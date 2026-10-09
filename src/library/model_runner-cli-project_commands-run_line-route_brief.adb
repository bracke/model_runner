separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Brief is

   package Cx renames Model_Runner.Framework.Context;

   --  What /work would give a task's agent, built as it builds it and
   --  shown item by item: what went in, as what and how much it mattered,
   --  and what was left out and why -- so what a model is handed is read,
   --  not guessed at.
   procedure Answer (Store : in out S.Store) is
      Given : constant String := Ada.Characters.Handling.To_Upper (Argument (1));
      Asked : constant String :=
        (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
         then "TASK-" & [1 .. Integer'Max (0, 3 - Given'Length) => '0'] & Given
         else Given);
      Made  : Cx.Built;
      Read  : E.Error_Info;
   begin
      if Asked = "" then
         Outcome := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Outcome, "name", "a task: /brief TASK");
         Pres.Report (Screen, Outcome);
         Last_Status := E.Exit_Status (Outcome);
         return;
      end if;
      Cx.Build (Store, Asked, Cx.Profile (Store, ""), Made, Read);
      if E.Is_Error (Read) then
         Pres.Report (Screen, Read);
         Last_Status := E.Exit_Status (Read);
         return;
      end if;
      Pres.Put_Note (Screen, "cli.brief.head",
                     [Loc.Named ("name", Asked), Loc.Named ("count", Image (Cx.Cost (Made))),
                      Loc.Named ("total", Image (Cx.Budget (Made)))]);
      for Index in 1 .. Cx.Included_Count (Made) loop
         declare
            One : constant Cx.Item := Cx.Included_At (Made, Index);
         begin
            Pres.Put_Note (Screen, "cli.brief.in",
                           [Loc.Named ("name", To_String (One.Id)),
                            Loc.Named ("detail", To_String (One.Kind) & ", "
                                       & Ada.Characters.Handling.To_Lower (Cx.Priority'Image (One.Rank))
                                       & "," & Natural'Image (Cx.Estimate (To_String (One.Text))) & " tokens")]);
         end;
      end loop;
      for Index in 1 .. Cx.Excluded_Count (Made) loop
         Pres.Put_Note (Screen, "cli.brief.out",
                        [Loc.Named ("name", To_String (Cx.Excluded_At (Made, Index).Id)),
                         Loc.Named ("detail", Cx.Excluded_Why (Made, Index))]);
      end loop;
   end Answer;
begin
   if Word = "/brief" then
      With_Store (Answer'Access);
   end if;
end Route_Brief;
