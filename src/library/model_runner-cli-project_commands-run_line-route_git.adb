separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Git is
begin
   if Word = "/git" and then Argument (1) /= "" then
      --  Nothing is taken: an argument would look obeyed if ignored.
      Pres.Put_Message (Screen, "error.cli.unexpected_operand", [Loc.Named ("value", Argument (1))]);
      Pres.Put_Usage (Screen, "cli.interactive.usage.git");
   elsif Word = "/git" then
      With_Store (Git_Status'Access);
   end if;
end Route_Git;
