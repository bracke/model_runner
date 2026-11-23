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
with Project_Tools.Files;
with Trial_Graders;
with Trial_Metrics;
with Adapter_Inspection;
with Interfaces;
with Tiny_Model;
with Campaign_Statistics;
with GNAT.SHA256;
with Model_Runner.Numerics;
with Hostkit;

package body Tests.Campaign_Cases is

   use Ada.Strings.Unbounded;
   use type Agent_Trial.Verdict;
   use type Jsonlib.Documents.Value_Kind;
   use type Jsonlib.Errors.Error_Code;
   package J renames Jsonlib.Documents;
   Root : constant String := "obj/campaign-tests";

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
      procedure Run (Options : String := "--backend cpu") is
      begin
         Agent_Campaign.Run
           (Root & "/base", Root & "/adapted", Root & "/program", Directory, Clean,
            Only => "edit", Options => Options, Repeats => 1, Check_Only => True);
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
      for Arm in 1 .. 4 loop
         declare
            Name : constant String :=
              (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                           when 3 => "base-on", when others => "adapted-on");
            Id : constant String := "edit-1-" & Name;
         begin
            Project_Tools.Files.Write_Raw_File
              (Directory & "/" & Id & ".json", Agent_Campaign.Attempt_JSON
                 (Id, Name, 42, Item,
                  GNAT.SHA256.Digest (Project_Tools.Files.Read_Raw_File (Directory & "/manifest.json"))));
         end;
      end loop;
      Run;
      Assert (Clean, "complete records were not resumed");
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
      for Arm in 1 .. 4 loop
         declare
            Name : constant String :=
              (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                           when 3 => "base-on", when others => "adapted-on");
            Id : constant String := "edit-1-" & Name;
         begin
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
   begin
      Fresh;
      Agent_Trial.Validate_Graders (Root & "/graders", Clean);
      Assert (Clean, "a pilot grader accepted a control or rejected its reference solution");
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

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
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
