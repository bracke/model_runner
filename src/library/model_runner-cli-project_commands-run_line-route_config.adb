separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Config is
begin
   if Word = "/config" then
      With_Store (Show_Config'Access);
   end if;
end Route_Config;
