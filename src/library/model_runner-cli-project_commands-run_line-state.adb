separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure State (Store : in out S.Store) is
   Config : R.Item;
   Read   : E.Error_Info;
   --  Advice found among the counts, said after them.
   Unserved   : Names.Vector;
   Last_Check : Unbounded_String;

   procedure Line_Of (Key : String; Value : String) is
   begin
      Pres.Put_Indented
        (Screen, "cli.task.field",
         [Loc.Named ("name", Pres.Message_Value (Screen, Key)),
          Loc.Named ("value", Value)]);
   end Line_Of;

   --  Stopped by the person: blocked, and said apart, as /task list
   --  says it.
   function Stopped (Id : String) return Boolean
   is (Tk.State_Of (Store, Id) = Tk.Blocked
       and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                   Ada.Strings.Fixed.Index (Reason, "you stopped its work") > 0));

   --  Waiting for its parts: blocked, and no failure, said apart.
   function Parts_Wait (Id : String) return Boolean
   is (Tk.State_Of (Store, Id) = Tk.Blocked
       and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                   Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0));

   --  Parts, as /task list says them, and which of them failed.
   function Parts_Said (Id, Why : String) return String is
      At_Children : constant Natural := Ada.Strings.Fixed.Index (Why, "waiting for its children");
      Failed      : Unbounded_String;
   begin
      if At_Children = 0 then
         return Why;
      end if;
      for Child of Tk.Children (Store, Id) loop
         if Tk.State_Of (Store, Child) = Tk.Failed then
            Append (Failed, (if Failed = Null_Unbounded_String then "" else " ") & Child);
         end if;
      end loop;
      return Why (Why'First .. At_Children - 1) & "waiting for its parts"
        & Why (At_Children + 24 .. Why'Last)
        & (if Failed = Null_Unbounded_String then ""
           else " -- " & To_String (Failed) & " failed: /task accept " & To_String (Failed)
                & (if Ada.Strings.Unbounded.Index (Failed, " ") > 0 then " tries them again"
                   else " tries it again"));
   end Parts_Said;

   --  Which of the blocked a name means: stopped, parts, or the rest.
   function Of_Kind (Id, State_Name : String) return Boolean
   is (if State_Name = "stopped" then Stopped (Id)
       elsif State_Name = "parts" then Parts_Wait (Id)
       elsif State_Name = "blocked" then not Stopped (Id) and then not Parts_Wait (Id)
       else True);

   function Count (State_Name : String) return String is
      Counted : Natural := 0;
   begin
      for Id of Tk.List (Store, (if State_Name in "stopped" | "parts" then "blocked" else State_Name)) loop
         if Of_Kind (Id, State_Name) then
            Counted := Counted + 1;
         end if;
      end loop;
      return Image (Counted);
   end Count;

   --  The tasks in a state that needs a person, each with why.
   procedure Which (State_Name : String) is
   begin
      for Id of Tk.List (Store, (if State_Name in "stopped" | "parts" then "blocked" else State_Name)) loop
         declare
            Reasons : constant Names.Vector := Tk.Ready (Store, Id).Reasons;
            Why     : constant String := (if Reasons.Is_Empty then State_Name else Reasons.First_Element);
         begin
            if Of_Kind (Id, State_Name) then
               Pres.Put_Indented
                 (Screen, "cli.project.which",
                  [Loc.Named ("name", Id),
                   Loc.Named ("value", Parts_Said (Id,
                                          (if Ada.Strings.Fixed.Head (Why, 15)
                                                in "it is blocked: " | "it is stopped: "
                                             and then State_Name in "stopped" | "parts"
                                           then Why (Why'First + 15 .. Why'Last) else Why)))], Indent => 4);
            end if;
         end;
      end loop;
   end Which;

   Ready : Natural := 0;
begin
   Config := Model_Runner.Framework.Configurations.Required (Store);
   --  In groups, each under its title, as /task show has a task: the
   --  project, its registers, its tasks, its checks, its agents, and
   --  what needs a person.
   Pres.Put_Header (Screen, "cli.state.section.project");
   Line_Of ("cli.project.template", R.Get (Config, "template_id"));
   Line_Of ("cli.project.configuration", Image (R.Revision (Config)));
   --  A project with nothing in it yet: said in a line, with how to
   --  begin, not as a column of noughts.
   if Nt.List (Store, Nt.Requirement).Is_Empty and then Nt.List (Store, Nt.Specification).Is_Empty
     and then Nt.List (Store, Nt.Decision).Is_Empty and then Tk.List (Store).Is_Empty
   then
      Pres.Put_Note (Screen, "cli.project.state_empty");
      return;
   end if;
   --  Requirements that still stand: none rejected, retired or
   --  replaced; those waiting to be decided counted apart.
   Pres.Put_Section (Screen, "cli.state.section.registers");
   declare
      Standing : Natural := 0;
   begin
      for Id of Nt.List (Store, Nt.Requirement) loop
         declare
            Held : Nt.Entity;
            Got  : E.Error_Info;
         begin
            Nt.Read (Store, Nt.Requirement, Id, Held, Got);
            if E.Is_Ok (Got)
              and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
            then
               Standing := Standing + 1;
            end if;
         end;
      end loop;
      Line_Of ("cli.project.requirements", Image (Standing));
   end;
   Line_Of ("cli.project.candidate_requirements",
            Image (Natural (Nt.List (Store, Nt.Requirement,
                                     Nt.First_State (Nt.Requirement)).Length)));
   Line_Of ("cli.project.verified",
            Image (Natural (Nt.List (Store, Nt.Requirement, "verified").Length)));
   --  Specifications and decisions waiting to be decided, where any
   --  do: /accept lists them with the requirements.
   declare
      Specs : constant Natural :=
        Natural (Nt.List (Store, Nt.Specification, Nt.First_State (Nt.Specification)).Length);
      Decisions : constant Natural :=
        Natural (Nt.List (Store, Nt.Decision, Nt.First_State (Nt.Decision)).Length);
   begin
      --  Those in force, where any are: what governs the work.
      if not Nt.List (Store, Nt.Decision, "accepted").Is_Empty then
         Line_Of ("cli.project.accepted_decisions",
                  Image (Natural (Nt.List (Store, Nt.Decision, "accepted").Length)));
      end if;
      if not Nt.List (Store, Nt.Specification, "accepted").Is_Empty then
         Line_Of ("cli.project.accepted_specs",
                  Image (Natural (Nt.List (Store, Nt.Specification, "accepted").Length)));
      end if;
      if Specs > 0 then
         Line_Of ("cli.project.candidate_specs", Image (Specs));
      end if;
      if Decisions > 0 then
         Line_Of ("cli.project.proposed_decisions", Image (Decisions));
      end if;
   end;
   --  Accepted, and nothing open or done serves it: no work will
   --  carry it out unless some is made.
   for Id of Nt.List (Store, Nt.Requirement, "accepted") loop
      declare
         Served : Boolean := False;
      begin
         for Task_Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
               Got     : E.Error_Info;
            begin
               Tk.Definition (Store, Task_Id, Defined, Got);
               Served := Served
                 or else (E.Is_Ok (Got)
                          and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                          and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                     .Contains (Id));
            end;
         end loop;
         if not Served then
            Unserved.Append (Id);
         end if;
      end;
   end loop;
   for Id of Tk.List (Store, "accepted") loop
      if Tk.Ready (Store, Id).Ready then
         Ready := Ready + 1;
      end if;
   end loop;
   Pres.Put_Section (Screen, "cli.state.section.tasks");
   Line_Of ("cli.project.candidates", Count ("candidate"));
   Line_Of ("cli.project.accepted", Count ("accepted"));
   Line_Of ("cli.project.ready", Image (Ready));
   --  Accepted and not ready: each, with what it waits for -- a task,
   --  or a requirement since retired.
   --  Refused -- its permissions keep it from the work -- apart from
   --  waiting, as /task list says them.
   declare
      function Refused (Id : String) return Boolean is
         Now : constant Tk.Readiness := Tk.Ready (Store, Id);
      begin
         return not Now.Ready
           and then not (for some Reason of Now.Reasons =>
                           Ada.Strings.Fixed.Index (Reason, "waits for") > 0
                           or else Ada.Strings.Fixed.Index (Reason, "waiting for") > 0
                           or else Ada.Strings.Fixed.Index (Reason, "a candidate") > 0)
           and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= "";
      end Refused;
      Waiting_Count, Refused_Count : Natural := 0;
   begin
      for Id of Tk.List (Store, "accepted") loop
         if Refused (Id) then
            Refused_Count := Refused_Count + 1;
         elsif not Tk.Ready (Store, Id).Ready then
            Waiting_Count := Waiting_Count + 1;
         end if;
      end loop;
      for Refusing in Boolean loop
         if (if Refusing then Refused_Count else Waiting_Count) > 0 then
            Line_Of ((if Refusing then "cli.project.refused" else "cli.project.waiting"),
                     Image (if Refusing then Refused_Count else Waiting_Count));
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  if not Now.Ready and then Refused (Id) = Refusing then
                     Pres.Put_Indented
                       (Screen, "cli.project.which",
                        [Loc.Named ("name", Id),
                         Loc.Named ("value", (if Now.Reasons.Is_Empty then "waiting"
                                              else Now.Reasons.First_Element))], Indent => 4);
                  end if;
               end;
            end loop;
         end if;
      end loop;
   end;
   --  Work a person takes in: each, with how.
   declare
      Waiting : Names.Vector;
   begin
      for Id of Tk.List (Store, "verification") loop
         if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
            Waiting.Append (Id);
         end if;
      end loop;
      if not Waiting.Is_Empty then
         Line_Of ("cli.project.to_integrate", Image (Natural (Waiting.Length)));
         for Id of Waiting loop
            Pres.Put_Indented
              (Screen, "cli.project.which",
               [Loc.Named ("name", Id),
                Loc.Named ("value", Tk.Ready (Store, Id).Reasons.First_Element)], Indent => 4);
         end loop;
      end if;
   end;
   Line_Of ("cli.project.blocked", Count ("blocked"));
   Which ("blocked");
   Line_Of ("cli.project.stopped", Count ("stopped"));
   Which ("stopped");
   Line_Of ("cli.project.waiting_parts", Count ("parts"));
   Which ("parts");
   Line_Of ("cli.project.running", Count ("running"));
   --  Each running, with the agent that runs it.
   for Id of Tk.List (Store, "running") loop
      declare
         Runs_It : constant String := Model_Runner.Framework.Agents.Working_On (Store, Id);
      begin
         Pres.Put_Indented
           (Screen, "cli.project.which",
            [Loc.Named ("name", Id),
             Loc.Named ("value", (if Runs_It = "" then "running"
                                  else "its agent " & Runs_It & " is working on it"))], Indent => 4);
      end;
   end loop;
   Line_Of ("cli.project.complete", Count ("complete"));
   Line_Of ("cli.project.failed", Count ("failed"));
   Which ("failed");
   --  Ended undone, counted too: a task let go is still one there is.
   Line_Of ("cli.project.cancelled", Count ("cancelled"));
   Line_Of ("cli.project.rejected", Count ("rejected"));
   declare
      Last : constant Names.Vector :=
        S.Names (Store, Model_Runner.Framework.Verification_Area);
      Held : R.Item;
   begin
      --  Checks, where any has run.
      if not Last.Is_Empty then
         Pres.Put_Section (Screen, "cli.state.section.checks");
         S.Read (Store, Model_Runner.Framework.Verification_Area,
                 Last.Last_Element, Held, Read);
         Last_Check := To_Unbounded_String (Last.Last_Element);
         Pres.Put_Pair (Screen, "cli.task.field", Pres.Message_Value (Screen, "cli.project.last_check"),
                        Last.Last_Element & " "
                        & (if R.Get (Held, "passed") = "true" then "passed" else "failed"),
                        (if R.Get (Held, "passed") = "true" then Pres.Good else Pres.Bad), Indent => 2);
      end if;
   end;
   declare
      --  The last run of every profile the full verification is made
      --  of, or of the default where it names none: all passed, or
      --  not.
      Full   : Names.Vector := Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full"));
      Latest : Unbounded_String;
      Result : Unbounded_String;
   begin
      --  As /check full chooses it: a profile called full first.
      if R.Has (Config, "profile.full") then
         Full.Clear;
         Full.Append ("full");
      elsif Full.Is_Empty then
         Full.Append (R.Get (Config, "scalar.verification.default"));
      end if;
      for Name of S.Names (Store, Model_Runner.Framework.Verification_Area) loop
         declare
            Held : R.Item;
         begin
            S.Read (Store, Model_Runner.Framework.Verification_Area, Name, Held, Read);
            --  A test is a profile that runs tests: a build in the
            --  full verification is not one.
            --  And on the project: a check run in a task's workspace
            --  tested that workspace, not the project.
            if E.Is_Ok (Read) and then Full.Contains (R.Get (Held, "profile"))
              and then R.Get (Config, "scalar.profile_capability." & R.Get (Held, "profile"))
                       = "run_tests"
              and then R.Get (Held, "workspace") = ""
            then
               Latest := To_Unbounded_String (Name);
               Result := To_Unbounded_String
                 (if R.Get (Held, "passed") = "true" then "passed" else "failed");
            end if;
         end;
      end loop;
      --  The same run as the last check: said once.
      if Latest /= Null_Unbounded_String and then Latest /= Last_Check then
         Pres.Put_Pair (Screen, "cli.task.field", Pres.Message_Value (Screen, "cli.project.last_full"),
                        To_String (Latest) & " " & To_String (Result),
                        (if To_String (Result) = "passed" then Pres.Good else Pres.Bad), Indent => 2);
      end if;
   end;

   Pres.Put_Section (Screen, "cli.state.section.agents");
   Line_Of ("cli.project.agents_active",
            Image (Model_Runner.Framework.Agents.Active_Count (Store)));
   --  What confines every agent the session starts, where anything does.
   if Model_Runner.Framework.Permissions.Sandbox_Source /= "" then
      declare
         Shown : Unbounded_String;
      begin
         for Part of Model_Runner.Framework.Lines_Of
           (Model_Runner.Framework.Permissions.Image (Model_Runner.Framework.Permissions.Sandbox))
         loop
            Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Part);
         end loop;
         Line_Of ("cli.project.sandbox",
                  Model_Runner.Framework.Permissions.Sandbox_Source & ": " & To_String (Shown));
      end;
   end if;
   Pres.Put_Section (Screen, "cli.state.section.attention");
   --  What waits on a person besides tasks: issues not yet dealt
   --  with, and what does not hold together.
   declare
      Dismissed : constant Names.Vector := Dismissed_List (Store);
      Open      : Natural := 0;
      Counted   : Names.Vector;
   begin
      for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
         declare
            Result_Id : constant String :=
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            One       : Rs.Result;
            Got       : E.Error_Info;
         begin
            Rs.Read (Store, Result_Id, One, Got);
            if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
              and then not Dismissed.Contains (Result_Id)
              and then not Acted_On (Store, Result_Id, To_String (One.Summary))
              --  As /result counts: an attempt's issue whose task was
              --  taken up again since, or ended, is acted on.
              and then not (Task_Of_Issue (Store, One) /= ""
                            and then Tk.State_Of (Store, Task_Of_Issue (Store, One))
                                       in "accepted" | "running" | "verification" | "complete"
                                        | "cancelled" | "rejected")
              and then not Counted.Contains
                             (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
            then
               Counted.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
               Open := Open + 1;
            end if;
         end;
      end loop;
      --  What waits on a person to be decided, in every register.
      Line_Of ("cli.project.to_decide",
               Image (Natural (Tk.List (Store, "candidate").Length)
                      + Natural (Model_Runner.CLI.Intents.Pending (Store).Length)));
      Line_Of ("cli.project.open_issues", Image (Open));
      --  Failed or stopped work needs a person as much as an issue.
      declare
         Held_Up : Natural := Natural (Tk.List (Store, "failed").Length);
      begin
         --  Blocked, not by parts still open: /result's.
         for Id of Tk.List (Store, "blocked") loop
            if not (for some Reason of Tk.Ready (Store, Id).Reasons =>
                      Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0)
            then
               Held_Up := Held_Up + 1;
            end if;
         end loop;
         Line_Of ("cli.project.failed_or_stopped", Image (Held_Up));
      end;
      Line_Of ("cli.project.inconsistent",
               Image (Model_Runner.Framework.Consistency.Length
                        (Model_Runner.Framework.Consistency.Check (Store))));
   end;
   --  Events a later build wrote, left for it: said, or they would wait
   --  unseen.
   declare
      Unknown : constant Model_Runner.Framework.Name_Lists.Vector :=
        Model_Runner.Framework.Orchestration.Unknown_Waiting (Store);
      Words   : Unbounded_String;
   begin
      if not Unknown.Is_Empty then
         for Word of Unknown loop
            if Index (Words, Word) = 0 then
               Append (Words, (if Words = Null_Unbounded_String then "" else ", ") & Word);
            end if;
         end loop;
         Pres.Put_Note (Screen, "cli.project.unknown_events",
                        [Loc.Named ("count", Image (Natural (Unknown.Length))),
                         Loc.Named ("detail", To_String (Words))]);
      end if;
   end;
   --  Done and not verified: each, and how it is.
   for Id of Nt.List (Store, Nt.Requirement, "implemented") loop
      Pres.Put_Note (Screen, "cli.project.not_verified",
                     [Loc.Named ("name", Id),
                      Loc.Named ("detail",
                                 (if Vf.Why_Not_Verified (Store, Id) = ""
                                  then "its evidence holds; check " & Id & " records it verified"
                                  else Vf.Why_Not_Verified (Store, Id)))]);
   end loop;
   --  Recorded verified, and its evidence no longer holds: said, not
   --  counted on until it is judged again.
   for Id of Nt.List (Store, Nt.Requirement, "verified") loop
      declare
         Why : constant String := Vf.Why_Not_Verified (Store, Id);
      begin
         if Why /= "" then
            Pres.Put_Note (Screen, "cli.project.stale_verified",
                           [Loc.Named ("name", Id), Loc.Named ("detail", Why)]);
         end if;
      end;
   end loop;
   --  Accepted, and nothing serves it: after the counts, with a task
   --  that served it once and was cancelled, taken back.
   for Id of Unserved loop
      declare
         Cancelled : Unbounded_String;
         --  Cancelled, or rejected: taken back each its own way.
         Rejected  : Unbounded_String;
      begin
         for Task_Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
               Got     : E.Error_Info;
            begin
               Tk.Definition (Store, Task_Id, Defined, Got);
               if E.Is_Ok (Got)
                 and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")).Contains (Id)
               then
                  if Cancelled = Null_Unbounded_String and then Tk.State_Of (Store, Task_Id) = Tk.Cancelled then
                     Cancelled := To_Unbounded_String (Task_Id);
                  elsif Rejected = Null_Unbounded_String and then Tk.State_Of (Store, Task_Id) = Tk.Rejected then
                     Rejected := To_Unbounded_String (Task_Id);
                  end if;
               end if;
            end;
         end loop;
         if Cancelled = Null_Unbounded_String and then Rejected /= Null_Unbounded_String then
            Pres.Put_Note (Screen, "cli.project.unserved_rejected",
                           [Loc.Named ("name", Id), Loc.Named ("value", To_String (Rejected))]);
         elsif Cancelled /= Null_Unbounded_String then
            Pres.Put_Note (Screen, "cli.project.unserved_cancelled",
                           [Loc.Named ("name", Id), Loc.Named ("value", To_String (Cancelled))]);
         else
            Pres.Put_Note (Screen, "cli.project.unserved", [Loc.Named ("name", Id)]);
         end if;
      end;
   end loop;

   --  Failed or stopped tasks beside other work: their way on said
   --  too, not only the other work's.
   declare
      Ended_Badly : Unbounded_String;
   begin
      for Id of Tk.List (Store, "failed") loop
         Append (Ended_Badly, (if Ended_Badly = Null_Unbounded_String then "" else ", ") & Id & " (failed)");
      end loop;
      for Id of Tk.List (Store, "blocked") loop
         if not Parts_Wait (Id) then
            Append (Ended_Badly, (if Ended_Badly = Null_Unbounded_String then "" else ", ") & Id
                                 & (if Stopped (Id) then " (stopped)" else " (blocked)"));
         end if;
      end loop;
      if Ended_Badly /= Null_Unbounded_String
        and then (Ready > 0 or else not Tk.List (Store, "candidate").Is_Empty
                  or else not Model_Runner.CLI.Intents.Pending (Store).Is_Empty
                  --  A refused one's way on is said below: theirs too.
                  or else (for some Id of Tk.List (Store, "accepted") =>
                             Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= ""))
      then
         Pres.Put_Note (Screen, "cli.next.take_up_blocked", [Loc.Named ("detail", To_String (Ended_Badly))]);
      end if;
   end;
   --  The step that comes next, as the state stands: work to take in,
   --  a ready task, candidates to decide, or how to begin.
   declare
      To_Take   : Unbounded_String;
      Ready_One : Unbounded_String;
      --  Candidates said by the step below, or still to be said after it.
      Accept_Said : Boolean := False;
   begin
      for Id of Tk.List (Store, "verification") loop
         if To_Take = Null_Unbounded_String
           and then Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
         then
            To_Take := To_Unbounded_String (Id);
         end if;
      end loop;
      for Id of Tk.List (Store, "accepted") loop
         if Ready_One = Null_Unbounded_String and then Tk.Ready (Store, Id).Ready then
            Ready_One := To_Unbounded_String (Id);
         end if;
      end loop;
      if To_Take /= Null_Unbounded_String
        and then not Model_Runner.Framework.Workspaces.Conflict_Files
                       (Store, Model_Runner.Framework.Workspaces.Active_For (Store, To_String (To_Take)),
                        Unsettled_Only => True).Is_Empty
      then
         --  In conflict: settled first, as integrating plainly stops again.
         Pres.Put_Note (Screen, "cli.next.integrate_conflicted",
                        [Loc.Named ("name", To_String (To_Take)),
                         Loc.Named ("path", Model_Runner.Framework.Workspaces.Active_For
                                              (Store, To_String (To_Take)))]);
      elsif To_Take /= Null_Unbounded_String then
         Pres.Put_Note (Screen, "cli.next.integrate", [Loc.Named ("name", To_String (To_Take))]);
      elsif Ready_One /= Null_Unbounded_String and then Ready > 1 then
         Pres.Put_Note (Screen, "cli.next.work_all",
                        [Loc.Named ("count", Image (Ready)), Loc.Named ("name", To_String (Ready_One))]);
      elsif Ready_One /= Null_Unbounded_String then
         Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", To_String (Ready_One))]);
      --  Accepted, and kept from the work by its permissions: the way
      --  that is, before any candidate.
      elsif (for some Id of Tk.List (Store, "accepted") =>
               Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= "")
      then
         for Id of Tk.List (Store, "accepted") loop
            if Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= "" then
               Pres.Put_Note (Screen, "cli.next.state_refused",
                              [Loc.Named ("name", Id),
                               Loc.Named ("detail", Model_Runner.Framework.Work.Unable_Reason (Store, Id))]);
               exit;
            end if;
         end loop;
      elsif not Tk.List (Store, "candidate").Is_Empty
        or else not Model_Runner.CLI.Intents.Pending (Store).Is_Empty
      then
         --  Every candidate waiting, tasks and the registers' alike:
         --  one is decided by /accept, several listed by it.
         declare
            --  As /accept takes them: not a task serving only what is
            --  retired, which it leaves as it is.
            function Candidates return Names.Vector is
               Result : Names.Vector;
            begin
               for Id of Tk.List (Store, "candidate") loop
                  declare
                     Served : constant Names.Vector := Task_Requirements (Store, Id);
                  begin
                     if Served.Is_Empty
                       or else (for some Req of Served =>
                                  Nt.State_Of (Store, Nt.Requirement, Req)
                                    not in "obsolete" | "superseded" | "rejected")
                     then
                        Result.Append (Id);
                     end if;
                  end;
               end loop;
               return Result;
            end Candidates;
            Waiting : Names.Vector := Candidates;
         begin
            for Which of Model_Runner.CLI.Intents.Pending (Store) loop
               Waiting.Append (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
            end loop;
            if Waiting.Is_Empty then
               --  Only tasks serving what is retired: let go, not accepted.
               Pres.Put_Note (Screen, "cli.next.reject_retired",
                              [Loc.Named ("name", Tk.List (Store, "candidate").First_Element)]);
            elsif Natural (Waiting.Length) = 1 then
               Pres.Put_Note (Screen, "cli.next.accept_one",
                              [Loc.Named ("name", Waiting.First_Element)]);
            else
               Pres.Put_Note (Screen, "cli.next.accept_several",
                              [Loc.Named ("count", Image (Natural (Waiting.Length)))]);
            end if;
            Accept_Said := True;
         end;
      --  A failed task, nothing else open: tried again -- several, all.
      elsif Natural (Tk.List (Store, "failed").Length) > 1 then
         Pres.Put_Note (Screen, "cli.next.retry_all",
                        [Loc.Named ("detail", Joined_Names (Tk.List (Store, "failed")))]);
      elsif not Tk.List (Store, "failed").Is_Empty then
         Pres.Put_Note (Screen, "cli.next.retry_only",
                        [Loc.Named ("name", Tk.List (Store, "failed").First_Element)]);
      --  Blocked or stopped, nothing else open: taken up again.
      elsif (for some Id of Tk.List (Store, "blocked") => not Parts_Wait (Id)) then
         declare
            Taken_Up : Names.Vector;
         begin
            for Id of Tk.List (Store, "blocked") loop
               if not Parts_Wait (Id) then
                  Taken_Up.Append (Id & " (" & (if Stopped (Id) then "stopped" else "blocked") & ")");
               end if;
            end loop;
            Pres.Put_Note (Screen, "cli.next.take_up_blocked", [Loc.Named ("detail", Joined_Names (Taken_Up))]);
         end;
      elsif Tk.List (Store).Is_Empty and then Nt.List (Store, Nt.Requirement).Is_Empty then
         Pres.Put_Note (Screen, "cli.next.init");
      end if;
      --  Waiting to be decided, as its count above says, and another
      --  step said first: the deciding said too.
      if not Accept_Said then
         declare
            Waiting : Names.Vector;
         begin
            for Id of Tk.List (Store, "candidate") loop
               if Task_Requirements (Store, Id).Is_Empty
                 or else (for some Req of Task_Requirements (Store, Id) =>
                            Nt.State_Of (Store, Nt.Requirement, Req)
                              not in "obsolete" | "superseded" | "rejected")
               then
                  Waiting.Append (Id);
               end if;
            end loop;
            for Which of Model_Runner.CLI.Intents.Pending (Store) loop
               Waiting.Append (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
            end loop;
            if Natural (Waiting.Length) = 1 then
               Pres.Put_Note (Screen, "cli.next.accept_one", [Loc.Named ("name", Waiting.First_Element)]);
            elsif Natural (Waiting.Length) > 1 then
               Pres.Put_Note (Screen, "cli.next.accept_several",
                              [Loc.Named ("count", Image (Natural (Waiting.Length)))]);
            end if;
         end;
      end if;
   end;
end State;
