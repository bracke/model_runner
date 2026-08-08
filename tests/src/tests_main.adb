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
with External_Model;
with Docs_Generation;
with Benchmarks;
with Packaging;
with Fuzzing;
with Tiny_Model;

--  Entry point of the model_runner test and tooling executable.
--
--  The first argument selects a command. "test" runs every mandatory
--  deterministic suite and is the default.
procedure Tests_Main is
   use type AUnit.Status;

   function Run_Suite is
     new AUnit.Run.Test_Runner_With_Status (Tests.Suite.Suite);

   Reporter : AUnit.Reporter.Text.Text_Reporter;

   --  Selected command, defaulting to the mandatory suite.
   function Command return String is
   begin
      if Ada.Command_Line.Argument_Count = 0 then
         return "test";
      else
         return Ada.Command_Line.Argument (1);
      end if;
   end Command;

begin
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
      begin
         Checks.Run (Root, Result);
         if not Checks.Is_Clean (Result) then
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
            & ", outside tolerance" & Natural'Image (Result.Failures));

         if not Conformance.Is_Clean (Result) then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
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

         Path   : constant String := Option ("--model", "");
         Result : External_Model.Report;
      begin
         External_Model.Run
           (Path    => Path,
            Prompt  => Option ("--prompt", "Hello"),
            Tokens  => Number ("--max-tokens", 16),
            Threads => Number ("--threads", 4),
            Expect  => Option ("--expect", ""),
            Result  => Result);

         case Result.Result is
            when External_Model.Skipped =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "external-model: skipped ("
                  & External_Model.Detail_Text (Result) & ")");

            when External_Model.Rejected =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "external-model: rejected ("
                  & External_Model.Detail_Text (Result) & ")");
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);

            when External_Model.Failed =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "external-model: FAILED ("
                  & External_Model.Detail_Text (Result) & ")");
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);

            when External_Model.Ran =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "external-model: ok, "
                  & External_Model.Detail_Text (Result)
                  & ", prompt" & Natural'Image (Result.Prompt_Tokens)
                  & " tokens, generated"
                  & Natural'Image (Result.Generated)
                  & ", deterministic "
                  & Boolean'Image (Result.Deterministic)
                  & ", thread-stable "
                  & Boolean'Image (Result.Thread_Stable)
                  & (if Result.Reference_Run
                     then ", tokens-match "
                          & Boolean'Image (Result.Tokens_Match)
                          & ", greedy-match "
                          & Boolean'Image (Result.Greedy_Match)
                          & ", text-match "
                          & Boolean'Image (Result.Text_Match)
                          & ", logits compared"
                          & Natural'Image (Result.Compared)
                     else ""));
         end case;
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

   elsif Command = "benchmark" then
      --  Measure the kernels. Not part of the mandatory suite: it reports
      --  numbers rather than passing or failing.
      Benchmarks.Run;

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
        (Ada.Text_IO.Standard_Error, "usage: tests [test | check [ROOT] | fuzz [--seed N] [--cases N]"
         & " | fixtures [DIR]]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests_Main;
