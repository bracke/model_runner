package body Model_Runner.Code_Health.Execution is

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;

   package E renames Model_Runner.Errors;

   procedure Initialize
     (Self   : in out Framework_Runner;
      Store  : not null Store_Reference;
      Change : not null Transaction_Reference;
      Base   : String := "") is
   begin
      Self.Store := Store;
      Self.Change := Change;
      Self.Base := To_Unbounded_String (Base);
   end Initialize;

   overriding procedure Run
     (Self      : in out Framework_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out E.Error_Info)
   is
      Applied : X.Policy := Rules;
   begin
      if Self.Store = null or else Self.Change = null then
         Result := (Command => To_Unbounded_String (Command), others => <>);
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "the Code Health runner has no owning transaction");
         return;
      end if;

      if Deadline /= Ada.Real_Time.Time_Last then
         declare
            Left : constant Duration := Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
         begin
            if Left <= 0.0 then
               Result :=
                 (Command   => To_Unbounded_String (Command),
                  Directory => To_Unbounded_String (Directory),
                  Timed_Out => True,
                  others    => <>);
               Status := E.Success;
               return;
            end if;
            if Left < Duration (Applied.Timeout) then
               Applied.Timeout :=
                 Positive'Max (1, Positive (Long_Float'Ceiling (Long_Float (Left))));
            end if;
         end;
      end if;

      X.Watch (Cancel);
      X.Run
        (Self.Store.all, Self.Change.all, Applied, Command, Directory, Result, Status,
         Base => To_String (Self.Base));
   end Run;

end Model_Runner.Code_Health.Execution;
