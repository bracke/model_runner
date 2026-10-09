separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Decide (Store : in out S.Store) is
   --  /accept and /reject, or /task accept and /task reject with no
   --  task named: the same question.
   Accepting : constant Boolean :=
     Word = "/accept" or else (Word = "/task" and then Argument (1) = "accept");
   --  A candidate serving only requirements since retired can never
   --  be worked: not offered to be decided, but let go of.
   function Live_Candidates return Names.Vector is
      Result : Names.Vector;
   begin
      for Id of Tk.List (Store, "candidate") loop
         declare
            Defined : R.Item;
            Read    : E.Error_Info;
         begin
            Tk.Definition (Store, Id, Defined, Read);
            declare
               Serves : constant Names.Vector :=
                 Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"));
            begin
               if Serves.Is_Empty
                 or else (for some Req of Serves =>
                            Nt.State_Of (Store, Nt.Requirement, Req)
                              not in "obsolete" | "rejected" | "superseded")
               then
                  Result.Append (Id);
               end if;
            end;
         end;
      end loop;
      return Result;
   end Live_Candidates;
   Tasks_Waiting : Names.Vector := Live_Candidates;
   Intent_Waiting : constant Names.Vector := Model_Runner.CLI.Intents.Pending (Store);

   --  A number alone is the candidate of that number, in whichever
   --  register: where several have one, which is asked, not guessed.
   Ambiguous : Unbounded_String;
   function Resolved (Given : String) return String is
      Matches : Names.Vector;
      function Number_Of (Id : String) return Natural is
         Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
      begin
         return (if Dash > 0 and then Dash < Id'Last
                   and then (for all C of Id (Dash + 1 .. Id'Last) => C in '0' .. '9')
                 then Natural'Value (Id (Dash + 1 .. Id'Last)) else 0);
      exception
         when others =>
            return 0;
      end Number_Of;
   begin
      if Given = "" or else Given'Length > 6
        or else not (for all C of Given => C in '0' .. '9')
      then
         return Given;
      end if;
      for Id of Tasks_Waiting loop
         if Number_Of (Id) = Natural'Value (Given) then
            Matches.Append (Id);
         end if;
      end loop;
      for Which of Intent_Waiting loop
         declare
            Id : constant String := Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last);
         begin
            if Number_Of (Id) = Natural'Value (Given) then
               Matches.Append (Id);
            end if;
         end;
      end loop;
      if Natural (Matches.Length) = 1 then
         return Matches.First_Element;
      elsif Natural (Matches.Length) > 1 then
         for Id of Matches loop
            Append (Ambiguous, (if Ambiguous = Null_Unbounded_String then "" else ", ") & Id);
         end loop;
         return "";
      end if;
      return "TASK-" & (if Given'Length >= 3 then Given else [1 .. 3 - Given'Length => '0'] & Given);
   end Resolved;
   Named_One : constant String := (if Word = "/task" then "" else Resolved (Argument (1)));
   Waiting : Names.Vector := Tasks_Waiting;
   Listed  : Unbounded_String;

   --  Those waiting, by identifier and title, as a question names
   --  what it would end.
   function Titled_Waiting return String is
      Said : Unbounded_String;
   begin
      for Which of Waiting loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
            Id    : constant String := Which (Colon + 1 .. Which'Last);
            Kind  : constant Nt.Intent_Kind :=
              (if Ada.Strings.Fixed.Index (Id, "DEC-") = Id'First then Nt.Decision
               elsif Ada.Strings.Fixed.Index (Id, "SPEC-") = Id'First then Nt.Specification
               else Nt.Requirement);
            Held  : Nt.Entity;
            Defined : R.Item;
            Got   : E.Error_Info;
            Title : Unbounded_String;
         begin
            if Ada.Strings.Fixed.Index (Id, "TASK-") = Id'First then
               Tk.Definition (Store, Id, Defined, Got);
               if E.Is_Ok (Got) then
                  Title := To_Unbounded_String (R.Get (Defined, "title"));
               end if;
            else
               Nt.Read (Store, Kind, Id, Held, Got);
               if E.Is_Ok (Got) then
                  Title := Held.Title;
               end if;
            end if;
            Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Id
                          & (if Title = Null_Unbounded_String then "" else " (" & To_String (Title) & ")"));
         end;
      end loop;
      return To_String (Said);
   end Titled_Waiting;
