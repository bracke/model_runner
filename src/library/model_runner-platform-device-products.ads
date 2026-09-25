with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.Cancellation;
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

   --  Largest product this will attempt, in elements.
   --
   --  A bound so that a request the caller got wrong is refused rather than
   --  handed to a driver, and nothing more than that: what a device will
   --  actually take is the device's own answer and is asked for, matrix by
   --  matrix, against Byte_Limit below.
   --
   --  This was two hundred and sixty-eight million and was described as
   --  smaller than any device's own limit. It was not. A model's widest
   --  matrix is its output projection, which is the vocabulary by the
   --  embedding: 151936 by 4096 is six hundred and twenty-two million, so
   --  every Qwen3 above the smallest, every Falcon-7B and every published
   --  mixture was refused by this line -- and refused as though the device
   --  lacked a capability, because that is the only answer the layer above
   --  had for a product that would not run. Four thousand million is past
   --  what any file this reads can hold and short of what a thirty-two bit
   --  index in a shader can address.
   Max_Elements : constant Interfaces.Unsigned_64 := 4_294_967_296;

   --  Vectors one dispatch carries, which is what the shader declares an
   --  invocation to hold. A longer batch is several dispatches in the one
   --  command buffer, not several submissions.
   Batch_Group : constant := 8;

   --  And what the wider compilation carries. Between Batch_Group and
   --  Tile_Least a batch is served by neither of the other two well: too
   --  many vectors for one dispatch of eight, too few to fill a tile of a
   --  hundred and twenty-eight. Sixteen halves the passes over the weights
   --  there.
   Wide_Group : constant := 16;

   --  A pipeline for every count the row kernel answers directly.
   --
   --  The eight-wide kernel carries eight accumulators whatever it is given,
   --  so a round of five paid for eight: 33.3 milliseconds against the 27.7
   --  the columns are worth, and five sequences came out slower than four.
   --  llama.cpp compiles its mat-vec once for every count from one to eight
   --  and indexes them by it; with the width a specialization constant here
   --  the same thing is a pipeline each and no more words.
   type Row_Line_Array is array (1 .. Batch_Group) of System.Address;

   --  Query positions one workgroup of the tiled attention kernel answers.
   --  attention.comp declares the same number as QUERIES under QUERY_TILE
   --  and the two have to agree: this decides how many workgroups the
   --  dispatch asks for and that one decides how many each does.
   Query_Block : constant := 8;

   --  Heads one workgroup of the bundled attending kernel answers.
   --  attention.comp declares the same number as HEADS under GROUPED and
   --  the two have to agree: this decides how many workgroups the dispatch
   --  asks for down the first axis and that one decides how many heads each
   --  reads. Four rather than eight so that a model whose group is four is
   --  served as well as one whose group is eight.
   Head_Bundle : constant := 4;

   --  And the wider bundle the exact kernel is also made at, for a model
   --  whose group is eight: its keys and values cross once a layer
   --  rather than twice.
   Wide_Bundle : constant := 8;

   --  And the fewest cached positions the exact bundle is bound over: a
   --  short cache is a few workgroups doing little each, and a head a
   --  workgroup is more workgroups.
   Bundle_Least : constant := 256;

   --  Most slices a long cache is cut into for a generated token, and the
   --  fewest positions a slice is worth: attention.comp takes a slice a
   --  workgroup down its third axis and merge.comp puts them together.
   --  A part with a dozen compute units and eight bundles of heads wants
   --  more workgroups than eight, and a slice shorter than a tile or two
   --  is a workgroup that does less than its start costs.
   Slice_Limit : constant := 16;

   --  Most rows and most vectors a binary32 product goes to thin.comp
   --  with, a workgroup a row and vector: past either the row kernel's
   --  economy -- a row read once for every vector an invocation carries
   --  -- is the better one.
   Thin_Rows    : constant := 512;
   Thin_Vectors : constant := 8;

   --  Most experts a batch's routing is inverted over, which is what
   --  invert.comp keeps counters for in shared memory.
   Max_Experts : constant := 512;
   Slice_Least : constant := 256;

   --  Whole numbers written into the cache buffer for a kernel to read
   --  back with floatBitsToUint. A round's per-row table is two of them a
   --  row -- where the row has got to and where its cache begins -- and it
   --  lives at the end of the cache rather than in the push constants,
   --  which is what lets a round have more rows than a push block has room
   --  for words.
   type Word_List is array (Positive range <>) of Natural;

   --  And how many the matrix kernel answers, which is what its tile is
   --  tall. Below this a block is mostly rows the batch does not have.
   --
   --  Sixteen rather than thirty-two, measured: thirty-two holds twice the
   --  answer in registers and needs two hundred and fifty-six of them,
   --  which is four subgroups a SIMD, where sixteen needs ninety-six and
   --  gets ten. The prompt reads 1.212 s against 1.237, better in each of
   --  three rounds. Sixteen is also the floor -- it is what the
   --  instruction's own tile is.
   Matrix_Queries : constant := 16;

   --  The widest head that kernel takes, which is what the shared memory
   --  its queries are staged into is sized for; and the widest its second
   --  compilation takes, for the models whose heads are a hundred and
   --  twenty-eight. A model with heads wider still attends through the
   --  scalar kernel.
   Matrix_Head : constant := 64;
   Matrix_Wide_Head : constant := 128;

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
   --
   --  MXFP4 is last rather than beside the other thirty-two-element
   --  formats because it arrived last: the shader's constants are the
   --  positions, and a format slotted into the middle would renumber every
   --  branch after it.
   type Weight_Packing is
     (Values_F32, Values_F16, Values_BF16,
      Packed_Q4_0, Packed_Q4_1, Packed_Q5_0, Packed_Q5_1, Packed_Q8_0,
      Packed_IQ4_NL,
      Packed_Q2_K, Packed_Q3_K, Packed_Q4_K, Packed_Q5_K, Packed_Q6_K,
      Packed_IQ4_XS,
      Packed_MXFP4,
      Packed_IQ3_S, Packed_IQ2_XXS, Packed_IQ2_XS, Packed_IQ2_S,
      Packed_IQ3_XXS, Packed_IQ1_S, Packed_IQ1_M,
      Packed_TQ1_0, Packed_TQ2_0, Packed_Q1_0, Packed_Q2_0, Packed_NVFP4);

   --  The low-bit packings, which the row product decodes in a compilation
   --  of their own (row_product.comp built with LOW_BITS): a branch costs
   --  every format beside it registers whether taken or not, so the sixteen
   --  above keep their words and these twelve take a pipeline apart. None
   --  has a tile; a batch in one goes to the row product.
   subtype Low_Packing is Weight_Packing range Packed_IQ3_S .. Packed_NVFP4;

   --  One handle for each low-bit packing.
   type Low_Address_Array is array (Low_Packing) of System.Address;

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

   --  How many slices the last product spent waiting for the device.
   --
   --  One is a product the device answered at once. More than one means the
   --  engine went round waiting for it, which is where a stop request made
   --  while a product is running is seen -- so this is how a test can tell
   --  that a cancelled product was cancelled there rather than by the check
   --  before anything was submitted.
   --
   --  Turns rather than slices since the engine asks a fence whether it is
   --  finished before it waits for one: a short product is answered inside
   --  the asking and never reaches the wait at all, and both places count
   --  here and both notice a request. Counting only the slices would say a
   --  product that the asking answered had not waited, which is the thing
   --  this exists to distinguish and would have been false.
   --
   --  @param Item Engine to ask about.
   --  @return Turns taken by the last product, or zero before any.
   function Waited (Item : Engine) return Natural;

   --  Whether a dispatch was left unfinished on this engine.
   --
   --  A device that stopped answering keeps the buffers it was given, and
   --  there is no way to take work back off it. So the engine stops rather
   --  than recording over a buffer the device may still be reading.
   --
   --  @param Item Engine to ask about.
   --  @return True once a dispatch has exceeded the whole bound.
   function Is_Stalled (Item : Engine) return Boolean;

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
   --  @param Slice How long one wait for the device to finish lasts before
   --    the caller's stop request is asked about again. The default is what
   --    a caller wants; a test naming a tiny one is how the loop below can
   --    be reached at all, because a product that finishes inside the first
   --    slice never gets to a second.
   --  @param Patience How long to wait in all before giving up on a device
   --    that has stopped answering. Zero waits not at all, which is how a
   --    test reaches the giving-up path without a device that has genuinely
   --    stopped -- there is no way to arrange one of those on demand.
   procedure Open
     (Item       : in out Engine;
      On         : Context;
      Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0);

   --  Release everything the device was holding. Idempotent.
   --
   --  @param Item Engine to release.
   procedure Close (Item : in out Engine);

   --  Report whether an engine has a device behind it.
   --
   --  @param Item Engine to inspect.
   --  @return True when it is ready to compute.
   function Is_Ready (Item : Engine) return Boolean;

   --  Whether this engine may dispatch the heads step, which a device
   --  that refused its pipeline cannot: the caller records the three steps
   --  it stands for instead.
   --
   --  @param Item Engine to ask.
   --  @return True when Add_Heads will be run rather than refused.
   function Readies_Heads (Item : Engine) return Boolean;

   --  Put one matrix on the device and keep it, computing nothing.
   --
   --  What a product does before it dispatches, without the dispatch: the
   --  matrix is uploaded if it is not there and kept under its key, so a
   --  product that names it later finds it. A mixture's experts are
   --  touched by the tokens that route to them, so a fresh process ran
   --  its first hundred tokens at half speed while it uploaded five
   --  gigabytes a few matrices at a time; holding every stack at load is
   --  the same bytes crossing once, before anyone is waiting.
   --
   --  @param Item Ready engine.
   --  @param Weights The storage the matrix lives in, as for Multiply.
   --  @param At_Byte Where the matrix begins in that storage.
   --  @param Packing How those bytes are packed.
   --  @param Rows Number of rows.
   --  @param Columns Number of columns.
   --  @param Key Where these weights live; what a product will name.
   --  @param Ok True when the device holds it now.
   procedure Hold
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Key     : System.Address;
      Ok      : out Boolean);

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
   --  @param Cancelled True when the caller asked to stop. The product
   --    finished on the device -- a dispatch cannot be taken back, and its
   --    buffers belong to the device until the fence says otherwise -- and
   --    its result is not written out.
   --  @param Key Address identifying the matrix, so that a matrix already
   --    on the device is used where it lies rather than uploaded again.
   --  @param Cancel Stop request to watch, or null for none. Asked before
   --    anything reaches the device and between slices of the wait for it.
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
      Cancel  : Model_Runner.Cancellation.Token_Reference := null);

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

   --  A run of products the engine performs in order.
   --
   --  Every product today is its own call: the activation goes to the device,
   --  one matrix runs, and the result comes back before the next matrix is
   --  named. For a matrix of any size that upload and download disappear
   --  beside the arithmetic, and for the small operations of a layer --
   --  normalizations, softmaxes, rotations -- they would not: the round trip
   --  costs more than the work. Naming several products before any of them
   --  runs is what lets an activation stay where it is between them.
   --
   --  This is the recording half. A sequence of one behaves exactly as the
   --  single call it replaces, which is what makes the change to the caller
   --  provable before anything new is built on it; a sequence of several
   --  still returns each result to the host today, and hoisting that is the
   --  next change rather than this one.
   --
   --  Task safety: a sequence belongs to the task that opened it.

   --  Products one sequence may hold. A layer of a large model names fewer
   --  than a dozen matrices, and a bound that cannot be reached is a bound
   --  nothing has to grow.
   Sequence_Limit : constant := 32;

   --  What the device's own clock said each step of a sequence took.
   --
   --  Microseconds, from the device's timestamp counter: a stamp is
   --  written before the first dispatch and after each step's last, and a
   --  step's figure is the interval between its stamp and the one before
   --  it. A stamp says when everything recorded before it had finished, so
   --  where two steps run side by side -- the two arms of a gated
   --  feed-forward share no barrier and do -- the second is charged with
   --  the overlap and the first with what finished before it started.
   --  Whole is the first stamp to the last, which is what the sequence
   --  cost the device however the steps overlapped.
   type Step_Times is array (1 .. Sequence_Limit) of Float;

   type Timeline is record
      Held  : Natural := 0;
      Whole : Float := 0.0;
      Steps : Step_Times := [others => 0.0];
   end record;

   --  Ask the device to stamp every step of every sequence, or stop.
   --
   --  What it costs is the wait: a timed sequence is waited for before Run
   --  returns, so that its stamps can be read, where an untimed one that
   --  leaves its answer on the device is handed over and left. The device
   --  side of the figures is unchanged by that -- the stamps are between
   --  dispatches the device runs back to back either way -- but the token
   --  rate measured alongside is the rate with the wait in it.
   --
   --  @param Item Ready engine.
   --  @param On True to stamp, False to stop.
   --  @param Ok True when the device can do it: a device whose compute
   --    queue writes no timestamps refuses, and the engine goes on untimed.
   procedure Time_Steps (Item : in out Engine; On : Boolean; Ok : out Boolean);

   --  Attend a generated token out of the half-precision copy of the
   --  cache, or out of the cache proper.
   --
   --  place.comp and heads.comp write every position twice, as it is and
   --  as half precision; the matrix kernel reads the copy for a prompt
   --  and a round's kernel reads it for a row, and a token read the cache
   --  proper, at the precision its answer is published in. At thirteen
   --  hundred positions a token's attention is the bytes of keys and
   --  values it reads, and the copy is half of them. What it costs is the
   --  last bits of a long context's attention, which is what --kv-cache
   --  f16 asks for on the processor too.
   --
   --  @param Item Ready engine.
   --  @param On True to read the copy, False the cache proper.
   procedure Prefer_Halves (Item : in out Engine; On : Boolean);

   --  Whether a token's attention reads the half-precision copy.
   --
   --  @param Item Engine to ask.
   --  @return True after Prefer_Halves said so, where the device has the
   --    kernels for it.
   function Prefers_Halves (Item : Engine) return Boolean;

   --  Keep a batch's attention off the matrix instruction, whose operand
   --  is half precision: every batch then attends through the kernel that
   --  reads the cache proper, in binary32, as a head the instruction cannot
   --  take does anyway. For a caller whose blends go through many blocks
   --  in a row, where the halves compound -- a picture encoder, where the
   --  matrix kernel's halves moved a row by a thousandth of its norm and
   --  the cache proper by a millionth. What it costs is the instruction's
   --  speed on that batch.
   --
   --  @param Item Ready engine.
   --  @param On True to attend in binary32, False as the device prefers.
   procedure Prefer_Exact_Attention (Item : in out Engine; On : Boolean);

   --  Whether a packed session's kernels -- the attention over its block
   --  and the packing into it -- go through shared memory alone rather
   --  than subgroup operations, which is what a device without those
   --  operations gets and what a test asks for on a device that has
   --  them, so the compilation the other devices run is run here too.
   --  Both compilations are made; this says which is bound.
   --
   --  @param Item Ready engine.
   --  @param On True to bind the shared-memory compilations, False to
   --    bind whichever the device can run best.
   procedure Prefer_Plain_Packing (Item : in out Engine; On : Boolean);

   --  Whether a batch's attention is kept off the matrix instruction.
   --
   --  @param Item Engine to ask.
   --  @return True after Prefer_Exact_Attention said so.
   function Prefers_Exact_Attention (Item : Engine) return Boolean;

   --  Whether steps are being stamped.
   --
   --  @param Item Engine to ask.
   --  @return True after Time_Steps said yes and before it was told to stop.
   function Timed (Item : Engine) return Boolean;

   --  What the last Run's stamps said.
   --
   --  @param Item Engine to ask.
   --  @return The timeline, with Held zero before any timed run.
   function Last_Timeline (Item : Engine) return Timeline;

   --  How many experts one gathered product may read at once, which is
   --  the third dimension of its dispatch. Sixteen is what the shader's
   --  push block has room for, and twice what any mixture this program
   --  has been shown chooses.
   Max_Gather : constant := 16;

   --  How many experts one route may choose. Larger than Max_Gather -- the
   --  route buffer holds the whole chosen set for the gather to read in
   --  chunks of Max_Gather -- and matched by the route shader's own arrays.
   Max_Route : constant := 64;

   type Member_List is array (1 .. Max_Gather) of Natural;

   type Sequence is limited private;

   --  A packed session's block on the device, for an attention step of a
   --  sequence: where its rows begin in bytes of the cache buffer and its
   --  scales in floats, how many scales a row has, and how many bits an
   --  element for the keys and for the values -- what Attend_Packed is
   --  told, carried into a sequence so the step binds that kernel rather
   --  than the exact one. K_Bits zero is a cache the exact kernels read.
   type Packed_Cache is record
      K_Bits   : Natural := 0;
      V_Bits   : Natural := 0;
      K_Bytes  : Interfaces.Unsigned_64 := 0;
      V_Bytes  : Interfaces.Unsigned_64 := 0;
      KS_At    : Natural := 0;
      VS_At    : Natural := 0;
      K_Blocks : Natural := 0;
      V_Blocks : Natural := 0;
   end record;

   --  A cache the exact kernels read.
   Not_Packed : constant Packed_Cache := (others => <>);

   --  How a placing step packs the rows it writes, for a packed session's
   --  block: how many bits an element, the bytes from one row to the
   --  next, where the first row's bytes and scales go, and how many
   --  scales a row has. Bits zero is a row placed as it is, into the
   --  exact cache.
   type Packing_Shape is record
      Bits      : Natural := 0;
      Row_Bytes : Natural := 0;
      At_Byte   : Interfaces.Unsigned_64 := 0;
      At_Scale  : Natural := 0;
      Blocks    : Natural := 0;
   end record;

   --  A row placed as it is.
   Not_Packing : constant Packing_Shape := (others => <>);

   --  A packed layer's keys or values unpacked into the half-precision
   --  copy for a batch, so that the matrix kernel attends over them as
   --  it does over an exact session's: how the rows are packed and where
   --  the first is, how many positions from it, and where the halves go
   --  -- an element index the attention step is given as its K_Base or
   --  V_Base, into the copy. Cells zero asks for no unpacking.
   type Unpacking_Shape is record
      Keys   : Packing_Shape := Not_Packing;
      Values : Packing_Shape := Not_Packing;
      Cells  : Natural := 0;
      K_Base : Natural := 0;
      V_Base : Natural := 0;
   end record;

   --  No unpacking.
   Not_Unpacked : constant Unpacking_Shape := (others => <>);

   --  Empty a sequence so that products may be added to it.
   --
   --  @param Steps Sequence to empty.
   procedure Open_Sequence (Steps : out Sequence);

   --  How many products a sequence holds.
   --
   --  @param Steps Sequence to read.
   --  @return The count, which is zero for a sequence just opened.
   function Length (Steps : Sequence) return Natural;

   --  What one step of a sequence is, in a word and a shape.
   --
   --  The kind first -- norm, product, gather, join, combine, rotate,
   --  place, attend, heads, route, mix -- then the rows and columns and
   --  the packing where the step has a matrix, so that a timeline can say
   --  which of thirty steps a figure belongs to without the caller having
   --  named them.
   --
   --  @param Steps Sequence to read.
   --  @param Index Which step, from 1 to Length.
   --  @return The description, or the empty string past Length.
   function Describe (Steps : Sequence; Index : Positive) return String;

   --  Name one product for a sequence to perform.
   --
   --  The weights are held by reference: a sequence names matrices the model
   --  already has and copies none of them, which is the same arrangement the
   --  single call has and the reason a device reads a model's own storage.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the matrix lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the matrix begins.
   --  @param Packing How each row is packed.
   --  @param Rows Number of rows.
   --  @param Columns Number of columns.
   --  @param Key Identifies the matrix so the device may keep it, as it does
   --    for a single product.
   --  @param Added False when the sequence is full, which is a refusal to
   --    record rather than a silent truncation.
   --  @param Kept False when nothing on the host reads this step's answer,
   --    which saves Run the copy back and leaves it where the step after it
   --    will read it.
   --  @param At_Vector Where in the caller's activation this product's
   --    vector begins, in elements. Zero is the front of it, which is what
   --    every product reading one whole activation means.
   --
   --    It is here for a mixture. Its chosen experts each project a vector
   --    of their own down, so the products differ in their input as well as
   --    their matrix, and a sequence has one activation. Laid end to end in
   --    that one activation each product reads its own stretch, and the
   --    eight go over as one submission.
   --  @param Exact True keeps the product off the tile kernel: its
   --    activations are read in binary32 by the row kernel, at the row
   --    kernel's cost.
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
      Exact   : Boolean := False);

   --  Name one product over a few slices of a stack of matrices.
   --
   --  A mixture of experts stores every expert's matrix of one kind in one
   --  tensor, the expert axis outermost, and a token reads a few of them.
   --  Read an expert at a time, each slice is a matrix of its own to the
   --  device -- its own upload, its own residency, its own dispatch -- and
   --  a generated token dispatches twenty-four of them a layer. Read as a
   --  gather, the stack is one buffer the device keeps once, and the
   --  members are the third dimension of one dispatch: the shader is told
   --  which expert each workgroup reads and how many bytes a slice is.
   --
   --  The stack is named as a whole -- Base, Span, At_Byte, and Stack rows
   --  of Columns -- because that is what is uploaded and kept; Each is the
   --  rows of one slice, and the step's answer is Members'Length slices of
   --  Each rows, one after another, which is what the caller reads back.
   --
   --  Apart is where each member's own vector begins in what the step
   --  reads, in elements: zero when every member reads the same vector,
   --  as a gate and an up projection do, and Columns when each reads its
   --  own stretch of one activation laid end to end, as a projection down
   --  does. Chained, the step reads the result of the step it names, or
   --  the one before it, whose rows must then be Columns times the members
   --  where Apart is set and Columns where it is not.
   --
   --  A gather of one member at any batch is a plain product on the slice
   --  it names, and is what a batch's expert takes so that a prompt and a
   --  token keep the same stack resident rather than one each.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the stack lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the stack begins.
   --  @param Packing How each row is packed.
   --  @param Stack Rows the whole stack holds.
   --  @param Each Rows one expert's slice holds.
   --  @param Columns Number of columns.
   --  @param Members Which slices to read, in the order their answers are
   --    wanted; one to Max_Gather of them.
   --  @param Count How many of Members are meant.
   --  @param Added False when the sequence is full, when there are no
   --    members or too many, when a member is past the stack, or when a
   --    chained gather has nothing to chain to.
   --  @param Key Identifies the stack so the device may keep it.
   --  @param Kept False when nothing on the host reads this step's answer.
   --  @param Chained Whether this reads a step's result rather than the
   --    caller's activation.
   --  @param From_Step Which step's result to read when chained, or zero
   --    for the one before.
   --  @param Apart How far apart the members' own vectors begin, or zero.
   --  @param Routed A routing step whose choice replaces Members, so that
   --    the experts a token reads are decided where the router ran; or
   --    zero for Members. Count is then how many that step chose.
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
      Routed    : Natural := 0);

   --  Name a mixture's routing for a sequence to perform.
   --
   --  Reads the step it names -- a router's product, Experts scores a
   --  position -- and writes, for each position, the Used experts chosen
   --  and their shares: a softmax over every expert, the largest Used in
   --  order, the shares put back on a scale where they sum to one, which
   --  is what every mixture this program runs does on the host. The words
   --  it writes are what a gathered product routed on it and the mixing
   --  step after read.
   --
   --  @param Steps Sequence to add to.
   --  @param Experts Scores a position holds.
   --  @param Used How many to choose.
   --  @param Added False when the sequence is full, when there is nothing
   --    to read, or when Used is more than a gather may take.
   --  @param From_Step Which step's result to read, or zero for the one
   --    before.
   --  @param Kept False when nothing on the host reads the choice.
   --  @param Bias Where a bias added before the choosing begins, or null.
   --  @param Bias_Span Bytes the storage the bias lies in holds.
   --  @param Bias_At Where in that storage the bias begins.
   procedure Add_Route
     (Steps     : in out Sequence;
      Experts   : Natural;
      Used      : Natural;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Kept      : Boolean := True;
      Bias      : System.Address := System.Null_Address;
      Bias_Span : Model_Runner.Bytes.Byte_Count := 0;
      Bias_At   : Model_Runner.Bytes.Byte_Count := 0);

   --  Name the inversion of a batch's routing for a sequence to perform.
   --
   --  invert.comp turns what the routing step wrote -- each position's
   --  experts and shares -- into each expert's run of positions and
   --  shares, with a count and a start an expert and, for each position
   --  and rank, the slot it was given: what a listed product walks and a
   --  listed mix reads back. A token's mixture gathers its few experts
   --  straight from the routing and needs none of this; a batch's runs
   --  every expert over the positions that chose it, one dispatch a
   --  matrix, and this is what tells each expert's workgroups which.
   --
   --  @param Steps Sequence to add to.
   --  @param Experts How many experts the routing chose among.
   --  @param Used How many each position chose.
   --  @param Route_Step The routing step.
   --  @param Added False when the sequence is full or the step named is
   --    not a routing step of that shape.
   --  @param Kept False when nothing on the host reads the lists.
   procedure Add_Invert
     (Steps      : in out Sequence;
      Experts    : Natural;
      Used       : Natural;
      Route_Step : Positive;
      Added      : out Boolean;
      Kept       : Boolean := False);

   --  Name one product of every expert of a stack over the positions that
   --  chose it, for a sequence to perform.
   --
   --  The batch's counterpart of Add_Gathered_Product: the third
   --  dimension of the dispatch is the expert, and each expert's
   --  workgroups walk the run of positions the inverted routing in
   --  Invert_Step gives it, a group of vectors at a time, writing every
   --  answer at the position's slot in the runs -- Each rows a slot, Used
   --  slots a position, laid run after run -- rather than at the
   --  position. Reading by position takes each vector from the step in
   --  From_Step at the position the list names, which is what the gate
   --  and the up do; reading by slot takes it at the slot, which is what
   --  the down does with the combined arms before it.
   --
   --  @param Steps Sequence to add to.
   --  @param Base Storage the stack lies in, as for Add_Gathered_Product.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where the stack begins in it.
   --  @param Packing How the rows are packed.
   --  @param Stack Rows the whole stack holds.
   --  @param Each Rows each expert's slice holds.
   --  @param Columns Columns of every row.
   --  @param Experts How many experts the stack holds and the dispatch
   --    covers; Each times Experts may not exceed Stack.
   --  @param Used How many experts each position chose, which is how
   --    many slots a position has in the runs.
   --  @param Invert_Step The inversion of the routing.
   --  @param Count Positions the batch holds, which with Used and Experts
   --    bounds the slots the runs take: each expert's run is padded to
   --    sixteen, and the step's room is sized for the most padding there
   --    can be.
   --  @param Added False when the sequence is full or a step named is not
   --    what it should be.
   --  @param Key Where these weights live; what later products name.
   --  @param Kept False when nothing on the host reads the answer.
   --  @param From_Step The step whose result the vectors are read from.
   --  @param By_Slot True to read a vector at its slot rather than at the
   --    position the list names.
   --  @param Chained False to read the vectors from the activation the
   --    caller supplied rather than from a step.
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
      Chained     : Boolean := True);

   --  Name a mixture's weighted sum for a sequence to perform.
   --
   --  Reads the gathered projection down in Downs_Step -- Used slices of
   --  Width a position -- and the shares the routing step in Route_Step
   --  wrote, and writes each position's sum, best expert first, with the
   --  residual in Residual_Step added after: the layer's second join,
   --  folded in. Where Route_Step names an inversion and Downs_Step a
   --  listed product, each position's answers are found by their slots
   --  and weighed by the shares the inversion laid beside them.
   --
   --  @param Steps Sequence to add to.
   --  @param Width Components a position's answer holds.
   --  @param Used How many slices are summed.
   --  @param Downs_Step The gathered projection down.
   --  @param Route_Step The routing step.
   --  @param Added False when the sequence is full or a step named is not
   --    there or not what it should be.
   --  @param Residual_Step The step whose result is added, or zero for
   --    none.
   --  @param Kept False when nothing on the host reads the answer.
   procedure Add_Mix
     (Steps         : in out Sequence;
      Width         : Natural;
      Used          : Natural;
      Downs_Step    : Positive;
      Route_Step    : Positive;
      Added         : out Boolean;
      Residual_Step : Natural := 0;
      Kept          : Boolean := True);

   --  Name a step that adds each expert's bias to what a gathered product
   --  made of a position: the answer of every member with the slice of
   --  the bias stack belonging to the expert that member is, as the host
   --  adds a projection's bias before the gate and after the projection
   --  down. Which expert each member is comes from the routing the
   --  product was gathered by -- a token's routing step, or a batch's
   --  inversion, whose slots the members lie in. The stack is Experts
   --  slices of Each, resident as a norm's weight is, and the answers
   --  written are laid out as the product's were, so what read the
   --  product reads this instead.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the stack lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the stack begins.
   --  @param Experts How many slices the stack holds.
   --  @param Each Elements a slice holds, which is a member's answer.
   --  @param Source_Step The gathered or listed product whose answers
   --    the biases are added to.
   --  @param Route_Step The routing step, or the inverting step, the
   --    product was gathered by -- or zero for a bias that is no
   --    expert's: one slice of Each, added to every row the source made,
   --    which is what a projection's bias is. Experts is one then, and
   --    the source a product of Each rows. Or zero with Members given,
   --    for a gather whose members the host chose.
   --  @param Added False when the sequence is full, when the source is
   --    not a gathered product of Each a member, or when the routing
   --    step is not one.
   --  @param Key Identifies the stack so the device may keep it.
   --  @param Kept False when nothing on the host reads this step's answer.
   --  @param Members Which experts the source's members are, in the
   --    source's own order, where the host chose them: member m of the
   --    source is expert Members (1 + m mod Count). Count zero reads the
   --    routing step, or none.
   --  @param Count How many of Members are meant.
   --  @param Source_At Row where the fused source this biases begins. With
   --    Source_Stride it slices a fused source: a projection bias over Each
   --    of the source's rows, its own rows lying at Source_At.
   --  @param Source_Stride Gap between the fused source's rows, so every
   --    Source_Stride after Source_At. Both zero is a bias over the whole
   --    source.
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
      Source_Stride : Natural := 0);

   --  Name a step that picks every other stretch of a row.
   --
   --  The hybrid architecture projects each head's queries and a gate for
   --  the head in one tensor, the queries and then the gate, head after
   --  head; the host takes the row apart before anything reads it. This
   --  is that taking apart, on the device: the step reads a row of Among
   --  stretches a group, each Each wide, and writes the Which'th of every
   --  group one after another, a row of Rows -- one call for the queries
   --  and one for the gates.
   --
   --  @param Steps Sequence to add to.
   --  @param Rows Elements a position holds on the way out.
   --  @param Each Elements one stretch holds; Rows is a whole number of
   --    them.
   --  @param Which Which stretch of each group to take, from nought.
   --  @param Among How many stretches a group holds on the way in.
   --  @param Added False when the sequence is full, when the shape does
   --    not hold together, or when the step named does not hold Rows
   --    times Of elements a position.
   --  @param From_Step Step whose result to read, or zero for the step
   --    before this one.
   --  @param Kept False when nothing on the host reads this step's answer.
   procedure Add_Pick
     (Steps     : in out Sequence;
      Rows      : Natural;
      Each      : Natural;
      Which     : Natural;
      Among     : Positive;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Kept      : Boolean := True);

   --  What a convolving step and a rule step are told about the linear
   --  layer they are part of, beyond the step's own rows and columns.
   type Linear_Shape is record
      --  Elements a mixed row holds, and the state's width, which is a
      --  block of the row and a head of the state.
      Mix        : Natural := 0;
      Head       : Natural := 0;

      --  The convolution's taps, and the blocks scaled to unit length.
      Taps       : Natural := 0;
      Unit_Blocks : Natural := 0;

      --  The key heads and the value heads, and the elements the queries
      --  or the keys take in a row.
      Key_Heads   : Natural := 0;
      Value_Heads : Natural := 0;
      Key_Width   : Natural := 0;

      --  The ring: where the layer's memory or state begins within a
      --  slot, and how many elements a slot holds, in elements of the
      --  state buffer.
      Region_At  : Natural := 0;
      Every      : Natural := 0;

      --  The runs of the batch, each one session's: where the table
      --  begins in the state buffer, in elements, and how many runs it
      --  names. Five words a run, as the bits of floats: where the
      --  session's ring begins, the position the run starts at, how
      --  many rows it has, which row of the batch is its first, and how
      --  many slots the ring has. A batch is one run; a round of
      --  sessions is one a member.
      Table_At   : Natural := 0;
      Runs       : Positive := 1;

      --  The rule's other rows, named as steps: the gate, the alphas
      --  and the betas.
      Z_Step     : Natural := 0;
      Alpha_Step : Natural := 0;
      Beta_Step  : Natural := 0;

      --  The scale on the rule's answer and the stabilizer under its
      --  mean square, which is the unit length's floor for the front.
      Scale      : Model_Runner.Numerics.Real := 0.0;
      Epsilon    : Model_Runner.Numerics.Real := 0.0;
   end record;

   --  Name the front of a hybrid's linear layer: the causal convolution
   --  over each position and the ones remembered, the unit, and the
   --  query and key heads to unit length.
   --
   --  The step reads the mixed rows of the step it names, the taps as a
   --  weight the device keeps -- Taps rows of Mix, the oldest tap first,
   --  named in Base, Span and At_Byte -- and the memory of Taps - 1 rows
   --  the layer left in the slot of the state buffer the ring says, and
   --  writes the convolved rows as its answer and each position's memory
   --  into the slot the position after it reads. The ring's arithmetic
   --  is the host's: a run's ring is slots of Every elements from the
   --  base the table names, a position's slot being the position modulo
   --  the slots, the memory of this layer at Region_At within one.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the taps lie in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the taps begin.
   --  @param Shape The layer's geometry and the ring.
   --  @param Added False when the sequence is full, when the shape does
   --    not hold together, or when the step named does not hold Mix
   --    elements a position.
   --  @param From_Step Step whose rows to convolve, or zero for the step
   --    before this one.
   --  @param Key Identifies the taps so the device may keep them.
   --  @param Kept False when nothing on the host reads this step's answer.
   procedure Add_Conv
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Shape     : Linear_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True);

   --  Name the gated delta rule of a hybrid's linear layer, a value head
   --  at a time over the batch in order.
   --
   --  The step reads the convolved rows of the step it names, the gate,
   --  alpha and beta rows of the steps Shape names, the weight the
   --  device keeps -- A_log a value head, dt's bias a value head, then
   --  the gain a column, in Base, Span and At_Byte -- and the state of
   --  every value head in the slot of the state buffer the ring says; it
   --  writes each position's answer, Value_Heads heads of Head, and the
   --  states the ring keeps -- a run's last Slots positions', each into
   --  the slot the position after it reads. The run goes in chunks of
   --  sixteen positions unrolled from the state each began with, as the
   --  host's rule goes: the same numbers, associated as its triangles
   --  are.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the weight lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the weight begins.
   --  @param Shape The layer's geometry, the ring and the other rows.
   --  @param Added False when the sequence is full, when the shape does
   --    not hold together, or when a step named holds the wrong rows.
   --  @param From_Step Step whose rows the rule reads, or zero for the
   --    step before this one.
   --  @param Key Identifies the weight so the device may keep it.
   --  @param Kept False when nothing on the host reads this step's answer.
   procedure Add_Rule
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Shape     : Linear_Shape;
      Added     : out Boolean;
      From_Step : Natural := 0;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True);

   --  Name one product that reads what the product before it produced.
   --
   --  This is the point of a sequence rather than a convenience on top of it.
   --  Products of the same activation save submissions because they may all
   --  go at once; a chained product saves something different and larger --
   --  what it reads never leaves the device. Without chaining, the only way
   --  to feed one product's result to the next is to bring it back, hand it
   --  to the caller, and send it again.
   --
   --  A barrier stands between a chained product and the one before it,
   --  because the second reads what the first wrote. Products that are not
   --  chained have no barrier between them and do not need one.
   --
   --  The activation this reads is the previous product's whole result, so
   --  its column count must be that product's row count. A sequence whose
   --  first product is chained has nothing to chain to and is refused.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the matrix lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the matrix begins.
   --  @param Packing How each row is packed.
   --  @param Rows Number of rows.
   --  @param Columns Number of columns, which must be the previous
   --    product's row count.
   --  @param Added False when the sequence is full, when there is nothing to
   --    chain to, or when the widths do not meet.
   --  @param Key Identifies the matrix so the device may keep it.
   --  @param Kept False when nothing on the host reads this step's answer,
   --    which saves Run the copy back and leaves it where the step after it
   --    will read it.
   --  @param From_Step Which step's result to read, counting from one, or
   --    zero for the step immediately before this one. A layer's
   --    feed-forward reads the normalization twice, and its second arm is
   --    not the step before it.
   procedure Add_Chained_Product
     (Steps     : in out Sequence;
      Base      : System.Address;
      Span      : Model_Runner.Bytes.Byte_Count;
      At_Byte   : Model_Runner.Bytes.Byte_Count;
      Packing   : Weight_Packing;
      Rows      : Natural;
      Columns   : Natural;
      Added     : out Boolean;
      Key       : System.Address := System.Null_Address;
      Kept      : Boolean := True;
      From_Step : Natural := 0);

   --  Name a step that combines the two results before it.
   --
   --  The middle of a gated feed-forward: a unit on the first arm, multiplied
   --  elementwise by the second. On its own this is nothing -- a few thousand
   --  multiplications beside matrix products of millions -- and it is here for
   --  what it lets stand around it. With the combining on the device, the
   --  projection that reads the combined value can be chained to it, so a
   --  gated block's three matrices reach the device in one submission rather
   --  than two, and neither arm ever comes back.
   --
   --  The two steps before this must have the same row count, since they are
   --  combined elementwise. A sequence with fewer than two steps behind it
   --  has nothing to combine and is refused.
   --
   --  @param Steps Sequence to add to.
   --  @param Unit Which unit to apply to the first arm: zero for the
   --    sigmoid-weighted one, one for the Gaussian one in its tanh form,
   --    three for the clamped gate that reaches the second arm too -- the
   --    first held at Limit and passed through the logistic at a slope of
   --    Alpha, the second held at the limit either side and raised by one,
   --    the two multiplied. Four and five are the first two alone, on the
   --    one step before this and multiplied by nothing, which is the
   --    feed-forward of an architecture without a gate; one step behind
   --    is enough for those. Six is the logistic of the first arm
   --    multiplied by the second, elementwise: the gate beside each head
   --    that the hybrid architecture puts on what attention produced.
   --    Seven is the first arm scaled by the logistic of one number a
   --    position, read from a second arm that holds one element a
   --    position: a hybrid mixture's shared expert, by its own router's
   --    score.
   --  @param Added False when the sequence is full, when there are not two
   --    steps to combine, or when their rows do not match.
   --  @param Kept False when nothing on the host reads this step's answer,
   --    which saves Run the copy back and leaves it where the step after it
   --    will read it.
   --  @param Alpha The clamped gate's slope; unread by the other units.
   --  @param Limit The clamped gate's limit; unread by the other units.
   --  @param From_Step The first arm, named, or zero for the step two
   --    before this one -- the one before, for a unit alone.
   --  @param Other_Step The second arm, named, or zero for the step
   --    before this one. Both named or neither.
   procedure Add_Combination
     (Steps : in out Sequence;
      Unit  : Natural;
      Added : out Boolean;
      Kept  : Boolean := True;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      From_Step  : Natural := 0;
      Other_Step : Natural := 0);

   --  Name a residual join for a sequence to perform.
   --
   --  The same two arms in and one out that a combination has, adding them
   --  rather than putting a unit on the first: a layer joins twice and each
   --  of those is what the host used to do between one submission and the
   --  next. One arm is a step's result and the other is the residual, which
   --  travels beside the activation the caller supplies rather than in a
   --  buffer of its own.
   --
   --  @param Steps Sequence to add to.
   --  @param From_Step Step whose result is the second arm, or zero for the
   --    step before this one.
   --  @param From_Vector Where the residual begins in the caller's
   --    activation, in elements, when Residual_Step is zero.
   --  @param Residual_Step Step whose result is the residual, or zero to
   --    take it from the caller's activation.
   --  @param Added False when the sequence is full or there is nothing to
   --    join.
   --  @param Kept False when nothing on the host reads this step's answer.
   procedure Add_Join
     (Steps         : in out Sequence;
      Added         : out Boolean;
      From_Step     : Natural := 0;
      From_Vector   : Natural := 0;
      Residual_Step : Natural := 0;
      Kept          : Boolean := True);

   --  How a model pairs the components a rotation turns.
   type Rotary_Pairing is (Interleaved, Split);

   --  Name a rotary position encoding for a sequence to perform.
   --
   --  The turning only. Every architecture turns by a different angle -- the
   --  stretch a file states, its ramp, a divisor table, an attenuation --
   --  and none of that is on the device: the caller tabulates a cosine and
   --  a sine for each pair of each position, which is thirty-two numbers a
   --  position against the couple of thousand multiply-adds done with them,
   --  and hands the table over with the step. What varies between models
   --  stays written once, on the host.
   --
   --  The table is two numbers a pair a position, wide ones, a cosine and
   --  the sine after it, positions in the order the batch holds them.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the table lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the table begins.
   --  @param Width Components a position holds.
   --  @param Heads How many heads that is.
   --  @param Rotary How many components of a head turn.
   --  @param Pairing Which two components make a pair.
   --  @param Added False when the sequence is full, when the shape does not
   --    hold together, or when there is nothing to turn.
   --  @param From_Step Which step's result to turn, or zero for the step
   --    before this one -- and for a rotation first in a sequence, the
   --    caller's own activation.
   --  @param Kept False when nothing on the host reads this step's answer.
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
      Kept      : Boolean := True);

   --  Name a heads step for a sequence to perform.
   --
   --  The queries or the keys of a layer, made ready between their
   --  projection and the attention in one dispatch instead of three or
   --  six: each head normalized over its own mean square and by a weight
   --  one head wide where the architecture states one, turned by the
   --  caller's table as Add_Rotation turns, and -- for the keys -- placed
   --  in the cache as Add_Place places, the values placed beside them as
   --  they are. A workgroup to a head of a position, and the arithmetic
   --  is the arithmetic of the three steps it stands for, in the same
   --  order and the same precision.
   --
   --  @param Steps Sequence to add to.
   --  @param From_Step The projection to read: the queries, or the keys.
   --  @param Heads How many heads that projection holds.
   --  @param Head_Size How wide a head is; at most 256.
   --  @param Rotary How many components of a head turn.
   --  @param Pairing Which two components make a pair.
   --  @param Table First byte of the angle table, as Add_Rotation takes it.
   --  @param Table_Span Bytes that table holds.
   --  @param Epsilon The floor under the mean square, where normalized.
   --  @param Added False when the sequence is full or the shape does not
   --    hold together.
   --  @param Weight First byte of the storage the head weight lies in, or
   --    null for heads that are not normalized.
   --  @param Weight_Span Bytes that storage holds.
   --  @param Weight_At Where in that storage the weight begins.
   --  @param Key Identifies the weight so the device may keep it.
   --  @param Into_Cache Whether the answer goes into the cache rather
   --    than the step's own room -- the keys -- at At_First, Stride
   --    apart, in both precisions.
   --  @param At_First Where the first position's keys go in the cache.
   --  @param Stride How far apart positions' keys are in the cache.
   --  @param V_Step The values' projection, placed beside the keys, or
   --    zero for none.
   --  @param V_At_First Where the first position's values go.
   --  @param V_Stride How far apart positions' values are.
   --  @param Kept False when nothing on the host reads the answer, which
   --    for keys placed in the cache is always.
   --  @param Pages_At A cache in pages: where the batch's page table for
   --    this layer begins, in elements. At_First and V_At_First are then
   --    offsets inside a page. Zero with Page_Shift for a cache in
   --    blocks.
   --  @param Page_Shift The page's width in positions, as a shift; zero
   --    for a cache in blocks.
   --  @param First_Position Which position of its session the batch's
   --    first row is, for a cache in pages.
   --  @param Source_At Where this step's main stream begins in From_Step,
   --    in rows, when From_Step is a fused product of the three projections;
   --    zero reads it from the front.
   --  @param Source_Stride How far apart two positions lie in a fused
   --    From_Step, in rows -- the whole fused row count, not this stream's;
   --    zero is the ordinary source, a position Heads * Head_Size apart.
   --  @param V_Source_At Where the values begin in a fused V_Step, in rows.
   --  @param V_Source_Stride A fused V_Step's per-position stride, in rows;
   --    zero reads the values a width apart from their own step.
   --  @param V_Row_Count The values' own row count where V_Step is a fused
   --    slice and its whole row count is not the values'; zero takes it from
   --    the step.
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
      V_Row_Count     : Natural := 0);

   --  Name a write into the device's cache for a sequence to perform.
   --
   --  The keys and the values a layer produced belong in the cache before
   --  anything attends to them, and the host used to put them there --
   --  which is what makes a layer two submissions rather than one, since
   --  nothing between them can be recorded until the host has been round.
   --
   --  The host still reads them back for its own arrays. What this saves is
   --  the round trip, not the copy.
   --
   --  @param Steps Sequence to add to.
   --  @param Width Elements a position holds.
   --  @param Stride How far apart one position is from the next in the
   --    cache, which is every head's worth and not just this layer's.
   --  @param At_First Where the first position goes, in elements.
   --  @param Added False when the sequence is full, when the shape does not
   --    hold together, or when the engine holds no cache.
   --  @param From_Step Which step's result to write, or zero for the step
   --    before this one.
   --  @param Packed How the rows are packed, for a packed session's block:
   --    the step then rounds each row to bytes or nibbles and a scale as
   --    the host rounds it, through pack.comp, and At_First and Stride go
   --    unread; a round's rows go each to its own block, out of the
   --    table. Run refuses the sequence where the device has no such
   --    kernel.
   --  @param Unpack True to read packed rows and write them as halves
   --    into the copy instead: Packed says how the rows are packed and
   --    where the first is, Width how wide a row is, Half_At where the
   --    first row's halves go, and Count -- given to Run -- is not how
   --    many rows; Cells is. The step reads the cache alone, so From_Step
   --    names the step whose writing it must wait for; At_First and
   --    Stride go unread.
   --  @param Cells How many rows an unpacking step unpacks.
   --  @param Half_At Where an unpacking step writes the first row, in
   --    halves of the cache buffer.
   --  @param Pages_At A cache in pages: where the batch's page table for
   --    this layer begins, in elements, and At_First then the layer's
   --    offset inside a page. A round's rows carry their own tables in
   --    the per-row table, where a block's base was. Zero with
   --    Page_Shift for a cache in blocks.
   --  @param Page_Shift The page's width in positions, as a shift; zero
   --    for a cache in blocks.
   --  @param First_Position Which position of its session a batch's
   --    first row is, for a cache in pages.
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
      First_Position : Natural := 0);

   --  Name a root-mean-square normalization for a sequence to perform.
   --
   --  It is here for the submission it saves rather than for itself: a
   --  layer normalizes twice, each of a few thousand elements against
   --  products of millions, and the host doing them is the host needing the
   --  products back. The weight is a tensor of the model and is named the
   --  way a matrix is, so the device keeps it resident the same way.
   --
   --  The sum is walked in order and accumulated in binary64, which is what
   --  the processor's does: a tree reduction would associate differently
   --  and a layer's normalization feeds everything after it.
   --
   --  @param Steps Sequence to add to.
   --  @param Base First byte of the storage the weight lies in.
   --  @param Span Bytes that storage holds.
   --  @param At_Byte Where in that storage the weight begins.
   --  @param Width Components a position holds.
   --  @param Epsilon The floor under the mean square.
   --  @param Added False when the sequence is full.
   --  @param Groups How many stretches of Width / Groups a position is
   --    normalized as, each over its own mean square and by the same
   --    weight of that length. One is the whole position, which is what a
   --    layer's two normalizations want; a head at a time is what an
   --    architecture that normalizes its queries and keys wants, and the
   --    weight it carries is one head wide.
   --  @param From_Step Step whose result to normalize, or zero for the step
   --    before this one.
   --  @param Key Identifies the weight so the device may keep it.
   --  @param Kept False when nothing on the host reads this step's answer.
   --  @param Shift True for the centred normalization with a shift that
   --    GPT-2, Phi-2, Falcon and Bert state: the position's mean is taken
   --    off before the mean square, and the weight is two stretches, the
   --    gain and then the shift, added after the gain. Refused with
   --    Groups other than one.
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
      Shift     : Boolean := False);

   --  Name an attention step for a sequence to perform.
   --
   --  This is what lets a layer's attention stop being a submission of its
   --  own. A call to a device costs 82.7 microseconds before it computes
   --  anything -- measured at a shape whose arithmetic runs at 0.05 Gflop/s
   --  and is therefore nearly all call -- and attention submitted alone pays
   --  that once a layer on top of what the products around it pay. Recorded
   --  here, the blend it writes never leaves the device either: the
   --  projection that reads it chains to it.
   --
   --  The queries are the activations given to Run, one position after
   --  another, and Run's Count is how many positions attend -- so a batch
   --  evaluates as one dispatch, as it does through Attend_Resident. The
   --  cache is the one the device already holds, which Reserve made room for
   --  and Put_Cache wrote; a sequence with an attention step and no cache is
   --  refused rather than run against nothing.
   --
   --  @param Steps Sequence to add to.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first of them may look at.
   --  @param Last Last cached position the first of them may look at.
   --    Position p of a batch looks to Last + p.
   --  @param K_Base Where the keys begin.
   --  @param V_Base Where the values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Added False when the sequence is full or the shape is refused.
   --  @param Window This layer's sliding window, or zero where it does not
   --    slide one, which a batch needs because First can only speak for one
   --    position and a window moves with each of them.
   --  @param Chained True to read the queries from what the step before it
   --    wrote rather than from the activation given to Run, so they never
   --    leave the device. The engine cannot use this yet -- it rotates the
   --    queries and writes the position's keys and values on the processor,
   --    between the product that makes them and the attention that reads
   --    them -- and it is here to measure what moving that work would be
   --    worth before it is moved.
   --  @param Causal True where a position may see only what precedes it,
   --    which is every model that generates. False where it sees the whole
   --    text, and every position then attends to Last rather than to Last
   --    plus its own place in the batch.
   --  @param Kept False when nothing on the host reads this step's answer,
   --    which saves Run the copy back and leaves it where the step after it
   --    will read it.
   --  @param From_Step Which step the queries come from, or zero for the
   --    step before this one. A layer named whole rotates them several
   --    steps before it attends with them.
   --  @param Packed The session's packed block, where it has one: the
   --    step then binds the packed kernel over it, with K_Base and V_Base
   --    unread, and Run refuses the sequence where the device has no such
   --    kernel or the block's bases and widths are not multiples of four.
   --  @param Sinks_At Where the heads' sinks begin in the cache, counted
   --    in elements, for an architecture that learned one a head: a score
   --    that joins the softmax's denominator and takes no value. Zero for
   --    a layer without them. The caller puts Heads of them there before
   --    the sequence runs, as it puts a round's table.
   --  @param Pages_At A cache in pages: where a batch's page table for
   --    this layer begins, in elements -- a word a page, each the element
   --    that page starts at -- and K_Base and V_Base then offsets inside
   --    a page. A round's rows carry their own tables in the per-row
   --    table, where a block's base was. Zero with Page_Shift for a
   --    cache in blocks.
   --  @param Page_Shift The page's width in positions, as a shift; zero
   --    for a cache in blocks.
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
      Page_Shift : Natural := 0);

   --  Perform every product a sequence holds, in the order they were named.
   --
   --  An unchained product reads the activation given here; a chained one
   --  reads what the product before it produced, without that ever leaving
   --  the device. Each writes its own result, one after another into Target:
   --  a sequence naming two matrices of R rows fills the first R values from
   --  the first and the next R from the second. A sequence of one fills
   --  Target exactly as the single call does.
   --
   --  @param Item Ready engine.
   --  @param Steps Sequence to perform.
   --  @param Vectors Count activations, one after another.
   --  @param Count How many activations each product is given.
   --  @param Target Receives every product's rows, product by product.
   --  @param Ok True when the device computed all of them.
   --  @param Cancelled True when a caller asked to stop partway.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  @param Carry_In True where the activation this sequence reads is
   --    the one the sequence before it left on the device, rather than
   --    Vectors. Vectors is then not sent over at all.
   --  @param Carry_Out True where the last step's answer is to be left on
   --    the device for the next sequence to read, rather than copied back
   --    into Target.
   --
   --  A layer's answer is the next layer's activation, and between them it
   --  went to the host and came back: a megabyte a layer out of the mapped
   --  result buffer and the same megabyte over again. Carried, neither
   --  happens -- the answer stays where the device wrote it, in room the
   --  result buffer keeps at its front for exactly this, and the next
   --  sequence reads it there.
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
      Carry_Out : Boolean := False);

   --  The activation the last sequence left on the device, read back.
   --
   --  A sequence that carries out leaves the host's copy of the activation
   --  behind, and a sequence that then cannot run -- a matrix the budget
   --  has no room for while the one before is still reading the others --
   --  hands the layer back to the host, which must start from what the
   --  device holds and not from what it last saw. Everything in flight is
   --  waited for first.
   --
   --  @param Item Ready engine.
   --  @param Target Receives the activation, as many elements as it holds.
   --  @param Ok True when it was read.
   procedure Fetch_Carried
     (Item   : in out Engine;
      Target : out Model_Runner.Numerics.Real_Array;
      Ok     : out Boolean);

   --  One position attending to everything a cache holds.
   --
   --  The scores against every key in range, the bound where the architecture
   --  states one, the softmax across them, and the values weighted by what
   --  comes out. This is the piece of a layer that stands between two matrix
   --  products; while it is on the processor the products on either side of
   --  it cannot be sent together.
   --
   --  Keys and values are given as one array because the kernel reads them
   --  from one buffer: attention wants four arrays and the layout carries
   --  three. Where they lie inside it is said by K_Base and V_Base.
   --
   --  This uploads the cache on every call, so it is not yet faster than
   --  doing it on the processor -- it exists to be checked against the
   --  processor first. What makes it worth having is the cache staying on the
   --  device between calls, which is a change to where the cache lives rather
   --  than to this.
   --
   --  @param Item Ready engine.
   --  @param Cache Keys and values, in one array.
   --  @param Query This position's queries, one head after another.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position that may be looked at.
   --  @param Last Last cached position that may be looked at.
   --  @param K_Base Where the keys begin in Cache.
   --  @param V_Base Where the values begin in Cache.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by before the bound.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Target Receives Positions * Heads * Value_Size values.
   --  @param Ok True when the device computed it.
   --  @param Positions How many positions attend in this call, whose
   --    queries follow one another in Query and whose blends follow one
   --    another in Target. Position p looks back to Last + p.
   --  @param Window This layer's sliding window, or zero where it does not
   --    slide one, which a batch needs because First can only speak for one
   --    position and a window moves with each of them.
   --  @param Causal True where a position may see only what precedes it,
   --    which is every model that generates. False where it sees the whole
   --    text, and every position then attends to Last rather than to Last
   --    plus its own place in the batch.
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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  Make room on the device for a cache and keep it between calls.
   --
   --  Uploading the whole cache for every call is most of what an attention
   --  call costs -- a per-call floor of 0.42 ms against a processor that does
   --  the whole layer in 0.85 ms -- and a cache written a position at a time
   --  and read where it lies removes it.
   --
   --  @param Item Ready engine.
   --  @param Elements How many values, keys and values together.
   --  @param Copy_Upto How far into that the half-precision copy must
   --    reach, in elements: the highest element anything on this device
   --    will read a half of. A block whose session keeps an exact cache
   --    has a half of every element of it; one kept packed has no copy of
   --    itself, and what it uses the copy for is the room a layer's rows
   --    unpack into for the matrix instruction, which is a fraction of
   --    the block at its front. Nought where nothing reads halves at all,
   --    and then no copy is taken.
   --  @param Ok True when the room is there. False where the device has
   --    no room, and where the cache with its half-precision copy --
   --    six bytes an element -- would be larger than what the device
   --    says one storage buffer may hold, which Byte_Limit reports: a
   --    descriptor naming a range past that bound reads undefined
   --    values rather than being refused by the driver.
   --  @param Allow_Copy_Only Where the cache proper alone would not fit one
   --    storage buffer but its half-precision copy would, keep only the
   --    copy: the caller states this where nothing reads the cache proper
   --    -- a model with no sinks, whose attention is the matrix kernel and
   --    reads only the copy. The copy is two bytes an element to the
   --    cache's four, so a context past what six bytes fits is held where
   --    two do, and the kernels that write the cache proper are told to
   --    skip it. False keeps the old both-or-neither rule.
   --  @param Keys_Upto Where the keys end and the values begin in the
   --    copy, in halves: past it the split copy keeps a buffer of its own,
   --    so that neither half is past what one may hold. Zero asks for no
   --    split.
   procedure Reserve
     (Item            : in out Engine;
      Elements        : Model_Runner.Numerics.Element_Count;
      Copy_Upto       : Model_Runner.Numerics.Element_Count;
      Ok              : out Boolean;
      Allow_Copy_Only : Boolean := False;
      Keys_Upto       : Model_Runner.Numerics.Element_Count := 0);

   --  Write bytes into that cache, as they are.
   --
   --  A packed session's rows: its keys and values as the bytes and
   --  nibbles the host rounded them to, and its scales as floats, which
   --  the packed attention kernel reads back. Nothing is converted and
   --  no half-precision copy is written, since the copy is the exact
   --  cache's and a packed block has none.
   --
   --  @param Item Ready engine.
   --  @param At_Byte Where in the cache the bytes go, in bytes.
   --  @param Data What to write.
   --  @param Ok True when it was written.
   procedure Put_Bytes
     (Item    : in out Engine;
      At_Byte : Interfaces.Unsigned_64;
      Data    : Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean);

   --  Whether a batch of this many positions with heads these wide
   --  attends through the matrix instruction, over the half-precision
   --  copy: what an exact session's batch takes where the device has the
   --  instruction and the batch is long enough for its tile, and what a
   --  packed session's may take over its layer unpacked into the copy.
   --
   --  @param Item Engine to ask.
   --  @param Positions How many positions attend at once.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @return True where the matrix kernel would be bound.
   function Attends_By_Matrix
     (Item       : Engine;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean;

   --  Where the half-precision copy begins, in halves of the buffer it
   --  is in. Nought, the copy having a buffer of its own; kept as a
   --  question rather than written down as nought by its callers,
   --  because where the copy begins is the copy's business and it has
   --  been two things already.
   --
   --  @param Item Engine to ask.
   --  @return The copy's first half, in halves.
   function Copy_At (Item : Engine) return Interfaces.Unsigned_64;

   --  And bytes back out of it, as they are: a packed session's rows and
   --  scales the device packed itself, which is how the host's copy of a
   --  packed block is brought up to date at the end of a token or a batch.
   --
   --  @param Item Ready engine.
   --  @param At_Byte Where in the cache the bytes begin, in bytes.
   --  @param Data Receives what is there.
   --  @param Ok False where there is no cache or it is too small.
   procedure Get_Bytes
     (Item    : Engine;
      At_Byte : Interfaces.Unsigned_64;
      Data    : out Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean);

   --  Attend, on the device, over a cache kept packed: a byte an element
   --  with a scale a row, or a nibble an element with a scale a block of
   --  thirty-two, laid out in the cache buffer as the host lays its own --
   --  the keys' bytes, the values' bytes, the key scales and the value
   --  scales, each where the caller says. The arguments Attend_Resident
   --  takes, with the bases in bytes for the rows and in floats for the
   --  scales, and how many bits an element.
   --
   --  Through one kernel of its own: a workgroup eight rows sharing one
   --  group's keys and values -- heads of a position, or positions of a
   --  head -- the positions a tile of sixty-four at a time with the
   --  softmax carried along, a row read a word at a time. One slice and
   --  no round here; a sequence's step cuts a token's long cache into
   --  slices and merges them, and reads a round's table. The caller keeps
   --  a value head wider than Attention_Room, a layer with sinks, and a
   --  base or width that is not a multiple of four on the host. The kernel joins a tile through
   --  subgroup operations, so a device without them has no kernel and
   --  Attends_Packed says so.
   --
   --  @param Item Ready engine.
   --  @param K_Bits Eight or four, for the keys.
   --  @param V_Bits The same for the values, which may differ.
   --  @param Query The queries, Positions of them, a head after the other.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first of them may look at.
   --  @param Last Last cached position the first of them may look at.
   --    Position p of a batch looks to Last + p.
   --  @param K_Bytes Where the packed keys begin, in bytes.
   --  @param V_Bytes Where the packed values begin, in bytes.
   --  @param KS_At Where the key scales begin, in floats.
   --  @param VS_At Where the value scales begin, in floats.
   --  @param KV_Width How wide a row of keys is, in elements.
   --  @param V_Width How wide a row of values is, in elements.
   --  @param K_Blocks Scales a row of keys.
   --  @param V_Blocks Scales a row of values.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Target Receives the blend, Positions of them.
   --  @param Ok True when the blend was computed, False where the kernel
   --    is not there or the shape is one it does not take.
   --  @param Positions How many queries, one after the other.
   --  @param Window This layer's sliding window, or zero where it does not
   --    slide one.
   --  @param Causal True where a position may see only what precedes it.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  Whether the packed attention kernel was made.
   --
   --  @param Item Engine to ask.
   --  @return True when Attend_Packed can run.
   function Attends_Packed (Item : Engine) return Boolean;

   --  Whether this device keeps the cache's half-precision copy: the
   --  matrix attention reads it, a round's attention reads it, and a
   --  token reads it where the copy is preferred, so a device with any
   --  of those kernels keeps one and a device with none of them does
   --  not. Two bytes an element against the cache proper's four, which
   --  is a third of what a context takes on the device and was taken
   --  there for nobody.
   --
   --  @param Item Engine.
   --  @return True where a reserved cache has a copy beside it.
   function Keeps_Copy (Item : Engine) return Boolean;

   --  Whether the packed kernel reads heads of this shape, which is the
   --  part of its rule a model decides rather than a session's layout:
   --  it reads four elements of a row at a time out of one word, so a
   --  head is a whole number of fours, and it keeps room for a value
   --  head of Attention_Room at most. A caller that asks before it packs
   --  a cache knows the answer for every layer of the model, since a
   --  model's heads are one shape.
   --
   --  @param Item Engine.
   --  @param Head_Size Elements a key head holds.
   --  @param Value_Size Elements a value head holds.
   --  @return True where the kernel is here and reads them.
   function Takes_Packed_Heads
     (Item       : Engine;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean;

   --  Write whole numbers into that cache.
   --
   --  A round's per-row table, which a kernel reads back with
   --  floatBitsToUint. It goes in the cache because the cache is a buffer
   --  attention already has bound, and a table of two words a row does not
   --  earn a fourth buffer and a descriptor a step.
   --
   --  @param Item Ready engine.
   --  @param At_Value Where in the cache the table begins, in elements.
   --  @param Words What to write.
   --  @param Ok True when it was written.
   procedure Put_Words
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Words    : Word_List;
      Ok       : out Boolean);

   --  Give the cache back, both buffers of it.
   --
   --  A reserve only ever grows: a caller that asked for a long context
   --  and then for short ones left the device holding the long one's
   --  cache, which on a part that shares the host's memory is the
   --  machine's memory held for a session that has closed. The engine
   --  cannot know when that is -- a block is dealt out and kept, and a
   --  session that comes back writes into the one it had -- so the
   --  caller says, when the last block of it has been given up.
   --
   --  Waits for what is in flight, since a buffer a submission is
   --  reading may not be freed under it. The next Reserve makes a new
   --  one and zeroes it, so nothing of what was held is read again.
   --
   --  @param Item Engine.
   procedure Release_Cache (Item : in out Engine);

   --  Write a run of values into that cache.
   --
   --  @param Item Ready engine with a cache reserved.
   --  @param At_Value Where in the cache the run begins.
   --  @param Values What to write there.
   --  @param Ok True when it was written.
   procedure Put_Cache
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean);

   --  And back out of it, which is how the host's own copy of the cache is
   --  brought up to date without the device sending it a layer at a time.
   --
   --  The keys and the values a layer writes used to come back through the
   --  result buffer, step by step, because the host keeps a copy for a
   --  session that later runs on the processor. They are already in the
   --  cache the device holds, and this reads them from there in one go at
   --  the end of a batch instead -- the same bytes and none of the waiting,
   --  and the waiting is what a chained submission cannot do.
   --
   --  @param Item Ready engine with a cache reserved.
   --  @param At_Value Where in the cache to read from, in elements.
   --  @param Values Receives what is there.
   --  @param Ok False where there is no cache or it is too small.
   procedure Get_Cache
     (Item     : Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean);

   --  Make room on the device for a hybrid's linear states and keep it
   --  between calls, as Reserve does for the cache: what is there is
   --  carried over when it grows.
   --
   --  @param Item Ready engine.
   --  @param Elements How many binary32 values, states and memories
   --    together.
   --  @param Ok True when the room is there.
   procedure Reserve_State
     (Item     : in out Engine;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  A stretch inside a block that holds something: where it begins,
   --  counted from the block's base in elements, and how long it is.
   type Block_Run is record
      At_Value : Model_Runner.Numerics.Element_Count := 0;
      Count    : Model_Runner.Numerics.Element_Count := 0;
   end record;

   type Block_Runs is array (Positive range <>) of Block_Run;

   --  Move a block of the cache to another place in it, on the device.
   --
   --  What a block of the cache is moved with when the blocks are packed
   --  forward to close a gap. The host's copy of a session's cache is
   --  what the engine used to write into the new place, which is the
   --  slowest thing per byte this program does and needs the device's own
   --  copy read home first; vkCmdCopyBuffer moves it where it lies, and
   --  the half-precision copy beside it in the same submission.
   --
   --  Only the stretches of it that hold anything: a session of a
   --  2,048-token context that has said twelve tokens holds twelve cells
   --  of every layer, and the rest of its block is the zeros it was made
   --  with. The caller says which stretches those are, since only it
   --  knows how its cache is laid out; one run of the whole block is what
   --  a caller that cannot say asks for.
   --
   --  Source and destination may overlap -- a block moved down by less
   --  than its own width does -- so each run is recorded as regions of
   --  the distance between the two places, front to back, none of which
   --  overlaps its own source.
   --
   --  @param Item Ready engine with a cache reserved.
   --  @param From Where the block begins now, in elements.
   --  @param Into Where it is to begin, which must be below From.
   --  @param Runs What inside it to move, from the block's base.
   --  @param Halves True to move the same runs of the half-precision copy
   --    beside it: a block whose session keeps an exact cache has a half
   --    of every element of it, a packed one uses the copy only as the
   --    room a layer unpacks into, which the next layer writes again.
   --  @param Ok True when the move was recorded and ran.
   procedure Move_Cache
     (Item   : in out Engine;
      From   : Model_Runner.Numerics.Element_Count;
      Into   : Model_Runner.Numerics.Element_Count;
      Runs   : Block_Runs;
      Halves : Boolean;
      Ok     : out Boolean);

   --  The same for the room a hybrid's rings are seated in: a seat moved
   --  to close a gap below it, without the ring coming home and going
   --  back.
   --
   --  @param Item Ready engine with a room reserved.
   --  @param From Where the ring begins now, in elements.
   --  @param Into Where it is to begin, below From.
   --  @param Elements How long the ring is.
   --  @param Ok True when the move was recorded and ran.
   procedure Move_State
     (Item     : in out Engine;
      From     : Model_Runner.Numerics.Element_Count;
      Into     : Model_Runner.Numerics.Element_Count;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  Zero a run of that room, on the device.
   --
   --  A seat is a stretch of the room a session's ring lives in, and a
   --  seat given up is taken again by the next session that needs one --
   --  holding the ring the session before it left. A session with
   --  nothing committed has a ring of nothing, and writing twenty
   --  megabytes of nothing across the bus to say so is six milliseconds
   --  a session here; the device writes its own memory instead, and the
   --  ring is not sent at all.
   --
   --  Waits for what is in flight, since a kernel may be reading the
   --  room.
   --
   --  @param Item Engine with a room reserved.
   --  @param At_Value Where the run begins, in elements.
   --  @param Count How many elements.
   --  @param Ok True when it was zeroed.

   procedure Clear_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  Give that room back, once no session is seated in it.
   --
   --  As the cache is: a room grows to hold every seated session's ring
   --  and never shrank, so a hybrid session with many states kept left
   --  its room on the device until the engine closed -- the machine's
   --  own memory, on a part that shares it. The engine says when the
   --  last seat is given up; nothing here can tell, a seat being kept
   --  for a session that may run again.
   --
   --  Waits for what is in flight, since a buffer a submission is
   --  reading may not be freed under it.
   --
   --  @param Item Engine.
   procedure Release_State_Room (Item : in out Engine);

   --  Write values into that room.
   --
   --  @param Item Ready engine with the room reserved.
   --  @param At_Value Where in the room, in elements.
   --  @param Values What to write.
   --  @param Ok False where there is no room or it is too small.
   procedure Put_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean);

   --  And read them out of it.
   --
   --  @param Item Ready engine with the room reserved.
   --  @param At_Value Where in the room, in elements.
   --  @param Values Receives what is there.
   --  @param Ok False where there is no room or it is too small.
   procedure Get_State
     (Item     : in out Engine;
      At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Numerics.Real_Array;
      Ok       : out Boolean);

   --  Whether the engine made the convolving and rule pipelines.
   --
   --  @param Item Ready engine.
   --  @return True where a hybrid's linear layer may go whole.
   function Runs_Linear (Item : Engine) return Boolean;

   --  Why the last sequence was refused, where it was: its shape is not
   --  one the steps take; an attention step's packed block is not a
   --  shape the packed kernel reads -- a row, a head or a scale run that
   --  is not a whole number of the words it reads at a time -- or the
   --  context is not on the device at all; or the room for it was not
   --  there. A refusal says False and nothing else at every one of its
   --  many doors, and a layer handed back to the processor for a reason
   --  nobody could read was the whole of a token's cost on a fixture
   --  whose keys are four nibbles wide.
   type Refusal is
     (Not_Refused, Shape_Refused, Packed_Refused, Cache_Refused,
      Room_Refused);

   --  @param Item Engine.
   --  @return Why the last Run said False, or Not_Refused after one that
   --    said True.
   function Last_Refusal (Item : Engine) return Refusal;

   --  Forget it, before a caller builds a sequence it may not get to run:
   --  a sequence refused while it is built never reaches Run, and the
   --  answer standing there is the one before's.
   --
   --  @param Item Engine.
   procedure Forget_Refusal (Item : in out Engine);

   --  Whether the packed kernel reads a block of this shape -- the rows,
   --  the heads and the scale runs each a whole number of the words it
   --  reads at a time. A caller that finds it does not knows its layer
   --  will be refused and why, which is the one refusal a reader can act
   --  on: the cache was asked for in a shape this device will not read.
   --
   --  @param Item Engine.
   --  @param Packed How the block is packed.
   --  @param Head_Size Elements a key head holds.
   --  @param Value_Size Elements a value head holds.
   --  @param KV_Width Elements a position's keys hold.
   --  @param V_Width Elements a position's values hold.
   --  @return True where the packed kernel takes it.
   function Takes_Packed
     (Item       : Engine;
      Packed     : Packed_Cache;
      Head_Size  : Natural;
      Value_Size : Natural;
      KV_Width   : Natural;
      V_Width    : Natural) return Boolean;

   --  Attend against the cache the device already holds.
   --
   --  As Attend, without the cache crossing the interface: only the queries
   --  go over and only the blend comes back.
   --
   --  @param Item Ready engine with a cache reserved and written.
   --  @param Query This position's queries, one head after another.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position that may be looked at.
   --  @param Last Last cached position that may be looked at.
   --  @param K_Base Where the keys begin.
   --  @param V_Base Where the values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Target Receives Positions * Heads * Value_Size values.
   --  @param Ok True when the device computed it.
   --  @param Positions How many positions attend in this call. One while
   --    generating; a prompt's worth while evaluating a batch, whose
   --    queries follow one another in Query and whose blends follow one
   --    another in Target. Position p looks back to Last + p.
   --  @param Window How wide this layer's sliding window is, or zero where
   --    it does not slide one. A batch needs it because every position has
   --    its own first, which First cannot say for more than one of them.
   --  @param Causal True where a position may see only what precedes it,
   --    which is every model that generates. False where it sees the whole
   --    text, and every position of the batch then attends to Last rather
   --    than to Last plus its own place in the batch.
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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  The widest value head this kernel will take. One wider is refused, and
   --  the caller does it on the processor: a kernel that wrote past what it
   --  kept would be worse than one that says no.
   --
   --  It is the kernel's own `room`, which went from two hundred and
   --  fifty-six to a hundred and twenty-eight when eight queries a block
   --  landed -- the two multiply into a lane's registers -- and this number
   --  stayed behind. For a hundred days a Gemma, whose value heads are two
   --  hundred and fifty-six wide, passed this guard and had the kernel
   --  write past what it kept: the device answered every Gemma in nonsense
   --  while every fixture, four wide, agreed with the processor to the bit.
   --  The shader check proves the words came from the source; nothing
   --  proved this constant did, which is why it now says where it comes
   --  from. Two hundred and fifty-six again now: the kernel's loops stop
   --  at the width they are given and its reduction takes fewer heads a
   --  turn where the head is wide, so a Gemma's heads fit and a narrower
   --  head costs what it cost. The path four at a time keeps its own
   --  bound of a hundred and twenty-eight, `vroom`, and a wider head goes
   --  a word at a time.
   Attention_Room : constant := 256;

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

   --  The largest buffer this device will read, in bytes.
   --
   --  The device's own answer, and the bound a single matrix has to fit:
   --  one product's weights reach a shader as one buffer. A caller that
   --  wants to say why a product cannot run -- rather than that it did not
   --  -- asks this and compares.
   --
   --  @param Item Engine to inspect.
   --  @return Bytes, or zero when no device is open.
   function Byte_Limit (Item : Engine) return Interfaces.Unsigned_64;

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

   --  How many bytes of context the device is holding.
   --
   --  Zero when the device holds none, which is a different thing from
   --  holding no weights and is the one this program could not say. A
   --  device that has the weights and not the context computes the products
   --  there and attends here, and the only sign of it from outside is that
   --  a run spends processor time it should not need.
   --
   --  @param Item Engine to ask.
   --  @return Bytes of key and value cache resident, or zero for none.
   function Cached_Bytes (Item : Engine) return Interfaces.Unsigned_64;

   --  And how many bytes the room a hybrid's rings of states are seated
   --  in takes, which is the other thing a session holds on the device
   --  and the one a run said nothing about: a ring is every linear
   --  layer's memories and states for as many slots as a session keeps,
   --  tens of megabytes on a model of a few hundred million weights, and
   --  a round of sessions holds one apiece.
   --
   --  @param Item Engine to ask.
   --  @return Bytes of that room, or zero where none is taken.
   function State_Room_Bytes (Item : Engine) return Interfaces.Unsigned_64;

   --  How many values that cache holds room for: the count Reserve was
   --  last asked for and met, keys and values together. The bytes are
   --  more than four times it, since a half-precision copy of every
   --  value lies past the values, so a caller placing something in the
   --  cache by element counts from this and not from the bytes.
   --
   --  @param Item Engine to ask.
   --  @return Values the cache holds room for, or zero for none.
   function Cached_Elements
     (Item : Engine) return Model_Runner.Numerics.Element_Count;

   --  How many matrices one engine will keep, as a count.
   --
   --  Two bounds decide residency and the tighter one wins: this count, and
   --  the byte budget. IT WAS 4,096, AND THE COMMENT HERE SAID THAT WAS
   --  HIGH ENOUGH FOR THE BYTE BUDGET TO BE WHAT ACTUALLY DECIDES. It was
   --  not. A dense model of a few dozen layers has some hundreds of
   --  matrices; a mixture of experts has three a layer FOR EVERY EXPERT,
   --  and the engine takes each expert as its own matrix because that is
   --  what reading eight of a hundred and twenty-eight means. Forty-eight
   --  layers of a hundred and twenty-eight experts is eighteen thousand
   --  four hundred and thirty-two, and at four thousand the count bound
   --  first with two and a half gigabytes of a six-gigabyte budget unspent.
   --  See the README's `### A mixture of experts and a bound on a count`.
   --
   --  It is reported beside the count held, so that a run the count stops
   --  says so rather than printing a number that happens to be its own
   --  bound.
   Max_Resident : constant := 32_768;

private

   --  One descriptor set for every product a sequence may hold.
   --
   --  A descriptor update is not recorded into a command buffer: it takes
   --  effect when the buffer is submitted. With one set, two dispatches
   --  recorded together would both read whatever the last update named, so
   --  a sequence could never be more than a run of separate submissions.
   --  A set per step is what lets one command buffer hold them all, and
   --  they are allocated once with the engine rather than per sequence
   --  because allocating from a pool is the kind of work this exists to
   --  keep out of a layer.
   type Set_Array is array (1 .. Sequence_Limit) of System.Address;

   --  What fraction of the device's largest heap the resident matrices may
   --  take, as a numerator over a denominator. Three quarters: the rest is
   --  for whatever else the device is doing, for the vector and result
   --  buffers, and for the driver's own allocations, none of which this
   --  measures.
   Budget_Share : constant := 3;
   Budget_Whole : constant := 4;

   --  The heaps the weights may be held in: the one the upload kind draws
   --  from, and a second the device may offer, as Context.Second_Kind
   --  describes it. Each has its own share of its own heap, and a matrix
   --  is taken out of the first that has room for it.
   type Tier_Index is range 1 .. 2;
   type Tier_Bytes_Array is array (Tier_Index) of Interfaces.Unsigned_64;

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

      --  Which of the two heaps the memory came out of, one or two, so
      --  that giving it back returns the bytes to the heap that lent them.
      --  Meaningless for an imported matrix, which took neither.
      Tier    : Tier_Index := 1;

      --  Where the host may write it, kept rather than asked for.
      --
      --  The upload mapped the memory, copied and unmapped it, once for
      --  every matrix: three hundred and ninety times a generated token on
      --  a model that does not fit, on the same memory objects over and
      --  over now that a buffer given back is kept. The cache has been
      --  mapped once and held since it was written; this is the same, for
      --  the one thing that still asked the driver every time.
      --
      --  Null for an imported matrix, which is the host's own memory and
      --  was never mapped.
      Mapped  : System.Address := System.Null_Address;

      --  Where this entry sits in the order of last use, and in the chain
      --  of slots nothing is in.
      --
      --  Both were a walk of the whole table: the lookup asked every entry
      --  whether it was the one wanted, and the eviction asked every entry
      --  whether it was the oldest. A mixture's prompt does eighteen
      --  thousand of each over a table twelve thousand long, and the
      --  measurement that found it is that THE PROMPT GOT FASTER AS THE
      --  BUDGET SHRANK -- 23.57 tokens a second at two gigabytes against
      --  18.25 at eight, with more of the model resident. Nothing about
      --  memory does that; a list walked from one end does.
      --
      --  Newer and Older put the entries in one order of use, so the
      --  oldest is where the chain ends rather than where a walk finds it.
      --  Next_Free chains the slots nothing is in, so an entry keeps its
      --  slot for as long as it lives and the index below never has to be
      --  told that something moved.
      Newer     : Natural := 0;
      Older     : Natural := 0;
      Next_Free : Natural := 0;
   end record;

   type Held_Array is array (1 .. Max_Resident) of Held_Matrix;

   --  How many buffers may be held back for reuse.
   --
   --  Small on purpose: the loop this exists for gives one back and takes
   --  one, so what it needs is a handful and what a larger number would buy
   --  is device memory sitting idle. A model whose matrices are all
   --  different sizes finds nothing to reuse and pays what it always paid.
   Max_Spare : constant := 64;

   type Spare_Buffer is record
      Buffer : System.Address := System.Null_Address;
      Memory : System.Address := System.Null_Address;
      Bytes  : Interfaces.Unsigned_64 := 0;
      Mapped : System.Address := System.Null_Address;
      Tier   : Tier_Index := 1;
   end record;

   type Spare_Array is array (1 .. Max_Spare) of Spare_Buffer;

   --  Where a matrix is held, found by what identifies it.
   --
   --  Open addressing over the key's own address, twice the table so it is
   --  never more than half full and a probe is short. Zero is an empty
   --  slot; anything else is a place in Kept.
   Index_Slots : constant := 2 * Max_Resident;

   type Index_Array is array (0 .. Index_Slots - 1) of Natural;

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

      --  Why the last sequence was refused, as Last_Refusal says.
      Refused : Refusal := Not_Refused;

      --  The kind a buffer the processor reads back is allocated out of.
      --  What the context chose, and the same as Upload on a device with no
      --  cached kind to choose.
      Download : Natural := 0;

      --  Made once, in this order, and released in the reverse of it.
      Shader     : System.Address := System.Null_Address;

      --  The second kernel: the middle of a gated feed-forward. It takes the
      --  same descriptor layout and the same push constants as the first --
      --  three storage buffers and a block of six words -- so it shares the
      --  pipeline layout and needs only its own module and pipeline.
      Blender    : System.Address := System.Null_Address;

      --  The third kernel: one position attending to everything the cache
      --  holds. It shares the layout too -- three storage buffers, with the
      --  keys and values in one of them, and the same push-constant range.
      Attender   : System.Address := System.Null_Address;

      --  The packed attention kernel, over a cache of bytes or nibbles
      --  and scales, and its pipeline. Allowed to fail on their own: a
      --  device without them attends a packed session on the host.
      Packed_Attend : System.Address := System.Null_Address;
      Packed_Line   : System.Address := System.Null_Address;

      --  And the kernel that packs a step's rows into such a cache, with
      --  its pipeline: the placing step of a packed session's sequence.
      Packer        : System.Address := System.Null_Address;
      Pack_Line     : System.Address := System.Null_Address;

      --  The two again compiled without subgroup operations, for a device
      --  that offers none to a compute shader -- and for a test on one
      --  that does. Plain_Packing says which pair is bound.
      Packed_Plain      : System.Address := System.Null_Address;
      Packed_Plain_Line : System.Address := System.Null_Address;
      Packer_Plain      : System.Address := System.Null_Address;
      Pack_Plain_Line   : System.Address := System.Null_Address;
      Plain_Packing     : Boolean := False;

      --  And the one that unpacks a layer of it into the half-precision
      --  copy for a batch, with its pipeline.
      Unpacker      : System.Address := System.Null_Address;
      Unpack_Line   : System.Address := System.Null_Address;

      --  The same kernel compiled with SUBGROUPS, where the device says a
      --  compute shader may reduce across a subgroup. Its tile reductions
      --  are one instruction each instead of sixty-four serial reads a
      --  lane; everything else in it is the same text. Null where the
      --  device said no, and the third kernel then answers every call.
      Grouped    : System.Address := System.Null_Address;

      --  And the same source again with QUERY_TILE, where a workgroup
      --  answers a block of query positions rather than one and the key it
      --  reads is multiplied into every query of the block. Bound only
      --  where there are at least Query_Block positions to answer; below
      --  that a block is mostly padding and the kernel above is better.
      Query_Tile : System.Address := System.Null_Address;

      --  And attention through the matrix instruction, where the device
      --  offers it. Null on a device that does not.
      Attend_Matrix : System.Address := System.Null_Address;
      Attend_Matrix_Wide : System.Address := System.Null_Address;

      --  The fourth and fifth kernels, which go together and are made only
      --  where the device offers the matrix instruction: a tile of the
      --  answer at a time, and the copy of the batch in half precision that
      --  its operand has to be. Null everywhere else, and every product
      --  then goes to the first kernel as it always did.
      Matrix     : System.Address := System.Null_Address;
      Halver     : System.Address := System.Null_Address;

      --  The row product again, compiled from the same source with SINGLE,
      --  which sets its group to one. A generated token is one vector, and
      --  the wide kernel carries eight accumulators and eight kilobytes of
      --  shared memory for a reduction seven eighths of which is discarded.
      --  Null if the device refused it, which leaves a batch of one on the
      --  wide kernel exactly as before.

      --  And a third time with WIDER, which sets its group to sixteen. A
      --  round of nine to thirty-one sequences is two dispatches on the
      --  eight-wide kernel and therefore two passes over every weight in
      --  the model, which is what made a round of nine cost what a round of
      --  sixteen costs. Null if the device refused it, which puts those
      --  counts back on two passes and changes nothing else.

      --  And the four-wide one, for the counts between the single kernel
      --  and the eight-wide one.

      --  And the sixth: the same tile, compiled from the same source with
      --  MORE_FORMATS, decoding the nine formats the fourth leaves out.
      --  Two pipelines rather than one that decodes them all, because a
      --  pipeline's registers are allocated for every branch in it and the
      --  fourteen-branch shader cost the six formats a fifth of their speed
      --  with the other eight unreachable. Null if the device took the
      --  first and refused this one, which leaves the eight where they
      --  were and does not disturb the six.
      Extra      : System.Address := System.Null_Address;

      --  And the same two again with a tile a quarter as wide, for a batch
      --  too small to fill the one above. A tile costs what its width
      --  costs whether the batch fills it or not, so a round of seventeen
      --  sequences through a hundred-and-twenty-eight-wide tile pays for a
      --  hundred and eleven vectors of zeros. Null if the device refused
      --  them, which leaves those counts on the wide tile.
      --  Attention again, compiled to read the half-precision copy of the
      --  cache that place.comp already writes. It is what a round binds:
      --  the matrix kernel reads that copy and a round cannot use it, so
      --  until now a round read a cache twice the size it needed to.
      Halver_Attend : System.Address := System.Null_Address;

      --  And once more with GROUPED, where a workgroup answers a bundle of
      --  heads rather than one. A model with grouped queries gives several
      --  heads one group of keys and values, and a workgroup a head reads
      --  that group's slice once for each head that wants it.
      Bundled_Attend : System.Address := System.Null_Address;

      --  And GROUPED over the cache proper, for a generated token. A
      --  token's workgroup was a head, and a head reads its group's keys
      --  and values whole: with eight heads to a group the cache crossed
      --  eight times a layer, and the device's clock put attention at a
      --  third of a layer at thirteen hundred positions. A bundle reads
      --  it twice, in the precision the token's answer is published in.
      Exact_Bundled_Attend : System.Address := System.Null_Address;

      Narrow     : System.Address := System.Null_Address;
      Narrow_More : System.Address := System.Null_Address;
      Listed_Tile : System.Address := System.Null_Address;
      Listed_Tile_More : System.Address := System.Null_Address;

      --  And the normalization, which is here for the submission it saves
      --  rather than for itself: a layer normalizes twice and the host
      --  doing it is the host needing the products back.
      Normer     : System.Address := System.Null_Address;
      Turner     : System.Address := System.Null_Address;
      Placer     : System.Address := System.Null_Address;

      --  A mixture's routing and its weighted sum, the two steps that let
      --  a mixture layer be one submission: without them the host chose
      --  the experts between two and summed them after a third.
      Router     : System.Address := System.Null_Address;
      Mixer      : System.Address := System.Null_Address;

      --  And the one that adds each expert's bias to a gathered product's
      --  answers, for the mixture that carries them.
      Biaser     : System.Address := System.Null_Address;
      Picker     : System.Address := System.Null_Address;
      Conver     : System.Address := System.Null_Address;
      Ruler      : System.Address := System.Null_Address;

      --  The heads of a layer's queries or keys made ready in one step --
      --  normalized where the architecture says, turned, and the keys and
      --  values placed in the cache -- which is six dispatches a layer as
      --  two.
      Header     : System.Address := System.Null_Address;

      --  merge.comp: the slices of a split attention put together.
      Merger     : System.Address := System.Null_Address;

      --  invert.comp: a batch's routing turned into each expert's run.
      Inverter   : System.Address := System.Null_Address;

      --  thin.comp: a few binary32 rows against a few vectors, a
      --  workgroup a row.
      Thinner    : System.Address := System.Null_Address;

      Set_Layout : System.Address := System.Null_Address;
      Layout     : System.Address := System.Null_Address;
      Pipeline   : System.Address := System.Null_Address;
      Blend_Line : System.Address := System.Null_Address;
      Attend_Line : System.Address := System.Null_Address;
      Matrix_Line : System.Address := System.Null_Address;
      Halve_Line  : System.Address := System.Null_Address;
      Extra_Line  : System.Address := System.Null_Address;
      Halved_Line : System.Address := System.Null_Address;
      Bundle_Line : System.Address := System.Null_Address;
      Exact_Bundle_Line : System.Address := System.Null_Address;
      Eight_Bundle_Line : System.Address := System.Null_Address;

      --  The half-precision bundle at eight heads, for a token attending
      --  out of the copy, and whether a token does.
      Eight_Halved_Line : System.Address := System.Null_Address;
      Halves : Boolean := False;

      --  And whether a batch is kept off the matrix instruction, as
      --  Prefer_Exact_Attention says.
      Exact_Attention : Boolean := False;
      Narrow_Line : System.Address := System.Null_Address;
      Narrow_More_Line : System.Address := System.Null_Address;

      --  The wide tile compiled once more at sixty-four vectors a tile,
      --  for listed products: a run of thirty-two in a tile of a hundred
      --  and twenty-eight is three quarters padding the instruction
      --  multiplies all the same.
      Listed_Line : System.Address := System.Null_Address;
      Listed_More_Line : System.Address := System.Null_Address;

      --  The tile's LOW_BITS compilation, in the three widths the others
      --  come in, for the twelve low-bit packings; each null leaves those
      --  formats' batches on the row product.
      Low_Tile        : System.Address := System.Null_Address;
      Narrow_Low      : System.Address := System.Null_Address;
      Listed_Tile_Low : System.Address := System.Null_Address;
      Low_Tile_Line   : System.Address := System.Null_Address;
      Narrow_Low_Line : System.Address := System.Null_Address;
      Listed_Low_Line : System.Address := System.Null_Address;
      --  One for every count a round may bring, up to the eight-wide
      --  kernel, indexed by that count. A pipeline is cheap now the words
      --  are one module and the width is a constant it is told; what these
      --  buy is that a round of five stops paying for eight.
      Row_Lines : Row_Line_Array := [others => System.Null_Address];

      Half_Group_Line : System.Address := System.Null_Address;

      --  The super-block row product -- a workgroup of thirty-two, llama.cpp's
      --  vectorized k-quant decode -- and its own module, made only where the
      --  device runs a compute shader at a subgroup of thirty-two. Bound for a
      --  Q4_K generating a token; null elsewhere.
      Wave_Shader : System.Address := System.Null_Address;
      Wave_Line   : System.Address := System.Null_Address;

      --  The same for Q5_K, whose decode carries the fifth-bit mask.
      Wave_Shader5 : System.Address := System.Null_Address;
      Wave_Line5   : System.Address := System.Null_Address;

      --  And for Q6_K, six bits an element and a signed scale a sub-block.
      Wave_Shader6 : System.Address := System.Null_Address;
      Wave_Line6   : System.Address := System.Null_Address;

      --  And the twelve low-bit formats: one source, row_product_wave_low,
      --  compiled once a format, each with its decode and codebook alone.
      Low_Wave_Shaders : Low_Address_Array := [others => System.Null_Address];
      Low_Wave_Lines   : Low_Address_Array := [others => System.Null_Address];

      --  And Q8_0, on the same kernel compiled for it.
      Q8_Wave_Shader : System.Address := System.Null_Address;
      Q8_Wave_Line   : System.Address := System.Null_Address;

      --  And the two IQ4 formats, the same way: each read through its table
      --  of sixteen values, IQ4_XS with its sub-block scales beside.
      NL_Wave_Shader : System.Address := System.Null_Address;
      NL_Wave_Line   : System.Address := System.Null_Address;
      XS_Wave_Shader : System.Address := System.Null_Address;
      XS_Wave_Line   : System.Address := System.Null_Address;

      Wide_Line   : System.Address := System.Null_Address;

      --  The row product's LOW_BITS compilation and its pipelines, one for
      --  each the first compilation has -- the plain one, one a count, and
      --  the wide one -- so a low-bit product binds the same shape of
      --  kernel a sixteen-format one would.
      Low_Shader    : System.Address := System.Null_Address;
      Low_Pipeline  : System.Address := System.Null_Address;
      Low_Row_Lines : Row_Line_Array := [others => System.Null_Address];
      Low_Wide_Line : System.Address := System.Null_Address;

      Group_Line  : System.Address := System.Null_Address;
      Tile_Line   : System.Address := System.Null_Address;
      Matrix_Attend : System.Address := System.Null_Address;
      Matrix_Wide_Attend : System.Address := System.Null_Address;
      Norm_Line   : System.Address := System.Null_Address;
      Turn_Line   : System.Address := System.Null_Address;
      Place_Line  : System.Address := System.Null_Address;
      Route_Line  : System.Address := System.Null_Address;
      Mix_Line    : System.Address := System.Null_Address;
      Bias_Line   : System.Address := System.Null_Address;
      Pick_Line   : System.Address := System.Null_Address;
      Conv_Line   : System.Address := System.Null_Address;
      Rule_Line   : System.Address := System.Null_Address;
      Merge_Line  : System.Address := System.Null_Address;
      Invert_Line : System.Address := System.Null_Address;
      Thin_Line   : System.Address := System.Null_Address;
      Heads_Line  : System.Address := System.Null_Address;

      --  Whether this engine may dispatch the matrix product at all, which
      --  is what the device said when it was opened.
      Matrices    : Boolean := False;
      Pool       : System.Address := System.Null_Address;
      Descriptor : System.Address := System.Null_Address;

      --  The sets a sequence binds, one per product. Null until a device is
      --  open, and given back with the pool rather than one at a time.
      Sets       : Set_Array := [others => System.Null_Address];

      --  And a second of everything a submission holds while it runs, so
      --  that the host may record and submit the next sequence while the
      --  device is still on this one.
      --
      --  A layer used to wait on its own fence before the host would start
      --  the next: the device finished, the host woke, recorded, submitted,
      --  and the device started again. That gap is sixty-eight
      --  milliseconds of a fourteen-hundred-token prompt -- six per cent of
      --  it -- and nothing computes during it. Two of each means the host
      --  is always a sequence ahead.
      --
      --  Two command buffers because one may not be re-recorded while it
      --  executes; two sets of descriptors because they may not be written
      --  while a submission reads them; and two fences to tell the two
      --  apart. The second reads what the first wrote, which the barrier
      --  at the head of its command buffer orders.
      Sets_Two   : Set_Array := [others => System.Null_Address];
      Commands   : System.Address := System.Null_Address;
      Buffer     : System.Address := System.Null_Address;
      Buffer_Two : System.Address := System.Null_Address;

      --  Whether the fence beside each of those has a submission behind it
      --  that nothing has waited for yet.
      Pending     : Boolean := False;
      Pending_Two : Boolean := False;

      --  The clock reading each slot's sequence began at, so that the
      --  matrices it is still reading -- every one used at or after that
      --  reading -- can be pinned while it runs. The clock ticks once for
      --  every matrix acquired, so a sequence that acquires several sits
      --  several ticks below the clock, and a pin one tick below the clock
      --  left all but its last matrix free to be given back under it.
      Began     : Interfaces.Unsigned_64 := 0;
      Began_Two : Interfaces.Unsigned_64 := 0;

      --  What says each slot's submission has finished. What orders one
      --  submission after the one before is a barrier at the head of its
      --  command buffer, not a semaphore between them.
      Fence      : System.Address := System.Null_Address;
      Fence_Two  : System.Address := System.Null_Address;

      --  A pool of timestamp queries a slot, made when Time_Steps is first
      --  asked and kept until Close; the nanoseconds one tick of them is,
      --  which is zero on a device that writes none; whether Run stamps
      --  its steps; and what the stamps of the last run said.
      Queries     : System.Address := System.Null_Address;
      Queries_Two : System.Address := System.Null_Address;
      Tick        : Float := 0.0;
      Timing      : Boolean := False;
      Line        : Timeline;

      --  What the device says its largest heap is, and the share of it these
      --  matrices may take -- the sum over both tiers, where there are two.
      Heap       : Interfaces.Unsigned_64 := 0;
      Budget     : Interfaces.Unsigned_64 := 0;

      --  The second heap's memory kind, or -1 for a device with one heap,
      --  and per tier: what each may hold, what the matrices kept in it
      --  take, and what the buffers kept back for reuse in it take. The
      --  sums over the tiers are Kept_Bytes and Spare_Bytes, and each is
      --  moved wherever its sum is; the tiers exist so that a matrix is
      --  taken from a heap that has room rather than from one that only
      --  the total says has.
      Second     : Integer := -1;
      Tier_Limit : Tier_Bytes_Array := [others => 0];
      Tier_Kept  : Tier_Bytes_Array := [others => 0];
      Tier_Spare : Tier_Bytes_Array := [others => 0];

      --  And what it says one buffer may hold, which is the bound on a
      --  single matrix rather than on all of them.
      Storage    : Interfaces.Unsigned_64 := 0;

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

      --  Buffers given back but not given up.
      --
      --  A model larger than the device's budget gives a matrix back for
      --  every matrix it takes, and a mixture of experts does that four
      --  hundred times a generated token: each one was a vkDestroyBuffer
      --  and a vkFreeMemory followed by a vkCreateBuffer, a
      --  vkAllocateMemory and a vkBindBufferMemory, which is the call every
      --  guide to this interface says not to put in a loop.
      --
      --  A mixture's expert matrices are all one size, so a buffer given
      --  back is the right shape for the next one taken. Kept here by byte
      --  count, the driver is asked once and the loop reuses what it has.
      --  The bytes stay spent -- the device has not had them back -- so
      --  they count against the budget beside the matrices themselves.
      --  The order of last use, newest first, and the slots nothing is in.
      Newest      : Natural := 0;
      Oldest      : Natural := 0;
      Free_Head   : Natural := 0;

      --  How many slots have ever been given out, so that the ones past it
      --  need no chaining to be known free.
      Slots_Given : Natural := 0;

      --  Key to slot, so a lookup is a probe rather than a walk.
      Index_Of  : Index_Array := [others => 0];

      Spare       : Spare_Array := [others => <>];
      Spare_Used  : Natural := 0;
      Spare_Bytes : Interfaces.Unsigned_64 := 0;

      --  Products so far, which is the clock the eviction reads, and how
      --  many matrices have been given back to make room.
      Clock      : Interfaces.Unsigned_64 := 0;
      Released   : Natural := 0;

      --  How many of the resident matrices are the host's own memory rather
      --  than a copy of it.
      Taken      : Natural := 0;

      --  How long one wait lasts and how long to wait in all, as the
      --  engine was opened for.
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0;

      --  Slices taken waiting for the last product. One means the device
      --  answered inside the first, which is what every product on this
      --  machine does; more means the wait went round and asked the caller
      --  whether to stop, which is the only thing that makes a stop
      --  request during a product visible at all.
      Waited     : Natural := 0;

      --  Set when a dispatch did not finish inside the whole bound. The
      --  command buffer is still the device's, so nothing here may reset or
      --  record over it again, and the engine refuses every further product
      --  rather than reusing what it cannot take back.
      Stalled    : Boolean := False;

      Vector_Buffer : System.Address := System.Null_Address;
      Vector_Memory : System.Address := System.Null_Address;
      Vector_Bytes  : Interfaces.Unsigned_64 := 0;

      --  And the same for the angles a rotating step turns by. They change
      --  every call, as the activation does, so they are kept the way the
      --  activation is kept rather than acquired the way a matrix is: a
      --  buffer that grows when it has to and a copy into a standing
      --  mapping. Acquired as a matrix instead, a table cost an allocation
      --  and a release a layer, which a batch amortizes over its positions
      --  and a generated token pays whole.
      Turn_Buffer   : System.Address := System.Null_Address;
      Turn_Memory   : System.Address := System.Null_Address;
      Turn_Bytes    : Interfaces.Unsigned_64 := 0;
      Turn_At       : System.Address := System.Null_Address;

      --  And a second of it, swapped with the command buffer: a sequence
      --  is handed over and the next recorded while it runs, and the next
      --  writes its angles before anything waits. One table served every
      --  model whose layers turn on one base, since every layer wrote the
      --  same numbers over the last; Gemma 3's windowed layers turn on a
      --  base of their own, and the layer still running read the next
      --  one's angles.
      Turn_Buffer_Two : System.Address := System.Null_Address;
      Turn_Memory_Two : System.Address := System.Null_Address;
      Turn_Bytes_Two  : Interfaces.Unsigned_64 := 0;
      Turn_At_Two     : System.Address := System.Null_Address;

      --  Where that memory is mapped, kept from one call to the next, for
      --  the reason written against Result_At below.
      Vector_At     : System.Address := System.Null_Address;

      --  The batch in half precision, which the matrix product reads and
      --  nothing else does. Grown with the batch, like the two below, and
      --  never allocated on a device without the instruction.
      Half_Buffer : System.Address := System.Null_Address;
      Half_Memory : System.Address := System.Null_Address;
      Half_Bytes  : Interfaces.Unsigned_64 := 0;

      --  And how much of it one region is. The buffer holds two: a gated
      --  feed-forward has two arms alive at once, so the products that make
      --  them cannot both write at the front of it. Everything else uses
      --  the first region and the second stands empty.
      Half_Region : Interfaces.Unsigned_64 := 0;

      Result_Buffer : System.Address := System.Null_Address;
      Result_Memory : System.Address := System.Null_Address;
      Result_Bytes  : Interfaces.Unsigned_64 := 0;

      --  And where the results are mapped, for the same reason.
      Result_At     : System.Address := System.Null_Address;

      --  Where a cache goes when attention is done here. Grown when it has
      --  to and kept between calls, like the two above.
      Cache_Buffer : System.Address := System.Null_Address;
      Cache_Memory : System.Address := System.Null_Address;
      Cache_Bytes  : Interfaces.Unsigned_64 := 0;

      --  And the half-precision copy of it, which the matrix kernel
      --  attends out of and nothing else reads: a buffer of its own
      --  rather than the back half of that one.
      --
      --  A device states how much of one storage buffer a shader may be
      --  given and how large one allocation may be, and this part states
      --  four gigabytes for both. Kept together, a context of more than
      --  seven hundred million values was past the first number and a
      --  context of more than a thousand million past the second, so
      --  Phi-3 mini at its own four thousand and ninety-six -- 4.8 GB of
      --  the two together -- was refused the device and attended on the
      --  processor. Apart, the cache proper is four bytes an element and
      --  the copy two, and each is under both numbers where the two
      --  together were not.
      Copy_Buffer : System.Address := System.Null_Address;
      Copy_Memory : System.Address := System.Null_Address;
      Copy_Bytes  : Interfaces.Unsigned_64 := 0;
      Copy_At     : System.Address := System.Null_Address;

      --  How many binary32 elements the cache proper holds, which is how
      --  many halves the copy holds.
      Cache_Elements : Interfaces.Unsigned_64 := 0;

      --  The cache proper was not kept: only the half-precision copy is,
      --  which the matrix kernel attends out of. A sinkless model whose
      --  binary32 cache would not fit one storage buffer keeps just the
      --  copy -- two bytes an element rather than six -- and the kernels
      --  that would write the cache proper skip it, told so by a copy-only
      --  code in their push block. Nothing here reads the cache proper for
      --  such a model: the matrix kernel reads the copy, and only a sink
      --  or a round reads the binary32, neither of which this holds.
      Copy_Only : Boolean := False;

      --  The copy split in two, keys in Copy_Buffer above and values here,
      --  because at a wide enough context even the copy -- two bytes an
      --  element -- is past what one storage buffer may hold, where its
      --  keys and its values apart are not. Only a copy-only session
      --  splits, and only where the whole would not fit: the values kernel
      --  reads and writes this buffer, the keys kernel the one above, and
      --  the values' base is taken from the front of this rather than from
      --  the keys' end. Copy_Keys_Halves is where that end is, in halves.
      Copy_Split         : Boolean := False;
      Copy_Values_Buffer : System.Address := System.Null_Address;
      Copy_Values_Memory : System.Address := System.Null_Address;
      Copy_Values_Bytes  : Interfaces.Unsigned_64 := 0;
      Copy_Values_At     : System.Address := System.Null_Address;
      Copy_Keys_Halves   : Interfaces.Unsigned_64 := 0;

      --  The cache mapped once and left mapped. A position is written every
      --  layer of every token -- hundreds of writes a run, at a millisecond
      --  and a half apiece when each maps and unmaps around itself -- and the
      --  memory a device is chosen for is host-coherent, so what is written
      --  through a standing mapping is seen without a flush. That is the
      --  condition; it is required where the memory kind is picked.
      Cache_At     : System.Address := System.Null_Address;

      --  And where a hybrid's linear states and convolution memories go,
      --  as the cache does: a buffer grown when it has to be and kept,
      --  mapped once and left mapped. A convolving step and a rule step
      --  read and write it where the caller says.
      State_Buffer : System.Address := System.Null_Address;
      State_Memory : System.Address := System.Null_Address;
      State_Bytes  : Interfaces.Unsigned_64 := 0;
      State_At     : System.Address := System.Null_Address;
   end record;

   type Step is record
      --  Where the matrix lies and how much of it there is, rather than an
      --  access to it: a mapped model's weights are at an address this
      --  program did not allocate, and an access to an unconstrained array
      --  cannot be made to point at one.
      Base    : System.Address := System.Null_Address;
      Span    : Model_Runner.Bytes.Byte_Count := 0;
      At_Byte : Model_Runner.Bytes.Byte_Count := 0;
      Packing : Weight_Packing := Weight_Packing'First;
      Rows    : Natural := 0;
      Columns : Natural := 0;
      Key     : System.Address := System.Null_Address;

      --  Whether this reads what the product before it wrote, rather than
      --  the activation the caller supplied.
      Chained : Boolean := False;

      --  Which step's result this reads, where that is not the one before
      --  it. Zero means what Chained says: the step before, or the
      --  caller's activation.
      --
      --  A layer fused into one sequence needs this. Both arms of its
      --  gated feed-forward read the normalization several steps back, and
      --  its second residual join reads the first one -- neither of which
      --  is the step before, and neither of which can leave the device
      --  without costing the submission the fusing is for.
      Reads     : Natural := 0;

      --  And which step the second arm of a blending step reads, where that
      --  is not the one before it either. Zero means the step before.
      Reads_Two : Natural := 0;

      --  Where in the caller's activation a step that reads it begins, in
      --  elements. A residual join reads the residual, which travels beside
      --  the queries in one array rather than in a buffer of its own.
      At_Vector : Natural := 0;

      --  A slice of the step this one reads, rather than the whole of it.
      --  Where three projections were made by one fused product -- the
      --  queries, keys and values in a single matrix against one
      --  normalization -- each reader takes its own rows out of the fused
      --  answer: Reads_At is the first row it wants, in elements, and
      --  Reads_Stride is how far apart two positions lie in the fused answer,
      --  which is the fused product's whole row count and not the reader's.
      --  Both zero is the ordinary case, a reader over the whole of its
      --  source with the source's own width for a stride.
      Reads_At     : Natural := 0;
      Reads_Stride : Natural := 0;

      --  The same slice for a step's second source -- the values a heads
      --  step places while it turns the keys: where the values begin in the
      --  fused answer and its whole row count for a stride. Both zero is the
      --  ordinary case, the values read whole from their own step.
      V_Reads_At     : Natural := 0;
      V_Reads_Stride : Natural := 0;

      --  A join folded into the product it followed, and the two sides of
      --  that folding.
      --
      --  A layer adds its input back twice -- to what attention made and to
      --  what the feed-forward made -- and each of those used to be a
      --  dispatch: two arms read, a third buffer written, and the
      --  normalization after it reading that third buffer back. Where the
      --  arm is the product immediately before the join and nothing else
      --  reads that product alone, the product stores the sum instead and
      --  the join stops being dispatched at all. Its step stays in the
      --  sequence so that every index a caller wrote keeps meaning what it
      --  meant, and its place is the product's place, so a later step
      --  naming the join reads what the product wrote.
      --
      --  Joins and Joined are on the product: whether it adds a residual,
      --  and which step's join said so. Folded is on the join.
      Joins     : Boolean := False;
      Joined    : Natural := 0;
      Folded    : Boolean := False;

      --  A normalizing step rather than a product: it reads one step's
      --  result, or the caller's activation, and scales every position of
      --  it by the root of its own mean square and then by a weight the
      --  device keeps as it keeps a matrix. The weight is named by the
      --  Base, Span, At_Byte and Key above.
      Norms   : Boolean := False;

      --  How many stretches a position is normalized as, each its own
      --  Rows / Groups wide, as Add_Norm describes it. One for a whole
      --  position.
      Groups  : Positive := 1;

      --  Whether the normalization is the centred one with a shift: the
      --  mean taken off first, and the weight a gain and then a shift of
      --  the same width, added after the gain.
      Shifts  : Boolean := False;

      --  The floor under the mean square, as the architecture states it.
      Epsilon : Model_Runner.Numerics.Real := 0.0;

      --  A rotating step rather than a product: it turns each pair of a
      --  head by an angle the caller tabulated, and the table is named by
      --  the Base, Span and At_Byte above. It says how many heads the width
      --  holds in the Heads an attention step uses, because it means the
      --  same thing; Turns is how many components of a head turn, and Pairs
      --  which two of them make a pair.
      Rotates : Boolean := False;
      Turns   : Natural := 0;
      Pairs   : Rotary_Pairing := Interleaved;

      --  A placing step rather than a product: it writes what it reads into
      --  the cache the engine holds, a position at a time, at At_First and
      --  every Stride after it.
      Places   : Boolean := False;
      Stride   : Natural := 0;
      At_First : Model_Runner.Numerics.Element_Count := 0;

      --  Whether the caller wants this step's answer back. A step whose
      --  only reader is the step after it -- an arm of a gate, a blend a
      --  projection consumes -- has an answer that belongs on the device,
      --  and copying it to the host is a copy nobody reads. Run leaves the
      --  room for it in the target either way, so what a caller indexes
      --  does not depend on what it keeps.
      Kept    : Boolean := True;

      --  A combining step rather than a product: it takes the two results
      --  before it, puts a unit on the first and multiplies by the second.
      Blends  : Boolean := False;

      --  Which unit a combining step applies, and the clamped gate's
      --  slope and limit where it is that one. Meaningless otherwise.
      Unit    : Natural := 0;
      Alpha   : Model_Runner.Numerics.Real := 0.0;
      Limit   : Model_Runner.Numerics.Real := 0.0;

      --  An attention step rather than a product: it reads the queries the
      --  caller supplied and the cache the device holds, and writes a blend
      --  the step after it may chain to. Meaningless for anything else, and
      --  the fields below with it.
      Attends    : Boolean := False;

      --  Whether that step's positions see only what precedes them. Carried
      --  on the step rather than on the sequence, because a sequence holds
      --  the products around the attention as well and they have no opinion
      --  about it.
      Causal     : Boolean := True;
      Heads      : Natural := 0;
      Head_Size  : Natural := 0;
      Value_Size : Natural := 0;
      Group_Size : Natural := 1;
      First      : Natural := 0;
      Last       : Natural := 0;
      K_Base     : Model_Runner.Numerics.Element_Count := 0;
      V_Base     : Model_Runner.Numerics.Element_Count := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Window     : Natural := 0;
      Scale      : Model_Runner.Numerics.Real := 1.0;
      Cap        : Model_Runner.Numerics.Real := 0.0;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;

      --  A packed session's block, where the attention reads one.
      Packed     : Packed_Cache := Not_Packed;

      --  Where the heads' sinks begin in the cache, in elements, or zero
      --  for a layer without them.
      Sinks      : Natural := 0;

      --  A cache in pages rather than in blocks, for a step that reads
      --  or writes one: where the batch's page table for this layer
      --  begins, in elements, a word a page; the page's width in
      --  positions as a shift; and which position of its session the
      --  batch's first row is. The bases a step is given are then
      --  offsets inside a page. A shift of zero is a cache in blocks,
      --  which is what every step read before there were pages, and a
      --  round's rows each carry their own table in the per-row table.
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0;

      --  And how a placing step packs its rows into one -- or, where
      --  Unpacks, how the rows it unpacks into the half-precision copy
      --  are packed, and where in halves it writes them.
      Pack       : Packing_Shape := Not_Packing;
      Unpacks    : Boolean := False;
      Cells      : Natural := 0;
      Half_At    : Interfaces.Unsigned_64 := 0;

      --  A gathered product, as Add_Gathered_Product describes it: how
      --  many members, which slices they are, the rows of the whole stack
      --  and of one slice, and how far apart the members' vectors begin.
      --  Zero members is a plain product. Rows is then the answer's rows,
      --  Members' worth of Each, and Stack is what is uploaded.
      Gathers : Natural := 0;
      Members : Member_List := [others => 0];
      Stack   : Natural := 0;
      Each    : Natural := 0;
      Apart   : Natural := 0;

      --  Which routing step a gathered product takes its members from,
      --  or zero for the Members above.
      Routed  : Natural := 0;

      --  A routing step rather than a product: it reads a router's scores
      --  for every position, Columns an expert, and writes Rows words a
      --  position -- Used expert numbers and Used shares. A bias to add
      --  before choosing is named by Base, Span, At_Byte and Key, and
      --  Joins says whether there is one.
      Routes  : Boolean := False;
      Used    : Natural := 0;

      --  A mixing step rather than a product: it reads a gathered
      --  projection down, Used slices of Rows a position, weights each by
      --  the share the routing step it names in Reads_Two wrote, sums
      --  them best first, and adds the residual the step in Joined made.
      Mixes   : Boolean := False;

      --  An inverting step, as Add_Invert describes it: the routing in
      --  Reads turned into each of Experts experts' runs of positions.
      --  And a listed product, as Add_Listed_Product describes it: Gathers
      --  is then Experts, Routed the inverting step, and By_Slot says
      --  where a vector is read.
      Inverts : Boolean := False;
      Listed  : Boolean := False;
      By_Slot : Boolean := False;

      --  A biasing step, as Add_Bias describes it: the stack in Base,
      --  Span, At_Byte and Key, Stack slices of Each, added to the
      --  answers of the step in Reads by the routing in Reads_Two.
      Biases  : Boolean := False;

      --  A picking step, as Add_Pick describes it: of every Among
      --  stretches of Each in the step in Reads, the Which'th, written
      --  one after another as a row of Rows.
      Picks   : Boolean := False;
      Which   : Natural := 0;
      Among   : Positive := 1;

      --  A convolving step or a rule step, as Add_Conv and Add_Rule
      --  describe them: the front and the middle of a hybrid's linear
      --  layer, over the state buffer. The weight is in Base, Span,
      --  At_Byte and Key as a norm's is; the rest is in Linear.
      Convolves : Boolean := False;
      Rules     : Boolean := False;
      Linear    : Linear_Shape;

      --  A product kept off the tile whatever the count: the row kernel
      --  reads its activations in binary32 where the tile's operand is
      --  half precision, and a caller whose activations go through many
      --  products in a row -- a picture encoder's, through four a block
      --  over twenty-seven blocks -- asks for the row kernel and pays its
      --  reading of the weights once a group of vectors.
      Exact   : Boolean := False;

      --  A heads step rather than a product, as Add_Heads describes it:
      --  the queries or keys in Reads, Heads of Head_Size, each head
      --  normalized by the weight the Base, Span, At_Byte and Key above
      --  name where there is one, turned by Turns components with the
      --  table at Turn_Table, and written to the step's own room or -- into
      --  the cache -- at At_First, Stride apart, with the values in
      --  Reads_Two placed beside them.
      Readies    : Boolean := False;
      Turn_Table : System.Address := System.Null_Address;
      Into_Cache : Boolean := False;
      V_Rows     : Natural := 0;
      V_At_First : Model_Runner.Numerics.Element_Count := 0;
      V_Stride   : Natural := 0;
   end record;

   type Step_Array is array (1 .. Sequence_Limit) of Step;

   type Sequence is limited record
      Held  : Natural := 0;
      Items : Step_Array;
   end record;

end Model_Runner.Platform.Device.Products;
