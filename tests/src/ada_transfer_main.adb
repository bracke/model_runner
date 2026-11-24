with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Agent_Trial;
with Agent_Campaign;
with Transfer_Curriculum;
with Trial_Graders;
with Trial_Confinement;
with Hostkit;
with Hostkit.Process;
with Hostkit.Fs;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Jsonlib.Errors;
with Learning_Lora_Files;
with Learning_Report;
with Model_Runner.Errors;
with Model_Runner.Text;
with Project_Tools.Files;
with GNAT.SHA256;

--  Historical real-project replay; all reference artifacts remain outside each actor's boundary.
procedure Ada_Transfer_Main is
   use Ada.Strings.Unbounded;
   use type Agent_Trial.Verdict;
   use type Jsonlib.Documents.Value_Kind;
   use type Ada.Directories.File_Kind;
   package C renames Transfer_Curriculum;
   package J renames Jsonlib.Documents;
   function Arg (Index : Positive) return String renames Ada.Command_Line.Argument;
   function Number (Value : Natural) return String is
     (Model_Runner.Text.Image (Long_Long_Integer (Value)));
   function Workspace_Of (Program : String) return String is
     (Ada.Directories.Containing_Directory (Ada.Directories.Containing_Directory
       (Ada.Directories.Containing_Directory (Program))));
   function Hash (Path : String) return String renames Learning_Lora_Files.Digest;
   Protocol : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_TRANSFER_PROTOCOL_SHA256", "");
   Doc : J.Document;
   Object : J.Node;
   function Read (Path : String) return String renames Project_Tools.Files.Read_Raw_File;
   procedure Put (Into : in out J.Document; Node : J.Node; Key, Value : String) is
   begin
      J.Insert (Into, Node, Key, J.New_String (Into, Value));
   end Put;
   procedure Write (Path : String; From : J.Document) is
   begin
      Project_Tools.Files.Write_Raw_File (Path, Jsonlib.Serializers.To_String (From) & ASCII.LF);
   end Write;
   function File_Text (Path : String) return String is
      Raw : constant String := Read (Path);
      First : Natural := Raw'First;
      Last : Natural := Raw'Last;
   begin
      while First <= Last and then Raw (First) in ' ' | ASCII.LF | ASCII.CR loop
         First := First + 1;
      end loop;
      while Last >= First and then Raw (Last) in ' ' | ASCII.LF | ASCII.CR loop
         Last := Last - 1;
      end loop;
      return Raw (First .. Last);
   end File_Text;
   function Member (From : J.Document; Key : String) return String is
     (J.As_String (From, J.Member (From, J.Root (From), Key)));
   procedure Load (Path : String; Into : in out J.Document; Good : out Boolean) is
      Error : Jsonlib.Errors.Error_Info;
   begin
      Jsonlib.Parsers.Parse (Read (Path), Into, Error);
      Good := not Jsonlib.Errors.Failed (Error) and then J.Kind (Into, J.Root (Into)) = J.Object_Value;
   end Load;
   function Resource_Digest (Root, Output : String) return String is
      Rows : Hostkit.String_Vectors.Vector;
      package Ordering is new Hostkit.String_Vectors.Generic_Sorting;
      Joined : Unbounded_String;
      procedure Walk (Directory, Prefix : String; Depth : Natural) is
         Search : Ada.Directories.Search_Type;
         Entry_Item : Ada.Directories.Directory_Entry_Type;
      begin
         if Depth > 8 then
            raise Constraint_Error;
         end if;
         Ada.Directories.Start_Search (Search, Directory, "*");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Entry_Item);
            declare
               Name : constant String := Ada.Directories.Simple_Name (Entry_Item);
               Full : constant String := Ada.Directories.Full_Name (Entry_Item);
            begin
               if Name not in "." | ".." then
                  if Hostkit.Fs.Is_Link (Full) then
                     raise Constraint_Error;
                  end if;
                  if Ada.Directories.Kind (Entry_Item) = Ada.Directories.Directory then
                     Walk (Full, Prefix & Name & "/", Depth + 1);
                  elsif Ada.Directories.Kind (Entry_Item) = Ada.Directories.Ordinary_File then
                     Rows.Append (To_Unbounded_String (Hash (Full) & "  " & Prefix & Name & ASCII.LF));
                  end if;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      end Walk;
   begin
      Walk (Root, "", 0);
      Ordering.Sort (Rows);
      for Row of Rows loop
         Append (Joined, Row);
      end loop;
      Project_Tools.Files.Write_Raw_File (Output, To_String (Joined));
      return GNAT.SHA256.Digest (To_String (Joined));
   end Resource_Digest;
