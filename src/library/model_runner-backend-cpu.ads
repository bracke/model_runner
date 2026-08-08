private with Ada.Finalization;

with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  The mandatory CPU backend and its Ada worker pool.
--
--  Concurrency uses Ada tasking and protected objects only. There is no
--  foreign thread pool, and no task is created per row, per block or per
--  token: the workers are created once with the pool and reused for every
--  matrix-vector product.
--
--  Determinism. Work is partitioned by a fixed formula over row indices, each
--  worker writes a disjoint range of the output, and every reduction
--  accumulates in the wide format. A result is therefore bit-identical
--  whatever the worker count, which is what makes `--threads` safe to change
--  without changing what a model produces. The tests assert this directly.
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

   --  Matrix product against several input vectors at once.
   --
   --  The rows are partitioned across workers exactly as Mat_Vec partitions
   --  them, so the result does not depend on the worker count, and a batch of
   --  one is the same computation as Mat_Vec.
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
   procedure Partition
     (Rows    : Element_Count;
      Workers : Share_Count;
      Index   : Share_Count;
      First   : out Element_Count;
      Last    : out Element_Count);

private

   --  One unit of work. The vector and the target are referenced rather than
   --  copied; the caller blocks until every worker has finished, so both stay
   --  alive and unchanged for the whole job.
   type Job is record
      Count  : Element_Count := 1;
      Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access := null;
      Target : Model_Runner.Tensors.Real_Array_Access := null;
      Rows   : Element_Count := 0;
      Team   : Share_Count := 1;
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

   --  A reusable worker. It blocks on the coordinator between jobs, so no task
   --  is created per unit of work.
   task type Worker is
      --  Bind the worker to its pool position. Called once, by the pool.
      entry Start (Index : Worker_Count; Owner : Coordinator_Access);
   end Worker;

   type Worker_Array is array (Worker_Count range <>) of Worker;

   --  Derived from Limited_Controlled so that finalization asks the workers to
   --  finish even when a caller forgets to close the pool. The language waits
   --  for the workers at the end of the frame that declares the pool, so there
   --  is no task to deallocate.
   type Pool (Workers : Worker_Count) is
     limited new Ada.Finalization.Limited_Controlled with record
      Control : aliased Coordinator (Workers);
      Team    : Worker_Array (1 .. Workers);
      Started : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Pool);

end Model_Runner.Backend.CPU;
