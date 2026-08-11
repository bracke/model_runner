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

      if Rows = 0 then
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

      entry Wait_For_Work (for Index in Worker_Count)
        (Current_Job : out Job; Is_Closing : out Boolean)
        when Closing or else Generation /= Seen (Index) is
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
         Remaining := Natural (Team);
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

               if First <= Last
                 and then Current.Vector /= null
                 and then Current.Target /= null
               then
                  T.Mat_Mul_Range
                    (Current.Weight, Current.Vector.all, Current.Count,
                     Current.Target.all, First, Last);
               end if;
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
         Team   => Item.Workers + 1);

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
            T.Mat_Mul_Range
              (Work.Weight, Work.Vector.all, Work.Count,
               Work.Target.all, First, Last);
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
         if Vector /= null and then Target /= null and then Weight.Rows > 0 then
            T.Mat_Vec_Range (Weight, Vector.all, Target.all, 0, Weight.Rows - 1);
         end if;
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
         Team   => Item.Workers + 1);

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
            T.Mat_Mul_Range
              (Work.Weight, Work.Vector.all, Work.Count,
               Work.Target.all, First, Last);
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
         if Vectors /= null and then Target /= null
           and then Weight.Rows > 0 and then Count > 0
         then
            T.Mat_Mul_Range
              (Weight, Vectors.all, Count, Target.all, 0, Weight.Rows - 1);
         end if;
      else
         Mat_Mul (Item.all, Weight, Vectors, Count, Target, Status);
      end if;
   end Dispatch_Batch;

end Model_Runner.Backend.CPU;
