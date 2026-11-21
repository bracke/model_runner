with Model_Runner.Platform.Pages;
with Model_Runner.Platform.Mapped_Ranges;
with Model_Runner.Platform.Device.Tile_Plans;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

with Model_Runner.Kernels;
with Model_Runner.Shaders;
with Model_Runner.Shaders.Low;
with Model_Runner.Shaders.Low_Dots;
with Model_Runner.Shaders.Low_Tiles;
with Model_Runner.Shaders.Mid_Tiles;
with Model_Runner.Shaders.Attend;
with Model_Runner.Shaders.Super;

--  Products on a device, through the same interface the parent opened it
--  with.
--
--  A weight handed over once stays. What that costs is a table of what is
--  held, keyed by where the matrix lives in the model's own storage; what it
--  buys is that the second product with the same matrix moves a vector
--  rather than a matrix, which on any real model is every product but the
--  first.
--
--  Handles here are addresses. The interface has two kinds -- ones that are
--  pointers and ones that are sixty-four bit numbers -- and on the machines
--  this program targets both are eight bytes, so one Ada type carries both.
--  A thirty-two bit host would need them told apart, and this does not
--  claim to run on one.
--
--  Every structure is declared with the fields the interface states, in
--  order. Where C would pad between a four-byte field and an eight-byte one
--  the Ada compiler pads the same way for a record with C convention, which
--  is what that convention is for.
package body Model_Runner.Platform.Device.Products is

   use type Interfaces.C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Model_Runner.Numerics.Element_Count;

   package C renames Interfaces.C;
   package Tiles renames Model_Runner.Platform.Device.Tile_Plans;

   use type Model_Runner.Bytes.Byte_Count;

   subtype Address is System.Address;

   Null_Handle : constant Address := System.Null_Address;

   --  What the interface calls the structures this passes.
   Structure_Submit            : constant := 4;
   Structure_Memory_Allocate   : constant := 5;
   Structure_Fence_Create      : constant := 8;
   Structure_Buffer_Create     : constant := 12;
   Structure_Shader_Create     : constant := 16;
   Structure_Stage_Create      : constant := 18;
   Structure_Compute_Pipeline  : constant := 29;
   Structure_Pipeline_Layout   : constant := 30;
   Structure_Set_Layout        : constant := 32;
   Structure_Descriptor_Pool   : constant := 33;
   Structure_Descriptor_Set    : constant := 34;
   Structure_Write_Descriptor  : constant := 35;
   Structure_Command_Pool      : constant := 39;
   Structure_Command_Buffer    : constant := 40;
   Structure_Command_Begin     : constant := 42;

   --  A buffer is a storage buffer the shaders read and write, and a
   --  transfer's source and destination besides: the engine fills one to
   --  zero it and copies one into another to grow a session's cache, and
   --  the interface asks a buffer to say so before either. The bits are
   --  disjoint, so the sum is their union.
   Usage_Transfer_Src   : constant := 16#01#;
   Usage_Transfer_Dst   : constant := 16#02#;
   Usage_Storage_Buffer : constant := 16#20#;
   Usage_Buffer         : constant :=
     Usage_Storage_Buffer + Usage_Transfer_Src + Usage_Transfer_Dst;
   Sharing_Exclusive    : constant := 0;
   Descriptor_Storage   : constant := 7;
   Stage_Compute        : constant := 16#20#;

   --  A barrier between one dispatch and the next, for the case where the
   --  second reads what the first wrote. Products of the same activation
   --  need none of this -- they touch nothing in common -- but a chained one
   --  does, and without it a device is free to start the reader before the
   --  writer has finished.
   Structure_Memory_Barrier : constant := 46;
   Pipeline_Stage_Compute   : constant := 16#800#;

   --  A timestamp query pool, and the stamps a timed sequence writes into
   --  it: one before the first dispatch and one after each step's last,
   --  each latched when everything before it has left the pipeline.
   Structure_Query_Pool     : constant := 11;
   Query_Timestamp          : constant := 2;
   Pipeline_Stage_Bottom    : constant := 16#2000#;
   Query_Result_64          : constant := 1;
   Query_Result_Wait        : constant := 2;
   Access_Shader_Read       : constant := 16#20#;
   Access_Shader_Write      : constant := 16#40#;

   --  And the transfer stage, for the two commands that write a buffer
   --  without a shader: the fill that zeroes a fresh cache or room, and
   --  the copy that carries what a smaller one held into it.
   Pipeline_Stage_Transfer  : constant := 16#1000#;
   Access_Transfer_Read     : constant := 16#800#;
   Access_Transfer_Write    : constant := 16#1000#;
   Bind_Point_Compute   : constant := 1;
   Level_Primary        : constant := 0;
   Use_Once             : constant := 1;

   --  How many invocations one group has, which the shader states as well.
   --  The two have to agree: the dispatch below asks for one group per this
   --  many rows.
   --
   --  Two hundred and fifty-six rather than the sixty-four it was, which is
   --  four waves to a group rather than one. Nothing had ever varied it --
   --  it was the width of a wave on the part this was written against, which
   --  is a reason to pick a number and not a reason to keep it -- and it is
   --  worth five per cent of a device prompt: 0.547 s against 0.579, better
   --  in each of three alternated rounds. What it buys is latency hiding,
   --  since a group is what the device can switch between when one of its
   --  waves is waiting on memory, and one wave to a group leaves it nothing
   --  to switch to. Generating reads about two per cent slower, which is
   --  inside the spread of that row and the other way round in one round of
   --  the three; a prompt has the rows to fill the wider group and a token
   --  does not.
   Group_Size : constant := 256;

   --  And the width the second compilation of the row product declares,
   --  which the two formats named in Half_Grouped are bound to.
   Half_Group : constant := 128;

   --  Invocations that share one row, which the shader states as well.
   --
   --  A row is divided across this many lanes so that their reads of the
   --  weights are consecutive bytes rather than one byte each from addresses
   --  a row apart. The dispatch below therefore asks for this many
   --  invocations per row rather than one.
   Row_Lanes : constant := 8;

   --  The super-block row product's workgroup is one subgroup of thirty-two
   --  lanes, and it lands a band of this many rows -- the shader's NUM_ROWS,
   --  which the two must agree on: the dispatch asks for one workgroup a band.
   --  Host memory a default device budget leaves available, on a part
   --  whose device memory is the host's: the desktop and whatever else the
   --  machine runs keep this much however large a model is.
   Host_Reserve : constant := 6 * 1024 * 1024 * 1024;

   Wave_Lanes : constant := 64;

   --  The widest row an integer walk rounds the activations of, and the
   --  room that takes: eight positions' bytes and a four-byte scale for
   --  every thirty-two of them, nine bytes a column. Wider rows walk in
   --  binary32.
   Round_Columns : constant := 131_072;

   --  A region's room: eight positions of the widest row, or -- for a
   --  mixture's runs by slot, which may be many more rows than eight -- as
   --  many rows of a narrower one as fit.
   Round_Bytes   : constant := 4 * 1024 * 1024;

   --  The longest run a long batch's listed product walks rather than
   --  tiles; see Split_Listed.
   Split_Most    : constant := 4;

   --  And a second region past it that only a normalization rounding its
   --  own answer writes, for the walks that read that answer: a walk's own
   --  rounding between the two would otherwise overwrite it.
   Normed_At     : constant := Round_Bytes;
   Round_Room    : constant := 2 * Round_Bytes;
   Wave_Rows  : constant := 2;

   --  The low-bit subgroup kernels' band, their shader's NUM_ROWS, and their
   --  width: a wave of sixty-four -- four groups of 256 in flight -- where
   --  the k-quants' is thirty-two. llama.cpp's own kernels for these
   --  formats run at the device's native wave, and on this part the width
   --  was worth more than any change to the decode.
   Low_Wave_Rows  : constant := 8;

   --  The grid formats but IQ1's, one vector at a time: four rows a
   --  workgroup, twice the workgroups (llama.cpp's own count on this part);
   --  their few-vector walks keep eight (MANY_ROWS in compile-shaders.sh).
   --  On the device's clock, three alternated rounds: rows of 17,408 5-9
   --  per cent faster, rows of 5,120 level but for the IQ3 formats' 4-9
   --  faster and IQ2_XXS's 3 slower; IQ1_S and IQ1_M 2-5 slower, and
   --  left at eight.
   Codebook_Wave_Rows : constant := 4;
   subtype Four_Row_Codebooks is Weight_Packing range Packed_IQ3_S .. Packed_IQ3_XXS;

   --  Q8_0's band on the same kernel: fewer rows a workgroup, more
   --  workgroups, which a format that is read rather than decoded wants.
   Q8_Wave_Rows   : constant := 2;

   --  And for rows shorter than this, four rows a workgroup: a short row is
   --  a few groups of 256, which leaves most of a workgroup's four groups in
   --  flight with nothing to read, and a row more a workgroup gives them
   --  work. Measured a token, two rows against four: gpt-2 (768 wide)
   --  378.7 -> 384, qwen3.5-0.8b (1024) 72.8 -> 75.3, DeepSeek-V2-Lite's
   --  experts' down (1408) 296 -> 276 us; TinyLlama (2048 and wider) 62.0
   --  -> 60.1 the other way.
   Q8_Short_Rows    : constant := 4;

   --  And Q4_K's and Q6_K's band over a few positions at once: their
   --  shader's NUM_ROWS.
   Many_Rows : constant := 8;
   Q8_Short_Columns : constant := 2048;

   --  And its compilations over several vectors, which load each vector's
   --  activations once for this many rows.
   Q8_Multi_Rows  : constant := 4;
   Q6_Wave_Rows   : constant := 2;

   --  The row length past which a Q6_K row goes to the compilation that
   --  gives each row two waves' lanes: a projection down reads rows of
   --  ten or twelve thousand columns, a dozen blocks a lane in a row,
   --  and qwen3-8b's read at 63 GB/s where its output head's rows of four
   --  thousand read at 70 -- 649 -> 596 us with the row shared. The head
   --  itself went the other way, 7.3 -> 7.9 ms, and stays where it was.
   Long_Row_Columns : constant := 8192;

   --  The row length past which a Q6_K row goes to the compilation that
   --  reads a block's scales a lane each and shares them round the wave
   --  (SHARED_SCALES in row_product_super6.comp): Steelman-14B's 152064 x
   --  5120 head 8,900 -> 8,632 us, where TinyLlama's 32000 x 2048 one went
   --  745 -> 783 and stays with the four loads.
   Mid_Row_Columns : constant := 2048;

   --  And the IQ4 formats', their shader's NUM_ROWS: four, as Q2_K's,
   --  where two read TinyLlama IQ4_NL at 96 and IQ4_XS at 104 tokens a
   --  second against 99 and 108 at four.
   IQ4_Wave_Rows  : constant := 4;
   Half_Wave_Rows : constant := 2;
   Q2K_Wave_Rows  : constant := 4;
   Low_Wave_Lanes : constant := 64;

   --  Rows of the answer one workgroup of the matrix product computes, and
   --  vectors of it. The shader states both and this has to agree: the
   --  first says how many workgroups a matrix needs, the second says how
   --  far the batch is rounded up before it is handed over.
   Tile_Rows    : constant := 64;

   --  The narrow tile's rows: thirty-two, on two subgroups. It was one
   --  subgroup of sixty-four rows, and a matrix of few rows was few
   --  workgroups -- gemma's 2048 rows thirty-two, too few to keep the
   --  memory busy. At thirty-two rows on one subgroup Gemma 4 E4B's
   --  24-token prompt read in 0.137 s against 0.144, gemma-3-4b's 0.101
   --  against 0.107, and qwen3-8b's 0.205 against 0.193, its rows enough
   --  already; on two subgroups 0.113, 0.088 and 0.166, sixty-four rows
   --  for the matrices with many no better (0.113, 0.093, 0.168). The
   --  narrow tile is a batch of nine to thirty-two: a short prompt, a long
   --  one's last batch, a drafted round's check.
   Narrow_Rows : constant := 32;

   --  What a matrix's rows must divide by to be tiled: half a tile, the
   --  last tile of such a matrix covering the half it has.
   Tile_Grain   : constant := 32;

   --  The rows of the taps' two tiles (matrix_product.comp's TAP_ROWS).
   --  A VAE's 3x3s on the first tile, Qwen-Image's decoder at 1024 on the
   --  device's timeline, a tap product's microseconds at 64 / 32 / 96 rows:
   --  160 by 160 5641 / 4495 / 5550, 160 by 288 5535 / 4520 / 5411, 32 by
   --  160 10121 / 6233 / 13577; 288 by 288 7862 / 7383 / 7199, 288 by 576
   --  7966 / 7786 / 7106, 576 by 576 9360 / 9610 / 8934, 1152 by 1152
   --  19091 / 20400 / 18386. Its vectors come from the cache however many
   --  tiles of rows read them, so the rows past a matrix's end are what a
   --  height that does not divide it costs.
   Tap_Short_Rows : constant := 32;

   --  And the wider tile's (matrix_product.comp's WIDER).
   Wider_Rows : constant := 96;
   Tap_Tall_Rows  : constant := 96;
   Tile_Vectors : constant := Tiles.Default_Vectors;

   --  And the tile a listed product's runs are cut into -- thirty-two
   --  vectors, sixty-four rows, two subgroups stepping sixty-four columns
   --  -- as matrix_product.comp says why. Measured against the clock,
   --  which drifts with the heat: a hundred and twenty-eight vectors
   --  wide, as the dense tile is, 13.0 million cycles a gate stack at
   --  512 positions; sixty-four wide 10.2; thirty-two wide and two
   --  subgroups 9.4, and 8.5 to 9.3 at thirty-two rows against 10.5 to
   --  10.7 for the down stack, which is why the rows stay at sixty-four.
   --  A hundred and twenty-eight rows read 11.5.
   Listed_Vectors : constant := 32;
   Listed_Rows    : constant := 64;
   Listed_Step    : constant := 64;

   --  And the tile again at sixty-four vectors, for runs long enough to
   --  fill it: an expert's weights are decoded once for every tile of its
   --  run, so a run of sixty decodes half as often. Taken where the runs
   --  average Listed_Wide_Run or more, as gpt-oss's thirty-two experts
   --  four at a time make them: its 481-token prompt 280 -> 316 tokens a
   --  second, its 2,000-token one 302 -> 372, Mellum's sixty-four eight at
   --  a time 664 -> 674 and 626 -> 658, the answers the same. Not for the
   --  low-bit formats: Qwen3.6's IQ3_XXS stacks read 2% slower at runs of
   --  sixteen and the same at sixty-two.
   Listed_Wide_Vectors : constant := 64;
   Listed_Wide_Run     : constant := 48;

   --  The runs a mixture's experts average for their gate, up and
   --  combination to be folded into two products (Fold_Gate). It was
   --  Listed_Wide_Run, the wider tile's, which a fold does not need: at
   --  runs of sixteen the fold's two products beat the gate, the up and
   --  the combination apart. Gemma 4's 26B, a batch of 512 over 128
   --  experts eight at a time, runs of 32: 1,328-token prompt 380-390 ->
   --  404-406 tokens a second; Mellum's 279 616 -> 661, gpt-oss's 262
   --  408 -> 428-436. The fold stores the gate and the middle as halves,
   --  as it did past the old line, so an answer at a near-tie may move;
   --  Mellum's perplexity over 16 chunks of 256, 19.086 -> 19.057.
   Fold_Least_Run      : constant := 16;

   --  Tile selection is a measured policy, now owned by a small package
   --  rather than by loose globals in this Vulkan engine.  These wrappers
   --  retain the vocabulary used by the product and Run subunits.
   Mid_Wide_Vectors : constant := Tiles.Mid_Wide_Vectors;
   Wider_Vectors    : constant := Tiles.Wider_Vectors;

   function Narrowed (Count : Natural) return Boolean
   is (Tiles.Narrowed (Count));

   function Midway (Item : Engine; Count : Natural) return Boolean
   is (Tiles.Midway (Item.Tile_Plan.Mid_Ready, Count));

   function Mid_Widely (Item : Engine; Count : Natural) return Boolean
   is (Tiles.Mid_Widely
         (Item.Tile_Plan.Mid_Ready, Item.Tile_Plan.Mid_Wide_Ready, Count));

   function Widened (Item : Engine; Count : Natural) return Boolean
   is (Tiles.Widened
         (Item.Tile_Plan.Wider_Ready, Item.Tile_Plan.Narrow_Run, Count));

   function Tile_Width (Item : Engine; Count : Natural) return Positive
   is (Tiles.Width
         (Item.Tile_Plan.Mid_Ready, Item.Tile_Plan.Mid_Wide_Ready,
          Item.Tile_Plan.Wider_Ready, Item.Tile_Plan.Narrow_Run, Count));

   procedure Keep_Route_Shares
     (Item : in out Engine;
      Keep : Boolean) is
   begin
      Item.Tile_Plan.Route_Keeps := Keep;
   end Keep_Route_Shares;

   function Keeps_Route_Shares (Item : Engine) return Boolean is
     (Item.Tile_Plan.Route_Keeps);

   --  The batch, rounded up to a whole tile. The shader has no test for a
   --  tile that is not full, on purpose and at a fifth of its speed if it
   --  had; what the rounding invents is zeroed by the copying kernel and
   --  written to room the result buffer is given for it.
   --  Columns a tile reads at a time: the narrow one a chunk, the wide one
   --  a chunk for each of its four lane groups.
   Wide_Step : constant := 128;

   function Whole_Tiles (Item : Engine; Count : Natural) return Natural
   is ((Count + Tile_Width (Item, Count) - 1) / Tile_Width (Item, Count)
       * Tile_Width (Item, Count));

   --  Below this the row product is the better shape and the matrix one is
   --  a tile mostly full of the zeros the rounding invented. A generated
   --  token is one vector and is the case this is really keeping out.
   --
   --  It was thirty-two, and above Wide_Group that was the wrong side of
   --  the trade. A tile is a hundred and twenty-eight vectors wide whether
   --  it is given seventeen or thirty-two, so the matrix product costs the
   --  same across that whole span -- while the row product above sixteen
   --  vectors is two dispatches and two passes over every weight. Measured
   --  on a round of thirty-one sequences: 5.95 s the row way and 4.53 the
   --  matrix way, and at seventeen 5.39 against 4.16. Sixteen is untouched,
   --  which is what the boundary being Wide_Group + 1 rather than a round
   --  number is for.
   Tile_Least : constant := Batch_Group + 1;

   ---------------------------------------------------------------------------
   --  Structures
   ---------------------------------------------------------------------------

   type Buffer_Create_Info is record
      Kind         : C.unsigned := Structure_Buffer_Create;
      Next         : Address := Null_Handle;
      Flags        : C.unsigned := 0;
      Size         : Interfaces.Unsigned_64 := 0;
      Usage        : C.unsigned := Usage_Buffer;
      Sharing      : C.unsigned := Sharing_Exclusive;
      Family_Count : C.unsigned := 0;
      Families     : Address := Null_Handle;
   end record
     with Convention => C;

   type Memory_Requirements is record
      Size      : Interfaces.Unsigned_64 := 0;
      Alignment : Interfaces.Unsigned_64 := 0;
      Kinds     : C.unsigned := 0;
   end record
     with Convention => C;

   type Memory_Allocate_Info is record
      Kind  : C.unsigned := Structure_Memory_Allocate;
      Next  : Address := Null_Handle;
      Size  : Interfaces.Unsigned_64 := 0;
      Which : C.unsigned := 0;
   end record
     with Convention => C;

   --  Handing the device the host's own memory rather than a copy of what
   --  is in it. Three structures and one entry point:
   --
   --  the buffer is told its memory will come from outside the interface,
   --  the allocation is told which host pointer it is, and the interface is
   --  asked which memory kinds that pointer can be taken as -- because a
   --  pointer the device cannot address is a pointer it will not take, and
   --  the answer is a mask rather than a yes.
   Structure_External_Buffer : constant := 1_000_158_000 + 13;
   Structure_Import_Host     : constant := 1_000_178_000;
   Structure_Host_Properties : constant := 1_000_178_000 + 1;

   Handle_Host_Allocation : constant := 16#80#;

   type External_Buffer_Info is record
      Kind    : C.unsigned := Structure_External_Buffer;
      Next    : Address := Null_Handle;
      Handles : C.unsigned := Handle_Host_Allocation;
   end record
     with Convention => C;

   type Import_Host_Info is record
      Kind    : C.unsigned := Structure_Import_Host;
      Next    : Address := Null_Handle;
      Handle  : C.unsigned := Handle_Host_Allocation;
      Pointer : Address := Null_Handle;
   end record
     with Convention => C;

   type Host_Pointer_Properties is record
      Kind  : C.unsigned := Structure_Host_Properties;
      Next  : Address := Null_Handle;
      Kinds : C.unsigned := 0;
   end record
     with Convention => C;

   type Host_Properties_Call is access
     function (Device  : Address;
               Handle  : C.unsigned;
               Pointer : Address;
               Result  : Address) return C.int
     with Convention => C;

   type Set_Layout_Binding is record
      Binding  : C.unsigned := 0;
      Kind     : C.unsigned := Descriptor_Storage;
      Count    : C.unsigned := 1;
      Stages   : C.unsigned := Stage_Compute;
      Samplers : Address := Null_Handle;
   end record
     with Convention => C;

   --  Six storage buffers: the weights, the vectors, the results, the
   --  half-precision copy of the vectors the matrix product reads, a
   --  fifth a kernel may use for what it likes, and the cache's own
   --  half-precision copy, which has a buffer of its own so that neither
   --  it nor the cache proper is past what one storage buffer may hold.
   --  Most kernels name three of the six and never the rest; a descriptor
   --  that is written and not read costs nothing, and a second layout for
   --  the sake of one binding would cost a second pool, a second set of
   --  sets and a second of everything that names one.
   --  Seven now: the six a kernel names at most were six until a copy-only
   --  session's attention grew a seventh, the values' half of a cache split
   --  in two so that neither half is past what one storage buffer may hold.
   --  A kernel that names none of the seventh writes six and leaves it, as
   --  it always left the ones it did not name.
   type Binding_Array is array (1 .. 7) of Set_Layout_Binding;

   type Set_Layout_Create_Info is record
      Kind     : C.unsigned := Structure_Set_Layout;
      Next     : Address := Null_Handle;
      Flags    : C.unsigned := 0;
      Count    : C.unsigned := 7;
      Bindings : Address := Null_Handle;
   end record
     with Convention => C;

   type Pool_Size is record
      Kind  : C.unsigned := Descriptor_Storage;
      Count : C.unsigned := 3;
   end record
     with Convention => C;

   type Descriptor_Pool_Info is record
      Kind       : C.unsigned := Structure_Descriptor_Pool;
      Next       : Address := Null_Handle;
      Flags      : C.unsigned := 0;
      Max_Sets   : C.unsigned := 1;
      Size_Count : C.unsigned := 1;
      Sizes      : Address := Null_Handle;
   end record
     with Convention => C;

   type Descriptor_Set_Info is record
      Kind    : C.unsigned := Structure_Descriptor_Set;
      Next    : Address := Null_Handle;
      Pool    : Address := Null_Handle;
      Count   : C.unsigned := 1;
      Layouts : Address := Null_Handle;
   end record
     with Convention => C;

   type Buffer_Info is record
      Buffer : Address := Null_Handle;
      Offset : Interfaces.Unsigned_64 := 0;
      Extent : Interfaces.Unsigned_64 := 0;
   end record
     with Convention => C;

   type Buffer_Info_Array is array (1 .. 7) of aliased Buffer_Info;

   --  The fourth descriptor of every set: the half-precision copy of the
   --  batch where the engine has one, and the vectors again where it has
   --  not.
   --
   --  Written for every set whether or not the kernel about to run names
   --  it, because the layout declares it and the interface wants every
   --  declared binding pointed at something real. Three of the five kernels
   --  never read it.
   --  Whether a product goes to the matrix kernel rather than the row one.
   --
   --  Four questions, and each of them is a promise the shader relies on
   --  rather than a preference. The device has to have said it offers the
   --  instruction; the weights have to be in one of the fourteen formats
   --  matrix_product.comp decodes between its two compilations, at a width
   --  that is a whole number of their blocks -- and binary32 is
   --  deliberately not one of them, because the tile's operand is half
   --  precision and a caller who kept a model at binary32 asked for the
   --  mantissa that would be lost; the rows have to divide by the tile,
   --  because a workgroup writes a whole tile and a partial one would write
   --  into the next vector's answers; and the batch has to be long enough
   --  to be worth rounding up to a tile.
   --
   --  Everything else -- binary32, a generated token, a row count the tile
   --  does not divide, and every device that has not got the instruction --
   --  goes where it always went.

   --  Which of the two pipelines a format belongs to. The six the first
   --  decodes are the ones a published model is usually made of; the nine
   --  the second decodes are the rest. The split is the shader's, not a
   --  judgement about the formats: see the note on Extra.
   function On_Extra (Packing : Weight_Packing) return Boolean
   is (Packing in Packed_Q4_0 | Packed_Q4_1 | Packed_Q5_0 | Packed_Q5_1
                  | Packed_IQ4_NL | Packed_Q2_K | Packed_Q3_K
                  | Packed_IQ4_XS | Packed_MXFP4);

   --  Which of the two row kernels a batch of this length wants. The narrow
   --  one exists only for a batch of one -- a generated token -- and is null
   --  on a device that refused it, which is what makes this a choice rather
   --  than an assumption.
   --  Which of the two attention kernels this device got. The subgroup one
   --  where it offered the operations, the shared-memory one everywhere
   --  else.
   --  Which matrix kernel takes this shape, or none. It stages a head's
   --  queries into shared memory sized for Matrix_Head, or for
   --  Matrix_Wide_Head in its second compilation, and reads the cache
   --  sixteen components at a time, so a head wider than both or not a
   --  multiple of sixteen is not one it can answer.
   --  Cached positions a batch must attend across for the few-position
   --  pipeline: it is two workgroups a slice where a model has two groups
   --  of keys, and shallower than this the scalar kernel's one a head of a
   --  position was the faster -- Qwen3.6 at 4,000 positions drafted 16.9
   --  tokens a second with it and 19.9 without.
   Few_Span : constant := 8_192;

   --  The least group a generated token alone takes the few-position
   --  pipeline for, its heads the rows of a tile of sixteen; a smaller
   --  group stays on attention_token.comp. At 16,000 positions, one
   --  token a time: Mellum's groups of eight 30.8 -> 32.5 tokens a
   --  second, Qwen3.6's 20.0 -> 20.3; qwen3-8b's of four 9.58 -> 8.92,
   --  Gemma 3's of two 21.7 -> 19.9. Mellum 32,000 deep attended a layer
   --  in 323-401 us where the token kernel took 410-518.
   Few_Token_Group : constant := 8;

   --  And the cached positions it takes it from, shallower than a round's
   --  Few_Span: at 4,000 positions gpt-oss generated 22.2 -> 23.0 tokens
   --  a second (llama.cpp 22.9), Mellum 35.3 -> 36.2.
   Few_Token_Span : constant := 2_048;

   --  How many slices a few positions at once cut the cache into: enough
   --  that the groups times the slices keep the part busy -- Few_Busy
   --  workgroups -- but none shorter than Slice_Least positions and no more
   --  than Few_Most_Slices. The scalar kernel's slices are held to
   --  Merged_Rows records between the heads, which left a model with two
   --  groups of keys sixteen workgroups.
   Few_Busy        : constant := 48;
   Few_Most_Slices : constant := 32;

   --  And for a head wider than Matrix_Wide_Head, whose workgroup stages
   --  its queries in 30 KB of shared memory: two of them to a compute
   --  unit, twenty-four on this part at once, so forty-eight ran as two
   --  rounds and every workgroup's start and end were paid twice.
   --  Swift-1.5-Qwen3.8-27B's check of four positions 8,188 deep attended
   --  a layer in 945-960 us at 48, 851 at 24, 1,136 at 32. A token's one
   --  subgroup a workgroup too: Qwen3.6-35B-A3B's two groups 30,549 deep
   --  attended a layer in 1,630-1,680 us at 24, 2,640 at 12 and at 48.
   --  With the scores' room a matrix a subgroup (22 KB a workgroup of two
   --  where it was 28), 36 generated 16,377 deep at 20.2 tokens a second
   --  against 21.0-21.8 at 24.
   Few_Wide_Busy : constant := 24;

   function Few_Slices
     (Groups : Natural;
      Span   : Natural;
      Wide   : Boolean := False) return Natural
   is (Natural'Max
         (1,
          Natural'Min
            (Few_Most_Slices,
             Natural'Min
               (Span / Slice_Least,
                ((if Wide then Few_Wide_Busy else Few_Busy)
                 + Natural'Max (1, Groups) - 1)
                / Natural'Max (1, Groups)))));

   --  Whether attention_latent.comp takes a head of this shape: an absorbed
   --  latent's one key-value head, wider than the matrix kernels stage --
   --  576 for DeepSeek-V2, its rotated slice and its rank -- its values up
   --  to 512, and at most the sixteen query heads one tile of the
   --  instruction holds reading it.
   Latent_Head  : constant := 576;
   Latent_Value : constant := 512;
   Latent_Rows  : constant := 16;

   function Latent_Fits
     (Item       : Engine;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural) return Boolean
   is (Item.Latent_Attend /= Null_Handle
       and then Head_Size > Matrix_Wider_Head
       and then Head_Size <= Latent_Head
       and then Head_Size mod 16 = 0
       and then Value_Size in 16 .. Latent_Value
       and then Value_Size mod 16 = 0
       and then Group_Size in 1 .. Latent_Rows);

   --  How many slices it cuts a cache of Span positions into: a tile of it
   --  at least, and no more than its workgroups of 25 KB of shared memory
   --  that the part holds at once.
   --  Positions a tile of attention_latent.comp's plain compilation holds:
   --  as many as fill its rows with a group's heads, where the group is
   --  fewer than the rows and divides them, and one otherwise. Its
   --  workgroups go a run of that many positions each.
   function Latent_Packed (Group_Size : Natural) return Positive
   is (if Group_Size in 1 .. Latent_Rows - 1
          and then Latent_Rows mod Group_Size = 0
       then Latent_Rows / Group_Size else 1);

   function Takes_Latent
     (Item       : Engine;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural) return Boolean
   is (Latent_Fits (Item, Head_Size, Value_Size, Group_Size));

   --  A batch of positions is busy enough a slice each: sliced, every
   --  slice staged its position's queries and left a record to merge.
   --  Positions a workgroup of a latent's batch compilation answers; see
   --  attention_latent.comp's POS.
   Latent_Pair : constant := 3;

   --  Tiles of packed positions a workgroup of the PACK_PAIR compilation
   --  holds: a group of fewer heads than the tile's rows, Gemma4's four,
   --  reads each key and value for twice as many positions.
   Latent_Pack_Pair : constant := 2;

   --  And the widest head it takes: it stages a key of this width.
   Latent_Pack_Head : constant := 512;

   --  At most Few_Wide_Busy a position: DeepSeek-Coder-V2-Lite's token
   --  31,161 deep attended a layer in 731 us at twenty-four, 842 at
   --  thirty-two.
   function Latent_Slices
     (Span : Natural; Positions : Natural := 1; Groups : Natural := 1) return Natural
   is (if Positions >= Latent_Rows then 1
       else Natural'Max
              (1, Natural'Min (Few_Wide_Busy
                               / (Natural'Max (1, Positions) * Natural'Max (1, Groups)),
                               (Span + 63) / 64)));

   --  The few-position pipeline for a step of Positions, or none: one to
   --  eight positions whose heads in a group, times the positions, fill at
   --  most four subgroups of sixteen rows, out of the half-precision copy,
   --  causal, and with nothing the few-position mode leaves out -- a
   --  sliding window, a slope. See FEW in attention_matrix.comp.
   function Few_Kernel
     (Item       : Engine;
      Positions  : Natural;
      Heads      : Natural;
      Group_Size : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Address
   is
      Rows : constant Natural := Positions * Natural'Max (1, Group_Size);
      --  A head wider than Matrix_Wide_Head on two subgroups even where its
      --  rows fit one: the pair split the values' tiles between them, and
      --  a lone subgroup waited on every read of a tile one after another
      --  with nothing beside it -- Qwen3.6-35B-A3B's token 30,549 deep
      --  attended a layer in 1,630 us on one, 1,196 on two, 1,830 on four.
      Wider : constant Boolean :=
        Head_Size > Matrix_Wide_Head or else Value_Size > Matrix_Wide_Head;
      Many : constant Natural :=
        (if Rows <= 16 and then not Wider then 1
         elsif Rows <= 32 then 2 else 3);
      Width : constant Natural :=
        (if Head_Size <= Matrix_Head and then Value_Size <= Matrix_Head
         then 1
         elsif Head_Size <= Matrix_Mid_Head
           and then Value_Size <= Matrix_Mid_Head
         then 2
         elsif Head_Size <= Matrix_Wide_Head
           and then Value_Size <= Matrix_Wide_Head
         then 3
         elsif Head_Size <= Matrix_Wider_Head
           and then Value_Size <= Matrix_Wider_Head
         then 4
         else 0);
   begin
      if Positions not in 1 .. Query_Block - 1
        or else (Positions = 1 and then Group_Size < Few_Token_Group)
        or else Group_Size = 0
        or else Rows > 64
        or else Heads mod Group_Size /= 0
        or else Head_Size mod 16 /= 0
        or else Value_Size mod 16 /= 0
        or else Width = 0
        or else Item.Exact_Attention
        or else Item.Merge_Line = Null_Handle
      then
         return Null_Handle;
      end if;
      return Item.Few_Attend (Width, Many);
   end Few_Kernel;

   --  The deep pipeline of the kernel Matrix_Kernel would bind for this
   --  shape, or none: the same choice, at Matrix_Deep_Queries a
   --  workgroup.
   function Deep_Kernel
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Causal     : Boolean := True) return Address
   is (if Item.Exact_Attention
         or else Positions
                 < (if Item.Copy_Only then Query_Block else Matrix_Queries)
         or else Head_Size mod 16 /= 0
         or else Value_Size mod 16 /= 0
       then Null_Handle
       elsif Head_Size <= Matrix_Head and then Value_Size <= Matrix_Head
       then Item.Matrix_Deep_Attend
       elsif Head_Size <= Matrix_Mid_Head
         and then Value_Size <= Matrix_Mid_Head
         and then Item.Matrix_Mid_Attend /= Null_Handle
       then Item.Matrix_Mid_Deep_Attend
       elsif Head_Size <= Matrix_Wide_Head
         and then Value_Size <= Matrix_Wide_Head
         and then not Causal
         and then Item.Matrix_Wide_Deep8_Attend /= Null_Handle
       then Item.Matrix_Wide_Deep8_Attend
       elsif Head_Size <= Matrix_Wide_Head
         and then Value_Size <= Matrix_Wide_Head
       then Item.Matrix_Wide_Deep_Attend
       elsif Head_Size <= Matrix_Wider_Head
         and then Value_Size <= Matrix_Wider_Head
       then Item.Matrix_Wider_Deep_Attend
       else Null_Handle);

   function Matrix_Kernel
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Span       : Natural := 0;
      Causal     : Boolean := True) return Address
   is (if Span >= Deep_Span
         and then Deep_Kernel (Item, Positions, Head_Size, Value_Size, Causal)
                  /= Null_Handle
       then Deep_Kernel (Item, Positions, Head_Size, Value_Size, Causal)
       elsif Item.Exact_Attention
         --  A cache kept as its copy has no binary32 rows for the tiled
         --  kernel that takes eight to fifteen queries otherwise, so the
         --  matrix kernel takes them, a block part empty -- as it takes the
         --  last block of any prompt.
         or else Positions
                 < (if Item.Copy_Only then Query_Block else Matrix_Queries)
         or else Head_Size mod 16 /= 0
         or else Value_Size mod 16 /= 0
       then Null_Handle
       --  Sinks too: gpt-oss-20b's attention moves its perplexity by up
       --  to half a per cent on whichever kernel reads it -- over chunks
       --  of 120 of one text 4.1096 here, 4.1289 on the other
       --  compilation, 4.1354 on the 128-wide one and 4.1280 on the
       --  processor; over README chunks of 256, 25.4737 here, 25.4616 there
       --  and 25.5580 on the processor -- neither kernel the nearer on
       --  both, and its prompt of 1,257 reads 621 -> 635 tokens a second
       --  this way.
       elsif Head_Size <= Matrix_Head
         and then Value_Size <= Matrix_Head
         and then Item.Matrix_Split_Narrow_Attend /= Null_Handle
       then Item.Matrix_Split_Narrow_Attend
       elsif Head_Size <= Matrix_Head and then Value_Size <= Matrix_Head
       then Item.Matrix_Attend
       elsif Head_Size <= Matrix_Mid_Head
         and then Value_Size <= Matrix_Mid_Head
         and then Item.Matrix_Mid_Attend /= Null_Handle
       then (if Item.Matrix_Split_Mid_Attend /= Null_Handle
             then Item.Matrix_Split_Mid_Attend
             else Item.Matrix_Mid_Attend)
       --  A short span's heads of 128 on the kernel that splits each tile
       --  between the four subgroups of a block: see attention_split.comp.
       elsif Head_Size <= Matrix_Wide_Head
         and then Value_Size <= Matrix_Wide_Head
         and then Item.Matrix_Split_Attend /= Null_Handle
       then Item.Matrix_Split_Attend
       elsif Head_Size <= Matrix_Wide_Head
         and then Value_Size <= Matrix_Wide_Head
       then Item.Matrix_Wide_Attend
       elsif Head_Size <= Matrix_Wider_Head
         and then Value_Size <= Matrix_Wider_Head
       then (if Item.Matrix_Split_Wider_Attend /= Null_Handle
             then Item.Matrix_Split_Wider_Attend
             else Item.Matrix_Wider_Attend)
       else Null_Handle);

   function Attends_By_Matrix
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Matrix_Kernel (Item, Positions, Head_Size, Value_Size)
       /= Null_Handle);

   function Attends_In_Segments
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Matrix_Kernel (Item, Positions, Head_Size, Value_Size,
                      Span => 0, Causal => False)
       in Item.Matrix_Split_Attend | Item.Matrix_Split_Narrow_Attend
        | Item.Matrix_Split_Mid_Attend | Item.Matrix_Split_Wider_Attend
       and then Matrix_Kernel (Item, Positions, Head_Size, Value_Size,
                               Span => 0, Causal => False) /= Null_Handle);

   --  The span a step's kernel is chosen by: its own, or none where it
   --  attends in segments, which only a short span's kernel reads.
   function Chosen_Span (First, Last, Window : Natural) return Natural
   is (if Window >= Segmented_Window then 0
       elsif Last >= First then Last - First + 1
       else 0);

   --  Whether attention reads the half-precision copy rather than the
   --  cache proper: a round always, where the kernel exists, and a token
   --  where the copy is preferred. A token read the cache proper alone
   --  for a long time, on a measurement that said half precision gained
   --  nothing -- 1.362 and 1.375 s against 1.374 and 1.415 -- which was
   --  true of a head a workgroup reading its group's cache eight times:
   --  that token was short of work, not of bytes. Bundled and sliced, a
   --  token at thirteen hundred positions is the bytes, and the copy is
   --  half of them.
   --  Whether anything on this device would ever read the cache's
   --  half-precision copy: the matrix attention reads it, a round's
   --  attention reads it, and a token reads it where the copy is
   --  preferred -- and a device with none of those kernels has nothing
   --  that would. Two bytes an element of the cache, which is a third of
   --  what a context takes there, kept for nobody.
   function Wants_Copy (Item : Engine) return Boolean
   is (Item.Attend_Matrix /= Null_Handle
       or else Item.Attend_Matrix_Wide /= Null_Handle
       or else Item.Attend_Matrix_Wider /= Null_Handle
       or else Item.Attend_Matrix_Mid /= Null_Handle
       or else Item.Halved_Line /= Null_Handle);

   function Keeps_Copy (Item : Engine) return Boolean
   is (Wants_Copy (Item));

   --  A copy-only session forces this too: it has no binary32 cache for a
   --  token's kernel to read, so the token reads the half-precision copy
   --  where the device offers the kernel that does -- the same one a
   --  half-precision cache uses. Where it does not, the token falls to the
   --  host, as it did before.
   function Attends_By_Halves
     (Item : Engine; Rounding : Boolean) return Boolean
   is ((Rounding or else Item.Halves or else Item.Copy_Only)
       and then Item.Halved_Line /= Null_Handle);

   --  Whether the kernel Attend_Kernel binds for these positions reads
   --  the half-precision copy of the cache rather than the cache proper:
   --  the matrix kernel and a round's do, the tiled one does not, and a
   --  token's does where the copy is preferred. What the bases in the
   --  push block are moved by.
   function Reads_Copy
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Rounding   : Boolean) return Boolean
   is (if Rounding then Attends_By_Halves (Item, True)
       elsif Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
       then True
       --  An absorbed latent's head, past every other kernel's width, is
       --  attention_latent.comp's at any batch, and it reads the copy --
       --  whether or not the session prefers it: the copy is kept beside an
       --  exact cache too, and no other kernel attends such a head. Asked
       --  to prefer it, a session holding its cache exact -- the perplexity
       --  tool's -- had Gemma 4's 512-wide global heads refused, and the host
       --  attends no head that wide: every chunk of the 12B and the 26B
       --  ended non-finite at their last layer.
       elsif Head_Size > Matrix_Wider_Head and then Item.Latent_Attend /= Null_Handle
       then Attends_By_Halves (Item, True)
       elsif Item.Tile_Line /= Null_Handle and then Positions >= Query_Block
       then False
       else Attends_By_Halves (Item, False));

   --  Whether a batch of this many positions is a token attending out of
   --  the copy: too short for the matrix and the tiled kernels, which
   --  read what they read whatever a token prefers, and the copy
   --  preferred. The kernel and the workgroups it wants are decided on
   --  this together, as the other kernels' are: a token's workgroups
   --  bound to the tiled kernel would answer a bundle's worth of heads
   --  and leave the rest as they were.
   function Token_By_Halves
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Attends_By_Halves (Item, False)
       and then not Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
       and then not (Item.Tile_Line /= Null_Handle
                     and then Positions >= Query_Block));

   --  How many of a group's heads attention_token.comp's workgroup takes:
   --  the whole group for heads up to 128 wide, and for wider ones the
   --  largest part of it that divides it and keeps the rows times the
   --  sixty-fours within eight, which is what a lane's registers hold --
   --  Qwen3.6's groups of eight 256-wide heads as four workgroups of two,
   --  each reading the group's keys and values. The whole group on one,
   --  its heads split over sixteen lanes a position, generated Qwen3.6
   --  16,377 deep at 19.9 tokens a second where the few-position kernel's
   --  pair generates 20.9-21.4.
   function Token_Rows (Group_Size, Head_Size : Natural) return Natural is
      Width : constant Natural := Head_Size / 64;
   begin
      if Width <= 2 then
         return Group_Size;
      end if;
      for Rows in reverse 1 .. Natural'Min (Group_Size, (if Width = 8 then 4 else 8 / Width)) loop
         if Group_Size mod Rows = 0 then
            return Rows;
         end if;
      end loop;
      return 0;
   end Token_Rows;

   --  How wide a bundle a token attending out of the copy takes: four,
   --  a whole group of five to seven, or nought for the plain
   --  half-precision kernel, a head a workgroup. Nought too over a short cache, as the exact bundle
   --  decides it: a bundle pays where there is enough cache to read,
   --  and at seventy positions a head a workgroup reads 13 us where the
   --  bundle of eight reads 25.
   --
   --  Four, and no longer eight where the group divides by eight: a group
   --  of eight read as two bundles crosses its keys and values twice, but
   --  the second crossing comes out of the cache and twice the workgroups
   --  keep the part busier. A token's attention a layer, four against
   --  eight: gpt-oss-20b 39.9 against 43.0 us at 481 positions and 94.3
   --  against 105.2 at 2,071; Qwen3.6-35B-A3B 79 against 105 at 513 and
   --  197 against 227 at 2,163. A head a workgroup was slower again at
   --  depth, 139.5 and 257.
   function Halved_Bundle
     (Item : Engine; Group_Size : Natural; Span : Natural;
      Head_Size : Natural) return Natural
   is (if Span < Bundle_Least
       then 0
       elsif Span >= Whole_Span
         and then Head_Size <= Whole_Head_Most
         and then Group_Size in Whole_Lines'Range
         and then Item.Whole_Halved_Line (Group_Size) /= Null_Handle
       then Group_Size
       elsif Item.Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then Head_Bundle
       elsif Group_Size in Whole_Lines'Range
         and then Item.Whole_Halved_Line (Group_Size) /= Null_Handle
       then Group_Size
       else 0);

   --  Whether a batch too short for the tiled kernels takes the bundled
   --  one over the cache proper: a generated token, whose workgroups are
   --  a head each and whose heads share a group's keys and values. The
   --  kernel and the first axis of the dispatch decide this together.
   --  How wide that bundle is: eight where the group divides by eight and
   --  the eight-wide pipeline was made, four where it divides by four,
   --  and nought for no bundle at all.
   function Fours_Fit
     (Head_Size  : Natural;
      Value_Size : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count;
      V_Base     : Model_Runner.Numerics.Element_Count;
      KV_Width   : Natural;
      V_Width    : Natural) return Boolean
   is (Head_Size mod 4 = 0
       and then Value_Size mod 4 = 0
       and then Value_Size <= 128
       and then K_Base mod 4 = 0
       and then V_Base mod 4 = 0
       and then KV_Width mod 4 = 0
       and then V_Width mod 4 = 0);

   function Exact_Bundle
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count := 0;
      V_Base     : Model_Runner.Numerics.Element_Count := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Span       : Natural := Bundle_Least) return Natural
   is (if Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
         or else (Item.Tile_Line /= Null_Handle
                  and then Positions >= Query_Block)
         --  A short cache is a few workgroups doing little each, and a
         --  head a workgroup is more of them: the bundle pays where
         --  there is enough cache to read.
         or else Span < Bundle_Least
       then 0
       --  The bundles of four and eight read four at a time and nothing
       --  else, on the engine's word that every base and width allows
       --  it; a cache that does not goes to the pair, a word at a time.
       --  Four where it divides the group, eight's too, as a token out of
       --  the copy takes them (Halved_Bundle): gpt-oss-20b's attention a
       --  layer over the cache proper 150.9 -> 140.2 us at 2,071
       --  positions and 58.8 -> 54.2 at 481; Qwen3.6-35B-A3B level at
       --  2,163 and 74 -> 72 at 513.
       elsif Fours_Fit (Head_Size, Value_Size, K_Base, V_Base,
                        KV_Width, V_Width)
         and then Item.Exact_Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then Head_Bundle
       --  A group of five, six or seven, bundled whole.
       elsif Fours_Fit (Head_Size, Value_Size, K_Base, V_Base,
                        KV_Width, V_Width)
         and then Group_Size in Whole_Lines'Range
         and then Item.Whole_Bundle_Line (Group_Size) /= Null_Handle
       then Group_Size
       elsif Item.Pair_Bundle_Line /= Null_Handle
         and then Group_Size mod Pair_Bundle = 0
       then Pair_Bundle
       else 0);

   function Bundles_Exact
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count := 0;
      V_Base     : Model_Runner.Numerics.Element_Count := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Span       : Natural := Bundle_Least) return Boolean
   is (Exact_Bundle (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
       > 0);

   function Attend_Kernel
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural := 1;
      Rounding   : Boolean := False;
      K_Base     : Model_Runner.Numerics.Element_Count := 0;
      V_Base     : Model_Runner.Numerics.Element_Count := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Span       : Natural := Bundle_Least;
      Causal     : Boolean := True) return Address
   is (if not Rounding
         and then Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
       then Matrix_Kernel (Item, Positions, Head_Size, Value_Size, Span,
                           Causal)
       elsif not Rounding
         and then Item.Tile_Line /= Null_Handle
         and then Positions >= Query_Block
       then Item.Tile_Line
       --  A token out of the copy, in the widest bundle its group takes.
       elsif not Rounding
         and then Token_By_Halves (Item, Positions, Head_Size, Value_Size)
       then (case Halved_Bundle (Item, Group_Size, Span, Head_Size) is
               when Head_Bundle => Item.Bundle_Line,
               when Whole_Lines'Range =>
                 Item.Whole_Halved_Line (Group_Size),
               when others      => Item.Halved_Line)
       elsif not Rounding
         and then Exact_Bundle
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
                  in Whole_Lines'Range
       then Item.Whole_Bundle_Line (Group_Size)
       elsif not Rounding
         and then Exact_Bundle
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
                  = Pair_Bundle
       then Item.Pair_Bundle_Line
       elsif not Rounding
         and then Bundles_Exact
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
       then Item.Exact_Bundle_Line
       elsif Rounding
         and then Item.Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then Item.Bundle_Line
       elsif Rounding and then Item.Halved_Line /= Null_Handle
       then Item.Halved_Line
       elsif Item.Group_Line /= Null_Handle
       then Item.Group_Line
       else Item.Attend_Line);

   --  And how many workgroups that kernel wants down the second axis: one
   --  per query position, or one per block of them where the tiled kernel
   --  answers a block at a time. The two have to be decided together, which
   --  is why neither is written out at a call site.
   --  And how many workgroups the first axis wants, which is one a head
   --  except where the bundled kernel is bound and it is one a bundle. The
   --  two are one decision with the kernel above, as the second axis is.
   function Attend_Heads
     (Item       : Engine;
      Heads      : Natural;
      Group_Size : Natural;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Rounding   : Boolean := False;
      K_Base     : Model_Runner.Numerics.Element_Count := 0;
      V_Base     : Model_Runner.Numerics.Element_Count := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Span       : Natural := Bundle_Least) return C.unsigned
   is (if Rounding
         and then Item.Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then C.unsigned ((Heads + Head_Bundle - 1) / Head_Bundle)
       elsif not Rounding
         and then Token_By_Halves (Item, Positions, Head_Size, Value_Size)
       then (if Halved_Bundle (Item, Group_Size, Span, Head_Size) > 0
             then C.unsigned
                    ((Heads + Halved_Bundle (Item, Group_Size, Span, Head_Size) - 1)
                     / Halved_Bundle (Item, Group_Size, Span, Head_Size))
             else C.unsigned (Heads))
       elsif not Rounding
         and then Bundles_Exact
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
       then C.unsigned
              ((Heads
                + Exact_Bundle
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
                - 1)
               / Exact_Bundle
                   (Item, Positions, Head_Size, Value_Size, Group_Size,
                    K_Base, V_Base, KV_Width, V_Width, Span))
       else C.unsigned (Heads));

   --  How many slices the cached positions are cut into down the third
   --  axis: one, except for a batch too short for the tiled kernels over
   --  a cache long enough to be worth cutting, where merge.comp is there
   --  to put the slices together.
   --  Workgroups worth having in flight at once on this part: a dozen
   --  compute units, each wanting several to hide what a read costs.
   --
   --  A number and not a question asked of the device, because Vulkan has
   --  no portable answer -- the compute-unit count is a vendor extension
   --  where it exists at all -- and because the answer here is flat over
   --  a wide range. Sixteen rounds of a 1,419-token prompt with packed
   --  caches, the same binary built five ways:
   --
   --     want      64    128    256    512   1024
   --     2 members 0.444 0.442 0.438 0.439 0.445 s
   --     8 members 0.938 0.869 0.840 0.838 0.856 s
   --
   --  Two hundred and fifty-six and five hundred and twelve are the same
   --  answer; being wrong by a factor of four either way costs two to
   --  twelve per cent. A part of another shape would want its own number
   --  and would not suffer much for this one.
   Want_Workgroups : constant := 256;

   --  Most partial answers a generated token's attention leaves for
   --  merge.comp, the heads times the cache's slices. A slice is a whole
   --  tile of 256 positions at least, each carries an unnormalized blend a
   --  head, and the merge reads them all back: many heads cut fine spend
   --  more there than the extra workgroups bring. Tokens a second, the
   --  half-precision cache, alternated:
   --
   --                        heads  positions  slices   before -> after
   --    Steelman-14B (qwen2)  40     1,318    6 -> 3   7.82 -> 7.85 (llama 7.84)
   --    Steelman-14B          40     3,892   16 -> 3   7.25 -> 7.36 (llama 7.37)
   --    qwen3-8b              32     1,297    6 -> 4   14.09 -> 14.23
   --    gemma-3-4b             8     1,335    6, kept  24.4 (3 slices: 23.8)
   --    gemma-3-270m           4     1,335    6, kept  156 (3 slices: 134)
   Merged_Rows : constant := 128;

   --  And that many again for every further stretch of this many cached
   --  positions: deep in the cache a slice is long, and four slices of
   --  4,096 positions were thirty-two workgroups for the whole part to
   --  read the keys with. Mellum at 16,381 positions, four slices against
   --  twelve, tokens a second: 31.17 -> 31.60; at 4,096 kept at four.
   Merged_Stretch : constant := 4_096;

   --  The most slices the heads may cut a cache of Span positions into
   --  between them.
   --  Twice that from a stretch on: gpt-oss-20b's sixty-four heads cut a
   --  cache 16,213 deep into eight slices, 128 workgroups of four heads
   --  reading 512 KB each, and its attention a layer read 798 us; sixteen
   --  read 673, thirty-two 683.
   function Merged_Slices (Heads, Span : Natural) return Natural
   is (Natural'Max
         (1,
          Merged_Rows
          * (if Span >= Merged_Stretch then 2 * (Span / Merged_Stretch) else 1)
          / Natural'Max (1, Heads)));

   --  Whether a round's cache is cut into slices, which the two kernels
   --  answer differently because their workgroups cost differently.
   --
   --  Either kernel would take the cut: each reads a round's span from
   --  the per-row table and marks an empty slice as empty. What differs
   --  is whether the merge pass a cut adds is worth the workgroups it
   --  wins. Sixteen rounds of a 1,419-token prompt on this part, cut
   --  against whole:
   --
   --    exact    2 members  0.359 / 0.364 s    packed  0.431 / 0.784 s
   --             4          0.397 / 0.401              0.525 / 0.794
   --             8          0.588 / 0.605              0.834 / 0.953
   --             16         0.750 / 0.717              1.293 / 1.473
   --
   --  A packed workgroup unpacks every element it reads and is slow
   --  enough that more of them wins by a third; an exact one bundles
   --  eight heads and is quick, so the merge costs more than it saves
   --  and the wrong way at sixteen members. Named here rather than
   --  written as a bare condition in each rule, so that the difference
   --  is one thing a reader finds rather than two they must notice.
   Exact_Cuts_A_Round : constant Boolean := False;

   --  How many slices the exact kernels cut the cache into.
   function Attend_Slices
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      First      : Natural;
      Last       : Natural;
      Rounding   : Boolean) return Natural
   is (if (Rounding and then not Exact_Cuts_A_Round)
         or else Item.Merge_Line = Null_Handle
         or else Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
         or else (Item.Tile_Line /= Null_Handle
                  and then Positions >= Query_Block)
         or else Last < First
       then 1
       else Natural'Min
              (Item.Launch.Attention_Slice_Limit,
               (Last - First + Item.Launch.Attention_Slice_Least)
                 / Item.Launch.Attention_Slice_Least));

   --  Queries a deep workgroup answers for a head of this shape: the
   --  eight-subgroup pipeline's where it is the one bound.
   function Deep_Queries
     (Item       : Engine;
      Head_Size  : Natural;
      Value_Size : Natural;
      Causal     : Boolean := True) return Natural
   is (if (Head_Size <= Matrix_Mid_Head and then Value_Size <= Matrix_Mid_Head)
         or else (not Causal
                  and then Head_Size <= Matrix_Wide_Head
                  and then Value_Size <= Matrix_Wide_Head
                  and then Item.Matrix_Wide_Deep8_Attend /= Null_Handle)
       then Matrix_Deep_Queries_Held else Matrix_Deep_Queries);

   function Attend_Groups
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Rounding   : Boolean := False;
      Span       : Natural := 0;
      Causal     : Boolean := True) return C.unsigned
   is (if not Rounding
         and then Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
         and then Span >= Deep_Span
         and then Deep_Kernel (Item, Positions, Head_Size, Value_Size, Causal)
                  /= Null_Handle
       then C.unsigned
              ((Positions
                + Deep_Queries (Item, Head_Size, Value_Size, Causal) - 1)
               / Deep_Queries (Item, Head_Size, Value_Size, Causal))
       elsif not Rounding
         and then Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
       then C.unsigned ((Positions + Matrix_Queries - 1) / Matrix_Queries)
       elsif not Rounding
         and then Item.Tile_Line /= Null_Handle
         and then Positions >= Query_Block
       then C.unsigned ((Positions + Query_Block - 1) / Query_Block)
       else C.unsigned (Positions));

   --  Whether this format generates better on the narrower workgroup. Two
   --  of them do and the rest do not, which is why this is a list and not a
   --  rule: Q8_0 is four per cent worse on it and Q2_K sixteen.
   --  Whether a product goes to thin.comp: binary32, a few rows, a few
   --  vectors, and a matrix that begins on a word of four so the kernel
   --  may read four at a time.
   function Thin
     (Item    : Engine;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural;
      Base    : Interfaces.Unsigned_64) return Boolean
   is (Item.Thin_Line /= Null_Handle
       and then Packing = Values_F32
       and then Rows <= Thin_Rows
       and then (Count <= Thin_Vectors or else Rows <= Thin_Matrix_Rows)
       and then Columns mod 4 = 0
       and then Base mod 16 = 0);

   --  Whether a binary32 product over a batch goes to f32_tile.comp: more
   --  vectors than the thin kernel takes, where the row kernel would read
   --  the matrix again for every eight of them.
   function F32_Tiled
     (Item    : Engine;
      Packing : Weight_Packing;
      Rows    : Natural;
      Count   : Natural;
      Base    : Interfaces.Unsigned_64) return Boolean
   is (Item.F32_Tile_Line /= Null_Handle
       and then Packing = Values_F32
       and then Rows >= 64
       and then Count > Thin_Vectors
       and then Base mod 4 = 0);

   function Half_Grouped
     (Item : Engine; Packing : Weight_Packing; Count : Natural) return Boolean
   is (Count = 1
       and then Item.Half_Group_Line /= Null_Handle
       and then (Item.Launch.Row_Product_Workgroup = Half_Group
                 or else Packing in Packed_Q4_K | Packed_Q5_K));

   --  Whether the super-block row product answers this: a Q4_K or Q5_K
   --  generating a token, on a device that gave the engine the kernel. Each
   --  format has its own decode and its own pipeline.
   function Waved
     (Item : Engine; Packing : Weight_Packing; Count : Natural) return Boolean
   is ((Packing = Packed_Q8_0
        and then Count in Q8_Count
        and then Item.Q8_Multi_Lines (Count) /= Null_Handle)
       or else
       (Count in Many_Count
        and then Item.Wave_Multi_Lines (Packing) (Count) /= Null_Handle)
       or else
       (Count in Many_Count
        and then ((Packing = Packed_Q4_K
                   and then Item.Many_Lines4 (Count) /= Null_Handle)
                  or else
                  (Packing = Packed_Q5_K
                   and then Item.Many_Lines5 (Count) /= Null_Handle)
                  or else
                  (Packing = Packed_Q6_K
                   and then Item.Many_Lines6 (Count) /= Null_Handle)))
       or else
       (Count = 1
       and then ((Packing = Packed_Q4_K and then Item.Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_Q5_K
                  and then Item.Wave_Line5 /= Null_Handle)
                 or else
                 (Packing = Packed_Q6_K
                  and then Item.Wave_Line6 /= Null_Handle)
                 or else
                 (Packing in Low_Packing
                  and then Item.Low_Wave_Lines (Packing) /= Null_Handle)
                 or else
                 (Packing = Packed_Q8_0
                  and then Item.Q8_Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_IQ4_NL
                  and then Item.NL_Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_MXFP4
                  and then Item.MX_Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_IQ4_XS
                  and then Item.XS_Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_Q2_K
                  and then Item.Q2K_Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_Q3_K
                  and then Item.Q3K_Wave_Line /= Null_Handle)
                 or else
                 (Packing in Legacy_Packing
                  and then Item.Legacy_Wave_Lines (Packing) /= Null_Handle)
                 or else
                 (Packing in Half_Packing
                  and then Item.Half_Wave_Lines (Packing) /= Null_Handle))));

   --  Invocations a workgroup of the bound row kernel has. The super-block
   --  kernel's workgroup is a single subgroup of thirty-two; the half-group
   --  kernel narrows; the rest are the group size.
   function Row_Width
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Positive
   is (if Waved (Item, Packing, Count)
       then (if Packing in Low_Packing | Packed_Q8_0 | Packed_IQ4_NL
                          | Packed_MXFP4
                          | Packed_IQ4_XS | Packed_Q2_K | Packed_Q3_K
                          | Legacy_Packing | Half_Packing
             then Low_Wave_Lanes
             else Wave_Lanes)
       elsif Half_Grouped (Item, Packing, Count) then Half_Group
       else Group_Size);

   --  Lanes a row is divided into, which the dispatch multiplies the rows by.
   --  The super-block kernel gives a band thirty-two; the rest give a row
   --  eight.
   function Row_Lane_Count
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Positive
   is (if Waved (Item, Packing, Count)
       then (if Packing in Low_Packing | Packed_Q8_0 | Packed_IQ4_NL
                          | Packed_MXFP4
                          | Packed_IQ4_XS | Packed_Q2_K | Packed_Q3_K
                          | Legacy_Packing | Half_Packing
             then Low_Wave_Lanes
             else Wave_Lanes)
       else Row_Lanes);

   --  Whether a token's Q8_0 product takes the four-row compilation: a
   --  short row, where the device made it.
   function Q8_Short
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural;
      Columns : Natural) return Boolean
   is (Packing = Packed_Q8_0
       and then Count = 1
       and then Columns in 1 .. Q8_Short_Columns - 1
       and then Item.Q8_Short_Line /= Null_Handle);

   --  Rows a subgroup kernel's workgroup lands: the k-quants' band, or the
   --  low-bit formats' own.
   function Wave_Band
     (Packing : Weight_Packing;
      Count   : Natural := 1;
      Short   : Boolean := False) return Positive
   is (if Packing in Half_Packing then Half_Wave_Rows
       elsif Packing = Packed_Q8_0 and then Count in Q8_Count
       then Q8_Multi_Rows
       --  And the few-vector walks compiled to land as many (MANY_ROWS in
       --  compile-shaders.sh): Q2_K's and Q3_K's check of four 18 per cent
       --  faster at eight rows than at four, the IQ4 formats' 4 to 7; the
       --  older formats slower at four vectors and faster at eight, so they
       --  take eight past four (MANY_ROWS_FEW). Sixteen for Q2_K's check of
       --  four measured the same as eight, alternated; four for it, 3 per
       --  cent faster than eight at four vectors and 6 slower at eight, so
       --  it too takes eight only past four.
       elsif Packing = Packed_Q2_K and then Count in Multi_Count
       then Q2K_Wave_Rows
       elsif Packing in Packed_Q4_K | Packed_Q5_K | Packed_Q6_K
                        | Packed_Q2_K | Packed_Q3_K
                        | Packed_IQ4_NL | Packed_IQ4_XS | Packed_MXFP4
         and then Count in Many_Count
       then Many_Rows
       elsif Packing in Legacy_Packing and then Count in Many_Count
         and then Count not in Multi_Count
       then Many_Rows
       elsif Short then Q8_Short_Rows
       elsif Packing in Four_Row_Codebooks and then Count not in Many_Count then Codebook_Wave_Rows
       elsif Packing in Low_Packing then Low_Wave_Rows
       elsif Packing in Packed_IQ4_NL | Packed_IQ4_XS | Packed_MXFP4
                        | Legacy_Packing
       then IQ4_Wave_Rows
       elsif Packing in Packed_Q2_K | Packed_Q3_K then Q2K_Wave_Rows
       elsif Packing = Packed_Q8_0 then Q8_Wave_Rows
       elsif Packing = Packed_Q6_K then Q6_Wave_Rows
       else Wave_Rows);

   --  Rows the dispatch reckons in: the super-block kernel's workgroup lands
   --  a band of Wave_Band rows, so it asks for a band's worth fewer.
   function Row_Reach
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural;
      Rows    : Natural;
      Columns : Natural := 0) return Natural
   is (if Waved (Item, Packing, Count)
       then (Rows
             + Wave_Band (Packing, Count,
                          Q8_Short (Item, Packing, Count, Columns)) - 1)
            / Wave_Band (Packing, Count,
                         Q8_Short (Item, Packing, Count, Columns))
       else Rows);

   function Row_Line
     (Item    : Engine;
      Count   : Natural;
      Packing : Weight_Packing := Values_F32;
      Columns : Natural := 0) return Address
   is (if Count in Many_Count
         and then Item.Wave_Multi_Lines (Packing) (Count) /= Null_Handle
       then Item.Wave_Multi_Lines (Packing) (Count)
       elsif Packing in Low_Packing and then Waved (Item, Packing, Count)
       then Item.Low_Wave_Lines (Packing)
       elsif Packing = Packed_Q8_0 and then Waved (Item, Packing, Count)
       then (if Count in Q8_Count then Item.Q8_Multi_Lines (Count)
             elsif Q8_Short (Item, Packing, Count, Columns)
             then Item.Q8_Short_Line
             else Item.Q8_Wave_Line)
       elsif Packing = Packed_IQ4_NL and then Waved (Item, Packing, Count)
       then Item.NL_Wave_Line
       elsif Packing = Packed_MXFP4 and then Waved (Item, Packing, Count)
       then Item.MX_Wave_Line
       elsif Packing = Packed_IQ4_XS and then Waved (Item, Packing, Count)
       then Item.XS_Wave_Line
       elsif Packing = Packed_Q2_K and then Waved (Item, Packing, Count)
       then Item.Q2K_Wave_Line
       elsif Packing = Packed_Q3_K and then Waved (Item, Packing, Count)
       then Item.Q3K_Wave_Line
       elsif Packing in Legacy_Packing and then Waved (Item, Packing, Count)
       then Item.Legacy_Wave_Lines (Packing)
       elsif Packing in Half_Packing and then Waved (Item, Packing, Count)
       then Item.Half_Wave_Lines (Packing)
       elsif Packing in Low_Packing
       then (if Count in Row_Line_Array'Range
               and then Item.Low_Row_Lines (Count) /= Null_Handle
             then Item.Low_Row_Lines (Count)
             elsif Count > Batch_Group and then Item.Low_Wide_Line /= Null_Handle
             then Item.Low_Wide_Line
             else Item.Low_Pipeline)
       elsif Count in Many_Count and then Packing = Packed_Q4_K
         and then Waved (Item, Packing, Count)
       then Item.Many_Lines4 (Count)
       elsif Count in Many_Count and then Packing = Packed_Q5_K
         and then Waved (Item, Packing, Count)
       then Item.Many_Lines5 (Count)
       elsif Count in Many_Count and then Packing = Packed_Q6_K
         and then Waved (Item, Packing, Count)
       then Item.Many_Lines6 (Count)
       elsif Waved (Item, Packing, Count)
       then (if Packing = Packed_Q5_K
               and then Columns >= Long_Row_Columns
               and then Item.Long_Line5 /= Null_Handle
             then Item.Long_Line5
             elsif Packing = Packed_Q5_K then Item.Wave_Line5
             elsif Packing = Packed_Q6_K
               and then Columns >= Long_Row_Columns
               and then Item.Long_Line6 /= Null_Handle
             then Item.Long_Line6
             elsif Packing = Packed_Q6_K
               and then Columns > Mid_Row_Columns
               and then Item.Mid_Line6 /= Null_Handle
             then Item.Mid_Line6
             elsif Packing = Packed_Q6_K then Item.Wave_Line6
             elsif Columns >= Long_Row_Columns
               and then Item.Long_Line /= Null_Handle
             then Item.Long_Line
             else Item.Wave_Line)
       elsif Half_Grouped (Item, Packing, Count)
       then Item.Half_Group_Line
       elsif Count in Row_Line_Array'Range
         and then Item.Row_Lines (Count) /= Null_Handle
       then Item.Row_Lines (Count)
       elsif Count > Batch_Group and then Item.Wide_Line /= Null_Handle
       then Item.Wide_Line
       else Item.Pipeline);

   --  And how many vectors that kernel carries, which is how far the
   --  dispatch loop steps. The two are one decision: a loop that steps
   --  eight while the bound kernel accumulates sixteen would ask the second
   --  dispatch to start halfway through what the first already wrote.
   function Row_Group (Item : Engine; Count : Natural) return Positive
   is (if Count > Batch_Group and then Item.Wide_Line /= Null_Handle
       then Wide_Group
       elsif Count in Row_Line_Array'Range
         and then Item.Row_Lines (Count) /= Null_Handle
       then Count
       else Batch_Group);

   --  Whether this format has a few-vector walk for Count vectors: one
   --  pass over the weights carrying them all.
   function Has_Walk
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Boolean
   is (Count in Many_Count
       and then (Item.Wave_Multi_Lines (Packing) (Count) /= Null_Handle
                 or else (Packing = Packed_Q4_K
                          and then Waved (Item, Packing, Count)
                          and then Item.Many_Lines4 (Count) /= Null_Handle)
                 or else (Packing = Packed_Q5_K
                          and then Waved (Item, Packing, Count)
                          and then Item.Many_Lines5 (Count) /= Null_Handle)
                 or else (Packing = Packed_Q6_K
                          and then Waved (Item, Packing, Count)
                          and then Item.Many_Lines6 (Count) /= Null_Handle)));

   --  A batch of nine to sixteen taken as two few-vector walks, the first
   --  carrying this many and the second the rest, where the format has
   --  walks for both; nought where it goes to the tile. A tile costs what
   --  its width costs whatever it is given, and a walk what its weights
   --  do: ThinkingCap's prompt of 10 read in 1.15 s on the narrow tile
   --  and 0.67 as two walks, of 15 in 1.14 and 0.87. Only the formats
   --  whose tile decodes through a table, which the tile pays for at
   --  every position: Q4_K's tile won, qwen3-8b's prompt of 15 0.195 s
   --  against 0.268 as walks, and TinyLlama's Q2_K and Q3_K by a few
   --  milliseconds, where its IQ4_NL lost 0.044 to 0.036.
   function Split_Half
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Natural
   is (if Count in Batch_Group + 1 .. 2 * Batch_Group
         and then Packing in Packed_IQ4_XS | Packed_IQ4_NL
         and then Has_Walk (Item, Packing, (Count + 1) / 2)
         and then Has_Walk (Item, Packing, Count / 2)
       then (Count + 1) / 2
       else 0);

   --  Which of the four tiles answers this format at this width. Null when
   --  the device refused the one this batch would need.
   function Tile_Pipeline
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural) return Address
   is (if Packing in Low_Packing
       then (if Narrowed (Count) then Item.Narrow_Low_Line
             elsif Midway (Item, Count) then Item.Mid_Low_Line
             elsif Mid_Widely (Item, Count) then Item.Mid_Wide_Low_Line
             elsif Widened (Item, Count) then Item.Wider_Low_Line
             else Item.Low_Tile_Line)
       elsif Narrowed (Count)
       then (if On_Extra (Packing)
             then Item.Narrow_More_Line else Item.Narrow_Line)
       elsif Midway (Item, Count)
       then (if On_Extra (Packing)
             then Item.Mid_More_Line else Item.Mid_Line)
       elsif Mid_Widely (Item, Count)
       then (if On_Extra (Packing)
             then Item.Mid_Wide_More_Line else Item.Mid_Wide_Line)
       elsif Widened (Item, Count)
       then (if On_Extra (Packing)
             then Item.Wider_More_Line else Item.Wider_Line)
       else (if On_Extra (Packing)
             then Item.Extra_Line else Item.Matrix_Line));

   --  The tile a listed product binds: the wide tile's words at thirty-two
   --  vectors, in the compilation that decodes the format.
   function Listed_Pipeline
     (Item : Engine; Packing : Weight_Packing) return Address
   is (if Packing in Low_Packing then Item.Listed_Low_Line
       --  Q5_0 on its own compilation, which reads it a step ahead: Mellum's
       --  projections down that are not Q8_0.
       elsif Packing = Packed_Q5_0 and then Item.Listed_Five_Line /= Null_Handle
       then Item.Listed_Five_Line
       elsif On_Extra (Packing) then Item.Listed_More_Line
       else Item.Listed_Line);

   --  And the tile at Listed_Wide_Vectors, where there is one for the
   --  format: null for the low-bit formats.
   function Listed_Wide_Pipeline
     (Item : Engine; Packing : Weight_Packing) return Address
   is (if Packing in Low_Packing then Null_Handle
       elsif On_Extra (Packing) then Item.Listed_Wide_More_Line
       else Item.Listed_Wide_Line);

   --  Whether a listed product of Count positions, Used of Experts each,
   --  takes the wider tile: where its runs average Listed_Wide_Run.
   function Listed_Wide
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural;
      Used    : Natural;
      Experts : Natural) return Boolean
   is (Listed_Wide_Pipeline (Item, Packing) /= Null_Handle
       and then Count * Used >= Listed_Wide_Run * Natural'Max (Experts, 1));

   --  How many values past its own vectors a tap product reads: two padded
   --  rows and two pixels, the last tap's neighbour; nought for any other
   --  step.
   function Tap_Reach (This : Step) return Natural
   is (if This.Tap_Row = 0 then 0 else 2 * This.Tap_Row + 2 * This.Columns);

   function Uses_Matrix
     (Item    : Engine;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural;
      Rounded : Boolean := False) return Boolean
   is (Item.Matrices
       and then Item.Matrix_Line /= Null_Handle
       and then Rows mod Tile_Grain = 0
       and then Count >= Item.Launch.Matrix_Row_Crossover
       and then Split_Half (Item, Packing, Count) = 0

       --  The tile this width and this format has to exist, not merely
       --  some tile: the room the batch is rounded into is decided by the
       --  width before the pipeline is bound, so a device that took the
       --  wide tile and refused the narrow one must not be given a batch
       --  the narrow one would have answered.
       and then Tile_Pipeline (Item, Packing, Count) /= Null_Handle
       --  The width the tile steps in. The wide tile decodes four chunks of
       --  thirty-two at once -- one for each of its lane groups -- so its
       --  step is a hundred and twenty-eight where the narrow tile's is
       --  thirty-two. A width that is not a whole number of steps ends in a
       --  step whose chunks past the row the tile neither decodes nor
       --  multiplies, so a whole number of chunks is what it needs:
       --  Falcon-7B is 4544 wide, and its prompts went to the row product,
       --  at an eighth of the tile's rate.
       and then (((Packing in Values_F16 | Values_BF16
                   or else (Packing = Values_F32 and then Rounded))
                  and then Columns mod 32 = 0)
                 or else (Packing in Packed_Q4_0 | Packed_Q4_1 | Packed_Q5_0
                                     | Packed_Q5_1 | Packed_Q8_0
                                     | Packed_IQ4_NL | Packed_MXFP4
                          and then Columns mod 32 = 0)
                 or else (Packing in Low_Packing
                          and then Columns mod 256 = 0)
                 or else (Packing in Super_Packing
                          and then Columns mod 256 = 0)));

   function Half_Descriptor (Item : Engine) return Buffer_Info
   is (if Item.Half_Buffer /= Null_Handle
       then (Buffer => Item.Half_Buffer,
             Offset => 0,
             Extent => Item.Half_Bytes)
       else (Buffer => Item.Vector_Buffer,
             Offset => 0,
             Extent => Item.Vector_Bytes));

   --  And the cache's half-precision copy, which has a buffer of its own
   --  so that neither it nor the cache proper is past what one storage
   --  buffer may hold. A set is written whole, so a dispatch that never
   --  reads the copy is given something rather than nothing: the vector
   --  buffer, as the halves above are.
   function Copy_Descriptor (Item : Engine) return Buffer_Info
   is (if Item.Use_Second and then Item.Second_Buffer /= Null_Handle
       then (Buffer => Item.Second_Buffer,
             Offset => 0,
             Extent => Item.Second_Bytes)
       elsif Item.Copy_Buffer /= Null_Handle
       then (Buffer => Item.Copy_Buffer,
             Offset => 0,
             Extent => Item.Copy_Bytes)
       else (Buffer => Item.Vector_Buffer,
             Offset => 0,
             Extent => Item.Vector_Bytes));

   --  Where a kernel reads the values' halves: the values' buffer where the
   --  copy is split, and the copy buffer itself where it is not -- there the
   --  values sit past the keys in the one buffer and the base says where, so
   --  binding the same buffer to the values' binding and reading it at the
   --  global base is the same bytes as reading the keys' binding was. A
   --  dispatch that reads no values is still given something valid.
   function Values_Copy_Descriptor (Item : Engine) return Buffer_Info
   is (if Item.Use_Second and then Item.Second_Buffer /= Null_Handle
       then Copy_Descriptor (Item)
       elsif Item.Copy_Split and then Item.Copy_Values_Buffer /= Null_Handle
       then (Buffer => Item.Copy_Values_Buffer,
             Offset => 0,
             Extent => Item.Copy_Values_Bytes)
       else Copy_Descriptor (Item));

   --  The cache proper, or a stand-in where only the copy is kept. A set
   --  is written whole, so the binding a copy-only session would name for
   --  the binary32 cache is given something valid: that session is
   --  sinkless, so the attend kernel never reads it, and the heads and
   --  place kernels are told to skip the write, so what is there is never
   --  touched. The copy serves.
   function Cache_Descriptor (Item : Engine) return Buffer_Info
   is (if Item.Cache_Buffer /= Null_Handle
       then (Buffer => Item.Cache_Buffer,
             Offset => 0,
             Extent => Item.Cache_Bytes)
       else Copy_Descriptor (Item));

   type Write_Descriptor is record
      Kind        : C.unsigned := Structure_Write_Descriptor;
      Next        : Address := Null_Handle;
      Target      : Address := Null_Handle;
      Binding     : C.unsigned := 0;
      First       : C.unsigned := 0;
      Count       : C.unsigned := 1;
      Descriptor  : C.unsigned := Descriptor_Storage;
      Images      : Address := Null_Handle;
      Buffers     : Address := Null_Handle;
      Texels      : Address := Null_Handle;
   end record
     with Convention => C;

   type Write_Array is array (1 .. 7) of aliased Write_Descriptor;

   --  Bytes of push constants, which the layout declares and every dispatch
   --  writes. One number in two places is one number that can differ, so it
   --  is this one.
   --  The push constants a pipeline layout carries. Twenty-four bytes are
   --  what the two matrix kernels want; attention wants sixteen words, and
   --  a range is declared once for every pipeline that shares the layout. A
   --  shader may read fewer words than the range holds, so the larger number
   --  costs the smaller kernels nothing.
   --
   --  It has to be the larger one. This said fifty-six while attention
   --  pushed sixty, which is a write past the range the layout declares --
   --  allowed by no device and refused by no device either, because every
   --  one of them offers at least a hundred and twenty-eight bytes and no
   --  validation layer was running to say so. Two numbers a word apart is
   --  what let it drift; the range below is now taken from the largest of
   --  them rather than written again.
   Attention_Bytes : constant := 80;

   --  A binary32 by its bits, for a push word that carries one.
   function Float_Bits is new Ada.Unchecked_Conversion
     (C.C_float, C.unsigned);

   --  And the packed kernel's, which has the bases twice over -- the
   --  rows' in bytes and the scales' in floats -- the bits an element of
   --  each side, how many heads and positions a workgroup answers, a
   --  round's table and the sinks.
   Packed_Bytes    : constant := 124;
   Product_Bytes   : constant := 32 + 4 * Max_Gather + 12;
   Widest_Plain    : constant :=
     (if Product_Bytes > Attention_Bytes then Product_Bytes
      else Attention_Bytes);
   --  The layout's push-constant range must cover every shader's block, and
   --  the packed constants are the widest: a paged packed dispatch pushes
   --  Packed_Bytes, whose Page_Shift and First_Position sit past the plain
   --  range, so a layout sized to the plain paths leaves them undefined.
   Shape_Bytes     : constant :=
     (if Widest_Plain > Packed_Bytes then Widest_Plain else Packed_Bytes);

   type Push_Range is record
      Stages : C.unsigned := Stage_Compute;
      Offset : C.unsigned := 0;
      Size   : C.unsigned := Shape_Bytes;
   end record
     with Convention => C;

   type Pipeline_Layout_Info is record
      Kind        : C.unsigned := Structure_Pipeline_Layout;
      Next        : Address := Null_Handle;
      Flags       : C.unsigned := 0;
      Set_Count   : C.unsigned := 1;
      Sets        : Address := Null_Handle;
      Push_Count  : C.unsigned := 1;
      Pushes      : Address := Null_Handle;
   end record
     with Convention => C;

   type Shader_Create_Info is record
      Kind  : C.unsigned := Structure_Shader_Create;
      Next  : Address := Null_Handle;
      Flags : C.unsigned := 0;
      Size  : Interfaces.C.size_t := 0;
      Code  : Address := Null_Handle;
   end record
     with Convention => C;

   type Stage_Create_Info is record
      Kind          : C.unsigned := Structure_Stage_Create;
      Next          : Address := Null_Handle;
      Flags         : C.unsigned := 0;
      Stage         : C.unsigned := Stage_Compute;
      Module        : Address := Null_Handle;
      Name          : C.Strings.chars_ptr := C.Strings.Null_Ptr;
      Specialized   : Address := Null_Handle;
   end record
     with Convention => C;

   --  A stage flag and a chained structure that pin a compute shader's
   --  subgroup to a width: full subgroups, and the width itself. The
   --  structure was typed as the subgroup-size features, 1000225002, which
   --  a driver skips as a structure it does not expect there: the width
   --  was never asked for, and the validation layer said so at every
   --  pipeline. RADV's own width for compute is sixty-four, which is the
   --  width asked, so nothing measured moved.
   Require_Full_Subgroups  : constant := 16#0000_0002#;

   --  The subgroup width the matrix kernels number their subgroups by:
   --  matrix_product.comp and attention_matrix.comp take a subgroup as
   --  sixty-four lanes of the workgroup.
   Matrix_Lanes : constant := 64;
   Structure_Required_Size : constant := 1000225001;

   type Required_Size_Info is record
      Kind     : C.unsigned := Structure_Required_Size;
      Next     : Address := Null_Handle;
      Required : C.unsigned := 0;
   end record
     with Convention => C;

   --  One specialization constant and the block that carries it, which is
   --  how the row product's workgroup width is set: the same words, made
   --  into two pipelines at two widths.
   type Specialization_Entry is record
      Which  : C.unsigned := 0;
      At_Was : C.unsigned := 0;
      Span   : Interfaces.C.size_t := 4;
   end record
     with Convention => C;

   type Specialization_Info is record
      Count   : C.unsigned := 1;
      Entries : Address := Null_Handle;
      Span    : Interfaces.C.size_t := 4;
      Values  : Address := Null_Handle;
   end record
     with Convention => C;

   type Compute_Pipeline_Info is record
      Kind     : C.unsigned := Structure_Compute_Pipeline;
      Next     : Address := Null_Handle;
      Flags    : C.unsigned := 0;
      Stage    : Stage_Create_Info;
      Layout   : Address := Null_Handle;
      Base     : Address := Null_Handle;
      Base_Num : C.int := 0;
   end record
     with Convention => C;

   type Command_Pool_Info is record
      Kind   : C.unsigned := Structure_Command_Pool;
      Next   : Address := Null_Handle;
      Flags  : C.unsigned := 2;   --  reset a buffer without resetting a pool
      Family : C.unsigned := 0;
   end record
     with Convention => C;

   type Command_Buffer_Info is record
      Kind  : C.unsigned := Structure_Command_Buffer;
      Next  : Address := Null_Handle;
      Pool  : Address := Null_Handle;
      Level : C.unsigned := Level_Primary;
      Count : C.unsigned := 1;
   end record
     with Convention => C;

   type Query_Pool_Create_Info is record
      Kind       : C.unsigned := Structure_Query_Pool;
      Next       : Address := Null_Handle;
      Flags      : C.unsigned := 0;
      Query_Kind : C.unsigned := Query_Timestamp;
      Count      : C.unsigned := C.unsigned (Sequence_Limit + 1);
      Statistics : C.unsigned := 0;
   end record
     with Convention => C;

   type Command_Begin_Info is record
      Kind        : C.unsigned := Structure_Command_Begin;
      Next        : Address := Null_Handle;
      Flags       : C.unsigned := Use_Once;
      Inheritance : Address := Null_Handle;
   end record
     with Convention => C;

   type Submit_Info is record
      Kind         : C.unsigned := Structure_Submit;
      Next         : Address := Null_Handle;
      Wait_Count   : C.unsigned := 0;
      Waits        : Address := Null_Handle;
      Wait_Stages  : Address := Null_Handle;
      Buffer_Count : C.unsigned := 1;
      Buffers      : Address := Null_Handle;
      Signal_Count : C.unsigned := 0;
      Signals      : Address := Null_Handle;
   end record
     with Convention => C;

   type Fence_Create_Info is record
      Kind  : C.unsigned := Structure_Fence_Create;
      Next  : Address := Null_Handle;
      Flags : C.unsigned := 0;
   end record
     with Convention => C;

   --  What the shader is told about the shape, in the order it declares.
   --  What the attention kernel is told. Thirty-one words, against the six
   --  the matrix kernels take, pushed into the same range. Inside the
   --  hundred and twenty-eight bytes every device that runs Vulkan offers.
   type Packed_Constants is record
      Heads      : C.unsigned := 0;
      Head_Size  : C.unsigned := 0;
      Value_Size : C.unsigned := 0;
      Group_Size : C.unsigned := 1;
      First      : C.unsigned := 0;
      Last       : C.unsigned := 0;
      K_Bytes    : C.unsigned := 0;
      V_Bytes    : C.unsigned := 0;
      KV_Width   : C.unsigned := 0;
      V_Width    : C.unsigned := 0;
      KS_At      : C.unsigned := 0;
      VS_At      : C.unsigned := 0;
      K_Blocks   : C.unsigned := 1;
      V_Blocks   : C.unsigned := 1;
      K_Bits     : C.unsigned := 8;
      V_Bits     : C.unsigned := 8;
      Scale      : C.C_float := 1.0;
      Cap        : C.C_float := 0.0;
      Max_Bias   : C.C_float := 0.0;
      Positions  : C.unsigned := 1;
      Window     : C.unsigned := 0;
      Causal     : C.unsigned := 1;
      Bundle     : C.unsigned := 1;
      Queries    : C.unsigned := 1;
      Table_At   : C.unsigned := 0;
      Sinks_At   : C.unsigned := 0;

      --  A cache in pages: the batch's page table, the page's shift, and
      --  the first row's position -- as place.comp and pack.comp carry
      --  them. Zero shift is a cache in blocks.
      Pages_At       : C.unsigned := 0;
      Page_Shift     : C.unsigned := 0;
      First_Position : C.unsigned := 0;

      --  Append-only codec identities. Bits describe code width; these
      --  describe its meaning, so transformed Q4 never aliases plain Q4.
      K_Codec : C.unsigned := 0;
      V_Codec : C.unsigned := 0;
   end record
     with Convention => C;

   pragma Compile_Time_Error
     (Packed_Constants'Size /= Packed_Bytes * 8,
      "the packed attention constants are not the size the shader reads");

   type Attention_Constants is record
      Heads      : C.unsigned := 0;
      Head_Size  : C.unsigned := 0;
      Value_Size : C.unsigned := 0;
      Group_Size : C.unsigned := 1;
      First      : C.unsigned := 0;
      Last       : C.unsigned := 0;
      K_Base     : C.unsigned := 0;
      V_Base     : C.unsigned := 0;
      KV_Width   : C.unsigned := 0;
      V_Width    : C.unsigned := 0;
      Scale      : C.C_float := 1.0;
      Cap        : C.C_float := 0.0;
      Positions  : C.unsigned := 1;
      Window     : C.unsigned := 0;

      --  One where a position sees only what precedes it, which is every
      --  model that generates, and zero where it sees the whole text. The
      --  shader derives each position's last from this, so a call that
      --  pushed the wrong one would attend to the wrong half of a text and
      --  return numbers of exactly the right shape.
      Causal     : C.unsigned := 1;

      --  How steeply a head's attention falls off with distance, for the one
      --  architecture that is told where a token is by the scores rather
      --  than by a rotation or a learned row. Zero for every other, which is
      --  no fall-off at all and the branch the shader skips.
      Max_Bias   : C.C_float := 0.0;

      --  A round rather than a batch: where in the cache the per-row table
      --  begins, in elements, and zero for a batch. Two words a row --
      --  where the row has got to, and where its cache begins -- read back
      --  out of the cache buffer, which the kernel has bound already. They
      --  were pushed until a round wanted more rows than a push block has
      --  room for words.
      Table_At   : C.unsigned := 0;

      --  Where the heads' sinks begin in the cache, in elements, for an
      --  architecture that learned one a head -- a score that joins the
      --  softmax's denominator and takes no value -- and zero for none.
      --  In the cache for the reason the table is.
      Sinks_At   : C.unsigned := 0;

      --  A cache in pages: where a batch's page table for the layer
      --  begins, and the page's width as a shift. Zero shift for a cache
      --  in blocks.
      Pages_At   : C.unsigned := 0;
      Page_Shift : C.unsigned := 0;
   end record
     with Convention => C;

   pragma Compile_Time_Error
     (Attention_Constants'Size /= Attention_Bytes * 8,
      "the attention constants are not the size the shader reads");

   type Member_Words is array (0 .. Max_Gather - 1) of C.unsigned
     with Convention => C;

   --  What heads.comp is told, in its order.
   type Heads_Constants is record
      Heads      : C.unsigned := 0;
      Head_Size  : C.unsigned := 0;
      Rotary     : C.unsigned := 0;
      Pairing    : C.unsigned := 0;
      Count      : C.unsigned := 0;
      Normed     : C.unsigned := 0;
      Epsilon    : C.unsigned := 0;
      Base       : C.unsigned := 0;
      From       : C.unsigned := 0;
      Into       : C.unsigned := 0;
      Stride     : C.unsigned := 0;
      Turn_Base  : C.unsigned := 0;
      Half_Base  : C.unsigned := 0;
      Halves     : C.unsigned := 0;
      V_From     : C.unsigned := 0;
      V_Width    : C.unsigned := 0;
      V_Into     : C.unsigned := 0;
      V_Stride   : C.unsigned := 0;

      --  A cache in pages, for the dispatch that places: the batch's
      --  page table, the page's width as a shift, and the session
      --  position of the first row. Zero shift for a cache in blocks.
      Pages_At       : C.unsigned := 0;
      Page_Shift     : C.unsigned := 0;
      First_Position : C.unsigned := 0;

      --  A fused source's per-position stride, main stream and values: the
      --  whole fused row count where one matmul made all three projections,
      --  zero for the ordinary per-arm source.
      Src_Stride     : C.unsigned := 0;
      V_Src_Stride   : C.unsigned := 0;

      --  The projections' bias, where the weight binding holds it: whether,
      --  where the heads' begins and where the values' begins, in elements.
      Biased         : C.unsigned := 0;
      Bias_Base      : C.unsigned := 0;
      V_Bias_Base    : C.unsigned := 0;
   end record
     with Convention => C;

   Heads_Bytes : constant := 26 * 4;

   --  What merge.comp is told.
   type Merge_Constants is record
      Heads      : C.unsigned := 0;
      Value_Size : C.unsigned := 0;
      Positions  : C.unsigned := 0;
      Slices     : C.unsigned := 0;
   end record
     with Convention => C;

   Merge_Bytes : constant := 4 * 4;

   type Shape_Constants is record
      Rows    : C.unsigned := 0;
      Columns : C.unsigned := 0;
      Count   : C.unsigned := 1;
      First   : C.unsigned := 0;
      Packing : C.unsigned := 0;
      Base    : C.unsigned := 0;

      --  Whether the product adds the residual bound beside it before it
      --  stores, which is a join folded into the product the join followed.
      Joins   : C.unsigned := 0;

      --  Where a round's per-row table begins, in elements, for the step
      --  that writes the cache. Zero for a batch and for every other kind
      --  of step, which do not read it.
      Table   : C.unsigned := 0;

      --  A gather: which expert each workgroup of the third dispatch
      --  dimension reads, the bytes one expert's slice takes, and how far
      --  into the activation each member's own vector begins. All zero for
      --  a plain product, which is a gather of one member at slice zero.
      Members : Member_Words := [others => 0];
      Stride  : C.unsigned := 0;
      Apart   : C.unsigned := 0;

      --  Whether a gather takes its members from the routing step bound
      --  at three rather than from Members.
      Routed  : C.unsigned := 0;
   end record
     with Convention => C;

   ---------------------------------------------------------------------------
   --  Entry points
   ---------------------------------------------------------------------------

   type Create_Call is access
     function (Device : Address; Info : Address; Allocator : Address;
               Result : access Address) return C.int
     with Convention => C;

   type Destroy_Call is access
     procedure (Device : Address; Item : Address; Allocator : Address)
     with Convention => C;

   type Requirements_Call is access
     procedure (Device : Address; Buffer : Address; Result : Address)
     with Convention => C;

   type Bind_Call is access
     function (Device : Address; Buffer : Address; Memory : Address;
               Offset : Interfaces.Unsigned_64) return C.int
     with Convention => C;

   type Map_Call is access
     function (Device : Address; Memory : Address;
               Offset : Interfaces.Unsigned_64;
               Size   : Interfaces.Unsigned_64;
               Flags  : C.unsigned;
               Data   : access Address) return C.int
     with Convention => C;

   type Unmap_Call is access
     procedure (Device : Address; Memory : Address)
     with Convention => C;

   type Allocate_Sets_Call is access
     function (Device : Address; Info : Address;
               Sets : access Address) return C.int
     with Convention => C;

   type Update_Sets_Call is access
     procedure (Device : Address; Write_Count : C.unsigned; Writes : Address;
                Copy_Count : C.unsigned; Copies : Address)
     with Convention => C;

   type Create_Pipelines_Call is access
     function (Device : Address; Cache : Address; Count : C.unsigned;
               Info : Address; Allocator : Address;
               Result : access Address) return C.int
     with Convention => C;

   type Allocate_Buffers_Call is access
     function (Device : Address; Info : Address;
               Buffers : access Address) return C.int
     with Convention => C;

   type Begin_Call is access
     function (Buffer : Address; Info : Address) return C.int
     with Convention => C;

   type End_Call is access
     function (Buffer : Address) return C.int
     with Convention => C;

   type Reset_Buffer_Call is access
     function (Buffer : Address; Flags : C.unsigned) return C.int
     with Convention => C;

   type Bind_Pipeline_Call is access
     procedure (Buffer : Address; Point : C.unsigned; Pipeline : Address)
     with Convention => C;

   type Bind_Sets_Call is access
     procedure (Buffer : Address; Point : C.unsigned; Layout : Address;
                First : C.unsigned; Count : C.unsigned; Sets : Address;
                Dynamic_Count : C.unsigned; Dynamic : Address)
     with Convention => C;

   type Push_Call is access
     procedure (Buffer : Address; Layout : Address; Stages : C.unsigned;
                Offset : C.unsigned; Size : C.unsigned; Values : Address)
     with Convention => C;

   type Memory_Barrier is record
      Kind   : C.unsigned := Structure_Memory_Barrier;
      Next   : Address := Null_Handle;
      Wrote  : C.unsigned := Access_Shader_Write;
      Reads  : C.unsigned := Access_Shader_Read;
   end record
     with Convention => C;

   type Barrier_Call is access
     procedure (Buffer : Address;
                From, Into : C.unsigned;
                Flags : C.unsigned;
                Memory_Count : C.unsigned; Memories : Address;
                Buffer_Count : C.unsigned; Buffers : Address;
                Image_Count : C.unsigned; Images : Address)
     with Convention => C;

   type Dispatch_Call is access
     procedure (Buffer : Address; X, Y, Z : C.unsigned)
     with Convention => C;

   --  Fill a run of a buffer with one word, on the device. Zeroing a
   --  cache through its mapping is the host faulting in every page of it
   --  -- seventeen milliseconds of a nineteen-millisecond reserve for a
   --  cache of ninety megabytes -- and the device writes its own memory
   --  at its own rate.
   --  A run of one buffer copied into another, on the device: where the
   --  run begins in each and how long it is, in bytes.
   type Copy_Region is record
      From : Interfaces.Unsigned_64 := 0;
      Into : Interfaces.Unsigned_64 := 0;
      Span : Interfaces.Unsigned_64 := 0;
   end record
     with Convention => C;

   type Copy_Buffer_Call is access
     procedure (Buffer : Address; From, Into : Address;
                Count : C.unsigned; Regions : Address)
     with Convention => C;

   type Fill_Call is access
     procedure (Buffer : Address; Target : Address;
                Offset : Interfaces.Unsigned_64;
                Size   : Interfaces.Unsigned_64;
                Value  : C.unsigned)
     with Convention => C;

   type Submit_Call is access
     function (Queue : Address; Count : C.unsigned; Info : Address;
               Fence : Address) return C.int
     with Convention => C;

   type Wait_Call is access
     function (Device : Address; Count : C.unsigned; Fences : Address;
               All_Of : C.unsigned;
               Timeout : Interfaces.Unsigned_64) return C.int
     with Convention => C;

   type Reset_Fences_Call is access
     function (Device : Address; Count : C.unsigned;
               Fences : Address) return C.int
     with Convention => C;

   --  Whether a fence has been signalled, asked without waiting.
   type Fence_Status_Call is access
     function (Device : Address; Fence : Address) return C.int
     with Convention => C;

   --  Reset a run of queries, write a timestamp into one, and read what a
   --  run of them latched.
   type Reset_Queries_Call is access
     procedure (Buffer : Address; Pool : Address; First : C.unsigned;
                Count : C.unsigned)
     with Convention => C;

   type Write_Stamp_Call is access
     procedure (Buffer : Address; Stage : C.unsigned; Pool : Address;
                Query : C.unsigned)
     with Convention => C;

   type Query_Results_Call is access
     function (Device : Address; Pool : Address; First : C.unsigned;
               Count : C.unsigned; Bytes : Interfaces.Unsigned_64;
               Data : Address; Stride : Interfaces.Unsigned_64;
               Flags : C.unsigned) return C.int
     with Convention => C;

   function To_Create is
     new Ada.Unchecked_Conversion (Address, Create_Call);
   function To_Destroy is
     new Ada.Unchecked_Conversion (Address, Destroy_Call);
   function To_Requirements is
     new Ada.Unchecked_Conversion (Address, Requirements_Call);
   function To_Bind is new Ada.Unchecked_Conversion (Address, Bind_Call);
   function To_Host_Properties is
     new Ada.Unchecked_Conversion (Address, Host_Properties_Call);
   function To_Map is new Ada.Unchecked_Conversion (Address, Map_Call);
   function To_Unmap is new Ada.Unchecked_Conversion (Address, Unmap_Call);
   function To_Allocate_Sets is
     new Ada.Unchecked_Conversion (Address, Allocate_Sets_Call);
   function To_Update_Sets is
     new Ada.Unchecked_Conversion (Address, Update_Sets_Call);
   function To_Create_Pipelines is
     new Ada.Unchecked_Conversion (Address, Create_Pipelines_Call);
   function To_Allocate_Buffers is
     new Ada.Unchecked_Conversion (Address, Allocate_Buffers_Call);
   function To_Begin is new Ada.Unchecked_Conversion (Address, Begin_Call);
   function To_End is new Ada.Unchecked_Conversion (Address, End_Call);
   function To_Reset_Buffer is
     new Ada.Unchecked_Conversion (Address, Reset_Buffer_Call);
   function To_Bind_Pipeline is
     new Ada.Unchecked_Conversion (Address, Bind_Pipeline_Call);
   function To_Bind_Sets is
     new Ada.Unchecked_Conversion (Address, Bind_Sets_Call);
   function To_Push is new Ada.Unchecked_Conversion (Address, Push_Call);
   function To_Dispatch is
     new Ada.Unchecked_Conversion (Address, Dispatch_Call);

   function To_Fill is new Ada.Unchecked_Conversion (Address, Fill_Call);

   function To_Copy_Buffer is
     new Ada.Unchecked_Conversion (Address, Copy_Buffer_Call);
   function To_Barrier is
     new Ada.Unchecked_Conversion (Address, Barrier_Call);
   function To_Submit is new Ada.Unchecked_Conversion (Address, Submit_Call);
   function To_Wait is new Ada.Unchecked_Conversion (Address, Wait_Call);
   function To_Fence_Status is
     new Ada.Unchecked_Conversion (Address, Fence_Status_Call);
   function To_Reset_Fences is
     new Ada.Unchecked_Conversion (Address, Reset_Fences_Call);
   function To_Reset_Queries is
     new Ada.Unchecked_Conversion (Address, Reset_Queries_Call);
   function To_Write_Stamp is
     new Ada.Unchecked_Conversion (Address, Write_Stamp_Call);
   function To_Query_Results is
     new Ada.Unchecked_Conversion (Address, Query_Results_Call);

   --  The instance every entry point below is found through. Set from the
   --  engine whose operation is running, because an entry point belongs to
   --  the instance it was found through and outlives none of them.
   --
   --  It used to be set once, when an engine was opened, and left. Closing
   --  an engine and then the device under it left this naming an instance
   --  that no longer existed, and the next engine's Open -- which releases
   --  before it makes -- asked that dead instance for vkDestroyBuffer. The
   --  loader does not return null for an invalid instance; it aborts the
   --  process, which is what it did.
   Instance_Of : Address := Null_Handle;

   --  The implementation below has package-wide worker tasks, prefetch slots
   --  and Vulkan entry-point state. Refuse a second live Engine explicitly;
   --  allowing one would make those globals cross device instances.
   protected Engine_Slot is
      procedure Claim (Granted : out Boolean);
      procedure Release;
   private
      Held : Boolean := False;
   end Engine_Slot;

   protected body Engine_Slot is
      procedure Claim (Granted : out Boolean) is
      begin
         Granted := not Held;
         Held := True;
      end Claim;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Engine_Slot;

   --  Null when there is no instance to ask, so that a caller releasing an
   --  engine that was never made asks nobody rather than asking a handle
   --  that is not one.
   function Point (Name : String) return Address
   is (if Instance_Of = Null_Handle
       then Null_Handle
       else Entry_Point (Instance_Of, Name));

   --  Point this engine's instance at the loader before anything is asked of
   --  it. A function so that it can be a declaration in the operations that
   --  need it, which is how it comes before their first entry point.
   function Set_Asking (Item : Engine) return Boolean is
   begin
      Instance_Of := Item.Instance;
      return True;
   end Set_Asking;

   --  Make a buffer and the memory behind it, both released by the caller.
   --
   --  Read says the processor reads what is in it, which decides which kind
   --  of memory it is made of rather than anything about the buffer itself:
   --  a result is read back and an upload is not, and the two want opposite
   --  kinds. See Engine.Download.
   procedure Take
     (Item   : in out Engine;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Ok     : out Boolean;
      Read   : Boolean := False;
      Kind   : Integer := -1)
   is
      Create : constant Create_Call := To_Create (Point ("vkCreateBuffer"));
      Wants  : constant Requirements_Call :=
        To_Requirements (Point ("vkGetBufferMemoryRequirements"));
      Allocate : constant Create_Call :=
        To_Create (Point ("vkAllocateMemory"));
      Bind : constant Bind_Call := To_Bind (Point ("vkBindBufferMemory"));

      Made : aliased Address := Null_Handle;
   begin
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Ok := False;

      if Create = null or else Wants = null or else Allocate = null
        or else Bind = null or else Bytes = 0
      then
         return;
      end if;

      declare
         Request : aliased Buffer_Create_Info;
      begin
         Request.Size := Bytes;
         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            return;
         end if;
         Buffer := Made;
      end;

      declare
         Needed  : aliased Memory_Requirements;
         Request : aliased Memory_Allocate_Info;
      begin
         Wants (Item.Logical, Buffer, Needed'Address);
         Request.Size := Needed.Size;
         --  A kind named outright, where the caller chose a heap; else the
         --  one the purpose decides.
         Request.Which :=
           (if Kind >= 0 then C.unsigned (Kind)
            else C.unsigned (if Read then Item.Download else Item.Upload));

         if Allocate (Item.Logical, Request'Address, Null_Handle,
                      Made'Access) /= 0
         then
            return;
         end if;
         Memory := Made;
      end;

      Ok := Bind (Item.Logical, Buffer, Memory, 0) = 0;
   end Take;

   --  Take the host's own memory as a buffer, rather than a copy of it.
   --
   --  What the device is given is a page-aligned address at or before the
   --  weights and a length that covers them, so the matrix begins some way
   --  into the buffer: that distance comes back as Base and goes to the
   --  shader, which adds it to every offset it reads.
   --
   --  Every way this can fail is a False and a caller that copies instead:
   --  a device without the extensions, a pointer the device cannot address,
   --  an allocation refused. None of them is an error -- they are the same
   --  answer arrived at one call later.
   --
   --  @param Item Engine holding the device.
   --  @param Whole Where the storage the weights live in begins, and how far
   --    it runs. The device is given a page-aligned range and pages are
   --    larger than tensors, so what it is handed reaches before the matrix
   --    and past it; both ends have to stay inside memory this process
   --    owns, and this is what says where that is. A range that would leave
   --    it is copied instead.
   --  @param Span How long that storage is.
   --  @param From Where the weights are, in this process.
   --  @param Bytes How many of them.
   --  @param Buffer Receives the buffer.
   --  @param Memory Receives the memory behind it.
   --  @param Base Receives the distance from the buffer to the weights.
   --  @param Ok True when the device took the pointer.
   procedure Take_Host_Memory
     (Item   : in out Engine;
      Whole  : Address;
      Span   : Interfaces.Unsigned_64;
      From   : Address;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Base   : out Interfaces.Unsigned_64;
      Ok     : out Boolean)
   is
      use type System.Storage_Elements.Integer_Address;

      Create : constant Create_Call := To_Create (Point ("vkCreateBuffer"));
      Allocate : constant Create_Call :=
        To_Create (Point ("vkAllocateMemory"));
      Bind : constant Bind_Call := To_Bind (Point ("vkBindBufferMemory"));
      Asked : constant Host_Properties_Call :=
        To_Host_Properties (Point ("vkGetMemoryHostPointerPropertiesEXT"));

      Made : aliased Address := Null_Handle;

      Where : constant System.Storage_Elements.Integer_Address :=
        System.Storage_Elements.To_Integer (From);
   begin
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Base := 0;
      Ok := False;

      if not Item.Imports or else Item.Import_To = 0
        or else Create = null or else Allocate = null or else Bind = null
        or else Asked = null or else Bytes = 0
      then
         return;
      end if;

      declare
         Align : constant System.Storage_Elements.Integer_Address :=
           System.Storage_Elements.Integer_Address (Item.Import_To);

         Start : constant System.Storage_Elements.Integer_Address :=
           Where - Where mod Align;

         Slack : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Where - Start);

         --  A whole number of whatever the device wanted, because that is
         --  what it will take: the pointer aligned and the length a
         --  multiple of the same.
         Length : constant Interfaces.Unsigned_64 :=
           ((Slack + Bytes + Item.Import_To - 1) / Item.Import_To)
           * Item.Import_To;

         Head : constant Address :=
           System.Storage_Elements.To_Address (Start);

         --  Both ends of what the device would be handed, against both
         --  ends of what this process owns. The rounding is what makes this
         --  necessary: a matrix at the end of a heap arena rounds up past
         --  the arena, and a device told to take memory nobody allocated is
         --  a fault this program would have asked for.
         Owned_First : constant System.Storage_Elements.Integer_Address :=
           System.Storage_Elements.To_Integer (Whole);
         Owned_Last  : constant System.Storage_Elements.Integer_Address :=
           Owned_First + System.Storage_Elements.Integer_Address (Span);

         Known : aliased Host_Pointer_Properties;
         Kinds : Interfaces.Unsigned_32;
         Which : Natural := 0;
      begin
         if Start < Owned_First
           or else Start + System.Storage_Elements.Integer_Address (Length)
                   > Owned_Last
         then
            return;
         end if;

         if Asked (Item.Logical, Handle_Host_Allocation, Head,
                   Known'Address) /= 0
         then
            return;
         end if;

         Kinds := Interfaces.Unsigned_32 (Known.Kinds);
         if Kinds = 0 then
            return;
         end if;

         --  A kind the pointer can be taken as and the processor writes
         --  and sees without being told to flush. Not the kind the uploads
         --  use: that one is chosen for being fast for the device to read,
         --  and a host pointer is rarely offered as it. On this machine the
         --  uploads use kind three and a host pointer is offered as kind
         --  five, which is why the first version of this imported nothing.
         Kinds := Kinds and Item.Plain;
         if Kinds = 0 then
            return;
         end if;

         while (Kinds and 1) = 0 loop
            Kinds := Interfaces.Shift_Right (Kinds, 1);
            Which := Which + 1;
         end loop;

         declare
            Outside : aliased External_Buffer_Info;
            Request : aliased Buffer_Create_Info;
         begin
            Request.Size := Length;
            Request.Next := Outside'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) /= 0
            then
               return;
            end if;
            Buffer := Made;
         end;

         declare
            Imported : aliased Import_Host_Info;
            Request  : aliased Memory_Allocate_Info;
         begin
            Imported.Pointer := Head;
            Request.Next := Imported'Address;
            Request.Size := Length;
            Request.Which := C.unsigned (Which);

            if Allocate (Item.Logical, Request'Address, Null_Handle,
                         Made'Access) /= 0
            then
               return;
            end if;
            Memory := Made;
         end;

         if Bind (Item.Logical, Buffer, Memory, 0) /= 0 then
            return;
         end if;

         Base := Slack;
         Ok := True;
      end;
   end Take_Host_Memory;

   --  Wait until every part of every copy into the device's memory is in.
   procedure Settle_Copies;

   procedure Give_Back_Buffer
     (Item : in out Engine; Buffer : in out Address; Memory : in out Address)
   is
      Destroy : constant Destroy_Call :=
        To_Destroy (Point ("vkDestroyBuffer"));
      Free : constant Destroy_Call := To_Destroy (Point ("vkFreeMemory"));
   begin
      --  Not from under a copy still on its way into it.
      Settle_Copies;

      if Buffer /= Null_Handle and then Destroy /= null
        and then Item.Logical /= Null_Handle
      then
         Destroy (Item.Logical, Buffer, Null_Handle);
      end if;
      Buffer := Null_Handle;

      if Memory /= Null_Handle and then Free /= null
        and then Item.Logical /= Null_Handle
      then
         Free (Item.Logical, Memory, Null_Handle);
      end if;
      Memory := Null_Handle;
   end Give_Back_Buffer;

   --  Where a buffer's memory is mapped, mapping it if it is not yet.
   --
   --  A standing mapping rather than a pair of calls per use. Vulkan allows
   --  one mapping of a memory object at a time and does not mind how long it
   --  stands; what making one costs is what this stops paying twice a
   --  product.
   --
   --  Two things about it have to be got right and both were got wrong
   --  first, so they are written down. The mapping covers the whole
   --  allocation and not the bytes one call happens to want, because the
   --  next call may want more and a mapping is not extended by asking again.
   --  And nothing else may unmap these two memories while an address into
   --  them is held. A writer that maps and unmaps around its own copy --
   --  which is what Write_Bytes still does, correctly, for memory nobody
   --  keeps a pointer into -- pulls the mapping out from under every other
   --  writer of the same buffer.
   procedure Standing
     (Item   : in out Engine;
      Memory : Address;
      Where  : in out Address;
      Bytes  : Interfaces.Unsigned_64;
      Ok     : out Boolean)
   is
      Map : constant Map_Call := To_Map (Point ("vkMapMemory"));

      Found : aliased Address := Null_Handle;
   begin
      Ok := False;

      if Where /= Null_Handle then
         Ok := True;
         return;
      end if;

      if Map = null or else Memory = Null_Handle or else Bytes = 0 then
         return;
      end if;

      if Map (Item.Logical, Memory, 0, Bytes, 0, Found'Access) /= 0 then
         return;
      end if;

      Where := Found;
      Ok := True;
   end Standing;

   --  Give back a standing mapping, before the memory behind it goes.
   procedure Unmap_Standing
     (Item : in out Engine; Memory : Address; Where : in out Address)
   is
      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
   begin
      if Where /= Null_Handle and then Unmap /= null
        and then Memory /= Null_Handle
      then
         Unmap (Item.Logical, Memory);
      end if;
      Where := Null_Handle;
   end Unmap_Standing;

   --  The same for storage this does not interpret. A packed matrix is bytes
   --  until the shader reads it, and copying it as anything else would be
   --  claiming to know what it holds.
   --  Map a matrix's memory and keep the pointer.
   --
   --  The upload used to map, copy and unmap for every matrix. With a
   --  buffer given back now kept rather than given up, that was the same
   --  memory object being mapped again and again -- three hundred and
   --  ninety times a generated token on a model that does not fit. The
   --  cache has been mapped once and held since it was written; this is
   --  the same for the weights.
   procedure Map_Memory
     (Item   : in out Engine;
      Memory : Address;
      Bytes  : Interfaces.Unsigned_64;
      Where  : out Address;
      Ok     : out Boolean)
   is
      Map : constant Map_Call := To_Map (Point ("vkMapMemory"));

      Got : aliased Address := Null_Handle;
   begin
      Where := Null_Handle;
      Ok := False;

      if Map = null or else Memory = Null_Handle then
         return;
      end if;

      if Map (Item.Logical, Memory, 0, Bytes, 0, Got'Access) /= 0 then
         return;
      end if;

      Where := Got;
      Ok := True;
   end Map_Memory;

   --  Give a matrix's storage up, mapping and all.
   procedure Release_Weight
     (Item   : in out Engine;
      Buffer : in out Address;
      Memory : in out Address;
      Mapped : in out Address)
   is
      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
   begin
      Settle_Copies;

      if Mapped /= Null_Handle
        and then Memory /= Null_Handle
        and then Unmap /= null
        and then Item.Logical /= Null_Handle
      then
         Unmap (Item.Logical, Memory);
      end if;

      Mapped := Null_Handle;
      Give_Back_Buffer (Item, Buffer, Memory);
   end Release_Weight;

   --  Write_Bytes's eight copiers, made the first time a matrix is copied
   --  and kept: eight tasks made and ended for every matrix were most of a
   --  thousand threads for a small model's first prompt.
   task type Byte_Copier is
      entry Go
        (Into, From : System.Address; Length : Model_Runner.Bytes.Byte_Count;
         Direct : Boolean);
   end Byte_Copier;
   type Byte_Copier_Access is access Byte_Copier;
   --  Sixteen measured no better with the reads not waited for: Qwen3.6's
   --  first batch 1.76 s against 1.84 over three pairs, its load slower.
   Copiers : array (1 .. 8) of Byte_Copier_Access;

   --  The copier a part goes to next, in turn, under Copying.
   Next_Copier : Positive := 1;

   --  One copy at a time through them, and its parts counted home.
   protected Copying is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Copying;

   --  Parts are counted out and home across copies: a read from the file
   --  is not waited for where it is asked (Write_Bytes), but before the
   --  device is handed work (Hand_Over) and before any memory goes.
   protected Copy_Count is
      procedure Expect (Parts : Natural);
      --  A part done; Failed where it could not be copied.
      procedure One_Done (Failed : Boolean := False);
      --  Every part done; Failed where any since the last asking could
      --  not be.
      entry Finished (Failed : out Boolean);
      --  Every part done, the failures left for Finished to tell.
      entry Quiet;
   private
      Left : Natural := 0;
      Bad  : Boolean := False;
   end Copy_Count;

   protected body Copying is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Copying;

   protected body Copy_Count is
      procedure Expect (Parts : Natural) is
      begin
         Left := Left + Parts;
      end Expect;

      procedure One_Done (Failed : Boolean := False) is
      begin
         if Left > 0 then
            Left := Left - 1;
         end if;
         Bad := Bad or else Failed;
      end One_Done;

      entry Finished (Failed : out Boolean) when Left = 0 is
      begin
         Failed := Bad;
         Bad := False;
      end Finished;

      entry Quiet when Left = 0 is
      begin
         null;
      end Quiet;
   end Copy_Count;

   procedure Settle_Copies is
   begin
      Copy_Count.Quiet;
   end Settle_Copies;

   task body Byte_Copier is
      To, Source : System.Address;
      Size       : Model_Runner.Bytes.Byte_Count;
      Past_Cache : Boolean;
   begin
      loop
         select
            accept Go
              (Into, From : System.Address; Length : Model_Runner.Bytes.Byte_Count;
               Direct : Boolean)
            do
               To := Into;
               Source := From;
               Size := Length;
               Past_Cache := Direct;
            end Go;
         or
            terminate;
         end select;

         --  A part that raised -- a page of a truncated mapping, a read past
         --  the cache refused -- is said done and failed, not left: a task
         --  ended without a word left every later large copy waiting on
         --  a count that would never come down.
         if Size > 0 then
            declare
               Read : Boolean := False;
            begin
               --  A read slowed past anything a device takes to start its
               --  work, which is how the work is checked to wait for it:
               --  a drive is otherwise quick enough to hide a submission
               --  that went first.
               if Past_Cache
                 and then Ada.Environment_Variables.Exists ("MR_SLOW_COPY")
               then
                  delay 0.05;
               end if;

               --  A file's mapping from the file itself, in large reads
               --  past the host's cache, where the host has them: three
               --  times what the mapping's faults read. See Read_Direct.
               if Past_Cache then
                  Model_Runner.Platform.Pages.Read_Direct
                    (Source, To, Size, Read);
               end if;
               if not Read then
                  declare
                     Target : Model_Runner.Bytes.Byte_Array (1 .. Size)
                       with Import, Address => To;
                     Origin : constant Model_Runner.Bytes.Byte_Array (1 .. Size)
                       with Import, Address => Source;
                  begin
                     Target := Origin;
                  end;
               end if;
               Copy_Count.One_Done;
            exception
               when others =>
                  Copy_Count.One_Done (Failed => True);
            end;
         else
            Copy_Count.One_Done;
         end if;
      end loop;
   end Byte_Copier;

   procedure Write_Bytes
     (Where  : Address;
      Values : Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean;
      Direct : Boolean := False) is
   begin
      Ok := False;

      if Where = Null_Handle then
         return;
      end if;

      --  A matrix of a megabyte or more is copied eight ways at once. The
      --  copy into fresh device memory is not the memory's speed but the
      --  host's faults: the first touch of each page of the mapping, and of
      --  the file's where it is mapped and not yet read, and a second copy
      --  into the same buffer took a twelfth of the first. Several of them
      --  overlap: Steelman-14B's first prompt, which uploads its 8 GiB,
      --  18.5-25.2 s one way, 9.8-10.8 four ways, 7.3-8.3 eight; Qwen3.5's
      --  first picture 0.231, 0.209, 0.189 s, and 0.20 sixteen ways.
      --
      --  One read from the file past the cache goes as many ways as it has
      --  eighth-megabyte pieces, up to eight, from a quarter of a megabyte:
      --  a drive answers reads in flight together, and one read at a time
      --  of a matrix under a megabyte went through the mapping's faults at
      --  a quarter of a gigabyte a second -- 0.49 s of Qwen3.6's first
      --  prompt, in 197 matrices of 133 MB.
      declare
         Room : Model_Runner.Bytes.Byte_Array (Values'Range)
           with Import, Address => Where;
         Least_Piece : constant := 131_072;
         --  A read from the file is not waited for here. The device is
         --  handed nothing until it is done (Hand_Over), and meanwhile
         --  the next matrix's reads go out beside it: one matrix at a time
         --  kept fewer than three reads in flight, where the drive answers
         --  eight together at nearly four times the speed. Only from a
         --  file's mapping, which stands while the model is open; any
         --  other source may be gone once this returns.
         Behind : constant Boolean :=
           Direct
           and then Model_Runner.Platform.Mapped_Ranges.Holds
                      (Values'Address, Values'Length);
         Ways : constant Positive :=
           (if Direct
            then Positive'Max
                   (1, Positive'Min
                         (Copiers'Length,
                          Natural (Values'Length / Least_Piece)))
            else Copiers'Length);
         Failed : Boolean := False;
      begin
         if Values'Length < (if Direct then 2 * Least_Piece else 1_048_576)
         then
            Room := Values;
         else
            declare
               Step : constant Model_Runner.Bytes.Byte_Count :=
                 (Values'Length + Model_Runner.Bytes.Byte_Count (Ways) - 1)
                 / Model_Runner.Bytes.Byte_Count (Ways);
            begin
               Copying.Seize;
               if Copiers (1) = null then
                  for K in Copiers'Range loop
                     Copiers (K) := new Byte_Copier;
                  end loop;
               end if;
               Copy_Count.Expect (Ways);
               for K in 1 .. Ways loop
                  declare
                     Lo : constant Model_Runner.Bytes.Byte_Count :=
                       Values'First + Model_Runner.Bytes.Byte_Count (K - 1) * Step;
                     Hi : constant Model_Runner.Bytes.Byte_Count :=
                       Model_Runner.Bytes.Byte_Count'Min (Values'Last, Lo + Step - 1);
                  begin
                     Copiers (Next_Copier).Go
                       (Room (Lo)'Address, Values (Lo)'Address,
                        (if Hi >= Lo then Hi - Lo + 1 else 0), Direct);
                     Next_Copier := Next_Copier mod Copiers'Length + 1;
                  end;
               end loop;
               if not Behind then
                  Copy_Count.Finished (Failed);
               end if;
               Copying.Release;
            exception
               when others =>
                  Copying.Release;
                  raise;
            end;
         end if;
         Ok := not Failed;
      end;
   end Write_Bytes;

   ---------------------------------------------------------------------------
   --  Making and releasing
   ---------------------------------------------------------------------------

   --  Its pipelines come out of the driver's own cache, a file a pipeline:
   --  a thousand files opened and unpacked, about a fifth of a second of
   --  every open. Measured and left: a pipeline cache of the program's own,
   --  kept in one file and given to every pipeline (RADV took it and read
   --  its own files all the same, and wrote them again), and Mesa's single-
   --  file cache (level, and its first open built every pipeline afresh,
   --  three minutes).
   procedure Open
     (Item       : in out Engine;
      On         : Context;
      Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0)
   is separate;

   --  Declared here because Close and Forget_Matrices need it and it is written below, with
   --  the other two of everything a submission holds.
   procedure Settle (Item : in out Engine; Ok : out Boolean);

   --  The copies in the background landed and their buffers given up,
   --  claimed or not: before the device they belong to goes.
   procedure Drop_Prefetches (Item : in out Engine);

   --------------------------
   -- Forget_Matrices --
   --------------------------

   procedure Forget_Matrices (Item : in out Engine) is
      --  Buffers belong to the instance that made them, so the entry points
      --  have to be the ones this engine was opened with.
      Ignored : constant Boolean := Set_Asking (Item);
      Settled : Boolean;
   begin
      --  Nothing in flight reads what goes: a sequence handed over without
      --  a wait, and the copies in the background -- one of a stack whose
      --  model's memory is freed after this would read freed host memory,
      --  and its buffer, matched by address and size alone, be handed to
      --  the next model whose stack lands where this one's was.
      Settle (Item, Settled);
      Drop_Prefetches (Item);

      --  Every slot ever given out, because a live entry keeps its slot
      --  and the ones between are the chain of free ones. On an engine
      --  that would not settle -- stalled, lost -- what was in flight may
      --  still read them, and they are left where they are rather than
      --  freed under it, as Release_All leaves its own; the table is
      --  forgotten all the same, so no later model's matrix is matched to
      --  one of these by an address its memory came to share.
      for Index in 1 .. Item.Slots_Given loop
         if Settled and then not Item.Stalled then
            Release_Weight
              (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory,
               Item.Kept (Index).Mapped);
         end if;
         Item.Kept (Index) := (others => <>);
      end loop;

      --  And the ones kept back for reuse, which are the device's memory
      --  as much as the matrices are.
      if Settled and then not Item.Stalled then
         for Index in 1 .. Item.Spare_Used loop
            Release_Weight
              (Item, Item.Spare (Index).Buffer, Item.Spare (Index).Memory,
               Item.Spare (Index).Mapped);
         end loop;
      end if;

      Item.Spare := [others => <>];
      Item.Spare_Used := 0;
      Item.Spare_Bytes := 0;

      Item.Used := 0;
      Item.Slots_Given := 0;
      Item.Free_Head := 0;
      Item.Newest := 0;
      Item.Oldest := 0;
      Item.Index_Of := [others => 0];
      Item.Kept_Bytes := 0;
      Item.Tier_Kept := [others => 0];
      Item.Tier_Spare := [others => 0];
   end Forget_Matrices;

   procedure Close (Item : in out Engine) is
      --  Whatever this engine was opened on, which is nothing at all for an
      --  engine that never was.
      Restore : constant Address := Instance_Of;

      procedure Give_Back (Handle : in out Address; Name : String) is
         Destroy : constant Destroy_Call := To_Destroy (Point (Name));
      begin
         if Handle /= Null_Handle
           and then Item.Logical /= Null_Handle
           and then Destroy /= null
         then
            Destroy (Item.Logical, Handle, Null_Handle);
         end if;
         Handle := Null_Handle;
      end Give_Back;
   begin
      --  A never-opened or refused Engine owns none of the package-wide copy
      --  and prefetch state and must not settle or clear another Engine's.
      if not Item.Owns_Slot then
         return;
      end if;

      Instance_Of := Item.Instance;
      Settle_Copies;

      --  Nothing may be in flight: what follows destroys the fences a
      --  submission is still holding, and gives back the memory it is still
      --  reading.
      declare
         Settled : Boolean;
      begin
         Settle (Item, Settled);
      end;

      if Item.Logical /= Null_Handle then
         Drop_Prefetches (Item);
      end if;

      --  Everything the device was holding for a model, then the two that
      --  change every call.
      for Index in 1 .. Item.Slots_Given loop
         Release_Weight
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory,
            Item.Kept (Index).Mapped);
         Item.Kept (Index) := (others => <>);
      end loop;
      for Index in 1 .. Item.Spare_Used loop
         Release_Weight
           (Item, Item.Spare (Index).Buffer, Item.Spare (Index).Memory,
            Item.Spare (Index).Mapped);
      end loop;

      Item.Spare := [others => <>];
      Item.Spare_Used := 0;
      Item.Spare_Bytes := 0;

      Item.Used := 0;
      Item.Slots_Given := 0;
      Item.Free_Head := 0;
      Item.Newest := 0;
      Item.Oldest := 0;
      Item.Index_Of := [others => 0];
      Item.Kept_Bytes := 0;
      Item.Tier_Kept := [others => 0];
      Item.Tier_Spare := [others => 0];
      Item.Tier_Limit := [others => 0];
      Item.Second := -1;
      Item.Clock := 0;
      Item.Released := 0;
      Item.Streamed := 0;
      Item.Taken := 0;
      Item.Heap := 0;

      --  A closed engine has given up on nothing. Forgetting this left an
      --  engine that had been given up on refusing every product after the
      --  next Open, on a device in perfect health.
      Item.Stalled := False;
      Item.Budget := 0;
      Item.Imports := False;
      Item.Import_To := 0;
      Item.Share := False;

      --  The cache goes back with them, and its mapping first.
      --
      --  It did not, and that was the whole of a corruption: Close released
      --  the two buffers above and left the cache allocated, still mapped,
      --  with Cache_At pointing into memory the device was about to take
      --  with it. Nothing showed while nothing called Reserve. The moment
      --  the engine wired attention up, a suite that opens and closes a
      --  device once a test went from passing to "malloc(): unaligned
      --  tcache chunk detected" -- and, in another run, to a glibc thread
      --  assertion, which is the same stale pointer surfacing wherever the
      --  allocator next looked.
      --
      --  The unmapping goes before the giving back, because unmapping
      --  memory that has already gone back is the same fault the other way
      --  round.
      declare
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
      begin
         if Item.Cache_At /= Null_Handle
           and then Unmap /= null
           and then Item.Logical /= Null_Handle
           and then Item.Cache_Memory /= Null_Handle
         then
            Unmap (Item.Logical, Item.Cache_Memory);
         end if;

         Item.Cache_At := Null_Handle;

         if Unmap /= null
           and then Item.Logical /= Null_Handle
           and then Item.Copy_Memory /= Null_Handle
         then
            Unmap (Item.Logical, Item.Copy_Memory);
         end if;

         Item.Copy_At := Null_Handle;

         if Unmap /= null
           and then Item.Logical /= Null_Handle
           and then Item.Copy_Values_Memory /= Null_Handle
         then
            Unmap (Item.Logical, Item.Copy_Values_Memory);
         end if;

         Item.Copy_Values_At := Null_Handle;
      end;

      if Item.Second_At /= Null_Handle
        and then Item.Logical /= Null_Handle
      then
         declare
            Unmap : constant Unmap_Call :=
              To_Unmap (Point ("vkUnmapMemory"));
         begin
            if Unmap /= null then
               Unmap (Item.Logical, Item.Second_Memory);
            end if;
         end;
      end if;
      Item.Second_At := Null_Handle;
      Give_Back_Buffer (Item, Item.Second_Buffer, Item.Second_Memory);
      Item.Second_Bytes := 0;

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
      Give_Back_Buffer
        (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);
      Item.Cache_Bytes := 0;
      Item.Copy_Bytes := 0;
      Item.Copy_Only := False;
      Item.Cache_Front := 0;
      --  All of what Release_Cache resets: an engine opened again after a
      --  close begins as one never opened, not split with a stale count.
      Item.Copy_Values_Bytes := 0;
      Item.Cache_Elements := 0;
      Item.Copy_Split := False;
      Item.Copy_Keys_Halves := 0;

      --  And the linear states' room, the same way.
      declare
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
      begin
         if Item.State_At /= Null_Handle
           and then Unmap /= null
           and then Item.Logical /= Null_Handle
           and then Item.State_Memory /= Null_Handle
         then
            Unmap (Item.Logical, Item.State_Memory);
         end if;

         Item.State_At := Null_Handle;
      end;

      Give_Back_Buffer (Item, Item.State_Buffer, Item.State_Memory);
      Item.State_Bytes := 0;

      Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
      Unmap_Standing (Item, Item.Turn_Memory, Item.Turn_At);
      Unmap_Standing (Item, Item.Turn_Memory_Two, Item.Turn_At_Two);
      Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
      Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
      Give_Back_Buffer (Item, Item.Turn_Buffer, Item.Turn_Memory);
      Give_Back_Buffer (Item, Item.Turn_Buffer_Two, Item.Turn_Memory_Two);
      Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
      Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
      Give_Back_Buffer (Item, Item.Round_Buffer, Item.Round_Memory);
      Item.Vector_Bytes := 0;
      Item.Turn_Bytes := 0;
      Item.Turn_Bytes_Two := 0;
      Item.Result_Bytes := 0;
      Item.Half_Bytes := 0;

      --  In the reverse of the order they were made, and each only if it
      --  was. The command buffer goes with its pool and the descriptor set
      --  with its own, so neither is given back on its own.
      Give_Back (Item.Fence, "vkDestroyFence");
      Item.Buffer := Null_Handle;
      Item.Buffer_Two := Null_Handle;

      --  Nothing is in flight.
      Item.Pending := False;
      Item.Pending_Two := False;
      Item.Sets_Two := [others => Null_Handle];
      Give_Back (Item.Commands, "vkDestroyCommandPool");
      Item.Descriptor := Null_Handle;
      Give_Back (Item.Fence_Two, "vkDestroyFence");
      Give_Back (Item.Queries, "vkDestroyQueryPool");
      Give_Back (Item.Queries_Two, "vkDestroyQueryPool");
      Item.Timing := False;
      Item.Line := (others => <>);
      Give_Back (Item.Pool, "vkDestroyDescriptorPool");
      Give_Back (Item.Tile_Line, "vkDestroyPipeline");
      Give_Back (Item.Group_Line, "vkDestroyPipeline");
      for Count in Row_Line_Array'Range loop
         Give_Back (Item.Row_Lines (Count), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Half_Group_Line, "vkDestroyPipeline");
      Give_Back (Item.Wave_Line, "vkDestroyPipeline");
      Give_Back (Item.Wave_Line5, "vkDestroyPipeline");
      Give_Back (Item.Wave_Line6, "vkDestroyPipeline");
      Give_Back (Item.Glu_Line, "vkDestroyPipeline");
      for Count in Many_Count loop
         Give_Back (Item.Many_Lines4 (Count), "vkDestroyPipeline");
         Give_Back (Item.Many_Lines5 (Count), "vkDestroyPipeline");
         Give_Back (Item.Many_Lines6 (Count), "vkDestroyPipeline");
         Give_Back (Item.Glu_Many_Lines (Count), "vkDestroyPipeline");
         Give_Back (Item.Dots_Lines (Count), "vkDestroyPipeline");
         Give_Back (Item.Dots_Lines5 (Count), "vkDestroyPipeline");
         Give_Back (Item.Dots_Lines6 (Count), "vkDestroyPipeline");
         Give_Back (Item.Glu_Dots_Lines (Count), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Long_Line6, "vkDestroyPipeline");
      Give_Back (Item.Mid_Line6, "vkDestroyPipeline");
      Give_Back (Item.Long_Line, "vkDestroyPipeline");
      Give_Back (Item.Long_Line5, "vkDestroyPipeline");
      for Packing in Low_Packing loop
         Give_Back (Item.Low_Wave_Lines (Packing), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Q8_Wave_Line, "vkDestroyPipeline");
      Give_Back (Item.Q8_Short_Line, "vkDestroyPipeline");
      Give_Back (Item.Q8_Glu_Line, "vkDestroyPipeline");
      Give_Back (Item.Q8_Glu_Short_Line, "vkDestroyPipeline");
      for Count in Q8_Count loop
         Give_Back (Item.Q8_Multi_Lines (Count), "vkDestroyPipeline");
         Give_Back (Item.Q8_Dots_Lines (Count), "vkDestroyPipeline");
      end loop;
      for Count in Multi_Count loop
         Give_Back (Item.Q8_Glu_Multi_Lines (Count), "vkDestroyPipeline");
         Give_Back (Item.Q8_Glu_Dots_Lines (Count), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.NL_Wave_Line, "vkDestroyPipeline");
      Give_Back (Item.MX_Wave_Line, "vkDestroyPipeline");
      Give_Back (Item.MX_Glu_Line, "vkDestroyPipeline");
      Give_Back (Item.XS_Wave_Line, "vkDestroyPipeline");
      for Packing in Weight_Packing loop
         for Count in Many_Count loop
            Give_Back (Item.Dots_Multi_Lines (Packing) (Count), "vkDestroyPipeline");
            Give_Back (Item.Wave_Multi_Lines (Packing) (Count),
                       "vkDestroyPipeline");
         end loop;
      end loop;
      Give_Back (Item.Q2K_Wave_Line, "vkDestroyPipeline");
      Give_Back (Item.Q3K_Wave_Line, "vkDestroyPipeline");
      for Packing in Legacy_Packing loop
         Give_Back (Item.Legacy_Wave_Lines (Packing), "vkDestroyPipeline");
      end loop;
      for Packing in Half_Packing loop
         Give_Back (Item.Half_Wave_Lines (Packing), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Low_Pipeline, "vkDestroyPipeline");
      Give_Back (Item.Low_Wide_Line, "vkDestroyPipeline");
      for Count in Item.Low_Row_Lines'Range loop
         Give_Back (Item.Low_Row_Lines (Count), "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Wide_Line, "vkDestroyPipeline");
      Give_Back (Item.Extra_Line, "vkDestroyPipeline");
      Give_Back (Item.Halved_Line, "vkDestroyPipeline");
      Give_Back (Item.Packed_Line, "vkDestroyPipeline");
      Give_Back (Item.Packed_Plain_Line, "vkDestroyPipeline");
      Give_Back (Item.Pack_Line, "vkDestroyPipeline");
      Give_Back (Item.Pack_Plain_Line, "vkDestroyPipeline");
      Give_Back (Item.Unpack_Line, "vkDestroyPipeline");
      Give_Back (Item.Bundle_Line, "vkDestroyPipeline");
      Give_Back (Item.Exact_Bundle_Line, "vkDestroyPipeline");
      Give_Back (Item.Pair_Bundle_Line, "vkDestroyPipeline");
      for Line of Item.Whole_Bundle_Line loop
         Give_Back (Line, "vkDestroyPipeline");
      end loop;
      for Lines of Item.Token_Lines loop
         for Line of Lines loop
            Give_Back (Line, "vkDestroyPipeline");
         end loop;
      end loop;
      for Lines of Item.Packed_Token_Lines loop
         for Line of Lines loop
            Give_Back (Line, "vkDestroyPipeline");
         end loop;
      end loop;
      Give_Back (Item.Token_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Packed_Token_Attend, "vkDestroyShaderModule");
      for Line of Item.Whole_Halved_Line loop
         Give_Back (Line, "vkDestroyPipeline");
      end loop;
      Give_Back (Item.Merge_Line, "vkDestroyPipeline");
      Give_Back (Item.Thin_Line, "vkDestroyPipeline");
      Give_Back (Item.Fold_Line, "vkDestroyPipeline");
      Give_Back (Item.F32_Tile_Line, "vkDestroyPipeline");
      Give_Back (Item.Invert_Line, "vkDestroyPipeline");
      Give_Back (Item.Narrow_Line, "vkDestroyPipeline");
      Give_Back (Item.Narrow_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_Five_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_Wide_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_Wide_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Low_Tile_Line, "vkDestroyPipeline");
      Give_Back (Item.Wider_Line, "vkDestroyPipeline");
      Give_Back (Item.Wider_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Wider_Low_Line, "vkDestroyPipeline");
      Give_Back (Item.Tap_Short_Line, "vkDestroyPipeline");
      Give_Back (Item.Tap_Tall_Line, "vkDestroyPipeline");
      Item.Tile_Plan.Mid_Ready := False;
      Item.Tile_Plan.Mid_Wide_Ready := False;
      Item.Tile_Plan.Wider_Ready := False;
      Give_Back (Item.Narrow_Low_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_Low_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_Wide_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_Wide_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Mid_Wide_Low_Line, "vkDestroyPipeline");
      for Index in 1 .. Item.Special_Count loop
         Give_Back (Item.Special_Line (Index), "vkDestroyPipeline");
      end loop;
      Item.Special_Count := 0;
      Give_Back (Item.Listed_Low_Line, "vkDestroyPipeline");
      Give_Back (Item.Halve_Line, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Line, "vkDestroyPipeline");
      Give_Back (Item.Attend_Line, "vkDestroyPipeline");
      Give_Back (Item.Blend_Line, "vkDestroyPipeline");
      Give_Back (Item.Pipeline, "vkDestroyPipeline");
      Give_Back (Item.Layout, "vkDestroyPipelineLayout");
      Give_Back (Item.Set_Layout, "vkDestroyDescriptorSetLayout");

      Give_Back (Item.Extra, "vkDestroyShaderModule");
      Give_Back (Item.Halver_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Packed_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Packed_Plain, "vkDestroyShaderModule");
      Give_Back (Item.Packer, "vkDestroyShaderModule");
      Give_Back (Item.Packer_Plain, "vkDestroyShaderModule");
      Give_Back (Item.Unpacker, "vkDestroyShaderModule");
      Give_Back (Item.Bundled_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Exact_Bundled_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Exact_Paired_Attend, "vkDestroyShaderModule");
      Give_Back (Item.Merger, "vkDestroyShaderModule");
      Give_Back (Item.Thinner, "vkDestroyShaderModule");
      Give_Back (Item.Folder, "vkDestroyShaderModule");
      Give_Back (Item.F32_Tiler, "vkDestroyShaderModule");
      Give_Back (Item.Inverter, "vkDestroyShaderModule");
      Give_Back (Item.Narrow, "vkDestroyShaderModule");
      Give_Back (Item.Narrow_More, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_More, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_Five, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_Wide, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_Wide_More, "vkDestroyShaderModule");
      Give_Back (Item.Low_Tile, "vkDestroyShaderModule");
      Give_Back (Item.Wider, "vkDestroyShaderModule");
      Give_Back (Item.Wider_More, "vkDestroyShaderModule");
      Give_Back (Item.Wider_Low, "vkDestroyShaderModule");
      Give_Back (Item.Tap_Short, "vkDestroyShaderModule");
      Give_Back (Item.Tap_Tall, "vkDestroyShaderModule");
      Give_Back (Item.Narrow_Low, "vkDestroyShaderModule");
      Give_Back (Item.Mid, "vkDestroyShaderModule");
      Give_Back (Item.Mid_More, "vkDestroyShaderModule");
      Give_Back (Item.Mid_Low, "vkDestroyShaderModule");
      Give_Back (Item.Mid_Wide, "vkDestroyShaderModule");
      Give_Back (Item.Mid_Wide_More, "vkDestroyShaderModule");
      Give_Back (Item.Mid_Wide_Low, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_Low, "vkDestroyShaderModule");
      Give_Back (Item.Halver, "vkDestroyShaderModule");
      Give_Back (Item.Matrix, "vkDestroyShaderModule");
      Give_Back (Item.Matrix_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wide_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Split_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Split_Narrow_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Split_Mid_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Split_Wider_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wider_Attend, "vkDestroyPipeline");
      Give_Back (Item.Latent_Attend, "vkDestroyPipeline");
      Give_Back (Item.Latent_Batch_Attend, "vkDestroyPipeline");
      Give_Back (Item.Latent_Split_Attend, "vkDestroyPipeline");
      Give_Back (Item.Latent_Packed_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Mid_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Deep_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wide_Deep_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wide_Deep8_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Mid_Deep_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wider_Deep_Attend, "vkDestroyPipeline");
      for Width in Item.Few_Attend'Range (1) loop
         for Many in Item.Few_Attend'Range (2) loop
            Give_Back (Item.Few_Attend (Width, Many), "vkDestroyPipeline");
         end loop;
      end loop;
      Give_Back (Item.Attend_Matrix, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Matrix_Wide, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Split, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Split_Narrow, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Split_Mid, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Split_Wider, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Matrix_Wider, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Latent, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Latent_Batch, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Latent_Split, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Latent_Packed, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Matrix_Mid, "vkDestroyShaderModule");
      Give_Back (Item.Query_Tile, "vkDestroyShaderModule");
      Give_Back (Item.Grouped, "vkDestroyShaderModule");
      Give_Back (Item.Attender, "vkDestroyShaderModule");
      Give_Back (Item.Norm_Line, "vkDestroyPipeline");
      Give_Back (Item.Norm_Round_Line, "vkDestroyPipeline");
      Give_Back (Item.Route_Line, "vkDestroyPipeline");
      Give_Back (Item.Mix_Line, "vkDestroyPipeline");
      Give_Back (Item.Bias_Line, "vkDestroyPipeline");
      Give_Back (Item.Pick_Line, "vkDestroyPipeline");
      Give_Back (Item.Assemble_Line, "vkDestroyPipeline");
      Give_Back (Item.Rwkv_Line, "vkDestroyPipeline");
      Give_Back (Item.Wkv_Line, "vkDestroyPipeline");
      Give_Back (Item.Mamba_Line, "vkDestroyPipeline");
      Give_Back (Item.Scan_Line, "vkDestroyPipeline");
      Give_Back (Item.Scan1_Line, "vkDestroyPipeline");
      Give_Back (Item.Conv_Line, "vkDestroyPipeline");
      Give_Back (Item.Rule_Line, "vkDestroyPipeline");
      Give_Back (Item.Held_Rule_Line, "vkDestroyPipeline");
      Give_Back (Item.Replay_Line, "vkDestroyPipeline");
      Give_Back (Item.Single_Rule_Line, "vkDestroyPipeline");
      Give_Back (Item.Heads_Line, "vkDestroyPipeline");
      Give_Back (Item.Turn_Line, "vkDestroyPipeline");
      Give_Back (Item.Place_Line, "vkDestroyPipeline");
      Give_Back (Item.Fetch_Line, "vkDestroyPipeline");
      Give_Back (Item.Normer, "vkDestroyShaderModule");
      Give_Back (Item.Round_Normer, "vkDestroyShaderModule");
      Give_Back (Item.Router, "vkDestroyShaderModule");
      Give_Back (Item.Mixer, "vkDestroyShaderModule");
      Give_Back (Item.Biaser, "vkDestroyShaderModule");
      Give_Back (Item.Picker, "vkDestroyShaderModule");
      Give_Back (Item.Assembler, "vkDestroyShaderModule");
      Give_Back (Item.Rwkver, "vkDestroyShaderModule");
      Give_Back (Item.Wkver, "vkDestroyShaderModule");
      Give_Back (Item.Mambaer, "vkDestroyShaderModule");
      Give_Back (Item.Scanner, "vkDestroyShaderModule");
      Give_Back (Item.Scanner1, "vkDestroyShaderModule");
      Give_Back (Item.Conver, "vkDestroyShaderModule");
      Give_Back (Item.Ruler, "vkDestroyShaderModule");
      Give_Back (Item.Held_Ruler, "vkDestroyShaderModule");
      Give_Back (Item.Single_Ruler, "vkDestroyShaderModule");
      Give_Back (Item.Replayer, "vkDestroyShaderModule");
      Give_Back (Item.Header, "vkDestroyShaderModule");
      Give_Back (Item.Turner, "vkDestroyShaderModule");
      Give_Back (Item.Placer, "vkDestroyShaderModule");
      Give_Back (Item.Fetcher, "vkDestroyShaderModule");
      Give_Back (Item.Blender, "vkDestroyShaderModule");
      Give_Back (Item.Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader5, "vkDestroyShaderModule");
      for Packing in Low_Packing loop
         Give_Back (Item.Low_Wave_Shaders (Packing), "vkDestroyShaderModule");
      end loop;
      Give_Back (Item.Q8_Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Q8_Short_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Q8_Glu_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Q8_Glu_Short_Shader, "vkDestroyShaderModule");
      for Count in Q8_Count loop
         Give_Back (Item.Q8_Multi_Shaders (Count), "vkDestroyShaderModule");
         Give_Back (Item.Q8_Dots_Shaders (Count), "vkDestroyShaderModule");
      end loop;
      for Count in Multi_Count loop
         Give_Back (Item.Q8_Glu_Dots_Shaders (Count), "vkDestroyShaderModule");
         Give_Back (Item.Q8_Glu_Multi_Shaders (Count),
                    "vkDestroyShaderModule");
      end loop;
      Give_Back (Item.NL_Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.MX_Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.MX_Glu_Shader, "vkDestroyShaderModule");
      Give_Back (Item.XS_Wave_Shader, "vkDestroyShaderModule");
      for Packing in Weight_Packing loop
         Give_Back (Item.Dots_Wave_Shaders (Packing), "vkDestroyShaderModule");
      end loop;
      Give_Back (Item.Q2K_Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Q3K_Wave_Shader, "vkDestroyShaderModule");
      for Packing in Legacy_Packing loop
         Give_Back (Item.Legacy_Wave_Shaders (Packing),
                    "vkDestroyShaderModule");
      end loop;
      for Packing in Half_Packing loop
         Give_Back (Item.Half_Wave_Shaders (Packing),
                    "vkDestroyShaderModule");
      end loop;
      Give_Back (Item.Low_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader6, "vkDestroyShaderModule");
      Give_Back (Item.Many_Shader4, "vkDestroyShaderModule");
      Give_Back (Item.Many_Shader5, "vkDestroyShaderModule");
      Give_Back (Item.Many_Shader6, "vkDestroyShaderModule");
      Give_Back (Item.Glu_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Glu_Many_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Dots_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Dots_Shader5, "vkDestroyShaderModule");
      Give_Back (Item.Dots_Shader6, "vkDestroyShaderModule");
      Give_Back (Item.Glu_Dots_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Round_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Round_Line, "vkDestroyPipeline");
      Give_Back (Item.Long_Shader6, "vkDestroyShaderModule");
      Give_Back (Item.Mid_Shader6, "vkDestroyShaderModule");
      Give_Back (Item.Long_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Long_Shader5, "vkDestroyShaderModule");
      Item.Matrices := False;

      Item.Logical := Null_Handle;
      Item.Queue := Null_Handle;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Download := 0;
      Item.Instance := Null_Handle;
      Item.Launch := Model_Runner.Platform.Device.Tuning.Default_Choices;

      --  Whoever was asking before this, if anyone was and its instance is
      --  still there. Close is called from Open, and Open has an instance
      --  of its own to go back to; an engine closed after the inventory it
      --  was made from would otherwise leave every later asker -- the
      --  keeper among them -- naming an instance that is gone.
      Instance_Of := (if Is_Live (Restore) then Restore else Null_Handle);
      Item.Owns_Slot := False;
      Engine_Slot.Release;
   end Close;

   function Is_Ready (Item : Engine) return Boolean
   is (Item.Pipeline /= Null_Handle and then Item.Fence /= Null_Handle
       and then not Item.Stalled);

   procedure Use_Tuning
     (Item     : in out Engine;
      Choices  : Model_Runner.Platform.Device.Tuning.Launch_Choices;
      Accepted : out Boolean)
   is
   begin
      Accepted :=
        Model_Runner.Platform.Device.Tuning.Is_Supported (Choices);
      if Accepted then
         Item.Launch := Choices;
      end if;
   end Use_Tuning;

   function Tuning_Of
     (Item : Engine)
      return Model_Runner.Platform.Device.Tuning.Launch_Choices
   is (Item.Launch);

   function Is_Stalled (Item : Engine) return Boolean is (Item.Stalled);

   function Readies_Heads (Item : Engine) return Boolean
   is (Item.Heads_Line /= Null_Handle);

   function Timed (Item : Engine) return Boolean is (Item.Timing);

   --  The integer walk standing in for the binary32 walk Row_Line binds
   --  for these, or none: see Round_Walks.
   function Dots_Line
     (Item : Engine; Packing : Weight_Packing; Count : Natural;
      Columns : Natural) return Address
   is (if Count not in Many_Count
         or else Columns mod 32 /= 0
         or else (Packing not in Packed_Q8_0 | Packed_IQ4_NL | Packed_MXFP4
                  and then Columns mod 256 /= 0)
         or else Columns > Round_Columns
       then Null_Handle
       elsif Item.Dots_Multi_Lines (Packing) (Count) /= Null_Handle
       then (if Row_Line (Item, Count, Packing, Columns)
                = Item.Wave_Multi_Lines (Packing) (Count)
             then Item.Dots_Multi_Lines (Packing) (Count)
             else Null_Handle)
       elsif Packing = Packed_Q8_0
       then (if Count in Q8_Count
               and then Row_Line (Item, Count, Packing, Columns)
                        = Item.Q8_Multi_Lines (Count)
             then Item.Q8_Dots_Lines (Count)
             else Null_Handle)
       elsif Packing = Packed_Q4_K
         and then Row_Line (Item, Count, Packing, Columns)
                  = Item.Many_Lines4 (Count)
       then Item.Dots_Lines (Count)
       elsif Packing = Packed_Q5_K
         and then Row_Line (Item, Count, Packing, Columns)
                  = Item.Many_Lines5 (Count)
       then Item.Dots_Lines5 (Count)
       elsif Packing = Packed_Q6_K
         and then Row_Line (Item, Count, Packing, Columns)
                  = Item.Many_Lines6 (Count)
       then Item.Dots_Lines6 (Count)
       else Null_Handle);

   procedure Round_Walks (Item : in out Engine; Rounding : Walk_Rounding)
   is
   begin
      Item.Rounding := Rounding;
   end Round_Walks;

   function Rounds_Walks (Item : Engine) return Walk_Rounding
   is (if Item.Round_Line = Null_Handle then Rounds_None else Item.Rounding);

   procedure Prefer_Halves (Item : in out Engine; On : Boolean) is
   begin
      Item.Halves := On and then Item.Halved_Line /= Null_Handle;
   end Prefer_Halves;

   function Prefers_Halves (Item : Engine) return Boolean is (Item.Halves);

   procedure Prefer_Exact_Attention (Item : in out Engine; On : Boolean) is
   begin
      Item.Exact_Attention := On;
   end Prefer_Exact_Attention;

   function Prefers_Exact_Attention (Item : Engine) return Boolean
   is (Item.Exact_Attention);

   --------------------------
   -- Prefer_Plain_Packing --
   --------------------------

   procedure Prefer_Plain_Packing (Item : in out Engine; On : Boolean) is
   begin
      Item.Plain_Packing := On or else Item.Packed_Line = Null_Handle;
   end Prefer_Plain_Packing;

   --  The packed kernels as bound: the shared-memory compilations where
   --  those are preferred or the only ones made, the subgroup ones else.
   function Packed_Pipeline (Item : Engine) return Address
   is (if Item.Plain_Packing then Item.Packed_Plain_Line
       else Item.Packed_Line);

   function Pack_Pipeline (Item : Engine) return Address
   is (if Item.Plain_Packing then Item.Pack_Plain_Line
       else Item.Pack_Line);

   function Last_Timeline (Item : Engine) return Timeline is (Item.Line);

   procedure Time_Steps (Item : in out Engine; On : Boolean; Ok : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);
      Create  : constant Create_Call := To_Create (Point ("vkCreateQueryPool"));
      Request : aliased Query_Pool_Create_Info;
      Made    : aliased Address := Null_Handle;
   begin
      Ok := False;

      if not On then
         Item.Timing := False;
         Ok := True;
         return;
      end if;

      --  Nothing to scale a stamp by is a device that writes none.
      if Item.Logical = Null_Handle or else Item.Tick <= 0.0
        or else Create = null
      then
         return;
      end if;

      --  One pool a slot, since a slot's stamps are read after its own
      --  fence and the other slot may be recording over its own by then.
      if Item.Queries = Null_Handle then
         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            return;
         end if;
         Item.Queries := Made;
      end if;

      if Item.Queries_Two = Null_Handle then
         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            return;
         end if;
         Item.Queries_Two := Made;
      end if;

      Item.Timing := True;
      Ok := True;
   end Time_Steps;

   function Waited (Item : Engine) return Natural is (Item.Waited);

   --  The code a Vulkan wait returns when the fence has not signalled yet.
   --  Anything else that is not success is a refusal, and asking again would
   --  only put the same question.
   Timeout_Result : constant Interfaces.C.int := 2;

   --  How long to ask a fence whether it is finished before waiting for it.
   --
   --  A submission here is a submit and a wait, and a generated token makes
   --  sixty-seven of them: three a layer, because the host normalizes,
   --  rotates and joins between the products and holds the activations
   --  itself. Waiting is a blocking call into the driver, and what it costs
   --  is not the device's work but the wake-up at the end of it -- the same
   --  thing the worker pool's own wake cost, and answered the same way.
   --
   --  Asked rather than waited for, up to this many turns, and then waited
   --  for as before. A device that has not finished inside the spin costs
   --  the spin and then blocks exactly as it used to; the cancellation
   --  bound and the stall path below are untouched, because both live in
   --  the wait that follows.
   Fence_Spin : constant := 1000;

   ---------------------------------------------------------------------------
   --  One product
   ---------------------------------------------------------------------------

   ---------------------
   -- Give_Back_Least --
   ---------------------

   -----------------------------
   -- The order and the index --
   -----------------------------

   --  Where a key starts probing.
   --
   --  A key is the address a matrix's weights begin at, which is aligned
   --  and therefore has zeros where a table would want variety. The shift
   --  and the multiply spread them; nothing here depends on the constant
   --  being any particular one, only on it being odd.
   function Start_At (Key : Address) return Natural is
      use type System.Storage_Elements.Integer_Address;

      Value : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64
          (System.Storage_Elements.To_Integer (Key) / 16);
   begin
      return Natural
        ((Value * 11_400_714_819_323_198_485) mod Index_Slots);
   end Start_At;

   --  The slot a matrix is held in, or zero.
   --
   --  A matrix is what it is, what shape it is and where it is, and all of
   --  that is compared -- which is what the walk this replaces did, and the
   --  reason it kept walking past an entry whose key matched and whose
   --  shape did not. Two matrices can share an address: a model with a tied
   --  output holds one under two names, and a caller that reuses storage
   --  can put another where one was. Stopping at the first key that matches
   --  found the wrong entry, missed, and kept the found one AND a second
   --  beside it -- which measured as a third of the speed at a budget that
   --  evicts, because the large matrices read every token stopped being
   --  found and the small ones read rarely stayed.
   function Index_Find
     (Item    : Engine;
      Key     : Address;
      Bytes   : Interfaces.Unsigned_64;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural) return Natural
   is
      Probe : Natural := Start_At (Key);
   begin
      for Step in 1 .. Index_Slots loop
         if Item.Index_Of (Probe) = 0 then
            return 0;
         end if;

         declare
            Held : Held_Matrix renames Item.Kept (Item.Index_Of (Probe));
         begin
            if Held.Key = Key
              and then Held.Bytes = Bytes
              and then Held.Packing = Packing
              and then Held.Rows = Rows
              and then Held.Columns = Columns
            then
               return Item.Index_Of (Probe);
            end if;
         end;

         Probe := (Probe + 1) mod Index_Slots;
      end loop;

      return 0;
   end Index_Find;

   --  Say that a key is held in a slot.
   procedure Index_Put (Item : in out Engine; Key : Address; Where : Natural)
   is
      Probe : Natural := Start_At (Key);
   begin
      for Step in 1 .. Index_Slots loop
         if Item.Index_Of (Probe) = 0 then
            Item.Index_Of (Probe) := Where;
            return;
         end if;

         Probe := (Probe + 1) mod Index_Slots;
      end loop;
   end Index_Put;

   --  Take a key out, and close the gap behind it.
   --
   --  Open addressing cannot leave a hole: a key that probed past this
   --  place would stop at the hole and be called absent. Every entry after
   --  it whose own start is at or before the hole moves back into it, which
   --  is the standard deletion and the reason this is not three lines.
   --
   --  The entry is the one pointing at Where, not the first with the key:
   --  two matrices may share a key -- the output head and the slice of it
   --  a draft reads, which begin at the same byte -- and dropping the
   --  other's entry would leave the evicted one's pointing at a slot that
   --  holds something else.
   procedure Index_Drop
     (Item  : in out Engine;
      Key   : Address;
      Where : Natural)
   is
      Hole  : Natural := Start_At (Key);
      Steps : Natural := 0;
   begin
      while Item.Index_Of (Hole) /= 0
        and then Item.Index_Of (Hole) /= Where
      loop
         Hole := (Hole + 1) mod Index_Slots;
         Steps := Steps + 1;
         exit when Steps > Index_Slots;
      end loop;

      if Item.Index_Of (Hole) /= Where or else Where = 0 then
         return;
      end if;

      Item.Index_Of (Hole) := 0;

      declare
         Probe : Natural := (Hole + 1) mod Index_Slots;
      begin
         while Item.Index_Of (Probe) /= 0 loop
            declare
               Ideal : constant Natural :=
                 Start_At (Item.Kept (Item.Index_Of (Probe)).Key);

               --  Whether the entry at Probe would still be found if it
               --  moved back into the hole: it would, unless its own start
               --  lies in the stretch between them.
               Moves : constant Boolean :=
                 (if Probe > Hole
                  then Ideal <= Hole or else Ideal > Probe
                  else Ideal <= Hole and then Ideal > Probe);
            begin
               if Moves then
                  Item.Index_Of (Hole) := Item.Index_Of (Probe);
                  Item.Index_Of (Probe) := 0;
                  Hole := Probe;
               end if;
            end;

            Probe := (Probe + 1) mod Index_Slots;
         end loop;
      end;
   end Index_Drop;

   --  Take an entry out of the order of use.
   procedure Unlink (Item : in out Engine; Where : Natural) is
      Newer : constant Natural := Item.Kept (Where).Newer;
      Older : constant Natural := Item.Kept (Where).Older;
   begin
      if Newer /= 0 then
         Item.Kept (Newer).Older := Older;
      else
         Item.Newest := Older;
      end if;

      if Older /= 0 then
         Item.Kept (Older).Newer := Newer;
      else
         Item.Oldest := Newer;
      end if;

      Item.Kept (Where).Newer := 0;
      Item.Kept (Where).Older := 0;
   end Unlink;

   --  Put an entry that is in no chain at the newest end.
   procedure Link_Front (Item : in out Engine; Where : Natural) is
   begin
      Item.Kept (Where).Older := Item.Newest;
      Item.Kept (Where).Newer := 0;

      if Item.Newest /= 0 then
         Item.Kept (Item.Newest).Newer := Where;
      end if;

      Item.Newest := Where;

      if Item.Oldest = 0 then
         Item.Oldest := Where;
      end if;
   end Link_Front;

   --  Put an entry already in the chain at the newest end, which is what
   --  using it means.
   --
   --  IT MUST BE IN THE CHAIN. Unlinking one that is not reads its links as
   --  zero, concludes from that that it is both the newest and the oldest,
   --  and sets both ends of the chain to nothing -- which orphans every
   --  other entry and leaves the eviction walking a chain of one. That is
   --  what a freshly taken slot looks like, and calling this on one measured
   --  as a third of the speed at a budget that evicts.
   procedure Touch (Item : in out Engine; Where : Natural) is
   begin
      if Item.Newest = Where then
         return;
      end if;

      Unlink (Item, Where);
      Link_Front (Item, Where);
   end Touch;

   --  A slot nothing is in, or zero when the table is full.
   procedure Take_Slot (Item : in out Engine; Where : out Natural) is
   begin
      if Item.Free_Head = 0 then
         --  Slots past the high-water mark have never been given out and
         --  are free by construction, which saves chaining every one of
         --  thirty-two thousand at the start.
         if Item.Slots_Given < Max_Resident then
            Item.Slots_Given := Item.Slots_Given + 1;
            Where := Item.Slots_Given;
            return;
         end if;

         Where := 0;
         return;
      end if;

      Where := Item.Free_Head;
      Item.Free_Head := Item.Kept (Where).Next_Free;
      Item.Kept (Where).Next_Free := 0;
   end Take_Slot;

   --  And back again.
   procedure Free_Slot (Item : in out Engine; Where : Natural) is
   begin
      Item.Kept (Where) := (others => <>);
      Item.Kept (Where).Next_Free := Item.Free_Head;
      Item.Free_Head := Where;
   end Free_Slot;

   --------------------
   -- Spare buffers --
   --------------------

   --  Take a buffer of exactly this size back, if one was kept.
   --
   --  Exactly, because a buffer is bound to its memory at a size and the
   --  device was told that size when it was made. A larger one would serve
   --  and would leave the difference unusable by anything else, which on a
   --  model that gives a matrix back for every matrix it takes is a leak
   --  spread over a run.
   procedure Take_Spare
     (Item   : in out Engine;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Mapped : out Address;
      Tier   : out Tier_Index;
      Found  : out Boolean) is
   begin
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Mapped := Null_Handle;
      Tier := 1;
      Found := False;

      for Index in reverse 1 .. Item.Spare_Used loop
         if Item.Spare (Index).Bytes = Bytes then
            Buffer := Item.Spare (Index).Buffer;
            Memory := Item.Spare (Index).Memory;
            Mapped := Item.Spare (Index).Mapped;
            Tier := Item.Spare (Index).Tier;
            Found := True;

            Item.Spare (Index) := Item.Spare (Item.Spare_Used);
            Item.Spare (Item.Spare_Used) := (others => <>);
            Item.Spare_Used := Item.Spare_Used - 1;
            Item.Spare_Bytes := Item.Spare_Bytes - Bytes;
            Item.Tier_Spare (Tier) := Item.Tier_Spare (Tier) - Bytes;
            return;
         end if;
      end loop;
   end Take_Spare;

   --  Keep a buffer rather than give it up. False where there is no room
   --  for it, and the caller gives it up as it always did.
   procedure Keep_Spare
     (Item   : in out Engine;
      Buffer : Address;
      Memory : Address;
      Mapped : Address;
      Bytes  : Interfaces.Unsigned_64;
      Tier   : Tier_Index;
      Kept   : out Boolean) is
   begin
      Kept := False;

      if Item.Spare_Used >= Max_Spare
        or else Buffer = Null_Handle
        or else Memory = Null_Handle
      then
         return;
      end if;

      Item.Spare_Used := Item.Spare_Used + 1;
      Item.Spare (Item.Spare_Used) := (Buffer, Memory, Bytes, Mapped, Tier);
      Item.Spare_Bytes := Item.Spare_Bytes + Bytes;
      Item.Tier_Spare (Tier) := Item.Tier_Spare (Tier) + Bytes;
      Kept := True;
   end Keep_Spare;

   --  Give one kept buffer up for real, which is what makes room when the
   --  budget is what binds rather than the driver.
   procedure Drop_Spare (Item : in out Engine; Gone : out Boolean) is
   begin
      Gone := False;

      if Item.Spare_Used = 0 then
         return;
      end if;

      declare
         Buffer : Address := Item.Spare (Item.Spare_Used).Buffer;
         Memory : Address := Item.Spare (Item.Spare_Used).Memory;
         Mapped : Address := Item.Spare (Item.Spare_Used).Mapped;
      begin
         Item.Spare_Bytes :=
           Item.Spare_Bytes - Item.Spare (Item.Spare_Used).Bytes;
         Item.Tier_Spare (Item.Spare (Item.Spare_Used).Tier) :=
           Item.Tier_Spare (Item.Spare (Item.Spare_Used).Tier)
           - Item.Spare (Item.Spare_Used).Bytes;
         Item.Spare (Item.Spare_Used) := (others => <>);
         Item.Spare_Used := Item.Spare_Used - 1;

         Release_Weight (Item, Buffer, Memory, Mapped);
      end;

      Gone := True;
   end Drop_Spare;

   --  Give back what one slot holds, and the slot.
   procedure Give_Back_Slot (Item : in out Engine; Oldest : Natural);

   --  Release the matrix least recently multiplied by, so that another can
   --  take its place.
   --
   --  Least recently used rather than first or last. A forward pass reads
   --  every matrix of the model once in the same order, so releasing the
   --  most recent would release the one wanted next, and releasing the first
   --  would release the one wanted after that. The one wanted longest ago is
   --  the one whose turn comes last.
   --
   --  Pinned says which matrices this may not touch: those wanted since
   --  that reading of the clock. A sequence acquires every matrix it names
   --  before it dispatches any of them, and within one sequence the matrix
   --  wanted longest ago is the one acquired first -- which is a matrix a
   --  later step of the same sequence is about to read. Releasing it leaves
   --  a descriptor pointing at a buffer that no longer exists, and the
   --  answer that comes back is not an answer. So a sequence pins what it
   --  has taken, and a budget too small for all of it fails to acquire
   --  rather than quietly overwriting itself: the caller is told, and does
   --  the work the way it did before.
   --
   --  @param Item Engine holding them.
   --  @param Gone True when one was released.
   --  @param Pinned Clock reading before which a matrix may be released.
   procedure Give_Back_Least
     (Item   : in out Engine;
      Gone   : out Boolean;
      Pinned : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last)
   is
      Oldest : Natural := 0;
   begin
      Gone := False;

      --  Among the ones that took budget, because those are the only ones
      --  releasing which makes room. An imported matrix is the host's own
      --  memory and giving it back frees none of the device's.
      --  From the oldest end of the order of use, which is where the
      --  answer is: this walked the whole table to find the smallest count
      --  and now takes the first entry the chain offers that may go.
      --
      --  An entry may not go while the sequence in flight is reading it,
      --  and those are the ones most recently used -- at the other end --
      --  so the walk stops almost at once. An imported matrix is the
      --  host's own memory and releasing it frees none of the device's.
      declare
         Look : Natural := Item.Oldest;
      begin
         while Look /= 0 loop
            if not Item.Kept (Look).Own
              and then Item.Kept (Look).Used_At <= Pinned
            then
               Oldest := Look;
               exit;
            end if;

            Look := Item.Kept (Look).Newer;
         end loop;
      end;

      if Oldest = 0 then
         return;
      end if;

      Give_Back_Slot (Item, Oldest);
      Gone := True;
   end Give_Back_Least;

   --------------------
   -- Give_Back_Slot --
   --------------------

   procedure Give_Back_Slot (Item : in out Engine; Oldest : Natural) is
   begin
      --  Kept rather than given up, where there is room to keep it: the
      --  next matrix taken is very often the same size, and asking the
      --  driver for memory is what this loop cost.
      declare
         Spared : Boolean := False;
      begin
         if not Item.Kept (Oldest).Own then
            Keep_Spare
              (Item, Item.Kept (Oldest).Buffer, Item.Kept (Oldest).Memory,
               Item.Kept (Oldest).Mapped, Item.Kept (Oldest).Bytes,
               Item.Kept (Oldest).Tier, Spared);
         end if;

         if not Spared then
            Release_Weight
              (Item, Item.Kept (Oldest).Buffer, Item.Kept (Oldest).Memory,
               Item.Kept (Oldest).Mapped);
         end if;
      end;

      Item.Released := Item.Released + 1;

      --  An imported matrix took none of the budget, so releasing it gives
      --  none back. Subtracting its bytes would make the budget grow every
      --  time one went, which on a model that does not fit is every token.
      if Item.Kept (Oldest).Own then
         Item.Taken := Item.Taken - 1;
      else
         Item.Kept_Bytes := Item.Kept_Bytes - Item.Kept (Oldest).Bytes;
         Item.Tier_Kept (Item.Kept (Oldest).Tier) :=
           Item.Tier_Kept (Item.Kept (Oldest).Tier)
           - Item.Kept (Oldest).Bytes;
      end if;

      --  Out of the order, out of the index, and the slot goes back on the
      --  chain of slots nothing is in. It used to move the last entry into
      --  the gap, which is fine for a table nothing points into and wrong
      --  for one that is indexed: the index would name a slot holding
      --  somebody else.
      Unlink (Item, Oldest);
      Index_Drop (Item, Item.Kept (Oldest).Key, Oldest);
      Free_Slot (Item, Oldest);
      Item.Used := Item.Used - 1;

   end Give_Back_Slot;

   ----------------------
   -- Give_Back_Matrix --
   ----------------------

   procedure Give_Back_Matrix (Item : in out Engine; Key : Address) is
      Look : Natural := Item.Oldest;
      Next : Natural;
   begin
      --  Nothing may be reading it: what is in flight settles first.
      declare
         Settled : Boolean;
      begin
         Settle (Item, Settled);
         if not Settled then
            return;
         end if;
      end;

      while Look /= 0 loop
         Next := Item.Kept (Look).Newer;
         if Item.Kept (Look).Key = Key and then not Item.Kept (Look).Own then
            Give_Back_Slot (Item, Look);
         end if;
         Look := Next;
      end loop;
   end Give_Back_Matrix;

   --------------
   -- Resident --
   --------------

   function Resident (Item : Engine) return Natural is (Item.Used);

   function Resident_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Kept_Bytes);

   function Capacity (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Budget);

   function Heaps (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Heap + Item.Second_Heap);

   function Heap_Budget (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Budget_Heaps);

   function Spare_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Spare_Bytes);

   procedure Drop_Spares (Item : in out Engine) is
      Gone : Boolean := True;
   begin
      while Gone loop
         Drop_Spare (Item, Gone);
      end loop;
   end Drop_Spares;

   procedure Fit_Budget
     (Item : in out Engine; Bytes : Interfaces.Unsigned_64)
   is
      --  The second heap is the host's memory as Open takes it: no more of
      --  it than leaves Host_Reserve available, where the host says what
      --  is. The host's budget for the device, which a fitting's room is
      --  counted from, does not see the panels, the kept pages or the
      --  host's own cache beside it, so the reserve is what keeps them.
      --  What the second heap holds already is out of what is available
      --  now, and counted back: a fitting made after the weights went over
      --  would otherwise take them for the host's and give them back.
      Available : constant Interfaces.Unsigned_64 :=
        Model_Runner.Platform.Available_Memory;
      Holding   : constant Interfaces.Unsigned_64 :=
        Item.Tier_Kept (2) + Item.Tier_Spare (2);
      Affords   : constant Interfaces.Unsigned_64 :=
        (if Available = 0 then Interfaces.Unsigned_64'Last
         elsif Available + Holding > Host_Reserve
         then Available + Holding - Host_Reserve
         else 0);
   begin
      Item.Tier_Limit (2) :=
        (if Item.Second >= 0
         then Interfaces.Unsigned_64'Min
                (Interfaces.Unsigned_64'Min (Bytes, Item.Second_Heap),
                 Affords)
         else 0);
      Item.Tier_Limit (1) :=
        Interfaces.Unsigned_64'Min (Bytes - Item.Tier_Limit (2), Item.Heap);
      Item.Budget := Item.Tier_Limit (1) + Item.Tier_Limit (2);
   end Fit_Budget;

   function Given_Back (Item : Engine) return Natural is (Item.Released);

   function Streamed_Copies (Item : Engine) return Natural is (Item.Streamed);

   function Weight_Copies (Item : Engine) return Natural is (Item.Copies);

   function Holds
     (Item    : Engine;
      Key     : System.Address;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural) return Boolean
   is (Key /= System.Null_Address
       and then Index_Find
                  (Item, Key,
                   Interfaces.Unsigned_64 (Rows) * Row_Bytes (Packing, Columns),
                   Packing, Rows, Columns) /= 0);

   -------------------
   -- Cached_Bytes --
   -------------------

   --  Both buffers: what the device holds for the context is the cache
   --  proper and its half-precision copy, and a reader asking how much
   --  of the device the context takes is asking about both.
   function Cached_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Cache_Bytes + Item.Copy_Bytes);

   function State_Room_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.State_Bytes);

   function Cached_Elements
     (Item : Engine) return Model_Runner.Numerics.Element_Count
   is (Model_Runner.Numerics.Element_Count (Item.Cache_Elements));

   --  Whether a buffer of this many bytes is past what the device said it
   --  will read. A device that stated nothing bounds nothing here: the
   --  request goes to the driver, which is where it went before anything
   --  asked.
   function Over_Limit
     (Item : Engine; Bytes : Interfaces.Unsigned_64) return Boolean
   is (Item.Storage > 0 and then Bytes > Item.Storage);

   function Imported (Item : Engine) return Natural is (Item.Taken);

   ----------------
   -- Byte_Limit --
   ----------------

   function Byte_Limit (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Storage);

   --------------
   -- Multiply --
   --------------

   ----------------
   -- Row_Bytes --
   ----------------

   function Row_Bytes
     (Packing : Weight_Packing; Columns : Natural)
      return Interfaces.Unsigned_64
   is
      --  Bytes a block takes, in the order Weight_Packing declares. A table
      --  rather than a case, because the shader's row_bytes is the same
      --  table and two lists side by side are easier to compare than two
      --  shapes of code.
      Block : constant array (Weight_Packing) of Interfaces.Unsigned_64 :=
        [Values_F32    => 4,
         Values_F16    => 2,
         Values_BF16   => 2,
         Packed_Q4_0   => 18,
         Packed_Q4_1   => 20,
         Packed_Q5_0   => 22,
         Packed_Q5_1   => 24,
         Packed_Q8_0   => 34,
         Packed_IQ4_NL => 18,
         Packed_Q2_K   => 84,
         Packed_Q3_K   => 110,
         Packed_Q4_K   => 144,
         Packed_Q5_K   => 176,
         Packed_Q6_K   => 210,
         Packed_IQ4_XS => 136,
         Packed_MXFP4  => 17,
         Packed_IQ3_S   => 110,
         Packed_IQ2_XXS => 66,
         Packed_IQ2_XS  => 74,
         Packed_IQ2_S   => 82,
         Packed_IQ3_XXS => 98,
         Packed_IQ1_S   => 50,
         Packed_IQ1_M   => 56,
         Packed_TQ1_0   => 54,
         Packed_TQ2_0   => 66,
         Packed_Q1_0    => 18,
         Packed_Q2_0    => 18,
         Packed_NVFP4   => 36];

      Per : constant Natural :=
        (case Packing is
            when Values_F32 | Values_F16 | Values_BF16 => 1,
            when Super_Packing                         => 256,
            when Packed_IQ3_S .. Packed_TQ2_0          => 256,
            when Packed_Q1_0                           => 128,
            when Packed_Q2_0 | Packed_NVFP4            => 64,
            when others                                => 32);
   begin
      --  A row is a whole number of blocks. A width that is not says the
      --  caller and the file disagree about the matrix, which is not a thing
      --  to round: zero refuses the product rather than computing one from
      --  bytes that mean something else.
      if Columns mod Per /= 0 then
         return 0;
      end if;

      return Interfaces.Unsigned_64 (Columns / Per) * Block (Packing);
   end Row_Bytes;

   ---------------------
   -- Acquire_Weights --
   ---------------------

   --  Put one matrix where the device can read it, and say how it got there.
   --
   --  Lifted out of the single product unchanged so that a sequence may do
   --  it once per step before anything is recorded. A product used to
   --  acquire its matrix and dispatch it in one breath, which is exactly
   --  what a run of products recorded together cannot do: every matrix has
   --  to be in place before the first dispatch is written down.
   --
   --  @param Item Ready engine.
   --  @param Weights Storage the matrix lies in.
   --  @param At_Byte Where in that storage the matrix begins.
   --  @param Packing How each row is packed.
   --  @param Rows Number of rows.
   --  @param Columns Number of columns.
   --  @param Weight_Bytes Bytes the matrix takes, as the caller computed it.
   --  @param Buffer Receives the device buffer holding it.
   --  @param Memory Receives the memory behind that buffer.
   --  @param Base Where in the buffer the matrix begins, which is not zero
   --    when the device took the host's own memory and had to align it.
   --  @param Borrowed True when the buffer belongs to this call and has to
   --    go back at the end of it rather than being kept.
   --  @param Ok False when the matrix could not be put anywhere.
   --  @param Key Identifies the matrix so it may be kept between calls.
   ---------------------------------------------------------------------------
   --  Copies in the background
   ---------------------------------------------------------------------------

   --  A matrix being copied, or copied, into a buffer of its own for the
   --  sequence that will name it: the next layer's expert stacks, while the
   --  device works through this layer's.
   Prefetch_Slots : constant := 8;

   subtype Prefetch_Index is Positive range 1 .. Prefetch_Slots;

   type Prefetched is record
      Used   : Boolean := False;
      Key    : System.Address := System.Null_Address;
      Buffer : Address := Null_Handle;
      Memory : Address := Null_Handle;
      Mapped : Address := Null_Handle;
      Tier   : Tier_Index := 1;
      Bytes  : Interfaces.Unsigned_64 := 0;
   end record;

   Prefetches : array (Prefetch_Index) of Prefetched;

   function Prefetches_Held return Natural is
      Held : Natural := 0;
   begin
      for Slot of Prefetches loop
         if Slot.Used then
            Held := Held + 1;
         end if;
      end loop;
      return Held;
   end Prefetches_Held;

   type Copy_Job is record
      Into  : System.Address := System.Null_Address;
      From  : System.Address := System.Null_Address;
      Bytes : Interfaces.Unsigned_64 := 0;
      Slot  : Prefetch_Index := 1;
      --  Which use of the slot the copy is for. A slot given up on after
      --  a copy took too long is used again, and the late copier's mark
      --  is the old use's, not the new one's.
      Round : Natural := 0;
   end record;

   type Copy_Jobs is array (1 .. Prefetch_Slots) of Copy_Job;

   --  The copies set up and not yet handed over.
   Waiting      : Copy_Jobs;
   Waiting_Held : Natural := 0;

   type Landing_Flags is array (Prefetch_Index) of Boolean;

   --  The copiers, each taking its share of every copy: one ran at 6.5
   --  GB/s, one core's copy rather than what the memory moves, and a layer
   --  of qwen3.6-35b-a3b's experts took it 70 ms against the device's 80
   --  for the layer before -- close behind, and moving its bytes all the
   --  while the device read its own. Two read that model's prompt of 1302
   --  at 426 tokens a second, four at 419, eight at 408, one at 402: past
   --  two the copies take more of the memory than they give back.
   Copier_Count : constant := 2;

   subtype Copier_Index is Positive range 1 .. Copier_Count;

   type Landing_Counts is array (Prefetch_Index) of Natural;

   --  Which slots' copies have landed: every copier's share of them.
   protected Landed is
      --  A new use of the slot, and which one it is.
      procedure Clear (Slot : Prefetch_Index; Round : out Natural);
      --  A copier's share of the slot's copy landed, for the use Round:
      --  a share of an earlier use -- a copy given up on and still going
      --  -- marks nothing, where it took a share off the new use's count
      --  and its half-copied buffer was taken for landed.
      procedure Mark (Slot : Prefetch_Index; Round : Natural; Good : Boolean);
      entry Wait (Prefetch_Index);
      function Copied (Slot : Prefetch_Index) return Boolean;
   private
      Left  : Landing_Counts := [others => 0];
      Fine  : Landing_Flags := [others => True];
      Use_Of : Landing_Counts := [others => 0];
   end Landed;

   protected body Landed is
      procedure Clear (Slot : Prefetch_Index; Round : out Natural) is
      begin
         Use_Of (Slot) := (if Use_Of (Slot) = Natural'Last then 1 else Use_Of (Slot) + 1);
         Round := Use_Of (Slot);
         Left (Slot) := Copier_Count;
         Fine (Slot) := True;
      end Clear;

      procedure Mark (Slot : Prefetch_Index; Round : Natural; Good : Boolean) is
      begin
         if Round /= Use_Of (Slot) or else Left (Slot) = 0 then
            return;
         end if;
         Left (Slot) := Left (Slot) - 1;
         Fine (Slot) := Fine (Slot) and then Good;
      end Mark;

      function Copied (Slot : Prefetch_Index) return Boolean
      is (Left (Slot) = 0 and then Fine (Slot));

      entry Wait (for Slot in Prefetch_Index) when Left (Slot) = 0 is
      begin
         null;
      end Wait;
   end Landed;

   --  The copiers: handed a layer's worth of copies at a time, each runs
   --  its share of them in order and marks each share as it lands.
   task type Copier (Share : Copier_Index) is
      entry Start (Jobs : Copy_Jobs; Count : Natural);
   end Copier;

   task body Copier is
      Held  : Copy_Jobs;
      Many  : Natural := 0;
   begin
      loop
         select
            accept Start (Jobs : Copy_Jobs; Count : Natural) do
               Held := Jobs;
               Many := Count;
            end Start;
         or
            terminate;
         end select;

         for Index in 1 .. Many loop
            declare
               Good : Boolean := True;
            begin
               declare
                  Whole : Copy_Job renames Held (Index);

                  --  This copier's share, in whole pages; the last takes
                  --  what the division leaves.
                  Piece : constant Interfaces.Unsigned_64 :=
                    Whole.Bytes / Copier_Count / 4096 * 4096;
                  First : constant Interfaces.Unsigned_64 :=
                    Piece * Interfaces.Unsigned_64 (Share - 1);
                  Job   : constant Copy_Job :=
                    (Into  => System.Storage_Elements."+"
                                (Whole.Into,
                                 System.Storage_Elements.Storage_Offset
                                   (First)),
                     From  => System.Storage_Elements."+"
                                (Whole.From,
                                 System.Storage_Elements.Storage_Offset
                                   (First)),
                     Bytes => (if Share = Copier_Count
                               then Whole.Bytes - First else Piece),
                     Slot  => Whole.Slot,
                     Round => Whole.Round);

                  subtype Room is Model_Runner.Bytes.Byte_Array
                    (1 .. Model_Runner.Bytes.Byte_Count (Job.Bytes));

                  Into : Room with Import, Address => Job.Into;
                  From : Room with Import, Address => Job.From;
               begin
                  Into := From;
               exception
                  when others =>
                     Good := False;
               end;

               Landed.Mark (Held (Index).Slot, Held (Index).Round, Good);
            end;
         end loop;
      end loop;
   end Copier;

   Copier_1 : Copier (1);
   Copier_2 : Copier (2);

   procedure Drop_Prefetches (Item : in out Engine) is
   begin
      --  Copies set up and never handed to the copiers -- a sequence that
      --  stopped between naming the next layer's stacks and starting it --
      --  will never land, and waiting for them below never ends: they are
      --  marked landed and wrong instead, every copier's share.
      for Index in 1 .. Waiting_Held loop
         for Share in Copier_Index loop
            Landed.Mark (Waiting (Index).Slot, Waiting (Index).Round, False);
         end loop;
      end loop;
      Waiting_Held := 0;
      for Slot in Prefetch_Index loop
         if Prefetches (Slot).Used then
            Landed.Wait (Slot);
            Release_Weight
              (Item, Prefetches (Slot).Buffer, Prefetches (Slot).Memory,
               Prefetches (Slot).Mapped);
            Prefetches (Slot) := (others => <>);
         end if;
      end loop;
   end Drop_Prefetches;

   --  Waited for and handed over, or none.
   procedure Take_Prefetched
     (Item   : in out Engine;
      Key    : System.Address;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Mapped : out Address;
      Tier   : out Tier_Index;
      Found  : out Boolean) is
   begin
      Found := False;
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Mapped := Null_Handle;
      Tier := 1;

      for Slot in Prefetch_Index loop
         if Prefetches (Slot).Used
           and then Prefetches (Slot).Key = Key
           and then Prefetches (Slot).Bytes = Bytes
         then
            --  A copy that has not landed in half a minute has gone wrong
            --  somewhere the copier cannot say -- a page of the file the
            --  disk would not give -- and the matrix is copied here as it
            --  was before. Its buffer is left where it is: the copier may
            --  still write it.
            select
               Landed.Wait (Slot);
            or
               delay 30.0;
               Prefetches (Slot) := (others => <>);
               return;
            end select;

            --  Landed and wrong: the buffer is the copier's no longer, and
            --  goes back; the matrix is copied here instead.
            if not Landed.Copied (Slot) then
               Release_Weight
                 (Item, Prefetches (Slot).Buffer, Prefetches (Slot).Memory,
                  Prefetches (Slot).Mapped);
               Prefetches (Slot) := (others => <>);
               return;
            end if;

            Buffer := Prefetches (Slot).Buffer;
            Memory := Prefetches (Slot).Memory;
            Mapped := Prefetches (Slot).Mapped;
            Tier := Prefetches (Slot).Tier;
            Prefetches (Slot) := (others => <>);
            Found := True;
            return;
         end if;
      end loop;
   end Take_Prefetched;

   --  Where a matrix is streamed rather than kept: an expert stack of a
   --  mixture the device does not hold, for a batch long enough that the
   --  device reading it beats the processor's pool. Nothing resident is
   --  given back to make room for it -- it would be the layer's own front
   --  half, uploaded again a layer later -- and it is not kept; its buffer
   --  goes back among the spares instead, mapped, for the next layer's
   --  stack of the same size, so that a stack costs its copy and nothing
   --  else. Mapped and Tier say where the caller hands it back.
   procedure Acquire_Weights_Streamed
     (Item         : in out Engine;
      Weights      : Model_Runner.Bytes.Byte_Array;
      At_Byte      : Model_Runner.Bytes.Byte_Count;
      Packing      : Weight_Packing;
      Rows         : Natural;
      Columns      : Natural;
      Weight_Bytes : Interfaces.Unsigned_64;
      Buffer       : out Address;
      Memory       : out Address;
      Base         : out Interfaces.Unsigned_64;
      Borrowed     : out Boolean;
      Ok           : out Boolean;
      Key          : System.Address;
      Pinned       : Interfaces.Unsigned_64;
      Stream       : Boolean;
      Mapped       : out Address;
      Tier         : out Tier_Index)
   is
      Weight_Buffer : Address renames Buffer;
      Weight_Memory : Address renames Memory;
      Weight_Base   : Interfaces.Unsigned_64 renames Base;
      Weight_Own    : Boolean := False;
      Weight_Mapped : Address renames Mapped;
      Weight_Tier   : Tier_Index renames Tier;
      Good          : Boolean;

      --  Whether a tier has room for this matrix beside what it holds,
      --  the buffers kept back for reuse counted with the matrices, as
      --  the one budget counted them before there were two.
      function Fits (Tier : Tier_Index) return Boolean
      is (Item.Tier_Kept (Tier) + Item.Tier_Spare (Tier) + Weight_Bytes
          <= Item.Tier_Limit (Tier));

      --  The first tier with room, or the first tier: a caller that named
      --  a budget past what the device holds is run rather than refused,
      --  and the driver's own answer is the only bound left.
      function Roomy_Tier return Tier_Index
      is (if Fits (1) or else Item.Second < 0 or else not Fits (2)
          then 1 else 2);
   begin
      Mapped := Null_Handle;
      Tier := 1;
      Weight_Buffer := Null_Handle;
      Weight_Memory := Null_Handle;
      Weight_Base := 0;
      Borrowed := False;
      Ok := True;

      --  Copied already, or being copied, in the background.
      if Stream and then Key /= System.Null_Address then
         declare
            Found : Boolean;
         begin
            Take_Prefetched
              (Item, Key, Weight_Bytes, Weight_Buffer, Weight_Memory, Mapped, Tier,
               Found);
            if Found then
               Borrowed := True;
               return;
            end if;
         end;
      end if;

      --  Is it already there? A matrix is what it is, what shape it is, and
      --  where it is. Every part of that is compared, because a caller that
      --  reuses storage would otherwise be handed somebody else's weights --
      --  and the byte count alone does not tell two matrices apart: two
      --  formats of the same width are the same length, and so are two
      --  shapes with the same number of elements.
      Item.Clock := Item.Clock + 1;

      if Key /= System.Null_Address then
         declare
            Index : constant Natural :=
              Index_Find (Item, Key, Weight_Bytes, Packing, Rows, Columns);
         begin
            if Index /= 0 then
               Weight_Buffer := Item.Kept (Index).Buffer;
               Weight_Memory := Item.Kept (Index).Memory;
               Weight_Base := Item.Kept (Index).Base;
               Weight_Own := Item.Kept (Index).Own;
               Weight_Mapped := Item.Kept (Index).Mapped;
               Item.Kept (Index).Used_At := Item.Clock;
               Touch (Item, Index);
            end if;
         end;
      end if;

      if Weight_Buffer = Null_Handle then
         --  Not resident, so room is about to be made: a matrix given back,
         --  a kept buffer written over. A caller that pins nothing -- one
         --  product at a time, a matrix held at load -- is one that will
         --  wait for its own work, and what may still be in flight is the
         --  sequence before it, which may be reading the very matrix about
         --  to go, or the buffer about to be written. So everything in
         --  flight finishes first. It used to be settled after acquiring,
         --  which is when the damage was already done: a model larger than
         --  the budget answered differently one run in six.
         if Pinned = Interfaces.Unsigned_64'Last then
            Settle (Item, Good);
            if not Good then
               Ok := False;
               return;
            end if;
         end if;

         --  Where the weights already are, when the caller asked for that.
         --
         --  It saves memory and never time, and the difference was measured
         --  rather than assumed. The same model and prompt on this machine:
         --  9.95 tokens a second with the weights copied to the device,
         --  2.59 with a budget holding a fifth of them and the rest uploaded
         --  again as they are wanted, and 0.80 read where they lie. So this
         --  is not the answer to a model that does not fit -- giving
         --  matrices back and uploading them again is three times better
         --  than that, which is the opposite of what this was written
         --  expecting -- it is the answer to a machine that cannot hold the
         --  model twice.
         --
         --  It costs no budget, because it is not the device's memory.
         if Item.Share
           and then Item.Imports
           and then Key /= System.Null_Address
         then
            Take_Host_Memory
              (Item,
               Whole => Weights (Weights'First)'Address,
               Span  => Interfaces.Unsigned_64 (Weights'Length),
               From  => Weights (Weights'First + At_Byte)'Address,
               Bytes => Weight_Bytes,
               Buffer => Weight_Buffer, Memory => Weight_Memory,
               Base => Weight_Base, Ok => Good);
            Weight_Own := Good;

            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
               Weight_Base := 0;
            end if;
         end if;

         if not Weight_Own then
            --  Room for it, then. A device with a heap smaller than the
            --  model used to take matrices until an allocation failed and
            --  then fail the product; now the matrix wanted longest ago
            --  goes back and this one takes its place.
            --  One that was given back and not given up, if it is the
            --  right size. A mixture's expert matrices are all one size, so
            --  on the model this was built for it always is.
            declare
               Found : Boolean;
            begin
               Take_Spare
                 (Item, Weight_Bytes, Weight_Buffer, Weight_Memory,
                  Weight_Mapped, Weight_Tier, Found);
               Good := Found;
            end;

            if Weight_Buffer = Null_Handle
              and then Key /= System.Null_Address and then Item.Budget > 0
              and then not Stream
            then
               declare
                  Gone : Boolean := True;

                  --  Room in some heap, rather than room in the total: two
                  --  heaps each a little short of a matrix add up to a
                  --  matrix and hold none.
                  function Room return Boolean
                  is (Fits (1) or else (Item.Second >= 0 and then Fits (2)));
               begin
                  --  The kept buffers first, because giving one of those up
                  --  costs nothing but the driver call, and a matrix given
                  --  back has to be uploaded again.
                  while Gone and then not Room loop
                     Drop_Spare (Item, Gone);
                  end loop;

                  Gone := True;

                  --  A matrix given back is kept as a spare, and a spare
                  --  counts against the budget as a kept matrix does: one
                  --  given back made no room, and the loop gave back up to
                  --  Max_Spare matrices still wanted before any memory
                  --  went. Each one given back is taken for this matrix
                  --  where it is the right size, and else given up, which
                  --  is what makes the room.
                  while Gone and then Item.Used > 0 and then not Room loop
                     Give_Back_Least (Item, Gone, Pinned);
                     if Gone then
                        declare
                           Found, Dropped : Boolean;
                        begin
                           Take_Spare
                             (Item, Weight_Bytes, Weight_Buffer, Weight_Memory,
                              Weight_Mapped, Weight_Tier, Found);
                           if Found then
                              Good := True;
                              exit;
                           end if;
                           loop
                              exit when Room;
                              Drop_Spare (Item, Dropped);
                              exit when not Dropped;
                           end loop;
                        end;
                     end if;
                  end loop;
               end;
            end if;

            if Weight_Buffer = Null_Handle then
               Weight_Tier := Roomy_Tier;
               Take (Item, Weight_Bytes, Weight_Buffer, Weight_Memory, Good,
                     Kind => (if Weight_Tier = 2 then Item.Second else -1));

               --  Mapped once, here, and kept for as long as the memory
               --  is: the copy below and every copy into this buffer after
               --  it writes through the pointer rather than asking again.
               if Good then
                  Map_Memory
                    (Item, Weight_Memory, Weight_Bytes, Weight_Mapped, Good);
               end if;
            end if;

            if not Good then
               Release_Weight
                 (Item, Weight_Buffer, Weight_Memory, Weight_Mapped);
               Ok := False;
               return;
            end if;

            --  Past the host's cache where the matrix is to be kept, as
            --  below: its file pages are given back once it is copied, so
            --  the cache would not have kept them. A matrix streamed, or
            --  borrowed for one call, is read again; the cache may answer
            --  that, and a read past it would ask the drive every time.
            Item.Copies := Item.Copies + 1;
            Write_Bytes
              (Weight_Mapped,
               Weights (Weights'First + At_Byte
                        .. Weights'First + At_Byte
                           + Model_Runner.Bytes.Byte_Count (Weight_Bytes) - 1),
               Good,
               Direct =>
                 Key /= System.Null_Address
                 and then not Stream
                 and then not Item.Keep_Pages
                 and then Item.Used < Max_Resident
                 and then (Item.Budget = 0
                           or else Item.Tier_Kept (Weight_Tier) + Weight_Bytes
                                   <= Item.Tier_Limit (Weight_Tier)));
            if not Good then
               Release_Weight
                 (Item, Weight_Buffer, Weight_Memory, Weight_Mapped);
               Ok := False;
               return;
            end if;
         end if;

         --  Kept if it was named and it fits, by count and by bytes.
         --  Otherwise it belongs to this call and goes back at the end of
         --  it: one matrix larger than the whole budget, on a device that
         --  will not take a host pointer, is the case that reaches this
         --  with nothing left to release, and it is handled the same way --
         --  computed, given back, correct.
         if Key /= System.Null_Address
           and then not Stream
           and then Item.Used < Max_Resident
           and then (Weight_Own
                     or else Item.Budget = 0
                     or else Item.Tier_Kept (Weight_Tier) + Weight_Bytes
                             <= Item.Tier_Limit (Weight_Tier))
         then
            declare
               Where : Natural;
            begin
               Take_Slot (Item, Where);

               Item.Used := Item.Used + 1;
               Item.Kept (Where) :=
                 (Key => Key, Buffer => Weight_Buffer,
                  Memory => Weight_Memory,
                  Bytes => Weight_Bytes, Used_At => Item.Clock,
                  Packing => Packing, Rows => Rows, Columns => Columns,
                  Base => Weight_Base, Own => Weight_Own,
                  Tier => Weight_Tier, Mapped => Weight_Mapped,
                  Newer => 0, Older => 0, Next_Free => 0);

               Index_Put (Item, Key, Where);
               Link_Front (Item, Where);
            end;

            --  Kept, so the mapping's copy is not read again: let its
            --  pages go rather than hold the matrix twice in the host's
            --  memory, which on a part whose device memory is the host's
            --  is also the device's. ThinkingCap's split ran a streamed
            --  layer for 13 to 30 s, its device pages swapped out beside
            --  eight gigabytes of mapped weights it had already copied.
            if not Weight_Own and then not Item.Keep_Pages then
               Model_Runner.Platform.Pages.Page_Out
                 (Weights (Weights'First + At_Byte)'Address,
                  Model_Runner.Bytes.Byte_Count (Weight_Bytes));
            end if;

            if Weight_Own then
               Item.Taken := Item.Taken + 1;
            else
               Item.Kept_Bytes := Item.Kept_Bytes + Weight_Bytes;
               Item.Tier_Kept (Weight_Tier) :=
                 Item.Tier_Kept (Weight_Tier) + Weight_Bytes;
            end if;
         else
            Borrowed := True;
         end if;
      end if;

   end Acquire_Weights_Streamed;

   procedure Acquire_Weights
     (Item         : in out Engine;
      Weights      : Model_Runner.Bytes.Byte_Array;
      At_Byte      : Model_Runner.Bytes.Byte_Count;
      Packing      : Weight_Packing;
      Rows         : Natural;
      Columns      : Natural;
      Weight_Bytes : Interfaces.Unsigned_64;
      Buffer       : out Address;
      Memory       : out Address;
      Base         : out Interfaces.Unsigned_64;
      Borrowed     : out Boolean;
      Ok           : out Boolean;
      Key          : System.Address;
      Pinned       : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Last)
   is
      Mapped : Address;
      Tier   : Tier_Index;
   begin
      Acquire_Weights_Streamed
        (Item, Weights, At_Byte, Packing, Rows, Columns, Weight_Bytes,
         Buffer, Memory, Base, Borrowed, Ok, Key, Pinned,
         Stream => False, Mapped => Mapped, Tier => Tier);
   end Acquire_Weights;

   --------------
   -- Prefetch --
   --------------

   procedure Prefetch
     (Item    : in out Engine;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Key     : System.Address)
   is
      Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Row_Bytes (Packing, Columns);

      Buffer : Address := Null_Handle;
      Memory : Address := Null_Handle;
      Mapped : Address := Null_Handle;
      Tier   : Tier_Index := 1;
      Good   : Boolean;
      Free   : Natural := 0;
   begin
      if not Is_Ready (Item)
        or else Waiting_Held >= Prefetch_Slots
        or else Key = System.Null_Address
        or else Bytes = 0
        or else Interfaces.Unsigned_64 (At_Byte) + Bytes
                > Interfaces.Unsigned_64 (Span)
      then
         return;
      end if;

      --  Held already, or on its way.
      if Index_Find (Item, Key, Bytes, Packing, Rows, Columns) /= 0 then
         return;
      end if;

      for Slot in Prefetch_Index loop
         if Prefetches (Slot).Used and then Prefetches (Slot).Key = Key then
            return;
         end if;
         if not Prefetches (Slot).Used and then Free = 0 then
            Free := Slot;
         end if;
      end loop;

      if Free = 0 then
         return;
      end if;

      Take_Spare (Item, Bytes, Buffer, Memory, Mapped, Tier, Good);
      if not Good then
         Take (Item, Bytes, Buffer, Memory, Good);
         if Good then
            Map_Memory (Item, Memory, Bytes, Mapped, Good);
         end if;
         if not Good then
            Release_Weight (Item, Buffer, Memory, Mapped);
            return;
         end if;
      end if;

      Prefetches (Free) :=
        (Used => True, Key => Key, Buffer => Buffer, Memory => Memory,
         Mapped => Mapped, Tier => Tier, Bytes => Bytes);
      declare
         Round : Natural;
      begin
         Landed.Clear (Free, Round);

         Waiting_Held := Waiting_Held + 1;
         Waiting (Waiting_Held) :=
           (Into  => Mapped,
            From  => System.Storage_Elements."+"
                       (Base, System.Storage_Elements.Storage_Offset (At_Byte)),
            Bytes => Bytes,
            Slot  => Free,
            Round => Round);
      end;
   end Prefetch;

   -----------------
   -- Prefetch_Go --
   -----------------

   procedure Prefetch_Go (Item : in out Engine) is
      pragma Unreferenced (Item);
   begin
      if Waiting_Held > 0 then
         Copier_1.Start (Waiting, Waiting_Held);
         Copier_2.Start (Waiting, Waiting_Held);

         Waiting_Held := 0;
      end if;
   end Prefetch_Go;

   ---------------------
   -- Submit_And_Wait --
   ---------------------

   --  Hand the recorded command buffer to the queue and wait for it.
   --
   --  Lifted out of the single product unchanged, so that a sequence which
   --  records several dispatches into one buffer waits once for all of them
   --  rather than once for each. Cleaning up whatever the caller borrowed is
   --  the caller's, which is why this reports rather than releases.
   --
   --  @param Item Ready engine, with a command buffer already recorded.
   --  @param Ok False when the device did not run it.
   --  @param Cancelled True when a caller asked to stop while it ran.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  Hand a recorded buffer over, without waiting for it.
   --
   --  It waits on what the submission before it signals and signals for the
   --  one after, because two submissions to one queue are not ordered
   --  against each other unless they are made to be -- and the sequence
   --  after this one reads what this one leaves at the front of the result
   --  buffer.
   --  Begin recording into a command buffer, ordered after everything
   --  submitted to the queue before it.
   --
   --  A submission used to wait on a semaphore the one before it signalled.
   --  That ordered them, and it also made the kernel's scheduler hold each
   --  submission until the one before had finished -- a round trip through
   --  the scheduler with the device idle, at every layer of every token:
   --  thirty-seven of them a qwen3-8b token, some two milliseconds of its
   --  seventy-three. A barrier at the head of the buffer orders it the same
   --  way from inside the queue -- its first scope is every command
   --  submitted earlier -- so the scheduler has nothing to wait for and the
   --  next submission is on the ring before the last one ends.
   function Opened
     (Buffer : Address;
      Start  : Begin_Call;
      Info   : Address) return C.int
   is
      use type C.unsigned;

      Answer : constant C.int := Start (Buffer, Info);
   begin
      if Answer = 0 then
         declare
            Barrier : constant Barrier_Call :=
              To_Barrier (Point ("vkCmdPipelineBarrier"));
            Wall : aliased Memory_Barrier :=
              (Wrote => Access_Shader_Write + Access_Transfer_Write,
               Reads => Access_Shader_Read + Access_Shader_Write
                        + Access_Transfer_Read + Access_Transfer_Write,
               others => <>);
         begin
            if Barrier = null then
               return -1;
            end if;

            Barrier
              (Buffer,
               Pipeline_Stage_Compute + Pipeline_Stage_Transfer,
               Pipeline_Stage_Compute + Pipeline_Stage_Transfer,
               0, 1, Wall'Address, 0, Null_Handle, 0, Null_Handle);
         end;
      end if;

      return Answer;
   end Opened;

   procedure Hand_Over (Item : in out Engine; Ok : out Boolean) is
      Submit : constant Submit_Call := To_Submit (Point ("vkQueueSubmit"));
      Reset  : constant Reset_Fences_Call :=
        To_Reset_Fences (Point ("vkResetFences"));

      Buffer_Handle : aliased Address := Item.Buffer;
      Fence_Handle  : aliased Address := Item.Fence;
      Request       : aliased Submit_Info;
      Torn          : Boolean;
   begin
      Ok := False;

      --  The matrices this work reads are in before it is handed over:
      --  their reads from the file were not waited for as they were asked.
      Copy_Count.Finished (Torn);
      if Torn then
         return;
      end if;

      if Submit = null or else Reset = null then
         return;
      end if;

      Request.Buffers := Buffer_Handle'Address;

      --  No semaphore: the barrier Opened put at the head of the buffer
      --  orders it after what came before, inside the queue.

      declare
         --  VK_ERROR_DEVICE_LOST: a device that is gone is gone for every
         --  sequence after this one too. Not marked, each of them was
         --  submitted, refused and done on the host a layer at a time.
         Device_Lost : constant C.int := -4;
         Result      : C.int := Reset (Item.Logical, 1, Fence_Handle'Address);
      begin
         if Result = 0 then
            Result := Submit (Item.Queue, 1, Request'Address, Item.Fence);
         end if;
         if Result /= 0 then
            if Result = Device_Lost then
               Item.Stalled := True;
            end if;
            return;
         end if;
      end;

      Item.Pending := True;
      Ok := True;
   end Hand_Over;

   --  The other of the two of everything a submission holds.
   procedure Swap_Slots (Item : in out Engine) is
      Buffer  : constant Address := Item.Buffer;
      Fence   : constant Address := Item.Fence;
      Pending : constant Boolean := Item.Pending;
      Sets    : constant Set_Array := Item.Sets;
   begin
      Item.Buffer := Item.Buffer_Two;
      Item.Fence := Item.Fence_Two;
      Item.Pending := Item.Pending_Two;
      Item.Sets := Item.Sets_Two;

      Item.Buffer_Two := Buffer;
      Item.Fence_Two := Fence;
      Item.Pending_Two := Pending;
      Item.Sets_Two := Sets;

      declare
         Began : constant Interfaces.Unsigned_64 := Item.Began;
      begin
         Item.Began := Item.Began_Two;
         Item.Began_Two := Began;
      end;

      declare
         Queries : constant Address := Item.Queries;
      begin
         Item.Queries := Item.Queries_Two;
         Item.Queries_Two := Queries;
      end;

      --  The angle table with the rest: the one the running sequence
      --  reads stays as it is while the next sequence writes the other.
      declare
         Buffer : constant Address := Item.Turn_Buffer;
         Memory : constant Address := Item.Turn_Memory;
         Bytes  : constant Interfaces.Unsigned_64 := Item.Turn_Bytes;
         Where  : constant Address := Item.Turn_At;
      begin
         Item.Turn_Buffer := Item.Turn_Buffer_Two;
         Item.Turn_Memory := Item.Turn_Memory_Two;
         Item.Turn_Bytes := Item.Turn_Bytes_Two;
         Item.Turn_At := Item.Turn_At_Two;
         Item.Turn_Buffer_Two := Buffer;
         Item.Turn_Memory_Two := Memory;
         Item.Turn_Bytes_Two := Bytes;
         Item.Turn_At_Two := Where;
      end;
   end Swap_Slots;

   --  Wait for what this slot last handed over, and nothing else.
   procedure Await
     (Item      : in out Engine;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference)
   is
   begin
      Ok := True;
      Cancelled := False;

      if not Item.Pending then
         return;
      end if;

      declare
         Wait   : constant Wait_Call := To_Wait (Point ("vkWaitForFences"));

         Ready  : constant Fence_Status_Call :=
           To_Fence_Status (Point ("vkGetFenceStatus"));

         Fence_Handle  : aliased Address := Item.Fence;
      begin
         if Wait = null then
            Ok := False;
            return;
         end if;

         --  Waited for in slices rather than in one go, for two reasons.
         --
         --  A caller can ask to stop. Cancellation is checked between
         --  layers everywhere else in this program, and a layer on a device
         --  is one of these waits, so a wait that cannot be interrupted is
         --  the longest a stop request goes unanswered. Slicing makes that
         --  a slice rather than a whole product.
         --
         --  And the bound was wrong. A single second was a bound on the
         --  wait, and a product larger than this machine's -- a wider model,
         --  a longer batch -- can legitimately take longer, so the bound
         --  refused work that was going perfectly well. Worse, it returned
         --  with the command buffer still executing and the next call would
         --  reset and record over it while the device was reading it. The
         --  slices make the whole bound generous, because a device that has
         --  stopped answering no longer holds the thread for the whole of
         --  it; and when the bound does expire the engine is finished with
         --  rather than reused, because there is no way to take work back
         --  off a device that is not responding.
         declare
            --  Nanoseconds, which is what a Vulkan wait counts in.
            Nanoseconds : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64'Max
                (1, Interfaces.Unsigned_64 (Item.Slice * 1_000_000_000.0));

            --  How many of those the whole bound holds. A caller who asks
            --  for no patience at all gets none: zero slices is a wait that
            --  does not happen, which is the only way to reach the giving-up
            --  path without a device that has genuinely stopped answering.
            --  Clamped, because a long patience divided by a short slice
            --  is a count no Natural holds: a minute of nanosecond slices
            --  is sixty thousand million of them. The clamp is what makes
            --  a caller who asks for both an ordinary caller rather than a
            --  Constraint_Error.
            Wanted : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64
                (Duration'Max (0.0, Item.Patience) * 1_000_000_000.0)
              / Nanoseconds;

            Slices : constant Natural :=
              (if Wanted > Interfaces.Unsigned_64 (Natural'Last)
               then Natural'Last
               else Natural (Wanted));

            Answered : Boolean := False;
            Stopped  : Boolean := False;
         begin
            Item.Waited := 0;

            --  Asked before it is waited for. A dispatch this engine sends
            --  is tens of microseconds of work and the wait around it is a
            --  blocking call; asking first is what the worker pool does for
            --  the same reason and answers here for the same one.
            if Ready /= null then
               for Turn in 1 .. Fence_Spin loop
                  Item.Waited := Turn;
                  exit when Ready (Item.Logical, Item.Fence) = 0;

                  --  The same question the wait below asks between its
                  --  slices, asked here as well. Without it a spin that
                  --  covers the whole of a short dispatch is a spin that
                  --  never notices a caller has asked to stop -- which is
                  --  what the test for a standing stop request found the
                  --  first time this was built, and is the only thing the
                  --  spin changed about what this procedure means.
                  if not Stopped
                    and then Turn mod 64 = 0
                    and then Model_Runner.Cancellation."/=" (Cancel, null)
                    and then Cancel.all.Is_Requested
                  then
                     Stopped := True;
                  end if;
               end loop;
            end if;

            for Attempt in 1 .. Slices loop
               Item.Waited := Item.Waited + 1;
               declare
                  Answer : constant Interfaces.C.int :=
                    Wait (Item.Logical, 1, Fence_Handle'Address, 1,
                          Nanoseconds);
               begin
                  if Answer = 0 then
                     Answered := True;
                     exit;
                  elsif Answer /= Timeout_Result then
                     --  A refusal rather than a timeout, and waiting again
                     --  would only ask the same question.
                     exit;
                  end if;
               end;

               --  Asked between slices and acted on after the device has
               --  finished, never instead of finishing: the buffers this
               --  dispatch is reading belong to it until the fence says
               --  otherwise, and giving them back sooner is how a cancelled
               --  run corrupts the next one.
               if not Stopped
                 and then Model_Runner.Cancellation."/=" (Cancel, null)
                 and then Cancel.all.Is_Requested
               then
                  Stopped := True;
               end if;
            end loop;

            if not Answered then
               --  The device did not finish inside the whole bound. Its
               --  buffers are still its own, so this engine is done: the
               --  caller is told, and nothing here touches them again.
               Item.Stalled := True;
               Ok := False;
               return;
            end if;

            Item.Pending := False;

            if Stopped then
               Cancelled := True;
               Ok := False;
               return;
            end if;
         end;
      end;

   end Await;

   procedure Submit_And_Wait
     (Item      : in out Engine;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference)
   is
   begin
      Cancelled := False;
      Hand_Over (Item, Ok);

      if not Ok then
         return;
      end if;

      Await (Item, Ok, Cancelled, Cancel);
   end Submit_And_Wait;

   -------------------
   -- Fetch_Carried --
   -------------------

   procedure Fetch_Carried
     (Item   : in out Engine;
      Target : out Model_Runner.Numerics.Real_Array;
      Ok     : out Boolean)
   is
      Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Target'Length) * 4;
   begin
      Ok := False;
      Target := [others => 0.0];

      if Item.Result_Buffer = Null_Handle or else Item.Result_Bytes < Bytes
      then
         return;
      end if;

      Settle (Item, Ok);
      if not Ok then
         return;
      end if;

      Standing (Item, Item.Result_Memory, Item.Result_At,
                Item.Result_Bytes, Ok);
      if not Ok then
         return;
      end if;

      declare
         Held : Model_Runner.Numerics.Real_Array (Target'Range)
           with Import, Address => Item.Result_At;
      begin
         Target := Held;
      end;
   end Fetch_Carried;

   --  Everything in flight finished, which is what the host must do before
   --  it writes anything a submission may still be reading -- the
   --  activation it sends over, a buffer it grows, a matrix it gives back.
   procedure Settle (Item : in out Engine; Ok : out Boolean) is
      Gone : Boolean;
   begin
      Ok := True;

      if Item.Pending then
         Await (Item, Ok, Gone, null);
         if not Ok then
            return;
         end if;
      end if;

      if Item.Pending_Two then
         Swap_Slots (Item);
         Await (Item, Ok, Gone, null);
         Swap_Slots (Item);
      end if;
   end Settle;

   ------------------
   -- Tile_Product --
   ------------------

   --  The two dispatches a tiled product is: the batch into half precision,
   --  a wall so that the copy is finished before it is read, and then the
   --  tiles.
   --
   --  Recorded into a command buffer the caller has already begun, and
   --  leaving the row product's pipeline bound behind it, because a
   --  sequence's next step may be a kernel that expects to find it there.
   --
   --  Fresh says whether the copy has to be made. A layer asks for seven
   --  products and hands only four activations to them -- the query, the
   --  key and the value read one normalization, the two feed-forward arms
   --  read another -- so three of the seven copies are of something the one
   --  before them already converted. The caller says so; this cannot tell,
   --  because what it is handed is a shape and a weight rather than which
   --  step's answer it is reading.
   --  The module a tile's pipeline was made from, or null for one this
   --  does not make again: the listed tiles bind their own, and the first
   --  compilation's six formats -- the half precisions, Q8_0 and the
   --  k-quants -- are left as they are: qwen3-8b's 24-token prompt read in
   --  0.193 s on them and 0.218 made for Q4_K and Q6_K.
   function Tile_Module (Item : Engine; Line : Address) return Address
   is (if Line = Null_Handle then Null_Handle
       elsif Line = Item.Extra_Line then Item.Extra
       elsif Line = Item.Narrow_More_Line then Item.Narrow_More
       elsif Line = Item.Low_Tile_Line then Item.Low_Tile
       elsif Line = Item.Narrow_Low_Line then Item.Narrow_Low
       elsif Line = Item.Mid_More_Line then Item.Mid_More
       elsif Line = Item.Mid_Low_Line then Item.Mid_Low
       elsif Line = Item.Mid_Wide_More_Line then Item.Mid_Wide_More
       elsif Line = Item.Mid_Wide_Low_Line then Item.Mid_Wide_Low
       elsif Line = Item.Wider_More_Line then Item.Wider_More
       elsif Line = Item.Wider_Low_Line then Item.Wider_Low
       else Null_Handle);

   --  A tile's pipeline made again for one format, the first time that
   --  format asks for it: the format told through the shader's constant
   --  FORMAT_FIXED, so that the driver drops every other format's decode.
   --  matrix_product.comp carries the measurements. The tile itself where
   --  it cannot be made, or the room for them is full.
   procedure Specialized_Tile
     (Item    : in out Engine;
      Line    : Address;
      Packing : Weight_Packing;
      Result  : out Address)
   is
      Module : constant Address := Tile_Module (Item, Line);
   begin
      Result := Line;
      if Module = Null_Handle then
         return;
      end if;

      for Index in 1 .. Item.Special_Count loop
         if Item.Special_Base (Index) = Line
           and then Item.Special_Packing (Index) = Packing
         then
            Result := Item.Special_Line (Index);
            return;
         end if;
      end loop;

      if Item.Special_Count = Special_Most then
         return;
      end if;

      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
         Pin     : aliased Required_Size_Info;
         Which   : aliased Specialization_Entry :=
           (Which => 0, At_Was => 0, Span => 4);
         Value   : aliased C.unsigned :=
           C.unsigned (Weight_Packing'Pos (Packing) + 1);
         Told    : aliased Specialization_Info;
         Made    : aliased Address := Null_Handle;
      begin
         if Create /= null then
            Pin.Required := Matrix_Lanes;
            Told.Count := 1;
            Told.Entries := Which'Address;
            Told.Span := 4;
            Told.Values := Value'Address;
            Request.Stage.Module := Module;
            Request.Stage.Name := Name;
            Request.Stage.Next := Pin'Address;
            Request.Stage.Flags := Require_Full_Subgroups;
            Request.Stage.Specialized := Told'Address;
            Request.Layout := Item.Layout;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Special_Count := Item.Special_Count + 1;
               Item.Special_Base (Item.Special_Count) := Line;
               Item.Special_Packing (Item.Special_Count) := Packing;
               Item.Special_Line (Item.Special_Count) := Made;
               Result := Made;
            end if;
         end if;
         C.Strings.Free (Name);
      end;
   end Specialized_Tile;

   procedure Tile_Product
     (Item    : in out Engine;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural;
      Room    : Natural;
      Packing : Weight_Packing;
      Base    : Interfaces.Unsigned_64;
      Fresh   : Boolean;

      --  How many values past its own vectors a fresh copy takes, for the
      --  taps after it that read from further on.
      Reach   : Interfaces.Unsigned_64;

      --  Where the answer goes in the half-precision buffer, in halves and
      --  plus one, or zero for the binary32 answer into the result buffer.
      Into    : Interfaces.Unsigned_64;

      --  Whether a join was folded into this product, so that what it
      --  stores is its answer plus the residual bound beside it.
      Joins   : Boolean;
      Good    : out Boolean;

      --  Where the operand begins in the half-precision buffer, in halves:
      --  the front but for a projection down whose gated middle the
      --  projection up wrote into its own region.
      From    : Interfaces.Unsigned_64 := 0;

      --  And for that projection up, where the gate arm is, in halves and
      --  plus one, and which unit goes on it: its answer is then the gated
      --  middle rather than the up arm. Zero for every other product.
      Gate_At : Interfaces.Unsigned_64 := 0;
      Unit    : Natural := 0;

      --  A 3x3's taps as one product: the values a padded row of the band
      --  holds, and the bytes from one tap's matrix to the next; nought
      --  for a plain product.
      Tap_Row   : Natural := 0;
      Tap_Bytes : Interfaces.Unsigned_64 := 0;

      --  Where a normed tap product's gain lies in the weights, in bytes
      --  and plus one, and its epsilon: the copy is then made normed
      --  (half_batch.comp's fourth way). Nought for a plain copy.
      Gain_At : Interfaces.Unsigned_64 := 0;
      Epsilon : Float := 0.0;

      --  A gather's members, each its own slice of the stack -- Slice bytes
      --  apart -- reading its own stretch of every vector, the members'
      --  stretches end to end, and answering into a run of its own, a
      --  member's every position before the next's. One for every other
      --  product. See matrix_product.comp's members[6].
      Members : Positive := 1;
      Slice   : Interfaces.Unsigned_64 := 0)
   is
      Bind_Pipeline : constant Bind_Pipeline_Call :=
        To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
      Push     : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
      Dispatch : constant Dispatch_Call :=
        To_Dispatch (Point ("vkCmdDispatch"));
      Barrier  : constant Barrier_Call :=
        To_Barrier (Point ("vkCmdPipelineBarrier"));

      Wall : aliased Memory_Barrier;

      --  What a vector of the copy holds: every member's stretch.
      Copy_Columns : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Members);

      Held : constant Interfaces.Unsigned_64 :=
        Copy_Columns * Interfaces.Unsigned_64 (Count) + Reach;
      Made : constant Interfaces.Unsigned_64 :=
        Copy_Columns * Interfaces.Unsigned_64 (Room) + Reach;
   begin
      Good := False;

      if Bind_Pipeline = null or else Push = null or else Dispatch = null
        or else Barrier = null
      then
         return;
      end if;

      if Fresh then
         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Halve_Line);

         if Gain_At > 0 then
            declare
               Words : Member_Words := [others => 0];
               Shape : aliased Shape_Constants;
            begin
               Words (0) := C.unsigned (Columns);
               Words (1) := Float_Bits (C.C_float (Epsilon));
               Shape :=
                 (Rows    => C.unsigned (Held),
                  Columns => C.unsigned (Made),
                  Base    => C.unsigned (Gain_At - 1),
                  Members => Words,
                  Routed  => 4,
                  others  => <>);
               Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                     Product_Bytes, Shape'Address);
               Dispatch
                 (Item.Buffer,
                  C.unsigned ((Made / Copy_Columns + 7) / 8), 1, 1);
            end;
         else
            declare
               --  The copying kernel reads the first two words as how many
               --  values the batch really holds and how many the copy is to
               --  hold. The rest of the block is nothing to it.
               Shape : aliased Shape_Constants :=
                 (Rows    => C.unsigned (Held),
                  Columns => C.unsigned (Made),
                  others  => <>);
            begin
               Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                     Product_Bytes, Shape'Address);
               Dispatch
                 (Item.Buffer,
                  C.unsigned ((Made / 2 + Group_Size - 1) / Group_Size), 1, 1);
            end;
         end if;

         Barrier
           (Item.Buffer, Pipeline_Stage_Compute, Pipeline_Stage_Compute,
            0, 1, Wall'Address, 0, Null_Handle, 0, Null_Handle);
      end if;

      --  Whichever of the four tiles decodes this format at this width.
      --  A narrow tile that the device refused leaves the batch on the wide
      --  one, which is what Whole_Tiles has to agree about -- so the width
      --  below is asked of the same function the room was rounded with.
      --  A long batch past a whole number of wide tiles by no more than a
      --  narrower one holds: the wide tiles over the whole of them, and the
      --  end on the narrower tile in a second dispatch, from the vector
      --  the first stopped at. Rounded up to a wide tile instead, a batch
      --  of 513 did the work of 768 -- a qwen3.6 layer's projections half
      --  as long again as at 512 -- and a long prompt's last batch of a
      --  few dozen paid a whole wide tile for them.
      --  And a batch past one tile of 128 by no more than the narrow tiles
      --  hold the same way: the tile of 128, then the rest on the narrow
      --  or the mid tile.
      declare
         Short_Split : constant Boolean :=
           Members = 1
           and then not Widened (Item, Count)
           and then Count in Tile_Vectors + 1 .. Tile_Vectors + Mid_Wide_Vectors
           and then Tile_Pipeline (Item, Packing, Count - Tile_Vectors)
                      /= Null_Handle;
         Rest : constant Natural :=
           (if Widened (Item, Count) then Count mod Wider_Vectors
            elsif Short_Split then Count - Tile_Vectors
            else 0);
         --  And past whole wider tiles by more than a tile of 128 and no
         --  more than the narrow tiles hold past that: the wider tiles, a
         --  tile of 128, and the rest on the narrow tiles -- three
         --  dispatches, where it rounded up to another wider tile. E4B's
         --  449-token prompt took 0.873 s and its 377-token one 0.640.
         Long_Split : constant Boolean :=
           Members = 1
           and then Widened (Item, Count)
           and then Count > Wider_Vectors
           and then Rest in Tile_Vectors + 1 .. Tile_Vectors + Mid_Wide_Vectors
           and then Tile_Pipeline (Item, Packing, Tile_Vectors) /= Null_Handle
           and then Tile_Pipeline (Item, Packing, Rest - Tile_Vectors)
                      /= Null_Handle;
         Split : constant Boolean :=
           Short_Split
           or else Long_Split
           or else (Members = 1
                    and then Rest > 0 and then Rest <= Tile_Vectors
                    and then Count > Wider_Vectors
                    and then Tile_Pipeline (Item, Packing, Rest) /= Null_Handle);
         Aligned : constant Natural := Count - (if Split then Rest else 0);

         --  The count whose tile takes the aligned part.
         Lead : constant Natural := (if Short_Split then Tile_Vectors else Count);

         --  A 3x3's taps on the first tile take the taps' own height
         --  where its rows are not a whole number of sixty-fours, or are of
         --  ninety-sixes: see Tap_Short_Rows.
         function Chosen (Pipeline : Address) return Address
         is (if Tap_Row = 0 or else Pipeline /= Item.Matrix_Line then Pipeline
             elsif Rows mod Tap_Tall_Rows = 0
               and then Item.Tap_Tall_Line /= Null_Handle
             then Item.Tap_Tall_Line
             elsif Rows mod Tile_Rows /= 0
               and then Item.Tap_Short_Line /= Null_Handle
             then Item.Tap_Short_Line
             else Pipeline);

         function Height (Pipeline : Address) return Natural
         is (if Pipeline = Item.Tap_Short_Line then Tap_Short_Rows
             elsif Pipeline = Item.Narrow_Line
               or else Pipeline = Item.Narrow_More_Line
               or else Pipeline = Item.Narrow_Low_Line
               or else Pipeline = Item.Mid_Line
               or else Pipeline = Item.Mid_More_Line
               or else Pipeline = Item.Mid_Low_Line
               or else Pipeline = Item.Mid_Wide_Line
               or else Pipeline = Item.Mid_Wide_More_Line
               or else Pipeline = Item.Mid_Wide_Low_Line
             then Narrow_Rows
             elsif Pipeline = Item.Tap_Tall_Line then Tap_Tall_Rows
             elsif Pipeline = Item.Wider_Line or else Pipeline = Item.Wider_More_Line
               or else Pipeline = Item.Wider_Low_Line
             then Wider_Rows
             else Tile_Rows);

         procedure Run_Tiles
           (Pipeline : Address; Vectors, Start, Groups : Natural)
         is
            Members : Member_Words := [others => 0];
         begin
            Members (2) := C.unsigned (Start);
            if Tap_Row > 0 then
               Members (3) := 9;
               Members (4) := C.unsigned (Tap_Bytes);
               Members (5) := C.unsigned (Tap_Row);
            end if;
            if Tile_Product.Members > 1 then
               Members (6) := C.unsigned (Slice);
               Members (7) := C.unsigned (Columns);
               Members (8) := C.unsigned (Copy_Columns);
               Members (9) := C.unsigned (Rows * Count);
            end if;
            declare
               Special : Address;
            begin
               Specialized_Tile (Item, Pipeline, Packing, Special);
               Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Special);
            end;
            declare
               Shape : aliased Shape_Constants :=
                 (Rows    => C.unsigned (Rows),
                  Columns => C.unsigned (Columns),
                  Count   => C.unsigned (Vectors),
                  First   => C.unsigned (Into),
                  Packing => C.unsigned (Weight_Packing'Pos (Packing)),
                  Base    => C.unsigned (Base),
                  Joins   => (if Joins then 1 else 0),
                  Table   => C.unsigned (Unit),
                  Members => Members,
                  Stride  => C.unsigned (From),
                  Apart   => C.unsigned (Gate_At),
                  others  => <>);
            begin
               Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                     Product_Bytes, Shape'Address);
               Dispatch
                 (Item.Buffer,
                  C.unsigned ((Rows + Height (Pipeline) - 1) / Height (Pipeline)),
                  C.unsigned (Groups), C.unsigned (Tile_Product.Members));
            end;
         end Run_Tiles;
      begin
         if Long_Split then
            Run_Tiles
              (Chosen (Tile_Pipeline (Item, Packing, Count)), Aligned, 0,
               Aligned / Tile_Width (Item, Count));
            Run_Tiles
              (Chosen (Tile_Pipeline (Item, Packing, Tile_Vectors)),
               Tile_Vectors, Aligned, 1);
            declare
               Last : constant Natural := Rest - Tile_Vectors;
            begin
               Run_Tiles
                 (Chosen (Tile_Pipeline (Item, Packing, Last)), Last,
                  Aligned + Tile_Vectors,
                  (Last + Tile_Width (Item, Last) - 1) / Tile_Width (Item, Last));
            end;
         elsif Split then
            Run_Tiles
              (Chosen (Tile_Pipeline (Item, Packing, Lead)), Aligned, 0,
               Aligned / Tile_Width (Item, Lead));
            Run_Tiles
              (Chosen (Tile_Pipeline (Item, Packing, Rest)), Rest, Aligned,
               (Rest + Tile_Width (Item, Rest) - 1) / Tile_Width (Item, Rest));
         else
            Run_Tiles
              (Chosen (Tile_Pipeline (Item, Packing, Count)), Count, 0,
               Room / Tile_Width (Item, Count));
         end if;
      end;

      Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));
      Good := True;
   end Tile_Product;

   --  Record whether one product's width excludes the widest tile.
   function Set_Narrow_For
     (Item    : in out Engine;
      Columns : Natural) return Boolean is
      Narrow : constant Boolean := Columns mod (2 * Wide_Step) /= 0;
   begin
      Item.Tile_Plan.Narrow_Run := Narrow;
      return Narrow;
   end Set_Narrow_For;

   -----------------
   -- One_Product --
   -----------------

   --  One matrix against one or more activations: the whole of what a
   --  product on a device is, unchanged. Both the single call and a
   --  sequence's Run reach the device through here, so there is one copy of
   --  the buffer handling, the descriptor update, the dispatch and the wait
   --  rather than two that could drift apart.
   procedure One_Product
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Positive;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Cancelled : out Boolean;
      Key     : System.Address := System.Null_Address;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null)
   is
      Elements : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Interfaces.Unsigned_64 (Columns);

      --  Whichever engine is being asked, because an entry point belongs to
      --  the instance behind it.
      Ignored : constant Boolean := Set_Asking (Item);
      Narrowed_Run : constant Boolean := Set_Narrow_For (Item, Columns);
      pragma Unreferenced (Narrowed_Run);

      Wide : constant Interfaces.Unsigned_64 := Row_Bytes (Packing, Columns);

      Weight_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Wide;
      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Count) * 4;

      --  What the matrix kernel would need: the batch rounded up to a whole
      --  tile, the room its answers take, and the half-precision copy of
      --  it. Worked out before the kernel is chosen because two of them
      --  are part of choosing -- a buffer larger than the device will bind
      --  is a refusal, and a refusal here should be the row product rather
      --  than a product that does not happen.
      Tiled_Room   : constant Natural := Whole_Tiles (Item, Count);
      Tiled_Result : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows)
        * Interfaces.Unsigned_64 (Tiled_Room) * 4;
      Tiled_Half   : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns)
        * Interfaces.Unsigned_64 (Tiled_Room) * 2;

      --  Which kernel, decided once: it changes how much room the answers
      --  need as well as which pipeline is bound.
      Tiled : constant Boolean :=
        Uses_Matrix (Item, Packing, Rows, Columns, Count)
        and then not Over_Limit (Item, Tiled_Result)
        and then not Over_Limit (Item, Tiled_Half);

      --  And whether its walk multiplies as integers, as a sequence's
      --  would: see Round_Walks.
      Rounds : constant Boolean :=
        not Tiled
        and then Rounds_Walks (Item) = Rounds_Every
        and then Dots_Line (Item, Packing, Count, Columns) /= Null_Handle;

      --  The batch as the kernel that will run wants it.
      Vectors_Room : constant Natural :=
        (if Tiled then Tiled_Room else Count);

      Result_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows)
        * Interfaces.Unsigned_64 (Vectors_Room) * 4;

      --  And the half-precision copy, which only the matrix kernel reads.
      Half_Bytes : constant Interfaces.Unsigned_64 :=
        (if Tiled
         then Interfaces.Unsigned_64 (Columns)
              * Interfaces.Unsigned_64 (Vectors_Room) * 2
         else 0);

      --  The matrix, kept when it has a key and made afresh when it has not.
      Weight_Buffer : Address := Null_Handle;
      Weight_Memory : Address := Null_Handle;
      Weight_Base   : Interfaces.Unsigned_64 := 0;
      Borrowed      : Boolean := False;

      procedure Release_Borrowed is
      begin
         --  Not while the device may still read it: see Release_All.
         if Borrowed and then not Item.Stalled then
            Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
            Borrowed := False;
         end if;
      end Release_Borrowed;

      Good : Boolean;
   begin
      Target := [others => 0.0];
      Ok := False;
      Cancelled := False;

      --  Asked before anything is uploaded or recorded, as well as between
      --  slices of the wait further down. A request that is already standing
      --  when the product is asked for costs the device nothing, and it is
      --  the only form of this a test can arrange: a request that arrives
      --  during a wait needs a wait long enough to arrive during.
      if Model_Runner.Cancellation."/=" (Cancel, null)
        and then Cancel.all.Is_Requested
      then
         Cancelled := True;
         return;
      end if;

      if not Is_Ready (Item)
        or else Rows = 0
        or else Columns = 0
        or else Wide = 0
        or else Elements > Max_Elements
        or else Interfaces.Unsigned_64 (Columns)
                  * Interfaces.Unsigned_64 (Count) > Max_Elements
        or else Over_Limit (Item, Weight_Bytes)
        or else Over_Limit (Item, Vector_Bytes)
        or else Over_Limit (Item, Result_Bytes)
        or else Interfaces.Unsigned_64 (Weights'Length)
                  < Interfaces.Unsigned_64 (At_Byte) + Weight_Bytes
        or else Vectors'Length
                  < Model_Runner.Numerics.Element_Count (Columns)
                    * Model_Runner.Numerics.Element_Count (Count)
        or else Target'Length
                  < Model_Runner.Numerics.Element_Count (Rows)
                    * Model_Runner.Numerics.Element_Count (Count)
      then
         return;
      end if;

      --  The matrix, wherever it has to be put to be read.
      Acquire_Weights
        (Item, Weights, At_Byte, Packing, Rows, Columns, Weight_Bytes,
         Weight_Buffer, Weight_Memory, Weight_Base, Borrowed, Good, Key);
      if not Good then
         return;
      end if;

      --  What is in flight is done with the shared buffers before any of
      --  them is grown or the activation written into them: a sequence
      --  handed over without a wait still reads the activation and writes
      --  the result and the halves.
      Settle (Item, Good);
      if not Good then
         Release_Borrowed;
         return;
      end if;

      --  The two that change every call, grown when they have to, and the
      --  size recorded what is there: nought between giving one back and
      --  taking the next.
      if Item.Vector_Bytes < Vector_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Item.Vector_Bytes := 0;
         Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
            Release_Borrowed;
            return;
         end if;
         Item.Vector_Bytes := Vector_Bytes;
      end if;

      if Item.Result_Bytes < Result_Bytes then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Item.Result_Bytes := 0;
         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
            Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
            Release_Borrowed;
            return;
         end if;
         Item.Result_Bytes := Result_Bytes;
      end if;

      --  Two regions of it, because a gated feed-forward has both its arms
      --  alive at once and the products that make them cannot both write at
      --  the front. Everything else uses the first and the second stands
      --  empty.
      Item.Half_Region := Half_Bytes;

      if Item.Half_Bytes < 3 * Half_Bytes then
         Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
         Item.Half_Bytes := 0;
         Take (Item, 3 * Half_Bytes,
               Item.Half_Buffer, Item.Half_Memory, Good);
         if not Good then
            Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
            Release_Borrowed;
            return;
         end if;
         Item.Half_Bytes := 3 * Half_Bytes;
      end if;

      if Rounds and then Item.Round_Buffer = Null_Handle then
         Take (Item, Round_Room, Item.Round_Buffer, Item.Round_Memory,
               Good);
         if not Good then
            --  Taken without its memory, the buffer was kept and bound at
            --  the next call, which saw it there and took no other.
            Give_Back_Buffer (Item, Item.Round_Buffer, Item.Round_Memory);
            Release_Borrowed;
            return;
         end if;
      end if;

      --  Still a map and an unmap of its own, unlike the read-back below.
      --  Keeping this one standing as well was written and measured and is
      --  not here: the results it produced were wrong -- the drafted device
      --  test, which runs a batched evaluator and a single-token one over
      --  the same weights, said the two disagreed -- and the cause was not
      --  found. What is known is that the read-back's standing mapping is
      --  correct and worth 1.66 times on a prompt, and that this one is a
      --  separate question with the same shape and a different answer.
      declare
         Wanted : Model_Runner.Numerics.Real_Array
           renames Vectors (Vectors'First
                            .. Vectors'First
                               + Model_Runner.Numerics.Element_Count (Columns)
                                 * Model_Runner.Numerics.Element_Count (Count)
                               - 1);
      begin
         Standing (Item, Item.Vector_Memory, Item.Vector_At,
                   Item.Vector_Bytes, Good);
         if Good then
            declare
               Room : Model_Runner.Numerics.Real_Array (Wanted'Range)
                 with Import, Address => Item.Vector_At;
            begin
               Room := Wanted;
            end;
         end if;
      end;
      if not Good then
         Release_Borrowed;
         return;
      end if;

      --  What the shader is pointed at.
      declare
         Update : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Buffers : constant array (1 .. 3) of Address :=
           [Weight_Buffer, Item.Vector_Buffer, Item.Result_Buffer];
         --  The weight buffer is longer than the matrix when the device
         --  took the host's memory: it starts at whatever boundary that
         --  memory had to be aligned to, and the shader is told how far in
         --  the matrix begins.
         Extent : constant array (1 .. 3) of Interfaces.Unsigned_64 :=
           [Weight_Base + Weight_Bytes, Vector_Bytes, Result_Bytes];

         Told  : aliased Buffer_Info_Array;
         Notes : aliased Write_Array;
      begin
         if Update = null then
            Release_Borrowed;
            return;
         end if;

         Told (4) := Half_Descriptor (Item);
         Told (5) := Told (3);

         Told (6) := Copy_Descriptor (Item);
         Told (7) :=
           (Buffer => Item.Round_Buffer, Offset => 0, Extent => Round_Bytes);

         for Index in Told'Range loop
            if Index in Buffers'Range then
               Told (Index).Buffer := Buffers (Index);
               Told (Index).Extent := Extent (Index);
            end if;

            Notes (Index).Target := Item.Descriptor;
            Notes (Index).Binding := C.unsigned (Index - 1);
            Notes (Index).Buffers := Told (Index)'Address;
         end loop;

         Update (Item.Logical, (if Rounds then 7 else 6), Notes'Address, 0,
                 Null_Handle);
      end;

      --  The work: one group per sixty-four rows, which is what the shader
      --  declares a group to be, and one dispatch per Row_Group vectors,
      --  which is what an invocation of the bound kernel carries. All of them in the one command
      --  buffer: they write disjoint parts of the result and wait for
      --  nothing, so what a longer batch costs is a dispatch and not a
      --  submission.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));

         Sets  : aliased Address := Item.Descriptor;
         Began : aliased Command_Begin_Info;
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            Release_Borrowed;
            return;
         end if;

         --  This path records into the same buffer a sequence may
         --  still be executing from, and waits for its own work, so
         --  everything in flight finishes first.
         declare
            Settled : Boolean;
         begin
            Settle (Item, Settled);

            if not Settled then
               return;
            end if;
         end;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Opened (Item.Buffer, Start, Began'Address) /= 0
         then
            Release_Borrowed;
            return;
         end if;

         Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));
         Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);

         if Tiled then
            Tile_Product
              (Item, Rows, Columns, Count, Vectors_Room, Packing,
               Weight_Base, Fresh => True, Reach => 0, Into => 0, Joins => False,
               Good => Good);

            if not Good then
               Release_Borrowed;
               return;
            end if;
         elsif Thin (Item, Packing, Rows, Columns, Count, Weight_Base) then
            --  The thin kernel, as a sequence would bind it for the same
            --  product: a call and a sequence answer the same bits.
            Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Thin_Line);

            declare
               Shape : aliased Shape_Constants :=
                 (Rows    => C.unsigned (Rows),
                  Columns => C.unsigned (Columns),
                  Count   => C.unsigned (Count),
                  First   => 0,
                  Packing => C.unsigned (Weight_Packing'Pos (Packing)),
                  Base    => C.unsigned (Weight_Base),
                  Joins   => 0, Table => 0, others => <>);
            begin
               Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                     Product_Bytes, Shape'Address);
               Dispatch (Item.Buffer, C.unsigned (Rows), C.unsigned (Count),
                         1);
            end;
         elsif F32_Tiled (Item, Packing, Rows, Count, Weight_Base) then
            Bind_Pipeline
              (Item.Buffer, Bind_Point_Compute, Item.F32_Tile_Line);

            declare
               Shape : aliased Shape_Constants :=
                 (Rows    => C.unsigned (Rows),
                  Columns => C.unsigned (Columns),
                  Count   => C.unsigned (Count),
                  First   => 0,
                  Packing => C.unsigned (Weight_Packing'Pos (Packing)),
                  Base    => C.unsigned (Weight_Base),
                  Joins   => 0, Table => 0, others => <>);
            begin
               Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                     Product_Bytes, Shape'Address);
               Dispatch (Item.Buffer, C.unsigned ((Rows + 63) / 64),
                         C.unsigned ((Count + 63) / 64), 1);
            end;
         else
            declare
               First : Natural := 0;
            begin
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count, Packing, Columns));

               --  The activations rounded first, for a walk that
               --  multiplies as integers.
               if Rounds then
                  declare
                     Barrier : constant Barrier_Call :=
                       To_Barrier (Point ("vkCmdPipelineBarrier"));
                     Wall : aliased Memory_Barrier;
                     Shape : aliased Shape_Constants :=
                       (Rows    => 0,
                        Columns => C.unsigned (Columns),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing => 0,
                        Base    => 0,
                        Joins   => 0,
                        Table   => 0,
                        others  => <>);
                  begin
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Item.Round_Line);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((Count * Columns / 32 + 63) / 64), 1, 1);
                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        Dots_Line (Item, Packing, Count, Columns));
                  end;
               end if;

               while First < Count loop
                  declare
                     Half  : constant Natural :=
                       Split_Half (Item, Packing, Count);
                     --  The vectors this dispatch's kernel carries: the
                     --  batch, or one walk's share of it.
                     Carry : constant Natural :=
                       (if Half = 0 then Count
                        elsif First = 0 then Half
                        else Count - Half);
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (Rows),
                        Columns => C.unsigned (Columns),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (First),
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (Packing)),
                        Base    => C.unsigned (Weight_Base),
                        Joins   => 0, Table => 0, others => <>);
                  begin
                     if Half > 0 then
                        Bind_Pipeline
                          (Item.Buffer, Bind_Point_Compute,
                           Row_Line (Item, Carry, Packing, Columns));
                     end if;
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Row_Reach (Item, Packing, Carry, Rows, Columns)
                              * Row_Lane_Count (Item, Packing, Carry)
                            + Row_Width (Item, Packing, Carry) - 1)
                           / Row_Width (Item, Packing, Carry)), 1, 1);

                     First := First
                       + (if Half > 0 then Carry else Row_Group (Item, Count));
                  end;
               end loop;
            end;
         end if;

         if Stop (Item.Buffer) /= 0 then
            Release_Borrowed;
            return;
         end if;
      end;

      --  Hand it over and wait.
      Submit_And_Wait (Item, Good, Cancelled, Cancel);
      if not Good then
         Release_Borrowed;
         return;
      end if;

      --  And what came out.
      declare
         Good_Map : Boolean;
      begin
         Standing (Item, Item.Result_Memory, Item.Result_At,
                   Item.Result_Bytes, Good_Map);
         if not Good_Map then
            Release_Borrowed;
            return;
         end if;

         declare
            Slice : Model_Runner.Numerics.Real_Array
              (Target'First
               .. Target'First
                  + Model_Runner.Numerics.Element_Count (Rows)
                    * Model_Runner.Numerics.Element_Count (Count) - 1)
              with Import, Address => Item.Result_At;
         begin
            Target (Slice'Range) := Slice;
         end;
      end;

      Release_Borrowed;
      Ok := True;
   end One_Product;

   -------------
   -- Reserve --
   -------------

   procedure Reserve_Exact
     (Item            : in out Engine;
      Elements        : Model_Runner.Numerics.Element_Count;
      Copy_Upto       : Model_Runner.Numerics.Element_Count;
      Ok              : out Boolean;
      Allow_Copy_Only : Boolean := False;
      Keys_Upto       : Model_Runner.Numerics.Element_Count := 0;
      Front           : Model_Runner.Numerics.Element_Count := 0)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      --  Four bytes an element for the cache and two for the
      --  half-precision copy the matrix kernel attends out of, in two
      --  buffers rather than one.
      --
      --  The copy is what makes that kernel worth having. Staging the
      --  binary32 cache into shared memory a tile at a time and converting
      --  it there was measured twice and cost more than the instruction
      --  saved: a second walk over the keys, which is one more staging and
      --  one more product, took a 1419-token prompt from 1.535 s to 1.785.
      --  Kept in halves, the keys and values are what the instruction
      --  reads and are loaded straight out of memory.
      --
      --  Apart, because a device states how much of one buffer a shader
      --  may be given and how large one allocation may be: six bytes an
      --  element reached both bounds at a context this program can be
      --  asked for, and four and two do not.
      Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;

      --  And the copy only as far as anything reads halves: a block kept
      --  packed uses the room a layer's rows unpack into, at the front of
      --  it, and not two bytes for every element of the block. A cache
      --  dealt to packed sessions used to carry a half of every element
      --  of every one of them, which is half again of what the blocks
      --  themselves take.
      --  Each in whole words: the device zeroes a buffer four bytes at a
      --  time, and a count of halves that was odd gave a size it would
      --  not fill to the end.
      Copy_Wanted : constant Interfaces.Unsigned_64 :=
        (Interfaces.Unsigned_64 (Copy_Upto) * 2 + 3) / 4 * 4;

      --  The keys' half of the copy and the values' half, in bytes, where
      --  the caller said in halves where the keys end. A whole number of
      --  the two makes the copy, so the values are what is left.
      Keys_Wanted : constant Interfaces.Unsigned_64 :=
        (Interfaces.Unsigned_64 (Keys_Upto) * 2 + 3) / 4 * 4;
      Values_Wanted : constant Interfaces.Unsigned_64 :=
        (if Copy_Upto >= Keys_Upto
         then (Interfaces.Unsigned_64 (Copy_Upto - Keys_Upto) * 2 + 3) / 4 * 4
         else 0);

      --  Split the copy in two -- keys apart from values -- where even the
      --  copy would not fit one storage buffer but its keys and its values
      --  each would. Only a copy-only session splits, and only where the
      --  caller said where the keys end. The environment variable forces
      --  it where the whole copy would fit, which is how the split is
      --  checked against the single buffer: the two hold the same halves at
      --  the same places, so they must answer identically.
      Split : constant Boolean :=
        Allow_Copy_Only
        and then Wants_Copy (Item)
        and then Copy_Wanted > 0
        and then Keys_Upto in 1 .. Copy_Upto - 1
        and then not Over_Limit (Item, Keys_Wanted)
        and then not Over_Limit (Item, Values_Wanted)
        and then
          (Ada.Environment_Variables.Exists ("MR_FORCE_SPLIT_COPY")
           or else Over_Limit (Item, Copy_Wanted));

      --  Keep only the copy where the caller allows it and the cache
      --  proper would not fit one storage buffer but the copy would --
      --  the copy is two bytes an element to the cache's four, so it
      --  reaches a context the cache does not. A split copy is a copy-only
      --  one as well: it too keeps no cache proper. The environment
      --  variable forces it at a context where both would fit, which is how
      --  the copy-only path is checked against the both-buffers one: for a
      --  sinkless model the cache proper is written and never read, so
      --  the two must answer identically.
      --  A paged cache kept as its copy and a front of binary32 words
      --  its tables are read out of: where the caller gives the front and
      --  allows the copy, and the device's attention reads halves -- the
      --  rows are then never read as binary32, and a buffer of them is
      --  four bytes an element nobody reads. Steelman-14B's 3,892
      --  positions took 2.7 GB of context, its copy a third of it. Kept so
      --  once it is: a call that gives no front -- a picture's attention,
      --  whose kernel reads the copy too -- extends the copy and keeps the
      --  front, and one that gives a front it may not keep so is refused
      --  below, since the rows already written are in the copy alone.
      Front_Active : constant Boolean :=
        Item.Copy_Only and then Item.Cache_Front > 0;
      Kept_Front : constant Interfaces.Unsigned_64 :=
        (if Front > 0 then Interfaces.Unsigned_64 (Front)
         elsif Front_Active then Item.Cache_Front
         else 0);
      Front_Copy : constant Boolean :=
        Kept_Front > 0
        and then (Allow_Copy_Only or else (Front = 0 and then Front_Active))
        and then Wants_Copy (Item)
        and then Copy_Wanted > 0
        and then Item.Halves
        and then not Over_Limit (Item, Copy_Wanted);

      Copy_Only : constant Boolean :=
        Split
        or else Front_Copy
        or else
          (Allow_Copy_Only
           and then Wants_Copy (Item)
           and then Copy_Wanted > 0
           and then not Over_Limit (Item, Copy_Wanted)
           and then
             (Ada.Environment_Variables.Exists ("MR_FORCE_COPY_ONLY")
              or else Over_Limit (Item, Wanted)));

      --  What the copy buffer holds and is mapped and filled to: the keys'
      --  half where the copy is split, the whole copy where it is not.
      --  What the binary32 buffer holds: the whole cache, the front alone
      --  where the copy and a front are kept, nothing where only the copy
      --  is.
      F32_Bytes : constant Interfaces.Unsigned_64 :=
        (if not Copy_Only then Wanted
         elsif Front_Copy then Kept_Front * 4
         else 0);

      Copy_Alloc : constant Interfaces.Unsigned_64 :=
        (if Split then Keys_Wanted else Copy_Wanted);

      --  What the buffers being replaced held, kept until the new ones
      --  have been made and mapped.
      Carry_Over     : Boolean := False;
      Carried        : Interfaces.Unsigned_64 := 0;
      Carried_Bytes  : Interfaces.Unsigned_64 := 0;
      Carried_Buffer : Address := Null_Handle;
      Carried_Memory : Address := Null_Handle;
      Carried_At     : Address := Null_Handle;

      Copy_Carried_At     : Address := Null_Handle;
      Copy_Carried_Buffer : Address := Null_Handle;
      Copy_Carried_Memory : Address := Null_Handle;
      Copy_Carried_Bytes  : Interfaces.Unsigned_64 := 0;
      Values_Carried_At     : Address := Null_Handle;
      Values_Carried_Buffer : Address := Null_Handle;
      Values_Carried_Memory : Address := Null_Handle;

      --  A reserve that cannot finish leaves the cache as it was: the new
      --  buffers given back, the old ones -- still mapped, still holding
      --  every session's rows -- in their place. It used to keep the new
      --  ones, half made, with sizes of nought, and the old ones nowhere:
      --  a retry at the exact size then came up zeroed and every other
      --  block attended over zeros. Not where the device stalled: what it
      --  was given is still its own.
      procedure Undo is
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
      begin
         Ok := False;
         if Item.Stalled then
            return;
         end if;
         if Unmap /= null then
            if Item.Cache_At /= Null_Handle then
               Unmap (Item.Logical, Item.Cache_Memory);
            end if;
            if Item.Copy_At /= Null_Handle then
               Unmap (Item.Logical, Item.Copy_Memory);
            end if;
            if Item.Copy_Values_At /= Null_Handle then
               Unmap (Item.Logical, Item.Copy_Values_Memory);
            end if;
         end if;
         Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
         Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
         Give_Back_Buffer (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);
         Item.Cache_Buffer := Carried_Buffer;
         Item.Cache_Memory := Carried_Memory;
         Item.Cache_At := Carried_At;
         Item.Copy_Buffer := Copy_Carried_Buffer;
         Item.Copy_Memory := Copy_Carried_Memory;
         Item.Copy_At := Copy_Carried_At;
         Item.Copy_Values_Buffer := Values_Carried_Buffer;
         Item.Copy_Values_Memory := Values_Carried_Memory;
         Item.Copy_Values_At := Values_Carried_At;
      end Undo;
   begin
      Ok := False;

      if not Is_Ready (Item) or else Elements = 0 then
         return;
      end if;

      --  A front that may not be kept as the copy, on a cache kept so: the
      --  rows written so far are in the copy alone, and a binary32 cache
      --  grown under them would hold none of them.
      if Front > 0 and then Front_Active and then not Front_Copy then
         return;
      end if;

      --  Past what the device said one storage buffer may hold, refused
      --  here rather than bound: the allocation goes through, the
      --  descriptor naming a range past the bound does not, and every
      --  read out of it is undefined. Phi-3 mini at its own 4,096 asks
      --  for 4.8 GB of context with the half-precision copy, on a part
      --  that reads 4 GiB of one buffer, and answered nonsense from the
      --  first token. Refused, the session keeps its context on the host
      --  and attends there, as one the device has no room for does; a
      --  packed cache is a quarter of the size and fits.
      --  A split copy is past the bound as a whole and under it in each
      --  half, so it is the two halves that are held against the bound, not
      --  the whole.
      if (not Copy_Only and then Over_Limit (Item, Wanted))
        or else (Wants_Copy (Item) and then Copy_Wanted > 0
                 and then not Split
                 and then Over_Limit (Item, Copy_Wanted))
      then
         return;
      end if;

      --  Already large enough is already done, so a caller may say this
      --  every layer without paying for it after the first. A change of
      --  mode -- the cache proper kept or not -- is not already done,
      --  however large what is there, because the kernels are told which
      --  to write by what this reserved.
      if Item.Cache_Bytes >= F32_Bytes
        and then Item.Cache_Front = (if Front_Copy then Kept_Front else 0)
        and then Item.Copy_Only = Copy_Only
        and then Item.Copy_Split = Split
        and then (if Split
                  then Item.Copy_Bytes >= Keys_Wanted
                       and then Item.Copy_Values_Bytes >= Values_Wanted
                  else (Item.Copy_Bytes >= Copy_Wanted
                        or else not Wants_Copy (Item)))
      then
         Ok := True;
         return;
      end if;

      --  A split copy is not made again in another shape: its values sit
      --  against its own keys' end, which a copy made whole or split
      --  elsewhere does not keep, and carrying its front would carry the
      --  keys alone. The block that asks attends on the host instead,
      --  and the one in it keeps what it holds.
      if Item.Copy_Split then
         return;
      end if;

      --  The old one is kept until the new one holds what it held. A cache
      --  is dealt out in blocks a session apiece, and a session's block is
      --  its keys and values as they stand, so a wider buffer that came up
      --  empty would make every session write its whole cache over again --
      --  which it did, and cost a third of a round of eight members the
      --  first time that round formed.
      declare
         Was_Buffer   : constant Address := Item.Cache_Buffer;
         Was_Memory   : constant Address := Item.Cache_Memory;
         Was_At       : constant Address := Item.Cache_At;
         Was_Elements : constant Interfaces.Unsigned_64 :=
           Item.Cache_Elements;
         Was_Bytes    : constant Interfaces.Unsigned_64 := Item.Cache_Bytes;

         Was_Copy_Buffer : constant Address := Item.Copy_Buffer;
         Was_Copy_Memory : constant Address := Item.Copy_Memory;
         Was_Copy_At     : constant Address := Item.Copy_At;

         Was_Values_Buffer : constant Address := Item.Copy_Values_Buffer;
         Was_Values_Memory : constant Address := Item.Copy_Values_Memory;
         Was_Values_At     : constant Address := Item.Copy_Values_At;

         --  What the copy held, in bytes, which is no longer two for
         --  every element of the cache: it reaches as far as halves are
         --  read and no further, so what is carried into the new one is
         --  bounded by both.
         Was_Copy_Bytes : constant Interfaces.Unsigned_64 := Item.Copy_Bytes;

         --  Where a new buffer cannot be had, the old ones back in their
         --  place, untouched: a retry carries them, and every block dealt
         --  out of them keeps its rows.
         procedure Give_Both_Back is
         begin
            Item.Cache_Buffer := Was_Buffer;
            Item.Cache_Memory := Was_Memory;
            Item.Cache_At := Was_At;
            Item.Copy_Buffer := Was_Copy_Buffer;
            Item.Copy_Memory := Was_Copy_Memory;
            Item.Copy_At := Was_Copy_At;
            Item.Copy_Values_Buffer := Was_Values_Buffer;
            Item.Copy_Values_Memory := Was_Values_Memory;
            Item.Copy_Values_At := Was_Values_At;
            Ok := False;
         end Give_Both_Back;
      begin
         Item.Cache_Buffer := Null_Handle;
         Item.Cache_Memory := Null_Handle;
         Item.Cache_At := Null_Handle;
         Item.Copy_Buffer := Null_Handle;
         Item.Copy_Memory := Null_Handle;
         Item.Copy_At := Null_Handle;
         Item.Copy_Values_Buffer := Null_Handle;
         Item.Copy_Values_Memory := Null_Handle;
         Item.Copy_Values_At := Null_Handle;

         --  The cache proper, unless only the copy is kept.
         if F32_Bytes > 0 then
            Take (Item, F32_Bytes, Item.Cache_Buffer, Item.Cache_Memory, Ok);
            if not Ok then
               Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
               Give_Both_Back;
               return;
            end if;
         end if;

         --  The copy only where something on this device would read it,
         --  and only as far as it is read -- the keys' half of it where it
         --  is split, the whole otherwise.
         if Wants_Copy (Item) and then Copy_Wanted > 0 then
            Take (Item, Copy_Alloc, Item.Copy_Buffer, Item.Copy_Memory, Ok);
            if not Ok then
               Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
               Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
               Give_Both_Back;
               return;
            end if;

            --  And the values' half, a buffer of its own, where the copy
            --  is split because the whole would not fit one.
            if Split then
               Take (Item, Values_Wanted,
                     Item.Copy_Values_Buffer, Item.Copy_Values_Memory, Ok);
               if not Ok then
                  Give_Back_Buffer
                    (Item, Item.Cache_Buffer, Item.Cache_Memory);
                  Give_Back_Buffer
                    (Item, Item.Copy_Buffer, Item.Copy_Memory);
                  Give_Back_Buffer
                    (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);
                  Give_Both_Back;
                  return;
               end if;
            end if;
         else
            Ok := True;
         end if;

         --  A cache kept as its copy alone has no binary32 buffer, and its
         --  copy is all it holds: carried as well. It was not -- the copy
         --  came up zeroed and the old one was left standing -- so a block
         --  dealt behind one, a Gemma 3 4B's at its unnamed context and its
         --  270M draft's, wiped the first one's keys and values and the
         --  drafted run wrote underscores.
         Carry_Over :=
           (Was_At /= Null_Handle and then Was_Elements > 0)
           or else (Was_Copy_At /= Null_Handle and then Was_Copy_Bytes > 0);
         Carried := Was_Elements;
         Carried_Bytes := Was_Bytes;
         Carried_Buffer := Was_Buffer;
         Carried_Memory := Was_Memory;
         Carried_At := Was_At;
         Copy_Carried_At := Was_Copy_At;
         Copy_Carried_Buffer := Was_Copy_Buffer;
         Copy_Carried_Memory := Was_Copy_Memory;
         Copy_Carried_Bytes := Was_Copy_Bytes;
         Values_Carried_At := Was_Values_At;
         Values_Carried_Buffer := Was_Values_Buffer;
         Values_Carried_Memory := Was_Values_Memory;
      end;

      --  Mapped here and left mapped. The kind this came from is
      --  host-coherent by the rule that chose it, so a write through this
      --  pointer is seen by the device without a flush.
      declare
         Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
         Where : aliased Address := Null_Handle;
      begin
         if Map = null then
            Undo;
            return;
         end if;

         if F32_Bytes > 0 then
            if Map (Item.Logical, Item.Cache_Memory, 0, F32_Bytes, 0,
                    Where'Access) /= 0
            then
               Undo;
               return;
            end if;

            Item.Cache_At := Where;
         end if;

         if Item.Copy_Buffer /= Null_Handle then
            if Map (Item.Logical, Item.Copy_Memory, 0, Copy_Alloc, 0,
                    Where'Access) /= 0
            then
               Undo;
               return;
            end if;

            Item.Copy_At := Where;
         end if;

         if Item.Copy_Values_Buffer /= Null_Handle then
            if Map (Item.Logical, Item.Copy_Values_Memory, 0, Values_Wanted, 0,
                    Where'Access) /= 0
            then
               Undo;
               return;
            end if;

            Item.Copy_Values_At := Where;
         end if;
      end;

      --  Zeroed, because the matrix kernel reads a whole tile of cached
      --  positions whether or not every position in it has been written:
      --  the scores of the ones past the end are masked to nothing, but a
      --  weight of zero against a value that was never written is zero
      --  times whatever was in that memory, and a not-a-number there
      --  survives the zero.
      --
      --  On the device rather than through the mapping. Written by the
      --  host, the zeroing faults in every page of the cache as it goes:
      --  seventeen milliseconds of a nineteen-millisecond reserve for the
      --  ninety megabytes a 2,048-token context of TinyLlama takes, paid
      --  by every session since a cache nobody holds is given back. The
      --  device writes its own memory at its own rate, and the pages the
      --  host touches are the ones it writes a position into.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Fill  : constant Fill_Call := To_Fill (Point ("vkCmdFillBuffer"));
         Copy_Buffer : constant Copy_Buffer_Call :=
           To_Copy_Buffer (Point ("vkCmdCopyBuffer"));
         Barrier : constant Barrier_Call :=
           To_Barrier (Point ("vkCmdPipelineBarrier"));

         Began : aliased Command_Begin_Info;

         Good, Cancelled : Boolean;
      begin
         --  What is in flight is using the command buffer this records
         --  into, and its own buffers: a reserve happens between layers,
         --  where the sequence before it may still be running.
         Settle (Item, Good);

         if not Good then
            Undo;
            return;
         end if;

         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Fill = null or else Copy_Buffer = null
           or else Barrier = null
           or else Reset_Buffer (Item.Buffer, 0) /= 0
           or else Opened (Item.Buffer, Start, Began'Address) /= 0
         then
            Undo;
            return;
         end if;

         if Item.Cache_Buffer /= Null_Handle then
            Fill (Item.Buffer, Item.Cache_Buffer, 0, F32_Bytes, 0);
         end if;

         if Item.Copy_Buffer /= Null_Handle then
            Fill (Item.Buffer, Item.Copy_Buffer, 0, Copy_Alloc, 0);
         end if;

         if Item.Copy_Values_Buffer /= Null_Handle then
            Fill (Item.Buffer, Item.Copy_Values_Buffer, 0, Values_Wanted, 0);
         end if;

         --  And what the buffers being replaced hold, carried into the
         --  front of the new ones: a cache is dealt out in blocks a
         --  session apiece, and a wider buffer that came up empty would
         --  make every session write its whole cache over again. Through
         --  the mappings this was the host reading the device's memory,
         --  which is the slowest thing per byte this program does; the
         --  device copies its own memory beside the fill.
         --
         --  Behind a barrier, because the fill wrote the same bytes and
         --  two transfers may run in either order.
         if Carry_Over then
            declare
               Wall : aliased Memory_Barrier :=
                 (Wrote  => Access_Transfer_Write,
                  Reads  => C.unsigned (Access_Transfer_Read
                                        + Access_Transfer_Write),
                  others => <>);

               --  No more than either buffer holds: a cache kept as its copy
               --  and a front has a binary32 buffer the front's length, and
               --  one grown from such a cache carries no more than that.
               Values : aliased Copy_Region :=
                 (From => 0, Into => 0,
                  Span =>
                    Interfaces.Unsigned_64'Min
                      (Interfaces.Unsigned_64'Min (Carried * 4, Carried_Bytes),
                       F32_Bytes));
               --  And no more than the new copy buffer was made: the keys'
               --  half alone where it is split.
               Halves : aliased Copy_Region :=
                 (From => 0, Into => 0,
                  Span =>
                    Interfaces.Unsigned_64'Min
                      (Interfaces.Unsigned_64'Min (Copy_Carried_Bytes, Copy_Wanted), Copy_Alloc));
            begin
               Barrier (Item.Buffer, Pipeline_Stage_Transfer,
                        Pipeline_Stage_Transfer, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);

               if Item.Cache_Buffer /= Null_Handle
                 and then Carried_Buffer /= Null_Handle
                 and then Values.Span > 0
               then
                  Copy_Buffer (Item.Buffer, Carried_Buffer, Item.Cache_Buffer,
                               1, Values'Address);
               end if;

               if Item.Copy_Buffer /= Null_Handle
                 and then Copy_Carried_Buffer /= Null_Handle
               then
                  Copy_Buffer (Item.Buffer, Copy_Carried_Buffer,
                               Item.Copy_Buffer, 1, Halves'Address);
               end if;
            end;
         end if;

         if Stop (Item.Buffer) /= 0 then
            Undo;
            return;
         end if;

         Submit_And_Wait (Item, Good, Cancelled, null);

         if not Good then
            Undo;
            return;
         end if;
      end;

      --  The old buffers, unmapped and given back. What they held is in
      --  the new ones already, carried there by the device beside the
      --  fill that zeroed the rest.
      if Carry_Over then
         declare
            Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
         begin
            if Unmap /= null then
               if Carried_Buffer /= Null_Handle then
                  Unmap (Item.Logical, Carried_Memory);
               end if;

               if Copy_Carried_At /= Null_Handle then
                  Unmap (Item.Logical, Copy_Carried_Memory);
               end if;

               if Values_Carried_At /= Null_Handle then
                  Unmap (Item.Logical, Values_Carried_Memory);
               end if;
            end if;
         end;

         Give_Back_Buffer (Item, Carried_Buffer, Carried_Memory);
         Give_Back_Buffer (Item, Copy_Carried_Buffer, Copy_Carried_Memory);
         Give_Back_Buffer (Item, Values_Carried_Buffer, Values_Carried_Memory);
      end if;

      Item.Cache_Bytes := F32_Bytes;
      Item.Cache_Front := (if Front_Copy then Kept_Front else 0);
      Item.Copy_Bytes :=
        (if Item.Copy_Buffer /= Null_Handle then Copy_Alloc else 0);
      Item.Copy_Values_Bytes :=
        (if Item.Copy_Values_Buffer /= Null_Handle then Values_Wanted else 0);
      Item.Cache_Elements := Interfaces.Unsigned_64 (Elements);
      Item.Copy_Only := Copy_Only;
      Item.Copy_Split := Split;
      Item.Copy_Keys_Halves := (if Split then Interfaces.Unsigned_64 (Keys_Upto) else 0);
   end Reserve_Exact;

   --  What Reserve_Exact does, with room to grow. A paged cache grows by a
   --  page's worth of tables at a time, and two paged sessions -- a model
   --  and its draft -- ask for sizes a few kilobytes apart; asked for
   --  exactly, the buffer was made again and the whole cache copied into
   --  it at every step up: qwen3-8b drafted by qwen3-0.6b spent 2.4 s of a
   --  9.4 s run, 12 ms a time, in 202 of them. Made a quarter larger than
   --  asked, where the budget allows, a step up is a step into room
   --  already there; where it does not, it is made to size as before.
   --
   --  A first block is made to size: a block is a session's whole context
   --  asked for at once, and nothing steps up from it unless a second
   --  session comes, which is a step up and gets the room then. Made a
   --  quarter larger, a single session's block held a quarter of its
   --  context again in memory nothing would write -- 705 MB of qwen3-0.6b
   --  at 8,192 positions.
   procedure Reserve
     (Item            : in out Engine;
      Elements        : Model_Runner.Numerics.Element_Count;
      Copy_Upto       : Model_Runner.Numerics.Element_Count;
      Ok              : out Boolean;
      Allow_Copy_Only : Boolean := False;
      Keys_Upto       : Model_Runner.Numerics.Element_Count := 0;
      Front           : Model_Runner.Numerics.Element_Count := 0)
   is

      --  A quarter more, up to 2 ** 27 elements -- half a gigabyte of
      --  binary32, a quarter of halves. A quarter of a long context's cache
      --  is gigabytes nothing writes: Steelman-14B's at 32,768 held 1.6 GB
      --  of copy past its last page. Past the cap a step up comes every
      --  few hundred positions, and costs a copy of the cache the device
      --  makes in milliseconds.
      function Roomier
        (Count : Model_Runner.Numerics.Element_Count)
         return Model_Runner.Numerics.Element_Count
      is (Count + Model_Runner.Numerics.Element_Count'Min (Count / 4, 2 ** 27));

      Wanted      : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;
      Copy_Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Copy_Upto) * 2;
   begin
      --  Room enough already: the exact call answers at once. A cache kept
      --  as its copy and a front holds no rows in the binary32, so its
      --  room is the copy's.
      if ((Item.Cache_Bytes >= Wanted
           or else (Item.Copy_Only and then Item.Cache_Front > 0))
          and then (Item.Copy_Bytes >= Copy_Wanted
                    or else not Wants_Copy (Item)))
        or else (Front = 0 and then Item.Cache_Bytes = 0 and then Item.Copy_Bytes = 0)
      then
         Reserve_Exact
           (Item, Elements, Copy_Upto, Ok, Allow_Copy_Only, Keys_Upto, Front);
         return;
      end if;

      Reserve_Exact
        (Item, Roomier (Elements), Roomier (Copy_Upto), Ok, Allow_Copy_Only,
         (if Keys_Upto = 0 then 0 else Roomier (Keys_Upto)), Front);
      if not Ok then
         Reserve_Exact
           (Item, Elements, Copy_Upto, Ok, Allow_Copy_Only, Keys_Upto, Front);
      end if;
   end Reserve;

   -------------------
   -- Release_Cache --
   -------------------

   procedure Release_Cache (Item : in out Engine) is
      Ignored : constant Boolean := Set_Asking (Item);

      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

      Settled : Boolean;
   begin
      if Item.Cache_Buffer = Null_Handle
        and then Item.Copy_Buffer = Null_Handle
        and then Item.Second_Buffer = Null_Handle
      then
         return;
      end if;

      --  What is in flight is reading it.
      Settle (Item, Settled);

      if not Settled then
         return;
      end if;

      if Unmap /= null and then Item.Logical /= Null_Handle then
         if Item.Cache_At /= Null_Handle then
            Unmap (Item.Logical, Item.Cache_Memory);
         end if;

         if Item.Copy_At /= Null_Handle then
            Unmap (Item.Logical, Item.Copy_Memory);
         end if;

         if Item.Copy_Values_At /= Null_Handle then
            Unmap (Item.Logical, Item.Copy_Values_Memory);
         end if;

         if Item.Second_At /= Null_Handle then
            Unmap (Item.Logical, Item.Second_Memory);
         end if;
      end if;

      Item.Cache_At := Null_Handle;
      Item.Copy_At := Null_Handle;
      Item.Copy_Values_At := Null_Handle;
      Item.Second_At := Null_Handle;
      Give_Back_Buffer (Item, Item.Second_Buffer, Item.Second_Memory);
      Item.Second_Bytes := 0;

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
      Give_Back_Buffer (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);

      Item.Cache_Bytes := 0;
      Item.Copy_Bytes := 0;
      Item.Copy_Values_Bytes := 0;
      Item.Cache_Elements := 0;
      Item.Copy_Only := False;
      Item.Cache_Front := 0;
      Item.Copy_Split := False;
   end Release_Cache;

   procedure Keep_File_Pages (Item : in out Engine; Keep : Boolean) is
   begin
      Item.Keep_Pages :=
        Keep and then (Item.Keep_Pages or else not Item.Pages_Told);
      Item.Pages_Told := True;
   end Keep_File_Pages;

   --  Where a run of halves lies in a copy that holds it alone, or
   --  Null_Address where it is not such a run.
   function Halves_At
     (Item     : Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count) return Address
   is
      use type System.Storage_Elements.Integer_Address;
      Span : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Count) * 2;
   begin
      if not Is_Ready (Item) or else Count = 0 then
         return Null_Handle;
      elsif At_Value >= Second_Copy then
         declare
            From : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (At_Value - Second_Copy) * 2;
         begin
            if Item.Second_At = Null_Handle
              or else From + Span > Item.Second_Bytes
            then
               return Null_Handle;
            end if;
            return System.Storage_Elements.To_Address
              (System.Storage_Elements.To_Integer (Item.Second_At)
               + System.Storage_Elements.Integer_Address (From));
         end;
      elsif Item.Cache_Front > 0
        and then not Item.Copy_Split
        and then Interfaces.Unsigned_64 (At_Value) >= Item.Cache_Front
        and then Item.Copy_At /= Null_Handle
        and then Interfaces.Unsigned_64 (At_Value) * 2 + Span <= Item.Copy_Bytes
      then
         return System.Storage_Elements.To_Address
           (System.Storage_Elements.To_Integer (Item.Copy_At)
            + System.Storage_Elements.Integer_Address
                (Interfaces.Unsigned_64 (At_Value) * 2));
      else
         return Null_Handle;
      end if;
   end Halves_At;

   procedure Put_Cache_Halves
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Halves   : Model_Runner.Numerics.Half_Array;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);
      Where : constant Address :=
        Halves_At (Item, At_Value, Halves'Length);
   begin
      Ok := Where /= Null_Handle;
      if Ok then
         declare
            Room : Model_Runner.Numerics.Half_Array (Halves'Range)
              with Import, Address => Where;
         begin
            Room := Halves;
         end;
      end if;
   end Put_Cache_Halves;

   procedure Get_Cache_Halves
     (Item     : Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Halves   : out Model_Runner.Numerics.Half_Array;
      Ok       : out Boolean)
   is
      Where : constant Address :=
        Halves_At (Item, At_Value, Halves'Length);
   begin
      Ok := Where /= Null_Handle;
      if Ok then
         declare
            Room : Model_Runner.Numerics.Half_Array (Halves'Range)
              with Import, Address => Where;
         begin
            Halves := Room;
         end;
      end if;
   end Get_Cache_Halves;

   --------------------
   -- Reserve_Second --
   --------------------

   procedure Reserve_Second
     (Item      : in out Engine;
      Copy_Upto : Model_Runner.Numerics.Element_Count;
      Ok        : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      --  In whole words, as the first copy's room is: see Reserve_Exact.
      Wanted : constant Interfaces.Unsigned_64 :=
        (Interfaces.Unsigned_64 (Copy_Upto) * 2 + 3) / 4 * 4;

      Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

      Was_Buffer : Address := Item.Second_Buffer;
      Was_Memory : Address := Item.Second_Memory;
      Was_At     : constant Address := Item.Second_At;
      Was_Bytes  : constant Interfaces.Unsigned_64 := Item.Second_Bytes;

      New_Buffer, New_Memory : Address := Null_Handle;
      Where : aliased Address := Null_Handle;
   begin
      Ok := False;

      if not Is_Ready (Item) or else Map = null or else Unmap = null then
         return;
      end if;

      if Item.Second_Bytes >= Wanted then
         Ok := True;
         return;
      end if;

      --  As one storage buffer: past that the kernels could not read it.
      if Over_Limit (Item, Wanted) then
         return;
      end if;

      Take (Item, Wanted, New_Buffer, New_Memory, Ok);
      if not Ok then
         Give_Back_Buffer (Item, New_Buffer, New_Memory);
         return;
      end if;
      if Map (Item.Logical, New_Memory, 0, Wanted, 0, Where'Access) /= 0 then
         Give_Back_Buffer (Item, New_Buffer, New_Memory);
         Ok := False;
         return;
      end if;

      --  Zeroed and what the old one held carried over, by the device,
      --  as the first copy is when it grows; see Reserve_Exact.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Fill  : constant Fill_Call := To_Fill (Point ("vkCmdFillBuffer"));
         Copy_Buffer : constant Copy_Buffer_Call :=
           To_Copy_Buffer (Point ("vkCmdCopyBuffer"));
         Barrier : constant Barrier_Call :=
           To_Barrier (Point ("vkCmdPipelineBarrier"));

         Began : aliased Command_Begin_Info;
         Good, Cancelled : Boolean;
      begin
         Settle (Item, Good);

         if not Good
           or else Reset_Buffer = null or else Start = null
           or else Stop = null or else Fill = null
           or else Copy_Buffer = null or else Barrier = null
           or else Reset_Buffer (Item.Buffer, 0) /= 0
           or else Opened (Item.Buffer, Start, Began'Address) /= 0
         then
            Unmap (Item.Logical, New_Memory);
            Give_Back_Buffer (Item, New_Buffer, New_Memory);
            Ok := False;
            return;
         end if;

         Fill (Item.Buffer, New_Buffer, 0, Wanted, 0);

         if Was_Buffer /= Null_Handle and then Was_Bytes > 0 then
            declare
               Wall : aliased Memory_Barrier :=
                 (Wrote  => Access_Transfer_Write,
                  Reads  => C.unsigned (Access_Transfer_Read
                                        + Access_Transfer_Write),
                  others => <>);
               Halves : aliased Copy_Region :=
                 (From => 0, Into => 0, Span => Was_Bytes);
            begin
               Barrier (Item.Buffer, Pipeline_Stage_Transfer,
                        Pipeline_Stage_Transfer, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);
               Copy_Buffer (Item.Buffer, Was_Buffer, New_Buffer, 1,
                            Halves'Address);
            end;
         end if;

         if Stop (Item.Buffer) /= 0 then
            Unmap (Item.Logical, New_Memory);
            Give_Back_Buffer (Item, New_Buffer, New_Memory);
            Ok := False;
            return;
         end if;

         Submit_And_Wait (Item, Good, Cancelled, null);
         if not Good then
            --  Stalled, the device may still be writing it: left as it is.
            if not Item.Stalled then
               Unmap (Item.Logical, New_Memory);
               Give_Back_Buffer (Item, New_Buffer, New_Memory);
            end if;
            Ok := False;
            return;
         end if;
      end;

      if Was_At /= Null_Handle then
         Unmap (Item.Logical, Was_Memory);
      end if;
      Give_Back_Buffer (Item, Was_Buffer, Was_Memory);

      Item.Second_Buffer := New_Buffer;
      Item.Second_Memory := New_Memory;
      Item.Second_At := Where;
      Item.Second_Bytes := Wanted;
      Ok := True;
   end Reserve_Second;

   ---------------
   -- Put_Cache --
   ---------------

   procedure Halve
     (Values : Model_Runner.Numerics.Real_Array;
      Halves : out Model_Runner.Numerics.Half_Array) renames
     Model_Runner.Kernels.To_Halves;

   procedure Put_Cache
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Values'Length) * 4;

      --  Rows past the front of a cache kept as its copy and a front: the
      --  binary32 buffer is the front alone, so they go to the copy only.
      Past_Front : constant Boolean :=
        Item.Cache_Front > 0
        and then Interfaces.Unsigned_64 (At_Value) >= Item.Cache_Front;
   begin
      Ok := False;

      --  The second copy's rows: halves alone, as a copy-only cache's are.
      if At_Value >= Second_Copy then
         declare
            From : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (At_Value - Second_Copy);
         begin
            if not Is_Ready (Item)
              or else Item.Second_At = Null_Handle
              or else Values'Length = 0
              or else (From + Interfaces.Unsigned_64 (Values'Length)) * 2
                      > Item.Second_Bytes
            then
               return;
            end if;

            declare
               Halves : Model_Runner.Numerics.Half_Array (Values'Range)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer (Item.Second_At)
                           + System.Storage_Elements.Integer_Address
                               (From * 2));
            begin
               Halve (Values, Halves);
            end;
            Ok := True;
            return;
         end;
      end if;

      if not Is_Ready (Item)
        or else Values'Length = 0
        or else (Item.Cache_At = Null_Handle
                 and then Item.Copy_At = Null_Handle)
        or else (Item.Cache_At /= Null_Handle
                 and then not Past_Front
                 and then At_Byte + Span > Item.Cache_Bytes)
      then
         return;
      end if;

      --  Straight into the standing mapping: a copy and no call to the
      --  driver at all. Only where the cache proper is kept -- a copy-only
      --  session has just the half-precision copy below.
      if Item.Cache_At /= Null_Handle and then not Past_Front then
         declare
            Room : Model_Runner.Numerics.Real_Array (Values'Range)
              with Import,
                   Address =>
                     System.Storage_Elements.To_Address
                       (System.Storage_Elements.To_Integer (Item.Cache_At)
                        + System.Storage_Elements.Integer_Address (At_Byte));
         begin
            Room := Values;
         end;
      end if;

      --  And the half-precision copy beside it, so that a cache the host
      --  seeded reads the same to the matrix kernel as one the device
      --  wrote itself. Only where there is one: a caller may put values
      --  into a cache this engine took for itself rather than reserved,
      --  and there is no copy of such a cache to write.
      --
      --  Where the copy is split, a row is all keys or all values -- a
      --  position's keys and its values are put a call apart -- so which
      --  buffer it goes to and where in it follow from where the element
      --  sits against the keys' end.
      declare
         Into_Values : constant Boolean :=
           Item.Copy_Split
           and then Interfaces.Unsigned_64 (At_Value) >= Item.Copy_Keys_Halves;

         At_Half : constant Interfaces.Unsigned_64 :=
           (if Into_Values
            then Interfaces.Unsigned_64 (At_Value) - Item.Copy_Keys_Halves
            else Interfaces.Unsigned_64 (At_Value)) * 2;

         Base_At : constant Address :=
           (if Into_Values then Item.Copy_Values_At else Item.Copy_At);
         Room_Bytes : constant Interfaces.Unsigned_64 :=
           (if Into_Values then Item.Copy_Values_Bytes else Item.Copy_Bytes);
      begin
         if Base_At /= Null_Handle
           and then At_Half + Interfaces.Unsigned_64 (Values'Length) * 2
                    <= Room_Bytes
         then
            declare
               Halves : Model_Runner.Numerics.Half_Array (Values'Range)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer (Base_At)
                           + System.Storage_Elements.Integer_Address (At_Half));
            begin
               Halve (Values, Halves);
            end;
         elsif Item.Cache_At = Null_Handle or else Past_Front then
            --  The copy was the only place for these rows, and they were
            --  not written there: nothing holds them, and saying so is the
            --  caller's to act on.
            return;
         end if;
      end;

      Ok := True;
   end Put_Cache;

   function Result_Room (Item : Engine) return Interfaces.Unsigned_64 is (Item.Result_Bytes);

   function Kept_Answer (Item : Engine) return System.Address
   is (Item.Kept_At);

   ---------------------
   -- Activation_Room --
   ---------------------

   procedure Activation_Room
     (Item   : in out Engine;
      Bytes  : Interfaces.Unsigned_64;
      Where  : out System.Address;
      Ok     : out Boolean;
      Origin : Interfaces.Unsigned_64 := 0;
      Wait   : Boolean := True)
   is
      Wanted : constant Interfaces.Unsigned_64 := Origin + (Bytes + 255) / 256 * 256;
   begin
      Where := Null_Handle;
      Item.Kept_At := Null_Handle;
      if Wait or else Item.Result_Bytes < Wanted or else Item.Result_At = Null_Handle then
         Settle (Item, Ok);
         if not Ok then
            return;
         end if;
      end if;
      if Item.Result_Bytes < Wanted then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Item.Result_Bytes := 0;
         Take (Item, Wanted, Item.Result_Buffer, Item.Result_Memory, Ok, Read => True);
         if not Ok then
            Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
            return;
         end if;
         Item.Result_Bytes := Wanted;
      end if;
      Standing (Item, Item.Result_Memory, Item.Result_At, Item.Result_Bytes, Ok);
      if Ok then
         declare
            use System.Storage_Elements;
         begin
            Where := To_Address (To_Integer (Item.Result_At) + Integer_Address (Origin));
         end;
      end if;
   end Activation_Room;

   procedure Finish_All (Item : in out Engine; Ok : out Boolean) is
   begin
      Settle (Item, Ok);
   end Finish_All;

   ------------------
   -- Cache_Places --
   ------------------

   procedure Cache_Places
     (Item     : Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count;
      Proper   : out System.Address;
      Copy     : out System.Address)
   is
      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Count) * 4;

      --  As Put_Cache reads them: rows past a front go to the copy alone,
      --  and a split copy's values have a buffer of their own.
      Past_Front : constant Boolean :=
        Item.Cache_Front > 0
        and then Interfaces.Unsigned_64 (At_Value) >= Item.Cache_Front;
      Into_Values : constant Boolean :=
        Item.Copy_Split
        and then Interfaces.Unsigned_64 (At_Value) >= Item.Copy_Keys_Halves;
      At_Half : constant Interfaces.Unsigned_64 :=
        (if Into_Values
         then Interfaces.Unsigned_64 (At_Value) - Item.Copy_Keys_Halves
         else Interfaces.Unsigned_64 (At_Value)) * 2;
      Base_At : constant Address :=
        (if Into_Values then Item.Copy_Values_At else Item.Copy_At);
      Room_Bytes : constant Interfaces.Unsigned_64 :=
        (if Into_Values then Item.Copy_Values_Bytes else Item.Copy_Bytes);
   begin
      Proper := Null_Handle;
      Copy := Null_Handle;
      if not Is_Ready (Item) or else Count = 0 or else At_Value >= Second_Copy then
         return;
      end if;
      if Item.Cache_At /= Null_Handle and then not Past_Front
        and then At_Byte + Span <= Item.Cache_Bytes
      then
         Proper := System.Storage_Elements.To_Address
           (System.Storage_Elements.To_Integer (Item.Cache_At)
            + System.Storage_Elements.Integer_Address (At_Byte));
      end if;
      if Base_At /= Null_Handle
        and then At_Half + Interfaces.Unsigned_64 (Count) * 2 <= Room_Bytes
      then
         Copy := System.Storage_Elements.To_Address
           (System.Storage_Elements.To_Integer (Base_At)
            + System.Storage_Elements.Integer_Address (At_Half));
      end if;
   end Cache_Places;

   ---------------
   -- Put_Bytes --
   ---------------

   procedure Put_Bytes
     (Item    : in out Engine;
      At_Byte : Interfaces.Unsigned_64;
      Data    : Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      use type System.Storage_Elements.Integer_Address;

      Span : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Data'Length);
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.Cache_At = Null_Handle
        or else Data'Length = 0
        or else At_Byte + Span > Item.Cache_Bytes
      then
         return;
      end if;

      declare
         Room : Model_Runner.Bytes.Byte_Array (Data'Range)
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.Cache_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         Room := Data;
      end;

      Ok := True;
   end Put_Bytes;

   -------------
   -- Copy_At --
   -------------

   function Copy_At (Item : Engine) return Interfaces.Unsigned_64
   is (0 * Item.Cache_Elements);

   ---------------
   -- Get_Bytes --
   ---------------

   procedure Get_Bytes
     (Item    : Engine;
      At_Byte : Interfaces.Unsigned_64;
      Data    : out Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean)
   is
      use type System.Storage_Elements.Integer_Address;

      Span : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Data'Length);
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.Cache_At = Null_Handle
        or else Data'Length = 0
        or else At_Byte + Span > Item.Cache_Bytes
      then
         return;
      end if;

      declare
         Room : Model_Runner.Bytes.Byte_Array (Data'Range)
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.Cache_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         Data := Room;
      end;

      Ok := True;
   end Get_Bytes;

   --------------------
   -- Attends_Packed --
   --------------------

   function Attends_Packed (Item : Engine) return Boolean
   is (Packed_Pipeline (Item) /= Null_Handle);

   function Takes_Packed_Heads
     (Item       : Engine;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Packed_Pipeline (Item) /= Null_Handle
       and then Head_Size in 4 .. 256
       and then Head_Size mod 4 = 0
       and then Value_Size in 4 .. Attention_Room
       and then Value_Size mod 4 = 0);

   --  Valid codec/width pairs for packing and unpacking. The attention
   --  kernel has the narrower rule below: four bits alone never let it
   --  interpret transformed bytes as ordinary Q4.
   function Cache_Codec_Fits
     (Codec : Cache_Codec; Bits : Natural) return Boolean
   is (case Codec is
         when Scaled_Integer_Cache => Bits in 4 | 8,
         when OCP_E4M3_Cache => Bits = E4M3_Cache_Code,
         when Transformed_Four_Bit_Cache => Bits = 4,
         when Inferred_From_Bits_Cache => False);

   --  Whether the packed kernel takes this shape over this block: the
   --  kernel reads a row a word at a time, four elements of it, and a
   --  head's four never straddle a word only where every base and width
   --  is a multiple of four -- which the engine's layout gives, and which
   --  this holds it to. Asked by the single call and by a sequence alike.
   function Packed_Fits
     (Item       : Engine;
      Packed     : Packed_Cache;
      Head_Size  : Natural;
      Value_Size : Natural;
      KV_Width   : Natural;
      V_Width    : Natural) return Boolean
   is (Packed_Pipeline (Item) /= Null_Handle
       and then Packed.V_Codec /= Transformed_Four_Bit_Cache
       and then Cache_Codec_Fits (Packed.K_Codec, Packed.K_Bits)
       and then Cache_Codec_Fits (Packed.V_Codec, Packed.V_Bits)
       and then (Packed.K_Codec /= Transformed_Four_Bit_Cache
                 or else Head_Size mod 32 = 0)
       and then Head_Size in 4 .. 256
       and then Head_Size mod 4 = 0
       and then Value_Size in 4 .. Attention_Room
       and then Value_Size mod 4 = 0
       and then KV_Width mod 4 = 0
       and then V_Width mod 4 = 0
       and then Packed.K_Bytes mod 4 = 0
       and then Packed.V_Bytes mod 4 = 0);

   --  The rows a workgroup of the packed kernel answers: eight, as the
   --  shader declares, shared between positions of a batch and heads of
   --  a group. A batch takes the positions first, since eight positions
   --  of one head share a group's keys as eight heads of one position
   --  do and a batch has positions to spare; a token takes the heads.
   Packed_Rows : constant := 8;

   --  How many positions a workgroup answers.
   function Packed_Queries (Positions : Positive) return Positive
   is (Positive'Min (Positions, Packed_Rows));

   --  How many heads: the most that fit beside the positions and divide
   --  the group, so a workgroup reads a group's keys and values once for
   --  every row of it and never crosses into another group's -- and one
   --  over a short cache, where a workgroup a head is more workgroups
   --  doing little each, as the exact bundle is bound.
   function Packed_Bundle
     (Item       : Engine;
      Group_Size : Positive;
      Queries    : Positive;
      Span       : Natural) return Positive
   is (if Span < Item.Launch.Packed_Bundle_Least then 1
       elsif Queries = 1 and then Group_Size mod 8 = 0 then 8
       elsif Queries <= 2 and then Group_Size mod 4 = 0 then 4
       elsif Queries <= 4 and then Group_Size mod 2 = 0 then 2
       else 1);

   --  How many slices a sequence's packed attention cuts the cache into,
   --  as Attend_Slices cuts it for the exact kernel.
   --
   --  What the first two axes give is the bundles across the heads and
   --  the rows down the second, and where that is not enough to fill the
   --  part the cache is cut across the third. A batch of one session has
   --  its positions for that; a token has one row and a few bundles; a
   --  round of eight rows has thirty-two workgroups, which read a long
   --  cache a third slower than the same rows cut into slices -- 1.36 ms
   --  a layer against 0.98 on a 1,419-token prompt. Rounds were not cut
   --  at all until that was measured, on the reading that their rows'
   --  lasts are in the table rather than in First and Last; the kernel
   --  takes its span from the table and divides what it finds, so the
   --  count here is a hint and an empty slice says so for itself.
   --
   --  Never below a slice of Slice_Least positions: cutting a short cache
   --  into sixteen is sixteen dispatches with nothing in them.
   --
   --  @param Item Engine.
   --  @param Wide How many workgroups the first two axes give.
   --  @param First The lowest cached position this call reads.
   --  @param Last The highest.
   --  @param Rounding True where the rows are different sessions, whose
   --    own lasts are in the table.
   function Packed_Slices
     (Item     : Engine;
      Wide     : Natural;
      First    : Natural;
      Last     : Natural;
      Rounding : Boolean := False) return Natural
   is (if Item.Merge_Line = Null_Handle
         or else Last < First
         or else Wide = 0
         or else (Rounding and then not Item.Launch.Packed_Cuts_A_Round)
       then 1
       else Natural'Max
              (1,
               Natural'Min
                 (Natural'Min
                    (Item.Launch.Attention_Slice_Limit,
                     (Item.Launch.Attention_Workgroups + Wide - 1) / Wide),
                  (Last - First + Item.Launch.Attention_Slice_Least)
                    / Item.Launch.Attention_Slice_Least)));

   -------------------
   -- Attend_Packed --
   -------------------

   procedure Attend_Packed
     (Item       : in out Engine;
      K_Bits     : Positive;
      V_Bits     : Positive;
      Query      : Model_Runner.Numerics.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Bytes    : Interfaces.Unsigned_64;
      V_Bytes    : Interfaces.Unsigned_64;
      KV_Width   : Natural;
      V_Width    : Natural;
      KS_At      : Natural;
      VS_At      : Natural;
      K_Blocks   : Natural;
      V_Blocks   : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Target     : out Model_Runner.Numerics.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;
      K_Codec    : Cache_Codec := Inferred_From_Bits_Cache;
      V_Codec    : Cache_Codec := Inferred_From_Bits_Cache)
   is separate;

   ---------------
   -- Put_Words --
   ---------------

   procedure Put_Words
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Words    : Word_List;
      Ok       : out Boolean)
   is
      type Table_Words is array (Words'Range) of C.unsigned
        with Convention => C;

      Ignored : constant Boolean := Set_Asking (Item);

      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Words'Length) * 4;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.Cache_At = Null_Handle
        or else Words'Length = 0
        or else At_Byte + Span > Item.Cache_Bytes
      then
         return;
      end if;

      --  Whole numbers where the buffer holds binary32, read back by the
      --  kernel with floatBitsToUint. The alternative was a fourth buffer
      --  and a descriptor a step to go with it, for a table of two words a
      --  row; this is the same memory the kernel already has bound.
      declare
         Room : Table_Words
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.Cache_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         for Index in Words'Range loop
            Room (Index) := C.unsigned (Words (Index));
         end loop;
      end;

      Ok := True;
   end Put_Words;

   ---------------
   -- Get_Cache --
   ---------------

   procedure Get_Cache
     (Item     : Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean)
   is
      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Values'Length) * 4;
   begin
      Ok := False;

      --  The second copy's rows, from its halves.
      if At_Value >= Second_Copy then
         declare
            From : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (At_Value - Second_Copy);
         begin
            if not Is_Ready (Item)
              or else Item.Second_At = Null_Handle
              or else Values'Length = 0
              or else (From + Interfaces.Unsigned_64 (Values'Length)) * 2
                      > Item.Second_Bytes
            then
               return;
            end if;

            declare
               Halves : Model_Runner.Numerics.Half_Array (Values'Range)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer (Item.Second_At)
                           + System.Storage_Elements.Integer_Address
                               (From * 2));
            begin
               for Index in Values'Range loop
                  Values (Index) :=
                    Model_Runner.Numerics.To_Real (Halves (Index));
               end loop;
            end;
            Ok := True;
            return;
         end;
      end if;

      --  Rows past the front of a cache kept as its copy and a front are in
      --  the copy alone, and come back from its halves -- the values the
      --  device attends with, which a binary16 cache holds anyway.
      --  And so are a block's rows where the copy is all that is kept --
      --  in the values' buffer, off its front, where the copy is split.
      --  A split copy's generated tokens attend on the host, which reads
      --  the rows the prompt wrote here first; it read the binary32
      --  cache there is none of, and qwen3-8b's first token was noise.
      if (Item.Cache_Front > 0
          and then Interfaces.Unsigned_64 (At_Value) >= Item.Cache_Front)
        or else (Item.Copy_Only and then Item.Cache_Front = 0)
      then
         declare
            In_Values : constant Boolean :=
              Item.Copy_Split
              and then Interfaces.Unsigned_64 (At_Value)
                       >= Item.Copy_Keys_Halves;
            From : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (At_Value)
              - (if In_Values then Item.Copy_Keys_Halves else 0);
            Base : constant Address :=
              (if In_Values then Item.Copy_Values_At else Item.Copy_At);
            Room : constant Interfaces.Unsigned_64 :=
              (if In_Values then Item.Copy_Values_Bytes else Item.Copy_Bytes);
         begin
            if not Is_Ready (Item)
              or else Base = Null_Handle
              or else Values'Length = 0
              or else (From + Interfaces.Unsigned_64 (Values'Length)) * 2 > Room
            then
               return;
            end if;

            declare
               Halves : Model_Runner.Numerics.Half_Array (Values'Range)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer (Base)
                           + System.Storage_Elements.Integer_Address (From * 2));
            begin
               for Index in Values'Range loop
                  Values (Index) := Model_Runner.Numerics.To_Real (Halves (Index));
               end loop;
            end;

            Ok := True;
            return;
         end;
      end if;

      if not Is_Ready (Item)
        or else Item.Cache_At = Null_Handle
        or else Values'Length = 0
        --  As far as the buffer is mapped: a kept front maps only so far.
        or else At_Byte + Span > Item.Cache_Bytes
      then
         return;
      end if;

      declare
         Room : Model_Runner.Numerics.Real_Array (Values'Range)
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.Cache_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         Values := Room;
      end;

      Ok := True;
   end Get_Cache;

   -------------------
   -- Reserve_State --
   -------------------

   procedure Reserve_State
     (Item     : in out Engine;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;

      Was_Buffer : Address := Item.State_Buffer;
      Was_Memory : Address := Item.State_Memory;
      Was_At     : constant Address := Item.State_At;
      Was_Bytes  : constant Interfaces.Unsigned_64 := Item.State_Bytes;

      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
      Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
      Where : aliased Address := Null_Handle;

      --  A room that could not be made leaves the one there was, whole:
      --  the new one given back, the old one kept as it stood -- the rings
      --  of every seated session in it. It was given back with the new
      --  one, or kept mapped and lost, and each session's state with it.
      --  On a stalled engine the new room may still be the device's, and
      --  is kept rather than freed under it.
      procedure Undo is
      begin
         if not Item.Stalled then
            if Item.State_At /= Null_Handle and then Unmap /= null then
               Unmap (Item.Logical, Item.State_Memory);
            end if;
            Give_Back_Buffer (Item, Item.State_Buffer, Item.State_Memory);
         end if;
         Item.State_Buffer := Was_Buffer;
         Item.State_Memory := Was_Memory;
         Item.State_At := Was_At;
         Item.State_Bytes := Was_Bytes;
         Ok := False;
      end Undo;
   begin
      Ok := False;

      if not Is_Ready (Item) or else Elements = 0 or else Map = null then
         return;
      end if;

      if Over_Limit (Item, Wanted) then
         return;
      end if;

      if Item.State_Bytes >= Wanted then
         Ok := True;
         return;
      end if;

      --  The host is about to copy out of a buffer a submission may
      --  still be writing.
      Settle (Item, Ok);
      if not Ok then
         return;
      end if;

      Item.State_Buffer := Null_Handle;
      Item.State_Memory := Null_Handle;
      Item.State_At := Null_Handle;

      Take (Item, Wanted, Item.State_Buffer, Item.State_Memory, Ok);
      if not Ok then
         Undo;
         return;
      end if;

      if Map (Item.Logical, Item.State_Memory, 0, Wanted, 0, Where'Access)
         /= 0
      then
         Undo;
         return;
      end if;

      Item.State_At := Where;

      --  Zeroed on the device rather than through the mapping, for the
      --  reason the cache is: written by the host it faults in every page
      --  of a room that is tens of megabytes, and the device writes its
      --  own memory at its own rate. A ring is written by the session
      --  that seats in it before anything reads it, so what this buys is
      --  a room whose gaps are nothing rather than whatever was there.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Fill  : constant Fill_Call := To_Fill (Point ("vkCmdFillBuffer"));
         Copy_Buffer : constant Copy_Buffer_Call :=
           To_Copy_Buffer (Point ("vkCmdCopyBuffer"));
         Barrier : constant Barrier_Call :=
           To_Barrier (Point ("vkCmdPipelineBarrier"));

         Began : aliased Command_Begin_Info;

         Good, Cancelled : Boolean;
      begin
         --  What is in flight is using the command buffer this records
         --  into: a room is reserved between layers, where the sequence
         --  before it may still be running.
         Settle (Item, Good);

         if not Good
           or else Reset_Buffer = null or else Start = null
           or else Stop = null or else Fill = null
           or else Copy_Buffer = null or else Barrier = null
           or else Reset_Buffer (Item.Buffer, 0) /= 0
           or else Opened (Item.Buffer, Start, Began'Address) /= 0
         then
            Undo;
            return;
         end if;

         Fill (Item.Buffer, Item.State_Buffer, 0, Wanted, 0);

         --  And what the room being replaced held, into the front of the
         --  new one: every seated session's ring, which a room that came
         --  up empty would make each of them write again. On the device,
         --  behind a barrier, for the reasons the cache's carry is.
         if Was_At /= Null_Handle and then Was_Bytes > 0 then
            declare
               Wall : aliased Memory_Barrier :=
                 (Wrote  => Access_Transfer_Write,
                  Reads  => C.unsigned (Access_Transfer_Read
                                        + Access_Transfer_Write),
                  others => <>);

               Rings : aliased Copy_Region :=
                 (From => 0, Into => 0, Span => Was_Bytes);
            begin
               Barrier (Item.Buffer, Pipeline_Stage_Transfer,
                        Pipeline_Stage_Transfer, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);

               Copy_Buffer (Item.Buffer, Was_Buffer, Item.State_Buffer,
                            1, Rings'Address);
            end;
         end if;

         if Stop (Item.Buffer) /= 0 then
            Undo;
            return;
         end if;

         Submit_And_Wait (Item, Good, Cancelled, null);

         if not Good then
            Undo;
            return;
         end if;
      end;

      --  The room being replaced, unmapped and given back: what it held
      --  is in the new one already, carried there by the device.
      if Was_At /= Null_Handle and then Was_Bytes > 0 then
         if Unmap /= null then
            Unmap (Item.Logical, Was_Memory);
         end if;
      end if;

      Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
      Item.State_Bytes := Wanted;
      Ok := True;
   end Reserve_State;

   -----------------
   -- Clear_State --
   -----------------

   ----------------
   -- Move_Cache --
   ----------------

   --  One buffer's run moved into another place in the same buffer, and
   --  the halves beside it. Recorded as one submission with a barrier
   --  between the two so that a reader of either sees the whole of it.
   procedure Move_Run
     (Item    : in out Engine;
      Buffer  : Address;
      From    : Interfaces.Unsigned_64;
      Into    : Interfaces.Unsigned_64;
      Bytes   : Interfaces.Unsigned_64;
      Copier  : Copy_Buffer_Call;
      Wall_Up : Barrier_Call);

   procedure Move_Run
     (Item    : in out Engine;
      Buffer  : Address;
      From    : Interfaces.Unsigned_64;
      Into    : Interfaces.Unsigned_64;
      Bytes   : Interfaces.Unsigned_64;
      Copier  : Copy_Buffer_Call;
      Wall_Up : Barrier_Call)
   is
      --  Non-overlapping pieces where the two runs overlap: the distance
      --  between them is how much may be moved at once, front to back.
      Step : constant Interfaces.Unsigned_64 :=
        (if Bytes <= From - Into then Bytes else From - Into);

      Done : Interfaces.Unsigned_64 := 0;
   begin
      while Done < Bytes loop
         declare
            Span : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64'Min (Step, Bytes - Done);

            Piece : aliased Copy_Region :=
              (From => From + Done, Into => Into + Done, Span => Span);
            Wall  : aliased Memory_Barrier :=
              (Wrote  => Access_Transfer_Write,
               Reads  => C.unsigned (Access_Transfer_Read + Access_Transfer_Write),
               others => <>);
         begin
            --  Each piece writes what the one before it read -- of this run,
            --  or of the run moved before it: copies in one command buffer
            --  are not ordered, so each waits for the last.
            Wall_Up (Item.Buffer, Pipeline_Stage_Transfer, Pipeline_Stage_Transfer, 0, 1, Wall'Address,
                     0, Null_Handle, 0, Null_Handle);
            Copier (Item.Buffer, Buffer, Buffer, 1, Piece'Address);
            Done := Done + Span;
         end;
      end loop;
   end Move_Run;

   procedure Move_Cache
     (Item   : in out Engine;
      From   : Model_Runner.Numerics.Element_Count;
      Into   : Model_Runner.Numerics.Element_Count;
      Runs   : Block_Runs;
      Halves : Boolean;
      Ok     : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      --  The highest element any run reaches, for the bounds check.
      Reaches : Model_Runner.Numerics.Element_Count := 0;

      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Copier : constant Copy_Buffer_Call :=
        To_Copy_Buffer (Point ("vkCmdCopyBuffer"));
      Wall_Up : constant Barrier_Call :=
        To_Barrier (Point ("vkCmdPipelineBarrier"));

      Began : aliased Command_Begin_Info;

      Good, Cancelled : Boolean;

      --  Where a run's halves lie: a copy split in two keeps the elements
      --  from Copy_Keys_Halves on in a buffer of its own, counted from its
      --  front. A run whose source and destination are not both on one
      --  side of that end cannot be moved by one copy.
      function In_Values (Element : Model_Runner.Numerics.Element_Count)
        return Boolean
      is (Item.Copy_Split
          and then Interfaces.Unsigned_64 (Element) >= Item.Copy_Keys_Halves);

      function Copy_Takes (Run : Block_Run) return Boolean is
         S : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (From + Run.At_Value);
         N : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Run.Count);
      begin
         if Run.Count = 0 then
            return True;
         elsif In_Values (Into + Run.At_Value) then
            return Item.Copy_Values_Buffer /= Null_Handle
              and then (S + N - Item.Copy_Keys_Halves) * 2
                       <= Item.Copy_Values_Bytes;
         elsif Item.Copy_Split and then S + N > Item.Copy_Keys_Halves then
            return False;
         else
            return (S + N) * 2 <= Item.Copy_Bytes;
         end if;
      end Copy_Takes;
   begin
      Ok := False;

      for Run of Runs loop
         Reaches :=
           Model_Runner.Numerics.Element_Count'Max
             (Reaches, Run.At_Value + Run.Count);
      end loop;

      --  A cache kept as its copy alone -- a block too long for its
      --  binary32 rows to fit one storage buffer -- has only the copy to
      --  move, and is moved there; Gemma 3 4B's block of its whole context
      --  refused every slide on the binary32 bound and slid through the
      --  host instead.
      if not Is_Ready (Item)
        or else (Item.Cache_Buffer = Null_Handle and then not Item.Copy_Only)
        or else Runs'Length = 0
        or else Reaches = 0
        or else Into >= From
        or else (if Item.Copy_Only
                 then not Halves
                      or else Item.Copy_Buffer = Null_Handle
                      or else (for some Run of Runs => not Copy_Takes (Run))
                 else Interfaces.Unsigned_64 (From + Reaches) * 4
                      > Item.Cache_Bytes)
        or else Reset_Buffer = null or else Start = null
        or else Stop = null or else Copier = null or else Wall_Up = null
      then
         return;
      end if;

      --  A kernel in flight may be reading the block.
      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      for Run of Runs loop
         if Run.Count > 0 then
            if not Item.Copy_Only then
               Move_Run
                 (Item, Item.Cache_Buffer,
                  Interfaces.Unsigned_64 (From + Run.At_Value) * 4,
                  Interfaces.Unsigned_64 (Into + Run.At_Value) * 4,
                  Interfaces.Unsigned_64 (Run.Count) * 4, Copier, Wall_Up);
            end if;

            --  The run's halves, in the buffer they lie in. A split copy's
            --  values past the keys' buffer were left where they were, so
            --  a block moved down kept their old copy.
            if Halves
              and then Item.Copy_Buffer /= Null_Handle
              and then Copy_Takes (Run)
            then
               if In_Values (Into + Run.At_Value) then
                  Move_Run
                    (Item, Item.Copy_Values_Buffer,
                     (Interfaces.Unsigned_64 (From + Run.At_Value)
                      - Item.Copy_Keys_Halves) * 2,
                     (Interfaces.Unsigned_64 (Into + Run.At_Value)
                      - Item.Copy_Keys_Halves) * 2,
                     Interfaces.Unsigned_64 (Run.Count) * 2, Copier, Wall_Up);
               else
                  Move_Run
                    (Item, Item.Copy_Buffer,
                     Interfaces.Unsigned_64 (From + Run.At_Value) * 2,
                     Interfaces.Unsigned_64 (Into + Run.At_Value) * 2,
                     Interfaces.Unsigned_64 (Run.Count) * 2, Copier, Wall_Up);
               end if;
            end if;
         end if;
      end loop;

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Move_Cache;

   ----------------
   -- Move_State --
   ----------------

   procedure Move_State
     (Item     : in out Engine;
      From     : Model_Runner.Numerics.Element_Count;
      Into     : Model_Runner.Numerics.Element_Count;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      From_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (From) * 4;
      Into_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Into) * 4;
      Span      : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;

      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Copier : constant Copy_Buffer_Call :=
        To_Copy_Buffer (Point ("vkCmdCopyBuffer"));
      Wall_Up : constant Barrier_Call :=
        To_Barrier (Point ("vkCmdPipelineBarrier"));

      Began : aliased Command_Begin_Info;

      Good, Cancelled : Boolean;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_Buffer = Null_Handle
        or else Elements = 0
        or else Into >= From
        or else From_Byte + Span > Item.State_Bytes
        or else Reset_Buffer = null or else Start = null
        or else Stop = null or else Copier = null or else Wall_Up = null
      then
         return;
      end if;

      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      Move_Run (Item, Item.State_Buffer, From_Byte, Into_Byte, Span, Copier, Wall_Up);

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Move_State;

   procedure Copy_State
     (Item     : in out Engine;
      From     : Model_Runner.Numerics.Element_Count;
      Into     : Model_Runner.Numerics.Element_Count;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      From_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (From) * 4;
      Into_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Into) * 4;
      Span      : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;

      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Copier : constant Copy_Buffer_Call :=
        To_Copy_Buffer (Point ("vkCmdCopyBuffer"));

      Began : aliased Command_Begin_Info;

      Good, Cancelled : Boolean;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_Buffer = Null_Handle
        or else Elements = 0
        or else (From_Byte < Into_Byte + Span
                 and then Into_Byte < From_Byte + Span)
        or else From_Byte + Span > Item.State_Bytes
        or else Into_Byte + Span > Item.State_Bytes
        or else Reset_Buffer = null or else Start = null
        or else Stop = null or else Copier = null
      then
         return;
      end if;

      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      declare
         Piece : aliased Copy_Region :=
           (From => From_Byte, Into => Into_Byte, Span => Span);
      begin
         Copier (Item.Buffer, Item.State_Buffer, Item.State_Buffer, 1,
                 Piece'Address);
      end;

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Copy_State;

   procedure Replay_States
     (Item  : in out Engine;
      Base  : Model_Runner.Numerics.Element_Count;
      Records : Model_Runner.Numerics.Element_Count;
      Every : Model_Runner.Numerics.Element_Count;
      Slots : Natural;
      From  : Natural;
      Count : Natural;
      Heads : Natural;
      All_Slots : Boolean;
      Ok    : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      type Replay_Constants is record
         Base, Records, Every, Slots, From, Count, Heads, All_Slots : C.unsigned;
      end record
        with Convention => C;

      Update : constant Update_Sets_Call :=
        To_Update_Sets (Point ("vkUpdateDescriptorSets"));
      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Bind_Pipeline : constant Bind_Pipeline_Call :=
        To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
      Bind_Sets : constant Bind_Sets_Call :=
        To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
      Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
      Dispatch : constant Dispatch_Call :=
        To_Dispatch (Point ("vkCmdDispatch"));

      Told  : aliased Buffer_Info_Array;
      Notes : aliased Write_Array;
      Sets  : aliased Address := Item.Descriptor;
      Began : aliased Command_Begin_Info;
      Shape : aliased Replay_Constants :=
        (Base      => C.unsigned (Base),
         Records   => C.unsigned (Records),
         Every     => C.unsigned (Every),
         Slots     => C.unsigned (Slots),
         From      => C.unsigned (From),
         Count     => C.unsigned (Count),
         Heads     => C.unsigned (Heads),
         All_Slots => (if All_Slots then 1 else 0));

      Good, Cancelled : Boolean;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_Buffer = Null_Handle
        or else Item.Replay_Line = Null_Handle
        or else Count = 0 or else Slots = 0 or else Heads = 0
        or else Update = null or else Reset_Buffer = null
        or else Start = null or else Stop = null
        or else Bind_Pipeline = null or else Bind_Sets = null
        or else Push = null or else Dispatch = null
      then
         return;
      end if;

      Settle (Item, Good);
      if not Good then
         return;
      end if;

      --  The kernel reads the room alone; a set is written whole, so the
      --  room stands for every binding.
      for Binding in Told'Range loop
         Told (Binding) :=
           (Buffer => Item.State_Buffer, Offset => 0,
            Extent => Item.State_Bytes);
         Notes (Binding).Target := Item.Descriptor;
         Notes (Binding).Binding := C.unsigned (Binding - 1);
         Notes (Binding).Buffers := Told (Binding)'Address;
      end loop;
      Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);

      if Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Replay_Line);
      Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                 Sets'Address, 0, Null_Handle);
      Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
            C.unsigned (Shape'Size / 8), Shape'Address);
      Dispatch (Item.Buffer, C.unsigned (Heads), 1, 1);

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Replay_States;

   function Replays_States (Item : Engine) return Boolean
   is (Item.Replay_Line /= Null_Handle
       and then Item.Held_Rule_Line /= Null_Handle
       and then Item.Single_Rule_Line /= Null_Handle);

   procedure Clear_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Count) * 4;

      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Fill  : constant Fill_Call := To_Fill (Point ("vkCmdFillBuffer"));

      Began : aliased Command_Begin_Info;

      Good, Cancelled : Boolean;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_Buffer = Null_Handle
        or else Count = 0
        or else At_Byte + Span > Item.State_Bytes
        or else Reset_Buffer = null or else Start = null
        or else Stop = null or else Fill = null
      then
         return;
      end if;

      --  A kernel in flight may be reading the room.
      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      Fill (Item.Buffer, Item.State_Buffer, At_Byte, Span, 0);

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Clear_State;

   -------------------------
   -- Release_State_Room --
   -------------------------

   procedure Release_State_Room (Item : in out Engine) is
      Ignored : constant Boolean := Set_Asking (Item);

      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

      Settled : Boolean;
   begin
      if Item.State_Buffer = Null_Handle then
         return;
      end if;

      Settle (Item, Settled);

      if not Settled then
         return;
      end if;

      if Unmap /= null
        and then Item.Logical /= Null_Handle
        and then Item.State_At /= Null_Handle
      then
         Unmap (Item.Logical, Item.State_Memory);
      end if;

      Item.State_At := Null_Handle;
      Give_Back_Buffer (Item, Item.State_Buffer, Item.State_Memory);
      Item.State_Bytes := 0;
   end Release_State_Room;

   ---------------
   -- Put_State --
   ---------------

   procedure Put_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Values'Length) * 4;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_At = Null_Handle
        or else Values'Length = 0
        or else At_Byte + Span > Item.State_Bytes
      then
         return;
      end if;

      --  A submission still running may be reading or writing it.
      Settle (Item, Ok);
      if not Ok then
         return;
      end if;

      declare
         Room : Model_Runner.Numerics.Real_Array (Values'Range)
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.State_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         Room := Values;
      end;

      Ok := True;
   end Put_State;

   ---------------
   -- Get_State --
   ---------------

   procedure Get_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      use type System.Storage_Elements.Integer_Address;

      At_Byte : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (At_Value) * 4;
      Span    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Values'Length) * 4;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Item.State_At = Null_Handle
        or else Values'Length = 0
        or else At_Byte + Span > Item.State_Bytes
      then
         return;
      end if;

      --  What a submission still running would write is what is asked
      --  for.
      Settle (Item, Ok);
      if not Ok then
         return;
      end if;

      declare
         Room : Model_Runner.Numerics.Real_Array (Values'Range)
           with Import,
                Address =>
                  System.Storage_Elements.To_Address
                    (System.Storage_Elements.To_Integer (Item.State_At)
                     + System.Storage_Elements.Integer_Address (At_Byte));
      begin
         Values := Room;
      end;

      Ok := True;
   end Get_State;

   function Submissions (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Clock);

   function Runs_Linear (Item : Engine) return Boolean
   is (Item.Conv_Line /= Null_Handle and then Item.Rule_Line /= Null_Handle);

   function Runs_Rwkv (Item : Engine) return Boolean
   is (Item.Rwkv_Line /= Null_Handle and then Item.Wkv_Line /= Null_Handle);

   function Runs_Mamba2 (Item : Engine) return Boolean
   is (Item.Mamba_Line /= Null_Handle and then Item.Scan_Line /= Null_Handle);

   function Runs_Mamba (Item : Engine) return Boolean
   is (Runs_Mamba2 (Item) and then Item.Scan1_Line /= Null_Handle);

   function Last_Refusal (Item : Engine) return Refusal
   is (Item.Refused);

   procedure Forget_Refusal (Item : in out Engine) is
   begin
      Item.Refused := Not_Refused;
   end Forget_Refusal;

   function Takes_Packed
     (Item       : Engine;
      Packed     : Packed_Cache;
      Head_Size  : Natural;
      Value_Size : Natural;
      KV_Width   : Natural;
      V_Width    : Natural) return Boolean
   is (Packed_Fits (Item, Packed, Head_Size, Value_Size, KV_Width, V_Width));

   ------------
   -- Attend --
   ------------

   procedure Attend_Resident
     (Item       : in out Engine;
      Query      : Model_Runner.Numerics.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count;
      V_Base     : Model_Runner.Numerics.Element_Count;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Target     : out Model_Runner.Numerics.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      --  A batch of none is not an error and not work either.
      Slots : constant Natural := Natural'Max (Positions, 1);

      Query_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Query'Length) * 4;
      Blend_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Slots) *
        Interfaces.Unsigned_64 (Heads) *
        Interfaces.Unsigned_64 (Value_Size) * 4;

      Good      : Boolean;
      Cancelled : Boolean;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Heads = 0
        or else Head_Size = 0
        or else Value_Size = 0
        or else Value_Size > Attention_Room
        or else Group_Size = 0
        or else Last < First
        --  A copy-only session's cache proper is null; its token attends
        --  out of the copy, so the copy standing in is enough.
        or else (Item.Cache_Buffer = Null_Handle
                 and then not (Item.Copy_Only
                               and then Item.Copy_Buffer /= Null_Handle))
        --  A cache kept as its copy holds no rows in binary32, so a batch
        --  for the tiled kernel, or exact attention, attends on the host.
        or else (Item.Copy_Only
                 and then not Reads_Copy
                                (Item, Slots, Head_Size, Value_Size, False))
        --  A split copy's values are on their own binding, read only by the
        --  matrix kernel; a batch too small for it attends on the host.
        or else (Item.Copy_Split
                 and then not Attends_By_Matrix
                                (Item, Slots, Head_Size, Value_Size))
        or else Query'Length
                  < Model_Runner.Numerics.Element_Count (Slots)
                    * Model_Runner.Numerics.Element_Count (Heads)
                    * Model_Runner.Numerics.Element_Count (Head_Size)
        or else Target'Length
                  < Model_Runner.Numerics.Element_Count (Slots)
                    * Model_Runner.Numerics.Element_Count (Heads)
                    * Model_Runner.Numerics.Element_Count (Value_Size)
      then
         return;
      end if;

      --  What is in flight done with the shared buffers before they are
      --  grown or the query written into them, as One_Product has it: a
      --  sequence handed over without a wait may still read the activation
      --  this overwrites.
      Settle (Item, Good);
      if not Good then
         return;
      end if;

      if Item.Vector_Bytes < Query_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Item.Vector_Bytes := 0;
         Take (Item, Query_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
            return;
         end if;
         Item.Vector_Bytes := Query_Bytes;
      end if;

      if Item.Result_Bytes < Blend_Bytes then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Item.Result_Bytes := 0;
         Take (Item, Blend_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
            Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
            return;
         end if;
         Item.Result_Bytes := Blend_Bytes;
      end if;

      --  Through the standing mapping, like every other writer of this
      --  buffer, and they had to move together: a writer that unmaps when
      --  it is done pulls the mapping out from under the others and leaves
      --  them writing into memory that is no longer there. Converting one of
      --  the two products and not the other is exactly that, and it is what
      --  made a drafted device run disagree with an undrafted one for an
      --  afternoon -- the two products are textually different and one
      --  search-and-replace found only the first of them.
      declare
         Wanted : Model_Runner.Numerics.Real_Array renames Query;
      begin
         Standing (Item, Item.Vector_Memory, Item.Vector_At,
                   Item.Vector_Bytes, Good);
         if Good then
            declare
               Room : Model_Runner.Numerics.Real_Array (Wanted'Range)
                 with Import, Address => Item.Vector_At;
            begin
               Room := Wanted;
            end;
         end if;
      end;
      if not Good then
         return;
      end if;

      declare
         Update : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Told  : aliased Buffer_Info_Array;
         Notes : aliased Write_Array;
      begin
         if Update = null then
            return;
         end if;

         Told (1) := Cache_Descriptor (Item);
         Told (2) := (Item.Vector_Buffer, 0, Query_Bytes);
         Told (3) := (Item.Result_Buffer, 0, Blend_Bytes);
         Told (4) := Half_Descriptor (Item);
         Told (5) := Told (3);

         Told (6) := Copy_Descriptor (Item);
         Told (7) := Values_Copy_Descriptor (Item);

         for Binding in Told'Range loop
            Notes (Binding).Target := Item.Descriptor;
            Notes (Binding).Binding := C.unsigned (Binding - 1);
            Notes (Binding).Buffers := Told (Binding)'Address;
         end loop;

         Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
      end;

      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));

         Sets  : aliased Address := Item.Descriptor;
         Began : aliased Command_Begin_Info;

         Shape : aliased Attention_Constants :=
           (Heads      => C.unsigned (Heads),
            Head_Size  => C.unsigned (Head_Size),
            Value_Size => C.unsigned (Value_Size),
            Group_Size => C.unsigned (Group_Size),
            First      => C.unsigned (First),
            Last       => C.unsigned (Last),
            --  Where the keys and the values begin. The matrix kernel
            --  reads them out of the half-precision copy, which has a
            --  buffer of its own and is indexed the same way, so where
            --  that kernel is the one bound these say so and nothing else
            --  in the block has to change. A push constant is what the
            --  shader that is running reads, and only one of them runs.
            K_Base     =>
              C.unsigned
                (K_Base
                 + (if Reads_Copy (Item, Slots, Head_Size, Value_Size, False)
                    then Model_Runner.Numerics.Element_Count (Copy_At (Item))
                    else 0)),
            V_Base     =>
              C.unsigned
                (V_Base
                 + (if Reads_Copy (Item, Slots, Head_Size, Value_Size, False)
                    then Model_Runner.Numerics.Element_Count (Copy_At (Item))
                    else 0)
                 --  Off the values' buffer front where the copy is split
                 --  and this is the global base -- a whole-layer step's is
                 --  already the values' own and is left as it is.
                 - (if Item.Copy_Split
                      and then V_Base >= Model_Runner.Numerics.Element_Count
                                           (Item.Copy_Keys_Halves)
                    then Model_Runner.Numerics.Element_Count
                           (Item.Copy_Keys_Halves)
                    else 0)),
            KV_Width   => C.unsigned (KV_Width),
            V_Width    => C.unsigned (V_Width),
            Scale      => C.C_float (Scale),
            Cap        => C.C_float (Cap),
            Positions  => C.unsigned (Slots),
            Window     => C.unsigned (Window),
            Causal     => (if Causal then 1 else 0),
            Max_Bias   => C.C_float (Max_Bias),

            --  Never a round: this is the single call, one session's own
            --  positions. And no sinks: a layer with them goes over as a
            --  sequence or on the host. Nor pages: the cache it reads is
            --  the one it was just given, whole.
            Table_At   => 0,
            Sinks_At   => 0,
            Pages_At   => 0,
            Page_Shift => 0);
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            return;
         end if;

         --  This path records into the same buffer a sequence may
         --  still be executing from, and waits for its own work, so
         --  everything in flight finishes first.
         declare
            Settled : Boolean;
         begin
            Settle (Item, Settled);

            if not Settled then
               return;
            end if;
         end;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Opened (Item.Buffer, Start, Began'Address) /= 0
         then
            return;
         end if;

         Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute,
            Attend_Kernel (Item, Slots, Head_Size, Value_Size));
         Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Attention_Bytes, Shape'Address);
         --  A workgroup a head of a position, or of a block of them where
         --  the tiled kernel is bound: its invocations divide the cached
         --  positions between them, and the positions of a batch do not
         --  need each other, so they go in one submission rather than one
         --  each.
         --  The matrix kernel takes its blocks along the first axis and
         --  its heads along the second; see attention_matrix.comp.
         if Attends_By_Matrix (Item, Slots, Head_Size, Value_Size) then
            Dispatch (Item.Buffer,
                      Attend_Groups (Item, Slots, Head_Size, Value_Size),
                      C.unsigned (Heads), 1);
         else
            Dispatch (Item.Buffer, C.unsigned (Heads),
                      Attend_Groups (Item, Slots, Head_Size, Value_Size), 1);
         end if;

         if Stop (Item.Buffer) /= 0 then
            return;
         end if;
      end;

      Submit_And_Wait (Item, Good, Cancelled, null);
      if not Good then
         return;
      end if;

      declare
         Good_Map : Boolean;
      begin
         Standing (Item, Item.Result_Memory, Item.Result_At,
                   Item.Result_Bytes, Good_Map);
         if not Good_Map then
            return;
         end if;

         declare
            --  Every position's blend, not the first one's: a batch that
            --  read back one position's worth would leave the rest holding
            --  whatever was there, which is an answer and a wrong one.
            Slice : Model_Runner.Numerics.Real_Array
              (Target'First
               .. Target'First
                  + Model_Runner.Numerics.Element_Count (Slots)
                    * Model_Runner.Numerics.Element_Count (Heads)
                    * Model_Runner.Numerics.Element_Count (Value_Size) - 1)
              with Import, Address => Item.Result_At;
         begin
            Target (Slice'Range) := Slice;
         end;
      end;

      Ok := True;
   end Attend_Resident;

   ------------
   -- Attend --
   ------------

   procedure Attend
     (Item       : in out Engine;
      Cache      : Model_Runner.Numerics.Real_Array;
      Query      : Model_Runner.Numerics.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count;
      V_Base     : Model_Runner.Numerics.Element_Count;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Target     : out Model_Runner.Numerics.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0)
   is
      Good : Boolean;
   begin
      Ok := False;

      --  The cache put where the kernel reads it, then the kernel. Kept as
      --  one call for a caller with a cache in hand; a caller that writes a
      --  position at a time uses the two beneath it and pays the upload once
      --  rather than once a call.
      --  A whole cache handed over at once is read as an exact session's
      --  is, halves and all.
      Reserve (Item, Cache'Length, Cache'Length, Good);
      if not Good then
         return;
      end if;

      Put_Cache (Item, 0, Cache, Good);
      if not Good then
         return;
      end if;

      Attend_Resident
        (Item, Query, Heads, Head_Size, Value_Size, Group_Size,
         First, Last, K_Base, V_Base, KV_Width, V_Width, Scale, Cap,
         Target, Ok, Positions, Window, Causal, Max_Bias);
   end Attend;

   --------------
   -- Multiply --
   --------------

   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Positive;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Cancelled : out Boolean;
      Key     : System.Address := System.Null_Address;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null) is
   begin
      --  A product of one, which is what a sequence of one performs. Kept as
      --  its own entry point because every caller has one matrix in hand and
      --  nothing to gain from naming a sequence to hold it.
      One_Product
        (Item, Weights, At_Byte, Packing, Rows, Columns, Vectors, Count,
         Target, Ok, Cancelled, Key, Cancel);
   end Multiply;

   -------------------
   -- Open_Sequence --
   -------------------

   ----------
   -- Hold --
   ----------

   procedure Hold
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Key     : System.Address;
      Ok      : out Boolean;
      Ahead   : Boolean := False)
   is
      Wide : constant Interfaces.Unsigned_64 := Row_Bytes (Packing, Columns);
      Size : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Rows) * Wide;

      --  Room in some heap beside what is kept and kept back, as the
      --  acquiring counts it, so that nothing need be given back.
      function Fits (Tier : Tier_Index) return Boolean
      is (Item.Tier_Kept (Tier) + Item.Tier_Spare (Tier) + Size <= Item.Tier_Limit (Tier));

      Buffer, Memory : Address := Null_Handle;
      Base     : Interfaces.Unsigned_64 := 0;
      Borrowed : Boolean := False;
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Rows = 0 or else Wide = 0
        or else Key = System.Null_Address
        or else Interfaces.Unsigned_64 (Weights'Length)
                < Interfaces.Unsigned_64 (At_Byte)
                  + Interfaces.Unsigned_64 (Rows) * Wide
      then
         return;
      end if;

      if Ahead then
         --  Held already: nothing to do, and nothing to wait for.
         if Index_Find (Item, Key, Size, Packing, Rows, Columns) /= 0 then
            Ok := True;
            return;
         end if;

         --  Nothing given back for it: what goes may be what is running.
         if Item.Budget > 0
           and then not Fits (1)
           and then (Item.Second < 0 or else not Fits (2))
         then
            return;
         end if;
      else
         --  Nothing in flight may be reading a matrix this evicts, so the
         --  device is settled first; a load is the only caller and nothing
         --  is in flight then.
         Settle (Item, Ok);
         if not Ok then
            return;
         end if;
      end if;

      --  Ahead, pinned at nought: no kept matrix is old enough to go.
      Acquire_Weights
        (Item, Weights, At_Byte, Packing, Rows, Columns, Size,
         Buffer, Memory, Base, Borrowed, Ok, Key,
         Pinned => (if Ahead then 0 else Interfaces.Unsigned_64'Last));

      --  A matrix the budget would not keep is not held: it was uploaded
      --  and is given straight back, and a product will do the same when
      --  it is asked for.
      if Borrowed then
         Give_Back_Buffer (Item, Buffer, Memory);
         Ok := False;
      end if;
   end Hold;

   procedure Open_Sequence (Steps : out Sequence) is
   begin
      Steps.Held := 0;
   end Open_Sequence;

   ------------
   -- Length --
   ------------

   function Length (Steps : Sequence) return Natural is (Steps.Held);

   function Describe (Steps : Sequence; Index : Positive) return String is
      --  The packing's own name, without the prefix every one carries and
      --  in the case the formats are written in.
      function Packing_Name (Packing : Weight_Packing) return String is
         Whole : constant String := Weight_Packing'Image (Packing);
         Word  : String := Whole (Whole'First + 7 .. Whole'Last);
      begin
         for Letter of Word loop
            if Letter in 'A' .. 'Z' and then Letter /= 'K' then
               Letter := Character'Val (Character'Pos (Letter) + 32);
            end if;
         end loop;
         return Word;
      end Packing_Name;

      --  Rows by columns, without the space 'Image puts before a number;
      --  for a routing step, how many experts of how many.
      function Shape
        (Rows, Columns : Natural; Between : String := "x") return String
      is
         R : constant String := Natural'Image (Rows);
         C : constant String := Natural'Image (Columns);
      begin
         return R (R'First + 1 .. R'Last) & Between
           & C (C'First + 1 .. C'Last);
      end Shape;
   begin
      if Index > Steps.Held then
         return "";
      end if;

      declare
         This : Step renames Steps.Items (Index);
      begin
         if This.Norms then
            return "norm " & Shape (1, This.Rows)
              & (if This.Joins then " +join" else "");
         elsif This.Rotates then
            return "rotate";
         elsif This.Places and then This.Fetches then
            return "fetch";
         elsif This.Places then
            return "place";
         elsif This.Readies then
            return "heads";
         elsif This.Attends then
            return "attend";
         elsif This.Routes then
            return "route " & Shape (This.Used, This.Columns, " of ");
         elsif This.Mixes then
            return "mix";
         elsif This.Biases then
            return "bias";
         elsif This.Assembles then
            return "assemble";
         elsif This.Picks then
            return "pick";
         elsif This.Rwkvs then
            return "rwkv " & Rwkv_Mode'Image (This.Rwkv.Mode);
         elsif This.Wkvs then
            return "wkv";
         elsif This.Mambas then
            return "mamba2 " & Mamba2_Mode'Image (This.Mamba.Mode);
         elsif This.Convolves then
            return "conv";
         elsif This.Rules then
            return "rule";
         elsif This.Inverts then
            return "invert";
         elsif This.Listed then
            return "listed " & Shape (This.Each, This.Columns) & " "
              & Packing_Name (This.Packing);
         elsif This.Blends then
            return (if This.Unit /= 2 then "combine"
                    elsif This.Folded then "join folded" else "join");
         elsif This.Glu and then This.Gathers > 0 then
            return "gated gather " & Shape (This.Each, This.Columns) & " "
              & Packing_Name (This.Packing);
         elsif This.Gathers > 0 and then This.Transposed then
            return "fold " & Shape (This.Each, This.Columns) & " "
              & Packing_Name (This.Packing);
         elsif This.Gathers > 0 then
            return "gather " & Shape (This.Each, This.Columns) & " "
              & Packing_Name (This.Packing)
              & (if This.Joins then " +join" else "");
         elsif This.Glu then
            return "gated pair " & Shape (This.Rows, This.Columns) & " "
              & Packing_Name (This.Packing);
         else
            return "product " & Shape (This.Rows, This.Columns) & " "
              & Packing_Name (This.Packing)
              & (if This.Joins then " +join" else "");
         end if;
      end;
   end Describe;

   -----------------
   -- Add_Product --
   -----------------

   procedure Add_Product
     (Steps   : in out Sequence;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address;
      Kept    : Boolean := True;
      At_Vector : Natural := 0;
      Exact   : Boolean := False)
   is
   begin
      if Steps.Held = Sequence_Limit or else Base = System.Null_Address then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => False,
         Kept => Kept, At_Vector => At_Vector,
         Blends => False, Unit => 0, Attends => False, Exact => Exact,
         others => <>);
      Added := True;
   end Add_Product;

   -------------------------
   -- Add_Chained_Product --
   -------------------------

   procedure Add_Chained_Product
     (Steps   : in out Sequence;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address;
      Kept    : Boolean := True;
      From_Step : Natural := 0;
      Rounded   : Boolean := False;
      Region_Rows : Natural := 0;
      Region_At   : Natural := 0;
      Streamed    : Boolean := False;
      Exact       : Boolean := False)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      --  Nothing to chain to, no room, or a width that does not meet the
      --  step it reads. Each is a refusal rather than something patched
      --  over: a product reading the wrong number of values would compute
      --  and be wrong.
      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Source not in 1 .. Steps.Held
        or else Columns /= Steps.Items (Source).Rows
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => True,
         Reads => (if From_Step = 0 then 0 else From_Step),
         Kept => Kept, Rounded => Rounded,
         Blends => False, Unit => 0, Attends => False,
         Region_Rows => Region_Rows, Region_At => Region_At,
         Streams => Streamed, Exact => Exact,
         others => <>);
      Added := True;
   end Add_Chained_Product;

   ---------------------
   -- Add_Tap_Product --
   ---------------------

   procedure Add_Tap_Product
     (Steps   : in out Sequence;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Row     : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address;
      Kept    : Boolean := True;
      Normed  : Boolean := False;
      Epsilon : Float := 1.0E-12) is
   begin
      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Row < 3 * Columns
      then
         Added := False;
         return;
      end if;

      --  Uploaded as the nine together, from the first.
      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => False,
         Reads => 0, Kept => Kept, Blends => False, Unit => 0,
         Attends => False,
         Region_Rows => 9 * Rows + (if Normed then Gain_Rows (Packing, Columns) else 0),
         Tap_Row => Row, Tap_Normed => Normed, Tap_Epsilon => Epsilon,
         others => <>);
      Added := True;
   end Add_Tap_Product;

   ---------------
   -- Gain_Rows --
   ---------------

   function Gain_Rows (Packing : Weight_Packing; Columns : Natural) return Natural is
      Row : constant Interfaces.Unsigned_64 := Row_Bytes (Packing, Columns);
   begin
      return Natural ((Interfaces.Unsigned_64 (Columns) * 4 + Row - 1) / Row);
   end Gain_Rows;

   ----------------
   -- Takes_Taps --
   ----------------

   function Takes_Taps
     (Item    : Engine;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural) return Boolean
   is (Uses_Matrix (Item, Packing, Rows, Columns, Count));

   ----------------
   -- Pairs_Gate --
   ----------------

   --  The words an MXFP4 pair's dispatch is told beside its shape: where
   --  its biases lie on the device, in bytes and plus one, nought for
   --  none, and the clamped gate's slope and limit by their bits. Base is
   --  where its gate's rows begin there.
   function Pair_Words
     (This : Step;
      Base : Interfaces.Unsigned_64) return Member_Words
   is
   begin
      return
        [1 => (if This.Gate_Bias_Back = 0 then 0
               else C.unsigned
                      (Base - Interfaces.Unsigned_64 (This.Gate_Bias_Back)
                       + 1)),
         2 => (if This.Up_Bias_At = 0 then 0
               else C.unsigned
                      (Base + Interfaces.Unsigned_64 (This.Up_Bias_At) + 1)),
         3 => Float_Bits (C.C_float (This.Alpha)),
         4 => Float_Bits (C.C_float (This.Limit)),
         others => 0];
   end Pair_Words;

   function Pairs_Gate
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural;
      Columns : Natural) return Boolean
   is ((Packing = Packed_Q4_K
        and then Columns mod 256 = 0
        and then ((Count = 1
                   and then Columns < Long_Row_Columns
                   and then Item.Glu_Line /= Null_Handle
                   and then Waved (Item, Packing, Count))
                  or else
                  (Count in Many_Count
                   and then Item.Glu_Many_Lines (Count) /= Null_Handle
                   and then Waved (Item, Packing, Count))))
       or else
       --  MXFP4's for one position: a mixture's gathered pair.
       (Packing = Packed_MXFP4
        and then Columns mod 32 = 0
        and then Count = 1
        and then Item.MX_Glu_Line /= Null_Handle
        and then Waved (Item, Packing, Count))
       or else
       (Packing = Packed_Q8_0
        and then Columns mod 32 = 0
        and then Waved (Item, Packing, Count)
        and then ((Count = 1
                   and then (if Q8_Short (Item, Packing, Count, Columns)
                             then Item.Q8_Glu_Short_Line /= Null_Handle
                             else Item.Q8_Glu_Line /= Null_Handle))
                  or else
                  (Count in Multi_Count
                   and then Item.Q8_Glu_Multi_Lines (Count)
                            /= Null_Handle))));

   --  Bytes a row of either format a gated pair takes holds.
   function Pair_Row_Bytes
     (Packing : Weight_Packing;
      Columns : Natural) return Model_Runner.Bytes.Byte_Count
   is (if Packing = Packed_Q8_0
       then Model_Runner.Bytes.Byte_Count (Columns / 32) * 34
       elsif Packing = Packed_MXFP4
       then Model_Runner.Bytes.Byte_Count (Columns / 32) * 17
       else Model_Runner.Bytes.Byte_Count (Columns / 256) * 144);

   ---------------
   -- Pair_Rows --
   ---------------

   function Pair_Rows
     (Pair_At : Model_Runner.Bytes.Byte_Count;
      Rows    : Natural;
      Columns : Natural;
      Packing : Weight_Packing := Packed_Q4_K;
      Lead    : Natural := 0) return Natural
   is
      Wide : constant Model_Runner.Bytes.Byte_Count :=
        Pair_Row_Bytes (Packing, Columns);
   begin
      if Wide = 0 then
         return 0;
      end if;
      return Natural
        ((Model_Runner.Bytes.Byte_Count (Lead) + Pair_At
          + Model_Runner.Bytes.Byte_Count (Rows) * Wide + Wide - 1)
         / Wide);
   end Pair_Rows;

   --------------
   -- Pair_Pad --
   --------------

   function Pair_Pad
     (Pair_At : Model_Runner.Bytes.Byte_Count;
      Rows    : Natural;
      Columns : Natural;
      Packing : Weight_Packing := Packed_Q4_K;
      Lead    : Natural := 0) return Natural
   is
      Wide : constant Model_Runner.Bytes.Byte_Count :=
        Pair_Row_Bytes (Packing, Columns);
   begin
      return Natural
        (Model_Runner.Bytes.Byte_Count
           (Pair_Rows (Pair_At, Rows, Columns, Packing, Lead))
         * Wide
         - Pair_At - Model_Runner.Bytes.Byte_Count (Rows) * Wide);
   end Pair_Pad;

   --------------------
   -- Add_Gated_Pair --
   --------------------

   procedure Add_Gated_Pair
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Pair_At   : Model_Runner.Bytes.Byte_Count;
      Packing   : Weight_Packing;
      Rows      : Natural;
      Columns   : Natural;
      Added     : out Boolean;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True;
      From_Step : Natural := 0;
      Unit      : Natural := 0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      --  Bytes a row holds.
      Wide : constant Model_Runner.Bytes.Byte_Count :=
        Pair_Row_Bytes (Packing, Columns);
   begin
      Added := False;
      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Packing not in Packed_Q4_K | Packed_Q8_0
        or else Unit > 1
        or else Columns = 0
        or else Columns mod (if Packing = Packed_Q8_0 then 32 else 256) /= 0
        or else Rows = 0
        or else Source not in 1 .. Steps.Held
        or else Columns /= Steps.Items (Source).Rows
        or else Pair_At < Model_Runner.Bytes.Byte_Count (Rows) * Wide
        or else Pair_At > Model_Runner.Bytes.Byte_Count (Natural'Last / 2)
        or else Span < At_Byte
                       + Model_Runner.Bytes.Byte_Count
                           (Pair_Pad (Pair_At, Rows, Columns, Packing))
                       + Pair_At
                       + Model_Runner.Bytes.Byte_Count (Rows) * Wide
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => True,
         Reads => (if From_Step = 0 then 0 else From_Step),
         Kept => Kept,
         Blends => False, Unit => Unit, Attends => False,
         Glu => True, Pair_At => Natural (Pair_At),
         Region_Rows => Pair_Rows (Pair_At, Rows, Columns, Packing),
         Region_At => Pair_Pad (Pair_At, Rows, Columns, Packing),
         others => <>);
      Added := True;
   end Add_Gated_Pair;

   -----------------------
   -- Add_Gathered_Pair --
   -----------------------

   procedure Add_Gathered_Pair
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Pair_At   : Model_Runner.Bytes.Byte_Count;
      Packing   : Weight_Packing;
      Stack     : Natural;
      Each      : Natural;
      Columns   : Natural;
      Count     : Positive;
      Routed    : Positive;
      Added     : out Boolean;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True;
      From_Step : Natural := 0;
      Unit      : Natural := 0;
      Lead      : Natural := 0;
      Gate_Bias_Back : Natural := 0;
      Up_Bias_At     : Natural := 0;
      Alpha     : Model_Runner.Numerics.Real := 0.0;
      Limit     : Model_Runner.Numerics.Real := 0.0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      --  Bytes a row holds.
      Wide : constant Model_Runner.Bytes.Byte_Count :=
        Pair_Row_Bytes (Packing, Columns);

      MX : constant Boolean := Packing = Packed_MXFP4;
   begin
      Added := False;
      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Packing not in Packed_Q4_K | Packed_MXFP4
        or else (if MX then Unit not in 0 | 1 | 3 else Unit > 1)
        or else (not MX and then (Lead > 0 or else Gate_Bias_Back > 0
                                  or else Up_Bias_At > 0))
        or else Gate_Bias_Back > Lead
        or else Columns = 0
        or else Columns mod (if MX then 32 else 256) /= 0
        or else Each = 0
        or else Stack < Each
        or else Count > Max_Gather
        or else Source not in 1 .. Steps.Held
        or else Columns /= Steps.Items (Source).Rows
        or else Routed > Steps.Held
        or else not Steps.Items (Routed).Routes
        or else Steps.Items (Routed).Used /= Count
        or else Pair_At < Model_Runner.Bytes.Byte_Count (Stack) * Wide
        or else Pair_At > Model_Runner.Bytes.Byte_Count (Natural'Last / 2)
        or else Span < At_Byte
                       + Model_Runner.Bytes.Byte_Count
                           (Pair_Pad (Pair_At, Stack, Columns, Packing, Lead))
                       + Pair_At
                       + Model_Runner.Bytes.Byte_Count (Stack) * Wide
      then
         return;
      end if;

      --  Uploaded as a gather is, the whole region; Stack is its rows.
      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Each * Count, Columns => Columns, Key => Key,
         Chained => True,
         Reads => (if From_Step = 0 then 0 else From_Step),
         Kept => Kept,
         Blends => False, Unit => Unit, Attends => False,
         Glu => True, Pair_At => Natural (Pair_At),
         Gathers => Count, Each => Each, Routed => Routed,
         Stack => Pair_Rows (Pair_At, Stack, Columns, Packing, Lead),
         Region_At => Pair_Pad (Pair_At, Stack, Columns, Packing, Lead),
         Gate_Bias_Back => Gate_Bias_Back, Up_Bias_At => Up_Bias_At,
         Alpha => Alpha, Limit => Limit,
         others => <>);
      Added := True;
   end Add_Gathered_Pair;

   --------------------------
   -- Add_Gathered_Product --
   --------------------------

   procedure Add_Gathered_Product
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Packing   : Weight_Packing;
      Stack     : Natural;
      Each      : Natural;
      Columns   : Natural;
      Members   : Member_List;
      Count     : Positive;
      Added     : out Boolean;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True;
      Chained   : Boolean := False;
      From_Step : Natural := 0;
      Apart     : Natural := 0;
      Routed    : Natural := 0;
      Region_At : Natural := 0;
      Transposed : Boolean := False;
      Slice_Rows : Natural := 0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      --  Rows from one expert's slice to the next's.
      Apart_Rows : constant Natural := (if Slice_Rows = 0 then Each else Slice_Rows);

      --  How wide a member's vector is: a row's width, or read down the
      --  columns a slice's rows.
      Reads_Wide : constant Natural := (if Transposed then Each else Columns);

      --  What a chained gather reads: each member its own stretch of the
      --  source, or all of them the whole of it. Read down the columns, a
      --  member's stretch may be wider than its vector, which is its front.
      Wanted : constant Natural :=
        (if Apart > 0 then Apart * Count else Reads_Wide);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Count > Max_Gather
        or else Each = 0
        or else Stack < Each
        or else (Apart > 0
                 and then (if Transposed then Apart < Each
                           else Apart /= Reads_Wide))
        or else (Transposed and then (Routed /= 0 or else Region_At /= 0
                                      or else Slice_Rows /= 0))
        or else (Slice_Rows /= 0 and then Slice_Rows < Each)
        --  A region of a pair's layout, or -- with Slice_Rows -- of any
        --  format, rows being rows.
        or else (Region_At /= 0
                 and then ((Slice_Rows = 0
                            and then Packing not in Packed_Q4_K | Packed_MXFP4)
                           or else Model_Runner.Bytes.Byte_Count (Region_At)
                                   >= Model_Runner.Bytes.Byte_Count (Stack)
                                      * Model_Runner.Bytes.Byte_Count
                                          (Row_Bytes (Packing, Columns))))
        or else (Chained
                 and then (Steps.Held = 0
                           or else Source not in 1 .. Steps.Held
                           or else Steps.Items (Source).Rows /= Wanted))

        --  Routed, the step it names has to be a routing step that chose
        --  exactly this many, and the members it wrote are what is read.
        or else (Routed /= 0
                 and then (Routed > Steps.Held
                           or else not Steps.Items (Routed).Routes
                           or else Steps.Items (Routed).Used /= Count))
      then
         return;
      end if;

      if Routed = 0 then
         declare
            --  Rows of the region before the stack's own, whole or not:
            --  a pair's layout's rows, or -- with Slice_Rows -- the
            --  format's own.
            Row : constant Model_Runner.Bytes.Byte_Count :=
              (if Slice_Rows /= 0
               then Model_Runner.Bytes.Byte_Count (Row_Bytes (Packing, Columns))
               else Pair_Row_Bytes (Packing, Columns));
            Lead : constant Natural :=
              (if Region_At = 0 then 0
               else Natural
                      ((Model_Runner.Bytes.Byte_Count (Region_At) + Row - 1)
                       / Row));
         begin
            for Index in 1 .. Count loop
               if Lead + Members (Index) * Apart_Rows + Each > Stack then
                  return;
               end if;
            end loop;
         end;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => (if Transposed then Columns else Each) * Count,
         Columns => Columns, Key => Key,
         Chained => Chained,
         Reads => (if Chained and then From_Step /= 0 then From_Step else 0),
         Kept => Kept,
         Blends => False, Unit => 0, Attends => False,
         Gathers => Count, Members => Members, Stack => Stack,
         Each => Each, Apart => Apart, Routed => Routed,
         Region_At => Region_At, Transposed => Transposed,
         Slice_Rows => Slice_Rows,
         others => <>);
      Added := True;
   end Add_Gathered_Product;

   ----------------
   -- Folds_Down --
   ----------------

   --  Positions fold.comp answers a workgroup; see its POS.
   Fold_Positions : constant := 4;

   function Folds_Down
     (Item    : Engine;
      Packing : Weight_Packing;
      Each    : Natural;
      Columns : Natural;
      Count   : Natural) return Boolean
   is (Item.Fold_Line /= Null_Handle
       and then Each > 0
       and then Count in 1 .. 2 * Fold_Positions
       and then (case Packing is
                   when Packed_Q4_K | Packed_Q6_K => Columns mod 256 = 0,
                   when Packed_Q8_0 => Columns mod 32 = 0,
                   when others => False));

   ---------------
   -- Add_Route --
   ---------------

   procedure Add_Route
     (Steps     : in out Sequence;
      Experts   : Natural;
      Used      : Natural;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Kept      : Boolean := True;
      Bias      : System.Address := System.Null_Address;
      Bias_Span : Model_Runner.Bytes.Byte_Count := 0;
      Bias_At   : Model_Runner.Bytes.Byte_Count := 0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      Added := False;

      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Source not in 1 .. Steps.Held
        or else Used = 0
        or else Used > Max_Route
        or else Experts < Used

        --  No more than route.comp holds a position, which would choose
        --  among the first of them and say nothing of the rest.
        or else Experts > Max_Experts
        or else Steps.Items (Source).Rows /= Experts
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Bias, Span => Bias_Span, At_Byte => Bias_At,
         Packing => Weight_Packing'First,
         Rows => 2 * Used, Columns => Experts,
         Key => Bias,
         Chained => True, Reads => Source,
         Kept => Kept, Routes => True, Used => Used,
         Joins => Bias /= System.Null_Address,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Route;

   -------------
   -- Add_Mix --
   -------------

   procedure Add_Invert
     (Steps      : in out Sequence;
      Experts    : Natural;
      Used       : Natural;
      Route_Step : Positive;
      Added      : out Boolean;
      Kept       : Boolean := False) is
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Route_Step > Steps.Held
        or else not Steps.Items (Route_Step).Routes
        or else Steps.Items (Route_Step).Used /= Used
        or else Steps.Items (Route_Step).Columns /= Experts
        or else Experts = 0
        or else Experts > Max_Experts
      then
         return;
      end if;

      --  Rows is room (Invert_Rows), a step's room being Rows a
      --  position.
      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Invert_Rows (Experts, Used), Columns => Experts,
         Chained => True, Reads => Route_Step,
         Kept => Kept, Inverts => True, Used => Used,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Invert;

   --  Slots a position, with the padding: fifteen slots at most for each
   --  expert that has a run, spread over the positions -- where the batch
   --  is long enough for the tile, which stores sixteen at a time. A
   --  shorter batch's runs are tight (invert.comp), and its slots are the
   --  positions' own: a check of five padded to a hundred and twenty-eight
   --  slots a position, and the combining after it went over all of them,
   --  sixteen times what there was.
   function Run_Slots
     (Experts : Natural;
      Used    : Natural;
      Count   : Natural) return Natural
   is (if Count < Tile_Least then Used
       else Used + (15 * Natural'Min (Experts, Count * Used) + Count - 1)
                   / Count);

   --  Where invert.comp writes how many experts have a run and which,
   --  in words from the front of its lists: past two words an expert,
   --  the runs of positions and of shares with their padding, and a
   --  slot a position and rank.
   function Used_List_At
     (Experts : Natural;
      Count   : Natural;
      Used    : Natural) return Natural
   is (32 * Natural'Min (Experts, 512) + 3 * Count * Used);

   procedure Add_Listed_Product
     (Steps       : in out Sequence;
      Base        : System.Address;
      Span        : Model_Runner.Bytes.Byte_Count;
      At_Byte     : Model_Runner.Bytes.Byte_Count;
      Packing     : Weight_Packing;
      Stack       : Natural;
      Each        : Natural;
      Columns     : Natural;
      Experts     : Natural;
      Used        : Natural;
      Invert_Step : Positive;
      Count       : Positive;
      Added       : out Boolean;
      Key         : System.Address := System.Null_Address;
      Kept        : Boolean := True;
      From_Step   : Natural := 0;
      By_Slot     : Boolean := False;
      Chained     : Boolean := True;
      Region_At   : Natural := 0;
      Slice_Rows  : Natural := 0)
   is
      Apart_Rows : constant Natural := (if Slice_Rows = 0 then Each else Slice_Rows);

      Source : constant Natural :=
        (if not Chained then 0
         elsif From_Step = 0 then Steps.Held else From_Step);

      Slots : constant Natural := Run_Slots (Experts, Used, Count);

      --  What the source holds a position: the vectors themselves, or
      --  the slots' worth where they are read by slot.
      Wanted : constant Natural :=
        (if By_Slot then Columns * Slots else Columns);
   begin
      Added := False;

      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Each = 0
        or else Experts = 0
        or else (Slice_Rows /= 0 and then Slice_Rows < Each)
        or else Apart_Rows * (Experts - 1) + Each > Stack
        or else Model_Runner.Bytes.Byte_Count (Region_At)
                + Model_Runner.Bytes.Byte_Count (Apart_Rows * (Experts - 1) + Each)
                  * Model_Runner.Bytes.Byte_Count (Row_Bytes (Packing, Columns))
                > Model_Runner.Bytes.Byte_Count (Stack)
                  * Model_Runner.Bytes.Byte_Count (Row_Bytes (Packing, Columns))
        or else (Region_At /= 0 and then Slice_Rows = 0
                 and then Packing not in Packed_Q4_K | Packed_Q8_0 | Packed_MXFP4)
        or else (Chained
                 and then (Source not in 1 .. Steps.Held
                           or else Steps.Items (Source).Rows /= Wanted))
        or else (not Chained
                 and then (By_Slot
                           or else Steps.Items (1).Columns /= Columns))
        or else Invert_Step > Steps.Held
        or else not Steps.Items (Invert_Step).Inverts
        or else Steps.Items (Invert_Step).Used /= Used
        or else Steps.Items (Invert_Step).Columns /= Experts
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Each * Slots, Columns => Columns, Key => Key,
         Chained => Chained, Reads => Source,
         Kept => Kept,
         Blends => False, Unit => 0, Attends => False,
         Gathers => Experts, Stack => Stack, Each => Each,
         Routed => Invert_Step, Used => Used,
         Listed => True, By_Slot => By_Slot,
         Region_At => Region_At, Slice_Rows => Slice_Rows,
         others => <>);
      Added := True;
   end Add_Listed_Product;

   procedure Add_Mix
     (Steps         : in out Sequence;
      Width         : Natural;
      Used          : Natural;
      Downs_Step    : Positive;
      Route_Step    : Positive;
      Added         : out Boolean;
      Residual_Step : Natural := 0;
      Kept          : Boolean := True) is
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Width = 0
        or else Used = 0
        or else Downs_Step > Steps.Held
        or else Route_Step > Steps.Held
        or else Residual_Step > Steps.Held
        or else not (Steps.Items (Route_Step).Routes
                     or else Steps.Items (Route_Step).Inverts)
        or else Steps.Items (Route_Step).Used /= Used
        or else Steps.Items (Downs_Step).Listed
                /= Steps.Items (Route_Step).Inverts
        or else (not Steps.Items (Downs_Step).Listed
                 and then Steps.Items (Downs_Step).Gathers /= Used)
        or else (if Steps.Items (Downs_Step).Listed
                 then Steps.Items (Downs_Step).Each /= Width
                 else Steps.Items (Downs_Step).Rows /= Used * Width)
        or else (Residual_Step /= 0
                 and then Steps.Items (Residual_Step).Rows /= Width)
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => Width,
         Chained => True, Reads => Downs_Step, Reads_Two => Route_Step,
         Joins => Residual_Step /= 0, Joined => Residual_Step,
         Kept => Kept, Mixes => True, Used => Used,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Mix;

   --------------
   -- Add_Bias --
   --------------

   procedure Add_Bias
     (Steps       : in out Sequence;
      Base        : System.Address;
      Span        : Model_Runner.Bytes.Byte_Count;
      At_Byte     : Model_Runner.Bytes.Byte_Count;
      Experts     : Natural;
      Each        : Natural;
      Source_Step : Positive;
      Route_Step  : Natural;
      Added       : out Boolean;
      Key         : System.Address := System.Null_Address;
      Kept        : Boolean := True;
      Members     : Member_List := [others => 0];
      Count       : Natural := 0;
      Source_At     : Natural := 0;
      Source_Stride : Natural := 0;
      Cap           : Model_Runner.Numerics.Real := 0.0;
      Fold          : Boolean := False;
      Multiply      : Boolean := False;
      Per_Member    : Boolean := False;
      Fresh         : Boolean := False) is

      use type Model_Runner.Numerics.Real;

      --  A bound with no bias: a projection's rows, capped and nothing
      --  added.
      Cap_Only : constant Boolean :=
        Base = System.Null_Address and then Cap > 0.0;

      --  A sliced bias reads Each rows out of a wider fused product, its own
      --  lying at Source_At and every Source_Stride after; the stride is the
      --  fused product's whole row count. Both zero is the ordinary bias
      --  whose rows are all of its source's, laid one position after another.
      Sliced : constant Boolean := Source_Stride /= 0;
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else (Base = System.Null_Address and then not Cap_Only)
        or else (Cap_Only
                 and then (Experts /= 1 or else Route_Step /= 0
                           or else Count /= 0 or else Source_Stride /= 0))
        or else Cap < 0.0
        or else Experts = 0
        or else Each = 0
        or else (not Cap_Only
                 and then Span
                          < At_Byte
                            + Model_Runner.Bytes.Byte_Count (Experts * Each)
                              * 4)
        or else Source_Step > Steps.Held
        or else Route_Step > Steps.Held
        or else (not Sliced and then Steps.Items (Source_Step).Rows mod Each /= 0)
        or else Count > Max_Gather
        or else (Count > 0 and then Route_Step /= 0)
        or else (for some Index in 1 .. Count => Members (Index) >= Experts)
        --  A sliced bias: one slice, over Each rows lying within a fused
        --  product whose stride is its whole row count and which holds the
        --  slice Source_At begins.
        or else (Sliced
                 and then (Experts /= 1
                           or else Count /= 0
                           or else Route_Step /= 0
                           or else Source_Stride /= Steps.Items (Source_Step).Rows
                           or else Source_At + Each > Source_Stride))
        --  A projection's bias: one slice, over a product of Each rows --
        --  or, a slice a position, as many as the positions.
        or else (not Sliced and then Route_Step = 0 and then Count = 0
                 and then ((Experts /= 1 and then not Per_Member)
                           or else Steps.Items (Source_Step).Rows /= Each))
        --  A weight a position is a projection's alone, uncapped and
        --  unfolded; one that multiplies is a projection's or an expert's
        --  by its routing -- Gemma4's scale an expert -- unsliced,
        --  uncapped and unfolded.
        or else (Per_Member
                 and then (Sliced or else Route_Step /= 0 or else Count /= 0
                           or else Cap_Only or else Cap /= 0.0 or else Fold))
        or else (Multiply
                 and then (Sliced or else Count /= 0
                           or else Cap_Only or else Cap /= 0.0 or else Fold))
        or else (Per_Member and then not Multiply)
        --  A fresh weight is a projection's, read where it lies each run.
        or else (Fresh
                 and then (Base = System.Null_Address
                           or else Key /= System.Null_Address
                           or else Sliced or else Route_Step /= 0 or else Count /= 0
                           or else Cap /= 0.0 or else Fold))
        --  A gather the host chose: as many members as the source has.
        or else (Count > 0
                 and then Steps.Items (Source_Step).Gathers /= Count)
        --  An expert's: a gathered product of Each a member, and the
        --  routing it was gathered by.
        or else (Route_Step /= 0
                 and then (Steps.Items (Source_Step).Gathers = 0
                           or else Steps.Items (Source_Step).Each /= Each
                           or else not (Steps.Items (Route_Step).Routes
                                        or else Steps.Items (Route_Step).Inverts)
                           or else Steps.Items (Source_Step).Listed
                                   /= Steps.Items (Route_Step).Inverts
                           or else (Steps.Items (Route_Step).Inverts
                                    and then Steps.Items (Route_Step).Columns
                                             /= Experts)))
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte,
         Packing => Weight_Packing'First,
         --  A sliced bias writes Each rows, the slice it took; an ordinary
         --  one writes all of its source's.
         Rows => (if Sliced then Each else Steps.Items (Source_Step).Rows),
         Columns => (if Sliced then Each else Steps.Items (Source_Step).Rows),
         Reads_At => Source_At, Reads_Stride => Source_Stride,
         Key => Key,
         Chained => True, Reads => Source_Step, Reads_Two => Route_Step,
         Kept => Kept, Biases => True, Cap => Cap,
         Scales => Multiply, Per_Member => Per_Member, Fresh => Fresh,
         Stack => (if Cap_Only then 0 else Experts), Each => Each,
         Used => (if Count > 0 then Count
                  elsif Route_Step = 0 then 0
                  else Steps.Items (Route_Step).Used),
         Members => Members,
         Listed => Steps.Items (Source_Step).Listed,
         --  The source's gather, so that what read the source -- the mix,
         --  which asks how many members its downs hold -- reads this.
         Gathers => Steps.Items (Source_Step).Gathers,
         --  Kept off the tile whatever the count, as a norm is: this
         --  is not a product, and its room is its source's.
         Exact => True,
         Attends => False, Blends => False,
         others => <>);

      --  Folded into its product's store, where that product is plain,
      --  just named, read by nothing else and joined to nothing yet.
      if Fold
        and then not Cap_Only and then Cap = 0.0
        and then not Sliced and then Route_Step = 0 and then Count = 0
        and then Experts = 1
        and then Source_Step = Steps.Held - 1
      then
         declare
            That : Step renames Steps.Items (Source_Step);
         begin
            if not (That.Kept or else That.Joins or else That.Folded
                    or else That.Gathers > 0 or else That.Listed
                    or else That.Norms or else That.Rotates
                    or else That.Places or else That.Readies
                    or else That.Attends or else That.Routes
                    or else That.Mixes or else That.Biases
                    or else That.Picks or else That.Convolves
                    or else That.Rules or else That.Rwkvs
                    or else That.Wkvs or else That.Mambas
                    or else That.Inverts or else That.Blends)
            then
               Steps.Items (Steps.Held).Folded := True;
               That.Joins := True;
               That.Joined := Steps.Held;
            end if;
         end;
      end if;
      Added := True;
   end Add_Bias;

   --------------
   -- Add_Pick --
   --------------

   procedure Add_Pick
     (Steps     : in out Sequence;
      Rows      : Natural;
      Each      : Natural;
      Which     : Natural;
      Among     : Positive;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Rows = 0
        or else Each = 0
        or else Rows mod Each /= 0
        or else Which >= Among
        or else Source not in 1 .. Steps.Held
        or else Steps.Items (Source).Rows /= Rows * Among
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Rows, Columns => Rows * Among,
         Key => System.Null_Address,
         Chained => True, Reads => Source, Kept => Kept,
         Picks => True, Each => Each, Which => Which, Among => Among,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Pick;

   ------------------
   -- Add_Assemble --
   ------------------

   procedure Add_Assemble
     (Steps  : in out Sequence;
      Heads  : Natural;
      A_Step : Natural;
      B_Step : Natural;
      Shape  : Assemble_Shape;
      Added  : out Boolean;
      Kept   : Boolean := True)
   is
      Head_Width : constant Natural := Shape (1) + Shape (5);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Heads = 0
        or else Head_Width = 0
        or else A_Step not in 1 .. Steps.Held
        or else B_Step not in 1 .. Steps.Held
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Heads * Head_Width, Columns => Heads * Head_Width,
         Key => System.Null_Address,
         Chained => True, Reads => A_Step, Reads_Two => B_Step, Kept => Kept,
         Picks => True, Assembles => True, Shapes => Shape,
         Each => Head_Width, Which => Heads, Among => 1,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Assemble;

   --------------
   -- Add_Conv --
   --------------

   procedure Add_Conv
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Shape     : Linear_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Shape.Mix = 0
        or else Shape.Head = 0
        or else (Shape.Gated and then Shape.Mix mod 3 /= 0)
        or else Conv_Width (Shape) mod Shape.Head /= 0
        or else Shape.Taps < 2
        or else Shape.Unit_Blocks > Conv_Width (Shape) / Shape.Head
        or else (Shape.Gated and then Shape.Unit_Blocks /= 0)
        or else Shape.Every = 0
        or else Source not in 1 .. Steps.Held
        or else Steps.Items (Source).Rows /= Shape.Mix
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte,
         Packing => Weight_Packing'First,
         Rows => Conv_Width (Shape), Columns => Shape.Mix,
         Key => Key, Chained => True, Reads => Source, Kept => Kept,
         Convolves => True, Linear => Shape,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Conv;

   --------------
   -- Add_Rule --
   --------------

   procedure Add_Rule
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Shape     : Linear_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      Wide : constant Natural := Shape.Value_Heads * Shape.Head;
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Shape.Mix = 0
        or else Shape.Head = 0
        or else Shape.Key_Heads = 0
        or else Shape.Value_Heads = 0
        or else Shape.Value_Heads mod Shape.Key_Heads /= 0
        or else Shape.Key_Width /= Shape.Key_Heads * Shape.Head
        or else Shape.Mix /= 2 * Shape.Key_Width + Wide
        or else Shape.Every = 0
        or else Source not in 1 .. Steps.Held
        or else Steps.Items (Source).Rows /= Shape.Mix
        or else Shape.Z_Step not in 1 .. Steps.Held
        or else Steps.Items (Shape.Z_Step).Rows /= Wide
        or else Shape.Alpha_Step not in 1 .. Steps.Held
        or else Steps.Items (Shape.Alpha_Step).Rows /= Shape.Value_Heads
        or else Shape.Beta_Step not in 1 .. Steps.Held
        or else Steps.Items (Shape.Beta_Step).Rows /= Shape.Value_Heads
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte,
         Packing => Weight_Packing'First,
         Rows => Wide, Columns => Shape.Mix,
         Key => Key, Chained => True, Reads => Source, Kept => Kept,
         Rules => True, Linear => Shape,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Rule;

   --------------
   -- Add_Rwkv --
   --------------

   procedure Add_Rwkv
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      Shape     : Rwkv_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      --  Whether a step named holds Wide a position.
      function Holds (Which : Natural; Wide : Natural) return Boolean
      is (Which in 1 .. Steps.Held and then Steps.Items (Which).Rows = Wide);

      Read : Natural := 0;
      Rows : Natural := 0;
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Shape.Width = 0
        or else Shape.Low > 64
        or else Source not in 1 .. Steps.Held
      then
         return;
      end if;

      Read := Steps.Items (Source).Rows;

      case Shape.Mode is
         when Shift =>
            if Shape.Streams = 0
              or else Read /= Shape.Width
              or else (Shape.Low > 0
                       and then not Holds (Shape.Low_Step,
                                           Shape.Streams * Shape.Low))
            then
               return;
            end if;
            Rows := Shape.Streams * Shape.Width;
         when Decay =>
            if Shape.Low = 0
              or else not Holds (Shape.Low_Step, Shape.Low)
            then
               return;
            end if;
            Rows := Shape.Width;
         when Tanh | Squared_Relu =>
            if Read /= Shape.Width then
               return;
            end if;
            Rows := Shape.Width;
         when Finish =>
            if Read /= Shape.Width
              or else not Holds (Shape.B_Step, Shape.Width)
              or else not Holds (Shape.C_Step, Shape.Width)
            then
               return;
            end if;
            Rows := Shape.Width;
         when Save =>
            if Read /= Shape.Width
              or else not Holds (Shape.B_Step, Shape.Width)
            then
               return;
            end if;
            Rows := 1;
      end case;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Rows, Columns => Read,
         Key => Key, Chained => True, Reads => Source, Kept => Kept,
         Rwkvs => True, Rwkv => Shape,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Rwkv;

   -------------
   -- Add_Wkv --
   -------------

   procedure Add_Wkv
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      Shape     : Wkv_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      Wide : constant Natural := Shape.Heads * Shape.Head;

      function Holds (Which : Natural) return Boolean
      is (Which in 1 .. Steps.Held and then Steps.Items (Which).Rows = Wide);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Shape.Heads = 0
        or else Shape.Head /= Wkv_Head
        or else not Holds (Source)
        or else not Holds (Shape.K_Step)
        or else not Holds (Shape.V_Step)
        or else not Holds (Shape.W_Step)
        or else not Holds (Shape.G_Step)
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Wide, Columns => Wide,
         Key => Key, Chained => True, Reads => Source, Kept => Kept,
         Wkvs => True, Wkv => Shape,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Wkv;

   ----------------
   -- Add_Mamba2 --
   ----------------

   procedure Add_Mamba2
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      Shape     : Mamba2_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      function Holds (Which : Natural; Wide : Natural) return Boolean
      is (Which in 1 .. Steps.Held and then Steps.Items (Which).Rows = Wide);

      Rows : Natural := 0;
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Shape.Inner = 0
        or else Shape.Taps < 1
        or else not Holds (Shape.XZ_Step, Shape.In_Out)
        or else (case Shape.Version is
                    when 2 =>
                       Shape.Groups = 0
                       or else Shape.Heads = 0
                       or else Shape.Heads mod Shape.Groups /= 0
                       or else Shape.Inner mod Shape.Groups /= 0
                       or else Shape.DXBC
                               /= Shape.Inner + 2 * Shape.Groups * Shape.State
                       or else Shape.In_Out /= Shape.Inner + Shape.DXBC
                       or else Shape.X_At /= Shape.Inner
                       or else not Holds (Shape.Dt_Step, Shape.Heads),
                    when 1 =>
                       Shape.DXBC /= Shape.Inner
                       or else Shape.In_Out /= 2 * Shape.Inner
                       or else Shape.X_At /= 0
                       or else Shape.Mode = Gate
                       or else (Shape.Mode = Scan
                                and then
                                  (Shape.State = 0
                                   or else Shape.State > Mamba_Most_State
                                   or else not Holds (Shape.Dt_Step,
                                                      Shape.Inner)
                                   or else not Holds
                                     (Shape.Dbc_Step,
                                      Shape.Rank + 2 * Shape.State))),
                    when others => True)
      then
         return;
      end if;

      case Shape.Mode is
         when Conv | Save =>
            if Source /= Shape.XZ_Step then
               return;
            end if;
            Rows := (if Shape.Mode = Conv then Shape.DXBC else 1);
         when Scan =>
            if (Shape.Version = 2
                and then (Shape.Head /= Mamba2_Head
                          or else Shape.State /= Mamba2_State
                          or else Shape.Heads * Shape.Head /= Shape.Inner))
              or else not Holds (Source, Shape.DXBC)
            then
               return;
            end if;
            Rows := Shape.Inner;
         when Gate =>
            if not Holds (Source, Shape.Inner) then
               return;
            end if;
            Rows := Shape.Inner;
         when Dbc_Norm =>
            if Shape.Version /= 1
              or else not Holds (Source, Shape.Rank + 2 * Shape.State)
            then
               return;
            end if;
            Rows := Shape.Rank + 2 * Shape.State;
      end case;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Rows, Columns => Steps.Items (Source).Rows,
         Key => Key, Chained => True, Reads => Source, Kept => Kept,
         Mambas => True, Mamba => Shape,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Mamba2;

   ---------------------
   -- Add_Combination --
   ---------------------

   procedure Add_Combination
     (Steps : in out Sequence;
      Unit  : Natural;
      Added : out Boolean;
      Kept  : Boolean := True;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      From_Step  : Natural := 0;
      Other_Step : Natural := 0)
   is
      --  A unit alone reads the one step before it, for both arms: the
      --  kernel reads the first and not the second, and naming the same
      --  step twice is what keeps the two-arm binding as it is.
      Alone : constant Boolean := Unit in 4 | 5 | 9 | 10;

      --  The arms: named, or the two before this step -- the one before,
      --  twice, for a unit alone.
      First  : constant Natural :=
        (if From_Step /= 0 then From_Step
         elsif Alone then Steps.Held
         else Steps.Held - 1);
      Second : constant Natural :=
        (if Other_Step /= 0 then Other_Step else Steps.Held);
   begin
      if Steps.Held < (if Alone then 1 else 2)
        or else Steps.Held = Sequence_Limit
        or else (From_Step = 0) /= (Other_Step = 0)
        or else First not in 1 .. Steps.Held
        or else Second not in 1 .. Steps.Held
        --  The seventh unit's second arm is one number a block of the
        --  first -- a position, or LFM3's head -- and every other unit's
        --  is as wide as the first.
        or else (if Unit = 7
                 then Steps.Items (Second).Rows = 0
                      or else Steps.Items (First).Rows
                              mod Steps.Items (Second).Rows /= 0
                 elsif not Alone
                 then Steps.Items (First).Rows /= Steps.Items (Second).Rows
                 else False)
        or else Unit > 10
        or else (Unit = 3
                 and then (Model_Runner.Numerics."<=" (Alpha, 0.0)
                           or else Model_Runner.Numerics."<=" (Limit, 0.0)))
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Steps.Items (First).Rows,
         Columns => Steps.Items (First).Rows,
         Key => System.Null_Address, Chained => True, Kept => Kept,
         Reads => (if Alone or else From_Step /= 0 then First else 0),
         Reads_Two => (if Alone or else Other_Step /= 0 then Second else 0),
         Blends => True, Unit => Unit, Alpha => Alpha, Limit => Limit,
         Attends => False,
         others => <>);
      Added := True;
   end Add_Combination;

   --------------
   -- Add_Join --
   --------------

   procedure Add_Join
     (Steps         : in out Sequence;
      Added         : out Boolean;
      From_Step     : Natural := 0;
      From_Vector   : Natural := 0;
      Residual_Step : Natural := 0;
      Kept          : Boolean := True;
      Bias_Too      : Boolean := False)
   is
      Other : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      Room : constant Boolean :=
        Steps.Held /= 0
        and then Steps.Held /= Sequence_Limit
        and then Other <= Steps.Held
        and then Residual_Step <= Steps.Held;

      --  Folded into the product it follows, where that is what it
      --  follows. The arm has to be the step immediately before, has to be
      --  a product rather than one of the other kernels, and has to be a
      --  product nothing else reads on its own -- which is what Kept being
      --  false says. Everything else in the sequence stays as it was: the
      --  step is still counted, so an index a caller wrote still names what
      --  it named.
      Foldable : constant Boolean :=
        Room
        and then Other = Steps.Held
        and then not Steps.Items (Other).Kept
        and then not Steps.Items (Other).Joins
        --  A normalization of whole positions adds the residual in its
        --  own store as a product does; one of heads does not.
        and then (not Steps.Items (Other).Norms
                  or else Steps.Items (Other).Groups = 1)
        and then not Steps.Items (Other).Blends
        and then not Steps.Items (Other).Attends
        and then not Steps.Items (Other).Places
        and then not Steps.Items (Other).Rotates
        --  A biasing step is not a product either, and its kernel adds
        --  no residual: a join folded into it was a join lost, which is
        --  what the first gpt-oss layer over the device did.
        and then not Steps.Items (Other).Biases
        and then not Steps.Items (Other).Folded;

      --  Or, asked, onto a bias folded into the product before it: that
      --  product, plain, adds both in its store.
      Product : constant Natural := (if Other > 1 then Other - 1 else 0);
      Onto_Bias : constant Boolean :=
        Bias_Too
        and then Room
        and then Other = Steps.Held
        and then Product >= 1
        and then Steps.Items (Other).Biases
        and then Steps.Items (Other).Folded
        and then not Steps.Items (Other).Kept
        and then Steps.Items (Product).Joins
        and then Steps.Items (Product).Joined = Other
        and then Steps.Items (Product).Bias_Too = 0
        and then Steps.Items (Product).Routed = 0
        and then not Steps.Items (Product).Listed
        and then Steps.Items (Product).Gathers = 0
        and then Steps.Items (Product).Packing in Half_Packing;
   begin
      if not Room then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Steps.Items (Other).Rows,
         Columns => Steps.Items (Other).Rows,
         Key => System.Null_Address,
         Chained => Residual_Step /= 0,
         Reads => Residual_Step,
         Reads_Two => Other,
         At_Vector => From_Vector,
         Kept => Kept,
         Blends => True, Unit => 2, Attends => False,
         Folded => Foldable or else Onto_Bias,
         others => <>);

      if Foldable then
         Steps.Items (Other).Joins := True;
         Steps.Items (Other).Joined := Steps.Held;
      elsif Onto_Bias then
         Steps.Items (Product).Bias_Too := Other;
         Steps.Items (Product).Joined := Steps.Held;
      end if;

      Added := True;
   end Add_Join;

   --------------
   -- Add_Norm --
   --------------

   ---------------
   -- Add_Place --
   ---------------

   procedure Add_Place
     (Steps     : in out Sequence;
      Width     : Natural;
      Stride    : Natural;
      At_First  : Model_Runner.Numerics.Element_Count;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Packed    : Packing_Shape := Not_Packing;
      Unpack    : Boolean := False;
      Cells     : Natural := 0;
      Half_At   : Interfaces.Unsigned_64 := 0;
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      --  An unpacking step reads the cache and nothing a step made, so
      --  it may open a sequence; every other placing step writes what a
      --  step before it made.
      if Steps.Held = Sequence_Limit
        or else Width = 0
        or else Stride < Width
        or else (Source = 0 and then not Unpack)
        or else Source > Steps.Held
        or else (Unpack and then (Packed.Bits = 0 or else Cells = 0))
        --  A packed row is read four elements at a time by the attention
        --  that follows, which reads them out of one word: four elements
        --  are four bytes or two, so a row of a whole number of fours
        --  keeps them together wherever the row begins -- for bytes on a
        --  word, for nibbles on an even byte. The packing writes a word
        --  at a time and merges where a word is partly another row's, so
        --  a row narrower than a word is taken now rather than refused;
        --  what it may not be is a row that leaves the next one's four
        --  straddling a word, which is a count of elements that is not a
        --  multiple of four. A round's rows go each to its own block,
        --  which the packing kernel looks up in the table as place.comp
        --  does and the unpacking kernel does not.
        or else (Packed.Bits /= 0
                 and then (not Cache_Codec_Fits (Packed.Codec, Packed.Bits)
                           or else Width mod 4 /= 0
                           or else Packed.Row_Bytes
                                   /= (if Packed.Bits = 4 then Width / 2
                                       else Width)
                           or else Packed.At_Byte
                                   mod (if Packed.Bits = 4 then 2 else 4)
                                   /= 0))
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => Width, Key => System.Null_Address,
         Chained => True, Reads => Source,
         Kept => False, Places => True, Stride => Stride,
         At_First => At_First, Pack => Packed,
         Unpacks => Unpack, Half_At => Half_At,
         Cells => (if Unpack then Cells else 0),
         Pages_At => Pages_At, Page_Shift => Page_Shift,
         First_Position => First_Position,
         Attends => False, Blends => False, Norms => False,
         Rotates => False,
         others => <>);
      Added := True;
   end Add_Place;

   ---------------
   -- Add_Fetch --
   ---------------

   procedure Add_Fetch
     (Steps          : in out Sequence;
      Width          : Natural;
      Stride         : Natural;
      At_First       : Model_Runner.Numerics.Element_Count;
      Added          : out Boolean;
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0)
   is
   begin
      if Steps.Held = Sequence_Limit
        or else Width = 0
        or else Stride < Width
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => 0, Key => System.Null_Address,
         Chained => True, Reads => 0,
         Kept => False, Places => True, Fetches => True, Stride => Stride,
         At_First => At_First,
         Pages_At => Pages_At, Page_Shift => Page_Shift,
         First_Position => First_Position,
         others => <>);
      Added := True;
   end Add_Fetch;

   function Fetches_Cache (Item : Engine) return Boolean
   is (Item.Fetch_Line /= Null_Handle);

   ------------------
   -- Add_Rotation --
   ------------------

   procedure Add_Rotation
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Width     : Natural;
      Heads     : Natural;
      Rotary    : Natural;
      Pairing   : Rotary_Pairing;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Kept      : Boolean := True)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      if Steps.Held = Sequence_Limit
        or else Width = 0
        or else Heads = 0
        or else Width mod Heads /= 0
        or else Rotary = 0
        or else Rotary mod 2 /= 0
        or else Rotary > Width / Heads
        or else Base = System.Null_Address
        or else Source > Steps.Held
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => Width, Key => System.Null_Address,
         Chained => Source /= 0, Reads => Source,
         Kept => Kept, Rotates => True, Heads => Heads,
         Turns => Rotary, Pairs => Pairing,
         Attends => False, Blends => False, Norms => False,
         others => <>);
      Added := True;
   end Add_Rotation;

   ---------------
   -- Add_Heads --
   ---------------

   procedure Add_Heads
     (Steps       : in out Sequence;
      From_Step   : Positive;
      Heads       : Positive;
      Head_Size   : Positive;
      Rotary      : Natural;
      Pairing     : Rotary_Pairing;
      Table       : System.Address;
      Table_Span  : Model_Runner.Bytes.Byte_Count;
      Epsilon     : Model_Runner.Numerics.Real;
      Added       : out Boolean;
      Weight      : System.Address := System.Null_Address;
      Weight_Span : Model_Runner.Bytes.Byte_Count := 0;
      Weight_At   : Model_Runner.Bytes.Byte_Count := 0;
      Key         : System.Address := System.Null_Address;
      Into_Cache  : Boolean := False;
      At_First    : Model_Runner.Numerics.Element_Count := 0;
      Stride      : Natural := 0;
      V_Step      : Natural := 0;
      V_At_First  : Model_Runner.Numerics.Element_Count := 0;
      V_Stride    : Natural := 0;
      Kept        : Boolean := True;
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0;
      Source_At       : Natural := 0;
      Source_Stride   : Natural := 0;
      V_Source_At     : Natural := 0;
      V_Source_Stride : Natural := 0;
      V_Row_Count     : Natural := 0;
      Bias_Width      : Natural := 0;
      V_Bias_At       : Natural := 0)
   is
      Width : constant Natural := Heads * Head_Size;

      --  The values' own row count, which a fused V_Step's whole count is
      --  not; the caller names it then, else it is the step's.
      V_Actual : constant Natural :=
        (if V_Step = 0 then 0
         elsif V_Row_Count /= 0 then V_Row_Count
         else Steps.Items (V_Step).Rows);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else From_Step > Steps.Held
        or else (Source_Stride = 0
                 and then Steps.Items (From_Step).Rows /= Width)
        or else (Source_Stride /= 0
                 and then Source_At + Width > Steps.Items (From_Step).Rows)
        or else Head_Size > 256
        or else Rotary mod 2 /= 0
        or else Rotary > Head_Size
        --  No pair turned -- a model told its positions otherwise, as
        --  Whisper is -- reads no table; every component then passes
        --  as the components past the turned ones do.
        or else (Rotary > 0 and then Table = System.Null_Address)
        --  The table's span is what the rotation step checks too: two
        --  wide numbers a pair a position, and the caller has said how
        --  many. Refused before the step is held, not after: a step
        --  stored and then said not added stayed in the sequence, every
        --  later step a place out.
        or else (Rotary > 0 and then Table_Span = 0)
        or else (Into_Cache and then Stride < Width)
        or else (V_Step /= 0
                 and then (not Into_Cache
                           or else V_Step > Steps.Held
                           or else V_Stride < V_Actual))
        or else (not Into_Cache and then V_Step /= 0)
        or else (Bias_Width /= 0
                 and then (Weight = System.Null_Address
                           or else Weight_Span
                                   < Model_Runner.Bytes.Byte_Count
                                       (Bias_Width) * 4
                           or else Bias_Width < Width
                           or else V_Bias_At + V_Actual > Bias_Width))
      then
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Weight, Span => Weight_Span, At_Byte => Weight_At,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => Width, Key => Key,
         Chained => True, Reads => From_Step, Reads_Two => V_Step,
         Kept => Kept, Readies => True,
         Heads => Heads, Head_Size => Head_Size,
         Turns => Rotary, Pairs => Pairing,
         Turn_Table => Table, Turn_Span => Table_Span, Epsilon => Epsilon,
         Into_Cache => Into_Cache, At_First => At_First, Stride => Stride,
         V_Rows => V_Actual,
         V_At_First => V_At_First, V_Stride => V_Stride,
         Reads_At => Source_At, Reads_Stride => Source_Stride,
         V_Reads_At => V_Source_At, V_Reads_Stride => V_Source_Stride,
         Pages_At => (if Into_Cache then Pages_At else 0),
         Page_Shift => (if Into_Cache then Page_Shift else 0),
         First_Position => (if Into_Cache then First_Position else 0),
         Attends => False, Blends => False, Norms => False,
         Rotates => False, Places => False,
         Bias_Width => Bias_Width, V_Bias_At => V_Bias_At,
         others => <>);
      Added := True;
   end Add_Heads;

   procedure Add_Norm
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Width     : Natural;
      Epsilon   : Model_Runner.Numerics.Real;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True;
      Groups    : Positive := 1;
      Shift     : Boolean := False)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);
   begin
      --  Source is zero only on an empty sequence, where it means the
      --  caller's own activation -- which is what a product first in a
      --  sequence reads too. A layer's second half normalizes a step and
      --  its first half normalizes what it was handed.
      --  A shift is one stretch after the gain, and a stretch is the
      --  whole position: a head normalization has no shift here.
      if Steps.Held = Sequence_Limit
        or else Width = 0
        or else Width mod Groups /= 0
        or else Source > Steps.Held
        or else (Shift and then Groups /= 1)
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte,
         Packing => Weight_Packing'First,
         Rows => Width, Columns => Width, Key => Key,
         Chained => Source /= 0, Reads => Source,
         Kept => Kept, Norms => True, Groups => Groups, Shifts => Shift,
         Epsilon => Epsilon, Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Norm;

   --  A round's positions as a step keeps them, and as the push constants
   --  take them.
   -------------------
   -- Add_Attention --
   -------------------

   procedure Add_Attention
     (Steps      : in out Sequence;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Base     : Model_Runner.Numerics.Element_Count;
      V_Base     : Model_Runner.Numerics.Element_Count;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Added      : out Boolean;
      Window     : Natural := 0;
      Chained    : Boolean := False;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;
      Kept       : Boolean := True;
      From_Step  : Natural := 0;
      Packed     : Packed_Cache := Not_Packed;
      Sinks_At   : Natural := 0;
      Pages_At   : Natural := 0;
      Page_Shift : Natural := 0;
      Rows_As_Heads : Boolean := False) is
   begin
      --  The same refusals the single call makes, made while recording
      --  rather than while running: a step that could not be dispatched is
      --  better refused where the caller can still do it another way.
      if Steps.Held = Sequence_Limit
        or else From_Step > Steps.Held
        or else (Chained
                 and then (Steps.Held = 0
                           or else Steps.Items
                                     ((if From_Step = 0 then Steps.Held
                                       else From_Step)).Rows
                                     /= Heads * Head_Size))
        or else Heads = 0
        or else Head_Size = 0
        or else Value_Size = 0
        --  Past the room only an absorbed latent's head, which its own
        --  kernel takes; whether it runs is the run's to say.
        or else (Value_Size > Attention_Room
                 and then not (Head_Size > Matrix_Wider_Head
                               and then Head_Size <= Latent_Head
                               and then Value_Size <= Latent_Value))
        or else Group_Size = 0
        or else Last < First
        or else (Rows_As_Heads
                 and then (not Causal or else Window /= 0 or else Group_Size /= 1
                           or else Model_Runner.Numerics."/=" (Max_Bias, 0.0)
                           or else Model_Runner.Numerics."/=" (Cap, 0.0)
                           or else Sinks_At /= 0 or else Pages_At /= 0
                           or else Packed /= Not_Packed))
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,

         --  What it writes for one position, and what it reads for one:
         --  said as rows and columns so that a product chained to it and a
         --  product beside it are checked against it as against any step.
         Rows => Heads * Value_Size,
         Columns => Heads * Head_Size,
         Key => System.Null_Address, Chained => Chained, Blends => False,
         Reads => From_Step,
         Kept => Kept,
         Unit => 0, Attends => True,
         Heads => Heads, Head_Size => Head_Size, Value_Size => Value_Size,
         Group_Size => Group_Size, First => First, Last => Last,
         K_Base => K_Base, V_Base => V_Base, KV_Width => KV_Width,
         V_Width => V_Width, Window => Window, Scale => Scale, Cap => Cap,
         Causal => Causal, Max_Bias => Max_Bias, Rows_As_Heads => Rows_As_Heads,
         Packed => Packed, Sinks => Sinks_At,
         Pages_At => Pages_At, Page_Shift => Page_Shift,
         others => <>);
      Added := True;
   end Add_Attention;

   ---------
   -- Run --
   ---------

   --  What Tiled_Products and Untiled_Products read. Only the task that
   --  records a sequence writes them.
   Tiled_Count   : Natural := 0;
   Untiled_Count : Natural := 0;

   function Tiled_Products return Natural is (Tiled_Count);
   function Untiled_Products return Natural is (Untiled_Count);

   --  Record whether any product in this sequence excludes the widest tile.
   function Set_Narrow
     (Item  : in out Engine;
      Steps : Sequence) return Boolean is
      Narrow : Boolean := False;
   begin
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);
         begin
            if not (This.Blends or else This.Attends or else This.Places
                    or else This.Rotates or else This.Mixes
                    or else This.Inverts or else This.Picks
                    or else This.Norms or else This.Biases
                    or else This.Convolves or else This.Rules
                    or else This.Rwkvs or else This.Wkvs
                    or else This.Mambas
                    or else This.Routes or else This.Readies)
              and then This.Base /= System.Null_Address
              and then This.Columns mod (2 * Wide_Step) /= 0
            then
               Narrow := True;
            end if;
         end;
      end loop;
      Item.Tile_Plan.Narrow_Run := Narrow;
      return Narrow;
   end Set_Narrow;

   procedure Run
     (Item      : in out Engine;
      Steps     : Sequence;
      Vectors   : Model_Runner.Numerics.Real_Array;
      Count     : Positive;
      Target    : out Model_Runner.Numerics.Real_Array;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In  : Boolean := False;
      Carry_Out : Boolean := False;
      Kept_Into : Address_List := No_Places;
      Leave_Kept : Boolean := False;
      Origin     : Interfaces.Unsigned_64 := 0;
      Hold       : Boolean := False)
   is separate;

   ---------------
   -- Multiply --
   ---------------

   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Numerics.Real_Array;
      Vector  : Model_Runner.Numerics.Real_Array;
      Rows    : Natural;
      Columns : Natural;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Key     : System.Address := System.Null_Address)
   is
      Elements : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Interfaces.Unsigned_64 (Columns);

      --  This form has no caller that can be asked to stop -- it is the
      --  decoded-values one, used where a caller already holds binary32 --
      --  so nothing here reads it.
      Stopped : Boolean;
   begin
      Target := [others => 0.0];
      Ok := False;

      if Rows = 0 or else Columns = 0
        or else Elements > Max_Elements
        or else Weights'Length
                  < Model_Runner.Numerics.Element_Count (Elements)
      then
         return;
      end if;

      --  The same values, as the bytes they already are. Binary32 is what
      --  the buffer holds either way; naming it a format is the only
      --  difference between this and the general one.
      declare
         Room : constant Model_Runner.Bytes.Byte_Array
           (1 .. Model_Runner.Bytes.Byte_Count (Elements * 4))
           with Import, Address => Weights (Weights'First)'Address;
      begin
         Multiply
           (Item, Room, 0, Values_F32, Rows, Columns, Vector, 1, Target, Ok,
            Stopped, Key);
      end;
   end Multiply;

   ---------------------------------------------------------------------------
   --  The keeper: see Open_Keeper.
   ---------------------------------------------------------------------------

   --  Rounds of arithmetic a submission asks for: about a tenth of a
   --  millisecond on the part this was measured on. Longer and the engine's
   --  own work waits behind it -- twenty thousand cost a token 6 per cent --
   --  and shorter keeps the part less busy: none at all, only the
   --  submissions, kept a split mixture's check at 22 tokens a second of
   --  the 24.7 these give.
   Keeper_Spin : constant := 4_000;

   --  How long after the engine last said it was working the keeper goes
   --  on: long enough to bridge a sampled token and a drafted round's
   --  bookkeeping, short enough that a session waiting for its user leaves
   --  the part alone.
   Keeper_Linger : constant Ada.Real_Time.Time_Span :=
     Ada.Real_Time.Milliseconds (100);

   --  What the keeper holds on its own device.
   type Keeper_Objects is record
      Logical  : Address := Null_Handle;
      Queue    : Address := Null_Handle;
      Module   : Address := Null_Handle;
      Set_Kind : Address := Null_Handle;
      Layout   : Address := Null_Handle;
      Pipeline : Address := Null_Handle;
      Sink     : Address := Null_Handle;
      Memory   : Address := Null_Handle;
      Pool     : Address := Null_Handle;
      Set      : Address := Null_Handle;
      Commands : Address := Null_Handle;
      Buffer   : Address := Null_Handle;
      Fence    : Address := Null_Handle;
   end record;

   Keep : Keeper_Objects;

   --  A round whose fence did not signal in a minute: what it submitted may
   --  still be the device's, and the keeper's objects are left where they
   --  are rather than destroyed under it, as a stalled engine leaves its
   --  buffers.
   Keep_Abandoned : Boolean := False
     with Atomic;

   --  When the engine last said it was working, whether there is a keeper
   --  to wake, and whether it is running a round: what the engine, the
   --  keeper and Close_Keeper decide by, under one lock.
   protected Keeper_Stamp is
      procedure Touch (Wake : out Boolean);
      procedure Begin_Round (Go : out Boolean);
      procedure Set_Open (On : Boolean);
      function Rounds return Natural;
      entry Settled;
   private
      Last     : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Open     : Boolean := False;
      Spinning : Boolean := False;
      Count    : Natural := 0;
   end Keeper_Stamp;

   protected body Keeper_Stamp is
      procedure Touch (Wake : out Boolean) is
      begin
         Last := Ada.Real_Time.Clock;
         Wake := Open and then not Spinning;
      end Touch;

      procedure Begin_Round (Go : out Boolean) is
         use type Ada.Real_Time.Time;
         use type Ada.Real_Time.Time_Span;
      begin
         Go := Open and then Ada.Real_Time.Clock - Last < Keeper_Linger;
         Spinning := Go;
         if Go and then Count < Natural'Last then
            Count := Count + 1;
         end if;
      end Begin_Round;

      procedure Set_Open (On : Boolean) is
      begin
         Open := On;
         if On then
            Count := 0;
         end if;
      end Set_Open;

      function Rounds return Natural is (Count);

      entry Settled when not Spinning is
      begin
         null;
      end Settled;
   end Keeper_Stamp;

   --  One submission of the kernel, waited for.
   procedure Keeper_Round (Ok : out Boolean) is
      Submit : constant Submit_Call := To_Submit (Point ("vkQueueSubmit"));
      Wait   : constant Wait_Call := To_Wait (Point ("vkWaitForFences"));
      Reset  : constant Reset_Fences_Call :=
        To_Reset_Fences (Point ("vkResetFences"));

      Buffer_Handle : aliased Address := Keep.Buffer;
      Fence_Handle  : aliased Address := Keep.Fence;
      Request       : aliased Submit_Info;
   begin
      Ok := False;

      if Submit = null or else Wait = null or else Reset = null then
         return;
      end if;

      Request.Buffers := Buffer_Handle'Address;

      if Submit (Keep.Queue, 1, Request'Address, Keep.Fence) /= 0 then
         return;
      end if;

      --  Waited for until it signals, a second at a time: a round held up
      --  behind a long submission of the engine's -- two seconds is within
      --  what one may take -- was taken for failed after the first, and
      --  Close_Keeper then destroyed the fence and the pool of a round the
      --  device was still running. A minute without a signal is a device
      --  that will not give one, and the objects are abandoned rather than
      --  destroyed.
      declare
         Timeout : constant C.int := 2;
         Result  : C.int;
      begin
         for Second in 1 .. 60 loop
            Result := Wait (Keep.Logical, 1, Fence_Handle'Address, 1,
                            1_000_000_000);
            exit when Result /= Timeout;
         end loop;
         if Result = Timeout then
            Keep_Abandoned := True;
            return;
         end if;
         if Result /= 0 then
            return;
         end if;
      end;

      if Reset (Keep.Logical, 1, Fence_Handle'Address) /= 0 then
         return;
      end if;

      Ok := True;
   end Keeper_Round;

   --  Woken by Keep_Clock, it runs rounds for as long as the engine has
   --  lately been working, and waits again.
   task Keeper with Storage_Size => 8 * 1024 * 1024 is
      entry Wake;
   end Keeper;

   task body Keeper is
      Go, Ok : Boolean;
   begin
      loop
         select
            accept Wake;
         or
            terminate;
         end select;

         begin
            loop
               Keeper_Stamp.Begin_Round (Go);
               exit when not Go;

               Keeper_Round (Ok);
               if not Ok then
                  --  A device that refuses a round refuses the next: the
                  --  keeper stops, and the engine is none the worse.
                  Keeper_Stamp.Set_Open (False);
               end if;
            end loop;
         exception
            when others =>
               --  Nor for anything else: a keeper that has stopped is
               --  one Close_Keeper must not wait for.
               Keeper_Stamp.Set_Open (False);
               Keeper_Stamp.Begin_Round (Go);
         end;
      end loop;
   end Keeper;

   procedure Close_Keeper is
      procedure Drop (Name : String; Handle : in out Address);

      procedure Drop (Name : String; Handle : in out Address) is
         Call : constant Destroy_Call := To_Destroy (Point (Name));
      begin
         if Handle /= Null_Handle and then Call /= null then
            Call (Keep.Logical, Handle, Null_Handle);
         end if;
         Handle := Null_Handle;
      end Drop;
   begin
      Keeper_Stamp.Set_Open (False);
      Keeper_Stamp.Settled;

      --  Nothing is asked of the loader for a keeper never made: the
      --  instance it would be asked through may be gone by now.
      if Keep.Logical = Null_Handle then
         Keep := (others => <>);
         return;
      end if;

      --  A round abandoned may still be the device's: nothing of it is
      --  destroyed under it.
      if Keep_Abandoned then
         Keep := (others => <>);
         Keep_Abandoned := False;
         return;
      end if;

      --  The command buffer goes with its pool, and the set with its.
      Drop ("vkDestroyFence", Keep.Fence);
      Drop ("vkDestroyCommandPool", Keep.Commands);
      Drop ("vkDestroyDescriptorPool", Keep.Pool);
      Drop ("vkDestroyPipeline", Keep.Pipeline);
      Drop ("vkDestroyPipelineLayout", Keep.Layout);
      Drop ("vkDestroyDescriptorSetLayout", Keep.Set_Kind);
      Drop ("vkDestroyShaderModule", Keep.Module);
      Drop ("vkDestroyBuffer", Keep.Sink);
      Drop ("vkFreeMemory", Keep.Memory);

      --  The device itself is its context's, which the caller closes.
      Keep := (others => <>);
   end Close_Keeper;

   procedure Open_Keeper (On : Context; Ready : out Boolean) is
      Made : aliased Address := Null_Handle;

      Sink_Bytes : constant := 256;

      procedure Fail;

      procedure Fail is
      begin
         Close_Keeper;
         Ready := False;
      end Fail;
   begin
      Close_Keeper;
      Ready := False;

      --  Asked through the instance its own context came from, not through
      --  whichever engine asked last, which may have been another's.
      if not Is_Open (On) or else not Is_Live (On.Instance) then
         return;
      end if;
      Instance_Of := On.Instance;

      Keep.Logical := On.Logical;
      Keep.Queue := On.Queue;

      --  The kernel.
      declare
         Create  : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words   : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Keep_Clock;
         Request : aliased Shader_Create_Info;
      begin
         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create = null
           or else Create (Keep.Logical, Request'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Module := Made;
      end;

      --  One storage buffer, and a pipeline that takes it and the count.
      declare
         Create   : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorSetLayout"));
         Bindings : aliased Binding_Array;
         Request  : aliased Set_Layout_Create_Info;
      begin
         Request.Count := 1;
         Request.Bindings := Bindings'Address;

         if Create = null
           or else Create (Keep.Logical, Request'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Set_Kind := Made;
      end;

      declare
         Create  : constant Create_Call :=
           To_Create (Point ("vkCreatePipelineLayout"));
         Sets    : aliased Address := Keep.Set_Kind;
         Pushes  : aliased Push_Range := (Size => 4, others => <>);
         Request : aliased Pipeline_Layout_Info;
      begin
         Request.Sets := Sets'Address;
         Request.Pushes := Pushes'Address;

         if Create = null
           or else Create (Keep.Logical, Request'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Layout := Made;
      end;

      declare
         Create  : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
         Answer  : C.int := -1;
      begin
         Request.Stage.Module := Keep.Module;
         Request.Stage.Name := Name;
         Request.Layout := Keep.Layout;

         if Create /= null then
            Answer := Create (Keep.Logical, Null_Handle, 1, Request'Address,
                              Null_Handle, Made'Access);
         end if;

         C.Strings.Free (Name);

         if Answer /= 0 then
            Fail;
            return;
         end if;

         Keep.Pipeline := Made;
      end;

      --  The sink, in whatever memory the buffer may have.
      declare
         Create   : constant Create_Call := To_Create (Point ("vkCreateBuffer"));
         Wants    : constant Requirements_Call :=
           To_Requirements (Point ("vkGetBufferMemoryRequirements"));
         Allocate : constant Create_Call :=
           To_Create (Point ("vkAllocateMemory"));
         Bind     : constant Bind_Call := To_Bind (Point ("vkBindBufferMemory"));

         Request  : aliased Buffer_Create_Info :=
           (Size => Sink_Bytes, Usage => Usage_Storage_Buffer, others => <>);
         Needs    : aliased Memory_Requirements;
         Asking   : aliased Memory_Allocate_Info;
      begin
         if Create = null or else Wants = null or else Allocate = null
           or else Bind = null
           or else Create (Keep.Logical, Request'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Sink := Made;
         Wants (Keep.Logical, Keep.Sink, Needs'Address);

         Asking.Size := Needs.Size;
         for Kind in 0 .. 31 loop
            if (Interfaces.Unsigned_32 (Needs.Kinds)
                and Interfaces.Shift_Left (1, Kind)) /= 0
            then
               Asking.Which := C.unsigned (Kind);
               exit;
            end if;
         end loop;

         if Allocate (Keep.Logical, Asking'Address, Null_Handle, Made'Access)
            /= 0
         then
            Fail;
            return;
         end if;

         Keep.Memory := Made;

         if Bind (Keep.Logical, Keep.Sink, Keep.Memory, 0) /= 0 then
            Fail;
            return;
         end if;
      end;

      --  The set that points the kernel at it.
      declare
         Create   : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorPool"));
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));
         Update   : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Sizes   : aliased Pool_Size := (Count => 1, others => <>);
         Pooled  : aliased Descriptor_Pool_Info;
         Layouts : aliased Address := Keep.Set_Kind;
         Asking  : aliased Descriptor_Set_Info;
         Told    : aliased Buffer_Info :=
           (Buffer => Keep.Sink, Offset => 0, Extent => Sink_Bytes);
         Note    : aliased Write_Descriptor;
      begin
         Pooled.Sizes := Sizes'Address;

         if Create = null or else Allocate = null or else Update = null
           or else Create (Keep.Logical, Pooled'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Pool := Made;
         Asking.Pool := Keep.Pool;
         Asking.Layouts := Layouts'Address;

         if Allocate (Keep.Logical, Asking'Address, Made'Access) /= 0 then
            Fail;
            return;
         end if;

         Keep.Set := Made;
         Note.Target := Keep.Set;
         Note.Buffers := Told'Address;
         Update (Keep.Logical, 1, Note'Address, 0, Null_Handle);
      end;

      --  The one command buffer, recorded once and submitted every round,
      --  and the fence a round waits on.
      declare
         Create   : constant Create_Call :=
           To_Create (Point ("vkCreateCommandPool"));
         Allocate : constant Allocate_Buffers_Call :=
           To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));
         Start    : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop     : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push     : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));
         Fence    : constant Create_Call := To_Create (Point ("vkCreateFence"));

         Pooled : aliased Command_Pool_Info;
         Asking : aliased Command_Buffer_Info;
         Began  : aliased Command_Begin_Info := (Flags => 0, others => <>);
         Sets   : aliased Address := Keep.Set;
         Spin   : aliased C.unsigned := Keeper_Spin;
         Fenced : aliased Fence_Create_Info;
      begin
         Pooled.Family := C.unsigned (On.Family);

         if Create = null or else Allocate = null or else Start = null
           or else Stop = null or else Bind_Pipeline = null
           or else Bind_Sets = null or else Push = null or else Dispatch = null
           or else Create (Keep.Logical, Pooled'Address, Null_Handle,
                           Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Commands := Made;
         Asking.Pool := Keep.Commands;

         if Allocate (Keep.Logical, Asking'Address, Made'Access) /= 0 then
            Fail;
            return;
         end if;

         Keep.Buffer := Made;

         if Start (Keep.Buffer, Began'Address) /= 0 then
            Fail;
            return;
         end if;

         Bind_Pipeline (Keep.Buffer, Bind_Point_Compute, Keep.Pipeline);
         Bind_Sets (Keep.Buffer, Bind_Point_Compute, Keep.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);
         Push (Keep.Buffer, Keep.Layout, Stage_Compute, 0, 4, Spin'Address);
         Dispatch (Keep.Buffer, 1, 1, 1);

         if Stop (Keep.Buffer) /= 0
           or else Fence = null
           or else Fence (Keep.Logical, Fenced'Address, Null_Handle,
                          Made'Access) /= 0
         then
            Fail;
            return;
         end if;

         Keep.Fence := Made;
      end;

      Keeper_Stamp.Set_Open (True);
      Ready := True;
   end Open_Keeper;

   procedure Keep_Clock is
      Wake : Boolean;
   begin
      Keeper_Stamp.Touch (Wake);

      --  Only a keeper waiting to be woken is: one busy with a round will
      --  see the stamp when it asks for the next.
      if Wake then
         select
            Keeper.Wake;
         else
            null;
         end select;
      end if;
   end Keep_Clock;

   function Keeper_Rounds return Natural is (Keeper_Stamp.Rounds);

end Model_Runner.Platform.Device.Products;
