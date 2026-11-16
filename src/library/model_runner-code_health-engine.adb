with Ada.Directories;
with Ada.Real_Time;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Evidence;
with Model_Runner.Code_Health.Feedback;
with Model_Runner.Framework.Records;
package body Model_Runner.Code_Health.Engine is

   use Standard.Ada.Strings.Unbounded;
   use type Standard.Ada.Real_Time.Time;
   use type Model_Runner.Code_Health.Providers.Command_Runner_Reference;
   use type Model_Runner.Code_Health.Providers.Provider_Reference;
   use type Model_Runner.Code_Health.Execution.Store_Reference;
   use type Model_Runner.Code_Health.Changes.Change_Kind;
   use type Model_Runner.Code_Health.Providers.Check_Status;
   use type Model_Runner.Code_Health.Providers.Scope_Kind;
   use type Model_Runner.Code_Health.Baselines.Finding_State;

   package B renames Model_Runner.Code_Health.Baselines;
   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package Ev renames Model_Runner.Code_Health.Evidence;
   package F renames Model_Runner.Code_Health.Feedback;
   package P renames Model_Runner.Code_Health.Providers;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package X renames Model_Runner.Framework.Execution;

   function Image (Value : Natural) return String is
     (Standard.Ada.Strings.Fixed.Trim (Natural'Image (Value), Standard.Ada.Strings.Both));

   function Results_Fingerprint
     (Kind    : String;
      Results : Ev.Analysis_Result_Lists.Vector) return String
   is
      Meaning : R.Item := R.Create ("code_health." & Kind, 1, "PROVIDERS", 1);
   begin
      for Index in 1 .. Natural (Results.Length) loop
         declare
            One : constant P.Analysis_Result := Results.Element (Index);
            Key : constant String := "provider." & R.Numbered (Index, Natural (Results.Length));
         begin
            R.Set (Meaning, Key & ".id", To_String (One.Provider_Id));
            R.Set (Meaning, Key & ".version", To_String (One.Provider_Version));
            R.Set
              (Meaning, Key & ".fingerprint",
               (if Kind = "toolchain" then To_String (One.Toolchain_Fingerprint)
                else To_String (One.Environment_Fingerprint)));
         end;
      end loop;
      return R.Fingerprint_Of (Meaning);
   end Results_Fingerprint;

   procedure Analyze_All
     (Self        : in out Instance;
      Request     : P.Analysis_Request;
      Results     : out Ev.Analysis_Result_Lists.Vector;
      Combined    : out P.Analysis_Result;
      Operational : out E.Error_Info;
      Status      : out E.Error_Info)
   is
   begin
      Results.Clear;
      Combined := (others => <>);
      Operational := E.Success;
      Status := E.Success;
      for Provider of Self.Providers loop
         declare
            Provider_Id : constant String := P.Identifier (Provider.all);
            One_Request : P.Analysis_Request := Request;
            One_Result  : P.Analysis_Result;
            Ran         : E.Error_Info;
            Applicable  : Boolean := False;
         begin
            One_Request.Changed_Files.Clear;
            One_Request.Removed_Files.Clear;
            One_Request.Checks.Clear;
            for Path of Request.Changed_Files loop
               if P.Supports (Provider.all, Path, Request.Level) then
                  One_Request.Changed_Files.Append (Path);
                  Applicable := True;
               end if;
            end loop;
            for Path of Request.Removed_Files loop
               if P.Supports (Provider.all, Path, Request.Level) then
                  One_Request.Removed_Files.Append (Path);
                  Applicable := True;
               end if;
            end loop;
            for Check of Request.Checks loop
               if Length (Check.Provider) = 0 or else To_String (Check.Provider) = Provider_Id then
                  One_Request.Checks.Append (Check);
                  if Check.Scope = P.Dependency_Scope then
                     for Path of Request.Dependencies loop
                        Applicable := Applicable
                          or else P.Supports (Provider.all, Path, Request.Level);
                     end loop;
                  elsif Check.Scope = P.Whole_Project then
                     for Path of Request.Project_Files loop
                        Applicable := Applicable
                          or else P.Supports (Provider.all, Path, Request.Level);
                     end loop;
                  end if;
               end if;
            end loop;
            if Applicable
              and then (Request.Checks.Is_Empty or else not One_Request.Checks.Is_Empty)
            then
               P.Analyze_Safely (Provider.all, One_Request, One_Result, Ran);
               if E.Is_Error (Ran) and then One_Result.Checks.Is_Empty then
                  Status := Ran;
                  return;
               end if;
               if E.Is_Error (Ran) and then E.Is_Ok (Operational) then
                  Operational := Ran;
               end if;
               Results.Append (One_Result);
            end if;
         end;
      end loop;

      if Results.Is_Empty then
         Combined.Provider_Id := To_Unbounded_String ("code-health");
         Combined.Provider_Version := To_Unbounded_String ("1.0.0");
         Combined.Input_Fingerprint := Request.Change_Id;
         Combined.Configuration_Fingerprint := Request.Configuration;
         Combined.Toolchain_Fingerprint := To_Unbounded_String ("not-applicable");
         Combined.Environment_Fingerprint := To_Unbounded_String ("not-applicable");
         Combined.Checks.Append
           (P.Check_Result'
              (Identifier => To_Unbounded_String ("provider-applicability"),
               Status     => P.Check_Passed,
               Required   => False,
               Detail     => To_Unbounded_String ("no registered provider applies to these inputs"),
               Evidence   => Null_Unbounded_String));
         Results.Append (Combined);
         return;
      end if;

      Combined.Provider_Id :=
        (if Natural (Results.Length) = 1 then Results.First_Element.Provider_Id
         else To_Unbounded_String ("code-health"));
      Combined.Provider_Version :=
        (if Natural (Results.Length) = 1 then Results.First_Element.Provider_Version
         else To_Unbounded_String ("1.0.0"));
      Combined.Input_Fingerprint := Request.Change_Id;
      Combined.Configuration_Fingerprint := Request.Configuration;
      Combined.Toolchain_Fingerprint :=
        (if Natural (Results.Length) = 1 then Results.First_Element.Toolchain_Fingerprint
         else To_Unbounded_String (Results_Fingerprint ("toolchain", Results)));
      Combined.Environment_Fingerprint :=
        (if Natural (Results.Length) = 1 then Results.First_Element.Environment_Fingerprint
         else To_Unbounded_String (Results_Fingerprint ("environment", Results)));
      for One of Results loop
         Combined.Timed_Out := Combined.Timed_Out or else One.Timed_Out;
         Combined.Cancelled := Combined.Cancelled or else One.Cancelled;
         Combined.Duration := Combined.Duration + One.Duration;
         for Check of One.Checks loop
            Combined.Checks.Append (Check);
         end loop;
         for Path of One.Files_Analyzed loop
            if not Combined.Files_Analyzed.Contains (Path) then
               Combined.Files_Analyzed.Append (Path);
            end if;
         end loop;
         for Index in 1 .. D.Length (One.Diagnostics) loop
            D.Append_Validated
              (Combined.Diagnostics, D.Element (One.Diagnostics, Index), Status,
               To_String (Request.Project_Root));
            if E.Is_Error (Status) then
               return;
            end if;
         end loop;
      end loop;
      Status := E.Success;
   end Analyze_All;

   procedure Initialize
     (Self          : in out Instance;
      Project       : String;
      Status        : out E.Error_Info;
      Store         : Model_Runner.Code_Health.Execution.Store_Reference := null;
      Provider      : P.Provider_Reference := null;
      Runner        : P.Command_Runner_Reference := null;
      Execution_Policy : X.Policy := (others => <>);
      Cancel        : Model_Runner.Cancellation.Token_Reference := null;
      Agent_Id      : String := "";
      Invocation_Id : String := "";
      Enabled       : Boolean := True;
      Profile       : String := "ada-fast";
      Focused_Profile : String := "ada-focused";
      Configuration : String := "code-health/default";
      Block_On      : Diagnostic_Severity := Error;
      Deadline      : Positive := 10;
      Focused_Deadline : Positive := 120;
      Fallback_Test : String := "";
      Feedback_Limit : Positive := 8 * 1024)
   is
      Analysis_Root : constant String := Hostkit.Fs.Join (Project, "obj/code_health");
   begin
      Self.Active := False;
      Self.Project := To_Unbounded_String (Standard.Ada.Directories.Full_Name (Project));
      Self.Profile := To_Unbounded_String (Profile);
      Self.Focused_Profile := To_Unbounded_String (Focused_Profile);
      Self.Configuration := To_Unbounded_String (Configuration);
      Self.Threshold := Block_On;
      Self.Deadline := Deadline;
      Self.Focused_Deadline := Focused_Deadline;
      Self.Fallback_Test := To_Unbounded_String (Fallback_Test);
      Self.Focused_Tests.Clear;
      Self.Focused_Test_Directories.Clear;
      Self.Fast_Checks.Clear;
      Self.Focused_Checks.Clear;
      Self.Policy := Execution_Policy;
      Self.Cancel := Cancel;
      Self.Agent_Id := To_Unbounded_String (Agent_Id);
      Self.Invocation_Id := To_Unbounded_String (Invocation_Id);
      Self.Feedback_Limit := Feedback_Limit;
      Self.Sequence := 0;
      Self.Summary := Null_Unbounded_String;
      Self.Has_Assessment := False;
      Self.Latest := (others => <>);
      Self.Latest_Level := Fast;
      B.Clear (Self.Latest_Classifications);
      Model_Runner.Code_Health.Changes.Clear (Self.Pending);
      Self.Pending_Event := (others => <>);
      Self.Has_Pending := False;
      Self.Has_Baseline := False;
      Self.Has_Baseline_Tree := False;
      Self.Baseline_Event := (others => <>);
      Self.Store := Store;
      Self.Runner := Runner;
      Self.Providers.Clear;
      Model_Runner.Code_Health.Ada.Initialize
        (Self.Native, Self.Quality'Unchecked_Access, Self.Language'Unchecked_Access);
      Self.Provider :=
        (if Provider = null then Self.Native'Unchecked_Access else Provider);
      Self.Providers.Append (Self.Provider);

      if not Enabled then
         Status := E.Success;
         return;
      end if;
      if not Standard.Ada.Directories.Exists (Analysis_Root) then
         Standard.Ada.Directories.Create_Path (Analysis_Root);
      end if;
      if Store /= null and then Runner = null then
         declare
            Main : constant String :=
              Standard.Ada.Directories.Containing_Directory (S.Root (Store.all));
            Base : constant String :=
              (if Standard.Ada.Directories.Full_Name (Project)
                    = Standard.Ada.Directories.Full_Name (Main)
               then "" else Standard.Ada.Directories.Full_Name (Project));
         begin
            Model_Runner.Code_Health.Execution.Initialize
              (Self.Framework, Store, Self.Change'Unchecked_Access, Status, Base);
         end;
         if E.Is_Error (Status) then
            return;
         end if;
         Self.Runner := Self.Framework'Unchecked_Access;
      elsif Store = null and then Runner = null then
         Model_Runner.Code_Health.Execution.Initialize
           (Self.Standalone, Project, Execution_Policy);
         Self.Runner := Self.Standalone'Unchecked_Access;
      end if;
      Self.Active := True;
      Status := E.Success;
   exception
      when Failure : others =>
         Status := E.Unexpected (Failure, "initializing Code Health");
   end Initialize;

   procedure Disable (Self : in out Instance) is
   begin
      Self.Active := False;
   end Disable;

   function Enabled (Self : Instance) return Boolean is (Self.Active);

   procedure Use_Language_Server
     (Self   : in out Instance;
      Source : Model_Runner.Code_Health.Ada_LSP_Adapter.Problem_Source) is
   begin
      Model_Runner.Code_Health.Ada_LSP_Adapter.Use_Source (Self.Language, Source);
   end Use_Language_Server;

   procedure Add_Focused_Test
     (Self      : in out Instance;
      Command   : String;
      Directory : String := "") is
   begin
      Self.Focused_Tests.Append (Command);
      Self.Focused_Test_Directories.Append (Directory);
   end Add_Focused_Test;

   procedure Use_Profiles
     (Self    : in out Instance;
      Defined : Model_Runner.Code_Health.Profiles.Profile_Set;
      Status  : out E.Error_Info) is
   begin
      Model_Runner.Code_Health.Profiles.Select_Checks
        (Defined, To_String (Self.Profile), Fast, Self.Fast_Checks, Status);
      if E.Is_Ok (Status) then
         Model_Runner.Code_Health.Profiles.Select_Checks
           (Defined, To_String (Self.Focused_Profile), Focused,
            Self.Focused_Checks, Status);
      end if;
   end Use_Profiles;

   procedure Use_Checks
     (Self   : in out Instance;
      Level  : Check_Level;
      Checks : P.Requested_Check_Lists.Vector) is
   begin
      if Level = Fast then
         Self.Fast_Checks := Checks;
      elsif Level = Focused then
         Self.Focused_Checks := Checks;
      end if;
   end Use_Checks;

   procedure Add_Provider
     (Self     : in out Instance;
      Provider : not null P.Provider_Reference;
      Status   : out E.Error_Info) is
   begin
      if not P.Valid_Identifier (P.Identifier (Provider.all))
        or else not P.Valid_Version (P.Version (Provider.all))
      then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", P.Identifier (Provider.all));
         E.Add_Text (Status, "detail", "invalid Code Health provider identity or version");
         return;
      end if;
      for Existing of Self.Providers loop
         if P.Identifier (Existing.all) = P.Identifier (Provider.all) then
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", P.Identifier (Provider.all));
            E.Add_Text (Status, "detail", "duplicate Code Health provider identifier");
            return;
         end if;
      end loop;
      Self.Providers.Append (Provider);
      declare
         function Less (Left, Right : P.Provider_Reference) return Boolean is
           (P.Identifier (Left.all) < P.Identifier (Right.all));
         package Sorting is new Provider_Lists.Generic_Sorting (Less);
      begin
         Sorting.Sort (Self.Providers);
      end;
      Status := E.Success;
   end Add_Provider;

   procedure Capture_Baseline
     (Self       : in out Instance;
      Status     : out E.Error_Info;
      Task_Id    : String := "";
      Generation : Natural := 0;
      Workspace  : String := "")
   is
      Tree    : Model_Runner.Code_Health.Changes.Snapshot;
      After   : Model_Runner.Code_Health.Changes.Snapshot;
      Request : P.Analysis_Request;
      Result  : P.Analysis_Result;
      Results : Ev.Analysis_Result_Lists.Vector;
      Ran     : E.Error_Info;
      Stale   : Boolean := False;
   begin
      Self.Has_Baseline := False;
      Status := E.Success;
      if not Self.Active then
         return;
      end if;
      Model_Runner.Code_Health.Changes.Capture
        (To_String (Self.Project), Tree, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Self.Baseline_Tree := Tree;
      Self.Has_Baseline_Tree := True;
      Self.Baseline_Event.Task_Id := To_Unbounded_String (Task_Id);
      Self.Baseline_Event.Generation := Generation;
      Self.Baseline_Event.Workspace_Id := To_Unbounded_String (Workspace);
      Request.Project_Root := Self.Project;
      Request.Analysis_Root :=
        To_Unbounded_String (Hostkit.Fs.Join (To_String (Self.Project), "obj/code_health"));
      Request.Change_Id := To_Unbounded_String
        (Model_Runner.Code_Health.Changes.Identifier (Tree));
      Request.Level := Fast;
      Request.Checks := Self.Fast_Checks;
      Request.Configuration := Self.Configuration;
      Request.Started := Standard.Ada.Real_Time.Clock;
      Request.Deadline :=
        Request.Started + Standard.Ada.Real_Time.Seconds (Self.Deadline);
      Request.Runner := Self.Runner;
      Request.Cancel := Self.Cancel;
      Request.Execution_Policy := Self.Policy;
      Request.Fallback_Test := Self.Fallback_Test;
      Request.Affected_Tests := Self.Focused_Tests;
      Request.Affected_Test_Directories := Self.Focused_Test_Directories;
      Request.Task_Id := To_Unbounded_String (Task_Id);
      Request.Generation := Generation;
      Request.Environment := To_Unbounded_String ("native Ada Code Health dispatcher 1");
      if Self.Store /= null then
         Request.Execution_Policy := X.Policy_Of (Self.Store.all);
      end if;
      for Index in 1 .. Model_Runner.Code_Health.Changes.File_Count (Tree) loop
         declare
            Path : constant String := Model_Runner.Code_Health.Changes.File_At (Tree, Index);
         begin
            Request.Changed_Files.Append (Path);
            Request.Project_Files.Append (Path);
         end;
      end loop;
      if Request.Changed_Files.Is_Empty then
         return;
      end if;
      Analyze_All (Self, Request, Results, Result, Ran, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Model_Runner.Code_Health.Changes.Capture
        (To_String (Self.Project), After, Status);
      if E.Is_Error (Status) then
         return;
      elsif Model_Runner.Code_Health.Changes.Identifier (After)
        /= Model_Runner.Code_Health.Changes.Identifier (Tree)
      then
         Status := E.Make (E.Framework_Contract_Violation);
         E.Add_Text (Status, "detail", "project source changed while capturing its Code Health baseline");
         return;
      end if;
      if Self.Store /= null and then Self.Runner = Self.Framework'Unchecked_Access then
         Model_Runner.Code_Health.Execution.Verify_Unchanged
           (Self.Framework, Stale, Status);
         if E.Is_Error (Status) or else Stale then
            return;
         end if;
      end if;
      declare
         Context : constant B.Comparison_Context :=
           (Snapshot                => Request.Change_Id,
            Policy_Fingerprint      => Self.Configuration,
            Provider_Fingerprint    => To_Unbounded_String
              (To_String (Result.Provider_Id) & ":" & To_String (Result.Provider_Version)),
            Toolchain_Fingerprint   =>
              (if Result.Toolchain_Fingerprint = Null_Unbounded_String
               then To_Unbounded_String ("unreported") else Result.Toolchain_Fingerprint),
            Environment_Fingerprint =>
              (if Result.Environment_Fingerprint = Null_Unbounded_String
               then To_Unbounded_String ("unreported") else Result.Environment_Fingerprint),
            Scope                   => To_Unbounded_String ("project"),
            Task_Id                 => To_Unbounded_String (Task_Id),
            Generation              => Generation,
            Workspace               => To_Unbounded_String (Workspace));
      begin
         B.Create (Context, Result.Diagnostics, Self.Baseline, Status);
      end;
      if E.Is_Error (Status) then
         return;
      end if;
      if Self.Store /= null then
         B.Keep (Self.Store.all, Self.Change, Self.Baseline, Status);
         if E.Is_Ok (Status) then
            S.Commit (Self.Store.all, Self.Change, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;
      end if;
      Self.Has_Baseline := True;
      Status := E.Success;
   exception
      when Failure : others =>
         Self.Has_Baseline := False;
         Status := E.Unexpected (Failure, "capturing the Code Health baseline");
   end Capture_Baseline;

   function Last_Summary (Self : Instance) return String is
     (To_String (Self.Summary));

   overriding procedure Dispatch
     (Self     : in out Instance;
      Event    : Model_Runner.Code_Health.Hooks.Change_Event;
      Changed  : Model_Runner.Code_Health.Changes.Change_Set;
      Feedback : out Unbounded_String;
      Status   : out E.Error_Info)
   is
      Request         : P.Analysis_Request;
      Provider_Result : P.Analysis_Result;
      Results         : Ev.Analysis_Result_Lists.Vector;
      Classifications : B.Classification_List;
      Scope_Files     : String_Lists.Vector;
      State           : Health_State := Passed;
      Required_Failed : Boolean := False;
      Cancelled_Check : Boolean := False;
      Stale_Check     : Boolean := False;
      Blockers        : Natural := 0;
      Warnings        : Natural := 0;
      Existing        : Natural := 0;
      Resolved        : Natural := 0;
      Unknown         : Natural := 0;
      Checks_Passed   : Natural := 0;
      Checks_Failed   : Natural := 0;
      Guard_Stale     : Boolean := False;
      Guard_Status    : E.Error_Info;
      Assessment_Id   : Unbounded_String;
      Cache_Key       : Unbounded_String;
      Reusable_Id     : Unbounded_String;
      Cache_Probe     : P.Cache_Probe;
      Probe_Status    : E.Error_Info;
      Reused          : Boolean := False;
      Analyzed_Tree   : Model_Runner.Code_Health.Changes.Snapshot;
      Published_Tree  : Model_Runner.Code_Health.Changes.Snapshot;
      Prior_Classifications : constant B.Classification_List := Self.Latest_Classifications;
      Level           : constant Check_Level :=
        (if Event.Trigger = Before_Agent_Answer then Focused else Fast);
      Profile         : constant Unbounded_String :=
        (if Level = Focused then Self.Focused_Profile else Self.Profile);

      function Cache_Check_Identity return String is
         Items : String_Lists.Vector;
         package Sorting is new String_Lists.Generic_Sorting;
      begin
         Items.Append ("level:" & Check_Level'Image (Request.Level));
         if Request.Checks.Is_Empty then
            Items.Append ("check:provider-level-defaults");
         else
            for Check of Request.Checks loop
               Items.Append
                 ("check:" & To_String (Check.Identifier)
                  & (if Check.Required then ":required" else ":optional")
                  & ":block=" & Diagnostic_Severity'Image (Check.Block_On)
                  & ":scope=" & P.Scope_Kind'Image (Check.Scope)
                  & ":timeout=" & Image (Check.Timeout_Seconds)
                  & ":output=" & Image (Check.Output_Limit)
                  & (if Check.Cacheable then ":cache" else ":no-cache"));
               for Dependency of Check.Dependencies loop
                  Items.Append
                    ("check:" & To_String (Check.Identifier) & ":dependency:" & Dependency);
               end loop;
               for Tool of Check.Tool_Requirements loop
                  Items.Append
                    ("check:" & To_String (Check.Identifier) & ":tool:" & Tool);
               end loop;
            end loop;
         end if;
         for Path of Request.Changed_Files loop
            Items.Append ("changed:" & Path);
         end loop;
         for Path of Request.Removed_Files loop
            Items.Append ("removed:" & Path);
         end loop;
         for Path of Request.Dependencies loop
            Items.Append ("dependency:" & Path);
         end loop;
         Sorting.Sort (Items);
         declare
            Result : Unbounded_String;
         begin
            for Item of Items loop
               Append (Result, (if Length (Result) = 0 then "" else ",") & Item);
            end loop;
            return To_String (Result);
         end;
      end Cache_Check_Identity;

      procedure Operational_Check (Kind : P.Check_Status; Detail : String) is
         Check : constant P.Check_Result :=
           (Identifier => To_Unbounded_String ("source-snapshot"),
            Status     => Kind,
            Required   => True,
            Detail     => To_Unbounded_String (Detail),
            Evidence   => Null_Unbounded_String);
      begin
         Provider_Result.Checks.Append (Check);
         if not Results.Is_Empty then
            declare
               First : P.Analysis_Result := Results.First_Element;
            begin
               First.Checks.Append (Check);
               Results.Replace_Element (Results.First_Index, First);
            end;
         end if;
      end Operational_Check;
   begin
      Feedback := Null_Unbounded_String;
      Status := E.Success;
      if not Self.Active or else Model_Runner.Code_Health.Changes.Length (Changed) = 0 then
         return;
      end if;

      if Level = Fast then
         for Index in 1 .. Model_Runner.Code_Health.Changes.Length (Changed) loop
            Model_Runner.Code_Health.Changes.Record_Change
              (Self.Pending, Model_Runner.Code_Health.Changes.Element (Changed, Index));
         end loop;
         Model_Runner.Code_Health.Changes.Normalize (Self.Pending);
         Self.Pending_Event := Event;
         Self.Has_Pending := True;
      end if;

      Self.Sequence := Self.Sequence + 1;
      Request.Project_Root := Self.Project;
      Request.Analysis_Root :=
        To_Unbounded_String (Hostkit.Fs.Join (To_String (Self.Project), "obj/code_health"));
      Request.Change_Id := Event.Change_Id;
      Request.Level := Level;
      Request.Checks :=
        (if Level = Focused then Self.Focused_Checks else Self.Fast_Checks);
      Request.Configuration := Self.Configuration;
      Request.Started := Standard.Ada.Real_Time.Clock;
      Request.Deadline :=
        Request.Started
        + Standard.Ada.Real_Time.Seconds
            (if Level = Focused then Self.Focused_Deadline else Self.Deadline);
      Request.Runner := Self.Runner;
      Request.Cancel := Self.Cancel;
      Request.Execution_Policy := Self.Policy;
      Request.Fallback_Test := Self.Fallback_Test;
      Request.Affected_Tests := Self.Focused_Tests;
      Request.Affected_Test_Directories := Self.Focused_Test_Directories;
      Request.Task_Id := Event.Task_Id;
      Request.Generation := Event.Generation;
      Request.Environment := To_Unbounded_String ("native Ada Code Health dispatcher 1");
      if Self.Store /= null then
         Request.Execution_Policy := X.Policy_Of (Self.Store.all);
         if Self.Runner = Self.Framework'Unchecked_Access then
            Model_Runner.Code_Health.Execution.Rebind_Source (Self.Framework, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
      end if;
      for Index in 1 .. Model_Runner.Code_Health.Changes.Length (Changed) loop
         declare
            Item : constant Model_Runner.Code_Health.Changes.File_Change :=
              Model_Runner.Code_Health.Changes.Element (Changed, Index);
         begin
            if Item.Kind = Model_Runner.Code_Health.Changes.Deleted then
               Request.Removed_Files.Append (To_String (Item.Path));
            else
               Request.Changed_Files.Append (To_String (Item.Path));
               if Item.Kind = Model_Runner.Code_Health.Changes.Renamed
                 and then Length (Item.Old_Path) > 0
                 and then not Request.Removed_Files.Contains
                   (To_String (Item.Old_Path))
               then
                  --  A rename is a creation at its new language boundary and
                  --  a removal at its old one.  Providers must see both when
                  --  an extension change moves the file out of their scope.
                  Request.Removed_Files.Append (To_String (Item.Old_Path));
               end if;
            end if;
            if Length (Item.Path) > 0 and then not Scope_Files.Contains (To_String (Item.Path)) then
               Scope_Files.Append (To_String (Item.Path));
            end if;
            if Length (Item.Old_Path) > 0
              and then not Scope_Files.Contains (To_String (Item.Old_Path))
            then
               Scope_Files.Append (To_String (Item.Old_Path));
            end if;
         end;
      end loop;

      Model_Runner.Code_Health.Changes.Capture
        (To_String (Self.Project), Analyzed_Tree, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Request.Change_Id := To_Unbounded_String
        (Model_Runner.Code_Health.Changes.Identifier (Analyzed_Tree));
      for Index in 1 .. Model_Runner.Code_Health.Changes.File_Count (Analyzed_Tree) loop
         Request.Project_Files.Append
           (Model_Runner.Code_Health.Changes.File_At (Analyzed_Tree, Index));
      end loop;
      if Level = Focused then
         for Index in 1 .. Model_Runner.Code_Health.Changes.File_Count (Analyzed_Tree) loop
            declare
               Path : constant String :=
                 Model_Runner.Code_Health.Changes.File_At (Analyzed_Tree, Index);
            begin
               if Path'Length >= 4 and then Path (Path'Last - 3 .. Path'Last) = ".gpr" then
                  Request.Dependencies.Append (Path);
               end if;
            end;
         end loop;
      end if;
      for Check of Request.Checks loop
         case Check.Scope is
            when P.Changed_Files =>
               null;
            when P.Dependency_Scope =>
               for Path of Request.Dependencies loop
                  if not Scope_Files.Contains (Path) then
                     Scope_Files.Append (Path);
                  end if;
               end loop;
            when P.Whole_Project =>
               for Path of Request.Project_Files loop
                  if not Scope_Files.Contains (Path) then
                     Scope_Files.Append (Path);
                  end if;
               end loop;
         end case;
      end loop;

      if Self.Store /= null
        and then Natural (Self.Providers.Length) = 1
        and then Self.Provider.all in P.Cache_Aware_Provider'Class
      then
         P.Probe_Cache_Safely
           (P.Cache_Aware_Provider'Class (Self.Provider.all), Request,
            Cache_Probe, Probe_Status);
         if E.Is_Ok (Probe_Status) and then Cache_Probe.Reusable then
            Cache_Key := To_Unbounded_String
              (Ev.Make_Cache_Key
                 (P.Identifier (Self.Provider.all), P.Version (Self.Provider.all),
                  Cache_Check_Identity, To_String (Request.Change_Id),
                  To_String (Cache_Probe.Configuration_Fingerprint),
                  To_String (Cache_Probe.Toolchain_Fingerprint),
                  To_String (Cache_Probe.Environment_Fingerprint)));
            declare
               Current : constant Ev.Assessment_Context :=
                 (Project                   => Self.Project,
                  Task_Id                   => Event.Task_Id,
                  Generation                => Event.Generation,
                  Agent_Id                  => Self.Agent_Id,
                  Invocation_Id             => Self.Invocation_Id,
                  Workspace                 => Event.Workspace_Id,
                  Snapshot                  => Request.Change_Id,
                  Configuration_Fingerprint => Cache_Probe.Configuration_Fingerprint,
                  Toolchain_Fingerprint     => Cache_Probe.Toolchain_Fingerprint,
                  Environment_Fingerprint   => Cache_Probe.Environment_Fingerprint,
                  Profile                   => Profile);
            begin
               Reusable_Id := To_Unbounded_String
                 (Ev.Find_Reusable (Self.Store.all, To_String (Cache_Key), Current));
            end;
            if Length (Reusable_Id) > 0 then
               declare
                  Cached : Ev.Assessment;
               begin
                  Ev.Read (Self.Store.all, To_String (Reusable_Id), Cached, Probe_Status);
                  if E.Is_Ok (Probe_Status)
                    and then Ev.Level_Of (Cached) = Level
                    and then Natural (Ev.Results_Of (Cached).Length) = 1
                  then
                     Provider_Result := Ev.Results_Of (Cached).First_Element;
                     Results := Ev.Results_Of (Cached);
                     Classifications := Ev.Classifications_Of (Cached);
                     Assessment_Id := Reusable_Id;
                     Reused := True;
                  end if;
               end;
            end if;
         end if;
      end if;
      if not Reused then
         Analyze_All
           (Self, Request, Results, Provider_Result, Guard_Status, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         if Length (Cache_Key) > 0
           and then (Provider_Result.Configuration_Fingerprint
                       /= Cache_Probe.Configuration_Fingerprint
                     or else Provider_Result.Toolchain_Fingerprint
                       /= Cache_Probe.Toolchain_Fingerprint
                     or else Provider_Result.Environment_Fingerprint
                       /= Cache_Probe.Environment_Fingerprint)
         then
            Cache_Key := Null_Unbounded_String;
         end if;
      else
         Guard_Status := E.Success;
      end if;
      Model_Runner.Code_Health.Changes.Capture
        (To_String (Self.Project), Published_Tree, Status);
      if E.Is_Error (Status) then
         return;
      elsif Model_Runner.Code_Health.Changes.Identifier (Published_Tree)
        /= Model_Runner.Code_Health.Changes.Identifier (Analyzed_Tree)
      then
         Operational_Check (P.Check_Stale, "source changed while the assessment was running");
      end if;
      if Self.Store /= null and then Self.Runner = Self.Framework'Unchecked_Access then
         Model_Runner.Code_Health.Execution.Verify_Unchanged
           (Self.Framework, Guard_Stale, Status);
         if Guard_Stale then
            Operational_Check (P.Check_Stale, "source changed before the assessment could be published");
         elsif E.Is_Error (Status) then
            return;
         end if;
      end if;
      if E.Is_Error (Guard_Status) and then Provider_Result.Checks.Is_Empty then
         Status := Guard_Status;
         return;
      end if;

      for Check of Provider_Result.Checks loop
         if Check.Status in P.Check_Passed | P.Check_Findings then
            Checks_Passed := Checks_Passed + 1;
         else
            Checks_Failed := Checks_Failed + 1;
         end if;
         if Check.Required then
            Required_Failed := Required_Failed
              or else Check.Status in
                P.Check_Not_Run | P.Check_Unavailable | P.Check_Timed_Out | P.Check_Failed;
            Cancelled_Check := Cancelled_Check or else Check.Status = P.Check_Cancelled;
            Stale_Check := Stale_Check or else Check.Status = P.Check_Stale;
         end if;
      end loop;
      if not Reused then
         declare
            Scope : Unbounded_String;
         begin
            for Path of Scope_Files loop
               Append (Scope, (if Length (Scope) = 0 then "" else [1 => ASCII.LF]) & Path);
            end loop;
            if Self.Has_Baseline then
               declare
                  Original : constant B.Comparison_Context := B.Context_Of (Self.Baseline);
                  Before_Findings : D.Diagnostic_List;
                  Scoped_Context  : B.Comparison_Context := Original;
                  Current_Context : B.Comparison_Context := Original;
                  Scoped_Baseline : B.Baseline;
               begin
                  for Index in 1 .. D.Length (B.Findings_Of (Self.Baseline)) loop
                     declare
                        Finding : constant D.Diagnostic := D.Element (B.Findings_Of (Self.Baseline), Index);
                     begin
                        if Scope_Files.Contains (To_String (Finding.Path)) then
                           D.Append_Validated
                             (Before_Findings, Finding, Status, To_String (Self.Project));
                           if E.Is_Error (Status) then
                              return;
                           end if;
                        end if;
                     end;
                  end loop;
                  Scoped_Context.Scope := Scope;
                  B.Create (Scoped_Context, Before_Findings, Scoped_Baseline, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  Current_Context.Snapshot := To_Unbounded_String
                    (Model_Runner.Code_Health.Changes.Identifier (Analyzed_Tree));
                  Current_Context.Provider_Fingerprint := To_Unbounded_String
                    (To_String (Provider_Result.Provider_Id) & ":"
                     & To_String (Provider_Result.Provider_Version));
                  Current_Context.Toolchain_Fingerprint :=
                    (if Provider_Result.Toolchain_Fingerprint = Null_Unbounded_String
                     then To_Unbounded_String ("unreported") else Provider_Result.Toolchain_Fingerprint);
                  Current_Context.Environment_Fingerprint :=
                    (if Provider_Result.Environment_Fingerprint = Null_Unbounded_String
                     then To_Unbounded_String ("unreported") else Provider_Result.Environment_Fingerprint);
                  Current_Context.Scope := Scope;
                  Current_Context.Task_Id := Event.Task_Id;
                  Current_Context.Generation := Event.Generation;
                  Current_Context.Workspace := Event.Workspace_Id;
                  B.Compare
                    (Scoped_Baseline, Current_Context, Provider_Result.Diagnostics, Classifications);
               end;
            else
               for Index in 1 .. D.Length (Provider_Result.Diagnostics) loop
                  B.Append
                    (Classifications,
                     (State => B.Unknown_Finding,
                      Current => D.Element (Provider_Result.Diagnostics, Index),
                      Previous => (others => <>)));
               end loop;
            end if;
         end;
      end if;
      if Level = Focused then
         declare
            Refined : B.Classification_List;

            function Was_Already_A_Regression (Finding : D.Diagnostic) return Boolean is
            begin
               for Index in 1 .. B.Length (Prior_Classifications) loop
                  declare
                     Earlier : constant B.Classified_Finding :=
                       B.Element (Prior_Classifications, Index);
                  begin
                     if Earlier.State in B.New_Finding | B.Changed_Finding
                       and then Earlier.Current.Fingerprint = Finding.Fingerprint
                     then
                        return True;
                     end if;
                  end;
               end loop;
               return False;
            end Was_Already_A_Regression;
         begin
            for Index in 1 .. B.Length (Classifications) loop
               declare
                  Item : B.Classified_Finding := B.Element (Classifications, Index);
               begin
                  if Item.State = B.New_Finding
                    and then not Was_Already_A_Regression (Item.Current)
                  then
                     Item.State := B.Unknown_Finding;
                  end if;
                  B.Append (Refined, Item);
               end;
            end loop;
            Classifications := Refined;
         end;
      end if;
      for Index in 1 .. B.Length (Classifications) loop
         declare
            Classified : constant B.Classified_Finding := B.Element (Classifications, Index);

            function Blocking_Threshold return Diagnostic_Severity is
               Result : Diagnostic_Severity := Self.Threshold;
            begin
               for Check of Request.Checks loop
                  if To_String (Check.Identifier) = To_String (Classified.Current.Check_Id)
                    and then Check.Block_On < Result
                  then
                     Result := Check.Block_On;
                  end if;
               end loop;
               return Result;
            end Blocking_Threshold;
         begin
            case Classified.State is
               when B.New_Finding | B.Changed_Finding =>
                  if D.Blocks (Classified.Current, Blocking_Threshold) then
                     Blockers := Blockers + 1;
                  elsif Classified.Current.Severity = Warning then
                     Warnings := Warnings + 1;
                  end if;
               when B.Existing_Finding =>
                  Existing := Existing + 1;
               when B.Resolved_Finding =>
                  Resolved := Resolved + 1;
               when B.Unknown_Finding =>
                  Unknown := Unknown + 1;
            end case;
         end;
      end loop;
      State :=
        (if Cancelled_Check then Cancelled
         elsif Stale_Check then Stale
         elsif Required_Failed then Unavailable
         elsif Blockers > 0 or else Unknown > 0 then Blocked
         elsif D.Length (Provider_Result.Diagnostics) > 0 then Findings_Present
         else Passed);

      Self.Latest :=
        (State              => State,
         Snapshot           => To_Unbounded_String
           (Model_Runner.Code_Health.Changes.Identifier (Analyzed_Tree)),
         Policy_Fingerprint => Self.Configuration,
         Diagnostics        => Provider_Result.Diagnostics,
         Checks             => Provider_Result.Checks,
         Permissions_Valid  => True);
      Self.Has_Assessment := True;
      Self.Latest_Level := Level;
      Self.Latest_Classifications := Classifications;

      if Self.Store /= null and then not Reused then
         declare
            Context : constant Ev.Assessment_Context :=
              (Project                   => Self.Project,
               Task_Id                   => Event.Task_Id,
               Generation                => Event.Generation,
               Agent_Id                  => Self.Agent_Id,
               Invocation_Id             => Self.Invocation_Id,
               Workspace                 => Event.Workspace_Id,
               Snapshot                  => Self.Latest.Snapshot,
               Configuration_Fingerprint => Provider_Result.Configuration_Fingerprint,
               Toolchain_Fingerprint     =>
                 (if Length (Provider_Result.Toolchain_Fingerprint) = 0
                  then To_Unbounded_String ("unreported") else Provider_Result.Toolchain_Fingerprint),
               Environment_Fingerprint   =>
                 (if Length (Provider_Result.Environment_Fingerprint) = 0
                  then To_Unbounded_String ("unreported") else Provider_Result.Environment_Fingerprint),
               Profile                   => Profile);
            Assessment : Ev.Assessment;
         begin
            Ev.Create
              (Context, Level, State, Results, Classifications,
               (if Self.Has_Baseline then B.Identifier (Self.Baseline) else ""),
               To_String (Cache_Key), Assessment, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Ev.Keep (Self.Store.all, Self.Change, Assessment, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            S.Commit (Self.Store.all, Self.Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Assessment_Id := To_Unbounded_String (Ev.Identifier (Assessment));
         end;
      elsif Self.Store /= null then
         S.Commit (Self.Store.all, Self.Change, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      else
         Assessment_Id := To_Unbounded_String ("CH-LIVE-" & Image (Self.Sequence));
      end if;

      declare
         Presented : constant F.Assessment :=
           (Identifier     => Assessment_Id,
            Level          => Level,
            State          => State,
            Snapshot       => Self.Latest.Snapshot,
            Files_Analyzed => Natural (Provider_Result.Files_Analyzed.Length),
            Checks_Passed  => Checks_Passed,
            Checks_Failed  => Checks_Failed,
            New_Errors     => Blockers,
            New_Warnings   => Warnings,
            Existing       => Existing,
            Resolved       => Resolved,
            Unknown        => Unknown,
            Findings       => Provider_Result.Diagnostics,
            Completion     =>
              (if State in Passed | Findings_Present then Allow_Completion
               elsif State = Blocked then Require_Remediation else Refuse_Completion),
            Next_Action    => To_Unbounded_String
              (if State in Passed | Findings_Present then "continue"
               elsif State = Blocked then "repair_and_recheck" else "stop_incomplete"));
         Limits : F.Render_Limits := F.Default_Limits;
      begin
         Limits.Total_Bytes := F.Feedback_Bytes'Max
           (F.Feedback_Bytes'First,
            F.Feedback_Bytes'Min (F.Feedback_Bytes'Last, Self.Feedback_Limit));
         Feedback := To_Unbounded_String (F.Render_Model (Presented, Limits));
         Self.Summary := Feedback;
      end;
      if Level = Focused then
         Model_Runner.Code_Health.Changes.Clear (Self.Pending);
         Self.Has_Pending := False;
      end if;
      Status := E.Success;
   exception
      when Failure : others =>
         Feedback := Null_Unbounded_String;
         Status := E.Unexpected (Failure, "dispatching Code Health");
   end Dispatch;

   overriding procedure Assess
     (Self     : in out Instance;
      Trigger  : Trigger_Kind;
      Answer   : String;
      Result   : out Model_Runner.Code_Health.Remediation.Assessment;
      Feedback : out Unbounded_String;
      Status   : out E.Error_Info)
   is
      Current : Model_Runner.Code_Health.Changes.Snapshot;
      Boundary_Feedback : Unbounded_String;
      Changed : Model_Runner.Code_Health.Changes.Change_Set;
   begin
      pragma Unreferenced (Answer);
      Feedback := Null_Unbounded_String;
      if Self.Active and then Trigger = Before_Agent_Answer and then Self.Has_Pending then
         declare
            Event   : Model_Runner.Code_Health.Hooks.Change_Event := Self.Pending_Event;
            Changed : constant Model_Runner.Code_Health.Changes.Change_Set := Self.Pending;
         begin
            Event.Trigger := Before_Agent_Answer;
            Event.Change_Id := To_Unbounded_String
              (Model_Runner.Code_Health.Changes.Identifier (Changed));
            Dispatch (Self, Event, Changed, Boundary_Feedback, Status);
            if E.Is_Error (Status) then
               Result := (State => Unavailable, others => <>);
               Feedback := Boundary_Feedback;
               return;
            end if;
         end;
      end if;
      if Self.Active and then Trigger = Before_Agent_Answer and then Self.Has_Baseline_Tree
        and then not Self.Has_Pending
      then
         Model_Runner.Code_Health.Changes.Capture
           (To_String (Self.Project), Current, Status);
         if E.Is_Error (Status) then
            return;
         elsif not Self.Has_Assessment
           or else Self.Latest_Level /= Focused
           or else Model_Runner.Code_Health.Changes.Identifier (Current)
             /= To_String (Self.Latest.Snapshot)
         then
            Model_Runner.Code_Health.Changes.Reconcile
              (Self.Baseline_Tree, Current,
               Model_Runner.Code_Health.Changes.Reconciliation, Changed, Status);
            if E.Is_Error (Status) then
               return;
            elsif Model_Runner.Code_Health.Changes.Length (Changed) > 0 then
               declare
                  Event : Model_Runner.Code_Health.Hooks.Change_Event := Self.Baseline_Event;
               begin
                  Event.Trigger := Before_Agent_Answer;
                  Event.Change_Id := To_Unbounded_String
                    (Model_Runner.Code_Health.Changes.Identifier (Changed));
                  Dispatch (Self, Event, Changed, Boundary_Feedback, Status);
                  if E.Is_Error (Status) then
                     Result := (State => Unavailable, others => <>);
                     Feedback := Boundary_Feedback;
                     return;
                  end if;
               end;
            elsif not Self.Has_Assessment
              or else Model_Runner.Code_Health.Changes.Identifier (Current)
                /= To_String (Self.Latest.Snapshot)
            then
               Self.Latest :=
                 (State              => Passed,
                  Snapshot           => To_Unbounded_String
                    (Model_Runner.Code_Health.Changes.Identifier (Current)),
                  Policy_Fingerprint => Self.Configuration,
                  others             => <>);
               Self.Latest_Level := Focused;
               Self.Has_Assessment := True;
               Self.Summary := Null_Unbounded_String;
            end if;
         end if;
      end if;
      if not Self.Active or else not Self.Has_Assessment then
         Result :=
           (State              => Passed,
            Policy_Fingerprint => Self.Configuration,
            others             => <>);
      else
         Result := Self.Latest;
         Feedback :=
           (if Boundary_Feedback = Null_Unbounded_String
            then Self.Summary else Boundary_Feedback);
         Model_Runner.Code_Health.Changes.Capture
           (To_String (Self.Project), Current, Status);
         if E.Is_Error (Status) then
            return;
         elsif Model_Runner.Code_Health.Changes.Identifier (Current)
           /= To_String (Result.Snapshot)
         then
            Result.State := Stale;
            Result.Checks.Append
              (P.Check_Result'
                 (Identifier => To_Unbounded_String ("completion-snapshot"),
                  Status     => P.Check_Stale,
                  Required   => True,
                  Detail     => To_Unbounded_String
                    ("source changed after the latest assessment"),
                  Evidence   => Null_Unbounded_String));
            Feedback := To_Unbounded_String
              ("CODE HEALTH: STALE" & ASCII.LF
               & "The source changed after the latest assessment." & ASCII.LF
               & "Run a current assessment before reporting completion.");
         end if;
      end if;
      Status := E.Success;
   exception
      when Failure : others =>
         Result := (State => Unavailable, others => <>);
         Feedback := Null_Unbounded_String;
         Status := E.Unexpected (Failure, "checking Code Health at the answer boundary");
   end Assess;

end Model_Runner.Code_Health.Engine;
