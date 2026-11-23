with AUnit.Assertions; use AUnit.Assertions;
with AUnit.Test_Cases;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Agent_Campaign;
with Agent_Trial;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Project_Tools.Files;
with Project_Tools.Text;
with Captured_Output;
with Trial_Graders;
with Trial_Metrics;
with Adapter_Inspection;
with Interfaces;
with Tiny_Model;
with Campaign_Statistics;
with GNAT.SHA256;
with Model_Runner.Numerics;
with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;
with Trial_Confinement;
with Trial_Settings;
with Model_Runner.CLI.Run_Settings;
with Model_Runner.CLI.Options;
with Model_Runner.CLI.Interactive;
with Model_Runner.Generation;
with Model_Runner.Templates;
with Model_Runner.Llama;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Errors;

package body Tests.Campaign_Cases is

   use Ada.Strings.Unbounded;
   use type Agent_Trial.Verdict;
   use type Jsonlib.Documents.Value_Kind;
   use type Jsonlib.Errors.Error_Code;
   package J renames Jsonlib.Documents;
   Root : constant String := "obj/campaign-tests";

   Sampling_Settings : constant String :=
     "{""temperature"":0.4,""dynatemp_range"":0,""dynatemp_exponent"":1,""top_k"":40,""top_p"":0.95,"
     & """min_p"":0.05,""top_a"":0,""repeat_penalty"":1,""repeat_window"":64,""frequency_penalty"":0,"
     & """presence_penalty"":0,""typical_p"":1,""tail_free"":1,""xtc_probability"":0,""xtc_threshold"":0.1,"
     & """dry_multiplier"":0,""dry_base"":1.75,""dry_allowed_length"":2,"
     & """mirostat"":0,""mirostat_tau"":5,""mirostat_eta"":0.1}";
   Session_Settings : constant String :=
     "{""schema_version"":1,""role"":""session"",""sampling"":" & Sampling_Settings & ",""context_size"":8192,"
     & """threads"":1,""batch_size"":16,""backend"":""cpu"",""cache_keys"":""f32"","
     & """cache_values"":""f32"",""arithmetic"":""f32"",""thinking"":""THINKING_OFF"",""seed_given"":true,"
     & """seed"":""42"",""runtime_adapters"":0}";
   Root_Settings : constant String :=
     "{""schema_version"":1,""role"":""root"",""round"":1,""policy"":""fixed"",""sampling"":" & Sampling_Settings & ","
     & """context_size"":8192,""threads"":1,""batch_size"":16,""backend"":""cpu"","
     & """cache_keys"":""f32"",""cache_values"":""f32"",""arithmetic"":""f32"","
     & """thinking"":""THINKING_OFF"",""seed_given"":true,""seed"":""42"",""runtime_adapters"":0}";

   procedure Qualify (Item : in out Agent_Trial.Attempt; Thinking : Boolean := False; Adapters : Natural := 0) is
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      Jsonlib.Parsers.Parse ("[" & Session_Settings & "," & Root_Settings & "]", Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "invalid settings control");
      for Index in 1 .. 2 loop
         J.Set_Member (Doc, J.Element (Doc, J.Root (Doc), Index), "thinking",
                       J.New_String (Doc, (if Thinking then "THINKING_ON" else "THINKING_OFF")));
         J.Set_Member (Doc, J.Element (Doc, J.Root (Doc), Index), "runtime_adapters",
                       J.New_Integer (Doc, Long_Long_Integer (Adapters)));
      end loop;
      Item.Resolved_Settings := To_Unbounded_String (Jsonlib.Serializers.To_String (Doc));
      Item.Configuration_Before := To_Unbounded_String ("{""revision"":1,""fields"":{}}");
      Item.Configuration_After := Item.Configuration_Before;
      Item.Isolation := To_Unbounded_String ("bubblewrap-v1");
   end Qualify;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("paired agent campaigns");
   end Name;

   procedure Fresh is
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root);
   end Fresh;

   procedure Metrics_Keep_Missing_Values (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Item : Agent_Trial.Attempt;
   begin
      Assert (Trial_Metrics.Count_After ("tokens: 0", "tokens:") = 0, "zero was lost");
      Assert (Trial_Metrics.Count_After ("no measurement", "tokens:") = -1, "absence became zero");
      Assert (Trial_Metrics.Count_After ("tokens: 0", "") = -1, "empty marker was accepted");
      Assert (Trial_Metrics.Count_After ("tokens: 3.5", "tokens:") = -1, "fraction accepted as count");
      Assert (Trial_Metrics.Count_After ("tokens: 99999999999999999999", "tokens:") = -1,
              "oversized measurement accepted");
      Assert (Trial_Metrics.Seconds_After ("time: 1.25 s", "time:") = 1.25, "time misread");
      Assert (Trial_Metrics.Seconds_After ("time: 1..2", "time:") = -1.0, "malformed time accepted");
      Item.Task_Name := To_Unbounded_String ("quoted ""task""");
      Item.Grade := Agent_Trial.Failed;
      Jsonlib.Parsers.Parse (Agent_Campaign.Attempt_JSON ("id", "base-off", 42, Item), Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "attempt is not valid JSON");
      Assert (J.Kind (Doc, J.Member (Doc, J.Root (Doc), "generated_tokens")) = J.Null_Value,
              "unavailable tokens became a measurement");
      Assert (J.Kind (Doc, J.Member (Doc, J.Root (Doc), "elapsed_seconds")) = J.Null_Value,
              "unavailable elapsed time became a measured zero");
      Assert (J.As_String (Doc, J.Member (Doc, J.Root (Doc), "task")) = "quoted ""task""",
              "task text did not round-trip");
   end Metrics_Keep_Missing_Values;

   procedure Resume_Is_Bound_To_The_Request (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Clean : Boolean;
      Item : Agent_Trial.Attempt;
      Directory : constant String := Root & "/resume";
      Output : Unbounded_String;
      procedure Run (Options : String := "--backend cpu") is
      begin
         Captured_Output.Open (Root & "/resume-output.txt");
         Agent_Campaign.Run
           (Root & "/base", Root & "/adapted", Root & "/program", Directory, Clean,
            Only => "edit", Options => Options, Repeats => 1, Check_Only => True);
         Output := To_Unbounded_String (Captured_Output.Close);
      exception
         when others =>
            Output := To_Unbounded_String (Captured_Output.Close);
            raise;
      end Run;
   begin
      Fresh;
      Project_Tools.Files.Write_Raw_File (Root & "/base", "abc");
      Project_Tools.Files.Write_Raw_File (Root & "/adapted", "def");
      Project_Tools.Files.Write_Raw_File (Root & "/program", "program");
      Assert (Agent_Campaign.File_Digest (Root & "/base")
                = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "file SHA-256 is not the content digest");
      Run;
      Assert (not Clean, "an empty campaign claimed completion");
      declare
         Manifest : J.Document;
         Error : Jsonlib.Errors.Error_Info;
      begin
         Jsonlib.Parsers.Parse
           (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"), Manifest, Error);
         Assert (Error.Code = Jsonlib.Errors.No_Error, "manifest did not serialize");
         declare
            Revision : constant String := J.As_String (Manifest, J.Member (Manifest, J.Root (Manifest),
                                                                          "source_revision"));
         begin
            Assert (Revision /= "" and then Ada.Strings.Fixed.Index (Revision, "" & ASCII.LF) = 0
                      and then Ada.Strings.Fixed.Index (Revision, "" & ASCII.CR) = 0,
                    "source revision retained a line ending");
         end;
      end;
      Item.Task_Name := To_Unbounded_String ("edit");
      Item.Grade := Agent_Trial.Passed;
      Qualify (Item);
      for Arm in 1 .. 4 loop
         declare
            Name : constant String :=
              (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                           when 3 => "base-on", when others => "adapted-on");
            Id : constant String := "edit-1-" & Name;
         begin
            Qualify (Item, Thinking => Arm >= 3);
            Project_Tools.Files.Write_Raw_File
              (Directory & "/" & Id & ".json", Agent_Campaign.Attempt_JSON
                 (Id, Name, 42, Item,
                  GNAT.SHA256.Digest (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"))));
         end;
      end loop;
      Run;
      Assert (Clean, "complete records were not resumed");
      Assert (Ada.Strings.Fixed.Index (To_String (Output), "0 new attempts") > 0,
              "resume claimed to start fresh attempts");
      Item.Resolved_Settings := Null_Unbounded_String;
      Project_Tools.Files.Write_Raw_File
        (Directory & "/edit-1-base-off.json", Agent_Campaign.Attempt_JSON
           ("edit-1-base-off", "base-off", 42, Item,
            GNAT.SHA256.Digest (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"))));
      Run;
      Assert (not Clean, "a result without native settings was reused");
      Qualify (Item);
      Project_Tools.Files.Write_Raw_File
        (Directory & "/edit-1-base-off.json", Agent_Campaign.Attempt_JSON
           ("edit-1-base-off", "base-off", 42, Item,
            GNAT.SHA256.Digest (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"))));
      Run ("--backend reference");
      Assert (not Clean, "changed settings reused old results");
      Project_Tools.Files.Write_Raw_File
        (Directory & "/edit-1-base-off.json", "{""state"":""invoking""}");
      Run;
      Assert (not Clean, "an interrupted attempt was replayed or counted as passed");
   end Resume_Is_Bound_To_The_Request;

   procedure Adapter_Arms_Bind_Content_And_Scale (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Clean : Boolean;
      Directory : constant String := Root & "/adapter-resume";
      Adapter : constant String := Root & "/adapter with spaces.gguf";
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Item : Agent_Trial.Attempt;
      Original_Manifest : Unbounded_String;
      Expected_Scale : constant Model_Runner.Numerics.Real := Model_Runner.Numerics.From_Bits (16#3F800001#);
      procedure Run (Scale : Model_Runner.Numerics.Real := Expected_Scale; Swap : Boolean := False) is
      begin
         Agent_Campaign.Run
           (Root & "/base", Root & "/base", Root & "/program", Directory, Clean,
            Only => "edit", Repeats => 1, Check_Only => True,
            Base_Adapter => (if Swap then Adapter else ""),
            Adapted_Adapter => (if Swap then "" else Adapter),
            Base_Scale => (if Swap then Scale else 1.0),
            Adapted_Scale => (if Swap then 1.0 else Scale));
      end Run;
      function Field (Name : String) return String
      is (J.As_String (Doc, J.Member (Doc, J.Root (Doc), Name)));
   begin
      Fresh;
      Project_Tools.Files.Write_Raw_File (Root & "/base", "base");
      Project_Tools.Files.Write_Raw_File (Root & "/program", "program");
      Project_Tools.Files.Write_Raw_File (Adapter, "adapter");
      Run;
      Assert (not Clean, "an unrun adapter campaign claimed success");
      Original_Manifest := To_Unbounded_String (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"));
      Jsonlib.Parsers.Parse (To_String (Original_Manifest), Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "adapter manifest is not JSON");
      Assert (Field ("base_adapter") = "" and then Field ("base_adapter_mode") = "none",
              "base arm acquired the adapted arm's adapter");
      Assert (Field ("adapted_adapter") = Ada.Directories.Full_Name (Adapter)
                and then Field ("adapted_adapter_sha256") = Agent_Campaign.File_Digest (Adapter)
                and then Field ("adapted_adapter_mode") = "runtime",
              "adapted arm lost its exact path, content or execution mode");
      Assert (Model_Runner.Numerics."="
                (Model_Runner.Numerics.Real'Value (Field ("adapted_adapter_scale")), Expected_Scale),
              "adapter scale was not retained");
      Item.Task_Name := To_Unbounded_String ("edit");
      Item.Grade := Agent_Trial.Passed;
      Qualify (Item);
      for Arm in 1 .. 4 loop
         declare
            Name : constant String :=
              (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                           when 3 => "base-on", when others => "adapted-on");
            Id : constant String := "edit-1-" & Name;
         begin
            Qualify (Item, Thinking => Arm >= 3, Adapters => (if Arm in 2 | 4 then 1 else 0));
            Project_Tools.Files.Write_Raw_File
              (Directory & "/" & Id & ".json", Agent_Campaign.Attempt_JSON
                 (Id, Name, 42, Item, GNAT.SHA256.Digest (To_String (Original_Manifest))));
         end;
      end loop;
      Run;
      Assert (Clean, "identical adapter campaign did not resume");
      Run (Scale => 0.0);
      Assert (not Clean, "changed adapter scale reused outcomes");
      Run (Swap => True);
      Assert (not Clean, "moving the adapter to the base arm reused outcomes");
      Project_Tools.Files.Write_Raw_File (Adapter, "changed");
      Run;
      Assert (not Clean, "changed adapter payload reused outcomes");
      Project_Tools.Files.Write_Raw_File (Adapter, "adapter");
      Project_Tools.Files.Write_Raw_File
        (Directory & "/edit-1-adapted-off.json", Agent_Campaign.Attempt_JSON
           ("edit-1-adapted-off", "adapted-off", 42, Item, "another manifest"));
      Run;
      Assert (not Clean, "a finished record from a different manifest was reused");
      Ada.Directories.Delete_File (Adapter);
      Run;
      Assert (not Clean, "a missing adapter reused outcomes");
      Assert (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json") = To_String (Original_Manifest),
              "refusal rewrote the original manifest");
   end Adapter_Arms_Bind_Content_And_Scale;

   procedure Shared_Adapters_Are_Refused (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      pragma Suppress (Validity_Check);
      Clean : Boolean;
      Directory : constant String := Root & "/invalid";
   begin
      Fresh;
      for Flag of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String ("--lora adapter.gguf"), To_Unbounded_String ("--lora-scale 0"),
          To_Unbounded_String ("--lora-mode runtime")])
      loop
         Agent_Campaign.Run
           ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
            Options => To_String (Flag), Check_Only => True);
         Assert (not Clean and then not Ada.Directories.Exists (Directory),
                 "shared adapter controls reached campaign setup");
      end loop;
      Agent_Campaign.Run
        ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
         Check_Only => True, Adapted_Scale => 0.0);
      Assert (not Clean and then not Ada.Directories.Exists (Directory), "scale without an adapter was accepted");
      Agent_Campaign.Run
        ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
         Check_Only => True, Adapted_Adapter => "adapter",
         Adapted_Scale => Model_Runner.Numerics.From_Bits (16#7FC00000#));
      Assert (not Clean and then not Ada.Directories.Exists (Directory), "NaN adapter scale was accepted");
      Agent_Campaign.Run
        ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
         Check_Only => True, Adapted_Adapter => "adapter", Adapted_Scale => 1.0E-30);
      Assert (not Clean and then not Ada.Directories.Exists (Directory), "a tiny scale silently became zero");
      Agent_Campaign.Run
        ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
         Check_Only => True, Adapted_Adapter => "adapter", Adapted_Scale => 1.0E30);
      Assert (not Clean and then not Ada.Directories.Exists (Directory), "an unrepresentable huge scale was accepted");
      for Backend of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String (""), To_Unbounded_String ("--backend auto"),
          To_Unbounded_String ("--backend vulkan"), To_Unbounded_String ("--backend=cpujunk"),
          To_Unbounded_String ("--backend cpu --backend vulkan")])
      loop
         Agent_Campaign.Run
           ("absent", "absent", "absent", Directory, Clean, Only => "edit", Repeats => 1,
            Options => To_String (Backend), Check_Only => True, Adapted_Adapter => "adapter");
         Assert (not Clean and then not Ada.Directories.Exists (Directory),
                 "runtime adapter campaign accepted an uncontrolled backend");
      end loop;
   end Shared_Adapters_Are_Refused;

   procedure Grading_Uses_The_Preserved_Test (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Project : constant String := Ada.Directories.Full_Name (Root & "/project");
      procedure Put (Name, Text : String) is
      begin
         Project_Tools.Files.Write_Raw_File (Project & "/src/" & Name, Text);
      end Put;
      function Grade return Agent_Trial.Verdict
      is (Trial_Graders.Verify (Project, "edit", "", "", Completed => True));
   begin
      Fresh;
      Ada.Directories.Create_Path (Project & "/src");
      Put ("calc.ads", "package Calc is function Value return Integer; end Calc;");
      Put ("calc.adb", "package body Calc is function Value return Integer is (0); end Calc;");
      Put ("test_add.adb", "with Calc; procedure Test_Add is begin if Calc.Value /= 42 then"
           & " raise Program_Error; end if; end Test_Add;");
      Trial_Graders.Preserve (Project);
      Assert (Grade = Agent_Trial.Failed, "doing nothing passed");
      Put ("calc.adb", "package body Calc is function Value return Integer is (42); end Calc;");
      Assert (Grade = Agent_Trial.Passed, "reference solution failed");
      if Trial_Confinement.Ready (Project) then
         Assert (Trial_Graders.Verify (Project, "edit", "", "", True, Confine => True) = Agent_Trial.Passed,
                 "OS-confined independent grader refused the reference solution");
      end if;
      Put ("calc.adb", "package body Calc is function Value return Integer is (41); end Calc;");
      Assert (Grade = Agent_Trial.Failed, "known-wrong solution passed");
      Put ("test_add.adb", "procedure Test_Add is begin null; end Test_Add;");
      Assert (Grade = Agent_Trial.Failed, "weakening the agent's test defeated independent grading");
      Assert (Trial_Graders.Verify (Project, "edit", "", "", Completed => False) = Agent_Trial.Failed,
              "native failure was counted as completion");
   end Grading_Uses_The_Preserved_Test;

   procedure Headers_Do_Not_Verify_Payload (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Clean : Boolean;
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      Fresh;
      Tiny_Model.Write (Root & "/base.gguf");
      Tiny_Model.Write_Adapter (Root & "/adapter.gguf");
      Adapter_Inspection.Run
        (Root & "/base.gguf", Root & "/base.gguf", Root & "/adapter.gguf", Root & "/probe.json",
         0, 0, 0, Clean);
      Assert (Clean, "compatible fixture headers were refused");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Root & "/probe.json"), Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "inspection report is not JSON");
      Assert (not J.As_Boolean (Doc, J.Member (Doc, J.Root (Doc), "payload_verified")),
              "header inspection claimed to verify weights");
      declare
         Whole : constant String := Project_Tools.Files.Read_Raw_File (Root & "/base.gguf");
      begin
         Project_Tools.Files.Write_Raw_File (Root & "/prefix", Whole (Whole'First .. Whole'First + 23));
         Adapter_Inspection.Run
           (Root & "/prefix", Root & "/base.gguf", Root & "/adapter.gguf", Root & "/short.json",
            Interfaces.Unsigned_64 (Whole'Length), 0, 0, Clean);
         Assert (not Clean, "advertising a complete size masked a truncated header");
      end;
   end Headers_Do_Not_Verify_Payload;

   procedure Pilot_Graders_Reject_Controls (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Clean : Boolean;
      Project : constant String := Ada.Directories.Full_Name (Root & "/graders/find");
      Ran : Hostkit.Process.Process_Outcome;
   begin
      Fresh;
      Agent_Trial.Validate_Graders (Root & "/graders", Clean);
      Assert (Clean, "a pilot grader accepted a control or rejected its reference solution");
      Project_Tools.Files.Write_Raw_File (Project & "/README.md", "trusted initialization");
      Assert (Trial_Graders.Seal (Project), "trusted initialization could not seal its baseline");
      Assert (Trial_Graders.Check_Changes (Project, "find") = Agent_Trial.Passed,
              "trusted initialization was counted as model work");
      Ada.Directories.Create_Path (Project & "/docs");
      Project_Tools.Files.Write_Raw_File (Project & "/docs/hidden.md", "an unrelated edit");
      Ran := Hostkit.Process.Run_Captured
        ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Project), To_Unbounded_String ("add"),
                 To_Unbounded_String ("docs/hidden.md")], Stdout_Path => Hostkit.Fs.Null_Device,
         Stderr_Path => Hostkit.Fs.Null_Device);
      Assert (Ran.Started and then Ran.Exit_Status = 0, "could not stage the repository-spoofing control");
      Ran := Hostkit.Process.Run_Captured
        ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Project),
                 To_Unbounded_String ("-c"), To_Unbounded_String ("user.name=trial"),
                 To_Unbounded_String ("-c"), To_Unbounded_String ("user.email=trial@example.invalid"),
                 To_Unbounded_String ("commit"), To_Unbounded_String ("-qm"), To_Unbounded_String ("hide edit")],
         Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Hostkit.Fs.Null_Device);
      Assert (Ran.Started and then Ran.Exit_Status = 0, "could not commit the repository-spoofing control");
      Assert (Trial_Graders.Check_Changes (Project, "find") = Agent_Trial.Failed,
              "committing an unrelated edit hid it from independent grading");
      Ada.Directories.Delete_File (Project & "/docs/hidden.md");
      Assert (Trial_Graders.Check_Changes (Project, "find") = Agent_Trial.Passed,
              "the protected baseline followed the agent's committed history");
      Project_Tools.Files.Write_Raw_File
        (Project & "-verifier/baseline.git/info/exclude", "docs/ignored.md" & ASCII.LF);
      Project_Tools.Files.Write_Raw_File (Project & "/docs/ignored.md", "an ignored unrelated edit");
      Assert (Trial_Graders.Check_Changes (Project, "find") = Agent_Trial.Failed,
              "an ignored file escaped independent scope checking");
      Ada.Directories.Delete_File (Project & "/docs/ignored.md");
      Project_Tools.Files.Write_Raw_File (Project & "/.gitignore", "*");
      Assert (Trial_Graders.Check_Changes (Project, "find") = Agent_Trial.Failed,
              "a change to a tracked fixture input escaped source-only checking");
   end Pilot_Graders_Reject_Controls;

   procedure Paired_Costs_Exclude_Fast_Failures (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Source, Output : J.Document;
      Rows : constant J.Node := J.New_Array (Source);
      Error : Jsonlib.Errors.Error_Info;
      procedure Add (Task_Name, Arm : String; Grade : Agent_Trial.Verdict; Seconds : Duration) is
         Item : Agent_Trial.Attempt;
         Row : J.Document;
      begin
         Item.Task_Name := To_Unbounded_String (Task_Name);
         Item.Grade := Grade;
         Item.Work_Seconds := Seconds;
         Jsonlib.Parsers.Parse (Agent_Campaign.Attempt_JSON (Task_Name & Arm, Arm, 42, Item), Row, Error);
         Assert (Error.Code = Jsonlib.Errors.No_Error, "fixture attempt did not serialize");
         J.Append (Source, Rows, J.Copy (Source, Row, J.Root (Row)));
      end Add;
   begin
      J.Set_Root (Source, Rows);
      Add ("edit", "base-off", Agent_Trial.Passed, 10.0);
      Add ("edit", "adapted-off", Agent_Trial.Passed, 6.0);
      Add ("find", "base-off", Agent_Trial.Failed, 0.1);
      Add ("find", "adapted-off", Agent_Trial.Passed, 1.0);
      Add ("delegate", "base-off", Agent_Trial.Infrastructure_Error, 0.0);
      Add ("delegate", "adapted-off", Agent_Trial.Passed, 0.1);
      Jsonlib.Parsers.Parse (Campaign_Statistics.Describe (Source, Rows), Output, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "statistics did not serialize");
      declare
         Pair : constant J.Node := J.Element (Output, J.Member (Output, J.Root (Output), "comparisons"), 1);
         function Count (Name : String) return Long_Long_Integer
         is (J.As_Integer (Output, J.Member (Output, Pair, Name)));
      begin
         Assert (Count ("adapted_wins") = 1 and then Count ("adapted_losses") = 0,
                 "paired wins were miscounted");
         Assert (Count ("ineligible_pairs") = 1, "infrastructure failure became a model loss");
         Assert (Count ("both_solved_time_pairs") = 1, "a failure entered the both-solved cost view");
         Assert (J.As_Float (Output, J.Member (Output, Pair, "base_median_work_seconds_both_solved")) = 10.0
                 and then J.As_Float (Output, J.Member (Output, Pair, "adapted_median_work_seconds_both_solved")) = 6.0,
                 "fast failures distorted the cost comparison");
      end;
   end Paired_Costs_Exclude_Fast_Failures;

   procedure Settings_Are_Native_And_Required (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package L renames Model_Runner.Llama;
      package E renames Model_Runner.Errors;
      Item : Model_Runner.CLI.Options.Command;
      Request : Model_Runner.Generation.Request;
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Container : Model_Runner.GGUF.Containers.Container;
      Prepared : L.Model;
      Session : L.Session;
      Status : E.Error_Info;
      Clean : Boolean;
      Captured : Unbounded_String;
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      Fresh;
      Tiny_Model.Write (Root & "/settings.gguf");
      declare
         Line : constant String := "/settings json";
         Parsed : constant Model_Runner.CLI.Interactive.Parsed_Command := Model_Runner.CLI.Interactive.Parse (Line);
      begin
         Assert (Parsed.First > 0 and then Line (Parsed.First .. Parsed.Last) = "json",
                 "the interactive parser discarded the machine-readable settings argument");
      end;
      Model_Runner.Byte_Sources.Files.Open (Source, Root & "/settings.gguf", Status => Status);
      Assert (E.Is_Ok (Status), "settings fixture open failed");
      Model_Runner.GGUF.Containers.Reader.Parse (Container, Source, Status => Status);
      Assert (E.Is_Ok (Status), "settings fixture parse failed");
      L.Prepare (Prepared, Container, Source, Threads => 1, Status => Status);
      Assert (E.Is_Ok (Status), "settings fixture preparation failed");
      L.Open (Session, Prepared, 16, Cache => L.Exact, Status => Status);
      Assert (E.Is_Ok (Status), "settings fixture session failed");
      Item.Context_Size := 8_192;
      Item.Cache := L.Halved;
      Request.Sampling.Temperature := 0.625;
      Request.Batch_Size := 7;
      declare
         Native : constant String := Model_Runner.CLI.Run_Settings.Describe
           (Item, Prepared, Session, Request, Model_Runner.Templates.Thinking_Off,
            Model_Runner.Templates.Effort_Unstated);
      begin
         Captured := To_Unbounded_String (Trial_Settings.Extract
           ("ordinary output" & ASCII.LF & Model_Runner.CLI.Run_Settings.Marker & Native & ASCII.LF, Clean));
         Assert (Clean, "native settings were refused");
         Jsonlib.Parsers.Parse (Native, Doc, Error);
         Assert (Error.Code = Jsonlib.Errors.No_Error, "native settings are not JSON");
         Assert (J.As_Integer (Doc, J.Member (Doc, J.Root (Doc), "context_size")) = 16,
                 "requested context was reported in place of actual capacity");
         Assert (J.As_String (Doc, J.Member (Doc, J.Root (Doc), "cache_keys")) = L.Cache_Name (L.Exact),
                 "requested cache was reported in place of actual storage");
         Assert (J.As_Float (Doc, J.Member (Doc, J.Member (Doc, J.Root (Doc), "sampling"), "temperature")) = 0.625,
                 "fitted request sampling was replaced by command defaults");
      end;
      L.Close (Session);
      L.Close (Prepared, Status);
      Model_Runner.GGUF.Containers.Close (Container);
      Model_Runner.Byte_Sources.Files.Close (Source);
      Assert (not Trial_Settings.Valid (To_String (Captured), Need_Work => True),
              "session settings alone qualified a successful work result");
      Captured := To_Unbounded_String (Trial_Settings.Extract
        (Model_Runner.CLI.Run_Settings.Marker & Session_Settings & ASCII.LF
         & Model_Runner.CLI.Run_Settings.Marker & Root_Settings, Clean));
      Assert (Clean and then Trial_Settings.Valid (To_String (Captured), Need_Work => True),
              "session and fitted work settings did not qualify");
      Assert (Trial_Settings.Matches (To_String (Captured), 42, 8_192, False, 0),
              "matching campaign inference controls were refused");
      Assert (not Trial_Settings.Matches (To_String (Captured), 43, 8_192, False, 0)
                and then not Trial_Settings.Matches (To_String (Captured), 42, 4_096, False, 0)
                and then not Trial_Settings.Matches (To_String (Captured), 42, 8_192, True, 0)
                and then not Trial_Settings.Matches (To_String (Captured), 42, 8_192, False, 1),
              "a fitted call changed a campaign-owned inference control");
      Captured := To_Unbounded_String (Trial_Settings.Extract ("no settings", Clean));
      Assert (not Clean and then Length (Captured) = 0, "missing settings were invented");
      Captured := To_Unbounded_String (Trial_Settings.Extract
        (Model_Runner.CLI.Run_Settings.Marker & "{broken", Clean));
      Assert (not Clean and then Length (Captured) = 0, "malformed native settings were ignored");
      Assert (not Trial_Settings.Valid ("[" & Session_Settings & "," & Session_Settings & "]"),
              "duplicate session snapshots passed");
   end Settings_Are_Native_And_Required;

   procedure Isolation_Protects_Graders_And_Descendants (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Directory : constant String := Ada.Directories.Full_Name (Root & "/private");
      Project : constant String := Directory & "/project";
      Guarded : constant String := Directory & "/verifier.txt";
      Outside : constant String := Ada.Directories.Full_Name (Root & "/outside.txt");
      Ran : Hostkit.Process.Process_Outcome;
      Clean : Boolean;
   begin
      Fresh;
      Ada.Directories.Create_Path (Project);
      Project_Tools.Files.Write_Raw_File (Guarded, "protected verifier");
      Project_Tools.Files.Write_Raw_File (Outside, "protected outside");
      if not Trial_Confinement.Ready (Directory) then
         Agent_Campaign.Run
           (Guarded, Outside, Hostkit.Fs.Own_Executable, Directory & "/refused", Clean,
            Only => "edit", Repeats => 1, Max_Seconds => 1);
         Assert (not Clean and then not Ada.Directories.Exists (Directory & "/refused/edit-1-base-off.json"),
                 "an unavailable boundary started an unconfined model attempt");
         return;
      end if;
      Ran := Hostkit.Process.Run_Captured
        (Trial_Confinement.Executable,
         Trial_Confinement.Wrap
           (Hostkit.Fs.Own_Executable,
            [To_Unbounded_String ("probe"), To_Unbounded_String ("campaign-boundary"),
             To_Unbounded_String (Project), To_Unbounded_String (Guarded), To_Unbounded_String (Outside)],
            Project, Directory),
         Stdout_Path => Root & "/boundary.txt", Stderr_Path => Root & "/boundary-errors.txt", Timeout_Ms => 20_000);
      Assert (Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0,
              "native boundary or descendant attack failed: "
              & To_String (Project_Tools.Text.Read_Text_File (Root & "/boundary-errors.txt")));
      Assert (Project_Tools.Files.Read_Raw_File (Guarded) = "protected verifier"
                and then Project_Tools.Files.Read_Raw_File (Outside) = "protected outside",
              "an agent or descendant changed a trusted host file");
      Assert (Ada.Directories.Exists (Project & "/allowed.txt"), "the agent could not write its own project");
   end Isolation_Protects_Graders_And_Descendants;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Settings_Are_Native_And_Required'Access, "settings come from fitted native calls");
      Register_Routine
        (T, Isolation_Protects_Graders_And_Descendants'Access, "OS isolation protects verifiers from descendants");
      Register_Routine (T, Metrics_Keep_Missing_Values'Access, "metrics and JSON preserve unavailable values");
      Register_Routine (T, Resume_Is_Bound_To_The_Request'Access, "resume binds every attempt to the campaign");
      Register_Routine (T, Adapter_Arms_Bind_Content_And_Scale'Access, "adapter arms bind content and scale");
      Register_Routine (T, Shared_Adapters_Are_Refused'Access, "shared adapters cannot contaminate both arms");
      Register_Routine (T, Grading_Uses_The_Preserved_Test'Access, "independent graders reject no-op and wrong code");
      Register_Routine
        (T, Headers_Do_Not_Verify_Payload'Access, "bounded header inspection never verifies missing data");
      Register_Routine (T, Pilot_Graders_Reject_Controls'Access, "every pilot grader is qualified by controls");
      Register_Routine (T, Paired_Costs_Exclude_Fast_Failures'Access, "paired costs exclude fast failures");
   end Register_Tests;

end Tests.Campaign_Cases;
