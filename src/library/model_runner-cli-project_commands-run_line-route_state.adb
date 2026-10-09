separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_State is
begin
   if Word = "/state" then
      if Argument (1) /= "" then
         --  It takes nothing: a word after it is a mistake to say.
         Outcome := E.Make (E.CLI_Unexpected_Operand);
         E.Add_Text (Outcome, "value", Rest (1) & "; /state takes no argument");
         Pres.Report (Screen, Outcome);
         Last_Status := E.Exit_Status (Outcome);
         return;
      end if;
      With_Store (State'Access);
   end if;
end Route_State;
