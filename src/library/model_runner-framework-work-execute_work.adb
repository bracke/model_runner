separate (Model_Runner.Framework.Work)
procedure Execute_Work
  (Item     : aliased in out Stores.Store;
   Task_Id  : String;
   Runner   : Agent_Runner'Class;
   Model    : Context.Model_Profile;
   Result   : out Report;
   Status   : out Model_Runner.Errors.Error_Info;
   Starting : access procedure (Agent_Id, Manifest_Id, Invocation_Id : String) := null)
is
   Change  : Stores.Transaction;
   Project : constant String :=
     Ada.Directories.Containing_Directory (Stores.Root (Item));
   Built   : Context.Built;
   Answer  : Unbounded_String;
   Ran     : E.Error_Info;
   Said    : Invocations.Claims;
   Held    : E.Error_Info;

   --  The state files an agent run as a process of its own changed, put
   --  back as they were: the project's state is the harness's to change.
   Tampered : Name_Lists.Vector;

   --  What of it could not be put back, each with why.
   Tamper_Left : Name_Lists.Vector;

   --  What it wrote that it may not, put back as it was; and what could
   --  not be, each with why.
   Put_Back_Files : Name_Lists.Vector;
   Not_Put_Back   : Name_Lists.Vector;

   --  Parts it asked for, made proposals of their own as its agent may
   --  not make children.
   Parts_Proposed : Name_Lists.Vector;

   --  The result its answer was kept as, which its end names.
   Last_Result : Unbounded_String;

   --  The parts its answer split the task into, as candidate children,
   --  how many it may have, and why not more.
   Split_Into  : Name_Lists.Vector;
   Split_Room  : Natural := Natural'Last;
   Split_Why   : Unbounded_String;

   --  What an earlier attempt left changed in the project, which this
   --  one may say it changed though it did not touch it again.
   function Changed_Before return Name_Lists.Vector is
      Held : Records.Item;
      Read : E.Error_Info;
   begin
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Read);
      return (if E.Is_Ok (Read) then Lines_Of (Records.Get (Held, "changed_files"))
              else Name_Lists.Empty_Vector);
   end Changed_Before;

   Earlier_Changed : constant Name_Lists.Vector := Changed_Before;

   --  What it changed that its permissions do not let it write.
   function Beyond_Permissions return String is
      Held_Agent : Agents.Agent;
      Read       : E.Error_Info;
      Named      : Unbounded_String;
   begin
      Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
      for Path of Result.Changed_Files loop
         if not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Source, Path)
           and then not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Specs, Path)
         then
            Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
         end if;
      end loop;
      return To_String (Named);
   end Beyond_Permissions;

   type Permission_Pair is array (1 .. 2) of Permissions.Capability;

   --  What it was allowed to write, which the files were not within.
   function Rule_Said return String is
      Held_Agent : Agents.Agent;
      Read       : E.Error_Info;
      Said       : Unbounded_String;
   begin
      Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
      if E.Is_Error (Read) then
         return "";
      end if;
      for One of Permission_Pair'(Permissions.Write_Source, Permissions.Write_Specs) loop
         Append (Said, (if Said = Null_Unbounded_String then "" else "; ")
                 & Permissions.Word (One) & " "
                 & (if not Held_Agent.Allowed (One).Granted then "not granted"
                    elsif Held_Agent.Allowed (One).Roots.Is_Empty
                    then (if Permissions."=" (One, Permissions.Write_Specs)
                          then "in docs/, doc/, specs/, spec/ and Markdown files" else "anywhere")
                    else "in " & Comma_Separated (Held_Agent.Allowed (One).Roots)));
      end loop;
      return " (its agent may write: " & To_String (Said) & ")";
   end Rule_Said;

   --  Said after the files refused: whether the session's sandbox,
   --  not the project, refused them.
   function Sandbox_Said (Paths : String) return String is
   begin
      for Path of Split_On (Paths, ',') loop
         if Permissions.Sandbox_Refuses (Trim (Path), Writing => True) then
            return " -- " & Permissions.Sandbox_Source & " refused them, not the project's"
              & " permissions";
         end if;
      end loop;
      return "";
   end Sandbox_Said;

   --  What its agent is told after its context, from what it holds.
   function Instructions_Here return String is
      Held_Agent : Agents.Agent;
      Read       : E.Error_Info;
   begin
      Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
      return (if E.Is_Error (Read) then Instructions_Of (Item, Task_Id)
              else Instructions_With
                     (Item, Task_Id, Held_Agent.Allowed,
                      (if Tasks.Kind_Policy (Item, Kind_Of (Item, Task_Id), "isolation") /= ""
                       then Tasks.Kind_Policy (Item, Kind_Of (Item, Task_Id), "isolation")
                       else Work_Setting (Item, "isolation")) = "workspace",
                      Helpers => Runner in Parenting_Runner'Class));
   end Instructions_Here;

   --  Whether it went over its token budget.
   Over_Budget : Boolean := False;

   --  What the call used, as the agent reports it.
   Used    : Invocations.Usage;

   --  Where the agent writes: the project, or its workspace, as its
   --  kind says, else the project.
   Kind     : constant String := Kind_Of (Item, Task_Id);
   use type Intent.Intent_Kind;
   Isolated : constant Boolean :=
     (if Tasks.Kind_Policy (Item, Kind, "isolation") /= ""
      then Tasks.Kind_Policy (Item, Kind, "isolation")
      else Work_Setting (Item, "isolation")) = "workspace";
   Place    : Unbounded_String := To_Unbounded_String (Project);

   --  End the work with the task moved and the agent recorded.
   --  Files it changed that its answer did not name, where it named
   --  some: said, as what a person looks at before trusting its report.
   function Unreported_Note return String is
      Said_Changed : constant Name_Lists.Vector :=
        Lines_Of (Replaced (Invocations.Claim (Said, "changed_files")));
      Unreported   : Name_Lists.Vector;
   begin
      for Path of Result.Changed_Files loop
         if not (for some Line of Said_Changed =>
                   Trim (Line) = Path or else Trim (Line) = "./" & Path)
         then
            Unreported.Append (Path);
         end if;
      end loop;
      return (if Unreported.Is_Empty or else Said_Changed.Is_Empty then ""
              else "it also changed files it did not report: " & Comma_Separated (Unreported));
   end Unreported_Note;

   --  What it said it changed and did not: rewritten as it was, or not
   --  touched at all.
   function Overclaimed_Note return String is
      Said_Changed : constant Name_Lists.Vector :=
        Lines_Of (Replaced (Invocations.Claim (Said, "changed_files")));
      Not_Changed  : Name_Lists.Vector;
   begin
      for Line of Said_Changed loop
         declare
            Path : constant String :=
              (if Trim (Line)'Length > 2 and then Trim (Line) (Trim (Line)'First .. Trim (Line)'First + 1) = "./"
               then Trim (Line) (Trim (Line)'First + 2 .. Trim (Line)'Last) else Trim (Line));
         begin
            if Path not in "" | "-" and then not Result.Changed_Files.Contains (Path) then
               Not_Changed.Append (Path);
            end if;
         end;
      end loop;
      return (if Not_Changed.Is_Empty then ""
              else "it reported files it did not change: " & Comma_Separated (Not_Changed));
   end Overclaimed_Note;

   --  What an answer that is not taken proposed is not lost with it:
   --  kept as an issue, to be seen and made by hand.
   procedure Keep_Proposals_Aside is
      Lost : Unbounded_String;
      Held : E.Error_Info;
   begin
      for Line of Lines_Of (Invocations.Claim (Said, "proposed_tasks")) loop
         if Trim (Line) not in "" | "-" then
            Append (Lost, ASCII.LF & "not proposed: " & Trim (Line));
            Result.Kept_Back.Append (Trim (Line) & ": its answer was not taken");
         end if;
      end loop;
      for Line of Lines_Of (Invocations.Claim (Said, "parts")) loop
         if Trim (Line) not in "" | "-" then
            Append (Lost, ASCII.LF & "part not made: " & Trim (Line));
            Result.Kept_Back.Append (Trim (Line) & ": its answer was not taken");
         end if;
      end loop;
      if Lost /= Null_Unbounded_String
        or else Trim (Invocations.Claim (Said, "issues")) /= ""
      then
         declare
            Issue : Results.Result :=
              (Kind       => Results.Diagnostic,
               Producer   => Result.Agent_Id,
               Summary    => To_Unbounded_String ("issues found working on " & Task_Id),
               Payload    => To_Unbounded_String
                               (Invocations.Claim (Said, "issues") & To_String (Lost)),
               Provenance => Result.Invocation_Id,
               others     => <>);
         begin
            Results.Add (Item, Change, Issue, Held);
            if E.Is_Ok (Held) then
               Result.Issue_Id := Issue.Id;
               Annotate (Item, Change, Task_Id, "issues", To_String (Issue.Id));
            end if;
         end;
      end if;
   end Keep_Proposals_Aside;

   procedure Conclude (Next, Given_Reason, Agent_End : String) is
      --  Not done, where it worked in the project itself: what it
      --  changed is still there, and said so.
      function Left_Behind return String is
         Named : Unbounded_String;
      begin
         if Isolated or else Next not in "failed" | "blocked" | "cancelled"
           or else Result.Changed_Files.Is_Empty
         then
            return "";
         end if;
         for Path of Result.Changed_Files loop
            Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
         end loop;
         return Left_Words (Item, To_String (Named), Task_Id, Cancelled => Next = "cancelled");
      end Left_Behind;

      --  Not done, where it worked apart: its workspace is given up --
      --  a retry starts afresh -- and said.
      function Given_Up return String is
         Held : E.Error_Info;
      begin
         if not Isolated or else Next not in "failed" | "blocked"
           or else Result.Workspace_Id = Null_Unbounded_String
           or else Workspaces.Active_For (Item, Task_Id) /= To_String (Result.Workspace_Id)
         then
            return "";
         end if;
         Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Held);
         return (if E.Is_Ok (Held)
                 then "; its workspace " & To_String (Result.Workspace_Id) & " is given up"
                      & (if Result.Changed_Files.Is_Empty then ""
                         else ", what it changed there kept in "
                              & Ada.Directories.Simple_Name
                                  (Workspaces.Kept_Copy (Item, To_String (Result.Workspace_Id)))
                              & " (/task kept lists it): "
                              & Comma_Separated (Result.Changed_Files))
                 else "");
      end Given_Up;

      Reason : constant String := Given_Reason & Left_Behind & Given_Up;
   begin
      if Next /= "" then
         Tasks.Move (Item, Change, Task_Id, Next, Reason, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;
      Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
      Result.Reason := To_Unbounded_String (Reason);
      --  Its end, as any agent's: with the result it gave and an event
      --  saying so -- cancelled is only a state.
      declare
         Ended : E.Error_Info := E.Make (E.Framework_Transition_Invalid);
      begin
         if Agent_End in "completed" | "failed" then
            --  Its summary its own words, where it gave them; the
            --  reason the task stands where it does otherwise.
            Agents.Finish
              (Item, Change, To_String (Result.Agent_Id), Agent_End = "completed",
               To_String (Last_Result),
               (if Reason = "" then To_String (Result.Summary)
                elsif Result.Summary = Null_Unbounded_String then Reason
                else To_String (Result.Summary) & " -- " & Reason),
               Ended);
         end if;
         if E.Is_Error (Ended) then
            Agent_State (Item, Change, To_String (Result.Agent_Id), Agent_End, Reason);
         end if;
      end;
      --  What its attempt came to, beside how its agent ended: the state
      --  it left the task in.
      declare
         Held   : Records.Item;
         Staged : Boolean;
      begin
         Stores.Pending (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Held, Staged);
         if Staged then
            --  The state it moves to here, not yet committed.
            Records.Set (Held, "outcome",
                         (if Next /= "" then Next else Tasks.State_Of (Item, Task_Id)));
            --  Why, where its ending did not say: a cancel, an interrupt.
            if Records.Get (Held, "summary") = "" and then Reason /= "" then
               Records.Set (Held, "summary", Reason);
            end if;
            Stores.Put (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Held);
         end if;
      end;
      --  A move lets go of what the task held; staying in verification,
      --  its work waiting to be taken in, it is let go of here.
      if Next = "" then
         Leases.Release
           (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Status);
         if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= ""
         then
            Leases.Release
              (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
               To_String (Result.Agent_Id), Status);
         end if;
         if E.Is_Ok (Status) and then not Isolated then
            Leases.Release
              (Item, Change, Tasks.Project_Lease, To_String (Result.Agent_Id), Status);
         end if;
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
   end Conclude;

   --  Work that did not end as it should -- an answer that broke the
   --  contract, an agent that crashed -- and changed files: kept for a
   --  person. Apart, it waits in its workspace to be taken in as any
   --  finished work does; in the project, the task is set aside with
   --  the files where they are.
   procedure Keep_Work (Why : String) is
   begin
      if Isolated and then Result.Workspace_Id /= Null_Unbounded_String
        and then not Result.Changed_Files.Is_Empty
      then
         Conclude ("verification",
                   Why & "; what it changed is kept in its workspace "
                   & To_String (Result.Workspace_Id) & ": " & Comma_Separated (Result.Changed_Files)
                   & " -- /task integrate " & Task_Id & " checks it and takes it in, /task integrate "
                   & Task_Id & " discard gives it up and does the task afresh",
                   "failed");
      --  What it left in the project, and /task complete for it, are
      --  said once, with the files, where the run's end is said.
      else
         Conclude ("blocked", Why, "failed");
      end if;
   end Keep_Work;

   --  Hold the task -- and, writing in the project itself, its component
   --  and the project -- for so long; taken again by the same agent, a
   --  hold is renewed. Long enough for the work it is allowed, so a live
   --  task is not taken back from it; a process that dies lets go at once.
   procedure Hold (Seconds : Positive) is
   begin
      Leases.Acquire
        (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Seconds, Status);

      --  Writing in the project itself, it holds its component too, so
      --  no other agent writes the same component meanwhile.
      if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= ""
      then
         Leases.Acquire
           (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
            To_String (Result.Agent_Id), Seconds, Status);
      end if;

      --  And the project, so that no other agent writes in it meanwhile.
      if E.Is_Ok (Status) and then not Isolated then
         Leases.Acquire
           (Item, Change, Tasks.Project_Lease, To_String (Result.Agent_Id), Seconds, Status);
      end if;
   end Hold;
begin
   Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);

   declare
      Now : constant Tasks.Readiness := Tasks.Ready (Item, Task_Id);
   begin
      --  Its permissions leaving its agent unable are not a reason not to
      --  start here: what it is refused is found as it works, and said.
      if not Now.Ready
        and then not (Natural (Now.Reasons.Length) = 1
                      and then Now.Reasons.First_Element = Unable_Reason (Item, Task_Id))
      then
         Status := E.Make (E.Framework_Task_Not_Ready);
         E.Add_Text (Status, "name", Task_Id);
         declare
            Why : constant String := (if Now.Reasons.Is_Empty then "" else Now.Reasons.First_Element);
            At_Children : constant Natural :=
              Ada.Strings.Fixed.Index (Why, "it is blocked: waiting for its children");
         begin
            --  Its parts, as every list says them, not its children.
            E.Add_Text
              (Status, "detail",
               (if At_Children = Why'First
                then "it is waiting for its parts" & Why (Why'First + 39 .. Why'Last)
                else Why));
         end;
         return;
      end if;
   end;

   --  A runner that cannot start is a setup to put right: said, and the
   --  task left ready, no attempt spent on it.
   Status := E.Success;
   Runner.Check_Start (Item, Status);
   if E.Is_Error (Status) then
      return;
   end if;

   --  An agent of its own, holding the task, in a new generation, with
   --  what its task's kind and its role allow.
   declare
      Defined : Records.Item;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      Agents.Start_Root
        (Item, Change, Task_Id, "worker", Records.Get (Defined, "kind"),
         Result.Agent_Id, Status,
         Restriction => Records.Get (Defined, "permissions"),
         Budget      => Number_Of (Tasks.Kind_Policy (Item, Kind, "token_budget"), 0));
   end;
   if E.Is_Error (Status) then
      return;
   end if;
   Hold (Lease_Seconds (Item) + Time_Allowed (Item, Task_Id));
   if E.Is_Ok (Status) then
      Tasks.Move (Item, Change, Task_Id, "running", "", Status => Status);
   end if;

   --  The agent works in the generation the move to running began, not
   --  the one before it.
   if E.Is_Ok (Status) then
      declare
         Task_State, Agent : Records.Item;
         Staged, Held      : Boolean;
      begin
         Stores.Pending (Change, Tasks_Area, Task_Id & ".state", Task_State, Staged);
         Stores.Pending (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id),
                         Agent, Held);
         if Staged and then Held then
            Records.Set (Agent, "generation", Records.Get (Task_State, "generation"));
            Stores.Put (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Agent);
         end if;
      end;
   end if;
   if E.Is_Ok (Status) then
      Annotate (Item, Change, Task_Id, "admission", Admission (Item, Task_Id, Isolated));
      declare
         Named : Unbounded_String;
      begin
         Runner.Describe (Named);
         Annotate (Item, Change, Task_Id, "runner", To_String (Named));
      end;
      Annotate (Item, Change, Task_Id, "active_agent", To_String (Result.Agent_Id));
      Stores.Commit (Item, Change, Status);
   end if;
   if E.Is_Error (Status) then
      return;
   end if;

   --  What it is told, and the call, recorded before it is made.
   Context.Build
     (Item, Task_Id, Model, Built, Held,
      Instructions => Instructions_Here);
   if E.Is_Error (Held) then
      Conclude ("blocked", "its context cannot be built: "
                & Why_Of (Held), "failed");
      return;
   end if;
   Result.Manifest_Id := To_Unbounded_String (Context.Manifest_Id (Built));
   Context.Keep (Item, Change, Built, Status);
   if E.Is_Ok (Status) then
      Invocations.Start
        (Item, Change, To_String (Result.Agent_Id), Task_Id,
         Generation_Of (Item, Task_Id),
         To_String (Model.Id),
         To_String (Result.Manifest_Id),
         Tool_Policy
           (Item, To_String (Result.Agent_Id),
            Number_Of ((if Tasks.Kind_Policy (Item, Kind, "max_tool_calls") /= ""
                        then Tasks.Kind_Policy (Item, Kind, "max_tool_calls")
                        else Scalar (Item, "agents.max_tool_calls")), 0),
            Task_Id, Isolated, Hosted => Runner in Parenting_Runner'Class),
         Invocations.Work_Claim,
         Result.Invocation_Id, Status, Resource_Class => To_String (Model.Resource_Class));
      if E.Is_Ok (Status) then
         Agents.Record_Holding
           (Item, Change, To_String (Result.Agent_Id), "", To_String (Result.Invocation_Id),
            Status);
      end if;
   end if;
   if E."=" (Status.Code, E.Framework_Limit_Exceeded) then
      --  Out of calls: blocked, deterministically, not run past its bound.
      Change := Stores.No_Changes;
      Conclude ("blocked", "no model call is left to it: " & Why_Of (Status),
                "failed");
      return;
   end if;
   if E.Is_Ok (Status) then
      Stores.Commit (Item, Change, Status);
   end if;
   if E.Is_Error (Status) then
      return;
   end if;

   --  Its own copy to write in, when the project isolates work.
   if Isolated then
      declare
         Made  : Workspaces.Workspace;
         Stale : constant String := Workspaces.Active_For (Item, Task_Id);
      begin
         --  A workspace an earlier attempt left -- set aside, not taken in
         --  -- is that attempt's: this generation starts from the project
         --  as it is, and the task has one workspace, not two.
         if Stale /= "" then
            Workspaces.Abandon (Item, Change, Stale, Held);
            if E.Is_Error (Held) then
               Change := Stores.No_Changes;
               Conclude ("blocked", "its earlier workspace cannot be set aside", "failed");
               return;
            end if;
         end if;
         Workspaces.Create
           (Item, Change, Task_Id, To_String (Result.Agent_Id),
            Generation_Of (Item, Task_Id), Work_Setting (Item, "backend") /= "copy",
            Made, Held);
         if E.Is_Ok (Held) then
            Agents.Record_Holding
              (Item, Change, To_String (Result.Agent_Id), To_String (Made.Id), "", Held);
         end if;
         if E.Is_Error (Held) then
            Change := Stores.No_Changes;
            Conclude ("blocked",
                      (if E."=" (Held.Code, E.Framework_Limit_Exceeded)
                       then "no workspace slot is free"
                       else "its workspace cannot be made"),
                      "failed");
            return;
         end if;
         Result.Workspace_Id := Made.Id;
         Place := Made.Path;
         Annotate (Item, Change, Task_Id, "current_workspace", To_String (Made.Id));
         Stores.Commit (Item, Change, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;
   end if;

   declare
      Scratch : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "exec");
      Prompt  : constant String :=
        Hostkit.Fs.Join (Scratch, "prompt-" & To_String (Result.Agent_Id) & ".txt");
      Before  : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place), Repository.Roots_Of (Item));
      By_Checks : Name_Lists.Vector;
   begin
      --  Written in the project itself: what the files were, kept for an
      --  opening after a kill to compare with.
      if not Isolated then
         declare
            Lines : Unbounded_String;
            Kept  : E.Error_Info;
         begin
            for Position in Before.Iterate loop
               Append (Lines, Configurations.Value_Maps.Key (Position) & ASCII.HT
                       & Configurations.Value_Maps.Element (Position) & ASCII.LF);
            end loop;
            Files.Write_Text (Before_File (Item, Task_Id), To_String (Lines), Kept);
         end;
      end if;
      if Files.Make_Directory (Scratch) then
         Files.Write_Text
           (Prompt, Context.Rendered (Built), Status);

         --  What the agent may do, for a runner that starts it as a
         --  process of its own to hold it to.
         if E.Is_Ok (Status) then
            declare
               Root_Agent : Agents.Agent;
               Read       : E.Error_Info;
            begin
               Agents.Read (Item, To_String (Result.Agent_Id), Root_Agent, Read);
               Files.Write_Text
                 (Permissions.Permissions_Beside (Prompt),
                  (if E.Is_Ok (Read) then Permissions.Image (Root_Agent.Allowed) else ""),
                  Status);
               if E.Is_Ok (Read) and then not Isolated then
                  Keep_Originals (Item, To_String (Result.Agent_Id), To_String (Place), Before,
                                  Root_Agent.Allowed, Status);
               end if;
            end;
         end if;
      else
         Files.Write_Failed (Scratch, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Host : Child_Host (Item'Access);
      begin
         Host.Task_Id := To_Unbounded_String (Task_Id);
         Host.Apart := Isolated;
         Host.Model := Model;
         declare
            use type Ada.Calendar.Time;
            Seconds : constant Natural := Time_Allowed (Item, Task_Id);
         begin
            Host.Bounded := Seconds > 0;
            Host.Deadline := Ada.Calendar.Clock + Duration (Seconds);
         end;
         Host.Max_Calls := Number_Of
           ((if Tasks.Kind_Policy (Item, Kind, "max_tool_calls") /= ""
             then Tasks.Kind_Policy (Item, Kind, "max_tool_calls")
             else Scalar (Item, "agents.max_tool_calls")), 0);
         Host.Max_Steps := Number_Of
           ((if Tasks.Kind_Policy (Item, Kind, "max_steps") /= ""
             then Tasks.Kind_Policy (Item, Kind, "max_steps")
             else Scalar (Item, "agents.max_steps")), 24);
         Host.Open.Append (To_String (Result.Agent_Id));
         Host.Calls.Append (To_String (Result.Invocation_Id));
         Host.Opened.Append (Ada.Calendar.Clock);

         --  Ended elsewhere meanwhile -- cancelled from another process
         --  -- what runs for it is stopped.
         Execution.Watch_Lease
           (Item'Unchecked_Access, Lease_Of (Task_Id), To_String (Result.Agent_Id));
         if Runner in Parenting_Runner'Class then
            Parenting_Runner'Class (Runner).Run_Parenting
              (Prompt, To_String (Place), Host, Answer, Ran);
         else
            declare
               State : Stores.State_Snapshot;
            begin
               Stores.Snapshot_State (Item, State);
               if Starting /= null then
                  Starting (To_String (Result.Agent_Id), To_String (Result.Manifest_Id),
                            To_String (Result.Invocation_Id));
               end if;
               Runner.Run (Prompt, To_String (Place), Answer, Ran);
               Stores.Restore_State (Item, State, Tampered, Tamper_Left);
            end;

            --  What an agent run apart used, as its runner reports it:
            --  charged, and its calls recorded, as the harness's own are.
            if Ada.Directories.Exists (Usage_Beside (Prompt)) then
               declare
                  Text   : Unbounded_String;
                  Read   : E.Error_Info;
                  Spent  : Natural := 0;
                  Seen   : Natural := 0;
               begin
                  Files.Read_Text (Usage_Beside (Prompt), Text, Read);
                  for Line of Lines_Of (To_String (Text)) loop
                     if Ada.Strings.Fixed.Index (Line, "output_tokens ") = Line'First then
                        Spent := Number_Of (Trim (Line (Line'First + 14 .. Line'Last)), 0);
                     elsif Ada.Strings.Fixed.Index (Line, "prompt_tokens ") = Line'First then
                        Seen := Number_Of (Trim (Line (Line'First + 14 .. Line'Last)), 0);
                     elsif Ada.Strings.Fixed.Index (Line, "call ") = Line'First then
                        declare
                           Rest : constant String := Line (Line'First + 5 .. Line'Last);
                           Tab  : constant Natural :=
                             Ada.Strings.Fixed.Index (Rest, [1 => ASCII.HT]);
                        begin
                           Note_Call
                             (Host, (if Tab = 0 then Rest else Rest (Rest'First .. Tab - 1)),
                              (if Tab = 0 then "" else Rest (Tab + 1 .. Rest'Last)), "");
                        end;
                     end if;
                  end loop;
                  Spend (Host, Spent, Seen);
                  Files.Discard (Usage_Beside (Prompt));
               end;
            end if;
         end if;
         Execution.Watch_Lease (null);
         Abandon (Host);
         By_Checks := Host.Written;
         Over_Budget := Host.Root_Over;
         Used :=
           (Prompt_Tokens =>
              (if Host.Root_Prompt > 0 then Host.Root_Prompt else Context.Cost (Built)),
            Output_Tokens => Host.Root_Out,
            Seconds       =>
              Natural (Duration'Max
                (0.0, Ada.Calendar."-" (Ada.Calendar.Clock, Host.Opened.First_Element))));
      end;
      for Line of Lines_Of (Agents.Child_Results (Item, To_String (Result.Agent_Id))) loop
         Result.Children.Append (Line);
      end loop;
      Files.Discard (Prompt);
      Files.Discard (Permissions.Permissions_Beside (Prompt));

      --  What changed is what the files say, not what the answer says.
      declare
         After : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place), Repository.Roots_Of (Item));
      begin
         for Position in After.Iterate loop
            declare
               Path : constant String := Configurations.Value_Maps.Key (Position);
            begin
               if (not Before.Contains (Path)
                   or else Before (Path) /= Configurations.Value_Maps.Element (Position))
                 and then not By_Checks.Contains
                                (Path & ASCII.HT & Configurations.Value_Maps.Element (Position))
               then
                  Result.Changed_Files.Append (Path);
               end if;
            end;
         end loop;
         for Position in Before.Iterate loop
            if not After.Contains (Configurations.Value_Maps.Key (Position)) then
               Result.Changed_Files.Append (Configurations.Value_Maps.Key (Position));
            end if;
         end loop;
      end;

      --  What it wrote that it may not is put back as it was, where it
      --  can be: the project is not left holding it.
      if not Isolated then
         declare
            Root_Agent : Agents.Agent;
            Read       : E.Error_Info;
            Kept       : Name_Lists.Vector;
         begin
            Agents.Read (Item, To_String (Result.Agent_Id), Root_Agent, Read);
            for Path of Result.Changed_Files loop
               if E.Is_Ok (Read)
                 and then not Permissions.Allows (Root_Agent.Allowed, Permissions.Write_Source, Path)
                 and then not Permissions.Allows (Root_Agent.Allowed, Permissions.Write_Specs, Path)
               then
                  declare
                     Back : E.Error_Info;
                     Said : Boolean;
                     Why  : E.Parameter;
                  begin
                     Put_Back (Item, To_String (Result.Agent_Id), To_String (Place), Path,
                               Before.Contains (Path), Back);
                     if E.Is_Ok (Back) then
                        Put_Back_Files.Append (Path);
                     else
                        --  Still there, and why, for what the run says.
                        E.Find_Parameter (Back, "detail", Said, Why);
                        Not_Put_Back.Append
                          (Path & " (" & (if Said then Model_Runner.Text.To_String (Why.Text_Value)
                                          else E.Error_Code'Image (Back.Code)) & ")");
                        Kept.Append (Path);
                     end if;
                  end;
               else
                  Kept.Append (Path);
               end if;
            end loop;
            Result.Changed_Files := Kept;
         end;
         Files.Discard_Tree (Kept_Directory (Item, To_String (Result.Agent_Id)));
      end if;
   end;

   --  The answer, kept, and the call ended.
   declare
      Kept : Results.Result :=
        (Kind       => (if Kind_Of_Task (Item, Task_Id) = "analysis" then Results.Analysis
                        else Results.Implementation),
         Producer   => Result.Agent_Id,
         Summary    => To_Unbounded_String ("answer to " & To_String (Result.Invocation_Id)),
         Payload    => Answer,
         Provenance => Result.Invocation_Id,
         others     => <>);
      Files_Text : Unbounded_String;
   begin
      Results.Add (Item, Change, Kept, Status);
      Last_Result := Kept.Id;
      Invocations.Finish
        (Item, Change, To_String (Result.Invocation_Id),
         (if E.Is_Ok (Ran) then Invocations.Completed
          elsif Interrupted (Ran) then Invocations.Cancelled
          else Invocations.Failed),
         Used,
         To_String (Kept.Id),
         (if E.Is_Ok (Ran) then "" else Why_Of (Ran)), Status);
      Annotate (Item, Change, Task_Id, "last_result", To_String (Kept.Id));
      for Path of Result.Changed_Files loop
         Append (Files_Text, (if Files_Text = Null_Unbounded_String then "" else ASCII.LF & "")
                             & Path);
      end loop;

      --  In the project itself, what an earlier attempt left changed is
      --  still this task's work: counted with this one's.
      if not Isolated then
         for Path of Earlier_Changed loop
            if not Result.Changed_Files.Contains (Path) then
               Append (Files_Text, (if Files_Text = Null_Unbounded_String then ""
                                    else ASCII.LF & "") & Path);
            end if;
         end loop;
      end if;
      Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
      Annotate (Item, Change, Task_Id, "undone_by", "");
      --  Written in the project itself: what it wrote, file by file, as
      --  what a workspace's taking in keeps -- an edit after is not its.
      if not Isolated then
         declare
            Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
            Prints  : Unbounded_String;
         begin
            for Path of Result.Changed_Files loop
               Append (Prints, Path & ASCII.HT & File_Print (Hostkit.Fs.Join (Project, Path)) & ASCII.LF);
            end loop;
            Annotate (Item, Change, Task_Id, "taken_in", To_String (Prints));
            Annotate (Item, Change, Task_Id, "joined_files", "");
         end;
      end if;
      if not Result.Changed_Files.Is_Empty and then not Isolated then
         declare
            Event : Unbounded_String;
         begin
            Events.Emit (Item, Change, Events.Source_Changed, Task_Id,
                         To_String (Files_Text), Event, Status);
         end;
      end if;
   end;
   if E.Is_Error (Status) then
      return;
   end if;

   --  Ended elsewhere while it ran: what that did stands, and nothing of
   --  this run is added to a task that is no longer its.
   if Tasks.State_Of (Item, Task_Id) /= "running"
     or else Leases.Holder (Item, Lease_Of (Task_Id)) /= To_String (Result.Agent_Id)
   then
      Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
      Result.Reason := To_Unbounded_String
        (if Tasks.State_Of (Item, Task_Id) = "running"
         then "its hold on the task was taken over elsewhere while it ran -- its lease ran out first;"
              & " nothing of this run is kept, and /work " & Task_Id & " runs it again"
         else "it was " & Tasks.State_Of (Item, Task_Id) & " elsewhere while it ran; nothing of this"
              & " run is kept");
      return;
   end if;

   --  Stopped by whoever started it: the agent and what it made are
   --  cancelled, and the task is put aside, not failed -- nothing is
   --  known against it -- until it is accepted again.
   if Interrupted (Ran) and then Execution.Cancel_Asked_From_Outside then
      --  Cancelled from another terminal: cancelled, as asked.
      Stop_Children (Item, Change, To_String (Result.Agent_Id), "the task was cancelled");
      Conclude ("cancelled", "it was cancelled from another terminal", "cancelled");
      return;
   elsif Interrupted (Ran) then
      Stop_Children (Item, Change, To_String (Result.Agent_Id), "the work was interrupted");
      Conclude ("blocked", "you stopped its work (Ctrl-C) before it finished", "cancelled");
      return;
   elsif Out_Of_Time (Ran) then
      --  Out of time is not wrong work: the task is set aside, not
      --  failed, with what its agents made stopped.
      Stop_Children (Item, Change, To_String (Result.Agent_Id), "the work ran out of time");
      declare
         Defined : Records.Item;
         Read    : E.Error_Info;
      begin
         Tasks.Definition (Item, Task_Id, Defined, Read);
         declare
            Own : constant Boolean :=
              Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "max_seconds") /= "";
            --  Which limit it was, and how it is raised: a retry alone
            --  runs out the same way.
            Limit : constant String :=
              (if Own then "task.max_seconds." & Records.Get (Defined, "kind")
               elsif Scalar (Item, "agents.max_seconds") /= "" then "agents.max_seconds"
               else "work.lease");
         begin
            Conclude ("blocked", "its work ran out of time:" & Natural'Image (Time_Allowed (Item, Task_Id))
                      & " s, as " & Limit & " allows; /reconfigure " & Limit & "=N gives it longer",
                      "failed");
         end;
      end;
      return;
   elsif E.Is_Error (Ran) and then Ran.Code = E.Framework_Agent_Failed then
      --  A crash is not wrong work: what it changed is kept to be
      --  looked at, and the task set aside.
      Keep_Work (Why_Of (Ran));
      return;
   elsif E.Is_Error (Ran) then
      --  A required helper that failed is why the work could not go
      --  on, whatever the agent did after: the task set aside as the
      --  policy says, the helper's failure named first.
      declare
         Child_Why : Unbounded_String;
      begin
         if not Agents.May_Complete (Item, To_String (Result.Agent_Id), Child_Why) then
            Conclude ((if Scalar (Item, "agents.on_child_failure") = "fail" then "failed" else "blocked"),
                      Child_Failure (To_String (Child_Why), Why_Of (Ran),
                                     Scalar (Item, "agents.on_child_failure")), "failed");
            return;
         end if;
      end;
      Conclude ("failed", Why_Of (Ran), "failed");
      return;
   end if;

   --  What it used is bounded as its children's is: past its budget the
   --  work is set aside, whatever it says it did.
   if Over_Budget then
      Conclude ("blocked", "it went over its token budget", "failed");
      return;
   end if;

   --  Its state is not the agent's to write, whatever it may; and what
   --  it wrote outside its permissions is named with that, every one.
   if not Tampered.Is_Empty then
      declare
         Named    : Unbounded_String;
         Read_Out : E.Error_Info;
      begin
         Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Read_Out);
         Keep_Proposals_Aside;
         for Path of Tampered loop
            Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                    & State_Directory & "/" & Path);
         end loop;
         Conclude ("failed", "it changed the project's state, which was put back: "
                   & To_String (Named)
                   & (if Tamper_Left.Is_Empty then ""
                      else "; but not all of it could be: " & Comma_Separated (Tamper_Left))
                   & (if Beyond_Permissions = "" then ""
                      else "; and it changed files it may not write, which are still there:"
                           & " " & Beyond_Permissions & " -- take them out before /task complete"
                           & Sandbox_Said (Beyond_Permissions))
                   & (if Put_Back_Files.Is_Empty then ""
                      else "; and it changed files it may not write, which were put back as"
                           & " they were: " & Comma_Separated (Put_Back_Files)
                           & Sandbox_Said (Comma_Separated (Put_Back_Files))),
                   "failed");
      end;
      return;
   end if;

   --  What it changed must be what it may write, whatever it says.
   declare
      Held_Agent : Agents.Agent;
      Denied     : Unbounded_String;
   begin
      Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Held);
      for Path of Result.Changed_Files loop
         if not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Source, Path)
           and then not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Specs, Path)
         then
            Append (Denied, (if Denied = Null_Unbounded_String then "" else ", ") & Path);
         end if;
      end loop;
      if Denied /= Null_Unbounded_String or else not Put_Back_Files.Is_Empty then
         declare
            Read_Out : E.Error_Info;
         begin
            Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Read_Out);
            Keep_Proposals_Aside;
         end;
         if Isolated then
            Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Held);
         end if;
         --  Refused by the session's sandbox alone, the work is not
         --  wrong: set aside until the sandbox lets it.
         Conclude ((if Sandbox_Said (Comma_Separated (Put_Back_Files)
                                     & (if Denied = Null_Unbounded_String then ""
                                        else "," & To_String (Denied))) /= ""
                    then "blocked" else "failed"),
                   "it changed files it may not write: "
                   & (if Put_Back_Files.Is_Empty then ""
                      else Comma_Separated (Put_Back_Files) & ", which were put back as they"
                           & " were" & (if Denied = Null_Unbounded_String then "" else "; "))
                   & (if Denied = Null_Unbounded_String then ""
                      else To_String (Denied)
                           & (if Isolated then ""
                              else ", which are still in the project -- take them out before"
                                   & " /task complete"))
                   & (if Not_Put_Back.Is_Empty then ""
                      else "; putting back failed for " & Comma_Separated (Not_Put_Back))
                   & Sandbox_Said (Comma_Separated (Put_Back_Files)
                                   & (if Denied = Null_Unbounded_String then ""
                                      else "," & To_String (Denied)))
                   & Rule_Said,
                   "failed");
         return;
      end if;
   end;

   Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Held);
   if E.Is_Error (Held) then
      Keep_Proposals_Aside;
      declare
         Why : constant String :=
           --  In words: the field the answer lacked, not the record's name.
           (if E.Text_Of (Held, "name") = "work_claim.status"
            then "its answer did not end with the status: line that says how the work stands"
            else "its answer did not say what the harness needs: "
                 & (if Ada.Strings.Fixed.Index (E.Text_Of (Held, "name"), "work_claim.") = 1
                    then E.Text_Of (Held, "name") (E.Text_Of (Held, "name")'First + 11
                                                   .. E.Text_Of (Held, "name")'Last)
                    else E.Text_Of (Held, "name"))
                 & ": " & E.Text_Of (Held, "detail"))
           --  A call written out as text is no call: said, since the
           --  model meant one and nothing ran.
           & (if Index (Answer, """name""") > 0 and then Index (Answer, """arguments""") > 0
              then "; the answer looks like a tool call written as text, which runs"
                   & " nothing -- a model that writes its calls so needs the model's own"
                   & " call format, or a larger model"
              else "")
           & "; the answer is kept as "
           & To_String (Last_Result);
      begin
         --  Files it did change are work, whatever it said of them: kept
         --  to be looked at, not thrown away with the answer.
         if not Result.Changed_Files.Is_Empty then
            Keep_Work (Why);
         else
            Conclude ("failed", Why, "failed");
         end if;
      end;
      return;
   end if;
   Result.Claimed := To_Unbounded_String (Invocations.Claim (Said, "status"));
   Result.Summary := To_Unbounded_String (Own_Words (Invocations.Claim (Said, "summary")));

   --  A change it says it made and did not is a claim the files refute:
   --  whatever else it did, its answer cannot be taken.
   if To_String (Result.Claimed) = "done" then
      declare
         Missing       : Unbounded_String;
         Missing_Count : Natural := 0;
      begin
         for Line of Lines_Of (Replaced (Invocations.Claim (Said, "changed_files"))) loop
            declare
               Named : constant String := Trim (Line);
               Path  : constant String :=
                 (if Named'Length > 2 and then Named (Named'First .. Named'First + 1) = "./"
                  then Named (Named'First + 2 .. Named'Last) else Named);
            begin
               --  A file there, written as it was, is no false claim:
               --  only one that is not there at all is.
               if Path not in "" | "-" | "none" and then not Result.Changed_Files.Contains (Path)
                 and then not (not Isolated and then Earlier_Changed.Contains (Path))
                 and then not Ada.Directories.Exists (Hostkit.Fs.Join (To_String (Place), Path))
               then
                  Missing_Count := Missing_Count + 1;
                  if Missing_Count <= 10 then
                     Append (Missing, (if Missing = Null_Unbounded_String then "" else ", ") & Path);
                  end if;
               end if;
            end;
         end loop;
         if Missing_Count > 10 then
            Append (Missing, " and" & Natural'Image (Missing_Count - 10) & " more");
         end if;
         if Missing /= Null_Unbounded_String then
            Keep_Proposals_Aside;
            --  Kept as an issue, as what an attempt reports is: found
            --  again by /result beside the rest.
            declare
               Claimed : Results.Result :=
                 (Kind       => Results.Diagnostic,
                  Producer   => Result.Agent_Id,
                  Summary    => To_Unbounded_String
                                  (Task_Id & " failed: its answer says it changed " & To_String (Missing)
                                   & ", which is not there"),
                  Payload    => To_Unbounded_String (Invocations.Claim (Said, "changed_files")),
                  Provenance => Result.Invocation_Id,
                  others     => <>);
               Held : E.Error_Info;
            begin
               Results.Add (Item, Change, Claimed, Held);
            end;
            Conclude ("failed", "it says it changed " & To_String (Missing)
                      & ", which is not there", "failed");
            return;
         end if;
      end;
   end if;

   --  An agent does not enlarge its task. Work it found beyond it
   --  becomes candidate tasks, one a line, where it may propose them --
   --  a person still accepts them -- and is kept as an issue where it may
   --  not; issues are kept either way.
   declare
      Proposed  : constant Name_Lists.Vector :=
        Lines_Of (Invocations.Claim (Said, "proposed_tasks"));
      Parts     : constant Name_Lists.Vector :=
        Lines_Of (Invocations.Claim (Said, "parts"));
      Held_Root : Agents.Agent;
      Defined   : Records.Item;
      May_Propose : Boolean;
      Kept_Back : Unbounded_String;

      --  Whether the parts it asks for are children: only where its agent
      --  may create them; otherwise they are proposals of their own.
      Parts_Are_Children : Boolean := True;

      --  What this answer has made so far, by title in lower case, and
      --  as what.
      Made_Titles : Name_Lists.Vector;
      Made_Ids    : Name_Lists.Vector;

      --  A task of that title there already: this one, or one not
      --  ended. What is proposed twice is made once.
      --  A task of that title there already, which this answer's line
      --  is: one made from this same answer; for a proposal, one not
      --  ended; for a part, one of this task's own parts, done or not.
      --  Never this task itself.
      --  A task named as what it is: a part says whose.
      function Described (Other : String) return String is
         Its  : Records.Item;
         Read : E.Error_Info;
      begin
         Tasks.Definition (Item, Other, Its, Read);
         return Other
           & (if E.Is_Ok (Read) and then Records.Get (Its, "parent") /= ""
              then " (a part of " & Records.Get (Its, "parent") & ")" else "");
      end Described;

      function Same_Title (Title : String; Part : Boolean := False) return String is
         Lower : constant String := Ada.Characters.Handling.To_Lower (Title);
      begin
         for Made in 1 .. Natural (Made_Titles.Length) loop
            if Made_Titles (Made) = Lower then
               return Made_Ids (Made);
            end if;
         end loop;
         --  A proposal of this very task is this task.
         if not Part then
            declare
               Its  : Records.Item;
               Read : E.Error_Info;
            begin
               Tasks.Definition (Item, Task_Id, Its, Read);
               if E.Is_Ok (Read)
                 and then Ada.Characters.Handling.To_Lower (Records.Get (Its, "title")) = Lower
               then
                  return Task_Id;
               end if;
            end;
         end if;
         --  For a proposal, a task of any state: one a person rejected
         --  or cancelled is not proposed again.
         for Other of Tasks.List (Item) loop
            if Other /= Task_Id then
               declare
                  Its  : Records.Item;
                  Read : E.Error_Info;
               begin
                  Tasks.Definition (Item, Other, Its, Read);
                  if E.Is_Ok (Read)
                    and then Ada.Characters.Handling.To_Lower (Records.Get (Its, "title")) = Lower
                    and then (not Part or else Records.Get (Its, "parent") = Task_Id)
                    and then (not Part
                              or else Tasks.State_Of (Item, Other) not in "cancelled" | "rejected")
                  then
                     return Other;
                  end if;
               end;
            end if;
         end loop;
         return "";
      end Same_Title;

   begin
      Agents.Read (Item, To_String (Result.Agent_Id), Held_Root, Held);
      May_Propose := E.Is_Ok (Held)
        and then Permissions.Allows (Held_Root.Allowed, Permissions.Propose_Tasks);
      Tasks.Definition (Item, Task_Id, Defined, Held);
      for Line of Proposed loop
         declare
            --  TITLE, then as it may say, ; kind=K ; component=C ;
            --  depends_on=TASK -- a candidate's own, not assumed from this
            --  task; it is proposal data until a person accepts it.
            Parts_Of : constant Name_Lists.Vector := Split_On (Line, ';');
            Title  : constant String :=
              (if Parts_Of.Is_Empty then "" else Trim (Parts_Of.First_Element));
            Fields : Tasks.Field_Map;
            Made   : Unbounded_String;

            function Said_Of (Name, Default : String) return String is
            begin
               for Part of Parts_Of loop
                  declare
                     Bare  : constant String := Trim (Part);
                     Equal : constant Natural := Ada.Strings.Fixed.Index (Bare, "=");
                  begin
                     if Equal > Bare'First and then Trim (Bare (Bare'First .. Equal - 1)) = Name
                     then
                        return Trim (Bare (Equal + 1 .. Bare'Last));
                     end if;
                  end;
               end loop;
               return Default;
            end Said_Of;
         begin
            if Title = "" or else Title = "-" then
               null;
            elsif May_Propose and then Made_Titles.Contains
                                         (Ada.Characters.Handling.To_Lower (Title))
            then
               --  Said twice in this answer: made once, and said so.
               if not Result.Twice.Contains (Title) then
                  Result.Twice.Append (Title);
               end if;
            elsif May_Propose and then Same_Title (Title) /= "" then
               declare
                  Other : constant String := Same_Title (Title);
                  State : constant String := Tasks.State_Of (Item, Other);
                  Said  : constant String :=
                    Title & ": "
                    & (if Other = Task_Id then "it is this task"
                       elsif State in "rejected" | "cancelled"
                       then "it is " & Other & ", which was " & State
                       else "it is " & Described (Other) & " already");
               begin
                  --  Said once, however often the answer says it.
                  if not Result.Kept_Back.Contains (Said) then
                     Result.Kept_Back.Append (Said);
                  end if;
               end;
            elsif May_Propose then
               Fields.Include ("title", Title);
               Fields.Include ("kind", Said_Of ("kind", Records.Get (Defined, "kind")));
               if Said_Of ("component", Records.Get (Defined, "component")) /= "" then
                  Fields.Include
                    ("component", Said_Of ("component", Records.Get (Defined, "component")));
               end if;
               if Said_Of ("depends_on", "") /= "" then
                  Fields.Include ("depends_on", Said_Of ("depends_on", ""));
               end if;
               Fields.Include ("notes", "proposed working on " & Task_Id);
               --  Made by an agent, from the task it was working on.
               Tasks.Create
                 (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                  Made, Held);
               if E.Is_Ok (Held) then
                  Result.Proposed.Append (To_String (Made));
                  Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                  Made_Ids.Append (To_String (Made));
               else
                  Append (Kept_Back, ASCII.LF & "asked for: " & Trim (Line));
                  Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
               end if;
            --  Kept as the answer said it, kind and component with it, so
            --  that it can be made by hand as it was meant; said once.
            elsif not Result.Kept_Back.Contains
                        (Trim (Line) & ": this task's agent may not propose tasks")
            then
               Append (Kept_Back, ASCII.LF & "asked for: " & Trim (Line));
               Result.Kept_Back.Append (Trim (Line) & ": this task's agent may not propose tasks");
            end if;
         end;
      end loop;

      --  The parts it would split its task into: proposal data, not a
      --  split -- candidate children, which a person accepts or not, and
      --  the task itself is left as the answer leaves it.
      --  A split is held to the limits children are: no more parts than
      --  create_children's max_children, and none below its max_depth.
      declare
         --  Parts are proposals, which propose_tasks allows; how many,
         --  and how deep, create_children bounds -- the agent's, or where
         --  it has none, the project's.
         Own   : constant Permissions.Grant := Held_Root.Allowed (Permissions.Create_Children);
         Limit : constant Permissions.Grant :=
           (if Own.Granted then Own
            else Permissions.Effective (Item, "", "", Within_Sandbox => False)
                   (Permissions.Create_Children));
         Depth : Natural := 0;
         Up    : Unbounded_String := To_Unbounded_String (Task_Id);
      begin
         loop
            declare
               Defined_Up : Records.Item;
               Read_Up    : E.Error_Info;
            begin
               Tasks.Definition (Item, To_String (Up), Defined_Up, Read_Up);
               exit when E.Is_Error (Read_Up) or else Records.Get (Defined_Up, "parent") = ""
                 or else Depth > 64;
               Up := To_Unbounded_String (Records.Get (Defined_Up, "parent"));
               Depth := Depth + 1;
            end;
         end loop;
         Parts_Are_Children := Own.Granted;
         --  Bounded as helpers are too: the project's agents.max_depth
         --  and agents.max_children hold for parts as for children.
         declare
            Bounds   : constant Agents.Limits := Agents.Limits_Of (Item);
            Deepest  : constant Natural := Natural'Min (Limit.Max_Depth, Bounds.Max_Depth);
            Most     : constant Natural := Natural'Min (Limit.Max_Children, Bounds.Max_Children);
         begin
            Split_Room := (if not Limit.Granted then 0
                           elsif Depth + 1 > Deepest then 0
                           else Most);
            Split_Why := To_Unbounded_String
              (if not Limit.Granted
               then "the project grants no create_children, which bounds parts"
               elsif Depth + 1 > Deepest
               then "a part here would be" & Natural'Image (Depth + 1) & " below the task it came"
                    & " from, past "
                    & (if Bounds.Max_Depth < Limit.Max_Depth then "agents.max_depth"
                       else "create_children's max_depth")
                    & Natural'Image (Deepest)
               else "past " & (if Bounds.Max_Children < Limit.Max_Children then "agents.max_children"
                               else "create_children's max_children")
                    & Natural'Image (Most));
         end;
      end;
      for Line of Parts loop
         declare
            Title  : constant String := Trim (Line);
            Fields : Tasks.Field_Map;
            Made   : Unbounded_String;
         begin
            if Title = "" or else Title = "-" then
               null;

            --  Its agent may not make children: the part is a proposal
            --  of its own, with no parent to wait for it.
            elsif May_Propose and then not Parts_Are_Children then
               if Made_Titles.Contains (Ada.Characters.Handling.To_Lower (Title)) then
                  null;
               elsif Same_Title (Title) /= "" then
                  Result.Kept_Back.Append (Title & ": it is " & Described (Same_Title (Title))
                                           & " already");
               else
                  Fields.Include ("title", Title);
                  Fields.Include ("kind", Records.Get (Defined, "kind"));
                  if Records.Get (Defined, "component") /= "" then
                     Fields.Include ("component", Records.Get (Defined, "component"));
                  end if;
                  Fields.Include ("notes", "proposed as a part of " & Task_Id
                                  & ", whose agent may not make children");
                  Tasks.Create
                    (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                     Made, Held);
                  if E.Is_Ok (Held) then
                     Result.Proposed.Append (To_String (Made));
                     Parts_Proposed.Append (To_String (Made));
                     Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                     Made_Ids.Append (To_String (Made));
                  else
                     Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                     Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
                  end if;
               end if;
            elsif May_Propose and then Same_Title (Title, Part => True) = ""
              and then Natural (Split_Into.Length) >= Split_Room
            then
               Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
               Result.Kept_Back.Append (Title & ": " & To_String (Split_Why));

            --  A part there already -- from an earlier split, or twice in
            --  this answer -- is that part, not another.
            elsif May_Propose and then Same_Title (Title, Part => True) /= "" then
               if not Split_Into.Contains (Same_Title (Title, Part => True)) then
                  Split_Into.Append (Same_Title (Title, Part => True));
               end if;
            elsif May_Propose then
               Fields.Include ("title", Title);
               Fields.Include ("kind", Records.Get (Defined, "kind"));
               Fields.Include ("parent", Task_Id);
               if Records.Get (Defined, "component") /= "" then
                  Fields.Include ("component", Records.Get (Defined, "component"));
               end if;
               Tasks.Create
                 (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                  Made, Held);
               if E.Is_Ok (Held) then
                  Result.Proposed.Append (To_String (Made));
                  Split_Into.Append (To_String (Made));
                  Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                  Made_Ids.Append (To_String (Made));
               else
                  Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                  Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
               end if;
            else
               if not Result.Kept_Back.Contains
                        (Title & ": this task's agent may not propose tasks or parts")
               then
                  Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                  Result.Kept_Back.Append (Title & ": this task's agent may not propose tasks or"
                                           & " parts");
               end if;
            end if;
         end;
      end loop;

      --  Decisions and specifications it proposes: entries in their
      --  registers, proposed or candidate, that govern nothing until a
      --  person accepts them.
      for Register in Intent.Specification .. Intent.Decision loop
         if Register /= Intent.Requirement then
            for Line of Lines_Of
              (Invocations.Claim
                 (Said, (if Register = Intent.Decision then "decisions" else "specifications")))
            loop
               declare
                  Text  : constant String := Trim (Line);
                  Stop  : constant Natural := Ada.Strings.Fixed.Index (Text, ". ");
                  Title : constant String :=
                    (if Stop in Text'First .. Text'First + 70 then Text (Text'First .. Stop)
                     elsif Text'Length > 70 then Text (Text'First .. Text'First + 69)
                     else Text);
                  Made  : Unbounded_String;
               begin
                  if Text = "" or else Text = "-" then
                     null;
                  elsif May_Propose then
                     Intent.Propose
                       (Item, Change, Register, "", Title, Text, "",
                        To_String (Result.Agent_Id), "", "project", Made, Held);
                     if E.Is_Ok (Held) then
                        Result.Proposed.Append (To_String (Made));
                     else
                        Append (Kept_Back, ASCII.LF & "asked for: " & Text);
                     end if;
                  else
                     Append (Kept_Back, ASCII.LF & "asked for: " & Text);
                  end if;
               end;
            end loop;
         end if;
      end loop;

      --  Tasks it says this one should wait for: said, and kept, never
      --  asserted -- a person makes the dependency with task depend.
      for Line of Lines_Of (Invocations.Claim (Said, "waits_for")) loop
         if Trim (Line) not in "" | "-" then
            Append (Kept_Back, ASCII.LF & "waits for: " & Trim (Line));
            Result.Waits_For.Append (Trim (Line));
         end if;
      end loop;

      declare
         function Not_Proposed return String is
            Why : Unbounded_String;
         begin
            for Line of Result.Kept_Back loop
               Append (Why, ASCII.LF & "not proposed: " & Line);
            end loop;
            return To_String (Why);
         end Not_Proposed;

         Found : constant String :=
           Invocations.Claim (Said, "issues") & To_String (Kept_Back) & Not_Proposed;
         --  An issue, not a proposal: what it may not propose is
         --  returned to be seen, not kept as work to be accepted.
         Issue : Results.Result :=
           (Kind       => Results.Diagnostic,
            Producer   => Result.Agent_Id,
            Summary    => To_Unbounded_String ("issues found working on " & Task_Id),
            Payload    => To_Unbounded_String (Found),
            Provenance => Result.Invocation_Id,
            others     => <>);
      begin
         if Trim (Found) /= "" then
            Results.Add (Item, Change, Issue, Status);
            if E.Is_Ok (Status) then
               --  Found again by its identifier: in the report, and in
               --  the task's audit.
               Result.Issue_Id := Issue.Id;
               Annotate (Item, Change, Task_Id, "issues", To_String (Issue.Id));
            end if;
         end if;
      end;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
   end;

   --  Not done, it says, but asks for its work to be checked: the
   --  evidence is taken and kept, and the task still goes where the
   --  answer says.
   if To_String (Result.Claimed) /= "done"
     and then Invocations.Claim (Said, "verify") = "yes"
   then
      declare
         Chosen : constant Verification.Choice :=
           Verification.Choose (Item, Task_Id, Result.Changed_Files);
         Passed : Boolean;
      begin
         if To_String (Chosen.Profile) /= "" then
            Verification.Run_Profile
              (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
               Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
            if E.Is_Ok (Held) then
               Stores.Commit (Item, Change, Status);
            else
               Change := Stores.No_Changes;
               Result.Evidence_Id := Null_Unbounded_String;
            end if;
         end if;
      end;
   end if;

   if To_String (Result.Claimed) in "blocked" | "issue" and then not Split_Into.Is_Empty
     and then (for all Part of Split_Into => Tasks.State_Of (Item, Part) = "complete")
   then
      --  Split again into parts all done: nothing is left to wait for,
      --  and waiting would only bring it back here.
      Conclude ("blocked", "its parts " & Comma_Separated (Split_Into) & " are complete and it"
                & " asked for them again; /task complete " & Task_Id & " takes it as done",
                "completed");
      return;
   elsif To_String (Result.Claimed) in "blocked" | "issue" then
      --  Split into parts, it waits for them: once they are accepted and
      --  done it goes back to work on its own, and not before.
      Conclude ("blocked",
                (if Split_Into.Is_Empty then To_String (Result.Summary)
                 else Tasks.Waiting_For (Split_Into) & " (" & To_String (Result.Summary) & ")")
                & (if Parts_Proposed.Is_Empty then ""
                   else "; its agent may not make children, so the parts it asked for are"
                        & " proposals of their own (" & Comma_Separated (Parts_Proposed)
                        & "): /task split " & Task_Id & " makes parts of it by hand"),
                "completed");
      return;
   elsif To_String (Result.Claimed) = "failed" then
      Conclude ("failed", To_String (Result.Summary), "completed");
      return;
   end if;

   --  Done, it says -- but not while a child it needed is going or
   --  failed.
   --  Where the policy lets a parent go on another way, it may -- once
   --  it has said how, which is kept beside the failure it went past.
   declare
      Why     : Unbounded_String;
      Still   : Unbounded_String;
      Instead : constant String := Trim (Invocations.Claim (Said, "instead"));
      Going_On : constant Boolean :=
        Scalar (Item, "agents.on_child_failure") = "continue" and then Instead not in "" | "-";
   begin
      if not Agents.May_Complete (Item, To_String (Result.Agent_Id), Why) then
         if not Going_On
           or else not Agents.May_Complete
                         (Item, To_String (Result.Agent_Id), Still, Past_Failures => True)
         then
            if Going_On then
               Why := Still;
            elsif Scalar (Item, "agents.on_child_failure") = "continue" then
               --  continue set, and no instead: said why it did not go on.
               Append (Why, " (agents.on_child_failure is continue, which goes on only when the agent says"
                            & " instead: how it did the failed part; it said nothing of it)");
            end if;
            Conclude ((if Scalar (Item, "agents.on_child_failure") = "fail" then "failed"
                       else "blocked"),
                      To_String (Why), "completed");
            return;
         end if;
         declare
            Kept : Results.Result :=
              (Kind       => Results.Diagnostic,
               Producer   => Result.Agent_Id,
               Summary    => To_Unbounded_String
                               ("went on past a failed required child: " & To_String (Why)),
               Payload    => To_Unbounded_String (Instead),
               Provenance => Result.Invocation_Id,
               others     => <>);
         begin
            Results.Add (Item, Change, Kept, Status);
            if E.Is_Ok (Status) then
               Stores.Commit (Item, Change, Status);
            end if;
            if E.Is_Error (Status) then
               return;
            end if;
         end;
      end if;
   end;

   --  The routine the project gives the harness, not the model: its
   --  generators, then its formatter, each a profile named by scalar
   --  stage.generate and stage.format, run where the work was written.
   --  What they change is the task's change; one that does not pass
   --  sets the task aside with its evidence.
   for Stage of Name_Lists.Vector'(["generate", "format"]) loop
      declare
         Profile  : constant String := Scalar (Item, "stage." & Stage);
         Evidence : Unbounded_String;
         Passed   : Boolean;
         Ran      : E.Error_Info;
      begin
         if Profile /= "" then
            declare
               Before : constant Configurations.Value_Maps.Map :=
                 Snapshot (To_String (Place), Repository.Roots_Of (Item));
            begin
               Verification.Run_Profile
                 (Item, Change, Profile, Task_Id, Evidence, Passed, Ran,
                  Workspace => (if Isolated then To_String (Place) else ""));
               if E.Is_Ok (Ran) then
                  Stores.Commit (Item, Change, Ran);
               end if;
               if E.Is_Error (Ran) or else not Passed then
                  Conclude ("blocked",
                            "its " & Stage & " stage did not pass"
                            & (if Evidence = Null_Unbounded_String then ": " & Why_Of (Ran)
                               else " (" & To_String (Evidence) & ")"),
                            "completed");
                  return;
               end if;
               declare
                  After : constant Configurations.Value_Maps.Map :=
                    Snapshot (To_String (Place), Repository.Roots_Of (Item));
               begin
                  for Position in After.Iterate loop
                     declare
                        Path : constant String := Configurations.Value_Maps.Key (Position);
                     begin
                        if (not Before.Contains (Path)
                            or else Before (Path) /= Configurations.Value_Maps.Element (Position))
                          and then not Result.Changed_Files.Contains (Path)
                        then
                           Result.Changed_Files.Append (Path);
                        end if;
                     end;
                  end loop;
                  declare
                     Files_Text : Unbounded_String;
                  begin
                     for Path of Result.Changed_Files loop
                        Append (Files_Text, (if Files_Text = Null_Unbounded_String then ""
                                             else [1 => ASCII.LF]) & Path);
                     end loop;
                     Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
                     Stores.Commit (Item, Change, Status);
                  end;
               end;
            end;
         end if;
      end;
   end loop;

   --  Done, it says. The harness decides -- held again for as long as
   --  that may take.
   Hold (Lease_Seconds (Item));
   if E.Is_Ok (Status) then
      Tasks.Move (Item, Change, Task_Id, "verification", "", Status => Status);
   end if;
   if E.Is_Ok (Status) then
      Stores.Commit (Item, Change, Status);
   end if;
   if E.Is_Error (Status) then
      return;
   end if;

   --  Work written apart is taken in before it is verified: by the
   --  harness when the configuration says so, otherwise left waiting for
   --  whoever has the right.
   if Isolated then
      --  Nothing changed where its kind must change something: there is
      --  nothing to take in, and it is blocked now, as it is where work
      --  is written in the project itself -- not after an integration.
      if Result.Changed_Files.Is_Empty
        and then Tasks.Gate_Names (Item, Kind_Of_Task (Item, Task_Id))
                   .Contains ("implementation_present")
      then
         declare
            Given_Up : E.Error_Info;
         begin
            Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Given_Up);
            Conclude ("blocked", "its work changed no file, so there is nothing in "
                      & To_String (Result.Workspace_Id) & " to take in", "completed");
         end;
         return;
      end if;
      --  Checked where it was written, before anyone takes it in: the
      --  evidence says how it stands, and only work that passed is taken
      --  in on its own.
      declare
         Chosen : constant Verification.Choice :=
           Verification.Choose (Item, Task_Id, Result.Changed_Files);
         Space  : Workspaces.Workspace;
         Passed : Boolean := True;
         Said   : Unbounded_String;
      begin
         Workspaces.Read (Item, To_String (Result.Workspace_Id), Space, Held);
         if E.Is_Ok (Held) and then To_String (Chosen.Profile) /= "" then
            Verification.Run_Profile
              (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
               Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For),
               Workspace => To_String (Space.Path));
            if E.Is_Ok (Held) then
               --  Its evidence, as the task's audit reads it.
               Annotate (Item, Change, Task_Id, "current_verification",
                         To_String (Result.Evidence_Id));
               Stores.Commit (Item, Change, Held);
            else
               Change := Stores.No_Changes;
               Passed := False;
            end if;
            Said := To_Unbounded_String
              ("; checked in it: " & (if Passed then "passed" else "did not pass")
               & (if Result.Evidence_Id = Null_Unbounded_String then ""
                  else " (" & To_String (Result.Evidence_Id) & ")"));
         end if;
         --  Work that does not pass where it was written is not taken in
         --  -- and not thrown away either: what nearly does is what is
         --  put right. It waits in its workspace, with what failed.
         if not Passed and then Result.Evidence_Id /= Null_Unbounded_String then
            declare
               Evidence : constant String := To_String (Result.Evidence_Id);
               Space_Id : constant String := To_String (Result.Workspace_Id);
            begin
               Conclude ("", Evidence & " did not pass in " & Space_Id
                         & ", so nothing was taken in"
                         & First_Diagnostics (Item, Evidence)
                         & "; the work is kept there -- put it right in " & Space_Id
                         & " and /task integrate " & Task_Id & " checks it again, or /task integrate "
                         & Task_Id & " discard gives it up and does the task afresh", "completed");
            end;
            return;
         --  Nothing written, nothing to take in: it goes on at once, as
         --  an analysis's answer is all its work.
         elsif Work_Setting (Item, "integrate") /= "automatic"
           and then not (Ada.Strings.Fixed.Index (May_Do (Item, Task_Id), "write") = 0
                         and then Workspaces.Changes (Item, To_String (Result.Workspace_Id)).Is_Empty)
         then
            --  What it did not report is kept, for the taking in to say.
            if Unreported_Note /= "" then
               Annotate (Item, Change, Task_Id, "unreported_files",
                         Unreported_Note (Unreported_Note'First + 41 .. Unreported_Note'Last));
            end if;
            Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in"
                      & To_String (Said)
                      & (if Unreported_Note = "" then "" else "; " & Unreported_Note),
                      "completed");
            return;
         elsif not Passed then
            Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in"
                      & To_String (Said) & ", so it is not taken in on its own", "completed");
            return;
         end if;
      end;

      --  The harness takes it in for the agent only when the agent may
      --  ask for that.
      declare
         Held_Root : Agents.Agent;
      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Root, Held);
         if (E.Is_Error (Held)
             or else not Permissions.Allows (Held_Root.Allowed, Permissions.Request_Integration))
           and then not (Ada.Strings.Fixed.Index (May_Do (Item, Task_Id), "write") = 0
                         and then Workspaces.Changes (Item, To_String (Result.Workspace_Id)).Is_Empty)
         then
            Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in: its"
                      & " agent may not request integration", "completed");
            return;
         end if;
      end;
      declare
         Taken : Name_Lists.Vector;
      begin
         Workspaces.Integrate
           (Item, Change, To_String (Result.Workspace_Id), True, Taken, Held);
         if E.Is_Error (Held) then
            Change := Stores.No_Changes;
            Conclude ("blocked", "its workspace cannot be taken in: "
                      & Why_Of (Held), "completed");
            return;
         end if;
         Report_Integration
           (Item, Change, To_String (Result.Workspace_Id), Task_Id, Taken, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;
         Workspaces.Release (Item, To_String (Result.Workspace_Id));
      end;
   end if;

   --  Verified as widely as what it changed reaches, by the project's
   --  policy: a model has no say in it.
   declare
      Chosen  : constant Verification.Choice :=
        Verification.Choose (Item, Task_Id, Result.Changed_Files);
      Profile : constant String := To_String (Chosen.Profile);
      Passed  : Boolean := False;
   begin
      Result.Scope := Chosen.Scope;
      Result.Scope_Reason := Chosen.Reason;
      if Profile = "" then
         Conclude ("blocked", "no verification profile applies to it", "completed");
         return;
      end if;
      Verification.Run_Profile
        (Item, Change, Profile, Task_Id, Result.Evidence_Id, Passed, Status,
         Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
      if E.Is_Error (Status) then
         Held := Status;
         Status := E.Success;
         Result.Evidence_Id := Null_Unbounded_String;
         Change := Stores.No_Changes;
         Conclude ("blocked", (if Interrupted (Held) then "its verification was cancelled"
                               else "its verification could not run: " & Why_Of (Held)),
                   "completed");
         return;
      end if;
      Annotate (Item, Change, Task_Id, "current_verification",
                To_String (Result.Evidence_Id));
      Stores.Commit (Item, Change, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if not Passed then
         Conclude ("failed", To_String (Result.Evidence_Id) & " did not pass"
                   & First_Diagnostics (Item, To_String (Result.Evidence_Id)),
                   "completed");
         return;
      end if;

      Verification.Complete_Task (Item, Change, Task_Id, Held);
      if E.Is_Error (Held) then
         Change := Stores.No_Changes;
         declare
            Failing : Unbounded_String;
            Judged  : constant Verification.Gate_List := Verification.Gates (Item, Task_Id);
         begin
            for Index in 1 .. Verification.Length (Judged) loop
               declare
                  Next : constant Verification.Gate := Verification.Element (Judged, Index);
               begin
                  if not Next.Passed then
                     Append (Failing, (if Failing = Null_Unbounded_String then "" else "; ")
                                      & To_String (Next.Name) & ": "
                                      & To_String (Next.Reason));
                  end if;
               end;
            end loop;
            Conclude ("blocked", "its gates did not pass: " & To_String (Failing),
                      "completed");
         end;
         return;
      end if;
      --  Committed before the requirements are judged: a requirement is
      --  judged by its tasks as the store holds them, and until then this
      --  one is still in verification.
      Stores.Commit (Item, Change, Status);
      if E.Is_Ok (Status) then
         Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
      end if;
      if E.Is_Ok (Status) then
         --  Done, and with files changed it did not say it changed, or
         --  files it said it changed and did not: said, as what a person
         --  looks at before trusting its report.
         Conclude ("", Unreported_Note
                   & (if Unreported_Note /= "" and then Overclaimed_Note /= "" then "; " else "")
                   & Overclaimed_Note, "completed");
      end if;
   end;
end Execute_Work;
