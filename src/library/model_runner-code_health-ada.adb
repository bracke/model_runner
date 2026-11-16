with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

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

   Provider_Version : constant String := "1.2.0";

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

   function Requested
     (Request    : P.Analysis_Request;
      Identifier : String) return Boolean is
   begin
      if Request.Checks.Is_Empty then
         return Identifier /= "ada-contracts";
      end if;
      for Check of Request.Checks loop
         if To_String (Check.Identifier) = Identifier then
            return True;
         end if;
      end loop;
      return False;
   end Requested;

   function Scope_Of
     (Request    : P.Analysis_Request;
      Identifier : String) return P.Scope_Kind is
   begin
      for Check of Request.Checks loop
         if To_String (Check.Identifier) = Identifier then
            return Check.Scope;
         end if;
      end loop;
      return
        (if Request.Checks.Is_Empty
           and then Request.Level /= Fast
           and then Identifier in
             "ada-project" | "ada-contracts" | "ada-affected-tests" | "ada-manifest"
         then P.Dependency_Scope
         else P.Changed_Files);
   end Scope_Of;

   function Files_For
     (Request    : P.Analysis_Request;
      Identifier : String) return String_Lists.Vector
   is
      Result : String_Lists.Vector;

      procedure Add_All (Items : String_Lists.Vector) is
      begin
         for Path of Items loop
            if not Result.Contains (Path) then
               Result.Append (Path);
            end if;
         end loop;
      end Add_All;
   begin
      case Scope_Of (Request, Identifier) is
         when P.Changed_Files =>
            Add_All (Request.Changed_Files);
         when P.Dependency_Scope =>
            Add_All (Request.Changed_Files);
            Add_All (Request.Dependencies);
         when P.Whole_Project =>
            Add_All (Request.Project_Files);
      end case;
      return Result;
   end Files_For;

   function Relevant_Files_For
     (Request    : P.Analysis_Request;
      Identifier : String) return String_Lists.Vector
   is
      Result : String_Lists.Vector := Files_For (Request, Identifier);
   begin
      --  A deleted path makes these checks applicable, but is deliberately
      --  kept out of Files_For: only live paths may become compiler targets.
      if Identifier in
        "ada-project" | "ada-contracts" | "ada-affected-tests" | "ada-manifest"
      then
         for Path of Request.Removed_Files loop
            if not Result.Contains (Path) then
               Result.Append (Path);
            end if;
         end loop;
      end if;
      return Result;
   end Relevant_Files_For;

   type File_Selection is (Ada_Source, Ada_Project, Ada_Manifest);

   function Files_Of
     (Request    : P.Analysis_Request;
      Identifier : String;
      Kind       : File_Selection;
      Relevant   : Boolean := False) return String_Lists.Vector
   is
      Result : String_Lists.Vector;
      Files  : constant String_Lists.Vector :=
        (if Relevant then Relevant_Files_For (Request, Identifier)
         else Files_For (Request, Identifier));
   begin
      for Path of Files loop
         if (case Kind is
                when Ada_Source   => Is_Source (Path),
                when Ada_Project  => Is_Project (Path),
                when Ada_Manifest => Is_Manifest (Path))
         then
            Result.Append (Path);
         end if;
      end loop;
      return Result;
   end Files_Of;

   function Configuration_Fingerprint
     (Request : P.Analysis_Request) return String
   is
   begin
      return To_String (Request.Configuration);
   end Configuration_Fingerprint;

   function Check_Deadline
     (Request    : P.Analysis_Request;
      Identifier : String) return Standard.Ada.Real_Time.Time
   is
      Started : constant Standard.Ada.Real_Time.Time :=
        (if Request.Started = Standard.Ada.Real_Time.Time_First
         then Standard.Ada.Real_Time.Clock else Request.Started);
      Result  : Standard.Ada.Real_Time.Time := Request.Deadline;
   begin
      for Check of Request.Checks loop
         if To_String (Check.Identifier) = Identifier
           and then Check.Timeout_Seconds > 0
         then
            declare
               Check_End : constant Standard.Ada.Real_Time.Time :=
                 Started + Standard.Ada.Real_Time.Seconds (Integer (Check.Timeout_Seconds));
            begin
               if Result = Standard.Ada.Real_Time.Time_Last or else Check_End < Result then
                  Result := Check_End;
               end if;
            end;
            exit;
         end if;
      end loop;
      return Result;
   end Check_Deadline;

   function Check_Policy
     (Request    : P.Analysis_Request;
      Identifier : String) return X.Policy
   is
      Result : X.Policy := Request.Execution_Policy;
   begin
      for Check of Request.Checks loop
         if To_String (Check.Identifier) = Identifier
           and then Check.Output_Limit > 0
         then
            Result.Output_Limit := Positive'Min
              (Result.Output_Limit, Positive (Check.Output_Limit));
            exit;
         end if;
      end loop;
      return Result;
   end Check_Policy;

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
      Check_Id : String;
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
            Check_Id    => To_Unbounded_String (Check_Id),
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
      Check_Id : String;
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
               Parse_Diagnostic
                 (Output (First .. Last - 1), Snapshot, Check_Id, Result, Status);
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
      Status   : out E.Error_Info;
      Check_Id : String := "") is
   begin
      if Request.Runner = null then
         Outcome := (others => <>);
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "no policy-bound Code Health command runner is available");
         return;
      end if;
      P.Run
        (Request.Runner.all,
         (if Check_Id = "" then Request.Execution_Policy else Check_Policy (Request, Check_Id)),
         Command, "",
         (if Check_Id = "" then Request.Deadline else Check_Deadline (Request, Check_Id)),
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

   overriding procedure Probe_Cache
     (Self    : in out Instance;
      Request : P.Analysis_Request;
      Result  : out P.Cache_Probe;
      Status  : out E.Error_Info)
   is
      Tool_Versions : String_Lists.Vector;
      Probed_Tools  : String_Lists.Vector;
      Applicable    : Boolean := False;
      Safe          : Boolean := True;

      procedure Version_Of (Tool, Check_Id : String) is
         Outcome : X.Outcome;
         Ran     : E.Error_Info;
      begin
         if Probed_Tools.Contains (Tool) then
            return;
         end if;
         Probed_Tools.Append (Tool);
         Execute (Request, Tool & " --version", Outcome, Ran, Check_Id);
         if not E.Is_Ok (Ran)
           or else not Outcome.Started
           or else Outcome.Exit_Status /= 0
           or else Outcome.Cancelled
           or else Outcome.Timed_Out
         then
            Safe := False;
            Tool_Versions.Append (Tool & ":unavailable");
         else
            Tool_Versions.Append (Tool & ":" & Trim (To_String (Outcome.Output)));
         end if;
      end Version_Of;

      function Applies (Check_Id : String) return Boolean is
        (not Files_Of (Request, Check_Id, Ada_Source, Relevant => True).Is_Empty
         or else not Files_Of (Request, Check_Id, Ada_Project, Relevant => True).Is_Empty
         or else not Files_Of (Request, Check_Id, Ada_Manifest, Relevant => True).Is_Empty);
   begin
      Result := (others => <>);
      Status := E.Success;
      if Requested (Request, "ada-syntax")
        and then not Files_Of (Request, "ada-syntax", Ada_Source).Is_Empty
      then
         Applicable := True;
         Version_Of ("gnatmake", "ada-syntax");
      end if;
      if Requested (Request, "ada-project")
        and then Applies ("ada-project")
      then
         Applicable := True;
         if Files_Of (Request, "ada-project", Ada_Project).Is_Empty then
            Safe := False;
         else
            Version_Of ("gprbuild", "ada-project");
         end if;
      end if;
      if Requested (Request, "ada-contracts")
        and then Applies ("ada-contracts")
      then
         Applicable := True;
         if Files_Of (Request, "ada-contracts", Ada_Project).Is_Empty then
            Safe := False;
         else
            Version_Of ("gnatprove", "ada-contracts");
         end if;
      end if;
      if Requested (Request, "ada-manifest")
        and then not Files_Of (Request, "ada-manifest", Ada_Manifest).Is_Empty
      then
         Applicable := True;
         Version_Of ("alr", "ada-manifest");
      end if;
      if Requested (Request, "ada-quality-source")
        and then not Files_Of (Request, "ada-quality-source", Ada_Source).Is_Empty
      then
         Applicable := True;
         if Self.Source_Checker = null
           or else not P.Valid_Version (Version (Self.Source_Checker.all))
         then
            Safe := False;
         else
            Tool_Versions.Append
              ("ada-quality-source:" & Version (Self.Source_Checker.all));
         end if;
      end if;

      --  Test commands and live editor state do not yet expose a complete
      --  prerequisite fingerprint, so their assessments are never reused.
      if Request.Level /= Fast
        and then Requested (Request, "ada-affected-tests")
        and then not Files_Of
          (Request, "ada-affected-tests", Ada_Source, Relevant => True).Is_Empty
      then
         Applicable := True;
         Safe := False;
      end if;
      if Requested (Request, "ada-language-server")
        and then not Files_Of (Request, "ada-language-server", Ada_Source).Is_Empty
      then
         Applicable := True;
         Safe := False;
      end if;
      for Check of Request.Checks loop
         if not Check.Cacheable then
            Safe := False;
         end if;
         if Applies (To_String (Check.Identifier))
         then
            for Requirement of Check.Tool_Requirements loop
               Version_Of (Requirement, To_String (Check.Identifier));
            end loop;
         end if;
      end loop;

      Result.Configuration_Fingerprint :=
        To_Unbounded_String (Configuration_Fingerprint (Request));
      Result.Toolchain_Fingerprint :=
        To_Unbounded_String (Fingerprint ("toolchain", Provider_Version, Tool_Versions));
      Result.Environment_Fingerprint :=
        To_Unbounded_String
          (Fingerprint ("environment", To_String (Request.Environment)));
      Result.Reusable := Applicable and then Safe;
      if not Applicable then
         Result.Detail := To_Unbounded_String ("no selected check applies to these inputs");
      elsif not Safe then
         Result.Detail := To_Unbounded_String
           ("selected checks have no complete reusable prerequisite fingerprint");
      end if;
   end Probe_Cache;

   overriding procedure Analyze
     (Self    : in out Instance;
      Request : P.Analysis_Request;
      Result  : out P.Analysis_Result;
      Status  : out E.Error_Info)
   is
      Started       : constant Standard.Ada.Real_Time.Time := Standard.Ada.Real_Time.Clock;
      Tool_Versions : String_Lists.Vector;
      Ready_Tools   : String_Lists.Vector;
      Missing_Tools : String_Lists.Vector;
      Any_Findings  : Boolean := False;

      function Requested (Identifier : String) return Boolean is
      begin
         if Request.Checks.Is_Empty then
            return Identifier /= "ada-contracts";
         end if;
         for Check of Request.Checks loop
            if To_String (Check.Identifier) = Identifier then
               return True;
            end if;
         end loop;
         return False;
      end Requested;

      function Is_Required
        (Identifier : String;
         Default    : Boolean := True) return Boolean is
      begin
         if Request.Checks.Is_Empty then
            return Default;
         end if;
         for Check of Request.Checks loop
            if To_String (Check.Identifier) = Identifier then
               return Check.Required;
            end if;
         end loop;
         return False;
      end Is_Required;

      function Prerequisites_Passed
        (Check_Id : String;
         Detail   : out Unbounded_String) return Boolean is
      begin
         Detail := Null_Unbounded_String;
         for Selected of Request.Checks loop
            if To_String (Selected.Identifier) = Check_Id then
               for Dependency of Selected.Dependencies loop
                  declare
                     Found : Boolean := False;
                  begin
                     for Earlier of Result.Checks loop
                        if To_String (Earlier.Identifier) = Dependency then
                           Found := Earlier.Status in P.Check_Passed | P.Check_Findings;
                           exit;
                        end if;
                     end loop;
                     if not Found then
                        Detail := To_Unbounded_String
                          ("prerequisite check " & Dependency & " did not complete successfully");
                        return False;
                     end if;
                  end;
               end loop;
               exit;
            end if;
         end loop;
         return True;
      end Prerequisites_Passed;

      procedure Run_Check
        (Check_Id : String;
         Tool     : String;
         Command  : String;
         File     : String)
      is
         Tool_Result : X.Outcome;
         Ran         : E.Error_Info;
         Before      : constant Natural := D.Length (Result.Diagnostics);
         Required    : constant Boolean := Is_Required (Check_Id);
         Dependency  : Unbounded_String;

         procedure Discover (Program : String; Available : out Boolean) is
         begin
            if Missing_Tools.Contains (Program) then
               Available := False;
            elsif Ready_Tools.Contains (Program) then
               Available := True;
            else
               Execute (Request, Program & " --version", Tool_Result, Ran, Check_Id);
               Available := E.Is_Ok (Ran)
                 and then Tool_Result.Started
                 and then Tool_Result.Exit_Status = 0
                 and then not Tool_Result.Cancelled
                 and then not Tool_Result.Timed_Out;
               if Available then
                  Ready_Tools.Append (Program);
                  Tool_Versions.Append
                    (Program & ":" & Trim (To_String (Tool_Result.Output)));
               else
                  Missing_Tools.Append (Program);
                  Tool_Versions.Append (Program & ":unavailable");
               end if;
            end if;
         end Discover;

         Available : Boolean;
      begin
         if not Prerequisites_Passed (Check_Id, Dependency) then
            Add_Check
              (Result, Check_Id, P.Check_Unavailable,
               To_String (Dependency), Required);
            return;
         end if;
         for Selected of Request.Checks loop
            if To_String (Selected.Identifier) = Check_Id then
               for Requirement of Selected.Tool_Requirements loop
                  Discover (Requirement, Available);
                  if not Available then
                     Add_Check
                       (Result, Check_Id, P.Check_Unavailable,
                        Requirement & " is unavailable or not authorized", Required);
                     return;
                  end if;
               end loop;
               exit;
            end if;
         end loop;
         Discover (Tool, Available);
         if not Available then
            Add_Check
              (Result, Check_Id, P.Check_Unavailable,
               Tool & " is unavailable or not authorized", Required);
            return;
         end if;

         Execute (Request, Command, Tool_Result, Ran, Check_Id);
         if not E.Is_Ok (Ran) or else not Tool_Result.Started then
            Add_Check
              (Result, Check_Id, P.Check_Unavailable,
               "the check could not be started", Required);
         elsif Tool_Result.Cancelled then
            Result.Cancelled := True;
            Add_Check
              (Result, Check_Id, P.Check_Cancelled,
               "the check was cancelled", Required);
         elsif Tool_Result.Timed_Out then
            Result.Timed_Out := True;
            Add_Check
              (Result, Check_Id, P.Check_Timed_Out,
               "the check exceeded its deadline", Required);
         else
            Parse_Output
              (To_String (Tool_Result.Output), To_String (Request.Change_Id),
               Check_Id, Result, Ran);
            if not E.Is_Ok (Ran) then
               Status := Ran;
               return;
            end if;
            Result.Exit_Status := Tool_Result.Exit_Status;
            if D.Length (Result.Diagnostics) > Before then
               Add_Check (Result, Check_Id, P.Check_Findings, Required => Required);
               Result.Files_Analyzed.Append (File);
               Any_Findings := True;
            elsif Tool_Result.Exit_Status = 0 then
               Add_Check (Result, Check_Id, P.Check_Passed, Required => Required);
               Result.Files_Analyzed.Append (File);
            else
               Add_Check
                 (Result, Check_Id, P.Check_Failed,
                  "the analysis process failed without a recognized source diagnostic",
                  Required);
            end if;
         end if;
      end Run_Check;

      procedure Run_Focused_Test (Command, Directory : String) is
         Tool_Result : X.Outcome;
         Ran         : E.Error_Info;
         Required    : constant Boolean := Is_Required ("ada-affected-tests");
         Dependency  : Unbounded_String;
      begin
         if not Prerequisites_Passed ("ada-affected-tests", Dependency) then
            Add_Check
              (Result, "ada-affected-tests", P.Check_Unavailable,
               To_String (Dependency), Required);
            return;
         elsif Request.Runner = null then
            Ran := E.Make (E.Framework_Execution_Refused);
         else
            P.Run
              (Request.Runner.all, Check_Policy (Request, "ada-affected-tests"),
               Command, Directory, Check_Deadline (Request, "ada-affected-tests"),
               Request.Cancel, Tool_Result, Ran);
         end if;
         if not E.Is_Ok (Ran) or else not Tool_Result.Started then
            Add_Check (Result, "ada-affected-tests", P.Check_Unavailable,
                       "the configured test command could not be started", Required);
         elsif Tool_Result.Cancelled then
            Result.Cancelled := True;
            Add_Check
              (Result, "ada-affected-tests", P.Check_Cancelled,
               "the test command was cancelled", Required);
         elsif Tool_Result.Timed_Out then
            Result.Timed_Out := True;
            Add_Check
              (Result, "ada-affected-tests", P.Check_Timed_Out,
               "the test command timed out", Required);
         elsif Tool_Result.Exit_Status = 0 then
            Add_Check
              (Result, "ada-affected-tests", P.Check_Passed,
               Required => Required);
         else
            declare
               Message : constant String := Bounded_Output (To_String (Tool_Result.Output));
               Finding : constant D.Diagnostic :=
                 (Provider    => To_Unbounded_String ("ada"),
                  Check_Id    => To_Unbounded_String ("ada-affected-tests"),
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
            Add_Check
              (Result, "ada-affected-tests", P.Check_Findings,
               Required => Required);
         end if;
      end Run_Focused_Test;

      procedure Run_Analyzer
        (Analyzer : not null Source_Analyzer_Reference;
         Check_Id : String;
         Sources  : String_Lists.Vector)
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
            To_String (Request.Configuration), To_String (Request.Change_Id),
            Check_Deadline (Request, Check_Id), Request.Cancel, Shared, Read);
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
            declare
               Check : P.Check_Result := Shared.Check;
            begin
               Check.Required := Is_Required (Check_Id, Shared.Check.Required);
               Result.Checks.Append (Check);
            end;
            for Index in 1 .. D.Length (Shared.Diagnostics) loop
               declare
                  Finding : D.Diagnostic := D.Element (Shared.Diagnostics, Index);
               begin
                  if Finding.Snapshot /= Request.Change_Id then
                     Status := E.Make (E.Framework_Schema_Violation);
                     E.Add_Text (Status, "name", "diagnostic.snapshot");
                     E.Add_Text (Status, "detail", "the source analyzer returned stale diagnostic data");
                     return;
                  end if;
                  Finding.Check_Id := To_Unbounded_String (Check_Id);
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
            Tool_Versions.Append (Check_Id & ":" & Version (Analyzer.all));
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

      if Requested ("ada-project") and then Request.Level /= Fast then
         if Files_Of (Request, "ada-project", Ada_Project).Is_Empty
           and then
             (not Files_Of
                (Request, "ada-project", Ada_Source, Relevant => True).Is_Empty
              or else not Files_Of
                (Request, "ada-project", Ada_Project, Relevant => True).Is_Empty)
         then
            Add_Check
              (Result, "ada-project", P.Check_Unavailable,
               "dependency-aware validation needs an explicit GPR project mapping");
         end if;
      end if;
      if Requested ("ada-contracts") and then Request.Level /= Fast
        and then Files_Of (Request, "ada-contracts", Ada_Project).Is_Empty
        and then
          (not Files_Of
             (Request, "ada-contracts", Ada_Source, Relevant => True).Is_Empty
           or else not Files_Of
             (Request, "ada-contracts", Ada_Project, Relevant => True).Is_Empty)
      then
         Add_Check
           (Result, "ada-contracts", P.Check_Unavailable,
            "contract validation needs an explicit GPR project mapping",
            Is_Required ("ada-contracts", False));
      end if;

      if Requested ("ada-syntax")
        and then not Files_Of (Request, "ada-syntax", Ada_Source).Is_Empty
        and then Length (Request.Analysis_Root) = 0
      then
         Add_Check
           (Result, "ada-syntax", P.Check_Failed,
            "syntax analysis requires a disposable analysis directory",
            Is_Required ("ada-syntax"));
      end if;
      if Requested ("ada-syntax") then
         for Path of Files_Of (Request, "ada-syntax", Ada_Source) loop
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
                  Add_Check
                    (Result, "ada-syntax", P.Check_Failed,
                     "an analysis path contains an unsupported quote",
                     Is_Required ("ada-syntax"));
               else
                  Run_Check ("ada-syntax", "gnatmake", Command, Path);
               end if;
            end;
            exit when not E.Is_Ok (Status);
         end loop;
      end if;

      if Requested ("ada-project") then
         for Path of Files_Of (Request, "ada-project", Ada_Project) loop
            if Quote (Path) = "" then
               Add_Check
                 (Result, "ada-project", P.Check_Failed,
                  "a project path contains an unsupported quote",
                  Is_Required ("ada-project"));
            else
               Run_Check
                 ("ada-project", "gprbuild",
                  "gprbuild -P " & Quote (Path) & " --subdirs=code_health -c -u -gnatc", Path);
            end if;
            exit when not E.Is_Ok (Status);
         end loop;
      end if;

      if Requested ("ada-contracts") and then Request.Level /= Fast then
         for Path of Files_Of (Request, "ada-contracts", Ada_Project) loop
            if Quote (Path) = "" then
               Add_Check
                 (Result, "ada-contracts", P.Check_Failed,
                  "a project path contains an unsupported quote",
                  Is_Required ("ada-contracts", False));
            else
               Run_Check
                 ("ada-contracts", "gnatprove",
                  "gnatprove -P " & Quote (Path)
                  & " --mode=check --subdirs=code_health_proof", Path);
            end if;
            exit when not E.Is_Ok (Status);
         end loop;
      end if;

      if Requested ("ada-manifest") then
         declare
            Live : constant String_Lists.Vector :=
              Files_Of (Request, "ada-manifest", Ada_Manifest);
            Relevant : constant String_Lists.Vector :=
              Files_Of
                (Request, "ada-manifest", Ada_Manifest, Relevant => True);
         begin
            if Live.Is_Empty then
               --  alr show validates the project rooted by the runner; the
               --  deleted name is evidence, not a path supplied to alr.
               if not Relevant.Is_Empty then
                  Run_Check
                    ("ada-manifest", "alr", "alr show",
                     Relevant.First_Element);
               end if;
            else
               for Path of Live loop
                  Run_Check ("ada-manifest", "alr", "alr show", Path);
                  exit when not E.Is_Ok (Status);
               end loop;
            end if;
         end;
      end if;
      if not E.Is_Ok (Status) then
         return;
      end if;

      if Requested ("ada-affected-tests")
        and then Request.Level /= Fast
        and then not Files_Of
          (Request, "ada-affected-tests", Ada_Source, Relevant => True).Is_Empty
      then
         if not Request.Affected_Tests.Is_Empty then
            for Index in Request.Affected_Tests.First_Index .. Request.Affected_Tests.Last_Index loop
               Run_Focused_Test
                 (Request.Affected_Tests (Index),
                  (if Index <= Request.Affected_Test_Directories.Last_Index
                   then Request.Affected_Test_Directories (Index) else ""));
               exit when not E.Is_Ok (Status);
            end loop;
         elsif Length (Request.Fallback_Test) > 0 then
            Run_Focused_Test (To_String (Request.Fallback_Test), "");
         else
            Add_Check
              (Result, "ada-affected-tests", P.Check_Unavailable,
               "no reliable affected-test mapping or fallback test scope is configured",
               Is_Required ("ada-affected-tests"));
         end if;
      end if;
      if not E.Is_Ok (Status) then
         return;
      end if;

      if not Files_Of (Request, "ada-quality-source", Ada_Source).Is_Empty
        or else not Files_Of (Request, "ada-language-server", Ada_Source).Is_Empty
      then
         if Requested ("ada-quality-source")
           and then not Files_Of (Request, "ada-quality-source", Ada_Source).Is_Empty
           and then Self.Source_Checker = null
         then
            Add_Check
              (Result, "ada-quality-source", P.Check_Unavailable,
               "change-scoped ada_quality adapter is not linked",
               Required => Is_Required ("ada-quality-source"));
         elsif Requested ("ada-quality-source")
           and then not Files_Of (Request, "ada-quality-source", Ada_Source).Is_Empty
         then
            Run_Analyzer
              (Self.Source_Checker, "ada-quality-source",
               Files_Of (Request, "ada-quality-source", Ada_Source));
         end if;
         if E.Is_Ok (Status)
           and then Requested ("ada-language-server")
           and then not Files_Of (Request, "ada-language-server", Ada_Source).Is_Empty
           and then Self.Language_Checker /= null
         then
            Run_Analyzer
              (Self.Language_Checker, "ada-language-server",
               Files_Of (Request, "ada-language-server", Ada_Source));
         elsif E.Is_Ok (Status)
           and then not Request.Checks.Is_Empty
           and then Requested ("ada-language-server")
           and then not Files_Of (Request, "ada-language-server", Ada_Source).Is_Empty
         then
            Add_Check
              (Result, "ada-language-server", P.Check_Unavailable,
               "no language-server diagnostic source is configured",
               Is_Required ("ada-language-server", False));
         end if;
      end if;

      if Result.Checks.Is_Empty then
         Add_Check
           (Result, "ada-applicability", P.Check_Passed,
            "no selected Ada check applies to the changed inputs",
            Required => False);
      end if;

      --  Change_Id identifies the immutable logical snapshot supplied by
      --  the harness.  A provider-specific hash here would make otherwise
      --  current evidence incomparable with that snapshot.
      Result.Input_Fingerprint := Request.Change_Id;
      Result.Configuration_Fingerprint :=
        To_Unbounded_String (Configuration_Fingerprint (Request));
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
