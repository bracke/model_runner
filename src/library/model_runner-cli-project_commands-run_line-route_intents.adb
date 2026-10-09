separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Intents is
begin
   if Word = "/req" and then Argument (1) = "verify" and then Argument (2) /= "" then
      --  The same as /check REQ: one way to verify one, said one way.
      declare
         All_Named : constant Names.Vector := Positional;
      begin
         for Index in 2 .. Natural (All_Named.Length) loop
            Positional.Clear;
            Positional.Append (All_Named (Index));
            With_Store (Check'Access);
         end loop;
      end;
   elsif Word in "/req" | "/decision" | "/spec" then
      With_Store (Intent_Command'Access);
   end if;
end Route_Intents;
