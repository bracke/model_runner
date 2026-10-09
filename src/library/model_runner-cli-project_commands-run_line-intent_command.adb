separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Intent_Command (Store : in out S.Store) is
   After : Names.Vector;
begin
   for Index in 2 .. Natural (All_Words.Length) loop
      After.Append (All_Words (Index));
   end loop;
   Model_Runner.CLI.Intents.Run
     (Store,
      (if Word = "/req" then Nt.Requirement
       elsif Word = "/decision" then Nt.Decision
       else Nt.Specification),
      After, Screen);
   --  One turned down by name: what still waits, as /reject says it.
   if Natural (All_Words.Length) >= 3 and then Ada.Characters.Handling.To_Lower (All_Words (2)) = "reject" then
      Say_Still_Waiting (Store);
   end if;
end Intent_Command;
