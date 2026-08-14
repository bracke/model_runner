with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.Numerics;

--  Matrix-vector products on a device.
--
--  One operation, because one is what an evaluation is made of: a matrix of
--  rows by columns against a vector of columns, giving a vector of rows.
--  Everything else the engine does is that, repeated.
--
--  An Engine holds what is expensive to make -- the pipeline, the layout,
--  the command pool -- and makes what is cheap per call. Buffers are cheap
--  and are made per call in this piece; keeping a model resident on the
--  device is what the piece after this one is for, and it is the difference
--  between a device that helps and one that spends its time being handed
--  the same weights again.
--
--  Availability. Everything here reports failure rather than raising. A
--  machine with no device, a driver that refuses, a shader that will not
--  load: each is a False, and the caller runs on the processor instead.
--
--  Arithmetic. The shader accumulates in binary32 where the processor's
--  kernels accumulate a row in binary64 and round once. The two agree to
--  the precision binary32 carries and not beyond it, which is a thing to
--  measure rather than to assume.
--
--  Task safety: an Engine belongs to one task. Two tasks wanting a device
--  want two engines.
package Model_Runner.Platform.Device.Products is

   --  Largest product this will attempt, in elements. A device states its
   --  own limits and they are larger than this; the bound is here so that a
   --  request the caller got wrong is refused rather than handed to a
   --  driver.
   Max_Elements : constant := 2 ** 28;

   --  Vectors one dispatch carries, which is what the shader declares an
   --  invocation to hold. A longer batch is several dispatches in the one
   --  command buffer, not several submissions.
   Batch_Group : constant := 8;

   --  How a matrix's bytes are packed. The device decodes every one of these
   --  itself, which is every format this program reads: nothing has to be
   --  repacked to reach a device any more, and repacking is what it always
   --  was -- four bytes a weight, and the caller's decision.
   --
   --  The order is the definition. The shader is given Weight_Packing'Pos
   --  and switches on it, so its constants are a copy of this list and
   --  reordering here silently changes what every branch there decodes. The
   --  conformance sweep multiplies a matrix in each of these on the device
   --  and against the reference transformer, which is what would catch it.
   type Weight_Packing is
     (Values_F32, Values_F16, Values_BF16,
      Packed_Q4_0, Packed_Q4_1, Packed_Q5_0, Packed_Q5_1, Packed_Q8_0,
      Packed_IQ4_NL,
      Packed_Q2_K, Packed_Q3_K, Packed_Q4_K, Packed_Q5_K, Packed_Q6_K,
      Packed_IQ4_XS);

   --  The packings whose blocks hold two hundred and fifty-six elements
   --  rather than thirty-two. A row in one of these is a whole number of
   --  super-blocks, so a width that is not a multiple of 256 is refused
   --  rather than rounded.
   --  The super-block formats are kept together for this: IQ4_XS shares its
   --  levels with IQ4_NL and its shape with the k-quants, and it is the shape
   --  that decides what a width has to be.
   subtype Super_Packing is Weight_Packing range Packed_Q2_K .. Packed_IQ4_XS;

   --  What holds a device's pipeline for the product.
   type Engine is limited private;

   --  Give back every matrix the device is holding, and keep the pipeline.
   --
   --  A resident matrix is remembered by where its bytes lie, what shape
   --  they have and what format they are in. That names a matrix for as long
   --  as it exists, and no longer: once the storage is freed, another matrix
   --  of the same shape and format can be put at the same address, and the
   --  device would answer for the second with the first one's weights.
   --
   --  So whoever frees the storage has to say so, and a model closing is
   --  exactly that moment. It is not a hypothetical: the conformance sweep
   --  opens and closes a model per format and architecture with the device
   --  open across all of them, and the allocator returns the address it has
   --  just taken often enough that a run in every three or four came out
   --  wrong -- by a fifth of a logit, which is a wrong answer and not a
   --  rounding difference.
   --
   --  @param Item Engine to empty; harmless on one that holds nothing.
   procedure Forget_Matrices (Item : in out Engine);

   --  Prepare a device to compute products.
   --
   --  @param Item Engine to fill; released first.
   --  @param On Open device.
   --  @param Ready True when the device took the shader and the pipeline.
   --  @param Budget Bytes of device memory the resident matrices may take,
   --    or zero for the share of the device's own heap described below. A
   --    caller that knows the device is doing something else can say so, and
   --    a caller that wants to see what a model does when it does not fit
   --    can make it not fit.
   --  @param Share_Host Whether to hand the device the host's own memory
   --    rather than copy the weights into its own, where the device will
   --    take a pointer at all. It holds the model once instead of twice,
   --    and the device reads it more slowly for the rest of the run:
   --    measured on this machine at 0.80 tokens a second against 9.95 for
   --    the same model copied in. A memory decision, not a speed one.
   procedure Open
     (Item       : in out Engine;
      On         : Context;
      Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False);

   --  Release everything the device was holding. Idempotent.
   --
   --  @param Item Engine to release.
   procedure Close (Item : in out Engine);

   --  Report whether an engine has a device behind it.
   --
   --  @param Item Engine to inspect.
   --  @return True when it is ready to compute.
   function Is_Ready (Item : Engine) return Boolean;

   --  One matrix against a batch of vectors.
   --
   --  Weights are read row by row, which is the layout every weight in this
   --  program already has: element (row, column) is at row * columns +
   --  column, however the row is packed.
   --
   --  The batch is where a device earns its place. Each weight is read once
   --  for every vector of the batch rather than once for each, so a prompt
   --  costs one pass over the model instead of a pass a token -- which is
   --  the difference between a backend that helps with a prompt and one that
   --  only helps with what comes after it.
   --
   --  @param Item Ready engine.
   --  @param Weights The storage the matrix lives in, which is the model's
   --    own bytes rather than the matrix alone: what a device is handed when
   --    it reads the weights where they lie is a page-aligned range, and
   --    pages are larger than tensors, so the range reaches either side of
   --    the matrix and both ends have to be inside memory this process owns.
   --  @param At_Byte Where the matrix begins in that storage.
   --  @param Packing How those bytes are packed. Columns must be a whole
   --    number of thirty-two element blocks for anything but Values_F32.
   --  @param Rows Number of rows, which is the length of one result.
   --  @param Columns Number of columns.
   --  @param Vectors Count runs of Columns values, one after another.
   --  @param Count How many vectors; one is a batch of one.
   --  @param Target Receives Count runs of Rows values.
   --  @param Key Where these weights live, which is what makes a second
   --    product with the same matrix cost nothing to set up. Null_Address
   --    keeps nothing, which is what a caller with a matrix it will not use
   --    again should pass.
   --  @param Ok True when the device computed it.
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
      Key     : System.Address := System.Null_Address);

   --  The same, for one vector of binary32 weights already decoded.
   --
   --  @param Item Ready engine.
   --  @param Weights Rows * Columns values, row by row.
   --  @param Vector Columns values.
   --  @param Rows Number of rows, which is the length of the result.
   --  @param Columns Number of columns.
   --  @param Target Receives Rows values.
   --  @param Ok True when the device computed it.
   --  @param Key As above.
   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Numerics.Real_Array;
      Vector  : Model_Runner.Numerics.Real_Array;
      Rows    : Natural;
      Columns : Natural;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Key     : System.Address := System.Null_Address);

   --  Bytes one row of a matrix takes.
   --
   --  @param Packing How the row is packed.
   --  @param Columns Number of columns.
   --  @return The byte count, or zero when the columns do not divide into
   --    blocks the packing is made of.
   function Row_Bytes
     (Packing : Weight_Packing; Columns : Natural)
      return Interfaces.Unsigned_64;

   --  How many matrices the device is holding.
   --
   --  @param Item Engine to inspect.
   --  @return Count of matrices kept.
   function Resident (Item : Engine) return Natural;

   --  How many bytes those matrices take on the device.
   --
   --  @param Item Engine to inspect.
   --  @return Bytes held.
   function Resident_Bytes (Item : Engine) return Interfaces.Unsigned_64;

   --  How many bytes this engine will hold before it starts giving matrices
   --  back.
   --
   --  A fraction of the largest heap the device reports, because a device is
   --  not the only thing using its memory -- on an integrated part it is the
   --  host's memory and the model is already in it once. Zero when no device
   --  is open, which is also what a caller gets for asking a closed engine
   --  how much it can hold.
   --
   --  @param Item Engine to inspect.
   --  @return Byte budget for resident matrices.
   function Capacity (Item : Engine) return Interfaces.Unsigned_64;

   --  How many matrices the device is reading where they already are.
   --
   --  A device that shares the host's memory can be handed a pointer to the
   --  weights instead of a copy of them, which is a gigabyte not copied and
   --  a gigabyte not held twice for a model of that size. Not every device
   --  will, and not every pointer can be taken, so this is what actually
   --  happened rather than what was asked for.
   --
   --  @param Item Engine to inspect.
   --  @return Count of matrices taken where they lie.
   function Imported (Item : Engine) return Natural;

   --  How many matrices have been given back to make room for others.
   --
   --  Zero for a model that fits, and a number that rises with every token
   --  for one that does not: a matrix given back is a matrix uploaded again
   --  the next time a token needs it. It is the difference between a device
   --  that is computing and one that is being handed the same weights over
   --  and over, and it was silent before it was counted.
   --
   --  @param Item Engine to inspect.
   --  @return Count of matrices released to make room.
   function Given_Back (Item : Engine) return Natural;

