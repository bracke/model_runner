with Ada.Real_Time;
with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Changes;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Stores;

--  Framework-backed provider process capability. The owning lifecycle keeps
--  the store and transaction alive; providers receive only Command_Runner.
package Model_Runner.Code_Health.Execution is

   package P renames Model_Runner.Code_Health.Providers;
   package X renames Model_Runner.Framework.Execution;
   package S renames Model_Runner.Framework.Stores;

   type Store_Reference is access all S.Store;
   type Transaction_Reference is access all S.Transaction;

   type Framework_Runner is limited new P.Command_Runner with private;
   type Standalone_Runner is limited new P.Command_Runner with private;

   --  Bind interactive checks to an explicitly supplied local policy. This
   --  runner has no framework store and therefore retains no formal evidence.
   --  @param Self Runner to initialize.
   --  @param Root Canonical source tree.
   --  @param Authorized User-authorized execution policy.
   procedure Initialize
     (Self       : in out Standalone_Runner;
      Root       : String;
      Authorized : X.Policy);

   overriding procedure Run
     (Self      : in out Standalone_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

   --  @param Self Runner to initialize.
   --  @param Store Owning framework store.
   --  @param Change Owning transaction.
   --  @param Status Success or policy/snapshot failure.
   --  @param Base Workspace root relative to the project, when isolated.
   procedure Initialize
     (Self   : in out Framework_Runner;
      Store  : not null Store_Reference;
      Change : not null Transaction_Reference;
      Status : out Model_Runner.Errors.Error_Info;
      Base   : String := "");

   --  A provider may only narrow the owning project's execution authority.
   --  It cannot add a program, environment variable, shell, network access,
   --  resource allowance or write capability absent from project policy.
   --  @param Authorized Authority captured from project policy.
   --  @param Requested Provider-requested restrictions.
   --  @return Intersection of both policies.
   function Effective_Policy
     (Authorized : X.Policy;
      Requested  : X.Policy) return X.Policy;

   --  Confirm that the source snapshot bound by Initialize is still current.
   --  Generated build output under excluded roots does not make it stale.
   --  @param Self Bound framework runner.
   --  @param Stale Whether protected source changed.
   --  @param Status Success or capture failure.
   procedure Verify_Unchanged
     (Self   : Framework_Runner;
      Stale  : out Boolean;
      Status : out Model_Runner.Errors.Error_Info);

   --  Bind a new post-change source snapshot while retaining the execution
   --  authority captured by Initialize.  A policy edit made by the agent
   --  therefore cannot authorize the assessment of that same edit.
   --  @param Self Bound framework runner.
   --  @param Status Success or snapshot failure.
   procedure Rebind_Source
     (Self   : in out Framework_Runner;
      Status : out Model_Runner.Errors.Error_Info);

   overriding procedure Run
     (Self      : in out Framework_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

private

   type Standalone_Runner is limited new P.Command_Runner with record
      Root       : Ada.Strings.Unbounded.Unbounded_String;
      Authorized : X.Policy;
      Ready      : Boolean := False;
   end record;

   type Framework_Runner is limited new P.Command_Runner with record
      Store  : Store_Reference;
      Change : Transaction_Reference;
      Base   : Ada.Strings.Unbounded.Unbounded_String;
      Authorized : X.Policy;
      Snapshot   : Model_Runner.Code_Health.Changes.Snapshot;
      Ready      : Boolean := False;
      Initialization : Model_Runner.Errors.Error_Info;
   end record;

end Model_Runner.Code_Health.Execution;
