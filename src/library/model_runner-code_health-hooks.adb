with Ada.Strings.Fixed;

package body Model_Runner.Code_Health.Hooks is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Tools.Runner.Answer_Kind;
   use type Model_Runner.Tools.Runner.Call_Kind;
   use type Model_Runner.Tools.Runner.Resource;

   package E renames Model_Runner.Errors;
   package Tr renames Model_Runner.Tools.Runner;

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   procedure Initialize
     (Item       : in out Context;
      Project    : String;
      Handler    : not null Dispatcher_Reference;
      Status     : out E.Error_Info;
      Workspace  : String := "";
      Task_Id    : String := "";
      Generation : Natural := 0) is
   begin
      Changes.Capture (Project, Item.Last, Status);
      if E.Is_Error (Status) then
         Item.Active := False;
         Item.Handler := null;
         return;
      end if;
      Item.Active := True;
      Item.Handler := Handler;
      Item.Workspace := To_Unbounded_String (Workspace);
      Item.Task_Id := To_Unbounded_String (Task_Id);
      Item.Generation := Generation;
      Item.Sequence := 0;
   end Initialize;

   procedure Disable (Item : in out Context) is
   begin
      Item.Active := False;
      Item.Handler := null;
   end Disable;

   function Enabled (Item : Context) return Boolean is
     (Item.Active and then Item.Handler /= null);

   procedure After_Call
     (Item      : in out Context;
      Named     : String;
      Kind      : Tr.Call_Kind;
      Touches   : Tr.Resource;
      Outcome   : Tr.Call_Outcome;
      Trigger   : Trigger_Kind;
      Feedback  : out Unbounded_String;
      Status    : out E.Error_Info)
   is
      Current : Changes.Snapshot;
      Changed : Changes.Change_Set;
      Source  : constant Changes.Source_Kind :=
        (case Trigger is
            when After_File_Change => Changes.Direct_Tool,
            when After_Delegation  => Changes.Delegated_Agent,
            when others            => Changes.External_Command);
   begin
      Feedback := Null_Unbounded_String;
      Status := E.Success;
      if not Enabled (Item)
        or else Outcome.Answer /= Tr.Answered
        or else not Outcome.Changed
        or else Kind /= Tr.Changes
        or else Touches not in Tr.Files | Tr.Anything
      then
         return;
      end if;

      Changes.Capture (Changes.Root (Item.Last), Current, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Changes.Reconcile (Item.Last, Current, Source, Changed, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The next reconciliation begins at the state actually observed,
      --  even if analysis itself is unavailable.  Its failure is evidence,
      --  not permission to attribute the same edit to a later tool call.
      Item.Last := Current;
      if Changes.Length (Changed) = 0 then
         return;
      end if;

      Item.Sequence := Item.Sequence + 1;
      declare
         Event : constant Change_Event :=
           (Trigger      => Trigger,
            Change_Id    => To_Unbounded_String (Changes.Identifier (Changed)),
            Workspace_Id => Item.Workspace,
            Task_Id      => Item.Task_Id,
            Generation   => Item.Generation,
            Tool_Call_Id => To_Unbounded_String (Named & "-" & Image (Item.Sequence)),
            Sequence     => Item.Sequence);
      begin
         Dispatch (Item.Handler.all, Event, Changed, Feedback, Status);
      end;
   end After_Call;

end Model_Runner.Code_Health.Hooks;
