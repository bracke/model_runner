with Ada.Task_Attributes;

package body Model_Runner.Tools.Runner is

   use type Ada.Real_Time.Time;

   --  The context each task's waits answer to.
   package Entered is new Ada.Task_Attributes (Tool_Context, No_Context);

   -----------------
   -- Set_Context --
   -----------------

   procedure Set_Context (Self : in out Instance'Class; Context : Tool_Context) is
   begin
      Self.Context := Context;
   end Set_Context;

   ----------------
   -- Context_Of --
   ----------------

   function Context_Of (Self : Instance'Class) return Tool_Context is (Self.Context);

   -------------
   -- Stopped --
   -------------

   function Stopped (Context : Tool_Context) return Boolean is
     (Model_Runner.Cancellation.Is_Cancelled (Context.Cancel)
      or else (Context.Deadline /= Ada.Real_Time.Time_Last
               and then Ada.Real_Time.Clock >= Context.Deadline));

   ---------------
   -- Time_Left --
   ---------------

   function Time_Left (Context : Tool_Context; Most : Duration) return Duration is
   begin
      if Context.Deadline = Ada.Real_Time.Time_Last then
         return Most;
      end if;
      declare
         Left : constant Duration :=
           Ada.Real_Time.To_Duration (Context.Deadline - Ada.Real_Time.Clock);
      begin
         return Duration'Max (0.0, Duration'Min (Most, Left));
      end;
   end Time_Left;

   -----------
   -- Enter --
   -----------

   procedure Enter (Context : Tool_Context) is
   begin
      Entered.Set_Value (Context);
   end Enter;

   --------------
   -- Stop_Now --
   --------------

   function Entered_Context return Tool_Context is (Entered.Value);

   function Stop_Now return Boolean is (Stopped (Entered.Value));

   ---------
   -- Run --
   ---------

   procedure Run
     (Self      : in out Instance'Class;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Ended : Call_Outcome;
   begin
      Self.Run (Named, Arguments, Result, Last, Ended, Status);
   end Run;

end Model_Runner.Tools.Runner;
