separate (Model_Runner.Framework.Work)
procedure Recover_On_Opening
  (Item   : in out Stores.Store;
   Opened : Stores.Recovery_Report;
   Said   : out Name_Lists.Vector;
   Status : out Model_Runner.Errors.Error_Info)
is
   Change   : Stores.Transaction;
   Put_Back : Name_Lists.Vector;

   --  The root of an agent: itself, or the first of its ancestors with no
   --  parent.
   function Root_Of (Id : String) return String is
      Held : Agents.Agent;
      Read : E.Error_Info;
   begin
      Agents.Read (Item, Id, Held, Read);
      return (if E.Is_Error (Read) or else Held.Parent = Null_Unbounded_String then Id
              else Root_Of (To_String (Held.Parent)));
   end Root_Of;

   --  Whether something is running an agent: its root holds its task.
   function Live (Id : String) return Boolean is
      Held : Agents.Agent;
      Read : E.Error_Info;
   begin
      Agents.Read (Item, Id, Held, Read);
      return E.Is_Ok (Read)
        and then Leases.Holder (Item, Lease_Of (To_String (Held.Task_Id))) = Root_Of (Id);
   end Live;
begin
   Said.Clear;

   --  0: the configuration, which everything after reads, put right from
   --  its history where it cannot be read.
   declare
      Restored : Natural;
      Kept     : E.Error_Info;
   begin
      Configurations.Recover (Item, Restored, Kept);
      if Restored > 0 then
         Said.Append ("the configuration could not be read and was put back from its history,"
                      & " revision" & Natural'Image (Restored));
      end if;
   end;

   --  1, 2 and 6: what opening the store did.
   if Opened.Rolled_Forward > 0 then
      Said.Append ("finished" & Natural'Image (Opened.Rolled_Forward)
                   & " committed changes an interruption had left");
   end if;
   if Opened.Rolled_Back > 0 then
      Said.Append ("threw away" & Natural'Image (Opened.Rolled_Back)
                   & " changes interrupted before they were committed");
   end if;
   if Opened.Partials_Removed > 0 then
      Said.Append ("removed" & Natural'Image (Opened.Partials_Removed)
                   & " half-written files");
   end if;
   if Opened.Index_Rebuilt then
      Said.Append ("built the entity index again");
   end if;

   --  3: what a killed run left running is stopped, and the tasks it
   --  left running with no one running them put back.
   declare
      Stopped : Name_Lists.Vector;
   begin
      Execution.Stop_Left_Groups (Item, Stopped);
      Said.Append (Stopped);
   end;
   Recover (Item, Put_Back, Status);
   if E.Is_Error (Status) then
      return;
   end if;
   for Id of Put_Back loop
      declare
         Held   : Records.Item;
         Read   : E.Error_Info;
         Reason : Unbounded_String;
      begin
         --  A workspace given up with it is said with it.
         Stores.Read (Item, Tasks_Area, Id & ".state", Held, Read);
         if E.Is_Ok (Read) then
            Reason := To_Unbounded_String (Records.Get (Held, "blocking_reasons"));
         end if;
         Said.Append (Id & " was running with no one running it; it is "
                      & Tasks.State_Of (Item, Id) & " now"
                      & (if Index (Reason, "; its workspace") > 0
                         then Slice (Reason, Index (Reason, "; its workspace"), Length (Reason))
                         elsif Index (Reason, "; what it changed is still") > 0
                         then Slice (Reason, Index (Reason, "; what it changed is still"),
                                     Length (Reason))
                         else ""));
      end;
   end loop;

   --  4: agents and invocations no one is running any more.
   for Name of Stores.Names (Item, Runtime_Area) loop
      if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "agent." then
         declare
            Id   : constant String := Name (Name'First + 6 .. Name'Last);
            Held : Agents.Agent;
            Read : E.Error_Info;
         begin
            Agents.Read (Item, Id, Held, Read);
            if E.Is_Ok (Read)
              and then To_String (Held.Status) in "created" | "running" | "waiting"
              and then not Live (Id)
            then
               Agents.Finish (Item, Change, Id, False, "",
                              "abandoned: nothing was running it", Read);
               if E.Is_Ok (Read) then
                  Said.Append (Id & " was abandoned");
               end if;
            end if;
         end;
      end if;
   end loop;
   for Name of Stores.Names (Item, Invocations_Area) loop
      if Name'Length > 4 and then Name (Name'First .. Name'First + 3) = "INV-"
        and then Invocations.State_Of (Item, Name) = "started"
      then
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            Stores.Read (Item, Invocations_Area, Name, Value, Read);
            if E.Is_Ok (Read) and then not Live (Records.Get (Value, "agent")) then
               Invocations.Finish
                 (Item, Change, Name, Invocations.Failed, (others => 0), "",
                  "abandoned: nothing was running it", Read);
               if E.Is_Ok (Read) then
                  Said.Append (Name & " was abandoned");
                  --  A call it had started and not seen answered: whether
                  --  it took effect is not known, and it is said by name.
                  for Call of Invocations.Unanswered_Calls (Item, Name) loop
                     Said.Append
                       (Name & " stopped in a call that may have changed the project: " & Call);
                  end loop;
               end if;
            end if;
         end;
      end if;
   end loop;

   --  5: workspaces, against their directories and their tasks.
   declare
      Home : constant String :=
        Hostkit.Fs.Join (Stores.Root (Item), "workspaces");
      Recorded : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Workspaces_Area) loop
         declare
            Held  : Workspaces.Workspace;
            Read  : E.Error_Info;
         begin
            Workspaces.Read (Item, Name, Held, Read);
            Recorded.Append (To_String (Held.Id));
            if E.Is_Ok (Read) and then To_String (Held.Status) = "active" then
               declare
                  Now : constant String := Tasks.State_Of (Item, To_String (Held.Task_Id));
               begin
                  if not Ada.Directories.Exists (To_String (Held.Path)) then
                     Workspaces.Abandon (Item, Change, To_String (Held.Id), Read);
                     Said.Append (To_String (Held.Id) & ": its directory is gone; abandoned");
                  elsif Now in "complete" | "cancelled" | "failed" then
                     Workspaces.Abandon (Item, Change, To_String (Held.Id), Read);
                     Said.Append (To_String (Held.Id) & ": its task is " & Now
                                  & "; abandoned");
                  end if;
               end;
            end if;
         end;
      end loop;
      if Ada.Directories.Exists (Home) then
         declare
            use Ada.Directories;
            Search : Search_Type;
            Found  : Directory_Entry_Type;
         begin
            Start_Search (Search, Home, "WS-*", [Directory => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Found);
               if not Recorded.Contains (Simple_Name (Found)) then
                  Said.Append ("workspaces/" & Simple_Name (Found)
                               & " has no record; it is left for you to remove");
               end if;
            end loop;
            End_Search (Search);
         end;
      end if;
   end;

   Stores.Commit (Item, Change, Status);
   if E.Is_Error (Status) then
      return;
   end if;

   --  7: readiness and verification, as the state now stands.
   declare
      Moved : Name_Lists.Vector;
   begin
      Reevaluate (Item, Moved, Status);
      Said.Append (Moved);
   end;

   --  What of the state goes into the repository, as the policy says.
   declare
      Written : Boolean;
      Kept    : E.Error_Info;
   begin
      Git.Keep_Policy (Item, Written, Kept);
      if Written then
         Said.Append ("wrote the state's .gitignore for its repository policy");
      end if;
   end;

   --  Results the project keeps only for a while, let go of.
   declare
      Removed : Natural;
   begin
      Results.Prune
        (Item, Change,
         Raw_Log_Days => Number_Of (Scalar (Item, "retention.raw_log_days"), 0),
         Context_Days => Number_Of (Scalar (Item, "retention.context_days"), 0),
         Removed      => Removed,
         Cache_Days   => Number_Of (Scalar (Item, "retention.cache_days"), 0));
      if Removed > 0 then
         Stores.Commit (Item, Change, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Said.Append ("let go of" & Natural'Image (Removed)
                      & " raw logs and kept contexts past their retention");
      end if;

      --  And the payloads kept apart that nothing refers to now.
      declare
         Collected : Natural;
      begin
         Results.Collect_Payloads (Item, Collected);
      end;
   end;

   --  6: the repository's graph, brought up to date and kept, so what
   --  reads it next reads only what changed since; and the indexes
   --  built again where they are missing or stale.
   declare
      Graph  : Repository.Graph;
      Kept   : E.Error_Info;
      Change : Stores.Transaction;
   begin
      Repository.Current (Item, Graph, Kept);
      if not Indexes.Current (Item, Graph) then
         Indexes.Build (Item, Change, Graph, Kept);
         if E.Is_Ok (Kept) then
            Stores.Commit (Item, Change, Kept);
         end if;
      end if;
   end;

   --  7: the events nothing has acted on yet -- a session that stopped
   --  between an event and what it calls for -- acted on now.
   declare
      Done : Orchestration.Step_Report;
      Ran  : E.Error_Info;
   begin
      --  Routine, and not said as such: only what it made -- a task a
      --  requirement implies -- and what it could not do.
      Orchestration.Step (Item, Done, Ran);
      for Id of Done.Derived loop
         Said.Append ("derived " & Id & " from an accepted requirement");
      end loop;
      if E.Is_Error (Ran) then
         Said.Append ("the rules could not all be acted on: " & Why_Of (Ran));
      end if;
   end;

   --  8: leases run out are let go of, once, and said.
   declare
      Change  : Stores.Transaction;
      Cleared : Name_Lists.Vector;
      Kept    : E.Error_Info;
   begin
      Leases.Clear_Stale (Item, Change, Cleared);
      Stores.Commit (Item, Change, Kept);
      if E.Is_Ok (Kept) then
         for Resource of Cleared loop
            Said.Append (Resource & ": its lease had run out, and is let go of");
         end loop;
      end if;
   end;

   --  9: what is still wrong, for someone to settle.
   declare
      Wrong : constant Consistency.Finding_List := Consistency.Check (Item);

      --  Said once: the same findings as last time are not said again.
      Mark    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "consistency.said");
      Summary : Unbounded_String;
      Before  : Unbounded_String;
      Read    : E.Error_Info;
      Kept    : E.Error_Info;
   begin
      for Index in 1 .. Consistency.Length (Wrong) loop
         Append (Summary, To_String (Consistency.Element (Wrong, Index).Subject) & " "
                 & To_String (Consistency.Element (Wrong, Index).Detail) & ASCII.LF);
      end loop;
      if Ada.Directories.Exists (Mark) then
         Files.Read_Text (Mark, Before, Read);
      end if;
      if Before /= Summary then
         Files.Write_Text (Mark, To_String (Summary), Kept);
      end if;
      if Consistency.Length (Wrong) > 0 and then Before /= Summary then
         Said.Append
           ("what does not hold together in the state:"
            & Natural'Image (Consistency.Length (Wrong)) & ", first "
            & To_String (Consistency.Element (Wrong, 1).Subject) & ": "
            & To_String (Consistency.Element (Wrong, 1).Detail)
            & "; /check consistency lists it all");
      end if;
   end;
end Recover_On_Opening;