private

   --  How many matrices one engine will keep, as a count. A dense model of a
   --  few dozen layers has some hundreds of them and a mixture of experts has
   --  three a layer for every expert, so this is high enough that the byte
   --  budget is what actually decides. Both bounds are enforced and the
   --  tighter one wins.
   Max_Resident : constant := 4096;

   --  What fraction of the device's largest heap the resident matrices may
   --  take, as a numerator over a denominator. Three quarters: the rest is
   --  for whatever else the device is doing, for the vector and result
   --  buffers, and for the driver's own allocations, none of which this
   --  measures.
   Budget_Share : constant := 3;
   Budget_Whole : constant := 4;

   type Held_Matrix is record
      Key    : System.Address := System.Null_Address;
      Buffer : System.Address := System.Null_Address;
      Memory : System.Address := System.Null_Address;
      Bytes  : Interfaces.Unsigned_64 := 0;

      --  What was uploaded, not just how much of it. An address and a byte
      --  count do not name a matrix: a twelve by two hundred and fifty-six
      --  matrix of half-precision values and one of brain floats are the
      --  same length at the same place and decode to different numbers, and
      --  so are a twelve by two hundred and fifty-six and a six by five
      --  hundred and twelve of the same format.
      --
      --  Found by a test that ran every format in turn through storage of
      --  the same size: the allocator handed back the address it had just
      --  taken, and the device answered the second format with the first
      --  one's weights. What is still not covered, and cannot be from here,
      --  is a caller that frees a matrix and puts another of exactly this
      --  shape and format at the same address. In this program the weights
      --  live as long as the model does, so that does not arise; a caller
      --  for whom it would has to say so by passing a null key.
      Packing : Weight_Packing := Values_F32;
      Rows    : Natural := 0;
      Columns : Natural := 0;

      --  When this was last multiplied by, as a count of products. What
      --  makes the one given back the one least recently wanted, rather
      --  than whichever happens to be first.
      Used_At : Interfaces.Unsigned_64 := 0;

      --  Where the matrix begins inside the buffer. Zero for a matrix
      --  copied in, and the distance from a page boundary for one the
      --  device took where it already was -- which can also be zero, when
      --  the weights happen to start on one, so the flag below says which
      --  of the two this is rather than the number.
      Base    : Interfaces.Unsigned_64 := 0;
      Own     : Boolean := False;
   end record;

   type Held_Array is array (1 .. Max_Resident) of Held_Matrix;

   type Engine is limited record
      --  The instance every entry point this engine uses is found through.
      --  An engine outlives no instance and each names its own.
      Instance : System.Address := System.Null_Address;

      --  The device this belongs to, and the queue work goes to. Copies of
      --  what the context holds: an engine outlives no context, and holding
      --  them saves reaching back through one on every call.
      Logical : System.Address := System.Null_Address;
      Queue   : System.Address := System.Null_Address;
      Family  : Natural := 0;
      Upload  : Natural := 0;

      --  Made once, in this order, and released in the reverse of it.
      Shader     : System.Address := System.Null_Address;
      Set_Layout : System.Address := System.Null_Address;
      Layout     : System.Address := System.Null_Address;
      Pipeline   : System.Address := System.Null_Address;
      Pool       : System.Address := System.Null_Address;
      Descriptor : System.Address := System.Null_Address;
      Commands   : System.Address := System.Null_Address;
      Buffer     : System.Address := System.Null_Address;
      Fence      : System.Address := System.Null_Address;

      --  What the device says its largest heap is, and the share of it these
      --  matrices may take.
      Heap       : Interfaces.Unsigned_64 := 0;
      Budget     : Interfaces.Unsigned_64 := 0;

      --  Whether this device will take the host's own memory as a buffer,
      --  and what a pointer to it has to be aligned to.
      Imports    : Boolean := False;
      Import_To  : Interfaces.Unsigned_64 := 0;
      Plain      : Interfaces.Unsigned_32 := 0;

      --  Whether this engine was asked to read the weights where they lie
      --  rather than copy them.
      Share      : Boolean := False;

      --  The matrices this device is holding, and the two buffers that
      --  change every call.
      Kept       : Held_Array;
      Used       : Natural := 0;
      Kept_Bytes : Interfaces.Unsigned_64 := 0;

      --  Products so far, which is the clock the eviction reads, and how
      --  many matrices have been given back to make room.
      Clock      : Interfaces.Unsigned_64 := 0;
      Released   : Natural := 0;

      --  How many of the resident matrices are the host's own memory rather
      --  than a copy of it.
      Taken      : Natural := 0;

      Vector_Buffer : System.Address := System.Null_Address;
      Vector_Memory : System.Address := System.Null_Address;
      Vector_Bytes  : Interfaces.Unsigned_64 := 0;

      Result_Buffer : System.Address := System.Null_Address;
      Result_Memory : System.Address := System.Null_Address;
      Result_Bytes  : Interfaces.Unsigned_64 := 0;
   end record;

end Model_Runner.Platform.Device.Products;
