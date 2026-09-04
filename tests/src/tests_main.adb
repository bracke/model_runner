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
with Ada.Text_IO.Text_Streams;

with AUnit;
with AUnit.Reporter.Text;
with Case_Timing;
with Device_Bench;
with AUnit.Run;

with Tests.Suite;
with Checks;
with Conformance;
with Fixture_Mutation;
with External_Model;
with Fixture_Likeness;
with Docs_Generation;
with Shader_Generation;
with Benchmarks;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Tokenizer;
with Model_Runner.Templates;
with Model_Runner.Conversation;
with Model_Runner.Limits;
with Model_Runner.Text;
with Model_Runner.Errors;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Numerics;
with Model_Runner.Llama;
with Model_Runner.Generation;
with Model_Runner.Schema;
with Model_Runner.Tools;
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

        --  The shape behind the totals, held to the README as the totals
        --  are: a published count of architectures that no longer matches
        --  what ran is the same kind of stale as a published tolerance,
        --  and it was stale once already.
        new String'("crossed" & Natural'Image (Item.Architectures)
                    & " architectures"),
        new String'("in" & Natural'Image (Item.Formats) & " formats"),
        new String'("and" & Natural'Image (Item.Shapes) & " shapes"),
        new String'("of which" & Natural'Image (Item.On_Device)
                    & " ran on a device"),
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
        new String'("quantized logits compared"
                    & Natural'Image (Item.Integer_Compared)),
        new String'("quantized worst absolute"
                    & Long_Float'Image (Item.Integer_Worst_Abs)),
        new String'("quantized worst relative"
                    & Long_Float'Image (Item.Integer_Worst_Rel)),
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
            & ", ran" & Natural'Image (Result.Ran)
            & ", on a device" & Natural'Image (Result.On_Device));

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

         Failed : Boolean := False;

         --  When the gate began, against a bound on the whole of it. Four
         --  stages each inside their own bound can still add to a run
         --  nobody notices growing, which is how a half-hour gate became an
         --  hour without any one part of it looking wrong.
         Whole  : constant Ada.Calendar.Time := Ada.Calendar.Clock;

         --  And what the machine spends on the whole of it, which is what
         --  the bound is held against for the same reason the stages' are.
         Whole_Burned : constant Long_Float := Host_Load.Processor_Seconds;
         Bound  : constant Duration := 4_800.0;

         --  When the stage now running began, and how to say what it took.
         --
         --  Ada.Calendar rather than Host_Load.Now: that one is the host's
         --  load average and not a clock, which the first version of this
         --  subtracted from itself and reported a stage as taking minus
         --  eight hundredths of a second.
         Started : Ada.Calendar.Time := Ada.Calendar.Clock;

         --  And what the machine spent on it, which is the figure the bounds
         --  are held against. A wall clock measures what else the host was
         --  doing as much as what the stage did: two quiet readings of
         --  conformance differed by 2.3 times on this host, which is more
         --  than the doubling a bound exists to catch. Processor seconds
         --  barely move when something else runs, so a bound against them
         --  says something about the stage and not about the afternoon.
         Burned : Long_Float := Host_Load.Processor_Seconds;

         --  What each stage cost the machine when it was last measured on
         --  the host the figures name, and roughly twice that as the bound.
         --  Twice, because a stage that doubles has had something added to
         --  it rather than been unlucky, and the gate grew from half an hour
         --  to an hour once with nothing saying so.
         --
         --  Against processor seconds and not the wall. These are what the
         --  five read on 2026-08-20:
         --
         --    suite 3.94 and 6.28; repository checks 9.00, 11.81, 13.03
         --    and 19.39; conformance 1757.39 and 1945.01; fixtures 199.92
         --    and 211.37; fuzzing 0.28 and 0.30; about 2180 for the whole
         --
         --  The wall said 1741.85 for conformance in that run and 962 in
         --  the one before it, for the same work; the machine's own figure
         --  moved by a tenth of that. A bound wants holding against the
         --  number that describes the stage.
         --
         --  Twice the worst reading, and three times it for the two short
         --  stages. The first pass at these took one reading each and set
         --  ten seconds for a suite that read 3.94; it read 6.28 next run.
         --  The repository checks then read 9.00, 11.81, 13.03 and 19.39
         --  across four -- better than two to one, on the figure that was
         --  supposed to be the steady one.
         --
         --  A short stage is mostly the machine's other business: reading
         --  five thousand files takes what the page cache and the scheduler
         --  give it that minute. The long ones are arithmetic and hold
         --  still. So the short two get three times their worst and the
         --  long ones twice, and a bound set from a single reading is a
         --  bound set from the best of them.
         --
         --  Where a host reports no processor time none of this is held at
         --  all. Host_Load reads /proc/self/stat, so that is every host but
         --  one family of them. Asking the system instead -- getrusage is
         --  POSIX and answers the same question everywhere this is built --
         --  belongs in the platform layer with a body per host, not in the
         --  tests crate, which is one directory for every host and has a
         --  check that says so. It caught this being done the wrong way.
         procedure Report_Stage (Named : String; Budget : Duration) is
            use type Ada.Calendar.Time;
            Ended : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Took  : constant Duration := Ended - Started;

            --  Zero where the host does not say, and then there is nothing
            --  to hold a bound against and the wall has to do.
            Now_Burned : constant Long_Float := Host_Load.Processor_Seconds;
            --  A start reading of zero is not a host that keeps no such
            --  number; it is a process that has barely run yet, and for the
            --  first stage the difference is the whole of it either way.
            --  What says the host keeps none is a reading of zero after the
            --  work, which no stage of this gate can honestly produce.
            Told : constant Boolean := Now_Burned > 0.0;

            Spent_On : constant Duration :=
              (if Told then Duration (Now_Burned - Burned) else Took);
         begin
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  took: " & Named & Duration'Image (Took) & " s"
               & (if Told
                  then "," & Duration'Image (Spent_On) & " s of it the"
                       & " machine's"
                  else ""));

            if not Told then
               --  No processor time from this host, so there is nothing to
               --  hold a bound against. Saying the wall time exceeded it
               --  would be saying something about the afternoon, which is
               --  what this stopped doing; so it is said and not counted.
               if Took > Budget then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  note: " & Named & " took" & Duration'Image (Took)
                     & " s against a bound of" & Duration'Image (Budget)
                     & " s of the machine's time, which this host does not"
                     & " report; the bound is not held here");
               end if;

            elsif Spent_On > Budget then
               --  "Either the machine was busy or the stage grew" is what
               --  this used to say, and it could not tell which. It can:
               --  Host_Load.Publishable is the rule this repository already
               --  applies to every figure it prints, and a stage's time is a
               --  figure. The average and not Quiet_Enough here on purpose:
               --  the question is whether the machine was busy over the
               --  minute this stage ran in, which is the window the average
               --  covers and the window a sample taken now does not. Above that load the number says nothing about the
               --  stage, so it is reported and not counted -- conformance
               --  read 648, 992, 1505 and 1794 s in one day against a bound
               --  of 1250, and the difference was the machine every time.
               --
               --  A bound that fails half the time is a bound people learn
               --  to ignore, which is how a suite of twenty-eight minutes
               --  went unnoticed for months.
               if not Host_Load.Publishable (Host_Load.Now) then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  note: " & Named & " cost" & Duration'Image (Spent_On)
                     & " s against a bound of" & Duration'Image (Budget)
                     & " s, at a load of" & Long_Float'Image (Host_Load.Now)
                     & "; too busy for that to say anything about the "
                     & "stage, so it is not counted against it");
               else
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  fail: " & Named & " cost" & Duration'Image (Spent_On)
                     & " s against a bound of" & Duration'Image (Budget)
                     & " s, at a load of" & Long_Float'Image (Host_Load.Now)
                     & "; the machine was quiet enough for that to mean the "
                     & "stage grew, and the bound is in tests_main beside "
                     & "this message");
                  Failed := True;
               end if;
            end if;

            Started := Ended;
            Burned := Now_Burned;
         end Report_Stage;
         Fuzzed : Fuzzing.Report;

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

         --  What the suite cost, which nothing said until now. Four stages
         --  reported their time and the first one did not, so a suite that
         --  had grown to twenty-four minutes was invisible in the gate's own
         --  accounting -- and a day was spent reading its silence as a hang,
         --  because AUnit prints nothing until it is finished and a timeout
         --  shorter than the stage looks exactly like one.
         --
         --  Eight seconds, and sixty as the bound. It was twenty-eight
         --  minutes until the conformance sweep stopped being run from
         --  inside it as well as beside it; a bound of sixty says loudly if
         --  anything of that size is put back.
         if not Repository_Only then
            Report_Stage ("suite", 20.0);
         end if;

         --  What each half of the gate costs, said as it goes. The gate
         --  grew from half an hour to the best part of an hour over three
         --  days and no line of its own output said where the time went;
         --  the fixture check's seventy-eight seconds had to be measured
         --  from outside to be known at all.
         Started := Ada.Calendar.Clock;

         Checks.Run (Root, Result, Record_Warnings => Recording);
         Report_Stage ("repository checks", 60.0);
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
            Report_Stage ("conformance", 4000.0);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  of which: fixtures built" & Duration'Image (Agreed.Built)
               & " s, reference" & Duration'Image (Agreed.Learned)
               & " s, the rest is the engine");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  the sweep crossed" & Natural'Image (Agreed.Architectures)
               & " architectures," & Natural'Image (Agreed.Formats)
               & " formats and" & Natural'Image (Agreed.Shapes)
               & " shapes;" & Natural'Image (Agreed.On_Device)
               & " sequences ran on a device");
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  the reference: decoding" & Duration'Image (Agreed.Decoded)
               & " s, computing" & Duration'Image (Agreed.Computed) & " s");
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
            Report_Stage ("fixtures", 450.0);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  fixtures: tensors moved" & Natural'Image (Moved.Examined)
               & ", unread" & Natural'Image (Moved.Unread)
               & ", quiet" & Natural'Image (Moved.Quiet)
               & ", unwanted" & Natural'Image (Moved.Unwanted)
               & ", declared" & Natural'Image (Moved.Declared)
               & ", faint" & Natural'Image (Moved.Faint)
               & ", unasked" & Natural'Image (Moved.Unasked)
               & ", refused" & Natural'Image (Moved.Refused));
            if not Fixture_Mutation.Is_Clean (Moved) then
               Failed := True;
            end if;

            declare
               use type Ada.Calendar.Time;
               Spent : constant Duration := Ada.Calendar.Clock - Whole;
            begin
               declare
                  Ended_Burned : constant Long_Float :=
                    Host_Load.Processor_Seconds;

                  Gate_Told : constant Boolean := Ended_Burned > 0.0;

                  Gate_Spent : constant Duration :=
                    (if Gate_Told
                     then Duration (Ended_Burned - Whole_Burned)
                     else Spent);
               begin
                  if not Gate_Told then
                     if Spent > Bound then
                        Ada.Text_IO.Put_Line
                          (Ada.Text_IO.Standard_Error,
                           "  note: the gate took" & Duration'Image (Spent)
                           & " s against a bound of" & Duration'Image (Bound)
                           & " s of the machine's time, which this host does"
                           & " not report; the bound is not held here");
                     end if;

                  elsif Gate_Spent > Bound then
                     --  Same rule, same reason: a whole-run time taken on a
                     --  busy machine is not a fact about the gate.
                     if not Host_Load.Publishable (Host_Load.Now) then
                        Ada.Text_IO.Put_Line
                          (Ada.Text_IO.Standard_Error,
                           "  note: the gate cost" & Duration'Image (Gate_Spent)
                           & " s against a bound of" & Duration'Image (Bound)
                           & " s, at a load of" & Long_Float'Image
                                                    (Host_Load.Now)
                           & "; too busy to count against it");
                     else
                        Ada.Text_IO.Put_Line
                          (Ada.Text_IO.Standard_Error,
                           "  fail: the gate cost" & Duration'Image (Gate_Spent)
                           & " s against a bound of" & Duration'Image (Bound)
                           & " s, though every stage was inside its own");
                        Failed := True;
                     end if;
                  end if;
               end;
            end;

            --  A short campaign, not the long one: the gate is asking whether
            --  the parser still refuses what it should, not searching for a new
            --  way to break it. 'tests fuzz' with a larger count is the search.
            Fuzzing.Run (1, 200, Fuzzed);
            Report_Stage ("fuzzing", 5.0);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  fuzz: cases" & Natural'Image (Fuzzed.Cases)
               & ", prepared" & Natural'Image (Fuzzed.Prepared)
               & ", ran" & Natural'Image (Fuzzed.Ran)
               & ", on a device" & Natural'Image (Fuzzed.On_Device)
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

            --  A device that was there and never asked is coverage that
            --  went away quietly, which is what the clean totals above
            --  would otherwise be read as.
            if not Fuzzing.Reached_A_Device (Fuzzed) then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "  fuzz: a device was open and no case was prepared for "
                  & "it, so nothing malformed reached a shader");
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
            & ", declared" & Natural'Image (Moved.Declared)
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

         --  The word after an option, or the default.
         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;
      begin
         --  The arithmetic the sweep holds to its tolerance. Told here
         --  rather than swept as a third axis, so that reading what
         --  quantized activations cost is one command and the gate keeps
         --  its own cross product at the tight bound.
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (Option ("--arith", "f32") = "int8");

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
            & ", quantized logits compared"
            & Natural'Image (Result.Integer_Compared)
            & ", quantized worst absolute"
            & Long_Float'Image (Result.Integer_Worst_Abs)
            & ", quantized worst relative"
            & Long_Float'Image (Result.Integer_Worst_Rel)
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

   elsif Command = "render" then
      --  Render a conversation through a model's own chat template and print
      --  what comes out, which is what makes a template comparable with
      --  another implementation. The templates models ship are written for
      --  one, and the way to know this engine agrees with it is to set the
      --  two answers beside each other rather than to read the template
      --  twice.
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

         function Given (Name : String) return Boolean is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return True;
               end if;
            end loop;
            return False;
         end Given;

         Path   : constant String := Option ("--model", "");
         System : constant String := Option ("--system", "");
         Offer  : constant String := Option ("--tools", "");
         Instead : constant String := Option ("--template", "");
         Opened : constant Boolean := Given ("--generation-prompt");

         Source   : Model_Runner.Byte_Sources.Files.File_Source;
         Item     : Model_Runner.GGUF.Containers.Container;
         Words    : Model_Runner.Tokenizer.Vocabulary;
         Template : Model_Runner.Templates.Compiled;
         Talk     : Model_Runner.Conversation.History;
         Offered  : aliased Model_Runner.Tools.Definitions;
         Status   : E.Error_Info;

         Room : String (1 .. 65_536);
         Used : Natural;

         --  A template from a file rather than the model's own. The model
         --  is still read, because the beginning and end tokens a template
         --  writes are the model's; what changes is which template writes
         --  them. Without this, telling a divergence between this engine
         --  and another implementation from a divergence in one branch of
         --  a four-kilobyte template means editing the model file.
         function Template_Text return String is
            Held : Ada.Text_IO.File_Type;
            Room : String (1 .. 65_536);
            Used : Natural := 0;
         begin
            if Instead = "" then
               return Model_Runner.GGUF.Containers.String_Value
                 (Item, "tokenizer.chat_template");
            end if;

            Ada.Text_IO.Open (Held, Ada.Text_IO.In_File, Instead);
            while not Ada.Text_IO.End_Of_File (Held) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (Held);
               begin
                  exit when Used + Line'Length + 1 > Room'Length;
                  Room (Used + 1 .. Used + Line'Length) := Line;
                  Used := Used + Line'Length + 1;
                  Room (Used) := Character'Val (10);
               end;
            end loop;
            Ada.Text_IO.Close (Held);

            --  A file ends with a newline and a template that was written
            --  as one line does not: the last one is dropped so that what
            --  is compiled is what the file says.
            return (if Used > 0 then Room (1 .. Used - 1) else "");
         end Template_Text;
      begin
         if Path = "" then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "render: --model is required");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            Model_Runner.Byte_Sources.Files.Open
              (Source, Path, Status => Status);
            if E.Is_Error (Status) then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "render: " & E.Diagnostic_Code (Status.Code));
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
               return;
            end if;

            Model_Runner.GGUF.Containers.Reader.Parse
              (Item, Source, Status => Status);
            if E.Is_Ok (Status) then
               Model_Runner.Tokenizer.Load (Words, Item, Status => Status);
            end if;

            if E.Is_Ok (Status) then
               Model_Runner.Templates.Compile
                 (Template, Template_Text, Status => Status);
            end if;

            if E.Is_Ok (Status) then
               Model_Runner.Conversation.Open (Talk, Status => Status);
            end if;

            if E.Is_Ok (Status) and then System /= "" then
               Model_Runner.Conversation.Set_System (Talk, System, Status);
            end if;

            --  The turns, in the order they were written rather than in
            --  an order this program decides: a conversation is a sequence
            --  and a comparison against another implementation has to be
            --  able to say which sequence. --prompt is a user turn,
            --  --assistant a reply, --calls the calls that reply asked for,
            --  and --tool an answer handed back -- which is a turn of its
            --  own and not the person speaking, because a template that
            --  reads tools writes it differently from both other roles.
            declare
               Index : Natural := 2;
            begin
               while E.Is_Ok (Status)
                 and then Index < Ada.Command_Line.Argument_Count
               loop
                  declare
                     Name  : constant String :=
                       Ada.Command_Line.Argument (Index);
                     Value : constant String :=
                       Ada.Command_Line.Argument (Index + 1);
                  begin
                     if Name = "--prompt" then
                        Model_Runner.Conversation.Append
                          (Talk, Model_Runner.Conversation.User_Role, Value,
                           Status);
                        Index := Index + 2;
                     elsif Name = "--assistant" then
                        Model_Runner.Conversation.Append_Asking
                          (Talk, Value, Status);
                        Index := Index + 2;
                     elsif Name = "--calls" then
                        declare
                           Asked : Model_Runner.Tools.Calls;
                        begin
                           --  Read the way a reply's calls are read, so
                           --  that what the comparison renders is what a
                           --  conversation would hold and not a second
                           --  spelling written for the test.
                           Model_Runner.Tools.Read_Calls
                             (Asked, "<tool_call>" & Value & "</tool_call>",
                              Status);
                           for Which in 1 ..
                             Model_Runner.Tools.Count (Asked)
                           loop
                              exit when E.Is_Error (Status);
                              Model_Runner.Conversation.Append_Call
                                (Talk,
                                 Model_Runner.Tools.Called (Asked, Which),
                                 Model_Runner.Tools.Arguments (Asked, Which),
                                 Status);
                           end loop;
                           Model_Runner.Tools.Close (Asked);
                        end;
                        Index := Index + 2;
                     elsif Name = "--tool" then
                        Model_Runner.Conversation.Append
                          (Talk, Model_Runner.Conversation.Tool_Role, Value,
                           Status);
                        Index := Index + 2;
                     else
                        Index := Index + 1;
                     end if;
                  end;
               end loop;
            end;

            if E.Is_Ok (Status) and then Offer /= "" then
               Model_Runner.Tools.Read (Offered, Offer, Status);
            end if;

            if E.Is_Ok (Status) then
               Model_Runner.Templates.Render
                 (Template, Talk,
                  Model_Runner.Tokenizer.Token_Text
                    (Words, Model_Runner.Tokenizer.Beginning_Token (Words)),
                  Model_Runner.Tokenizer.Token_Text
                    (Words, Model_Runner.Tokenizer.End_Token (Words)),
                  Opened, Room, Used, Status,
                  Tools => Offered'Access);
            end if;

            if E.Is_Error (Status) then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "render: " & E.Diagnostic_Code (Status.Code));
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            else
               --  Through the stream rather than through Put, because
               --  Text_IO ends an unterminated line when it closes and a
               --  rendered prompt is exactly what must not gain a newline
               --  it did not have.
               String'Write
                 (Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Output),
                  Room (1 .. Used));
            end if;

            Model_Runner.Tools.Close (Offered);
            Model_Runner.Conversation.Close (Talk);
            Model_Runner.Templates.Close (Template);
            Model_Runner.Tokenizer.Close (Words);
            Model_Runner.GGUF.Containers.Close (Item);
            Model_Runner.Byte_Sources.Files.Close (Source);
         end if;
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

         --  A flag rather than a value, so it is looked for over the whole
         --  argument list and not only where a value would follow.
         function Given (Name : String) return Boolean is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return True;
               end if;
            end loop;
            return False;
         end Given;

         Path    : constant String := Option ("--model", "");
         Prompt  : constant String := Option ("--prompt", "Hello");
         Special : constant Boolean := Given ("--special");

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
                     --  --special asks for the markers the vocabulary's own
                     --  policy adds, which is what the counterpart in
                     --  llama.cpp does by default. Without it the two differ
                     --  by those markers and the difference is the tool's
                     --  rather than the engine's; with it, a vocabulary that
                     --  wraps its text in two pieces and an engine that does
                     --  not can be told apart. A published jina-bert-v2 was
                     --  such a case.
                     Model_Runner.Tokenizer.Encode
                       (Words, Prompt,
                        Special
                          and then Model_Runner.Tokenizer.Adds_Beginning
                                     (Words),
                        Special
                          and then Model_Runner.Tokenizer.Adds_End (Words),
                        Tokens, Used, Status);

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

   elsif Command = "slow" then
      --  The suite, reported by where its time went. It costs twenty-eight
      --  minutes and nothing said which tests those were; the text reporter
      --  is handed AUnit's own measurements and prints none of them.
      if Ada.Command_Line.Argument_Count >= 2 then
         Case_Timing.Report_Routines (Ada.Command_Line.Argument (2));
      else
         Case_Timing.Report;
      end if;

   elsif Command = "device-bench" then
      --  Where an attention call's time goes, before another kernel is
      --  written on a guess about it.
      Device_Bench.Report;

   elsif Command = "fixture-likeness" then
      --  Compare a published file's tensor list against the fixture this
      --  repository builds for its architecture. Everything else here
      --  compares two implementations written together against a fixture
      --  written to suit them; this is the one check that asks whether the
      --  fixture resembles a model anybody ships.
      declare
         use type Fixture_Likeness.Outcome;
         Found : Fixture_Likeness.Report;
         --  Read an option's value.
         --
         --  @param Name Option to look for.
         --  @param Default What to return when it is absent.
         --  @return The word after the option, or the default.
         function Option (Name : String; Default : String) return String;

         --  Report whether a flag was given.
         --
         --  @param Name Flag to look for.
         --  @return Whether it appears among the arguments.
         function Given (Name : String) return Boolean;

         function Option (Name : String; Default : String) return String is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count - 1 loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return Ada.Command_Line.Argument (Index + 1);
               end if;
            end loop;
            return Default;
         end Option;

         function Given (Name : String) return Boolean is
         begin
            for Index in 2 .. Ada.Command_Line.Argument_Count loop
               if Ada.Command_Line.Argument (Index) = Name then
                  return True;
               end if;
            end loop;
            return False;
         end Given;

         Path    : constant String := Option ("--model", "");
         Verbose : constant Boolean := Given ("--names");

         --  Print one name and which side carries it.
         procedure Show
           (Name : String; In_File : Boolean; In_Fixture : Boolean);

         procedure Show
           (Name : String; In_File : Boolean; In_Fixture : Boolean) is
         begin
            Ada.Text_IO.Put_Line
              ("  " & (if In_File then "file" else "    ")
               & " " & (if In_Fixture then "fixture" else "       ")
               & "  " & Name);
         end Show;
      begin
         if Path = "" then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "usage: tests fixture-likeness MODEL.gguf [--names]");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            Fixture_Likeness.Compare (Path, Found);
            Ada.Text_IO.Put_Line
              ("fixture-likeness: " & Fixture_Likeness.Summary (Found));
            if Verbose then
               declare
                  procedure Walk is new Fixture_Likeness.Each_Name (Show);
               begin
                  Walk;
               end;
            end if;
            if Found.Result = Fixture_Likeness.Rejected then
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end if;
         end if;
      end;

   elsif Command = "shader" then
      --  Turn a compiled shader into the Ada constant the engine hands to a
      --  device. Compiling is not done here: it needs a shader compiler,
      --  which is not a build dependency of this project.
      declare
         --  Pairs follow the command word, and a root may follow them. With
         --  no root the count is odd, with one it is even, and the pair
         --  count falls out of which.
         Rooted : constant Boolean :=
           Ada.Command_Line.Argument_Count mod 2 = 0;

         Root : constant String :=
           (if Rooted
            then Ada.Command_Line.Argument (Ada.Command_Line.Argument_Count)
            else "..");
         Written : Boolean;
      begin
         if Ada.Command_Line.Argument_Count < 3 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "usage: tests shader SOURCE.comp COMPILED.spv"
               & " [SOURCE.comp COMPILED.spv ...] [ROOT]");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            declare
               --  Every shader on every call: the package is written whole,
               --  and one written from half the shaders would name one's
               --  words beside another's digest.
               Pairs : Shader_Generation.Shader_Pairs
                 (1 .. (if Rooted
                        then (Ada.Command_Line.Argument_Count - 2) / 2
                        else (Ada.Command_Line.Argument_Count - 1) / 2));
            begin
               for Index in Pairs'Range loop
                  Pairs (Index) :=
                    (Source =>
                       new String'(Ada.Command_Line.Argument (Index * 2)),
                     Compiled =>
                       new String'
                         (Ada.Command_Line.Argument (Index * 2 + 1)));
               end loop;

               Shader_Generation.Write_Shaders (Root, Pairs, Written);
            end;

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

         --  Quiet_Enough and not Publishable, because this asks whether a
         --  figure may be taken *now* and the two readers above ask whether
         --  the machine was busy while something already ran. The minute's
         --  average is the right instrument for the second question and the
         --  wrong one for the first: it answers about the window a finished
         --  stage occupied, and it lags the window a run is about to.
         elsif not Given ("--anyway")
           and then not Host_Load.Quiet_Enough
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

         --  The arithmetic, told to the backend before anything is
         --  dispatched. Not a parameter of the run, because what it selects
         --  is how a product is computed rather than what the run does, and
         --  the backend states that it must be told once and not part way
         --  through.
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (Option ("--arith", "int8") = "int8");

         --  Several sequences in one pass rather than one, which is a
         --  different measurement and takes a different loop: a round has
         --  no draft, no sampler beyond the greedy one and no repeats,
         --  because what it answers is what a token costs a member.
         --  Several callers arriving and leaving, which is the policy over
         --  the round rather than the round itself: members with different
         --  limits, and a caller admitted for every one that finishes.
         if Option ("--serve", "") /= "" then
            Speed_Run.Serve
              (Path        => Option ("--model", ""),
               Prompt_Path =>
                 Option ("--prompt-file",
                         "../tests/fixtures/speed-prompt-short.txt"),
               Tokens      => Number ("--max-tokens", 12),
               Threads     => Number ("--threads",
                                      Model_Runner.Platform.Core_Count - 1),
               Members     => Number ("--serve", 1),
               Arrivals    => Number ("--callers", Number ("--serve", 1)),
               Backend     => Backend_Of (Option ("--backend", "cpu")));
            return;
         end if;

         if Option ("--round", "") /= "" then
            Speed_Run.Round
              (Path        => Option ("--model", ""),
               Prompt_Path =>
                 Option ("--prompt-file",
                         "../tests/fixtures/speed-prompt-short.txt"),
               Tokens      => Number ("--max-tokens", 12),
               Threads     => Number ("--threads",
                                      Model_Runner.Platform.Core_Count - 1),
               Members     => Number ("--round", 1),
               Backend     => Backend_Of (Option ("--backend", "cpu")),
               Budget      => Given ("--budget"));
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
            --  The command's own default, not a copy of it. This carried
            --  its own 128 while the command's went to 512, and a sitting
            --  taken with it measured a batch nobody would ever run --
            --  which is the same failure this tool was fixed for once
            --  before, when it read the prompt file differently from the
            --  command it publishes figures for.
            Batch       =>
              Number ("--batch-size",
                      Model_Runner.Generation.Request'(others => <>)
                        .Batch_Size),

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
            Budget      => Given ("--budget"),
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
         --  Which architecture to write, for a caller who wants to run the
         --  program by hand against a shape the suite only reaches through
         --  the library. Absent, it is the one the suite's own fixture is.
         Named : constant String :=
           (if Ada.Command_Line.Argument_Count >= 3
            then Ada.Command_Line.Argument (3)
            else "");

         Kind  : Tiny_Model.Fixture_Architecture := Tiny_Model.Llama;
         Known : Boolean := Named = "";

         Stem  : constant String :=
           (if Named = "" then "tiny-model" else "tiny-" & Named);
      begin
         for Choice in Tiny_Model.Fixture_Architecture loop
            if Model_Runner.Text.To_Lower
                 (Tiny_Model.Fixture_Architecture'Image (Choice)) = Named
            then
               Kind := Choice;
               Known := True;
            end if;
         end loop;

         if not Known then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "unknown architecture: " & Named);
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;

         Tiny_Model.Write (Directory & "/" & Stem & ".gguf", Kind => Kind);
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "wrote " & Directory & "/" & Stem & ".gguf");
      end;

   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "unknown command: " & Command);
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, Tool_Commands.Usage_Line);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests_Main;
