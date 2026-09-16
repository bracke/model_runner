--  The vision encoder: a picture in, the rows a text model reads it as out.
--
--  What a multimodal model ships beside its text weights is a second file,
--  the projector -- `mmproj` in llama.cpp's naming -- holding an image
--  encoder and the small network that maps its output into the text
--  model's embedding width. The one this build carries is Gemma 3's:
--  SigLIP, a vision transformer of twenty-seven pre-normalized blocks over
--  the fourteen-pixel patches of an 896-pixel square, its 4096 patch
--  states pooled four by four to 256, each normalized and projected to the
--  text width. Those 256 rows stand in the prompt where the template wrote
--  the picture, one behind each <image_soft_token>, and the text model
--  reads them as it reads any embedding row.
--
--  Every product is the text model's own kernels over the projector's
--  tensors as they lie in the mapped file, in chunks of tokens sized for
--  the cache rather than for the weights, because here -- unlike a token
--  of text -- the activations outweigh the weights: 4096 rows of 1152
--  against 1152 of 1152.
--
--  Task safety: an encoder is opened, used and closed by one task. Its
--  products run on the pool the caller hands it.
with System;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Images;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

package Model_Runner.Vision is

   type Encoder is tagged limited private;

   --  Open a projector file and bind its tensors.
   --
   --  @param Item Encoder to open.
   --  @param Path The projector's GGUF file.
   --  @param Status Success, an IO or GGUF diagnostic, Arch_Unsupported_Projector
   --    when the file's projector is not one this build carries, or
   --    Arch_Missing_Tensor and its kin when the file is not whole.
   procedure Open
     (Item   : in out Encoder;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release everything. Idempotent.
   --
   --  @param Item Encoder to close.
   procedure Close (Item : in out Encoder);

   --  Whether Open succeeded and Close has not been called.
   --
   --  @param Item Encoder to inspect.
   --  @return True when the encoder can encode.
   function Is_Ready (Item : Encoder) return Boolean;

   --  The side of the square a picture is resampled to: 896 for Gemma 3.
   --
   --  @param Item Open encoder.
   --  @return Pixels a side.
   function Image_Size (Item : Encoder) return Positive;

   --  Rows one picture becomes: 256 for Gemma 3.
   --
   --  @param Item Open encoder.
   --  @return Rows a picture.
   function Rows_Per_Picture (Item : Encoder) return Positive;

   --  Width of each row, which is the text model's embedding width.
   --
   --  @param Item Open encoder.
   --  @return Elements a row.
   function Row_Width (Item : Encoder) return Positive;

   --  The projector's kind, as the file names it: "gemma3".
   --
   --  @param Item Open encoder.
   --  @return The projector type.
   function Projector (Item : Encoder) return String;

   --  Encode a picture.
   --
   --  The picture is resampled to Image_Size square, normalized as the
   --  file says, cut into patches, run through the encoder and the
   --  projector, and comes back as Rows_Per_Picture rows of Row_Width,
   --  laid end to end and indexed from 0, which the caller frees.
   --
   --  @param Item Open encoder.
   --  @param Picture The picture, any size.
   --  @param Team The pool the products run on -- the run's own, so that
   --    its workers do this rather than sit beside a second pool doing it
   --    -- or null to run on the calling task alone. Where the device
   --    backend is open, the encoder's linear products run there instead,
   --    the projector's tensors uploaded once and kept; the attention
   --    among the patches stays on the pool.
   --  @param Rows Receives the rows, or null on failure.
   --  @param Cancel Stop request, observed between blocks, or null.
   --  @param Status Success, Generation_Cancelled, Memory_Allocation_Failed
   --    or a backend diagnostic.
   procedure Encode
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : Model_Runner.Backend.CPU.Pool_Reference;
      Rows    : out Model_Runner.Tensors.Real_Array_Access;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out Model_Runner.Errors.Error_Info);

private

   package T renames Model_Runner.Tensors;

   --  Most blocks a projector may have; SigLIP so400m has twenty-seven.
   Max_Blocks : constant := 64;

   type Block is record
      Norm_1_Weight, Norm_1_Bias : T.Real_Array_Access := null;
      Norm_2_Weight, Norm_2_Bias : T.Real_Array_Access := null;
      Query, Key, Value, Output  : T.View := T.Empty_View;
      Query_Bias, Key_Bias, Value_Bias, Output_Bias : T.Real_Array_Access := null;
      Feed_In, Feed_Out : T.View := T.Empty_View;
      Feed_In_Bias, Feed_Out_Bias : T.Real_Array_Access := null;
   end record;

   type Block_Array is array (Natural range <>) of Block;
   type Block_Array_Access is access Block_Array;

   type Encoder is tagged limited record
      Ready     : Boolean := False;
      File      : Model_Runner.Byte_Sources.Files.File_Source;
      Container : Model_Runner.GGUF.Containers.Container;

      --  The tensor section, mapped or read.
      Base   : System.Address := System.Null_Address;
      Span   : Model_Runner.Bytes.Byte_Count := 0;
      Arena  : Model_Runner.Bytes.Byte_Array_Access := null;

      Kind       : String (1 .. 32) := [others => ' '];
      Kind_Last  : Natural := 0;
      Size       : Positive := 896;
      Patch      : Positive := 14;
      Width      : Positive := 1152;
      Feed       : Positive := 4304;
      Heads      : Positive := 16;
      Blocks     : Natural := 0;
      Epsilon    : Model_Runner.Numerics.Real := 1.0e-6;
      Pool_Side  : Positive := 4;
      Text_Width : Positive := 2560;
      Mean, Deviation : Model_Runner.Numerics.Real_List (1 .. 3) :=
        [others => 0.5];

      Patch_Weights : T.View := T.Empty_View;
      Patch_Bias    : T.Real_Array_Access := null;
      Positions     : T.View := T.Empty_View;
      Layers        : Block_Array_Access := null;
      Post_Weight, Post_Bias : T.Real_Array_Access := null;
      Soft_Norm     : T.Real_Array_Access := null;

      --  The projection, decoded and transposed from the file's rows --
      --  Width of them, Text_Width long -- into Text_Width rows of Width,
      --  so that it is a product like every other, and a view over those
      --  rows for a device to read.
      Projection_Rows : T.Real_Array_Access := null;
      Projection      : T.View := T.Empty_View;
   end record;

end Model_Runner.Vision;
