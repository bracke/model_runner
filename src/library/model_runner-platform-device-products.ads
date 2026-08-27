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

   --  How many slices the last product spent waiting for the device.
   --
   --  One is a product the device answered inside the first slice. More
   --  than one means the wait went round, which is where a stop request
   --  made while a product is running is seen -- so this is how a test can
   --  tell that a cancelled product was cancelled there rather than by the
   --  check before anything was submitted.
   --
   --  @param Item Engine to ask about.
   --  @return Slices taken by the last product, or zero before any.
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

   type Sequence is limited private;

   --  Empty a sequence so that products may be added to it.
   --
   --  @param Steps Sequence to empty.
   procedure Open_Sequence (Steps : out Sequence);

   --  How many products a sequence holds.
   --
   --  @param Steps Sequence to read.
   --  @return The count, which is zero for a sequence just opened.
   function Length (Steps : Sequence) return Natural;

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
   procedure Add_Product
     (Steps   : in out Sequence;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address);

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
   procedure Add_Chained_Product
     (Steps   : in out Sequence;
      Base    : System.Address;
      Span    : Model_Runner.Bytes.Byte_Count;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address);

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
   --    sigmoid-weighted one, one for the Gaussian one in its tanh form.
   --  @param Added False when the sequence is full, when there are not two
   --    steps to combine, or when their rows do not match.
   procedure Add_Combination
     (Steps : in out Sequence;
      Unit  : Natural;
      Added : out Boolean);

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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

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
   procedure Run
     (Item      : in out Engine;
      Steps     : Sequence;
      Vectors   : Model_Runner.Numerics.Real_Array;
      Count     : Positive;
      Target    : out Model_Runner.Numerics.Real_Array;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference := null);

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
   --  @param Ok True when the room is there.
   procedure Reserve
     (Item     : in out Engine;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  The widest value head this kernel will take. One wider is refused, and
   --  the caller does it on the processor: a kernel that wrote past what it
   --  kept would be worse than one that says no.
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

      --  The fourth and fifth kernels, which go together and are made only
      --  where the device offers the matrix instruction: a tile of the
      --  answer at a time, and the copy of the batch in half precision that
      --  its operand has to be. Null everywhere else, and every product
      --  then goes to the first kernel as it always did.
      Matrix     : System.Address := System.Null_Address;
      Halver     : System.Address := System.Null_Address;

      --  And the sixth: the same tile, compiled from the same source with
      --  MORE_FORMATS, decoding the eight formats the fourth leaves out.
      --  Two pipelines rather than one that decodes them all, because a
      --  pipeline's registers are allocated for every branch in it and the
      --  fourteen-branch shader cost the six formats a fifth of their speed
      --  with the other eight unreachable. Null if the device took the
      --  first and refused this one, which leaves the eight where they
      --  were and does not disturb the six.
      Extra      : System.Address := System.Null_Address;

      Set_Layout : System.Address := System.Null_Address;
      Layout     : System.Address := System.Null_Address;
      Pipeline   : System.Address := System.Null_Address;
      Blend_Line : System.Address := System.Null_Address;
      Attend_Line : System.Address := System.Null_Address;
      Matrix_Line : System.Address := System.Null_Address;
      Halve_Line  : System.Address := System.Null_Address;
      Extra_Line  : System.Address := System.Null_Address;

      --  Whether this engine may dispatch the matrix product at all, which
      --  is what the device said when it was opened.
      Matrices    : Boolean := False;
      Pool       : System.Address := System.Null_Address;
      Descriptor : System.Address := System.Null_Address;

      --  The sets a sequence binds, one per product. Null until a device is
      --  open, and given back with the pool rather than one at a time.
      Sets       : Set_Array := [others => System.Null_Address];
      Commands   : System.Address := System.Null_Address;
      Buffer     : System.Address := System.Null_Address;
      Fence      : System.Address := System.Null_Address;

      --  What the device says its largest heap is, and the share of it these
      --  matrices may take.
      Heap       : Interfaces.Unsigned_64 := 0;
      Budget     : Interfaces.Unsigned_64 := 0;

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

      --  Where that memory is mapped, kept from one call to the next, for
      --  the reason written against Result_At below.
      Vector_At     : System.Address := System.Null_Address;

      --  The batch in half precision, which the matrix product reads and
      --  nothing else does. Grown with the batch, like the two below, and
      --  never allocated on a device without the instruction.
      Half_Buffer : System.Address := System.Null_Address;
      Half_Memory : System.Address := System.Null_Address;
      Half_Bytes  : Interfaces.Unsigned_64 := 0;

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

      --  The cache mapped once and left mapped. A position is written every
      --  layer of every token -- hundreds of writes a run, at a millisecond
      --  and a half apiece when each maps and unmaps around itself -- and the
      --  memory a device is chosen for is host-coherent, so what is written
      --  through a standing mapping is seen without a flush. That is the
      --  condition; it is required where the memory kind is picked.
      Cache_At     : System.Address := System.Null_Address;
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

      --  A combining step rather than a product: it takes the two results
      --  before it, puts a unit on the first and multiplies by the second.
      Blends  : Boolean := False;

      --  Which unit a combining step applies. Meaningless otherwise.
      Unit    : Natural := 0;

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
      K_Base     : Natural := 0;
      V_Base     : Natural := 0;
      KV_Width   : Natural := 0;
      V_Width    : Natural := 0;
      Window     : Natural := 0;
      Scale      : Model_Runner.Numerics.Real := 1.0;
      Cap        : Model_Runner.Numerics.Real := 0.0;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;
   end record;

   type Step_Array is array (1 .. Sequence_Limit) of Step;

   type Sequence is limited record
      Held  : Natural := 0;
      Items : Step_Array;
   end record;

end Model_Runner.Platform.Device.Products;
