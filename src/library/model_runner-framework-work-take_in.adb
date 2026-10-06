separate (Model_Runner.Framework.Work)
procedure Take_In
  (Item    : in out Stores.Store;
   Task_Id : String;
   Result  : out Report;
   Status  : out Model_Runner.Errors.Error_Info;
   Semantic_Accepted : Boolean := False;
   Text_Resolved     : Boolean := False;
   Replaced_Kept     : String := "")
is
   Change : Stores.Transaction;
   Id     : constant String := Workspaces.Active_For (Item, Task_Id);
   Taken  : Name_Lists.Vector;
   Passed : Boolean := False;
   Held   : E.Error_Info;
begin
   Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);

   --  Work is taken in for a task that waits for it -- in verification,
   --  its agent done -- and not for one set aside or still being worked.
   if Tasks.State_Of (Item, Task_Id) /= "verification" then
      Status := E.Make (E.Framework_Transition_Invalid);
      E.Add_Text (Status, "name", Task_Id);
      E.Add_Text (Status, "value", Tasks.State_Of (Item, Task_Id));
      E.Add_Text (Status, "expected", "being taken in");
      declare
         State_Value : Records.Item;
         Read        : E.Error_Info;
         Had         : Unbounded_String;

         --  How a workspace it had ended: integrated, abandoned; "".
         function Space_Status return String is
            Space_Value : Records.Item;
            Space_Read  : E.Error_Info;
         begin
            if Had = Null_Unbounded_String then
               return "";
            end if;
            Stores.Read (Item, Workspaces_Area, To_String (Had), Space_Value, Space_Read);
            return (if E.Is_Error (Space_Read) then "" else Records.Get (Space_Value, "status"));
         end Space_Status;
      begin
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", State_Value, Read);
         Had := To_Unbounded_String (Records.Get (State_Value, "current_workspace"));
         E.Add_Text
           (Status, "detail",
            (if Id /= "" then "only work that waits to be taken in is taken in"
             elsif Had = Null_Unbounded_String
               and then Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" | "ready"
               and then Records.Get (State_Value, "generation") in "" | "0"
             then "it has not been worked on yet, so nothing of it waits to be taken in; /work " & Task_Id
                  & " does it"
             elsif Had = Null_Unbounded_String
               and then Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" | "ready"
             then "no work of it waits to be taken in: what its last attempt wrote is in the project"
                  & " itself; /work " & Task_Id & " does it again"
             elsif Had = Null_Unbounded_String
             then "it has no workspace -- it wrote in the project itself -- so there is nothing"
                  & " to take in"
             elsif Tasks.State_Of (Item, Task_Id) = "complete" and then Space_Status = "abandoned"
             then "it is complete, and " & To_String (Had) & " was given up: nothing of it waits to be"
                  & " taken in"
             elsif Tasks.State_Of (Item, Task_Id) = "complete"
             then To_String (Had) & " was taken in already"
             elsif Tasks.State_Of (Item, Task_Id) = "cancelled"
             then To_String (Had) & " was given up when it was cancelled; /task reopen " & Task_Id
                  & " makes it ready again"
             elsif Tasks.State_Of (Item, Task_Id) = "blocked"
               and then not Tasks.Children (Item, Task_Id).Is_Empty
             then To_String (Had) & " was given up when it split into parts; it goes on once they"
                  & " are done"
             --  Ready to be worked again: no work of it waits, and /work
             --  is what makes some.
             elsif Tasks.State_Of (Item, Task_Id) = "accepted"
             then "no work of it waits to be taken in -- " & To_String (Had) & " went with its last"
                  & " attempt; /work " & Task_Id & " does it"
             --  Stopped by the person: said so, with where its work was kept.
             elsif Tasks.State_Of (Item, Task_Id) = "blocked"
               and then (for some Reason of Tasks.Ready (Item, Task_Id).Reasons =>
                           Ada.Strings.Fixed.Index (Reason, "you stopped its work") > 0)
             then To_String (Had) & " was given up when you stopped it"
                  & (if Ada.Directories.Exists (Workspaces.Kept_Copy (Item, To_String (Had)))
                     then ", what it changed kept in "
                          & Ada.Directories.Simple_Name (Workspaces.Kept_Copy (Item, To_String (Had)))
                          & " -- /task kept diff "
                          & Ada.Directories.Simple_Name (Workspaces.Kept_Copy (Item, To_String (Had)))
                          & " shows it, /task kept restore "
                          & Ada.Directories.Simple_Name (Workspaces.Kept_Copy (Item, To_String (Had)))
                          & " puts it in the project; or"
                     else ";")
                  & " /task accept " & Task_Id & " does its work again"
             else To_String (Had) & " was given up when it " & Tasks.State_Of (Item, Task_Id)
                  & "; /task accept " & Task_Id & " does its work again"));
      end;
      return;
   end if;
   if Id = "" then
      Status := E.Make (E.Framework_Not_Found);
      E.Add_Text (Status, "name", "a workspace of " & Task_Id);
      return;
   end if;
   Result.Workspace_Id := To_Unbounded_String (Id);

   --  Settled by a person: checked where it was settled before any of it
   --  reaches the project, and left there when it does not pass.
   if Text_Resolved then
      declare
         Chosen : constant Verification.Choice :=
           Verification.Choose (Item, Task_Id, Workspaces.Changes (Item, Id));
         Space  : Workspaces.Workspace;
      begin
         Workspaces.Read (Item, Id, Space, Held);
         if E.Is_Ok (Held) and then To_String (Chosen.Profile) /= "" then
            Verification.Run_Profile
              (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
               Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For),
               Workspace => To_String (Space.Path));
            if E.Is_Ok (Held) then
               Stores.Commit (Item, Change, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               if not Passed then
                  Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
                  Result.Reason := To_Unbounded_String
                    ("it did not pass in " & Id & ", so nothing was taken in: "
                     & To_String (Result.Evidence_Id) & " did not pass"
                     & First_Diagnostics (Item, To_String (Result.Evidence_Id)));
                  Status := E.Success;
                  return;
               end if;
            else
               Change := Stores.No_Changes;
            end if;
         end if;
      end;
      Change := Stores.No_Changes;
   end if;

   --  Settled, it says: what is as it was when the conflict was found is
   --  the workspace's copy taken over the project's change, and said.
   declare
      Unsettled : constant Name_Lists.Vector :=
        (if Text_Resolved then Workspaces.Conflict_Files (Item, Id, Unsettled_Only => True)
         else Name_Lists.Empty_Vector);
   begin
      if not Unsettled.Is_Empty then
         declare
            --  The tasks whose change to those files the copy replaced:
            --  those completed after this workspace was made, not those
            --  whose change it was made from.
            Whose   : Name_Lists.Vector;
            History : constant Events.Event_List := Events.Since (Item, 0);
            Made_At : Natural := 0;

            function Done_Since (Other : String) return Boolean is
            begin
               for Index in 1 .. Events.Length (History) loop
                  declare
                     One : constant Events.Event := Events.Element (History, Index);
                  begin
                     if One.Sequence > Made_At
                       and then ((Events."=" (One.Kind, Events.Task_Completed)
                                  and then To_String (One.Subject) = Other)
                                 or else (Events."=" (One.Kind, Events.Workspace_Integrated)
                                          and then To_String (One.Detail) = Other))
                     then
                        return True;
                     end if;
                  end;
               end loop;
               return False;
            end Done_Since;
         begin
            for Index in 1 .. Events.Length (History) loop
               if Events."=" (Events.Element (History, Index).Kind, Events.Workspace_Created)
                 and then To_String (Events.Element (History, Index).Subject) = Id
               then
                  Made_At := Events.Element (History, Index).Sequence;
               end if;
            end loop;
            for Other of Tasks.List (Item, "complete") loop
               declare
                  State : Records.Item;
                  Read  : E.Error_Info;
               begin
                  Stores.Read (Item, Tasks_Area, Other & ".state", State, Read);
                  if Other /= Task_Id and then E.Is_Ok (Read)
                    and then (for some Path of Unsettled =>
                                Lines_Of (Records.Get (State, "changed_files")).Contains (Path))
                    and then Done_Since (Other)
                  then
                     Whose.Append (Other);
                  end if;
               end;
            end loop;
            Result.Reason := To_Unbounded_String
              ("not changed since the conflict was found, so the workspace's copy replaced the"
               & " project's change"
               & (if Whose.Is_Empty then "" else " (" & Comma_Separated (Whose) & "'s)")
               & ": " & Comma_Separated (Unsettled));
            Annotate (Item, Change, Task_Id, "integration_note", To_String (Result.Reason));
            --  Each task whose change went says so in its own history, with
            --  how to have it again.
            for Other of Whose loop
               Annotate (Item, Change, Other, "replaced_by",
                         Task_Id & "'s taking in replaced its change to "
                         & Comma_Separated (Unsettled) & "; /task reopen " & Other
                         & " does it again");
            end loop;
            if not Whose.Is_Empty then
               Append (Result.Reason, "; /task reopen " & Comma_Separated (Whose)
                       & " does that work again");
            end if;
         end;
      end if;
   end;
   --  How a conflict was got past, in the task's history.
   if Text_Resolved or else Semantic_Accepted then
      Annotate (Item, Change, Task_Id, "resolution",
                (if Replaced_Kept /= ""
                 then "the workspace's copy replaced the project's (resolved anyway); the project's"
                      & " copy is kept in " & Replaced_Kept
                 elsif Text_Resolved and then Semantic_Accepted then "settled by hand and taken in anyway"
                 elsif Text_Resolved then "settled by hand in " & Id
                 else "taken in anyway, past what the code joins"));
   end if;
   Workspaces.Integrate (Item, Change, Id, True, Taken, Status, Semantic_Accepted,
                         Text_Resolved);

   --  A conflict found: kept in the task's history, each time, apart
   --  from the change that did not happen.
   if Status.Code = E.Framework_Integration_Conflict then
      declare
         Noted  : Stores.Transaction;
         Kept   : E.Error_Info;
         State  : Records.Item;
         Read   : E.Error_Info;
      begin
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Read);
         Annotate (Item, Noted, Task_Id, "conflicts",
                   (if Records.Get (State, "conflicts") = "" then ""
                    else Records.Get (State, "conflicts") & ASCII.LF)
                   & Timestamp & " " & Id & ": "
                   & (if Workspaces.Conflict_Files (Item, Id).Is_Empty then E.Text_Of (Status, "detail")
                      else Comma_Separated (Workspaces.Conflict_Files (Item, Id))));
         Stores.Commit (Item, Noted, Kept);
      end;
   end if;

   if E.Is_Ok (Status) then
      Report_Integration (Item, Change, Id, Task_Id, Taken, Status);
   end if;
   --  What it took in, file by file as it was then: what differs later
   --  is not its; and taken in again, it is undone no more.
   if E.Is_Ok (Status) then
      declare
         Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
         Prints  : Unbounded_String;
      begin
         for Path of Taken loop
            Append (Prints, Path & ASCII.HT & File_Print (Hostkit.Fs.Join (Project, Path)) & ASCII.LF);
         end loop;
         Annotate (Item, Change, Task_Id, "taken_in", To_String (Prints));
         Annotate (Item, Change, Task_Id, "undone_by", "");
         --  Joined with the project's own change: lines of it are not its.
         declare
            Joined : Unbounded_String;
         begin
            for Path of Workspaces.Last_Joined loop
               Append (Joined, Path & ASCII.LF);
            end loop;
            --  Settled by hand, both sides' lines in it: joined too.
            if Text_Resolved then
               declare
                  Unsettled : constant Name_Lists.Vector :=
                    Workspaces.Conflict_Files (Item, Id, Unsettled_Only => True);
               begin
                  for Path of Workspaces.Conflict_Files (Item, Id) loop
                     if not Unsettled.Contains (Path) and then Ada.Strings.Unbounded.Index (Joined, Path) = 0 then
                        Append (Joined, Path & ASCII.LF);
                     end if;
                  end loop;
               end;
            end if;
            Annotate (Item, Change, Task_Id, "joined_files", To_String (Joined));
         end;
      end;
   end if;
   if E.Is_Ok (Status) then
      Stores.Commit (Item, Change, Status);
   end if;
   if E.Is_Ok (Status) then
      Workspaces.Release (Item, Id);
   end if;
   if E.Is_Error (Status) then
      return;
   end if;
   Result.Changed_Files := Taken;

   --  The project as it is now is what is verified, as widely as what was
   --  taken in reaches -- and the task goes where that leaves it, as work
   --  the harness ran goes: failed when the checks failed, blocked when
   --  they could not run or its gates did not hold, never left waiting.
   declare
      Chosen : constant Verification.Choice := Verification.Choose (Item, Task_Id, Taken);

      procedure Leave (Next, Why : String) is
         Moved : E.Error_Info;
      begin
         Change := Stores.No_Changes;
         Tasks.Move (Item, Change, Task_Id, Next, Why, Status => Moved);
         if E.Is_Ok (Moved) then
            Stores.Commit (Item, Change, Moved);
         end if;
         Result.Reason := To_Unbounded_String (Why);
      end Leave;
   begin
      Result.Scope := Chosen.Scope;
      Result.Scope_Reason := Chosen.Reason;
      if To_String (Chosen.Profile) = "" then
         Leave ("blocked", "no verification profile applies to it");
      else
         Verification.Run_Profile
           (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed, Held,
            Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
         if E.Is_Error (Held) then
            Leave ("blocked", (if Interrupted (Held) then "its verification was cancelled"
                                 else "its verification could not run: " & Why_Of (Held)));
         else
            Annotate (Item, Change, Task_Id, "current_verification",
                      To_String (Result.Evidence_Id));
            Stores.Commit (Item, Change, Status);
            if not Passed then
               Leave ("failed", To_String (Result.Evidence_Id) & " did not pass"
                      & First_Diagnostics (Item, To_String (Result.Evidence_Id)));
            else
               Verification.Complete_Task (Item, Change, Task_Id, Held);
               if E.Is_Ok (Held) then
                  --  Committed first, as Execute does: the requirements
                  --  are judged by the task as complete.
                  Stores.Commit (Item, Change, Status);
                  if E.Is_Ok (Status) then
                     Verification.Reevaluate_Requirements
                       (Item, Change, Result.Requirements, Status);
                  end if;
                  if E.Is_Ok (Status) then
                     Stores.Commit (Item, Change, Status);
                  end if;
               else
                  declare
                     Failing : Unbounded_String;
                     Judged  : constant Verification.Gate_List :=
                       Verification.Gates (Item, Task_Id);
                  begin
                     for Index in 1 .. Verification.Length (Judged) loop
                        if not Verification.Element (Judged, Index).Passed then
                           Append (Failing,
                                   (if Failing = Null_Unbounded_String then "" else "; ")
                                   & To_String (Verification.Element (Judged, Index).Name) & ": "
                                   & To_String (Verification.Element (Judged, Index).Reason));
                        end if;
                     end loop;
                     Leave ("blocked", "its gates did not pass: " & To_String (Failing));
                  end;
               end if;
            end if;
         end if;
      end if;
   end;
   Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
end Take_In;
