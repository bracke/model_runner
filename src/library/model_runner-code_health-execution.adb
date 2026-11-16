with Ada.Directories;
with Ada.Calendar;

with Model_Runner.Platform;
with Model_Runner.Processes;

package body Model_Runner.Code_Health.Execution is

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Ada.Calendar.Time;

   package E renames Model_Runner.Errors;

   function Smaller_Limit (Left, Right : Natural) return Natural is
     (if Left = 0 then Right elsif Right = 0 then Left else Natural'Min (Left, Right));

   procedure Initialize
     (Self       : in out Standalone_Runner;
      Root       : String;
      Authorized : X.Policy) is
   begin
      Self.Root := To_Unbounded_String (Ada.Directories.Full_Name (Root));
      Self.Authorized := Authorized;
      Self.Ready := True;
   exception
      when others =>
         Self.Ready := False;
   end Initialize;

   overriding procedure Run
     (Self      : in out Standalone_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out E.Error_Info)
   is
      Applied : constant X.Policy := Effective_Policy (Self.Authorized, Rules);
      Words   : constant Model_Runner.Framework.Name_Lists.Vector := X.Words_Of (Command);
      Asked   : Model_Runner.Processes.Request;
      Began   : constant Ada.Calendar.Time := Ada.Calendar.Clock;

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Result := (Command => To_Unbounded_String (Command), others => <>);
      if not Self.Ready then
         Refuse ("the interactive Code Health runner is not initialized");
         return;
      elsif X.Refusal (Applied, Command) /= "" then
         Refuse (X.Refusal (Applied, Command));
         return;
      elsif Directory /= "" then
         Refuse ("interactive Code Health commands run only at the project root");
         return;
      elsif Applied.Confine_Writes or else Applied.No_Network
        or else Applied.Memory_MB > 0 or else Applied.CPU_Seconds > 0
        or else Applied.Processes > 0 or else Applied.File_MB > 0
        or else Applied.Process_Slots > 0
      then
         Refuse ("the interactive runner cannot promise the requested isolation or resource limit");
         return;
      elsif Deadline <= Ada.Real_Time.Clock then
         Result.Timed_Out := True;
         Status := E.Success;
         return;
      elsif Model_Runner.Cancellation.Is_Cancelled (Cancel) then
         Result.Cancelled := True;
         Status := E.Success;
         return;
      end if;

      Asked.Program := To_Unbounded_String ("env");
      Asked.Arguments.Append (To_Unbounded_String ("-i"));
      declare
         Passed : constant String :=
           Model_Runner.Platform.Passed_Environment (To_String (Applied.Environment));
         First : Natural := Passed'First;
      begin
         for Index in Passed'First .. Passed'Last + 1 loop
            if Index > Passed'Last or else Passed (Index) = ASCII.LF then
               if Index > First then
                  Asked.Arguments.Append (To_Unbounded_String (Passed (First .. Index - 1)));
               end if;
               First := Index + 1;
            end if;
         end loop;
      end;
      for Word of Words loop
         Asked.Arguments.Append (To_Unbounded_String (Word));
      end loop;
      Asked.Directory := Self.Root;
      Asked.Limit := Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
      X.Watch (Cancel);
      Asked.Cancelled := X.Cancel_Requested'Access;
      declare
         Ran : constant Model_Runner.Processes.Result := Model_Runner.Processes.Run (Asked);
      begin
         Result.Started := Ran.Started;
         Result.Exit_Status := Ran.Exit_Status;
         Result.Cancelled := Ran.Stopped and then X.Cancel_Requested;
         Result.Timed_Out := Ran.Stopped and then not Result.Cancelled;
         Result.Output := Ran.Errors;
         if Length (Ran.Errors) > 0 and then Length (Ran.Output) > 0 then
            Append (Result.Output, ASCII.LF);
         end if;
         Append (Result.Output, Ran.Output);
         Result.Seconds := Natural (Ada.Calendar.Clock - Began);
      end;
      Status := E.Success;
   exception
      when Failure : others =>
         Status := E.Unexpected (Failure, "running an interactive Code Health command");
   end Run;

   function Effective_Policy
     (Authorized : X.Policy;
      Requested  : X.Policy) return X.Policy
   is
      Result : X.Policy;

      function Names (Text : String) return Model_Runner.Framework.Name_Lists.Vector is
         Listed : Model_Runner.Framework.Name_Lists.Vector;
         First  : Natural := Text'First;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = ',' then
               if Index > First then
                  Listed.Append (Text (First .. Index - 1));
               end if;
               First := Index + 1;
            end if;
         end loop;
         return Listed;
      end Names;
   begin
      for Program of Requested.Allowed loop
         if Authorized.Allowed.Contains (Program)
           and then not Result.Allowed.Contains (Program)
         then
            Result.Allowed.Append (Program);
         end if;
      end loop;
      Result.Shell_Allowed := Authorized.Shell_Allowed and then Requested.Shell_Allowed;
      for Name of Names (To_String (Requested.Environment)) loop
         if Names (To_String (Authorized.Environment)).Contains (Name) then
            Append (Result.Environment, Name & ",");
         end if;
      end loop;
      Result.Timeout := Positive'Min (Authorized.Timeout, Requested.Timeout);
      Result.Output_Limit := Positive'Min (Authorized.Output_Limit, Requested.Output_Limit);
      Result.Keep_Whole := Authorized.Keep_Whole and then Requested.Keep_Whole;
      Result.Network := Authorized.Network and then Requested.Network;
      Result.No_Network :=
        Authorized.No_Network or else Requested.No_Network or else not Result.Network;
      Result.Prefer_Offline := Authorized.Prefer_Offline or else Requested.Prefer_Offline;
      Result.Memory_MB := Smaller_Limit (Authorized.Memory_MB, Requested.Memory_MB);
      Result.CPU_Seconds := Smaller_Limit (Authorized.CPU_Seconds, Requested.CPU_Seconds);
      Result.Processes := Smaller_Limit (Authorized.Processes, Requested.Processes);
      Result.File_MB := Smaller_Limit (Authorized.File_MB, Requested.File_MB);
      Result.Process_Slots := Smaller_Limit (Authorized.Process_Slots, Requested.Process_Slots);
      Result.Confine_Writes := Authorized.Confine_Writes or else Requested.Confine_Writes;
      return Result;
   end Effective_Policy;

   procedure Initialize
     (Self   : in out Framework_Runner;
      Store  : not null Store_Reference;
      Change : not null Transaction_Reference;
      Status : out E.Error_Info;
      Base   : String := "") is
   begin
      Self.Store := Store;
      Self.Change := Change;
      Self.Base := To_Unbounded_String (Base);
      Self.Ready := False;
      Self.Initialization := E.Success;
      Self.Authorized := X.Policy_Of (Store.all);
      declare
         Root : constant String :=
           (if Base /= "" then Base
            else Ada.Directories.Containing_Directory (S.Root (Store.all)));
      begin
         Model_Runner.Code_Health.Changes.Capture (Root, Self.Snapshot, Status);
      end;
      if E.Is_Error (Status) then
         Self.Initialization := Status;
         return;
      end if;
      Self.Ready := True;
      Status := E.Success;
   exception
      when Failure : others =>
         Status := E.Unexpected (Failure, "binding the Code Health execution policy");
         Self.Initialization := Status;
   end Initialize;

   procedure Verify_Unchanged
     (Self   : Framework_Runner;
      Stale  : out Boolean;
      Status : out E.Error_Info)
   is
      Current : Model_Runner.Code_Health.Changes.Snapshot;
   begin
      Stale := False;
      if not Self.Ready then
         Status := Self.Initialization;
         if E.Is_Ok (Status) then
            Status := E.Make (E.Framework_Execution_Refused);
            E.Add_Text (Status, "name", "Code Health source guard");
            E.Add_Text (Status, "detail", "the runner was not initialized");
         end if;
         return;
      end if;
      Model_Runner.Code_Health.Changes.Capture
        (Model_Runner.Code_Health.Changes.Root (Self.Snapshot), Current, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Stale := Model_Runner.Code_Health.Changes.Identifier (Current)
        /= Model_Runner.Code_Health.Changes.Identifier (Self.Snapshot);
      if Stale then
         Status := E.Make (E.Framework_Contract_Violation);
         E.Add_Text (Status, "detail", "project source changed while Code Health was analyzing it");
      else
         Status := E.Success;
      end if;
   end Verify_Unchanged;

   procedure Rebind_Source
     (Self   : in out Framework_Runner;
      Status : out E.Error_Info) is
   begin
      if not Self.Ready then
         Status := Self.Initialization;
         if E.Is_Ok (Status) then
            Status := E.Make (E.Framework_Execution_Refused);
            E.Add_Text (Status, "name", "Code Health source guard");
            E.Add_Text (Status, "detail", "the runner was not initialized");
         end if;
         return;
      end if;
      declare
         Root : constant String := Model_Runner.Code_Health.Changes.Root (Self.Snapshot);
      begin
         Model_Runner.Code_Health.Changes.Capture (Root, Self.Snapshot, Status);
      end;
   end Rebind_Source;

   overriding procedure Run
     (Self      : in out Framework_Runner;
      Rules     : X.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out X.Outcome;
      Status    : out E.Error_Info)
   is
      Applied : X.Policy;
      Stale   : Boolean;
      Checked : E.Error_Info;
   begin
      if Self.Store = null or else Self.Change = null then
         Result := (Command => To_Unbounded_String (Command), others => <>);
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "the Code Health runner has no owning transaction");
         return;
      end if;

      if not Self.Ready then
         Result := (Command => To_Unbounded_String (Command), others => <>);
         Status := Self.Initialization;
         if E.Is_Ok (Status) then
            Status := E.Make (E.Framework_Execution_Refused);
            E.Add_Text (Status, "name", Command);
            E.Add_Text (Status, "detail", "the Code Health runner is not initialized");
         end if;
         return;
      end if;

      Applied := Effective_Policy (Self.Authorized, Rules);

      if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
         Result :=
           (Command   => To_Unbounded_String (Command),
            Directory => To_Unbounded_String (Directory),
            Cancelled => True,
            others    => <>);
         Status := E.Success;
         return;
      end if;

      if Deadline /= Ada.Real_Time.Time_Last then
         declare
            Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            if Deadline <= Now then
               Result :=
                 (Command   => To_Unbounded_String (Command),
                  Directory => To_Unbounded_String (Directory),
                  Timed_Out => True,
                  others    => <>);
               Status := E.Success;
               return;
            end if;
            declare
               Left : constant Duration := Ada.Real_Time.To_Duration (Deadline - Now);
            begin
               if Left < Duration (Applied.Timeout) then
                  Applied.Timeout :=
                    Positive'Max (1, Positive (Long_Float'Ceiling (Long_Float (Left))));
               end if;
            end;
         end;
      end if;

      Verify_Unchanged (Self, Stale, Status);
      if E.Is_Error (Status) then
         Result := (Command => To_Unbounded_String (Command), Directory => To_Unbounded_String (Directory),
                    others => <>);
         return;
      end if;

      X.Watch (Cancel);
      X.Run
        (Self.Store.all, Self.Change.all, Applied, Command, Directory, Result, Status,
         Base => To_String (Self.Base));
      Verify_Unchanged (Self, Stale, Checked);
      if E.Is_Error (Checked) then
         Status := Checked;
      end if;
   exception
      when Failure : others =>
         Result := (Command => To_Unbounded_String (Command), Directory => To_Unbounded_String (Directory),
                    others => <>);
         Status := E.Unexpected (Failure, "running a Code Health provider command");
   end Run;

end Model_Runner.Code_Health.Execution;
