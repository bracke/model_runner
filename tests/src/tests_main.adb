with Ada.Calendar;
--  SIGINT is reserved by the GNAT runtime unless a partition says otherwise.
--  model_runner attaches its own handler so that an interrupt requests a clean
--  cancellation -- releasing every resource and committing no cache position --
--  instead of terminating the process mid-token. This is a configuration
--  pragma and therefore belongs to the main unit of the partition.
pragma Unreserve_All_Interrupts;

with Ada.Command_Line;
with Interfaces;
with Ada.Text_IO;

with AUnit;
with AUnit.Reporter.Text;
with AUnit.Run;

with Tests.Suite;
with Checks;
with Conformance;
with Fixture_Mutation;
with External_Model;
with Docs_Generation;
with Shader_Generation;
with Benchmarks;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Tokenizer;
with Model_Runner.Limits;
with Model_Runner.Text;
with Model_Runner.Errors;
with Model_Runner.Backend;
with Model_Runner.Numerics;
with Model_Runner.Llama;
with Model_Runner.Schema;
with Model_Runner.Platform;
with Project_Tools.Files;
with Project_Tools.Text;
with Packaging;
with Pristine;
with Host_Load;
with Speed_Run;
with Tool_Commands;
with Fuzzing;
with Text_Fuzzing;
with Tiny_Model;

--  Entry point of the model_runner test and tooling executable.
--
--  The first argument selects a command. "test" runs every mandatory
--  deterministic suite and is the default.
procedure Tests_Main is
   package E renames Model_Runner.Errors;
   use type AUnit.Status;

   function Run_Suite is
     new AUnit.Run.Test_Runner_With_Status (Tests.Suite.Suite);

   Reporter : AUnit.Reporter.Text.Text_Reporter;

   --  A backend named the way --backend names it. An unknown name is the
   --  processor rather than a refusal: these are measuring and validating
   --  tools, and every one of them reports which backend it used, so a name
   --  that missed cannot be mistaken for one that took.
   --
   --  One copy, because two commands take this option and two copies of a
   --  lookup is one place for them to disagree about what "device" means.
   --  A real number as the options give it, falling back to the default
   --  when it is not one.
   function Real_Of (Word : String) return Model_Runner.Numerics.Real is
   begin
      return Model_Runner.Numerics.Real'Value (Word);
   exception
      when others =>
         return 1.1;
   end Real_Of;

   function Backend_Of (Word : String)
     return Model_Runner.Backend.Backend_Kind is
   begin
      for Kind in Model_Runner.Backend.Backend_Kind loop
         if Model_Runner.Backend.Backend_Name (Kind) = Word then
            return Kind;
         end if;
      end loop;
      return Model_Runner.Backend.Backend_CPU;
   end Backend_Of;

   --  Selected command, defaulting to the mandatory suite.
   function Command return String is
   begin
      if Ada.Command_Line.Argument_Count = 0 then
         return "test";
      else
         return Ada.Command_Line.Argument (1);
      end if;
   end Command;

   --  The README beside this crate, or the empty string when there is none.
   function Readme_Text return String is
      Path : constant String := "../README.md";
   begin
      if Project_Tools.Files.File_Exists (Path) then
         return Project_Tools.Files.Read_Raw_File (Path);
      end if;
      return "";
   exception
      when others =>
         return "";
   end Readme_Text;

   type Field_Text is access constant String;
   type Field_List is array (Positive range <>) of Field_Text;

   --  Every number the conformance summary prints, as it prints it.
   function Conformance_Fields (Item : Conformance.Report) return Field_List
   is ([new String'("sequences" & Natural'Image (Item.Sequences)),
        new String'("logits compared" & Natural'Image (Item.Compared)),
        new String'("worst absolute" & Long_Float'Image (Item.Worst_Abs)),
        new String'("worst relative" & Long_Float'Image (Item.Worst_Rel)),
        new String'("rounded logits compared"
                    & Natural'Image (Item.Lossy_Compared)),
        new String'("rounded worst absolute"
                    & Long_Float'Image (Item.Lossy_Worst_Abs)),
        new String'("rounded worst relative"
                    & Long_Float'Image (Item.Lossy_Worst_Rel)),
        new String'("cached logits compared"
                    & Natural'Image (Item.Cached_Compared)),
        new String'("cached worst absolute"
                    & Long_Float'Image (Item.Cached_Worst_Abs)),
        new String'("cached worst relative"
                    & Long_Float'Image (Item.Cached_Worst_Rel)),
        new String'("outside tolerance" & Natural'Image (Item.Failures))]);

   --  Refuse an option this command does not take.
   --
   --  These commands read their arguments by looking for the ones they know
   --  and ignoring the rest, which reads as tolerant and is not: asking
   --  tokenize for --text when it takes --prompt tokenized the default
   --  prompt and printed it with no complaint, so the same answer came back
   --  for every input while a real defect was being chased with it.
   function Unknown_Option (Known : String) return Boolean is
      Index : Positive := 2;
   begin
      while Index <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument'Length > 2
              and then Argument (Argument'First .. Argument'First + 1) = "--"
              and then not Project_Tools.Text.Contains
                             (Known, " " & Argument & " ")
            then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "unknown option: " & Argument
                  & (if Known = " " or else Known = ""
                     then "; this command takes no options"
                     else "; this command takes" & Known));
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
               return True;
            end if;
         end;
         Index := Index + 1;
      end loop;
      return False;
   end Unknown_Option;

