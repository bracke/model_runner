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

   procedure Dispatch
     (Self     : in out Dispatcher;
      Event    : Change_Event;
      Changed  : Changes.Change_Set;
      Feedback : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info) is abstract;

   type Context is private;

   procedure Initialize
     (Item       : in out Context;
      Project    : String;
      Handler    : not null Dispatcher_Reference;
      Status     : out Model_Runner.Errors.Error_Info;
      Workspace  : String := "";
      Task_Id    : String := "";
      Generation : Natural := 0);

   procedure Disable (Item : in out Context);
   function Enabled (Item : Context) return Boolean;

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
