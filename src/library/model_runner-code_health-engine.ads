with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Ada;
with Model_Runner.Code_Health.Ada_LSP_Adapter;
with Model_Runner.Code_Health.Ada_Quality_Adapter;
with Model_Runner.Code_Health.Baselines;
with Model_Runner.Code_Health.Changes;
with Model_Runner.Code_Health.Execution;
with Model_Runner.Code_Health.Hooks;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Code_Health.Profiles;
with Model_Runner.Code_Health.Remediation;
with Model_Runner.Errors;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Stores;

--  The production synchronous dispatcher.  It owns provider state, binds
--  execution to the project policy and turns every accepted change event
--  into bounded model feedback and, for framework projects, immutable
--  assessment evidence.
package Model_Runner.Code_Health.Engine is

   type Instance is limited new Model_Runner.Code_Health.Hooks.Dispatcher
     and Model_Runner.Code_Health.Remediation.Assessment_Source with private;

   --  @param Self Dispatcher to initialize.
   --  @param Project Canonical project or workspace root.
   --  @param Status Success or initialization failure.
   --  @param Store Framework store, when formal evidence is required.
   --  @param Provider Provider override used by deterministic tests.
   --  @param Runner Authorized command runner, or the framework runner.
   --  @param Execution_Policy Explicit authority for an interactive runner.
   --  @param Cancel Owning agent or task cancellation token.
   --  @param Agent_Id Owning agent identity, or empty interactively.
   --  @param Invocation_Id Owning model invocation, or empty interactively.
   --  @param Enabled Whether dispatch is active.
   --  @param Profile Profile identity recorded with evidence.
   --  @param Focused_Profile Completion-boundary profile identity.
   --  @param Configuration Configuration fingerprint.
   --  @param Block_On Least severity that blocks completion.
   --  @param Deadline Fast assessment deadline in seconds.
   --  @param Focused_Deadline Completion-boundary deadline in seconds.
   --  @param Fallback_Test Reliable focused-test fallback command.
   --  @param Feedback_Limit Maximum model-facing bytes.
   procedure Initialize
     (Self          : in out Instance;
      Project       : String;
      Status        : out Model_Runner.Errors.Error_Info;
      Store         : Model_Runner.Code_Health.Execution.Store_Reference := null;
      Provider      : Model_Runner.Code_Health.Providers.Provider_Reference := null;
      Runner        : Model_Runner.Code_Health.Providers.Command_Runner_Reference := null;
      Execution_Policy : Model_Runner.Framework.Execution.Policy := (others => <>);
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
      Feedback_Limit : Positive := 8 * 1024);

   --  @param Self Dispatcher to disable.
   procedure Disable (Self : in out Instance);

   --  @param Self Dispatcher to inspect.
   --  @return Whether it accepts change events.
   function Enabled (Self : Instance) return Boolean;

   --  @param Self Dispatcher receiving the optional source.
   --  @param Source CLI-owned language-server diagnostic callback.
   procedure Use_Language_Server
     (Self   : in out Instance;
      Source : Model_Runner.Code_Health.Ada_LSP_Adapter.Problem_Source);

   --  Add one reliable focused-check command derived from explicit project
   --  verification configuration.
   --  @param Self Initialized dispatcher.
   --  @param Command Authorized command.
   --  @param Directory Project-relative working directory.
   procedure Add_Focused_Test
     (Self      : in out Instance;
      Command   : String;
      Directory : String := "");

   --  Bind the initialized dispatcher to its validated fast and focused
   --  profile definitions.  Until called, providers retain their legacy
   --  level defaults for compatibility with injected test providers.
   --  @param Self Initialized dispatcher.
   --  @param Defined Validated profile definitions.
   --  @param Status Success or invalid selected profile.
   procedure Use_Profiles
     (Self    : in out Instance;
      Defined : Model_Runner.Code_Health.Profiles.Profile_Set;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Bind explicitly resolved project-policy checks.
   --  @param Self Initialized dispatcher.
   --  @param Level Assessment level to configure.
   --  @param Checks Requested checks for that level.
   procedure Use_Checks
     (Self   : in out Instance;
      Level  : Check_Level;
      Checks : Model_Runner.Code_Health.Providers.Requested_Check_Lists.Vector);

   --  Register an additional native provider for this dispatcher. Providers
   --  are invoked in stable identifier order and retain separate results.
   --  @param Self Initialized dispatcher.
   --  @param Provider Provider to add.
   --  @param Status Success or duplicate/invalid provider failure.
   procedure Add_Provider
     (Self     : in out Instance;
      Provider : not null Model_Runner.Code_Health.Providers.Provider_Reference;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Capture and, where a store is active, persist the immutable comparison
   --  point before the logical coding task makes its first change.
   --  @param Self Initialized dispatcher.
   --  @param Status Success or baseline-analysis/persistence failure.
   --  @param Task_Id Task identity, or empty for an interactive session.
   --  @param Generation Task execution generation.
   --  @param Workspace Workspace identity, or empty in-project.
   procedure Capture_Baseline
     (Self       : in out Instance;
      Status     : out Model_Runner.Errors.Error_Info;
      Task_Id    : String := "";
      Generation : Natural := 0;
      Workspace  : String := "");

   overriding procedure Dispatch
     (Self     : in out Instance;
      Event    : Model_Runner.Code_Health.Hooks.Change_Event;
      Changed  : Model_Runner.Code_Health.Changes.Change_Set;
      Feedback : out Standard.Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info);

   overriding procedure Assess
     (Self     : in out Instance;
      Trigger  : Trigger_Kind;
      Answer   : String;
      Result   : out Model_Runner.Code_Health.Remediation.Assessment;
      Feedback : out Standard.Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Self Dispatcher to inspect.
   --  @return Last bounded model-facing assessment summary.
   function Last_Summary (Self : Instance) return String;

private

   package Provider_Lists is new Standard.Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Model_Runner.Code_Health.Providers.Provider_Reference,
      "="          => Model_Runner.Code_Health.Providers."=");

   type Instance is limited new Model_Runner.Code_Health.Hooks.Dispatcher
     and Model_Runner.Code_Health.Remediation.Assessment_Source with record
      Active        : Boolean := False;
      Project       : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Profile       : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Focused_Profile : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Configuration : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Threshold     : Diagnostic_Severity := Error;
      Deadline      : Positive := 10;
      Focused_Deadline : Positive := 120;
      Fallback_Test : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Focused_Tests : String_Lists.Vector;
      Focused_Test_Directories : String_Lists.Vector;
      Fast_Checks   : Model_Runner.Code_Health.Providers.Requested_Check_Lists.Vector;
      Focused_Checks : Model_Runner.Code_Health.Providers.Requested_Check_Lists.Vector;
      Policy        : Model_Runner.Framework.Execution.Policy;
      Cancel        : Model_Runner.Cancellation.Token_Reference;
      Agent_Id      : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Invocation_Id : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Feedback_Limit : Positive := 8 * 1024;
      Sequence      : Natural := 0;
      Summary       : Standard.Ada.Strings.Unbounded.Unbounded_String;
      Has_Assessment : Boolean := False;
      Latest        : Model_Runner.Code_Health.Remediation.Assessment;
      Latest_Level  : Check_Level := Fast;
      Latest_Classifications : Model_Runner.Code_Health.Baselines.Classification_List;
      Pending       : Model_Runner.Code_Health.Changes.Change_Set;
      Pending_Event : Model_Runner.Code_Health.Hooks.Change_Event;
      Has_Pending   : Boolean := False;
      Baseline      : Model_Runner.Code_Health.Baselines.Baseline;
      Baseline_Tree : Model_Runner.Code_Health.Changes.Snapshot;
      Baseline_Event : Model_Runner.Code_Health.Hooks.Change_Event;
      Has_Baseline_Tree : Boolean := False;
      Has_Baseline  : Boolean := False;
      Store         : Model_Runner.Code_Health.Execution.Store_Reference;
      Change        : aliased Model_Runner.Framework.Stores.Transaction;
      Framework     : aliased Model_Runner.Code_Health.Execution.Framework_Runner;
      Standalone    : aliased Model_Runner.Code_Health.Execution.Standalone_Runner;
      Runner        : Model_Runner.Code_Health.Providers.Command_Runner_Reference;
      Quality       : aliased Model_Runner.Code_Health.Ada_Quality_Adapter.Instance;
      Language      : aliased Model_Runner.Code_Health.Ada_LSP_Adapter.Instance;
      Native        : aliased Model_Runner.Code_Health.Ada.Instance;
      Provider      : Model_Runner.Code_Health.Providers.Provider_Reference;
      Providers     : Provider_Lists.Vector;
   end record;

end Model_Runner.Code_Health.Engine;
