with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

with Model_Runner.Shaders;

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

   Usage_Storage_Buffer : constant := 16#20#;
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
   Access_Shader_Read       : constant := 16#20#;
   Access_Shader_Write      : constant := 16#40#;
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

   --  Invocations that share one row, which the shader states as well.
   --
   --  A row is divided across this many lanes so that their reads of the
   --  weights are consecutive bytes rather than one byte each from addresses
   --  a row apart. The dispatch below therefore asks for this many
   --  invocations per row rather than one.
   Row_Lanes : constant := 8;

   --  Rows of the answer one workgroup of the matrix product computes, and
   --  vectors of it. The shader states both and this has to agree: the
   --  first says how many workgroups a matrix needs, the second says how
   --  far the batch is rounded up before it is handed over.
   Tile_Rows    : constant := 32;
   Tile_Vectors : constant := 128;

   --  The batch, rounded up to a whole tile. The shader has no test for a
   --  tile that is not full, on purpose and at a fifth of its speed if it
   --  had; what the rounding invents is zeroed by the copying kernel and
   --  written to room the result buffer is given for it.
   function Whole_Tiles (Count : Natural) return Natural
   is ((Count + Tile_Vectors - 1) / Tile_Vectors * Tile_Vectors);

   --  Below this the row product is the better shape and the matrix one is
   --  a tile mostly full of the zeros the rounding invented. A generated
   --  token is one vector and is the case this is really keeping out.
   Tile_Least : constant := 32;

   ---------------------------------------------------------------------------
   --  Structures
   ---------------------------------------------------------------------------

   type Buffer_Create_Info is record
      Kind         : C.unsigned := Structure_Buffer_Create;
      Next         : Address := Null_Handle;
      Flags        : C.unsigned := 0;
      Size         : Interfaces.Unsigned_64 := 0;
      Usage        : C.unsigned := Usage_Storage_Buffer;
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

   --  Four storage buffers: the weights, the vectors, the results, and the
   --  half-precision copy of the vectors the matrix product reads. Three
   --  of the four kernels use three of them and never name the fourth; a
   --  descriptor that is written and not read costs nothing, and a second
   --  layout for the sake of one binding would cost a second pool, a second
   --  set of sets and a second of everything that names one.
   type Binding_Array is array (1 .. 4) of Set_Layout_Binding;

   type Set_Layout_Create_Info is record
      Kind     : C.unsigned := Structure_Set_Layout;
      Next     : Address := Null_Handle;
      Flags    : C.unsigned := 0;
      Count    : C.unsigned := 4;
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

   type Buffer_Info_Array is array (1 .. 4) of aliased Buffer_Info;

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
   --  decodes are the ones a published model is usually made of; the eight
   --  the second decodes are the rest. The split is the shader's, not a
   --  judgement about the formats: see the note on Extra.
   function On_Extra (Packing : Weight_Packing) return Boolean
   is (Packing in Packed_Q4_0 | Packed_Q4_1 | Packed_Q5_0 | Packed_Q5_1
                  | Packed_IQ4_NL | Packed_Q2_K | Packed_Q3_K
                  | Packed_IQ4_XS);

   --  Which of the two row kernels a batch of this length wants. The narrow
   --  one exists only for a batch of one -- a generated token -- and is null
   --  on a device that refused it, which is what makes this a choice rather
   --  than an assumption.
   --  Which of the two attention kernels this device got. The subgroup one
   --  where it offered the operations, the shared-memory one everywhere
   --  else.
   function Attend_Kernel (Item : Engine) return Address
   is (if Item.Group_Line /= Null_Handle
       then Item.Group_Line
       else Item.Attend_Line);

   function Row_Line (Item : Engine; Count : Natural) return Address
   is (if Count = 1 and then Item.Single_Line /= Null_Handle
       then Item.Single_Line
       else Item.Pipeline);

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
       and then (not On_Extra (Packing)
                 or else Item.Extra_Line /= Null_Handle)
       and then ((Packing in Values_F16 | Values_BF16
                  and then Columns mod 32 = 0)
                 or else (Packing in Packed_Q4_0 | Packed_Q4_1 | Packed_Q5_0
                                     | Packed_Q5_1 | Packed_Q8_0
                                     | Packed_IQ4_NL
                          and then Columns mod 32 = 0)
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

   type Write_Array is array (1 .. 4) of aliased Write_Descriptor;

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
   Attention_Bytes : constant := 64;
   Shape_Bytes     : constant := Attention_Bytes;
   Product_Bytes   : constant := 24;

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
   end record
     with Convention => C;

   type Shape_Constants is record
      Rows    : C.unsigned := 0;
      Columns : C.unsigned := 0;
      Count   : C.unsigned := 1;
      First   : C.unsigned := 0;
      Packing : C.unsigned := 0;
      Base    : C.unsigned := 0;
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
   function To_Barrier is
     new Ada.Unchecked_Conversion (Address, Barrier_Call);
   function To_Submit is new Ada.Unchecked_Conversion (Address, Submit_Call);
   function To_Wait is new Ada.Unchecked_Conversion (Address, Wait_Call);
   function To_Reset_Fences is
     new Ada.Unchecked_Conversion (Address, Reset_Fences_Call);

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
      Read   : Boolean := False)
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
         Request.Which :=
           C.unsigned (if Read then Item.Download else Item.Upload);

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
   procedure Write_Bytes
     (Item   : in out Engine;
      Memory : Address;
      Bytes  : Interfaces.Unsigned_64;
      Values : Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean)
   is
      Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

      Where : aliased Address := Null_Handle;
   begin
      Ok := False;

      if Map = null or else Unmap = null then
         return;
      end if;

      if Map (Item.Logical, Memory, 0, Bytes, 0, Where'Access) /= 0 then
         return;
      end if;

      declare
         Room : Model_Runner.Bytes.Byte_Array (Values'Range)
           with Import, Address => Where;
      begin
         Room := Values;
      end;

      Unmap (Item.Logical, Memory);
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
      Item.Plain := Plain_Memory_Kinds (On);
      Item.Share := Share_Host;
      Item.Budget :=
        (if Budget > 0 then Budget
         else Item.Heap / Budget_Whole * Budget_Share);

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

         --  And the same source compiled for a batch of one. Allowed to
         --  fail on its own: a device that takes the wide kernel and
         --  refuses the narrow one runs every batch on the wide one, which
         --  is what every device did until now.
         declare
            Narrow : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Row_Single;
         begin
            Request.Size := Interfaces.C.size_t (Narrow'Length * 4);
            Request.Code := Narrow'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Single := Made;
            end if;
         end;
      end;

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
         end if;
      end;

      --  And the two that only some devices get: the matrix product and
      --  the half-precision copy its operand needs. Made together, because
      --  neither is any use without the other, and made at all only where
      --  the device said it offers the instruction at the shape the shader
      --  is written for.
      Item.Matrices := Has_Matrix_Instruction (On);

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
               end if;
            end if;
         end;
      end if;

      --  Four storage buffers, and what a set of them looks like.
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

      --  And the pipeline.
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

         Request.Stage.Module := Item.Shader;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) /= 0
         then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Item.Pipeline := Made;

         --  And the narrow one, against the same layout. A refusal here is
         --  not a fault either.
         if Item.Single /= Null_Handle then
            Request.Stage.Module := Item.Single;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Single_Line := Made;
            end if;
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

         C.Strings.Free (Name);
         Item.Blend_Line := Made;
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
         --  longest sequence, in one pool: three storage descriptors each.
         Sizes   : aliased Pool_Size :=
           (Kind  => Descriptor_Storage,
            Count => C.unsigned (4 * (1 + Sequence_Limit)));
         Request : aliased Descriptor_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Max_Sets := C.unsigned (1 + Sequence_Limit);
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
      for Index in 1 .. Item.Used loop
         Give_Back_Buffer
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory);
         Item.Kept (Index).Key := Null_Handle;
         Item.Kept (Index).Bytes := 0;
         Item.Kept (Index).Rows := 0;
         Item.Kept (Index).Columns := 0;
      end loop;

      Item.Used := 0;
      Item.Kept_Bytes := 0;
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
      Instance_Of := Item.Instance;

      --  Everything the device was holding for a model, then the two that
      --  change every call.
      for Index in 1 .. Item.Used loop
         Give_Back_Buffer
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory);
         Item.Kept (Index).Key := Null_Handle;
         Item.Kept (Index).Bytes := 0;
      end loop;
      Item.Used := 0;
      Item.Kept_Bytes := 0;
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
      end;

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Item.Cache_Bytes := 0;

      Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
      Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
      Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
      Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
      Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
      Item.Vector_Bytes := 0;
      Item.Result_Bytes := 0;
      Item.Half_Bytes := 0;

      --  In the reverse of the order they were made, and each only if it
      --  was. The command buffer goes with its pool and the descriptor set
      --  with its own, so neither is given back on its own.
      Give_Back (Item.Fence, "vkDestroyFence");
      Item.Buffer := Null_Handle;
      Give_Back (Item.Commands, "vkDestroyCommandPool");
      Item.Descriptor := Null_Handle;
      Give_Back (Item.Pool, "vkDestroyDescriptorPool");
      Give_Back (Item.Group_Line, "vkDestroyPipeline");
      Give_Back (Item.Single_Line, "vkDestroyPipeline");
      Give_Back (Item.Extra_Line, "vkDestroyPipeline");
      Give_Back (Item.Halve_Line, "vkDestroyPipeline");
      Give_Back (Item.Matrix_Line, "vkDestroyPipeline");
      Give_Back (Item.Attend_Line, "vkDestroyPipeline");
      Give_Back (Item.Blend_Line, "vkDestroyPipeline");
      Give_Back (Item.Pipeline, "vkDestroyPipeline");
      Give_Back (Item.Layout, "vkDestroyPipelineLayout");
      Give_Back (Item.Set_Layout, "vkDestroyDescriptorSetLayout");
      Give_Back (Item.Single, "vkDestroyShaderModule");
      Give_Back (Item.Extra, "vkDestroyShaderModule");
      Give_Back (Item.Halver, "vkDestroyShaderModule");
      Give_Back (Item.Matrix, "vkDestroyShaderModule");
      Give_Back (Item.Grouped, "vkDestroyShaderModule");
      Give_Back (Item.Attender, "vkDestroyShaderModule");
      Give_Back (Item.Blender, "vkDestroyShaderModule");
      Give_Back (Item.Shader, "vkDestroyShaderModule");
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

   function Waited (Item : Engine) return Natural is (Item.Waited);

   --  The code a Vulkan wait returns when the fence has not signalled yet.
   --  Anything else that is not success is a refusal, and asking again would
   --  only put the same question.
   Timeout_Result : constant Interfaces.C.int := 2;

   ---------------------------------------------------------------------------
   --  One product
   ---------------------------------------------------------------------------

   ---------------------
   -- Give_Back_Least --
   ---------------------

   --  Release the matrix least recently multiplied by, so that another can
   --  take its place.
   --
   --  Least recently used rather than first or last. A forward pass reads
   --  every matrix of the model once in the same order, so releasing the
   --  most recent would release the one wanted next, and releasing the first
   --  would release the one wanted after that. The one wanted longest ago is
   --  the one whose turn comes last.
   --
   --  @param Item Engine holding them.
   --  @param Gone True when one was released.
   procedure Give_Back_Least (Item : in out Engine; Gone : out Boolean) is
      Oldest : Natural := 0;
   begin
      Gone := False;

      --  Among the ones that took budget, because those are the only ones
      --  releasing which makes room. An imported matrix is the host's own
      --  memory and giving it back frees none of the device's.
      for Index in 1 .. Item.Used loop
         if not Item.Kept (Index).Own
           and then (Oldest = 0
                     or else Item.Kept (Index).Used_At
                             < Item.Kept (Oldest).Used_At)
         then
            Oldest := Index;
         end if;
      end loop;

      if Oldest = 0 then
         return;
      end if;

      Give_Back_Buffer
        (Item, Item.Kept (Oldest).Buffer, Item.Kept (Oldest).Memory);
      Item.Released := Item.Released + 1;

      --  An imported matrix took none of the budget, so releasing it gives
      --  none back. Subtracting its bytes would make the budget grow every
      --  time one went, which on a model that does not fit is every token.
      if Item.Kept (Oldest).Own then
         Item.Taken := Item.Taken - 1;
      else
         Item.Kept_Bytes := Item.Kept_Bytes - Item.Kept (Oldest).Bytes;
      end if;

      --  The last one moves into the gap, because the order of this list is
      --  nothing: what says which is oldest is the count each carries.
      Item.Kept (Oldest) := Item.Kept (Item.Used);
      Item.Kept (Item.Used) :=
        (Key => Null_Handle, Buffer => Null_Handle, Memory => Null_Handle,
         Bytes => 0, Used_At => 0, Packing => Values_F32,
         Rows => 0, Columns => 0, Base => 0, Own => False);
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

   function Cached_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Cache_Bytes);

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
         Packed_IQ4_XS => 136];

      Per : constant Natural :=
        (case Packing is
            when Values_F32 | Values_F16 | Values_BF16 => 1,
            when Super_Packing                         => 256,
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
      Key          : System.Address)
   is
      Weight_Buffer : Address renames Buffer;
      Weight_Memory : Address renames Memory;
      Weight_Base   : Interfaces.Unsigned_64 renames Base;
      Weight_Own    : Boolean := False;
      Good          : Boolean;
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
         for Index in 1 .. Item.Used loop
            if Item.Kept (Index).Key = Key
              and then Item.Kept (Index).Bytes = Weight_Bytes
              and then Item.Kept (Index).Packing = Packing
              and then Item.Kept (Index).Rows = Rows
              and then Item.Kept (Index).Columns = Columns
            then
               Weight_Buffer := Item.Kept (Index).Buffer;
               Weight_Memory := Item.Kept (Index).Memory;
               Weight_Base := Item.Kept (Index).Base;
               Weight_Own := Item.Kept (Index).Own;
               Item.Kept (Index).Used_At := Item.Clock;
               exit;
            end if;
         end loop;
      end if;

      if Weight_Buffer = Null_Handle then
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
            if Key /= System.Null_Address and then Item.Budget > 0 then
               declare
                  Gone : Boolean := True;
               begin
                  while Gone
                    and then Item.Used > 0
                    and then Item.Kept_Bytes + Weight_Bytes > Item.Budget
                  loop
                     Give_Back_Least (Item, Gone);
                  end loop;
               end;
            end if;

            Take (Item, Weight_Bytes, Weight_Buffer, Weight_Memory, Good);
            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
               Ok := False;
               return;
            end if;

            Write_Bytes
              (Item, Weight_Memory, Weight_Bytes,
               Weights (Weights'First + At_Byte
                        .. Weights'First + At_Byte
                           + Model_Runner.Bytes.Byte_Count (Weight_Bytes) - 1),
               Good);
            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
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
                     or else Item.Kept_Bytes + Weight_Bytes <= Item.Budget)
         then
            Item.Used := Item.Used + 1;
            Item.Kept (Item.Used) :=
              (Key => Key, Buffer => Weight_Buffer, Memory => Weight_Memory,
               Bytes => Weight_Bytes, Used_At => Item.Clock,
               Packing => Packing, Rows => Rows, Columns => Columns,
               Base => Weight_Base, Own => Weight_Own);

            if Weight_Own then
               Item.Taken := Item.Taken + 1;
            else
               Item.Kept_Bytes := Item.Kept_Bytes + Weight_Bytes;
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
   procedure Submit_And_Wait
     (Item      : in out Engine;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference)
   is
   begin
      Ok := True;
      Cancelled := False;

      --  Hand it over and wait.
      declare
         Submit : constant Submit_Call := To_Submit (Point ("vkQueueSubmit"));
         Wait   : constant Wait_Call := To_Wait (Point ("vkWaitForFences"));
         Reset  : constant Reset_Fences_Call :=
           To_Reset_Fences (Point ("vkResetFences"));

         Buffer_Handle : aliased Address := Item.Buffer;
         Fence_Handle  : aliased Address := Item.Fence;
         Request       : aliased Submit_Info;
      begin
         if Submit = null or else Wait = null or else Reset = null then
            Ok := False;
            return;
         end if;

         Request.Buffers := Buffer_Handle'Address;

         if Reset (Item.Logical, 1, Fence_Handle'Address) /= 0
           or else Submit (Item.Queue, 1, Request'Address, Item.Fence) /= 0
         then
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

            for Attempt in 1 .. Slices loop
               Item.Waited := Attempt;
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

            if Stopped then
               Cancelled := True;
               Ok := False;
               return;
            end if;
         end;
      end;

   end Submit_And_Wait;

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
   procedure Tile_Product
     (Item    : in out Engine;
      Rows    : Natural;
      Columns : Natural;
      Count   : Natural;
      Room    : Natural;
      Packing : Weight_Packing;
      Base    : Interfaces.Unsigned_64;
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

      Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Halve_Line);

      declare
         --  The copying kernel reads the first two words as how many
         --  values the batch really holds and how many the copy is to
         --  hold. The rest of the block is nothing to it.
         Shape : aliased Shape_Constants :=
           (Rows    => C.unsigned (Held),
            Columns => C.unsigned (Made),
            others  => 0);
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

      --  Whichever of the two tiles decodes this format.
      Bind_Pipeline
        (Item.Buffer, Bind_Point_Compute,
         (if On_Extra (Packing) then Item.Extra_Line else Item.Matrix_Line));

      declare
         Shape : aliased Shape_Constants :=
           (Rows    => C.unsigned (Rows),
            Columns => C.unsigned (Columns),
            Count   => C.unsigned (Count),
            First   => 0,
            Packing => C.unsigned (Weight_Packing'Pos (Packing)),
            Base    => C.unsigned (Base));
      begin
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Product_Bytes, Shape'Address);
         Dispatch
           (Item.Buffer,
            C.unsigned (Rows / Tile_Rows),
            C.unsigned (Room / Tile_Vectors), 1);
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

      if Item.Half_Bytes < Half_Bytes then
         Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
         Take (Item, Half_Bytes, Item.Half_Buffer, Item.Half_Memory, Good);
         if not Good then
            Release_Borrowed;
            return;
         end if;
         Item.Half_Bytes := Half_Bytes;
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

         for Index in Told'Range loop
            if Index in Buffers'Range then
               Told (Index).Buffer := Buffers (Index);
               Told (Index).Extent := Extent (Index);
            end if;

            Notes (Index).Target := Item.Descriptor;
            Notes (Index).Binding := C.unsigned (Index - 1);
            Notes (Index).Buffers := Told (Index)'Address;
         end loop;

         Update (Item.Logical, 4, Notes'Address, 0, Null_Handle);
      end;

      --  The work: one group per sixty-four rows, which is what the shader
      --  declares a group to be, and one dispatch per Batch_Group vectors,
      --  which is what an invocation carries. All of them in the one command
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
               Weight_Base, Good);

            if not Good then
               Release_Borrowed;
               return;
            end if;
         else
            declare
               First : Natural := 0;
            begin
               while First < Count loop
                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (Rows),
                        Columns => C.unsigned (Columns),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (First),
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (Packing)),
                        Base    => C.unsigned (Weight_Base));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((Rows * Row_Lanes + Group_Size - 1)
                                    / Group_Size), 1, 1);
                  end;

                  First := First + Batch_Group;
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
     (Item     : in out Engine;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean)
   is
      Ignored : constant Boolean := Set_Asking (Item);

      Wanted : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;
   begin
      Ok := False;

      if not Is_Ready (Item) or else Elements = 0 then
         return;
      end if;

      --  Already large enough is already done, so a caller may say this
      --  every layer without paying for it after the first.
      if Item.Cache_Bytes >= Wanted then
         Ok := True;
         return;
      end if;

      declare
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));
      begin
         if Item.Cache_At /= Null_Handle
           and then Unmap /= null
           and then Item.Cache_Memory /= Null_Handle
         then
            Unmap (Item.Logical, Item.Cache_Memory);
         end if;

         Item.Cache_At := Null_Handle;
      end;

      Give_Back_Buffer (Item, Item.Cache_Buffer, Item.Cache_Memory);
      Take (Item, Wanted, Item.Cache_Buffer, Item.Cache_Memory, Ok);
      if not Ok then
         Item.Cache_Bytes := 0;
         return;
      end if;

      --  Mapped here and left mapped. The kind this came from is
      --  host-coherent by the rule that chose it, so a write through this
      --  pointer is seen by the device without a flush.
      declare
         Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
         Where : aliased Address := Null_Handle;
      begin
         if Map = null
           or else Map (Item.Logical, Item.Cache_Memory, 0, Wanted, 0,
                        Where'Access) /= 0
         then
            Ok := False;
            Item.Cache_Bytes := 0;
            return;
         end if;

         Item.Cache_At := Where;
      end;

      Item.Cache_Bytes := Wanted;
   end Reserve;

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
        or else Item.Cache_At = Null_Handle
        or else Values'Length = 0
        or else At_Byte + Span > Item.Cache_Bytes
      then
         return;
      end if;

      --  Straight into the standing mapping: a copy and no call to the
      --  driver at all.
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

      Ok := True;
   end Put_Cache;

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
      K_Base     : Natural;
      V_Base     : Natural;
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
        or else Heads = 0
        or else Head_Size = 0
        or else Value_Size = 0
        or else Value_Size > Attention_Room
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

         Told (1) := (Item.Cache_Buffer, 0, Kept_Bytes);
         Told (2) := (Item.Vector_Buffer, 0, Query_Bytes);
         Told (3) := (Item.Result_Buffer, 0, Blend_Bytes);
         Told (4) := Half_Descriptor (Item);

         for Binding in Told'Range loop
            Notes (Binding).Target := Item.Descriptor;
            Notes (Binding).Binding := C.unsigned (Binding - 1);
            Notes (Binding).Buffers := Told (Binding)'Address;
         end loop;

         Update (Item.Logical, 4, Notes'Address, 0, Null_Handle);
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
            K_Base     => C.unsigned (K_Base),
            V_Base     => C.unsigned (V_Base),
            KV_Width   => C.unsigned (KV_Width),
            V_Width    => C.unsigned (V_Width),
            Scale      => C.C_float (Scale),
            Cap        => C.C_float (Cap),
            Positions  => C.unsigned (Slots),
            Window     => C.unsigned (Window),
            Causal     => (if Causal then 1 else 0),
            Max_Bias   => C.C_float (Max_Bias));
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            return;
         end if;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            return;
         end if;

         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Attend_Kernel (Item));
         Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Attention_Bytes, Shape'Address);
         --  A workgroup a head of a position, which is what the kernel's
         --  source declares: its invocations divide the cached positions
         --  between them, and the positions of a batch do not need each
         --  other, so they go in one submission rather than one each.
         Dispatch (Item.Buffer, C.unsigned (Heads), C.unsigned (Slots), 1);

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
      K_Base     : Natural;
      V_Base     : Natural;
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
      Reserve (Item, Cache'Length, Good);
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

   procedure Open_Sequence (Steps : out Sequence) is
   begin
      Steps.Held := 0;
   end Open_Sequence;

   ------------
   -- Length --
   ------------

   function Length (Steps : Sequence) return Natural is (Steps.Held);

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
      Key     : System.Address := System.Null_Address)
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
         Blends => False, Unit => 0, Attends => False,
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
      Key     : System.Address := System.Null_Address)
   is
   begin
      --  Nothing to chain to, no room, or a width that does not meet the
      --  one before it. Each is a refusal rather than something patched
      --  over: a product reading the wrong number of values would compute
      --  and be wrong.
      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Base = System.Null_Address
        or else Columns /= Steps.Items (Steps.Held).Rows
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => Base, Span => Span, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => True,
         Blends => False, Unit => 0, Attends => False,
         others => <>);
      Added := True;
   end Add_Chained_Product;

   ---------------------
   -- Add_Combination --
   ---------------------

   procedure Add_Combination
     (Steps : in out Sequence;
      Unit  : Natural;
      Added : out Boolean) is
   begin
      if Steps.Held < 2
        or else Steps.Held = Sequence_Limit
        or else Steps.Items (Steps.Held).Rows
                  /= Steps.Items (Steps.Held - 1).Rows
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Base => System.Null_Address, Span => 0, At_Byte => 0,
         Packing => Weight_Packing'First,
         Rows => Steps.Items (Steps.Held - 1).Rows,
         Columns => Steps.Items (Steps.Held - 1).Rows,
         Key => System.Null_Address, Chained => True,
         Blends => True, Unit => Unit, Attends => False,
         others => <>);
      Added := True;
   end Add_Combination;

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
      K_Base     : Natural;
      V_Base     : Natural;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Added      : out Boolean;
      Window     : Natural := 0;
      Chained    : Boolean := False;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0) is
   begin
      --  The same refusals the single call makes, made while recording
      --  rather than while running: a step that could not be dispatched is
      --  better refused where the caller can still do it another way.
      if Steps.Held = Sequence_Limit
        or else (Chained
                 and then (Steps.Held = 0
                           or else Steps.Items (Steps.Held).Rows
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
         Unit => 0, Attends => True,
         Heads => Heads, Head_Size => Head_Size, Value_Size => Value_Size,
         Group_Size => Group_Size, First => First, Last => Last,
         K_Base => K_Base, V_Base => V_Base, KV_Width => KV_Width,
         V_Width => V_Width, Window => Window, Scale => Scale, Cap => Cap,
         Causal => Causal, Max_Bias => Max_Bias);
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
      Cancel    : Model_Runner.Cancellation.Token_Reference := null)
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

      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Steps.Items (1).Columns)
        * Interfaces.Unsigned_64 (Count) * 4;

      Result_Bytes : Interfaces.Unsigned_64 := 0;

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
              (if Uses_Matrix (Item, This.Packing, This.Rows,
                               This.Columns, Count)
               then Whole_Tiles (Count) else Count);

            Mine : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (This.Rows)
              * Interfaces.Unsigned_64 (Room) * 4;
         begin
            if Uses_Matrix (Item, This.Packing, This.Rows,
                            This.Columns, Count)
            then
               Half_Bytes := Interfaces.Unsigned_64'Max
                 (Half_Bytes,
                  Interfaces.Unsigned_64 (This.Columns)
                  * Interfaces.Unsigned_64 (Room) * 2);
            end if;

            --  A combining step carries no matrix: it reads the two
            --  results before it and writes its own. Everything the shape
            --  checks below say about a matrix is beside the point for it.
            if This.Attends then
               --  An attention step carries no matrix either, and reads a
               --  cache rather than a weight. What it needs that the shape
               --  checks below cannot say is that the cache is there: a
               --  sequence recorded against a cache the engine does not
               --  hold would dispatch against whatever the binding last
               --  named, which is an answer and a wrong one.
               if This.Rows = 0
                 or else Item.Cache_Buffer = Null_Handle
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
            elsif This.Blends then
               if This.Rows = 0
                 or else Index < 3
                 or else Steps.Items (Index - 1).Rows /= This.Rows
                 or else Steps.Items (Index - 2).Rows /= This.Rows
               then
                  return;
               end if;

               Places (Index).Weight := 0;
            elsif This.Rows = 0
              or else (not This.Chained
                       and then This.Columns /= Steps.Items (1).Columns)
              or else (This.Chained
                       and then This.Columns /= Steps.Items (Index - 1).Rows)
              or else Wide = 0
              or else Interfaces.Unsigned_64 (This.Rows)
                        * Interfaces.Unsigned_64 (This.Columns) > Max_Elements
              or else Interfaces.Unsigned_64 (This.Columns)
                        * Interfaces.Unsigned_64 (Count) > Max_Elements
              or else This.Base = System.Null_Address
              or else Interfaces.Unsigned_64 (This.Span)
                        < Interfaces.Unsigned_64 (This.At_Byte)
                          + Interfaces.Unsigned_64 (This.Rows) * Wide
            then
               return;
            else
               Places (Index).Weight :=
                 Interfaces.Unsigned_64 (This.Rows) * Wide;
            end if;
            Places (Index).At_Byte := Result_Bytes;
            Places (Index).Bytes := Mine;

            Result_Bytes :=
              Result_Bytes + (Mine + Alignment - 1) / Alignment * Alignment;

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

      Item.Clock := Item.Clock + 1;

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
            if This.Blends or else This.Attends then
               goto Next_Step;
            end if;

            Acquire_Weights
              (Item, Held, This.At_Byte, This.Packing,
               This.Rows, This.Columns, Places (Index).Weight,
               Places (Index).Buffer, Places (Index).Memory,
               Places (Index).Base, Places (Index).Borrowed, Good, This.Key);
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
         Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Result_Bytes := Result_Bytes;
      end if;

      if Item.Half_Bytes < Half_Bytes then
         Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
         Take (Item, Half_Bytes, Item.Half_Buffer, Item.Half_Memory, Good);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Half_Bytes := Half_Bytes;
      end if;

      --  The activation goes over once, however many products read it.
      declare
         Wanted : Model_Runner.Numerics.Real_Array
           renames Vectors (Vectors'First
                            .. Vectors'First
                               + Model_Runner.Numerics.Element_Count
                                   (Steps.Items (1).Columns)
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
               Told (1) :=
                 (Buffer => Item.Cache_Buffer,
                  Offset => 0,
                  Extent => Item.Cache_Bytes);
               --  The queries: where the activation was written, or --
               --  for a chained attention -- what the step before it wrote,
               --  which never left the device.
               if Steps.Items (Index).Chained then
                  Told (2) :=
                    (Buffer => Item.Result_Buffer,
                     Offset => Places (Index - 1).At_Byte,
                     Extent => Places (Index - 1).Bytes);
               else
                  Told (2) :=
                    (Buffer => Item.Vector_Buffer, Offset => 0,
                     Extent => Vector_Bytes);
               end if;
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 4, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            if Steps.Items (Index).Blends then
               --  Two arms in, its own room out. Both arms are results that
               --  never left the device.
               Told (1) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index - 2).At_Byte,
                  Extent => Places (Index - 2).Bytes);
               Told (2) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index - 1).At_Byte,
                  Extent => Places (Index - 1).Bytes);
               Told (3) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index).At_Byte,
                  Extent => Places (Index).Bytes);
               Told (4) := Half_Descriptor (Item);

               for Binding in Told'Range loop
                  Notes (Binding).Target := Item.Sets (Index);
                  Notes (Binding).Binding := C.unsigned (Binding - 1);
                  Notes (Binding).Buffers := Told (Binding)'Address;
               end loop;

               Update (Item.Logical, 4, Notes'Address, 0, Null_Handle);
               goto Next_Set;
            end if;

            Told (1) :=
              (Buffer => Places (Index).Buffer, Offset => 0,
               Extent => Places (Index).Base + Places (Index).Weight);
            --  What this product reads: the activation the caller sent,
            --  or -- for a chained one -- the result the product before it
            --  wrote, which never left the device.
            if Steps.Items (Index).Chained then
               Told (2) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index - 1).At_Byte,
                  Extent => Places (Index - 1).Bytes);
            else
               Told (2) :=
                 (Buffer => Item.Vector_Buffer, Offset => 0,
                  Extent => Vector_Bytes);
            end if;
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 4, Notes'Address, 0, Null_Handle);

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
         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));
         --  Looked up only when something chains. Resolving an entry point
         --  is not free, and a sequence of products that share an activation
         --  -- which is every sequence the engine names today -- would
         --  otherwise pay for a barrier it never records.
         Chains : Boolean := False;

         Barrier : Barrier_Call := null;

         Wall : aliased Memory_Barrier;

         Began : aliased Command_Begin_Info;
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

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Release_All;
            return;
         end if;

         Bind_Pipeline
           (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));

         for Index in 1 .. Steps.Held loop
            declare
               This : Step renames Steps.Items (Index);

               Bound : aliased Address := Item.Sets (Index);
               First : Natural := 0;
            begin
               --  A chained product reads what the one before it wrote, so
               --  the device is told to finish writing before it starts
               --  reading. Products of the same activation share nothing and
               --  get no barrier, which is why this is here and not around
               --  the whole loop.
               if This.Chained then
                  Barrier
                    (Item.Buffer, Pipeline_Stage_Compute,
                     Pipeline_Stage_Compute, 0, 1, Wall'Address,
                     0, Null_Handle, 0, Null_Handle);
               end if;

               Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                          Bound'Address, 0, Null_Handle);

               if This.Attends then
                  --  The attention kernel, and back again afterwards, as
                  --  the combining step does.
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Attend_Kernel (Item));

                  declare
                     Shape : aliased Attention_Constants :=
                       (Heads      => C.unsigned (This.Heads),
                        Head_Size  => C.unsigned (This.Head_Size),
                        Value_Size => C.unsigned (This.Value_Size),
                        Group_Size => C.unsigned (This.Group_Size),
                        First      => C.unsigned (This.First),
                        Last       => C.unsigned (This.Last),
                        K_Base     => C.unsigned (This.K_Base),
                        V_Base     => C.unsigned (This.V_Base),
                        KV_Width   => C.unsigned (This.KV_Width),
                        V_Width    => C.unsigned (This.V_Width),
                        Scale      => C.C_float (This.Scale),
                        Cap        => C.C_float (This.Cap),

                        --  Run's Count is how many positions attend: a
                        --  batch of activations is a batch of positions,
                        --  and a workgroup goes to each head of each.
                        Positions  => C.unsigned (Count),
                        Window     => C.unsigned (This.Window),
                        Causal     => (if This.Causal then 1 else 0),
                        Max_Bias   => C.C_float (This.Max_Bias));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Attention_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer, C.unsigned (This.Heads),
                        C.unsigned (Count), 1);
                  end;

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

                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (Span),
                        Columns => C.unsigned (This.Unit),
                        others  => 0);
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((Span + Group_Size - 1)
                                    / Group_Size), 1, 1);
                  end;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
                  goto Next_Dispatch;
               end if;

               if Uses_Matrix (Item, This.Packing, This.Rows,
                               This.Columns, Count)
               then
                  declare
                     Done : Boolean;
                  begin
                     Tile_Product
                       (Item, This.Rows, This.Columns, Count,
                        Whole_Tiles (Count), This.Packing,
                        Places (Index).Base, Done);

                     if not Done then
                        Release_All;
                        return;
                     end if;
                  end;

                  goto Next_Dispatch;
               end if;

               while First < Count loop
                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (First),
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((This.Rows * Row_Lanes + Group_Size - 1)
                                    / Group_Size), 1, 1);
                  end;

                  First := First + Batch_Group;
               end loop;

               <<Next_Dispatch>>
            end;
         end loop;

         if Stop (Item.Buffer) /= 0 then
            Release_All;
            return;
         end if;
      end;

      --  Once, for all of them.
      Submit_And_Wait (Item, Good, Cancelled, Cancel);
      if not Good then
         Release_All;
         return;
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
               Target (Slice'Range) := Slice;
               Filled := Filled + Mine;
            end;
         end loop;

      end;

      Release_All;
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
