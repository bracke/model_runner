with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Agent_Trial;
with Agent_Campaign;
with Hostkit;
with Hostkit.Process;
with Learning_Curriculum;
with Project_Tools.Files;
with Trial_Confinement;
with Model_Runner.Text;
with Model_Runner.Errors;
with Learning_Data;
with Learning_Lora_Files;
with Learning_Fit;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Learning_Report;
with Learning_Isolation;

--  Explicit local experiment driver. No model or configuration default is changed.
procedure Mellum_Learning_Main is
   use Ada.Strings.Unbounded;
   use type Agent_Trial.Verdict;
   function Arg (Which : Positive) return String renames Ada.Command_Line.Argument;
   Clean : Boolean;
   Seen : Natural := 0;
   Destination : Unbounded_String;
   Label : Unbounded_String;
   Arm : Unbounded_String := To_Unbounded_String ("base");
   Seed : Natural := 0;
   Protocol_SHA : constant String := Ada.Environment_Variables.Value
     ("MODEL_RUNNER_LEARNING_PROTOCOL_SHA256",
      "c2aec4be9117028fe5d449486e872cc2e929eddad99c6ef6ace21f6424ca30dc");
   Infrastructure_Failed : Boolean := False;
   Status : Model_Runner.Errors.Error_Info;
   procedure Record_Attempt (Item : Agent_Trial.Attempt) is
   begin
      Seen := Seen + 1;
      Infrastructure_Failed := Infrastructure_Failed or else Item.Grade = Agent_Trial.Infrastructure_Error;
      Project_Tools.Files.Write_Raw_File
        (To_String (Destination) & "/result.json",
         Agent_Campaign.Attempt_JSON
           (To_String (Label), To_String (Arm), Seed, Item,
            Protocol_SHA) & ASCII.LF);
   end Record_Attempt;
   procedure Say_Status is
   begin
      if Model_Runner.Errors.Is_Ok (Status) then
         Ada.Text_IO.Put_Line ("learning operation: complete");
         Ada.Command_Line.Set_Exit_Status (0);
      else
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "learning operation refused: " & Status'Image);
      end if;
   end Say_Status;
