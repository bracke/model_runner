with System;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Float_Panels;
with Model_Runner.Numerics;
with Model_Runner.Safetensors;
with Model_Runner.Tensors;

--  Qwen-Image 2.1's VAE decoder: a latent to a picture
--  (docs/plan-image-generation.md, step 5).
--
--  Wan 2.2's decoder used for one frame, its kernels already 2-D in the
--  file: the latent unnormalized by its 64 means and deviations and turned
--  by post_quant_conv; conv_in, a mid block of a residual block, one
--  attention over every position and another residual block; five levels
--  of three residual blocks, the first four doubling the picture --
--  nearest 2x and a 3x3 -- with a weightless shortcut from the level's
--  input that keeps Wan's temporal factor even for one frame; a channel
--  RMS norm, SiLU and conv_out to red, green, blue and alpha.
--
--  Task safety: one task opens, decodes and closes a Decoder.
package Model_Runner.Qwen_Image.Decoder is

   type Picture_Decoder is tagged limited private;

   --  Read the decoder's tensors.
   --
   --  @param Item closed first, then open on success
   --  @param Path the safetensors file
   --  @param Status success; the file's own refusal; Arch_Missing_Tensor or
   --    Arch_Invalid_Tensor_Shape naming a tensor not this model's
   procedure Open (Item : in out Picture_Decoder; Path : String; Status : out Model_Runner.Errors.Error_Info);

   --  Let a decoder go.
   --
   --  @param Item closed; closing a closed one does nothing
   procedure Close (Item : in out Picture_Decoder);

   --  @param Item a decoder
   --  @return whether it is open
   function Is_Ready (Item : Picture_Decoder) return Boolean;

   --  The latent's channels, and the picture's.
   Latent_Channels  : constant := 64;
   Picture_Channels : constant := 4;

   --  How much larger a side the picture is than the latent.
   Upscale : constant := 16;

   --  Decode a latent: its convolutions on the device where one is open
   --  (Model_Runner.Backend.Device), the rest on the processor.
   --
   --  @param Item an open decoder
   --  @param Latent Latent_Channels planes of Rows by Columns, as the
   --    sampler leaves them
   --  @param Rows the latent's height
   --  @param Columns its width
   --  @param Pool the processor's workers, or null for this task alone
   --  @param Picture Picture_Channels planes of Rows * Upscale by Columns *
   --    Upscale -- red, green, blue, alpha -- as the decoder leaves them,
   --    about -1 to 1
   --  @param Status success, Tensor_Shape_Mismatch where an array is not
   --    its length, or the products' failure
   procedure Decode
     (Item    : Picture_Decoder;
      Latent  : Model_Runner.Numerics.Real_Array;
      Rows    : Positive;
      Columns : Positive;
      Pool    : Model_Runner.Backend.CPU.Pool_Reference;
      Picture : out Model_Runner.Numerics.Real_Array;
      Status  : out Model_Runner.Errors.Error_Info);

   --  How large a buffer the full-size level may take before a picture is
   --  decoded a stripe of latent rows at a time: 2 GB unless said, which a
   --  picture of 2048 on a side passes. Past the mid block the decoder is
   --  local -- its 3x3s, norms and doublings reach under thirteen latent
   --  rows -- so each stripe is decoded with Stripe_Halo rows either side
   --  and its middle rows are the whole picture's, while memory holds a
   --  stripe's buffers rather than the picture's. A test sets it small.
   --
   --  Task safety: set before the decodes it should govern.
   --
   --  @param Bytes The full-size level's most bytes a buffer.
   procedure Set_Stripes (Bytes : Long_Long_Integer := 2 * 1024 ** 3);

   --  Latent rows a stripe is decoded with on either side.
   Stripe_Halo : constant := 14;

   --  A decoded picture's planes as bytes, a pixel's four together, as the
   --  reference turns them: (x + 1) / 2, held to 0 .. 1, times 255, cut.
   --
   --  @param Picture Picture_Channels planes of Pixels each
   --  @param Pixels how many a plane
   --  @return Pixels * Picture_Channels bytes, red, green, blue, alpha
   function To_Pixels
     (Picture : Model_Runner.Numerics.Real_Array; Pixels : Model_Runner.Numerics.Element_Count)
      return Model_Runner.Bytes.Byte_Array
   with Pre => Model_Runner.Numerics."=" (Picture'Length, Model_Runner.Numerics."*" (Pixels, Picture_Channels));

private

   package T renames Model_Runner.Tensors;

   --  A convolution: its kernel as rows of an output channel each, and its
   --  bias. A 1x1's row is its input channels as the file has them; a
   --  3x3's is laid out again, its nine taps one after another, each tap
   --  every input channel, so that a pixel's neighbourhood is nine runs of
   --  channels copied whole. Where the rows or the columns are not a
   --  multiple of 32 they are made so with zeros, which the device's
   --  matrix kernel wants and the answers' extra channels are dropped
   --  after; Owned holds such a kernel, null where the file's own is used.
   --  A 3x3's nine taps, each a matrix of its own.
   type Tap_Views is array (0 .. 8) of T.View;

   type Convolution is record
      Kernel   : T.View;
      Owned    : Model_Runner.Bytes.Byte_Array_Access;
      --  And a 3x3's taps apart, each a matrix of the output channels by
      --  the input channels, both padded to 32, which Tap_Owned holds: the
      --  device's form, where each tap reads the pixels shifted rather
      --  than a neighbourhood gathered nine times over. Null for a 1x1, or
      --  a kernel of a format laid out otherwise.
      Tap_Owned : Model_Runner.Bytes.Byte_Array_Access;
      Taps      : Tap_Views;
      --  The gain of the norm before a 3x3, where one is, fitted to the
      --  taps' padded channels for the device's norm: times the root of the
      --  channels over the padded channels, since that norm's mean is over
      --  the padded ones, and nought past the channels. Null for none.
      Fit       : T.Real_Array_Access;
      --  The kernel in panels, where the decoder was opened with no device
      --  to run it: what the processor's products read.
      Panels   : Model_Runner.Float_Panels.Panel_Set;
      Bias     : T.Real_Array_Access;
      Inputs   : Natural := 0;
      Outputs  : Natural := 0;
      Size     : Natural := 0;
   end record;

   type Residual is record
      Norm_1, Norm_2   : T.Real_Array_Access;
      Conv_1, Conv_2   : Convolution;
      --  Where the width changes; Outputs nought where it does not.
      Shortcut         : Convolution;
   end record;

   type Residual_Array is array (1 .. 3) of Residual;

   type Level is record
      Blocks   : Residual_Array;
      --  The doubling's 3x3; Outputs nought on the last level.
      Up       : Convolution;
      --  Wan's temporal factor for the shortcut: two, or one.
      Temporal : Positive := 1;
   end record;

   type Level_Array is array (1 .. 5) of Level;

   type Width_Array is array (0 .. 5) of Positive;

   type Picture_Decoder is tagged limited record
      File     : Model_Runner.Byte_Sources.Files.File_Source;
      Table    : Model_Runner.Safetensors.Table;
      Arena    : Model_Runner.Bytes.Byte_Array_Access;
      Base     : System.Address := System.Null_Address;
      Span     : Model_Runner.Bytes.Byte_Count := 0;
      Ready    : Boolean := False;
      --  The mid block's width, then each level's out.
      Widths   : Width_Array := [others => 1];

      Post_Quant, Conv_In     : Convolution;
      Mid_1, Mid_2            : Residual;
      Attention_Norm          : T.Real_Array_Access;
      Joint, Attention_Out    : Convolution;
      Levels                  : Level_Array;
      Norm_Out                : T.Real_Array_Access;
      Conv_Out                : Convolution;
   end record;

end Model_Runner.Qwen_Image.Decoder;
