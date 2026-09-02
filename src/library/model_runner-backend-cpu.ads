private with Ada.Finalization;
private with System.Atomic_Counters;

with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Quantization.Integers;
with Model_Runner.Tensors;

--  The mandatory CPU backend and its Ada worker pool.
--
--  Concurrency uses Ada tasking and protected objects only. There is no
--  foreign thread pool, and no task is created per row, per block or per
--  token: the workers are created once with the pool and reused for every
--  matrix-vector product.
--
--  Determinism. Work is partitioned by a fixed formula over row indices, each
--  worker writes a disjoint range of the output, every reduction accumulates
--  in the wide format, and a share boundary falls on a multiple of the row
--  tile. A result is therefore bit-identical whatever the worker count,
--  which is what makes `--threads` safe to change without changing what a
--  model produces. The tests assert this directly.
--
--  The tile is the part that was learned rather than designed. A batch is
--  computed a tile of rows at a time and a tile of an odd size takes a
--  different kernel from a full one, so cutting the rows without regard to
--  the tile left a short tile at the end of every share and a batched prompt
--  answered differently at four threads than at three or seven. The claim
--  above stood for as long as the integer tile kernel did, and the test that
--  asserted it used a binary32 weight and one vector, which is the one shape
--  that kernel is never asked for.
--
--  Bounded queue. The pool holds exactly one job at a time and the caller
--  blocks until it completes, so there is no queue that untrusted input can
--  grow. Submitting while the pool is closing is rejected rather than queued.
--
--  Lifetime. A Pool is a discriminated limited object: declare it in the frame
--  that owns it and the language waits for its workers to terminate when that
--  frame exits. Close asks the workers to finish and is idempotent.
--
--  Task safety: one task submits work at a time. The workers synchronize
--  through the protected coordinator and share nothing else.
package Model_Runner.Backend.CPU is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   --  Largest worker count this backend accepts.
   Max_Workers : constant := 64;

   subtype Worker_Count is Positive range 1 .. Max_Workers;

   --  How many pieces a job is cut into.
   --
   --  One more than the worker count, because the task that submits a job
   --  takes a piece of it rather than waiting for the workers to finish. It
   --  has a core either way, and using it to wait was costing one.
   subtype Share_Count is Positive range 1 .. Max_Workers + 1;

   --  Capabilities of the CPU backend at a given worker count.
   --
   --  @param Workers Number of workers the pool was opened with.
   --  @return Capability record.
   function Describe (Workers : Worker_Count := 1) return Capabilities;

   --  A pool of reusable worker tasks.
   type Pool (Workers : Worker_Count) is tagged limited private;

   type Pool_Reference is access all Pool;

   --  Report the worker count a pool was created with.
   --
   --  @param Item Pool to inspect.
   --  @return Worker count.
   function Worker_Total (Item : Pool) return Worker_Count;

   --  Bind the workers to their pool positions.
   --
   --  This cannot happen when the object is created: the language activates a
   --  record's task components at the end of the declaration that creates the
   --  object, so a rendezvous attempted during initialization would wait for a
   --  task that has not started yet. Mat_Vec calls Open on first use, so a
   --  caller cannot forget it; calling it explicitly after declaring the pool
   --  is equivalent. Idempotent.
   --
   --  @param Item Pool to start.
   procedure Open (Item : in out Pool);

   --  Report whether a pool is accepting work.
   --
   --  @param Item Pool to inspect.
   --  @return True until Close is called.
   function Is_Open (Item : Pool) return Boolean;

   --  Ask the workers to finish and stop accepting work. Idempotent.
   --
   --  @param Item Pool to close.
   procedure Close (Item : in out Pool);

   --  Compute a matrix-vector product across the workers.
   --
   --  Every row of Weight is computed exactly once, by exactly one worker,
   --  into its own slot of Target. With one worker this is the same sequence
   --  of operations as the serial path.
   --
   --  @param Item Pool to run on.
   --  @param Weight Weight view with Target'Length rows.
   --  @param Vector Input vector of Weight's column width.
   --  @param Target Output vector of Weight's row count.
   --  @param Status Success, Backend_Closed or Backend_Worker_Failed.
   procedure Mat_Vec
     (Item   : in out Pool;
      Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info);

   --  Compute a matrix-vector product on a possibly absent pool.
   --
   --  A null reference computes serially on the calling task, which is what a
   --  caller that did not ask for parallel execution expects and what every
   --  test that does not exercise the pool uses.
   --
   --  @param Item Pool reference, possibly null.
   --  @param Weight Weight view.
   --  @param Vector Input vector.
   --  @param Target Output vector.
   --  @param Status Success or a backend diagnostic.
   procedure Dispatch
     (Item   : Pool_Reference;
      Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info);

   --  Several matrix products against one input vector, in one job.
   --
   --  The same answers `Dispatch` gives for each of them in turn, to the
   --  bit: the parts share the chunk counter but not their tiles, so every
   --  part's rows are partitioned exactly as they would be alone. What is
   --  saved is the wake and the settle of each product after the first,
   --  which a generated token pays a hundred and fifty-five times.
   --
   --  Up to three matrices; more than that, or matrices that do not agree
   --  on their format and width, are run one at a time as they were.
   --
   --  @param Item Pool to run on.
   --  @param Weights The matrices, in the order their answers are wanted.
   --  @param Vector The input every one of them reads.
   --  @param Into Where each one's answer goes, in the same order.
   --  @param Status Success, Backend_Closed or Backend_Worker_Failed.
   procedure Dispatch_Group
     (Item    : Pool_Reference;
      Weights : Model_Runner.Tensors.View_Group;
      Vector  : Model_Runner.Tensors.Real_Array_Access;
      Into    : Model_Runner.Tensors.Target_Group;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Matrix product against several input vectors at once.
   --
   --  The rows are partitioned across workers exactly as Mat_Vec partitions
   --  them, on boundaries that fall where the row tile does, so the result
   --  does not depend on the worker count, and a batch of one is the same
   --  computation as Mat_Vec.
   --
   --  @param Item Pool to run on.
   --  @param Weight Weight view.
   --  @param Vectors Count input vectors laid end to end.
   --  @param Count Number of input vectors.
   --  @param Target Count output vectors laid end to end.
   --  @param Status Success, Backend_Closed or Backend_Worker_Failed.
   procedure Mat_Mul
     (Item    : in out Pool;
      Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Run a batched product on a pool that may be absent.
   --
   --  @param Item Pool, or null to compute in the calling task.
   --  @param Weight Weight view.
   --  @param Vectors Input vectors.
   --  @param Count Number of input vectors.
   --  @param Target Output vectors.
   --  @param Status Success or a backend error.
   procedure Dispatch_Batch
     (Item    : Pool_Reference;
      Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Workers to open a pool with on a machine of a given size.
   --
   --  One fewer than the cores, because a job is cut into one more share than
   --  there are workers and the task that submits it takes the last one.
   --  Asking for a worker per core instead leaves one more runnable task than
   --  there are cores, the operating system takes a core from a worker, and
   --  the whole job waits for it, because a job is not finished until its
   --  slowest share is.
   --
   --  Two cores are the exception: one worker there is the serial path, which
   --  gives up half the machine, so both are used and the submitting task
   --  competes. That case was not measurable where this was written and is
   --  left as it was rather than changed on reasoning alone.
   --
   --  @param Cores Cores the machine has.
   --  @return Workers to open, never above Max_Workers.
   function Default_Workers (Cores : Positive) return Worker_Count;

   --  Row range one share of a job covers.
   --
   --  Exposed so that the tests can assert the partition is a disjoint cover
   --  of the rows for every share count.
   --
   --  @param Rows Total number of rows.
   --  @param Workers Number of shares the rows are cut into.
   --  @param Index Share position in 1 .. Workers.
   --  @param First First row, zero based.
   --  @param Last Last row, zero based; Last < First when the worker has no
   --    rows, which happens when there are fewer rows than workers.
   --  @param Grain Rows a boundary must fall on. Every share but the last
   --    holds a whole number of these, so a row's position inside its tile
   --    does not depend on how many shares there are.
   procedure Partition
     (Rows    : Element_Count;
      Workers : Share_Count;
      Index   : Share_Count;
      First   : out Element_Count;
      Last    : out Element_Count;
      Grain   : Element_Count := 1);

   --  Something a share of an indexed job can be asked to do.
   --
   --  The pool cuts a count of items into shares the way it cuts the rows of
   --  a matrix, hands each worker its range, and knows nothing else about
   --  the work. It exists because attention is the one part of a forward
   --  pass that ran entirely on the calling task while the workers sat idle,
   --  and because dragging a blend's twenty parameters into this package to
   --  fix that would put the engine's arithmetic in the backend.
   type Task_Item is limited interface;

   --  Do the share from First to Last, inclusive.
   --
   --  @param Item The work.
   --  @param First First index of the share, zero based.
   --  @param Last Last index of the share; Last < First is an empty share
   --    and must do nothing.
   procedure Run
     (Item : in out Task_Item; First : Element_Count; Last : Element_Count)
   is abstract;

   type Task_Item_Access is access all Task_Item'Class;

   --  Cut Items into shares and run Work over each of them.
   --
   --  The submitting task takes the last share itself, exactly as the matrix
   --  product does and for the same reason. Work is referenced rather than
   --  copied and the caller blocks until every worker has finished, so it
   --  stays alive for the whole job.
   --
   --  @param Item Pool to run on, or null to run the whole of it here.
   --  @param Items How many items there are.
   --  @param Work What to do with a share of them.
   --  @param Status Success, or the pool refusing.
   procedure Dispatch_Shares
     (Item   : Pool_Reference;
      Items  : Element_Count;
      Work   : Task_Item_Access;
      Status : out Model_Runner.Errors.Error_Info);

   --  Allow the products that quantize their activations to a byte.
   --
   --  Told rather than asked, and told once before any product is dispatched,
   --  for the same reason Use_Wide_Decoders is: what this selects is
   --  arithmetic, and a run must not change its arithmetic part way through.
   --  A format without an integer kernel, or a width that is not a whole
   --  number of blocks, takes the floating-point path whatever this says.
   --
   --  @param Allowed True to quantize activations before a matrix product.
   procedure Use_Integer_Activations (Allowed : Boolean);

   --  Report what the last such telling said.
   --
   --  @return True when products quantize their activations.
   function Integer_Activations return Boolean;

private

   --  One unit of work. The vector and the target are referenced rather than
   --  copied; the caller blocks until every worker has finished, so both stay
   --  alive and unchanged for the whole job.
   type Signed_Array_Access is
     access Model_Runner.Quantization.Integers.Signed_Array;
   type Sum_Array_Access is
     access Model_Runner.Quantization.Integers.Sum_Array;

   type Job is record
      Count  : Element_Count := 1;
      Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access := null;
      Target : Model_Runner.Tensors.Real_Array_Access := null;
      Rows   : Element_Count := 0;
      Team   : Share_Count := 1;

      --  The activations quantized, when they were. Null means the share
      --  runs the floating-point path, so a job carries which arithmetic it
      --  is rather than reading a flag a worker might see change.
      Values : Signed_Array_Access := null;
      Scales : Model_Runner.Tensors.Real_Array_Access := null;
      Totals : Sum_Array_Access := null;

      --  Indexed work that is not a matrix product. When it is there the
      --  share runs it and nothing else, so a job that never carries one
      --  leaves the product's own path exactly as it was.
      Work   : Task_Item_Access := null;

      --  Two further matrices the same input is multiplied by, each with
      --  its own answer.
      --
      --  A layer multiplies one normalized input by three matrices for
      --  attention -- the queries, the keys and the values -- and by two
      --  more for the gated middle, and each of those was a job of its own:
      --  a wake, a chunk counter and a settle apiece, five times a layer
      --  where two would do. A generated token is a hundred and fifty-five
      --  products and eighty-nine jobs is what those five become.
      --
      --  The rows of the parts are one space the chunk counter walks, and a
      --  chunk never crosses from one part into the next -- each part's
      --  tiles begin at a tile boundary of their own. So a part's rows are
      --  partitioned exactly as they were when it was a job alone, and no
      --  answer moves.
      Weight_Two   : Model_Runner.Tensors.View;
      Target_Two   : Model_Runner.Tensors.Real_Array_Access := null;
      Rows_Two     : Element_Count := 0;

      Weight_Three : Model_Runner.Tensors.View;
      Target_Three : Model_Runner.Tensors.Real_Array_Access := null;
      Rows_Three   : Element_Count := 0;
   end record;

   type Generation_Array is array (Worker_Count) of Natural;

   --  Rendezvous between the submitting task and the workers.
   protected type Coordinator (Team : Worker_Count) is

      --  Wait until job number Generation differs from the one this worker
      --  last ran, or until the pool is closing.
      entry Wait_For_Work (Worker_Count)
        (Current_Job : out Job; Is_Closing : out Boolean);

      --  Publish a job to every worker.
      procedure Post (Item : Job; Accepted : out Boolean);

      --  Record that one worker finished its partition.
      procedure Finished (Failed : Boolean);

      --  Wait until every worker has finished the current job.
      entry Await (Failed : out Boolean);

      --  Stop accepting work and release the workers.
      procedure Shut_Down;

      --  Report whether the pool still accepts work.
      function Accepting return Boolean;

   private
      Current    : Job;
      Generation : Natural := 0;
      Seen       : Generation_Array := [others => 0];
      Remaining  : Natural := 0;
      Any_Failed : Boolean := False;
      Closing    : Boolean := False;
   end Coordinator;

   type Coordinator_Access is access all Coordinator;

   --  The wake path, and nothing else.
   --
   --  A worker that blocks on the coordinator between jobs is asleep in the
   --  kernel, and a job that only takes a couple of hundred microseconds
   --  spends a tenth of that being woken. Generating a token is a hundred
   --  and fifty-five products, so the wake is paid a hundred and fifty-five
   --  times a token, which is what stopped this pool using more than four
   --  shares to generate: past four the wakes cost more than the extra core
   --  brings.
   --
   --  So a worker looks here first, and only blocks when nothing has come
   --  for a while. Ticket counts jobs posted and Left counts the shares of
   --  the current one that have yet to report. Neither decides anything:
   --  the coordinator is still what opens the barrier and what says the job
   --  is done, and a run with the spin never taken is the run this had
   --  before.
   --  How many tiles of a product have been handed out so far.
   --
   --  A job used to be cut into one contiguous range for every worker,
   --  decided before any of them started. That is right when the workers
   --  run at the same speed and wrong when they do not: the job is not
   --  done until its slowest share is, and on a fifteen-watt part sharing
   --  its boost between eight cores they do not. This counter is what a
   --  worker takes its next tile from instead, so a core that finishes
   --  early takes more and the job ends when the work does rather than
   --  when the unluckiest range does.
   type Chunk_Counter is new Integer with Atomic;

   type Wake_Signal is limited record
      Ticket : aliased System.Atomic_Counters.Atomic_Unsigned := 0;
      Left   : aliased System.Atomic_Counters.Atomic_Unsigned := 0;
      Chunk  : aliased Chunk_Counter := 0;
   end record;

   type Wake_Access is access all Wake_Signal;

   --  A reusable worker. It blocks on the coordinator between jobs, so no task
   --  is created per unit of work.
   task type Worker is
      --  Bind the worker to its pool position. Called once, by the pool.
      entry Start
        (Index  : Worker_Count;
         Owner  : Coordinator_Access;
         Waking : Wake_Access);
   end Worker;

   type Worker_Array is array (Worker_Count range <>) of Worker;

   --  Derived from Limited_Controlled so that finalization asks the workers to
   --  finish even when a caller forgets to close the pool. The language waits
   --  for the workers at the end of the frame that declares the pool, so there
   --  is no task to deallocate.
   type Pool (Workers : Worker_Count) is
     limited new Ada.Finalization.Limited_Controlled with record
      Control : aliased Coordinator (Workers);
      Waking  : aliased Wake_Signal;
      Team    : Worker_Array (1 .. Workers);
      Started : Boolean := False;

      --  Where the submitting task leaves the activations it quantized
      --  before it posted the job. One set for the pool, because exactly one
      --  job is outstanding at a time and it is filled before the workers
      --  are told there is one. Grown when a wider batch arrives and never
      --  shrunk.
      Values : Signed_Array_Access := null;
      Scales : Model_Runner.Tensors.Real_Array_Access := null;
      Totals : Sum_Array_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Pool);

end Model_Runner.Backend.CPU;
