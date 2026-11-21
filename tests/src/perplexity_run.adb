with Ada.Directories;
with Ada.Finalization;
with Ada.Real_Time;

with Host_Load;

with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Project_Tools.Files;

package body Perplexity_Run is

   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package Vocab renames Model_Runner.Tokenizer;
   package Containers renames Model_Runner.GGUF.Containers;
   package Files renames Model_Runner.Byte_Sources.Files;
   package CPU renames Model_Runner.Backend.CPU;

   use type Model_Runner.Backend.Backend_Kind;
   use type Model_Runner.Llama.Cache_Precision;
   use type Model_Runner.Llama.Value_Precision;
   use type Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Ada.Real_Time.Time;

   type Device_Guard is
     new Ada.Finalization.Limited_Controlled with record
        Owned : Boolean := False;
     end record;

   overriding procedure Finalize (Item : in out Device_Guard);

   procedure Claim (Item : in out Device_Guard) is
   begin
      Item.Owned := True;
   end Claim;

   overriding procedure Finalize (Item : in out Device_Guard) is
   begin
      if Item.Owned then
         begin
            Model_Runner.Backend.Device.Close;
         exception
            when others => null;
         end;
         Item.Owned := False;
      end if;
   end Finalize;

   --  The project's own exponential and logarithm, in the wide arithmetic
   --  they are written for. Long_Float has no such attributes and a
   --  perplexity is an exponential of a mean, so the two are named here
   --  rather than pulled from a standard instantiation nothing else uses.
   function Exp_Of (Item : Long_Float) return Long_Float
   is (Long_Float (N.Exp (N.Wide_Real (Item))));

   function Log_Of (Item : Long_Float) return Long_Float
   is (Long_Float (N.Log (N.Wide_Real (Item))));

   ---------------------
   -- Log_Probability --
   ---------------------

   function Log_Probability
     (Logits : Real_Array; Token : Element_Count) return Long_Float
   is
      Highest : Long_Float := Long_Float'First;
      Total   : Long_Float := 0.0;
   begin
      if Logits'Length = 0
        or else Token < Logits'First
        or else Token > Logits'Last
      then
         return 0.0;
      end if;

      for Index in Logits'Range loop
         Highest := Long_Float'Max (Highest, Long_Float (Logits (Index)));
      end loop;

      --  The maximum out first: an exponential of a raw logit overflows and
      --  an exponential of a logit minus the largest one cannot.
      for Index in Logits'Range loop
         Total := Total + Exp_Of (Long_Float (Logits (Index))
                                          - Highest);
      end loop;

      return Long_Float (Logits (Token)) - Highest - Log_Of (Total);
   end Log_Probability;

   ----------------
   -- Divergence --
   ----------------

   function Divergence
     (Baseline : Real_Array; Other : Real_Array) return Long_Float
   is
      Top_P, Top_Q : Long_Float := Long_Float'First;
      Sum_P, Sum_Q : Long_Float := 0.0;
      Answer       : Long_Float := 0.0;
   begin
      if Baseline'Length /= Other'Length or else Baseline'Length = 0 then
         return -1.0;
      end if;

      for Index in Baseline'Range loop
         Top_P := Long_Float'Max (Top_P, Long_Float (Baseline (Index)));
      end loop;

      for Index in Other'Range loop
         Top_Q := Long_Float'Max (Top_Q, Long_Float (Other (Index)));
      end loop;

      for Index in Baseline'Range loop
         Sum_P := Sum_P
           + Exp_Of (Long_Float (Baseline (Index)) - Top_P);
      end loop;

      for Index in Other'Range loop
         Sum_Q := Sum_Q + Exp_Of (Long_Float (Other (Index)) - Top_Q);
      end loop;

      declare
         Log_P_Total : constant Long_Float := Log_Of (Sum_P);
         Log_Q_Total : constant Long_Float := Log_Of (Sum_Q);
         Offset      : constant Element_Count := Other'First - Baseline'First;
      begin
         for Index in Baseline'Range loop
            declare
               Log_P : constant Long_Float :=
                 Long_Float (Baseline (Index)) - Top_P - Log_P_Total;
               Log_Q : constant Long_Float :=
                 Long_Float (Other (Index + Offset)) - Top_Q - Log_Q_Total;

               P : constant Long_Float := Exp_Of (Log_P);
            begin
               --  A term whose weight is nothing contributes nothing, and
               --  asking for its logarithm where the other side is nothing
               --  too is what would produce a not-a-number.
               if P > 0.0 then
                  Answer := Answer + P * (Log_P - Log_Q);
               end if;
            end;
         end loop;
      end;

      --  It cannot be negative and rounding can make it look it, by about
      --  the width of the arithmetic. Reported as the zero it is.
      return Long_Float'Max (0.0, Answer);
   end Divergence;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
      package Say renames Model_Runner.Text;

      function Cache_Image
        (Cache  : L.Cache_Precision;
         Values : L.Value_Precision) return String
      is (if Values = L.Same_As_Keys then L.Cache_Name (Cache)
          else L.Cache_Name (Cache) & " keys/"
               & L.Cache_Name (L.Values_Held (Cache, Values)) & " values");
   begin
      if Item.Missing then
         return "nothing measured: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      if not Item.Ran then
         return "measured nothing: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      return
        Natural'Image (Item.Tokens) & " tokens,"
        & Natural'Image (Item.Chunks) & " chunks,"
        & Natural'Image (Item.Scored) & " positions scored"
        & "; candidate "
        & Cache_Image (Item.Candidate_Cache, Item.Candidate_Values)
        & " perplexity " & Say.Image (Item.Perplexity, 4)
        & ", " & Say.Image (Item.Entropy, 4) & " nats/token"
        & (if not Item.Compared then ""
           else "; baseline "
                & Cache_Image (Item.Baseline_Cache, Item.Baseline_Values)
                & " perplexity " & Say.Image (Item.Baseline_Perplexity, 4)
                & "; mean KL " & Say.Image (Item.Divergence, 6)
                & " nats, worst " & Say.Image (Item.Worst, 4)
                & " at position" & Natural'Image (Item.Worst_Position)
                & " (wanted" & Natural'Image (Item.Worst_Wanted)
                & ", top" & Natural'Image (Item.Worst_Candidate_Top)
                & " vs" & Natural'Image (Item.Worst_Baseline_Top)
                & ", wanted log-p "
                & Say.Image (Item.Worst_Candidate_Wanted_Logp, 3)
                & " vs "
                & Say.Image (Item.Worst_Baseline_Wanted_Logp, 3) & ")"
                & ", top token agreed "
                & Say.Image
                    (Long_Float (Item.Agreed) * 100.0
                     / Long_Float (Natural'Max (Item.Scored, 1)), 1)
                & " per cent"
                & "; KV bytes"
                & Model_Runner.Memory.U64'Image (Item.Cache_Bytes)
                & " vs"
                & Model_Runner.Memory.U64'Image
                    (Item.Baseline_Cache_Bytes)
                & "; arm time "
                & Say.Image (Long_Float (Item.Candidate_Seconds), 2)
                & " vs "
                & Say.Image (Long_Float (Item.Baseline_Seconds), 2)
                & " s")
        & "; took " & Say.Image (Long_Float (Item.Seconds), 2) & " s"
        & "; load " & Say.Image (Item.Load_Before, 2)
        & " to " & Say.Image (Item.Load_After, 2)
        & (if Item.Warm_Before < 0.0 then ""
           else "; " & Say.Image (Item.Warm_Before, 1)
                & " to " & Say.Image (Item.Warm_After, 1) & " degrees");
   end Summary;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path    : String;
      Against : String;
      Text    : String;
      Chunk   : Positive := 512;
      Chunks  : Natural := 0;
      Threads : Positive;
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Anyway  : Boolean := False;
      Waiting : Natural := 0;
      Result  : out Report;
      Stretch : String := "";
      Factor  : Model_Runner.Numerics.Wide_Real := 0.0;
      Repack  : Model_Runner.Llama.Repack_Mode :=
        Model_Runner.Llama.No_Repack;
      Cache   : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Values  : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Compare_Cache : Boolean := False;
      Against_Cache : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Against_Values : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys)
   is
      procedure Note (Item : String);

      --  The FIRST note is kept, not the last.
      --
      --  A refusal is followed by the consequences of it, and each of those
      --  had something to say: a session that would not open ended the
      --  chunk loop, and the run then reported "nothing was scored", which
      --  is true and is not the reason. What a reader needs is the first
      --  thing that went wrong.
      procedure Note (Item : String) is
         Room : constant Natural :=
           Natural'Min (Item'Length, Result.Detail'Length);
      begin
         if Result.Detail_Up /= 0 then
            return;
         end if;

         Result.Detail (1 .. Room) := Item (Item'First .. Item'First + Room - 1);
         Result.Detail_Up := Room;
      end Note;

      --  One model, its file and its container, opened and closed together.
      type Reader is limited record
         Source    : aliased Files.File_Source;
         Container : Containers.Container;
         Engine    : aliased L.Model;
         Opened    : Boolean := False;
         Parsed    : Boolean := False;
         Ready     : Boolean := False;
      end record;

      procedure Take (Item : in out Reader; From : String; Ok : out Boolean);
      procedure Give (Item : in out Reader);

      procedure Take (Item : in out Reader; From : String; Ok : out Boolean)
      is
         Status : E.Error_Info;
      begin
         Ok := False;

         Files.Open (Item.Source, From, Status => Status);
         if E.Is_Error (Status) then
            Note ("the model would not open: "
                  & E.Error_Code'Image (Status.Code));
            return;
         end if;
         Item.Opened := True;

         Containers.Reader.Parse
           (Item.Container, Item.Source, Status => Status);
         if E.Is_Error (Status) then
            Note ("the model would not parse: "
                  & E.Error_Code'Image (Status.Code));
            return;
         end if;
         Item.Parsed := True;

         L.Prepare
           (Item.Engine, Item.Container, Item.Source,
            Backend => Backend, Threads => Threads, Status => Status,
            Repack => Repack,
            --  The positions a pass holds, a chunk's: unsaid, a model's own
            --  context was planned -- 262,144 positions, 18 GiB for a 27B --
            --  and the device refused it while a chunk takes 512.
            Context => Chunk,
            Stretch =>
              (Kind =>
                 (if Stretch = "none" then L.As_Trained
                  elsif Stretch = "linear" then L.Linear_Stretch
                  elsif Stretch = "yarn" then L.Yarn_Stretch
                  else L.Unasked),
               Factor => Factor,
               others => <>));
         if E.Is_Error (Status) then
            Note ("the model would not prepare: "
                  & E.Error_Code'Image (Status.Code));
            return;
         end if;
         Item.Ready := True;
         Ok := True;
      end Take;

      procedure Give (Item : in out Reader) is
         Status : E.Error_Info;
      begin
         if Item.Ready then
            L.Close (Item.Engine, Status);
            Item.Ready := False;
         end if;
         if Item.Parsed then
            Containers.Close (Item.Container);
            Item.Parsed := False;
         end if;
         if Item.Opened then
            Files.Close (Item.Source);
            Item.Opened := False;
         end if;
      end Give;

      Started : Ada.Real_Time.Time;
      Device  : Device_Guard;
      Ok      : Boolean;
   begin
      Result := (others => <>);
      Result.Candidate_Cache := Cache;
      Result.Candidate_Values := Values;
      Result.Baseline_Cache :=
        (if Compare_Cache then Against_Cache else Cache);
      Result.Baseline_Values :=
        (if Compare_Cache then Against_Values else Values);
      Result.Cache_Comparison := Compare_Cache;
      Result.Load_Before := Host_Load.Now;
      Result.Warm_Before := Host_Load.Warmth;

      if Compare_Cache and then Against /= "" then
         Note ("choose either --against or --against-kv-cache, not both");
         return;
      end if;

      if Compare_Cache
        and then Cache = Against_Cache
        and then Values = Against_Values
      then
         Note ("candidate and baseline cache modes are identical");
         return;
      end if;

      if not L.Stores_Pair (Cache, Values)
        or else
          (Compare_Cache
           and then not L.Stores_Pair (Against_Cache, Against_Values))
      then
         Note ("the requested key/value cache pairing is not stored");
         return;
      end if;

      if not Ada.Directories.Exists (Path) then
         Result.Missing := True;
         Note ("no model at that path");
         return;
      end if;

      if not Ada.Directories.Exists (Text) then
         Result.Missing := True;
         Note ("no corpus at that path");
         return;
      end if;

      if Against /= "" and then not Ada.Directories.Exists (Against) then
         Result.Missing := True;
         Note ("no baseline model at that path");
         return;
      end if;

      --  A chunk is one pass, and a pass is bounded. Said here rather than
      --  left to the refusal a batch gives, which names a shape mismatch
      --  and not the option that caused it -- a chunk above the bound read
      --  "nothing was scored", which is true and is no help at all.
      --  A chunk longer than one pass is evaluated in several, into the
      --  one session, which is what a long context is. It used to be
      --  refused, and the consequence was quiet: every perplexity this
      --  repository has published was measured at a context of at most 512
      --  tokens, because that is the largest chunk the tool would take.

      --  The same gate every published figure comes through. A perplexity is
      --  not a timing, but the seconds it reports are, and a reader
      --  comparing two formats wants to know both were taken on the same
      --  machine.
      if not Host_Load.Settle (Waiting, Anyway) then
         Result.Missing := True;
         Note ("the machine is too busy to measure on");
         return;
      end if;

      if Backend = Model_Runner.Backend.Backend_Device then
         declare
            Awake : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Awake);
            if not Awake then
               Result.Missing := True;
               Note ("no device answered");
               return;
            end if;
            Claim (Device);
         end;
      end if;

      Started := Ada.Real_Time.Clock;

      declare
         Under : Reader;
         Base  : Reader;

         Comparing_Files : constant Boolean := Against /= "";
         Comparing       : constant Boolean :=
           Comparing_Files or Compare_Cache;
      begin
         Take (Under, Path, Ok);
         if not Ok then
            Give (Under);
            return;
         end if;

         if Comparing_Files then
            Take (Base, Against, Ok);
            if not Ok then
               Give (Base);
               Give (Under);
               return;
            end if;

            --  Two models numbering their tokens differently would be
            --  compared distribution against distribution over different
            --  questions, and the number that came out would look like a
            --  divergence. What this measures is one model in two formats;
            --  anything else is refused rather than answered.
            if L.Config (Base.Engine).Vocabulary
               /= L.Config (Under.Engine).Vocabulary
            then
               Note ("the baseline has a different vocabulary, so the two "
                     & "are not one model in two formats");
               Give (Base);
               Give (Under);
               return;
            end if;
         end if;

         declare
            Candidate_Plan : Model_Runner.Memory.Session_Plan;
            Baseline_Plan  : Model_Runner.Memory.Session_Plan;
            Plan_Status    : E.Error_Info;
         begin
            L.Plan_Session
              (Under.Engine, Chunk, Candidate_Plan, Plan_Status,
               Cache, Values);
            if E.Is_Error (Plan_Status) then
               Note ("the candidate cache could not be planned: "
                     & E.Error_Code'Image (Plan_Status.Code));
               Give (Base);
               Give (Under);
               return;
            end if;
            Result.Cache_Bytes := Candidate_Plan.KV_Cache_Bytes;

            if Comparing then
               if Comparing_Files then
                  L.Plan_Session
                    (Base.Engine, Chunk, Baseline_Plan, Plan_Status,
                     Cache, Values);
               else
                  L.Plan_Session
                    (Under.Engine, Chunk, Baseline_Plan, Plan_Status,
                     Against_Cache, Against_Values);
               end if;
               if E.Is_Error (Plan_Status) then
                  Note ("the baseline cache could not be planned: "
                        & E.Error_Code'Image (Plan_Status.Code));
                  Give (Base);
                  Give (Under);
                  return;
               end if;
               Result.Baseline_Cache_Bytes :=
                 Baseline_Plan.KV_Cache_Bytes;
            end if;
         end;

         declare
            --  The pool the products are divided across. Without one every
            --  product runs on the calling task, which for a run that asks
            --  for every position's distribution is the difference between
            --  minutes and seconds.
            Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
            Where : constant CPU.Pool_Reference :=
              (if Threads = 1 then null else Team'Unchecked_Access);

            Settings : constant L.Configuration := L.Config (Under.Engine);
            Width    : constant Element_Count :=
              Element_Count (Settings.Vocabulary);

            --  The corpus, read whole and encoded once.
            Body_Text : constant String :=
              Project_Tools.Files.Read_Raw_File (Text);

            --  The tokenizer refuses more than sixty-five thousand
            --  code points in one call, so nothing longer than that
            --  can arrive and a token cannot outnumber a code point.
            Held : Vocab.Token_Array (1 .. 70_000);
            Last : Natural := 0;

            Status : E.Error_Info;
         begin
            Vocab.Encode
              (L.Vocabulary (Under.Engine).all, Body_Text,
               Add_Beginning =>
                 Vocab.Adds_Beginning (L.Vocabulary (Under.Engine).all),
               Add_End => False,
               Target => Held, Last => Last, Status => Status);

            if E.Is_Error (Status) or else Last = 0 then
               Note ("the corpus would not encode: "
                     & E.Error_Code'Image (Status.Code));
               Give (Base);
               Give (Under);
               return;
            end if;

            Result.Tokens := Last;

            if Last < Chunk then
               Note ("the corpus is shorter than one chunk");
               Give (Base);
               Give (Under);
               return;
            end if;

            declare
               Rounds : constant Natural :=
                 (if Chunks = 0 then Last / Chunk
                  else Natural'Min (Chunks, Last / Chunk));

               First_Scored : constant Natural := Chunk / 2;

               Logits     : T.Real_Array_Access := null;
               Every      : T.Real_Array_Access := null;
               Base_Every : T.Real_Array_Access := null;

               Surprise : Long_Float := 0.0;
               Baseline_Surprise : Long_Float := 0.0;
               Apart    : Long_Float := 0.0;

               --  One pass's worth of rows, copied into the chunk's own
               --  array afterwards. A pass writes from the front of what it
               --  is given and there is no way to hand it an offset, so the
               --  offset is done here.
               Pass_Rows : T.Real_Array_Access := null;

               procedure Release_Buffers is
               begin
                  if Logits /= null then
                     T.Free (Logits);
                  end if;
                  if Pass_Rows /= null then
                     T.Free (Pass_Rows);
                  end if;
                  if Every /= null then
                     T.Free (Every);
                  end if;
                  if Base_Every /= null then
                     T.Free (Base_Every);
                  end if;
               end Release_Buffers;

               --  Evaluate a chunk in as many passes as it takes, into one
               --  session. A pass holds at most Max_Batch positions; a
               --  chunk may be a whole context, and the second pass sees
               --  the first pass's positions because the session is the
               --  same one.
               procedure Score_Chunk
                 (Live   : in out L.Session;
                  Engine : in out L.Model;
                  From   : Natural;
                  Upto   : Natural;
                  Into   : T.Real_Array_Access;
                  Room   : T.Real_Array_Access;
                  Status : out E.Error_Info)
               is
                  At_Row : Element_Count := 0;
                  Lo     : Natural := From;
               begin
                  Status := E.Success;

                  while Lo <= Upto loop
                     declare
                        Hi : constant Natural :=
                          Natural'Min (Lo + L.Max_Batch - 1, Upto);

                        Wide : constant Element_Count :=
                          Element_Count (Hi - Lo + 1) * Width;
                     begin
                        L.Evaluate_Batch
                          (Live, Engine, Held (Lo .. Hi), Room.all,
                           Every => Pass_Rows, Status => Status);
                        exit when E.Is_Error (Status);

                        Into.all (Into.all'First + At_Row
                                  .. Into.all'First + At_Row + Wide - 1) :=
                          Pass_Rows.all
                            (Pass_Rows.all'First
                             .. Pass_Rows.all'First + Wide - 1);

                        At_Row := At_Row + Wide;
                        Lo := Hi + 1;
                     end;
                  end loop;
               end Score_Chunk;

               --  Open, evaluate and close one arm. Closing before the
               --  other arm opens makes a same-model comparison exercise
               --  one prepared set of weights without requiring two cache
               --  allocations to coexist.
               procedure Score_Arm
                 (Engine  : in out L.Model;
                  Storage : L.Cache_Precision;
                  Values  : L.Value_Precision;
                  From    : Natural;
                  Upto    : Natural;
                  Into    : T.Real_Array_Access;
                  Elapsed : in out Duration;
                  Status  : out E.Error_Info)
               is
                  Live    : L.Session;
                  Started : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
               begin
                  L.Open
                    (Live, Engine, Context => Chunk,
                     Workers => Where, Cache => Storage,
                     Values => Values, Status => Status);
                  if E.Is_Error (Status) then
                     Elapsed := Elapsed
                       + Ada.Real_Time.To_Duration
                           (Ada.Real_Time.Clock - Started);
                     return;
                  end if;

                  Score_Chunk
                    (Live, Engine, From, Upto, Into, Logits, Status);
                  L.Close (Live);
                  Elapsed := Elapsed
                    + Ada.Real_Time.To_Duration
                        (Ada.Real_Time.Clock - Started);
               end Score_Arm;

               procedure Score_Candidate
                 (From, Upto : Natural;
                  Status     : out E.Error_Info) is
               begin
                  Score_Arm
                    (Under.Engine, Cache, Values, From, Upto, Every,
                     Result.Candidate_Seconds, Status);
               end Score_Candidate;

               procedure Score_Baseline
                 (From, Upto : Natural;
                  Status     : out E.Error_Info) is
               begin
                  if Comparing_Files then
                     Score_Arm
                       (Base.Engine, Cache, Values, From, Upto,
                        Base_Every, Result.Baseline_Seconds, Status);
                  else
                     Score_Arm
                       (Under.Engine, Against_Cache, Against_Values,
                        From, Upto, Base_Every,
                        Result.Baseline_Seconds, Status);
                  end if;
               end Score_Baseline;
            begin
               T.Allocate (Width, Logits);
               T.Allocate
                 (Width * Element_Count (Natural'Min (Chunk, L.Max_Batch)),
                  Pass_Rows);
               T.Allocate (Width * Element_Count (Chunk), Every);
               if Comparing then
                  T.Allocate (Width * Element_Count (Chunk), Base_Every);

                  --  Fault mapped weights, allocate each cache layout and
                  --  exercise both session-opening paths before either arm's
                  --  clock starts. Alternating timed order cannot remove the
                  --  first arm's cold-start cost when the corpus has only one
                  --  chunk, which is a common comparison.
                  if Vocab.Adds_Beginning
                       (L.Vocabulary (Under.Engine).all)
                  then
                     Held (1) :=
                       Vocab.Beginning_Token
                         (L.Vocabulary (Under.Engine).all);
                  end if;
                  Score_Candidate (1, Chunk, Status);
                  if not E.Is_Error (Status) then
                     Score_Baseline (1, Chunk, Status);
                  end if;
                  Result.Candidate_Seconds := 0.0;
                  Result.Baseline_Seconds := 0.0;
                  if E.Is_Error (Status) then
                     Note ("a cache-comparison arm would not warm up");
                  end if;
               end if;

               for Round in 1 .. Rounds loop
                  exit when E.Is_Error (Status);
                  declare
                     From : constant Natural := (Round - 1) * Chunk + 1;
                     Upto : constant Natural := From + Chunk - 1;
                  begin
                     --  Each chunk begins as a text does, where the model
                     --  begins one with a marker: the reference runtime
                     --  puts the marker in place of a chunk's first token,
                     --  and a chunk read without one is read as a text
                     --  begun mid-sentence, scored otherwise than it is
                     --  there.
                     if Vocab.Adds_Beginning (L.Vocabulary (Under.Engine).all) then
                        Held (From) := Vocab.Beginning_Token (L.Vocabulary (Under.Engine).all);
                     end if;
                     --  At the chunk's own length, so that a chunk longer
                     --  than the model's trained context is scored rather
                     --  than truncated to it. The engine refuses this
                     --  unless the rotation was stretched for it.
                     --  Alternate which arm runs first. Session opening and
                     --  cache allocation are part of the reported arm time;
                     --  a fixed candidate-then-baseline order therefore
                     --  measured warm-up order as if it were cache speed.
                     if Comparing and then Round mod 2 = 0 then
                        Score_Baseline (From, Upto, Status);
                        if E.Is_Error (Status) then
                           Note ("the baseline would not evaluate a chunk");
                           exit;
                        end if;
                        Score_Candidate (From, Upto, Status);
                     else
                        Score_Candidate (From, Upto, Status);
                        if not E.Is_Error (Status) and then Comparing then
                           Score_Baseline (From, Upto, Status);
                           if E.Is_Error (Status) then
                              Note ("the baseline would not evaluate a chunk");
                              exit;
                           end if;
                        end if;
                     end if;

                     if E.Is_Error (Status) then
                        Note ("a chunk would not evaluate: "
                              & E.Error_Code'Image (Status.Code)
                              & (if E.Text_Of (Status, "layer") /= ""
                                 then " at layer " & E.Text_Of (Status, "layer")
                                 else ""));
                        exit;
                     end if;

                     --  The second half only: the first token of a chunk has
                     --  no context and the second has one token of it, and
                     --  scoring those would measure the chunking.
                     for Row in First_Scored .. Chunk - 2 loop
                        declare
                           At_Row : constant Element_Count :=
                             Element_Count (Row) * Width;

                           Wanted : constant Element_Count :=
                             Element_Count (Held (From + Row + 1));

                           Mine : Real_Array renames
                             Every.all (At_Row .. At_Row + Width - 1);
                        begin
                           Surprise := Surprise
                             - Log_Probability
                                 (Mine, Mine'First + Wanted);
                           Result.Scored := Result.Scored + 1;

                           if Comparing then
                              declare
                                 Theirs : Real_Array renames
                                   Base_Every.all
                                     (At_Row .. At_Row + Width - 1);

                                 Gap : constant Long_Float :=
                                   Divergence (Theirs, Mine);

                                 Best_Mine, Best_Theirs : Element_Count :=
                                   Mine'First;
                              begin
                                 Baseline_Surprise := Baseline_Surprise
                                   - Log_Probability
                                       (Theirs, Theirs'First + Wanted);
                                 Apart := Apart + Gap;
                                 for Index in Mine'Range loop
                                    if Mine (Index) > Mine (Best_Mine) then
                                       Best_Mine := Index;
                                    end if;
                                 end loop;

                                 for Index in Theirs'Range loop
                                    if Theirs (Index) > Theirs (Best_Theirs)
                                    then
                                       Best_Theirs := Index;
                                    end if;
                                 end loop;

                                 if Gap > Result.Worst then
                                    Result.Worst := Gap;
                                    Result.Worst_Position := From + Row;
                                    Result.Worst_Wanted := Natural (Wanted);
                                    Result.Worst_Candidate_Top :=
                                      Natural (Best_Mine - Mine'First);
                                    Result.Worst_Baseline_Top :=
                                      Natural (Best_Theirs - Theirs'First);
                                    Result.Worst_Candidate_Wanted_Logp :=
                                      Log_Probability
                                        (Mine, Mine'First + Wanted);
                                    Result.Worst_Baseline_Wanted_Logp :=
                                      Log_Probability
                                        (Theirs, Theirs'First + Wanted);
                                 end if;

                                 if Best_Mine - Mine'First
                                    = Best_Theirs - Theirs'First
                                 then
                                    Result.Agreed := Result.Agreed + 1;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;

                     Result.Chunks := Result.Chunks + 1;
                  end;
               end loop;

               Release_Buffers;

               if Result.Scored > 0 then
                  Result.Entropy :=
                    Surprise / Long_Float (Result.Scored);
                  Result.Perplexity := Exp_Of (Result.Entropy);
                  Result.Compared := Comparing;
                  if Comparing then
                     Result.Baseline_Entropy :=
                       Baseline_Surprise / Long_Float (Result.Scored);
                     Result.Baseline_Perplexity :=
                       Exp_Of (Result.Baseline_Entropy);
                     Result.Divergence :=
                       Apart / Long_Float (Result.Scored);
                  end if;
                  Result.Ran := True;
               else
                  Note ("nothing was scored");
               end if;
            exception
               when others =>
                  Release_Buffers;
                  raise;
            end;

            --  The workers, given back before the block that holds them
            --  ends: a pool nobody closes keeps its tasks alive and the
            --  program does not finish.
            CPU.Close (Team);
         exception
            --  Closed on the way out as well: a pool left open by an
            --  exception kept its workers waiting, and leaving the block
            --  waited on them for ever instead of saying what went wrong.
            when others =>
               CPU.Close (Team);
               raise;
         end;

         Give (Base);
         Give (Under);
      exception
         when others =>
            begin
               Give (Base);
            exception
               when others => null;
            end;
            begin
               Give (Under);
            exception
               when others => null;
            end;
            raise;
      end;

      Result.Seconds :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Result.Load_After := Host_Load.Now;
      Result.Warm_After := Host_Load.Warmth;
   end Run;

end Perplexity_Run;
