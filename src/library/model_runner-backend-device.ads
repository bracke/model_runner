with Interfaces;

with Model_Runner.Bytes;

with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Tensors;

--  The backend that runs on a device.
--
--  It computes what an evaluation spends its time on -- a matrix against a
--  vector, and the attention that reads a cache -- on whatever compute
--  device the host has, and it is refused work it cannot take rather than
--  approximating it.
--
--  Every format, decoded where the weights lie. The shader has a branch for
--  each of the twenty-eight formats this program reads -- the twelve
--  low-bit ones in a compilation of their own -- and decodes the file's own
--  bytes, so nothing has to be repacked to reach a device. It was three --
--  binary32, Q8_0 and Q4_0 -- and the other twelve arrived through
--  `--repack f32`: a pass over the whole model at load and four bytes a
--  weight afterwards, which for a k-quant model is four times the memory it
--  was quantized to avoid. What this backend declares is read from
--  GGUF.Is_Supported rather than listed again here, because the two lists
--  that have to agree are the shader's branches and that one.
--
--  Availability. A machine with no device, or a device that will not take
--  the shader, reports itself unready. A caller that asked for this backend
--  is told so rather than quietly given another one: choosing a backend is a
--  decision, and silently substituting would make it a suggestion.
--
--  One device, opened once. A second call to Open on an open backend is the
--  same device; Close gives back everything the device is holding, which is
--  every weight of the model that was run on it.
--
--  Task safety: one task at a time. The device is a single queue and this
--  makes no attempt to feed it from several.
package Model_Runner.Backend.Device is

   --  Blocks the device's cache is dealt out in.
   --
   --  One session's keys and values apiece. A session takes one and keeps
   --  it for its life; a round's rows read the blocks their sessions hold.
   --
   --  What bounds this is memory rather than any kernel, which is the whole
   --  point of a table the kernel reads out of the cache rather than out of
   --  its push constants -- those held eight. Sixteen blocks of a
   --  1.1-billion-parameter model at two thousand positions is two
   --  gigabytes, which is what an integrated part will give; a round with
   --  more members than this attends on the host, as every round did
   --  before.
   Block_Limit : constant := 16;

   --  Rows a round's per-row table holds.
   --
   --  Rows and not members: a round whose members are all generating has one
   --  row apiece, and one that carries a joining member's prompt has that
   --  member's whole prompt in it. Sixteen kilobytes of a cache measured in
   --  gigabytes, so the number is chosen to be past anything rather than to
   --  be tight.
   Table_Rows : constant := 2048;

   --  Words that table holds: two a row.
   Table_Room : constant := 2 * Table_Rows;

   --  The sinks sit past the table, one a head and a slot a layer where an
   --  architecture learned them -- a token chains its layers into one
   --  submission and each layer's sinks are written to the mapping as it is
   --  built, so they need a slot apiece or the last layer's win. The room
   --  they take is sized to the model rather than capped here, so a sink
   --  model of any depth or width keeps every layer on the device: the
   --  caller adds Sink_Footprint of the model to the cache it reserves and
   --  writes each layer's slot within it.

   --  A round's per-row table: where each row has got to and where its
   --  cache begins, a row at a time in the rows' order.
   type Word_List is array (Positive range <>) of Natural;

   --  What this backend can do.
   --
   --  @return The capability record.
   function Describe return Capabilities;

   --  Open the first device the host names.
   --
   --  @param Ready True when a device took the shader and is ready for work.
   --  @param Budget Bytes of device memory the model's matrices may take, or
   --    zero for the share of the device's own heap the product engine
   --    chooses. What does not fit is given back and uploaded again when it
   --    is next wanted, so a budget is a speed decision rather than a limit
   --    on what will run.
   --  @param Share_Host Whether to read the weights where they lie rather
   --    than copy them to the device. It holds the model once instead of
   --    twice and runs slower, measurably; the statistics report how many
   --    matrices it applied to.
   --  @param Slice How long one wait for the device lasts before a stop
   --    request is asked about again.
   --  @param Patience How long to wait in all before giving up on a device
   --    that has stopped answering. Zero waits not at all.
   --  @param Which Which of the host's devices to open, counting from one in
   --    the order the host names them -- which is the order `inspect` lists
   --    them in. Out of range is a refusal rather than a fallback: a caller
   --    that named a device and got another one would be told the wrong
   --    thing about what ran.
   procedure Open
     (Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0;
      Which      : Positive := 1);

   --  Release the device and everything it holds. Idempotent.
   procedure Close;

   --  Slices the last product spent waiting for the device.
   --
   --  One is a product answered inside the first slice, which is what every
   --  product on this machine is. More says the wait went round and asked
   --  whether the caller wanted to stop.
   --
   --  @return Slices taken by the last product, or zero before any.

   function Waited return Natural;

   --  How many queues the open device's family offers.
   --
   --  The engine submits to one and waits on it. Whether it could submit to
   --  two is a fact about the host rather than a plan, and a run that used a
   --  device says what it found rather than leaving the number where only a
   --  test can see it.
   --
   --  @return Queues the family has, or zero when no device is open.
   function Queues return Natural;

   --  Give back every matrix the device holds, and stay open.
   --
   --
   --  Called when a model closes, because a resident matrix is remembered by
   --  where its bytes lie: once that storage is freed, another matrix of the
   --  same shape and format can take the address and the device would answer
   --  for the second with the first one's weights. Safe to call with no
   --  device, or with one holding nothing.
   procedure Forget_Matrices;

   --  Report whether a device is open and ready.
   --
   --  @return True when Dispatch can succeed.
   function Is_Ready return Boolean;

   --  What the device is called, for a report.
   --
   --  @return The device's own name, or an empty string when none is open.
   function Name return String;

   --  How many of a model's matrices the device is holding.
   --
   --  A model handed over once stays there; this is how much of it has
   --  arrived. It is what tells a reader that the device is computing rather
   --  than being handed the same weights again.
   --
   --  @return Count of matrices resident.
   function Resident return Natural;

   --  The most matrices this engine will hold, as a count.
   --
   --  There are two bounds on residency and the tighter one wins: this
   --  count, and the byte budget. The count is a table size and cannot be
   --  unbounded; it is reported beside the count held so that a run where
   --  the count is what stopped it says so, which one where the count sat
   --  at exactly its bound for a mixture of experts did not.
   --
   --  @return The bound, as a count of matrices.
   function Resident_Limit return Natural;

   --  How many bytes of the model the device is holding.
   --
   --  @return Bytes resident.
   function Resident_Bytes return Interfaces.Unsigned_64;

   --  How many matrices the device is reading where they already are.
   --
   --  @return Count taken rather than copied.
   function Imported return Natural;

   --  Whether this device was opened to read the weights where they lie.
   --
   --  Asked by the preparation, because the two ways of not copying a model
   --  are exclusive on the hardware this runs on: a device that takes the
   --  host's own pointer cannot be handed one into a mapped file -- the
   --  driver will not import pages it cannot pin -- so a caller who asked
   --  for that gets a model read into memory the device can take, and a
   --  caller who did not gets the file's pages and no copy at all.
   --
   --  @return True when the device was opened sharing the host's memory.
   function Shares_Host return Boolean;

   --  How many matrices have been given back to make room for others.
   --
   --  Zero for a model the device can hold. A number that rises with every
   --  token means the model does not fit and is being uploaded again as it
   --  is needed, which is correct and slow.
   --
   --  @return Count of matrices released to make room.
   function Given_Back return Natural;

   --  How many layers went over as one sequence and how many did not,
   --  and why the first of those did not.
   --
   --  A layer the device will not take whole goes over in pieces instead
   --  -- a submission a step, its activation home between them -- or on
   --  the processor, and nothing said so: a session whose rows are
   --  narrower than the word the packing writes had every layer refused,
   --  and the run reported a device with the weights and the context on
   --  it, which is what it reports when the whole model runs there. The
   --  engine notes every layer's outcome; the run's report shows the
   --  counts, and the reason where any were refused.
   type Handing is
     (Not_Handed, Shape_Handed, Packed_Handed, Cache_Handed, Blocks_Handed,
      Room_Handed, Refused_Handed);

   --  @param Whole True where the whole layer went over as one sequence.
   --  @param Asked True where the device was asked, False where the
   --    engine's own check kept the layer back.
   --  @param Cache True where what kept it back was the context not being
   --    on the device -- a context past what one storage buffer holds
   --    there, or a device with no room for one -- which the engine knows
   --    and the sequence never hears about, having never been built.
   --  @param Held True where the context is not there for a reason of its
   --    own: every block of the cache is another session's, and none was
   --    cold enough to turn out. A run whose layers were handed back for
   --    that is one the device could have taken had it been asked sooner,
   --    which is a different thing from a context it will not hold at
   --    all, and the report said the same for both.
   --  @param Split True where the device ran the layer's front half and
   --    the processor its mixture of experts: the model's experts do not
   --    fit the device, the rest of it does.
   procedure Note_Layer
     (Whole : Boolean;
      Asked : Boolean := False;
      Cache : Boolean := False;
      Held  : Boolean := False;
      Split : Boolean := False);

   --  @return Layers noted whole since the device was opened.
   function Layers_Whole return Natural;

   --  @return Layers noted not whole since then.
   function Layers_Handed return Natural;

   --  @return Layers noted split since then: the front half on the
   --    device, the mixture on the processor.
   function Layers_Split return Natural;

   --  @return Why the first of those was, or Not_Handed for none.
   function First_Handing return Handing;

   --  A stretch inside a block that holds something, and a list of them:
   --  the engine's names for what the products call the same.
   subtype Block_Run is
     Model_Runner.Platform.Device.Products.Block_Run;
   subtype Block_Runs is
     Model_Runner.Platform.Device.Products.Block_Runs;

   --  Move a block of the cache to another place in it, on the device.
   --
   --  What the packing moves a block with. The engine used to write the
   --  session's cache into the new place out of the host's copy, which
   --  meant reading back whatever the device owed that copy first and
   --  then sending the whole of what the session holds across the bus;
   --  the device copies it where it lies instead, and the
   --  half-precision copy beside it in the same submission.
   --
   --  Only the stretches of it that hold anything, which the caller says
   --  because only it knows how its cache is laid out: a session of a
   --  2,048-token context that has said twelve tokens holds twelve cells
   --  of every layer, and the rest of the block is the zeros it was made
   --  with.
   --
   --  @param From Where the block begins now, in elements.
   --  @param Into Where it is to begin, which must be below From.
   --  @param Runs What inside it to move, counted from the block's base.
   --  @param Halves True to move the same runs of the half-precision copy
   --    beside it, which an exact session's block has and a packed one
   --    uses only as scratch.
   --  @param Ok True when the move ran.
   procedure Move_Cache
     (From   : Model_Runner.Numerics.Element_Count;
      Into   : Model_Runner.Numerics.Element_Count;
      Runs   : Block_Runs;
      Halves : Boolean;
      Ok     : out Boolean);

   --  The same for a seat in the room of rings.
   --
   --  @param From Where the ring begins now, in elements.
   --  @param Into Where it is to begin, below From.
   --  @param Elements How long the ring is.
   --  @param Ok True when the move ran.
   procedure Move_State
     (From     : Model_Runner.Numerics.Element_Count;
      Into     : Model_Runner.Numerics.Element_Count;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  Note that a block of the cache, or a seat in the room of rings, was
   --  moved to close a gap below it.
   --
   --  Both are placed at the first gap that holds them and given back in
   --  whatever order the sessions holding them close, so a gap a larger
   --  one cannot use is room kept for nobody. Rather than grow, the
   --  places are packed forward -- which costs the cache or the ring
   --  written where it now is, as a session turned out of one pays.
   --
   --  @param Ring True for a seat in the room of rings, False for a block
   --    of the cache.
   procedure Note_Moved (Ring : Boolean := False);

   --  @return Blocks of the cache moved since the device was opened.
   function Blocks_Moved return Natural;

   --  @return Seats in the room of rings moved since then.
   function Rings_Moved return Natural;

   --  Attend a generated token out of the half-precision copy of the
   --  cache, or out of the cache proper.
   --
   --  What --kv-cache f16 means on the device: the device keeps every
   --  position in both precisions already, and a token's attention at a
   --  long context is the bytes of keys and values it reads. The host's
   --  copy of record stays exact. Off, a token reads the cache proper,
   --  at the precision its answer is published in.
   --
   --  Task safety: run from one task, before the sequences it should
   --  govern.
   --
   --  @param On True to read the copy.
   procedure Attend_In_Halves (On : Boolean);

   --  Whether a generated token attends out of the half-precision copy.
   --
   --  @return True after Attend_In_Halves said so, where the device has
   --    the kernels for it.
   function Attends_In_Halves return Boolean;

   --  Whether a batch attends in binary32, off the matrix instruction
   --  whose operand is half precision: through the kernel that reads the
   --  cache proper, as a head the instruction cannot take does anyway.
   --  For a caller whose blends go through many blocks in a row, where
   --  the halves compound. Costs the instruction's speed on the batch.
   --
   --  Task safety: run from one task, around the calls it should govern,
   --  and set back after them: a session's prompt wants the instruction.
   --
   --  @param On True to attend in binary32.
   procedure Attend_Exactly (On : Boolean);

   --  Whether a batch attends off the matrix instruction.
   --
   --  @return True after Attend_Exactly said so and a device is open.
   function Attends_Exactly return Boolean;

   --  Keep a timeline of every sequence the device runs, or stop.
   --
   --  Every sequence from then on is stamped by the device's own clock,
   --  step by step, and the intervals are summed by the shape of the
   --  sequence -- the same steps at the same widths, run for a number of
   --  positions within the same doubling -- so that a layer run forty
   --  times a token and a hundred tokens over is one line a step rather
   --  than four thousand.
   --  Timeline_Report says what was summed. Turning it on empties the sums.
   --
   --  A device whose compute queue writes no timestamps keeps none, and
   --  the report says so.
   --
   --  Task safety: run from one task, before the sequences it should see.
   --
   --  @param On True to keep one, False to stop.
   procedure Keep_Timeline (On : Boolean);

   --  What the timeline kept, one shape at a time.
   --
   --  A heading a shape -- how many runs, how many steps, how many
   --  positions or what range of them, and the mean microseconds a run
   --  cost the device from its first dispatch to its last -- then a line
   --  a step with the mean microseconds and the share of the run it was,
   --  and last the whole: the milliseconds the device was busy across
   --  every run, which against a wall clock is the host's share. See
   --  Products.Timeline for what a step's interval means where steps
   --  overlap.
   --
   --  @return The report, or a line saying nothing was kept.
   function Timeline_Report return String;

   --  How many bytes of context the device is holding.
   --
   --  A device holding the weights and not the context is a device that
   --  computes the products there and hands attention back, and the only
   --  sign of it from outside is a run spending processor time it should
   --  not need. This program could report the first and not the second, and
   --  a figure that halved with no cause found is what made that a gap
   --  worth closing rather than an omission.
   --
   --  @return Bytes of key and value cache resident, or zero for none.
   function Cached_Bytes return Interfaces.Unsigned_64;

   --  And the room a hybrid's rings of states are seated in, which is
   --  the other thing a session holds there: every linear layer's
   --  memories and states for as many slots as it keeps, a ring a
   --  session, and nothing said how much.
   --
   --  @return Bytes of that room, or zero where none is taken.
   function State_Room_Bytes return Interfaces.Unsigned_64;

   --  How many values that cache holds room for, keys and values
   --  together: what Reserve_Cache was last asked for and met. Not the
   --  bytes over four -- the bytes hold a half-precision copy past the
   --  values as well -- so a caller placing something of its own past
   --  what the sessions hold counts from this.
   --
   --  @return Values the cache holds room for, or zero for none.
   function Cached_Elements return Model_Runner.Numerics.Element_Count;

   --  One matrix-vector product, on the device.
   --
   --  @param Weight Weight view; must be binary32.
   --  @param Vector Input vector of Weight's column count.
   --  @param Target Receives Weight's row count.
   --  @param Cancel Stop request to watch, or null for none. Asked before
   --    anything reaches the device and between slices of the wait for it
   --    to finish; answered with Generation_Cancelled once the dispatch is
   --    done there, which it must be, because a dispatch cannot be taken
   --    back and its buffers belong to the device until the fence says
   --    otherwise. Cancellation is checked between layers everywhere else
   --    in this program, and a layer on a device is these waits, so a wait
   --    that could not be interrupted was the longest a stop request went
   --    unanswered.
   --  @param Status Success, Backend_Unsupported_Format when the view is not
   --    binary32, Lifecycle_Invalid_State when no device is open, or
   --    Tensor_Shape_Mismatch.
   procedure Dispatch
     (Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null);

   --  Make room on the device for a key-and-value cache and keep it.
   --
   --  A model's largest runtime allocation, put where attention can read it
   --  without any of it crossing the interface for every position that
   --  attends to it. Asking for no more than is already held does nothing,
   --  so a caller may say it every layer.
   --
   --  @param Elements How many values, keys and values together.
   --  @param Copy_Upto How far into that the half-precision copy must
   --    reach, in elements: the highest element anything here will read a
   --    half of. A block whose session keeps an exact cache has a half of
   --    every element of it; one kept packed has no copy of itself and
   --    uses the copy only as the room a layer's rows unpack into, at the
   --    block's front. Nought where nothing reads halves, and then no copy
   --    is taken at all.
   --  @param Ok True when the room is there.
   --  @param Allow_Copy_Only Where the cache proper alone would not fit one
   --    storage buffer but its half-precision copy would, keep only the
   --    copy; the caller states this where nothing reads the cache proper.
   --  @param Keys_Upto Where the keys end and the values begin in the
   --    copy, in halves, so that a copy past one buffer is split there.
   --    Zero asks for no split.
   procedure Reserve_Cache
     (Elements        : Model_Runner.Numerics.Element_Count;
      Copy_Upto       : Model_Runner.Numerics.Element_Count;
      Ok              : out Boolean;
      Allow_Copy_Only : Boolean := False;
      Keys_Upto       : Model_Runner.Numerics.Element_Count := 0);

   --  How many bytes one storage buffer may hold here, which is what
   --  bounds a session's context: the cache is one buffer, binary32 with
   --  a half-precision copy after it, and a context past the bound is
   --  refused rather than bound -- the allocation goes through, the
   --  descriptor naming a range past it does not, and every read out of
   --  it is undefined. A caller that knows what its context will take can
   --  say so before the run rather than leave the reader to infer it from
   --  a run that was slower than it looked.
   --
   --  @return The bound in bytes, or zero where no device is open or the
   --    device states none.
   function Cache_Bound return Interfaces.Unsigned_64;

   --  Give the device's cache back, both buffers of it, once no session
   --  holds a block of it.
   --
   --  A reserve only ever grows, so a run that opened a long-context
   --  session and closed it left the device holding that cache -- on a
   --  part that shares the host's memory, the machine's memory held for
   --  a session that is gone, and a later model refused for want of it.
   --  The engine says when the last block has been given up; nothing
   --  here can tell on its own, a block being kept for a session that
   --  may come back.
   procedure Release_Cache;

   --  And the room a hybrid's rings of states are seated in, once no
   --  session is seated in it: the same rule and the same reason, a room
   --  that grew to hold every seated ring and never shrank.
   procedure Release_State_Room;

   --  Zero a run of that room, on the device: a seat taken again holds
   --  the ring the session before it left, and a session with nothing
   --  committed has a ring of nothing to put there.
   --
   --  @param At_Value Where the run begins, in elements.
   --  @param Count How many elements.
   --  @param Ok True when it was zeroed.
   procedure Clear_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  How many bytes of one storage buffer a context of this many
   --  elements would take on the device: four an element, the cache
   --  proper being one buffer and its half-precision copy another of two
   --  bytes an element. What bounds a context is the larger of the two,
   --  which is the cache proper.
   --
   --  @param Elements Values, keys and values together.
   --  @return Bytes of the buffer that decides.
   function Cache_Bytes_For
     (Elements : Model_Runner.Numerics.Element_Count)
      return Interfaces.Unsigned_64;

   --  Write a round's per-row table into that cache.
   --
   --  @param At_Value Where the table begins, in elements.
   --  @param Words Two a row: where the row has got to, and where its
   --    cache begins.
   --  @param Ok True when it was written.
   procedure Put_Table
     (At_Value : Model_Runner.Numerics.Element_Count;
      Words    : Word_List;
      Ok       : out Boolean);

   --  Write one position's keys or values into that cache.
   --
   --  @param At_Value Where in the cache the run begins.
   --  @param Values What to write.
   --  @param Ok True when it was written.
   procedure Put_Cache
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean);

   --  Write bytes into that cache as they are: a packed session's rows and
   --  scales, which the packed attention kernel reads back.
   --
   --  @param At_Byte Where in the cache the bytes go, in bytes.
   --  @param Data What to write.
   --  @param Ok True when it was written.
   procedure Put_Cache_Bytes
     (At_Byte : Interfaces.Unsigned_64;
      Data    : Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean);

   --  And bytes back out of it: a packed session's rows and scales the
   --  device packed itself, read into the host's copy once a token or a
   --  batch is done.
   --
   --  @param At_Byte Where in the cache the bytes begin, in bytes.
   --  @param Data Receives what is there.
   --  @param Ok True when it was read.
   procedure Get_Cache_Bytes
     (At_Byte : Interfaces.Unsigned_64;
      Data    : out Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean);

   --  Whether the device has the kernel that attends over a packed cache.
   --
   --  @return True when Attend_Packed can run.
   function Attends_Packed return Boolean;

   --  And whether that kernel reads heads of this shape. It reads four
   --  elements of a row at a time out of one word, so a head is a whole
   --  number of fours, and it keeps room for a value head of 256 at
   --  most. A model whose heads are another shape keeps its packed cache
   --  on the processor and attends there: the answer is the same for
   --  every layer, since a model's heads are one shape, so a caller may
   --  ask once rather than find out a layer at a time.
   --
   --  @param Head_Size Elements a key head holds.
   --  @param Value_Size Elements a value head holds.
   --  @return True where the kernel is here and reads them.
   function Attends_Packed_Heads
     (Head_Size : Natural; Value_Size : Natural) return Boolean;

   --  The widest head the device's attention keeps room for, packed or
   --  exact. A model whose heads are wider attends on the processor,
   --  every layer, whatever its cache is kept in -- a kernel that wrote
   --  past what it kept would be worse than one that says no.
   --
   --  @return The width in elements, or zero where no device is open.
   function Attention_Head_Room return Natural;

   --  Attend over a cache kept packed on the device -- a byte an element
   --  with a scale a row, or a nibble an element with a scale a block of
   --  thirty-two -- as Attend does over the exact one. The rows' bases
   --  are in bytes and the scales' in floats of the cache buffer.
   --
   --  @param K_Bits Eight or four, for the keys.
   --  @param V_Bits The same for the values, which may differ.
   --  @param Query The queries, Positions of them, a head after the other.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first of them may look at.
   --  @param Last Last cached position the first of them may look at.
   --  @param K_Bytes Where the packed keys begin, in bytes.
   --  @param V_Bytes Where the packed values begin, in bytes.
   --  @param KV_Width How wide a row of keys is, in elements.
   --  @param V_Width How wide a row of values is, in elements.
   --  @param KS_At Where the key scales begin, in floats.
   --  @param VS_At Where the value scales begin, in floats.
   --  @param K_Blocks Scales a row of keys.
   --  @param V_Blocks Scales a row of values.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Target Receives the blend, Positions of them.
   --  @param Ok True when the blend was computed on the device.
   --  @param Positions How many queries, one after the other.
   --  @param Window This layer's sliding window, or zero for none.
   --  @param Causal True where a position may see only what precedes it.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for none.
   procedure Attend_Packed
     (K_Bits     : Positive;
      V_Bits     : Positive;
      Query      : Model_Runner.Tensors.Real_Array;
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
      Target     : out Model_Runner.Tensors.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  And back out of it, which is how the host's copy of the cache is
   --  brought up to date after a batch the device took whole.
   --
   --  A layer's keys and values used to come back through the result
   --  buffer step by step, because the host keeps a copy for a session
   --  that later runs on the processor. They are already in the cache the
   --  device holds; this reads them from there once a batch instead of
   --  once a layer, which is the same bytes and none of the waiting.
   --
   --  @param At_Value Where in the cache to read from.
   --  @param Values Receives what is there.
   --  @param Ok True when it was read.
   procedure Get_Cache
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean);

   --  The activation a layer carried out, brought home: for a caller
   --  that cannot hand the next layer over after all, whose host copy is
   --  the layer before's.
   --
   --  @param Into Receives the activation, Count positions of its width.
   --  @param Ok True when it was read.
   procedure Fetch_Carried
     (Into : out Model_Runner.Tensors.Real_Array;
      Ok   : out Boolean);

   --  Whether the device has the kernels a hybrid's linear layer takes
   --  whole: the convolution and the rule.
   --
   --  @return True where the engine made both pipelines.
   function Runs_Linear return Boolean;

   --  A linear layer's geometry and its place in the ring, as Whole_Layer
   --  takes it: the products' own type, named here so the engine reads
   --  no platform package.
   subtype Linear_Shape is
     Model_Runner.Platform.Device.Products.Linear_Shape;

   --  Room on the device for a hybrid's linear states and convolution
   --  memories, kept between calls as the cache is; what is there is
   --  carried over when it grows. A linear layer taken whole reads and
   --  writes its slot of it where the caller says, and the host's copy is
   --  what Get_State brings home.
   --
   --  @param Elements How many binary32 values, states and memories
   --    together.
   --  @param Ok True when the room is there.
   procedure Reserve_State
     (Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean);

   --  Values into that room.
   --
   --  @param At_Value Where in the room, in elements.
   --  @param Values What to write.
   --  @param Ok False where there is no room or it is too small.
   procedure Put_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean);

   --  And back out of it.
   --
   --  @param At_Value Where in the room, in elements.
   --  @param Values Receives what is there.
   --  @param Ok False where there is no room or it is too small.
   procedure Get_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean);

   --  One position attending to the cache the device holds.
   --
   --  Only the queries go over and only the blend comes back. The arguments
   --  are the ones the processor's own attention takes, so the two read side
   --  by side.
   --
   --  @param Query This position's queries, one head after another.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position that may be looked at.
   --  @param Last Last cached position that may be looked at.
   --  @param K_Base Where this layer's keys begin.
   --  @param V_Base Where this layer's values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Target Receives Positions blends, each one head after
   --    another.
   --  @param Ok True when the device computed it.
   --  @param Positions How many positions attend in this call. One while
   --    generating; the whole batch while a prompt is evaluated, whose
   --    queries follow one another in Query and whose blends follow one
   --    another in Target. Position p of the batch looks back to Last + p.
   --  @param Window How wide this layer's sliding window is, or zero where
   --    it does not slide one. A batch needs it because First can only
   --    speak for one position and a window moves with each of them.
   --  @param Causal True where a position may see only what precedes it,
   --    which is every model that generates. False where it sees the whole
   --    text, and every position then attends to Last rather than to Last
   --    plus its own place in the batch.
   procedure Attend
     (Query      : Model_Runner.Tensors.Real_Array;
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
      Target     : out Model_Runner.Tensors.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

   --  A packed session's block on the device, as Products describes it:
   --  what the fused sequences below are given so that their attention
   --  step reads the packed kernel rather than the exact one.
   subtype Packed_Cache is Model_Runner.Platform.Device.Products.Packed_Cache;

   --  A cache the exact kernels read.
   Not_Packed : constant Packed_Cache :=
     Model_Runner.Platform.Device.Products.Not_Packed;

   --  How a whole layer packs the keys or the values it places, for a
   --  packed session, as Products describes it.
   subtype Packing_Shape is
     Model_Runner.Platform.Device.Products.Packing_Shape;

   --  Rows placed as they are.
   Not_Packing : constant Packing_Shape :=
     Model_Runner.Platform.Device.Products.Not_Packing;

   --  A packed layer unpacked into the half-precision copy for a batch's
   --  attention through the matrix instruction, as Products describes it.
   subtype Unpacking_Shape is
     Model_Runner.Platform.Device.Products.Unpacking_Shape;

   --  No unpacking.
   Not_Unpacked : constant Unpacking_Shape :=
     Model_Runner.Platform.Device.Products.Not_Unpacked;

   --  Attend, and project the blend, in one submission.
   --
   --  A layer's attention and the matrix that reads its result are two
   --  submissions with a round trip between them: the blend comes back to
   --  the host only to be sent again as the projection's activation. Named
   --  together they are one command buffer, one fence, and a blend that
   --  never leaves the device -- a call costs 82.7 microseconds before it
   --  computes anything, and a run generating pays that once a layer a
   --  token.
   --
   --  The arithmetic is the same either way, and a test says so rather than
   --  this comment: attention recorded into a sequence is compared against
   --  attention submitted on its own, on the same cache with the same
   --  queries.
   --
   --  @param Query The queries, one position after another.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first position may look at.
   --  @param Last Last cached position the first position may look at.
   --  @param K_Base Where the keys begin.
   --  @param V_Base Where the values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Weight The matrix the blend is projected through.
   --  @param Into Receives the projection, Positions * Weight.Rows values.
   --  @param Ok True when the device computed both.
   --  @param Positions How many positions attend, which is also how many
   --    activations the projection is given.
   --  @param Window This layer's sliding window, or zero for none.
   --  @param Causal True where a position may see only what precedes it,
   --    which is every model that generates. False where it sees the whole
   --    text, and every position then attends to Last rather than to Last
   --    plus its own place in the batch.
   --  @param Packed The session's packed block, where it has one, which
   --    the attention step then reads with the packed kernel; K_Base and
   --    V_Base go unread.
   --  @param Sinks_At Where the heads' sinks begin in the cache, in
   --    elements, for a layer that has them; zero for none.
   --  @param Pages_At A cache in pages rather than in blocks: where the
   --    batch's page table for this layer begins, in elements, a word a
   --    page; K_Base and V_Base are then offsets inside a page. A round's
   --    rows carry their own tables in the per-row table, where a block's
   --    base was. Zero with Page_Shift for a cache in blocks.
   --  @param Page_Shift The page's width in positions, as a shift, or
   --    zero for a cache in blocks.
   procedure Attend_And_Project
     (Query      : Model_Runner.Tensors.Real_Array;
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
      Weight     : Model_Runner.Tensors.View;
      Into       : Model_Runner.Tensors.Real_Array_Access;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;
      Packed     : Packed_Cache := Not_Packed;
      Sinks_At   : Natural := 0;
      Pages_At   : Natural := 0;
      Page_Shift : Natural := 0);

   --  A layer's second half, in one submission rather than two.
   --
   --  Attention, the projection that reads it, the residual join, the
   --  normalization, the two arms of the gated feed-forward, their
   --  combination, the projection down and the second join -- nine steps
   --  that used to be two submissions with the host joining and normalizing
   --  in between. A submission is a submit and a wait on a fence, and a
   --  generated token made sixty-seven of them; this is one of the three a
   --  layer made.
   --
   --  The activation is the queries and the residual, one after the other,
   --  because the joins need the residual and Run is given one array.
   --
   --  @param Query The rotated queries, Positions of them.
   --  @param Residual The layer's input, Positions of them, which the
   --    first join adds to; the second adds to what the first wrote.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first position may look at.
   --  @param Last Last cached position the first position may look at.
   --  @param K_Base Where the keys begin.
   --  @param V_Base Where the values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Weight The matrix the blend is projected through.
   --  @param Positions How many positions the layer is given.
   --  @param Norm_Weight The feed-forward normalization's weight.
   --  @param Epsilon The floor under its mean square.
   --  @param Gate The gating arm of the feed-forward.
   --  @param Up The other arm, which the gate multiplies.
   --  @param Down The projection back down to the layer's width.
   --  @param Unit Which unit the combination applies.
   --  @param Into Receives the layer's output, Positions of them.
   --  @param Ok False when the device did not run it, which leaves the
   --    caller to do the whole of it as it did before.
   --  @param Window This layer's sliding window, or zero for none.
   --  @param Causal True where a position may see only what precedes it.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero for a model told where a token is otherwise.
   --  @param Packed The session's packed block, where it has one, which
   --    the attention step then reads with the packed kernel; K_Base and
   --    V_Base go unread.
   --  @param Sinks_At Where the heads' sinks begin in the cache, in
   --    elements, for a layer that has them; zero for none.
   --  @param Alpha The clamped gate's slope, where Unit is three.
   --  @param Limit The clamped gate's limit, where Unit is three.
   --  @param Pages_At A cache in pages rather than in blocks: where the
   --    batch's page table for this layer begins, in elements, a word a
   --    page; K_Base and V_Base are then offsets inside a page. A round's
   --    rows carry their own tables in the per-row table, where a block's
   --    base was. Zero with Page_Shift for a cache in blocks.
   --  @param Page_Shift The page's width in positions, as a shift, or
   --    zero for a cache in blocks.
   procedure Attend_And_Feed
     (Query       : Model_Runner.Tensors.Real_Array;
      Residual    : Model_Runner.Tensors.Real_Array;
      Heads       : Natural;
      Head_Size   : Natural;
      Value_Size  : Natural;
      Group_Size  : Natural;
      First       : Natural;
      Last        : Natural;
      K_Base      : Model_Runner.Numerics.Element_Count;
      V_Base      : Model_Runner.Numerics.Element_Count;
      KV_Width    : Natural;
      V_Width     : Natural;
      Scale       : Model_Runner.Numerics.Real;
      Cap         : Model_Runner.Numerics.Real;
      Weight      : Model_Runner.Tensors.View;
      Norm_Weight : Model_Runner.Tensors.Real_Array;
      Epsilon     : Model_Runner.Numerics.Real;
      Gate        : Model_Runner.Tensors.View;
      Up          : Model_Runner.Tensors.View;
      Down        : Model_Runner.Tensors.View;
      Unit        : Natural;
      Into        : Model_Runner.Tensors.Real_Array_Access;
      Ok          : out Boolean;
      Positions   : Natural := 1;
      Window      : Natural := 0;
      Causal      : Boolean := True;
      Max_Bias    : Model_Runner.Numerics.Real := 0.0;
      Packed      : Packed_Cache := Not_Packed;
      Sinks_At    : Natural := 0;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Pages_At   : Natural := 0;
      Page_Shift : Natural := 0);

   --  Several products of the same activation, in one submission.
   --
   --  A layer's queries, keys and values are three matrices read against one
   --  normalized input, and the gate and up projection of a gated
   --  feed-forward are two more; nothing between any of them waits for
   --  anything. Sent one at a time they cost an upload of that input, a
   --  command buffer, a submission and a fence each; sent together they cost
   --  one of each and a dispatch apiece.
   --
   --  The matrices must agree about how wide the activation is, which they do
   --  by construction: they all read the same one. They may differ in every
   --  other way, and for the architectures that fuse their projections into
   --  one tensor they are several views of it.
   --
   --  A caller with no device, or one whose device refuses, gets the same
   --  diagnostics the single dispatch gives.
   --
   --  @param Weights The matrices, in the order their results are wanted.
   --  @param Vector The activation all of them read.
   --  @param Into Receives each matrix's result, one array apiece and in the
   --    same order.
   --  @param Status Success, or why not.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  @param Apart Where each matrix's vector begins, in elements, as a
   --    stride: the first reads from the front, the second from Apart, and
   --    so on. Zero is every matrix reading the same activation whole,
   --    which is what a layer's queries, keys and values are.
   --
   --    It is here for a mixture, whose chosen experts each project a
   --    vector of their own down -- so the products differ in their input
   --    as well as their matrix. Laid end to end in one activation they are
   --    still one submission, which is the whole point of a group.
   procedure Dispatch_Group
     (Weights : Model_Runner.Tensors.View_Group;
      Vector  : Model_Runner.Tensors.Real_Array_Access;
      Into    : Model_Runner.Tensors.Target_Group;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Apart   : Model_Runner.Numerics.Element_Count := 0);

   --  An empty table, for a caller that rotates nothing.
   No_Turns : constant Model_Runner.Numerics.Wide_Real_Array (1 .. 0) :=
     [others => 0.0];

   --  A normalization and the products that read it, in one submission.
   --
   --  The other half of what `Attend_And_Feed` does. A layer normalizes its
   --  input and then multiplies that by three matrices -- the queries, the
   --  keys and the values -- and those were four submissions: the host
   --  normalized and each product went on its own. Normalizing here makes
   --  them one, and the normalized value never leaves the device.
   --
   --  The caller keeps the rotation and the cache write, which is why this
   --  is not the whole first half of a layer: a rotation carries the
   --  architecture's scaling, its ramp and its pairing, and those are not
   --  worth restating in a shader for what they cost.
   --
   --  @param Weights The matrices, in the order their results are wanted.
   --  @param Vector The layer's input, Spread positions of it.
   --  @param Norm_Weight The normalization's weight.
   --  @param Epsilon The floor under its mean square.
   --  @param Spread How many positions the input holds.
   --  @param Into Receives each matrix's result, one array apiece and in the
   --    same order, Spread positions of each.
   --  @param Ok False when the device did not run it, which leaves the
   --    caller to normalize and multiply as it did before.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  @param Turns The cosines and sines the first Turned results are
   --    rotated by, two a pair a position, positions in the order the batch
   --    holds them. Empty where nothing is rotated.
   --  @param Turned How many of the results the rotation reaches, counting
   --    from the first: two for a layer, whose queries and keys turn and
   --    whose values do not.
   --  @param Head_Size How wide a head is, which says how many heads each
   --    rotated result holds.
   --  @param Rotary How many components of a head turn.
   --  @param Split True where a head's pairs are a component and the one
   --    half a rotary further on, false where they are neighbours.
   --  @param Carry_In True where the input is what the sequence before
   --    left on the device rather than Vector, which then says only how
   --    long it is: a token's output head after its last layer.
   procedure Normalize_And_Project
     (Weights     : Model_Runner.Tensors.View_Group;
      Vector      : Model_Runner.Tensors.Real_Array_Access;
      Norm_Weight : Model_Runner.Tensors.Real_Array;
      Epsilon     : Model_Runner.Numerics.Real;
      Into        : Model_Runner.Tensors.Target_Group;
      Ok          : out Boolean;
      Spread      : Model_Runner.Numerics.Element_Count := 1;
      Turns       : Model_Runner.Numerics.Wide_Real_Array := No_Turns;
      Turned      : Natural := 0;
      Head_Size   : Natural := 0;
      Rotary      : Natural := 0;
      Split       : Boolean := False;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In    : Boolean := False);

   --  A mixture's shared expert for one position, sent over and not waited
   --  for: the normalization the feed-forward reads, the gated block, and
   --  its scaling by the logistic of its router's score, over Residual.
   --  The answer stays on the device for Finish_Shared, and the host runs
   --  the chosen experts meanwhile -- a token's eight of them and the
   --  shared one were nine jobs for the pool's eight hands, and the device
   --  stood idle while they ran.
   --
   --  @param Residual The residual after attention, one position.
   --  @param Feed_Norm The normalization's weight.
   --  @param Epsilon Its floor.
   --  @param Gate The shared expert's gate.
   --  @param Up Its projection up.
   --  @param Down Its projection down.
   --  @param Router Its router's row.
   --  @param Ok False where nothing was sent; the host makes it then.
   procedure Start_Shared
     (Residual  : Model_Runner.Tensors.Real_Array_Access;
      Feed_Norm : Model_Runner.Tensors.Real_Array_Access;
      Epsilon   : Model_Runner.Numerics.Real;
      Gate      : Model_Runner.Tensors.View;
      Up        : Model_Runner.Tensors.View;
      Down      : Model_Runner.Tensors.View;
      Router    : Model_Runner.Tensors.Real_Array_Access;
      Ok        : out Boolean);

   --  What Start_Shared left on the device, scaled by its gate, one
   --  position of it. Ok is False where nothing is there to fetch -- none
   --  was started, or something else went over since and wrote where it
   --  lay -- and the host makes it itself.
   --
   --  @param Into Receives the answer, one position wide.
   --  @param Ok True where the answer was fetched.
   procedure Finish_Shared
     (Into : Model_Runner.Tensors.Real_Array_Access;
      Ok   : out Boolean);

   --  Start copying a layer's expert stacks to the device in the
   --  background, for a batch whose mixture the device will run with
   --  stacks it does not hold: the copy runs while the device works on
   --  the layer before, and the layer's sequence takes the copies.
   --
   --  @param Gate The layer's gate stack.
   --  @param Up Its up stack.
   --  @param Down Its down stack.
   procedure Prefetch_Stacks
     (Gate : Model_Runner.Tensors.View;
      Up   : Model_Runner.Tensors.View;
      Down : Model_Runner.Tensors.View);

   --  A whole layer, in one submission.
   --
   --  `Attend_And_Feed` takes its second half and `Normalize_And_Project`
   --  its first, and between them the host rotated and wrote the cache --
   --  which is what made a layer two submissions rather than one. With the
   --  rotation a step and the cache write a step, there is nothing left in
   --  between, and a generated token goes from forty-five submissions to
   --  twenty-three.
   --
   --  Seventeen steps: the normalization, the queries, the keys and the
   --  values, the turning of the first two, the two cache writes,
   --  attention, its projection, the residual join, the second
   --  normalization, both arms of the feed-forward, their combination, the
   --  projection down and the join after it.
   --
   --  The host still gets the keys and the values back, because a session
   --  that later runs on the processor needs its own copy of them. What it
   --  no longer does is stand between two halves of a layer.
   --
   --  @param Residual The layer's input, Positions of it, which the first
   --    join adds to; the second adds to what the first wrote.
   --  @param Attention_Norm The normalization on the way in.
   --  @param Feed_Norm The normalization before the feed-forward.
   --  @param Epsilon The floor under both mean squares.
   --  @param Query The query projection.
   --  @param Key The key projection.
   --  @param Value The value projection.
   --  @param Turns The cosines and sines the queries and keys turn by, two
   --    a pair a position.
   --  @param Head_Size How wide a head is.
   --  @param Rotary How many components of a head turn.
   --  @param Split True where a head's pairs are a component and the one
   --    half a rotary further on.
   --  @param At_Key Where this batch's keys go in the cache, in elements.
   --  @param At_Value Where its values go, in the same buffer.
   --  @param Heads How many heads.
   --  @param Value_Size How wide a value head is.
   --  @param Group_Size How many heads share one group of keys and values.
   --  @param First First cached position the first position may look at.
   --  @param Last The last it may look at.
   --  @param K_Base Where the keys begin.
   --  @param V_Base Where the values begin.
   --  @param KV_Width How far apart one position's keys are.
   --  @param V_Width How far apart its values are.
   --  @param Scale What a score is multiplied by.
   --  @param Cap The bound on a score, or zero for none.
   --  @param Weight The matrix the blend is projected through.
   --  @param Gate The gating arm of the feed-forward.
   --  @param Up The other arm.
   --  @param Down The projection back down to the layer's width.
   --  @param Unit Which unit the combination applies.
   --  @param Keys Receives the rotated keys, Positions of them.
   --  @param Values Receives the values, Positions of them.
   --  @param Into Receives the layer's output, Positions of them.
   --  @param Positions How many positions the layer is given.
   --  @param Window This layer's sliding window, or zero for none.
   --  @param Causal True where a position may see only what precedes it.
   --  @param Max_Bias How steeply a head's attention falls off with
   --    distance, or zero.
   --  @param Ok False when the device did not run it, which leaves the
   --    caller to do the whole of it as it did before.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  @param Carry_In True where this layer's activation is the answer the
   --    layer before it left on the device. Residual is then neither read
   --    nor sent over.
   --  @param Carry_Out True where this layer's answer is to be left on the
   --    device for the next layer to read. Into is then not written.
   --
   --  A layer's answer is the next layer's activation, and between them it
   --  was a megabyte out of the mapped result buffer and the same megabyte
   --  back over. Carried, the last step writes straight into the room the
   --  next layer reads from and neither happens. The first layer of a
   --  batch reads what the host sent and the last writes what the host
   --  reads; the ones between need neither.
   --
   --  @param Mirror True where Keys and Values are to be filled. False
   --    where the caller will read them out of the device's own cache
   --    afterwards instead, which is the same bytes without a step of
   --    this layer's waiting for them.
   --  @param Query_Norm A normalization of every query head after it is
   --    projected and before it is turned, each head over its own mean
   --    square and by this weight, one head wide -- what Qwen3 states.
   --    Null for an architecture without one.
   --  @param Key_Norm The same for every key head, or null.
   --  @param Router A mixture of experts in place of the gated block: the
   --    router's matrix, Experts rows of the width. Present, the router
   --    runs, the routing step chooses, the gathered products read the
   --    chosen slices and the mixing step sums them by their shares and
   --    adds the residual -- the whole of it on the device, for a token --
   --    and Gate, Up and Down are not read. Absent, the gated block as
   --    before.
   --  @param Router_Bias A bias added to the router's scores before the
   --    choosing, or null.
   --  @param Gate_Stack Every expert's gate matrix, one after another.
   --  @param Up_Stack Every expert's up matrix, the same shape.
   --  @param Down_Stack Every expert's down matrix, one after another.
   --  @param Feed One expert's feed width: the rows of a gate or up slice.
   --  @param Used How many experts a position reads.
   --  @param Experts How many experts there are.
   --  @param Packed The session's packed block, where it has one: the
   --    attention step then reads it with the packed kernel, and K_Base
   --    and V_Base go unread.
   --  @param Pack_Keys How the keys are packed into that block as they
   --    are placed, and where; At_Key then goes unread.
   --  @param Pack_Values The same for the values, and At_Value.
   --  @param Unpacked Where a packed session's batch may attend through
   --    the matrix instruction instead: the layer's packed keys and
   --    values are unpacked into the copy first, and the attention reads
   --    them there as an exact session's does. Taken where that kernel
   --    would be the one for the batch, and otherwise not.
   --  @param Sinks_At Where the heads' sinks begin in the cache, in
   --    elements, for a layer that has them, which the caller put there;
   --    zero for none.
   --  @param Alpha The clamped gate's slope, where Unit is three.
   --  @param Limit The clamped gate's limit, where Unit is three.
   --  @param Gate_Bias A mixture's bias on each expert's gate
   --    projection, Experts slices of Feed, or null for none: added to
   --    each member's gate arm before the gate, by a step that reads the
   --    routing for the expert.
   --  @param Up_Bias The same on the up projection, or null.
   --  @param Down_Bias The same on the projection down, Experts slices
   --    of the width, added after it and before the mix, or null.
   --  @param Query_Bias The query projection's bias, added to every
   --    position's queries before they are normalized or turned, or
   --    null for none.
   --  @param Key_Bias The same for the keys, or null.
   --  @param Value_Bias The same for the values, or null; Values then
   --    receives the biased values.
   --  @param Out_Bias The bias on the way out of attention, added to the
   --    projection before the residual join, or null.
   --  @param Post_Attention_Norm The normalization Gemma 2 and 3 put on
   --    what attention produced before it joins the residual, a gain of
   --    Width, or null for none.
   --  @param Post_Feed_Norm The same on what the feed-forward produced,
   --    or null; refused with a mixture, whose sum joins the residual as
   --    it sums -- except After, where it is the normalization of that
   --    sum.
   --  @param Shifted True where the layer's normalizations are the
   --    centred ones with a shift that GPT-2, Phi-2, Falcon and Bert
   --    state: every normalization weight is then twice the width, the
   --    gain and after it the shift.
   --  @param After True for an architecture that normalizes on the way
   --    out of each sublayer, Bert's: Attention_Norm and Feed_Norm are
   --    empty, the projections read the layer's input as it is,
   --    Post_Attention_Norm normalizes the sum of the input and what
   --    attention produced, the feed-forward reads that sum and joins
   --    it, and Post_Feed_Norm normalizes the second sum into the
   --    layer's answer. Both must be present.
   --
   --  @param Head_Gates True for the hybrid architecture's attention
   --    layers, whose query projection is twice as wide -- each head's
   --    queries and then a gate for the head -- and whose blend is
   --    multiplied by the logistic of that gate before the projection
   --    out. The queries and the gates are picked apart on the device,
   --    and the value heads must be as wide as the query heads, since
   --    the gate is elementwise over the blend.
   --  @param Shared_Gate A hybrid mixture's shared expert, the gated
   --    block every position goes through beside its chosen experts:
   --    its gate matrix. Not present for a mixture without one, and
   --    refused without a mixture.
   --  @param Shared_Up The shared expert's up matrix, the same shape.
   --  @param Shared_Down The shared expert's projection down.
   --  @param Shared_Router The row of the width whose score against the
   --    input, through the logistic, scales the shared expert's answer
   --    before it joins the sum.
   --  @param Linear_Mix A hybrid's linear layer in place of attention:
   --    the projection to the mixed row, queries, keys and values one
   --    after another. Present, the layer is the linear one -- the four
   --    projections, the convolution over the memory the ring keeps, the
   --    gated delta rule over the state it keeps, and the projection out
   --    in Weight -- and Query, Key, Value, the cache and the turning go
   --    unread; the feed-forward follows as for any layer.
   --  @param Linear_Z The projection to the gate rows.
   --  @param Linear_Alpha The projection to the alphas, one a value head.
   --  @param Linear_Beta The projection to the betas, one a value head.
   --  @param Conv The convolution's taps, Taps rows of Mix.
   --  @param Numbers A_log a value head, dt's bias a value head, and the
   --    gain a column, one after another.
   --  @param Linear The layer's geometry and the ring, as Add_Conv and
   --    Add_Rule take it, with Region_At the memory's place within a
   --    slot; the three row steps are filled in here.
   --  @param Linear_State_At The state's place within a slot.
   --
   --  The two normalization weights are named by reference, as every
   --  weight the device keeps is: the device remembers a weight by its
   --  address, and an array passed by value is a copy at a new one each
   --  call. Null is a normalization the layer has not got.
   --
   --  Three shapes of the feed-forward besides the gated one and the
   --  mixture: a Feed_Norm that is null with After false runs the
   --  feed-forward beside attention, from the normalization on the way in
   --  (Falcon, Phi-2); a Gate that is not present is the one projection
   --  up with Unit alone on it, and Up_Bias is then that projection's own
   --  one slice rather than a mixture's stack, added before the unit;
   --  Down_Bias is the projection down's one slice for any dense layer,
   --  gated or not, added after it. And a Rotary of zero turns nothing, which is what
   --  an architecture that learned a row a position has: Turns is empty.
   --
   --  A caller must not carry out of a layer unless the next one will be
   --  taken whole as well: a layer that falls back reads the host's copy,
   --  and the host's copy is the thing carrying does not write.
   --  @param Pages_At A cache in pages rather than in blocks: where the
   --    batch's page table for this layer begins, in elements, a word a
   --    page; K_Base and V_Base are then offsets inside a page. A round's
   --    rows carry their own tables in the per-row table, where a block's
   --    base was. Zero with Page_Shift for a cache in blocks.
   --  @param Page_Shift The page's width in positions, as a shift, or
   --    zero for a cache in blocks.
   --  @param First_Position Which position of its session the batch's
   --    first row is, for a cache in pages: where the step that places
   --    puts it, At_Key and At_Value being offsets inside a page.
   --  @param No_Feed The front half alone: the normalization, attention or
   --    the delta rule, the projection out and the join, and no feed-forward
   --    -- the residual after attention lands in Into for the host to run
   --    the feed-forward on. For a mixture too large for the device, whose
   --    experts the processor runs. Refused with Carry_Out and with After.
   procedure Whole_Layer
     (Residual       : Model_Runner.Tensors.Real_Array;
      Attention_Norm : Model_Runner.Tensors.Real_Array_Access;
      Feed_Norm      : Model_Runner.Tensors.Real_Array_Access;
      Epsilon        : Model_Runner.Numerics.Real;
      Query          : Model_Runner.Tensors.View;
      Key            : Model_Runner.Tensors.View;
      Value          : Model_Runner.Tensors.View;
      Turns          : Model_Runner.Numerics.Wide_Real_Array;
      Head_Size      : Natural;
      Rotary         : Natural;
      Split          : Boolean;
      At_Key         : Model_Runner.Numerics.Element_Count;
      At_Value       : Model_Runner.Numerics.Element_Count;
      Heads          : Natural;
      Value_Size     : Natural;
      Group_Size     : Natural;
      First          : Natural;
      Last           : Natural;
      K_Base         : Model_Runner.Numerics.Element_Count;
      V_Base         : Model_Runner.Numerics.Element_Count;
      KV_Width       : Natural;
      V_Width        : Natural;
      Scale          : Model_Runner.Numerics.Real;
      Cap            : Model_Runner.Numerics.Real;
      Weight         : Model_Runner.Tensors.View;
      Gate           : Model_Runner.Tensors.View;
      Up             : Model_Runner.Tensors.View;
      Down           : Model_Runner.Tensors.View;
      Unit           : Natural;
      Keys           : Model_Runner.Tensors.Real_Array_Access;
      Values         : Model_Runner.Tensors.Real_Array_Access;
      Into           : Model_Runner.Tensors.Real_Array_Access;
      Ok             : out Boolean;
      Positions      : Natural := 1;
      Window         : Natural := 0;
      Causal         : Boolean := True;
      Max_Bias       : Model_Runner.Numerics.Real := 0.0;
      Cancel         : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In       : Boolean := False;
      Carry_Out      : Boolean := False;
      Mirror         : Boolean := True;
      Query_Norm     : Model_Runner.Tensors.Real_Array_Access := null;
      Key_Norm       : Model_Runner.Tensors.Real_Array_Access := null;
      Router         : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Router_Bias    : Model_Runner.Tensors.Real_Array_Access := null;
      Gate_Stack     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Up_Stack       : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Down_Stack     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Feed           : Natural := 0;
      Used           : Natural := 0;
      Experts        : Natural := 0;
      Packed         : Packed_Cache := Not_Packed;
      Pack_Keys      : Packing_Shape := Not_Packing;
      Pack_Values    : Packing_Shape := Not_Packing;
      Unpacked       : Unpacking_Shape := Not_Unpacked;
      Sinks_At       : Natural := 0;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias      : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias        : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias      : Model_Runner.Tensors.Real_Array_Access := null;
      Query_Bias     : Model_Runner.Tensors.Real_Array_Access := null;
      Key_Bias       : Model_Runner.Tensors.Real_Array_Access := null;
      Value_Bias     : Model_Runner.Tensors.Real_Array_Access := null;
      Out_Bias       : Model_Runner.Tensors.Real_Array_Access := null;
      Post_Attention_Norm : Model_Runner.Tensors.Real_Array_Access := null;
      Post_Feed_Norm      : Model_Runner.Tensors.Real_Array_Access := null;
      Shifted        : Boolean := False;
      After          : Boolean := False;
      Head_Gates     : Boolean := False;
      Shared_Gate    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Up      : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Down    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Router  : Model_Runner.Tensors.Real_Array_Access := null;
      Linear_Mix     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Z       : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Alpha   : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Beta    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Conv           : Model_Runner.Tensors.Real_Array_Access := null;
      Numbers        : Model_Runner.Tensors.Real_Array_Access := null;
      Linear         : Model_Runner.Platform.Device.Products.Linear_Shape :=
        (others => <>);
      Linear_State_At : Natural := 0;
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0;
      No_Feed        : Boolean := False);

   --  A gated feed-forward block, whole, in one submission.
   --
   --  The gate and up projections read the same normalized input; a unit is
   --  put on the first and multiplied by the second; the down projection
   --  reads that. Sent this way, neither arm nor the combined value ever
   --  leaves the device -- only what the down projection produced comes back.
   --  Sent as separate calls it is two submissions and four arrays crossing
   --  the interface.
   --
   --  Only for the gated arrangement. An architecture with one arm and no
   --  gate has nothing to combine and uses the ordinary dispatch.
   --
   --  @param Gate Matrix for the gate arm.
   --  @param Up Matrix for the other arm.
   --  @param Down Matrix the combined value is read by.
   --  @param Vector The normalized input both arms read.
   --  @param Spread How many positions that input holds. The combining is
   --    elementwise over whatever the arms produce, so a batch needs no
   --    other handling than its length.
   --  @param Unit Which unit the gate arm takes: zero for the
   --    sigmoid-weighted one, one for the Gaussian one.
   --  @param Into Receives what the down projection produced.
   --  @param Status Success, or why not.
   --  @param Cancel Token a caller may set to ask for a stop.
   --  @param Alpha The clamped gate's slope, where Unit is three.
   --  @param Limit The clamped gate's limit, where Unit is three.
   procedure Dispatch_Gated
     (Gate   : Model_Runner.Tensors.View;
      Up     : Model_Runner.Tensors.View;
      Down   : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Spread : Model_Runner.Numerics.Element_Count;
      Unit   : Natural;
      Into   : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0);

   --  The same product for each vector of a batch.
   --
   --  A batch of one is what the evaluator hands a backend that says it does
   --  not batch, and it still comes through this path. So this is not a
   --  refusal but a loop: one whole product per vector, which is the saving
   --  this backend declines to make and the reason it reports that it does
   --  not batch.
   --
   --  @param Weight Weight view; must be binary32.
   --  @param Vectors Count vectors of Weight's column count, one after
   --    another.
   --  @param Count How many.
   --  @param Target Receives Count results of Weight's row count.
   --  @param Cancel Stop request to watch, or null for none, as in Dispatch.
   --  @param Status Success, or what one product would have said.
   --  @param Exact True reads the vectors in binary32 whatever their count:
   --    the row kernel rather than the matrix tile, whose operand is half
   --    precision. For a caller whose vectors go through many products in
   --    a row, where the halves compound; slower, since the row kernel
   --    reads the weights once a group of vectors.
   procedure Dispatch_Batch
     (Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Exact   : Boolean := False);

   --  How many experts one gathered mixture may read at once.
   Max_Members : constant := 16;

   --  How many experts a route may choose. The gather still reads Max_Members
   --  at once, so a wider route is read in chunks; the route buffer and the
   --  route shader hold the whole chosen set. Mirrors Products.Max_Route.
   Max_Route : constant := 64;

   type Member_List is array (1 .. Max_Members) of Natural;

   --  A batch's choices, position by position.
   type Choice_Array is array (Natural range <>) of Natural;

   --  One expert's product over a batch, read out of the stack it is a
   --  slice of.
   --
   --  The same answer Dispatch_Batch gives for the slice's own view, and a
   --  different thing to the device: the stack is what is uploaded and
   --  kept, once, and the slice is an offset into it. A prompt that reads
   --  its experts this way and a token that reads them gathered share one
   --  resident copy of each stack rather than holding a slice beside it.
   --
   --  @param Stack The whole stack, every expert's rows one after another.
   --  @param Each Rows one expert's slice holds.
   --  @param Member Which expert, counting from zero.
   --  @param Vectors Count vectors of the stack's column count.
   --  @param Count How many.
   --  @param Target Receives Count results of Each rows.
   --  @param Status Success, or what one product would have said.
   --  @param Cancel Stop request to watch, or null for none.
   procedure Dispatch_Slice
     (Stack   : Model_Runner.Tensors.View;
      Each    : Model_Runner.Numerics.Element_Count;
      Member  : Natural;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null);

   --  A token's mixture, as one submission: the chosen experts' gate and
   --  up projections gathered into one dispatch each, the gate's unit and
   --  the multiply on the device, and the projections down gathered into
   --  one more, each reading its own expert's gated vector.
   --
   --  What comes back is one vector of the width a projection down makes
   --  for each member, in the order the members were given, unweighted:
   --  the shares and the sum stay with the caller, in the order it has
   --  always added them. Biases the experts carry are not applied here;
   --  a caller whose architecture has them takes the slice-at-a-time road.
   --
   --  @param Gates The gate stack: Members' slices of Feed rows.
   --  @param Ups The up stack, the same shape.
   --  @param Downs The down stack: slices of Width rows of Feed columns.
   --  @param Feed Rows one gate or up slice holds.
   --  @param Width Rows one down slice holds.
   --  @param Members Which experts, counting from zero.
   --  @param Count How many of Members are meant.
   --  @param Unit Which unit the gate applies, as Add_Combination takes it.
   --  @param Vector The normalized activation every gate and up reads.
   --  @param Target Receives Count vectors of Width.
   --  @param Status Success, or the first refusal.
   --  @param Cancel Stop request to watch, or null for none.
   --  @param Alpha The clamped gate's slope, where Unit is three.
   --  @param Limit The clamped gate's limit, where Unit is three.
   --  @param Gate_Bias A bias on each expert's gate projection, Experts
   --    slices of Feed, added to each member's gate arm before the gate,
   --    or null for none.
   --  @param Up_Bias The same on the up projection, or null.
   --  @param Down_Bias The same on the projection down, Experts slices of
   --    Width, added after it, or null.
   procedure Dispatch_Mixture
     (Gates   : Model_Runner.Tensors.View;
      Ups     : Model_Runner.Tensors.View;
      Downs   : Model_Runner.Tensors.View;
      Feed    : Model_Runner.Numerics.Element_Count;
      Width   : Model_Runner.Numerics.Element_Count;
      Members : Member_List;
      Count   : Positive;
      Unit    : Natural;
      Vector  : Model_Runner.Tensors.Real_Array_Access;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias   : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias : Model_Runner.Tensors.Real_Array_Access := null);

   --  One expert's whole feed-forward over a batch, as one submission:
   --  its gate and up slices over every vector, the unit and the multiply
   --  on the device, and its slice down over what that made. The same
   --  four steps Dispatch_Mixture records for a token's several experts,
   --  for one expert and a batch's several positions -- so a prompt and a
   --  token put the gate through the same kernel and agree to the bit.
   --
   --  @param Gates The gate stack, as in Dispatch_Mixture.
   --  @param Ups The up stack.
   --  @param Downs The down stack.
   --  @param Feed Rows one gate or up slice holds.
   --  @param Width Rows one down slice holds.
   --  @param Member Which expert.
   --  @param Unit Which unit the gate applies.
   --  @param Vectors Count vectors of Width.
   --  @param Count How many.
   --  @param Target Receives Count vectors of Width.
   --  @param Status Success, or the first refusal.
   --  @param Cancel Stop request to watch, or null for none.
   --  @param Alpha The clamped gate's slope, where Unit is three.
   --  @param Limit The clamped gate's limit, where Unit is three.
   --  @param Gate_Bias A bias on each expert's gate projection, Experts
   --    slices of Feed, added to each member's gate arm before the gate,
   --    or null for none.
   --  @param Up_Bias The same on the up projection, or null.
   --  @param Down_Bias The same on the projection down, Experts slices of
   --    Width, added after it, or null.
   procedure Dispatch_Expert
     (Gates   : Model_Runner.Tensors.View;
      Ups     : Model_Runner.Tensors.View;
      Downs   : Model_Runner.Tensors.View;
      Feed    : Model_Runner.Numerics.Element_Count;
      Width   : Model_Runner.Numerics.Element_Count;
      Member  : Natural;
      Unit    : Natural;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias   : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias : Model_Runner.Tensors.Real_Array_Access := null);

   --  A batch's routing, decided on the device: the router's product over
   --  every position and the choosing after it, as one submission, with
   --  the choice read back -- Used expert numbers and Used shares a
   --  position, the shares as the bits of a binary32.
   --
   --  Here so that a prompt chooses its experts through the same kernel a
   --  token does. The host's softmax sums in binary64 and the device's in
   --  binary32, and the two can differ in the last bit of a share -- or,
   --  on a near tie, in which expert is chosen -- and a batch and a token
   --  that chose differently would answer differently.
   --
   --  @param Router The router's matrix, Experts rows of the width.
   --  @param Router_Bias A bias added before the choosing, or null.
   --  @param Experts How many experts there are.
   --  @param Used How many a position chooses.
   --  @param Vectors Count normalized positions of the width.
   --  @param Count How many.
   --  @param Choice Receives Count * Used expert numbers, position by
   --    position, best first.
   --  @param Shares Receives Count * Used shares in the same order, each
   --    position's summing to one.
   --  @param Status Success, or the first refusal.
   --  @param Cancel Stop request to watch, or null for none.
   procedure Dispatch_Route
     (Router      : Model_Runner.Tensors.View;
      Router_Bias : Model_Runner.Tensors.Real_Array_Access;
      Experts     : Natural;
      Used        : Natural;
      Vectors     : Model_Runner.Tensors.Real_Array_Access;
      Count       : Model_Runner.Numerics.Element_Count;
      Choice      : out Choice_Array;
      Shares      : out Model_Runner.Numerics.Real_Array;
      Status      : out Model_Runner.Errors.Error_Info;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null);

   --  The experts a front half chose on the device, where it was handed
   --  the layer's router: the front half of a split mixture's layer, for
   --  a token or a short batch -- a drafted round's check -- routes before
   --  it comes home, so the host's experts start from the choice rather
   --  than a product of their own. Found is False where the last front
   --  half routed nothing, or routed with another router or another
   --  number of positions. Taken once.
   --
   --  @param Router The router the host would route with.
   --  @param Used Experts a position takes.
   --  @param Count Positions routed.
   --  @param Choice Receives the experts, position by position, best
   --    first.
   --  @param Shares Receives their shares, renormalized, in the same
   --    order.
   --  @param Found True where the choice was there to take.
   procedure Take_Front_Route
     (Router : Model_Runner.Tensors.View;
      Used   : Natural;
      Count  : Positive;
      Choice : out Choice_Array;
      Shares : out Model_Runner.Numerics.Real_Array;
      Found  : out Boolean);

   --  The most positions a front half routes for the host.
   Front_Route_Most : constant := 8;

   --  Put a matrix on the device and keep it, computing nothing.
   --
   --  What a product does before it dispatches, without the dispatch, so
   --  that a load can put a model's matrices where its tokens will read
   --  them before anyone is waiting: a mixture's experts are touched by
   --  the tokens that route to them, and a fresh process generated its
   --  first hundred tokens at half speed while it uploaded them a few at
   --  a time.
   --
   --  @param Weight The matrix, whole.
   --  @param Status Success, or why the device would not hold it -- which
   --    is not a fault of the model: a product will upload it as it is
   --    wanted, as it always did.
   procedure Hold
     (Weight : Model_Runner.Tensors.View;
      Status : out Model_Runner.Errors.Error_Info);

private

   subtype Real_Array is Model_Runner.Numerics.Real_Array;

end Model_Runner.Backend.Device;