begin
   Ada.Command_Line.Set_Exit_Status (1);
   if Protocol_SHA'Length /= 64
     or else not (for all Ch of Protocol_SHA => Ch in '0' .. '9' | 'a' .. 'f')
   then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "learning driver: protocol SHA-256 must be 64 lowercase hex digits");
      return;
   end if;
   if Ada.Command_Line.Argument_Count = 2 and then Arg (1) = "controls" then
      Learning_Curriculum.Validate (Arg (2), Clean);
      Ada.Text_IO.Put_Line ("learning curriculum controls: " & (if Clean then "passed" else "FAILED"));
      Ada.Command_Line.Set_Exit_Status (if Clean then 0 else 1);
   elsif Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "curate" then
      Learning_Data.Curate (Arg (2), Arg (3), Status);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "curate-preview" then
      Learning_Data.Curate (Arg (2), Arg (3), Status, Only_Family => 1);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "summarize" then
      Learning_Report.Run (Arg (2), Arg (3), Status);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 4 and then Arg (1) = "extract" then
      Learning_Data.Extract (Arg (2), Arg (3), Arg (4), Status);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 4 and then Arg (1) = "merge" then
      Learning_Lora_Files.Merge (Arg (2), Arg (3), Arg (4), Status);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 4 and then Arg (1) = "fit" then
      Learning_Fit.Run (Arg (2), Arg (3), Arg (4), Status);
      Say_Status;
   elsif Ada.Command_Line.Argument_Count = 4 and then Arg (1) = "collect-all" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Ran : Hostkit.Process.Process_Outcome;
      begin
         if Ada.Directories.Exists (Root) then
            Ada.Text_IO.Put_Line ("collection requires a new root");
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         for Which in 1 .. Learning_Curriculum.Families loop
            for Trial_Seed in 42 .. 44 loop
               declare
                  Id : constant String := Learning_Curriculum.Family (Which) & "-"
                    & Model_Runner.Text.Image (Long_Long_Integer (Trial_Seed));
               begin
                  Ada.Text_IO.Put_Line ("collecting " & Id);
                  Ada.Text_IO.Flush;
                  Ran := Hostkit.Process.Run_Captured
                    (Ada.Command_Line.Command_Name,
                     [To_Unbounded_String ("collect"), To_Unbounded_String (Root & "/" & Id),
                      To_Unbounded_String (Arg (3)), To_Unbounded_String (Arg (4)),
                      To_Unbounded_String (Model_Runner.Text.Image (Long_Long_Integer (Which))),
                      To_Unbounded_String (Model_Runner.Text.Image (Long_Long_Integer (Trial_Seed)))],
                     Stdout_Path => Root & "/" & Id & ".log", Stderr_Path => Root & "/" & Id & ".errors",
                     Timeout_Ms => 900_000, Whole_Group => True);
                  if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
                     Ada.Text_IO.Put_Line ("collection infrastructure failure: " & Id);
                     return;
                  end if;
                  Ada.Text_IO.Put_Line ("retained " & Id);
               end;
            end loop;
         end loop;
         Ada.Command_Line.Set_Exit_Status (0);
      end;
   elsif Ada.Command_Line.Argument_Count = 5 and then Arg (1) = "evaluate-all" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Ran : Hostkit.Process.Process_Outcome;
         Tasks : constant Hostkit.String_Vectors.Vector :=
           [To_Unbounded_String ("edit"), To_Unbounded_String ("times-negative"), To_Unbounded_String ("subtract")];
         package J renames Jsonlib.Documents;
         Doc : J.Document;
         Object : constant J.Node := J.New_Object (Doc);
         procedure Put (Key, Value : String) is
         begin
            J.Insert (Doc, Object, Key, J.New_String (Doc, Value));
         end Put;
      begin
         if Ada.Directories.Exists (Root) then
            Ada.Text_IO.Put_Line ("held-out evaluation requires a new root");
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         J.Set_Root (Doc, Object);
         Put ("schema", "model_runner.mellum_learning_evaluation.v1");
         Put ("protocol_sha256", Protocol_SHA);
         Put ("base_sha256", Learning_Lora_Files.Digest (Arg (3)));
         Put ("base_path", Ada.Directories.Full_Name (Arg (3)));
         Put ("adapted_sha256", Learning_Lora_Files.Digest (Arg (4)));
         Put ("adapted_path", Ada.Directories.Full_Name (Arg (4)));
         Put ("program_sha256", Learning_Lora_Files.Digest (Arg (5)));
         Put ("program_path", Ada.Directories.Full_Name (Arg (5)));
         Put ("driver_sha256", Learning_Lora_Files.Digest (Ada.Command_Line.Command_Name));
         Put ("configuration_sha256", Learning_Lora_Files.Digest
           (Ada.Environment_Variables.Value ("MODEL_RUNNER_CONFIG", "")));
         Put ("configuration_path", Ada.Environment_Variables.Value ("MODEL_RUNNER_CONFIG", ""));
         Put ("isolation_hidden_root", Root);
         J.Insert (Doc, Object, "pairs", J.New_Integer (Doc, 9));
         J.Insert (Doc, Object, "work_limit_seconds", J.New_Integer (Doc, 300));
         Project_Tools.Files.Write_Raw_File
           (Root & "/manifest.json", Jsonlib.Serializers.To_String (Doc) & ASCII.LF);
         for Which in 1 .. 3 loop
            for Trial_Seed in 51 .. 53 loop
               for Turn in 0 .. 1 loop
                  declare
                     Adapted : constant Boolean := (Turn = 0) = ((Which + Trial_Seed) mod 2 = 0);
                     Role : constant String := (if Adapted then "adapted" else "base");
                     Task_Name : constant String := To_String (Tasks (Which));
                     Id : constant String := Task_Name & "-"
                       & Model_Runner.Text.Image (Long_Long_Integer (Trial_Seed)) & "-" & Role;
                  begin
                     Ada.Text_IO.Put_Line ("evaluating " & Id);
                     Ada.Text_IO.Flush;
                     Ran := Hostkit.Process.Run_Captured
                       (Ada.Command_Line.Command_Name,
                        [To_Unbounded_String ("evaluate"), To_Unbounded_String (Root & "/" & Id),
                         To_Unbounded_String (if Adapted then Arg (4) else Arg (3)), To_Unbounded_String (Arg (5)),
                         To_Unbounded_String (Task_Name),
                         To_Unbounded_String (Model_Runner.Text.Image (Long_Long_Integer (Trial_Seed))),
                         To_Unbounded_String (Role)],
                        Stdout_Path => Root & "/" & Id & ".log", Stderr_Path => Root & "/" & Id & ".errors",
                        Timeout_Ms => 900_000, Whole_Group => True);
                     if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
                        Ada.Text_IO.Put_Line ("evaluation infrastructure failure: " & Id);
                        return;
                     end if;
                     Ada.Text_IO.Put_Line ("retained " & Id);
                  end;
               end loop;
            end loop;
         end loop;
         Ada.Command_Line.Set_Exit_Status (0);
      end;
   elsif Ada.Command_Line.Argument_Count = 7 and then Arg (1) = "evaluate" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Words : Hostkit.String_Vectors.Vector;
      begin
         Seed := Natural'Value (Arg (6));
         if Arg (5) not in "edit" | "times-negative" | "subtract"
           or else Arg (7) not in "base" | "adapted" or else Ada.Directories.Exists (Root)
         then
            Ada.Text_IO.Put_Line ("a new root and a declared evaluation task/arm are required");
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         if not Trial_Confinement.Ready (Root) then
            Ada.Text_IO.Put_Line ("evaluation confinement refused");
            return;
         end if;
         Destination := To_Unbounded_String (Root);
         Label := To_Unbounded_String (Arg (5));
         Arm := To_Unbounded_String (Arg (7));
         Ada.Environment_Variables.Set
           ("MODEL_RUNNER_CAPTURE_DIR", Root & "/attempts/trial-" & Arg (5) & "/.trial-runtime/captures");
         Words.Append (To_Unbounded_String ("--seed"));
         Words.Append (To_Unbounded_String (Arg (6)));
         Agent_Trial.Run
           (Model => Arg (3), Program => Arg (4), Options => "", Only => Arg (5), Clean => Clean,
            Repeats => 1, Knowledge => False, Max_Seconds => 300,
            Output_Directory => Root & "/attempts", Isolation_Root => Learning_Isolation.Hidden_Root (Root),
            On_Attempt => Record_Attempt'Access, Extra_Arguments => Words);
         Ada.Command_Line.Set_Exit_Status (if Seen = 1 and then not Infrastructure_Failed then 0 else 1);
      end;
   elsif Ada.Command_Line.Argument_Count = 6 and then Arg (1) = "collect" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Which : constant Positive := Positive'Value (Arg (5));
         Words : Hostkit.String_Vectors.Vector;
      begin
         Seed := Natural'Value (Arg (6));
         if Which > Learning_Curriculum.Families or else Ada.Directories.Exists (Root) then
            Ada.Text_IO.Put_Line ("a new collection root and a valid family are required");
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         if not Trial_Confinement.Ready (Root) then
            Ada.Text_IO.Put_Line ("learning collection confinement refused");
            return;
         end if;
         Learning_Curriculum.Make_Project (Root & "/fixture", Which);
         Destination := To_Unbounded_String (Root);
         Label := To_Unbounded_String (Learning_Curriculum.Family (Which));
         Ada.Environment_Variables.Set
           ("MODEL_RUNNER_CAPTURE_DIR", Root & "/attempts/trial-edit/.trial-runtime/captures");
         Words.Append (To_Unbounded_String ("--seed"));
         Words.Append (To_Unbounded_String (Arg (6)));
         Agent_Trial.Run
           (Model => Arg (3), Program => Arg (4), Options => "", Only => "edit", Clean => Clean,
            Repeats => 1, Knowledge => False, Max_Seconds => 300,
            Output_Directory => Root & "/attempts", Isolation_Root => Learning_Isolation.Hidden_Root (Root),
            On_Attempt => Record_Attempt'Access, Extra_Arguments => Words,
            Fixture_Root => Root & "/fixture", Fixture_Notes => Learning_Curriculum.Notes (Which));
         --  A task failure is retained data. Infrastructure or a missing result fails this driver.
         Ada.Command_Line.Set_Exit_Status (if Seen = 1 and then not Infrastructure_Failed then 0 else 1);
      end;
   else
      Ada.Text_IO.Put_Line ("usage: mellum_learning_main controls NEW_ROOT");
      Ada.Text_IO.Put_Line ("       mellum_learning_main collect NEW_ROOT MODEL PROGRAM FAMILY SEED");
      Ada.Text_IO.Put_Line ("       mellum_learning_main collect-all NEW_ROOT MODEL PROGRAM");
      Ada.Text_IO.Put_Line ("       mellum_learning_main curate COLLECTION NEW_DATASET");
      Ada.Text_IO.Put_Line ("       mellum_learning_main extract MODEL DATASET NEW_FEATURES");
      Ada.Text_IO.Put_Line ("       mellum_learning_main fit MODEL FEATURES NEW_CHECKPOINTS");
      Ada.Text_IO.Put_Line ("       mellum_learning_main merge MODEL ADAPTER NEW_MODEL");
      Ada.Text_IO.Put_Line ("       mellum_learning_main evaluate-all NEW_ROOT BASE ADAPTED PROGRAM");
      Ada.Text_IO.Put_Line ("       mellum_learning_main summarize EVALUATION NEW_JSON");
   end if;
exception
   when others =>
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "learning driver: invalid input or experiment failure");
      Ada.Command_Line.Set_Exit_Status (1);
end Mellum_Learning_Main;
