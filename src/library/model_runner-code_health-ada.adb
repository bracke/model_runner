with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Records;
with Model_Runner.UTF8;

package body Model_Runner.Code_Health.Ada is

   use Standard.Ada.Strings.Unbounded;
   use type Standard.Ada.Real_Time.Time;
   use type P.Command_Runner_Reference;
   use type P.Check_Status;

   package E renames Model_Runner.Errors;
   package X renames Model_Runner.Framework.Execution;
   package R renames Model_Runner.Framework.Records;

   Provider_Version : constant String := "1.0.0";

   function Lower (Text : String) return String is
     (Standard.Ada.Characters.Handling.To_Lower (Text));

   function Trim (Text : String) return String is
     (Standard.Ada.Strings.Fixed.Trim (Text, Standard.Ada.Strings.Both));

   function Ends_With (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Lower (Text (Text'Last - Suffix'Length + 1 .. Text'Last)) = Lower (Suffix));

   function Is_Source (Path : String) return Boolean is
     (Ends_With (Path, ".ads") or else Ends_With (Path, ".adb"));

   function Is_Project (Path : String) return Boolean is
     (Ends_With (Path, ".gpr"));

   function Is_Manifest (Path : String) return Boolean is
     (Lower (Standard.Ada.Directories.Simple_Name (Path)) = "alire.toml");

   function Quote (Text : String) return String is
   begin
      if (for some Letter of Text => Letter = '"') then
         return "";
      end if;
      return '"' & Text & '"';
   end Quote;

   function Bounded_Output (Text : String) return String is
      Repaired : constant String := Model_Runner.UTF8.Repaired (Text);
      Limit    : constant Natural := Natural'Min (Repaired'Length, 1024);
      Kept     : constant Natural :=
        Model_Runner.UTF8.Safe_Prefix_Length (Repaired (Repaired'First .. Repaired'First + Limit - 1));
   begin
      return (if Kept = 0 then "" else Repaired (Repaired'First .. Repaired'First + Kept - 1));
   end Bounded_Output;

   function Fingerprint
     (Kind  : String;
      First : String;
      More  : String_Lists.Vector := String_Lists.Empty_Vector) return String
   is
      Meaning : R.Item := R.Create ("code_health.ada." & Kind, 1, "ADA", 1);
   begin
      R.Set (Meaning, "first", First);
      for Index in 1 .. Natural (More.Length) loop
         R.Set (Meaning, "item." & R.Numbered (Index, Natural (More.Length)), More.Element (Index));
      end loop;
      return R.Fingerprint_Of (Meaning);
   end Fingerprint;

   procedure Add_Check
     (Result     : in out P.Analysis_Result;
      Identifier : String;
      State       : P.Check_Status;
      Detail      : String := "";
      Required    : Boolean := True)
   is
      function Rank (Value : P.Check_Status) return Natural is
        (case Value is
            when P.Check_Not_Run     => 0,
            when P.Check_Passed      => 1,
            when P.Check_Findings    => 2,
            when P.Check_Failed      => 3,
            when P.Check_Unavailable => 4,
            when P.Check_Timed_Out   => 5,
            when P.Check_Cancelled   => 6,
            when P.Check_Stale       => 7);
   begin
      for Index in 1 .. Natural (Result.Checks.Length) loop
         if To_String (Result.Checks.Element (Index).Identifier) = Identifier then
            declare
               Item : P.Check_Result := Result.Checks.Element (Index);
            begin
               if Rank (State) > Rank (Item.Status) then
                  Item.Status := State;
               end if;
               Item.Required := Item.Required or else Required;
               if Detail /= "" and then Length (Item.Detail) = 0 then
                  Item.Detail := To_Unbounded_String (Detail);
               end if;
               Result.Checks.Replace_Element (Index, Item);
               return;
            end;
         end if;
      end loop;
      Result.Checks.Append
        (P.Check_Result'
         (Identifier => To_Unbounded_String (Identifier),
          Status     => State,
          Required   => Required,
          Detail     => To_Unbounded_String (Detail),
          Evidence   => Null_Unbounded_String));
   end Add_Check;

   function All_Decimal (Text : String) return Boolean is
     (Text /= "" and then (for all Letter of Text => Letter in '0' .. '9'));

   procedure Parse_Diagnostic
     (Line     : String;
      Snapshot : String;
      Result   : in out P.Analysis_Result;
      Status   : out E.Error_Info)
   is
      First  : Natural := 0;
      Second : Natural := 0;
      Third  : Natural := 0;

      function Native_Code (Text, Fallback : String) return String is
         Opened : Natural := 0;
      begin
         if Text'Length > 2 and then Text (Text'Last) = ']' then
            for Position in reverse Text'First .. Text'Last - 1 loop
               if Text (Position) = '[' then
                  Opened := Position;
                  exit;
               end if;
            end loop;
         end if;
         return
           (if Opened = 0 then Fallback
            else Text (Opened + 1 .. Text'Last - 1));
      end Native_Code;
   begin
      --  Find path:line:column: from the left while allowing a drive colon.
      for Position in Line'First .. Line'Last loop
         if Line (Position) = ':' then
            if First = 0 then
               First := Position;
            elsif All_Decimal (Line (First + 1 .. Position - 1)) then
               Second := Position;
               exit;
            else
               First := Position;
            end if;
         end if;
      end loop;
      if Second = 0 then
         Status := E.Success;
         return;
      end if;
      for Position in Second + 1 .. Line'Last loop
         if Line (Position) = ':' then
            if All_Decimal (Line (Second + 1 .. Position - 1)) then
               Third := Position;
            end if;
            exit;
         end if;
      end loop;
      if Third = 0 or else First = Line'First then
         Status := E.Success;
         return;
      end if;

      declare
         Words   : constant String := Trim (Line (Third + 1 .. Line'Last));
         Warning : constant Boolean :=
           Words'Length >= 8 and then Lower (Words (Words'First .. Words'First + 7)) = "warning:";
         Failure : constant Boolean :=
           Words'Length >= 6 and then Lower (Words (Words'First .. Words'First + 5)) = "error:";
         Offset  : constant Natural := (if Warning then 8 elsif Failure then 6 else 0);
         Message : constant String :=
           (if Offset = 0 then Words else Trim (Words (Words'First + Offset .. Words'Last)));
         Finding : constant D.Diagnostic :=
           (Provider    => To_Unbounded_String ("ada"),
            Rule_Id     => To_Unbounded_String (if Warning then "GNAT-WARNING" else "GNAT-ERROR"),
            Severity    => (if Warning then Code_Health.Warning else Code_Health.Error),
            Path        => To_Unbounded_String (Line (Line'First .. First - 1)),
            Line        => Natural'Value (Line (First + 1 .. Second - 1)),
            Column      => Natural'Value (Line (Second + 1 .. Third - 1)),
            Message     => To_Unbounded_String (Message),
            Explanation => To_Unbounded_String ("GNAT rejected or warned about this Ada construct"),
            Remediation => To_Unbounded_String ("Correct the reported Ada construct and recheck"),
            Native_Code => To_Unbounded_String
              (Native_Code (Words, (if Warning then "warning" else "error"))),
            Snapshot    => To_Unbounded_String (Snapshot),
            others      => <>);
      begin
         if not Warning and then not Failure then
            Status := E.Success;
            return;
         end if;
         D.Append_Validated (Result.Diagnostics, Finding, Status);
      end;
   exception
      when Constraint_Error =>
         Status := E.Success;
   end Parse_Diagnostic;

   procedure Parse_Output
     (Output   : String;
      Snapshot : String;
      Result   : in out P.Analysis_Result;
      Status   : out E.Error_Info)
   is
      First : Natural := Output'First;
   begin
      while First <= Output'Last loop
         declare
            Last : Natural :=
              Standard.Ada.Strings.Fixed.Index (Output (First .. Output'Last), String'(1 => ASCII.LF));
         begin
            if Last = 0 then
               Last := Output'Last + 1;
            end if;
            if Last > First then
               Parse_Diagnostic (Output (First .. Last - 1), Snapshot, Result, Status);
               if not E.Is_Ok (Status) then
                  return;
               end if;
            end if;
            First := Last + 1;
         end;
      end loop;
      Status := E.Success;
   end Parse_Output;

   procedure Execute
     (Request  : P.Analysis_Request;
      Command  : String;
      Outcome  : out X.Outcome;
      Status   : out E.Error_Info) is
   begin
      if Request.Runner = null then
         Outcome := (others => <>);
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "no policy-bound Code Health command runner is available");
         return;
      end if;
      P.Run
        (Request.Runner.all, Request.Execution_Policy, Command, "", Request.Deadline,
         Request.Cancel, Outcome, Status);
   end Execute;

   procedure Initialize
     (Self           : in out Instance;
      Source_Checker : Source_Analyzer_Reference := null;
      Language_Checker : Source_Analyzer_Reference := null) is
   begin
      Self.Source_Checker := Source_Checker;
      Self.Language_Checker := Language_Checker;
   end Initialize;

   overriding function Identifier (Self : Instance) return String is
   begin
      pragma Unreferenced (Self);
      return "ada";
   end Identifier;

   overriding function Version (Self : Instance) return String is
   begin
      pragma Unreferenced (Self);
      return Provider_Version;
   end Version;

   overriding function Supports
     (Self  : Instance;
      Path  : String;
      Level : Check_Level) return Boolean is
   begin
      pragma Unreferenced (Self, Level);
      return Is_Source (Path) or else Is_Project (Path) or else Is_Manifest (Path);
   end Supports;

   overriding procedure Analyze
     (Self    : in out Instance;
      Request : P.Analysis_Request;
      Result  : out P.Analysis_Result;
      Status  : out E.Error_Info)
   is
      Started       : constant Standard.Ada.Real_Time.Time := Standard.Ada.Real_Time.Clock;
      Sources       : String_Lists.Vector;
      Projects      : String_Lists.Vector;
      Manifests     : String_Lists.Vector;
      Tool_Versions : String_Lists.Vector;
      Ready_Tools   : String_Lists.Vector;
      Missing_Tools : String_Lists.Vector;
      Any_Findings  : Boolean := False;

      procedure Run_Check
        (Check_Id : String;
         Tool     : String;
         Command  : String;
         File     : String)
      is
         Tool_Result : X.Outcome;
         Ran         : E.Error_Info;
         Before      : constant Natural := D.Length (Result.Diagnostics);
      begin
         if Missing_Tools.Contains (Tool) then
            Add_Check (Result, Check_Id, P.Check_Unavailable, Tool & " is unavailable or not authorized");
            return;
         elsif not Ready_Tools.Contains (Tool) then
            Execute (Request, Tool & " --version", Tool_Result, Ran);
            if not E.Is_Ok (Ran) or else not Tool_Result.Started or else Tool_Result.Exit_Status /= 0 then
               Missing_Tools.Append (Tool);
               Tool_Versions.Append (Tool & ":unavailable");
               Add_Check (Result, Check_Id, P.Check_Unavailable, Tool & " is unavailable or not authorized");
               return;
            end if;
            Ready_Tools.Append (Tool);
            Tool_Versions.Append (Tool & ":" & Trim (To_String (Tool_Result.Output)));
         end if;

         Execute (Request, Command, Tool_Result, Ran);
         if not E.Is_Ok (Ran) or else not Tool_Result.Started then
            Add_Check (Result, Check_Id, P.Check_Unavailable, "the check could not be started");
         elsif Tool_Result.Cancelled then
            Result.Cancelled := True;
            Add_Check (Result, Check_Id, P.Check_Cancelled, "the check was cancelled");
         elsif Tool_Result.Timed_Out then
            Result.Timed_Out := True;
            Add_Check (Result, Check_Id, P.Check_Timed_Out, "the check exceeded its deadline");
         else
            Parse_Output (To_String (Tool_Result.Output), To_String (Request.Change_Id), Result, Ran);
            if not E.Is_Ok (Ran) then
               Status := Ran;
               return;
            end if;
            Result.Exit_Status := Tool_Result.Exit_Status;
            if D.Length (Result.Diagnostics) > Before then
               Add_Check (Result, Check_Id, P.Check_Findings);
               Result.Files_Analyzed.Append (File);
               Any_Findings := True;
            elsif Tool_Result.Exit_Status = 0 then
               Add_Check (Result, Check_Id, P.Check_Passed);
               Result.Files_Analyzed.Append (File);
            else
               Add_Check
                 (Result, Check_Id, P.Check_Failed,
                  "the analysis process failed without a recognized source diagnostic");
            end if;
         end if;
      end Run_Check;

      procedure Run_Focused_Test (Command : String) is
         Tool_Result : X.Outcome;
         Ran         : E.Error_Info;
      begin
         Execute (Request, Command, Tool_Result, Ran);
         if not E.Is_Ok (Ran) or else not Tool_Result.Started then
            Add_Check (Result, "ada-affected-tests", P.Check_Unavailable,
                       "the configured test command could not be started");
         elsif Tool_Result.Cancelled then
            Result.Cancelled := True;
            Add_Check (Result, "ada-affected-tests", P.Check_Cancelled, "the test command was cancelled");
         elsif Tool_Result.Timed_Out then
            Result.Timed_Out := True;
            Add_Check (Result, "ada-affected-tests", P.Check_Timed_Out, "the test command timed out");
         elsif Tool_Result.Exit_Status = 0 then
            Add_Check (Result, "ada-affected-tests", P.Check_Passed);
         else
            declare
               Message : constant String := Bounded_Output (To_String (Tool_Result.Output));
               Finding : constant D.Diagnostic :=
                 (Provider    => To_Unbounded_String ("ada"),
                  Rule_Id     => To_Unbounded_String ("AUNIT-TEST-FAILURE"),
                  Severity    => Code_Health.Error,
                  Message     => To_Unbounded_String
                    (if Message = "" then "configured affected test command failed" else Message),
                  Explanation => To_Unbounded_String
                    ("The configured affected-test scope returned a failing status"),
                  Remediation => To_Unbounded_String
                    ("Repair the regression and rerun the same affected-test scope"),
                  Native_Code => To_Unbounded_String ("exit-" & Trim (Integer'Image (Tool_Result.Exit_Status))),
                  Snapshot    => Request.Change_Id,
                  others      => <>);
            begin
               D.Append_Validated (Result.Diagnostics, Finding, Ran);
               if not E.Is_Ok (Ran) then
                  Status := Ran;
                  return;
               end if;
            end;
            Result.Exit_Status := Tool_Result.Exit_Status;
            Any_Findings := True;
            Add_Check (Result, "ada-affected-tests", P.Check_Findings);
         end if;
      end Run_Focused_Test;

      procedure Run_Analyzer
        (Analyzer : not null Source_Analyzer_Reference;
         Check_Id : String)
      is
         Shared : Source_Analysis;
         Read   : E.Error_Info;
      begin
         if not P.Valid_Version (Version (Analyzer.all)) then
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", Check_Id & ".version");
            E.Add_Text (Status, "detail", "the source analyzer returned an invalid version");
            return;
         end if;
         Analyze_Changed_Sources
           (Analyzer.all, To_String (Request.Project_Root), Sources,
            To_String (Request.Configuration), To_String (Request.Change_Id), Shared, Read);
         if not E.Is_Ok (Read) then
            Add_Check (Result, Check_Id, P.Check_Failed, "supplemental source analysis failed");
         elsif To_String (Shared.Check.Identifier) /= Check_Id
           or else Shared.Check.Status = P.Check_Not_Run
         then
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", Check_Id);
            E.Add_Text (Status, "detail", "the source analyzer returned an invalid check result");
            return;
         else
            Result.Checks.Append (Shared.Check);
            for Index in 1 .. D.Length (Shared.Diagnostics) loop
               declare
                  Finding : constant D.Diagnostic := D.Element (Shared.Diagnostics, Index);
               begin
                  if Finding.Snapshot /= Request.Change_Id then
                     Status := E.Make (E.Framework_Schema_Violation);
                     E.Add_Text (Status, "name", "diagnostic.snapshot");
                     E.Add_Text (Status, "detail", "the source analyzer returned stale diagnostic data");
                     return;
                  end if;
                  D.Append_Validated
                    (Result.Diagnostics, Finding, Read, To_String (Request.Project_Root));
                  if not E.Is_Ok (Read) then
                     Status := Read;
                     return;
                  end if;
               end;
            end loop;
            for File of Shared.Files_Analyzed loop
               if not Result.Files_Analyzed.Contains (File) then
                  Result.Files_Analyzed.Append (File);
               end if;
            end loop;
            for Tool_Version of Shared.Toolchain_Fingerprint loop
               Tool_Versions.Append (Tool_Version);
            end loop;
            Any_Findings := Any_Findings or else D.Length (Shared.Diagnostics) > 0;
         end if;
      end Run_Analyzer;
   begin
      Result := (others => <>);
      Result.Provider_Id := To_Unbounded_String (Identifier (Self));
      Result.Provider_Version := To_Unbounded_String (Version (Self));
      Status := E.Success;

      if Request.Change_Id = Null_Unbounded_String then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "change_id");
         E.Add_Text (Status, "detail", "Ada analysis requires an immutable snapshot identifier");
         return;
      elsif Model_Runner.Cancellation.Is_Cancelled (Request.Cancel) then
         Result.Cancelled := True;
         Add_Check (Result, "ada-analysis", P.Check_Cancelled, "analysis was cancelled before it started");
         return;
      end if;

      for Path of Request.Changed_Files loop
         if Is_Source (Path) then
            Sources.Append (Path);
         elsif Is_Project (Path) then
            Projects.Append (Path);
         elsif Is_Manifest (Path) then
            Manifests.Append (Path);
         end if;
      end loop;
      if Request.Level /= Fast
        and then (for some Path of Sources => Ends_With (Path, ".ads"))
      then
         for Path of Request.Dependencies loop
            if Is_Project (Path) and then not Projects.Contains (Path) then
               Projects.Append (Path);
            end if;
         end loop;
         if Projects.Is_Empty then
            Add_Check
              (Result, "ada-project", P.Check_Unavailable,
               "dependency-aware validation needs an explicit GPR project mapping");
         end if;
      end if;

      if not Sources.Is_Empty and then Length (Request.Analysis_Root) = 0 then
         Add_Check
           (Result, "ada-syntax", P.Check_Failed,
            "syntax analysis requires a disposable analysis directory");
      end if;
      for Path of Sources loop
         declare
            Destination : constant String := To_String (Request.Analysis_Root);
            File_Name   : constant String := Quote (Path);
            Command     : constant String :=
              "gnatmake -q -c -gnatc -gnat2022 -gnatwa"
              & (if Destination = "" then "" else " -D " & Quote (Destination))
              & " " & File_Name;
         begin
            if Destination = "" then
               null;
            elsif File_Name = "" or else Quote (Destination) = "" then
               Add_Check (Result, "ada-syntax", P.Check_Failed, "an analysis path contains an unsupported quote");
            else
               Run_Check ("ada-syntax", "gnatmake", Command, Path);
            end if;
         end;
         exit when not E.Is_Ok (Status);
      end loop;

      for Path of Projects loop
         if Quote (Path) = "" then
            Add_Check (Result, "ada-project", P.Check_Failed, "a project path contains an unsupported quote");
         else
            Run_Check
              ("ada-project", "gprbuild",
               "gprbuild -P " & Quote (Path) & " --subdirs=code_health -c -u -gnatc", Path);
         end if;
         exit when not E.Is_Ok (Status);
      end loop;

      for Path of Manifests loop
         Run_Check ("ada-manifest", "alr", "alr show", Path);
         exit when not E.Is_Ok (Status);
      end loop;
      if not E.Is_Ok (Status) then
         return;
      end if;

      if Request.Level /= Fast and then not Sources.Is_Empty then
         if not Request.Affected_Tests.Is_Empty then
            for Command of Request.Affected_Tests loop
               Run_Focused_Test (Command);
               exit when not E.Is_Ok (Status);
            end loop;
         elsif Length (Request.Fallback_Test) > 0 then
            Run_Focused_Test (To_String (Request.Fallback_Test));
         else
            Add_Check
              (Result, "ada-affected-tests", P.Check_Unavailable,
               "no reliable affected-test mapping or fallback test scope is configured");
         end if;
      end if;
      if not E.Is_Ok (Status) then
         return;
      end if;

      if not Sources.Is_Empty then
         if Self.Source_Checker = null then
            Add_Check
              (Result, "ada-quality-source", P.Check_Unavailable,
               "change-scoped ada_quality adapter is not linked", Required => False);
         else
            Run_Analyzer (Self.Source_Checker, "ada-quality-source");
         end if;
         if E.Is_Ok (Status) and then Self.Language_Checker /= null then
            Run_Analyzer (Self.Language_Checker, "ada-language-server");
         end if;
      end if;

      Result.Input_Fingerprint :=
        To_Unbounded_String (Fingerprint ("input", To_String (Request.Change_Id), Request.Changed_Files));
      declare
         Test_Settings : String_Lists.Vector := Request.Affected_Tests;
      begin
         Test_Settings.Append ("fallback=" & To_String (Request.Fallback_Test));
         Result.Configuration_Fingerprint :=
           To_Unbounded_String
             (Fingerprint ("configuration", To_String (Request.Configuration), Test_Settings));
      end;
      Result.Toolchain_Fingerprint :=
        To_Unbounded_String (Fingerprint ("toolchain", Provider_Version, Tool_Versions));
      Result.Environment_Fingerprint :=
        To_Unbounded_String (Fingerprint ("environment", To_String (Request.Environment)));
      Result.Duration :=
        Standard.Ada.Real_Time.To_Duration (Standard.Ada.Real_Time.Clock - Started);
      Result.Resource_Summary :=
        To_Unbounded_String
          (Natural'Image (Natural (Result.Checks.Length)) & " checks;"
           & Natural'Image (D.Length (Result.Diagnostics)) & " diagnostics"
           & (if Any_Findings then "; findings present" else ""));
      Status := E.Success;
   end Analyze;

end Model_Runner.Code_Health.Ada;
