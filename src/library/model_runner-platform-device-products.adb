with Ada.Environment_Variables;
with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

with Model_Runner.Shaders;
with Model_Runner.Shaders.Low;

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

   use type Model_Runner.Bytes.Byte_Count;

   subtype Address is System.Address;

   Null_Handle : constant Address := System.Null_Address;

   --  What the interface calls the structures this passes.
   Structure_Submit            : constant := 4;
   Structure_Memory_Allocate   : constant := 5;
   Structure_Fence_Create      : constant := 8;
   Structure_Semaphore_Create  : constant := 9;
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
   Wave_Lanes : constant := 32;
   Wave_Rows  : constant := 2;

   --  The low-bit subgroup kernels' band, their shader's NUM_ROWS.
   Low_Wave_Rows : constant := 4;

   --  Rows of the answer one workgroup of the matrix product computes, and
   --  vectors of it. The shader states both and this has to agree: the
   --  first says how many workgroups a matrix needs, the second says how
   --  far the batch is rounded up before it is handed over.
   Tile_Rows    : constant := 32;
   Tile_Vectors : constant := 128;

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

   --  And the narrow tile's width, which the same source compiled with
   --  NARROW declares. A tile costs what its width costs whether the batch
   --  fills it or not, so a batch this size or smaller is given one of
   --  these instead of paying for the wide one's invented zeros.
   Narrow_Vectors : constant := 32;

   --  And the batch size at or below which it is the one to take, which is
   --  a separate question from how wide it is: above the narrow tile's own
   --  width a batch is several narrow tiles, and whether that beats one
   --  wide tile is a measurement rather than arithmetic.
   Narrow_Limit : constant := 64;

   --  Which of the two a batch of this size takes.
   function Narrowed (Count : Natural) return Boolean
   is (Count <= Narrow_Limit);

   function Tile_Width (Count : Natural) return Positive
   is (if Narrowed (Count) then Narrow_Vectors else Tile_Vectors);

   --  The batch, rounded up to a whole tile. The shader has no test for a
   --  tile that is not full, on purpose and at a fifth of its speed if it
   --  had; what the rounding invents is zeroed by the copying kernel and
   --  written to room the result buffer is given for it.
   --  Columns a tile reads at a time: the narrow one a chunk, the wide one
   --  a chunk for each of its four lane groups.
   Wide_Step : constant := 128;

   function Tile_Step (Count : Natural) return Positive
   is (if Narrowed (Count) then 32 else Wide_Step);

   function Whole_Tiles (Count : Natural) return Natural
   is ((Count + Tile_Width (Count) - 1) / Tile_Width (Count)
       * Tile_Width (Count));

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
   function Matrix_Kernel
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Address
   is (if Item.Exact_Attention
         or else Positions < Matrix_Queries
         or else Head_Size mod 16 /= 0
         or else Value_Size mod 16 /= 0
       then Null_Handle
       elsif Head_Size <= Matrix_Head and then Value_Size <= Matrix_Head
       then Item.Matrix_Attend
       elsif Head_Size <= Matrix_Wide_Head
         and then Value_Size <= Matrix_Wide_Head
       then Item.Matrix_Wide_Attend
       else Null_Handle);

   function Attends_By_Matrix
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Matrix_Kernel (Item, Positions, Head_Size, Value_Size)
       /= Null_Handle);

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

   --  How wide a bundle a token attending out of the copy takes: eight,
   --  four, or nought for the plain half-precision kernel, a head a
   --  workgroup. Nought too over a short cache, as the exact bundle
   --  decides it: a bundle pays where there is enough cache to read,
   --  and at seventy positions a head a workgroup reads 13 us where the
   --  bundle of eight reads 25.
   function Halved_Bundle
     (Item : Engine; Group_Size : Natural; Span : Natural) return Natural
   is (if Span < Bundle_Least
       then 0
       elsif Item.Eight_Halved_Line /= Null_Handle
         and then Group_Size mod Wide_Bundle = 0
       then Wide_Bundle
       elsif Item.Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then Head_Bundle
       else 0);

   --  Whether a batch too short for the tiled kernels takes the bundled
   --  one over the cache proper: a generated token, whose workgroups are
   --  a head each and whose heads share a group's keys and values. The
   --  kernel and the first axis of the dispatch decide this together.
   --  How wide that bundle is: eight where the group divides by eight and
   --  the eight-wide pipeline was made, four where it divides by four,
   --  and nought for no bundle at all.
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
         --  The bundled compilation reads four at a time and nothing
         --  else, on the engine's word that every base and width allows
         --  it; a cache that does not is attended a word at a time.
         or else Head_Size mod 4 /= 0
         or else Value_Size mod 4 /= 0
         or else Value_Size > 128
         or else K_Base mod 4 /= 0
         or else V_Base mod 4 /= 0
         or else KV_Width mod 4 /= 0
         or else V_Width mod 4 /= 0
       then 0
       elsif Item.Eight_Bundle_Line /= Null_Handle
         and then Group_Size mod Wide_Bundle = 0
       then Wide_Bundle
       elsif Item.Exact_Bundle_Line /= Null_Handle
         and then Group_Size mod Head_Bundle = 0
       then Head_Bundle
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
      Span       : Natural := Bundle_Least) return Address
   is (if not Rounding
         and then Attends_By_Matrix (Item, Positions, Head_Size, Value_Size)
       then Matrix_Kernel (Item, Positions, Head_Size, Value_Size)
       elsif not Rounding
         and then Item.Tile_Line /= Null_Handle
         and then Positions >= Query_Block
       then Item.Tile_Line
       --  A token out of the copy, in the widest bundle its group takes.
       elsif not Rounding
         and then Token_By_Halves (Item, Positions, Head_Size, Value_Size)
       then (case Halved_Bundle (Item, Group_Size, Span) is
               when Wide_Bundle => Item.Eight_Halved_Line,
               when Head_Bundle => Item.Bundle_Line,
               when others      => Item.Halved_Line)
       elsif not Rounding
         and then Exact_Bundle
                    (Item, Positions, Head_Size, Value_Size, Group_Size,
                     K_Base, V_Base, KV_Width, V_Width, Span)
                  = Wide_Bundle
       then Item.Eight_Bundle_Line
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
       then (if Halved_Bundle (Item, Group_Size, Span) > 0
             then C.unsigned
                    ((Heads + Halved_Bundle (Item, Group_Size, Span) - 1)
                     / Halved_Bundle (Item, Group_Size, Span))
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
   Exact_Cuts_A_Round  : constant Boolean := False;
   Packed_Cuts_A_Round : constant Boolean := True;

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
              (Slice_Limit,
               (Last - First + Slice_Least) / Slice_Least));

   function Attend_Groups
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Rounding   : Boolean := False) return C.unsigned
   is (if not Rounding
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
       and then Count <= Thin_Vectors
       and then Columns mod 4 = 0
       and then Base mod 16 = 0);

   function Half_Grouped
     (Item : Engine; Packing : Weight_Packing; Count : Natural) return Boolean
   is (Count = 1
       and then Item.Half_Group_Line /= Null_Handle
       and then Packing in Packed_Q4_K | Packed_Q5_K);

   --  Whether the super-block row product answers this: a Q4_K or Q5_K
   --  generating a token, on a device that gave the engine the kernel. Each
   --  format has its own decode and its own pipeline.
   function Waved
     (Item : Engine; Packing : Weight_Packing; Count : Natural) return Boolean
   is (Count = 1
       and then ((Packing = Packed_Q4_K and then Item.Wave_Line /= Null_Handle)
                 or else
                 (Packing = Packed_Q5_K
                  and then Item.Wave_Line5 /= Null_Handle)
                 or else
                 (Packing = Packed_Q6_K
                  and then Item.Wave_Line6 /= Null_Handle)
                 or else
                 (Packing in Low_Packing
                  and then Item.Low_Wave_Lines (Packing) /= Null_Handle)));

   --  Invocations a workgroup of the bound row kernel has. The super-block
   --  kernel's workgroup is a single subgroup of thirty-two; the half-group
   --  kernel narrows; the rest are the group size.
   function Row_Width
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Positive
   is (if Waved (Item, Packing, Count) then Wave_Lanes
       elsif Half_Grouped (Item, Packing, Count) then Half_Group
       else Group_Size);

   --  Lanes a row is divided into, which the dispatch multiplies the rows by.
   --  The super-block kernel gives a band thirty-two; the rest give a row
   --  eight.
   function Row_Lane_Count
     (Item : Engine; Packing : Weight_Packing; Count : Natural)
      return Positive
   is (if Waved (Item, Packing, Count) then Wave_Lanes else Row_Lanes);

   --  Rows a subgroup kernel's workgroup lands: the k-quants' band, or the
   --  low-bit formats' own.
   function Wave_Band (Packing : Weight_Packing) return Positive
   is (if Packing in Low_Packing then Low_Wave_Rows else Wave_Rows);

   --  Rows the dispatch reckons in: the super-block kernel's workgroup lands
   --  a band of Wave_Band rows, so it asks for a band's worth fewer.
   function Row_Reach
     (Item : Engine; Packing : Weight_Packing; Count : Natural; Rows : Natural)
      return Natural
   is (if Waved (Item, Packing, Count)
       then (Rows + Wave_Band (Packing) - 1) / Wave_Band (Packing)
       else Rows);

   function Row_Line
     (Item    : Engine;
      Count   : Natural;
      Packing : Weight_Packing := Values_F32) return Address
   is (if Packing in Low_Packing and then Waved (Item, Packing, Count)
       then Item.Low_Wave_Lines (Packing)
       elsif Packing in Low_Packing
       then (if Count in Row_Line_Array'Range
               and then Item.Low_Row_Lines (Count) /= Null_Handle
             then Item.Low_Row_Lines (Count)
             elsif Count > Batch_Group and then Item.Low_Wide_Line /= Null_Handle
             then Item.Low_Wide_Line
             else Item.Low_Pipeline)
       elsif Waved (Item, Packing, Count)
       then (if Packing = Packed_Q5_K then Item.Wave_Line5
             elsif Packing = Packed_Q6_K then Item.Wave_Line6
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

   --  Which of the four tiles answers this format at this width. Null when
   --  the device refused the one this batch would need.
   function Tile_Pipeline
     (Item    : Engine;
      Packing : Weight_Packing;
      Count   : Natural) return Address
   is (if Narrowed (Count)
       then (if On_Extra (Packing)
             then Item.Narrow_More_Line else Item.Narrow_Line)
       else (if On_Extra (Packing)
             then Item.Extra_Line else Item.Matrix_Line));

   --  The tile a listed product binds: the wide tile's words at sixty-four
   --  vectors, in the compilation that decodes the format.
   function Listed_Pipeline
     (Item : Engine; Packing : Weight_Packing) return Address
   is (if On_Extra (Packing) then Item.Listed_More_Line
       else Item.Listed_Line);

   function Uses_Matrix
     (Item    : Engine;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural) return Boolean
   is (Item.Matrices
       and then Item.Matrix_Line /= Null_Handle
       and then Rows mod Tile_Rows = 0
       and then Count >= Tile_Least

       --  The tile this width and this format has to exist, not merely
       --  some tile: the room the batch is rounded into is decided by the
       --  width before the pipeline is bound, so a device that took the
       --  wide tile and refused the narrow one must not be given a batch
       --  the narrow one would have answered.
       and then Tile_Pipeline (Item, Packing, Count) /= Null_Handle
       --  The width the tile steps in. The wide tile decodes four chunks of
       --  thirty-two at once -- one for each of its lane groups -- so its
       --  step is a hundred and twenty-eight where the narrow tile's is
       --  thirty-two. A hidden width is a multiple of a hundred and
       --  twenty-eight in every model this has been shown, and one that is
       --  not takes the row product for its batches rather than a tile that
       --  would read past the end of a row.
       and then ((Packing in Values_F16 | Values_BF16
                  and then Columns mod Tile_Step (Count) = 0)
                 or else (Packing in Packed_Q4_0 | Packed_Q4_1 | Packed_Q5_0
                                     | Packed_Q5_1 | Packed_Q8_0
                                     | Packed_IQ4_NL | Packed_MXFP4
                          and then Columns mod Tile_Step (Count) = 0)
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
   is (if Item.Copy_Buffer /= Null_Handle
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
   is (if Item.Copy_Split and then Item.Copy_Values_Buffer /= Null_Handle
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
   Packed_Bytes    : constant := 116;
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
   --  subgroup to a width: full subgroups, and the width itself.
   Require_Full_Subgroups  : constant := 16#0000_0002#;
   Structure_Required_Size : constant := 1000225002;

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
   --  What the attention kernel is told. Fifteen words, against the six the
   --  matrix kernels take, pushed into the same range. Well inside the
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
   end record
     with Convention => C;

   Heads_Bytes : constant := 23 * 4;

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

   procedure Give_Back_Buffer
     (Item : in out Engine; Buffer : in out Address; Memory : in out Address)
   is
      Destroy : constant Destroy_Call :=
        To_Destroy (Point ("vkDestroyBuffer"));
      Free : constant Destroy_Call := To_Destroy (Point ("vkFreeMemory"));
   begin
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

   procedure Write_Bytes
     (Where  : Address;
      Values : Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean) is
   begin
      Ok := False;

      if Where = Null_Handle then
         return;
      end if;

      declare
         Room : Model_Runner.Bytes.Byte_Array (Values'Range)
           with Import, Address => Where;
      begin
         Room := Values;
      end;

      Ok := True;
   end Write_Bytes;

   ---------------------------------------------------------------------------
   --  Making and releasing
   ---------------------------------------------------------------------------

   procedure Open
     (Item       : in out Engine;
      On         : Context;
      Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0)
   is
      Made : aliased Address := Null_Handle;
   begin
      Close (Item);
      Ready := False;

      if not Is_Open (On) then
         return;
      end if;

      Item.Instance := On.Instance;
      Instance_Of := Item.Instance;

      --  Through the accessor rather than the field. This package can see
      --  the private part, being a child, and reading it directly would make
      --  a public operation that answers exactly this question something
      --  nothing calls.
      Item.Heap := Memory_Bytes (On);
      Item.Imports := Takes_Host_Memory (On);
      Item.Import_To := Host_Alignment (On);
      Item.Storage := Storage_Limit (On);
      Item.Tick := Timestamp_Period (On);
      Item.Plain := Plain_Memory_Kinds (On);
      Item.Share := Share_Host;
      --  The budget, by heap. Unasked, it is what it always was: the share
      --  of the largest heap, and the second heap holds nothing. A budget
      --  named by the caller fills the first tier to that share and puts
      --  the rest in the second, so a test that names a few kilobytes
      --  still evicts, and a caller who names more than the first heap's
      --  share gets the second heap rather than the driver's refusal.
      --
      --  The second heap is NOT taken by default, and the reason is the
      --  host's memory rather than the device's. On the integrated part
      --  this was built on, the two heaps together hold 11.8 GB of an
      --  11.26 GB mixture, and holding it cost about twenty-five gigabytes
      --  of a thirty-gigabyte host -- the kernel reports the buffers as
      --  shmem and pool pages both, at about two bytes of system memory
      --  for every byte on the device -- and the desktop was killed for
      --  want of memory, twice. The share of one heap is what this machine
      --  can afford, and a caller who knows theirs can afford more says so
      --  with the budget.
      Item.Second := Second_Kind (On);

      declare
         First_Share  : constant Interfaces.Unsigned_64 :=
           Item.Heap / Budget_Whole * Budget_Share;
         Second_Share : constant Interfaces.Unsigned_64 :=
           (if Item.Second >= 0
            then Second_Memory_Bytes (On) / Budget_Whole * Budget_Share
            else 0);
      begin
         if Budget = 0 then
            Item.Tier_Limit := [First_Share, 0];
         elsif Item.Second < 0 then
            Item.Tier_Limit := [Budget, 0];
         else
            --  The second heap takes what the first's share does not
            --  cover, up to its own share; past both, the first is asked
            --  for the rest and the driver's answer is the bound, as it
            --  always was for a budget past the heap.
            Item.Tier_Limit (1) :=
              Interfaces.Unsigned_64'Min (Budget, First_Share);
            Item.Tier_Limit (2) :=
              Interfaces.Unsigned_64'Min
                (Budget - Item.Tier_Limit (1), Second_Share);
            Item.Tier_Limit (1) := Budget - Item.Tier_Limit (2);
         end if;

         Item.Budget := Item.Tier_Limit (1) + Item.Tier_Limit (2);
      end;

      Item.Tier_Kept := [others => 0];
      Item.Tier_Spare := [others => 0];

      Item.Logical := On.Logical;
      Item.Queue := On.Queue;
      Item.Family := On.Family;
      Item.Upload := On.Upload;
      Item.Download := On.Download;

      --  The shader.
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Row_Product;
         Request : aliased Shader_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Shader := Made;
      end;

      --  The same kernel's LOW_BITS compilation, which decodes the twelve
      --  low-bit formats and nothing else. It asks nothing of the device the
      --  first does not, so a device that took the first takes this.
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Low.Row_Product_Low;
         Request : aliased Shader_Create_Info;
      begin
         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Low_Shader := Made;
      end;

      --  The super-block row product's module, made only where the device
      --  offers a subgroup to reduce across and the setting of its width to
      --  thirty-two. A refusal leaves Wave_Shader null and the engine binds
      --  the eight-lane kernel.
      if Has_Subgroup_Arithmetic (On) and then Has_Sized_Subgroups (On) then
         declare
            Create : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Words  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Row_Product_Super;
            Request : aliased Shader_Create_Info;
         begin
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Wave_Shader := Made;
               end if;
            end if;
         end;

         declare
            Create : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Words  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Row_Product_Super5;
            Request : aliased Shader_Create_Info;
         begin
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Wave_Shader5 := Made;
               end if;
            end if;
         end;

         declare
            Create : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Words  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Row_Product_Super6;
            Request : aliased Shader_Create_Info;
         begin
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Wave_Shader6 := Made;
               end if;
            end if;
         end;

         for Packing in Low_Packing loop
            declare
               Create : constant Create_Call :=
                 To_Create (Point ("vkCreateShaderModule"));
               Words  : aliased constant Model_Runner.Shaders.Word_Array :=
                 (case Packing is
                    when Packed_IQ3_S =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq3_S,
                    when Packed_IQ2_XXS =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_Xxs,
                    when Packed_IQ2_XS =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_Xs,
                    when Packed_IQ2_S =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_S,
                    when Packed_IQ3_XXS =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq3_Xxs,
                    when Packed_IQ1_S =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq1_S,
                    when Packed_IQ1_M =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Iq1_M,
                    when Packed_TQ1_0 =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Tq1_0,
                    when Packed_TQ2_0 =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Tq2_0,
                    when Packed_Q1_0 =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Q1_0,
                    when Packed_Q2_0 =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Q2_0,
                    when Packed_NVFP4 =>
                      Model_Runner.Shaders.Low.Row_Product_Wave_Nvfp4);
               Request : aliased Shader_Create_Info;
            begin
               if Create /= null then
                  Request.Size := Interfaces.C.size_t (Words'Length * 4);
                  Request.Code := Words'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Low_Wave_Shaders (Packing) := Made;
                  end if;
               end if;
            end;
         end loop;
      end if;

      --  The second kernel's module.
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Combine;
         Request : aliased Shader_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Blender := Made;

         --  And the normalization, from its own source. A device that
         --  refuses it is left doing its normalizing on the host, which is
         --  what every device did before this.
         declare
            Normed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Norm;
         begin
            Request.Size := Interfaces.C.size_t (Normed'Length * 4);
            Request.Code := Normed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Normer := Made;
            end if;
         end;

         --  And a mixture's routing and its weighted sum, the same story
         --  again: a device that refuses either runs its mixtures a
         --  submission at a time, as every device did before.
         declare
            Routed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Route;
            Mixed  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Mix;
            Biased : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Bias;
            Picked : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Pick;
            Conved : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Conv;
            Ruled  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Rule;
         begin
            Request.Size := Interfaces.C.size_t (Routed'Length * 4);
            Request.Code := Routed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Router := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Mixed'Length * 4);
            Request.Code := Mixed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Mixer := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Biased'Length * 4);
            Request.Code := Biased'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Biaser := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Picked'Length * 4);
            Request.Code := Picked'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Picker := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Conved'Length * 4);
            Request.Code := Conved'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Conver := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Ruled'Length * 4);
            Request.Code := Ruled'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Ruler := Made;
            end if;
         end;

         --  And the heads step, which stands for three of the others: a
         --  device that refuses it dispatches those three.
         declare
            Readied : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Heads;
         begin
            Request.Size := Interfaces.C.size_t (Readied'Length * 4);
            Request.Code := Readied'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Header := Made;
            end if;
         end;

         --  And the merge of a split attention's slices.
         declare
            Merged : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Merge;
         begin
            Request.Size := Interfaces.C.size_t (Merged'Length * 4);
            Request.Code := Merged'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Merger := Made;
            end if;
         end;

         --  And a batch's routing inverted.
         declare
            Inverted : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Invert;
         begin
            Request.Size := Interfaces.C.size_t (Inverted'Length * 4);
            Request.Code := Inverted'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Inverter := Made;
            end if;
         end;

         --  And the thin product.
         declare
            Thinned : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Thin;
         begin
            Request.Size := Interfaces.C.size_t (Thinned'Length * 4);
            Request.Code := Thinned'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Thinner := Made;
            end if;
         end;

         --  And the rotation, which is the same story: a device that
         --  refuses it turns on the host, as every device did before.
         declare
            Turned : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Rotate;
         begin
            Request.Size := Interfaces.C.size_t (Turned'Length * 4);
            Request.Code := Turned'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Turner := Made;
            end if;
         end;

         --  And the cache write, the same again.
         declare
            Placed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Place;
         begin
            Request.Size := Interfaces.C.size_t (Placed'Length * 4);
            Request.Code := Placed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Placer := Made;
            end if;
         end;
      end;

      --  The third kernel's module.
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Attention;
         Request : aliased Shader_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Attender := Made;

         --  And the packed kernel, over a cache of bytes or nibbles and
         --  scales, compiled twice as attention.comp is: with subgroup
         --  operations where the device offers them to a compute shader,
         --  and through shared memory alone everywhere else. Allowed to
         --  fail on its own: a device that refuses it attends a packed
         --  session on the host.
         declare
            Plain  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Attention_Packed;
            Packed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Attention_Packed_Subgroups;
         begin
            Request.Size := Interfaces.C.size_t (Plain'Length * 4);
            Request.Code := Plain'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Packed_Plain := Made;
            end if;

            if Has_Subgroup_Arithmetic (On) then
               Request.Size := Interfaces.C.size_t (Packed'Length * 4);
               Request.Code := Packed'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Packed_Attend := Made;
               end if;
            end if;
         end;

         --  And the kernel that packs a step's rows into such a cache,
         --  which finds a row's largest the same two ways.
         declare
            Plain  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Pack;
            Packer : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Pack_Subgroups;
         begin
            Request.Size := Interfaces.C.size_t (Plain'Length * 4);
            Request.Code := Plain'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Packer_Plain := Made;
            end if;

            if Has_Subgroup_Arithmetic (On) then
               Request.Size := Interfaces.C.size_t (Packer'Length * 4);
               Request.Code := Packer'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Packer := Made;
               end if;
            end if;
         end;

         --  And the one that unpacks a layer of it into the copy for a
         --  batch, which is worth having only where the matrix kernel is
         --  -- whose module is made below, so the pipeline is what is
         --  gated on it.
         declare
            Unpacker : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Unpack;
         begin
            Request.Size := Interfaces.C.size_t (Unpacker'Length * 4);
            Request.Code := Unpacker'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Unpacker := Made;
            end if;
         end;

         --  And the same source compiled with SUBGROUPS, where the device
         --  offers them. Allowed to fail on its own: a device that takes
         --  the wide kernel and refuses this one attends as it always did.
         if Has_Subgroup_Arithmetic (On) then
            declare
               Grouped : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attention_Subgroups;
            begin
               Request.Size := Interfaces.C.size_t (Grouped'Length * 4);
               Request.Code := Grouped'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Grouped := Made;
               end if;
            end;

            --  And once more with QUERY_TILE. It needs the subgroup one to
            --  have been made, because a block reduces per query per tile
            --  and that is what the subgroup operations are for.
            if Item.Grouped /= Null_Handle then
               declare
                  Blocked : aliased constant
                    Model_Runner.Shaders.Word_Array :=
                      Model_Runner.Shaders.Attention_Tiled;
               begin
                  Request.Size :=
                    Interfaces.C.size_t (Blocked'Length * 4);
                  Request.Code := Blocked'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Query_Tile := Made;
                  end if;
               end;

               --  And once more with HALVED, which reads the cache in half
               --  precision. It is the subgroup one again -- a round binds
               --  it -- so it needs the same device offer, and it is
               --  allowed to fail on its own: a device that refuses it
               --  reads the cache proper as it always did.
               declare
                  Halved : aliased constant
                    Model_Runner.Shaders.Word_Array :=
                      Model_Runner.Shaders.Attention_Halved;
               begin
                  Request.Size :=
                    Interfaces.C.size_t (Halved'Length * 4);
                  Request.Code := Halved'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Halver_Attend := Made;
                  end if;
               end;

               --  And a fifth with GROUPED beside it, a bundle of heads to
               --  a workgroup. Made only where the fourth was: it is the
               --  same kernel with the same cache and the fourth is what a
               --  round falls back to.
               if Item.Halver_Attend /= Null_Handle then
                  declare
                     Bundled : aliased constant
                       Model_Runner.Shaders.Word_Array :=
                         Model_Runner.Shaders.Attention_Bundled;
                  begin
                     Request.Size :=
                       Interfaces.C.size_t (Bundled'Length * 4);
                     Request.Code := Bundled'Address;

                     if Create (Item.Logical, Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Bundled_Attend := Made;
                     end if;
                  end;
               end if;

               --  And a sixth, GROUPED over the cache proper, beside the
               --  subgroup one it falls back to.
               declare
                  Bundled : aliased constant
                    Model_Runner.Shaders.Word_Array :=
                      Model_Runner.Shaders.Attention_Bundle_Exact;
               begin
                  Request.Size := Interfaces.C.size_t (Bundled'Length * 4);
                  Request.Code := Bundled'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Exact_Bundled_Attend := Made;
                  end if;
               end;
            end if;
         end if;
      end;

      --  And the two that only some devices get: the matrix product and
      --  the half-precision copy its operand needs. Made together, because
      --  neither is any use without the other, and made at all only where
      --  the device said it offers the instruction at the shape the shader
      --  is written for.
      Item.Matrices := Has_Matrix_Instruction (On);

      --  And attention through the same instruction, which belongs here
      --  rather than beside the other attending modules: it is wanted only
      --  where the instruction is, and whether it is has just been decided.
      --  Allowed to fail on its own -- a device that takes the matrix
      --  product and refuses this one attends as it did before.
      if Item.Matrices then
         declare
            Create  : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Attends : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Attention_Matrix;
            Request : aliased Shader_Create_Info;
         begin
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Attends'Length * 4);
               Request.Code := Attends'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Matrix := Made;
               end if;

               --  And the same words staging a head twice as wide.
               declare
                  Wide : aliased constant Model_Runner.Shaders.Word_Array :=
                    Model_Runner.Shaders.Attention_Matrix_Wide;
               begin
                  Request.Size := Interfaces.C.size_t (Wide'Length * 4);
                  Request.Code := Wide'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Attend_Matrix_Wide := Made;
                  end if;
               end;
            end if;
         end;
      end if;

      if Item.Matrices then
         declare
            Create : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Tiles  : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Product;
            Copy   : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Half_Batch;
            More   : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Extra;
            Thin   : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Narrow;
            Thin_More : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Narrow_Extra;
            Listed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Listed;
            Listed_More : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Matrix_Listed_Extra;
            Request : aliased Shader_Create_Info;
         begin
            if Create = null then
               Close (Item);
               return;
            end if;

            Request.Size := Interfaces.C.size_t (Tiles'Length * 4);
            Request.Code := Tiles'Address;

            --  A module the device refuses is not a fault. The shader is
            --  SPIR-V 1.6 and names an extension; a device that took the
            --  extension and will not take the module is a device this
            --  leaves on the row product, which is what every device
            --  without the instruction runs anyway.
            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) /= 0
            then
               Item.Matrices := False;
            else
               Item.Matrix := Made;

               Request.Size := Interfaces.C.size_t (Copy'Length * 4);
               Request.Code := Copy'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) /= 0
               then
                  Item.Matrices := False;
               else
                  Item.Halver := Made;

                  --  And the sixth, from the same source compiled with the
                  --  other eight formats. This one is allowed to fail on
                  --  its own: it is left null and those eight go to the row
                  --  product, while the six the fourth decodes carry on.
                  Request.Size := Interfaces.C.size_t (More'Length * 4);
                  Request.Code := More'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Extra := Made;
                  end if;

                  --  And the two narrow tiles, on the same terms: refused,
                  --  they leave a small batch on the wide tile.
                  Request.Size := Interfaces.C.size_t (Thin'Length * 4);
                  Request.Code := Thin'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow := Made;
                  end if;

                  Request.Size :=
                    Interfaces.C.size_t (Thin_More'Length * 4);
                  Request.Code := Thin_More'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow_More := Made;
                  end if;

                  Request.Size := Interfaces.C.size_t (Listed'Length * 4);
                  Request.Code := Listed'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Tile := Made;
                  end if;

                  Request.Size :=
                    Interfaces.C.size_t (Listed_More'Length * 4);
                  Request.Code := Listed_More'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Tile_More := Made;
                  end if;
               end if;
            end if;
         end;
      end if;

      --  Six storage buffers, and what a set of them looks like.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorSetLayout"));

         Bindings : aliased Binding_Array;
         Request  : aliased Set_Layout_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         for Index in Bindings'Range loop
            Bindings (Index).Binding := C.unsigned (Index - 1);
         end loop;

         Request.Bindings := Bindings'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Set_Layout := Made;
      end;

      --  The layout of the pipeline: that set, and the two numbers the
      --  shader is told about the shape.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreatePipelineLayout"));

         Sets    : aliased Address := Item.Set_Layout;
         Pushes  : aliased Push_Range;
         Request : aliased Pipeline_Layout_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Sets := Sets'Address;
         Request.Pushes := Pushes'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Layout := Made;
      end;

      --  And the pipelines, all from the one module.
      --
      --  Five of them, differing only in the two constants the shader takes:
      --  how wide a workgroup is and how many vectors an invocation carries.
      --  They were five modules until the fourth one put the generated Ada
      --  over the size this repository accepts, which was the right thing to
      --  be told -- ninety-six kilobytes of SPIR-V a copy, and the copies
      --  differed by one integer.
      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));

         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;

         type Told_Entries is array (1 .. 2) of aliased Specialization_Entry;
         type Told_Values is array (1 .. 2) of aliased C.unsigned;

         Entries : aliased Told_Entries :=
           [(Which => 0, At_Was => 0, Span => 4),
            (Which => 1, At_Was => 4, Span => 4)];

         Values : aliased Told_Values := [Group_Size, Batch_Group];
         Told   : aliased Specialization_Info;

         --  Made and reported rather than made and required: a device that
         --  refuses one of the narrower shapes runs every count on the one
         --  before it, which is what every device did before that shape
         --  existed. Only the first is a fault.
         procedure Line (Width, Group : C.unsigned; Into : out Address);

         procedure Line (Width, Group : C.unsigned; Into : out Address) is
         begin
            Values := [Width, Group];
            Request.Stage.Specialized := Told'Address;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Into := Made;
            end if;
         end Line;
      begin
         if Create = null then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Told.Count := 2;
         Told.Entries := Entries (Entries'First)'Address;
         Told.Span := 8;
         Told.Values := Values (Values'First)'Address;

         Request.Stage.Module := Item.Shader;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         Line (Group_Size, Batch_Group, Item.Pipeline);

         if Item.Pipeline = Null_Handle then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         for Count in Row_Line_Array'Range loop
            Line (Group_Size, C.unsigned (Count), Item.Row_Lines (Count));
         end loop;

         Line (Half_Group, 1, Item.Half_Group_Line);
         Line (Group_Size, Wide_Group, Item.Wide_Line);

         --  And the low-bit compilation's, one for each of those but the
         --  narrowed one, which is a sixteen-format tuning.
         Request.Stage.Module := Item.Low_Shader;
         Line (Group_Size, Batch_Group, Item.Low_Pipeline);

         for Count in Row_Line_Array'Range loop
            Line (Group_Size, C.unsigned (Count), Item.Low_Row_Lines (Count));
         end loop;

         Line (Group_Size, Wide_Group, Item.Low_Wide_Line);
         Request.Stage.Module := Item.Shader;

         if Item.Low_Pipeline = Null_Handle then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         --  The super-block row product, from its module, at a workgroup of
         --  thirty-two pinned to a subgroup of thirty-two -- one subgroup a
         --  workgroup, which is what lets the device honour the width. It
         --  carries one vector, the generating width.
         if Item.Wave_Shader /= Null_Handle then
            declare
               Reqsize : aliased Required_Size_Info;
            begin
               Reqsize.Required := Wave_Lanes;
               Request.Stage.Next := Reqsize'Address;
               Request.Stage.Flags := Require_Full_Subgroups;

               Request.Stage.Module := Item.Wave_Shader;
               Line (Wave_Lanes, 1, Item.Wave_Line);

               if Item.Wave_Shader5 /= Null_Handle then
                  Request.Stage.Module := Item.Wave_Shader5;
                  Line (Wave_Lanes, 1, Item.Wave_Line5);
               end if;

               if Item.Wave_Shader6 /= Null_Handle then
                  Request.Stage.Module := Item.Wave_Shader6;
                  Line (Wave_Lanes, 1, Item.Wave_Line6);
               end if;

               for Packing in Low_Packing loop
                  if Item.Low_Wave_Shaders (Packing) /= Null_Handle then
                     Request.Stage.Module := Item.Low_Wave_Shaders (Packing);
                     Line (Wave_Lanes, 1, Item.Low_Wave_Lines (Packing));
                  end if;
               end loop;

               Request.Stage.Module := Item.Shader;
               Request.Stage.Next := Null_Handle;
               Request.Stage.Flags := 0;
            end;
         end if;

         C.Strings.Free (Name);
      end;
      --  And the second kernel's pipeline, against the same layout.
      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));

         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
      begin
         if Create = null then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Request.Stage.Module := Item.Blender;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) /= 0
         then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Item.Blend_Line := Made;

         --  And the normalization's, on the same layout and after the
         --  request has its entry point and its layout -- which is the
         --  whole of what a pipeline needs and what creating one before
         --  those were set does not have.
         if Item.Normer /= Null_Handle then
            Request.Stage.Module := Item.Normer;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Norm_Line := Made;
            end if;
         end if;

         if Item.Router /= Null_Handle then
            Request.Stage.Module := Item.Router;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Route_Line := Made;
            end if;
         end if;

         if Item.Header /= Null_Handle then
            Request.Stage.Module := Item.Header;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Heads_Line := Made;
            end if;
         end if;

         if Item.Merger /= Null_Handle then
            Request.Stage.Module := Item.Merger;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Merge_Line := Made;
            end if;
         end if;

         if Item.Inverter /= Null_Handle then
            Request.Stage.Module := Item.Inverter;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Invert_Line := Made;
            end if;
         end if;

         if Item.Thinner /= Null_Handle then
            Request.Stage.Module := Item.Thinner;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Thin_Line := Made;
            end if;
         end if;

         if Item.Mixer /= Null_Handle then
            Request.Stage.Module := Item.Mixer;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Mix_Line := Made;
            end if;
         end if;

         if Item.Biaser /= Null_Handle then
            Request.Stage.Module := Item.Biaser;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Bias_Line := Made;
            end if;
         end if;

         if Item.Picker /= Null_Handle then
            Request.Stage.Module := Item.Picker;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Pick_Line := Made;
            end if;
         end if;

         if Item.Conver /= Null_Handle then
            Request.Stage.Module := Item.Conver;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Conv_Line := Made;
            end if;
         end if;

         if Item.Ruler /= Null_Handle then
            Request.Stage.Module := Item.Ruler;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Rule_Line := Made;
            end if;
         end if;

         if Item.Turner /= Null_Handle then
            Request.Stage.Module := Item.Turner;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Turn_Line := Made;
            end if;
         end if;

         if Item.Placer /= Null_Handle then
            Request.Stage.Module := Item.Placer;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Place_Line := Made;
            end if;
         end if;

         C.Strings.Free (Name);
      end;

      --  And the third kernel's pipeline, against the same layout.
      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));

         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
      begin
         if Create = null then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Request.Stage.Module := Item.Attender;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) /= 0
         then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Item.Attend_Line := Made;

         --  And the subgroup one, if its module was made. A refusal here is
         --  not a fault either.
         if Item.Grouped /= Null_Handle then
            Request.Stage.Module := Item.Grouped;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Group_Line := Made;
            end if;
         end if;

         if Item.Group_Line /= Null_Handle
           and then Item.Query_Tile /= Null_Handle
         then
            Request.Stage.Module := Item.Query_Tile;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Tile_Line := Made;
            end if;
         end if;

         if Item.Halver_Attend /= Null_Handle then
            Request.Stage.Module := Item.Halver_Attend;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Halved_Line := Made;
            end if;
         end if;

         if Item.Packed_Attend /= Null_Handle then
            Request.Stage.Module := Item.Packed_Attend;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Packed_Line := Made;
            end if;
         end if;

         if Item.Packed_Plain /= Null_Handle then
            Request.Stage.Module := Item.Packed_Plain;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Packed_Plain_Line := Made;
            end if;
         end if;

         if Item.Packer /= Null_Handle then
            Request.Stage.Module := Item.Packer;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Pack_Line := Made;
            end if;
         end if;

         if Item.Packer_Plain /= Null_Handle then
            Request.Stage.Module := Item.Packer_Plain;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Pack_Plain_Line := Made;
            end if;
         end if;

         --  Bound where the device offers no subgroup operations, or where
         --  a test asks.
         Item.Plain_Packing := Item.Packed_Line = Null_Handle;

         if Item.Halved_Line /= Null_Handle
           and then Item.Bundled_Attend /= Null_Handle
         then
            Request.Stage.Module := Item.Bundled_Attend;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Bundle_Line := Made;
            end if;

            --  And the same words at a bundle of eight, as the exact
            --  bundle has, for a token attending out of the copy.
            declare
               Which  : aliased Specialization_Entry :=
                 (Which => 1, At_Was => 0, Span => 4);
               Value  : aliased C.unsigned := Wide_Bundle;
               Told   : aliased Specialization_Info;
            begin
               Told.Count := 1;
               Told.Entries := Which'Address;
               Told.Span := 4;
               Told.Values := Value'Address;
               Request.Stage.Specialized := Told'Address;

               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) = 0
               then
                  Item.Eight_Halved_Line := Made;
               end if;

               Request.Stage.Specialized := Null_Handle;
            end;
         end if;

         if Item.Group_Line /= Null_Handle
           and then Item.Exact_Bundled_Attend /= Null_Handle
         then
            Request.Stage.Module := Item.Exact_Bundled_Attend;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Exact_Bundle_Line := Made;
            end if;

            --  And the same words at a bundle of eight, told through the
            --  shader's second specialization constant.
            declare
               Which  : aliased Specialization_Entry :=
                 (Which => 1, At_Was => 0, Span => 4);
               Value  : aliased C.unsigned := Wide_Bundle;
               Told   : aliased Specialization_Info;
            begin
               Told.Count := 1;
               Told.Entries := Which'Address;
               Told.Span := 4;
               Told.Values := Value'Address;
               Request.Stage.Specialized := Told'Address;

               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) = 0
               then
                  Item.Eight_Bundle_Line := Made;
               end if;

               Request.Stage.Specialized := Null_Handle;
            end;
         end if;

         if Item.Attend_Matrix /= Null_Handle then
            Request.Stage.Module := Item.Attend_Matrix;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Matrix_Attend := Made;
            end if;
         end if;

         if Item.Attend_Matrix_Wide /= Null_Handle then
            Request.Stage.Module := Item.Attend_Matrix_Wide;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Matrix_Wide_Attend := Made;
            end if;
         end if;

         --  And the unpacking of a packed layer into the copy that
         --  kernel reads, which is worth having only where it is.
         if Item.Unpacker /= Null_Handle
           and then Item.Matrix_Attend /= Null_Handle
         then
            Request.Stage.Module := Item.Unpacker;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Unpack_Line := Made;
            end if;
         end if;

         C.Strings.Free (Name);
      end;

      --  And the two pipelines the matrix product needs, against the same
      --  layout as the other three. A device that takes the module and
      --  refuses the pipeline is left on the row product for the same
      --  reason.
      if Item.Matrices then
         declare
            Create : constant Create_Pipelines_Call :=
              To_Create_Pipelines (Point ("vkCreateComputePipelines"));

            Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
            Request : aliased Compute_Pipeline_Info;
         begin
            if Create = null then
               C.Strings.Free (Name);
               Close (Item);
               return;
            end if;

            Request.Stage.Module := Item.Matrix;
            Request.Stage.Name := Name;
            Request.Layout := Item.Layout;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) /= 0
            then
               Item.Matrices := False;
            else
               Item.Matrix_Line := Made;

               Request.Stage.Module := Item.Halver;

               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) /= 0
               then
                  Item.Matrices := False;
               else
                  Item.Halve_Line := Made;

                  --  And the second tile, if its module was made. A
                  --  refusal here is not a fault either.
                  if Item.Extra /= Null_Handle then
                     Request.Stage.Module := Item.Extra;

                     if Create (Item.Logical, Null_Handle, 1,
                                Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Extra_Line := Made;
                     end if;
                  end if;

                  --  And the wide tile at sixty-four vectors, for listed
                  --  products.
                  if Item.Listed_Tile /= Null_Handle then
                     Request.Stage.Module := Item.Listed_Tile;

                     if Create (Item.Logical, Null_Handle, 1,
                                Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Listed_Line := Made;
                     end if;
                  end if;

                  if Item.Listed_Tile_More /= Null_Handle then
                     Request.Stage.Module := Item.Listed_Tile_More;

                     if Create (Item.Logical, Null_Handle, 1,
                                Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Listed_More_Line := Made;
                     end if;
                  end if;

                  if Item.Narrow /= Null_Handle then
                     Request.Stage.Module := Item.Narrow;

                     if Create (Item.Logical, Null_Handle, 1,
                                Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Narrow_Line := Made;
                     end if;
                  end if;

                  if Item.Narrow_More /= Null_Handle then
                     Request.Stage.Module := Item.Narrow_More;

                     if Create (Item.Logical, Null_Handle, 1,
                                Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Narrow_More_Line := Made;
                     end if;
                  end if;
               end if;
            end if;

            C.Strings.Free (Name);
         end;
      end if;

      --  Somewhere to keep one set of descriptors, and the set itself.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorPool"));

         --  Room for the single product's set and for one per step of the
         --  longest sequence, in one pool: six storage descriptors each,
         --  which is what the set layout declares. A pool sized for five
         --  of them hands out sets whose sixth descriptor was never
         --  allocated, and a device asked to write one wrote nothing --
         --  every product read whatever the binding held last.
         Sizes   : aliased Pool_Size :=
           (Kind  => Descriptor_Storage,
            Count => C.unsigned (7 * (1 + 2 * Sequence_Limit)));
         Request : aliased Descriptor_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Max_Sets := C.unsigned (1 + 2 * Sequence_Limit);
         Request.Sizes := Sizes'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Pool := Made;
      end;

      declare
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

         Layouts : aliased Address := Item.Set_Layout;
         Request : aliased Descriptor_Set_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Pool;
         Request.Layouts := Layouts'Address;

         if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Descriptor := Made;
      end;

      --  And one set per product a sequence may hold, from the same pool
      --  and against the same layout. Allocated in one call: a pool hands
      --  out as many sets as it is asked for, and asking thirty-two times
      --  would be thirty-two round trips for the same thing.
      declare
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

         Layouts : aliased array (1 .. Sequence_Limit) of Address :=
           [others => Item.Set_Layout];
         Given   : Set_Array := [others => Null_Handle];
         First   : aliased Address := Null_Handle
           with Address => Given (Given'First)'Address;
         Request : aliased Descriptor_Set_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Pool;
         Request.Count := C.unsigned (Sequence_Limit);
         Request.Layouts := Layouts (Layouts'First)'Address;

         if Allocate (Item.Logical, Request'Address, First'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Sets := Given;
      end;

      --  And a second array of them, for the sequence the host records
      --  while the device is still on the one before it.
      declare
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

         Layouts : aliased array (1 .. Sequence_Limit) of Address :=
           [others => Item.Set_Layout];
         Given   : Set_Array := [others => Null_Handle];
         First   : aliased Address := Null_Handle
           with Address => Given (Given'First)'Address;
         Request : aliased Descriptor_Set_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Pool;
         Request.Count := C.unsigned (Sequence_Limit);
         Request.Layouts := Layouts (Layouts'First)'Address;

         if Allocate (Item.Logical, Request'Address, First'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Sets_Two := Given;
      end;

      --  A pool of commands and one buffer to record into.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateCommandPool"));

         Request : aliased Command_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Family := C.unsigned (Item.Family);

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Commands := Made;
      end;

      declare
         Allocate : constant Allocate_Buffers_Call :=
           To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));

         Request : aliased Command_Buffer_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Commands;

         if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Buffer := Made;
      end;

      declare
         Allocate : constant Allocate_Buffers_Call :=
           To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));

         Request : aliased Command_Buffer_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Commands;

         if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Buffer_Two := Made;
      end;

      --  And something to wait on.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateFence"));

         Request : aliased Fence_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Fence := Made;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Fence_Two := Made;
      end;

      --  And what one submission signals for the next to wait on. Two
      --  submissions to one queue are not ordered against each other
      --  unless they are made to be, and the second reads what the first
      --  left at the front of the result buffer.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateSemaphore"));

         Request : aliased Fence_Create_Info :=
           (Kind => Structure_Semaphore_Create, others => <>);
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Signal := Made;
      end;

      Item.Slice := Slice;
      Item.Patience := Patience;
      Ready := True;
   end Open;

   --------------------------
   -- Forget_Matrices --
   --------------------------

   procedure Forget_Matrices (Item : in out Engine) is
      --  Buffers belong to the instance that made them, so the entry points
      --  have to be the ones this engine was opened with.
      Ignored : constant Boolean := Set_Asking (Item);
   begin
      --  Every slot ever given out, because a live entry keeps its slot
      --  and the ones between are the chain of free ones.
      for Index in 1 .. Item.Slots_Given loop
         Release_Weight
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory,
            Item.Kept (Index).Mapped);
         Item.Kept (Index) := (others => <>);
      end loop;

      --  And the ones kept back for reuse, which are the device's memory
      --  as much as the matrices are.
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
   end Forget_Matrices;

   --  Declared here because Close needs it and it is written below, with
   --  the other two of everything a submission holds.
   procedure Settle (Item : in out Engine; Ok : out Boolean);

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
      Instance_Of := Item.Instance;

      --  Nothing may be in flight: what follows destroys the fences and the
      --  semaphore a submission is still holding, and gives back the memory
      --  it is still reading.
      declare
         Settled : Boolean;
      begin
         Settle (Item, Settled);
      end;

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

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
      Give_Back_Buffer
        (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);
      Item.Cache_Bytes := 0;
      Item.Copy_Bytes := 0;

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

      --  Nothing is in flight and nothing has signalled: an engine opened
      --  after this one gets a fresh semaphore, and a submission that
      --  waited on it because this engine had armed the old one would wait
      --  for something that will never be signalled.
      Item.Pending := False;
      Item.Pending_Two := False;
      Item.Armed := False;
      Item.Sets_Two := [others => Null_Handle];
      Give_Back (Item.Commands, "vkDestroyCommandPool");
      Item.Descriptor := Null_Handle;
      Give_Back (Item.Signal, "vkDestroySemaphore");
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
      for Packing in Low_Packing loop
         Give_Back (Item.Low_Wave_Lines (Packing), "vkDestroyPipeline");
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
      Give_Back (Item.Eight_Bundle_Line, "vkDestroyPipeline");
      Give_Back (Item.Eight_Halved_Line, "vkDestroyPipeline");
      Give_Back (Item.Merge_Line, "vkDestroyPipeline");
      Give_Back (Item.Thin_Line, "vkDestroyPipeline");
      Give_Back (Item.Invert_Line, "vkDestroyPipeline");
      Give_Back (Item.Narrow_Line, "vkDestroyPipeline");
      Give_Back (Item.Narrow_More_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_Line, "vkDestroyPipeline");
      Give_Back (Item.Listed_More_Line, "vkDestroyPipeline");
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
      Give_Back (Item.Merger, "vkDestroyShaderModule");
      Give_Back (Item.Thinner, "vkDestroyShaderModule");
      Give_Back (Item.Inverter, "vkDestroyShaderModule");
      Give_Back (Item.Narrow, "vkDestroyShaderModule");
      Give_Back (Item.Narrow_More, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile, "vkDestroyShaderModule");
      Give_Back (Item.Listed_Tile_More, "vkDestroyShaderModule");
      Give_Back (Item.Halver, "vkDestroyShaderModule");
      Give_Back (Item.Matrix, "vkDestroyShaderModule");
      Give_Back (Item.Matrix_Attend, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Wide_Attend, "vkDestroyPipeline");
      Give_Back (Item.Attend_Matrix, "vkDestroyShaderModule");
      Give_Back (Item.Attend_Matrix_Wide, "vkDestroyShaderModule");
      Give_Back (Item.Query_Tile, "vkDestroyShaderModule");
      Give_Back (Item.Grouped, "vkDestroyShaderModule");
      Give_Back (Item.Attender, "vkDestroyShaderModule");
      Give_Back (Item.Norm_Line, "vkDestroyPipeline");
      Give_Back (Item.Route_Line, "vkDestroyPipeline");
      Give_Back (Item.Mix_Line, "vkDestroyPipeline");
      Give_Back (Item.Bias_Line, "vkDestroyPipeline");
      Give_Back (Item.Pick_Line, "vkDestroyPipeline");
      Give_Back (Item.Conv_Line, "vkDestroyPipeline");
      Give_Back (Item.Rule_Line, "vkDestroyPipeline");
      Give_Back (Item.Heads_Line, "vkDestroyPipeline");
      Give_Back (Item.Turn_Line, "vkDestroyPipeline");
      Give_Back (Item.Place_Line, "vkDestroyPipeline");
      Give_Back (Item.Normer, "vkDestroyShaderModule");
      Give_Back (Item.Router, "vkDestroyShaderModule");
      Give_Back (Item.Mixer, "vkDestroyShaderModule");
      Give_Back (Item.Biaser, "vkDestroyShaderModule");
      Give_Back (Item.Picker, "vkDestroyShaderModule");
      Give_Back (Item.Conver, "vkDestroyShaderModule");
      Give_Back (Item.Ruler, "vkDestroyShaderModule");
      Give_Back (Item.Header, "vkDestroyShaderModule");
      Give_Back (Item.Turner, "vkDestroyShaderModule");
      Give_Back (Item.Placer, "vkDestroyShaderModule");
      Give_Back (Item.Blender, "vkDestroyShaderModule");
      Give_Back (Item.Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader5, "vkDestroyShaderModule");
      for Packing in Low_Packing loop
         Give_Back (Item.Low_Wave_Shaders (Packing), "vkDestroyShaderModule");
      end loop;
      Give_Back (Item.Low_Shader, "vkDestroyShaderModule");
      Give_Back (Item.Wave_Shader6, "vkDestroyShaderModule");
      Item.Matrices := False;

      Item.Logical := Null_Handle;
      Item.Queue := Null_Handle;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Download := 0;
      Item.Instance := Null_Handle;

      --  Whoever was asking before this, if anyone was. Close is called from
      --  Open, and Open has an instance of its own to go back to.
      Instance_Of := Restore;
   end Close;

   function Is_Ready (Item : Engine) return Boolean
   is (Item.Pipeline /= Null_Handle and then Item.Fence /= Null_Handle
       and then not Item.Stalled);

   function Is_Stalled (Item : Engine) return Boolean is (Item.Stalled);

   function Readies_Heads (Item : Engine) return Boolean
   is (Item.Heads_Line /= Null_Handle);

   function Timed (Item : Engine) return Boolean is (Item.Timing);

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
   procedure Index_Drop (Item : in out Engine; Key : Address) is
      Hole  : Natural := Start_At (Key);
      Steps : Natural := 0;
   begin
      while Item.Index_Of (Hole) /= 0
        and then Item.Kept (Item.Index_Of (Hole)).Key /= Key
      loop
         Hole := (Hole + 1) mod Index_Slots;
         Steps := Steps + 1;
         exit when Steps > Index_Slots;
      end loop;

      if Item.Index_Of (Hole) = 0
        or else Item.Kept (Item.Index_Of (Hole)).Key /= Key
      then
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
      Index_Drop (Item, Item.Kept (Oldest).Key);
      Free_Slot (Item, Oldest);
      Item.Used := Item.Used - 1;

      Gone := True;
   end Give_Back_Least;

   --------------
   -- Resident --
   --------------

   function Resident (Item : Engine) return Natural is (Item.Used);

   function Resident_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Kept_Bytes);

   function Capacity (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Budget);

   function Given_Back (Item : Engine) return Natural is (Item.Released);

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
      Weight_Buffer : Address renames Buffer;
      Weight_Memory : Address renames Memory;
      Weight_Base   : Interfaces.Unsigned_64 renames Base;
      Weight_Own    : Boolean := False;
      Weight_Mapped : Address := Null_Handle;
      Weight_Tier   : Tier_Index := 1;
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
      Weight_Buffer := Null_Handle;
      Weight_Memory := Null_Handle;
      Weight_Base := 0;
      Borrowed := False;
      Ok := True;

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

                  while Gone and then Item.Used > 0 and then not Room loop
                     Give_Back_Least (Item, Gone, Pinned);
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

            Write_Bytes
              (Weight_Mapped,
               Weights (Weights'First + At_Byte
                        .. Weights'First + At_Byte
                           + Model_Runner.Bytes.Byte_Count (Weight_Bytes) - 1),
               Good);
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

   end Acquire_Weights;

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
   procedure Hand_Over (Item : in out Engine; Ok : out Boolean) is
      Submit : constant Submit_Call := To_Submit (Point ("vkQueueSubmit"));
      Reset  : constant Reset_Fences_Call :=
        To_Reset_Fences (Point ("vkResetFences"));

      Buffer_Handle : aliased Address := Item.Buffer;
      Fence_Handle  : aliased Address := Item.Fence;
      Wait_Handle   : aliased Address := Item.Signal;
      Signal_Handle : aliased Address := Item.Signal;
      Stage         : aliased C.unsigned := Pipeline_Stage_Compute;
      Request       : aliased Submit_Info;
   begin
      Ok := False;

      if Submit = null or else Reset = null then
         return;
      end if;

      Request.Buffers := Buffer_Handle'Address;

      --  Only where something has signalled it and nothing has waited yet.
      if Item.Armed then
         Request.Wait_Count := 1;
         Request.Waits := Wait_Handle'Address;
         Request.Wait_Stages := Stage'Address;
      end if;

      Request.Signal_Count := 1;
      Request.Signals := Signal_Handle'Address;

      if Reset (Item.Logical, 1, Fence_Handle'Address) /= 0
        or else Submit (Item.Queue, 1, Request'Address, Item.Fence) /= 0
      then
         return;
      end if;

      Item.Pending := True;
      Item.Armed := True;
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
   procedure Tile_Product
     (Item    : in out Engine;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural;
      Room    : Natural;
      Packing : Weight_Packing;
      Base    : Interfaces.Unsigned_64;
      Fresh   : Boolean;

      --  Where the answer goes in the half-precision buffer, in halves and
      --  plus one, or zero for the binary32 answer into the result buffer.
      Into    : Interfaces.Unsigned_64;

      --  Whether a join was folded into this product, so that what it
      --  stores is its answer plus the residual bound beside it.
      Joins   : Boolean;
      Good    : out Boolean)
   is
      Bind_Pipeline : constant Bind_Pipeline_Call :=
        To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
      Push     : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
      Dispatch : constant Dispatch_Call :=
        To_Dispatch (Point ("vkCmdDispatch"));
      Barrier  : constant Barrier_Call :=
        To_Barrier (Point ("vkCmdPipelineBarrier"));

      Wall : aliased Memory_Barrier;

      Held : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Count);
      Made : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Room);
   begin
      Good := False;

      if Bind_Pipeline = null or else Push = null or else Dispatch = null
        or else Barrier = null
      then
         return;
      end if;

      if Fresh then
         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Halve_Line);

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

         Barrier
           (Item.Buffer, Pipeline_Stage_Compute, Pipeline_Stage_Compute,
            0, 1, Wall'Address, 0, Null_Handle, 0, Null_Handle);
      end if;

      --  Whichever of the four tiles decodes this format at this width.
      --  A narrow tile that the device refused leaves the batch on the wide
      --  one, which is what Whole_Tiles has to agree about -- so the width
      --  below is asked of the same function the room was rounded with.
      Bind_Pipeline
        (Item.Buffer, Bind_Point_Compute,
         Tile_Pipeline (Item, Packing, Count));

      declare
         Shape : aliased Shape_Constants :=
           (Rows    => C.unsigned (Rows),
            Columns => C.unsigned (Columns),
            Count   => C.unsigned (Count),
            First   => C.unsigned (Into),
            Packing => C.unsigned (Weight_Packing'Pos (Packing)),
            Base    => C.unsigned (Base),
            Joins   => (if Joins then 1 else 0), Table => 0, others => <>);
      begin
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Product_Bytes, Shape'Address);
         Dispatch
           (Item.Buffer,
            C.unsigned (Rows / Tile_Rows),
            C.unsigned (Room / Tile_Width (Count)), 1);
      end;

      Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));
      Good := True;
   end Tile_Product;

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
      Tiled_Room   : constant Natural := Whole_Tiles (Count);
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
         if Borrowed then
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

      --  The two that change every call, grown when they have to.
      if Item.Vector_Bytes < Vector_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Release_Borrowed;
            return;
         end if;
         Item.Vector_Bytes := Vector_Bytes;
      end if;

      if Item.Result_Bytes < Result_Bytes then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
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
         Take (Item, 3 * Half_Bytes,
               Item.Half_Buffer, Item.Half_Memory, Good);
         if not Good then
            Release_Borrowed;
            return;
         end if;
         Item.Half_Bytes := 3 * Half_Bytes;
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

         for Index in Told'Range loop
            if Index in Buffers'Range then
               Told (Index).Buffer := Buffers (Index);
               Told (Index).Extent := Extent (Index);
            end if;

            Notes (Index).Target := Item.Descriptor;
            Notes (Index).Binding := C.unsigned (Index - 1);
            Notes (Index).Buffers := Told (Index)'Address;
         end loop;

         Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
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
           or else Start (Item.Buffer, Began'Address) /= 0
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
               Weight_Base, Fresh => True, Into => 0, Joins => False,
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
         else
            declare
               First : Natural := 0;
            begin
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count, Packing));

               while First < Count loop
                  declare
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
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Row_Reach (Item, Packing, Count, Rows)
                              * Row_Lane_Count (Item, Packing, Count)
                            + Row_Width (Item, Packing, Count) - 1)
                           / Row_Width (Item, Packing, Count)), 1, 1);
                  end;

                  First := First + Row_Group (Item, Count);
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

   procedure Reserve
     (Item            : in out Engine;
      Elements        : Model_Runner.Numerics.Element_Count;
      Copy_Upto       : Model_Runner.Numerics.Element_Count;
      Ok              : out Boolean;
      Allow_Copy_Only : Boolean := False;
      Keys_Upto       : Model_Runner.Numerics.Element_Count := 0)
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
      Copy_Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Copy_Upto) * 2;

      --  The keys' half of the copy and the values' half, in bytes, where
      --  the caller said in halves where the keys end. A whole number of
      --  the two makes the copy, so the values are what is left.
      Keys_Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Keys_Upto) * 2;
      Values_Wanted : constant Interfaces.Unsigned_64 :=
        (if Copy_Wanted >= Keys_Wanted then Copy_Wanted - Keys_Wanted else 0);

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
      Copy_Only : constant Boolean :=
        Split
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
      Copy_Alloc : constant Interfaces.Unsigned_64 :=
        (if Split then Keys_Wanted else Copy_Wanted);

      --  What the buffers being replaced held, kept until the new ones
      --  have been made and mapped.
      Carry_Over     : Boolean := False;
      Carried        : Interfaces.Unsigned_64 := 0;
      Carried_Buffer : Address := Null_Handle;
      Carried_Memory : Address := Null_Handle;

      Copy_Carried_At     : Address := Null_Handle;
      Copy_Carried_Buffer : Address := Null_Handle;
      Copy_Carried_Memory : Address := Null_Handle;
      Copy_Carried_Bytes  : Interfaces.Unsigned_64 := 0;
   begin
      Ok := False;

      if not Is_Ready (Item) or else Elements = 0 then
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
      if (Copy_Only or else Item.Cache_Bytes >= Wanted)
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

      --  The old one is kept until the new one holds what it held. A cache
      --  is dealt out in blocks a session apiece, and a session's block is
      --  its keys and values as they stand, so a wider buffer that came up
      --  empty would make every session write its whole cache over again --
      --  which it did, and cost a third of a round of eight members the
      --  first time that round formed.
      declare
         Was_Buffer   : Address := Item.Cache_Buffer;
         Was_Memory   : Address := Item.Cache_Memory;
         Was_At       : constant Address := Item.Cache_At;
         Was_Elements : constant Interfaces.Unsigned_64 :=
           Item.Cache_Elements;

         Was_Copy_Buffer : Address := Item.Copy_Buffer;
         Was_Copy_Memory : Address := Item.Copy_Memory;
         Was_Copy_At     : constant Address := Item.Copy_At;

         Was_Values_Buffer : Address := Item.Copy_Values_Buffer;
         Was_Values_Memory : Address := Item.Copy_Values_Memory;
         Was_Values_At     : constant Address := Item.Copy_Values_At;

         --  What the copy held, in bytes, which is no longer two for
         --  every element of the cache: it reaches as far as halves are
         --  read and no further, so what is carried into the new one is
         --  bounded by both.
         Was_Copy_Bytes : constant Interfaces.Unsigned_64 := Item.Copy_Bytes;

         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

         --  Both or neither: a cache without its copy is a cache the
         --  matrix kernel would read nothing out of. The values' buffer of
         --  a split copy goes back with them.
         procedure Give_Both_Back is
         begin
            if Was_At /= Null_Handle and then Unmap /= null then
               Unmap (Item.Logical, Was_Memory);
            end if;

            if Was_Copy_At /= Null_Handle and then Unmap /= null then
               Unmap (Item.Logical, Was_Copy_Memory);
            end if;

            if Was_Values_At /= Null_Handle and then Unmap /= null then
               Unmap (Item.Logical, Was_Values_Memory);
            end if;

            Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
            Give_Back_Buffer (Item, Was_Copy_Buffer, Was_Copy_Memory);
            Give_Back_Buffer (Item, Was_Values_Buffer, Was_Values_Memory);
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
            Item.Copy_Values_Bytes := 0;
            Item.Cache_Elements := 0;
            Item.Copy_Only := False;
            Item.Copy_Split := False;
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
         if not Copy_Only then
            Take (Item, Wanted, Item.Cache_Buffer, Item.Cache_Memory, Ok);
            if not Ok then
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
                  Give_Both_Back;
                  return;
               end if;
            end if;
         else
            Ok := True;
         end if;

         Carry_Over := Was_At /= Null_Handle and then Was_Elements > 0;
         Carried := Was_Elements;
         Carried_Buffer := Was_Buffer;
         Carried_Memory := Was_Memory;
         Copy_Carried_At := Was_Copy_At;
         Copy_Carried_Buffer := Was_Copy_Buffer;
         Copy_Carried_Memory := Was_Copy_Memory;
         Copy_Carried_Bytes := Was_Copy_Bytes;
      end;

      --  Mapped here and left mapped. The kind this came from is
      --  host-coherent by the rule that chose it, so a write through this
      --  pointer is seen by the device without a flush.
      declare
         Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
         Where : aliased Address := Null_Handle;
      begin
         if Map = null then
            Ok := False;
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
            return;
         end if;

         if not Copy_Only then
            if Map (Item.Logical, Item.Cache_Memory, 0, Wanted, 0,
                    Where'Access) /= 0
            then
               Ok := False;
               Item.Cache_Bytes := 0;
               Item.Copy_Bytes := 0;
               return;
            end if;

            Item.Cache_At := Where;
         end if;

         if Item.Copy_Buffer /= Null_Handle then
            if Map (Item.Logical, Item.Copy_Memory, 0, Copy_Alloc, 0,
                    Where'Access) /= 0
            then
               Ok := False;
               Item.Cache_Bytes := 0;
               Item.Copy_Bytes := 0;
               return;
            end if;

            Item.Copy_At := Where;
         end if;

         if Item.Copy_Values_Buffer /= Null_Handle then
            if Map (Item.Logical, Item.Copy_Values_Memory, 0, Values_Wanted, 0,
                    Where'Access) /= 0
            then
               Ok := False;
               Item.Cache_Bytes := 0;
               Item.Copy_Bytes := 0;
               Item.Copy_Values_Bytes := 0;
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
            Ok := False;
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
            return;
         end if;

         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Fill = null or else Copy_Buffer = null
           or else Barrier = null
           or else Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Ok := False;
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
            return;
         end if;

         if Item.Cache_Buffer /= Null_Handle then
            Fill (Item.Buffer, Item.Cache_Buffer, 0, Wanted, 0);
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

               Values : aliased Copy_Region :=
                 (From => 0, Into => 0, Span => Carried * 4);
               Halves : aliased Copy_Region :=
                 (From => 0, Into => 0,
                  Span =>
                    Interfaces.Unsigned_64'Min
                      (Copy_Carried_Bytes, Copy_Wanted));
            begin
               Barrier (Item.Buffer, Pipeline_Stage_Transfer,
                        Pipeline_Stage_Transfer, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);

               if Item.Cache_Buffer /= Null_Handle
                 and then Carried_Buffer /= Null_Handle
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
            Ok := False;
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
            return;
         end if;

         Submit_And_Wait (Item, Good, Cancelled, null);

         if not Good then
            Ok := False;
            Item.Cache_Bytes := 0;
            Item.Copy_Bytes := 0;
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
               Unmap (Item.Logical, Carried_Memory);

               if Copy_Carried_At /= Null_Handle then
                  Unmap (Item.Logical, Copy_Carried_Memory);
               end if;
            end if;
         end;

         Give_Back_Buffer (Item, Carried_Buffer, Carried_Memory);
         Give_Back_Buffer (Item, Copy_Carried_Buffer, Copy_Carried_Memory);
      end if;

      Item.Cache_Bytes := (if Copy_Only then 0 else Wanted);
      Item.Copy_Bytes :=
        (if Item.Copy_Buffer /= Null_Handle then Copy_Alloc else 0);
      Item.Copy_Values_Bytes :=
        (if Item.Copy_Values_Buffer /= Null_Handle then Values_Wanted else 0);
      Item.Cache_Elements := Interfaces.Unsigned_64 (Elements);
      Item.Copy_Only := Copy_Only;
      Item.Copy_Split := Split;
      Item.Copy_Keys_Halves := (if Split then Interfaces.Unsigned_64 (Keys_Upto) else 0);
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
      end if;

      Item.Cache_At := Null_Handle;
      Item.Copy_At := Null_Handle;
      Item.Copy_Values_At := Null_Handle;

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Give_Back_Buffer (Item, Item.Copy_Buffer, Item.Copy_Memory);
      Give_Back_Buffer (Item, Item.Copy_Values_Buffer, Item.Copy_Values_Memory);

      Item.Cache_Bytes := 0;
      Item.Copy_Bytes := 0;
      Item.Copy_Values_Bytes := 0;
      Item.Cache_Elements := 0;
      Item.Copy_Only := False;
      Item.Copy_Split := False;
   end Release_Cache;

   ---------------
   -- Put_Cache --
   ---------------

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
   begin
      Ok := False;

      if not Is_Ready (Item)
        or else Values'Length = 0
        or else (Item.Cache_At = Null_Handle
                 and then Item.Copy_At = Null_Handle)
        or else (Item.Cache_At /= Null_Handle
                 and then At_Byte + Span > Item.Cache_Bytes)
      then
         return;
      end if;

      --  Straight into the standing mapping: a copy and no call to the
      --  driver at all. Only where the cache proper is kept -- a copy-only
      --  session has just the half-precision copy below.
      if Item.Cache_At /= Null_Handle then
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
               for Index in Halves'Range loop
                  Halves (Index) :=
                    Model_Runner.Numerics.To_Half (Values (Index));
               end loop;
            end;
         end if;
      end;

      Ok := True;
   end Put_Cache;

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
       and then Packed.K_Bits in 4 | 8
       and then Packed.V_Bits in 4 | 8
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
     (Group_Size : Positive;
      Queries    : Positive;
      Span       : Natural) return Positive
   is (if Span < Bundle_Least then 1
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
         or else (Rounding and then not Packed_Cuts_A_Round)
       then 1
       else Natural'Max
              (1,
               Natural'Min
                 (Natural'Min (Slice_Limit,
                               (Want_Workgroups + Wide - 1) / Wide),
                  (Last - First + Slice_Least) / Slice_Least)));

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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      Slots : constant Natural := Natural'Max (Positions, 1);

      Kept_Bytes  : constant Interfaces.Unsigned_64 := Item.Cache_Bytes;
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
        or else not Packed_Fits
                      (Item,
                       (K_Bits => K_Bits, V_Bits => V_Bits,
                        K_Bytes => K_Bytes, V_Bytes => V_Bytes,
                        KS_At => KS_At, VS_At => VS_At,
                        K_Blocks => K_Blocks, V_Blocks => V_Blocks),
                       Head_Size, Value_Size, KV_Width, V_Width)
        or else Heads = 0
        or else Group_Size = 0
        or else Last < First
        or else Item.Cache_Buffer = Null_Handle
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

      if Item.Vector_Bytes < Query_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Query_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            return;
         end if;
         Item.Vector_Bytes := Query_Bytes;
      end if;

      if Item.Result_Bytes < Blend_Bytes then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Blend_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
            return;
         end if;
         Item.Result_Bytes := Blend_Bytes;
      end if;

      Standing (Item, Item.Vector_Memory, Item.Vector_At, Item.Vector_Bytes,
                Good);
      if Good then
         declare
            Room : Model_Runner.Numerics.Real_Array (Query'Range)
              with Import, Address => Item.Vector_At;
         begin
            Room := Query;
         end;
      end if;
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

         Told (1) := (Item.Cache_Buffer, 0, Kept_Bytes);
         Told (2) := (Item.Vector_Buffer, 0, Query_Bytes);
         Told (3) := (Item.Result_Buffer, 0, Blend_Bytes);
         Told (4) := Half_Descriptor (Item);
         Told (5) := Told (3);

         Told (6) := Copy_Descriptor (Item);

         for Binding in Told'Range loop
            Notes (Binding).Target := Item.Descriptor;
            Notes (Binding).Binding := C.unsigned (Binding - 1);
            Notes (Binding).Buffers := Told (Binding)'Address;
         end loop;

         Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
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

         Queries : constant Positive := Packed_Queries (Slots);
         Bundle  : constant Positive :=
           Packed_Bundle (Group_Size, Queries, Last - First + 1);

         Shape : aliased Packed_Constants :=
           (Heads      => C.unsigned (Heads),
            Head_Size  => C.unsigned (Head_Size),
            Value_Size => C.unsigned (Value_Size),
            Group_Size => C.unsigned (Group_Size),
            First      => C.unsigned (First),
            Last       => C.unsigned (Last),
            K_Bytes    => C.unsigned (K_Bytes),
            V_Bytes    => C.unsigned (V_Bytes),
            KV_Width   => C.unsigned (KV_Width),
            V_Width    => C.unsigned (V_Width),
            KS_At      => C.unsigned (KS_At),
            VS_At      => C.unsigned (VS_At),
            K_Blocks   => C.unsigned (K_Blocks),
            V_Blocks   => C.unsigned (V_Blocks),
            K_Bits     => C.unsigned (K_Bits),
            V_Bits     => C.unsigned (V_Bits),
            Scale      => C.C_float (Scale),
            Cap        => C.C_float (Cap),
            Max_Bias   => C.C_float (Max_Bias),
            Positions  => C.unsigned (Slots),
            Window     => C.unsigned (Window),
            Causal     => (if Causal then 1 else 0),
            Bundle     => C.unsigned (Bundle),
            Queries    => C.unsigned (Queries),
            Table_At   => 0,
            Sinks_At   => 0,

            --  The single call reads one session's cache whole, never a
            --  round and never in pages.
            Pages_At       => 0,
            Page_Shift     => 0,
            First_Position => 0);
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            return;
         end if;

         declare
            Settled : Boolean;
         begin
            Settle (Item, Settled);
            if not Settled then
               return;
            end if;
         end;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            return;
         end if;

         --  A workgroup its rows of heads and positions, and one slice:
         --  the single call has no merge after it, and a sequence is
         --  where a token's long cache is cut.
         Bind_Pipeline (Item.Buffer, Bind_Point_Compute,
                        Packed_Pipeline (Item));
         Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Packed_Bytes, Shape'Address);
         Dispatch (Item.Buffer,
                   C.unsigned ((Heads + Bundle - 1) / Bundle),
                   C.unsigned ((Slots + Queries - 1) / Queries), 1);

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
   end Attend_Packed;

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

      if not Is_Ready (Item)
        or else Item.Cache_At = Null_Handle
        or else Values'Length = 0
        or else At_Byte + Span > Item.Cache_Elements * 4
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
         if Was_At /= Null_Handle and then Unmap /= null then
            Unmap (Item.Logical, Was_Memory);
         end if;
         Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
         Item.State_Bytes := 0;
         return;
      end if;

      if Map (Item.Logical, Item.State_Memory, 0, Wanted, 0, Where'Access)
         /= 0
      then
         Ok := False;
         Give_Back_Buffer (Item, Item.State_Buffer, Item.State_Memory);
         if Was_At /= Null_Handle and then Unmap /= null then
            Unmap (Item.Logical, Was_Memory);
         end if;
         Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
         Item.State_Bytes := 0;
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
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Ok := False;
            Item.State_Bytes := 0;
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
            Ok := False;
            Item.State_Bytes := 0;
            return;
         end if;

         Submit_And_Wait (Item, Good, Cancelled, null);

         if not Good then
            Ok := False;
            Item.State_Bytes := 0;
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
      Copier  : Copy_Buffer_Call);

   procedure Move_Run
     (Item    : in out Engine;
      Buffer  : Address;
      From    : Interfaces.Unsigned_64;
      Into    : Interfaces.Unsigned_64;
      Bytes   : Interfaces.Unsigned_64;
      Copier  : Copy_Buffer_Call)
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
         begin
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

      Began : aliased Command_Begin_Info;

      Good, Cancelled : Boolean;
   begin
      Ok := False;

      for Run of Runs loop
         Reaches :=
           Model_Runner.Numerics.Element_Count'Max
             (Reaches, Run.At_Value + Run.Count);
      end loop;

      if not Is_Ready (Item)
        or else Item.Cache_Buffer = Null_Handle
        or else Runs'Length = 0
        or else Reaches = 0
        or else Into >= From
        or else Interfaces.Unsigned_64 (From + Reaches) * 4 > Item.Cache_Bytes
        or else Reset_Buffer = null or else Start = null
        or else Stop = null or else Copier = null
      then
         return;
      end if;

      --  A kernel in flight may be reading the block.
      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Start (Item.Buffer, Began'Address) /= 0
      then
         return;
      end if;

      for Run of Runs loop
         if Run.Count > 0 then
            Move_Run
              (Item, Item.Cache_Buffer,
               Interfaces.Unsigned_64 (From + Run.At_Value) * 4,
               Interfaces.Unsigned_64 (Into + Run.At_Value) * 4,
               Interfaces.Unsigned_64 (Run.Count) * 4, Copier);

            if Halves
              and then Item.Copy_Buffer /= Null_Handle
              and then Interfaces.Unsigned_64 (From + Run.At_Value + Run.Count)
                         * 2 <= Item.Copy_Bytes
            then
               Move_Run
                 (Item, Item.Copy_Buffer,
                  Interfaces.Unsigned_64 (From + Run.At_Value) * 2,
                  Interfaces.Unsigned_64 (Into + Run.At_Value) * 2,
                  Interfaces.Unsigned_64 (Run.Count) * 2, Copier);
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
        or else Stop = null or else Copier = null
      then
         return;
      end if;

      Settle (Item, Good);

      if not Good
        or else Reset_Buffer (Item.Buffer, 0) /= 0
        or else Start (Item.Buffer, Began'Address) /= 0
      then
         return;
      end if;

      Move_Run (Item, Item.State_Buffer, From_Byte, Into_Byte, Span, Copier);

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;

      Submit_And_Wait (Item, Good, Cancelled, null);
      Ok := Good;
   end Move_State;

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
        or else Start (Item.Buffer, Began'Address) /= 0
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

   function Runs_Linear (Item : Engine) return Boolean
   is (Item.Conv_Line /= Null_Handle and then Item.Rule_Line /= Null_Handle);

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

      if Item.Vector_Bytes < Query_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Query_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            return;
         end if;
         Item.Vector_Bytes := Query_Bytes;
      end if;

      if Item.Result_Bytes < Blend_Bytes then
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Blend_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
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
           or else Start (Item.Buffer, Began'Address) /= 0
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
         Dispatch (Item.Buffer, C.unsigned (Heads),
                   Attend_Groups (Item, Slots, Head_Size, Value_Size), 1);

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
      Ok      : out Boolean)
   is
      Wide : constant Interfaces.Unsigned_64 := Row_Bytes (Packing, Columns);

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

      --  Nothing in flight may be reading a matrix this evicts, so the
      --  device is settled first; a load is the only caller and nothing
      --  is in flight then.
      Settle (Item, Ok);
      if not Ok then
         return;
      end if;

      Acquire_Weights
        (Item, Weights, At_Byte, Packing, Rows, Columns,
         Interfaces.Unsigned_64 (Rows) * Wide,
         Buffer, Memory, Base, Borrowed, Ok, Key);

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
            return "norm " & Shape (1, This.Rows);
         elsif This.Rotates then
            return "rotate";
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
         elsif This.Picks then
            return "pick";
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
         elsif This.Gathers > 0 then
            return "gather " & Shape (This.Each, This.Columns) & " "
              & Packing_Name (This.Packing)
              & (if This.Joins then " +join" else "");
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
      From_Step : Natural := 0)
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
         Kept => Kept,
         Blends => False, Unit => 0, Attends => False,
         others => <>);
      Added := True;
   end Add_Chained_Product;

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
      Routed    : Natural := 0)
   is
      Source : constant Natural :=
        (if From_Step = 0 then Steps.Held else From_Step);

      --  What a chained gather reads: each member its own stretch of the
      --  source, or all of them the whole of it.
      Wanted : constant Natural :=
        (if Apart > 0 then Columns * Count else Columns);
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Count > Max_Gather
        or else Each = 0
        or else Stack < Each
        or else (Apart > 0 and then Apart /= Columns)
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
         for Index in 1 .. Count loop
            if (Members (Index) + 1) * Each > Stack then
               return;
            end if;
         end loop;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Each * Count, Columns => Columns, Key => Key,
         Chained => Chained,
         Reads => (if Chained and then From_Step /= 0 then From_Step else 0),
         Kept => Kept,
         Blends => False, Unit => 0, Attends => False,
         Gathers => Count, Members => Members, Stack => Stack,
         Each => Each, Apart => Apart, Routed => Routed,
         others => <>);
      Added := True;
   end Add_Gathered_Product;

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

      --  Rows is room: two words an expert, three a position and rank,
      --  and thirty more an expert for the padding of the runs is what
      --  the lists take, and a step's room is Rows a position.
      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => 32 * Experts + 3 * Used, Columns => Experts,
         Chained => True, Reads => Route_Step,
         Kept => Kept, Inverts => True, Used => Used,
         Attends => False, Blends => False,
         others => <>);
      Added := True;
   end Add_Invert;

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
      Chained     : Boolean := True)
   is
      Source : constant Natural :=
        (if not Chained then 0
         elsif From_Step = 0 then Steps.Held else From_Step);

      --  Slots a position, with the padding: fifteen slots at most for
      --  each expert that has a run, spread over the positions.
      Slots : constant Natural :=
        Used + (15 * Natural'Min (Experts, Count * Used) + Count - 1)
               / Count;

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
        or else Each * Experts > Stack
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
      Source_Stride : Natural := 0) is

      --  A sliced bias reads Each rows out of a wider fused product, its own
      --  lying at Source_At and every Source_Stride after; the stride is the
      --  fused product's whole row count. Both zero is the ordinary bias
      --  whose rows are all of its source's, laid one position after another.
      Sliced : constant Boolean := Source_Stride /= 0;
   begin
      Added := False;

      if Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Experts = 0
        or else Each = 0
        or else Span < At_Byte + Model_Runner.Bytes.Byte_Count (Experts * Each) * 4
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
        --  A projection's bias: one slice, over a product of Each rows.
        or else (not Sliced and then Route_Step = 0 and then Count = 0
                 and then (Experts /= 1
                           or else Steps.Items (Source_Step).Rows /= Each))
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
         Kept => Kept, Biases => True,
         Stack => Experts, Each => Each,
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
        or else Shape.Mix mod Shape.Head /= 0
        or else Shape.Taps < 2
        or else Shape.Unit_Blocks > Shape.Mix / Shape.Head
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
         Rows => Shape.Mix, Columns => Shape.Mix,
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
      Alone : constant Boolean := Unit in 4 | 5;

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
        --  The seventh unit's second arm is one number a position, and
        --  every other unit's is as wide as the first.
        or else (if Unit = 7
                 then Steps.Items (Second).Rows /= 1
                 elsif not Alone
                 then Steps.Items (First).Rows /= Steps.Items (Second).Rows
                 else False)
        or else Unit > 7
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
      Kept          : Boolean := True)
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
        and then not Steps.Items (Other).Norms
        and then not Steps.Items (Other).Blends
        and then not Steps.Items (Other).Attends
        and then not Steps.Items (Other).Places
        and then not Steps.Items (Other).Rotates
        --  A biasing step is not a product either, and its kernel adds
        --  no residual: a join folded into it was a join lost, which is
        --  what the first gpt-oss layer over the device did.
        and then not Steps.Items (Other).Biases
        and then not Steps.Items (Other).Folded;
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
         Folded => Foldable,
         others => <>);

      if Foldable then
         Steps.Items (Other).Joins := True;
         Steps.Items (Other).Joined := Steps.Held;
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
                 and then (Packed.Bits not in 4 | 8
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
      V_Row_Count     : Natural := 0)
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
        or else Rotary = 0
        or else Rotary mod 2 /= 0
        or else Rotary > Head_Size
        or else Table = System.Null_Address
        or else (Into_Cache and then Stride < Width)
        or else (V_Step /= 0
                 and then (not Into_Cache
                           or else V_Step > Steps.Held
                           or else V_Stride < V_Actual))
        or else (not Into_Cache and then V_Step /= 0)
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
         Turn_Table => Table, Epsilon => Epsilon,
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
         others => <>);

      --  The table's span is what the rotation step checks too: two wide
      --  numbers a pair a position, and the caller has said how many.
      Added := Table_Span > 0;
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
      Page_Shift : Natural := 0) is
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
        or else Value_Size > Attention_Room
        or else Group_Size = 0
        or else Last < First
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
         Causal => Causal, Max_Bias => Max_Bias,
         Packed => Packed, Sinks => Sinks_At,
         Pages_At => Pages_At, Page_Shift => Page_Shift,
         others => <>);
      Added := True;
   end Add_Attention;

   ---------
   -- Run --
   ---------

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
      Carry_Out : Boolean := False)
   is
      use type System.Storage_Elements.Integer_Address;

      Ignored : constant Boolean := Set_Asking (Item);

      --  A storage buffer binding may not begin anywhere: a device states
      --  the boundary it wants, and no device asks for more than this.
      --  Rounding every step's share up to it is cheaper than reading the
      --  limit and far cheaper than getting it wrong, which is a validation
      --  failure on some drivers and wrong answers on others.
      Alignment : constant Interfaces.Unsigned_64 := 256;

      --  Where each product's matrix and result ended up.
      type Place is record
         Buffer   : Address := Null_Handle;
         Memory   : Address := Null_Handle;
         Base     : Interfaces.Unsigned_64 := 0;
         Borrowed : Boolean := False;
         Weight   : Interfaces.Unsigned_64 := 0;
         At_Byte  : Interfaces.Unsigned_64 := 0;
         Bytes    : Interfaces.Unsigned_64 := 0;
      end record;

      Places : array (1 .. Sequence_Limit) of Place;

      --  What the activation buffer has to hold. The first step's own
      --  reading of it, and past that whatever a step reading at an offset
      --  needs -- a residual join reads the residual, which travels behind
      --  the queries in the same array.
      function Vector_Elements return Model_Runner.Numerics.Element_Count;

      function Vector_Elements return Model_Runner.Numerics.Element_Count is
         Most : Model_Runner.Numerics.Element_Count :=
           Model_Runner.Numerics.Element_Count (Steps.Items (1).Columns)
           * Model_Runner.Numerics.Element_Count (Count);
      begin
         for Index in 1 .. Steps.Held loop
            if Steps.Items (Index).At_Vector > 0 then
               --  What a step reads from the activation is its COLUMNS,
               --  which for a join is its width and for a product is the
               --  vector the matrix takes. It said Rows, and a join's rows
               --  and columns are the same number so nothing noticed --
               --  until a group of down projections read its own stretch of
               --  one activation, where the rows are the answer's width and
               --  the columns are the expert's, and the upload ran off the
               --  end of the array.
               Most := Model_Runner.Numerics.Element_Count'Max
                 (Most,
                  Model_Runner.Numerics.Element_Count
                    (Steps.Items (Index).At_Vector)
                  + Model_Runner.Numerics.Element_Count
                      (Steps.Items (Index).Columns)
                    * Model_Runner.Numerics.Element_Count (Count));
            end if;
         end loop;

         return Most;
      end Vector_Elements;

      Vector_Room  : constant Model_Runner.Numerics.Element_Count :=
        Vector_Elements;

      --  Whether a step goes to the tile kernel. A gather of more than one
      --  member never does: the tile kernel reads one matrix at one base,
      --  and a gather of one is that, at the base of the slice it names.
      --  The slots a listed product's runs may take, with the padding
      --  and a tile's worth past the end for the loads a tile makes
      --  beyond its run.
      function Listed_Slots (Which : Positive) return Natural
      is (Steps.Items (Which).Rows / Steps.Items (Which).Each * Count
          + Tile_Vectors);

      --  Whether a listed product goes to the matrix kernel, every
      --  expert's run as a tile of the half-precision copy that
      --  half_batch.comp lays out from the lists: where the batch is
      --  long enough for the tile at all, and the slice's rows divide
      --  by it. The row kernel walks the runs otherwise.
      --
      --  The wide tile's words at sixty-four vectors, whatever an expert's
      --  run: a run of thirty-two in a tile of a hundred and twenty-eight
      --  is three quarters padding the instruction multiplies all the
      --  same, and the narrow tile of thirty-two -- one subgroup -- read
      --  slower than either, because it decodes a row into the
      --  instruction's operand once a tile and a subgroup alone hides
      --  none of that.
      function Listed_Tiled (Which : Positive) return Boolean
      is (Steps.Items (Which).Listed
          and then Uses_Matrix
                     (Item, Steps.Items (Which).Packing,
                      Steps.Items (Which).Each,
                      Steps.Items (Which).Columns, Count)
          --  The listed tile steps as the wide one does, whatever the
          --  batch, so the columns have to divide by its step.
          and then Steps.Items (Which).Columns mod Listed_Step = 0
          and then Steps.Items (Which).Each mod Listed_Rows = 0
          and then Listed_Pipeline (Item, Steps.Items (Which).Packing)
                   /= Null_Handle);

      --  A product, as against every other kind of step: the tile is
      --  theirs alone, and a question asked of a step's rows and columns
      --  without asking what kind it is would say yes of an attention
      --  step with the right numbers.
      function Is_Product (Which : Positive) return Boolean
      is (not (Steps.Items (Which).Norms or else Steps.Items (Which).Rotates
               or else Steps.Items (Which).Places
               or else Steps.Items (Which).Readies
               or else Steps.Items (Which).Attends
               or else Steps.Items (Which).Routes
               or else Steps.Items (Which).Mixes
               or else Steps.Items (Which).Biases
               or else Steps.Items (Which).Picks
               or else Steps.Items (Which).Convolves
               or else Steps.Items (Which).Rules
               or else Steps.Items (Which).Inverts
               or else Steps.Items (Which).Blends));

      function Tiled (Which : Positive) return Boolean
      is (Is_Product (Which)
          and then Steps.Items (Which).Gathers <= 1
          and then not Steps.Items (Which).Listed
          and then not Steps.Items (Which).Exact
          and then Uses_Matrix
                     (Item, Steps.Items (Which).Packing,
                      Steps.Items (Which).Rows,
                      Steps.Items (Which).Columns, Count));

      --  Bytes one member's slice of a gathered step takes, and where a
      --  gather of one begins: the tile kernel and the single-member row
      --  product both read that slice as a matrix of its own.
      function Slice_Bytes (Which : Positive) return Interfaces.Unsigned_64
      is (Interfaces.Unsigned_64 (Steps.Items (Which).Each)
          * Row_Bytes (Steps.Items (Which).Packing,
                       Steps.Items (Which).Columns));

      function Slice_Base (Which : Positive) return Interfaces.Unsigned_64
      is (if Steps.Items (Which).Gathers = 1
          then Interfaces.Unsigned_64 (Steps.Items (Which).Members (1))
               * Slice_Bytes (Which)
          else 0);

      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Vector_Room) * 4;

      --  Room the result buffer keeps at its front for the activation a
      --  sequence carries in or leaves behind. Nothing else is placed
      --  there, so a sequence may read what the one before it wrote while
      --  writing its own answers past it.
      --
      --  Wide enough for a tile's store as well as the activation's own
      --  size. Where a join is folded into the product before it, the step
      --  that leaves the answer here is a product rather than a join, and a
      --  product on the matrix kernel stores the columns the rounding
      --  invented beside the real ones. A hundred and ten columns of a
      --  batch rounded to a hundred and twenty-eight is a sixth more than
      --  the activation measures, and the front has to hold it or the carry
      --  is refused and the sequence after this one reads a room nothing
      --  wrote.
      Carry_Room : constant Interfaces.Unsigned_64 :=
        (Interfaces.Unsigned_64'Max
           (Vector_Bytes,
            (if Steps.Held = 0 then 0
             else Interfaces.Unsigned_64 (Steps.Items (Steps.Held).Rows)
                  * Interfaces.Unsigned_64 (Whole_Tiles (Count)) * 4))
         + Alignment - 1) / Alignment * Alignment;

      Result_Bytes : Interfaces.Unsigned_64 := Carry_Room;

      --  Room the angles need, which the widest rotating step decides.
      Turn_Room : Interfaces.Unsigned_64 := 0;

      --  The clock reading a sequence's matrices are pinned from, so that
      --  acquiring the last of them cannot release the first.
      Pinned : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;

      --  The largest half-precision copy any step of this sequence wants,
      --  which is what the one buffer holding it has to be. Zero when no
      --  step goes to the matrix kernel, and then no buffer is made.
      Half_Bytes   : Interfaces.Unsigned_64 := 0;

      Wanted       : Model_Runner.Numerics.Element_Count := 0;
      Good         : Boolean;

      --  Give back whatever this call borrowed, on every way out.
      procedure Release_All;

      procedure Release_All is
      begin
         for Index in 1 .. Steps.Held loop
            if Places (Index).Borrowed then
               Give_Back_Buffer
                 (Item, Places (Index).Buffer, Places (Index).Memory);
               Places (Index).Borrowed := False;
            end if;
         end loop;
      end Release_All;
   begin
      Ok := False;
      Cancelled := False;

      --  Until the shapes are through, a refusal is a shape's; the
      --  attention step names its own two below.
      Item.Refused := Shape_Refused;

      if Steps.Held = 0 or else not Is_Ready (Item) then
         return;
      end if;

      --  What the whole run needs, and whether it is askable at all. Every
      --  product reads the same activation, so they must agree about how
      --  wide it is; they may differ in every other way.
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);

            Wide : constant Interfaces.Unsigned_64 :=
              Row_Bytes (This.Packing, This.Columns);

            --  Vectors this step's answers are given room for: the batch
            --  rounded up to a whole tile where the matrix kernel will run,
            --  and the batch itself everywhere else. The rounding is room
            --  the kernel writes and nothing reads; the read-back below
            --  takes the batch's own share from the front of it.
            Room : constant Natural :=
              (if Tiled (Index) then Whole_Tiles (Count) else Count);

            Mine : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (This.Rows)
              * Interfaces.Unsigned_64 (Room) * 4
              --  And after an attending step's answers, room for the
              --  records its slices leave for the merge: a blend and two
              --  numbers a slice, position and head. Sized for the most
              --  slices, whatever this run cuts.
              + (if This.Attends and then Item.Merge_Line /= Null_Handle
                 then Interfaces.Unsigned_64 (Slice_Limit)
                      * Interfaces.Unsigned_64 (Room)
                      * Interfaces.Unsigned_64
                          (This.Rows + 2 * This.Heads) * 4
                 else 0);
         begin
            if Tiled (Index) then
               --  What it reads, and what it may be asked to write: a
               --  product whose answer is wanted only in half precision
               --  writes it here rather than into the result buffer.
               Half_Bytes := Interfaces.Unsigned_64'Max
                 (Half_Bytes,
                  Interfaces.Unsigned_64'Max
                    (Interfaces.Unsigned_64 (This.Columns),
                     Interfaces.Unsigned_64 (This.Rows))
                  * Interfaces.Unsigned_64 (Room) * 2);
            elsif Listed_Tiled (Index) then
               --  The runs' vectors, laid out by slot.
               Half_Bytes := Interfaces.Unsigned_64'Max
                 (Half_Bytes,
                  Interfaces.Unsigned_64 (This.Columns)
                  * Interfaces.Unsigned_64 (Listed_Slots (Index)) * 2);
            end if;

            --  A combining step carries no matrix: it reads the two
            --  results before it and writes its own. Everything the shape
            --  checks below say about a matrix is beside the point for it.
            if This.Places then
               --  A placing step carries no weight and reads no matrix: it
               --  writes what a step before it made into the cache, so what
               --  it needs is a cache to write into.
               if This.Rows = 0
                 or else (Item.Cache_Buffer = Null_Handle
                          and then not (Item.Copy_Only
                                        and then Item.Copy_Buffer
                                                 /= Null_Handle))
                 or else (This.Reads = 0 and then not This.Unpacks)
                 or else This.Reads > Steps.Held
                 --  And the kernel that packs, for a packed row, or the
                 --  one that unpacks, for a batch's copy of them -- and
                 --  room in the copy for what it writes.
                 or else (This.Pack.Bits /= 0
                          and then not This.Unpacks
                          and then Pack_Pipeline (Item) = Null_Handle)
                 or else (This.Unpacks
                          and then (Item.Unpack_Line = Null_Handle
                                    or else This.Half_At
                                            + Interfaces.Unsigned_64 (This.Cells)
                                              * Interfaces.Unsigned_64 (This.Rows)
                                            > Item.Cache_Bytes / 2))
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Rotates then
               --  A rotating step carries a table of two wide numbers a
               --  pair a position, which the device keeps the way it keeps
               --  a matrix -- so everything below about residency serves it
               --  and only the shape check differs.
               if This.Rows = 0
                 or else This.Base = System.Null_Address
                 or else This.Reads > Steps.Held
               then
                  return;
               end if;

               Places (Index).Weight := 0;

               Turn_Room := Interfaces.Unsigned_64'Max
                 (Turn_Room,
                  Interfaces.Unsigned_64 (This.Turns / 2)
                  * Interfaces.Unsigned_64 (Count) * 16);
            elsif This.Norms then
               --  A normalizing step carries a weight of one element a
               --  component, which the device keeps the way it keeps a
               --  matrix -- so everything below about residency serves it
               --  and only the shape check differs.
               if This.Rows = 0
                 or else This.Base = System.Null_Address
                 or else This.Reads > Steps.Held
                 or else Interfaces.Unsigned_64 (This.Span)
                           < Interfaces.Unsigned_64 (This.At_Byte)
                             + Interfaces.Unsigned_64
                                 (This.Rows / This.Groups) * 4
                               * (if This.Shifts then 2 else 1)
               then
                  return;
               end if;

               --  The weight is one stretch wide, however many stretches
               --  a position is normalized as -- and two, gain then
               --  shift, for the centred normalization.
               Places (Index).Weight :=
                 Interfaces.Unsigned_64 (This.Rows / This.Groups) * 4
                 * (if This.Shifts then 2 else 1);
            elsif This.Biases then
               --  A biasing step carries the bias stack, which the device
               --  keeps the way it keeps a matrix, and reads a gathered
               --  product and its routing.
               if This.Rows = 0
                 or else This.Base = System.Null_Address
                 or else This.Reads = 0
                 or else This.Reads > Steps.Held
                 or else This.Reads_Two > Steps.Held
                 or else Item.Bias_Line = Null_Handle
               then
                  return;
               end if;

               Places (Index).Weight :=
                 Interfaces.Unsigned_64 (This.Stack * This.Each) * 4;
            elsif This.Attends then
               --  An attention step carries no matrix either, and reads a
               --  cache rather than a weight. What it needs that the shape
               --  checks below cannot say is that the cache is there: a
               --  sequence recorded against a cache the engine does not
               --  hold would dispatch against whatever the binding last
               --  named, which is an answer and a wrong one. Where only the
               --  copy is kept the cache proper is null, but the matrix
               --  kernel reads the copy and a copy-only session has one --
               --  and it is sinkless, so nothing here reads the binary32.
               if Item.Cache_Buffer = Null_Handle
                 and then not (Item.Copy_Only
                               and then Item.Copy_Buffer /= Null_Handle)
               then
                  Item.Refused := Cache_Refused;
                  return;
               end if;

               --  A split copy keeps its values on a binding of their own,
               --  which only the matrix kernel reads. A batch too small for
               --  that kernel -- a generated token -- has no device kernel
               --  that reads the split copy, so it is refused here and
               --  attends on the host out of the host's own cache, as it
               --  did before the copy grew past one buffer.
               if Item.Copy_Split
                 and then not Attends_By_Matrix
                                (Item, Count, This.Head_Size, This.Value_Size)
               then
                  Item.Refused := Cache_Refused;
                  return;
               end if;

               --  A packed block needs the kernel that reads one, and a
               --  shape that kernel takes.
               if This.Packed.K_Bits /= 0
                 and then not Packed_Fits
                                (Item, This.Packed, This.Head_Size,
                                 This.Value_Size, This.KV_Width,
                                 This.V_Width)
               then
                  Item.Refused := Packed_Refused;
                  return;
               end if;

               if This.Rows = 0
                 or else (not This.Chained
                          and then Model_Runner.Numerics.Element_Count
                                     (This.Columns)
                                   * Model_Runner.Numerics.Element_Count
                                       (Count)
                                   > Vectors'Length)
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Readies then
               --  A heads step reads a projection and, placing, the
               --  values' projection; it carries a weight one head wide or
               --  none, kept like a normalization's; and it needs the
               --  cache where it places, and the pipeline at all.
               if This.Rows = 0
                 or else This.Reads not in 1 .. Index - 1
                 or else Steps.Items (This.Reads).Rows /= This.Rows
                 or else (This.Reads_Two /= 0
                          and then This.Reads_Two not in 1 .. Index - 1)
                 or else (This.Into_Cache
                          and then Item.Cache_Buffer = Null_Handle
                          and then not (Item.Copy_Only
                                        and then Item.Copy_Buffer
                                                 /= Null_Handle))
                 or else Item.Heads_Line = Null_Handle
                 or else This.Turn_Table = System.Null_Address
                 or else (This.Base /= System.Null_Address
                          and then Interfaces.Unsigned_64 (This.Span)
                                   < Interfaces.Unsigned_64 (This.At_Byte)
                                     + Interfaces.Unsigned_64
                                         (This.Head_Size) * 4)
               then
                  return;
               end if;

               Places (Index).Weight :=
                 (if This.Base = System.Null_Address then 0
                  else Interfaces.Unsigned_64 (This.Head_Size) * 4);

               Turn_Room := Interfaces.Unsigned_64'Max
                 (Turn_Room,
                  Interfaces.Unsigned_64 (This.Turns / 2)
                  * Interfaces.Unsigned_64 (Count) * 16);
            elsif This.Routes then
               --  A routing step reads the router's scores in the step it
               --  names and carries a bias or nothing: with a bias it is
               --  kept like a normalization's weight, one row of Columns.
               if This.Rows = 0
                 or else This.Reads not in 1 .. Index - 1
                 or else Item.Route_Line = Null_Handle
                 or else (This.Base /= System.Null_Address
                          and then Interfaces.Unsigned_64 (This.Span)
                                   < Interfaces.Unsigned_64 (This.At_Byte)
                                     + Interfaces.Unsigned_64 (This.Columns)
                                       * 4)
               then
                  return;
               end if;

               Places (Index).Weight :=
                 (if This.Base = System.Null_Address then 0
                  else Interfaces.Unsigned_64 (This.Columns) * 4);
            elsif This.Inverts then
               --  An inverting step reads the routing step it names and
               --  carries no weight.
               if This.Rows = 0
                 or else This.Reads not in 1 .. Index - 1
                 or else Item.Invert_Line = Null_Handle
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Mixes then
               --  A mixing step reads the gathered projection down and
               --  the routing step it names, and a residual where it has
               --  one; it carries no weight.
               if This.Rows = 0
                 or else This.Reads not in 1 .. Index - 1
                 or else This.Reads_Two not in 1 .. Index - 1
                 or else This.Joined > Index - 1
                 or else Item.Mix_Line = Null_Handle
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Picks then
               --  A picking step reads one step and carries no weight.
               if This.Rows = 0
                 or else This.Reads not in 1 .. Index - 1
                 or else Item.Pick_Line = Null_Handle
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Convolves or else This.Rules then
               --  A convolving step carries the taps and a rule step the
               --  three rows of the rule's numbers, each as a norm's
               --  weight is kept; both read the state buffer, which has
               --  to be there and hold the ring.
               declare
                  Held : constant Interfaces.Unsigned_64 :=
                    (if This.Convolves
                     then Interfaces.Unsigned_64 (This.Linear.Taps)
                          * Interfaces.Unsigned_64 (This.Linear.Mix)
                     else Interfaces.Unsigned_64
                            (2 * This.Linear.Value_Heads + This.Linear.Head));
               begin
                  if This.Rows = 0
                    or else This.Base = System.Null_Address
                    or else This.Reads not in 1 .. Index - 1
                    or else Interfaces.Unsigned_64 (This.Span)
                            < Interfaces.Unsigned_64 (This.At_Byte) + Held * 4
                    or else Item.State_At = Null_Handle
                    or else (Interfaces.Unsigned_64 (This.Linear.Table_At)
                             + Interfaces.Unsigned_64 (This.Linear.Runs) * 5)
                            * 4
                            > Item.State_Bytes
                    or else (This.Convolves
                             and then Item.Conv_Line = Null_Handle)
                    or else (This.Rules
                             and then (Item.Rule_Line = Null_Handle
                                       or else This.Linear.Z_Step
                                               not in 1 .. Index - 1
                                       or else This.Linear.Alpha_Step
                                               not in 1 .. Index - 1
                                       or else This.Linear.Beta_Step
                                               not in 1 .. Index - 1))
                  then
                     return;
                  end if;

                  Places (Index).Weight := Held * 4;
               end;
            elsif This.Blends then
               --  Two arms in and one out. A combination takes the two
               --  steps before it; a join names one of them and takes its
               --  residual from a step it names or from the caller's
               --  activation, which is what lets a layer's second join
               --  reach back to its first.
               declare
                  Arm : constant Natural :=
                    (if This.Reads_Two /= 0 then This.Reads_Two
                     else Index - 1);
                  Other : constant Natural :=
                    (if This.Reads_Two /= 0 or else This.Reads /= 0
                     then This.Reads
                     else Index - 2);
               begin
                  --  The seventh unit's second arm is one number a
                  --  position; every other unit's is as wide as the
                  --  first.
                  if This.Rows = 0
                    or else Arm not in 1 .. Index - 1
                    or else Other > Index - 1
                    or else Steps.Items (Arm).Rows
                            /= (if This.Unit = 7 then 1 else This.Rows)
                    or else (Other /= 0
                             and then Steps.Items (Other).Rows /= This.Rows)
                  then
                     return;
                  end if;
               end;

               Places (Index).Weight := 0;
            elsif This.Rows = 0
              or else (not This.Chained
                       and then This.Columns /= Steps.Items (1).Columns)

              --  A chained step reads the rows the step it names made,
              --  or -- a gather laid apart -- one stretch of them a
              --  member, which is what Add_Gathered_Product checked.
              or else (This.Chained
                       and then This.Columns
                                  * (if This.Apart > 0 then This.Gathers
                                     elsif This.Listed and then This.By_Slot
                                     then This.Rows / This.Each
                                     else 1)
                                  /= Steps.Items
                                       ((if This.Reads = 0 then Index - 1
                                         else This.Reads)).Rows)
              or else Wide = 0
              or else Interfaces.Unsigned_64
                        (if This.Gathers > 0 then This.Stack else This.Rows)
                        * Interfaces.Unsigned_64 (This.Columns) > Max_Elements
              or else Interfaces.Unsigned_64 (This.Columns)
                        * Interfaces.Unsigned_64 (Count) > Max_Elements
              or else This.Base = System.Null_Address
              or else Interfaces.Unsigned_64 (This.Span)
                        < Interfaces.Unsigned_64 (This.At_Byte)
                          + Interfaces.Unsigned_64
                              (if This.Gathers > 0 then This.Stack
                               else This.Rows) * Wide
            then
               return;
            else
               --  A gather uploads and keeps the whole stack, whatever
               --  few of its slices this step reads.
               Places (Index).Weight :=
                 Interfaces.Unsigned_64
                   (if This.Gathers > 0 then This.Stack else This.Rows)
                 * Wide;
            end if;
            if This.Folded then
               --  A join folded into the product before it writes nothing
               --  of its own: the product's store is the sum, and this
               --  step's place is that store, so a later step naming this
               --  one reads what the product wrote.
               Places (Index).At_Byte := Places (Index - 1).At_Byte;
               Places (Index).Bytes := Places (Index - 1).Bytes;
            else
               Places (Index).At_Byte := Result_Bytes;
               Places (Index).Bytes := Mine;

               Result_Bytes :=
                 Result_Bytes
                 + (Mine + Alignment - 1) / Alignment * Alignment;
            end if;

            Wanted := Wanted
              + Model_Runner.Numerics.Element_Count (This.Rows)
                * Model_Runner.Numerics.Element_Count (Count);
         end;
      end loop;

      if Vectors'Length
           < Model_Runner.Numerics.Element_Count (Steps.Items (1).Columns)
             * Model_Runner.Numerics.Element_Count (Count)
        or else Target'Length < Wanted
      then
         return;
      end if;

      --  The other of the two of everything a submission holds, and the
      --  wait for whatever that slot last handed over -- which is the
      --  sequence before the one before this, long finished in the usual
      --  case. Nothing else waits: the sequence just before this one is
      --  still running, and the device is meant to be.
      Swap_Slots (Item);

      if Item.Pending then
         Await (Item, Good, Cancelled, Cancel);

         if Cancelled or else not Good then
            Ok := Good;
            return;
         end if;
      end if;

      --  Carried out, the last step writes straight into the room the next
      --  sequence reads its activation from, and there is nothing to copy.
      --  Safe because the only step that reads that room is the first join,
      --  which is published by a barrier long before the last step runs.
      if Carry_Out and then Steps.Held > 0
        and then Places (Steps.Held).Bytes <= Carry_Room
      then
         Places (Steps.Held).At_Byte := 0;

         --  A folded join is the product before it, so moving one moves
         --  both: the store that has to land at the front is the product's.
         if Steps.Items (Steps.Held).Folded then
            Places (Steps.Held - 1).At_Byte := 0;
         end if;
      end if;

      --  The shapes are through: what refuses from here is room.
      Item.Refused := Room_Refused;

      Item.Clock := Item.Clock + 1;
      Item.Began := Item.Clock;

      --  A matrix the sequence still in flight is reading may not be given
      --  back either: the floor is the reading that sequence began at,
      --  less one, so that everything it acquired -- one tick each -- is
      --  above it. It used to be one tick below this clock, which pinned
      --  the last matrix that sequence took and none of the others, and a
      --  model that does not fit gave one of those back and uploaded
      --  another matrix into its buffer while the device was still
      --  reading it.
      Pinned :=
        (if Item.Pending_Two and then Item.Began_Two >= 1
         then Item.Began_Two - 1 else Item.Clock);

      --  Every matrix in place before the first dispatch is written down.
      --  This is the whole point of the arrangement: acquiring a matrix can
      --  upload it, evict another, or take the host's own memory, and none
      --  of that may happen between two dispatches that are already
      --  recorded.
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);

            --  The storage this step's matrix lies in, read where it lies.
            --  Zero length for the steps that name no matrix, which are
            --  left before the overlay is used.
            Held : Model_Runner.Bytes.Byte_Array (1 .. This.Span)
              with Import, Address => This.Base;
         begin
            --  Neither a combining step nor an attention step names a
            --  matrix: one reads the two results before it, the other reads
            --  the cache the device holds.
            if This.Blends or else This.Attends or else This.Places
              or else This.Rotates or else This.Mixes or else This.Inverts
              or else This.Picks
              or else (This.Routes and then This.Base = System.Null_Address)
              or else (This.Readies and then This.Base = System.Null_Address)
            then
               goto Next_Step;
            end if;

            --  A normalizing step's weight is one row of its width, not
            --  the square its Rows and Columns describe -- those say what
            --  it reads and writes, as they do for every step. Handing the
            --  square to the loader is asking it to upload four million
            --  values out of an array of two thousand, which faults in the
            --  driver rather than anywhere this program can see.
            Acquire_Weights
              (Item, Held, This.At_Byte, This.Packing,
               (if This.Norms or else This.Rotates or else This.Routes
                  or else This.Readies or else This.Biases
                  or else This.Convolves or else This.Rules
                then 1
                elsif This.Gathers > 0 then This.Stack
                else This.Rows),
               (if This.Norms then This.Rows / This.Groups
                elsif This.Biases then This.Stack * This.Each
                elsif This.Convolves then This.Linear.Taps * This.Linear.Mix
                elsif This.Rules
                then 2 * This.Linear.Value_Heads + This.Linear.Head
                elsif This.Routes then This.Columns
                elsif This.Readies then This.Head_Size
                elsif This.Rotates
                then This.Turns / 2 * Natural (Count) * 4
                else This.Columns),
               Places (Index).Weight,
               Places (Index).Buffer, Places (Index).Memory,
               Places (Index).Base, Places (Index).Borrowed, Good, This.Key,
               Pinned => Pinned);
            if not Good then
               Release_All;
               return;
            end if;
         end;

         <<Next_Step>>
      end loop;

      --  The two that change every call, grown when they have to.
      if Item.Vector_Bytes < Vector_Bytes then
         Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Vector_Bytes := Vector_Bytes;
      end if;

      if Item.Result_Bytes < Result_Bytes then
         --  A sequence carrying in reads its activation from the front
         --  of this buffer, where the one before left it; a buffer that
         --  grows here is a new buffer, and the front has to come with
         --  it. It did not, and a hybrid's linear layer -- whose
         --  sequence is smaller than the attention layer's after it --
         --  carried its answer into a buffer the next layer threw away
         --  on the first batch of a new length: every answer past a
         --  hundred and twenty-eight positions was noise. The sequence
         --  before may still be writing the front, so it is waited for.
         declare
            Was_Buffer : Address := Item.Result_Buffer;
            Was_Memory : Address := Item.Result_Memory;
            Was_At     : Address := Item.Result_At;
            Was_Bytes  : constant Interfaces.Unsigned_64 := Item.Result_Bytes;
            Carrying   : constant Boolean :=
              Carry_In and then Was_Buffer /= Null_Handle
              and then Was_Bytes >= Vector_Bytes;
         begin
            if Carrying then
               Settle (Item, Good);
               if Good then
                  Standing (Item, Was_Memory, Was_At, Was_Bytes, Good);
               end if;
               if not Good then
                  Release_All;
                  return;
               end if;
            else
               Unmap_Standing (Item, Was_Memory, Was_At);
               Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
            end if;

            Item.Result_Buffer := Null_Handle;
            Item.Result_Memory := Null_Handle;
            Item.Result_At := Null_Handle;

            Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
                  Good, Read => True);
            if not Good then
               if Carrying then
                  Unmap_Standing (Item, Was_Memory, Was_At);
                  Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
               end if;
               Release_All;
               return;
            end if;
            Item.Result_Bytes := Result_Bytes;

            if Carrying then
               Standing (Item, Item.Result_Memory, Item.Result_At,
                         Item.Result_Bytes, Good);
               if Good then
                  declare
                     Was : Model_Runner.Bytes.Byte_Array
                       (1 .. Model_Runner.Bytes.Byte_Count (Vector_Bytes))
                       with Import, Address => Was_At;
                     Now : Model_Runner.Bytes.Byte_Array
                       (1 .. Model_Runner.Bytes.Byte_Count (Vector_Bytes))
                       with Import, Address => Item.Result_At;
                  begin
                     Now := Was;
                  end;
               end if;

               Unmap_Standing (Item, Was_Memory, Was_At);
               Give_Back_Buffer (Item, Was_Buffer, Was_Memory);

               if not Good then
                  Release_All;
                  return;
               end if;
            end if;
         end;
      end if;

      --  Two regions of it, because a gated feed-forward has both its arms
      --  alive at once and the products that make them cannot both write at
      --  the front. Everything else uses the first and the second stands
      --  empty.
      Item.Half_Region := Half_Bytes;

      if Item.Half_Bytes < 3 * Half_Bytes then
         Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
         Take (Item, 3 * Half_Bytes,
               Item.Half_Buffer, Item.Half_Memory, Good);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Half_Bytes := 3 * Half_Bytes;
      end if;

      --  And the angles, where anything turns: written into a standing
      --  mapping as the activation is, because they change every call.
      if Turn_Room > 0 then
         if Item.Turn_Bytes < Turn_Room then
            Unmap_Standing (Item, Item.Turn_Memory, Item.Turn_At);
            Give_Back_Buffer (Item, Item.Turn_Buffer, Item.Turn_Memory);
            Take (Item, Turn_Room, Item.Turn_Buffer, Item.Turn_Memory, Good);
            if not Good then
               Release_All;
               return;
            end if;
            Item.Turn_Bytes := Turn_Room;
         end if;

         Standing (Item, Item.Turn_Memory, Item.Turn_At, Item.Turn_Bytes,
                   Good);
         if not Good then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            if Steps.Items (Index).Rotates or else Steps.Items (Index).Readies
            then
               declare
                  Span : constant Model_Runner.Bytes.Byte_Count :=
                    Model_Runner.Bytes.Byte_Count
                      (Interfaces.Unsigned_64 (Steps.Items (Index).Turns / 2)
                       * Interfaces.Unsigned_64 (Count) * 16);

                  From : Model_Runner.Bytes.Byte_Array (1 .. Span)
                    with Import,
                         Address =>
                           (if Steps.Items (Index).Readies
                            then Steps.Items (Index).Turn_Table
                            else Steps.Items (Index).Base);

                  Into : Model_Runner.Bytes.Byte_Array (1 .. Span)
                    with Import, Address => Item.Turn_At;
               begin
                  Into := From;
               end;
            end if;
         end loop;
      end if;

      --  The activation goes over once, however many products read it --
      --  and not at all where the sequence before this one left it on the
      --  device.
      declare
         Wanted : Model_Runner.Numerics.Real_Array
           renames Vectors (Vectors'First
                            .. Vectors'First + Vector_Room - 1);
      begin
         if Carry_In then
            Good := True;
         else
            --  The host is about to write a buffer a submission may still
            --  be reading.
            Settle (Item, Good);

            if Good then
               Standing (Item, Item.Vector_Memory, Item.Vector_At,
                         Item.Vector_Bytes, Good);
            end if;
         end if;

         if Good and then not Carry_In then
            declare
               Room : Model_Runner.Numerics.Real_Array (Wanted'Range)
                 with Import, Address => Item.Vector_At;
            begin
               Room := Wanted;
            end;
         end if;
      end;
      if not Good then
         Release_All;
         return;
      end if;

      --  One set per product, each pointed at its own matrix and its own
      --  share of the result. A descriptor update is not recorded, so all
      --  of them are made before anything is.
      declare
         Update : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Told  : aliased Buffer_Info_Array;
         Notes : aliased Write_Array;

         --  Where a step reads from: a step it names, the step before it
         --  when it is chained, or the caller's activation -- at an offset
         --  into it, because a residual travels beside the queries rather
         --  than in a buffer of its own.
         function Source_Of (Index : Positive; Named : Natural)
           return Buffer_Info
         is
            This : Step renames Steps.Items (Index);

            From : constant Natural :=
              (if Named /= 0 then Named
               elsif This.Chained then Index - 1
               else 0);

            Skip : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (This.At_Vector) * 4;
         begin
            if From = 0 then
               --  The activation: what the host sent, or what the sequence
               --  before this one left at the front of the result buffer.
               if Carry_In then
                  return (Buffer => Item.Result_Buffer, Offset => Skip,
                          Extent => Vector_Bytes - Skip);
               end if;

               return (Buffer => Item.Vector_Buffer, Offset => Skip,
                       Extent => Vector_Bytes - Skip);
            else
               return (Buffer => Item.Result_Buffer,
                       Offset => Places (From).At_Byte,
                       Extent => Places (From).Bytes);
            end if;
         end Source_Of;
      begin
         if Update = null then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            if Steps.Items (Index).Attends then
               --  The cache the engine holds, the queries where the
               --  activation was written, and this step's own share of the
               --  result: the same three the single call binds, in the same
               --  order, because they are the same kernel.
               Told (1) := Cache_Descriptor (Item);
               --  The queries: where the activation was written, or --
               --  for a chained attention -- what the step before it wrote,
               --  which never left the device.
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);
               Told (7) := Values_Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Places then
               --  What it writes, and the cache it writes into -- which is
               --  bound where every other step binds its own room out.
               Told (1) := Cache_Descriptor (Item);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) := Cache_Descriptor (Item);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Rotates then
               --  The table, what it turns, and its own room out.
               Told (1) :=
                 (Buffer => Item.Turn_Buffer, Offset => 0,
                  Extent => Item.Turn_Bytes);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Readies then
               --  The head weight or nothing, the whole result buffer --
               --  the projections it reads are named by offset in the
               --  push block -- its own room or the cache out, and the
               --  angle table where a product binds its residual.
               Told (3) :=
                 (if Steps.Items (Index).Into_Cache
                  then Cache_Descriptor (Item)
                  else (Buffer => Item.Result_Buffer,
                        Offset => Places (Index).At_Byte,
                        Extent => Places (Index).Bytes));
               Told (1) :=
                 (if Steps.Items (Index).Base = System.Null_Address
                  then Told (3)
                  else (Buffer => Places (Index).Buffer, Offset => 0,
                        Extent =>
                          Places (Index).Base + Places (Index).Weight));
               Told (2) :=
                 (Buffer => Item.Result_Buffer, Offset => 0,
                  Extent => Result_Bytes);
               --  Binding three is the cache read-only where a head step
               --  places into a paged cache -- it reads the page table
               --  there -- and the half batch otherwise. The one buffer
               --  cannot be bound both writeonly and readonly at the same
               --  binding without a driver dropping the writes, so the
               --  readable view is here.
               Told (4) :=
                 (if Steps.Items (Index).Into_Cache
                     and then Steps.Items (Index).Page_Shift /= 0
                  then Cache_Descriptor (Item)
                  else Half_Descriptor (Item));
               Told (5) :=
                 (Buffer => Item.Turn_Buffer, Offset => 0,
                  Extent => Item.Turn_Bytes);

               Told (6) := Copy_Descriptor (Item);
               Told (7) := Values_Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Routes then
               --  The bias where there is one -- and where there is not,
               --  the step's own room, bound and never read -- the scores
               --  it reads, and its own room out.
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (1) :=
                 (if Steps.Items (Index).Base = System.Null_Address
                  then Told (3)
                  else (Buffer => Places (Index).Buffer, Offset => 0,
                        Extent =>
                          Places (Index).Base + Places (Index).Weight));
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Inverts then
               --  The routing step's choice in, its own room out.
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (1) := Told (3);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Convolves or else Steps.Items (Index).Rules
            then
               --  The weight, the rows it reads, its own room out, the
               --  whole of the result buffer for the rule's other rows,
               --  and the state buffer.
               Told (1) :=
                 (Buffer => Places (Index).Buffer, Offset => 0,
                  Extent => Places (Index).Base + Places (Index).Weight);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) :=
                 (Buffer => Item.Result_Buffer, Offset => 0,
                  Extent => Item.Result_Bytes);
               Told (5) :=
                 (Buffer => Item.State_Buffer, Offset => 0,
                  Extent => Item.State_Bytes);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Picks then
               --  The step it takes apart, and its own room out.
               Told (1) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (2) := Told (1);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Mixes then
               --  The routing step's choice, the gathered projection
               --  down, its own room out, and the residual where there
               --  is one.
               Told (1) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Steps.Items (Index).Reads_Two).At_Byte,
                  Extent => Places (Steps.Items (Index).Reads_Two).Bytes);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) :=
                 (if Steps.Items (Index).Joined /= 0
                  then (Buffer => Item.Result_Buffer,
                        Offset =>
                          Places (Steps.Items (Index).Joined).At_Byte,
                        Extent =>
                          Places (Steps.Items (Index).Joined).Bytes)
                  else Told (3));

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Norms then
               --  The weight, what it normalizes, and its own room out.
               Told (1) :=
                 (Buffer => Places (Index).Buffer, Offset => 0,
                  Extent => Places (Index).Base + Places (Index).Weight);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Biases then
               --  The bias stack, the gathered answers it is added to,
               --  its own room out, and the routing that says which
               --  expert each answer is.
               Told (1) :=
                 (Buffer => Places (Index).Buffer, Offset => 0,
                  Extent => Places (Index).Base + Places (Index).Weight);
               Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) :=
                 (if Steps.Items (Index).Reads_Two /= 0
                  then (Buffer => Item.Result_Buffer,
                        Offset =>
                          Places (Steps.Items (Index).Reads_Two).At_Byte,
                        Extent =>
                          Places (Steps.Items (Index).Reads_Two).Bytes)
                  else Told (3));

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Blends then
               --  Two arms in, its own room out. A combination's arms are
               --  the two results before it; a join's are the ones it
               --  names, one of which may be the caller's own activation.
               Told (1) :=
                 (if Steps.Items (Index).Reads_Two = 0
                    and then Steps.Items (Index).Reads = 0
                  then (Buffer => Item.Result_Buffer,
                        Offset => Places (Index - 2).At_Byte,
                        Extent => Places (Index - 2).Bytes)
                  else Source_Of (Index, Steps.Items (Index).Reads));
               Told (2) :=
                 (if Steps.Items (Index).Reads_Two = 0
                  then (Buffer => Item.Result_Buffer,
                        Offset => Places (Index - 1).At_Byte,
                        Extent => Places (Index - 1).Bytes)
                  else (Buffer => Item.Result_Buffer,
                        Offset =>
                          Places (Steps.Items (Index).Reads_Two).At_Byte,
                        Extent =>
                          Places (Steps.Items (Index).Reads_Two).Bytes));
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);
               Told (5) := Told (3);

               Told (6) := Copy_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            Told (1) :=
              (Buffer => Places (Index).Buffer, Offset => 0,
               Extent => Places (Index).Base + Places (Index).Weight);
            --  What this product reads: the activation the caller sent,
            --  or -- for a chained one -- the result the product before it
            --  wrote, which never left the device.
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);

            --  The half-precision copy, or -- for a gather routed on the
            --  device -- the routing step's choice, bound where the row
            --  kernel reads its members from.
            --  A listed product on the matrix kernel reads the runs'
            --  half-precision copy here and its lists at the residual's
            --  binding; on the row kernel it reads the lists here.
            Told (4) :=
              (if Steps.Items (Index).Routed /= 0
                 and then not Listed_Tiled (Index)
               then (Buffer => Item.Result_Buffer,
                     Offset => Places (Steps.Items (Index).Routed).At_Byte,
                     Extent => Places (Steps.Items (Index).Routed).Bytes)
               else Half_Descriptor (Item));

            --  And the residual, where a join was folded into this product:
            --  what the join would have read as its first arm, bound where
            --  the product's store can add it.
            Told (5) :=
              (if Steps.Items (Index).Joins
               then Source_Of
                      (Steps.Items (Index).Joined,
                       Steps.Items (Steps.Items (Index).Joined).Reads)
               --  A listed product's kernels read the lists at the
               --  residual's binding, which a listed product never has.
               elsif Steps.Items (Index).Listed
               then (Buffer => Item.Result_Buffer,
                     Offset => Places (Steps.Items (Index).Routed).At_Byte,
                     Extent => Places (Steps.Items (Index).Routed).Bytes)
               else Told (3));

            --  And bounded to the columns the batch really holds. A tile
            --  stores the columns the rounding invented as well as the real
            --  ones, so it would read a residual for them too -- and what
            --  lies there is whatever the step before last left, since a
            --  join writes only the real ones. Bounded here, those reads
            --  fall outside the range the descriptor names and answer zero,
            --  which is what the invented columns are meant to hold.
            if Steps.Items (Index).Joins then
               Told (5).Extent :=
                 Interfaces.Unsigned_64'Min
                   (Told (5).Extent,
                    Interfaces.Unsigned_64 (Steps.Items (Index).Rows)
                    * Interfaces.Unsigned_64 (Count) * 4);
            end if;

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);

            <<Next_Set>>
         end loop;
      end;

      --  Every product in one command buffer. They read the same activation
      --  and write disjoint parts of the result, so nothing between them
      --  waits for anything and no barrier is needed -- what is saved is a
      --  submission and a fence for each product after the first.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         --  Steps whose results a barrier has already published.
         Fenced : Natural := 0;

         --  The last step that wrote the cache, which an attending step
         --  reads without naming: its queries come from a step it names and
         --  its keys come from the cache, so the rule below cannot see the
         --  dependency and is told about it here.
         Cached : Natural := 0;

         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));

         --  Whether this run stamps its steps, and what with. Looked up
         --  only when it does, for the reason Barrier is.
         Stamping : constant Boolean :=
           Item.Timing and then Item.Queries /= Null_Handle;
         Reset_Queries : Reset_Queries_Call := null;
         Write_Stamp   : Write_Stamp_Call := null;
         --  Looked up only when something chains. Resolving an entry point
         --  is not free, and a sequence of products that share an activation
         --  -- which is every sequence the engine names today -- would
         --  otherwise pay for a barrier it never records.
         Chains : Boolean := False;

         Barrier : Barrier_Call := null;

         Wall : aliased Memory_Barrier;

         Began : aliased Command_Begin_Info;

         --  Which step's answer the half-precision copy of the batch now
         --  holds, and how long that answer's vectors are. Minus one is
         --  none. A layer asks for seven products from four activations,
         --  so three of the seven find the copy already made and skip it.
         Half_From : Integer := -1;
         Half_Wide : Natural := 0;

         --  Which steps write only the half-precision copy. Worked out
         --  below from what reads each of them.
         Halved    : array (1 .. Sequence_Limit) of Boolean :=
           [others => False];

         --  And which region of the half-precision buffer each writes
         --  into. Three, because a gated feed-forward has three answers
         --  alive at once: the normalization both arms read, and the arms.
         Region    : array (1 .. Sequence_Limit) of Natural :=
           [others => 0];
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            Chains := Chains or else Steps.Items (Index).Chained;
         end loop;

         if Chains then
            Barrier := To_Barrier (Point ("vkCmdPipelineBarrier"));
            if Barrier = null then
               Release_All;
               return;
            end if;
         end if;

         if Stamping then
            Reset_Queries :=
              To_Reset_Queries (Point ("vkCmdResetQueryPool"));
            Write_Stamp := To_Write_Stamp (Point ("vkCmdWriteTimestamp"));
            if Reset_Queries = null or else Write_Stamp = null then
               Release_All;
               return;
            end if;
         end if;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Release_All;
            return;
         end if;

         --  Every stamp this run may write is cleared first, and the one
         --  before the first dispatch written; the pool must be reset in
         --  the command buffer before it is written in it.
         if Stamping then
            Reset_Queries
              (Item.Buffer, Item.Queries, 0, C.unsigned (Sequence_Limit + 1));
            Write_Stamp (Item.Buffer, Pipeline_Stage_Bottom, Item.Queries, 0);
         end if;

         Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));

         --  Whether a step's answer is wanted only in half precision --
         --  which is to say every step that reads it is a tiled product,
         --  and no tiled product reads the binary32 form.
         --
         --  A step like that need not write the binary32 at all. It writes
         --  the half-precision copy where the conversion would have put it
         --  and the conversion does not run: two bytes a value instead of
         --  four, and a whole pass over the activation that does not
         --  happen. That is the case the fusing measured earlier did not
         --  cover -- there the normalization wrote both, so the work moved
         --  rather than went.
         declare
            function Only_Halved (Which : Natural) return Boolean is
               Asked : Natural := 0;
               Last  : Natural := Which;
            begin
               if Steps.Items (Which).Kept then
                  return False;
               end if;

               for Later in Which + 1 .. Steps.Held loop
                  declare
                     That : Step renames Steps.Items (Later);

                     Reads_It : constant Boolean :=
                       That.Reads = Which
                       or else That.Reads_Two = Which
                       or else ((That.Chained or else That.Blends
                                 or else That.Attends)
                                and then That.Reads = 0
                                and then Later = Which + 1)

                       --  A combining step that names neither arm reads
                       --  the two before it, so the further one is two
                       --  back and not one.
                       or else (That.Blends
                                and then That.Reads = 0
                                and then That.Reads_Two = 0
                                and then Later = Which + 2);
                  begin
                     if Reads_It then
                        Asked := Asked + 1;
                        Last := Later;

                        if not Tiled (Later) then
                           return False;
                        end if;
                     end if;
                  end;
               end loop;

               --  Nothing reading it is not a licence to write nothing.
               if Asked = 0 then
                  return False;
               end if;

               --  And the copy has to hold this answer until the last of
               --  them has read it: a step written only as halves has no
               --  binary32 form to convert again from. Between this step
               --  and its last reader, nothing else may write the front
               --  of the half-precision buffer -- a normalization, a
               --  combination or an attention that would be halved, or a
               --  tiled product converting some other step's answer into
               --  it. A parallel block reads the normalization on the way
               --  in for its feed-forward after attention has been and
               --  gone, and Falcon on the device answered nonsense over
               --  the tile for as long as this went unasked.
               for Between in Which + 1 .. Last - 1 loop
                  declare
                     That : Step renames Steps.Items (Between);

                     Reads_It : constant Boolean :=
                       That.Reads = Which
                       or else ((That.Chained or else That.Blends
                                 or else That.Attends)
                                and then That.Reads = 0
                                and then Between = Which + 1);
                  begin
                     if That.Norms or else That.Blends or else That.Attends
                       or else (Tiled (Between) and then not Reads_It)
                     then
                        return False;
                     end if;
                  end;
               end loop;

               return True;
            end Only_Halved;
         begin
            for Which in 1 .. Steps.Held loop
               Halved (Which) :=
                 not Steps.Items (Which).Folded
                 and then
                 (Steps.Items (Which).Norms
                  or else Steps.Items (Which).Blends

                  --  Attention only where the tile kernel is the one that
                  --  will run: the scalar one writes the blend the way it
                  --  always has, and the engine picks between them by the
                  --  same test.
                  or else (Steps.Items (Which).Attends
                           and then Steps.Items (Which).Packed.K_Bits = 0
                           and then Attends_By_Matrix
                                      (Item, Count,
                                       Steps.Items (Which).Head_Size,
                                       Steps.Items (Which).Value_Size)))
                 and then Item.Half_Buffer /= Null_Handle
                 and then Item.Half_Bytes
                          >= Interfaces.Unsigned_64 (Steps.Items (Which).Rows)
                             * Interfaces.Unsigned_64 (Whole_Tiles (Count)) * 2
                 and then Only_Halved (Which);
            end loop;

            --  And the two arms of a gated feed-forward. Their only reader
            --  is the step that combines them, and where that step reads
            --  half precision they need write nothing else. Both are alive
            --  at once, so the nearer one goes to the second region.
            for Which in 1 .. Steps.Held loop
               if not Halved (Which)
                 and then not Steps.Items (Which).Kept
                 and then Tiled (Which)
               then
                  declare
                     Only : Integer := -1;
                     Many : Boolean := False;
                  begin
                     for Later in Which + 1 .. Steps.Held loop
                        declare
                           That : Step renames Steps.Items (Later);

                           Reads_It : constant Boolean :=
                             That.Reads = Which
                             or else That.Reads_Two = Which
                             or else ((That.Chained or else That.Blends
                                       or else That.Attends)
                                      and then That.Reads = 0
                                      and then Later = Which + 1)
                             or else (That.Blends
                                      and then That.Reads = 0
                                      and then That.Reads_Two = 0
                                      and then Later = Which + 2);
                        begin
                           if Reads_It then
                              if Only = -1 then
                                 Only := Later;
                              else
                                 Many := True;
                              end if;
                           end if;
                        end;
                     end loop;

                     --  The two elementwise units and the units alone
                     --  read their arms as halves; the join adds an
                     --  activation the host may have sent, and the head
                     --  gate and the shared expert's scaling each read
                     --  an arm no product made.
                     if not Many
                       and then Only > 0
                       and then Steps.Items (Only).Blends
                       and then Steps.Items (Only).Unit in 0 | 1 | 3 | 4 | 5
                       and then Halved (Only)
                     then
                        Halved (Which) := True;

                        --  Neither arm may sit where the normalization
                        --  they both read is still sitting.
                        Region (Which) := (if Which = Only - 1 then 2 else 1);
                     end if;
                  end;
               end if;
            end loop;
         end;

         for Index in 1 .. Steps.Held loop
            declare
               This : Step renames Steps.Items (Index);

               Bound : aliased Address := Item.Sets (Index);
               First : Natural := 0;

               --  Which step this one reads, filled in below beside the
               --  barrier that decides the same thing.
               Reading : Natural := 0;

               --  What the half-precision copy held when this step began.
               --  It is invalidated first and re-established only by a
               --  tiled product, so a step of any other kind -- which may
               --  have written what the copy holds -- leaves it invalid.
               Was_From : constant Integer := Half_From;
               Was_Wide : constant Natural := Half_Wide;
            begin
               --  A folded join is not dispatched at all: the product
               --  before it stored the sum, and this step's place is that
               --  store. Nothing is bound, nothing is pushed, and the
               --  half-precision copy is left as the product left it.
               if This.Folded then
                  goto Next_Dispatch;
               end if;

               --  The copy is not invalidated here. It once was, at every
               --  step, and re-established only by a tiled product -- so a
               --  step of any other kind between two products of the same
               --  normalization, a projection's bias say, had the second
               --  convert the normalization's binary32 answer again, and a
               --  normalization written only as halves has no such answer:
               --  every Qwen2 batch over the tile read zeros for its keys.
               --  The copy holds what it held until something writes its
               --  front, and the steps that do say so below.

               --  A chained product reads what the one before it wrote, so
               --  the device is told to finish writing before it starts
               --  reading. Products of the same activation share nothing and
               --  get no barrier, which is why this is here and not around
               --  the whole loop.
               --  A barrier before a step that reads something not yet
               --  published, and not otherwise.
               --
               --  Every step that reads an earlier result needs one --
               --  a join reading a projection two steps back exactly as a
               --  chained product does -- but one barrier publishes every
               --  step before it, so a second reader of the same result
               --  needs nothing. Fencing every reader instead serialized the two
               --  arms of a gated feed-forward, which used to run together
               --  and are the bulk of a layer.
               declare
                  --  A product with a join folded into it reads the
                  --  residual the join named, which is a step nothing else
                  --  in this step says it reads. A routing step says Joins
                  --  for the bias it adds and names no step, which read
                  --  step nought here and stopped a batch of a mixture
                  --  with a router bias the first time one reached the
                  --  device.
                  Joined : constant Natural :=
                    (if This.Joins and then This.Joined /= 0
                     then Steps.Items (This.Joined).Reads else 0);

                  --  A gather routed on the device reads the routing
                  --  step's choice as well, which no other field of the
                  --  step says.
                  --  A rule step reads the gate, alpha and beta rows as
                  --  well, which its shape names.
                  Ruled : constant Natural :=
                    (if This.Rules
                     then Natural'Max
                            (This.Linear.Z_Step,
                             Natural'Max (This.Linear.Alpha_Step,
                                          This.Linear.Beta_Step))
                     else 0);

                  Source : constant Natural :=
                    Natural'Max
                      (Natural'Max (Joined, Natural'Max (This.Routed, Ruled)),
                       Natural'Max
                         (Natural'Max
                            (This.Reads,
                             (if This.Reads_Two /= 0 then This.Reads_Two
                              elsif This.Blends then Index - 1 else 0)),
                          (if This.Blends and then This.Reads_Two = 0
                           then Index - 1
                           elsif This.Chained and then This.Reads = 0
                           then Index - 1
                           else 0)));
                  --  Whether this step writes the front of the
                  --  half-precision buffer: a tiled product converting
                  --  some answer other than the one the copy holds, or a
                  --  normalization, combination or attention written as
                  --  halves. The step before may still be reading that
                  --  front -- a tiled product reads its operand there --
                  --  and a step whose own sources are long fenced would
                  --  otherwise overwrite it under that read. Falcon's
                  --  projection up reads the normalization on the way in,
                  --  fenced twelve steps back, and converted it over the
                  --  attention the projection out was still reading.
                  Writes_Copy : constant Boolean :=
                    (if This.Norms or else This.Blends or else This.Attends
                     then Halved (Index)
                     elsif This.Rotates or else This.Places
                       or else This.Readies or else This.Routes
                       or else This.Mixes or else This.Biases
                       or else This.Inverts or else This.Picks
                       or else This.Convolves or else This.Rules
                     then False
                     else Tiled (Index)
                          and then (Was_From /= Source
                                    or else Was_Wide /= This.Columns));

                  Wanted : constant Natural :=
                    (if Writes_Copy then Index - 1
                     elsif This.Attends then Natural'Max (Source, Cached)
                     else Source);
               begin
                  Reading := Source;
                  if Wanted > Fenced then
                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);
                     Fenced := Index - 1;
                  end if;

                  if This.Places
                    or else (This.Readies and then This.Into_Cache)
                  then
                     Cached := Index;
                  end if;
               end;

               Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                          Bound'Address, 0, Null_Handle);

               if This.Attends and then This.Packed.K_Bits /= 0 then
                  --  Over a packed block: the one kernel that reads one,
                  --  a workgroup a head of a position, as the single call
                  --  dispatches it -- and no slices, no merge, no
                  --  half-precision copy, which are the exact kernels'.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Packed_Pipeline (Item));

                  declare
                     --  A round's rows share no keys, so a workgroup
                     --  takes one position's heads and no more.
                     Queries : constant Positive :=
                       Packed_Queries (Count);
                     --  The bundle is what makes a packed round bearable:
                     --  a workgroup of eight heads unpacks the key it
                     --  reads once and dots it into eight queries. A
                     --  round dispatched a workgroup a head instead --
                     --  two hundred and fifty-six of them rather than
                     --  thirty-two, which looked like the parallelism the
                     --  exact kernel gets -- read 4.59 ms a layer against
                     --  1.36, because what a packed row costs is the
                     --  unpacking and that is paid once a bundle.
                     Bundle  : constant Positive :=
                       Packed_Bundle (This.Group_Size, Queries,
                                      This.Last - This.First + 1);

                     Shape : aliased Packed_Constants :=
                       (Heads      => C.unsigned (This.Heads),
                        Head_Size  => C.unsigned (This.Head_Size),
                        Value_Size => C.unsigned (This.Value_Size),
                        Group_Size => C.unsigned (This.Group_Size),
                        First      => C.unsigned (This.First),
                        Last       => C.unsigned (This.Last),
                        K_Bytes    => C.unsigned (This.Packed.K_Bytes),
                        V_Bytes    => C.unsigned (This.Packed.V_Bytes),
                        KV_Width   => C.unsigned (This.KV_Width),
                        V_Width    => C.unsigned (This.V_Width),
                        KS_At      => C.unsigned (This.Packed.KS_At),
                        VS_At      => C.unsigned (This.Packed.VS_At),
                        K_Blocks   => C.unsigned (This.Packed.K_Blocks),
                        V_Blocks   => C.unsigned (This.Packed.V_Blocks),
                        K_Bits     => C.unsigned (This.Packed.K_Bits),
                        V_Bits     => C.unsigned (This.Packed.V_Bits),
                        Scale      => C.C_float (This.Scale),
                        Cap        => C.C_float (This.Cap),
                        Max_Bias   => C.C_float (This.Max_Bias),
                        Positions  => C.unsigned (Count),
                        Window     => C.unsigned (This.Window),
                        Causal     => (if This.Causal then 1 else 0),
                        Bundle     => C.unsigned (Bundle),
                        Queries    => C.unsigned (Queries),
                        Table_At   => 0,
                        Sinks_At   => C.unsigned (This.Sinks),

                        --  A cache in pages, from the step's own fields,
                        --  which Add_Attention carries as it does for the
                        --  exact kernels. Zero shift is a cache in blocks.
                        Pages_At       => C.unsigned (This.Pages_At),
                        Page_Shift     => C.unsigned (This.Page_Shift),
                        First_Position => C.unsigned (This.First_Position));

                     Slices : constant Natural :=
                       (if Barrier = null then 1
                        else Packed_Slices
                               (Item,
                                (This.Heads + Bundle - 1) / Bundle
                                * ((Count + Queries - 1) / Queries),
                                This.First, This.Last,
                                Rounding => False));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Packed_Bytes, Shape'Address);
                     Dispatch (Item.Buffer,
                               C.unsigned ((This.Heads + Bundle - 1) / Bundle),
                               C.unsigned ((Count + Queries - 1) / Queries),
                               C.unsigned (Slices));

                     --  The slices put together, as the exact kernel's
                     --  are: the records lie where merge.comp reads them.
                     if Slices > 1 then
                        declare
                           Merged : aliased Merge_Constants :=
                             (Heads      => C.unsigned (This.Heads),
                              Value_Size => C.unsigned (This.Value_Size),
                              Positions  => C.unsigned (Count),
                              Slices     => C.unsigned (Slices));
                        begin
                           Barrier
                             (Item.Buffer, Pipeline_Stage_Compute,
                              Pipeline_Stage_Compute, 0, 1, Wall'Address,
                              0, Null_Handle, 0, Null_Handle);
                           Bind_Pipeline
                             (Item.Buffer, Bind_Point_Compute,
                              Item.Merge_Line);
                           Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                                 Merge_Bytes, Merged'Address);
                           Dispatch
                             (Item.Buffer, C.unsigned (This.Heads),
                              C.unsigned (Count), 1);
                        end;
                     end if;
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Attends then
                  --  The attention kernel, and back again afterwards, as
                  --  the combining step does.
                  --  A round takes the kernel whose block is one query. A
                  --  block of more reads a cached key once and dots it into
                  --  every query of the block, and rows of a round do not
                  --  share a cache.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Attend_Kernel (Item, Count, This.Head_Size,
                                    This.Value_Size, This.Group_Size,
                                    Rounding => False,
                                    K_Base => This.K_Base,
                                    V_Base => This.V_Base,
                                    KV_Width => This.KV_Width,
                                    V_Width => This.V_Width,
                                    Span => (if This.Last >= This.First then This.Last - This.First + 1 else 0)));

                  declare
                     Shape : aliased Attention_Constants :=
                       (Heads      => C.unsigned (This.Heads),
                        Head_Size  => C.unsigned (This.Head_Size),
                        Value_Size => C.unsigned (This.Value_Size),
                        Group_Size => C.unsigned (This.Group_Size),
                        First      => C.unsigned (This.First),
                        Last       => C.unsigned (This.Last),
                        --  A base counted in elements of whichever the
                        --  kernel reads: the half-precision copy where the
                        --  matrix kernel is the one that will run, and the
                        --  cache proper otherwise. A round is never that
                        --  kernel however many rows it has, so it reads the
                        --  cache proper as it always did.
                        --  The copy has a buffer of its own, so a base
                        --  into it is the same number as into the cache:
                        --  what was added here was where the copy began
                        --  inside one buffer, and there is no such place
                        --  now. Kept as an addition of the copy's front,
                        --  which is nought, so that a copy put somewhere
                        --  else again is a change in one place.
                        K_Base     =>
                          C.unsigned
                            (Interfaces.Unsigned_64 (This.K_Base)
                             + (if Reads_Copy
                                     (Item, Count, This.Head_Size,
                                      This.Value_Size, False)
                                then Copy_At (Item)
                                else 0)),
                        --  Where the copy is split the values are a buffer
                        --  of their own, so the base is off its front, which
                        --  is the keys' end taken away.
                        V_Base     =>
                          C.unsigned
                            (Interfaces.Unsigned_64 (This.V_Base)
                             + (if Reads_Copy
                                     (Item, Count, This.Head_Size,
                                      This.Value_Size, False)
                                then Copy_At (Item)
                                else 0)
                             - (if Item.Copy_Split
                                  and then Interfaces.Unsigned_64 (This.V_Base)
                                           >= Item.Copy_Keys_Halves
                                then Item.Copy_Keys_Halves
                                else 0)),
                        KV_Width   => C.unsigned (This.KV_Width),
                        V_Width    => C.unsigned (This.V_Width),
                        Scale      => C.C_float (This.Scale),
                        Cap        => C.C_float (This.Cap),

                        --  Run's Count is how many positions attend: a
                        --  batch of activations is a batch of positions,
                        --  and a workgroup goes to each head of each.
                        Positions  => C.unsigned (Count),
                        Window     => C.unsigned (This.Window),
                        --  The flag in the low bit and, above it, how many
                        --  positions the half-precision copy is to hold --
                        --  zero for none. One word rather than two because
                        --  this block may not grow: widening it by a field
                        --  once corrupted this device's answers, which
                        --  docs/measured-figures.txt records and nobody has
                        --  explained.
                        Causal     =>
                          C.unsigned
                            ((if This.Causal then 1 else 0)
                             + (if Halved (Index)
                                then 2 * Whole_Tiles (Count) else 0)),
                        Max_Bias   => C.C_float (This.Max_Bias),
                        Table_At   => 0,
                        Sinks_At   => C.unsigned (This.Sinks),
                        Pages_At   => C.unsigned (This.Pages_At),
                        Page_Shift => C.unsigned (This.Page_Shift));

                     Slices : constant Natural :=
                       (if Barrier = null then 1
                        else Attend_Slices
                               (Item, Count, This.Head_Size, This.Value_Size,
                                This.First, This.Last,
                                Rounding => False));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Attention_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        Attend_Heads
                          (Item, This.Heads, This.Group_Size, Count,
                           This.Head_Size, This.Value_Size,
                           Rounding => False,
                           K_Base => This.K_Base, V_Base => This.V_Base,
                           KV_Width => This.KV_Width,
                           V_Width => This.V_Width,
                           Span => (if This.Last >= This.First then This.Last - This.First + 1 else 0)),
                        Attend_Groups
                          (Item,
                           (if Halved (Index) then Whole_Tiles (Count)
                            else Count),
                           This.Head_Size, This.Value_Size,
                           Rounding => False),
                        C.unsigned (Slices));

                     --  The slices put together, once every one of them
                     --  has left its record: a workgroup a head of a
                     --  position, reading the same result region it
                     --  writes.
                     if Slices > 1 then
                        declare
                           Merged : aliased Merge_Constants :=
                             (Heads      => C.unsigned (This.Heads),
                              Value_Size => C.unsigned (This.Value_Size),
                              Positions  => C.unsigned (Count),
                              Slices     => C.unsigned (Slices));
                        begin
                           Barrier
                             (Item.Buffer, Pipeline_Stage_Compute,
                              Pipeline_Stage_Compute, 0, 1, Wall'Address,
                              0, Null_Handle, 0, Null_Handle);
                           Bind_Pipeline
                             (Item.Buffer, Bind_Point_Compute,
                              Item.Merge_Line);
                           Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                                 Merge_Bytes, Merged'Address);
                           Dispatch
                             (Item.Buffer, C.unsigned (This.Heads),
                              C.unsigned (Count), 1);
                        end;
                     end if;
                  end;

                  if Halved (Index) then
                     Half_From := Index;
                     Half_Wide := This.Rows;
                  end if;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Places and then This.Unpacks then
                  --  A packed layer unpacked into the copy, for the matrix
                  --  kernel: a workgroup a row, Cells of them, and not
                  --  Count -- the rows are the cache's, not the batch's.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Unpack_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Pack.Row_Bytes),
                        Count   => C.unsigned (This.Cells),
                        First   => C.unsigned (This.Pack.At_Byte),
                        Packing => C.unsigned (This.Pack.Bits),
                        Base    => C.unsigned (This.Pack.At_Scale),
                        Joins   => C.unsigned (This.Pack.Blocks),
                        Table   => C.unsigned (This.Half_At),

                        --  A cache in pages, in the three words after: the
                        --  layer's page table, the shift and the first
                        --  row's position, which unpack.comp reads to
                        --  gather a session's scattered pages into the
                        --  copy. A gather's members, in every other step.
                        Members =>
                          [0 => C.unsigned (This.Pages_At),
                           1 => C.unsigned (This.Page_Shift),
                           2 => C.unsigned (This.First_Position),
                           others => 0],
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (This.Cells), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Places and then This.Pack.Bits /= 0 then
                  --  Packed as it is placed: the row's bytes and scales
                  --  where the packed attention reads them, through the
                  --  kernel that rounds as the host rounds.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Pack_Pipeline (Item));

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Pack.Row_Bytes),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Pack.At_Byte),
                        Packing => C.unsigned (This.Pack.Bits),
                        Base    => C.unsigned (This.Pack.At_Scale),
                        Joins   => C.unsigned (This.Pack.Blocks),
                        Table   => 0,

                        --  A cache in pages, in the three words after the
                        --  table: the batch's page table, the shift and
                        --  the first row's position, which pack.comp reads
                        --  as place.comp does. A gather's members, in every
                        --  other step's reading of this block.
                        Members =>
                          [0 => C.unsigned (This.Pages_At),
                           1 => C.unsigned (This.Page_Shift),
                           2 => C.unsigned (This.First_Position),
                           others => 0],
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Places then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Place_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Stride),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.At_First),
                        --  One where there is a copy of the cache to
                        --  write and nought where there is not, which is
                        --  a device that would never read one. Two where
                        --  only the copy is kept: write it and skip the
                        --  cache proper, whose binding is a stand-in.
                        Packing =>
                          (if Item.Copy_Buffer /= Null_Handle
                           then (if Item.Copy_Only then 2 else 1)
                           else 0),

                        --  Where the half-precision copy of the cache
                        --  begins, in halves of its own buffer, which is
                        --  the one thing this kernel needs that the others
                        --  put nothing in.
                        Base    =>
                          C.unsigned (Copy_At (Item)),
                        Joins   => 0,

                        --  A round's per-row table, which this is the one
                        --  kind of step that reads: every row of a round
                        --  goes into its own member's block at its own
                        --  position, and neither follows from the first
                        --  row's place.
                        Table   => 0,

                        --  And a cache in pages, in the three words after
                        --  it, which the kernel reads as the batch's page
                        --  table, the page's shift and the first row's
                        --  position: a gather's members, in every other
                        --  step's reading of this block.
                        Members =>
                          [0 => C.unsigned (This.Pages_At),
                           1 => C.unsigned (This.Page_Shift),
                           2 => C.unsigned (This.First_Position),
                           others => 0],
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Rotates then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Turn_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Heads),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Turns),
                        Packing => (if This.Pairs = Split then 1 else 0),

                        --  The table begins where the buffer does: it is
                        --  written for this call and nothing else is in it.
                        Base    => 0,
                        Joins   => 0, Table => 0, others => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);

                     --  A workgroup to a position, as the normalization
                     --  does: the pairs of one position are what its lanes
                     --  divide between them.
                     Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Readies then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Heads_Line);

                  declare
                     function Bits is new Ada.Unchecked_Conversion
                       (Model_Runner.Numerics.Real, C.unsigned);

                     Shape : aliased Heads_Constants :=
                       (Heads     => C.unsigned (This.Heads),
                        Head_Size => C.unsigned (This.Head_Size),
                        Rotary    => C.unsigned (This.Turns),
                        Pairing   => (if This.Pairs = Split then 1 else 0),
                        Count     => C.unsigned (Count),
                        Normed    =>
                          (if This.Base /= System.Null_Address then 1
                           else 0),
                        Epsilon   => Bits (This.Epsilon),
                        Base      => C.unsigned (Places (Index).Base / 4),
                        From      =>
                          C.unsigned
                            (Natural (Places (This.Reads).At_Byte / 4)
                             + This.Reads_At),
                        Into      =>
                          (if This.Into_Cache then C.unsigned (This.At_First)
                           else 0),
                        Stride    =>
                          (if This.Into_Cache then C.unsigned (This.Stride)
                           else C.unsigned (This.Rows)),
                        Turn_Base => 0,
                        --  The copy's front, which is nought: it has a
                        --  buffer of its own and this kernel writes into
                        --  it from there.
                        Half_Base =>
                          (if This.Into_Cache
                           then C.unsigned (Copy_At (Item))
                           else 0),
                        --  Into the cache, and a copy of it to write:
                        --  a device that would never read one has none,
                        --  and what is at that binding instead is not
                        --  this kernel's to write. Two where only the copy
                        --  is kept: write the copy and skip the cache
                        --  proper, whose binding is a stand-in the kernel
                        --  must not write past.
                        Halves    =>
                          (if This.Into_Cache
                             and then Item.Copy_Buffer /= Null_Handle
                           then (if Item.Copy_Only then 2 else 1)
                           else 0),
                        V_From    =>
                          (if This.Reads_Two /= 0
                           then C.unsigned
                                  (Natural
                                     (Places (This.Reads_Two).At_Byte / 4)
                                   + This.V_Reads_At)
                           else 0),
                        V_Width   => C.unsigned (This.V_Rows),
                        --  Where the copy is split the values are their own
                        --  buffer, so a value's place is off its front, the
                        --  keys' end taken away.
                        V_Into    =>
                          C.unsigned
                            (Interfaces.Unsigned_64 (This.V_At_First)
                             - (if Item.Copy_Split
                                  and then Interfaces.Unsigned_64
                                             (This.V_At_First)
                                           >= Item.Copy_Keys_Halves
                                then Item.Copy_Keys_Halves
                                else 0)),
                        V_Stride  => C.unsigned (This.V_Stride),
                        Pages_At       => C.unsigned (This.Pages_At),
                        Page_Shift     => C.unsigned (This.Page_Shift),
                        First_Position => C.unsigned (This.First_Position),
                        Src_Stride     => C.unsigned (This.Reads_Stride),
                        V_Src_Stride   => C.unsigned (This.V_Reads_Stride));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Heads_Bytes, Shape'Address);

                     --  A workgroup to a head of a position, and one more
                     --  a position for the values placed with the keys.
                     Dispatch
                       (Item.Buffer,
                        C.unsigned (Count * This.Heads
                                    + (if This.V_Rows > 0 then Count
                                       else 0)),
                        1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Inverts then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Invert_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Columns),
                        Columns => C.unsigned (This.Used),
                        Count   => C.unsigned (Count),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);

                     --  One workgroup for the whole batch.
                     Dispatch (Item.Buffer, 1, 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Routes then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Route_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Columns),
                        Columns => C.unsigned (This.Used),
                        Count   => C.unsigned (Count),
                        Base    => C.unsigned (Places (Index).Base / 4),
                        Joins   =>
                          (if This.Base /= System.Null_Address then 1
                           else 0),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);

                     --  An invocation a position, each choosing alone.
                     Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Mixes then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Mix_Line);

                  declare
                     Whole : constant Natural := This.Rows * Count;

                     --  A mix over listed answers is told so through
                     --  Base, and the expert count through First, which
                     --  says where the inversion's runs lie.
                     Listed : constant Boolean :=
                       Steps.Items (This.Reads_Two).Inverts;

                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Used),
                        Count   => C.unsigned (Count),
                        First   =>
                          (if Listed
                           then C.unsigned
                                  (Steps.Items (This.Reads_Two).Columns)
                           else 0),
                        Base    => (if Listed then 1 else 0),
                        Joins   => (if This.Joined /= 0 then 1 else 0),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer, C.unsigned ((Whole + 255) / 256), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Convolves then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Conv_Line);

                  declare
                     function Bits is new Ada.Unchecked_Conversion
                       (Model_Runner.Numerics.Real, C.unsigned);

                     --  The convolution, then the memories, with a
                     --  barrier between: a position's memory may land in
                     --  the slot another position is still reading.
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Linear.Mix),
                        Columns => C.unsigned (This.Linear.Head),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Linear.Table_At),
                        Packing => C.unsigned (This.Linear.Taps),
                        Base    => C.unsigned (Places (Index).Base / 4),
                        Joins   => 0,
                        Table   => C.unsigned (This.Linear.Unit_Blocks),
                        Members =>
                          [0 => C.unsigned (This.Linear.Region_At),
                           1 => C.unsigned (This.Linear.Every),
                           2 => C.unsigned (This.Linear.Runs),
                           3 => Bits (This.Linear.Epsilon),
                           others => 0],
                        others  => <>);

                     Blocks : constant Natural :=
                       This.Linear.Mix / This.Linear.Head;
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Blocks),
                               C.unsigned (Count), 1);

                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);

                     Shape.Joins := 1;
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Blocks),
                               C.unsigned (Count), 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Rules then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Rule_Line);

                  declare
                     function Bits is new Ada.Unchecked_Conversion
                       (Model_Runner.Numerics.Real, C.unsigned);

                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Linear.Mix),
                        Columns => C.unsigned (This.Linear.Head),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Linear.Table_At),
                        Packing => C.unsigned (This.Linear.Key_Heads),
                        Base    => C.unsigned (This.Linear.Key_Width),
                        Joins   => C.unsigned (Places (Index).Base / 4),
                        Table   => C.unsigned (This.Linear.Value_Heads),
                        Members =>
                          [0 => C.unsigned (This.Linear.Region_At),
                           1 => C.unsigned (This.Linear.Every),
                           2 => C.unsigned (This.Linear.Runs),
                           3 => C.unsigned
                                  (Places (This.Linear.Z_Step).At_Byte / 4),
                           4 => C.unsigned
                                  (Places (This.Linear.Alpha_Step).At_Byte
                                   / 4),
                           5 => C.unsigned
                                  (Places (This.Linear.Beta_Step).At_Byte / 4),
                           6 => Bits (This.Linear.Scale),
                           7 => Bits (This.Linear.Epsilon),
                           others => 0],
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer, C.unsigned (This.Linear.Value_Heads),
                        C.unsigned (This.Linear.Runs), 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Picks then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Pick_Line);

                  declare
                     --  A workgroup a position: the row it writes, the
                     --  stretch, which of each group, and how many a
                     --  group holds.
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Each),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Which),
                        Packing => C.unsigned (This.Among),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Biases then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Bias_Line);

                  declare
                     --  A workgroup a member: a position's rank, or a
                     --  slot of the inversion's runs, which is every
                     --  answer the source made.
                     Members : constant Natural :=
                       This.Rows * Count / This.Each;

                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Each),
                        Columns => C.unsigned (This.Used),
                        Count   => C.unsigned (Count),
                        First   =>
                          (if This.Reads_Two /= 0
                             and then Steps.Items (This.Reads_Two).Inverts
                           then C.unsigned
                                  (Steps.Items (This.Reads_Two).Columns)
                           else 0),

                        --  Listed, where the host chose the members and
                        --  no routing step did.
                        Packing =>
                          (if This.Reads_Two = 0 and then This.Used > 0
                           then 1 else 0),

                        --  Where the stack begins in the buffer it shares
                        --  with whatever else the device kept, in
                        --  elements, as a norm's weight is found.
                        Base    => C.unsigned (Places (Index).Base / 4),

                        --  A slice of a fused source: how far apart two
                        --  positions lie in it, and where this reader's rows
                        --  begin. Zero stride is a bias over the whole
                        --  source, a position every Each.
                        Joins   => C.unsigned (This.Reads_Stride),
                        Table   => C.unsigned (This.Reads_At),
                        Members =>
                          [for Which in Member_Words'Range =>
                             C.unsigned (This.Members (Which + 1))],
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (Members), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Norms then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Norm_Line);

                  declare
                     function Bits is new Ada.Unchecked_Conversion
                       (Model_Runner.Numerics.Real, C.unsigned);

                     --  A stretch to a workgroup: a position, or each of
                     --  the Groups a position is normalized as, which lie
                     --  one after another exactly as positions do.
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows / This.Groups),
                        --  One for the centred normalization with a
                        --  shift, in the slot the products' shape holds
                        --  their columns in.
                        Columns => (if This.Shifts then 1 else 0),
                        Count   => C.unsigned (Count * This.Groups),
                        First   => Bits (This.Epsilon),

                        --  Positions the half-precision copy is to hold,
                        --  and zero where there is none to write.
                        Packing =>
                          (if Halved (Index)
                           then C.unsigned
                                  (Whole_Tiles (Count) * This.Groups)
                           else 0),

                        --  Where the weight begins in the buffer it shares
                        --  with whatever else the device kept, in elements
                        --  rather than bytes because this one reads floats.
                        Base    =>
                          C.unsigned (Places (Index).Base / 4),
                          Joins   => 0, Table => 0, others => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);

                     --  A workgroup to a position: its lanes fetch the
                     --  row together and one of them adds it up in order.
                     --  See the shader. Over the rounded-up count where
                     --  the copy is being written, because the positions
                     --  past the batch write the zeros it needs.
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((if Halved (Index)
                                     then Whole_Tiles (Count) else Count)
                                    * This.Groups),
                        1, 1);
                  end;

                  if Halved (Index) then
                     Half_From := Index;
                     Half_Wide := This.Rows;
                  end if;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if This.Blends then
                  --  The other kernel, and back again afterwards. Bound per
                  --  step rather than once, because a sequence may go back
                  --  and forth between the two.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Blend_Line);

                  declare
                     --  Every value both arms hold, not one position's
                     --  worth: the combining is elementwise and the arms of
                     --  a batch are as long as the batch is.
                     Span : constant Natural := This.Rows * Count;
                     Room : constant Natural :=
                       This.Rows * Whole_Tiles (Count);

                     Over : constant Natural :=
                       (if Halved (Index) then Room else Span);

                     --  Where the two arms are. A gated pair whose
                     --  products were told to write half precision is read
                     --  out of the half-precision buffer instead of through
                     --  bindings nought and one, and half the bytes cross.
                     Gate_Step : constant Natural :=
                       (if This.Reads /= 0 then This.Reads
                        elsif Index > 2 then Index - 2 else 0);
                     Up_Step   : constant Natural :=
                       (if This.Reads_Two /= 0 then This.Reads_Two
                        elsif Index > 1 then Index - 1 else 0);

                     Arms : constant Boolean :=
                       This.Unit /= 2
                       and then Gate_Step in 1 .. Steps.Held
                       and then Up_Step in 1 .. Steps.Held
                       and then Halved (Gate_Step)
                       and then Halved (Up_Step);

                     function Sits (Which : Natural)
                       return Interfaces.Unsigned_64
                     is (Interfaces.Unsigned_64 (Region (Which))
                         * (Item.Half_Region / 2) + 1);

                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (Span),
                        Columns => C.unsigned (This.Unit),
                        Count   =>
                          (if Halved (Index) then C.unsigned (Room) else 0),
                        First   =>
                          (if Arms then C.unsigned (Sits (Gate_Step))
                           else 0),
                        Packing =>
                          (if Arms then C.unsigned (Sits (Up_Step))
                           else 0),

                        --  How wide a position is, for the unit that
                        --  reads one number a position.
                        Base    => C.unsigned (This.Rows),

                        --  The clamped gate's slope and limit, by their
                        --  bits, in the two words after the base.
                        Joins   => Float_Bits (C.C_float (This.Alpha)),
                        Table   => Float_Bits (C.C_float (This.Limit)),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((Over + Group_Size - 1)
                                    / Group_Size), 1, 1);
                  end;

                  if Halved (Index) then
                     Half_From := Index;
                     Half_Wide := This.Rows;
                  end if;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if Tiled (Index) then
                  declare
                     Done : Boolean;

                     --  The copy still describes this activation if the
                     --  product before this one converted the same answer
                     --  at the same width, and nothing has run in between.
                     Again : constant Boolean :=
                       Was_From = Reading
                       and then Was_Wide = This.Columns;
                  begin
                     Tile_Product
                       (Item, This.Rows, This.Columns, Count,
                        Whole_Tiles (Count), This.Packing,
                        Places (Index).Base + Slice_Base (Index),
                        Fresh => not Again,
                        Into =>
                          (if Halved (Index)
                           then Interfaces.Unsigned_64 (Region (Index))
                                * (Item.Half_Region / 2) + 1
                           else 0),
                        Joins => This.Joins,
                        Good => Done);

                     if not Done then
                        Release_All;
                        return;
                     end if;

                     Half_From := Reading;
                     Half_Wide := This.Columns;
                  end;

                  goto Next_Dispatch;
               end if;

               --  A few binary32 rows against a few vectors go to the
               --  thin kernel, a workgroup a row: the row kernel gave a
               --  mixture's router four workgroups.
               if This.Gathers = 0
                 and then Thin (Item, This.Packing, This.Rows, This.Columns,
                                Count, Places (Index).Base)
               then
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Thin_Line);

                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base),
                        Joins   => (if This.Joins then 1 else 0),
                        others  => <>);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned (This.Rows),
                               C.unsigned (Count), 1);
                  end;

                  goto Next_Dispatch;
               end if;

               --  Bound here rather than left to whatever the step
               --  before it bound: the row kernel is chosen by the format
               --  as well as by the batch, and only a product knows its
               --  format.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count, This.Packing));

               --  A listed product on the matrix kernel: the runs'
               --  vectors laid out by slot in half precision first, then
               --  every expert's tiles down the third axis.
               if Listed_Tiled (Index) and then Barrier /= null then
                  declare
                     Slots  : constant Natural := Listed_Slots (Index);
                     Halved_Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Columns),
                        Columns => C.unsigned (Slots),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing => 0,
                        Base    => C.unsigned (This.Gathers),
                        Joins   => 0,
                        Table   => 0,
                        Members => [others => 0],
                        Stride  => 0,
                        Apart   => 0,
                        Routed  => (if This.By_Slot then 3 else 2));
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Each),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base),
                        Joins   => 0,
                        Table   => 0,
                        Members => [0 => C.unsigned (This.Gathers),
                                    others => 0],
                        Stride  => C.unsigned (Slice_Bytes (Index)),
                        Apart   => 0,
                        Routed  => (if This.By_Slot then 3 else 2));
                  begin
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Item.Halve_Line);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Halved_Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Slots * This.Columns / 2 + Group_Size - 1)
                           / Group_Size), 1, 1);

                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);

                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        Listed_Pipeline (Item, This.Packing));
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned (This.Each / Listed_Rows),
                        C.unsigned
                          ((Count + 15 + Listed_Vectors - 1)
                           / Listed_Vectors),
                        C.unsigned (This.Gathers));

                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        Row_Line (Item, Count, This.Packing));
                  end;

                  goto Next_Dispatch;
               end if;

               --  A listed product is one dispatch, every expert down
               --  the third axis and each walking its own run; the rows
               --  the shader is told are one expert's.
               if This.Listed then
                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Each),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base),
                        Joins   => 0,
                        Table   => 0,
                        Members => [0 => C.unsigned (This.Gathers),
                                    others => 0],
                        Stride  => C.unsigned (Slice_Bytes (Index)),
                        Apart   => 0,
                        Routed  => (if This.By_Slot then 3 else 2));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Row_Reach (Item, This.Packing, Count,
                                       Natural (Shape.Rows))
                              * Row_Lane_Count (Item, This.Packing, Count)
                            + Row_Width (Item, This.Packing, Count) - 1)
                           / Row_Width (Item, This.Packing, Count)),
                        1,
                        C.unsigned (This.Gathers));
                  end;

                  goto Next_Dispatch;
               end if;

               while First < Count loop
                  declare
                     --  A gather's members ride in the push block and its
                     --  count is the third dispatch dimension; the rows
                     --  the shader is told are one slice's. A gather of
                     --  one is pushed as the plain product on that slice,
                     --  which is the same words the tile kernel is given.
                     Sliced : constant Boolean := This.Gathers = 1;
                     Spread : constant Boolean := This.Gathers > 1;

                     Shape : aliased Shape_Constants :=
                       (Rows    =>
                          C.unsigned
                            (if This.Gathers > 0 then This.Each
                             else This.Rows),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (First),
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    =>
                          C.unsigned
                            (Places (Index).Base
                             + (if Sliced then Slice_Base (Index) else 0)),
                        Joins   => (if This.Joins then 1 else 0),
                        Table   => 0,
                        Members => [others => 0],
                        Stride  =>
                          (if Spread then C.unsigned (Slice_Bytes (Index))
                           else 0),
                        Apart   =>
                          (if Spread then C.unsigned (This.Apart) else 0),
                        Routed  => (if This.Routed /= 0 then 1 else 0));
                  begin
                     if Spread then
                        for Member in 1 .. This.Gathers loop
                           Shape.Members (Member - 1) :=
                             C.unsigned (This.Members (Member));
                        end loop;
                     end if;

                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Row_Reach (Item, This.Packing, Count,
                                       Natural (Shape.Rows))
                              * Row_Lane_Count (Item, This.Packing, Count)
                            + Row_Width (Item, This.Packing, Count) - 1)
                           / Row_Width (Item, This.Packing, Count)),
                        1,
                        C.unsigned (if Spread then This.Gathers else 1));
                  end;

                  First := First + Row_Group (Item, Count);
               end loop;

               <<Next_Dispatch>>
               --  After this step's last dispatch, folded or not: a folded
               --  join dispatched nothing and its interval says so.
               if Stamping then
                  Write_Stamp
                    (Item.Buffer, Pipeline_Stage_Bottom, Item.Queries,
                     C.unsigned (Index));
               end if;
            end;
         end loop;

         if Stop (Item.Buffer) /= 0 then
            Release_All;
            return;
         end if;
      end;

      --  Once, for all of them -- and handed over rather than waited for.
      --  A sequence that keeps nothing and leaves its answer on the device
      --  is one the host has no reason to wait for, and not waiting is the
      --  whole of this: the device starts the next one the moment it
      --  finishes this, instead of standing idle while the host wakes up,
      --  records and submits.
      declare
         Reads_Back : Boolean := not Carry_Out;
      begin
         for Index in 1 .. Steps.Held loop
            --  A borrowed matrix is given back at the end of this call, and
            --  it may not be given back while the device is still reading
            --  it -- so a sequence that borrowed anything waits.
            Reads_Back :=
              Reads_Back or else Steps.Items (Index).Kept
              or else Places (Index).Borrowed;
         end loop;

         --  A timed sequence is waited for, so that its stamps can be read
         --  now rather than kept until this slot comes round again.
         Reads_Back := Reads_Back or else Item.Timing;

         Hand_Over (Item, Good);

         if Good and then Reads_Back then
            Await (Item, Good, Cancelled, Cancel);
         end if;
      end;

      if not Good then
         Release_All;
         return;
      end if;

      --  What the stamps latched, scaled to microseconds. Read after the
      --  fence, so the wait flag is a formality; a device that answers the
      --  read with anything but success leaves the line empty rather than
      --  publishing ticks it did not write.
      if Item.Timing and then Item.Queries /= Null_Handle then
         declare
            Results : constant Query_Results_Call :=
              To_Query_Results (Point ("vkGetQueryPoolResults"));

            type Stamp_Array is
              array (0 .. Sequence_Limit) of aliased Interfaces.Unsigned_64
              with Convention => C;

            Stamps : aliased Stamp_Array := [others => 0];
         begin
            Item.Line := (others => <>);

            if Results /= null
              and then Results
                (Item.Logical, Item.Queries, 0, C.unsigned (Steps.Held + 1),
                 Interfaces.Unsigned_64 ((Steps.Held + 1) * 8),
                 Stamps'Address, 8,
                 C.unsigned (Query_Result_64 + Query_Result_Wait)) = 0
            then
               Item.Line.Held := Steps.Held;
               for Index in 1 .. Steps.Held loop
                  Item.Line.Steps (Index) :=
                    (if Stamps (Index) >= Stamps (Index - 1)
                     then Float (Stamps (Index) - Stamps (Index - 1))
                          * Item.Tick / 1000.0
                     else 0.0);
               end loop;
               Item.Line.Whole :=
                 (if Stamps (Steps.Held) >= Stamps (0)
                  then Float (Stamps (Steps.Held) - Stamps (0))
                       * Item.Tick / 1000.0
                  else 0.0);
            end if;
         end;
      end if;

      --  And what came out, product by product, out of the one mapping.
      declare
         Good_Map : Boolean;
         Filled   : Model_Runner.Numerics.Element_Count := Target'First;
      begin
         Standing (Item, Item.Result_Memory, Item.Result_At,
                   Item.Result_Bytes, Good_Map);
         if not Good_Map then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            declare
               Mine : constant Model_Runner.Numerics.Element_Count :=
                 Model_Runner.Numerics.Element_Count (Steps.Items (Index).Rows)
                 * Model_Runner.Numerics.Element_Count (Count);

               Slice : Model_Runner.Numerics.Real_Array
                 (Filled .. Filled + Mine - 1)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer
                             (Item.Result_At)
                           + System.Storage_Elements.Integer_Address
                               (Places (Index).At_Byte));
            begin
               --  A step whose answer nothing on the host reads is not
               --  copied out. The room it would have taken is still stepped
               --  over, so what a caller indexes does not depend on what it
               --  kept -- and for a gated feed-forward that is three
               --  answers of the four left where they were written.
               if Steps.Items (Index).Kept then
                  Target (Slice'Range) := Slice;
               end if;

               Filled := Filled + Mine;
            end;
         end loop;

      end;

      Release_All;
      Item.Refused := Not_Refused;
      Ok := True;
   end Run;

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

end Model_Runner.Platform.Device.Products;
