with Interfaces;

with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  The backend that runs on a device.
--
--  It computes what an evaluation spends its time on -- a matrix against a
--  vector, and the attention that reads a cache -- on whatever compute
--  device the host has, and it is refused work it cannot take rather than
--  approximating it.
--
--  Every format, decoded where the weights lie. The shader has a branch for
--  each of the fifteen formats this program reads and decodes the file's own
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
   --  @param Ok True when the room is there.
   procedure Reserve_Cache
     (Elements : Model_Runner.Numerics.Element_Count;
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
      K_Base     : Natural;
      V_Base     : Natural;
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
   procedure Attend_And_Project
     (Query      : Model_Runner.Tensors.Real_Array;
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
      Weight     : Model_Runner.Tensors.View;
      Into       : Model_Runner.Tensors.Real_Array_Access;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0);

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
   --  @param Lifted True where that weight is lifted by one first.
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
   procedure Attend_And_Feed
     (Query       : Model_Runner.Tensors.Real_Array;
      Residual    : Model_Runner.Tensors.Real_Array;
      Heads       : Natural;
      Head_Size   : Natural;
      Value_Size  : Natural;
      Group_Size  : Natural;
      First       : Natural;
      Last        : Natural;
      K_Base      : Natural;
      V_Base      : Natural;
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
      Lifted      : Boolean := False;
      Max_Bias    : Model_Runner.Numerics.Real := 0.0);

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
   procedure Dispatch_Group
     (Weights : Model_Runner.Tensors.View_Group;
      Vector  : Model_Runner.Tensors.Real_Array_Access;
      Into    : Model_Runner.Tensors.Target_Group;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null);

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
   --  @param Lifted True where that weight is lifted by one first.
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
   procedure Normalize_And_Project
     (Weights     : Model_Runner.Tensors.View_Group;
      Vector      : Model_Runner.Tensors.Real_Array_Access;
      Norm_Weight : Model_Runner.Tensors.Real_Array;
      Epsilon     : Model_Runner.Numerics.Real;
      Into        : Model_Runner.Tensors.Target_Group;
      Ok          : out Boolean;
      Spread      : Model_Runner.Numerics.Element_Count := 1;
      Lifted      : Boolean := False;
      Turns       : Model_Runner.Numerics.Wide_Real_Array := No_Turns;
      Turned      : Natural := 0;
      Head_Size   : Natural := 0;
      Rotary      : Natural := 0;
      Split       : Boolean := False;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null);

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
   --  @param Lifted True where those weights are lifted by one first.
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
   --  A caller must not carry out of a layer unless the next one will be
   --  taken whole as well: a layer that falls back reads the host's copy,
   --  and the host's copy is the thing carrying does not write.
   procedure Whole_Layer
     (Residual       : Model_Runner.Tensors.Real_Array;
      Attention_Norm : Model_Runner.Tensors.Real_Array;
      Feed_Norm      : Model_Runner.Tensors.Real_Array;
      Epsilon        : Model_Runner.Numerics.Real;
      Query          : Model_Runner.Tensors.View;
      Key            : Model_Runner.Tensors.View;
      Value          : Model_Runner.Tensors.View;
      Turns          : Model_Runner.Numerics.Wide_Real_Array;
      Head_Size      : Natural;
      Rotary         : Natural;
      Split          : Boolean;
      At_Key         : Natural;
      At_Value       : Natural;
      Heads          : Natural;
      Value_Size     : Natural;
      Group_Size     : Natural;
      First          : Natural;
      Last           : Natural;
      K_Base         : Natural;
      V_Base         : Natural;
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
      Lifted         : Boolean := False;
      Max_Bias       : Model_Runner.Numerics.Real := 0.0;
      Cancel         : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In       : Boolean := False;
      Carry_Out      : Boolean := False);

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
   procedure Dispatch_Gated
     (Gate   : Model_Runner.Tensors.View;
      Up     : Model_Runner.Tensors.View;
      Down   : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Spread : Model_Runner.Numerics.Element_Count;
      Unit   : Natural;
      Into   : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null);

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
   procedure Dispatch_Batch
     (Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null);

private

   subtype Real_Array is Model_Runner.Numerics.Real_Array;

end Model_Runner.Backend.Device;