begin
   --  Every command's options are checked in one place, from the registry,
   --  before anything is dispatched. Five commands used to check their own
   --  and six did not: `tests check --nonsense` ran the whole gate without a
   --  word, `tests docs --nonsense` read the typo as a directory and failed
   --  at writing it, and `tests fixtures --nonsense` died with a stack
   --  trace. A command cannot forget to look now, because looking is not
   --  something a command does.
   if Unknown_Option (Tool_Commands.Options_Of (Command)) then
      return;
   end if;

   if Command = "test" then
      if Run_Suite (Reporter) /= AUnit.Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   elsif Command = "fuzz" then
      --  Mutation fuzzing over the GGUF parser. Every case is derived from the
      --  seed and the case number, so a failure replays exactly.
      declare

         --  Read a named option with a default.
         function Option (Name : String; Default : Natural) return Natural is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Natural'Value (Ada.Command_Line.Argument (Index + 1));
               end if;
            end loop;
            return Default;
         exception
            when others =>
               return Default;
         end Option;

         Seed   : constant Natural := Option ("--seed", 1);
         Cases  : constant Natural := Natural'Max (Option ("--cases", 500), 1);
         Result : Fuzzing.Report;
      begin
         Fuzzing.Run (Interfaces.Unsigned_64 (Seed), Cases, Result);

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "fuzz seed" & Natural'Image (Seed)
            & " cases" & Natural'Image (Result.Cases)
            & ": accepted" & Natural'Image (Result.Accepted)
            & ", rejected" & Natural'Image (Result.Rejected)
            & ", bounded" & Natural'Image (Result.Bounded)
            & ", escaped" & Natural'Image (Result.Escaped)
            & ", invalid" & Natural'Image (Result.Invalid)
            & ", slow" & Natural'Image (Result.Slow)
            & ", internal" & Natural'Image (Result.Internal)
            & ", prepared" & Natural'Image (Result.Prepared)
            & ", ran" & Natural'Image (Result.Ran));

         --  The other untrusted input. Containers are what a model file is;
         --  a prompt is what everybody else is, and it reaches the tokenizer
         --  whole. Both roads are run.
         declare
            Text : Text_Fuzzing.Report;
         begin
            Text_Fuzzing.Run (Interfaces.Unsigned_64 (Seed), Cases, Text);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "text fuzz seed" & Natural'Image (Seed)
               & " cases" & Natural'Image (Text.Cases)
               & ": encoded" & Natural'Image (Text.Encoded)
               & ", refused" & Natural'Image (Text.Refused)
               & ", escaped" & Natural'Image (Text.Escaped)
               & ", undocumented" & Natural'Image (Text.Undocumented)
               & ", out of range" & Natural'Image (Text.Out_Of_Range)
               & ", slow" & Natural'Image (Text.Slow)
               & ", worst" & Natural'Image (Text.Worst) & " ms at case"
               & Natural'Image (Text.Worst_Case));

            if not Text_Fuzzing.Is_Clean (Text)
              or else not Text_Fuzzing.Reached_The_Merges (Text)
            then
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end if;
         end;

         if not Fuzzing.Is_Clean (Result) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "first offending case:" & Natural'Image (Result.First_Bad));
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;

         --  A campaign whose files all stopped at the parser would report
         --  the same clean totals as one that drove the whole engine, and
         --  everything past the parser would be untested rather than
         --  satisfied. Failing here says which it was.
         if not Fuzzing.Reached_The_Engine (Result) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "no mutated file reached the engine: prepared"
               & Natural'Image (Result.Prepared)
               & ", ran" & Natural'Image (Result.Ran));
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "check" then
      --  Repository and dependency-boundary checks.
      declare
         Root   : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2)
            else "..");
         Result : Checks.Report;
         Agreed : Conformance.Report;
         Moved  : Fixture_Mutation.Report;

         --  When the stage now running began, and how to say what it took.
         --
         --  Ada.Calendar rather than Host_Load.Now: that one is the host's
         --  load average and not a clock, which the first version of this
         --  subtracted from itself and reported a stage as taking minus
         --  eight hundredths of a second.
         Started : Ada.Calendar.Time := Ada.Calendar.Clock;

         procedure Report_Stage (Named : String) is
            use type Ada.Calendar.Time;
            Ended : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         begin
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  took: " & Named & Duration'Image (Ended - Started) & " s");
            Started := Ended;
         end Report_Stage;
         Fuzzed : Fuzzing.Report;
         Failed : Boolean := False;

         --  What the fixture check says about each tensor nothing read. The
         --  package reports counts and hands the naming back here, because
         --  where a line goes is this program's business rather than its.
         --  Not called "fail": what the check says about a tensor is a
         --  note, and whether the run failed is decided by the counts it
         --  returns. An allowance printed as a failure teaches the reader to
         --  skip the word.
         procedure Complain (Line : String) is
         begin
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "  fixtures: " & Line);
         end Complain;

         --  Whether to run only the part that asks about this host.
         --
         --  The gate is one gate and stays one: on the host that releases,
         --  'tests check' runs the suite, the checks, the conformance
         --  comparison and two fuzzing campaigns, and any of them failing
         --  fails it. What this adds is a way for another host to ask the
         --  half that is about hosts -- whether every platform body
         --  compiles, whether a path or a line ending was written one host's
         --  way -- without repeating the arithmetic, which is the same
         --  everywhere and takes the time.
         --
         --  Measured before it existed: adding the whole gate to the two
         --  native jobs took Windows from 397 seconds to 668 and macOS from
         --  521 to 844, nearly all of it a suite that had just run in the
         --  step above and a conformance sweep that had run on Linux.
         Repository_Only : Boolean := False;

         --  Write the pinned crates' warning counts down instead of
         --  comparing against them. A maintenance action rather than a
         --  check, so it runs the repository checks and nothing else: a
         --  conformance sweep is not what a caller who wants a file
         --  rewritten is asking for.
         Recording : Boolean := False;
      begin
         for Index in 2 .. Ada.Command_Line.Argument_Count loop
            if Ada.Command_Line.Argument (Index) = "--repository" then
               Repository_Only := True;
            elsif Ada.Command_Line.Argument (Index) = "--record-warnings" then
               Recording := True;
               Repository_Only := True;
            end if;
         end loop;

         --  The suite first. Calling this command the gate while the
         --  hundred and sixty-four tests were a command somebody had to
         --  remember was the same mistake as leaving conformance outside,
         --  made in the sentence that fixed it.
         if not Repository_Only
           and then Run_Suite (Reporter) /= AUnit.Success
         then
            Failed := True;
         end if;

         --  What each half of the gate costs, said as it goes. The gate
         --  grew from half an hour to the best part of an hour over three
         --  days and no line of its own output said where the time went;
         --  the fixture check's seventy-eight seconds had to be measured
         --  from outside to be known at all.
         Started := Ada.Calendar.Clock;

         Checks.Run (Root, Result, Record_Warnings => Recording);
         Report_Stage ("repository checks");
         Failed := Failed or else not Checks.Is_Clean (Result);

         --  The gate runs the two things that were commands somebody had to
         --  remember. Conformance is the strongest evidence this repository
         --  has that the arithmetic is right rather than self-consistent,
         --  and fuzzing is the only thing that puts a mutated file in front
         --  of the parser. Both were outside the gate, so a release could
         --  have been cut with the suite and the checklist green and the two
         --  implementations disagreeing.
         --
         --  They cost forty-four milliseconds and ninety, which is no reason
         --  to leave either out.
         if not Repository_Only then
            Conformance.Run (Agreed);
            Report_Stage ("conformance");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  of which: fixtures built" & Duration'Image (Agreed.Built)
               & " s, reference" & Duration'Image (Agreed.Learned)
               & " s, the rest is the engine");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  conformance: sequences" & Natural'Image (Agreed.Sequences)
               & ", outside tolerance" & Natural'Image (Agreed.Failures)
               & ", refused" & Natural'Image (Agreed.Refused));
            if not Conformance.Is_Clean (Agreed) then
               --  Is_Clean already asks whether the comparison ran, so a
               --  reference that compared nothing fails here. Saying which of
               --  the two it was costs a line and saves the reader guessing
               --  from a count of zero.
               if not Agreed.Ran then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  fail: the conformance run ran"
                     & Natural'Image (Agreed.Sequences)
                     & " sequences where its own arithmetic expects"
                     & Natural'Image (Agreed.Wanted)
                     & ", so what it did not compare is unaccounted for");
               end if;
               Failed := True;
            end if;

            --  And whether the fixtures those comparisons run on can fail
            --  at all. A tensor nothing reads makes every comparison over
            --  that fixture weaker than its count suggests, and nothing here
            --  asked until a fixture wrote one projection twice and the two
            --  readers took different halves of it.
            Fixture_Mutation.Run (Moved, Say => Complain'Access);
            Report_Stage ("fixtures");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  fixtures: tensors moved" & Natural'Image (Moved.Examined)
               & ", unread" & Natural'Image (Moved.Unread)
               & ", quiet" & Natural'Image (Moved.Quiet)
               & ", unwanted" & Natural'Image (Moved.Unwanted)
               & ", faint" & Natural'Image (Moved.Faint)
               & ", refused" & Natural'Image (Moved.Refused));
            if not Fixture_Mutation.Is_Clean (Moved) then
               Failed := True;
            end if;

            --  A short campaign, not the long one: the gate is asking whether
            --  the parser still refuses what it should, not searching for a new
            --  way to break it. 'tests fuzz' with a larger count is the search.
            Fuzzing.Run (1, 200, Fuzzed);
            Report_Stage ("fuzzing");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  fuzz: cases" & Natural'Image (Fuzzed.Cases)
               & ", prepared" & Natural'Image (Fuzzed.Prepared)
               & ", ran" & Natural'Image (Fuzzed.Ran)
               & ", escaped" & Natural'Image (Fuzzed.Escaped)
               & ", internal" & Natural'Image (Fuzzed.Internal));

            --  Clean totals and nothing reaching the engine is a campaign that
            --  proved nothing: every case stopping at the parser leaves the
            --  checks past it untested rather than satisfied. Fuzzing says so
            --  itself, and the first version of this gate did not ask -- which
            --  is why no mutation of mine could make the fuzz half fail. I was
            --  trying to make it catch a parser regression when what it was
            --  failing to check was whether the campaign did anything at all.
            if not Fuzzing.Is_Clean (Fuzzed) then
               Failed := True;
            end if;

            if not Fuzzing.Reached_The_Engine (Fuzzed) then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "  fail: no mutated file reached the engine, so the fuzz "
                  & "campaign checked only the parser");
               Failed := True;
            end if;

            --  The same gate over text, which is the other untrusted input and
            --  the one nothing fuzzed. It watches the clock as well as the
            --  outcome: what it was written for was a scan whose cost grew with
            --  the text times a constant from the file format, which no
            --  correctness check could have seen.
            declare
               Texted : Text_Fuzzing.Report;
            begin
               Text_Fuzzing.Run (1, 150, Texted);
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "  text fuzz: cases" & Natural'Image (Texted.Cases)
                  & ", encoded" & Natural'Image (Texted.Encoded)
                  & ", refused" & Natural'Image (Texted.Refused)
                  & ", escaped" & Natural'Image (Texted.Escaped)
                  & ", slow" & Natural'Image (Texted.Slow)
                  & ", worst" & Natural'Image (Texted.Worst) & " ms");

               if not Text_Fuzzing.Is_Clean (Texted) then
                  Failed := True;
               end if;

               if not Text_Fuzzing.Reached_The_Merges (Texted) then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  fail: no text case encoded, so the text campaign "
                     & "checked only the refusals");
                  Failed := True;
               end if;
            end;

         end if;

         if Failed then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "fixture-check" then
      --  The fixture check on its own, for looking at one architecture's
      --  file rather than passing the gate.
      declare
         Moved : Fixture_Mutation.Report;

         procedure Complain (Line : String) is
         begin
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Line);
         end Complain;
      begin
         Fixture_Mutation.Run (Moved, Say => Complain'Access);

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "fixtures: tensors moved" & Natural'Image (Moved.Examined)
            & ", unread" & Natural'Image (Moved.Unread)
            & ", quiet" & Natural'Image (Moved.Quiet)
            & ", unwanted" & Natural'Image (Moved.Unwanted)
            & ", faint" & Natural'Image (Moved.Faint)
            & ", refused" & Natural'Image (Moved.Refused));

         if not Fixture_Mutation.Is_Clean (Moved) then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "conformance" then
      --  Compare the engine against the independent reference implementation
      --  on the synthetic model. Needs no external model and no network.
      declare
         Result : Conformance.Report;
      begin
         Conformance.Run (Result);

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "conformance: sequences" & Natural'Image (Result.Sequences)
            & ", logits compared" & Natural'Image (Result.Compared)
            & ", worst absolute" & Long_Float'Image (Result.Worst_Abs)
            & ", worst relative" & Long_Float'Image (Result.Worst_Rel)
            & ", rounded logits compared"
            & Natural'Image (Result.Lossy_Compared)
            & ", rounded worst absolute"
            & Long_Float'Image (Result.Lossy_Worst_Abs)
            & ", rounded worst relative"
            & Long_Float'Image (Result.Lossy_Worst_Rel)
            & ", cached logits compared"
            & Natural'Image (Result.Cached_Compared)
            & ", cached worst absolute"
            & Long_Float'Image (Result.Cached_Worst_Abs)
            & ", cached worst relative"
            & Long_Float'Image (Result.Cached_Worst_Rel)
            & ", byte logits compared"
            & Natural'Image (Result.Eighth_Compared)
            & ", byte worst absolute"
            & Long_Float'Image (Result.Eighth_Worst_Abs)
            & ", byte worst relative"
            & Long_Float'Image (Result.Eighth_Worst_Rel)
            & ", outside tolerance" & Natural'Image (Result.Failures)
            & ", unlearned" & Natural'Image (Result.Unlearned));

         if not Conformance.Is_Clean (Result) then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;

         --  The README publishes these numbers, and the support matrix names
         --  it as their only home. That made keeping them current a duty
         --  somebody had to remember, and twice nobody did: the counts there
         --  said 4 and 64 after the run had grown to 8 and 128, and the worst
         --  divergence was quoted six times smaller than it had become.
         --
         --  So the run checks the file. Every field it prints must appear
         --  there, which fails the moment the arithmetic changes -- and the
         --  moment the arithmetic changes is exactly when someone should look
         --  at what is published about it rather than find out later.
         declare
            Published : constant String := Readme_Text;
         begin
            if Published'Length = 0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "conformance: no README beside this crate, figures not"
                  & " checked");
            else
               for Number of Conformance_Fields (Result) loop
                  if not Project_Tools.Text.Contains
                           (Published, Number.all)
                  then
                     Ada.Text_IO.Put_Line
                       (Ada.Text_IO.Standard_Error,
                        "conformance: the README does not say """
                        & Number.all & """, so what it publishes about "
                        & "this run is out of date");
                     Ada.Command_Line.Set_Exit_Status
                       (Ada.Command_Line.Failure);
                  end if;
               end loop;
            end if;
         end;
      end;

   elsif Command = "tokenize" then
      --  Encode a prompt with a model's own vocabulary and print the
      --  identifiers, which is what makes a tokenizer comparable with
      --  another implementation. The counterpart in llama.cpp prints the
      --  same list, so the two can be set beside each other.
      declare
         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;

         Path   : constant String := Option ("--model", "");
         Prompt : constant String := Option ("--prompt", "Hello");

         Source : Model_Runner.Byte_Sources.Files.File_Source;
         Item   : Model_Runner.GGUF.Containers.Container;
         Words  : Model_Runner.Tokenizer.Vocabulary;
         Status : E.Error_Info;
         Tokens : Model_Runner.Tokenizer.Token_Array (1 .. 4096);
         Used   : Natural;
      begin
         if Path = "" then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "tokenize: --model is required");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            Model_Runner.Byte_Sources.Files.Open (Source, Path, Status => Status);
            if E.Is_Error (Status) then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error, "tokenize: cannot open " & Path);
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            else
               Model_Runner.GGUF.Containers.Reader.Parse
                 (Item, Source, Model_Runner.Limits.Default_Model_Limits,
                  null, null, Status);

               if E.Is_Error (Status) then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "tokenize: " & E.Diagnostic_Code (Status.Code));
                  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
               else
                  Model_Runner.Tokenizer.Load
                    (Words, Item, Model_Runner.Limits.Default_Model_Limits,
                     Status);

                  if E.Is_Error (Status) then
                     Ada.Text_IO.Put_Line
                       (Ada.Text_IO.Standard_Error,
                        "tokenize: " & E.Diagnostic_Code (Status.Code));
                     Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
                  else
                     Model_Runner.Tokenizer.Encode
                       (Words, Prompt, False, False, Tokens, Used, Status);

                     if E.Is_Error (Status) then
                        Ada.Text_IO.Put_Line
                          (Ada.Text_IO.Standard_Error,
                           "tokenize: " & E.Diagnostic_Code (Status.Code));
                        Ada.Command_Line.Set_Exit_Status
                          (Ada.Command_Line.Failure);
                     else
                        Ada.Text_IO.Put ("[");
                        for Index in 1 .. Used loop
                           if Index > 1 then
                              Ada.Text_IO.Put (", ");
                           end if;
                           Ada.Text_IO.Put
                             (Model_Runner.Text.Image
                                (Long_Long_Integer (Tokens (Index))));
                        end loop;
                        Ada.Text_IO.Put_Line ("]");
                     end if;
                  end if;

                  Model_Runner.Tokenizer.Close (Words);
                  Model_Runner.GGUF.Containers.Close (Item);
               end if;

               Model_Runner.Byte_Sources.Files.Close (Source);
            end if;
         end if;
      end;

   elsif Command = "external-model" then
      --  Validate a model the user already has. Nothing is downloaded, and a
      --  missing file is a skip rather than a failure.
      declare
         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;

         function Number (Name : String; Default : Positive) return Positive is
         begin
            return Positive'Value (Option (Name, ""));
         exception
            when others =>
               return Default;
         end Number;

         function Mode_Of (Word : String) return Model_Runner.Llama.Repack_Mode
         is
         begin
            for Mode in Model_Runner.Llama.Repack_Mode loop
               if Model_Runner.Llama.Repack_Name (Mode) = Word then
                  return Mode;
               end if;
            end loop;
            return Model_Runner.Llama.No_Repack;
         end Mode_Of;

         Path   : constant String := Option ("--model", "");
         Result : External_Model.Report;
      begin
         External_Model.Run
           (Path    => Path,
            Prompt  => Option ("--prompt", "Hello"),
            Tokens  => Number ("--max-tokens", 16),
            Threads => Number ("--threads", 4),
            Expect  => Option ("--expect", ""),
            Backend => Backend_Of (Option ("--backend", "cpu")),
            Draft   => Option ("--draft-model", ""),
            Draft_Tokens => Number ("--draft-tokens", 4),
            Repack  => Mode_Of (Option ("--repack", "none")),
            Result  => Result);

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, External_Model.Summary (Result));

         if Result.Result in External_Model.Rejected | External_Model.Failed
         then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "docs" then
      --  Regenerate the documentation that is derived from the Ada registries.
      declare
         Root    : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2)
            else "..");
         Written : Boolean;
      begin
         Docs_Generation.Write_Error_Reference (Root, Written);
         if Written then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "wrote " & Root & "/docs/error-codes.md");
         else
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "could not write the error-code reference");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "schema" then
      --  A schema, as the grammar it becomes. For seeing what a schema
      --  turns into without running a model, which is how the grammar it
      --  produces gets read at all.
      declare
         Text : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2) else "");

         Room   : String (1 .. Model_Runner.Schema.Max_Grammar_Bytes);
         Last   : Natural;
         Status : Model_Runner.Errors.Error_Info;
      begin
         if Text = "" then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "usage: tests schema SCHEMA");
            Ada.Command_Line.Set_Exit_Status (2);
            return;
         end if;

         Model_Runner.Schema.To_Grammar (Text, Room, Last, Status);

         if Model_Runner.Errors.Is_Error (Status) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "refused: "
               & Model_Runner.Errors.Error_Code'Image (Status.Code));
            Ada.Command_Line.Set_Exit_Status (1);
            return;
         end if;

         Ada.Text_IO.Put_Line (Room (1 .. Last));
      end;

   elsif Command = "shader" then
      --  Turn a compiled shader into the Ada constant the engine hands to a
      --  device. Compiling is not done here: it needs a shader compiler,
      --  which is not a build dependency of this project.
      declare
         Root : constant String :=
           (if Ada.Command_Line.Argument_Count >= 4
            then Ada.Command_Line.Argument (4)
            else "..");
         Written : Boolean;
      begin
         if Ada.Command_Line.Argument_Count < 3 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "usage: tests shader SOURCE.comp COMPILED.spv [ROOT]");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            Shader_Generation.Write_Shader
              (Root, Ada.Command_Line.Argument (2),
               Ada.Command_Line.Argument (3), Written);

            if Written then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "wrote " & Root & "/src/library/model_runner-shaders.ads");
            else
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "could not write the shader constant");
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end if;
         end if;
      end;

   elsif Command = "speed" then
      --  Take the published speed figures again. Needs a model the caller
      --  already has; nothing is downloaded and a missing file is a skip.
      declare
         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;

         function Number (Name : String; Default : Positive) return Positive is
         begin
            return Positive'Value (Option (Name, ""));
         exception
            when others =>
               return Default;
         end Number;

         --  Named the way --repack names them.
         function Mode_Of (Word : String) return Model_Runner.Llama.Repack_Mode
         is
         begin
            for Mode in Model_Runner.Llama.Repack_Mode loop
               if Model_Runner.Llama.Repack_Name (Mode) = Word then
                  return Mode;
               end if;
            end loop;
            return Model_Runner.Llama.No_Repack;
         end Mode_Of;

         Result  : Speed_Run.Report;

         --  A word on its own, so it is looked for across every argument.
         function Given (Name : String) return Boolean is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return True;
               end if;
            end loop;
            return False;
         end Given;

         Load_Now : constant Long_Float := Host_Load.Now;

         --  How many looks have gone by, so that waiting says so once in a
         --  while rather than once a second.
         Told : Natural := 0;

         --  Minutes to wait for the machine, or none. Read through its own
         --  reader because Number is for values that must be positive and
         --  this one's absence is the ordinary case.
         function Waiting return Natural is
         begin
            return Natural'Value (Option ("--wait", ""));
         exception
            when others =>
               return 0;
         end Waiting;
      begin
         --  Refused on a busy machine, exactly as `tests benchmark` is and
         --  on the same bound. These two publish figures that are compared
         --  with each other and with what the README says, and one of them
         --  refusing a machine the other accepted meant the same host was
         --  too busy for one set of published numbers and fine for another.
         --  A caller who says --wait is told when rather than refused: the
           --  loop that watched the load and started the tool when it fell
           --  used to live in a shell script outside this repository, which
           --  every figure retaken this week went through.
         if not Given ("--anyway")
           and then Waiting > 0
         then
            declare
               procedure Still (Load : Long_Float) is
               begin
                  if Told mod 30 = 0 then
                     Ada.Text_IO.Put_Line
                       (Ada.Text_IO.Standard_Error,
                        "waiting for the machine to fall below "
                        & Model_Runner.Text.Image
                            (Long_Float (Host_Load.Too_Busy), 2)
                        & "; it is at "
                        & Model_Runner.Text.Image (Load, 2));
                  end if;
                  Told := Told + 1;
               end Still;

               Quiet : constant Boolean :=
                 Host_Load.Wait_For_Quiet
                   (Waiting, Still'Unrestricted_Access);
            begin
               if not Quiet then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "the machine did not fall below "
                     & Model_Runner.Text.Image
                         (Long_Float (Host_Load.Too_Busy), 2)
                     & " within" & Natural'Image (Waiting)
                     & " minutes; nothing measured");
                  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
                  return;
               end if;
            end;

         elsif not Given ("--anyway")
           and then not Host_Load.Publishable (Load_Now)
         then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "the machine is at a load of "
               & Model_Runner.Text.Image (Load_Now, 2)
               & ", above the "
               & Model_Runner.Text.Image (Long_Float (Host_Load.Too_Busy), 2)
               & " a figure worth publishing needs; wait, or pass --anyway "
               & "for the shape of the answer");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;

         Speed_Run.Run
           (Path        => Option ("--model", ""),
            Prompt_Path =>
              Option ("--prompt-file",
                      "../tests/fixtures/speed-prompt-short.txt"),
            Tokens      => Number ("--max-tokens", 12),
            Threads     => Number ("--threads",
                                   Model_Runner.Platform.Core_Count - 1),
            Batch       => Number ("--batch-size", 32),

            --  Named with a value like every other option this command
            --  takes, so that a reader who saw --repack in the README does
            --  not have to guess whether it is a flag here.
            Repack      => Mode_Of (Option ("--repack", "none")),

            --  The storage the session keeps its context in, named the way
            --  the command names it: f32, f16 or q8.
            Cache       =>
              (declare
                 Named : constant String := Option ("--kv-cache", "f32");
               begin
                 (if Named = Model_Runner.Llama.Cache_Name
                              (Model_Runner.Llama.Halved)
                  then Model_Runner.Llama.Halved
                  elsif Named = Model_Runner.Llama.Cache_Name
                                  (Model_Runner.Llama.Eighth)
                  then Model_Runner.Llama.Eighth
                  else Model_Runner.Llama.Exact)),
            Backend     => Backend_Of (Option ("--backend", "cpu")),
            Penalty     => Real_Of (Option ("--repeat-penalty", "1.1")),
            Draft       => Option ("--draft-model", ""),
            Draft_Tokens => Number ("--draft-tokens", 4),
            Repeats     => Number ("--repeats", 3),
            Result      => Result);

         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Speed_Run.Summary (Result));

         --  A run that measured nothing is a failure, and the missing model
         --  is the commonest way to measure nothing. This used to exempt it:
         --  'tests speed' with no --model, and with a path to a file that is
         --  not there, printed "nothing measured" and left with a success.
         --  Every other campaign here refuses to pass on having done nothing
         --  -- the fuzz gate fails when no mutated file reached the engine,
         --  the repository checks fail below a floor, the text campaign
         --  fails when nothing encoded -- and this was the one whose "I did
         --  nothing" was indistinguishable from its "I did".
         if not Result.Ran then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "pristine" then
      --  Build and check a clone of what git carries. Minutes, and it needs
      --  git and Alire; it fetches nothing, because every pin is a path.
      declare
         Root : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2)
            else "..");
         Result : Pristine.Report;
      begin
         Pristine.Run (Root, Result);
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Pristine.Summary (Result));

         if not Result.Ran then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "benchmark" then
      --  Measure the kernels. Not part of the mandatory suite: it reports
      --  numbers rather than passing or failing.
      --
      --  Both knobs reach the caller now. Run had a Seconds parameter that
      --  nothing on the command line could set, so a reader who wanted a
      --  figure steadier than a half-second sample had no way to ask for
      --  one -- and the spread over a half second is about a tenth.
      declare
         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;

         function Number (Name : String; Default : Positive) return Positive is
         begin
            return Positive'Value (Option (Name, ""));
         exception
            when others =>
               return Default;
         end Number;

         --  Minutes to wait, where absent means none.
         function Minutes (Name : String) return Natural is
         begin
            return Natural'Value (Option (Name, ""));
         exception
            when others =>
               return 0;
         end Minutes;

         --  A word on its own rather than a value, so it is looked for
         --  across every argument including the last, which Option cannot
         --  do because it reads the one after the name.
         function Given (Name : String) return Boolean is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return True;
               end if;
            end loop;
            return False;
         end Given;

      begin
         --  Half a second a round when nothing is asked for, which is
         --  what the published figures were taken at; whole seconds when a
         --  steadier number is wanted.
         Benchmarks.Run
           (Seconds =>
              (if Option ("--seconds", "") = ""
               then 0.5
               else Duration (Number ("--seconds", 1))),
            Rounds  => Number ("--rounds", 3),
            Anyway  => Given ("--anyway"),
            Wait    => Minutes ("--wait"));
      end;

   elsif Command = "package" then
      --  Assemble the distributable archive. Nothing is built here and
      --  nothing is fetched; the executable must already exist.
      declare
         Root : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2)
            else "..");
         Into : constant String :=
           (if Ada.Command_Line.Argument_Count >= 3
            then Ada.Command_Line.Argument (3)
            else ".");
         Written : Boolean;
      begin
         Packaging.Run (Root, Into, Written);
         if not Written then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;

   elsif Command = "fixtures" then
      --  Write the synthetic models the acceptance scenarios use. Nothing is
      --  downloaded and nothing large is produced.
      declare
         Directory : constant String :=
           (if Ada.Command_Line.Argument_Count >= 2
            then Ada.Command_Line.Argument (2)
            else "fixtures");
      begin
         Tiny_Model.Write (Directory & "/tiny-model.gguf");
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "wrote " & Directory & "/tiny-model.gguf");
      end;

   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "unknown command: " & Command);
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, Tool_Commands.Usage_Line);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests_Main;
