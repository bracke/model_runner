with Ada.Directories;
with Ada.Real_Time;

with Host_Load;

with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
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
   use type Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Ada.Real_Time.Time;

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
        & "; perplexity " & Say.Image (Item.Perplexity, 4)
        & ", " & Say.Image (Item.Entropy, 4) & " nats a token"
        & (if not Item.Compared then ""
           else "; divergence " & Say.Image (Item.Divergence, 6)
                & " nats, worst " & Say.Image (Item.Worst, 4)
                & ", top token agreed "
                & Say.Image
                    (Long_Float (Item.Agreed) * 100.0
                     / Long_Float (Natural'Max (Item.Scored, 1)), 1)
                & " per cent")
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
      Factor  : Model_Runner.Numerics.Wide_Real := 0.0)
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
      Ok      : Boolean;
   begin
      Result := (others => <>);
      Result.Load_Before := Host_Load.Now;
      Result.Warm_Before := Host_Load.Warmth;

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
         end;
      end if;

      Started := Ada.Real_Time.Clock;

      declare
         Under : Reader;
         Base  : Reader;

         Comparing : constant Boolean := Against /= "";
      begin
         Take (Under, Path, Ok);
         if not Ok then
            Give (Under);
            return;
         end if;

         if Comparing then
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
               Add_Beginning => True, Add_End => False,
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

               Live, Baseline_Live : L.Session;

               Logits : T.Real_Array_Access;
               Every  : T.Real_Array_Access;
               Base_Every : T.Real_Array_Access;

               Surprise : Long_Float := 0.0;
               Apart    : Long_Float := 0.0;

               --  One pass's worth of rows, copied into the chunk's own
               --  array afterwards. A pass writes from the front of what it
               --  is given and there is no way to hand it an offset, so the
               --  offset is done here.
               Pass_Rows : T.Real_Array_Access;

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
            begin
               T.Allocate (Width, Logits);
               T.Allocate
                 (Width * Element_Count (Natural'Min (Chunk, L.Max_Batch)),
                  Pass_Rows);
               T.Allocate (Width * Element_Count (Chunk), Every);
               if Comparing then
                  T.Allocate (Width * Element_Count (Chunk), Base_Every);
               end if;

               for Round in 1 .. Rounds loop
                  declare
                     From : constant Natural := (Round - 1) * Chunk + 1;
                     Upto : constant Natural := From + Chunk - 1;
                  begin
                     --  At the chunk's own length, so that a chunk longer
                     --  than the model's trained context is scored rather
                     --  than truncated to it. The engine refuses this
                     --  unless the rotation was stretched for it.
                     L.Open
                       (Live, Under.Engine, Context => Chunk,
                        Workers => Where, Status => Status);
                     if E.Is_Error (Status) then
                        Note ("a session would not open: "
                              & E.Error_Code'Image (Status.Code));
                        exit;
                     end if;

                     Score_Chunk
                       (Live, Under.Engine, From, Upto, Every, Logits,
                        Status);

                     if E.Is_Error (Status) then
                        Note ("a chunk would not evaluate: "
                              & E.Error_Code'Image (Status.Code));
                        L.Close (Live);
                        exit;
                     end if;

                     if Comparing then
                        L.Open
                          (Baseline_Live, Base.Engine,
                           Workers => Where, Status => Status);
                        if E.Is_Error (Status) then
                           Note ("a baseline session would not open");
                           L.Close (Live);
                           exit;
                        end if;

                        Score_Chunk
                          (Baseline_Live, Base.Engine, From, Upto,
                           Base_Every, Logits, Status);

                        if E.Is_Error (Status) then
                           Note ("the baseline would not evaluate a chunk");
                           L.Close (Baseline_Live);
                           L.Close (Live);
                           exit;
                        end if;
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
                                 Apart := Apart + Gap;
                                 Result.Worst :=
                                   Long_Float'Max (Result.Worst, Gap);

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

                                 if Best_Mine - Mine'First
                                    = Best_Theirs - Theirs'First
                                 then
                                    Result.Agreed := Result.Agreed + 1;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;

                     if Comparing then
                        L.Close (Baseline_Live);
                     end if;
                     L.Close (Live);

                     Result.Chunks := Result.Chunks + 1;
                  end;
               end loop;

               T.Free (Logits);
               T.Free (Pass_Rows);
               T.Free (Every);
               if Base_Every /= null then
                  T.Free (Base_Every);
               end if;

               if Result.Scored > 0 then
                  Result.Entropy :=
                    Surprise / Long_Float (Result.Scored);
                  Result.Perplexity := Exp_Of (Result.Entropy);
                  Result.Compared := Comparing;
                  if Comparing then
                     Result.Divergence :=
                       Apart / Long_Float (Result.Scored);
                  end if;
                  Result.Ran := True;
               else
                  Note ("nothing was scored");
               end if;
            end;

            --  The workers, given back before the block that holds them
            --  ends: a pool nobody closes keeps its tasks alive and the
            --  program does not finish.
            CPU.Close (Team);
         end;

         Give (Base);
         Give (Under);
      end;

      Result.Seconds :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Result.Load_After := Host_Load.Now;
      Result.Warm_After := Host_Load.Warmth;
   end Run;

end Perplexity_Run;