begin
   Ada.Command_Line.Set_Exit_Status (1);
   if Protocol'Length /= 64 or else not (for all Ch of Protocol => Ch in '0' .. '9' | 'a' .. 'f') then
      Ada.Text_IO.Put_Line ("transfer: a predeclared protocol SHA-256 is required");
      return;
   end if;
   if Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "prepare" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Workspace : constant String := Ada.Directories.Full_Name (Arg (3));
         Rows : J.Node;
         Good : Boolean;
         Ran : Hostkit.Process.Process_Outcome;
      begin
         if Ada.Directories.Exists (Root) then
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         J.Set_Root (Doc, J.New_Object (Doc));
         Object := J.Root (Doc);
         Put (Doc, Object, "schema", "model_runner.ada_transfer_curriculum.v1");
         Put (Doc, Object, "protocol_sha256", Protocol);
         Rows := J.New_Array (Doc);
         for Which in 1 .. C.Tasks loop
            declare
               Path : constant String := Root & "/" & C.Name (Which);
               Item : constant J.Node := J.New_Object (Doc);
               Permitted : constant J.Node := J.New_Array (Doc);
               Grades : array (Boolean) of Agent_Trial.Verdict;
            begin
               for Reference in Boolean loop
                  declare
                     Project : constant String := Path & (if Reference then "-reference" else "");
                  begin
                     C.Make (Project, Workspace, Which, Reference, Good);
                     if not Good then
                        Ada.Text_IO.Put_Line ("transfer: snapshot preparation failed: " & Project);
                        return;
                     end if;
                     Trial_Graders.Preserve (Project, Project & ".hidden_test.adb");
                     Grades (Reference) := Trial_Graders.Verify
                       (Project, "edit", "", "", True, Confine => True, Modern => True, Hidden_Root => Workspace);
                     if Grades (Reference) /= (if Reference then Agent_Trial.Passed else Agent_Trial.Failed) then
                        Ada.Text_IO.Put_Line ("transfer: grader qualification failed: " & Project
                                               & " " & Grades (Reference)'Image);
                        return;
                     end if;
                  end;
               end loop;
               Ran := Hostkit.Process.Run_Captured
                 ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Path), To_Unbounded_String ("rev-parse"),
                          To_Unbounded_String ("HEAD:src")], Stdout_Path => Path & ".source-tree",
                  Stderr_Path => Path & ".tree-errors", Timeout_Ms => 10_000);
               if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
                  return;
               end if;
               Put (Doc, Item, "task", C.Name (Which));
               Put (Doc, Item, "repository", C.Repository (Which));
               Put (Doc, Item, "fix_commit", C.Revision (Which));
               Put (Doc, Item, "parent_commit", File_Text (Path & ".parent-commit"));
               Put (Doc, Item, "initial_src_git_tree", File_Text (Path & ".source-tree"));
               Put (Doc, Item, "notes", C.Notes (Which));
               Put (Doc, Item, "public_test_sha256", Hash (Path & "/src/test_add.adb"));
               Put (Doc, Item, "independent_test_sha256", Hash (Path & ".hidden_test.adb"));
               Put (Doc, Item, "unchanged_control", "failed");
               Put (Doc, Item, "reference_control", "passed");
               for Allowed of C.Paths (Which) loop
                  J.Append (Doc, Permitted, J.New_String (Doc, To_String (Allowed)));
               end loop;
               J.Insert (Doc, Item, "permitted_paths", Permitted);
               J.Append (Doc, Rows, Item);
               Ada.Text_IO.Put_Line ("qualified " & C.Name (Which));
               Ada.Text_IO.Flush;
            end;
         end loop;
         J.Insert (Doc, Object, "tasks", Rows);
         Write (Root & "/curriculum.json", Doc);
      end;
   elsif Ada.Command_Line.Argument_Count = 6 and then Arg (1) = "run" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Curriculum : constant String := Ada.Directories.Full_Name (Arg (3));
         Program : constant String := Ada.Directories.Full_Name (Arg (6));
         Resources : constant String := Ada.Directories.Containing_Directory
           (Ada.Directories.Containing_Directory (Program)) & "/resources";
         Ran : Hostkit.Process.Process_Outcome;
      begin
         if Ada.Directories.Exists (Root) then
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         J.Set_Root (Doc, J.New_Object (Doc));
         Object := J.Root (Doc);
         Put (Doc, Object, "schema", "model_runner.ada_transfer_manifest.v1");
         Put (Doc, Object, "protocol_sha256", Protocol);
         Put (Doc, Object, "curriculum_path", Curriculum);
         Put (Doc, Object, "curriculum_sha256", Hash (Curriculum & "/curriculum.json"));
         Put (Doc, Object, "base_path", Ada.Directories.Full_Name (Arg (4)));
         Put (Doc, Object, "base_sha256", Hash (Arg (4)));
         Put (Doc, Object, "adapted_path", Ada.Directories.Full_Name (Arg (5)));
         Put (Doc, Object, "adapted_sha256", Hash (Arg (5)));
         Put (Doc, Object, "program_path", Program);
         Put (Doc, Object, "program_sha256", Hash (Program));
         Put (Doc, Object, "driver_sha256", Hash (Ada.Command_Line.Command_Name));
         Put (Doc, Object, "driver_path", Ada.Directories.Full_Name (Ada.Command_Line.Command_Name));
         Put (Doc, Object, "configuration_path", Ada.Environment_Variables.Value ("MODEL_RUNNER_CONFIG", ""));
         Put (Doc, Object, "configuration_sha256", Hash
           (Ada.Environment_Variables.Value ("MODEL_RUNNER_CONFIG", "")));
         Put (Doc, Object, "hidden_workspace", Workspace_Of (Program));
         Put (Doc, Object, "runtime_resources_sha256", Resource_Digest (Resources, Root & "/runtime-resources.sha256"));
         J.Insert (Doc, Object, "pairs", J.New_Integer (Doc, 12));
         J.Insert (Doc, Object, "work_limit_seconds", J.New_Integer (Doc, 600));
         Write (Root & "/manifest.json", Doc);
         Ran := Hostkit.Process.Run_Captured
           ("gnatls", [To_Unbounded_String ("--version")], Stdout_Path => Root & "/compiler.txt",
            Stderr_Path => Root & "/compiler-errors.txt", Timeout_Ms => 10_000);
         if not Ran.Started or else Ran.Exit_Status /= 0 then
            return;
         end if;
         --  Preflight resource lookup under the same broad hidden-workspace boundary, before any generation.
         Ran := Hostkit.Process.Run_Captured
           (Trial_Confinement.Executable, Trial_Confinement.Wrap
              (Program, [To_Unbounded_String ("version")], Root,
               Workspace_Of (Program),
               [To_Unbounded_String (Resources)]), Stdout_Path => Root & "/runtime-preflight.txt",
            Stderr_Path => Root & "/runtime-preflight-errors.txt", Timeout_Ms => 30_000);
         if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
            Ada.Text_IO.Put_Line ("transfer: confined runtime preflight failed"); return;
         end if;
         Ran := Hostkit.Process.Run_Captured
           (Trial_Confinement.Executable, Trial_Confinement.Wrap
              (Hostkit.Process.Locate ("cat"), [To_Unbounded_String
                 (Workspace_Of (Program) & "/project_tools/src/project_tools-text.adb")], Root,
               Workspace_Of (Program), [To_Unbounded_String (Resources)]),
            Stdout_Path => Root & "/upstream-preflight.txt",
            Stderr_Path => Root & "/upstream-preflight-errors.txt", Timeout_Ms => 10_000);
         if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status = 0 then
            Ada.Text_IO.Put_Line ("transfer: upstream source was not hidden");
            return;
         end if;
         for Which in 1 .. C.Tasks loop
            for Seed in 71 .. 72 loop
               for Turn in 0 .. 1 loop
                  declare
                     Adapted : constant Boolean := (Turn = 0) = ((Which + Seed) mod 2 = 0);
                     Role : constant String := (if Adapted then "adapted" else "base");
                     Id : constant String := C.Name (Which) & "-" & Number (Seed) & "-" & Role;
                  begin
                     Ada.Text_IO.Put_Line ("evaluating " & Id); Ada.Text_IO.Flush;
                     Ran := Hostkit.Process.Run_Captured
                       (Ada.Command_Line.Command_Name,
                        [To_Unbounded_String ("evaluate"), To_Unbounded_String (Root & "/" & Id),
                         To_Unbounded_String (Curriculum), To_Unbounded_String (if Adapted then Arg (5) else Arg (4)),
                         To_Unbounded_String (Program), To_Unbounded_String (Number (Which)),
                         To_Unbounded_String (Number (Seed)), To_Unbounded_String (Role),
                         To_Unbounded_String (Hash (Root & "/manifest.json"))],
                        Stdout_Path => Root & "/" & Id & ".log", Stderr_Path => Root & "/" & Id & ".errors",
                        Timeout_Ms => 1_200_000, Whole_Group => True);
                     if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
                        Ada.Text_IO.Put_Line ("transfer: infrastructure failure retained: " & Id); return;
                     end if;
                     Ada.Text_IO.Put_Line ("retained " & Id); Ada.Text_IO.Flush;
                  end;
               end loop;
            end loop;
         end loop;
      end;
   elsif Ada.Command_Line.Argument_Count = 9 and then Arg (1) = "evaluate" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Curriculum : constant String := Ada.Directories.Full_Name (Arg (3));
         Program : constant String := Ada.Directories.Full_Name (Arg (5));
         Which : constant Positive := Positive'Value (Arg (6));
         Seed : constant Natural := Natural'Value (Arg (7));
         Good, Seen, Infrastructure : Boolean := False;
         procedure Record_Attempt (Item : Agent_Trial.Attempt) is
            Changed : Agent_Trial.Attempt := Item;
            Recorded : J.Document;
            Error : Jsonlib.Errors.Error_Info;
            Row : constant J.Node := J.Element (Doc, J.Member (Doc, J.Root (Doc), "tasks"), Which);
            Verifier : constant String := Root & "/attempts/trial-edit-verifier";
            Ran : Hostkit.Process.Process_Outcome;
            Matches : Boolean;
         begin
            Seen := True;
            Changed.Task_Name := To_Unbounded_String (C.Name (Which));
            Infrastructure := Item.Grade = Agent_Trial.Infrastructure_Error;
            Ran := Hostkit.Process.Run_Captured
              ("git", [To_Unbounded_String ("--git-dir=" & Verifier & "/baseline.git"),
                       To_Unbounded_String ("rev-parse"), To_Unbounded_String ("HEAD:src")],
               Stdout_Path => Root & "/initial-src-tree.txt", Stderr_Path => Root & "/identity-errors.txt",
               Timeout_Ms => 10_000);
            Matches := Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0
              and then File_Text (Root & "/initial-src-tree.txt") =
                J.As_String (Doc, J.Member (Doc, Row, "initial_src_git_tree"))
              and then Hash (Verifier & "/test_add.adb") =
                J.As_String (Doc, J.Member (Doc, Row, "public_test_sha256"))
              and then Hash (Verifier & "/hidden_test.adb") =
                J.As_String (Doc, J.Member (Doc, Row, "independent_test_sha256"));
            if not Matches then
               Infrastructure := True;
               Changed.Grade := Agent_Trial.Infrastructure_Error;
            end if;
            Jsonlib.Parsers.Parse (Agent_Campaign.Attempt_JSON
              (C.Name (Which) & "-" & Number (Seed) & "-" & Arg (8), Arg (8), Seed, Changed, Arg (9)), Recorded, Error);
            if Jsonlib.Errors.Failed (Error) then
               Infrastructure := True;
               return;
            end if;
            J.Insert (Recorded, J.Root (Recorded), "fixture", J.Copy (Recorded, Doc, Row));
            J.Insert
              (Recorded, J.Root (Recorded), "initial_source_identity_matched", J.New_Boolean (Recorded, Matches));
            Write (Root & "/result.json", Recorded);
         end Record_Attempt;
      begin
         if Which > C.Tasks or else Seed not in 71 .. 72 or else Arg (8) not in "base" | "adapted"
           or else Ada.Directories.Exists (Root)
         then
            return;
         end if;
         Ada.Directories.Create_Path (Root);
         Load (Curriculum & "/curriculum.json", Doc, Good);
         if not Good or else Member (Doc, "protocol_sha256") /= Protocol
           or else not Trial_Confinement.Ready (Root)
         then
            return;
         end if;
         declare
            Manifest : J.Document;
            Parent : constant String := Ada.Directories.Containing_Directory (Root) & "/manifest.json";
         begin
            Load (Parent, Manifest, Good);
            if not Good or else Hash (Parent) /= Arg (9)
              or else Member (Manifest, "curriculum_sha256") /= Hash (Curriculum & "/curriculum.json")
              or else Member (Manifest, "protocol_sha256") /= Protocol
              or else J.As_String (Doc, J.Member (Doc,
                J.Element (Doc, J.Member (Doc, J.Root (Doc), "tasks"), Which), "notes")) /= C.Notes (Which)
            then
               return;
            end if;
         end;
         Ada.Environment_Variables.Set
           ("MODEL_RUNNER_CAPTURE_DIR", Root & "/attempts/trial-edit/.trial-runtime/captures");
         Agent_Trial.Run
           (Model => Arg (4), Program => Program, Options => "", Only => "edit", Clean => Good,
            Repeats => 1, Knowledge => False, Max_Seconds => 600, Output_Directory => Root & "/attempts",
            On_Attempt => Record_Attempt'Access,
            Extra_Arguments => [To_Unbounded_String ("--seed"), To_Unbounded_String (Number (Seed))],
            Isolation_Root => Workspace_Of (Program),
            Fixture_Root => Curriculum & "/" & C.Name (Which), Fixture_Notes => C.Notes (Which),
            Fixture_Paths => C.Paths (Which), Fixture_Test => Curriculum & "/" & C.Name (Which) & ".hidden_test.adb",
            Isolation_Readable => [To_Unbounded_String (Ada.Directories.Containing_Directory
              (Ada.Directories.Containing_Directory (Program)) & "/resources")]);
         if not Seen or else Infrastructure then
            return;
         end if;
      end;
   elsif Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "diagnose" then
      declare
         Root : constant String := Ada.Directories.Full_Name (Arg (2));
         Output : constant String := Ada.Directories.Full_Name (Arg (3));
         Rows : constant J.Node := J.New_Array (Doc);
         Record_Doc : J.Document;
         Manifest : J.Document;
         Good : Boolean;
         Ran : Hostkit.Process.Process_Outcome;
      begin
         if Ada.Directories.Exists (Output) then
            return;
         end if;
         Load (Root & "/manifest.json", Manifest, Good);
         if not Good then
            return;
         end if;
         Ada.Directories.Create_Path (Output);
         J.Set_Root (Doc, J.New_Object (Doc));
         Put (Doc, J.Root (Doc), "schema", "model_runner.ada_transfer_posthoc.v1");
         for Which in 1 .. C.Tasks loop
            for Seed in 71 .. 72 loop
               for Arm in 1 .. 2 loop
                  declare
                     Role : constant String := (if Arm = 1 then "base" else "adapted");
                     Id : constant String := C.Name (Which) & "-" & Number (Seed) & "-" & Role;
                     Attempt : constant String := Root & "/" & Id;
                     Project : constant String := Output & "/" & Id;
                     Trusted : constant String := Attempt & "/attempts/trial-edit-verifier";
                     Item : constant J.Node := J.New_Object (Doc);
                     Grade : Agent_Trial.Verdict;
                  begin
                     Load (Attempt & "/result.json", Record_Doc, Good);
                     if not Good then
                        return;
                     end if;
                     if Member (Record_Doc, "grade") = "failed" then
                        Ada.Directories.Create_Path (Project);
                        Ada.Directories.Create_Path (Project & "-verifier/obj");
                        Ran := Hostkit.Process.Run_Captured
                          ("cp", [To_Unbounded_String ("-a"), To_Unbounded_String
                             (Member (Record_Doc, "directory") & "/src"), To_Unbounded_String (Project & "/src")],
                           Stdout_Path => Project & "/copy.txt", Stderr_Path => Project & "/copy-errors.txt",
                           Timeout_Ms => 30_000);
                        if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
                           return;
                        end if;
                        for Path of C.Paths (Which) loop
                           if Hash (Project & "/" & To_String (Path)) /= Hash
                             (Member (Record_Doc, "directory") & "/" & To_String (Path))
                           then
                              return;
                           end if;
                        end loop;
                        Ada.Directories.Copy_File (Trusted & "/test_add.adb", Project & "-verifier/test_add.adb");
                        Ada.Directories.Copy_File (Trusted & "/hidden_test.adb", Project & "-verifier/hidden_test.adb");
                        Grade := Trial_Graders.Verify
                          (Project, "edit", "", "", True, Confine => True, Modern => True,
                           Hidden_Root => Member (Manifest, "hidden_workspace"));
                        Put (Doc, Item, "attempt_id", Id);
                        Put (Doc, Item, "original_workflow_grade", "failed");
                        Put (Doc, Item, "independent_source_tests", Grade'Image);
                        Put (Doc, Item, "evidence_path", Project & "-verifier");
                        J.Append (Doc, Rows, Item);
                     end if;
                  end;
               end loop;
            end loop;
         end loop;
         J.Insert (Doc, J.Root (Doc), "failed_attempts", Rows);
         Put (Doc, J.Root (Doc), "scope", "Separate source diagnostics; no workflow outcome is upgraded.");
         Write (Output & "/results.json", Doc);
      end;
   elsif Ada.Command_Line.Argument_Count = 3 and then Arg (1) = "summarize" then
      declare
         Names : Hostkit.String_Vectors.Vector;
         Status : Model_Runner.Errors.Error_Info;
      begin
         for Which in 1 .. C.Tasks loop
            Names.Append (To_Unbounded_String (C.Name (Which)));
         end loop;
         Learning_Report.Run (Arg (2), Arg (3), Status, Names, First_Seed => 71, Seed_Count => 2);
         if Model_Runner.Errors.Is_Error (Status) then
            Ada.Text_IO.Put_Line (Status'Image); return;
         end if;
      end;
   else
      Ada.Text_IO.Put_Line ("transfer: prepare ROOT WORKSPACE | run ROOT CURRICULUM BASE ADAPTED PROGRAM"
                             & " | evaluate ROOT CURRICULUM MODEL PROGRAM TASK SEED ARM MANIFEST_SHA"
                             & " | summarize ROOT NEW_JSON | diagnose ROOT NEW_OUTPUT");
      return;
   end if;
   Ada.Command_Line.Set_Exit_Status (0);
exception
   when others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "transfer: operation refused; retained artifacts explain the stage");
      Ada.Command_Line.Set_Exit_Status (1);
end Ada_Transfer_Main;
