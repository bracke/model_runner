separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Results is
begin
   if Word = "/result" and then Argument (1) /= ""
     and then (for all C of Argument (1) => C in 'a' .. 'z')
     and then Argument (1) not in "dismiss" | "dismissed" | "restore" | "all" | "show" | "list" | "full"
     --  A word of letters alone may yet be the start of a result's hex.
     and then not (for all C of Argument (1) => C in 'a' .. 'f')
   then
      --  A word no action is: the actions it takes, not "not in the state".
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "/result's actions");
      E.Add_Text (Outcome, "value", Argument (1));
      E.Add_Text (Outcome, "detail",
                  "/result has no " & Argument (1) & "; it shows an ID, or takes dismiss ID...,"
                  & " dismissed, restore ID... or all");
      Pres.Report (Screen, Outcome);
      Last_Status := E.Exit_Status (Outcome);
   elsif Word = "/result" and then Argument (1) in "dismiss" | "restore"
     and then Argument (2) /= "" and then Argument (2)'Length <= 3
     and then (for all C of Argument (2) => C in '0' .. '9')
   then
      --  A number is no result's: what /result lists is by identifier.
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "what to " & Argument (1));
      E.Add_Text (Outcome, "value", Argument (2));
      E.Add_Text (Outcome, "detail", "a result is named by its identifier, as /result lists it -- /result "
                  & Argument (1) & " RES-1A2B, its first letters are enough");
      Pres.Report (Screen, Outcome);
      Last_Status := E.Exit_Status (Outcome);
   elsif Word = "/result" then
      --  A number alone is a task's: said, as it is no row of the list.
      if Argument (1) /= "" and then Argument (1)'Length <= 3 and then Argument (2) = ""
        and then (for all C of Argument (1) => C in '0' .. '9')
      then
         Pres.Put_Note (Screen, "cli.result.number_as_task",
                        [Loc.Named ("value", Argument (1)),
                         Loc.Named ("name", "TASK-" & (if Argument (1)'Length >= 3 then Argument (1)
                                                       else [1 .. 3 - Argument (1)'Length => '0']
                                                            & Argument (1)))]);
      end if;
      --  /result show ID as the registers take it: show is the default.
      if Argument (1) = "show" and then Argument (2) /= "" then
         Positional.Delete_First;
      --  /result list as the registers take it: the list is the default.
      elsif Argument (1) = "list" then
         Positional.Delete_First;
      end if;
      --  Several shown: each in turn, as dismiss and restore take several.
      if Argument (2) not in "" | "full"
        and then Argument (1) not in "dismiss" | "dismissed" | "restore" | "all"
      then
         declare
            Asked : constant Names.Vector := Positional;
         begin
            for One of Asked loop
               Positional := [One];
               With_Store (Show_Result'Access);
            end loop;
            Positional := Asked;
         end;
      else
         With_Store (Show_Result'Access);
      end if;
   end if;
end Route_Results;
