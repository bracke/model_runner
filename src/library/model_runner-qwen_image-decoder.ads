with System;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Float_Panels;
with Model_Runner.Images;
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

   --  Read the decoder's tensors, and the encoder's where asked.
   --
   --  @param Item closed first, then open on success
   --  @param Path the safetensors file
   --  @param Status success; the file's own refusal; Arch_Missing_Tensor or
   --    Arch_Invalid_Tensor_Shape naming a tensor not this model's
   --  @param Encoder whether to read the encoder too, for Encode
   procedure Open
     (Item    : in out Picture_Decoder;
      Path    : String;
      Status  : out Model_Runner.Errors.Error_Info;
      Encoder : Boolean := False);

   --  Let a decoder go.
   --
   --  @param Item closed; closing a closed one does nothing
   procedure Close (Item : in out Picture_Decoder);

   --  @param Item a decoder
   --  @return whether it is open
   function Is_Ready (Item : Picture_Decoder) return Boolean;

   --  @param Item a decoder
   --  @return whether it was opened with its encoder
   function Can_Encode (Item : Picture_Decoder) return Boolean;

   --  A picture as Encode reads it, at Height by Width: each pixel the
   --  source's nearest -- the reference's resampling, the source pixel
   --  at the floor of the pixel's place scaled -- its bytes b each 2 b /
   --  255 - 1, and an alpha of 255 where the picture has none.
   --
   --  @param Source the picture
   --  @param Height rows wanted
   --  @param Width columns wanted
   --  @param Planes receives Picture_Channels planes of Height by Width
   procedure From_Raster
     (Source : Model_Runner.Images.Raster;
      Height : Positive;
      Width  : Positive;
      Planes : out Model_Runner.Numerics.Real_Array)
   with Pre => Model_Runner.Numerics."="
                 (Planes'Length,
                  Model_Runner.Numerics.Element_Count (Picture_Channels * Height * Width));

   --  A picture into a latent, as the reference's VAE encodes one: its
   --  values as the decoder leaves them, -1 .. 1, a byte b being 2 b / 255
   --  - 1, and an opaque picture's alpha 1; the input 3x3; five levels of two residual blocks, the first four each
   --  ended by a 3x3 of stride two over the picture padded right and
   --  below by a pixel, and a weightless shortcut -- the level's input
   --  averaged over each 2x2 of pixels into its channels, behind a frame
   --  of zeros where the level halves time as well; the mid block's
   --  residual blocks and attention; a norm, SiLU, conv_out and
   --  quant_conv; the mean's half of what that makes, each channel less
   --  its mean and over its deviation. On the processor, through panels,
   --  whether a device is open or not: it runs once a picture.
   --
   --  @param Item a decoder opened with its encoder
   --  @param Picture Picture_Channels planes of Height by Width, red,
   --    green, blue, alpha, each value in -1 .. 1
   --  @param Height the picture's rows, a multiple of Upscale
   --  @param Width its columns, a multiple of Upscale
   --  @param Pool the workers, or null
   --  @param Latent receives Latent_Channels planes of Height / Upscale by
   --    Width / Upscale
   --  @param Status success, Tensor_Shape_Mismatch, or a memory failure
   procedure Encode
     (Item    : Picture_Decoder;
      Picture : Model_Runner.Numerics.Real_Array;
      Height  : Positive;
      Width   : Positive;
      Pool    : Model_Runner.Backend.CPU.Pool_Reference;
      Latent  : out Model_Runner.Numerics.Real_Array;
      Status  : out Model_Runner.Errors.Error_Info);

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

   --  The latent's statistics, from the model's configuration: what the
   --  sampler's latent is multiplied by and moved by before decoding, and
   --  what the encoder's mean is moved by and divided by after.
   type Latent_Statistics is array (0 .. Latent_Channels - 1) of Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Real;

   Latent_Means : constant Latent_Statistics :=
     [0.5126, 0.7721, -0.0631, 1.3506, -0.7855, -2.1025, -0.3458, 1.3722,
      1.8873, -1.7177, -0.6510, 0.2732, 0.7562, -0.6163, -1.0277, 3.8363,
      2.0210, 0.0472, 0.9320, 2.0087, 2.4954, -0.1391, -1.4249, 1.8464,
      -0.5236, 1.2826, 3.7046, -1.3035, 2.7286, -1.4518, -1.9036, -1.9955,
      -0.0342, -1.0265, -0.7636, 3.0555, 0.0746, -3.0751, -0.1076, 1.7376,
      -1.0914, -1.9435, -0.2784, -1.3680, 0.4809, -0.4433, 0.3764, 0.5729,
      -2.0595, 1.0960, -1.3260, -2.0211, -5.0179, 0.5275, 4.0162, 1.8505,
      0.3026, 1.9373, 1.4937, 0.2632, 0.5547, -1.7121, -0.1562, 0.0304];
   Latent_Deviations : constant Latent_Statistics :=
     [3.2001, 3.2936, 3.4321, 3.0091, 3.1061, 4.0379, 4.0705, 3.7910,
      3.0785, 3.6500, 3.9308, 3.0904, 2.8778, 3.7675, 3.7320, 5.0756,
      3.2864, 4.0397, 3.1317, 4.0443, 2.9249, 3.9454, 3.0988, 4.2489,
      3.4896, 3.8513, 3.9323, 3.4719, 3.7498, 4.2830, 3.5694, 4.2467,
      3.9037, 3.2947, 5.0770, 3.5075, 3.2700, 3.4767, 2.8063, 5.1125,
      3.5327, 4.7833, 3.1286, 4.1819, 3.8527, 3.8312, 3.5605, 4.3875,
      3.9624, 4.0168, 3.5643, 4.0550, 5.5614, 4.2963, 4.4080, 3.4959,
      3.8747, 3.7608, 3.5735, 3.1490, 3.7662, 3.6746, 3.4563, 3.8161];

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
      --  And the nine as one matrix, nine taps' rows tall, for the device's
      --  tile to run as one product (Backend.Device.Add_View_Taps).
      Tap_Stack : T.View;
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

   --  The encoder's two residual blocks a level, and the 3x3 of stride two
   --  that ends the first four (Outputs nought on the last); Temporal is
   --  the shortcut's factor in time, as the decoder's level has it.
   type Down_Blocks is array (1 .. 2) of Residual;

   type Down_Level is record
      Blocks   : Down_Blocks;
      Down     : Convolution;
      Temporal : Positive := 1;
   end record;

   type Down_Level_Array is array (0 .. 4) of Down_Level;

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

      --  The encoder's, where it was asked for: its widths (conv_in's
      --  out, then each level's out), and its layers.
      Encoding                : Boolean := False;
      Down_Widths             : Width_Array := [others => 1];
      Enc_In                  : Convolution;
      Downs                   : Down_Level_Array;
      Enc_Mid_1, Enc_Mid_2    : Residual;
      Enc_Attention_Norm      : T.Real_Array_Access;
      Enc_Joint, Enc_Attention_Out : Convolution;
      Enc_Norm_Out            : T.Real_Array_Access;
      Enc_Out, Quant          : Convolution;
   end record;

end Model_Runner.Qwen_Image.Decoder;
