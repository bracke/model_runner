separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Instructions is
begin
   if Word = "/instruct" then
      With_Store (Instruct'Access);
   end if;
end Route_Instructions;
