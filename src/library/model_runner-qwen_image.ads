with Interfaces;
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
   --  @param Panels Whether the matrices are rewritten into the processor's
   --    panel layout: for a denoiser the processor runs, and not for one
   --    the device does, which reads the file's own layout
   procedure Open
     (Item   : in out Denoiser;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info;
      Panels : Boolean := True);

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
   --  Where a device is open (Model_Runner.Backend.Device), its products and
   --  its attention run there, and the rest on the processor. The prompt's
   --  rows are worked out afresh; see the Velocity with a Prefix_Cache.
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

   --  What a prompt's rows leave in each block -- their keys, normalized
   --  and turned, and their values -- kept from one evaluation to the next.
   --  The prompt's rows see no image and take the modulation of time
   --  nought, so every block makes the same of them at every step: the
   --  first evaluation keeps them, and the later ones carry the image's
   --  rows alone, the kept rows standing in front of their keys and values
   --  where the prompt's are attended to. The reference keeps them so too.
   --
   --  Task safety: read and written by the one task evaluating with it.
   type Prefix_Cache is limited private;

   --  Let what a cache holds go; it is empty after, and the next
   --  evaluation with it keeps afresh.
   --
   --  @param Cache emptied
   procedure Forget (Cache : in out Prefix_Cache);

   --  Velocity, with the prompt's rows kept in Prefix: kept by the first
   --  evaluation with an empty cache, read by every later one with the same
   --  prompt rows, and kept again where the rows differ. A prompt so long
   --  its rows would take more than a gigabyte is not kept.
   --
   --  @param Item an open denoiser
   --  @param Latent In_Channels * Rows * Columns values
   --  @param Rows the latent's height
   --  @param Columns its width
   --  @param Timestep the noise level times a thousand
   --  @param Text the prompt's rows, Text_Rows of Context values each
   --  @param Text_Rows how many
   --  @param Pool the processor's workers, or null for this task alone
   --  @param Result Out_Channels * Rows * Columns values
   --  @param Status as the Velocity without a cache says
   --  @param Prefix the prompt's kept rows, for this denoiser alone
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
      Status    : out Model_Runner.Errors.Error_Info;
      Prefix    : in out Prefix_Cache);

   --  How large a picture's latent is before each block goes to the device
   --  a chunk of its rows at a time rather than in one sequence, and how
   --  large a chunk is: 8,192 rows and 4,096 unless said -- a 1440 picture
   --  and half. The processor's attention asks a quarter of a chunk's
   --  rows at a time. A test sets them small to take the chunked ways on a
   --  small picture.
   --
   --  Task safety: set before the evaluations it should govern.
   --
   --  @param Past Rows past which the blocks go in chunks.
   --  @param Rows Rows a chunk holds.
   procedure Set_Chunking (Past : Positive := 8_192; Rows : Positive := 4_096);

   --  How many bytes the prompt's keys and values, every block's, may take
   --  before they are not kept between steps and every step reads the
   --  prompt's rows beside the image's: 1 GiB unless said, which a prompt
   --  of the longest the encoder reads does not reach. A test sets it
   --  small to take the way a prompt past it takes.
   --
   --  Task safety: set before the evaluations it should govern.
   --
   --  @param Bytes The room.
   procedure Set_Prefix_Room (Bytes : Positive := 1_073_741_824);

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

   --  No prompt rows: what Sample reads as its negative where none is asked.
   No_Rows : constant Model_Runner.Numerics.Real_Array (1 .. 0) := [others => 0.0];

   --  The distilled model's own levels, eight steps, as the reference's
   --  qwen-image-2.1-turbo preset gives them.
   Turbo_Levels : constant Model_Runner.Numerics.Real_Array :=
     [1.0, 0.978_453, 0.954_18, 0.926_626, 0.895_08, 0.845_148, 0.704_534, 0.414_568, 0.0];

   --  A picture's latent, drawn from its seed: the seed's noise, then an
   --  Euler step a noise level, x + (next - sigma) * v, through Sigmas.
   --
   --  @param Item an open denoiser
   --  @param Rows the latent's height, a sixteenth of the picture's
   --  @param Columns its width
   --  @param Steps how many evaluations
   --  @param Seed the noise's, as the reference's Philox draws it
   --  @param Text the prompt's rows, Text_Rows of Context values each
   --  @param Text_Rows how many
   --  @param Pool the processor's workers, or null for this task alone
   --  @param Latent Out_Channels planes of Rows by Columns, as the decoder
   --    reads them
   --  @param Status success, or the step's failure
   --  @param Progress told after each step, where it is given
   --  @param Turbo through Turbo_Levels, eight steps whatever Steps says,
   --    for the distilled model
   --  @param Guidance how far each step leans from the negative prompt
   --    toward Text: the velocity is the negative's plus Guidance times the
   --    difference, as the reference's guidance takes it; at one there is
   --    no lean and no second evaluation
   --  @param Negative the negative prompt's rows, Negative_Rows of them,
   --    read where Guidance is not one
   --  @param Negative_Rows how many
   --  @param Init a picture's latent to draw from, as the encoder leaves
   --    it, or none to draw from noise
   --  @param Strength how much of Init is drawn anew: the levels from
   --    First_Level on, and the first a mix of Init and the noise -- the
   --    noise times that level, Init times one less it
   procedure Sample
     (Item      : Denoiser;
      Rows      : Positive;
      Columns   : Positive;
      Steps     : Positive;
      Seed      : Interfaces.Unsigned_64;
      Text      : Model_Runner.Numerics.Real_Array;
      Text_Rows : Natural;
      Pool      : Model_Runner.Backend.CPU.Pool_Reference;
      Latent    : out Model_Runner.Numerics.Real_Array;
      Status    : out Model_Runner.Errors.Error_Info;
      Progress  : access procedure (Step : Positive; Steps : Positive) := null;
      Turbo     : Boolean := False;
      Guidance  : Model_Runner.Numerics.Real := 1.0;
      Negative  : Model_Runner.Numerics.Real_Array := No_Rows;
      Negative_Rows : Natural := 0;
      Init      : Model_Runner.Numerics.Real_Array := No_Rows;
      Strength  : Model_Runner.Numerics.Real := 1.0);

   --  Where a picture drawn from another starts on its levels, as the
   --  reference starts it: Steps times Strength in binary32, truncated, is
   --  how many steps the picture keeps, one fewer where that is all of
   --  them; the levels taken from that many and one before the end.
   --
   --  @param Steps the levels a picture from noise is drawn through, less
   --    the last
   --  @param Strength how much of the picture is drawn anew, 0 .. 1
   --  @return the index, from nought, of the first level taken
   function First_Level (Steps : Positive; Strength : Model_Runner.Numerics.Real) return Natural;

private

   package T renames Model_Runner.Tensors;

   type Block is record
      --  Attention: queries, keys, values and the way out; the gains of
      --  each head's query and key normalization.
      Query, Key, Value, Attention_Out : aliased T.View;
      Query_Norm, Key_Norm             : T.Real_Array_Access;
      --  The feed-forward: the gate and the up projection in one, the gate
      --  first, then the way down; and the gate's rows and the up's apart,
      --  views over the same bytes, for the device's gated block.
      Gate_Up, Feed_Out : aliased T.View;
      Gate, Up          : T.View;
   end record;

   type Block_Array is array (Positive range <>) of Block;
   type Block_Array_Access is access Block_Array;

   type Prefix_Cache is limited record
      --  The prompt's rows it was kept from, and how many; their keys and
      --  values, a block after another, the rows of each one after
      --  another.
      Text         : T.Real_Array_Access;
      Rows         : Natural := 0;
      Keys, Values : T.Real_Array_Access;
   end record;

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
