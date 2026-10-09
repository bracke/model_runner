separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Why is

   procedure Answer (Store : in out S.Store) is
      Next  : constant Tk.Next_Work := Tk.Next_Work_Of (Store);
      Given : constant String := Ada.Characters.Handling.To_Upper (Argument (1));
      Asked : constant String :=
        (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
         then "TASK-" & [1 .. Integer'Max (0, 3 - Given'Length) => '0'] & Given
         else Given);
   begin
      --  No task named: what /work would take, or why it would take
      --  nothing.
      if Asked = "" then
         if not Next.Runnable.Is_Empty then
            Pres.Put_Note (Screen, "cli.why.next", [Loc.Named ("name", Next.Runnable.First_Element)]);
         elsif not Next.Blocked.Is_Empty then
            Pres.Put_Note (Screen, "cli.why.nothing_ready",
                           [Loc.Named ("count", Image (Natural (Next.Blocked.Length))),
                            Loc.Named ("name", Next.Blocked.First_Element),
                            Loc.Named ("detail", Next.Why_Not.First_Element)]);
         else
            Pres.Put_Note (Screen, "cli.why.nothing");
         end if;
         return;
      end if;

      if Tk.State_Of (Store, Asked) = "" then
         Outcome := E.Make (E.Framework_Not_Found);
         E.Add_Text (Outcome, "name", Asked);
         Pres.Report (Screen, Outcome);
         Last_Status := E.Exit_Status (Outcome);
         return;
      end if;

      if Next.Runnable.Contains (Asked) then
         Pres.Put_Note
           (Screen,
            (if Next.Runnable.First_Element = Asked then "cli.why.runnable_first" else "cli.why.runnable"),
            [Loc.Named ("name", Asked), Loc.Named ("value", Next.Runnable.First_Element)]);
      elsif Next.Blocked.Contains (Asked) then
         Pres.Put_Note (Screen, "cli.why.blocked",
                        [Loc.Named ("name", Asked),
                         Loc.Named ("detail", Next.Why_Not (Next.Blocked.Find_Index (Asked)))]);
      elsif Next.Awaiting.Contains (Asked) then
         Pres.Put_Note (Screen, "cli.why.candidate", [Loc.Named ("name", Asked)]);
      else
         Pres.Put_Note (Screen, "cli.why.state",
                        [Loc.Named ("name", Asked), Loc.Named ("value", Tk.State_Of (Store, Asked))]);
      end if;
   end Answer;
begin
   if Word = "/why" then
      With_Store (Answer'Access);
   end if;
end Route_Why;
