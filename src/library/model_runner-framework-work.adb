with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;

package body Model_Runner.Framework.Work is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   function Lease_Of (Task_Id : String) return String
   is ("task." & Task_Id);

   ------------------
   -- Instructions --
   ------------------

   function Instructions return String
   is ("## Instructions" & ASCII.LF
       & "Do the task above in the project's files, and nothing else." & ASCII.LF
       & "When you have finished, answer with these lines:" & ASCII.LF
       & "status: done, blocked, failed or issue" & ASCII.LF
       & "summary: what you did, or why you could not" & ASCII.LF
       & "changed_files: the files you changed, separated by commas" & ASCII.LF
       & "issues: anything you found that is outside the task" & ASCII.LF
       & "proposed_tasks: further work the project needs, one a line" & ASCII.LF);

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
                  Agent_State (Item, Change, Agent, "failed", "it stopped without finishing");
               end if;
               Leases.Release (Item, Change, Lease_Of (Id), Agent, Status);
               Recovered.Append (Id);
            end;
         end if;
      end loop;
      Stores.Commit (Item, Change, Status);
   end Recover;

   --  Every file's fingerprint, by path.
   function Snapshot (Project : String) return Configurations.Value_Maps.Map is
      Found  : constant Repository.Graph := Repository.Scan (Project);
      Result : Configurations.Value_Maps.Map;
   begin
      for Index in 1 .. Repository.File_Count (Found) loop
         Result.Include
           (To_String (Repository.File_At (Found, Index).Path),
            To_String (Repository.File_At (Found, Index).Fingerprint));
      end loop;
      return Result;
   end Snapshot;

   -------------
   -- Execute --
   -------------

   procedure Execute
     (Item    : in out Stores.Store;
      Task_Id : String;
      Runner  : Agent_Runner'Class;
      Model   : Context.Model_Profile;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Change  : Stores.Transaction;
      Project : constant String :=
        Ada.Directories.Containing_Directory (Stores.Root (Item));
      Number  : Natural;
      Built   : Context.Built;
      Answer  : Unbounded_String;
      Ran     : E.Error_Info;
      Said    : Invocations.Claims;
      Held    : E.Error_Info;

      --  Where the agent writes: the project, or its workspace.
      Isolated : constant Boolean := Work_Setting (Item, "isolation") = "workspace";
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

      --  An agent of its own, holding the task, in a new generation.
      Stores.Allocate_Number (Item, Change, "AG", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Result.Agent_Id := To_Unbounded_String
        ("AG-" & [1 .. Integer'Max (0, 6 - Image (Number)'Length) => '0'] & Image (Number));
      declare
         Agent : Records.Item :=
           Records.Create (Schemas.Agent_Schema, 1, To_String (Result.Agent_Id), 1);
      begin
         Records.Set (Agent, "state", "running");
         Records.Set (Agent, "task", Task_Id);
         Records.Set (Agent, "started_at", Timestamp);
         Stores.Put (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Agent);
      end;
      Leases.Acquire
        (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id),
         Lease_Seconds (Item), Status);
      if E.Is_Ok (Status) then
         Tasks.Move (Item, Change, Task_Id, "running", "", Status => Status);
      end if;
      if E.Is_Ok (Status) then
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
               Conclude ("blocked", "its workspace cannot be made", "failed");
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
         Before  : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place));
      begin
         if Files.Make_Directory (Scratch) then
            Files.Write_Text
              (Prompt, Context.Rendered (Built) & Instructions, Status);
         else
            Files.Write_Failed (Scratch, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;

         Runner.Run (Prompt, To_String (Place), Answer, Ran);
         Files.Discard (Prompt);

         --  What changed is what the files say, not what the answer says.
         declare
            After : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place));
         begin
            for Position in After.Iterate loop
               declare
                  Path : constant String := Configurations.Value_Maps.Key (Position);
               begin
                  if not Before.Contains (Path)
                    or else Before (Path) /= Configurations.Value_Maps.Element (Position)
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
            (if E.Is_Ok (Ran) then Invocations.Completed else Invocations.Failed),
            (Prompt_Tokens => Context.Cost (Built), others => 0),
            To_String (Kept.Id),
            (if E.Is_Ok (Ran) then "" else E.Error_Code'Image (Ran.Code)), Status);
         Annotate (Item, Change, Task_Id, "last_result", To_String (Kept.Id));
         for Path of Result.Changed_Files loop
            Append (Files_Text, (if Files_Text = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Path);
         end loop;
         Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
      end;
      if E.Is_Error (Status) then
         return;
      end if;

      if E.Is_Error (Ran) then
         Conclude ("failed", "the agent could not be run: " & E.Error_Code'Image (Ran.Code),
                   "failed");
         return;
      end if;

      Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Held);
      if E.Is_Error (Held) then
         Conclude ("failed", "its answer did not keep to the work contract", "failed");
         return;
      end if;
      Result.Claimed := To_Unbounded_String (Invocations.Claim (Said, "status"));
      Result.Summary := To_Unbounded_String (Invocations.Claim (Said, "summary"));

      --  Issues and proposed work are kept, not acted on: an agent does
      --  not enlarge its task.
      declare
         Found : constant String :=
           Invocations.Claim (Said, "issues")
           & (if Invocations.Claim (Said, "proposed_tasks") = "" then ""
              else ASCII.LF & "proposed: " & Invocations.Claim (Said, "proposed_tasks"));
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

      if To_String (Result.Claimed) in "blocked" | "issue" then
         Conclude ("blocked", To_String (Result.Summary), "completed");
         return;
      elsif To_String (Result.Claimed) = "failed" then
         Conclude ("failed", To_String (Result.Summary), "completed");
         return;
      end if;

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
            Stores.Commit (Item, Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end;
      end if;

      declare
         Profile : constant String := Verification.Profile_Of (Item, Task_Id);
         Passed  : Boolean := False;
      begin
         if Profile = "" then
            Conclude ("blocked", "no verification profile applies to it", "completed");
            return;
         end if;
         Verification.Run_Profile
           (Item, Change, Profile, Task_Id, Result.Evidence_Id, Passed, Status);
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
            Conclude ("blocked", "its gates did not pass", "completed");
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
      Status  : out Model_Runner.Errors.Error_Info)
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

      Workspaces.Integrate (Item, Change, Id, True, Taken, Status);
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      Result.Changed_Files := Taken;

      --  The project as it is now is what is verified.
      Verification.Run_Profile
        (Item, Change, Verification.Profile_Of (Item, Task_Id), Task_Id,
         Result.Evidence_Id, Passed, Held);
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
         Agent_State (Item, Change, Agent, "cancelled", "the task was cancelled");
         Leases.Release (Item, Change, Lease_Of (Task_Id), Agent, Status);
         if Status.Code = E.Framework_Lease_Held then
            Status := E.Success;
         end if;
      end if;
      Stores.Commit (Item, Change, Status);
   end Cancel;

end Model_Runner.Framework.Work;
