private with Ada.Finalization;

--  A wait for a typed line, said to the handler for as long as it lasts.
--
--  Set_Waiting_For_Input (True) and then (False) on the way out leave the
--  handler believing the program waits whenever something raises between
--  the two: told to end after, it ended at once, as it ends while a line is
--  waited for, and what the run had under way was not stopped and saved.
--  A guard says the wait is over however its scope is left.
--
--  Task safety: a guard belongs to the task that waits.
package Model_Runner.Platform.Signals.Waiting is

   --  The wait, held from Begin_Wait until Stop_Wait or the guard's end.
   type Guard is limited private;

   --  Say the program waits for a line, as Set_Waiting_For_Input (True).
   --
   --  @param Item The guard that ends the wait.
   --  @param Note What an interrupt during the wait says; see
   --    Set_Waiting_For_Input.
   procedure Begin_Wait (Item : in out Guard; Note : String := "");

   --  Say the wait is over. Idempotent.
   --
   --  @param Item The guard holding it.
   procedure Stop_Wait (Item : in out Guard);

private

   type Guard is new Ada.Finalization.Limited_Controlled with record
      Held : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Guard);

end Model_Runner.Platform.Signals.Waiting;
