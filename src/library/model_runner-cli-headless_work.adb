with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.CLI.Work;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Work;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Text;

package body Model_Runner.CLI.Headless_Work is

   package E renames Model_Runner.Errors;
   package Cfg renames Model_Runner.Framework.Configurations;
   package Rec renames Model_Runner.Framework.Records;
   package Repo renames Model_Runner.Framework.Repository;
   package Res renames Model_Runner.Framework.Results;
   package S renames Model_Runner.Framework.Stores;
   package Tk renames Model_Runner.Framework.Tasks;
   package W renames Model_Runner.Framework.Work;
   package Ws renames Model_Runner.Framework.Workspaces;
   package T renames Model_Runner.Text;

   Schema_Version : constant := 1;
   Producer_Prefix : constant String := "model_runner.headless-work/1/";
   Maximum_Operation_Results : constant := 100_000;

   type Request is record
      Command                     : Unbounded_String;
      Project                     : Unbounded_String;
      Task_Id                     : Unbounded_String;
      Operation                   : Unbounded_String;
      Expected_Task_Revision      : Unbounded_String;
      Expected_Project_Identity   : Unbounded_String;
      Expected_Source_Fingerprint : Unbounded_String;
      Execution_Policy            : Unbounded_String;
      Authorization               : Unbounded_String;
      Timeout_Seconds              : Natural := 0;
      Noninteractive              : Boolean := False;
      JSON                         : Boolean := False;
   end record;

   type Operation_View is record
      Has_Intent   : Boolean := False;
      Has_Invoking : Boolean := False;
      Has_Outcome  : Boolean := False;
      Intent_Id    : Unbounded_String;
      Outcome_Id   : Unbounded_String;
      Request_Text : Unbounded_String;
      Task_Id      : Unbounded_String;
      Outcome      : Unbounded_String;
   end record;

   function Q (Text : String) return String renames T.JSON_Quoted;

   function Bool (Value : Boolean) return String is (if Value then "true" else "false");

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Frame (Name, Value : String) return String is
     (Name & "=" & Image (Value'Length) & ":" & Value & ASCII.LF);

   function Canonical_Request (Item : Request) return String is
     (Frame ("schema_version", Image (Schema_Version))
      & Frame ("operation_id", To_String (Item.Operation))
      & Frame ("project", Ada.Directories.Full_Name (To_String (Item.Project)))
      & Frame ("task_id", To_String (Item.Task_Id))
      & Frame ("expected_task_revision", To_String (Item.Expected_Task_Revision))
      & Frame ("expected_project_identity", To_String (Item.Expected_Project_Identity))
      & Frame ("expected_source_fingerprint", To_String (Item.Expected_Source_Fingerprint))
      & Frame ("execution_policy", To_String (Item.Execution_Policy))
      & Frame ("timeout_seconds", Image (Item.Timeout_Seconds))
      & Frame ("noninteractive", Bool (Item.Noninteractive)));

   function Error_JSON (Code, Detail : String) return String is
     ("{""schema_version"":" & Image (Schema_Version)
      & ",""kind"":""error"",""error_code"":" & Q (Code)
      & ",""diagnostic"":" & Q (Detail) & "}");

   function Error_JSON (Item : E.Error_Info) return String is
      Detail : Unbounded_String;
   begin
      for Name of Model_Runner.Framework.Name_Lists.Vector'
        (["name", "value", "detail", "path", "task"])
      loop
         if E.Text_Of (Item, Name) /= "" then
            Append (Detail, (if Length (Detail) = 0 then "" else "; ") & E.Text_Of (Item, Name));
         end if;
      end loop;
      return Error_JSON
        ((if E.Diagnostic_Code (Item.Code) = "" then "MR-INTERNAL-HEADLESS" else E.Diagnostic_Code (Item.Code)),
         (if Length (Detail) = 0 then E.Message_Key (Item.Code) else To_String (Detail)));
   end Error_JSON;

   function Valid_Operation_Id (Value : String) return Boolean is
     (Value'Length in 1 .. 128
      and then (for all C of Value => C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.'));

   function Outcome_Succeeded (Value : Operation_View) return Boolean is
     (Ada.Strings.Fixed.Index (To_String (Value.Outcome), """result"":""success""") > 0);

   procedure Parse (Item : out Request; Status : out E.Error_Info) is
      Index : Positive := 3;

      procedure Fail (Name, Value, Detail : String) is
      begin
         Status := E.Make (E.CLI_Invalid_Option_Value);
         E.Add_Text (Status, "name", Name);
         E.Add_Text (Status, "value", Value);
         E.Add_Text (Status, "detail", Detail);
      end Fail;

      procedure Put (Target : in out Unbounded_String; Name : String) is
      begin
         if Length (Target) > 0 then
            Status := E.Make (E.CLI_Repeated_Option);
            E.Add_Text (Status, "name", Name);
         elsif Index = Ada.Command_Line.Argument_Count then
            Status := E.Make (E.CLI_Missing_Option_Value);
            E.Add_Text (Status, "name", Name);
         else
            Index := Index + 1;
            Target := To_Unbounded_String (Ada.Command_Line.Argument (Index));
         end if;
      end Put;
   begin
      Item := (others => <>);
      Status := E.Success;
      if Ada.Command_Line.Argument_Count < 2 then
         Status := E.Make (E.CLI_Missing_Command);
         return;
      end if;
      Item.Command := To_Unbounded_String
        (Ada.Characters.Handling.To_Lower (Ada.Command_Line.Argument (2)));
      while Index <= Ada.Command_Line.Argument_Count and then E.Is_Ok (Status) loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--project" then
               Put (Item.Project, Argument);
            elsif Argument = "--task" then
               Put (Item.Task_Id, Argument);
            elsif Argument = "--operation-id" then
               Put (Item.Operation, Argument);
            elsif Argument = "--expected-task-revision" then
               Put (Item.Expected_Task_Revision, Argument);
            elsif Argument = "--expected-project-identity" then
               Put (Item.Expected_Project_Identity, Argument);
            elsif Argument = "--expected-source-fingerprint" then
               Put (Item.Expected_Source_Fingerprint, Argument);
            elsif Argument = "--execution-policy" then
               Put (Item.Execution_Policy, Argument);
            elsif Argument = "--authorization" then
               Put (Item.Authorization, Argument);
            elsif Argument = "--timeout-seconds" then
               declare
                  Value : Unbounded_String;
               begin
                  Put (Value, Argument);
                  if E.Is_Ok (Status) then
                     Item.Timeout_Seconds := Natural'Value (To_String (Value));
                  end if;
               exception
                  when Constraint_Error =>
                     Fail (Argument, To_String (Value), "a nonnegative whole number is required");
               end;
            elsif Argument = "--noninteractive" then
               if Item.Noninteractive then
                  Status := E.Make (E.CLI_Repeated_Option);
                  E.Add_Text (Status, "name", Argument);
               else
                  Item.Noninteractive := True;
               end if;
            elsif Argument = "--format" then
               declare
                  Value : Unbounded_String;
               begin
                  Put (Value, Argument);
                  if E.Is_Ok (Status) and then To_String (Value) = "json" then
                     Item.JSON := True;
                  elsif E.Is_Ok (Status) then
                     Fail (Argument, To_String (Value), "headless work supports only json");
                  end if;
               end;
            else
               Status := E.Make (E.CLI_Unknown_Option);
               E.Add_Text (Status, "name", Argument);
            end if;
         end;
         Index := Index + 1;
      end loop;
   end Parse;

   function Required (Item : Request; Name : String) return Boolean is
     ((if Name = "project" then Length (Item.Project)
       elsif Name = "task" then Length (Item.Task_Id)
       elsif Name = "operation" then Length (Item.Operation)
       elsif Name = "expected_task_revision" then Length (Item.Expected_Task_Revision)
       elsif Name = "expected_project_identity" then Length (Item.Expected_Project_Identity)
       elsif Name = "expected_source_fingerprint" then Length (Item.Expected_Source_Fingerprint)
       elsif Name = "execution_policy" then Length (Item.Execution_Policy)
       else 0) > 0);

   procedure Require (Item : Request; Names : Model_Runner.Framework.Name_Lists.Vector;
                      Status : in out E.Error_Info) is
   begin
      if E.Is_Error (Status) then
         return;
      elsif not Item.JSON then
         Status := E.Make (E.CLI_Option_Required);
         E.Add_Text (Status, "name", "--format json");
         return;
      end if;
      for Name of Names loop
         if not Required (Item, Name) then
            Status := E.Make (E.CLI_Option_Required);
            E.Add_Text
              (Status, "name",
               "--" & Ada.Strings.Fixed.Translate (Name, Ada.Strings.Maps.To_Mapping ("_", "-")));
            return;
         end if;
      end loop;
      if Required (Item, "operation") and then not Valid_Operation_Id (To_String (Item.Operation)) then
         Status := E.Make (E.CLI_Invalid_Option_Value);
         E.Add_Text (Status, "name", "--operation-id");
         E.Add_Text (Status, "value", To_String (Item.Operation));
      end if;
   end Require;

   procedure Add_Record
     (Store     : in out S.Store;
      Stage     : String;
      Operation : String;
      Task_Id   : String;
      Payload   : String;
      Id        : out Unbounded_String;
      Status    : out E.Error_Info)
   is
      Change : S.Transaction;
      Value  : Res.Result :=
        (Id         => Null_Unbounded_String,
         Kind       => Res.Diagnostic,
         Producer   => To_Unbounded_String (Producer_Prefix & Stage),
         Created_At => Null_Unbounded_String,
         Summary    => To_Unbounded_String ("headless work " & Stage),
         Payload    => To_Unbounded_String (Payload),
         Provenance => To_Unbounded_String (Operation),
         References => To_Unbounded_String (Task_Id),
         Retired    => Null_Unbounded_String);
   begin
      Res.Add (Store, Change, Value, Status);
      if E.Is_Ok (Status) then
         S.Commit (Store, Change, Status);
      end if;
      Id := Value.Id;
   end Add_Record;

   procedure Read_Operation
     (Store     : S.Store;
      Operation : String;
      Value     : out Operation_View;
      Status    : out E.Error_Info)
   is
      Names : constant Model_Runner.Framework.Name_Lists.Vector := S.Names (Store, Model_Runner.Framework.Results_Area);
   begin
      Value := (others => <>);
      Status := E.Success;
      if Natural (Names.Length) > Maximum_Operation_Results then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "headless operation history");
         return;
      end if;
      for Name of Names loop
         declare
            Item : Res.Result;
         begin
            Res.Read (Store, Name, Item, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            if To_String (Item.Provenance) = Operation
              and then Ada.Strings.Fixed.Index (To_String (Item.Producer), Producer_Prefix) = 1
            then
               declare
                  Producer : constant String := To_String (Item.Producer);
                  Stage    : constant String :=
                    Producer (Producer_Prefix'Length + 1 .. Producer'Last);
                  Task_Id  : constant String := To_String (Item.References);
               begin
                  if Stage = "intent" then
                     if Value.Has_Intent
                       and then (Value.Request_Text /= Item.Payload or else Value.Task_Id /= Item.References)
                     then
                        Status := E.Make (E.Framework_Integrity_Failed);
                        E.Add_Text (Status, "detail", "operation identity has conflicting intents");
                        return;
                     end if;
                     Value.Has_Intent := True;
                     Value.Intent_Id := Item.Id;
                     Value.Request_Text := Item.Payload;
                     Value.Task_Id := To_Unbounded_String (Task_Id);
                  elsif Stage = "invoking" then
                     Value.Has_Invoking := True;
                  elsif Stage = "outcome" then
                     if Value.Has_Outcome and then Value.Outcome /= Item.Payload then
                        Status := E.Make (E.Framework_Integrity_Failed);
                        E.Add_Text (Status, "detail", "operation identity has conflicting outcomes");
                        return;
                     end if;
                     Value.Has_Outcome := True;
                     Value.Outcome_Id := Item.Id;
                     Value.Outcome := Item.Payload;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Read_Operation;

   function Reasons_JSON (Value : Tk.Readiness) return String is
      Result : Unbounded_String := To_Unbounded_String ("[");
   begin
      for Reason of Value.Reasons loop
         Append (Result, (if Length (Result) = 1 then "" else ",") & Q (Reason));
      end loop;
      Append (Result, "]");
      return To_String (Result);
   end Reasons_JSON;

   function Snapshot_JSON
     (Store           : S.Store;
      Task_Id         : String;
      Operation       : String := "";
      Result_Word     : String := "observed";
      Audit_Reference : String := "") return String
   is
      Definition : Rec.Item;
      Effective  : Rec.Item;
      Got        : E.Error_Info;
      Ready      : constant Tk.Readiness := Tk.Ready (Store, Task_Id);
      Native     : constant String := Tk.State_Of (Store, Task_Id);
      Core       : constant String := Tk.Counts_As (Store, Native);
      Workspace  : constant String := Ws.Active_For (Store, Task_Id);
      Workspace_State : Unbounded_String;

      function Execution_State return String is
      begin
         if Core = Tk.Image (Tk.Accepted) then
            return (if Ready.Ready then "ready" else "blocked");
         elsif Core = Tk.Image (Tk.Running) then
            return "executing";
         elsif Core = Tk.Image (Tk.Verification) then
            return (if Workspace = "" then "verifying" else "awaiting_integration");
         elsif Core = Tk.Image (Tk.Complete) then
            return "completed";
         elsif Core = Tk.Image (Tk.Blocked) then
            return "blocked";
         elsif Core = Tk.Image (Tk.Cancelled) then
            return "cancelled";
         elsif Core = Tk.Image (Tk.Failed) or else Core = Tk.Image (Tk.Rejected) then
            return "failed";
         elsif Core = Tk.Image (Tk.Candidate) then
            return "not_ready";
         else
            return "incompatible";
         end if;
      end Execution_State;
   begin
      Tk.Definition (Store, Task_Id, Definition, Got);
      if E.Is_Error (Got) then
         return Error_JSON (Got);
      end if;
      Tk.Effective (Store, Task_Id, Effective, Got);
      if E.Is_Error (Got) then
         return Error_JSON (Got);
      end if;
      if Workspace = "" then
         Workspace_State := To_Unbounded_String
           ((if Tk.Counts_As (Store, Native) = Tk.Image (Tk.Complete) then "integrated" else "none"));
      else
         declare
            Item : Ws.Workspace;
         begin
            Ws.Read (Store, Workspace, Item, Got);
            Workspace_State :=
              (if E.Is_Ok (Got) then Item.Status else To_Unbounded_String ("unreadable"));
         end;
      end if;
      return "{""schema_version"":" & Image (Schema_Version)
        & ",""kind"":""work-operation"""
        & ",""operation_id"":" & Q (Operation)
        & ",""project_identity"":" & Q (S.Project_Id (Store))
        & ",""source_fingerprint"":" & Q (Repo.Graph_Fingerprint (Repo.Now (Store)))
        & ",""task_id"":" & Q (Task_Id)
        & ",""task_revision"":" & Q (Rec.Fingerprint_Of (Definition))
        & ",""effective_task_revision"":" & Q (Rec.Fingerprint_Of (Effective))
        & ",""execution_policy"":" & Q (Rec.Fingerprint_Of (Cfg.Required (Store)))
        & ",""execution_generation"":" & Q (Rec.Get (Effective, "runtime.generation"))
        & ",""execution_state"":"
        & Q (Execution_State)
        & ",""native_task_state"":" & Q (Native)
        & ",""core_state"":" & Q (Core)
        & ",""ready"":" & Bool (Ready.Ready)
        & ",""readiness_reasons"":" & Reasons_JSON (Ready)
        & ",""workspace_id"":" & Q (Workspace)
        & ",""workspace_state"":" & Q (To_String (Workspace_State))
        & ",""result"":" & Q (Result_Word)
        & ",""diagnostics"":[]"
        & ",""audit_reference"":" & Q (Audit_Reference) & "}";
   end Snapshot_JSON;

   procedure Open_Read
     (Item : Request; Store : in out S.Store; Status : out E.Error_Info) is
   begin
      S.Open_To_Read (Store, To_String (Item.Project), Status);
   end Open_Read;

   procedure Open_Write
     (Item : Request; Store : in out S.Store; Status : out E.Error_Info) is
      Opened : S.Recovery_Report;
      Said   : Model_Runner.Framework.Name_Lists.Vector;
   begin
      S.Open (Store, To_String (Item.Project), Opened, Status);
      if E.Is_Ok (Status) then
         W.Recover_On_Opening (Store, Opened, Said, Status);
      end if;
   end Open_Write;

   function Inspect (Item : Request; Status : out E.Error_Info) return String is
      Store : S.Store;
   begin
      Open_Read (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      declare
         Answer : constant String := Snapshot_JSON (Store, To_String (Item.Task_Id));
      begin
         S.Close (Store);
         return Answer;
      end;
   end Inspect;

   function Status_Of (Item : Request; Status : out E.Error_Info) return String is
      Store : S.Store;
      Found : Operation_View;
   begin
      Open_Read (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      Read_Operation (Store, To_String (Item.Operation), Found, Status);
      if E.Is_Error (Status) then
         S.Close (Store);
         return Error_JSON (Status);
      elsif not Found.Has_Intent then
         S.Close (Store);
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", To_String (Item.Operation));
         return Error_JSON (Status);
      elsif Found.Has_Outcome then
         S.Close (Store);
         if not Outcome_Succeeded (Found) then
            Status := E.Make (E.Framework_Agent_Failed);
            E.Add_Text (Status, "task", To_String (Found.Task_Id));
            E.Add_Text (Status, "detail", "the recorded native execution did not succeed");
         end if;
         return To_String (Found.Outcome);
      end if;
      declare
         Answer : constant String := Snapshot_JSON
           (Store, To_String (Found.Task_Id), To_String (Item.Operation),
            (if Found.Has_Outcome then "recorded" elsif Found.Has_Invoking then "reconciling" else "prepared"),
            (if Found.Has_Outcome then To_String (Found.Outcome_Id) else To_String (Found.Intent_Id)));
      begin
         S.Close (Store);
         return Answer;
      end;
   end Status_Of;

   procedure Validate_Execution
     (Store : S.Store; Item : Request; Status : out E.Error_Info) is
      Definition : Rec.Item;
      Current_Source : constant String := Repo.Graph_Fingerprint (Repo.Now (Store));
   begin
      Status := E.Success;
      Tk.Definition (Store, To_String (Item.Task_Id), Definition, Status);
      if E.Is_Error (Status) then
         return;
      elsif Rec.Fingerprint_Of (Definition) /= To_String (Item.Expected_Task_Revision) then
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "detail", "native task revision changed");
      elsif S.Project_Id (Store) /= To_String (Item.Expected_Project_Identity) then
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "detail", "native project identity changed");
      elsif Current_Source /= To_String (Item.Expected_Source_Fingerprint) then
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "detail", "project source fingerprint changed");
      elsif Rec.Fingerprint_Of (Cfg.Required (Store)) /= To_String (Item.Execution_Policy) then
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "detail", "execution policy fingerprint changed");
      elsif not Item.Noninteractive then
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "detail", "noninteractive=true is required");
      elsif Tk.State_Of (Store, To_String (Item.Task_Id)) /= Tk.Image (Tk.Accepted)
        or else not Tk.Ready (Store, To_String (Item.Task_Id)).Ready
      then
         Status := E.Make (E.Framework_Task_Not_Ready);
         E.Add_Text (Status, "task", To_String (Item.Task_Id));
      end if;
   end Validate_Execution;

   function Execute (Item : Request; Status : out E.Error_Info) return String is
      Store      : S.Store;
      Found      : Operation_View;
      Intent_Id  : Unbounded_String;
      Marker_Id  : Unbounded_String;
      Outcome_Id : Unbounded_String;
      Canonical  : constant String := Canonical_Request (Item);
      Execution_Status : E.Error_Info := E.Success;
      Execution_Report : W.Report;
   begin
      Open_Write (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      Read_Operation (Store, To_String (Item.Operation), Found, Status);
      if E.Is_Error (Status) then
         S.Close (Store);
         return Error_JSON (Status);
      elsif Found.Has_Intent and then To_String (Found.Request_Text) /= Canonical then
         S.Close (Store);
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "detail", "operation identity was already bound to another request");
         return Error_JSON (Status);
      elsif Found.Has_Outcome then
         S.Close (Store);
         if not Outcome_Succeeded (Found) then
            Status := E.Make (E.Framework_Agent_Failed);
            E.Add_Text (Status, "task", To_String (Found.Task_Id));
            E.Add_Text (Status, "detail", "the recorded native execution did not succeed");
         end if;
         return To_String (Found.Outcome);
      elsif Found.Has_Invoking then
         declare
            Answer : constant String := Snapshot_JSON
              (Store, To_String (Found.Task_Id), To_String (Item.Operation), "reconciling",
               To_String (Found.Intent_Id));
         begin
            S.Close (Store);
            Status := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Status, "task", To_String (Found.Task_Id));
            E.Add_Text
              (Status, "detail",
               "the operation was already invoked; inspect native state before manual reconciliation");
            return Answer;
         end;
      end if;

      Validate_Execution (Store, Item, Status);
      if E.Is_Error (Status) then
         S.Close (Store);
         return Error_JSON (Status);
      end if;

      if not Found.Has_Intent then
         Add_Record
           (Store, "intent", To_String (Item.Operation), To_String (Item.Task_Id), Canonical, Intent_Id, Status);
         if E.Is_Error (Status) then
            S.Close (Store);
            return Error_JSON (Status);
         end if;
      else
         Intent_Id := Found.Intent_Id;
      end if;

      Add_Record
        (Store, "invoking", To_String (Item.Operation), To_String (Item.Task_Id), To_String (Intent_Id),
         Marker_Id, Status);
      if E.Is_Error (Status) then
         S.Close (Store);
         return Error_JSON (Status);
      end if;
      S.Close (Store);
      Model_Runner.CLI.Work.Run_Headless
        (To_String (Item.Project), To_String (Item.Task_Id), Item.Timeout_Seconds,
         Execution_Report, Execution_Status);
      Open_Write (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;

      declare
         Core : constant String := Tk.Counts_As
           (Store, Tk.State_Of (Store, To_String (Item.Task_Id)));
         Result_Word : constant String :=
           (if E.Is_Error (Execution_Status) then "execution_error"
            elsif Core = Tk.Image (Tk.Complete) or else Core = Tk.Image (Tk.Verification) then "success"
            else "execution_failed");
         Answer : constant String := Snapshot_JSON
           (Store, To_String (Item.Task_Id), To_String (Item.Operation),
            Result_Word,
            To_String (Execution_Report.Invocation_Id));
      begin
         Add_Record
           (Store, "outcome", To_String (Item.Operation), To_String (Item.Task_Id), Answer, Outcome_Id, Status);
         S.Close (Store);
         if E.Is_Error (Status) then
            return Error_JSON (Status);
         elsif E.Is_Error (Execution_Status) then
            Status := Execution_Status;
         elsif Result_Word /= "success" then
            Status := E.Make (E.Framework_Agent_Failed);
            E.Add_Text (Status, "task", To_String (Item.Task_Id));
            E.Add_Text (Status, "detail", To_String (Execution_Report.Reason));
         end if;
         return Answer;
      end;
   end Execute;

   function Recover (Item : Request; Status : out E.Error_Info) return String is
      Store : S.Store;
   begin
      Open_Write (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      declare
         Answer : constant String :=
           "{""schema_version"":1,""kind"":""work-recovery"",""project_identity"":"
           & Q (S.Project_Id (Store)) & ",""result"":""reconciled""}";
      begin
         S.Close (Store);
         return Answer;
      end;
   end Recover;

   function Cancel (Item : Request; Status : out E.Error_Info) return String is
      Read_Store : S.Store;
      Found      : Operation_View;
   begin
      Open_Read (Item, Read_Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      Read_Operation (Read_Store, To_String (Item.Operation), Found, Status);
      if E.Is_Error (Status) or else not Found.Has_Intent then
         S.Close (Read_Store);
         if E.Is_Ok (Status) then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", To_String (Item.Operation));
         end if;
         return Error_JSON (Status);
      end if;
      declare
         Native_Task : constant String := To_String (Found.Task_Id);
         State       : constant String := Tk.State_Of (Read_Store, Native_Task);
         Core_State  : constant String := Tk.Counts_As (Read_Store, State);
      begin
         S.Close (Read_Store);
         if Core_State = Tk.Image (Tk.Running) then
            Model_Runner.Framework.Execution.Ask_To_Stop
              (To_String (Item.Project), Native_Task, True, Status => Status);
         else
            declare
               Store : S.Store;
            begin
               Open_Write (Item, Store, Status);
               if E.Is_Ok (Status) then
                  W.Cancel
                    (Store, Native_Task, Status,
                     Actor => "headless-operation:" & To_String (Item.Operation));
               end if;
               S.Close (Store);
            end;
         end if;
         if E.Is_Error (Status) then
            return Error_JSON (Status);
         end if;
         return "{""schema_version"":1,""kind"":""work-cancellation"",""operation_id"":"
           & Q (To_String (Item.Operation)) & ",""task_id"":" & Q (Native_Task)
           & ",""result"":""requested""}";
      end;
   end Cancel;

   function Integrate (Item : Request; Status : out E.Error_Info) return String is
      Store : S.Store;
      Found : Operation_View;
      Report : W.Report;
   begin
      if To_String (Item.Authorization) /= "conflict-free" then
         Status := E.Make (E.Framework_Permission_Denied);
         E.Add_Text (Status, "detail", "--authorization conflict-free is required");
         return Error_JSON (Status);
      end if;
      Open_Write (Item, Store, Status);
      if E.Is_Error (Status) then
         return Error_JSON (Status);
      end if;
      Read_Operation (Store, To_String (Item.Operation), Found, Status);
      if E.Is_Ok (Status) and then not Found.Has_Intent then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", To_String (Item.Operation));
      end if;
      if E.Is_Ok (Status) then
         W.Take_In (Store, To_String (Found.Task_Id), Report, Status);
      end if;
      if E.Is_Error (Status) then
         S.Close (Store);
         return Error_JSON (Status);
      end if;
      declare
         Answer : constant String := Snapshot_JSON
           (Store, To_String (Found.Task_Id), To_String (Item.Operation), "integrated",
            To_String (Found.Outcome_Id));
      begin
         S.Close (Store);
         return Answer;
      end;
   end Integrate;

   function Capabilities return String is
     ("{""schema_version"":1,""kind"":""work-capabilities"",""noninteractive"":true,"
      & """idempotent_operations"":true,""operation_lookup"":true,""workspace_isolation"":true,"
      & """semantic_conflict_resolution"":false,""commands"":[""inspect"",""execute"",""status"","
      & """cancel"",""recover"",""integrate""]}");

   function Inspect_Task
     (Project_Directory : String;
      Task_Id           : String;
      Status            : out E.Error_Info) return String
   is
      Item : Request := (others => <>);
   begin
      Item.Project := To_Unbounded_String (Project_Directory);
      Item.Task_Id := To_Unbounded_String (Task_Id);
      Item.JSON := True;
      return Inspect (Item, Status);
   end Inspect_Task;

   function Execute_Task
     (Project_Directory           : String;
      Task_Id                     : String;
      Operation_Id                : String;
      Expected_Task_Revision      : String;
      Expected_Project_Identity   : String;
      Expected_Source_Fingerprint : String;
      Execution_Policy            : String;
      Timeout_Seconds             : Natural;
      Status                      : out E.Error_Info) return String
   is
      Item : Request := (others => <>);
   begin
      Item.Project := To_Unbounded_String (Project_Directory);
      Item.Task_Id := To_Unbounded_String (Task_Id);
      Item.Operation := To_Unbounded_String (Operation_Id);
      Item.Expected_Task_Revision := To_Unbounded_String (Expected_Task_Revision);
      Item.Expected_Project_Identity := To_Unbounded_String (Expected_Project_Identity);
      Item.Expected_Source_Fingerprint := To_Unbounded_String (Expected_Source_Fingerprint);
      Item.Execution_Policy := To_Unbounded_String (Execution_Policy);
      Item.Timeout_Seconds := Timeout_Seconds;
      Item.Noninteractive := True;
      Item.JSON := True;
      if not Valid_Operation_Id (Operation_Id) then
         Status := E.Make (E.CLI_Invalid_Option_Value);
         E.Add_Text (Status, "name", "operation_id");
         E.Add_Text (Status, "value", Operation_Id);
         return Error_JSON (Status);
      end if;
      return Execute (Item, Status);
   end Execute_Task;

   function Operation_Status
     (Project_Directory : String;
      Operation_Id      : String;
      Status            : out E.Error_Info) return String
   is
      Item : Request := (others => <>);
   begin
      Item.Project := To_Unbounded_String (Project_Directory);
      Item.Operation := To_Unbounded_String (Operation_Id);
      Item.JSON := True;
      return Status_Of (Item, Status);
   end Operation_Status;

   procedure Run_Process (Status : out Natural) is
      Item    : Request;
      Problem : E.Error_Info;
      Answer  : Unbounded_String;
      Command : Unbounded_String;
   begin
      Parse (Item, Problem);
      Command := Item.Command;
      if Command = "capabilities" then
         Require (Item, Model_Runner.Framework.Name_Lists.Empty_Vector, Problem);
         if E.Is_Ok (Problem) then
            Answer := To_Unbounded_String (Capabilities);
         end if;
      elsif Command = "inspect" then
         Require (Item, ["project", "task"], Problem);
         if E.Is_Ok (Problem) then
            Answer := To_Unbounded_String (Inspect (Item, Problem));
         end if;
      elsif Command = "execute" then
         Require
           (Item, ["project", "task", "operation", "expected_task_revision",
                   "expected_project_identity", "expected_source_fingerprint", "execution_policy"], Problem);
         if E.Is_Ok (Problem) then
            Answer := To_Unbounded_String (Execute (Item, Problem));
         end if;
      elsif Command = "status" or else Command = "cancel" or else Command = "integrate" then
         Require (Item, ["project", "operation"], Problem);
         if E.Is_Ok (Problem) then
            Answer := To_Unbounded_String
              ((if Command = "status" then Status_Of (Item, Problem)
                elsif Command = "cancel" then Cancel (Item, Problem)
                else Integrate (Item, Problem)));
         end if;
      elsif Command = "recover" then
         Require (Item, ["project"], Problem);
         if E.Is_Ok (Problem) then
            Answer := To_Unbounded_String (Recover (Item, Problem));
         end if;
      elsif E.Is_Ok (Problem) then
         Problem := E.Make (E.CLI_Unknown_Command);
         E.Add_Text (Problem, "name", To_String (Command));
      end if;

      if E.Is_Error (Problem) and then Length (Answer) = 0 then
         Answer := To_Unbounded_String (Error_JSON (Problem));
      end if;
      Ada.Text_IO.Put_Line (To_String (Answer));
      Status := (if E.Is_Ok (Problem) then E.Exit_Success else E.Exit_Status (Problem));
   exception
      when others =>
         Ada.Text_IO.Put_Line (Error_JSON ("MR-INTERNAL-HEADLESS", "unexpected headless work failure"));
         Status := E.Exit_Internal;
   end Run_Process;

end Model_Runner.CLI.Headless_Work;
