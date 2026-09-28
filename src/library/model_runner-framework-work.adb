with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Indexes;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Text;

package body Model_Runner.Framework.Work is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Lease_Of (Task_Id : String) return String
   is ("task." & Task_Id);

   ------------------
   -- Instructions --
   ------------------

   function Instructions return String
   is ("## What to do" & ASCII.LF
       & "Do the task now, with the tools: read_file reads a file, write_file"
       & " writes the whole new content of a file, list_directory lists a"
       & " directory. Paths are relative to the project. Make each change by"
       & " calling write_file; describing a change does not make it. Where"
       & " you have delegate, a part better done apart -- a review, an"
       & " investigation -- can be handed to a helper, who reports back."
       & ASCII.LF & ASCII.LF
       & "When the files are written, finish with a short report in these lines:"
       & ASCII.LF & ASCII.LF
       & "status: done" & ASCII.LF
       & "summary: one line on what you did" & ASCII.LF
       & "changed_files: the files you wrote" & ASCII.LF & ASCII.LF
       & "If you could not do it, the status is failed and the summary says"
       & " why. Two other statuses are for rare cases: issue, for a problem"
       & " found outside the task, and blocked, for a decision only a person"
       & " can make. Further work you found goes in proposed_tasks:, one a"
       & " line, each as TITLE; kind=K; component=C where it is another's."
       & " If the task is too large to do as one, say blocked and name the"
       & " parts it should be split into under parts:, one a line. A decision"
       & " or specification you would propose goes under decisions: or"
       & " specifications:, a task this one should wait for under waits_for:,"
       & " and verify: yes asks for your work to be checked whatever the"
       & " status." & ASCII.LF);

   --  The fields of a tab-separated line.
   function Fields_Of (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.HT then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Fields_Of;

   --  The parts of a line between separators.
   function Split_On (Text : String; Separator : Character) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = Separator then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split_On;

   --  A list written with commas, as one written a line an item.
   function Replaced (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C = ',' then
            C := ASCII.LF;
         end if;
      end loop;
      return Result;
   end Replaced;

   --  Whether a run was stopped by its time running out.
   function Out_Of_Time (Ran : E.Error_Info) return Boolean is
      Found : Boolean;
      Given : E.Parameter;
   begin
      if not E."=" (Ran.Code, E.Framework_Limit_Exceeded) then
         return False;
      end if;
      E.Find_Parameter (Ran, "name", Found, Given);
      return Found and then Model_Runner.Text.To_String (Given.Text_Value) = "time";
   end Out_Of_Time;

   --  Whether a run was stopped by whoever started it.
   function Interrupted (Ran : E.Error_Info) return Boolean
   is (E."=" (Ran.Code, E.Generation_Cancelled));

   --  Why a task could start, as it stood when it did: what it waited for
   --  and what state that was in, that nothing held it or its component,
   --  and what it was to be checked by -- kept, because afterwards the
   --  state that said so is gone.
   function Admission (Item : Stores.Store; Task_Id : String; Isolated : Boolean) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
      Text    : Unbounded_String;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      Append (Text, "it was " & Tasks.State_Of (Item, Task_Id) & " and ready");
      declare
         Waits : constant Name_Lists.Vector := Lines_Of (Records.Get (Defined, "depends_on"));
      begin
         if Waits.Is_Empty then
            Append (Text, "; it waited for nothing");
         else
            for Other of Waits loop
               Append (Text, "; " & Other & " was " & Tasks.State_Of (Item, Other));
            end loop;
         end if;
      end;
      Append (Text, "; no agent held it");
      Append (Text, (if Isolated then "; it was to write in a workspace of its own"
                     elsif Records.Get (Defined, "component") = "" then "; it named no component"
                     else "; no agent was writing " & Records.Get (Defined, "component")));
      Append (Text, "; kind " & Records.Get (Defined, "kind")
              & ", definition revision" & Natural'Image (Records.Revision (Defined))
              & ", checked by " & Verification.Profile_Of (Item, Task_Id));
      return To_String (Text);
   end Admission;

   --  A task's component.
   function Component_Of (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      return Records.Get (Defined, "component");
   end Component_Of;

   --  A task's kind.
   function Kind_Of (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      return Records.Get (Defined, "kind");
   end Kind_Of;

   --  A number a policy gives, or a default.
   function Number_Of (Text : String; Default : Natural) return Natural
   is (if Text'Length in 1 .. 9 and then (for all C of Text => C in '0' .. '9')
       then Natural'Value (Text) else Default);

   --  A scalar of the configuration.
   function Scalar (Item : Stores.Store; Name : String) return String is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      return Records.Get (Config, "scalar." & Name);
   end Scalar;

   --  A setting of the configuration's work.
   function Work_Setting (Item : Stores.Store; Name : String) return String is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      return Records.Get (Config, "scalar.work." & Name);
   end Work_Setting;

   --  How long an agent holds its task before it must have finished.
   function Lease_Seconds (Item : Stores.Store) return Positive is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      declare
         Text : constant String := Records.Get (Config, "scalar.work.lease");
      begin
         return (if Text'Length in 1 .. 7 and then (for all C of Text => C in '0' .. '9')
                   and then Natural'Value (Text) > 0
                 then Natural'Value (Text) else 3600);
      end;
   end Lease_Seconds;

   --  Set a field of a task's runtime record, in the transaction.
   procedure Annotate
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Field   : String;
      Value   : String)
   is
      Held   : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Tasks_Area, Task_Id & ".state", Held, Staged);
      if not Staged then
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Held, Records.Revision (Held) + 1);
      end if;
      Records.Set (Held, Field, Value);
      Stores.Put (Change, Tasks_Area, Task_Id & ".state", Held);
   end Annotate;

   --  Set an agent record's state, in the transaction.
   procedure Agent_State
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Agent  : String;
      State  : String;
      Note   : String := "")
   is
      Held   : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Runtime_Area, "agent." & Agent, Held, Staged);
      if not Staged then
         Stores.Read (Item, Runtime_Area, "agent." & Agent, Held, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Held, Records.Revision (Held) + 1);
      end if;
      Records.Set (Held, "state", State);
      if State /= "running" then
         Records.Set (Held, "ended_at", Timestamp);
      end if;
      if Note /= "" then
         Records.Set (Held, "note", Note);
      end if;
      Stores.Put (Change, Runtime_Area, "agent." & Agent, Held);
   end Agent_State;

   --  The agent holding a running task, from its lease.
   function Holder_Record (Item : Stores.Store; Task_Id : String) return String is
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Runtime_Area, "lease." & Lease_Of (Task_Id), Held, Status);
      return (if E.Is_Ok (Status) then Records.Get (Held, "owner") else "");
   end Holder_Record;

   --  The execution generation a task is in.
   function Generation_Of (Item : Stores.Store; Task_Id : String) return String is
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Status);
      return (if E.Is_Ok (Status) then Records.Get (Held, "generation") else "");
   end Generation_Of;

   --  Every child of an agent still going is cancelled with it: a child
   --  outlives nothing it was made for.
   procedure Stop_Children
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Agent  : String)
   is
      Stopped : Name_Lists.Vector;
      Status  : E.Error_Info;
   begin
      for Child of Agents.Children (Item, Agent) loop
         Agents.Cancel (Item, Change, Child, Stopped, Status);
      end loop;
   end Stop_Children;

   -------------
   -- Recover --
   -------------

   procedure Recover
     (Item      : in out Stores.Store;
      Recovered : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
   begin
      Recovered.Clear;
      Status := E.Success;
      for Id of Tasks.List (Item, "running") loop
         if Leases.Holder (Item, Lease_Of (Id)) = "" then
            declare
               Agent : constant String := Holder_Record (Item, Id);
            begin
               Tasks.Move
                 (Item, Change, Id, "blocked",
                  "its agent " & (if Agent = "" then "" else Agent & " ")
                  & "stopped without finishing", Status => Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               if Agent /= "" then
                  Stop_Children (Item, Change, Agent);
                  Agent_State (Item, Change, Agent, "failed", "it stopped without finishing");
               end if;
               Leases.Release (Item, Change, Lease_Of (Id), Agent, Status);
               if E.Is_Ok (Status) and then Component_Of (Item, Id) /= "" then
                  Leases.Release
                    (Item, Change, Tasks.Component_Lease (Component_Of (Item, Id)), Agent, Status);
               end if;

               --  Blocked, unless the project says otherwise.
               if E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "failed" then
                  Tasks.Move (Item, Change, Id, "failed", "its agent stopped without finishing",
                              Status => Status);
               elsif E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "accepted" then
                  Tasks.Move (Item, Change, Id, "accepted", "", Status => Status);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;
               Recovered.Append (Id);
            end;
         end if;
      end loop;
      Stores.Commit (Item, Change, Status);
   end Recover;

   ------------------------
   -- Recover_On_Opening --
   ------------------------

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

      --  3: tasks left running with no one running them.
      Recover (Item, Put_Back, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for Id of Put_Back loop
         Said.Append (Id & " was running with no one running it; it is "
                      & Tasks.State_Of (Item, Id) & " now");
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
         Became : Name_Lists.Vector;
         Moved  : Name_Lists.Vector;
      begin
         Tasks.Recompute_Readiness (Item, Change, Became, Status);
         if E.Is_Ok (Status) then
            Verification.Reevaluate_Requirements (Item, Change, Moved, Status);
         end if;
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         for Id of Moved loop
            Said.Append (Id & " changed its verification");
         end loop;
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
            Removed      => Removed);
         if Removed > 0 then
            Stores.Commit (Item, Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Said.Append ("let go of" & Natural'Image (Removed)
                         & " raw logs and kept contexts past their retention");
         end if;
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

      --  8: what is still wrong, for someone to settle.
      declare
         Wrong : constant Consistency.Finding_List := Consistency.Check (Item);
      begin
         if Consistency.Length (Wrong) > 0 then
            Said.Append
              ("what does not hold together in the state:"
               & Natural'Image (Consistency.Length (Wrong)) & ", first "
               & To_String (Consistency.Element (Wrong, 1).Subject) & ": "
               & To_String (Consistency.Element (Wrong, 1).Detail)
               & "; /check consistency lists it all");
         end if;
      end;
   end Recover_On_Opening;

   --  Every file's fingerprint, by path.
   function Snapshot
     (Project : String;
      Within  : Repository.Roots) return Configurations.Value_Maps.Map
   is
      Found  : constant Repository.Graph := Repository.Scan (Project, Within);
      Result : Configurations.Value_Maps.Map;
   begin
      for Index in 1 .. Repository.File_Count (Found) loop
         Result.Include
           (To_String (Repository.File_At (Found, Index).Path),
            To_String (Repository.File_At (Found, Index).Fingerprint));
      end loop;
      return Result;
   end Snapshot;

   --  What a child answers with.
   Child_Claim : constant Invocations.Contract :=
     Invocations.Contract_Of
       ("child_result",
        "status = done|failed" & ASCII.LF & "summary" & ASCII.LF
        & "findings?" & ASCII.LF & "changed_files?");

   -----------
   -- Audit --
   -----------

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

      --  The fields of a record whose names start with a prefix, as
      --  NAME VALUE, joined.
      function Fields_With (Value : Records.Item; Prefix : String) return String is
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
                          & Field (Field'First + Prefix'Length .. Field'Last) & " "
                          & Records.Get (Value, Field));
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
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Status);
      if Invocation /= "" then
         Stores.Read (Item, Invocations_Area, Invocation, Call, Status);
         Stores.Read (Item, Invocations_Area, "manifest." & Records.Get (Call, "context_manifest"),
                      Plan, Status);
      end if;
      if Records.Get (State, "current_verification") /= "" then
         Stores.Read (Item, Verification_Area, Records.Get (State, "current_verification"),
                      Proof, Status);
      end if;

      Say ("requirement revisions", Fields_With (Plan, "applies.REQ"));
      Say ("task definition revision", Natural'Image (Records.Revision (Defined)));
      Say ("why it could start", Records.Get (State, "admission"));
      Say ("decisions", Fields_With (Plan, "applies.DEC"));
      Say ("context", Records.Get (Call, "context_manifest")
           & (if Records.Get (Plan, "rendered") = "" then ""
              else ", rendered as " & Records.Get (Plan, "rendered")));
      Say ("model", Records.Get (Call, "model_profile")
           & (if Invocation = "" then "" else ", in " & Invocation));
      Say ("files changed", Records.Get (State, "changed_files"));
      Say ("workspace", Records.Get (State, "current_workspace"));
      Say ("verification", Records.Get (State, "current_verification")
           & (if Records.Get (Proof, "profile") = "" then ""
              else ", profile " & Records.Get (Proof, "profile")
                   & (if Records.Get (Proof, "passed") = "true" then ", passed" else ", failed")));
      Say ("tool versions", Fields_With (Proof, "tool."));
      Say ("completion", (if Tasks.State_Of (Item, Task_Id) = "complete"
                          then "its gates passed on " & Records.Get (State, "current_verification")
                          else "it is " & Tasks.State_Of (Item, Task_Id)));
      Say ("integration", (if Records.Get (State, "current_workspace") = ""
                           then "none: it wrote in the project itself"
                           else "the workspace " & Records.Get (State, "current_workspace")));
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

   ------------------------
   -- Child_Instructions --
   ------------------------

   function Child_Instructions return String
   is ("## What to do" & ASCII.LF
       & "Do what you are asked, with the tools you have, and nothing more."
       & " Paths are relative to the project. Only a write_file call changes a"
       & " file, and only if you were asked to change one." & ASCII.LF & ASCII.LF
       & "When you are done, report in these lines:" & ASCII.LF & ASCII.LF
       & "status: done" & ASCII.LF
       & "summary: one line on what you found or did" & ASCII.LF
       & "findings: what you were asked for, in as many lines as it needs"
       & ASCII.LF & ASCII.LF
       & "If you could not do it, the status is failed and the summary says"
       & " why. Add changed_files: for any file you wrote." & ASCII.LF);

   -------------
   -- Current --
   -------------

   function Current (Host : Child_Host) return String
   is (if Host.Open.Is_Empty then "" else Host.Open.Last_Element);

   ---------
   -- May --
   ---------

   function May
     (Host : Child_Host;
      What : Permissions.Capability;
      Path : String := "") return Boolean
   is
      Held   : Agents.Agent;
      Status : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status) and then Permissions.Allows (Held.Allowed, What, Path);
   end May;

   ---------------
   -- Time_Left --
   ---------------

   function Time_Left (Host : Child_Host) return Duration is
      use type Ada.Calendar.Time;
   begin
      if not Host.Bounded then
         return 0.0;
      end if;
      return Duration'Max (1.0, Host.Deadline - Ada.Calendar.Clock);
   end Time_Left;

   -----------------
   -- Tool_Budget --
   -----------------

   function Tool_Budget (Host : Child_Host) return Natural is (Host.Max_Calls);

   -----------
   -- Steps --
   -----------

   function Steps (Host : Child_Host) return Positive
   is (Positive'Max (1, Host.Max_Steps));

   ------------------
   -- Task_Profile --
   ------------------

   function Task_Profile (Host : Child_Host) return String
   is (Verification.Profile_Of (Host.Item.all, To_String (Host.Task_Id)));

   ---------------
   -- May_Check --
   ---------------

   function May_Check (Host : Child_Host; Profile : String) return Boolean is
      Held   : Agents.Agent;
      Status : E.Error_Info;
      Named  : constant String := Ada.Characters.Handling.To_Lower (Profile);
      Needed : constant Permissions.Capability :=
        (if Ada.Strings.Fixed.Index (Named, "build") > 0 then Permissions.Run_Build
         elsif Ada.Strings.Fixed.Index (Named, "analysis") > 0
           or else Ada.Strings.Fixed.Index (Named, "lint") > 0
         then Permissions.Run_Static_Analysis
         else Permissions.Run_Tests);
   begin
      if Host.Apart or else Profile = "" then
         return False;
      end if;
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status)
        and then Permissions.Allows_Profile (Held.Allowed, Needed, Profile);
   end May_Check;

   ----------------
   -- Run_Checks --
   ----------------

   procedure Run_Checks
     (Host    : in out Child_Host;
      Profile : String;
      Report  : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Change   : Stores.Transaction;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Value    : Records.Item;
      Read     : E.Error_Info;

      --  The last lines of a text, enough to see an error by.
      function Tail (Text : String; Count : Positive) return String is
         Seen : Natural := 0;
      begin
         for Index in reverse Text'Range loop
            if Text (Index) = ASCII.LF and then Index < Text'Last then
               Seen := Seen + 1;
               if Seen = Count then
                  return Text (Index + 1 .. Text'Last);
               end if;
            end if;
         end loop;
         return Text;
      end Tail;
   begin
      Report := Null_Unbounded_String;
      if not May_Check (Host, Profile) then
         Status := E.Make (E.Framework_Permission_Denied);
         E.Add_Text (Status, "name", Current (Host));
         E.Add_Text (Status, "detail", "it may not run the profile " & Profile);
         return;
      end if;
      declare
         Project : constant String :=
           Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
         Before  : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
      begin
         Verification.Run_Profile
           (Host.Item.all, Change, Profile, "", Evidence, Passed, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;

         --  A build writes files of its own; they are the checks', not the
         --  agent's.
         declare
            After : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
         begin
            for Position in After.Iterate loop
               declare
                  Path : constant String := Configurations.Value_Maps.Key (Position);
                  Now  : constant String := Configurations.Value_Maps.Element (Position);
               begin
                  if not Before.Contains (Path) or else Before (Path) /= Now then
                     Host.Written.Append (Path & ASCII.HT & Now);
                  end if;
               end;
            end loop;
         end;
      end;

      Report := To_Unbounded_String
        (Profile & (if Passed then " passed" else " failed") & ", "
         & To_String (Evidence));
      Stores.Read (Host.Item.all, Verification_Area, To_String (Evidence), Value, Read);
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Parts : constant Name_Lists.Vector :=
              (if Field'Length > 6 and then Field (Field'First .. Field'First + 5) = "check."
               then Fields_Of (Records.Get (Value, Field)) else Name_Lists.Empty_Vector);
         begin
            if Natural (Parts.Length) >= 7 then
               Append (Report, ASCII.LF & Parts (1) & ": " & Parts (5));
               if Parts (5) /= "passed" and then Parts (6) = "required" then
                  declare
                     Log  : Results.Result;
                     Held : E.Error_Info;
                  begin
                     Results.Read (Host.Item.all, Parts (7), Log, Held);
                     if E.Is_Ok (Held) then
                        Append (Report, ASCII.LF & Tail (To_String (Log.Payload), 30));
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end Run_Checks;

   -----------
   -- Spend --
   -----------

   procedure Spend
     (Host          : in out Child_Host;
      Tokens        : Natural;
      Prompt_Tokens : Natural := 0)
   is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      --  What it used is recorded; going over is the loop's to stop, and the
      --  record says so.
      Agents.Charge (Host.Item.all, Change, Current (Host), Tokens, Status);
      Stores.Commit (Host.Item.all, Change, Status);
      if Natural (Host.Open.Length) = 1 then
         Host.Root_Out := Host.Root_Out + Tokens;
         Host.Root_Prompt := Natural'Max (Host.Root_Prompt, Prompt_Tokens);
      end if;
   end Spend;

   ---------------
   -- Note_Call --
   ---------------

   procedure Note_Call
     (Host      : in out Child_Host;
      Named     : String;
      Arguments : String;
      Answer    : String)
   is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      if not Host.Calls.Is_Empty then
         Invocations.Note_Call
           (Host.Item.all, Change, Host.Calls.Last_Element, Named, Arguments, Answer, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
      end if;
   end Note_Call;

   ----------------
   -- Open_Child --
   ----------------

   procedure Open_Child
     (Host     : in out Child_Host;
      Role     : String;
      Need     : String;
      Brief    : String;
      Retry_Of : String;
      Child_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Context  : out Ada.Strings.Unbounded.Unbounded_String;
      Budget   : out Natural;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Change  : Stores.Transaction;
      Parent  : constant String := Current (Host);
      Owner   : Agents.Agent;
      Read    : E.Error_Info := E.Success;
      Named   : constant String := (if Trim (Role) = "" then "helper" else Trim (Role));
      Obliged : constant Agents.Obligation :=
        (if Need = "optional" then Agents.Optional
         elsif Need = "advisory" then Agents.Advisory
         else Agents.Required);
   begin
      Child_Id := Null_Unbounded_String;
      Context := Null_Unbounded_String;
      Budget := 0;

      --  Half of what its parent has left: a child that could spend all of
      --  it would leave its parent nothing to finish with.
      Agents.Read (Host.Item.all, Parent, Owner, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Budget := (if Owner.Used >= Owner.Budget then 0 else (Owner.Budget - Owner.Used) / 2);
      if Budget = 0 then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", Parent);
         E.Add_Text (Status, "detail", "it has no tokens left to give a child");
         return;
      end if;

      Agents.Spawn_Child
        (Host.Item.all, Change, Parent, Named, Obliged, Permissions.Unrestricted, Budget,
         Child_Id, Status, Retry_Of => Retry_Of);
      if E.Is_Ok (Status) then
         Stores.Commit (Host.Item.all, Change, Status);
      end if;
      if E.Is_Error (Status) then
         Child_Id := Null_Unbounded_String;
         Budget := 0;
         return;
      end if;
      Host.Open.Append (To_String (Child_Id));
      Host.Opened.Append (Ada.Calendar.Clock);

      --  A context of its own -- the task it helps with and what it is
      --  asked, nothing of the conversation it was asked from -- with its
      --  manifest kept and its invocation recorded before it is made.
      declare
         Made   : Framework.Context.Built;
         Called : Unbounded_String;
      begin
         Framework.Context.Build_Brief
           (Host.Item.all, To_String (Host.Task_Id), Host.Model,
            "You are helping an agent with one part of its task, as its " & Named
            & ". You cannot see its conversation, and it will see only your report.",
            Brief, Made, Read);
         if E.Is_Ok (Read) then
            Framework.Context.Keep (Host.Item.all, Change, Made, Read);
         end if;
         if E.Is_Ok (Read) then
            Invocations.Start
              (Host.Item.all, Change, To_String (Child_Id), To_String (Host.Task_Id),
               Generation_Of (Host.Item.all, To_String (Host.Task_Id)),
               To_String (Host.Model.Id), Framework.Context.Manifest_Id (Made), "files",
               Child_Claim, Called, Read);
         end if;
         if E.Is_Ok (Read) then
            Stores.Commit (Host.Item.all, Change, Read);
         end if;
         Host.Calls.Append (To_String (Called));
         Context := To_Unbounded_String
           (Framework.Context.Rendered (Made) & Child_Instructions);
         if E.Is_Error (Read) then
            Status := Read;
         end if;
      end;
   end Open_Child;

   -----------------
   -- Close_Child --
   -----------------

   procedure Close_Child
     (Host   : in out Child_Host;
      Answer : String;
      Tokens : Natural;
      Ran    : Model_Runner.Errors.Error_Info;
      Told   : out Ada.Strings.Unbounded.Unbounded_String;
      Retry  : out Boolean;
      Prompt_Tokens : Natural := 0)
   is
      Change  : Stores.Transaction;
      Status  : E.Error_Info;
      Charged : E.Error_Info;
      Held    : E.Error_Info;
      Said    : Invocations.Claims;
      Child   : Agents.Agent;
      Good    : Boolean := False;
      Why     : Unbounded_String;
      Kept    : Results.Result;

      --  How many times the child it stands for has been run before it.
      function Runs_Before (Id : String) return Natural is
         Held_Agent : Agents.Agent;
         Read       : E.Error_Info;
      begin
         Agents.Read (Host.Item.all, Id, Held_Agent, Read);
         return (if E.Is_Error (Read) or else Held_Agent.Retry_Of = Null_Unbounded_String
                 then 0 else 1 + Runs_Before (To_String (Held_Agent.Retry_Of)));
      end Runs_Before;

      Retries : constant Natural :=
        (declare
           Text : constant String := Scalar (Host.Item.all, "agents.child_retries");
         begin
           (if Text'Length in 1 .. 3 and then (for all C of Text => C in '0' .. '9')
            then Natural'Value (Text) else 1));
   begin
      Told := Null_Unbounded_String;
      Retry := False;
      if Natural (Host.Open.Length) < 2 then
         Told := To_Unbounded_String ("error: no child is open");
         return;
      end if;

      declare
         Id : constant String := Host.Open.Last_Element;
      begin
         Agents.Read (Host.Item.all, Id, Child, Status);
         Agents.Charge (Host.Item.all, Change, Id, Tokens, Charged);

         if E.Is_Error (Ran) then
            Why := To_Unbounded_String ("it could not be run: " & E.Error_Code'Image (Ran.Code));
         else
            Invocations.Hold (Child_Claim, Answer, Said, Held);
            if E.Is_Error (Held) then
               Why := To_Unbounded_String ("its answer did not keep to the child result contract");
            elsif E.Is_Error (Charged) then
               Why := To_Unbounded_String ("it went over its budget");
            else
               Good := Invocations.Claim (Said, "status") = "done";
               Why := To_Unbounded_String (Invocations.Claim (Said, "summary"));
            end if;
         end if;

         --  Its result is kept, whichever way it went; the parent is told
         --  of it, not of how it was reached.
         Kept :=
           (Kind       => Results.Child_Result,
            Producer   => To_Unbounded_String (Id),
            Summary    => Why,
            Payload    => To_Unbounded_String
              (if E.Is_Ok (Held) and then E.Is_Ok (Ran)
               then Invocations.Claim (Said, "findings")
                    & (if Invocations.Claim (Said, "changed_files") = "" then ""
                       else ASCII.LF & "changed_files: "
                            & Invocations.Claim (Said, "changed_files"))
               else Answer),
            Provenance => Child.Parent,
            others     => <>);
         Results.Add (Host.Item.all, Change, Kept, Status);
         if E.Is_Ok (Status) and then Interrupted (Ran) then
            --  Stopped by whoever started the work: cancelled, with what it
            --  made, and not run again.
            declare
               Stopped : Name_Lists.Vector;
            begin
               Agents.Cancel (Host.Item.all, Change, Id, Stopped, Status);
            end;
         elsif E.Is_Ok (Status) then
            Agents.Finish
              (Host.Item.all, Change, Id, Good, To_String (Kept.Id), To_String (Why), Status);
         end if;
         --  Its invocation ended, with what it used.
         if E.Is_Ok (Status) and then Host.Calls.Last_Element /= "" then
            Invocations.Finish
              (Host.Item.all, Change, Host.Calls.Last_Element,
               (if Interrupted (Ran) then Invocations.Cancelled
                elsif E.Is_Ok (Ran) then Invocations.Completed
                else Invocations.Failed),
               (Prompt_Tokens => Prompt_Tokens,
                Output_Tokens => Tokens,
                Seconds       =>
                  Natural (Duration'Max
                    (0.0, Ada.Calendar."-" (Ada.Calendar.Clock, Host.Opened.Last_Element)))),
               To_String (Kept.Id),
               (if E.Is_Ok (Ran) then "" else E.Error_Code'Image (Ran.Code)), Status);
         end if;
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         Host.Open.Delete_Last;
         Host.Calls.Delete_Last;
         Host.Opened.Delete_Last;

         Retry := not Good and then not Interrupted (Ran) and then not Out_Of_Time (Ran)
           and then Agents."=" (Child.Need, Agents.Required)
           and then Runs_Before (Id) < Retries;
         Told := To_Unbounded_String
           (Id & " (" & Ada.Characters.Handling.To_Lower (Agents.Obligation'Image (Child.Need))
            & ") " & (if Good then "done" else "failed")
            & (if Kept.Id = Null_Unbounded_String then "" else ", " & To_String (Kept.Id))
            & ": " & To_String (Why)
            & (if Good and then Invocations.Claim (Said, "findings") /= ""
               then ASCII.LF & Invocations.Claim (Said, "findings") else "")
            & (if Retry then ASCII.LF & "It is run once more." else ""));
      end;
   end Close_Child;

   --  Children still open when their parent stopped: each is recorded
   --  failed, so none of them goes missing.
   procedure Abandon (Host : in out Child_Host) is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      while Natural (Host.Open.Length) > 1 loop
         Agents.Finish
           (Host.Item.all, Change, Host.Open.Last_Element, False, "",
            "its parent stopped before it answered", Status);
         if Host.Calls.Last_Element /= "" then
            Invocations.Finish
              (Host.Item.all, Change, Host.Calls.Last_Element, Invocations.Failed,
               (others => 0), "", "its parent stopped before it answered", Status);
         end if;
         Host.Open.Delete_Last;
         Host.Calls.Delete_Last;
         Host.Opened.Delete_Last;
      end loop;
      Stores.Commit (Host.Item.all, Change, Status);
   end Abandon;

   -------------
   -- Execute --
   -------------

   procedure Execute
     (Item    : aliased in out Stores.Store;
      Task_Id : String;
      Runner  : Agent_Runner'Class;
      Model   : Context.Model_Profile;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Change  : Stores.Transaction;
      Project : constant String :=
        Ada.Directories.Containing_Directory (Stores.Root (Item));
      Built   : Context.Built;
      Answer  : Unbounded_String;
      Ran     : E.Error_Info;
      Said    : Invocations.Claims;
      Held    : E.Error_Info;

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
      procedure Conclude (Next, Reason, Agent_End : String) is
      begin
         if Next /= "" then
            Tasks.Move (Item, Change, Task_Id, Next, Reason, Status => Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
         Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
         Result.Reason := To_Unbounded_String (Reason);
         Agent_State (Item, Change, To_String (Result.Agent_Id), Agent_End, Reason);
         Leases.Release
           (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Status);
         if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= ""
         then
            Leases.Release
              (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
               To_String (Result.Agent_Id), Status);
         end if;
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
      end Conclude;
   begin
      Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);

      declare
         Now : constant Tasks.Readiness := Tasks.Ready (Item, Task_Id);
      begin
         if not Now.Ready then
            Status := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Status, "name", Task_Id);
            E.Add_Text
              (Status, "detail",
               (if Now.Reasons.Is_Empty then "" else Now.Reasons.First_Element));
            return;
         end if;
      end;

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
      Leases.Acquire
        (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id),
         Lease_Seconds (Item), Status);

      --  Writing in the project itself, it holds its component too, so no
      --  other agent writes the same component meanwhile.
      if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= "" then
         Leases.Acquire
           (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
            To_String (Result.Agent_Id), Lease_Seconds (Item), Status);
      end if;
      if E.Is_Ok (Status) then
         Tasks.Move (Item, Change, Task_Id, "running", "", Status => Status);
      end if;
      if E.Is_Ok (Status) then
         Annotate (Item, Change, Task_Id, "admission", Admission (Item, Task_Id, Isolated));
         Annotate (Item, Change, Task_Id, "active_agent", To_String (Result.Agent_Id));
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  What it is told, and the call, recorded before it is made.
      Context.Build (Item, Task_Id, Model, Built, Held);
      if E.Is_Error (Held) then
         Conclude ("blocked", "its context cannot be built: "
                   & E.Error_Code'Image (Held.Code), "failed");
         return;
      end if;
      Result.Manifest_Id := To_Unbounded_String (Context.Manifest_Id (Built));
      Context.Keep (Item, Change, Built, Status);
      if E.Is_Ok (Status) then
         Invocations.Start
           (Item, Change, To_String (Result.Agent_Id), Task_Id,
            Generation_Of (Item, Task_Id), To_String (Model.Id),
            To_String (Result.Manifest_Id), "files", Invocations.Work_Claim,
            Result.Invocation_Id, Status);
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
            Made : Workspaces.Workspace;
         begin
            Workspaces.Create
              (Item, Change, Task_Id, To_String (Result.Agent_Id),
               Generation_Of (Item, Task_Id), Work_Setting (Item, "backend") /= "copy",
               Made, Held);
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
         if Files.Make_Directory (Scratch) then
            Files.Write_Text
              (Prompt, Context.Rendered (Built) & Instructions, Status);

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
               Seconds : constant Natural := Number_Of
                 ((if Tasks.Kind_Policy (Item, Kind, "max_seconds") /= ""
                   then Tasks.Kind_Policy (Item, Kind, "max_seconds")
                   else Scalar (Item, "agents.max_seconds")),
                  Lease_Seconds (Item));
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
            if Runner in Parenting_Runner'Class then
               Parenting_Runner'Class (Runner).Run_Parenting
                 (Prompt, To_String (Place), Host, Answer, Ran);
            else
               Runner.Run (Prompt, To_String (Place), Answer, Ran);
            end if;
            Abandon (Host);
            By_Checks := Host.Written;
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
      end;

      --  The answer, kept, and the call ended.
      declare
         Kept : Results.Result :=
           (Kind       => Results.Implementation,
            Producer   => Result.Agent_Id,
            Summary    => To_Unbounded_String ("answer to " & To_String (Result.Invocation_Id)),
            Payload    => Answer,
            Provenance => Result.Invocation_Id,
            others     => <>);
         Files_Text : Unbounded_String;
      begin
         Results.Add (Item, Change, Kept, Status);
         Invocations.Finish
           (Item, Change, To_String (Result.Invocation_Id),
            (if E.Is_Ok (Ran) then Invocations.Completed
             elsif Interrupted (Ran) then Invocations.Cancelled
             else Invocations.Failed),
            Used,
            To_String (Kept.Id),
            (if E.Is_Ok (Ran) then "" else E.Error_Code'Image (Ran.Code)), Status);
         Annotate (Item, Change, Task_Id, "last_result", To_String (Kept.Id));
         for Path of Result.Changed_Files loop
            Append (Files_Text, (if Files_Text = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Path);
         end loop;
         Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
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

      --  Stopped by whoever started it: the agent and what it made are
      --  cancelled, and the task is put aside, not failed -- nothing is
      --  known against it -- until it is accepted again.
      if Interrupted (Ran) then
         Stop_Children (Item, Change, To_String (Result.Agent_Id));
         Conclude ("blocked", "its work was cancelled", "cancelled");
         return;
      elsif Out_Of_Time (Ran) then
         --  Out of time is not wrong work: the task is set aside, not
         --  failed, with what its agents made stopped.
         Stop_Children (Item, Change, To_String (Result.Agent_Id));
         Conclude ("blocked", "its work ran out of time", "failed");
         return;
      elsif E.Is_Error (Ran) then
         Conclude ("failed", "the agent could not be run: " & E.Error_Code'Image (Ran.Code),
                   "failed");
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
         if Denied /= Null_Unbounded_String then
            if Isolated then
               Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Held);
            end if;
            Conclude ("failed", "it changed files it may not write: " & To_String (Denied),
                      "failed");
            return;
         end if;
      end;

      Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Held);
      if E.Is_Error (Held) then
         Conclude ("failed", "its answer did not keep to the work contract", "failed");
         return;
      end if;
      Result.Claimed := To_Unbounded_String (Invocations.Claim (Said, "status"));
      Result.Summary := To_Unbounded_String (Invocations.Claim (Said, "summary"));

      --  A change it says it made and did not is a claim the files refute:
      --  whatever else it did, its answer cannot be taken.
      if To_String (Result.Claimed) = "done" then
         declare
            Missing : Unbounded_String;
         begin
            for Line of Lines_Of (Replaced (Invocations.Claim (Said, "changed_files"))) loop
               declare
                  Named : constant String := Trim (Line);
                  Path  : constant String :=
                    (if Named'Length > 2 and then Named (Named'First .. Named'First + 1) = "./"
                     then Named (Named'First + 2 .. Named'Last) else Named);
               begin
                  if Path not in "" | "-" | "none" and then not Result.Changed_Files.Contains (Path)
                  then
                     Append (Missing, (if Missing = Null_Unbounded_String then "" else ", ") & Path);
                  end if;
               end;
            end loop;
            if Missing /= Null_Unbounded_String then
               Conclude ("failed", "it says it changed " & To_String (Missing)
                         & ", which did not change", "failed");
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
                  Tasks.Create
                    (Item, Change, Fields, To_String (Result.Agent_Id), "agent", Made, Held);
                  if E.Is_Ok (Held) then
                     Result.Proposed.Append (To_String (Made));
                  else
                     Append (Kept_Back, ASCII.LF & "proposed: " & Title);
                  end if;
               else
                  Append (Kept_Back, ASCII.LF & "proposed: " & Title);
               end if;
            end;
         end loop;

         --  The parts it would split its task into: proposal data, not a
         --  split -- candidate children, which a person accepts or not, and
         --  the task itself is left as the answer leaves it.
         for Line of Parts loop
            declare
               Title  : constant String := Trim (Line);
               Fields : Tasks.Field_Map;
               Made   : Unbounded_String;
            begin
               if Title = "" or else Title = "-" then
                  null;
               elsif May_Propose then
                  Fields.Include ("title", Title);
                  Fields.Include ("kind", Records.Get (Defined, "kind"));
                  Fields.Include ("parent", Task_Id);
                  if Records.Get (Defined, "component") /= "" then
                     Fields.Include ("component", Records.Get (Defined, "component"));
                  end if;
                  Tasks.Create
                    (Item, Change, Fields, To_String (Result.Agent_Id),
                     "agent decomposition of " & Task_Id, Made, Held);
                  if E.Is_Ok (Held) then
                     Result.Proposed.Append (To_String (Made));
                  else
                     Append (Kept_Back, ASCII.LF & "part: " & Title);
                  end if;
               else
                  Append (Kept_Back, ASCII.LF & "part: " & Title);
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
                           Append (Kept_Back, ASCII.LF & "proposed: " & Text);
                        end if;
                     else
                        Append (Kept_Back, ASCII.LF & "proposed: " & Text);
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
            Found : constant String := Invocations.Claim (Said, "issues") & To_String (Kept_Back);
            Issue : Results.Result :=
              (Kind       => Results.Task_Proposal,
               Producer   => Result.Agent_Id,
               Summary    => To_Unbounded_String ("issues found working on " & Task_Id),
               Payload    => To_Unbounded_String (Found),
               Provenance => Result.Invocation_Id,
               others     => <>);
         begin
            if Trim (Found) /= "" then
               Results.Add (Item, Change, Issue, Status);
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

      if To_String (Result.Claimed) in "blocked" | "issue" then
         Conclude ("blocked", To_String (Result.Summary), "completed");
         return;
      elsif To_String (Result.Claimed) = "failed" then
         Conclude ("failed", To_String (Result.Summary), "completed");
         return;
      end if;

      --  Done, it says -- but not while a child it needed is going or
      --  failed.
      declare
         Why : Unbounded_String;
      begin
         if not Agents.May_Complete (Item, To_String (Result.Agent_Id), Why) then
            Conclude ((if Scalar (Item, "agents.on_child_failure") = "fail" then "failed"
                       else "blocked"),
                      To_String (Why), "completed");
            return;
         end if;
      end;

      --  Done, it says. The harness decides.
      Tasks.Move (Item, Change, Task_Id, "verification", "", Status => Status);
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
         if Work_Setting (Item, "integrate") /= "automatic" then
            Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in",
                      "completed");
            return;
         end if;

         --  The harness takes it in for the agent only when the agent may
         --  ask for that.
         declare
            Held_Root : Agents.Agent;
         begin
            Agents.Read (Item, To_String (Result.Agent_Id), Held_Root, Held);
            if E.Is_Error (Held)
              or else not Permissions.Allows (Held_Root.Allowed, Permissions.Request_Integration)
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
                         & E.Error_Code'Image (Held.Code), "completed");
               return;
            end if;
            declare
               Event : Unbounded_String;
            begin
               Events.Emit (Item, Change, Events.Source_Changed, Task_Id,
                            "taken in from " & To_String (Result.Workspace_Id), Event, Status);
            end;
            Stores.Commit (Item, Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
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
            Conclude ("blocked", "its verification could not run: "
                      & E.Error_Code'Image (Held.Code), "completed");
            return;
         end if;
         Annotate (Item, Change, Task_Id, "current_verification",
                   To_String (Result.Evidence_Id));
         Stores.Commit (Item, Change, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         if not Passed then
            Conclude ("failed", To_String (Result.Evidence_Id) & " did not pass",
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
         Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
         if E.Is_Ok (Status) then
            Conclude ("", "", "completed");
         end if;
      end;
   end Execute;

   -------------
   -- Take_In --
   -------------

   procedure Take_In
     (Item    : in out Stores.Store;
      Task_Id : String;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False)
   is
      Change : Stores.Transaction;
      Id     : constant String := Workspaces.Active_For (Item, Task_Id);
      Taken  : Name_Lists.Vector;
      Passed : Boolean := False;
      Held   : E.Error_Info;
   begin
      Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);
      if Id = "" then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "a workspace of " & Task_Id);
         return;
      end if;
      Result.Workspace_Id := To_Unbounded_String (Id);

      Workspaces.Integrate (Item, Change, Id, True, Taken, Status, Semantic_Accepted);
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      Result.Changed_Files := Taken;

      --  The project as it is now is what is verified, as widely as what was
      --  taken in reaches.
      declare
         Chosen : constant Verification.Choice := Verification.Choose (Item, Task_Id, Taken);
      begin
         Result.Scope := Chosen.Scope;
         Result.Scope_Reason := Chosen.Reason;
         Verification.Run_Profile
           (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed, Held,
            Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
      end;
      if E.Is_Ok (Held) then
         Stores.Commit (Item, Change, Status);
      else
         Change := Stores.No_Changes;
      end if;

      if E.Is_Ok (Held) and then Passed then
         Verification.Complete_Task (Item, Change, Task_Id, Held);
         if E.Is_Ok (Held) then
            Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
            if E.Is_Ok (Status) then
               Stores.Commit (Item, Change, Status);
            end if;
         else
            Change := Stores.No_Changes;
         end if;
      end if;

      if E.Is_Error (Held) or else not Passed then
         Result.Reason := To_Unbounded_String
           (if E.Is_Error (Held) then E.Error_Code'Image (Held.Code)
            else To_String (Result.Evidence_Id) & " did not pass");
      end if;
      Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
   end Take_In;

   ------------
   -- Cancel --
   ------------

   procedure Cancel
     (Item    : in out Stores.Store;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
      Agent  : constant String := Holder_Record (Item, Task_Id);
   begin
      Tasks.Move (Item, Change, Task_Id, "cancelled", "", Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  Work written apart for it is not taken in.
      declare
         Open : constant String := Workspaces.Active_For (Item, Task_Id);
      begin
         if Open /= "" then
            Workspaces.Abandon (Item, Change, Open, Status);
         end if;
      end;
      if Agent /= "" then
         Stop_Children (Item, Change, Agent);
         Agent_State (Item, Change, Agent, "cancelled", "the task was cancelled");
         Leases.Release (Item, Change, Lease_Of (Task_Id), Agent, Status);
         if E.Is_Ok (Status) and then Component_Of (Item, Task_Id) /= "" then
            Leases.Release
              (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)), Agent, Status);
         end if;
         if Status.Code = E.Framework_Lease_Held then
            Status := E.Success;
         end if;
      end if;
      Stores.Commit (Item, Change, Status);
   end Cancel;

end Model_Runner.Framework.Work;
