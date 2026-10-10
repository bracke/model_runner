with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;

package body Model_Runner.Framework.Orchestration is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   Consumer : constant String := "orchestrator";

   function Config (Item : Stores.Store) return Records.Item is
   begin
      return Configurations.Required (Item);
   end Config;

   -----------
   -- Rules --
   -----------

   procedure Rules
     (Item   : Stores.Store;
      Result : out Automation.Rule_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Given : constant Name_Lists.Vector :=
        Lines_Of (Records.Get (Config (Item), "list.automation.rules"));
   begin
      Status := E.Success;
      if Given.Is_Empty then
         Result := Automation.Defaults;
         return;
      end if;
      Result.Clear;
      for Line of Given loop
         declare
            One     : Automation.Rule;
            Refusal : Unbounded_String;
         begin
            Automation.Read (Line, One, Refusal);
            if Length (Refusal) > 0 then
               --  Accepted before rules were read where they are set: said
               --  rather than skipped, so no event is taken as acted on.
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "list.automation.rules");
               E.Add_Text (Status, "value", Line);
               E.Add_Text (Status, "detail", To_String (Refusal));
               Result.Clear;
               return;
            end if;
            Result.Append (One);
         end;
      end loop;
   end Rules;

   ---------------------
   -- Unknown_Waiting --
   ---------------------

   function Unknown_Waiting (Item : Stores.Store) return Name_Lists.Vector is
      Listed : constant Events.Event_List := Events.Since (Item, 0);
   begin
      return Result : Name_Lists.Vector do
         for Index in 1 .. Events.Length (Listed) loop
            declare
               Happened : constant Events.Event := Events.Element (Listed, Index);
               Fresh    : Boolean;
               Scratch  : Stores.Transaction;
               Status   : E.Error_Info;
            begin
               if not Happened.Known then
                  Events.Consume (Item, Scratch, Consumer, To_String (Happened.Id), Fresh, Status);
                  if E.Is_Ok (Status) and then Fresh then
                     Result.Append (To_String (Happened.Kind_Word));
                  end if;
               end if;
            end;
         end loop;
      end return;
   end Unknown_Waiting;

   ----------
   -- Step --
   ----------

   procedure Step
     (Item   : in out Stores.Store;
      Result : out Step_Report;
      Status : out Model_Runner.Errors.Error_Info)
   is
      use type Automation.Action;
      package Action_Lists is new Ada.Containers.Vectors (Positive, Automation.Action);

      In_Force : Automation.Rule_Lists.Vector;
      Listed   : constant Events.Event_List := Events.Since (Item, 0);
      Change   : Stores.Transaction;
      Wanted   : Action_Lists.Vector;

      --  The first action that failed, said once the rest are taken.
      Failed   : E.Error_Info := E.Success;

      --  The actions the rules give an event, in rule order, once each.
      function Actions_For (Kind : String) return Action_Lists.Vector is
         Found : Action_Lists.Vector;
      begin
         for One of In_Force loop
            if Automation.Matches (One, Kind) and then not Found.Contains (One.Act) then
               Found.Append (One.Act);
            end if;
         end loop;
         return Found;
      end Actions_For;

      --  The events not yet acted on, and the kinds they are.
      Fresh_Ids   : Name_Lists.Vector;
      Fresh_Kinds : Name_Lists.Vector;

      --  The actions that failed: their events stay to be acted on again.
      Broken      : Action_Lists.Vector;
   begin
      Result := (others => <>);
      Rules (Item, In_Force, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  Which events are new, asked without consuming them: an event is
      --  consumed only with what it calls for done, so that a failure or a
      --  stop in between leaves it to be acted on again.
      for Index in 1 .. Events.Length (Listed) loop
         declare
            Happened : constant Events.Event := Events.Element (Listed, Index);
            Fresh    : Boolean;
            Scratch  : Stores.Transaction;
         begin
            Events.Consume (Item, Scratch, Consumer, To_String (Happened.Id), Fresh, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            if Fresh and then not Happened.Known then
               --  Written by a later build: what it calls for is that
               --  build's to say, so it is left for it, and said.
               Result.Unknown.Append (To_String (Happened.Kind_Word));
            elsif Fresh then
               Result.Events_Seen := Result.Events_Seen + 1;
               Fresh_Ids.Append (To_String (Happened.Id));
               Fresh_Kinds.Append (To_String (Happened.Kind_Word));
               for Action of Actions_For (To_String (Happened.Kind_Word)) loop
                  if not Wanted.Contains (Action) then
                     Wanted.Append (Action);
                  end if;
               end loop;
            end if;
         end;
      end loop;

      for Action of Wanted loop
         if Action = Automation.Recompute_Readiness then
            goto Next_Action;
         end if;
         Result.Actions_Taken := Result.Actions_Taken + 1;
         case Action is
            when Automation.Derive_Tasks =>
               Tasks.Derive (Item, Change, Result.Derived, Status);
            when Automation.Reevaluate_Requirements =>
               Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
            when Automation.Verify =>
               declare
                  Profile  : constant String :=
                    Records.Get (Config (Item), "scalar.verification.default");
                  Evidence : Unbounded_String;
                  Passed   : Boolean;
               begin
                  if Profile /= "" then
                     Verification.Run_Profile (Item, Change, Profile, "", Evidence, Passed, Status);
                     if E.Is_Ok (Status) then
                        Result.Evidence.Append (To_String (Evidence));
                     end if;
                  end if;
               end;
            when Automation.Recompute_Readiness =>
               null;
         end case;

         --  Each action kept on its own; one that fails is dropped and
         --  said, and the others are still taken.
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         if E.Is_Error (Status) then
            Change := Stores.No_Changes;
            Broken.Append (Action);
            if E.Is_Ok (Failed) then
               Failed := Status;
            end if;
            Status := E.Success;
         end if;
         <<Next_Action>>
      end loop;

      --  Readiness last, over what the actions left.
      if Wanted.Contains (Automation.Recompute_Readiness) then
         Result.Actions_Taken := Result.Actions_Taken + 1;
         Tasks.Recompute_Readiness (Item, Change, Result.Became_Ready, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         if E.Is_Error (Status) then
            Change := Stores.No_Changes;
            Broken.Append (Automation.Recompute_Readiness);
            if E.Is_Ok (Failed) then
               Failed := Status;
            end if;
            Status := E.Success;
         end if;
      end if;

      --  Each event whose actions were all taken is consumed; one whose
      --  action failed waits for the next step. Everything else it calls
      --  for is taken again then, which each action is safe to be.
      for Index in 1 .. Natural (Fresh_Ids.Length) loop
         if (for all Action of Actions_For (Fresh_Kinds (Index)) => not Broken.Contains (Action))
         then
            declare
               Fresh : Boolean;
            begin
               Events.Consume (Item, Change, Consumer, Fresh_Ids (Index), Fresh, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end;
         end if;
      end loop;
      Stores.Commit (Item, Change, Status);
      if E.Is_Ok (Status) and then E.Is_Error (Failed) then
         Status := Failed;
      end if;
   end Step;

   ----------
   -- Plan --
   ----------

   function Plan (Item : Stores.Store) return Dispatch_Plan is
      Result   : Dispatch_Plan;
      Limits   : constant Agents.Limits := Agents.Limits_Of (Item);
      Settings : constant Records.Item := Config (Item);
      Isolated : constant Boolean :=
        Records.Get (Settings, "scalar.work.isolation") = "workspace";
      Running  : Natural := 0;

      --  The components being written, and those being read, by the tasks
      --  running or planned: two readers of one component go together, and
      --  a writer goes with nobody else in it.
      Written  : Name_Lists.Vector;
      Read_In  : Name_Lists.Vector;

      --  Whether a task's agent may write at all: one that only reads is
      --  no writer the project waits on.
      function Writes (Id : String) return Boolean is
         Defined : Records.Item;
         Read    : E.Error_Info;
      begin
         Tasks.Definition (Item, Id, Defined, Read);
         declare
            Allowed : constant Permissions.Permission_Set :=
              Permissions.Effective (Item, Records.Get (Defined, "kind"), "",
                                     Task_Level => Records.Get (Defined, "permissions"),
                                     Within_Sandbox => False);
         begin
            return Allowed (Permissions.Write_Source).Granted or else Allowed (Permissions.Write_Specs).Granted;
         end;
      end Writes;
      Writer_Running : Unbounded_String;
      Writer_Planned : Unbounded_String;

      type Candidate is record
         Id        : Unbounded_String;
         Priority  : Natural := 0;
         Component : Unbounded_String;

         --  The order it was made in: its definition's created_sequence,
         --  nought for one made before tasks were counted.
         Sequence  : Natural := 0;
      end record;
      package Candidate_Vectors is new Ada.Containers.Vectors (Positive, Candidate);
      Ready : Candidate_Vectors.Vector;
   begin
      for Id of Tasks.List (Item, "running") loop
         Running := Running + 1;
         if Writer_Running = Null_Unbounded_String and then Writes (Id) then
            Writer_Running := To_Unbounded_String (Id);
         end if;
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
         begin
            Tasks.Definition (Item, Id, Defined, Read);
            if Records.Get (Defined, "component") /= "" then
               if Writes (Id) then
                  Written.Append (Records.Get (Defined, "component"));
               else
                  Read_In.Append (Records.Get (Defined, "component"));
               end if;
            end if;
         end;
      end loop;
      Result.Slots :=
        (if Running >= Limits.Max_Active then 0 else Limits.Max_Active - Running);

      for Id of Tasks.List (Item, "accepted") loop
         if Tasks.Ready (Item, Id).Ready then
            declare
               Defined : Records.Item;
               Read    : E.Error_Info;
               Text    : Unbounded_String;
            begin
               Tasks.Definition (Item, Id, Defined, Read);
               Text := To_Unbounded_String (Records.Get (Defined, "priority"));
               declare
                  Made : constant String := Records.Get (Defined, "created_sequence");
               begin
                  Ready.Append
                 (Candidate'(Id        => To_Unbounded_String (Id),
                   Priority  =>
                     (if Length (Text) in 1 .. 9
                        and then (for all C of To_String (Text) => C in '0' .. '9')
                      then Natural'Value (To_String (Text)) else 0),
                   Component => To_Unbounded_String (Records.Get (Defined, "component")),
                   Sequence  =>
                     (if Made'Length in 1 .. 9 and then (for all C of Made => C in '0' .. '9')
                      then Natural'Value (Made) else 0)));
               end;
            end;
         end if;
      end loop;

      --  Most important first; of equals, the older -- by the order they
      --  were made in, and by name only between two made before that was
      --  counted.
      declare
         function Before (Left, Right : Candidate) return Boolean
         is (Left.Priority > Right.Priority
             or else (Left.Priority = Right.Priority
                      and then (Left.Sequence < Right.Sequence
                                or else (Left.Sequence = Right.Sequence and then Left.Id < Right.Id))));
         package Sorting is new Candidate_Vectors.Generic_Sorting (Before);
      begin
         Sorting.Sort (Ready);
      end;

      for Next of Ready loop
         declare
            Component : constant String := To_String (Next.Component);
         begin
            if Natural (Result.Start.Length) >= Result.Slots then
               Result.Held.Append (To_String (Next.Id) & ": no agent slot is free");

            --  In the project itself, one writer at a time: two in one tree
            --  would have each other's changes taken for their own.
            --  A task that only reads waits for no writer, nor holds one.
            elsif not Isolated and then Writes (To_String (Next.Id))
              and then (Writer_Running /= Null_Unbounded_String or else Writer_Planned /= Null_Unbounded_String)
            then
               Result.Held.Append
                 (To_String (Next.Id) & ": "
                  & (if Writer_Running /= Null_Unbounded_String
                     then To_String (Writer_Running) & " is writing in the project"
                     else "would wait for " & To_String (Writer_Planned)
                          & ", planned before it, to write in the project first")
                  & "; one task writes in it at a time");
            elsif not Isolated and then Component /= "" and then Written.Contains (Component) then
               Result.Held.Append
                 (To_String (Next.Id) & ": another task is writing " & Component);
            elsif not Isolated and then Component /= "" and then Writes (To_String (Next.Id))
              and then Read_In.Contains (Component)
            then
               Result.Held.Append
                 (To_String (Next.Id) & ": another task is reading " & Component
                  & ", and would read this one's changes half made");
            else
               Result.Start.Append (To_String (Next.Id));
               if Writer_Planned = Null_Unbounded_String and then Writes (To_String (Next.Id)) then
                  Writer_Planned := Next.Id;
               end if;
               if Component /= "" then
                  if Writes (To_String (Next.Id)) then
                     Written.Append (Component);
                  else
                     Read_In.Append (Component);
                  end if;
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Plan;

   --------------------
   -- Needs_Judgment --
   --------------------

   function Needs_Judgment (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Id of Tasks.List (Item, "candidate") loop
         Result.Append (Id & ": a candidate waiting to be accepted or rejected");
      end loop;
      for Id of Tasks.List (Item, "blocked") loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & ".state", Value, Status);
            --  Waiting for its parts is waiting, not a judgment to make.
            if Ada.Strings.Fixed.Index (Records.Get (Value, "blocking_reasons"), "waiting for its children") /= 1
            then
               Result.Append (Id & ": blocked, "
                              & (if Records.Get (Value, "blocking_reasons") = ""
                                 then "moved there by hand; /task accept " & Id & " takes it up again"
                                 else Records.Get (Value, "blocking_reasons")));
            end if;
         end;
      end loop;
      --  Waiting for work that ended undone: let go, or have it done.
      for Id of Tasks.List (Item, "accepted") loop
         for Reason of Tasks.Ready (Item, Id).Reasons loop
            if Ada.Strings.Fixed.Index (Reason, ", which is cancelled") > 0
              or else Ada.Strings.Fixed.Index (Reason, ", which is rejected") > 0
            then
               --  The task it waits for, by its identifier as the reason
               --  names it; brought back as its end allows.
               declare
                  At_Id : constant Natural := Ada.Strings.Fixed.Index (Reason, "TASK-");
                  Last  : Natural := At_Id;
               begin
                  if At_Id > 0 then
                     while Last < Reason'Last
                       and then Reason (Last + 1) in 'A' .. 'Z' | '0' .. '9' | '-' | '_'
                     loop
                        Last := Last + 1;
                     end loop;
                  end if;
                  declare
                     Other : constant String :=
                       (if At_Id = 0 then "TASK" else Reason (At_Id .. Last));
                  begin
                     Result.Append
                       (Id & ": " & Reason & "; /task depend " & Id & " " & Other
                        & " remove lets it go on without, or /task "
                        & (if Ada.Strings.Fixed.Index (Reason, ", which is rejected") > 0
                           then "reconsider " else "reopen ")
                        & Other & " has it done");
                  end;
               end;
            end if;
         end loop;
      end loop;
      --  Failed: tried again, or done by hand.
      for Id of Tasks.List (Item, "failed") loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & ".state", Value, Status);
            Result.Append (Id & ": failed"
                           & (if Records.Get (Value, "current_failure") = "" then ""
                              else ", " & Records.Get (Value, "current_failure"))
                           --  The ways on, unless its failure says them.
                           & (if Ada.Strings.Fixed.Index (Records.Get (Value, "current_failure"),
                                                          "/task complete " & Id) > 0
                              then ""
                              else "; /task accept " & Id & " tries again, /task complete " & Id
                                   & " once it is done by hand"));
         end;
      end loop;
      --  Waiting in a workspace to be taken in.
      for Id of Tasks.List (Item, "verification") loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & ".state", Value, Status);
            if Records.Get (Value, "current_workspace") /= "" then
               Result.Append (Id & ": its work waits in " & Records.Get (Value, "current_workspace")
                              & " to be taken in; /task integrate " & Id);
            end if;
         end;
      end loop;
      --  Within the project, and within each component.
      declare
         use type Authority.Relation;
         Scopes : Name_Lists.Vector := Tasks.Components (Item);
      begin
         Scopes.Prepend ("");
         for Scope of Scopes loop
            declare
               Resolved : constant Authority.Resolution :=
                 Authority.Resolve (Authority.Gather (Item, Scope));
            begin
               for Index in 1 .. Authority.Length (Resolved) loop
                  if Authority.Element (Resolved, Index).Relation = Authority.Conflict then
                     declare
                        Line : constant String :=
                          To_String (Authority.Element (Resolved, Index).Governing.Subject)
                          & ": a conflict of authority to resolve";
                     begin
                        if not Result.Contains (Line) then
                           Result.Append (Line);
                        end if;
                     end;
                  end if;
               end loop;
            end;
         end loop;
      end;
      return Result;
   end Needs_Judgment;

end Model_Runner.Framework.Orchestration;
