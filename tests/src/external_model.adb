with Ada.Directories;

with Model_Runner.Backend.CPU;
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
      Repack  : L.Repack_Mode := L.No_Repack;
      Result  : out Report)
   is
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
           (Engine, Session, Effective_Prompt, Request, Stop,
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
        (Engine, Container, Source, Repack => Repack,
         Threads => Threads, Status => Status);
      if E.Is_Error (Status) then
         Give_Up (Rejected,
                  "model rejected: " & E.Diagnostic_Code (Status.Code));
         return;
      end if;

      --  Self-consistency: valid UTF-8, reproducible under a fixed seed, and
      --  unchanged by the worker count.
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

         Result.Thread_Checked := Threads > 1;

         if Threads > 1 then
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
                  Status => Local);

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
                          (Plain, Session, Effective_Prompt, Request, Stop,
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
              & ", deterministic " & Boolean'Image (Item.Deterministic)
              & (if Item.Thread_Checked
                 then ", thread-stable " & Boolean'Image (Item.Thread_Stable)
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
