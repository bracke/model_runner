--  This tool publishes counts and answers rather than timings, which is
--  why it reports no load where `tests speed` and `tests benchmark` both
--  do. A line carrying a load is a line that differs between two runs of
--  the same check, and the transcripts this publishes are compared
--  against each other. The field was added here once and broke that
--  comparison, which is how the omission got a reason rather than
--  staying an oversight. `tests check` reads this paragraph: if this
--  tool ever does publish a timing, put it on the list there instead.

with Ada.Directories;
with Ada.Numerics.Long_Elementary_Functions;

with Model_Runner.Backend.CPU;
with Model_Runner.Tensors;
with Model_Runner.Backend.Device;
with Model_Runner.Backend.Reference;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Numerics;
with Model_Runner.Output;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.UTF8;

with Expectations;
with Speed_Run;

package body External_Model is

   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Tokenizer.Token_Id;

   package CPU renames Model_Runner.Backend.CPU;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Text;
   package Vocab renames Model_Runner.Tokenizer;

   use type L.Repack_Mode;

   Max_Captured : constant := 1_000_000;

   --  A sink that keeps what generation produced, so the run can check the
   --  bytes rather than trust that something was printed.
   type Capture is limited new Model_Runner.Output.Sink with record
      Data : String (1 .. Max_Captured) := [others => ' '];
      Used : Natural := 0;
   end record;

   overriding procedure Write
     (Self : in out Capture; Item : String; Closed : out Boolean);
   overriding procedure Flush (Self : in out Capture; Closed : out Boolean);
   overriding function Is_Closed (Self : Capture) return Boolean;

   overriding procedure Write
     (Self : in out Capture; Item : String; Closed : out Boolean) is
   begin
      if Self.Used + Item'Length > Self.Data'Length then
         Closed := True;
         return;
      end if;
      Self.Data (Self.Used + 1 .. Self.Used + Item'Length) := Item;
      Self.Used := Self.Used + Item'Length;
      Closed := False;
   end Write;

   overriding procedure Flush (Self : in out Capture; Closed : out Boolean) is
      pragma Unreferenced (Self);
   begin
      Closed := False;
   end Flush;

   overriding function Is_Closed (Self : Capture) return Boolean is
      pragma Unreferenced (Self);
   begin
      return False;
   end Is_Closed;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path    : String;
      Prompt  : String;
      Tokens  : Positive;
      Threads : Positive;
      Expect  : String := "";
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Draft   : String := "";
      Draft_Tokens : Positive := 4;
      Repack  : L.Repack_Mode := L.No_Repack;
      Result  : out Report)
   is
      use type Model_Runner.Backend.Backend_Kind;

      --  Whether this backend partitions rows across workers. Asked of the
      --  backend rather than of its name, so a backend that gains a pool
      --  gains the check with it.
      Shares : constant Boolean :=
        (case Backend is
           when Model_Runner.Backend.Backend_CPU =>
             CPU.Describe (CPU.Max_Workers).Supports_Parallel,
           when Model_Runner.Backend.Backend_Reference =>
             Model_Runner.Backend.Reference.Describe.Supports_Parallel,
           when Model_Runner.Backend.Backend_Device =>
             Model_Runner.Backend.Device.Describe.Supports_Parallel);

      Expected    : Expectations.Recording;
      Greedy      : String (1 .. Max_Captured) := [others => ' '];
      Greedy_Last : Natural := 0;
      Source      : Files.File_Source;
      Container : Containers.Container;
      Engine    : L.Model;
      Status    : E.Error_Info;

      --  The engine's own reason when a generation attempt gives up.
      Refusal : E.Error_Info := E.Success;

      procedure Say (Detail : String) is
         Room : constant Natural :=
           Natural'Min (Detail'Length, Result.Detail'Length);
      begin
         Result.Detail (1 .. Room) :=
           Detail (Detail'First .. Detail'First + Room - 1);
         Result.Detail_Last := Room;
      end Say;

      procedure Give_Up (Kind : Outcome; Detail : String) is
         Ignored : E.Error_Info;
      begin
         Result.Result := Kind;
         Say (Detail);
         L.Close (Engine, Ignored);
         Containers.Close (Container);
         Files.Close (Source);
      end Give_Up;

      --  The expectation's prompt wins when there is one: comparing against a
      --  reference that saw different input would prove nothing.
      function Effective_Prompt return String
      is (if Expected.Valid and then Expectations.Prompt_Text (Expected) /= ""
          then Expectations.Prompt_Text (Expected)
          else Prompt);

      --  One greedy generation pass through the coordinator, optionally across
      --  a worker pool. Used for the self-consistency checks.
      procedure Generate
        (Team    : CPU.Pool_Reference;
         Text    : out String;
         Last    : out Natural;
         Counted : out Natural;
         Ok      : out Boolean)
      is
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Local   : E.Error_Info;
      begin
         Text := [others => ' '];
         Last := 0;
         Counted := 0;
         Ok := False;

         Refusal := E.Success;

         L.Open (Session, Engine, Workers => Team, Status => Local);
         if E.Is_Error (Local) then
            Refusal := Local;
            return;
         end if;

         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := Tokens;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Seed := 42;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;

         Gen.Generate
           (Engine, Session, Effective_Prompt, Request, Stop, null,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);

         Result.Prompt_Tokens := Outcome.Prompt_Tokens;
         Counted := Outcome.Generated_Tokens;
         Last := Natural'Min (Sink.Used, Text'Length);
         if Last > 0 then
            Text (Text'First .. Text'First + Last - 1) :=
              Sink.Data (1 .. Last);
         end if;

         Ok := Outcome.Reason /= Gen.Runtime_Error;

         --  The run carries its own diagnostic. Reporting only that it failed
         --  discards the sentence the engine wrote about why, and leaves
         --  whoever reads the failure to reproduce it by hand to find out.
         if not Ok then
            Refusal := Outcome.Error;
         end if;

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Gen.Release (Outcome);
      end Generate;

      --  Drive the session directly to obtain the token identifiers greedy
      --  decoding produces, and the logits after the prompt. A reference
      --  runtime reports identifiers and logits, not decoded text, so this is
      --  what can be compared without folding in either side's decoder
      --  conventions.
      procedure Greedy_Trace
        (Prompt_Tokens : out Vocab.Token_Array;
         Prompt_Used   : out Natural;
         Produced      : out Vocab.Token_Array;
         Produced_Used : out Natural;
         First_Logits  : out N.Real_Array;
         Ok            : out Boolean)
      is
         --  Why it stopped, for the caller to report. Saying only that
         --  generation failed throws away the one thing the engine had to
         --  say about it, and then somebody has to run the engine by hand to
         --  find out what this already knew.
         Session : L.Session;
         Sampler : Model_Runner.Sampling.Sampler;
         Words   : constant access constant Vocab.Vocabulary :=
           L.Vocabulary (Engine);
         Settings : constant L.Configuration := L.Config (Engine);
         Logits  : N.Real_Array (0 .. N.Element_Count (Settings.Vocabulary) - 1)
           := [others => 0.0];
         Local   : E.Error_Info;
      begin
         Refusal := E.Success;
         Prompt_Used := 0;
         Produced_Used := 0;
         Produced := [others => Vocab.No_Token];
         First_Logits := [others => 0.0];
         Ok := False;

         --  Whether a beginning marker belongs in front is the vocabulary's
         --  business, not this runner's. Adding one to a model that says it
         --  does not want one feeds a different sequence than any other
         --  implementation would, and the logits then differ by enough --
         --  nearly two, against the hundredths that separate two honest
         --  implementations -- to look like an engine fault.
         Vocab.Encode
           (Words.all, Effective_Prompt, Vocab.Adds_Beginning (Words.all),
            False, Prompt_Tokens, Prompt_Used, Local);
         if E.Is_Error (Local) or else Prompt_Used = 0 then
            Refusal := Local;
            return;
         end if;

         L.Open (Session, Engine, Status => Local);
         if E.Is_Error (Local) then
            Refusal := Local;
            return;
         end if;

         Model_Runner.Sampling.Open
           (Sampler, Model_Runner.Sampling.Greedy_Configuration,
            Settings.Vocabulary, 0, Local);
         if E.Is_Error (Local) then
            Refusal := Local;
            L.Close (Session);
            return;
         end if;

         for Index in 1 .. Prompt_Used loop
            L.Evaluate
              (Session, Engine, Prompt_Tokens (Index), Logits,
               Status => Local);
            if E.Is_Error (Local) then
               Refusal := Local;
               Model_Runner.Sampling.Close (Sampler);
               L.Close (Session);
               return;
            end if;
         end loop;

         if First_Logits'Length = Logits'Length then
            First_Logits := Logits;
         end if;

         for Step in 1 .. Natural'Min (Tokens, Produced'Length) loop
            declare
               Token : Vocab.Token_Id;
            begin
               Model_Runner.Sampling.Sample (Sampler, Logits, Token, Local);
               exit when E.Is_Error (Local);

               Produced_Used := Produced_Used + 1;
               Produced (Produced_Used) := Token;

               exit when Token = Vocab.End_Token (Words.all);

               L.Evaluate (Session, Engine, Token, Logits, Status => Local);
               exit when E.Is_Error (Local);
            end;
         end loop;

         Model_Runner.Sampling.Close (Sampler);
         L.Close (Session);
         Ok := True;
      end Greedy_Trace;

   begin
      Result := (others => <>);

      if Expect /= "" then
         Expectations.Load (Expect, Expected);
         if not Expected.Valid then
            Result.Result := Failed;
            Say ("expectation file rejected: "
                 & Expectations.Problem_Text (Expected));
            return;
         end if;
      end if;

      if Path = "" or else not Ada.Directories.Exists (Path) then
         Result.Result := Skipped;
         Say ("no model at " & Path);
         return;
      end if;

      Result.Backend := Backend;
      Result.Partitions := Shares;

      --  The device is opened before the model loads, because preparation
      --  asks the backend what it can read and a device that is not there
      --  answers for nothing.
      if Backend = Model_Runner.Backend.Backend_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Ready);
            if not Ready then
               Result.Result := Skipped;
               Say ("no compute device on this machine");
               return;
            end if;
         end;
      end if;

      Files.Open (Source, Path, Files.Mapping_Automatic, 0, Status);
      if E.Is_Error (Status) then
         Give_Up (Rejected, "cannot open: " & E.Diagnostic_Code (Status.Code));
         return;
      end if;

      Containers.Reader.Parse (Container, Source, Status => Status);
      if E.Is_Error (Status) then
         Give_Up (Rejected,
                  "container rejected: " & E.Diagnostic_Code (Status.Code));
         return;
      end if;

      L.Prepare
        (Engine, Container, Source, Repack => Repack, Backend => Backend,
         Threads => Threads, Status => Status);
      if E.Is_Error (Status) then
         Give_Up (Rejected,
                  "model rejected: " & E.Diagnostic_Code (Status.Code));
         return;
      end if;

      --  Self-consistency: valid UTF-8, reproducible under a fixed seed, and
      --  unchanged by the worker count.
      --
      --  All three are about generated text, and a model with no projection
      --  to a distribution has none: it is asked for the thing it does
      --  produce and compared on that instead. Skipped rather than refused,
      --  because a refusal here would read as a fault in a model that is
      --  behaving exactly as its architecture says.
      if not L.Config (Engine).Has_Head then
         goto Compare_Embedding;
      end if;

      declare
         First   : String (1 .. Max_Captured);
         Second  : String (1 .. Max_Captured);
         Third   : String (1 .. Max_Captured);
         Last_1, Last_2, Last_3 : Natural;
         Count_1, Count_2, Count_3 : Natural;
         Ok_1, Ok_2, Ok_3 : Boolean;
      begin
         Generate (null, First, Last_1, Count_1, Ok_1);
         if not Ok_1 then
            if E.Is_Error (Refusal) then
               Give_Up (Failed,
                        "generation failed: "
                        & E.Diagnostic_Code (Refusal.Code));
            else
               Give_Up (Failed, "generation failed");
            end if;
            return;
         end if;

         Result.Generated := Count_1;
         Greedy_Last := Last_1;
         Result.Digest := Speed_Run.Digest_Of (First (1 .. Last_1));
         if Last_1 > 0 then
            Greedy (1 .. Last_1) := First (1 .. Last_1);
         end if;

         if not Model_Runner.UTF8.Is_Valid (First (1 .. Last_1)) then
            Give_Up (Failed, "generated text is not valid UTF-8");
            return;
         end if;

         Generate (null, Second, Last_2, Count_2, Ok_2);
         Result.Deterministic :=
           Ok_2 and then Last_1 = Last_2
           and then First (1 .. Last_1) = Second (1 .. Last_2);

         if not Result.Deterministic then
            Give_Up (Failed, "the same seed produced different text");
            return;
         end if;

         --  Only where the backend has workers to vary. Asking a device
         --  whether four workers change its answer would report a check
         --  that cannot run as one that held.
         Result.Thread_Checked := Threads > 1 and then Shares;

         if Result.Thread_Checked then
            declare
               Team : aliased CPU.Pool (CPU.Worker_Count (Threads));
            begin
               Generate (Team'Unchecked_Access, Third, Last_3, Count_3, Ok_3);
               CPU.Close (Team);
            end;

            Result.Thread_Stable :=
              Ok_3 and then Last_1 = Last_3
              and then First (1 .. Last_1) = Third (1 .. Last_3);

            if not Result.Thread_Stable then
               Give_Up (Failed, "the worker count changed the result");
               return;
            end if;
         end if;

      --  And the same model without repacking, when repacking was asked
         --  for. Two engines over the same bytes, one prompt, greedy: whether
         --  rounding the weights changed what came out is the question a
         --  fixture cannot answer, and this is a model somebody has.
         if Repack /= L.No_Repack then
            Result.Repack_Checked := True;

            declare
               Plain  : L.Model;
               Text   : String (1 .. Max_Captured) := [others => ' '];
               Last   : Natural := 0;
               Count  : Natural := 0;
               Fine   : Boolean := False;
               Local  : E.Error_Info;
            begin
               L.Prepare
                 (Plain, Container, Source, Threads => Threads,
                  Backend => Backend, Status => Local);

               if E.Is_Ok (Local) then
                  declare
                     Session : L.Session;
                     Stop    : Model_Runner.Stops.Set;
                     Sink    : aliased Capture;
                     Request : Gen.Request;
                     Outcome : Gen.Result;
                  begin
                     L.Open (Session, Plain, Status => Local);
                     if E.Is_Ok (Local) then
                        Model_Runner.Stops.Open (Stop);
                        Request.Max_Tokens := Tokens;
                        Request.Sampling :=
                          Model_Runner.Sampling.Greedy_Configuration;
                        Request.Seed := 42;
                        Request.Has_Seed := True;
                        Request.Add_Beginning := True;

                        Gen.Generate
                          (Plain, Session, Effective_Prompt, Request, Stop, null,
                           Sink'Unchecked_Access, null, null, null, null,
                           Outcome => Outcome);

                        Last := Natural'Min (Sink.Used, Text'Length);
                        if Last > 0 then
                           Text (1 .. Last) := Sink.Data (1 .. Last);
                        end if;
                        Count := Outcome.Generated_Tokens;
                        Fine := Outcome.Reason /= Gen.Runtime_Error;

                        Model_Runner.Stops.Close (Stop);
                        L.Close (Session);
                        Gen.Release (Outcome);
                     end if;
                  end;

                  L.Close (Plain, Local);
               end if;

               Result.Repack_Match :=
                 Fine and then Count = Result.Generated
                 and then Last = Last_1
                 and then Text (1 .. Last) = First (1 .. Last_1);
            end;
         end if;
      end;

      --  And the same model again with a draft proposing for it, when one
      --  was named. What this checks is the claim drafting makes: the text
      --  is exactly the text of the run without a draft. Any difference is a
      --  fault in the checking rather than a disagreement between two
      --  models, because this model checks every proposal.
      if Draft /= "" then
         Result.Draft_Checked := True;

         declare
            Draft_Source    : Files.File_Source;
            Draft_Container : Containers.Container;
            Draft_Engine    : aliased L.Model;

            Text  : String (1 .. Max_Captured) := [others => ' '];
            Last  : Natural := 0;
            Count : Natural := 0;
            Fine  : Boolean := False;
            Local : E.Error_Info;
         begin
            Files.Open (Draft_Source, Draft, Status => Local);

            if E.Is_Ok (Local) then
               Containers.Reader.Parse
                 (Draft_Container, Draft_Source, Status => Local);
            end if;

            if E.Is_Ok (Local) then
               L.Prepare
                 (Draft_Engine, Draft_Container, Draft_Source,
                  Threads => Threads, Backend => Backend, Status => Local);
            end if;

            if E.Is_Ok (Local) then
               declare
                  Session : L.Session;
                  Second  : aliased L.Session;
                  Stop    : Model_Runner.Stops.Set;
                  Sink    : aliased Capture;
                  Request : Gen.Request;
                  Outcome : Gen.Result;
               begin
                  L.Open (Session, Engine, Status => Local);
                  if E.Is_Ok (Local) then
                     L.Open (Second, Draft_Engine, Status => Local);
                  end if;

                  if E.Is_Ok (Local) then
                     Model_Runner.Stops.Open (Stop);
                     Request.Max_Tokens := Tokens;
                     Request.Sampling :=
                       Model_Runner.Sampling.Greedy_Configuration;
                     Request.Seed := 42;
                     Request.Has_Seed := True;
                     Request.Add_Beginning := True;
                     Request.Draft_Tokens := Draft_Tokens;

                     Gen.Generate
                       (Engine, Session, Effective_Prompt, Request, Stop,
                        null, Sink'Unchecked_Access, null, null, null, null,
                        Draft => Draft_Engine'Unchecked_Access,
                        Draft_Session => Second'Unchecked_Access,
                        Outcome => Outcome);

                     Last := Natural'Min (Sink.Used, Text'Length);
                     if Last > 0 then
                        Text (1 .. Last) := Sink.Data (1 .. Last);
                     end if;
                     Count := Outcome.Generated_Tokens;
                     Fine := Outcome.Reason /= Gen.Runtime_Error;
                     Result.Draft_Proposed := Outcome.Drafted;
                     Result.Draft_Accepted := Outcome.Accepted;

                     Model_Runner.Stops.Close (Stop);
                     L.Close (Second);
                     L.Close (Session);
                     Gen.Release (Outcome);
                  end if;
               end;

               L.Close (Draft_Engine, Local);
               Containers.Close (Draft_Container);
            end if;

            Files.Close (Draft_Source);

            Result.Draft_Match :=
              Fine and then Count = Result.Generated
              and then Last = Greedy_Last
              and then Text (1 .. Last) = Greedy (1 .. Greedy_Last);

            if not Result.Draft_Match then
               Give_Up (Failed,
                        "a drafted run produced different text from the "
                        & "same run without a draft");
               return;
            end if;
         end;
      end if;

      --  A recording of a pooled embedding, which is what a model with no
      --  projection to a distribution has to be compared on. It takes its
      --  own road: there is no greedy decoding to trace and no logits to
      --  read, and asking for either is refused by name.
      --
      --  This is the only comparison in this repository that does not rest
      --  on a reading of an architecture made here, and it earned that
      --  standing the first time it was run: it found a WordPiece text
      --  going unwrapped and a rotation paired the wrong way, both of which
      --  the sweep, the fixture check and an implementation written from
      --  the same description all agreed about.
      <<Compare_Embedding>>

      --  What a model with no distribution can be compared on: the
      --  tokenization, and the vector it produces. Both are optional and a
      --  recording may carry either.
      if Expected.Valid and then Expected.Has_Tokens
        and then not L.Config (Engine).Has_Head
      then
         Result.Reference_Run := True;

         declare
            Words : constant access constant Vocab.Vocabulary :=
              L.Vocabulary (Engine);
            Mine   : Vocab.Token_Array (1 .. 8192);
            Used   : Natural;
            Status : E.Error_Info;
         begin
            Vocab.Encode
              (Words.all, Expectations.Prompt_Text (Expected),
               False, False, Mine, Used, Status);
            if E.Is_Error (Status) then
               Give_Up (Failed, "the prompt did not tokenize");
               return;
            end if;

            Result.Tokens_Match := Used = Expected.Tokens_Used;
            if Result.Tokens_Match then
               for Index in 1 .. Used loop
                  if Integer (Mine (Index)) /= Expected.Tokens (Index) then
                     Result.Tokens_Match := False;
                     exit;
                  end if;
               end loop;
            end if;

            if not Result.Tokens_Match then
               Give_Up
                 (Failed,
                  "tokenization differs from "
                  & Expectations.Runtime_Text (Expected));
               return;
            end if;
         end;
      end if;

      if Expected.Valid and then Expected.Has_Embedding then
         Result.Reference_Run := True;

         declare
            Settings : constant L.Configuration := L.Config (Engine);
            Width    : constant N.Element_Count :=
              N.Element_Count (Settings.Embedding);

            Text_Tokens : Vocab.Token_Array (1 .. 8192);
            Text_Used   : Natural;
            Status      : E.Error_Info;

            Live   : L.Session;
            Room   : Model_Runner.Tensors.Real_Array_Access := null;
            Nothing : N.Real_Array (1 .. 0);
            Pooled : N.Real_Array (0 .. Width - 1) := [others => 0.0];
            Length : Long_Float := 0.0;

            use type Model_Runner.Tensors.Real_Array_Access;
            use type N.Real;
         begin
            if Natural (Width) /= Expected.Embedding_Used then
               Give_Up
                 (Failed,
                  "the recording has" & Natural'Image (Expected.Embedding_Used)
                  & " components and the model is"
                  & N.Element_Count'Image (Width) & " wide");
               return;
            end if;

            declare
               Words : constant access constant Vocab.Vocabulary :=
                 L.Vocabulary (Engine);
            begin
               Vocab.Encode
                 (Words.all, Expectations.Prompt_Text (Expected),
                  Vocab.Adds_Beginning (Words.all),
                  Vocab.Adds_End (Words.all),
                  Text_Tokens, Text_Used, Status);
            end;
            if E.Is_Error (Status) or else Text_Used = 0 then
               Give_Up (Failed, "the prompt did not tokenize");
               return;
            end if;

            L.Open (Live, Engine, Status => Status);
            if E.Is_Error (Status) then
               Give_Up (Failed, "no session for the embedding comparison");
               return;
            end if;

            Model_Runner.Tensors.Allocate
              (N.Element_Count (Text_Used) * Width, Room);
            if Room = null then
               L.Close (Live);
               Give_Up (Failed, "no room for the states");
               return;
            end if;

            --  The whole text in one call, which is what a model that
            --  attends both ways requires and what it is given here.
            L.Evaluate_Batch
              (Live, Engine, Text_Tokens (1 .. Text_Used), Nothing,
               States => Room, Status => Status);
            if E.Is_Error (Status) then
               Model_Runner.Tensors.Free (Room);
               L.Close (Live);
               Give_Up
                 (Failed,
                  "the text would not evaluate: "
                  & E.Error_Code'Image (Status.Code));
               return;
            end if;

            --  Pooled the way the reference pooled, then to unit length,
            --  because that is the vector it wrote down.
            case Expected.Pooling is
               when Expectations.Pool_Mean =>
                  for Which in 0 .. N.Element_Count (Text_Used) - 1 loop
                     for Element in Pooled'Range loop
                        Pooled (Element) := Pooled (Element)
                          + Room.all (Which * Width + Element);
                     end loop;
                  end loop;
                  for Element in Pooled'Range loop
                     Pooled (Element) :=
                       N.Real (Long_Float (Pooled (Element))
                               / Long_Float (Text_Used));
                  end loop;

               when Expectations.Pool_Cls =>
                  for Element in Pooled'Range loop
                     Pooled (Element) := Room.all (Element);
                  end loop;

               when Expectations.Pool_Last =>
                  for Element in Pooled'Range loop
                     Pooled (Element) :=
                       Room.all
                         ((N.Element_Count (Text_Used) - 1) * Width + Element);
                  end loop;
            end case;

            Model_Runner.Tensors.Free (Room);
            L.Close (Live);

            for Element of Pooled loop
               Length := Length + Long_Float (Element) * Long_Float (Element);
            end loop;
            Length := Ada.Numerics.Long_Elementary_Functions.Sqrt (Length);

            if Length > 0.0 then
               for Element of Pooled loop
                  Element := N.Real (Long_Float (Element) / Length);
               end loop;
            end if;

            --  Component by component against the tolerance, and the cosine
            --  reported beside it: the components say where they differ and
            --  the cosine says whether it matters.
            declare
               Dot : Long_Float := 0.0;
            begin
               for Index in 1 .. Expected.Embedding_Used loop
                  declare
                     Mine : constant Long_Float :=
                       Long_Float (Pooled (N.Element_Count (Index - 1)));
                     Gap  : constant Long_Float :=
                       abs (Mine - Expected.Embedding (Index));
                  begin
                     Dot := Dot + Mine * Expected.Embedding (Index);
                     Result.Components := Result.Components + 1;
                     Result.Worst_Component :=
                       Long_Float'Max (Result.Worst_Component, Gap);

                     if Gap > Expected.Tolerance then
                        Result.Cosine := Dot;
                        Give_Up
                          (Failed,
                           "component" & Natural'Image (Index - 1)
                           & " differs from "
                           & Expectations.Runtime_Text (Expected) & " by "
                           & T.Image (Gap, 6));
                        return;
                     end if;
                  end;
               end loop;

               Result.Cosine := Dot;
            end;
         end;

      end if;

      --  A model with no distribution has now been asked everything it can
      --  be asked, whichever of the two the recording carried.
      if Expected.Valid and then not L.Config (Engine).Has_Head then
         Result.Result := Ran;
         Say ("architecture "
              & Containers.String_Value (Container, "general.architecture")
              & ", compared against " & Expectations.Runtime_Text (Expected)
              & (if Result.Tokens_Match then ", tokens match" else "")
              & (if Result.Components > 0
                 then ": " & T.Image (Long_Long_Integer (Result.Components))
                      & " components, worst "
                      & T.Image (Result.Worst_Component, 8)
                      & ", cosine " & T.Image (Result.Cosine, 8)
                 else ""));
         return;
      end if;

      --  Comparison against what a trusted reference runtime recorded.
      if Expected.Valid then
         Result.Reference_Run := True;

         declare
            Settings : constant L.Configuration := L.Config (Engine);
            Prompt_Tokens : Vocab.Token_Array (1 .. 8192);
            Prompt_Used   : Natural;
            Produced      : Vocab.Token_Array (1 .. 4096);
            Produced_Used : Natural;
            Logits : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);
            Traced : Boolean;
         begin
            Greedy_Trace
              (Prompt_Tokens, Prompt_Used, Produced, Produced_Used,
               Logits, Traced);

            if not Traced then
               Give_Up (Failed, "could not trace greedy decoding");
               return;
            end if;

            --  Tokenization.
            if Expected.Has_Tokens then
               Result.Tokens_Match := Prompt_Used = Expected.Tokens_Used;
               if Result.Tokens_Match then
                  for Index in 1 .. Prompt_Used loop
                     if Integer (Prompt_Tokens (Index))
                       /= Expected.Tokens (Index)
                     then
                        Result.Tokens_Match := False;
                        exit;
                     end if;
                  end loop;
               end if;

               if not Result.Tokens_Match then
                  Give_Up
                    (Failed,
                     "tokenization differs from "
                     & Expectations.Runtime_Text (Expected));
                  return;
               end if;
            else
               Result.Tokens_Match := True;
            end if;

            --  Greedy continuation, compared as token identifiers.
            if Expected.Has_Greedy then
               Result.Greedy_Match :=
                 Produced_Used >= Expected.Greedy_Used;

               if Result.Greedy_Match then
                  for Index in 1 .. Expected.Greedy_Used loop
                     if Integer (Produced (Index)) /= Expected.Greedy (Index)
                     then
                        Result.Greedy_Match := False;
                        exit;
                     end if;
                  end loop;
               end if;

               if not Result.Greedy_Match then
                  Give_Up
                    (Failed,
                     "greedy output differs from "
                     & Expectations.Runtime_Text (Expected));
                  return;
               end if;
            else
               Result.Greedy_Match := True;
            end if;

            --  The greedy continuation as text, where the reference recorded
            --  it that way. A runtime reports text most directly; the
            --  identifier comparison above is stricter where identifiers are
            --  available.
            if Expected.Has_Text then
               Result.Text_Match :=
                 Greedy (1 .. Greedy_Last) = Expectations.Greedy_Text (Expected);

               if not Result.Text_Match then
                  Give_Up
                    (Failed,
                     "greedy text differs from "
                     & Expectations.Runtime_Text (Expected));
                  return;
               end if;
            else
               Result.Text_Match := True;
            end if;

            --  Individual logits, where the reference recorded them.
            for Index in 1 .. Expected.Logits_Used loop
               declare
                  Where : constant Natural := Expected.Logits (Index).Index;
               begin
                  if Where >= Settings.Vocabulary then
                     Give_Up (Failed, "an expected logit index is out of range");
                     return;
                  end if;

                  declare
                     Actual : constant Long_Float :=
                       Long_Float (Logits (N.Element_Count (Where)));
                     Gap    : constant Long_Float :=
                       abs (Actual - Expected.Logits (Index).Value);
                  begin
                     Result.Compared := Result.Compared + 1;
                     Result.Worst_Gap := Long_Float'Max (Result.Worst_Gap, Gap);

                     if Gap > Expected.Tolerance then
                        Give_Up
                          (Failed,
                           "logit" & Natural'Image (Where) & " differs from "
                           & Expectations.Runtime_Text (Expected) & " by "
                           & T.Image (Gap, 6));
                        return;
                     end if;
                  end;
               end;
            end loop;
         end;
      end if;

      Result.Result := Ran;
      Say ("architecture "
           & Containers.String_Value (Container, "general.architecture")
           & ", "
           & T.Image (Long_Long_Integer (Containers.Tensor_Count (Container)))
           & " tensors"
           & (if Result.Reference_Run
              then ", checked against "
                   & Expectations.Runtime_Text (Expected)
              else ", no reference comparison"));

      declare
         Ignored : E.Error_Info;
      begin
         L.Close (Engine, Ignored);
      end;
      Containers.Close (Container);
      Files.Close (Source);
   exception
      when others =>
         Result.Result := Failed;
         Say ("an exception escaped while validating the model");
   end Run;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
   begin
      case Item.Result is
         when Skipped =>
            return "external-model: skipped (" & Detail_Text (Item) & ")";

         when Rejected =>
            return "external-model: rejected (" & Detail_Text (Item) & ")";

         when Failed =>
            return "external-model: FAILED (" & Detail_Text (Item) & ")";

         when Ran =>
            return
              "external-model: ok, " & Detail_Text (Item)
              & ", prompt" & Natural'Image (Item.Prompt_Tokens)
              & " tokens, generated" & Natural'Image (Item.Generated)
              & (if not Item.Repack_Checked then ""
                 elsif Item.Repack_Match
                 then ", repacked text identical"
                 else ", repacked text differs")
              & ", backend "
              & Model_Runner.Backend.Backend_Name (Item.Backend)
              & ", deterministic " & Boolean'Image (Item.Deterministic)
              & (if not Item.Draft_Checked then ""
                 else ", drafted text identical "
                      & Boolean'Image (Item.Draft_Match)
                      & ", proposed" & Natural'Image (Item.Draft_Proposed)
                      & ", accepted" & Natural'Image (Item.Draft_Accepted))
              & (if Item.Thread_Checked
                 then ", thread-stable " & Boolean'Image (Item.Thread_Stable)
                 elsif not Item.Partitions
                 then ", thread-stability not checked: this backend does not "
                      & "partition"
                 else ", thread-stability not checked: one worker")
              & (if Item.Reference_Run
                 then ", tokens-match " & Boolean'Image (Item.Tokens_Match)
                      & ", greedy-match " & Boolean'Image (Item.Greedy_Match)
                      & ", text-match " & Boolean'Image (Item.Text_Match)
                      & ", logits compared" & Natural'Image (Item.Compared)
                 else "");
      end case;
   end Summary;

end External_Model;