begin
   Waiting.Append (Intent_Waiting);
   --  Accepting all takes up again what failed or was stopped too,
   --  as each one's way on says /task accept does.
   if Accepting and then Ada.Characters.Handling.To_Lower (Named_One) = "all" then
      for Id of Tk.List (Store) loop
         if Tk.State_Of (Store, Id) = Tk.Failed
           or else (Tk.State_Of (Store, Id) = Tk.Blocked
                    and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                                Ada.Strings.Fixed.Index (Reason, "you stopped its work") > 0))
         then
            Tasks_Waiting.Append (Id);
            Waiting.Append (Id);
         end if;
      end loop;
   end if;

   --  all: every one waiting -- the registers' first, as accepting a
   --  requirement may make tasks, then the tasks that were waiting.
   if Ada.Characters.Handling.To_Lower (Named_One) = "all" then
      if Waiting.Is_Empty then
         Pres.Put_Note (Screen, "cli.project.no_pending");
         --  As /accept alone says it: a failed task to take up again.
         if Accepting and then not Tk.List (Store, "failed").Is_Empty then
            Pres.Put_Note (Screen, "cli.next.retry_only",
                           [Loc.Named ("name", Tk.List (Store, "failed").First_Element)]);
         else
            Say_Ready_Work (Store);
         end if;
         return;
      end if;
      --  Rejecting every one: asked first, naming them, where there is
      --  someone to ask -- as rejecting the one waiting is.
      if not Accepting and then Model_Runner.CLI.Choosers.Is_Available (Screen)
        and then not Model_Runner.CLI.Choosers.Confirmed_Line
                       (Screen,
                        Pres.Next_Step_Value
                          (Screen, "cli.project.reject_all_confirm",
                           [Loc.Named ("detail", Titled_Waiting)]))
      then
         Pres.Put_Note (Screen, "cli.project.reject_kept");
         return;
      end if;
      --  What was waiting when it was asked, decided; what that makes
      --  -- tasks for the requirements accepted -- named once at the
      --  end, for a person to take up in turn.
      Pres.Hold_Next_Steps (Screen, True);
      for Which of Intent_Waiting loop
         Model_Runner.CLI.Intents.Decide (Store, Which, Accepting, Screen, Say_Next => False);
      end loop;
      Pres.Hold_Next_Steps (Screen, False);
      --  What accepting made -- tasks for the requirements accepted --
      --  is decided with the rest: all is all.
      declare
         Made_Now : Unbounded_String;
      begin
         for Id of Tk.List (Store, "candidate") loop
            if not Tasks_Waiting.Contains (Id) then
               Append (Made_Now, (if Made_Now = Null_Unbounded_String then "" else " ") & Id);
               if Accepting then
                  Tasks_Waiting.Append (Id);
               end if;
            end if;
         end loop;
         if Made_Now /= Null_Unbounded_String and then Tasks_Waiting.Is_Empty then
            Pres.Put_Note (Screen, "cli.next.accept_tasks", [Loc.Named ("detail", To_String (Made_Now))]);
         --  Made now, and taken with the rest: said, so none is
         --  accepted unseen.
         elsif Made_Now /= Null_Unbounded_String and then Accepting then
            Pres.Put_Note (Screen, "cli.project.accept_all_derived",
                           [Loc.Named ("detail", To_String (Made_Now))]);
         end if;
      end;
      if not Tasks_Waiting.Is_Empty then
         declare
            Joined : Unbounded_String;
         begin
            --  A task serving only what is retired is left out, and
            --  said: accepting it would have it wait for ever.
            for Id of Tasks_Waiting loop
               declare
                  Defined : R.Item;
                  Got     : E.Error_Info;
                  Served  : Names.Vector;
                  Retired : Boolean := False;
               begin
                  Tk.Definition (Store, Id, Defined, Got);
                  Served := Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"));
                  Retired := not Served.Is_Empty
                    and then (for all Req of Served =>
                                Nt.State_Of (Store, Nt.Requirement, Req)
                                  in "obsolete" | "superseded" | "rejected");
                  if Retired and then Accepting then
                     Pres.Put_Note (Screen, "cli.project.accept_all_skipped",
                                    [Loc.Named ("name", Id)]);
                  else
                     Append (Joined, (if Joined = Null_Unbounded_String then "" else " ") & Id);
                  end if;
               end;
            end loop;
            if Joined = Null_Unbounded_String then
               return;
            end if;
            Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
            Command.Action_Argument := T.To_Bounded (To_String (Joined));
            To_Task := True;
         end;
      end if;
      return;
   end if;

   --  A number several registers have a candidate of: which, asked.
   if Ambiguous /= Null_Unbounded_String then
      declare
         Which : E.Error_Info := E.Make (E.Framework_Input_Invalid);
      begin
         E.Add_Text (Which, "name", "what to " & (if Accepting then "accept" else "reject"));
         E.Add_Text (Which, "value", Argument (1));
         E.Add_Text (Which, "detail", "several candidates have that number -- " & To_String (Ambiguous)
                     & "; name the one meant");
         Pres.Report (Screen, Which);
         Last_Status := E.Exit_Status (Which);
      end;
      return;
   end if;

   --  One named: that one, and only if it waits to be decided.
   if Named_One /= "" then
      if Tasks_Waiting.Contains (Named_One) then
         Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
         Command.Action_Argument := T.To_Bounded (Named_One);
         To_Task := True;
         return;
      end if;
      for Which of Intent_Waiting loop
         if Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last) = Named_One then
            Model_Runner.CLI.Intents.Decide (Store, Which, Accepting, Screen);
            return;
         end if;
      end loop;
      --  Failed or blocked, accepting is taking it up again, as
      --  /task accept does it.
      if Accepting and then Tk.State_Of (Store, Named_One) in "failed" | "blocked" then
         Command.Action := T.To_Bounded ("accept");
         Command.Action_Argument := T.To_Bounded (Named_One);
         To_Task := True;
         return;
      end if;
      --  There, and decided already: said as what it is now.
      if Tk.State_Of (Store, Named_One) /= "" then
         declare
            Settled : E.Error_Info := E.Make (E.Framework_Input_Invalid);
         begin
            E.Add_Text (Settled, "name", "what to " & (if Accepting then "accept" else "reject"));
            E.Add_Text (Settled, "value", Named_One);
            E.Add_Text (Settled, "detail", Named_One & " is " & Tk.State_Of (Store, Named_One)
                        & ", not a candidate waiting to be decided"
                        --  Taken on and to be let go: the way that is.
                        & (if not Accepting
                             and then Tk.State_Of (Store, Named_One) in "accepted" | "blocked" | "failed"
                           then "; /task cancel " & Named_One & " lets it go"
                           elsif Tk.State_Of (Store, Named_One) = Tk.Rejected
                           then "; /task reconsider " & Named_One & " makes it a candidate again"
                           else "; /accept alone lists those that are"));
            Pres.Report (Screen, Settled);
         end;
         return;
      end if;
      --  An entry of a register, decided already: said as what it is
      --  now, with its way on, as its register's command says it.
      declare
         Upper : constant String := Ada.Characters.Handling.To_Upper (Named_One);
         Kind  : constant Nt.Intent_Kind :=
           (if Ada.Strings.Fixed.Index (Upper, "DEC-") = Upper'First then Nt.Decision
            elsif Ada.Strings.Fixed.Index (Upper, "SPEC-") = Upper'First then Nt.Specification
            else Nt.Requirement);
         State : constant String := Nt.State_Of (Store, Kind, Upper);
         Command_Word : constant String :=
           (if Nt."=" (Kind, Nt.Decision) then "/decision"
            elsif Nt."=" (Kind, Nt.Specification) then "/spec" else "/req");
      begin
         if State /= "" then
            declare
               Settled : E.Error_Info := E.Make (E.Framework_Input_Invalid);
            begin
               E.Add_Text (Settled, "name", "what to " & (if Accepting then "accept" else "reject"));
               E.Add_Text (Settled, "value", Upper);
               E.Add_Text (Settled, "detail",
                           Upper & " is " & State & ", not a candidate waiting to be decided"
                           & (if State = Tk.Rejected then "; " & Command_Word & " reconsider " & Upper
                                                         & " takes it back"
                              elsif State = Tk.Accepted and then not Accepting
                              then "; " & Command_Word & " obsolete " & Upper & " retires it"
                              elsif State = Tk.Accepted then "; it counts already"
                              else "; /accept alone lists those that are"));
               Pres.Report (Screen, Settled);
               Last_Status := E.Exit_Status (Settled);
            end;
            return;
         end if;
      end;
      declare
         Missing : E.Error_Info := E.Make (E.Framework_Not_Found);
      begin
         E.Add_Text (Missing, "name", Named_One);
         Pres.Report (Screen, Missing);
         Pres.Put_Note (Screen, "cli.next.accept_lists");
      end;
      return;
   end if;

   if Waiting.Is_Empty then
      Pres.Put_Note (Screen, "cli.project.no_pending");
      --  /task's own form, as its other actions say it.
      if Word = "/task" then
         Pres.Put_Note (Screen, "cli.task.usage_line",
                        [Loc.Named ("value", "/task " & (if Accepting then "accept" else "reject")
                                             & " TASK-ID, or all")]);
      end if;
      --  A failed task is what there is to take up again: said.
      if Accepting and then not Tk.List (Store, "failed").Is_Empty then
         Pres.Put_Note (Screen, "cli.next.retry_only",
                        [Loc.Named ("name", Tk.List (Store, "failed").First_Element)]);
      else
         Say_Ready_Work (Store);
      end if;
   elsif Natural (Waiting.Length) > 1 then
      --  Each as the command that decides it.
      for Id of Tasks_Waiting loop
         declare
            Defined : R.Item;
            Got     : E.Error_Info;
         begin
            Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Got);
            Append (Listed, (if Listed = Null_Unbounded_String then "" else [1 => ASCII.LF])
                    & "/task " & (if Accepting then "accept " else "reject ") & Id
                    & "  (" & R.Get (Defined, "title") & ")");
         end;
      end loop;
      for Which of Intent_Waiting loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
            Kind  : constant String := Which (Which'First .. Colon - 1);
            Register : constant Nt.Intent_Kind :=
              (if Kind = "requirement" then Nt.Requirement
               elsif Kind = "decision" then Nt.Decision else Nt.Specification);
            Held     : Nt.Entity;
            Got      : E.Error_Info;
         begin
            Nt.Read (Store, Register, Which (Colon + 1 .. Which'Last), Held, Got);
            Append (Listed, (if Listed = Null_Unbounded_String then "" else [1 => ASCII.LF])
                    & "/"
                    & (if Kind = "requirement" then "req"
                       elsif Kind = "decision" then "decision" else "spec")
                    & (if Accepting then " accept " else " reject ")
                    & Which (Colon + 1 .. Which'Last)
                    & (if E.Is_Ok (Got) then "  (" & To_String (Held.Title) & ")" else ""));
         end;
      end loop;
      --  Listed, not refused: asking what waits is what /accept alone
      --  does when there is more than one.
      --  Each on its own line, as the command that decides it.
      Pres.Put_Message (Screen, (if Accepting then "cli.project.pending_many"
                                 else "cli.project.pending_many_reject"));
      for Line of Model_Runner.Framework.Lines_Of (To_String (Listed)) loop
         Pres.Put_Message (Screen, "cli.project.pending_one", [Loc.Named ("detail", Line)]);
      end loop;
   --  Rejecting the one waiting, unnamed: asked first, where there is
   --  someone to ask -- typed to see what waits, it would lose it.
   elsif not Accepting and then Named_One = "" and then Model_Runner.CLI.Choosers.Is_Available (Screen)
     and then not Model_Runner.CLI.Choosers.Confirmed_Line
                    (Screen,
                     Pres.Next_Step_Value
                       (Screen, "cli.project.reject_one_confirm",
                        [Loc.Named ("name", (if Intent_Waiting.Is_Empty then Waiting.First_Element
                                             else Intent_Waiting.First_Element (Ada.Strings.Fixed.Index
                                                    (Intent_Waiting.First_Element, ":") + 1
                                                  .. Intent_Waiting.First_Element'Last)))]))
   then
      Pres.Put_Note (Screen, "cli.project.reject_kept");
   elsif Intent_Waiting.Is_Empty then
      Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
      Command.Action_Argument := T.To_Bounded (Waiting.First_Element);
      To_Task := True;
   else
      --  A requirement, specification or decision: decided here.
      Model_Runner.CLI.Intents.Decide
        (Store, Intent_Waiting.First_Element, Accepting, Screen);
   end if;
end Decide;
