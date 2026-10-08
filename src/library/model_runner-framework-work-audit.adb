separate (Model_Runner.Framework.Work)
function Audit (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is
   Result  : Name_Lists.Vector;
   Defined : Records.Item;
   State   : Records.Item;
   Call    : Records.Item;
   Plan    : Records.Item;
   Proof   : Records.Item;
   Status  : E.Error_Info;

   procedure Say (Question, Answer : String) is
   begin
      Result.Append (Question & ": " & (if Answer = "" then "(nothing recorded)" else Answer));
   end Say;

   --  A record there and not readable is said as that: its answers below
   --  read as nothing recorded, which is not what happened.
   procedure Unless_Read (What : String) is
   begin
      if E.Is_Error (Status) and then E."/=" (Status.Code, E.Framework_Not_Found) then
         Result.Append (What & ": cannot be read (" & E.Error_Code'Image (Status.Code) & ")");
      end if;
   end Unless_Read;

   --  The fields of a record whose names start with a prefix, as
   --  NAME VALUE, joined; the name without so much of it as Kept says
   --  not to keep.
   function Fields_With
     (Value : Records.Item; Prefix : String; Kept : Natural := 0; Between : String := " ") return String
   is
      Text : Unbounded_String;
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
         begin
            if Field'Length > Prefix'Length
              and then Field (Field'First .. Field'First + Prefix'Length - 1) = Prefix
            then
               Append (Text, (if Text = Null_Unbounded_String then "" else ", ")
                       --  A tool's version that names it already: not named twice.
                       & (if Kept = 0
                            and then Ada.Strings.Fixed.Index
                                       (Records.Get (Value, Field),
                                        Field (Field'First + Prefix'Length .. Field'Last) & " ") = 1
                          then Records.Get (Value, Field)
                          else Field (Field'First + Prefix'Length - Kept .. Field'Last) & Between
                               & Records.Get (Value, Field)));
            end if;
         end;
      end loop;
      return To_String (Text);
   end Fields_With;

   --  The last invocation made for the task.
   function Last_Call return String is
      Found : Unbounded_String;
   begin
      for Name of Stores.Names (Item, Invocations_Area) loop
         if Name'Length > 4 and then Name (Name'First .. Name'First + 3) = "INV-" then
            declare
               Value : Records.Item;
               Read  : E.Error_Info;
            begin
               Stores.Read (Item, Invocations_Area, Name, Value, Read);
               if E.Is_Ok (Read) and then Records.Get (Value, "task") = Task_Id
                 and then Records.Get (Value, "result_contract") = "work_claim"
               then
                  Found := To_Unbounded_String (Name);
               end if;
            end;
         end if;
      end loop;
      return To_String (Found);
   end Last_Call;

   Invocation : constant String := Last_Call;

   --  What became of a workspace: taken in, given up, or still there.
   function Workspace_Status (Id : String) return String is
      Held : Workspaces.Workspace;
      Read : E.Error_Info;
   begin
      Workspaces.Read (Item, Id, Held, Read);
      return (if E.Is_Ok (Read) then To_String (Held.Status) else "");
   end Workspace_Status;
begin
   Tasks.Definition (Item, Task_Id, Defined, Status);
   Unless_Read ("its definition");
   Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Status);
   Unless_Read ("its state");
   if Invocation /= "" then
      Stores.Read (Item, Invocations_Area, Invocation, Call, Status);
      Unless_Read ("its last call, " & Invocation);
      Stores.Read (Item, Invocations_Area, "manifest." & Records.Get (Call, "context_manifest"),
                   Plan, Status);
      Unless_Read ("that call's context manifest");
   end if;
   if Records.Get (State, "current_verification") /= "" then
      Stores.Read (Item, Verification_Area, Records.Get (State, "current_verification"),
                   Proof, Status);
      Unless_Read ("its verification, " & Records.Get (State, "current_verification"));
   end if;

   --  The revisions its context read, or, never worked, the one it was
   --  made from.
   if Invocation = "" then
      --  Never worked: where it came from, and that, on lines of their own.
      if Records.Get (Defined, "origin") /= "" then
         Say ("made from", Records.Get (Defined, "origin"));
      end if;
      Say ("worked", "never");
   else
      Say ("requirement revisions", Fields_With (Plan, "applies.REQ", Kept => 3, Between => " at revision "));
   end if;
   Say ("task definition revision", Trim (Natural'Image (Records.Revision (Defined))));
   Say ("why it could start", Records.Get (State, "admission"));
   Say ("decisions", Fields_With (Plan, "applies.DEC", Kept => 3, Between => " at revision "));
   Say ("context", Records.Get (Call, "context_manifest")
        & (if Records.Get (Plan, "rendered") = "" then ""
           else ", rendered as " & Records.Get (Plan, "rendered")));
   Say ("agent", (if Records.Get (State, "runner") /= "" then Records.Get (State, "runner")
                  else Records.Get (Call, "model_profile"))
        & (if Invocation = "" then "" else ", in " & Invocation));
   Say ("answer", Records.Get (Call, "result"));
   Say ("issues", Records.Get (State, "issues"));

   --  Where it came from: a part names its parent and who split it.
   if Records.Get (Defined, "parent") /= "" then
      Say ("part of", Records.Get (Defined, "parent")
           & (if Records.Get (Defined, "created_by") = "" then ""
              else ", split by " & Records.Get (Defined, "created_by")));
   elsif Records.Get (Defined, "created_by") /= "" then
      Say ("made by", Records.Get (Defined, "created_by")
           & (if Records.Get (Defined, "origin") = "" then ""
              else ", from " & Records.Get (Defined, "origin")));
   end if;

   --  Every attempt, and every agent that worked for it: those a root
   --  agent started with delegate among them, and how each ended.
   declare
      Attempts : Unbounded_String;
      Workers  : Unbounded_String;
   begin
      for Name of Stores.Names (Item, Runtime_Area) loop
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "agent." then
               Stores.Read (Item, Runtime_Area, Name, Value, Read);
            else
               Read := E.Make (E.Framework_Not_Found);
            end if;
            if E.Is_Ok (Read) and then Records.Get (Value, "task") = Task_Id then
               Append (Workers, (if Workers = Null_Unbounded_String then "" else ", ")
                       & Name (Name'First + 6 .. Name'Last) & " "
                       --  Stopped by the person: stopped, as the task is said.
                       & (if Records.Get (Value, "state") = "cancelled"
                            and then Ada.Strings.Fixed.Index (Records.Get (Value, "summary"), "you stopped") > 0
                          then "stopped"
                          --  Its work left to be taken in: what the task shows.
                          elsif Records.Get (Value, "outcome") = "verification"
                          then "done, its work to integrate"
                          else Records.Get (Value, "state"))
                       & (if Records.Get (Value, "parent") = "" then ""
                          else " (a child of " & Records.Get (Value, "parent")
                               & (if Records.Get (Value, "retry_of") = "" then ""
                                  else ", a retry of " & Records.Get (Value, "retry_of"))
                               & ")")
                       --  An ended one says why, where it was stopped.
                       & (if Records.Get (Value, "state") = "cancelled"
                            and then Ada.Strings.Fixed.Index (Records.Get (Value, "summary"), "you stopped") > 0
                          then ""
                          elsif Records.Get (Value, "state") = "cancelled"
                            and then Records.Get (Value, "summary") /= ""
                          then ": " & Records.Get (Value, "summary") else ""));

               --  An attempt is its root agent's run: how that ended,
               --  and why, not only that its call returned.
               if Records.Get (Value, "parent") = "" then
                  declare
                     Why : constant String := Records.Get (Value, "summary");
                  begin
                     Append (Attempts, (if Attempts = Null_Unbounded_String then "" else "; ")
                             & Name (Name'First + 6 .. Name'Last)
                             & (if Records.Get (Value, "invocation") = "" then ""
                                else " in " & Records.Get (Value, "invocation"))
                             & " " & (if Records.Get (Value, "outcome") = "blocked"
                                        and then Ada.Strings.Fixed.Index (Why, "you stopped its work") > 0
                                      then "left it stopped"
                                      --  As the list says the task: to integrate.
                                      elsif Records.Get (Value, "outcome") = "verification"
                                      then "left its work to integrate"
                                      elsif Records.Get (Value, "outcome") /= ""
                                      then "left it " & Records.Get (Value, "outcome")
                                      else Records.Get (Value, "state"))
                             & (if Why = "" then "" else ": " & Why));
                  end;
               end if;
            end if;
         end;
      end loop;
      Say ("attempts", To_String (Attempts));
      Say ("agents", To_String (Workers));
   end;

   --  Every move it made, when and why, not only the last attempt's.
   declare
      Happened : constant Events.Event_List := Events.Since (Item, 0);
      --  Stopped by the person last: its next move is from stopped.
      Was_Stopped : Boolean := False;
      --  This move is from a stop: said as taken up again.
      Was_Stopped_Before : Boolean := False;
      --  On its way to being completed by hand: the completion said so.
      By_Hand : Boolean := False;
   begin
      for Index in 1 .. Events.Length (Happened) loop
         declare
            One : constant Events.Event := Events.Element (Happened, Index);
            Raw : constant String := To_String (One.Detail);
            --  Its words as a person reads them: stopped, not blocked, where
            --  the stop is what it came from; reconsidered, not created.
            Detail : constant String :=
              (if Was_Stopped and then Ada.Strings.Fixed.Index (Raw, "blocked -> ") = Raw'First
               then "stopped -> " & Raw (Raw'First + 11 .. Raw'Last)
               else Raw);
         begin
            --  A move a completion by hand went through on its way --
            --  taken to running, then to its checks, at the same moment:
            --  the completion says it, not a run that never was.
            if To_String (One.Subject) = Task_Id
              and then (Ada.Strings.Fixed.Index (Raw, "-> running") > 0
                        or else Ada.Strings.Fixed.Index (Raw, "running -> verification") > 0)
              and then Ada.Strings.Fixed.Index (Raw, "completed by hand") > 0
            then
               By_Hand := True;
            elsif To_String (One.Subject) = Task_Id then
               Was_Stopped_Before := Was_Stopped and then Detail /= Raw;
               Was_Stopped := Ada.Strings.Fixed.Index (Raw, "-> blocked: you stopped its work") > 0;
               Result.Append
                 ("history: " & To_String (One.Occurred_At) & " "
                  --  In words: Task_Became_Ready is became ready.
                  & (if Ada.Strings.Fixed.Index (To_String (One.Detail), "-> blocked: you stopped its work") > 0
                     then "stopped"
                     --  Never worked, and taken to running: on its way to
                     --  being completed by hand.
                     elsif Words_Of_Kind (To_String (One.Kind_Word)) = "started"
                       and then (Invocation = "" or else Ada.Strings.Fixed.Index (Raw, "completed by hand") > 0)
                     then "taken up to be completed by hand"
                     elsif Ada.Strings.Fixed.Index (Raw, "rejected -> candidate") = Raw'First then "reconsidered"
                     elsif Was_Stopped_Before then "taken up again"
                     elsif By_Hand and then Ada.Strings.Fixed.Index (Raw, "-> complete") > 0
                     then "completed by hand"
                     else Words_Of_Kind (To_String (One.Kind_Word)))
                  & (if Length (One.Detail) = 0 then ""
                     --  Stopped by the person: said so, as /state says it.
                     elsif Ada.Strings.Fixed.Index (To_String (One.Detail), "-> blocked: you stopped its work") > 0
                     then " -- " & Ada.Strings.Fixed.Replace_Slice
                                     (To_String (One.Detail),
                                      Ada.Strings.Fixed.Index (To_String (One.Detail), "-> blocked"),
                                      Ada.Strings.Fixed.Index (To_String (One.Detail), "-> blocked") + 9,
                                      "-> stopped")
                     else " -- " & Detail));
            end if;
         end;
      end loop;
   end;
   Say ("proposed", Proposals_Of (Item, Task_Id));
   Say ("files changed", Comma_Separated (Lines_Of (Records.Get (State, "changed_files"))));
   Say ("workspace", Records.Get (State, "current_workspace"));
   Say ("verification", Records.Get (State, "current_verification")
        & (if Records.Get (Proof, "profile") = "" then ""
           else ", profile " & Records.Get (Proof, "profile")
                & (if Records.Get (Proof, "passed") = "true" then ", passed" else ", failed")));
   Say ("tool versions", Fields_With (Proof, "tool."));
   --  Checks run for it on the way -- by its agent, or by hand -- each
   --  with how it came out.
   declare
      Runs : Unbounded_String;
   begin
      for Name of Stores.Names (Item, Verification_Area) loop
         declare
            Evidence : constant String :=
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            if Ada.Strings.Fixed.Index (Evidence, "VER-") = Evidence'First then
               Stores.Read (Item, Verification_Area, Evidence, Value, Read);
               if E.Is_Ok (Read) and then Records.Get (Value, "task") = Task_Id
                 and then Evidence /= Records.Get (State, "current_verification")
               then
                  Append (Runs, (if Runs = Null_Unbounded_String then "" else ", ") & Evidence
                          & (if Records.Get (Value, "passed") = "true" then " passed" else " failed"));
               end if;
            end if;
         end;
      end loop;
      Say ("checks run on the way", To_String (Runs));
   end;
   Say ("completion",
        (if Tasks.State_Of (Item, Task_Id) /= "complete"
         then (if Tasks.State_Of (Item, Task_Id) = "failed" then "it has failed"
               --  Stopped by the person: said so, with the way on.
               elsif (for some Reason of Tasks.Ready (Item, Task_Id).Reasons =>
                        Ada.Strings.Fixed.Index (Reason, "you stopped its work") > 0)
               then "it is stopped (Ctrl-C) -- /task accept " & Task_Id & " takes it up again"
               else "it is " & Tasks.State_Of (Item, Task_Id))
         elsif Records.Get (State, "completed_by") = "hand"
         then "completed by hand"
              & (if Records.Get (State, "current_verification") = "" then ", with no evidence"
                 else ", checked by " & Records.Get (State, "current_verification"))
              & (if Records.Get (State, "set_aside") = "" then ""
                 else "; set aside: "
                      & Comma_Separated (Lines_Of (Records.Get (State, "set_aside"))))
         elsif Records.Get (State, "current_verification") = ""
         then "its gates passed, with no evidence"
         else "its gates passed on " & Records.Get (State, "current_verification")));
   if Records.Get (State, "replaced_by") /= "" then
      Say ("replaced", Records.Get (State, "replaced_by"));
   end if;
   for Line of Lines_Of (Records.Get (State, "conflicts")) loop
      Say ("conflict", Line);
   end loop;
   if Records.Get (State, "resolution") /= "" then
      Say ("resolution", Records.Get (State, "resolution"));
   end if;
   Say ("integration",
        (if Records.Get (State, "current_workspace") = ""
         then (if Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" then "none yet"
               elsif Invocation = "" then "none: it was never worked"
               else "none: it wrote in the project itself")
         elsif Tasks.State_Of (Item, Task_Id) = "complete"
           and then Workspace_Status (Records.Get (State, "current_workspace")) = "integrated"
         then "the workspace " & Records.Get (State, "current_workspace") & ", taken in"
              & (if Records.Get (State, "integration_note") = "" then ""
                 else "; " & Records.Get (State, "integration_note"))
         elsif Workspaces.Active_For (Item, Task_Id) /= ""
         then "the workspace " & Records.Get (State, "current_workspace") & ", waiting to be"
              & " taken in"
         else "the workspace " & Records.Get (State, "current_workspace") & ", given up:"
              & " nothing of it was taken in"
              & (if Records.Get (State, "changed_files") = "" then ""
                 else "; what it changed there ("
                      & Comma_Separated (Lines_Of (Records.Get (State, "changed_files")))
                      & (if Ada.Directories.Exists
                           (Workspaces.Kept_Copy (Item, Records.Get (State, "current_workspace")))
                         then ") is kept in "
                              & Ada.Directories.Simple_Name
                                  (Workspaces.Kept_Copy
                                     (Item, Records.Get (State, "current_workspace")))
                         else ") went with it"))));
   declare
      Became : Unbounded_String;
   begin
      for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
            Append (Became, (if Became = Null_Unbounded_String then "" else ", ")
                    & Requirement & " " & To_String (Held.State));
         end;
      end loop;
      Say ("requirements now", To_String (Became));
   end;
   return Result;
end Audit;
