with Model_Runner.Framework.Records;

package body Model_Runner.Framework.Transitions is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   --  Where a move is in a machine, or zero.
   function Find (From : Machine; Source, Target : String) return Natural is
   begin
      for Index in 1 .. Natural (From.Moves.Length) loop
         if To_String (From.Moves (Index).From) = Source
           and then To_String (From.Moves (Index).To) = Target
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   ---------------
   -- Add_State --
   ---------------

   procedure Add_State (Into : in out Machine; State : String) is
   begin
      if not Into.States.Contains (State) then
         Into.States.Append (State);
      end if;
   end Add_State;

   -----------
   -- Allow --
   -----------

   procedure Allow
     (Into     : in out Machine;
      From     : String;
      To       : String;
      Requires : Permission := Ordinary)
   is
      Held : constant Natural := Find (Into, From, To);
   begin
      Add_State (Into, From);
      Add_State (Into, To);
      if Held = 0 then
         Into.Moves.Append
           (Move'(From     => To_Unbounded_String (From),
                  To       => To_Unbounded_String (To),
                  Requires => Requires));
      else
         Into.Moves (Held).Requires := Requires;
      end if;
   end Allow;

   ------------
   -- Forbid --
   ------------

   procedure Forbid (Into : in out Machine; From : String; To : String) is
      Held : constant Natural := Find (Into, From, To);
   begin
      if Held /= 0 then
         Into.Moves.Delete (Held);
      end if;
   end Forbid;

   function Is_State (From : Machine; State : String) return Boolean
   is (From.States.Contains (State));

   -----------
   -- Check --
   -----------

   procedure Check
     (From    : Machine;
      Subject : String;
      Current : String;
      Next    : String;
      Granted : Permissions;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Held : constant Natural := Find (From, Current, Next);

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Subject);
         E.Add_Text (Status, "value", Current);
         E.Add_Text (Status, "expected", Next);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Status := E.Success;
      if not Is_State (From, Current) then
         Refuse (Current & " is not a state");
      elsif not Is_State (From, Next) then
         Refuse (Next & " is not a state");
      elsif Held = 0 then
         Refuse ("no such move is allowed");
      elsif not Granted (From.Moves (Held).Requires) then
         Refuse
           ("the move needs the "
            & (case From.Moves (Held).Requires is
                 when Ordinary        => "ordinary",
                 when Reopen          => "reopen",
                 when Reconsideration => "reconsideration")
            & " policy");
      end if;
   end Check;

   ------------------
   -- Task_Machine --
   ------------------

   function Task_Machine return Machine is
      Result : Machine;
   begin
      Allow (Result, "candidate", "accepted");
      Allow (Result, "candidate", "rejected");

      Allow (Result, "accepted", "running");
      Allow (Result, "accepted", "blocked");
      Allow (Result, "accepted", "cancelled");

      Allow (Result, "blocked", "accepted");
      Allow (Result, "blocked", "cancelled");
      Allow (Result, "blocked", "failed");

      Allow (Result, "running", "verification");
      Allow (Result, "running", "blocked");
      Allow (Result, "running", "failed");
      Allow (Result, "running", "cancelled");

      Allow (Result, "verification", "complete");
      Allow (Result, "verification", "running");
      Allow (Result, "verification", "blocked");
      Allow (Result, "verification", "failed");
      Allow (Result, "verification", "cancelled");

      Allow (Result, "failed", "accepted");
      Allow (Result, "failed", "cancelled");

      Allow (Result, "complete", "accepted", Reopen);
      Allow (Result, "cancelled", "accepted", Reopen);
      Allow (Result, "rejected", "candidate", Reconsideration);
      return Result;
   end Task_Machine;

   -----------
   -- Apply --
   -----------

   procedure Apply
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Rules   : Machine;
      Where   : Area;
      Name    : String;
      Next    : String;
      Granted : Permissions;
      Kind    : Events.Event_Kind;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
      Event  : Unbounded_String;
   begin
      Stores.Pending (Change, Where, Name, Value, Staged);
      if not Staged then
         Stores.Read (Item, Where, Name, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;

      Check
        (Rules, Records.Entity_Id (Value), Records.Get (Value, "state"), Next,
         Granted, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Previous : constant String := Records.Get (Value, "state");
      begin
         Records.Set (Value, "state", Next);
         Stores.Put (Change, Where, Name, Value);
         Events.Emit
           (Item, Change, Kind, Records.Entity_Id (Value),
            Previous & " -> " & Next, Event, Status);
      end;
   end Apply;

end Model_Runner.Framework.Transitions;
