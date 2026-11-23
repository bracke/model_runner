with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with Model_Runner.Errors;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Retrieval;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Editing;
with Model_Runner.Tools.Runner;
with Model_Runner.Trajectories;
with Project_Tools.Files;
with Agent_Trial;
with Trial_Graders;

package body Tests.Reference_Edit_Cases is
   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   package Ed renames Model_Runner.Tools.Editing;
   package Rt renames Model_Runner.Framework.Retrieval;
   package E renames Model_Runner.Errors;
   package Tr renames Model_Runner.Tools.Runner;
   use type Tr.Answer_Kind;
   LF : constant Character := ASCII.LF;
   Prefix : constant String := "package body Calc is" & LF & LF;
   Old_Body : constant String :=
     "   function Add (A, B : Integer) return Integer is" & LF & "   begin" & LF
     & "      return A + B;" & LF & "   end Add;" & LF;
   Suffix : constant String := LF & "   function Times (A, B : Integer) return Integer is" & LF
     & "   begin" & LF & "      return A * B;" & LF & "   end Times;" & LF & "end Calc;";
   Original : constant String := Prefix & Old_Body & Suffix;
   New_Body : constant String := "function Add (A, B : Integer) return Integer is" & LF
     & "begin" & LF & "   return A - B;" & LF & "end Add;";
   Expected : constant String := Prefix & "   function Add (A, B : Integer) return Integer is" & LF
     & "   begin" & LF & "      return A - B;" & LF & "   end Add;" & LF & Suffix;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("revision checked reference editing");
   end Name;

   function Fresh (Name : String) return String is
      Dir : constant String := Ada.Directories.Full_Name ("obj/reference-edits/" & Name);
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Project_Tools.Files.Write_Raw_File (Dir & "/calc.adb", Original);
      return Dir;
   end Fresh;

   function Ref (Dir : String; Line : Positive := 4) return String is
      Part : Rt.Excerpt;
      Status : E.Error_Info;
   begin
      Rt.Around (Dir, "calc.adb", Line, 400, Part, Status);
      Assert (E.Is_Ok (Status) and then Part.Structural and then not Part.Truncated,
              "fixture did not produce a complete structural reference");
      return Rt.Reference (Part);
   end Ref;

   function Read (Dir : String) return String is (Project_Tools.Files.Read_Raw_File (Dir & "/calc.adb"));
   procedure Put (Dir, Text : String) is
   begin
      Project_Tools.Files.Write_Raw_File (Dir & "/calc.adb", Text);
   end Put;

   procedure One_Routine_Only (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Dir : constant String := Fresh ("one");
      Reference : constant String := Ref (Dir);
      Result : constant Ed.Said := Ed.Edit_Reference ("calc.adb", Reference, New_Body, Dir);
   begin
      Assert (not Result.Failed and then Result.Changed and then Read (Dir) = Expected,
              "ref did not replace only the intended body with its indentation: " & To_String (Result.Text));
      Assert (To_String (Result.Before_Revision) = Ed.Revision (Original)
              and then To_String (Result.After_Revision) = Ed.Revision (Expected), "ref revisions were incorrect");
      Assert (Ada.Strings.Fixed.Index (To_String (Result.Text), "; ref " & Ref (Dir)) > 0,
              "replacement did not return a current reference for a subsequent repair");
      declare
         Noop : constant Ed.Said := Ed.Edit_Reference ("calc.adb", Ref (Dir), New_Body, Dir);
      begin
         Assert (not Noop.Failed and then not Noop.Changed and then Read (Dir) = Expected,
                 "identical reference replacement was reported as a change");
      end;
      Put (Dir, Prefix & "   -- Add documentation" & LF & Old_Body & Suffix);
      declare
         Commented : constant Ed.Said := Ed.Edit_Reference ("calc.adb", Ref (Dir, 5), New_Body, Dir);
      begin
         Assert (not Commented.Failed and then Read (Dir) = Expected,
                 "leading declaration comments prevented structural replacement");
      end;
   end One_Routine_Only;

   procedure Refusals_Keep_The_File (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Dir : constant String := Fresh ("guards");
      Reference : constant String := Ref (Dir);
      Rev : constant String := Ed.Revision (Original);
      Result : Ed.Said;
   begin
      Assert (Ed.Edit_Reference ("calc.adb", "Calc.Add", New_Body, Dir).Failed,
              "a bare ambiguous name was treated as a revision-bound reference");
      Assert (Ed.Edit_Reference ("other.adb", Reference, New_Body, Dir).Failed,
              "reference path bypassed the separately permission-checked path");
      Assert (Ed.Edit_Reference ("calc.adb", "calc.adb:4-5@" & Rev, New_Body, Dir).Failed,
              "an interior excerpt replaced a complete body");
      Assert (Ed.Edit_Reference ("calc.adb", "calc.adb:3-11@" & Rev, New_Body, Dir).Failed,
              "a range covering two neighbors was accepted");
      Assert (Ed.Edit_Reference ("calc.adb", Reference, "return 7;", Dir).Failed
              and then Ed.Edit_Reference ("calc.adb", Reference,
                "function Other return Integer is" & LF & "begin" & LF & " return 7;" & LF & "end Other;", Dir).Failed,
              "partial or differently named replacement was accepted");
      Assert (Ed.Edit_Reference ("calc.adb", Reference,
                "procedure Add (A, B : Integer) is" & LF & "begin" & LF & " null;" & LF & "end Add;", Dir).Failed,
              "replacement changed the target's declaration kind");
      Assert (Ed.Edit_Reference ("calc.adb", Reference, New_Body & LF
                & "procedure Extra is" & LF & "begin" & LF & " null;" & LF & "end Extra;", Dir).Failed,
              "replacement appended an unrelated declaration");
      Assert (Read (Dir) = Original, "a refused replacement changed the file");
      Put (Dir, Original & LF & "-- external save");
      Assert (Ed.Edit_Reference ("calc.adb", Reference, New_Body, Dir).Failed, "stale reference was accepted");
      Ed.Replace ("calc.adb", Expected, Result, Dir, Expected => Rev);
      Assert (Result.Failed and then Read (Dir) = Original & LF & "-- external save",
              "checked writer overwrote a version that changed after the reference read");
   end Refusals_Keep_The_File;

   procedure Ambiguous_Boundaries (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Dir : constant String := Fresh ("boundaries");
      Inline : constant String := "function Add return Integer is begin return 1; end Add; "
        & "function Add (A : Integer) return Integer is" & LF & "begin" & LF & " return A;" & LF & "end Add;";
      Crowded : constant String := Prefix & "   function Add (A, B : Integer) return Integer is" & LF
        & "   begin" & LF & "      return A + B;" & LF & "   end Add; X : Integer;" & LF & Suffix;
   begin
      Put (Dir, Inline);
      Assert (Ed.Edit_Reference ("calc.adb", "calc.adb:1-4@" & Ed.Revision (Inline), New_Body, Dir).Failed
              and then Read (Dir) = Inline, "same-line neighboring overload was consumed");
      declare
         With_Character : constant String := "function Add (C : Character := '(') return Integer is "
           & "begin return 1; end Add; function Add (A : Integer) return Integer is" & LF
           & "begin" & LF & " return A;" & LF & "end Add;";
      begin
         Put (Dir, With_Character);
         Assert (Ed.Edit_Reference ("calc.adb", "calc.adb:1-4@" & Ed.Revision (With_Character), New_Body, Dir).Failed
                 and then Read (Dir) = With_Character, "a character literal hid same-line neighboring code");
      end;
      Put (Dir, Crowded);
      Assert (Ed.Edit_Reference ("calc.adb", "calc.adb:3-6@" & Ed.Revision (Crowded), New_Body, Dir).Failed
              and then Read (Dir) = Crowded, "neighbor after the closing semicolon was consumed");
      declare
         Other : constant String := LF & "   function Add (A : Integer) return Integer is" & LF
           & "   begin" & LF & "      return A;" & LF & "   end Add;" & LF & "end Calc;";
         Before : constant String := Prefix & Old_Body & Other;
         Neww : constant String := "function Add (A : Integer) return Integer is" & LF & "begin" & LF
           & "   return A + 1;" & LF & "end Add;";
         Result : Ed.Said;
      begin
         Put (Dir, Before);
         Result := Ed.Edit_Reference ("calc.adb", Ref (Dir, 9), Neww, Dir);
         Assert (not Result.Failed and then Ada.Strings.Fixed.Index (Read (Dir), Prefix & Old_Body) = 1
                 and then Ada.Strings.Fixed.Index (Read (Dir), "return A + 1;") > 0,
                 "an explicit overload reference failed or changed its neighboring overload: "
                 & To_String (Result.Text));
      end;
   end Ambiguous_Boundaries;

   procedure Endings_And_Limits (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Dir : constant String := Fresh ("bytes");
      function CRLF (Text : String) return String is
         Result : Unbounded_String;
      begin
         for C of Text loop
            if C = LF then
               Append (Result, ASCII.CR);
            end if;
            Append (Result, C);
         end loop;
         return To_String (Result);
      end CRLF;
      Result : Ed.Said;
   begin
      Put (Dir, CRLF (Original));
      Result := Ed.Edit_Reference ("calc.adb", Ref (Dir), New_Body & LF, Dir);
      Assert (not Result.Failed and then Read (Dir) = CRLF (Expected),
              "CRLF neighbors or final missing newline changed: " & To_String (Result.Text));
      Put (Dir, New_Body);
      Result := Ed.Edit_Reference ("calc.adb", "calc.adb:1-4@" & Ed.Revision (New_Body),
                                  "function Add (A, B : Integer) return Integer is" & LF & "begin" & LF
                                  & "   return A;" & LF & "end Add;", Dir);
      Assert (not Result.Failed and then Read (Dir) (Read (Dir)'Last) = ';', "final body gained a newline");
      declare
         Procedure_Body : constant String := "procedure Inc (A : in out Integer) is" & LF
           & "begin" & LF & "   A := A + 1;" & LF & "end Inc;";
         Replacement : constant String := "procedure Inc (A : in out Integer) is" & LF
           & "begin" & LF & "   A := A + 2;" & LF & "end Inc;";
      begin
         Put (Dir, Procedure_Body);
         Result := Ed.Edit_Reference ("calc.adb", "calc.adb:1-4@" & Ed.Revision (Procedure_Body), Replacement, Dir);
         Assert (not Result.Failed and then Read (Dir) = Replacement, "procedure body replacement failed");
      end;
      Put (Dir, Original);
      declare
         Large : constant String := "function Add (A, B : Integer) return Integer is" & LF & "begin" & LF
           & [1 .. 401 => LF] & "   return A;" & LF & "end Add;";
      begin
         Assert (Ed.Edit_Reference ("calc.adb", Ref (Dir), Large, Dir).Failed and then Read (Dir) = Original,
                 "an excessive replacement was accepted");
      end;
   end Endings_And_Limits;

   procedure Tool_Mode_And_Permissions (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Pm renames Model_Runner.Framework.Permissions;
      Dir : constant String := Fresh ("tool");
      Runner : Model_Runner.Tools.Builtin.Instance;
      Room : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
      Last : Natural;
      Outcome : Tr.Call_Outcome;
      Status : E.Error_Info;
      function Q (Text : String) return String renames Model_Runner.Trajectories.Quote;
      procedure Call (Args : String) is
      begin
         Runner.Run ("edit_file", Args, Room, Last, Outcome, Status);
         Assert (E.Is_Ok (Status), "reference tool raised an unexpected runtime error");
      end Call;
      function Args (Reference : String; Extra : String := "") return String is
        ("{""path"":""calc.adb"",""ref"":" & Q (Reference) & ",""new_text"":" & Q (New_Body) & Extra & "}");
   begin
      Runner.Set_Base (Dir);
      Runner.Note_Seen ("calc.adb", Ed.Revision (Original));
      Put (Dir, Original & LF & "-- external save");
      Call (Args (Ref (Dir)));
      Assert (Outcome.Answer = Tr.Answered and then Outcome.Changed and then Read (Dir) = Expected & LF
              & "-- external save", "fresh explicit ref was blocked by an obsolete implicit seen revision");
      Call (Args (Ref (Dir), ",""old_text"":""return A - B;"""));
      Assert (Outcome.Answer = Tr.Failed, "mixed reference and passage modes were accepted");
      Call (Args (Ref (Dir), ",""revision"":""0000000000000000"""));
      Assert (Outcome.Answer = Tr.Failed, "contradictory explicit revision was accepted");
      Call ("{""path"":""calc.adb"",""ref"":0,""old_text"":""return A - B;"",""new_text"":""return 0;""}");
      Assert (Outcome.Answer = Tr.Failed and then Read (Dir) = Expected & LF & "-- external save",
              "malformed ref silently fell back to an unchecked passage edit");
      Ada.Environment_Variables.Set (Pm.Agent_Root_Variable, Dir);
      Ada.Environment_Variables.Set (Pm.Agent_Permissions_Variable, Pm.Image (Pm.Nothing));
      Call (Args (Ref (Dir)));
      Ada.Environment_Variables.Clear (Pm.Agent_Root_Variable);
      Ada.Environment_Variables.Clear (Pm.Agent_Permissions_Variable);
      Assert (Outcome.Answer = Tr.Refused and then not Outcome.Changed,
              "reference mode bypassed the ordinary write permission boundary");
   end Tool_Mode_And_Permissions;

   procedure Directed_Grade_Requires_Actual_Use (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Trace renames Model_Runner.Trajectories;
      Dir : constant String := Fresh ("directed-grade");
      function Q (Text : String) return String renames Trace.Quote;
      function Episode (Slot, Args, Reply : String) return String is
         Recorder : Trace.Recorder;
         Settings : Trace.Options;
         Status : E.Error_Info;
      begin
         Settings.Directory := To_Unbounded_String (Dir & "/" & Slot);
         Trace.Open (Recorder, Settings, "{}", Status);
         Assert (E.Is_Ok (Status), "grader control could not open capture");
         Trace.Append (Recorder, Trace.Generation_Start,
           "{""vocabulary_size"":16,""max_tokens"":1,""sampling_ada"":""fixture"",""request_ada"":""fixture"","
           & """grammar_constrained"":false,""grammar"":null,""stop_tokens"":[],""stop_strings_hex"":[]}");
         Trace.Append (Recorder, Trace.Model_Input, "{""prompt"":""fixture"",""tokens"":[1],""loss_mask"":0}");
         Trace.Selected (Recorder, 3, "x", False);
         Trace.Append (Recorder, Trace.Committed_Token, "{""id"":3}");
         Trace.Append (Recorder, Trace.Generation_End, "{""reason"":""maximum_tokens"",""generated_tokens"":1}");
         Trace.Append (Recorder, Trace.Tool_Call,
           "{""id"":1,""name"":""edit_file"",""arguments"":" & Q (Args) & "}");
         Trace.Append (Recorder, Trace.Tool_Result, "{""id"":1,""text"":" & Q (Reply) & ",""ending"":""fixture""}");
         Trace.Finish (Recorder, "{""complete"":true,""reason"":""answered""}", Status);
         Assert (E.Is_Ok (Status), "grader control could not finish capture");
         return Trace.Path (Recorder);
      end Episode;
      Ref_Args : constant String :=
        "{""path"":""src/calc.adb"",""ref"":""src/calc.adb:3-6@0123456789abcdef"",""new_text"":""fixture""}";
   begin
      Assert (Agent_Trial.Known_Task ("edit-ref"), "directed reference fixture was not registered");
      Assert (Trial_Graders.Uses_Reference_Edit
        (Episode ("used", Ref_Args, "replaced Calc.Add in src/calc.adb; revision now 0123456789abcdef")),
        "a successful reference call was not recognized");
      Assert (not Trial_Graders.Uses_Reference_Edit
        (Episode ("legacy", "{""path"":""src/calc.adb"",""old_text"":""old"",""new_text"":""new""}",
          "edited src/calc.adb at line 3")), "legacy passage editing incorrectly qualified reference use");
      Assert (not Trial_Graders.Uses_Reference_Edit
        (Episode ("failed", Ref_Args, "error: reference is stale")), "a failed reference call qualified");
      Assert (not Trial_Graders.Uses_Reference_Edit
        (Episode ("noop", Ref_Args, "unchanged: Calc.Add in src/calc.adb")), "a no-op reference call qualified");
      Assert (not Trial_Graders.Uses_Reference_Edit (Dir & "/missing/events.jsonl"),
              "missing capture qualified reference use");
   end Directed_Grade_Requires_Actual_Use;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, One_Routine_Only'Access, "a declaration reference replaces one body and preserves neighbors");
      Register_Routine (T, Refusals_Keep_The_File'Access, "stale references and invalid bodies leave the file intact");
      Register_Routine
        (T, Ambiguous_Boundaries'Access, "ambiguous spans are refused and explicit overloads are distinct");
      Register_Routine
        (T, Endings_And_Limits'Access, "reference changes preserve line endings and enforce body limits");
      Register_Routine
        (T, Tool_Mode_And_Permissions'Access, "reference calls retain revision and permission boundaries");
      Register_Routine
        (T, Directed_Grade_Requires_Actual_Use'Access, "directed grading requires an actual successful reference edit");
   end Register_Tests;
end Tests.Reference_Edit_Cases;
