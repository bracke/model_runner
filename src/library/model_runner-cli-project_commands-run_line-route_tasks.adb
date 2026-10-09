separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Tasks is
begin
   if Word = "/task" and then Argument (1) in "accept" | "reject" | "cancel" | "reopen" | "reconsider"
     and then Argument (3) /= ""
     and then (for all Index in 2 .. Natural (Positional.Length) =>
                 Ada.Strings.Fixed.Head (Positional (Index), 5) = "TASK-")
   then
      declare
         Named : constant Names.Vector := Positional;
      begin
         --  The way on said once, at the end, for the first of them.
         for Index in 2 .. Natural (Named.Length) loop
            Pres.Hold_Next_Steps (Screen, True);
            Command.Action := T.To_Bounded (Named (1));
            Command.Action_Argument := T.To_Bounded (Named (Index));
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
            Last_Status := Natural'Max (Last_Status, Status);
         end loop;
         Pres.Hold_Next_Steps (Screen, False);
         if Named (1) in "accept" | "reopen" | "reconsider" then
            Say_First_Ready (Named, 2);
         end if;
      end;
   elsif Word = "/task" and then Argument (1) = "complete"
     and then (Argument (3) /= "" or else Argument (2) = "all")
   then
      --  Several completed by hand, or all the open ones -- code there
      --  already, taken as done a task at a time, each by its checks.
      declare
         Named : Names.Vector;
      begin
         if Argument (2) = "all" then
            declare
               Store : S.Store;
               Read  : E.Error_Info;
            begin
               S.Open_To_Read (Store, Here, Read);
               if E.Is_Ok (Read) then
                  --  Not the candidates: no one has said they are to
                  --  be done at all -- each is completed by its ID.
                  Named.Append (Tk.List (Store, "accepted"));
                  --  Failed and stopped too: done by hand is what their
                  --  way on said, as it is for one named alone.
                  Named.Append (Tk.List (Store, "failed"));
                  Named.Append (Tk.List (Store, "blocked"));
               end if;
               S.Close (Store);
            end;
         else
            for Index in 2 .. Natural (Positional.Length) loop
               Named.Append (Positional (Index));
            end loop;
         end if;
         if Named.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.nothing_to_complete");
         --  All of them taken as done by hand: each named, with how it
         --  stands, and asked first where there is someone to ask.
         elsif Argument (2) = "all" and then Model_Runner.CLI.Choosers.Is_Available (Screen) then
            declare
               Store  : S.Store;
               Read   : E.Error_Info;
               Listed : Unbounded_String;
            begin
               S.Open_To_Read (Store, Here, Read);
               for Id of Named loop
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                                  & Id & " (" & (if E.Is_Ok (Read) then Tk.State_Of (Store, Id) else "?") & ")");
               end loop;
               S.Close (Store);
               Pres.Put_Message (Screen, "cli.project.complete_all_confirm",
                                 [Loc.Named ("detail", To_String (Listed))]);
               if not Answered_Yes (Screen) then
                  Pres.Put_Message (Screen, "cli.project.complete_all_kept");
                  Named.Clear;
               end if;
            end;
         end if;
         --  Each after what it waits for and its parts: a dependant
         --  completed before what it depends on would only be refused.
         if Argument (2) = "all" and then Natural (Named.Length) > 1 then
            declare
               Store   : S.Store;
               Read    : E.Error_Info;
               Left    : Names.Vector := Named;
               Ordered : Names.Vector;
            begin
               S.Open_To_Read (Store, Here, Read);
               if E.Is_Ok (Read) then
                  while not Left.Is_Empty loop
                     declare
                        Picked : Natural := 0;
                     begin
                        for Index in 1 .. Natural (Left.Length) loop
                           declare
                              Defined : R.Item;
                              Got     : E.Error_Info;
                           begin
                              Tk.Definition (Store, Left (Index), Defined, Got);
                              if not (for some Other of Model_Runner.Framework.Lines_Of
                                                         (Ada.Strings.Fixed.Translate
                                                            (R.Get (Defined, "depends_on"),
                                                             Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                                        => Left.Contains (Ada.Strings.Fixed.Trim (Other, Ada.Strings.Both)))
                                and then not (for some Child of Tk.Children (Store, Left (Index)) =>
                                                Left.Contains (Child))
                              then
                                 Picked := Index;
                                 exit;
                              end if;
                           end;
                        end loop;
                        --  Waiting on each other: the rest as they come.
                        if Picked = 0 then
                           Picked := 1;
                        end if;
                        Ordered.Append (Left (Picked));
                        Left.Delete (Picked);
                     end;
                  end loop;
                  Named := Ordered;
               end if;
               S.Close (Store);
            end;
         end if;
         for Position in 1 .. Natural (Named.Length) loop
            Command.Action := T.To_Bounded ("complete");
            Command.Action_Argument := T.To_Bounded (Named (Position));
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
            Last_Status := Natural'Max (Last_Status, Status);
            --  The project's checks failing fail every one alike: the
            --  rest left, and said, not run to fail the same way.
            if Status = E.Exit_Status (E.Make (E.Framework_Verification_Failed))
              and then Position < Natural (Named.Length)
            then
               Pres.Put_Note (Screen, "cli.project.complete_stopped",
                              [Loc.Named ("count", Image (Natural (Named.Length) - Position))]);
               exit;
            end if;
         end loop;
         --  Several: how many were completed, and which were not, with how
         --  each stands now.
         if Natural (Named.Length) > 1 then
            declare
               Store : S.Store;
               Read  : E.Error_Info;
               Done  : Natural := 0;
               Left  : Unbounded_String;
            begin
               S.Open_To_Read (Store, Here, Read);
               if E.Is_Ok (Read) then
                  for Id of Named loop
                     if Tk.State_Of (Store, Id) = Tk.Complete then
                        Done := Done + 1;
                     else
                        Append (Left, (if Left = Null_Unbounded_String then "" else ", ")
                                      & Id & " (" & Tk.State_Of (Store, Id) & ")");
                     end if;
                  end loop;
               end if;
               S.Close (Store);
               Pres.Put_Message (Screen, "cli.project.complete_summary",
                                 [Loc.Named ("count", Image (Done)),
                                  Loc.Named ("detail", (if Left = Null_Unbounded_String then "none"
                                                        else To_String (Left)))]);
            end;
         end if;
      end;

   elsif Word = "/task" and then Argument (1) in "accept" | "reject"
     and then Ada.Characters.Handling.To_Lower (Argument (2)) = "all"
   then
      --  Every candidate, each in turn, as if named alone.
      declare
         Named : Names.Vector;
         Store : S.Store;
         Read  : E.Error_Info;
         --  Asked, and the answer was no.
         Declined : Boolean := False;
      begin
         S.Open_To_Read (Store, Here, Read);
         if E.Is_Ok (Read) then
            Named.Append (Tk.List (Store, "candidate"));
            --  Accepting all takes up the failed and stopped too, as
            --  /accept all and /work all's way on say.
            if Argument (1) = "accept" then
               Named.Append (Tk.List (Store, "failed"));
               for Id of Tk.List (Store, "blocked") loop
                  if not (for some Reason of Tk.Ready (Store, Id).Reasons =>
                            Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0)
                  then
                     Named.Append (Id);
                  end if;
               end loop;
            end if;
         end if;
         --  Rejecting every one: asked first, naming them, as /reject
         --  all asks.
         if Argument (1) = "reject" and then not Named.Is_Empty
           and then Model_Runner.CLI.Choosers.Is_Available (Screen)
         then
            declare
               Listed : Unbounded_String;
            begin
               for Id of Named loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Id, Defined, Got);
                     Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Id
                                     & (if E.Is_Ok (Got) then " (" & R.Get (Defined, "title") & ")" else ""));
                  end;
               end loop;
               if not Model_Runner.CLI.Choosers.Confirmed_Line
                        (Screen, Pres.Next_Step_Value (Screen, "cli.project.reject_all_confirm",
                                                       [Loc.Named ("detail", To_String (Listed))]))
               then
                  Pres.Put_Note (Screen, "cli.project.reject_kept");
                  Named.Clear;
                  Declined := True;
               end if;
            end;
         end if;
         S.Close (Store);
         if Named.Is_Empty and then not Declined then
            Pres.Put_Note (Screen, "cli.project.no_pending");
         end if;
         --  Each one's way on held: the first that can be worked, once.
         Pres.Hold_Next_Steps (Screen, True);
         for Id of Named loop
            Command.Action := T.To_Bounded (Argument (1));
            Command.Action_Argument := T.To_Bounded (Id);
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
            Last_Status := Natural'Max (Last_Status, Status);
         end loop;
         Pres.Hold_Next_Steps (Screen, False);
         if Argument (1) = "accept" then
            Say_First_Ready (Named, 1);
         elsif not Named.Is_Empty then
            --  Rejected, and kept: how one comes back.
            Pres.Put_Note (Screen, "cli.next.reconsider_task", [Loc.Named ("name", Named.First_Element)]);
         end if;
      end;

   elsif Word = "/task" and then Argument (1) in "accept" | "reject" and then Argument (2) = "" then
      --  Accepting with no task named: as /accept is -- the one waiting,
      --  or those waiting, listed.
      With_Store (Decide'Access);
      if To_Task then
         Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
         Last_Status := Status;
      end if;

   elsif Word = "/task" then
      --  /task TASK-X is the task shown.
      if Ada.Strings.Fixed.Index (Argument (1), "TASK-") = Argument (1)'First then
         Command.Action := T.To_Bounded ("show");
         Command.Action_Argument := T.To_Bounded (Argument (1));
      else
         Command.Action := T.To_Bounded (Argument (1));
         --  --verbose is how much a look says, not what it is said of;
         --  in a title or a note it is the words typed.
         declare
            Said : constant String := Rest (2);
            At_V : constant Natural :=
              (if Argument (1) in "show" | "context" | "audit" | "list" | "plan"
               then Ada.Strings.Fixed.Index (" " & Said & " ", " --verbose ") else 0);
         begin
            Command.Action_Argument := T.To_Bounded
              (if At_V = 0 then Said
               else Ada.Strings.Fixed.Trim (Said (Said'First .. At_V - 1) & Said (At_V + 9 .. Said'Last),
                                            Ada.Strings.Both));
         end;
      end if;
      --  Several tasks named to look at or check -- TASK-1 TASK-2, or
      --  a comma apart: each in turn, as if named alone.
      declare
         Named : constant Names.Vector :=
           Split (Ada.Strings.Fixed.Translate (T.To_String (Command.Action_Argument),
                                               Ada.Strings.Maps.To_Mapping (",", " ")));
      begin
         if T.To_String (Command.Action) in "show" | "audit" | "diff" | "verify"
           and then Natural (Named.Length) > 1
           and then (for all One of Named =>
                       Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Upper (One), "TASK-") = One'First
                       or else (One'Length <= 6 and then (for all C of One => C in '0' .. '9')))
         then
            for Index in 1 .. Natural (Named.Length) loop
               Pres.Hold_Next_Steps (Screen, Index < Natural (Named.Length));
               Command.Action_Argument := T.To_Bounded (Named (Index));
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
            end loop;
            Pres.Hold_Next_Steps (Screen, False);
            return;
         end if;
      end;
      Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
      Last_Status := Status;

   end if;
end Route_Tasks;
