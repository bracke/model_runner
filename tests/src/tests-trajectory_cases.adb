with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with AUnit.Test_Cases;
with GNAT.SHA256;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Grammar;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Stops;
with Model_Runner.Trajectories;
with Model_Runner.Tokenizer;
with Model_Runner.Templates;
with Project_Tools.Files;
with Tiny_Model;
with Trajectory_Export;

package body Tests.Trajectory_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   package T renames Model_Runner.Trajectories;
   package E renames Model_Runner.Errors;
   package J renames Jsonlib.Documents;
   use type E.Error_Code;
   use type Jsonlib.Errors.Error_Code;
   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.Tokenizer.Token_Id;

   Base : constant String := "obj/trajectories";

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("complete trajectory evidence");
   end Name;

   procedure Fresh (Name : String) is
   begin
      if Ada.Directories.Exists (Base & "/" & Name) then
         Ada.Directories.Delete_Tree (Base & "/" & Name);
      end if;
      Ada.Directories.Create_Path (Base & "/" & Name);
   end Fresh;

   procedure Write (Path, Text : String) is
      File : Ada.Streams.Stream_IO.File_Type;
      Bytes : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Text'Length))
        with Import, Address => Text'Address;
   begin
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      Ada.Streams.Stream_IO.Write (File, Bytes);
      Ada.Streams.Stream_IO.Close (File);
   end Write;

   procedure Start
     (Item : in out T.Recorder; Name : String; Max_Bytes : T.Byte_Limit := T.Byte_Limit'Last;
      Max_Episodes : T.Episode_Limit := 64; Provenance : String := "{}"; Metadata : String := "{}")
   is
      Settings : T.Options;
      Status : E.Error_Info;
   begin
      Settings.Directory := To_Unbounded_String (Base & "/" & Name & "/capture");
      Settings.Provenance := To_Unbounded_String (Provenance);
      Settings.Max_Bytes := Max_Bytes;
      Settings.Max_Episodes := Max_Episodes;
      T.Open (Item, Settings, Metadata, Status);
      Assert (E.Is_Ok (Status), "could not open trajectory fixture: " & Status.Code'Image);
   end Start;

   procedure Generation
     (Item : in out T.Recorder; Mask : Natural := 0; Tokens : Natural := 1; Prefix : String := "") is
   begin
      T.Append (Item, T.Generation_Start,
        "{""vocabulary_size"":16,""max_tokens"":4,""sampling_ada"":""fixture"",""request_ada"":""fixture"","
        & """grammar_constrained"":false,""grammar"":null,""grammar_prefix_hex"":" & T.Quote (Prefix)
        & ",""stop_tokens"":[],""stop_strings_hex"":[]}");
      T.Append (Item, T.Model_Input,
        "{""prompt"":""hello"",""tokens"" :[1,4],""loss_mask"":" & T.Number (Long_Long_Integer (Mask)) & "}");
      T.Selected (Item, 5, [Character'Val (16#C3#)], False);
      T.Append (Item, T.Committed_Token, "{""id"":5}");
      T.Selected (Item, 2, "", True);
      T.Append (Item, T.Generation_End,
        "{""reason"":""end_of_sequence"",""generated_tokens"":" & T.Number (Long_Long_Integer (Tokens)) & "}");
   end Generation;

   procedure Finish (Item : in out T.Recorder) is
      Status : E.Error_Info;
   begin
      T.Finish (Item, "{""complete"":true,""reason"":""answered""}", Status);
      Assert (E.Is_Ok (Status), "could not finish trajectory fixture");
   end Finish;

   procedure Full_Text_And_Tokens (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Checked : T.Validation;
      Status : E.Error_Info;
      Full : constant String := [1 .. 20_000 => 'x'];
      Template : Model_Runner.Templates.Compiled;
      Template_Text : constant String := "{{ messages[0].content }}";
   begin
      Fresh ("full");
      Assert (T.Hex_Bytes ([Character'Val (16#C3#)]) = "c3",
        "partial UTF-8 bytes were changed by hexadecimal capture");
      Model_Runner.Templates.Compile (Template, Template_Text, Status => Status);
      Assert (E.Is_Ok (Status) and then Model_Runner.Templates.Source_Of (Template) = Template_Text,
        "capture did not retain the actual compiled template source");
      Model_Runner.Templates.Close (Template);
      Assert (Model_Runner.Templates.Source_Of (Template) = "", "closed template retained stale capture identity");
      Start (Item, "full");
      T.Append (Item, T.Context,
        "{""messages"" :[{""role"":""user"",""parts"":"""",""calls"":[],""content"":" & T.Quote (Full) & "}]}");
      Generation (Item);
      T.Append (Item, T.Raw_Reply, "{""text"":" & T.Quote (Full) & "}");
      T.Append (Item, T.Tool_Call, "{""id"":1,""name"":""write_file"",""arguments"":""{}""}");
      T.Append (Item, T.Tool_Result, "{""id"":1,""text"":" & T.Quote (Full) & ",""ending"":""answered""}");
      Finish (Item);
      T.Validate (T.Path (Item), Checked, Status);
      Assert (E.Is_Ok (Status) and then Checked.Complete and then Checked.Exact_Tokens
        and then Checked.Committed_Tokens = 1, "complete token and tool evidence did not validate");
      Assert (Ada.Strings.Fixed.Index (Project_Tools.Files.Read_Raw_File (T.Path (Item)), Full) > 0,
        "capture shortened a payload at the old journal limit");
   end Full_Text_And_Tokens;

   procedure Corruption_And_Truncation (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Checked : T.Validation;
      Status : E.Error_Info;
   begin
      Fresh ("corrupt");
      Start (Item, "corrupt");
      Generation (Item);
      Finish (Item);
      declare
         Raw : String := Project_Tools.Files.Read_Raw_File (T.Path (Item));
         At_Byte : constant Positive := Ada.Strings.Fixed.Index (Raw, "hello");
      begin
         Raw (At_Byte) := 'H';
         Write (Base & "/corrupt/edited.jsonl", Raw);
         T.Validate (Base & "/corrupt/edited.jsonl", Checked, Status);
         Assert (E.Is_Error (Status), "changed content kept a valid capture digest");
         Write (Base & "/corrupt/truncated.jsonl", Raw (1 .. Raw'Last - 120));
         T.Validate (Base & "/corrupt/truncated.jsonl", Checked, Status);
         Assert (E.Is_Error (Status), "truncated trajectory was accepted");
         Write (Base & "/corrupt/no-newline.jsonl",
           Project_Tools.Files.Read_Raw_File (T.Path (Item)) (1 .. Raw'Last - 1));
         T.Validate (Base & "/corrupt/no-newline.jsonl", Checked, Status);
         Assert (E.Is_Error (Status), "unterminated footer was accepted");
      end;
   end Corruption_And_Truncation;

   procedure Structural_Loss_Is_Refused (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Checked : T.Validation;
      Status : E.Error_Info;
   begin
      Fresh ("structural");
      for Which in 1 .. 7 loop
         Start (Item, "structural");
         if Which = 1 then
            Generation (Item, Mask => 1);
         elsif Which = 2 then
            Generation (Item, Tokens => 2);
         elsif Which = 3 then
            T.Append (Item, T.Tool_Result, "{""id"":1,""text"":""x"",""ending"":""answered""}");
         elsif Which = 4 then
            T.Append (Item, T.Forced_Text, "{""text"":""</think>"",""loss_mask"":1}");
         else
            Generation (Item, Prefix => (case Which is when 5 => "6", when 6 => "xx", when others => "61"));
         end if;
         Finish (Item);
         T.Validate (T.Path (Item), Checked, Status);
         Assert (E.Is_Error (Status), "valid hashes hid a bad mask, count, tool order or forced-token label");
      end loop;
   end Structural_Loss_Is_Refused;

   procedure Bounds_And_Retention (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Settings : T.Options;
      Checked : T.Validation;
      Status : E.Error_Info;
   begin
      Fresh ("bounded");
      Start (Item, "bounded", Max_Bytes => 1_024, Max_Episodes => 1);
      T.Append (Item, T.Raw_Reply, "{""text"":" & T.Quote ([1 .. 2_000 => 'x']) & "}");
      T.Finish (Item, "{""complete"":true,""reason"":""answered""}", Status);
      Assert (Status.Code = E.IO_Input_Too_Large and then not Ada.Directories.Exists (T.Path (Item)),
        "capped capture published a complete artifact");
      T.Validate (T.Path (Item) & ".partial", Checked, Status);
      Assert (E.Is_Error (Status), "partial capture was accepted");
      Settings.Directory := To_Unbounded_String (Base & "/bounded/capture");
      Settings.Max_Episodes := 1;
      T.Open (Item, Settings, "{}", Status);
      Assert (Status.Code = E.IO_Input_Too_Large, "retention overwrote an incomplete episode");
      T.Open (Item, (others => <>), "{}", Status);
      Assert (E.Is_Ok (Status) and then T.Path (Item) = "" and then not T.Active (Item),
        "capture is enabled by default");
   end Bounds_And_Retention;

   procedure Export_Is_Explicit_And_Bound (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Status : E.Error_Info;
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      Fresh ("export");
      Start (Item, "export");
      Generation (Item);
      Finish (Item);
      Trajectory_Export.Export (T.Path (Item), Base & "/export/redacted.json", "", False, Status);
      Assert (E.Is_Ok (Status), "metadata-only export was refused");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Base & "/export/redacted.json"), Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error
        and then J.Length (Doc, J.Member (Doc, J.Root (Doc), "events")) = 0
        and then not J.As_Boolean (Doc, J.Member (Doc, J.Root (Doc), "supervised_eligible")),
        "redacted export leaked content or became training data");
      Trajectory_Export.Export (T.Path (Item), Base & "/export/full.json", "", True, Status);
      Assert (E.Is_Ok (Status), "explicit full export was refused");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Base & "/export/full.json"), Doc, Error);
      Assert (J.Length (Doc, J.Member (Doc, J.Root (Doc), "events")) > 0
        and then not J.As_Boolean (Doc, J.Member (Doc, J.Root (Doc), "supervised_eligible")),
        "unverified content became a successful demonstration");
      Trajectory_Export.Export (T.Path (Item), Base & "/export/full.json", "", True, Status);
      Assert (E.Is_Error (Status), "export overwrote existing evidence");
      Write (Base & "/export/wrong-verdict.json",
        "{""schema_version"":1,""capture_sha256"":" & T.Quote ([1 .. 64 => '0']) & "}");
      Trajectory_Export.Export
        (T.Path (Item), Base & "/export/wrong.json", Base & "/export/wrong-verdict.json", True, Status);
      Assert (E.Is_Error (Status), "unbound verification was accepted");
   end Export_Is_Explicit_And_Bound;

   procedure Independent_Verification_Is_Required (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Item : T.Recorder;
      Status : E.Error_Info;
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Model : constant String := "deterministic fixture model";
      Proof : constant String := "independent protected grader passed";
      function Q (Value : String) return String renames T.Quote;
   begin
      Fresh ("verified");
      Write (Base & "/verified/proof.txt", Proof);
      Start (Item, "verified", Provenance =>
        "{""model_sha256"":" & Q (GNAT.SHA256.Digest (Model))
        & ",""settings"":{""sampling"":{},""architecture"":""fixture"",""backend"":""cpu""},"
        & """artifacts"" :[{""role"":""model"",""path"":""fixture.gguf"",""sha256"":"
        & Q (GNAT.SHA256.Digest (Model)) & "}]}",
        Metadata => "{""harness_sha256"":" & Q (GNAT.SHA256.Digest ("fixture-harness"))
        & ",""model_fingerprint"":""fixture-1"",""template_source"":""fixture"",""tools"":[]}");
      Generation (Item);
      Finish (Item);
      Write (Base & "/verified/verdict.json",
        "{""schema_version"":1,""capture_sha256"":"
        & Q (GNAT.SHA256.Digest (Project_Tools.Files.Read_Raw_File (T.Path (Item))))
        & ",""independent"":true,""task_id"":""edit-1"",""task_family"":""fixture-edit"","
        & """project_revision"":""fixture-1"",""split"":""train"",""expected_outputs"" :[""calc.ads""],"
        & """verifier_sha256"":" & Q (GNAT.SHA256.Digest ("fixture-verifier"))
        & ",""verifier_result_path"":" & Q (Ada.Directories.Full_Name (Base & "/verified/proof.txt"))
        & ",""verifier_result_sha256"":" & Q (GNAT.SHA256.Digest (Proof)) & ",""result"":""passed""}");
      Trajectory_Export.Export
        (T.Path (Item), Base & "/verified/export.json", Base & "/verified/verdict.json", True, Status);
      Assert (E.Is_Ok (Status), "matching independent evidence did not export");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Base & "/verified/export.json"), Doc, Error);
      Assert (J.As_Boolean (Doc, J.Member (Doc, J.Root (Doc), "supervised_eligible"))
        and then not J.As_Boolean (Doc, J.Member (Doc, J.Root (Doc), "rl_ready")),
        "independent success did not qualify, or aggregate capture was labeled RL-ready");
      Trajectory_Export.Validate_Export (Base & "/verified/export.json", Status);
      Assert (E.Is_Ok (Status), "self-contained verified export did not validate");
      J.Set_Member (Doc, J.Root (Doc), "supervised_eligible", J.New_Boolean (Doc, False));
      Write (Base & "/verified/false-flag.json", Jsonlib.Serializers.To_String (Doc));
      Trajectory_Export.Validate_Export (Base & "/verified/false-flag.json", Status);
      Assert (E.Is_Error (Status), "export validator trusted an edited eligibility flag");
      Write (Base & "/verified/proof.txt", "changed after verification");
      Trajectory_Export.Validate_Export (Base & "/verified/export.json", Status);
      Assert (E.Is_Ok (Status), "completed export still opened the mutable verifier result file");
      Trajectory_Export.Export
        (T.Path (Item), Base & "/verified/changed.json", Base & "/verified/verdict.json", True, Status);
      Assert (E.Is_Error (Status), "changed verifier output retained its grade");
   end Independent_Verification_Is_Required;

   procedure Real_Generation_Is_Unchanged (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Image : aliased Model_Runner.Bytes.Byte_Array_Access;
   begin
      Fresh ("native");
      Tiny_Model.Build (Image);
      declare
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready : Model_Runner.Llama.Model;
         Session : Model_Runner.Llama.Session;
         Request : Model_Runner.Generation.Request;
         Stop : Model_Runner.Stops.Set;
         Plain, Captured : Model_Runner.Generation.Result;
         Evidence : aliased T.Recorder;
         Status : E.Error_Info;
         Checked : T.Validation;
         Expected : Model_Runner.Tokenizer.Token_Array (1 .. 4);
         Rules : aliased Model_Runner.Grammar.Compiled;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "tiny capture model did not parse");
         Model_Runner.Llama.Prepare (Ready, Parsed, Source, Status => Status);
         Model_Runner.Llama.Open (Session, Ready, Status => Status);
         Assert (E.Is_Ok (Status), "tiny capture model did not open");
         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := 4;
         Request.Seed := 42;
         Request.Has_Seed := True;
         Request.Ignore_End := True;
         Request.Retain_Text := True;
         Request.Sampling.Temperature := 0.0;
         Model_Runner.Generation.Generate
           (Ready, Session, "hello", Request, Stop, Sink => null, Observer => null, Time => null,
            Seeds => null, Cancel => null, Outcome => Plain);
         Assert (E.Is_Ok (Plain.Error) and then Plain.Generated_Tokens = 4, "uncaptured native generation failed");
         for Index in Expected'Range loop
            Expected (Index) := Model_Runner.Llama.Committed_Token
              (Session, Plain.Prompt_Tokens + Index - 1);
         end loop;
         Model_Runner.Llama.Reset (Session);
         Start (Evidence, "native");
         Model_Runner.Generation.Generate
           (Ready, Session, "hello", Request, Stop, Sink => null, Observer => null, Time => null,
            Seeds => null, Cancel => null, Capture => Evidence'Unchecked_Access, Outcome => Captured);
         Finish (Evidence);
         Assert (Plain.Reason = Captured.Reason and then Plain.Generated_Tokens = Captured.Generated_Tokens
           and then Model_Runner.Generation.Generated_Text (Plain) = Model_Runner.Generation.Generated_Text (Captured),
           "capture changed real generation");
         T.Validate (T.Path (Evidence), Checked, Status);
         Assert (E.Is_Ok (Status) and then Checked.Committed_Tokens = 4 and then Checked.Exact_Tokens,
           "native token capture failed validation");
         declare
            Raw : constant String := Project_Tools.Files.Read_Raw_File (T.Path (Evidence));
            First : Positive := Raw'First;
            Seen : Natural := 0;
            Doc, Data : J.Document;
            Error : Jsonlib.Errors.Error_Info;
         begin
            for Index in Raw'Range loop
               if Raw (Index) = ASCII.LF then
                  Jsonlib.Parsers.Parse (Raw (First .. Index - 1), Doc, Error);
                  if J.As_String (Doc, J.Member (Doc, J.Root (Doc), "kind")) = "committed_token" then
                     Seen := Seen + 1;
                     Jsonlib.Parsers.Parse
                       (J.As_String (Doc, J.Member (Doc, J.Root (Doc), "payload")), Data, Error);
                     Assert (J.As_Integer (Data, J.Member (Data, J.Root (Data), "id"))
                       = Long_Long_Integer (Expected (Seen)), "capture token differs from native session");
                  end if;
                  First := Index + 1;
               end if;
            end loop;
            Assert (Seen = 4, "capture lost native generated token IDs");
         end;
         Model_Runner.Generation.Release (Plain);
         Model_Runner.Generation.Release (Captured);
         Model_Runner.Llama.Reset (Session);
         Model_Runner.Grammar.Compile (Rules, "root ::= ""a""", Status);
         Assert (E.Is_Ok (Status), "capture grammar did not compile");
         Model_Runner.Stops.Add_String (Stop, "zz", Status);
         Model_Runner.Stops.Add_Token (Stop, 0, Status);
         Assert (Model_Runner.Stops.String_At (Stop, 1) = "zz"
           and then Model_Runner.Stops.Token_At (Stop, 1) = 0,
           "stop capture did not preserve exact configured controls");
         Request.Ignore_End := False;
         Start (Evidence, "native");
         Model_Runner.Generation.Generate
           (Ready, Session, "hello", Request, Stop, Rules => Rules'Unchecked_Access,
            Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null,
            Capture => Evidence'Unchecked_Access, Outcome => Captured);
         Finish (Evidence);
         Assert (E.Is_Ok (Captured.Error)
           and then Model_Runner.Generation.Generated_Text (Captured) = "a",
           "native constrained capture did not generate its required answer");
         T.Validate (T.Path (Evidence), Checked, Status);
         Assert (E.Is_Ok (Status) and then Checked.Exact_Tokens,
           "compiled grammar and stop settings did not validate");
         declare
            Raw : constant String := Project_Tools.Files.Read_Raw_File (T.Path (Evidence));
         begin
            Assert (Ada.Strings.Fixed.Index (Raw, "ELEMENT_CHAR") > 0
              and then Ada.Strings.Fixed.Index (Raw, "7a7a") > 0,
              "capture omitted the compiled constraint or exact stop-string bytes");
         end;
         Model_Runner.Generation.Release (Captured);
         Model_Runner.Grammar.Close (Rules);
         Model_Runner.Llama.Reset (Session);
         Model_Runner.Grammar.Compile (Rules, "root ::= ""abc""", Status);
         Assert (E.Is_Ok (Status), "continuation grammar did not compile");
         Start (Evidence, "native");
         Model_Runner.Generation.Generate
           (Ready, Session, "helloab", Request, Stop, Rules => Rules'Unchecked_Access,
            Rules_Prefix => "ab", Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null,
            Capture => Evidence'Unchecked_Access, Outcome => Captured);
         Finish (Evidence);
         Assert (E.Is_Ok (Captured.Error) and then Captured.Generated_Tokens = 1
           and then Model_Runner.Generation.Generated_Text (Captured) = "c",
           "a sampled continuation restarted or discarded the grammar instead of resuming it");
         T.Validate (T.Path (Evidence), Checked, Status);
         Assert (E.Is_Ok (Status) and then Checked.Exact_Tokens,
           "a constrained continuation lost exact capture eligibility");
         Assert (Ada.Strings.Fixed.Index (Project_Tools.Files.Read_Raw_File (T.Path (Evidence)), "6162") > 0,
           "capture omitted the already generated grammar prefix");
         Model_Runner.Generation.Release (Captured);
         Model_Runner.Llama.Reset (Session);
         Model_Runner.Generation.Generate
           (Ready, Session, "hello", Request, Stop, Rules => Rules'Unchecked_Access,
            Rules_Prefix => "ax", Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null,
            Outcome => Captured);
         Assert (E.Is_Error (Captured.Error) and then Captured.Generated_Tokens = 0,
           "an invalid grammar prefix reached sampling");
         Model_Runner.Generation.Release (Captured);
         Model_Runner.Llama.Reset (Session);
         Model_Runner.Generation.Generate
           (Ready, Session, "hello", Request, Stop, Rules_Prefix => "ab",
            Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Captured);
         Assert (E.Is_Error (Captured.Error) and then Captured.Generated_Tokens = 0,
           "a continuation prefix silently ran without its grammar");
         Model_Runner.Generation.Release (Captured);
         Model_Runner.Grammar.Close (Rules);
         Model_Runner.Llama.Close (Session);
         Model_Runner.Llama.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;
      Model_Runner.Bytes.Free (Image);
   end Real_Generation_Is_Unchanged;

   procedure Helpers_Stay_With_Their_Parent (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Parent, Child : T.Recorder;
      Saved : constant T.Lineage := T.Current;
      Settings : T.Options;
      Status : E.Error_Info;
      Checked : T.Validation;
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Capture_Root : Unbounded_String;
   begin
      Fresh ("family");
      Start (Parent, "family");
      Generation (Parent);
      T.Append (Parent, T.Tool_Call, "{""id"":1,""name"":""delegate"",""arguments"":""{}""}");
      Capture_Root := To_Unbounded_String
        (Ada.Directories.Containing_Directory (Ada.Directories.Containing_Directory (T.Path (Parent))));
      T.Enter ((Parent => To_Unbounded_String (T.Path (Parent)), Parent_Call => 1,
        Directory => Capture_Root, Max_Bytes => 65_536, others => <>));
      Settings := T.Configured;
      Assert (Settings.Directory = Capture_Root and then Settings.Max_Bytes = 65_536,
        "an embedded helper did not inherit explicit parent capture settings");
      T.Open (Child, Settings,
        "{""parent_episode"":" & T.Quote (T.Path (Parent)) & ",""parent_call"":1}", Status);
      Assert (E.Is_Ok (Status), "helper capture did not open");
      Generation (Child);
      Finish (Child);
      T.Enter (Saved);
      T.Append (Parent, T.Tool_Result, "{""id"":1,""text"":""child done"",""ending"":""answered""}");
      Generation (Parent);
      Finish (Parent);
      T.Validate (T.Path (Parent), Checked, Status);
      Assert (E.Is_Ok (Status) and then Checked.Child_Episodes = 1 and then Checked.Exact_Tokens,
        "parent did not retain a validated helper stream");
      Trajectory_Export.Export (T.Path (Parent), Base & "/family/export.json", "", True, Status);
      Assert (E.Is_Ok (Status), "complete helper family did not export");
      Ada.Directories.Delete_Tree (To_String (Capture_Root));
      Trajectory_Export.Validate_Export (Base & "/family/export.json", Status);
      Assert (E.Is_Ok (Status), "export still depended on original capture files");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Base & "/family/export.json"), Doc, Error);
      declare
         First : constant J.Node := J.Element (Doc, J.Member (Doc, J.Root (Doc), "children"), 1);
      begin
         J.Set_Member (Doc, First, "jsonl", J.New_String (Doc, "changed helper"));
      end;
      Write (Base & "/family/changed.json", Jsonlib.Serializers.To_String (Doc));
      Trajectory_Export.Validate_Export (Base & "/family/changed.json", Status);
      Assert (E.Is_Error (Status), "an altered embedded helper retained its qualification");
   exception
      when others =>
         T.Enter (Saved);
         raise;
   end Helpers_Stay_With_Their_Parent;

   procedure A_Lost_Helper_Invalidates_The_Family (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Parent, Child : T.Recorder;
      Saved : constant T.Lineage := T.Current;
      Settings : T.Options;
      Status : E.Error_Info;
      Checked : T.Validation;
   begin
      Fresh ("lost-helper");
      Start (Parent, "lost-helper");
      Generation (Parent);
      T.Append (Parent, T.Tool_Call, "{""id"":1,""name"":""delegate"",""arguments"":""{}""}");
      Settings.Directory := To_Unbounded_String
        (Ada.Directories.Containing_Directory (Ada.Directories.Containing_Directory (T.Path (Parent))));
      Settings.Max_Bytes := 1_024;
      T.Enter ((Parent => To_Unbounded_String (T.Path (Parent)), Parent_Call => 1,
        Directory => Settings.Directory, others => <>));
      T.Open (Child, Settings,
        "{""parent_episode"":" & T.Quote (T.Path (Parent)) & ",""parent_call"":1}", Status);
      T.Append (Child, T.Raw_Reply, "{""text"":" & T.Quote ([1 .. 2_000 => 'x']) & "}");
      T.Finish (Child, "{""complete"":true,""reason"":""answered""}", Status);
      Assert (E.Is_Error (Status), "a capped helper was published as complete");
      T.Enter (Saved);
      T.Append (Parent, T.Tool_Result, "{""id"":1,""text"":""child done"",""ending"":""answered""}");
      T.Finish (Parent, "{""complete"":true,""reason"":""answered""}", Status);
      Assert (E.Is_Error (Status) and then not Ada.Directories.Exists (T.Path (Parent)),
        "the parent hid a missing helper behind its own success");
      T.Validate (T.Path (Parent) & ".partial", Checked, Status);
      Assert (E.Is_Error (Status), "an incomplete helper family remained exportable");
   exception
      when others =>
         T.Enter (Saved);
         raise;
   end A_Lost_Helper_Invalidates_The_Family;

   procedure Invalid_Environment_Is_Bounded (Case_Of : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Case_Of);
      Saved_Dir : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_CAPTURE_DIR", "");
      Saved_Bytes : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_CAPTURE_MAX_BYTES", "");
      Item : T.Recorder;
      Settings : T.Options;
      Status : E.Error_Info;
      type Values_List is array (Positive range <>) of Unbounded_String;
      Values : constant Values_List :=
        [To_Unbounded_String ("0"), To_Unbounded_String ("-1"), To_Unbounded_String ("bad"),
         To_Unbounded_String ("999999999999999999999999")];
      procedure Restore is
      begin
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CAPTURE_DIR", Saved_Dir);
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CAPTURE_MAX_BYTES", Saved_Bytes);
      end Restore;
   begin
      Ada.Environment_Variables.Set ("MODEL_RUNNER_CAPTURE_DIR", Base & "/invalid-env");
      for Value of Values loop
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CAPTURE_MAX_BYTES", To_String (Value));
         Settings := T.Configured;
         T.Open (Item, Settings, "{}", Status);
         Assert (Status.Code = E.CLI_Invalid_Environment_Value,
           "malformed or overflowing capture bounds were not refused");
      end loop;
      Restore;
   exception
      when others =>
         Restore;
         raise;
   end Invalid_Environment_Is_Bounded;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Full_Text_And_Tokens'Access, "whole text, terminal tokens and partial UTF-8 survive");
      Register_Routine (T, Corruption_And_Truncation'Access, "corruption and truncated capture are refused");
      Register_Routine (T, Structural_Loss_Is_Refused'Access, "valid digests cannot hide missing structure or masks");
      Register_Routine (T, Bounds_And_Retention'Access, "capture bounds retain partial evidence without replacement");
      Register_Routine (T, Export_Is_Explicit_And_Bound'Access, "export selection and verification are explicit");
      Register_Routine
        (T, Independent_Verification_Is_Required'Access, "training eligibility binds independent evidence");
      Register_Routine
        (T, Real_Generation_Is_Unchanged'Access, "actual token IDs agree with uncaptured native generation");
      Register_Routine (T, Helpers_Stay_With_Their_Parent'Access, "helper bundles validate without their source files");
      Register_Routine
        (T, A_Lost_Helper_Invalidates_The_Family'Access, "a lost helper cannot become a complete family");
      Register_Routine (T, Invalid_Environment_Is_Bounded'Access, "invalid environment bounds never overflow");
   end Register_Tests;
end Tests.Trajectory_Cases;
