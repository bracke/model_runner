with System;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  Qwen-Image 2.1's denoiser, read from its GGUF (docs/plan-image-
--  generation.md, step 1).
--
--  The file states nothing: no architecture, no widths, no counts. It is
--  known by its tensors' names -- img_in, txt_in, time_text_embed,
--  modulation.1, transformer_blocks.N, norm_out, proj_out, each under
--  "model.diffusion_model." or under no prefix at all -- and its
--  configuration is their shapes: the width from img_in, the head's from a
--  block's norm_q, the feed-forward's from its out, the blocks counted. A
--  file whose shapes are not this model's is refused, naming the tensor,
--  rather than read as a model it only resembles. It is no text model and
--  goes nowhere near the language model's preparation.
--
--  Opening binds every matrix where it lies -- the file's own pages where
--  it is mapped -- and decodes the norms' gains once.
--
--  Task safety: a Denoiser is read by one task while it is opened or
--  closed; once open, its tensors may be read by many.
package Model_Runner.Qwen_Image is

   --  The most blocks a file may have: the published model has 32.
   Max_Blocks : constant := 256;

   --  The time's sinusoid, as wide as the reference makes it.
   Time_Width : constant := 256;

   --  What the shapes say.
   type Configuration is record
      --  Transformer blocks.
      Blocks       : Natural := 0;
      --  The width every token is carried at.
      Width        : Natural := 0;
      --  Attention heads, and the width of one.
      Heads        : Natural := 0;
      Head_Size    : Natural := 0;
      --  The feed-forward's inner width; gate_up is twice it.
      Feed         : Natural := 0;
      --  A latent pixel's channels, in and out.
      In_Channels  : Natural := 0;
      Out_Channels : Natural := 0;
      --  The width the text encoder's rows come in at.
      Context      : Natural := 0;
   end record;

   type Denoiser is tagged limited private;

   --  Read a denoiser.
   --
   --  @param Item closed first, then open on success
   --  @param Path the GGUF file
   --  @param Status success; or the file unreadable; or Arch_Unsupported
   --    where its tensors are not Qwen-Image 2.1's, Arch_Missing_Tensor or
   --    Arch_Invalid_Tensor_Shape naming one, Arch_Layer_Numbering_Gap where
   --    a block is missing below another
   procedure Open (Item : in out Denoiser; Path : String; Status : out Model_Runner.Errors.Error_Info);

   --  Let a denoiser go: its file, its tensors, its gains.
   --
   --  @param Item closed; closing a closed one does nothing
   procedure Close (Item : in out Denoiser);

   --  @param Item a denoiser
   --  @return whether it is open
   function Is_Ready (Item : Denoiser) return Boolean;

   --  @param Item an open denoiser
   --  @return its configuration
   function Config (Item : Denoiser) return Configuration;

   --  One evaluation: the velocity the latent is to move by at a time.
   --
   --  The latent is the picture's In_Channels planes of Rows by Columns,
   --  a plane a channel, row-major, as the reference lays it out; the
   --  velocity comes back the same way, Out_Channels planes. The prompt's
   --  rows go in with the image's: they attend causally among themselves
   --  and see no image, take the modulation of time nought, and are not
   --  answered; every image row sees all of them and every other.
   --
   --  @param Item an open denoiser
   --  @param Latent In_Channels * Rows * Columns values
   --  @param Rows the latent's height
   --  @param Columns its width
   --  @param Timestep the time, as the sampler gives it: the noise level
   --    times a thousand
   --  @param Text the prompt's rows, Text_Rows of Context values each
   --  @param Text_Rows how many
   --  @param Pool the processor's workers, or null for this task alone
   --  @param Result Out_Channels * Rows * Columns values
   --  @param Status success, Tensor_Shape_Mismatch where the arrays are not
   --    those lengths, or the products' failure
   procedure Velocity
     (Item      : Denoiser;
      Latent    : Model_Runner.Numerics.Real_Array;
      Rows      : Positive;
      Columns   : Positive;
      Timestep  : Model_Runner.Numerics.Real;
      Text      : Model_Runner.Numerics.Real_Array;
      Text_Rows : Natural;
      Pool      : Model_Runner.Backend.CPU.Pool_Reference;
      Result    : out Model_Runner.Numerics.Real_Array;
      Status    : out Model_Runner.Errors.Error_Info);

   --  The noise levels a picture is drawn through, as the reference's flow
   --  scheduler works them out for this model: t = 1 - i / Steps shifted by
   --  mu, linear in the image's token count from 0.5 at 256 to 0.9 at 8192,
   --  sigma = e^mu / (e^mu + 1 / t - 1); every level but the last then
   --  stretched, 1 - (1 - sigma) / k, so the last one the model is run at
   --  is 0.02; and nought after it.
   --
   --  @param Steps how many evaluations
   --  @param Image_Tokens the latent's pixels, rows times columns
   --  @return Steps + 1 levels, from one down to nought
   function Sigmas (Steps : Positive; Image_Tokens : Positive) return Model_Runner.Numerics.Real_Array
   with Post => Sigmas'Result'Length = Steps + 1;

private

   package T renames Model_Runner.Tensors;

   type Block is record
      --  Attention: queries, keys, values and the way out; the gains of
      --  each head's query and key normalization.
      Query, Key, Value, Attention_Out : aliased T.View;
      Query_Norm, Key_Norm             : T.Real_Array_Access;
      --  The feed-forward: the gate and the up projection in one, the gate
      --  first, then the way down.
      Gate_Up, Feed_Out : aliased T.View;
   end record;

   type Block_Array is array (Positive range <>) of Block;
   type Block_Array_Access is access Block_Array;

   type Denoiser is tagged limited record
      File      : Model_Runner.Byte_Sources.Files.File_Source;
      Container : Model_Runner.GGUF.Containers.Container;
      Arena     : Model_Runner.Bytes.Byte_Array_Access;
      Base      : System.Address := System.Null_Address;
      Span      : Model_Runner.Bytes.Byte_Count := 0;
      Ready     : Boolean := False;
      Shape     : Configuration;

      --  The latent's way in; the text's: a gain, two linears.
      Image_In                  : aliased T.View;
      Text_Norm                 : T.Real_Array_Access;
      Text_In_First, Text_In_Second : aliased T.View;
      --  The time: two linears after the sinusoid; the modulation every
      --  block reads; the last norm's scale and the way out.
      Time_First, Time_Second : aliased T.View;
      Modulation              : aliased T.View;
      Norm_Out, Projection_Out : aliased T.View;

      --  The matrices rewritten a panel of rows at a time, which the
      --  processor's integer products read several rows of at once.
      Panels : Model_Runner.Bytes.Byte_Array_Access;

      Layers : Block_Array_Access;
   end record;

end Model_Runner.Qwen_Image;
