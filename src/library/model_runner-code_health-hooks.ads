with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Changes;
with Model_Runner.Errors;
with Model_Runner.Tools.Runner;

--  Synchronous post-change dispatch shared by interactive and spec-driven
--  agents.  The dispatcher owns analysis; this package owns authoritative
--  outcome filtering and actual-tree reconciliation.
package Model_Runner.Code_Health.Hooks is

   type Change_Event is record
      Trigger      : Trigger_Kind := After_File_Change;
      Change_Id    : Ada.Strings.Unbounded.Unbounded_String;
      Workspace_Id : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id      : Ada.Strings.Unbounded.Unbounded_String;
      Generation   : Natural := 0;
      Tool_Call_Id : Ada.Strings.Unbounded.Unbounded_String;
      Sequence     : Natural := 0;
   end record;

   type Dispatcher is limited interface;
   type Dispatcher_Reference is access all Dispatcher'Class;

   --  @param Self Dispatcher receiving the event.
   --  @param Event Immutable event provenance.
   --  @param Changed Normalized actual changes.
   --  @param Feedback Bounded trusted model feedback.
   --  @param Status Success or dispatch failure.
   procedure Dispatch
     (Self     : in out Dispatcher;
      Event    : Change_Event;
      Changed  : Changes.Change_Set;
      Feedback : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info) is abstract;

   type Context is private;

   --  @param Item Context to initialize.
   --  @param Project Project or workspace root to reconcile.
   --  @param Handler Synchronous assessment dispatcher.
   --  @param Status Success or snapshot failure.
   --  @param Workspace Workspace provenance.
   --  @param Task_Id Task provenance.
   --  @param Generation Execution generation.
   procedure Initialize
     (Item       : in out Context;
      Project    : String;
      Handler    : not null Dispatcher_Reference;
      Status     : out Model_Runner.Errors.Error_Info;
      Workspace  : String := "";
      Task_Id    : String := "";
      Generation : Natural := 0);

   --  @param Item Context to disable.
   procedure Disable (Item : in out Context);

   --  @param Item Context to inspect.
   --  @return Whether synchronous dispatch is enabled.
   function Enabled (Item : Context) return Boolean;

   --  @param Item Context retaining the prior tree snapshot.
   --  @param Named Tool name for provenance.
   --  @param Kind Tool mutation classification.
   --  @param Touches Resource classification.
   --  @param Outcome Authoritative tool outcome.
   --  @param Trigger Lifecycle boundary.
   --  @param Feedback Bounded trusted model feedback.
   --  @param Status Success or reconciliation/dispatch failure.
   procedure After_Call
     (Item      : in out Context;
      Named     : String;
      Kind      : Model_Runner.Tools.Runner.Call_Kind;
      Touches   : Model_Runner.Tools.Runner.Resource;
      Outcome   : Model_Runner.Tools.Runner.Call_Outcome;
      Trigger   : Trigger_Kind;
      Feedback  : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info);

private

   type Context is record
      Active     : Boolean := False;
      Handler    : Dispatcher_Reference;
      Last       : Changes.Snapshot;
      Workspace  : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id    : Ada.Strings.Unbounded.Unbounded_String;
      Generation : Natural := 0;
      Sequence   : Natural := 0;
   end record;

end Model_Runner.Code_Health.Hooks;
