--  The vision encoder: a picture in, the rows a text model reads it as out.
--
--  What a multimodal model ships beside its text weights is a second file,
--  the projector -- `mmproj` in llama.cpp's naming -- holding an image
--  encoder and the small network that maps its output into the text
--  model's embedding width. This build carries two. Gemma 3's: SigLIP, a
--  vision transformer of twenty-seven pre-normalized blocks over the
--  fourteen-pixel patches of an 896-pixel square, its 4096 patch states
--  pooled four by four to 256, each normalized and projected to the text
--  width. Those 256 rows stand in the prompt where the template wrote the
--  picture, one behind each <image_soft_token>, and the text model reads
--  them as it reads any embedding row. And Qwen3.5's, the Qwen3-VL
--  encoder: a picture kept at its own shape, its sides rounded to
--  multiples of thirty-two pixels, cut into sixteen-pixel patches walked
--  two by two so that a window's four patches lie together; a learned
--  position grid of forty-eight a side interpolated to the picture's;
--  twelve blocks whose queries and keys turn by the patch's row and
--  column -- half the pairs by each -- and attend over the whole; the
--  four patches of a window then joined into one row and projected in
--  two steps to the text width. A picture becomes as many rows as it has
--  windows, which the text model places by row and column too.
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
   --  For an encoder that keeps a picture's shape, the longest side a
   --  picture is held to.
   --
   --  @param Item Open encoder.
   --  @return Pixels a side.
   function Image_Size (Item : Encoder) return Positive;

   --  Whether every picture becomes the same number of rows -- Gemma 3's
   --  256 -- or a number its own shape decides, as a Qwen picture's is.
   --
   --  @param Item Open encoder.
   --  @return True when Rows_Per_Picture is every picture's count.
   function Fixed_Rows (Item : Encoder) return Boolean;

   --  Rows one picture becomes: 256 for Gemma 3. For an encoder whose
   --  count a picture's shape decides, the most a picture may become.
   --
   --  @param Item Open encoder.
   --  @return Rows a picture.
   function Rows_Per_Picture (Item : Encoder) return Positive;

   --  Whether the text model reads a picture's rows as a grid, each row
   --  turned by its own row and column: Qwen3.5 does, Gemma 3 does not.
   --
   --  @param Item Open encoder.
   --  @return True when the rows carry a place each.
   function Placed_Rows (Item : Encoder) return Boolean;

   --  Width of each row, which is the text model's embedding width.
   --
   --  @param Item Open encoder.
   --  @return Elements a row.
   function Row_Width (Item : Encoder) return Positive;

   --  The projector's kind, as the file names it: "gemma3" or
   --  "qwen3vl_merger".
   --
   --  @param Item Open encoder.
   --  @return The projector type.
   function Projector (Item : Encoder) return String;

   --  Encode a picture.
   --
   --  The picture is resampled to Image_Size square -- or, for an encoder
   --  that keeps its shape, to that shape rounded as the encoder needs and
   --  held within its bounds -- normalized as the file says, cut into
   --  patches, run through the encoder and the projector, and comes back
   --  as rows of Row_Width, laid end to end and indexed from 0, which the
   --  caller frees: Rows_Per_Picture of them where the count is fixed,
   --  and Grid_Rows by Grid_Columns of them otherwise, in row-major
   --  order.
   --
   --  @param Item Open encoder.
   --  @param Picture The picture, any size.
   --  @param Grid_Rows Receives how many rows of rows the picture became.
   --  @param Grid_Columns Receives how many rows each has.
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
      Grid_Rows    : out Natural;
      Grid_Columns : out Natural;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Whether the encoder reads a video: Qwen3.5's does, whose patch
   --  embedding is over two frames at once -- a still picture being the
   --  same frame twice -- and whose text model reads each pair of frames
   --  as a picture of its own, stood among the words that say when it
   --  was. Gemma 3's does not.
   --
   --  @param Item Open encoder.
   --  @return True when Frames_Fit and Encode_Frames may be called.
   function Reads_Video (Item : Encoder) return Boolean;

   --  The size every frame of a video is resampled to, by the reference
   --  video processor's rule: the sides rounded to multiples of the
   --  window, held between the video's pixel bounds over all its frames
   --  -- the least a video, and the most a frame times the frames, each
   --  frame capped at the reference's token ceiling -- and a side under
   --  the window scaled up to it first.
   --
   --  @param Item Open encoder that reads video.
   --  @param Width The frames' width, in pixels; every frame the same.
   --  @param Height The frames' height.
   --  @param Frames How many frames the video has, before any padding to
   --    a whole number of pairs.
   --  @param Fit_Width Receives the width to resample to.
   --  @param Fit_Height Receives the height.
   --  @param Status Success, or Arch_Unsupported_Feature where the frames'
   --    sides are more than two hundred to one, which the reference refuses.
   procedure Frames_Fit
     (Item   : Encoder;
      Width, Height : Positive;
      Frames : Positive;
      Fit_Width, Fit_Height : out Positive;
      Status : out Model_Runner.Errors.Error_Info);

   --  Encode one pair of frames of a video: the rows the text model reads
   --  the pair as, laid out as Encode lays a picture's -- Grid_Rows by
   --  Grid_Columns of them. The two frames are resampled to the fit
   --  Frames_Fit chose for the video, and each patch is the two frames'
   --  pixels through the patch weights of each temporal frame in turn,
   --  where a still picture's is the one frame through their sum. A video
   --  with an odd number of frames pairs its last with itself, as the
   --  reference pads it; the caller passes the same frame twice.
   --
   --  @param Item Open encoder that reads video.
   --  @param First The pair's first frame, any size.
   --  @param Second Its second, any size.
   --  @param Fit_Width The width Frames_Fit chose for the video.
   --  @param Fit_Height The height.
   --  @param Team As for Encode.
   --  @param Rows Receives the rows, or null on failure.
   --  @param Grid_Rows Receives how many rows of rows the pair became.
   --  @param Grid_Columns Receives how many rows each has.
   --  @param Cancel Stop request, or null.
   --  @param Status As for Encode, or Arch_Unsupported_Feature on an
   --    encoder that does not read video.
   procedure Encode_Frames
     (Item    : in out Encoder;
      First, Second : Model_Runner.Images.Raster;
      Fit_Width, Fit_Height : Positive;
      Team    : Model_Runner.Backend.CPU.Pool_Reference;
      Rows    : out Model_Runner.Tensors.Real_Array_Access;
      Grid_Rows    : out Natural;
      Grid_Columns : out Natural;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The reference video processor's bounds, which no projector file
   --  states: the fewest pixels a video may have over its frames, the
   --  most, and the most rows one frame may become, at which its pixels
   --  are capped when the budget's even share a frame is more.
   --  MiniCPM-V's llava-uhd slicing. A picture larger than the encoder's
   --  side is shown as an overview -- the whole fit to the side, aspect
   --  kept -- and a grid of slices, each a crop of the picture refined to
   --  a whole number of the encoder's-side cells. A picture within the
   --  side is the overview alone, upscaled to fill it. The grid is chosen
   --  to sit closest to the picture's aspect, at most nine cells. Every
   --  size returned is a whole number of patches, so the encoder resamples
   --  each to its own grid without distortion.
   Max_Slices : constant := 9;

   type Slice_Box is record
      Left, Top, Width, Height : Natural := 0;
   end record;

   type Slice_List is array (1 .. Max_Slices) of Slice_Box;

   --  Plan a picture's overview and slices.
   --
   --  @param Item Open MiniCPM-V encoder.
   --  @param Width The picture's width in pixels.
   --  @param Height Its height.
   --  @param Overview_W Receives the width to resize the whole to.
   --  @param Overview_H Its height.
   --  @param Refined_W The width to resize the whole to before cropping
   --    slices, or 0 where the picture is shown as the overview alone.
   --  @param Refined_H Its height, or 0.
   --  @param Grid_Cols How many slices a row, or 0 where there are none.
   --  @param Grid_Rows How many rows of slices, or 0.
   --  @param Slices Receives each slice's crop in the refined picture.
   --  @param Count How many slices, Grid_Cols times Grid_Rows, or 0.
   procedure Plan_Slices
     (Item          : Encoder;
      Width, Height : Positive;
      Overview_W, Overview_H : out Positive;
      Refined_W, Refined_H   : out Natural;
      Grid_Cols, Grid_Rows   : out Natural;
      Slices        : out Slice_List;
      Count         : out Natural);

   Video_Least_Pixels : constant := 4096;
   Video_Most_Pixels  : constant := 25_165_824;
   Video_Frame_Rows   : constant := 768;

private

   package T renames Model_Runner.Tensors;

   --  Most blocks a projector may have; SigLIP so400m has twenty-seven.
   Max_Blocks : constant := 64;

   type Block is record
      Norm_1_Weight, Norm_1_Bias : T.Real_Array_Access := null;
      Norm_2_Weight, Norm_2_Bias : T.Real_Array_Access := null;
      Query, Key, Value, Output  : T.View := T.Empty_View;
      Query_Bias, Key_Bias, Value_Bias, Output_Bias : T.Real_Array_Access := null;

      --  The three projections as one, where the file fuses them: rows of
      --  three times the width, queries first.
      Fused      : T.View := T.Empty_View;
      Fused_Bias : T.Real_Array_Access := null;
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

      --  What the Qwen encoder has that Gemma's has not: the patches
      --  walked in windows of Merge a side, whose rows are joined and
      --  projected in two steps; a position grid of Grid a side; the
      --  patch weights of the two temporal frames summed once, and a view
      --  over the sum for a device to read; and the bounds on how many
      --  rows a picture may become.
      Merge         : Positive := 2;
      Grid          : Positive := 48;
      Patch_Sum     : T.Real_Array_Access := null;
      Patch_Both    : T.View := T.Empty_View;

      --  And the two temporal frames' patch weights side by side, a row
      --  the first frame's then the second's, for a pair of frames of a
      --  video whose patch is the two frames' pixels laid the same way.
      Patch_Pair_Rows : T.Real_Array_Access := null;
      Patch_Pair      : T.View := T.Empty_View;
      Merge_In, Merge_Out : T.View := T.Empty_View;
      Merge_In_Bias, Merge_Out_Bias : T.Real_Array_Access := null;
      Least_Rows    : Positive := 64;
      Most_Rows     : Positive := 4096;

      --  What the MiniCPM-V resampler has that neither Gemma's pool nor
      --  Qwen's merge does: a fixed bank of learned query rows that read
      --  the patch states by cross-attention, so that a picture becomes
      --  Num_Query rows however many patches it has. The patch states are
      --  projected to the text width by Kv_Proj and normed (ln_kv); the
      --  queries normed (ln_q); the keys are the projected states plus a
      --  two-dimensional sinusoidal place; query, key and value each turn
      --  through their own weights into heads of a hundred and twenty-eight;
      --  the blend turns back through the output weights, is normed once
      --  more (ln_post) and projected. The version the file states, kept
      --  for the record.
      Num_Query        : Natural := 0;
      Minicpm_Version  : Natural := 0;
      Query_Rows       : T.View := T.Empty_View;
      Kv_Proj          : T.View := T.Empty_View;
      R_Attn_Q, R_Attn_K, R_Attn_V, R_Attn_O : T.View := T.Empty_View;
      R_Attn_Q_B, R_Attn_K_B, R_Attn_V_B, R_Attn_O_B :
        T.Real_Array_Access := null;
      R_Ln_Q_W, R_Ln_Q_B     : T.Real_Array_Access := null;
      R_Ln_Kv_W, R_Ln_Kv_B   : T.Real_Array_Access := null;
      R_Ln_Post_W, R_Ln_Post_B : T.Real_Array_Access := null;
      R_Proj           : T.View := T.Empty_View;
   end record;

end Model_Runner.Vision;
