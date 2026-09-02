with Ada.Unchecked_Deallocation;

with System.Atomic_Operations.Integer_Arithmetic;
with System.Machine_Code;

with Model_Runner.Kernels;
with Model_Runner.Platform;
with Model_Runner.Quantization;

package body Model_Runner.Backend.CPU is

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Tensors.Real_Array_Access;

   package AC renames System.Atomic_Counters;
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Tensors;

   --  How long a task looks before it blocks.
   --
   --  Long enough to cover the gap between one product and the next, which
   --  on this machine is a few microseconds of host work -- normalizing,
   --  rotating, quantizing the activation -- and short enough that a pool
   --  with nothing coming stops burning a core almost at once. A worker
   --  that spins the whole budget and finds nothing has cost one core about
   --  ten microseconds and then goes to sleep exactly as it used to.
   Spin_Budget : constant := 20_000;

   --  Wait for a job without leaving the processor, for a while.
   procedure Watch
     (Waking : Wake_Access; Mine : AC.Atomic_Unsigned);

   --  Wait for the shares to report without leaving the processor, for a
   --  while.
   procedure Settle (Waking : Wake_Access);

   --  Say that a job of this many shares has been posted.
   procedure Announce (Waking : Wake_Access; Shares : Natural);

   package Chunks is new System.Atomic_Operations.Integer_Arithmetic
     (Chunk_Counter);

   --  Every tile of a product this task can get, one at a time.
   --
   --  The grid is anchored at row zero and a tile is never split, so which
   --  task computes a row does not change how its row is summed and the
   --  answer is bit for bit what a fixed cut produced. What changes is only
   --  who does it.
   procedure Take_Chunks
     (Waking : Wake_Access;
      Work   : Job;
      Grain  : Element_Count);

   -----------
   -- Watch --
   -----------

   procedure Watch (Waking : Wake_Access; Mine : AC.Atomic_Unsigned) is
      use type AC.Atomic_Unsigned;
   begin
      if Waking = null then
         return;
      end if;

      for Turn in 1 .. Spin_Budget loop
         exit when Waking.Ticket /= Mine;

         --  The instruction that tells the processor this is a spin: it
         --  frees the pipeline for the other thread on the core and takes
         --  the memory-order penalty out of the loop's exit.
         System.Machine_Code.Asm ("pause", Volatile => True);
      end loop;
   end Watch;

   ------------
   -- Settle --
   ------------

   procedure Settle (Waking : Wake_Access) is
      use type AC.Atomic_Unsigned;
   begin
      if Waking = null then
         return;
      end if;

      for Turn in 1 .. Spin_Budget loop
         exit when Waking.Left = 0;
         System.Machine_Code.Asm ("pause", Volatile => True);
      end loop;
   end Settle;

   --------------
   -- Announce --
   --------------

   procedure Announce (Waking : Wake_Access; Shares : Natural) is
   begin
      if Waking = null then
         return;
      end if;

      --  The count and the tile counter first and the ticket second, so a
      --  worker that wakes on the ticket cannot see either belonging to the
      --  job before it.
      Waking.Left := AC.Atomic_Unsigned (Shares);
      Waking.Chunk := 0;
      AC.Increment (Waking.Ticket);
   end Announce;

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
   --  the arithmetic -- and that path is saturated before the cores are.
   --
   --  It was four, and four was measured against a pool that cut a job into
   --  one fixed range for every share. Under that pool a fifth and a sixth
   --  share bought nothing and cost a straggler: 2.303 s at three, 2.123 at
   --  four, 2.144 at five and 2.187 at eight, over three rounds of
   --  sixty-four tokens. With the shares handed out a tile at a time
   --  instead, the same sweep reads
   --
   --    three   2.047 s   6.77 s of processor time
   --    four    1.872     7.91
   --    five    1.812     9.35
   --    six     1.794    10.88
   --    eight   1.790    14.08
   --
   --  -- and five is the one to take. Alternated against four over three
   --  rounds, with every reading of one arm below every reading of the
   --  other, five reads 1.800 s against 1.849 for 9.29 seconds of processor
   --  time against 7.87: two and seven tenths per cent of the wall for
   --  eighteen more of the processor. Six reads 1.790 against the same
   --  1.847 for 10.84 -- three and a tenth for thirty-eight -- and eight is
   --  level with six again for fifty. Five takes seven eighths of what
   --  there is to take for less than half of what six spends on it, and on
   --  a part sharing fifteen watts with a device that is the same trade the
   --  worker default is chosen on.
   --
   --  A prompt is the other case and keeps every share: a batch shares one
   --  reading of the weights between its tokens and is bound by the
   --  arithmetic instead. So the share count follows the batch, as the row
   --  tile beside it already does.
   Vector_Team : constant Share_Count := 5;

   --  Below this much arithmetic a job is done by the task that submits it
   --  rather than shared out.
   --
   --  A generated token's small work -- two normalizations, two residual
   --  joins and the gated middle of the feed-forward -- is one position
   --  each, a few thousand elements, against a wake and a settle of tens of
   --  microseconds. Five of those a layer, twenty-two layers, is a hundred
   --  and ten jobs a token whose arithmetic is a fraction of what posting
   --  them costs. Measured rather than reasoned: see `### The jobs that were
   --  not worth waking anyone for` in the README.
   Inline_Floor : constant Element_Count := 1_048_576;

   procedure Partition
     (Rows    : Element_Count;
      Workers : Share_Count;
      Index   : Share_Count;
      First   : out Element_Count;
      Last    : out Element_Count;
      Grain   : Element_Count := 1)
   is
      --  Rows counted in whole grains, the last of them short where the
      --  matrix does not end on one.
      --
      --  A product is computed a tile of rows at a time and a tile of an odd
      --  size takes a different kernel from a full one, which sums the same
      --  products in a different order. Cutting the rows without regard to
      --  the tile put a short tile at the end of every share, so a row's
      --  answer depended on how many shares there were: the same model, the
      --  same prompt and the same seed generated different text at
      --  --threads 4 than at 3 or 7, from the forty-third token, and the
      --  claim beside this that a result is bit-identical whatever the
      --  worker count was false for a batched prompt.
      --
      --  So a boundary falls on a grain. Every share but the last holds a
      --  whole number of tiles, the tile grid is anchored at row zero
      --  wherever the share boundaries land, and the only short tile in a
      --  product is the one the matrix's own row count leaves -- which is
      --  the same short tile the serial path has.
      Units : constant Element_Count :=
        (if Grain <= 1 then Rows else (Rows + Grain - 1) / Grain);

      Share : constant Element_Count := Units / Element_Count (Workers);
      Extra : constant Element_Count := Units mod Element_Count (Workers);
      Position : constant Element_Count := Element_Count (Index) - 1;

      Step : constant Element_Count :=
        (if Grain <= 1 then 1 else Grain);
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
         First := Position * (Share + 1) * Step;
         Last := First + (Share + 1) * Step - 1;
      elsif Share > 0 then
         First :=
           (Extra * (Share + 1) + (Position - Extra) * Share) * Step;
         Last := First + Share * Step - 1;
      end if;

      --  The grain the matrix's own row count leaves short.
      if Last > Rows - 1 then
         Last := Rows - 1;
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
   --  A share of the packing, for the dispatch below.
   --
   --  Ok is set by every share and only ever to False, so the shares race
   --  to write the same value and a caller reading it after they are all
   --  collected sees True only where none of them refused.
   type Packing_Share is limited new Task_Item with record
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Element_Count;
      Columns : Element_Count;
      Values  : Signed_Array_Access;
      Scales  : Model_Runner.Tensors.Real_Array_Access;
      Totals  : Sum_Array_Access;
      Ok      : Boolean;
   end record;

   overriding procedure Run
     (Share : in out Packing_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Packing_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      Done : Boolean;
   begin
      if From > To then
         return;
      end if;

      Model_Runner.Quantization.Integers.Quantize_Blocks
        (Vectors => Share.Vectors.all,
         Count   => Share.Count,
         Columns => Share.Columns,
         First   => From,
         Last    => To,
         Values  => Share.Values.all,
         Scales  => Share.Scales.all,
         Totals  => Share.Totals.all,
         Ok      => Done);

      if not Done then
         Share.Ok := False;
      end if;
   end Run;

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

      --  Shared where there is enough of it to be worth a dispatch.
      --
      --  This runs before the workers are woken and cannot be folded into
      --  the product's own shares: that job is cut by rows of the weight
      --  matrix and every worker needs all of the activation, so none of
      --  them can start until the whole of it is packed. Profiled by
      --  thread on a 1419-token prompt it is one and a half per cent of
      --  the program's samples and all of them on one thread of eight,
      --  which is about nine per cent of the clock.
      --
      --  So it is a dispatch of its own, before the product's. A block is
      --  independent of every other -- its own scale, its own bytes, its
      --  own total -- so the split is exact and no digest moves.
      --
      --  The bound is what stops this costing more than it saves. A wake
      --  and a barrier are not free, and a run of a few blocks is packed
      --  faster than a pool can be told about it; a generated token is one
      --  vector and is the case that bound is really keeping out.
      declare
         Blocks : constant Element_Count :=
           QI.Packed_Blocks (Count, Columns);

         Least : constant Element_Count := 256;

         Share : aliased Packing_Share :=
           (Vectors => Vector,
            Count   => Count,
            Columns => Columns,
            Values  => Item.Values,
            Scales  => Item.Scales,
            Totals  => Item.Totals,
            Ok      => True);

         Sent : E.Error_Info;
      begin
         if Blocks >= Least then
            Dispatch_Shares
              (Item   => Item'Unchecked_Access,
               Items  => Blocks,
               Work   => Share'Unchecked_Access,
               Status => Sent);

            if E.Is_Error (Sent) then
               return False;
            end if;

            return Share.Ok;
         end if;
      end;

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
      Status : out E.Error_Info;
      Cost   : Element_Count := 0)
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
      --
      --  And a job too small to be worth waking anyone for, which is the
      --  same answer by the same code: every item of these jobs is
      --  independent of every other, so one task running the whole range
      --  computes what the shares would have computed, element for element.
      if Item = null
        or else (Cost /= 0 and then Cost < Inline_Floor)
      then
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
         Work   => Work,
         others => <>);

      Item.Control.Post (Job_Of, Taken);
      if not Taken then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Announce
        (Item.Waking'Unchecked_Access,
         Natural (Share_Count'Min (Share_Count (Item.Workers),
                                   Job_Of.Team - 1)));

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

      Settle (Item.Waking'Unchecked_Access);
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

   -----------------
   -- Take_Chunks --
   -----------------

   procedure Take_Chunks
     (Waking : Wake_Access;
      Work   : Job;
      Grain  : Element_Count)
   is
      Step   : constant Element_Count :=
        (if Grain <= 1 then 1 else Grain);

      --  Tiles a part holds, each part beginning at a tile of its own so
      --  that no chunk crosses from one matrix into the next. That is what
      --  makes a grouped job the same arithmetic as the products run one at
      --  a time: a part's rows are cut where they would have been cut
      --  alone.
      One   : constant Element_Count := (Work.Rows + Step - 1) / Step;
      Two   : constant Element_Count := (Work.Rows_Two + Step - 1) / Step;
      Three : constant Element_Count := (Work.Rows_Three + Step - 1) / Step;

      Tiles : constant Element_Count := One + Two + Three;
   begin
      if Waking = null or else Work.Rows = 0
        or else Work.Vector = null or else Work.Target = null
      then
         return;
      end if;

      loop
         declare
            Mine : constant Chunk_Counter :=
              Chunks.Atomic_Fetch_And_Add (Waking.Chunk, 1);
         begin
            exit when Mine < 0
              or else Element_Count (Mine) >= Tiles;

            declare
               Tile : constant Element_Count := Element_Count (Mine);

               --  Which part this tile belongs to, and the tile's place
               --  inside it.
               Part  : Job := Work;
               Local : Element_Count;
            begin
               if Tile < One then
                  Local := Tile;
               elsif Tile < One + Two then
                  Local := Tile - One;
                  Part.Weight := Work.Weight_Two;
                  Part.Target := Work.Target_Two;
                  Part.Rows := Work.Rows_Two;
               else
                  Local := Tile - One - Two;
                  Part.Weight := Work.Weight_Three;
                  Part.Target := Work.Target_Three;
                  Part.Rows := Work.Rows_Three;
               end if;

               declare
                  First : constant Element_Count := Local * Step;
                  Last  : constant Element_Count :=
                    Element_Count'Min (First + Step - 1, Part.Rows - 1);
               begin
                  Take_Share (Part, First, Last);
               end;
            end;
         end;
      end loop;
   end Take_Chunks;

   task body Worker is
      Position : Worker_Count := 1;
      Control  : Coordinator_Access := null;
      Waking   : Wake_Access := null;
      Current  : Job;
      Closing  : Boolean := False;
      Failed   : Boolean;

      --  The ticket this worker last saw a job under, so the spin below
      --  knows what a new one looks like.
      Mine     : AC.Atomic_Unsigned := 0;
   begin
      --  A pool can be created and then never used -- a command that fails
      --  while loading the model, for instance. The terminate alternative lets
      --  such a worker end with its master instead of waiting for a Start that
      --  will never come, which would hang the frame that declared the pool.
      select
         accept Start
           (Index  : Worker_Count;
            Owner  : Coordinator_Access;
            Waking : Wake_Access)
         do
            Position := Index;
            Control := Owner;
            Worker.Waking := Waking;
         end Start;
      or
         terminate;
      end select;

      loop
         --  Look for the next job before blocking for it. The entry below
         --  is what actually hands the job over and what says the pool is
         --  closing; this only decides whether the task is awake when it
         --  asks. A spin that finds nothing costs the budget below and then
         --  blocks, which is what this did before it was here.
         Watch (Waking, Mine);

         Control.Wait_For_Work (Position) (Current, Closing);
         exit when Closing;

         Mine := Waking.Ticket;

         Failed := False;

         begin
            declare
               First, Last : Element_Count;
            begin
               if Current.Work = null then
                  Take_Chunks
                    (Waking, Current,
                     Model_Runner.Quantization.Integers.Row_Tile);
               else
                  Partition
                    (Current.Rows, Current.Team, Position, First, Last,
                     Grain => 1);

                  Take_Share (Current, First, Last);
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

         --  After the coordinator, never before: a submitting task that
         --  sees this reach zero goes straight to Await, and Await opens on
         --  what the line above wrote.
         AC.Decrement (Waking.Left);
      end loop;
   exception
      when others =>
         if Control /= null then
            Control.Finished (True);
         end if;

         --  So that a task dying here does not leave every later Settle
         --  spinning its whole budget against a count that will never
         --  reach zero.
         if Waking /= null then
            AC.Decrement (Waking.Left);
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
         Item.Team (Index).Start
           (Index, Item.Control'Unchecked_Access,
            Item.Waking'Unchecked_Access);
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
         Work   => null,
         others => <>);

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

      Announce
        (Item.Waking'Unchecked_Access,
         Natural (Share_Count'Min (Share_Count (Item.Workers),
                                   Work.Team - 1)));

      --  The submitting task takes the last share rather than waiting for
      --  the workers to finish it. Waiting is what it used to do, and it
      --  cost a core: with one worker per core, the waiting task and the
      --  workers together are one more runnable task than there are cores,
      --  so the operating system takes a core away from a worker and the
      --  whole job waits for it. Pinned to one processor per core, eight
      --  workers measured 3.7x where seven measured 5.0x, which is that
      --  effect with nowhere to hide.
      begin
         Take_Chunks
           (Item.Waking'Unchecked_Access, Work,
            Model_Runner.Quantization.Integers.Row_Tile);
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

      Settle (Item.Waking'Unchecked_Access);
      Item.Control.Await (Failed);

      if Failed or else Mine_Failed then
         Status := E.Make (E.Backend_Worker_Failed);
         E.Add_Integer (Status, "workers", Long_Long_Integer (Item.Workers));
      end if;
   end Mat_Vec;

   -------------------
   -- Mat_Vec_Group --
   -------------------

   procedure Mat_Vec_Group
     (Item    : in out Pool;
      Weights : T.View_Group;
      Vector  : T.Real_Array_Access;
      Into    : T.Target_Group;
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
        (Weight => Weights (Weights'First),
         Count  => 1,
         Vector => Vector,
         Target => Into (Into'First),
         Rows   => Weights (Weights'First).Rows,
         Team   => Item.Workers + 1,
         Values => null,
         Scales => null,
         Totals => null,
         Work   => null,
         others => <>);

      if Weights'Length >= 2 then
         Work.Weight_Two := Weights (Weights'First + 1);
         Work.Target_Two := Into (Into'First + 1);
         Work.Rows_Two := Weights (Weights'First + 1).Rows;
      end if;

      if Weights'Length >= 3 then
         Work.Weight_Three := Weights (Weights'First + 2);
         Work.Target_Three := Into (Into'First + 2);
         Work.Rows_Three := Weights (Weights'First + 2).Rows;
      end if;

      if Prepare_Packed (Item, Work.Weight, Vector, 1) then
         Work.Values := Item.Values;
         Work.Scales := Item.Scales;
         Work.Totals := Item.Totals;

         --  The smaller team, as a single product asks for it and for the
         --  same reason: the byte path is answered by the memory.
         Work.Team := Share_Count'Min (Item.Workers + 1, Vector_Team);
      end if;

      Item.Control.Post (Work, Accepted);
      if not Accepted then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Announce
        (Item.Waking'Unchecked_Access,
         Natural (Share_Count'Min (Share_Count (Item.Workers),
                                   Work.Team - 1)));

      begin
         Take_Chunks
           (Item.Waking'Unchecked_Access, Work,
            Model_Runner.Quantization.Integers.Row_Tile);
      exception
         when others =>
            Mine_Failed := True;
      end;

      Settle (Item.Waking'Unchecked_Access);
      Item.Control.Await (Failed);

      if Failed or else Mine_Failed then
         Status := E.Make (E.Backend_Worker_Failed);
         E.Add_Integer (Status, "workers", Long_Long_Integer (Item.Workers));
      end if;
   end Mat_Vec_Group;

   --------------------
   -- Dispatch_Group --
   --------------------

   procedure Dispatch_Group
     (Item    : Pool_Reference;
      Weights : T.View_Group;
      Vector  : T.Real_Array_Access;
      Into    : T.Target_Group;
      Status  : out E.Error_Info)
   is
      use type Model_Runner.GGUF.Tensor_Type;

      --  What may be run as one job: at most three matrices, as many
      --  answers as matrices, and every one of them agreeing on the format
      --  and the width -- because the activation is quantized once for the
      --  whole job and what that quantizing does is decided by those two.
      --  Anything else is what it was, one product at a time.
      Together : Boolean :=
        Item /= null
        and then Weights'Length in 2 .. 3
        and then Into'Length = Weights'Length;
   begin
      Status := E.Success;

      if Together then
         for Index in Weights'Range loop
            declare
               Which : T.View renames Weights (Index);
            begin
               if Which.Format /= Weights (Weights'First).Format
                 or else Which.Columns /= Weights (Weights'First).Columns
                 or else Which.Rows = 0
                 or else Into (Into'First + (Index - Weights'First)) = null
               then
                  Together := False;
               end if;
            end;
         end loop;
      end if;

      if Together then
         Mat_Vec_Group (Item.all, Weights, Vector, Into, Status);
         return;
      end if;

      for Index in Weights'Range loop
         Dispatch
           (Item, Weights (Index), Vector,
            Into (Into'First + (Index - Weights'First)), Status);
         exit when E.Is_Error (Status);
      end loop;
   end Dispatch_Group;

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
         Work   => null,
         others => <>);

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

      Announce
        (Item.Waking'Unchecked_Access,
         Natural (Share_Count'Min (Share_Count (Item.Workers),
                                   Work.Team - 1)));

      --  The submitting task takes the last share rather than waiting for
      --  the workers to finish it. Waiting is what it used to do, and it
      --  cost a core: with one worker per core, the waiting task and the
      --  workers together are one more runnable task than there are cores,
      --  so the operating system takes a core away from a worker and the
      --  whole job waits for it. Pinned to one processor per core, eight
      --  workers measured 3.7x where seven measured 5.0x, which is that
      --  effect with nowhere to hide.
      begin
         Take_Chunks
           (Item.Waking'Unchecked_Access, Work,
            Model_Runner.Quantization.Integers.Row_Tile);
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

      Settle (Item.Waking'Unchecked_Access);
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
   Model_Runner.Kernels.Use_Wide_Lanes
     (Model_Runner.Platform.Wide_Vectors);
end Model_Runner.Backend.CPU;
