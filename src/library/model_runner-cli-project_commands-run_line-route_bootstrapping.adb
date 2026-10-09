separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Bootstrapping is
begin
   if Word = "/bootstrap" then
      With_Store (Bootstrap'Access);
   end if;
end Route_Bootstrapping;
