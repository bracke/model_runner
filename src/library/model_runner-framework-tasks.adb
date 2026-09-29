with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Tasks is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;

   State_Suffix    : constant String := ".state";
   Readiness_Name  : constant String := "readiness";
   Children_Reason : constant String := "waiting for its children: ";
   Deriver         : constant String := "task-derivation";

   --  The fields every task may have, whatever its kind.
   Core : constant array (1 .. 10) of access constant String :=
     [new String'("title"), new String'("kind"), new String'("component"),
      new String'("requirements"), new String'("depends_on"),
      new String'("priority"), new String'("acceptance"),
      new String'("parent"), new String'("notes"), new String'("permissions")];

   function Is_Core (Name : String) return Boolean
   is (for some Field of Core => Field.all = Name);

   function Is_Core_Field (Name : String) return Boolean renames Is_Core;

   --  Why a component cannot be named, where the configuration lists the
   --  project's components and it is not one of them; "" where it can.
   function Component_Problem (Item : Stores.Store; Component : String) return String;

   --  How a task of a kind waits on its children: parent_runs, or the
   --  default, parent_waits.
   function Coordination_Of (Item : Stores.Store; Kind : String) return String;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   --  The words of a comma- or line-separated list.
   function Split (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ',' | ASCII.LF then
            if Trim (Text (Start .. Index - 1)) /= "" then
               Result.Append (Trim (Text (Start .. Index - 1)));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split;

   function Joined (Items : Name_Lists.Vector; Between : String) return String is
      Result : Unbounded_String;
   begin
      for Item of Items loop
         if Result /= Null_Unbounded_String then
            Append (Result, Between);
         end if;
         Append (Result, Item);
      end loop;
      return To_String (Result);
   end Joined;

   function Config (Item : Stores.Store) return Records.Item is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Value, Status);
      return (if E.Is_Ok (Status) then Value else Records.Create ("", 1, "", 0));
   end Config;

   ---------------
   -- Lifecycle --
   ---------------

   function Core_Task_States return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for State of Name_Lists.Vector'
        (["candidate", "accepted", "running", "blocked", "verification", "complete",
          "failed", "cancelled", "rejected"])
      loop
         Result.Append (State);
      end loop;
      return Result;
   end Core_Task_States;

   function Forbiddable (From, To : String) return Boolean
   is ((From = "candidate" and then To = "rejected")
       or else (From = "accepted" and then To = "blocked")
       or else (From = "blocked" and then To = "failed")
       or else (From = "failed" and then To = "accepted")
       or else (From in "complete" | "cancelled" and then To = "accepted")
       or else (From = "rejected" and then To = "candidate"));

   --  A FROM -> TO line's two sides, or two empty ones.
   procedure Sides (Line : String; From, To : out Unbounded_String) is
      Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
   begin
      From := Null_Unbounded_String;
      To := Null_Unbounded_String;
      if Arrow > 0 then
         From := To_Unbounded_String (Trim (Line (Line'First .. Arrow - 1)));
         To := To_Unbounded_String (Trim (Line (Arrow + 2 .. Line'Last)));
      end if;
   end Sides;

   function Lifecycle_Of (Item : Stores.Store) return Transitions.Machine is
      Result   : Transitions.Machine := Transitions.Task_Machine;
      Settings : constant Records.Item := Config (Item);
      Known    : Name_Lists.Vector := Core_Task_States;
      Prefix   : constant String := "map.task.state.";
      From, To : Unbounded_String;
   begin
      for Index in 1 .. Records.Field_Count (Settings) loop
         declare
            Name : constant String := Records.Field_Name (Settings, Index);
         begin
            if Name'Length > Prefix'Length
              and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
              and then Records.Get (Settings, Name) /= ""
            then
               Known.Append (Name (Name'First + Prefix'Length .. Name'Last));
               Transitions.Add_State (Result, Name (Name'First + Prefix'Length .. Name'Last));

               --  A task can always be cancelled, whatever state it waits in.
               Transitions.Allow
                 (Result, Name (Name'First + Prefix'Length .. Name'Last), "cancelled");
            end if;
         end;
      end loop;
      for Line of Lines_Of (Records.Get (Settings, "set.task.transitions")) loop
         Sides (Line, From, To);
         if Known.Contains (To_String (From)) and then Known.Contains (To_String (To)) then
            Transitions.Allow (Result, To_String (From), To_String (To));
         end if;
      end loop;
      for Line of Lines_Of (Records.Get (Settings, "set.task.forbidden")) loop
         Sides (Line, From, To);
         if Forbiddable (To_String (From), To_String (To)) then
            Transitions.Forbid (Result, To_String (From), To_String (To));
         end if;
      end loop;
      return Result;
   end Lifecycle_Of;

   -----------
   -- Kinds --
   -----------

   function Kinds (Item : Stores.Store) return Name_Lists.Vector is
      Settings : constant Records.Item := Config (Item);
      Prefix   : constant String := "task_kind.";
      Result   : Name_Lists.Vector;
   begin
      for Index in 1 .. Records.Field_Count (Settings) loop
         declare
            Field : constant String := Records.Field_Name (Settings, Index);
         begin
            if Field'Length > Prefix'Length
              and then Field (Field'First .. Field'First + Prefix'Length - 1)
                         = Prefix
            then
               Result.Append (Field (Field'First + Prefix'Length .. Field'Last));
            end if;
         end;
      end loop;
      return Result;
   end Kinds;

   --  The fields a kind lists, each with whether it is required.
   procedure Kind_Fields
     (Item     : Stores.Store;
      Kind     : String;
      Required : out Name_Lists.Vector;
      Allowed  : out Name_Lists.Vector) is
   begin
      Required.Clear;
      Allowed.Clear;
      for Field of Split (Records.Get (Config (Item), "task_kind." & Kind)) loop
         if Field (Field'Last) = '?' then
            Allowed.Append (Field (Field'First .. Field'Last - 1));
         else
            Required.Append (Field);
            Allowed.Append (Field);
         end if;
      end loop;
   end Kind_Fields;

   ---------------------
   -- Required_Fields --
   ---------------------

   function Required_Fields
     (Item : Stores.Store;
      Kind : String) return Name_Lists.Vector
   is
      Required, Allowed : Name_Lists.Vector;
   begin
      Kind_Fields (Item, Kind, Required, Allowed);
      return Required;
   end Required_Fields;

   --------------------
   -- Allowed_Fields --
   --------------------

   function Allowed_Fields
     (Item : Stores.Store;
      Kind : String) return Name_Lists.Vector
   is
      Required, Allowed : Name_Lists.Vector;
   begin
      Kind_Fields (Item, Kind, Required, Allowed);
      return Allowed;
   end Allowed_Fields;

   --  A task's runtime record, as the transaction will leave it, or as the
   --  state has it at its next revision.
   procedure Runtime
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String;
      Value  : out Records.Item;
      Status : out E.Error_Info)
   is
      Staged : Boolean;
   begin
      Status := E.Success;
      Stores.Pending (Change, Tasks_Area, Id & State_Suffix, Value, Staged);
      if not Staged then
         Stores.Read (Item, Tasks_Area, Id & State_Suffix, Value, Status);
         if E.Is_Ok (Status) then
            Records.Set_Revision (Value, Records.Revision (Value) + 1);
         end if;
      end if;
   end Runtime;

   function Task_Exists
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String) return Boolean
   is
      Value  : Records.Item;
      Staged : Boolean;
   begin
      Stores.Pending (Change, Tasks_Area, Id, Value, Staged);
      return Staged or else Stores.Exists (Item, Tasks_Area, Id);
   end Task_Exists;

   ----------------
   -- Definition --
   ----------------

   procedure Definition
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Stores.Read (Item, Tasks_Area, Id, Value, Status);
   end Definition;

   --------------
   -- State_Of --
   --------------

   function State_Of (Item : Stores.Store; Id : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Tasks_Area, Id & State_Suffix, Value, Status);
      return (if E.Is_Ok (Status) then Records.Get (Value, "state") else "");
   end State_Of;

   --  The class of what created a task: an agent's identifier is an agent,
   --  and anything else is its first word.
   function Class_Of (Created_By : String) return String is
      Space : constant Natural := Ada.Strings.Fixed.Index (Created_By, " ");
      First : constant String :=
        (if Space = 0 then Created_By else Created_By (Created_By'First .. Space - 1));
   begin
      return (if First'Length > 3 and then First (First'First .. First'First + 2) = "AG-"
              then "agent" else First);
   end Class_Of;

   function Field_Schema (Item : Stores.Store; Name : String) return String
   is (if Is_Core (Name) then "" else Trim (Records.Get (Config (Item), "map.task_field." & Name)));

   -------------------
   -- Field_Problem --
   -------------------

   function Field_Problem (Item : Stores.Store; Name, Value : String) return String is
      Schema : constant String := Trim (Records.Get (Config (Item), "map.task_field." & Name));
      Space  : constant Natural := Ada.Strings.Fixed.Index (Schema, " ");
      Kind   : constant String := (if Space = 0 then Schema else Schema (Schema'First .. Space - 1));
      Rest   : constant String := (if Space = 0 then "" else Trim (Schema (Space + 1 .. Schema'Last)));
   begin
      if Is_Core (Name) or else Value = "" then
         return "";
      elsif Schema = "" then
         return "the field has no schema: map task_field." & Name & " says what it is";
      elsif Kind = "text" or else Kind = "list" then
         return "";
      elsif Kind = "number" then
         return (if Value'Length in 1 .. 9 and then (for all C of Value => C in '0' .. '9') then ""
                 else "a number is its digits, not " & Value);
      elsif Kind = "identifier" then
         return (if Identifiers.Is_Valid (Ada.Characters.Handling.To_Upper (Value)) then ""
                 else Value & " is not an identifier");
      elsif Kind = "path" then
         return (if Value (Value'First) not in '/' | '\' and then Ada.Strings.Fixed.Index (Value, "..") = 0
                 then "" else Value & " is not a path inside the project");
      elsif Kind = "choice" then
         for Choice of Split (Ada.Strings.Fixed.Translate
                                (Rest, Ada.Strings.Maps.To_Mapping ("|", ","))) loop
            if Choice = Value then
               return "";
            end if;
         end loop;
         return Value & " is none of " & Rest;
      end if;
      return "the schema of " & Name & " names no type this knows: " & Kind;
   end Field_Problem;

   --  Keep a definition as it stands before it is revised, under a name of
   --  its own -- TASK.rev-NNNNNN, an entity TASK-REV-NNNNNN -- so that no
   --  revision of what a task was is written over.
   procedure Keep_Revision
     (Change : in out Stores.Transaction;
      Id     : String;
      Value  : Records.Item)
   is
      Number : constant String := Trim (Natural'Image (Records.Revision (Value)));
      Padded : constant String := [1 .. Integer'Max (0, 6 - Number'Length) => '0'] & Number;
      Kept   : Records.Item :=
        Records.Create (Schemas.Task_Definition_Schema, 1, Id & "-REV-" & Padded, 1);
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         Records.Set (Kept, Records.Field_Name (Value, Index),
                      Records.Get (Value, Records.Field_Name (Value, Index)));
      end loop;
      Records.Set (Kept, "revision_of", Id);
      Stores.Put (Change, Tasks_Area, Id & ".rev-" & Padded, Kept);
   end Keep_Revision;

   ------------
   -- Create --
   ------------

   procedure Create
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Fields     : Field_Map;
      Created_By : String;
      Origin     : String;
      Id         : out Ada.Strings.Unbounded.Unbounded_String;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      function Given (Name : String) return String
      is (if Fields.Contains (Name) then Trim (Fields (Name)) else "");

      Kind     : constant String := Given ("kind");
      Known    : constant Name_Lists.Vector := Kinds (Item);
      Required : Name_Lists.Vector;
      Allowed  : Name_Lists.Vector;
      Missing  : Name_Lists.Vector;
      Event    : Unbounded_String;
      Linked   : Name_Lists.Vector := Split (Given ("depends_on"));
   begin
      Linked.Append (Split (Given ("parent")));
      Id := Null_Unbounded_String;
      Status := E.Success;

      if Kind = "" then
         --  None given is an input missing, and which it may be is said.
         Status := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Status, "name",
                     (if Known.Is_Empty then "kind"
                      else "kind (" & Joined (Known, ", ") & ")"));
         return;
      elsif not Known.Contains (Kind) then
         Status := E.Make (E.Framework_Task_Kind_Unknown);
         E.Add_Text (Status, "name", Kind);
         E.Add_Text
           (Status, "detail",
            (if Known.Is_Empty then "the project defines none"
             else "the project's are " & Joined (Known, ", ")));
         return;
      end if;

      Kind_Fields (Item, Kind, Required, Allowed);
      if Given ("title") = "" then
         Missing.Append ("title");
      end if;
      for Field of Required loop
         if Given (Field) = "" and then not Missing.Contains (Field) then
            Missing.Append (Field);
         end if;
      end loop;
      if not Missing.Is_Empty then
         Status := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Status, "name", Joined (Missing, ", "));
         return;
      end if;

      --  A field with no schema has no meaning, so it is refused rather
      --  than carried.
      for Position in Fields.Iterate loop
         declare
            Name : constant String := Configurations.Value_Maps.Key (Position);
         begin
            if not Is_Core (Name) and then not Allowed.Contains (Name) then
               Status := E.Make (E.Framework_Schema_Violation);
               E.Add_Text (Status, "name", Name);
               E.Add_Text
                 (Status, "detail", "no field of a " & Kind & " task is called so");
               return;
            elsif not Records.Is_Field_Name ("field." & Name) then
               Status := E.Make (E.Framework_Name_Invalid);
               E.Add_Text (Status, "value", Name);
               return;
            elsif Field_Problem (Item, Name, Trim (Configurations.Value_Maps.Element (Position))) /= ""
            then
               Status := E.Make (E.Framework_Schema_Violation);
               E.Add_Text (Status, "name", Name);
               E.Add_Text (Status, "detail",
                           Field_Problem (Item, Name, Trim (Configurations.Value_Maps.Element (Position))));
               return;
            elsif Name = "permissions" then
               --  A restriction that does not read is refused here, where it
               --  can still be put right, rather than left to narrow its
               --  agent to nothing.
               declare
                  Ignored : Model_Runner.Framework.Permissions.Permission_Set;
               begin
                  Model_Runner.Framework.Permissions.Restriction
                    (Configurations.Value_Maps.Element (Position), Ignored, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  A requirement or a component the project does not have is a
      --  value its field does not take: a form asks for it again.
      for Requirement of Split (Given ("requirements")) loop
         if not Stores.Exists (Item, Requirements_Area, Requirement) then
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", "requirements");
            E.Add_Text (Status, "detail", Requirement & " is not one of the project's requirements");
            return;
         end if;
      end loop;
      for Other of Linked loop
         if not Task_Exists (Item, Change, Other) then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Other);
            return;
         end if;
      end loop;

      if Component_Problem (Item, Given ("component")) /= "" then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "component");
         E.Add_Text (Status, "detail", Component_Problem (Item, Given ("component")));
         return;
      end if;

      declare
         Component : constant String := Given ("component");
         Key       : String :=
           Ada.Characters.Handling.To_Upper (Component);
      begin
         for Char of Key loop
            if Char not in 'A' .. 'Z' | '0' .. '9' then
               Char := '_';
            end if;
         end loop;
         Stores.Allocate_Identifier
           (Item, Change, "TASK",
            (if Component /= "" and then Identifiers.Is_Valid (Key) then Key
             else ""),
            Id, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;

      declare
         Task_Id : constant String := To_String (Id);
         Defined : Records.Item :=
           Records.Create (Schemas.Task_Definition_Schema, 1, Task_Id, 1);
         State   : Records.Item :=
           Records.Create
             (Schemas.Task_Runtime_Schema, 1, Task_Id & "-STATE", 1);
      begin
         for Position in Fields.Iterate loop
            declare
               Name  : constant String :=
                 Configurations.Value_Maps.Key (Position);
               Value : constant String :=
                 Trim (Configurations.Value_Maps.Element (Position));
            begin
               if Value /= "" then
                  Records.Set
                    (Defined, (if Is_Core (Name) then Name else "field." & Name),
                     (if Name in "requirements" | "depends_on"
                      then Joined (Split (Value), [1 => ASCII.LF])
                      else Value));
               end if;
            end;
         end loop;
         if not Records.Has (Defined, "acceptance") then
            Records.Set (Defined, "acceptance", "from_requirements");
         end if;
         Records.Set (Defined, "created_by", Created_By);
         Records.Set (Defined, "origin", Origin);
         Stores.Put (Change, Tasks_Area, Task_Id, Defined);

         Records.Set (State, "state", "candidate");
         Records.Set (State, "generation", "0");
         Stores.Put (Change, Tasks_Area, Task_Id & State_Suffix, State);

         Events.Emit
           (Item, Change, Events.Task_Candidate_Created, Task_Id,
            Given ("title"), Event, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         --  Accepted by the policy, when it accepts the task's class.
         declare
            Settings : constant Records.Item := Config (Item);
            Classes  : constant Name_Lists.Vector :=
              Split (Records.Get (Settings, "set.task.auto_accept"));
            Class    : constant String := Class_Of (Created_By);
         begin
            if Classes.Contains (Class) or else Classes.Contains (Kind)
              or else (Class = "requirement_derivation"
                       and then Records.Get (Settings, "scalar.task.auto_accept") = "true")
            then
               Move (Item, Change, Task_Id, "accepted", "", Status => Status,
                     Actor => "policy task.auto_accept " & Class);
            end if;
         end;
      end;
   end Create;

   function Ready_In
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String) return Readiness;

   --  The event a move is recorded by.
   function Event_For (Next : String) return Events.Event_Kind
   is (if Next = "accepted" then Events.Task_Accepted
       elsif Next = "rejected" then Events.Task_Rejected
       elsif Next = "running" then Events.Task_Started
       elsif Next = "blocked" then Events.Task_Blocked
       elsif Next = "verification" then Events.Task_Verification_Started
       elsif Next = "complete" then Events.Task_Completed
       elsif Next = "failed" then Events.Task_Failed
       elsif Next = "cancelled" then Events.Task_Cancelled
       elsif Next = "candidate" then Events.Task_Candidate_Created
       else Events.Task_Moved);

   ----------
   -- Move --
   ----------

   procedure Move
     (Item         : Stores.Store;
      Change       : in out Stores.Transaction;
      Id           : String;
      Next         : String;
      Reason       : String;
      Granted      : Transitions.Permissions := Transitions.Ordinary_Only;
      Gates_Passed : Boolean := False;
      Status       : out Model_Runner.Errors.Error_Info;
      Actor        : String := "")
   is
      Value : Records.Item;

      procedure Not_Ready (Detail : String) is
      begin
         Status := E.Make (E.Framework_Task_Not_Ready);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "detail", Detail);
      end Not_Ready;
   begin
      Runtime (Item, Change, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  Checked here, before the machine: a move the machine allows may
      --  still not be one this task can make now.
      Transitions.Check
        (Lifecycle_Of (Item), Id, Records.Get (Value, "state"), Next, Granted, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  A person does not make the harness's moves: work starts a task,
      --  and its checks take it to verification and completion; a task at
      --  work is stopped by cancelling it, which lets go of what it holds.
      --  A task waiting in verification -- its work not taken in, or its
      --  checks gone wrong -- a person may also fail or block.
      if Transitions.By_Person (Actor)
        and then (Next in "running" | "verification" | "complete"
                  or else (Records.Get (Value, "state") = "running"
                           and then Next /= "cancelled")
                  or else (Records.Get (Value, "state") = "verification"
                           and then Next not in "cancelled" | "failed" | "blocked"))
      then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", Records.Get (Value, "state"));
         E.Add_Text (Status, "expected", Next);
         E.Add_Text (Status, "detail",
                     (if Next in "running" | "verification" | "complete"
                      then "the harness makes this move: /work starts a task, and its checks"
                           & " take it to verification and completion"
                      else "a task at work is stopped by cancelling it"));
         return;
      end if;

      if Next = "running" then
         declare
            Now : constant Readiness := Ready_In (Item, Change, Id);
         begin
            if not Now.Ready then
               Not_Ready (Joined (Now.Reasons, "; "));
               return;
            end if;
         end;
      elsif Next = "complete" and then not Gates_Passed then
         Not_Ready ("its completion gates have not passed");
         return;
      end if;

      Transitions.Apply
        (Item, Change, Lifecycle_Of (Item), Tasks_Area, Id & State_Suffix, Next, Granted,
         Event_For (Next), Status, Actor, Subject => Id);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What the move changes beyond the state.
      Runtime (Item, Change, Id, Value, Status);
      if Next = "running" then
         declare
            Generation : constant String := Records.Get (Value, "generation");
         begin
            Records.Set
              (Value, "generation",
               Trim (Natural'Image
                       ((if Generation = "" then 0
                         else Natural'Value (Generation)) + 1)));
         end;
      elsif Next = "blocked" then
         Records.Set (Value, "blocking_reasons", Reason);
      elsif Next = "failed" then
         Records.Set (Value, "current_failure", Reason);
      elsif Next = "accepted" then
         Records.Remove (Value, "blocking_reasons");
         Records.Remove (Value, "current_failure");
         if Actor = "" and then Reason /= "" then
            Records.Set (Value, "accepted_by", Reason);
         end if;
      end if;
      Stores.Put (Change, Tasks_Area, Id & State_Suffix, Value);

      --  Accepted with children still open -- split while a candidate --
      --  its work is theirs, as a split of an accepted task makes it,
      --  unless the project lets it coordinate.
      if Next = "accepted" then
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
            Open    : Name_Lists.Vector;
         begin
            Definition (Item, Id, Defined, Read);
            for Child of Children (Item, Id) loop
               if State_Of (Item, Child) not in "complete" | "cancelled" | "rejected" then
                  Open.Append (Child);
               end if;
            end loop;
            if E.Is_Ok (Read) and then not Open.Is_Empty
              and then Coordination_Of (Item, Records.Get (Defined, "kind")) /= "parent_runs"
            then
               Move (Item, Change, Id, "blocked", Children_Reason & Joined (Open, ", "),
                     Status => Status);
            end if;
         end;
      end if;
   end Move;

   --  A task's state as the transaction will leave it.
   function State_In
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String) return String
   is
      Value  : Records.Item;
      Staged : Boolean;
   begin
      Stores.Pending (Change, Tasks_Area, Id & State_Suffix, Value, Staged);
      return (if Staged then Records.Get (Value, "state")
              else State_Of (Item, Id));
   end State_In;

   --  Readiness, as the transaction will leave it.
   function Ready_In
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String) return Readiness
   is
      Result  : Readiness;
      Defined : Records.Item;
      Status  : E.Error_Info;
      State   : constant String := State_In (Item, Change, Id);
   begin
      Definition (Item, Id, Defined, Status);
      if E.Is_Error (Status) then
         Result.Reasons.Append ("there is no such task");
         return Result;
      end if;

      if State /= "accepted" then
         Result.Reasons.Append ("it is " & State);
      end if;

      for Other of Split (Records.Get (Defined, "depends_on")) loop
         if State_In (Item, Change, Other) /= "complete" then
            Result.Reasons.Append
              ("it waits for " & Other & ", which is "
               & (if State_In (Item, Change, Other) = "" then "not there"
                  else State_In (Item, Change, Other)));
         end if;
      end loop;

      for Child of Children (Item, Id) loop
         if State_In (Item, Change, Child)
              not in "complete" | "cancelled" | "rejected"
         then
            Result.Reasons.Append
              ("its child " & Child & " is " & State_In (Item, Change, Child));
         end if;
      end loop;

      for Requirement of Split (Records.Get (Defined, "requirements")) loop
         declare
            Held : Intent.Entity;
         begin
            Intent.Read (Item, Intent.Requirement, Requirement, Held, Status);
            if E.Is_Error (Status) then
               Result.Reasons.Append (Requirement & " is not there");
            elsif To_String (Held.State) in "obsolete" | "rejected" | "candidate"
            then
               Result.Reasons.Append
                 (Requirement & " is " & To_String (Held.State));
            end if;
         end;
      end loop;

      declare
         Holder : constant String := Leases.Holder (Item, "task." & Id);
      begin
         if Holder /= "" then
            Result.Reasons.Append ("it is held by " & Holder);
         end if;
      end;

      --  Its component, where another agent is writing it in the project
      --  itself: two writers in one place is what isolation is for.
      declare
         Component : constant String := Records.Get (Defined, "component");
         Writer    : constant String :=
           (if Component = "" then "" else Leases.Holder (Item, Component_Lease (Component)));
      begin
         if Writer /= "" then
            Result.Reasons.Append
              ("its component " & Component & " is being written by " & Writer);
         end if;
      end;

      Result.Ready := Result.Reasons.Is_Empty;
      return Result;
   end Ready_In;

   -----------
   -- Ready --
   -----------

   function Ready (Item : Stores.Store; Id : String) return Readiness
   is (Ready_In (Item, Stores.No_Changes, Id));

   -------------------------
   -- Recompute_Readiness --
   -------------------------

   procedure Recompute_Readiness
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Became : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Cache   : Records.Item;
      Changed : Boolean := False;
      Event   : Unbounded_String;
   begin
      Became.Clear;
      Status := E.Success;

      --  A parent waiting on its children goes back to work once they are
      --  all done.
      for Id of List (Item, "blocked") loop
         declare
            Value : Records.Item;
            Held  : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & State_Suffix, Value, Held);
            if E.Is_Ok (Held)
              and then Ada.Strings.Fixed.Index
                         (Records.Get (Value, "blocking_reasons"),
                          Children_Reason) = 1
              and then (for all Child of Children (Item, Id) =>
                          State_Of (Item, Child) in "complete" | "cancelled")
            then
               Move (Item, Change, Id, "accepted", "its children are done",
                     Status => Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;
      end loop;

      if Stores.Exists (Item, Indexes_Area, Readiness_Name) then
         Stores.Read (Item, Indexes_Area, Readiness_Name, Cache, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Cache, Records.Revision (Cache) + 1);
      else
         Cache := Records.Create (Schemas.Readiness_Schema, 1, "READINESS", 1);
      end if;

      for Id of List (Item) loop
         declare
            Now  : constant Boolean := Ready_In (Item, Change, Id).Ready;
            Held : constant String := Records.Get (Cache, "task." & Id);
         begin
            if Now and then Held /= "ready" then
               Records.Set (Cache, "task." & Id, "ready");
               Changed := True;
               Became.Append (Id);
               Events.Emit
                 (Item, Change, Events.Task_Became_Ready, Id, "", Event, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            elsif not Now and then Held /= "waiting" then
               Records.Set (Cache, "task." & Id, "waiting");
               Changed := True;
            end if;
         end;
      end loop;

      if Changed then
         Stores.Put (Change, Indexes_Area, Readiness_Name, Cache);
      end if;
   end Recompute_Readiness;

   -----------------------
   -- Block_On_Children --
   -----------------------

   procedure Block_On_Children
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Waiting : constant Name_Lists.Vector := Children (Item, Parent);
   begin
      if Waiting.Is_Empty then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "the children of " & Parent);
         return;
      end if;
      Move (Item, Change, Parent, "blocked",
            Children_Reason & Joined (Waiting, ", "), Status => Status);
   end Block_On_Children;

   ----------
   -- List --
   ----------

   function List
     (Item  : Stores.Store;
      State : String := "") return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Tasks_Area) loop
         if Ada.Strings.Fixed.Index (Name, ".") = 0
           and then (State = "" or else State_Of (Item, Name) = State)
         then
            Result.Append (Name);
         end if;
      end loop;
      return Result;
   end List;

   --------------
   -- Children --
   --------------

   function Children
     (Item   : Stores.Store;
      Parent : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Id of List (Item) loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Definition (Item, Id, Value, Status);
            if E.Is_Ok (Status) and then Records.Get (Value, "parent") = Parent
            then
               Result.Append (Id);
            end if;
         end;
      end loop;
      return Result;
   end Children;

   ---------------
   -- Effective --
   ---------------

   procedure Effective
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Defined  : Records.Item;
      State    : Records.Item;
      Settings : constant Records.Item := Config (Item);
   begin
      Value := Records.Create ("task.effective", 1, Id, 1);
      Definition (Item, Id, Defined, Status);
      if E.Is_Ok (Status) then
         Stores.Read (Item, Tasks_Area, Id & State_Suffix, State, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      for Index in 1 .. Records.Field_Count (Defined) loop
         Records.Set
           (Value, "definition." & Records.Field_Name (Defined, Index),
            Records.Get (Defined, Records.Field_Name (Defined, Index)));
      end loop;
      Records.Set
        (Value, "definition.revision",
         Trim (Natural'Image (Records.Revision (Defined))));
      Records.Set (Value, "runtime.state", Records.Get (State, "state"));
      Records.Set (Value, "runtime.generation", Records.Get (State, "generation"));
      for Field of Name_Lists.Vector'
        (["moved_by", "accepted_by", "rejected_by", "blocking_reasons", "current_failure"])
      loop
         if Records.Get (State, Field) /= "" then
            Records.Set (Value, "runtime." & Field, Records.Get (State, Field));
         end if;
      end loop;

      declare
         Now : constant Readiness := Ready (Item, Id);
      begin
         Records.Set (Value, "ready", (if Now.Ready then "true" else "false"));
         Records.Set
           (Value, "blocked_by", Joined (Now.Reasons, [1 => ASCII.LF]));
      end;

      --  The revision of each requirement served, which is what evidence
      --  and traceability name.
      for Requirement of Split (Records.Get (Defined, "requirements")) loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
            if E.Is_Ok (Read) then
               Records.Set
                 (Value, "requirement." & Requirement,
                  "revision" & Natural'Image (Held.Revision) & ", "
                  & To_String (Held.Meaning));
            end if;
         end;
      end loop;

      for Decision of Intent.Applicable_Decisions
                        (Item, Records.Get (Defined, "component"))
      loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Decision, Decision, Held, Read);
            Records.Set
              (Value, "decision." & Decision,
               "revision" & Natural'Image (Held.Revision));
         end;
      end loop;

      declare
         Kind    : constant String := Records.Get (Defined, "kind");
         Profile : constant String :=
           Records.Get (Settings, "scalar.task.profile." & Kind);
      begin
         Records.Set
           (Value, "kind.fields", Records.Get (Settings, "task_kind." & Kind));
         if Profile /= "" then
            Records.Set
              (Value, "verification_profile",
               Profile & ": " & Records.Get (Settings, "profile." & Profile));
         end if;
      end;

      --  What governs the work: each statement that stands above the
      --  configuration -- instructions, decisions, specifications -- and
      --  each baseline that governs what nothing higher speaks to, and
      --  every explicit override and conflict, whatever its standing.
      declare
         use type Authority.Level;
         use type Authority.Relation;
         Resolved : constant Authority.Resolution :=
           Authority.Resolve (Authority.Gather (Item));
         function Word (Standing : Authority.Level) return String
         is (Ada.Characters.Handling.To_Lower (Authority.Level'Image (Standing)));
      begin
         for Index in 1 .. Authority.Governing_Count (Resolved) loop
            declare
               One : constant Authority.Statement := Authority.Governing_At (Resolved, Index);
            begin
               if One.Standing <= Authority.Project_Specification
                 or else One.Standing in Authority.Project_Baseline | Authority.Language_Baseline
               then
                  Records.Set
                    (Value, "authority." & To_String (One.Subject),
                     Word (One.Standing) & " " & To_String (One.Source)
                     & ": " & To_String (One.Value));
               end if;
            end;
         end loop;
         for Index in 1 .. Authority.Length (Resolved) loop
            declare
               One     : constant Authority.Standing_Of := Authority.Element (Resolved, Index);
               Subject : constant String := To_String (One.Governing.Subject);
            begin
               if One.Relation = Authority.Explicit_Override then
                  Records.Set
                    (Value, "override." & Subject,
                     To_String (One.Governing.Source) & " overrides "
                     & To_String (One.Other.Source));
               elsif One.Relation = Authority.Conflict then
                  Records.Set
                    (Value, "conflict." & Subject,
                     To_String (One.Governing.Source) & " and " & To_String (One.Other.Source)
                     & " disagree, and nothing says which holds");
               end if;
            end;
         end loop;
      end;

      --  What an agent on it may do, when it must stop, where it writes, and
      --  what it must pass to complete.
      declare
         Kind : constant String := Records.Get (Defined, "kind");
         function Or_Else (First, Second, Last : String) return String
         is (if First /= "" then First elsif Second /= "" then Second else Last);
      begin
         --  On one line, as a task's permissions field writes them: each
         --  capability and its constraints, a semicolon between.
         Records.Set
           (Value, "permissions",
            Joined (Lines_Of (Model_Runner.Framework.Permissions.Image
                                (Model_Runner.Framework.Permissions.Effective
                                   (Item, Kind, "worker",
                                    Task_Level => Records.Get (Defined, "permissions")))),
                    "; "));
         Records.Set
           (Value, "workspace_policy",
            Or_Else (Kind_Policy (Item, Kind, "isolation"),
                     Records.Get (Settings, "scalar.work.isolation"), "project"));
         Records.Set
           (Value, "resource.token_budget",
            Or_Else (Kind_Policy (Item, Kind, "token_budget"),
                     Records.Get (Settings, "scalar.agents.token_budget"), "200000"));
         Records.Set
           (Value, "resource.max_steps",
            Or_Else (Kind_Policy (Item, Kind, "max_steps"),
                     Records.Get (Settings, "scalar.agents.max_steps"), "24"));
         Records.Set (Value, "gates", Joined (Gate_Names (Item, Kind), ", "));
      end;

      Records.Set (Value, "fingerprint", Records.Fingerprint_Of (Value));
   end Effective;

   ------------
   -- Derive --
   ------------

   procedure Derive
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Made   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Settings  : constant Records.Item := Config (Item);
      Kind      : constant String :=
        (if Records.Get (Settings, "scalar.task.derived_kind") /= ""
         then Records.Get (Settings, "scalar.task.derived_kind")
         else "implementation");
      Listed    : constant Events.Event_List := Events.Since (Item, 0);

      --  The component that is the whole project: the first the
      --  configuration lists, else the project's name.
      Project_Component : constant String :=
        (if not Split (Records.Get (Settings, "set.components")).Is_Empty
         then Split (Records.Get (Settings, "set.components")).First_Element
         else Records.Get (Settings, "input.project_name"));

      --  The keys of the derivations already made.
      Done : Name_Lists.Vector;

      use type Events.Event_Kind;
   begin
      Made.Clear;
      Status := E.Success;

      --  Nothing is derived for a project whose configuration has no kind
      --  of task to derive.
      if not Kinds (Item).Contains (Kind) then
         return;
      end if;

      for Id of List (Item) loop
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            Definition (Item, Id, Value, Read);
            if E.Is_Ok (Read) and then Records.Get (Value, "derivation_key") /= ""
            then
               Done.Append (Records.Get (Value, "derivation_key"));
            end if;
         end;
      end loop;

      --  Driven by the events that accept and revise requirements, each
      --  consumed once; the derivation key is the second guard, so a
      --  requirement accepted before anybody consumed its event is not
      --  derived twice either.
      for Index in 1 .. Events.Length (Listed) loop
         declare
            Happened : constant Events.Event := Events.Element (Listed, Index);
            Fresh    : Boolean;
         begin
            if Happened.Known
              and then Happened.Kind in Events.Requirement_Accepted
                                      | Events.Requirement_Revised
            then
               Events.Consume
                 (Item, Change, Deriver, To_String (Happened.Id), Fresh, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               declare
                  Requirement : constant String := To_String (Happened.Subject);
                  Held        : Intent.Entity;
                  Read        : E.Error_Info;
               begin
                  Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
                  if Fresh and then E.Is_Ok (Read)
                    and then To_String (Held.State) = "accepted"
                  then
                     declare
                        Key    : constant String :=
                          "derive:" & Requirement & "#" & To_String (Held.Meaning);
                        Fields : Field_Map;
                        Id     : Unbounded_String;
                        Value  : Records.Item;
                        Staged : Boolean;
                        --  A task already derived from an earlier meaning of
                        --  it that nobody has started: the new meaning is its
                        --  work now, not another task beside it.
                        Earlier : Unbounded_String;
                     begin
                        if not Done.Contains (Key) then
                           for Other of List (Item) loop
                              declare
                                 Defined : Records.Item;
                                 Got     : E.Error_Info;
                                 Stem    : constant String := "derive:" & Requirement & "#";
                                 Held_Key : Unbounded_String;
                              begin
                                 Definition (Item, Other, Defined, Got);
                                 Held_Key := To_Unbounded_String (Records.Get (Defined, "derivation_key"));
                                 if E.Is_Ok (Got) and then Length (Held_Key) > Stem'Length
                                   and then Slice (Held_Key, 1, Stem'Length) = Stem
                                   and then State_In (Item, Change, Other)
                                              in "candidate" | "accepted" | "blocked"
                                 then
                                    Earlier := To_Unbounded_String (Other);
                                 end if;
                              end;
                           end loop;
                        end if;
                        if not Done.Contains (Key) and then Earlier /= Null_Unbounded_String then
                           Stores.Pending (Change, Tasks_Area, To_String (Earlier), Value, Staged);
                           if not Staged then
                              Definition (Item, To_String (Earlier), Value, Status);
                              if E.Is_Error (Status) then
                                 return;
                              end if;
                              Keep_Revision (Change, To_String (Earlier), Value);
                              Records.Set_Revision (Value, Records.Revision (Value) + 1);
                           end if;
                           Records.Set (Value, "derivation_key", Key);
                           Records.Set (Value, "origin",
                                        Requirement & "@" & Trim (Natural'Image (Held.Revision)));
                           Stores.Put (Change, Tasks_Area, To_String (Earlier), Value);
                           Done.Append (Key);
                        elsif not Done.Contains (Key) then
                           Fields.Include ("title", "Implement " & Requirement);
                           Fields.Include ("kind", Kind);
                           Fields.Include ("requirements", Requirement);
                           if To_String (Held.Scope) /= "project" then
                              Fields.Include ("component", To_String (Held.Scope));
                           elsif Project_Component /= ""
                             and then Required_Fields (Item, Kind).Contains ("component")
                           then
                              --  A requirement of the whole project, for a kind
                              --  that needs a component: the project's own.
                              Fields.Include ("component", Project_Component);
                           end if;
                           Create
                             (Item, Change, Fields, "requirement_derivation",
                              Requirement & "@"
                              & Trim (Natural'Image (Held.Revision)),
                              Id, Status);
                           if E.Is_Error (Status) then
                              return;
                           end if;

                           Stores.Pending
                             (Change, Tasks_Area, To_String (Id), Value, Staged);
                           Records.Set (Value, "derivation_key", Key);
                           Stores.Put (Change, Tasks_Area, To_String (Id), Value);
                           Done.Append (Key);
                           Made.Append (To_String (Id));

                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Derive;

   --  The tasks a task waits for, as the transaction will leave it.
   function Waits_For
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String;
      Field  : String := "depends_on") return Name_Lists.Vector
   is
      Value  : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Tasks_Area, Id, Value, Staged);
      if not Staged then
         Definition (Item, Id, Value, Status);
         if E.Is_Error (Status) then
            return Name_Lists.Empty_Vector;
         end if;
      end if;
      return Split (Records.Get (Value, Field));
   end Waits_For;

   --  Whether following a field from one task reaches another.
   function Reaches
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      From   : String;
      Target : String;
      Field  : String) return Boolean
   is
      --  What a task waits for along a field; "waits" is everything it
      --  waits for -- what it depends on, and, a parent, its children.
      function Along (Name : String) return Name_Lists.Vector is
      begin
         if Field /= "waits" then
            return Waits_For (Item, Change, Name, Field);
         end if;
         declare
            Result : Name_Lists.Vector := Waits_For (Item, Change, Name, "depends_on");
         begin
            Result.Append (Children (Item, Name));
            return Result;
         end;
      end Along;

      Seen  : Name_Lists.Vector;
      Queue : Name_Lists.Vector := Along (From);
   begin
      while not Queue.Is_Empty loop
         declare
            Next : constant String := Queue.First_Element;
         begin
            Queue.Delete_First;
            if Next = Target then
               return True;
            elsif not Seen.Contains (Next) then
               Seen.Append (Next);
               Queue.Append (Along (Next));
            end if;
         end;
      end loop;
      return False;
   end Reaches;

   --------------------
   -- Add_Dependency --
   --------------------

   procedure Add_Dependency
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      On     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
      type Text is access constant String;
      Pair   : constant array (1 .. 2) of Text :=
        [new String'(Id), new String'(On)];
   begin
      Status := E.Success;
      for Name of Pair loop
         if not Task_Exists (Item, Change, Name.all) then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Name.all);
            return;
         end if;
      end loop;

      --  Waiting counts the children a parent waits for too: a child that
      --  waits for its own parent would wait for ever.
      if On = Id or else Reaches (Item, Change, On, Id, "waits") then
         Status := E.Make (E.Framework_Dependency_Cycle);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "detail", On & " already waits for it");
         return;
      end if;

      Stores.Pending (Change, Tasks_Area, Id, Value, Staged);
      if not Staged then
         Definition (Item, Id, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;

      declare
         Held : Name_Lists.Vector := Split (Records.Get (Value, "depends_on"));
      begin
         if not Held.Contains (On) then
            Held.Append (On);
            Records.Set (Value, "depends_on", Joined (Held, [1 => ASCII.LF]));
            Stores.Put (Change, Tasks_Area, Id, Value);
         end if;
      end;
   end Add_Dependency;

   -----------------------
   -- Component_Problem --
   -----------------------

   function Components (Item : Stores.Store) return Name_Lists.Vector is
      Settings : Records.Item;
      Status   : E.Error_Info;
   begin
      Configurations.Read (Item, Settings, Status);
      declare
         Listed : Name_Lists.Vector := Split (Records.Get (Settings, "set.components"));
      begin
         --  A project that lists no components is one: the project itself,
         --  by its name.
         if Listed.Is_Empty and then Records.Get (Settings, "input.project_name") /= "" then
            Listed.Append (Records.Get (Settings, "input.project_name"));
         end if;
         return Listed;
      end;
   end Components;

   function Component_Problem (Item : Stores.Store; Component : String) return String is
   begin
      declare
         Listed : constant Name_Lists.Vector := Components (Item);
      begin
         if Component = "" or else Listed.Is_Empty or else Listed.Contains (Component) then
            return "";
         end if;
         return Component & " is not one of the project's components: " & Joined (Listed, ", ");
      end;
   end Component_Problem;

   function Coordination_Of (Item : Stores.Store; Kind : String) return String
   is (if Kind_Policy (Item, Kind, "coordination") /= ""
       then Kind_Policy (Item, Kind, "coordination")
       else Records.Get (Config (Item), "scalar.task.coordination"));

   -----------------
   -- Kind_Policy --
   -----------------

   function Kind_Policy (Item : Stores.Store; Kind, Name : String) return String
   is (Records.Get (Config (Item), "scalar.task." & Name & "." & Kind));

   ----------------
   -- Gate_Names --
   ----------------

   function Gate_Names (Item : Stores.Store; Kind : String) return Name_Lists.Vector is
      Settings : constant Records.Item := Config (Item);
      Result   : Name_Lists.Vector := Split (Records.Get (Settings, "set.task.gates." & Kind));
   begin
      if Result.Is_Empty then
         Result := Split (Records.Get (Settings, "set.task.gates"));
      end if;
      if Result.Is_Empty then
         Result.Append ("verification");
         Result.Append ("children");
         Result.Append ("no_blocking_issue");
         Result.Append ("integration");
      end if;
      return Result;
   end Gate_Names;

   ------------
   -- Revise --
   ------------

   procedure Revise
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Fields : Field_Map;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
      Now    : constant String := State_Of (Item, Id);
      Event  : Unbounded_String;
   begin
      Status := E.Success;
      --  Not while it is being worked or once it has ended; a state the
      --  project defined is one it waits in, and it may be revised there.
      if Now = "" then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Id);
         return;
      elsif Now in "running" | "verification" | "complete" | "cancelled" | "rejected" then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", Now);
         E.Add_Text (Status, "expected", "a state it is not worked in");
         E.Add_Text (Status, "detail", "a task is revised only while it is not being worked");
         return;
      end if;

      Stores.Pending (Change, Tasks_Area, Id, Value, Staged);
      if not Staged then
         Definition (Item, Id, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Keep_Revision (Change, Id, Value);
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;

      declare
         Kind    : constant String := Records.Get (Value, "kind");
         Allowed : constant Name_Lists.Vector := Allowed_Fields (Item, Kind);
      begin
         for Position in Fields.Iterate loop
            declare
               Name  : constant String := Configurations.Value_Maps.Key (Position);
               Given : constant String := Trim (Configurations.Value_Maps.Element (Position));
               Field : constant String := (if Is_Core (Name) then Name else "field." & Name);
            begin
               if Name in "kind" | "parent" | "depends_on" then
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", Name);
                  E.Add_Text (Status, "detail", "it is not revised; "
                              & (if Name = "kind" then "make a task of the other kind"
                                 elsif Name = "parent" then "split the parent instead"
                                 else "add a dependency instead"));
                  return;
               elsif not Is_Core (Name) and then not Allowed.Contains (Name) then
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", Name);
                  E.Add_Text (Status, "detail", "no field of a " & Kind & " task is called so");
                  return;
               elsif Field_Problem (Item, Name, Given) /= "" then
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", Name);
                  E.Add_Text (Status, "detail", Field_Problem (Item, Name, Given));
                  return;
               elsif Name = "title" and then Given = "" then
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", Name);
                  E.Add_Text (Status, "detail", "a task keeps a title");
                  return;
               elsif Name = "permissions" and then Given /= "" then
                  declare
                     Ignored : Model_Runner.Framework.Permissions.Permission_Set;
                  begin
                     Model_Runner.Framework.Permissions.Restriction (Given, Ignored, Status);
                     if E.Is_Error (Status) then
                        return;
                     end if;
                  end;
               elsif Name = "component" and then Component_Problem (Item, Given) /= "" then
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", "component");
                  E.Add_Text (Status, "detail", Component_Problem (Item, Given));
                  return;
               elsif Name = "requirements" then
                  for Requirement of Split (Given) loop
                     if not Stores.Exists (Item, Requirements_Area, Requirement) then
                        Status := E.Make (E.Framework_Schema_Violation);
                        E.Add_Text (Status, "name", "requirements");
                        E.Add_Text (Status, "detail",
                                    Requirement & " is not one of the project's requirements");
                        return;
                     end if;
                  end loop;
               end if;

               if Given = "" then
                  Records.Remove (Value, Field);
               else
                  Records.Set
                    (Value, Field,
                     (if Name = "requirements" then Joined (Split (Given), [1 => ASCII.LF])
                      else Given));
               end if;
            end;
         end loop;
      end;

      Stores.Put (Change, Tasks_Area, Id, Value);
      Events.Emit (Item, Change, Events.Task_Revised, Id,
                   "revision" & Natural'Image (Records.Revision (Value)), Event, Status);
   end Revise;

   ---------------
   -- Decompose --
   ---------------

   procedure Decompose
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Titles : Name_Lists.Vector;
      Made   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Defined : Records.Item;
   begin
      Made.Clear;
      Definition (Item, Parent, Defined, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Kind : constant String := Records.Get (Defined, "kind");
      begin
         for Title of Titles loop
            declare
               Fields : Field_Map;
               Child  : Unbounded_String;
            begin
               Fields.Include ("title", Title);
               Fields.Include ("kind", Kind);
               Fields.Include ("parent", Parent);
               if Records.Get (Defined, "component") /= "" then
                  Fields.Include ("component", Records.Get (Defined, "component"));
               end if;
               Create (Item, Change, Fields, "user", "decomposition of " & Parent, Child, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Made.Append (To_String (Child));
            end;
         end loop;

         --  Its work is theirs now, unless the project lets it coordinate.
         declare
            Coordination : constant String := Coordination_Of (Item, Kind);
         begin
            if Coordination /= "parent_runs" and then State_Of (Item, Parent) = "accepted"
              and then not Made.Is_Empty
            then
               Move (Item, Change, Parent, "blocked",
                     Children_Reason & Joined (Made, ", "), Status => Status);
            end if;
         end;
      end;
   end Decompose;

   ------------
   -- Cycles --
   ------------

   function Cycles (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Id of List (Item) loop
         if Reaches (Item, Stores.No_Changes, Id, Id, "waits")
           or else Reaches (Item, Stores.No_Changes, Id, Id, "parent")
         then
            Result.Append (Id);
         end if;
      end loop;
      return Result;
   end Cycles;

end Model_Runner.Framework.Tasks;
