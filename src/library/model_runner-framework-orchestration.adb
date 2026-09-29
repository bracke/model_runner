with Ada.Containers.Vectors;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;

package body Model_Runner.Framework.Orchestration is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   Consumer : constant String := "orchestrator";

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Config (Item : Stores.Store) return Records.Item is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Value, Status);
      return (if E.Is_Ok (Status) then Value else Records.Create ("", 1, "", 0));
   end Config;

   -----------
   -- Rules --
   -----------

   function Rules (Item : Stores.Store) return Name_Lists.Vector is
      Given : constant Name_Lists.Vector :=
        Lines_Of (Records.Get (Config (Item), "list.automation.rules"));
      Result : Name_Lists.Vector;
   begin
      if not Given.Is_Empty then
         return Given;
      end if;
      Result.Append ("Requirement_Accepted: derive_tasks");
      Result.Append ("Requirement_Revised: derive_tasks");
      Result.Append ("Task_Completed: reevaluate_requirements");
      Result.Append ("Source_Changed: reevaluate_requirements");
      Result.Append ("*: recompute_readiness");
      return Result;
   end Rules;

   ----------
   -- Step --
   ----------

   procedure Step
     (Item   : in out Stores.Store;
      Result : out Step_Report;
      Status : out Model_Runner.Errors.Error_Info)
   is
      In_Force : constant Name_Lists.Vector := Rules (Item);
      Listed   : constant Events.Event_List := Events.Since (Item, 0);
      Change   : Stores.Transaction;
      Wanted   : Name_Lists.Vector;

      --  The first action that failed, said once the rest are taken.
      Failed   : E.Error_Info := E.Success;

      --  The actions the rules give an event, in rule order, once each.
      procedure Actions_For (Kind : String) is
      begin
         for Line of In_Force loop
            declare
               Colon  : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
               Event  : constant String :=
                 (if Colon = 0 then "" else Trim (Line (Line'First .. Colon - 1)));
               Action : constant String :=
                 (if Colon = 0 then "" else Trim (Line (Colon + 1 .. Line'Last)));
            begin
               if (Event = "*" or else Event = Kind) and then Action /= ""
                 and then not Wanted.Contains (Action)
               then
                  Wanted.Append (Action);
               end if;
            end;
         end loop;
      end Actions_For;
   begin
      Result := (others => <>);
      Status := E.Success;

      --  Consume every event not yet acted on; the actions they call for
      --  are gathered and taken once, together.
      for Index in 1 .. Events.Length (Listed) loop
         declare
            Happened : constant Events.Event := Events.Element (Listed, Index);
            Fresh    : Boolean;
         begin
            Events.Consume (Item, Change, Consumer, To_String (Happened.Id), Fresh, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            if Fresh then
               Result.Events_Seen := Result.Events_Seen + 1;
               Actions_For (To_String (Happened.Kind_Word));
            end if;
         end;
      end loop;

      --  The events are acted on whatever becomes of the actions: kept
      --  consumed first, so that one action failing does not hold back
      --  every event after it.
      Stores.Commit (Item, Change, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      for Action of Wanted loop
         Result.Actions_Taken := Result.Actions_Taken + 1;
         if Action = "derive_tasks" then
            Tasks.Derive (Item, Change, Result.Derived, Status);
         elsif Action = "reevaluate_requirements" then
            Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
         elsif Action = "verify" then
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
         end if;
         --  Each action kept on its own; one that fails is dropped and
         --  said, and the others are still taken.
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         if E.Is_Error (Status) then
            Change := Stores.No_Changes;
            if E.Is_Ok (Failed) then
               Failed := Status;
            end if;
            Status := E.Success;
         end if;
      end loop;

      --  Readiness last, over what the actions left.
      if Wanted.Contains ("recompute_readiness") then
         Tasks.Recompute_Readiness (Item, Change, Result.Became_Ready, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
      end if;
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
      Taken    : Name_Lists.Vector;

      type Candidate is record
         Id        : Unbounded_String;
         Priority  : Natural := 0;
         Component : Unbounded_String;
      end record;
      package Candidate_Vectors is new Ada.Containers.Vectors (Positive, Candidate);
      Ready : Candidate_Vectors.Vector;
   begin
      for Id of Tasks.List (Item, "running") loop
         Running := Running + 1;
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
         begin
            Tasks.Definition (Item, Id, Defined, Read);
            Taken.Append (Records.Get (Defined, "component"));
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
               Ready.Append
                 (Candidate'(Id        => To_Unbounded_String (Id),
                   Priority  =>
                     (if Length (Text) in 1 .. 9
                        and then (for all C of To_String (Text) => C in '0' .. '9')
                      then Natural'Value (To_String (Text)) else 0),
                   Component => To_Unbounded_String (Records.Get (Defined, "component"))));
            end;
         end if;
      end loop;

      --  Most important first; of equals, the older.
      declare
         function Before (Left, Right : Candidate) return Boolean
         is (Left.Priority > Right.Priority
             or else (Left.Priority = Right.Priority and then Left.Id < Right.Id));
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
            elsif not Isolated and then Component /= "" and then Taken.Contains (Component)
            then
               Result.Held.Append
                 (To_String (Next.Id) & ": another task is writing " & Component);
            else
               Result.Start.Append (To_String (Next.Id));
               if Component /= "" then
                  Taken.Append (Component);
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
            Result.Append (Id & ": blocked, " & Records.Get (Value, "blocking_reasons"));
         end;
      end loop;
      declare
         use type Authority.Relation;
         Resolved : constant Authority.Resolution :=
           Authority.Resolve (Authority.Gather (Item));
      begin
         for Index in 1 .. Authority.Length (Resolved) loop
            if Authority.Element (Resolved, Index).Relation = Authority.Conflict then
               Result.Append
                 (To_String (Authority.Element (Resolved, Index).Governing.Subject)
                  & ": a conflict of authority to resolve");
            end if;
         end loop;
      end;
      return Result;
   end Needs_Judgment;

end Model_Runner.Framework.Orchestration;
