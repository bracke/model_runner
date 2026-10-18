separate (Model_Runner.Framework.Work)
procedure Run_Checks
  (Host     : in out Child_Host;
   Profile  : String;
   Report   : out Ada.Strings.Unbounded.Unbounded_String;
   Status   : out Model_Runner.Errors.Error_Info;
   Affected : Boolean := False)
is
   --  The files the work has changed so far, as the harness saw them.
   function Changed_So_Far return Name_Lists.Vector is (Host.Edited);

   --  What to run: the task's profile, or for the affected scope what the
   --  change reaches -- where the agent may run that.
   Changed : constant Name_Lists.Vector :=
     (if Affected then Changed_So_Far else Name_Lists.Empty_Vector);
   Chosen  : constant Verification.Choice :=
     (if Affected and then not Changed.Is_Empty
      then Verification.Choose (Host.Item.all, To_String (Host.Task_Id), Changed)
      else (others => <>));
   --  Narrower only where the agent may run that profile too, as it may
   --  now: what it takes is its own, not the task's profile's.
   Narrow  : constant Boolean :=
     Affected and then Length (Chosen.Profile) > 0 and then To_String (Chosen.Profile) /= Profile
     and then May_Check (Host, Profile)
     and then May_Check (Host, To_String (Chosen.Profile));
   Running : constant String := (if Narrow then To_String (Chosen.Profile) else Profile);
   Scope_Said : constant String :=
     (if not Affected then ""
      elsif Changed.Is_Empty then "scope: full, since nothing has been changed yet" & ASCII.LF
      elsif Narrow then "scope: " & To_String (Chosen.Scope) & " -- " & To_String (Chosen.Reason) & ASCII.LF
      else "scope: full -- " & (if Length (Chosen.Reason) > 0 then To_String (Chosen.Reason)
                                else "what was changed reaches no narrower profile") & ASCII.LF);

   --  The project's files, as the checks left them: what a FILE:LINE in
   --  their output is looked up among.
   Known    : Name_Lists.Vector;
   Project_Dir : Unbounded_String;

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
      --  Where the work is: the project, or the agent's own workspace.
      Project : constant String :=
        (if Host.Apart then To_String (Host.Tree)
         else Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all)));
      Before  : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
   begin
      Project_Dir := To_Unbounded_String (Project);
      --  Off the network unless the agent may use it.
      --  Within the time the work has left: a check does not carry it
      --  past its bound.
      if Time_Is_Up (Host) then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
         return;
      end if;
      --  Run for its task, in the tree its agents write: the project
      --  itself, or its workspace -- evidence that says so, and never
      --  counts as the project's.
      Verification.Run_Profile
        (Host.Item.all, Change, Running, To_String (Host.Task_Id),
         Evidence, Passed, Status,
         Given      => (if Narrow then Chosen.Given else Name_Lists.Empty_Vector),
         Stands_For => (if Narrow then Profile else ""),
         Selection  => (if Narrow then To_String (Chosen.Selection) else ""),
         Derived    => (if Narrow then Chosen.Derived else Derivations.Nothing_Staged),
         Offline => not May (Host, Permissions.Use_Network, ""),
         Workspace => (if Host.Apart then To_String (Host.Tree) else ""),
         Within  => (if Host.Bounded then Natural (Duration'Max (1.0, Time_Left (Host))) else 0),
         --  The work's own profile as it stood when the work started.
         Definition =>
           (if Host.Profile_Frozen and then not Narrow
              and then Running = To_String (Host.Profile)
            then To_String (Host.Profile_Text) else ""));
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
            Known.Append (Configurations.Value_Maps.Key (Position));
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

   Host.Checks_Failed := not Passed;

   --  Passing where they failed before: what failed, and what the work
   --  changed that made them pass, kept for later work -- apart, so what
   --  cannot be kept of it costs the run nothing.
   --  And what the changed files hold now, beside what they held when the
   --  checks last failed: the change that made them pass, said.
   declare
      function Text_Of (Path : String) return String is
         Text : Unbounded_String;
         Got  : E.Error_Info;
         Full : constant String := Hostkit.Fs.Join (To_String (Project_Dir), Path);
      begin
         if not Ada.Directories.Exists (Full) then
            return "";
         end if;
         Files.Read_Text (Full, Text, Got);
         return (if E.Is_Ok (Got) then To_String (Text) else "");
      exception
         when others =>
            return "";
      end Text_Of;

      Fixed_By : Unbounded_String;
   begin
      if Passed and then not Host.At_Failure.Is_Empty then
         for Held of Host.At_Failure loop
            declare
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Held, [1 => ASCII.NUL]);
               Path : constant String := Held (Held'First .. Cut - 1);
               Said : constant String := Observations.Change_Said (Path, Held (Cut + 1 .. Held'Last), Text_Of (Path));
            begin
               if Said /= "" then
                  Append (Fixed_By, (if Length (Fixed_By) = 0 then "" else " / ") & Said);
               end if;
            end;
         end loop;
      end if;
      if Passed then
         declare
            Fixed  : Stores.Transaction;
            Id     : Unbounded_String;
            Kept   : E.Error_Info;
         begin
            Observations.Observe_Fix
              (Host.Item.all, Fixed, To_String (Host.Task_Id), To_String (Evidence), Host.Edited,
               Host_Origin (Host, Observations.Harness_Producer), Id, Kept, To_String (Fixed_By));
            if E.Is_Ok (Kept) and then Stores.Change_Count (Fixed) > 0 then
               Stores.Commit (Host.Item.all, Fixed, Kept);
            end if;
         end;
         Host.At_Failure.Clear;
      else
         Host.At_Failure.Clear;
         for Path of Host.Edited loop
            Host.At_Failure.Append (Path & ASCII.NUL & Text_Of (Path));
         end loop;
      end if;
   end;
   Stores.Read (Host.Item.all, Verification_Area, To_String (Evidence), Value, Read);

   --  A profile whose every check is the command true -- what /init writes
   --  where no check was named -- passes having checked nothing. Said as
   --  that, or a model reads the pass as its work found sound: a 4B wrote
   --  Ada that would not compile and reported it verified on this.
   declare
      Commands : Natural := 0;
      Empty    : Natural := 0;
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Said  : constant String := Records.Get (Value, Field);
            Mark  : constant String := "command=true,";
         begin
            if Field'Length > 11 and then Field (Field'First .. Field'First + 10) = "parameters." then
               Commands := Commands + 1;
               if Said'Length >= Mark'Length
                 and then Said (Said'First .. Said'First + Mark'Length - 1) = Mark
               then
                  Empty := Empty + 1;
               end if;
            end if;
         end;
      end loop;
      Report := To_Unbounded_String
        (Scope_Said & Running
         & (if Passed and then Commands > 0 and then Empty = Commands
            then " checked nothing: its every check is the command true, which "
                 & "tests nothing -- the project names no real check, so the "
                 & "work is unchecked; say so rather than calling it verified"
            elsif Passed then " passed" else " failed") & ", "
         & To_String (Evidence));
   end;
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
                  if E.Is_Ok (Held) and then Length (Log.Retired) > 0 then
                     Append (Report, ASCII.LF & "(its log is retired under " & To_String (Log.Retired) & ")");
                  elsif E.Is_Ok (Held) then
                     Append (Report, ASCII.LF & Tail (To_String (Log.Payload), 30)
                             & Quoted_Lines (Tail (To_String (Log.Payload), 30), To_String (Project_Dir), Known));
                  end if;
               end;
            end if;
         end if;
      end;
   end loop;
end Run_Checks;
