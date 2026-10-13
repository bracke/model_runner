separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Git is
begin
   if Word = "/git" and then Argument (1) /= "" then
      --  Nothing is taken: an argument would look obeyed if ignored.
      --  Said as an error, and ended as one.
      Outcome := E.Make (E.CLI_Unexpected_Operand);
      E.Add_Text (Outcome, "value", Argument (1));
      Pres.Report (Screen, Outcome);
      Pres.Put_Usage (Screen, "cli.interactive.usage.git");
      Last_Status := E.Exit_Status (Outcome);
   elsif Word = "/git" then
      With_Store (Git_Status'Access);
   end if;
end Route_Git;
