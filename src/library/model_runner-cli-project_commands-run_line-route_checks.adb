separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Checks is
begin
   if Word = "/check" and then Argument (2) /= ""
     and then (for all One of Positional =>
                 One'Length > 4 and then One (One'First .. One'First + 3) = "REQ-")
   then
      --  Several requirements: each checked in turn, as if named alone.
      declare
         All_Named : constant Names.Vector := Positional;
      begin
         for One of All_Named loop
            Positional.Clear;
            Positional.Append (One);
            With_Store (Check'Access);
         end loop;
      end;
   elsif Word = "/check" then
      With_Store (Check'Access);
   end if;
end Route_Checks;
