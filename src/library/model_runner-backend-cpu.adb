with Ada.Unchecked_Deallocation;

with Model_Runner.Platform;
with Model_Runner.Quantization;

package body Model_Runner.Backend.CPU is

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Tensors.Real_Array_Access;

   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Tensors;

   --------------
   -- Describe --
   --------------

   function Describe (Workers : Worker_Count := 1) return Capabilities is
      Result : Capabilities;
   begin
      Result.Kind := Backend_CPU;
      --  Whatever the decoder decodes. This was a list written out by hand
      --  and it was wrong the moment two formats were added: the decoder
      --  decoded them, the reference backend said so of itself, and this one
      --  refused every model carrying them while nothing in the build had
      --  changed to say why. A capability answered from the code that
      --  provides it cannot drift from it.
      for Format in Model_Runner.GGUF.Tensor_Type loop
         Result.Formats (Format) :=
           Model_Runner.Quantization.Is_Decodable (Format);
      end loop;

      Result.Alignment := 4;
      Result.Supports_Matrix_Vector := True;
      --  Dispatch_Batch is how prefill evaluates several tokens against one
      --  reading of the weights, and Llama calls it. This said False for as
      --  long as that had been true; nothing consults it, which is why the
      --  two could disagree without anything going wrong -- but Supports is
      --  public, and a caller asking whether this backend batches was told
      --  the wrong thing.
      Result.Supports_Batched := True;

      Result.Supports_Parallel := Workers > 1;
      Result.Max_Workers := Max_Workers;
      return Result;
   end Describe;

   ----------------------
   -- Default_Workers --
   ----------------------

   function Default_Workers (Cores : Positive) return Worker_Count is
      Wanted : constant Positive := (if Cores <= 2 then Cores else Cores - 1);
   begin
      return Worker_Count (Positive'Min (Wanted, Max_Workers));
   end Default_Workers;

   ---------------
   -- Partition --
   ---------------

   --  Whether products quantize their activations. Written by one task
   --  before the workers exist and read by them after, which is the same
   --  protocol Model_Runner.Quantization states for its own such flag.
   Quantizing : Boolean := False;

   -------------------------------
   -- Use_Integer_Activations --
   -------------------------------

   procedure Use_Integer_Activations (Allowed : Boolean) is
   begin
      Quantizing := Allowed;
   end Use_Integer_Activations;

   ---------------------------
   -- Integer_Activations --
   ---------------------------

   function Integer_Activations return Boolean is (Quantizing);

   --  Shares for a product of one vector, which is what a generated token
   --  is. Fewer than the machine has, on purpose.
   --
   --  A generated token reads every weight of the model once and multiplies
   --  each of them once, so it is the memory path that answers rather than
   --  the arithmetic -- and that path is saturated well before the cores
   --  are. Measured over three rounds on sixty-four tokens: 2.303 s at
   --  three shares, 2.123 at four, 2.144 at five and 2.187 at eight, for
   --  6.3, 7.3, 8.7 and 12.7 seconds of processor time. Eight is both the
   --  slowest of those and by far the dearest.
   --
   --  A prompt is the other case and keeps every share: the same sweep
   --  reads 1.377 s at three against 0.815 at eight, because a batch shares
   --  one reading of the weights between its tokens and is bound by the
   --  arithmetic instead. So the share count follows the batch, as the row
   --  tile beside it already does.
   Vector_Team : constant Share_Count := 4;

   procedure Partition
     (Rows    : Element_Count;
      Workers : Share_Count;
      Index   : Share_Count;
      First   : out Element_Count;
      Last    : out Element_Count)
   is
      Share : constant Element_Count := Rows / Element_Count (Workers);
      Extra : constant Element_Count := Rows mod Element_Count (Workers);
      Position : constant Element_Count := Element_Count (Index) - 1;
   begin
      --  An empty range is reported as Last < First. It is produced without
      --  ever computing First + Share - 1 for Share = 0, which would underflow
      --  the unsigned element count.
      First := 1;
      Last := 0;

      --  A worker numbered past the end of the team has nothing to do.
      --  That used to be impossible, because every job was cut into one
      --  share for every worker there was; a job that asks for fewer makes
      --  it ordinary, and without this the arithmetic below would hand such
      --  a worker a range past the last row rather than an empty one.
      if Rows = 0 or else Index > Workers then
         return;
      end if;

      --  The first Extra workers take one row more than the rest. The ranges
      --  are contiguous and depend only on the indices, so the same worker
      --  count always produces the same split.
      if Position < Extra then
         First := Position * (Share + 1);
         Last := First + Share;
      elsif Share > 0 then
         First := Extra * (Share + 1) + (Position - Extra) * Share;
         Last := First + Share - 1;
      end if;
   end Partition;

   -----------------
   -- Coordinator --
   -----------------

   protected body Coordinator is

      --  Opened for the workers this job asked for and no others.
      --
      --  A worker outside the team leaves Seen (Index) where it was and
      --  takes the next job instead, which is what makes a smaller team
      --  cost nothing rather than costing a wake. Posting a job used to
      --  open every worker's barrier whatever the team, so cutting a job's
      --  team saved the memory traffic and paid for it in wake-ups: a
      --  quarter less processor time for three per cent more wall, which is
      --  the wrong side of the trade and is why this is here.
      entry Wait_For_Work (for Index in Worker_Count)
        (Current_Job : out Job; Is_Closing : out Boolean)
        when Closing
             or else (Generation /= Seen (Index)
                      and then Share_Count (Index) < Current.Team) is
      begin
         Seen (Index) := Generation;
         Current_Job := Current;
         Is_Closing := Closing;
      end Wait_For_Work;

      procedure Post (Item : Job; Accepted : out Boolean) is
      begin
         if Closing then
            --  Work submitted while closing is rejected, never queued.
            Accepted := False;
            return;
         end if;

         Current := Item;
         Any_Failed := False;

         --  How many workers will report, which is how many the barrier
         --  above will open for: the job's team less the share the
         --  submitting task takes itself, and never more than there are.
         --  Team here is the pool's, the discriminant; Item.Team is the
         --  job's, and before a job could ask for fewer the two agreed.
         Remaining :=
           Natural (Share_Count'Min (Share_Count (Team), Item.Team - 1));
         Generation := Generation + 1;
         Accepted := True;
      end Post;

      procedure Finished (Failed : Boolean) is
      begin
         if Failed then
            Any_Failed := True;
         end if;
         if Remaining > 0 then
            Remaining := Remaining - 1;
         end if;
      end Finished;

      entry Await (Failed : out Boolean) when Remaining = 0 is
      begin
         Failed := Any_Failed;
      end Await;

      procedure Shut_Down is
      begin
         Closing := True;
         Remaining := 0;
      end Shut_Down;

      function Accepting return Boolean is (not Closing);

   end Coordinator;

   ------------
   -- Worker --
   ------------

   --  Give back the pool's quantization buffers.
   procedure Free_Packed (Item : in out Pool) is
      procedure Release is new Ada.Unchecked_Deallocation
        (Model_Runner.Quantization.Integers.Signed_Array,
         Signed_Array_Access);
      procedure Release is new Ada.Unchecked_Deallocation
        (Model_Runner.Quantization.Integers.Sum_Array, Sum_Array_Access);
   begin
      Release (Item.Values);
      Release (Item.Totals);
      T.Free (Item.Scales);
   end Free_Packed;

   --  Quantize a job's activations into the pool's own buffers.
   --
   --  Once per matrix product, by the task that submits it, before the
   --  workers are told there is one -- not once per share. Quantizing per
   --  share would be a copy of the vector for every worker and the same
   --  answer, since this is a pure function of its input; doing it here is
   --  also what keeps a result independent of the worker count, of the batch
   --  width and of whether a pool exists at all.
   --
   --  Answers False when the arithmetic was not asked for, when the format
   --  has no integer kernel, when the width is not a whole number of blocks,
   --  or when the vector holds a value that has no nearest byte. The job
   --  then carries no quantized activations and every share runs the
   --  floating-point path.
   function Prepare_Packed
     (Item   : in out Pool;
      Weight : T.View;
      Vector : T.Real_Array_Access;
      Count  : Element_Count) return Boolean
   is
      package QI renames Model_Runner.Quantization.Integers;

      Columns  : constant Element_Count := Weight.Columns;
      Elements : constant Element_Count := Count * Columns;
      Blocks   : constant Element_Count :=
        (if Columns = 0 then 0 else Elements / QI.Activation_Block);
      Ok       : Boolean;
   begin
      if not Quantizing
        or else Vector = null
        or else Count = 0
        or else not QI.Packs_Vectors (Weight.Format, Count)
        or else not QI.Is_Packable (Columns)
        or else Vector.all'Length < Elements
      then
         return False;
      end if;

      if Item.Values = null or else Item.Values.all'Length < Elements then
         Free_Packed (Item);
         Item.Values := new QI.Signed_Array (0 .. Elements - 1);
         Item.Totals := new QI.Sum_Array (0 .. Blocks - 1);
         T.Allocate (Blocks, Item.Scales);
      end if;

      if Item.Values = null or else Item.Scales = null
        or else Item.Totals = null
      then
         return False;
      end if;

      QI.Quantize_Vectors
        (Vectors => Vector.all,
         Count   => Count,
         Columns => Columns,
         Values  => Item.Values.all,
         Scales  => Item.Scales.all,
         Totals  => Item.Totals.all,
         Ok      => Ok);

      return Ok;
   end Prepare_Packed;

   --  One product on the calling task, by whichever arithmetic is in force.
   --
   --  The serial path has no pool to keep buffers on, so it quantizes into
   --  buffers of its own and gives them back. That is one pass over the
   --  activation and one allocation per product, against a pass over every
   --  row of the weights -- and the alternative was worse than the cost:
   --  this path used to run the floating-point arithmetic whatever the run
   --  had asked for, silently, so a single-threaded run got none of what it
   --  asked for and a sweep that compared through it compared nothing.
   procedure Serially
     (Weight : T.View;
      Vector : T.Real_Array_Access;
      Count  : Element_Count;
      Target : T.Real_Array_Access)
   is
      package QI renames Model_Runner.Quantization.Integers;

      procedure Release is new Ada.Unchecked_Deallocation
        (QI.Signed_Array, Signed_Array_Access);
      procedure Release is new Ada.Unchecked_Deallocation
        (QI.Sum_Array, Sum_Array_Access);

      Columns  : constant Element_Count := Weight.Columns;
      Elements : constant Element_Count := Count * Columns;

      Values  : Signed_Array_Access := null;
      Scales  : T.Real_Array_Access := null;
      Totals  : Sum_Array_Access := null;
      Handled : Boolean := False;
      Ok      : Boolean := False;
   begin
      if Vector = null or else Target = null
        or else Weight.Rows = 0 or else Count = 0
      then
         return;
      end if;

      if Quantizing
        and then QI.Packs_Vectors (Weight.Format, Count)
        and then QI.Is_Packable (Columns)
        and then Vector.all'Length >= Elements
      then
         declare
            Blocks : constant Element_Count :=
              Elements / QI.Activation_Block;
         begin
            Values := new QI.Signed_Array (0 .. Elements - 1);
            Totals := new QI.Sum_Array (0 .. Blocks - 1);
            T.Allocate (Blocks, Scales);

            if Values /= null and then Totals /= null and then Scales /= null
            then
               QI.Quantize_Vectors
                 (Vector.all, Count, Columns, Values.all, Scales.all,
                  Totals.all, Ok);
            end if;

            if Ok then
               T.Mat_Mul_Range_Packed
                 (Weight, Values.all, Scales.all, Totals.all, Count,
                  Target.all, 0, Weight.Rows - 1, Handled);
            end if;
         end;

         Release (Values);
         Release (Totals);
         T.Free (Scales);
      end if;

      if not Handled then
         T.Mat_Mul_Range
           (Weight, Vector.all, Count, Target.all, 0, Weight.Rows - 1);
      end if;
   end Serially;

   ------------------------
   -- Dispatch_Shares --
   ------------------------

   procedure Dispatch_Shares
     (Item   : Pool_Reference;
      Items  : Element_Count;
      Work   : Task_Item_Access;
      Status : out E.Error_Info)
   is
      Job_Of : Job;
      Taken  : Boolean;
      Failed : Boolean;
      Mine   : Boolean := False;
   begin
      Status := E.Success;

      if Work = null or else Items = 0 then
         return;
      end if;

      --  No pool, or one worker: the calling task does the whole of it,
      --  which is what the serial matrix path does beside this.
      if Item = null then
         Work.all.Run (0, Items - 1);
         return;
      end if;

      Open (Item.all);
      if not Is_Open (Item.all) then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Job_Of :=
        (Weight => <>,
         Count  => 1,
         Vector => null,
         Target => null,
         Rows   => Items,
         Team   => Item.Workers + 1,
         Values => null,
         Scales => null,
         Totals => null,
         Work   => Work);

      Item.Control.Post (Job_Of, Taken);
      if not Taken then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      --  The submitting task takes the last share rather than waiting, for
      --  the reason written out above Mat_Vec.
      declare
         First, Last : Element_Count;
      begin
         Partition (Items, Job_Of.Team, Job_Of.Team, First, Last);
         if First <= Last then
            Work.all.Run (First, Last);
         end if;
      exception
         when others =>
            Mine := True;
      end;

      Item.Control.Await (Failed);

      if Failed or else Mine then
         Status := E.Make (E.Backend_Worker_Failed);
      end if;
   end Dispatch_Shares;

   --  One share of a job, by whichever arithmetic the job carries.
   --
   --  The integer path is asked first and may refuse -- a format without an
   --  integer kernel, a width that is not a whole number of blocks -- and a
   --  refusal is a share nobody has computed, so the floating-point path
   --  runs it instead. Refusing is all or nothing over the range, so no row
   --  is computed twice and none is left at zero.
   procedure Take_Share
     (Work : Job; First : Element_Count; Last : Element_Count)
   is
      Handled : Boolean := False;
   begin
      if First > Last then
         return;
      end if;

      --  Work that is not a matrix product, and nothing else if so.
      if Work.Work /= null then
         Work.Work.all.Run (First, Last);
         return;
      end if;

      if Work.Vector = null or else Work.Target = null then
         return;
      end if;

      if Work.Values /= null
        and then Work.Scales /= null
        and then Work.Totals /= null
      then
         T.Mat_Mul_Range_Packed
           (Work.Weight, Work.Values.all, Work.Scales.all, Work.Totals.all,
            Work.Count, Work.Target.all, First, Last, Handled);
      end if;

      if not Handled then
         T.Mat_Mul_Range
           (Work.Weight, Work.Vector.all, Work.Count,
            Work.Target.all, First, Last);
      end if;
   end Take_Share;

   task body Worker is
      Position : Worker_Count := 1;
      Control  : Coordinator_Access := null;
      Current  : Job;
      Closing  : Boolean := False;
      Failed   : Boolean;
   begin
      --  A pool can be created and then never used -- a command that fails
      --  while loading the model, for instance. The terminate alternative lets
      --  such a worker end with its master instead of waiting for a Start that
      --  will never come, which would hang the frame that declared the pool.
      select
         accept Start (Index : Worker_Count; Owner : Coordinator_Access) do
            Position := Index;
            Control := Owner;
         end Start;
      or
         terminate;
      end select;

      loop
         Control.Wait_For_Work (Position) (Current, Closing);
         exit when Closing;

         Failed := False;

         begin
            declare
               First, Last : Element_Count;
            begin
               Partition (Current.Rows, Current.Team, Position, First, Last);

               Take_Share (Current, First, Last);
            end;
         exception
            --  A worker failure is reported to the coordinator rather than
            --  killing the task, so the pool stays usable and the submitting
            --  task learns about it.
            when others =>
               Failed := True;
         end;

         Control.Finished (Failed);
      end loop;
   exception
      when others =>
         if Control /= null then
            Control.Finished (True);
         end if;
   end Worker;

   ----------
   -- Open --
   ----------

   procedure Open (Item : in out Pool) is
   begin
      if Item.Started then
         return;
      end if;

      for Index in 1 .. Item.Workers loop
         Item.Team (Index).Start (Index, Item.Control'Unchecked_Access);
      end loop;
      Item.Started := True;
   end Open;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Pool) is
   begin
      Close (Item);
   end Finalize;

   -------------------
   -- Worker_Total --
   -------------------

   function Worker_Total (Item : Pool) return Worker_Count is (Item.Workers);

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : Pool) return Boolean
   is (Item.Started and then Item.Control.Accepting);

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Pool) is
   begin
      Item.Control.Shut_Down;
      Free_Packed (Item);
   exception
      when others =>
         null;
   end Close;

   --------------
   -- Mat_Vec --
   --------------

   procedure Mat_Vec
     (Item   : in out Pool;
      Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Work        : Job;
      Accepted    : Boolean;
      Failed      : Boolean;
      Mine_Failed : Boolean := False;
   begin
      Status := E.Success;

      --  Bind the workers on first use. Doing it here rather than during
      --  initialization is what keeps the rendezvous after task activation.
      Open (Item);

      if not Is_Open (Item) then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Work :=
        (Weight => Weight,
         Count  => 1,
         Vector => Vector,
         Target => Target,
         Rows   => Weight.Rows,
         Team   => Item.Workers + 1,
         Values => null,
         Scales => null,
         Totals => null,
         Work   => null);

      if Prepare_Packed (Item, Weight, Vector, 1) then
         Work.Values := Item.Values;
         Work.Scales := Item.Scales;
         Work.Totals := Item.Totals;

         --  And now, and only now, the smaller team.
         --
         --  The share count is asked after the arithmetic is known because
         --  the two cases want different answers and asking before gets one
         --  of them wrong. The byte path reads every weight once and
         --  multiplies it once, so it is the memory that answers and four
         --  shares saturate it; the floating-point path does four times the
         --  arithmetic on the same bytes and is not memory-bound at all --
         --  cutting its team measured twelve tokens at 1.806 s against
         --  1.365, a third slower, which is what said this test belongs
         --  here rather than above.
         Work.Team := Share_Count'Min (Item.Workers + 1, Vector_Team);
      end if;

      --  Exactly one job is outstanding at a time, so the queue is bounded by
      --  construction and there is nothing for a hostile input to grow.
      Item.Control.Post (Work, Accepted);
      if not Accepted then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      --  The submitting task takes the last share rather than waiting for
      --  the workers to finish it. Waiting is what it used to do, and it
      --  cost a core: with one worker per core, the waiting task and the
      --  workers together are one more runnable task than there are cores,
      --  so the operating system takes a core away from a worker and the
      --  whole job waits for it. Pinned to one processor per core, eight
      --  workers measured 3.7x where seven measured 5.0x, which is that
      --  effect with nowhere to hide.
      declare
         First, Last : Element_Count;
      begin
         Partition (Work.Rows, Work.Team, Work.Team, First, Last);
         if First <= Last
           and then Work.Vector /= null
           and then Work.Target /= null
         then
            Take_Share (Work, First, Last);
         end if;
      exception
         --  Reported the way a worker's failure is, after the workers are
         --  collected: leaving before they finish would free the vector and
         --  the target under them.
         --
         --  Nothing reaches this through this package. Mat_Mul_Range checks
         --  every shape it is given and returns rather than raising, so a
         --  malformed request does no work instead of failing, and this is a
         --  net for what nobody thought of rather than a path anything
         --  travels. Shares_Cannot_Raise in the tests holds those checks, and
         --  fails if one is removed, which is the warning that this handler
         --  has become reachable and now wants a test of its own.
         when others =>
            Mine_Failed := True;
      end;

      Item.Control.Await (Failed);

      if Failed or else Mine_Failed then
         Status := E.Make (E.Backend_Worker_Failed);
         E.Add_Integer (Status, "workers", Long_Long_Integer (Item.Workers));
      end if;
   end Mat_Vec;

   ---------------
   -- Dispatch --
   ---------------

   procedure Dispatch
     (Item   : Pool_Reference;
      Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info) is
   begin
      if Item = null then
         --  Serial path, on the calling task. Identical results to the
         --  parallel path, because the partition never changes a row's value.
         Status := E.Success;
         Serially (Weight, Vector, 1, Target);
      else
         Mat_Vec (Item.all, Weight, Vector, Target, Status);
      end if;
   end Dispatch;

   ---------------
   -- Mat_Mul --
   ---------------

   procedure Mat_Mul
     (Item    : in out Pool;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Work        : Job;
      Accepted    : Boolean;
      Failed      : Boolean;
      Mine_Failed : Boolean := False;
   begin
      Status := E.Success;

      Open (Item);

      if not Is_Open (Item) then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Work :=
        (Weight => Weight,
         Count  => Count,
         Vector => Vectors,
         Target => Target,
         Rows   => Weight.Rows,
         Team   => Item.Workers + 1,
         Values => null,
         Scales => null,
         Totals => null,
         Work   => null);

      if Prepare_Packed (Item, Weight, Vectors, Count) then
         Work.Values := Item.Values;
         Work.Scales := Item.Scales;
         Work.Totals := Item.Totals;
      end if;

      Item.Control.Post (Work, Accepted);
      if not Accepted then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      --  The submitting task takes the last share rather than waiting for
      --  the workers to finish it. Waiting is what it used to do, and it
      --  cost a core: with one worker per core, the waiting task and the
      --  workers together are one more runnable task than there are cores,
      --  so the operating system takes a core away from a worker and the
      --  whole job waits for it. Pinned to one processor per core, eight
      --  workers measured 3.7x where seven measured 5.0x, which is that
      --  effect with nowhere to hide.
      declare
         First, Last : Element_Count;
      begin
         Partition (Work.Rows, Work.Team, Work.Team, First, Last);
         if First <= Last
           and then Work.Vector /= null
           and then Work.Target /= null
         then
            Take_Share (Work, First, Last);
         end if;
      exception
         --  Reported the way a worker's failure is, after the workers are
         --  collected: leaving before they finish would free the vector and
         --  the target under them.
         --
         --  Nothing reaches this through this package. Mat_Mul_Range checks
         --  every shape it is given and returns rather than raising, so a
         --  malformed request does no work instead of failing, and this is a
         --  net for what nobody thought of rather than a path anything
         --  travels. Shares_Cannot_Raise in the tests holds those checks, and
         --  fails if one is removed, which is the warning that this handler
         --  has become reachable and now wants a test of its own.
         when others =>
            Mine_Failed := True;
      end;

      Item.Control.Await (Failed);

      if Failed or else Mine_Failed then
         Status := E.Make (E.Backend_Worker_Failed);
      end if;
   end Mat_Mul;

   ---------------------
   -- Dispatch_Batch --
   ---------------------

   procedure Dispatch_Batch
     (Item    : Pool_Reference;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      if Item = null then
         Status := E.Success;
         Serially (Weight, Vectors, Count, Target);
      else
         Mat_Mul (Item.all, Weight, Vectors, Count, Target, Status);
      end if;
   end Dispatch_Batch;

begin
   --  Asked here and not where it is used. The decoders interpret what a
   --  model file holds and may not reach a host; this backend runs them and
   --  may, so the question is asked once, at elaboration, before any
   --  container has been opened.
   Model_Runner.Quantization.Use_Wide_Decoders
     (Model_Runner.Platform.Wide_Vectors);
   Model_Runner.Quantization.Integers.Use_Wide_Rows
     (Model_Runner.Platform.Wide_Vectors);
   Model_Runner.Quantization.Integers.Use_Deep_Rows
     (Model_Runner.Platform.Byte_Products);
end Model_Runner.Backend.CPU;
