separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Verdicts is
begin
   if Word in "/accept" | "/reject" and then Argument (2) /= "" then
      --  Several named: each decided as if named alone.
      declare
         Named : constant Names.Vector := Positional;
      begin
         for Index in 1 .. Natural (Named.Length) loop
            Pres.Hold_Next_Steps (Screen, True);
            Positional.Clear;
            Positional.Append (Named (Index));
            With_Store (Decide'Access);
            if To_Task then
               To_Task := False;
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
            end if;
         end loop;
         Pres.Hold_Next_Steps (Screen, False);
         if Word = "/accept" then
            Say_First_Ready (Named, 1);
         end if;
      end;
   elsif Word in "/accept" | "/reject" then
      With_Store (Decide'Access);
      --  The tasks it decides, each in turn -- the next step said once,
      --  after the last.
      if To_Task then
         declare
            Each : constant Names.Vector := Split (T.To_String (Command.Action_Argument));
         begin
            --  Several tasks: decided together, so the way on is the one
            --  to take first -- a ticked one completed, else the lowest
            --  ready -- not the last one's.
            if Natural (Each.Length) > 1
              and then (for all One of Each => Ada.Strings.Fixed.Index (One, "TASK-") = One'First)
            then
               Command.Action_Argument := T.To_Bounded (Joined_Words (Each));
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
            else
               for Index in 1 .. Natural (Each.Length) loop
                  Pres.Hold_Next_Steps (Screen, Index < Natural (Each.Length));
                  Command.Action_Argument := T.To_Bounded (Each (Index));
                  Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
                  Last_Status := Natural'Max (Last_Status, Status);
               end loop;
               Pres.Hold_Next_Steps (Screen, False);
            end if;
         end;
      end if;
      --  Several decided, or one turned down: what still waits, as
      --  /state says it -- a single accept says its own way on.
      if Argument (2) /= "" or else (Word = "/reject" and then Argument (1) /= "")
        --  An entry accepted -- not a task, which says its own way on.
        or else (Word = "/accept" and then Argument (1) /= ""
                 and then Ada.Strings.Fixed.Head (Argument (1), 5) /= "TASK-"
                 and then Ada.Characters.Handling.To_Lower (Argument (1)) /= "all")
      then
         With_Store (Say_Still_Waiting'Access);
      end if;

   end if;
end Route_Verdicts;
