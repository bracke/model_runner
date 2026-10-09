separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Cancel is
begin
   if Word = "/cancel" then
      if Argument (1) = "" then
         Pres.Put_Note (Screen, "cli.project.nothing_running");
      else
         --  Asked first at a terminal: a cancelled task is ended, and its
         --  agent stopped.
         --  Work waiting in a workspace is refused or asked about by the
         --  cancel itself -- with the way to keep it -- not asked here
         --  first to be refused after.
         if Model_Runner.CLI.Choosers.Is_Available (Screen) and then Argument (2) not in "yes" | "anyway"
           and then not Waiting_In_Workspace (Argument (1))
         then
            declare
               Store  : S.Store;
               Read   : E.Error_Info;
               Titled : Unbounded_String;
            begin
               if S.Is_Initialized (Here) then
                  S.Open_To_Read (Store, Here, Read);
                  --  None such, or all: said before anything is asked.
                  if E.Is_Ok (Read) and then Tk.State_Of (Store, Argument (1)) = "" then
                     S.Close (Store);
                     if Ada.Characters.Handling.To_Lower (Argument (1)) = "all" then
                        Outcome := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Outcome, "name", "the task to cancel");
                        E.Add_Text (Outcome, "value", "all");
                        E.Add_Text (Outcome, "detail", "a task is cancelled one at a time, each asked about:"
                                    & " /task cancel TASK-ID");
                     else
                        Outcome := E.Make (E.Framework_Not_Found);
                        E.Add_Text (Outcome, "name", Argument (1));
                     end if;
                     Pres.Report (Screen, Outcome);
                     return;
                  --  One that cannot be cancelled is said so before it is
                  --  asked about: a candidate is rejected, one ended is
                  --  ended already.
                  elsif E.Is_Ok (Read)
                    and then Tk.State_Of (Store, Argument (1))
                             in "candidate" | "complete" | "cancelled" | "rejected"
                  then
                     declare
                        Now : constant String := Tk.State_Of (Store, Argument (1));
                     begin
                        S.Close (Store);
                        Outcome := E.Make (E.Framework_Transition_Invalid);
                        E.Add_Text (Outcome, "name", Argument (1));
                        E.Add_Text (Outcome, "value", Now);
                        E.Add_Text (Outcome, "expected", "cancelled");
                        E.Add_Text (Outcome, "detail",
                                    (if Now = Tk.Candidate
                                     then "a candidate is not cancelled but rejected: /task reject "
                                          & Argument (1)
                                     else "it is " & Now & " already"));
                        Pres.Report (Screen, Outcome);
                        Last_Status := E.Exit_Status (Outcome);
                        return;
                     end;
                  end if;
                  if E.Is_Ok (Read) and then Tk.State_Of (Store, Argument (1)) /= "" then
                     declare
                        Defined : R.Item;
                     begin
                        Tk.Definition (Store, Argument (1), Defined, Read);
                        Titled := To_Unbounded_String
                          (R.Get (Defined, "title") & ", " & Tk.State_Of (Store, Argument (1))
                           & (if Tk.State_Of (Store, Argument (1)) = "running"
                              then "; its agent is stopped" else "")
                           & Model_Runner.CLI.Tasks.Waiting_On_It (Store, Argument (1)));
                     end;
                  end if;
                  S.Close (Store);
               end if;
               Pres.Put_Message (Screen, "cli.project.cancel.confirm",
                                 [Loc.Named ("name", Argument (1)),
                                  Loc.Named ("detail", To_String (Titled))]);
               if not Answered_Yes (Screen) then
                  Pres.Put_Message (Screen, "cli.project.cancel.kept", [Loc.Named ("name", Argument (1))]);
                  return;
               end if;
            end;
         end if;
         Command.Action := T.To_Bounded ("cancel");
         Command.Cancel_Confirmed := True;
         Command.Action_Argument := T.To_Bounded
           (Argument (1) & (if Argument (2) = "anyway" then " anyway" else ""));
         Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
         Last_Status := Status;

         --  What its work left in the project, named: cancelling ends
         --  the task, not what it wrote.
         declare
            Store : S.Store;
            Read  : E.Error_Info;
            Held  : R.Item;
         begin
            if S.Is_Initialized (Here) then
               S.Open_To_Read (Store, Here, Read);
               if E.Is_Ok (Read) and then Tk.State_Of (Store, Argument (1)) = "cancelled" then
                  S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument (1) & ".state", Held, Read);
                  if E.Is_Ok (Read) and then R.Get (Held, "changed_files") /= ""
                    and then R.Get (Held, "current_workspace") = ""
                  then
                     declare
                        Files : Unbounded_String;
                     begin
                        for Path of Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files")) loop
                           Append (Files, (if Files = Null_Unbounded_String then "" else ", ") & Path);
                        end loop;
                        Pres.Put_Note (Screen, "cli.project.cancel.left",
                                       [Loc.Named ("name", Argument (1)),
                                        Loc.Named ("detail", To_String (Files))]);
                     end;
                  end if;
               end if;
               S.Close (Store);
            end if;
         end;
      end if;

   end if;
end Route_Cancel;
