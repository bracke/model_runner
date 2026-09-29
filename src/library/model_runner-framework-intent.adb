with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Intent is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;

   History_Mark : constant String := ".rev-";

   function Area_Of (Kind : Intent_Kind) return Area
   is (case Kind is
         when Specification => Specs_Area,
         when Requirement   => Requirements_Area,
         when Decision      => Decisions_Area);

   function Kind_Word (Kind : Intent_Kind) return String
   is (Ada.Characters.Handling.To_Lower (Intent_Kind'Image (Kind)));

   function Link_Field (Relation : Link_Kind) return String
   is ("links."
       & Ada.Characters.Handling.To_Lower (Link_Kind'Image (Relation)));

   function Six (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
      Plain : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      return [1 .. Integer'Max (0, 6 - Plain'Length) => '0'] & Plain;
   end Six;

   --  The lines of a text, empty ones left out.
   function Split_Lines (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split_Lines;

   function Contains (Text, Part : String) return Boolean
   is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Meaning_Of (Text, Criteria : String) return String
   is (Fingerprint (Text & ASCII.LF & ASCII.LF & Criteria));

   ---------------
   -- Namespace --
   ---------------

   function Namespace (Kind : Intent_Kind) return String
   is (case Kind is
         when Specification => "SPEC",
         when Requirement   => "REQ",
         when Decision      => "DEC");

   -----------------
   -- First_State --
   -----------------

   function First_State (Kind : Intent_Kind) return String
   is (if Kind = Decision then "proposed" else "candidate");

   ----------------
   -- Machine_Of --
   ----------------

   function Machine_Of (Kind : Intent_Kind) return Transitions.Machine is
      use Transitions;
      Result : Machine;
   begin
      case Kind is
         when Specification | Decision =>
            declare
               First : constant String := First_State (Kind);
            begin
               Allow (Result, First, "accepted");
               Allow (Result, First, "rejected");
               Allow (Result, "rejected", First, Reconsideration);
               Allow (Result, "accepted", "superseded");
            end;

         when Requirement =>
            Allow (Result, "candidate", "accepted");
            Allow (Result, "candidate", "rejected");
            Allow (Result, "rejected", "candidate", Reconsideration);

            Allow (Result, "accepted", "implemented");
            Allow (Result, "accepted", "blocked");
            Allow (Result, "accepted", "obsolete");

            Allow (Result, "blocked", "accepted");
            Allow (Result, "blocked", "obsolete");

            Allow (Result, "implemented", "verified");
            Allow (Result, "implemented", "blocked");
            Allow (Result, "implemented", "obsolete");

            Allow (Result, "verified", "obsolete");

            --  What a revision's new meaning undoes, which nobody asks
            --  for directly.
            Allow (Result, "implemented", "accepted", Invalidation);
            Allow (Result, "verified", "implemented", Invalidation);
            Allow (Result, "verified", "accepted", Invalidation);
      end case;
      return Result;
   end Machine_Of;

   -----------------------------
   -- Core_Requirement_States --
   -----------------------------

   function Core_Requirement_States return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for State of Name_Lists.Vector'
        (["candidate", "accepted", "implemented", "verified", "blocked", "obsolete", "rejected"])
      loop
         Result.Append (State);
      end loop;
      return Result;
   end Core_Requirement_States;

   ------------------
   -- Lifecycle_Of --
   ------------------

   function Lifecycle_Of
     (Item : Stores.Store;
      Kind : Intent_Kind) return Transitions.Machine
   is
      Result : Transitions.Machine := Machine_Of (Kind);
      Config : Records.Item;
      Read   : E.Error_Info;
      Prefix : constant String := "map.requirement.state.";
      Known  : Name_Lists.Vector := Core_Requirement_States;
   begin
      if Kind /= Requirement then
         return Result;
      end if;
      Configurations.Read (Item, Config, Read);
      if E.Is_Error (Read) then
         return Result;
      end if;
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name : constant String := Records.Field_Name (Config, Index);
         begin
            if Name'Length > Prefix'Length
              and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
              and then Records.Get (Config, Name) /= ""
            then
               Known.Append (Name (Name'First + Prefix'Length .. Name'Last));
               Transitions.Add_State (Result, Name (Name'First + Prefix'Length .. Name'Last));
            end if;
         end;
      end loop;
      for Line of Lines_Of (Records.Get (Config, "set.requirement.transitions")) loop
         declare
            Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
            From  : constant String :=
              (if Arrow = 0 then "" else Ada.Strings.Fixed.Trim (Line (Line'First .. Arrow - 1),
                                                                  Ada.Strings.Both));
            To    : constant String :=
              (if Arrow = 0 then "" else Ada.Strings.Fixed.Trim (Line (Arrow + 2 .. Line'Last),
                                                                  Ada.Strings.Both));
         begin
            --  Only between states whose meaning is known.
            if Known.Contains (From) and then Known.Contains (To) then
               Transitions.Allow (Result, From, To);
            end if;
         end;
      end loop;
      return Result;
   end Lifecycle_Of;

   --  The event a move is recorded by.
   function Event_For
     (Kind : Intent_Kind;
      Next : String) return Events.Event_Kind
   is
      use Events;
   begin
      case Kind is
         when Specification =>
            return (if Next = "accepted" then Specification_Accepted
                    elsif Next = "superseded" then Specification_Superseded
                    elsif Next = "rejected" then Specification_Rejected
                    else Specification_Reconsidered);
         when Decision =>
            return (if Next = "accepted" then Decision_Accepted
                    elsif Next = "superseded" then Decision_Superseded
                    elsif Next = "rejected" then Decision_Rejected
                    else Decision_Reconsidered);
         when Requirement =>
            return (if Next = "accepted" then Requirement_Accepted
                    elsif Next = "implemented" then Requirement_Implemented
                    elsif Next = "verified" then Requirement_Verified
                    elsif Next = "blocked" then Requirement_Blocked
                    elsif Next = "obsolete" then Requirement_Obsoleted
                    elsif Next = "rejected" then Requirement_Rejected
                    elsif Next = "candidate" then Requirement_Reconsidered
                    else Requirement_Moved);
      end case;
   end Event_For;

   --  The record a change will write for an entity, or the one there is,
   --  at its next revision.
   procedure Current
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Kind   : Intent_Kind;
      Id     : String;
      Value  : out Records.Item;
      Status : out E.Error_Info)
   is
      Staged : Boolean;
   begin
      Status := E.Success;
      Stores.Pending (Change, Area_Of (Kind), Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Area_Of (Kind), Id, Value, Status);
         if E.Is_Ok (Status) then
            Records.Set_Revision (Value, Records.Revision (Value) + 1);
         end if;
      end if;
   end Current;

   --  Keep the revision as the project holds it, under a name of its own,
   --  before anything changes it: whatever names ID@N -- evidence, the
   --  traceability graph -- can read what N was. Kept once.
   procedure Keep_Earlier
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Kind   : Intent_Kind;
      Id     : String)
   is
      Before : Records.Item;
      Read   : E.Error_Info;
      Held   : Records.Item;
      Staged : Boolean;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Before, Read);
      if E.Is_Error (Read) then
         return;
      end if;
      declare
         Earlier : constant Natural := Records.Revision (Before);
         Name    : constant String := Id & History_Mark & Six (Earlier);
         Kept    : Records.Item :=
           Records.Create (Schemas.Intent_Schema, 1, Id & "-REV-" & Six (Earlier), 1);
      begin
         Stores.Pending (Change, Area_Of (Kind), Name, Held, Staged);
         if Staged or else Stores.Exists (Item, Area_Of (Kind), Name) then
            return;
         end if;
         for Field_At in 1 .. Records.Field_Count (Before) loop
            Records.Set (Kept, Records.Field_Name (Before, Field_At),
                         Records.Get (Before, Records.Field_Name (Before, Field_At)));
         end loop;
         Records.Set (Kept, "revision_of", Id);
         Stores.Put (Change, Area_Of (Kind), Name, Kept);
      end;
   end Keep_Earlier;

   -------------
   -- Propose --
   -------------

   procedure Propose
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Kind       : Intent_Kind;
      Key        : String;
      Title      : String;
      Text       : String;
      Criteria   : String;
      Source     : String;
      Provenance : String;
      Scope      : String;
      Id         : out Ada.Strings.Unbounded.Unbounded_String;
      Status     : out Model_Runner.Errors.Error_Info;
      Given      : String := "")
   is
      Event : Unbounded_String;

      --  Whether something has an identifier already, in the state or in
      --  this transaction.
      function Taken (Name : String) return Boolean is
         Held   : Records.Item;
         Staged : Boolean;
      begin
         Stores.Pending (Change, Area_Of (Kind), Name, Held, Staged);
         return Staged or else Stores.Exists (Item, Area_Of (Kind), Name);
      end Taken;
   begin
      Status := E.Success;
      if Given /= "" and then Identifiers.Is_Valid (Given)
        and then Given'Length > Namespace (Kind)'Length
        and then Given (Given'First .. Given'First + Namespace (Kind)'Length) = Namespace (Kind) & "-"
        and then not Taken (Given)
      then
         Id := To_Unbounded_String (Given);
      else
         --  Made, and made again past any a source gave that has the number.
         loop
            Stores.Allocate_Identifier
              (Item, Change, Namespace (Kind), Key, Id, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            exit when not Taken (To_String (Id));
         end loop;
      end if;

      declare
         Value : Records.Item :=
           Records.Create (Schemas.Intent_Schema, 1, To_String (Id), 1);
      begin
         Records.Set (Value, "kind", Kind_Word (Kind));
         Records.Set (Value, "state", First_State (Kind));
         Records.Set (Value, "title", Title);
         Records.Set (Value, "text", Text);
         Records.Set (Value, "criteria", Criteria);
         Records.Set (Value, "source", Source);
         Records.Set (Value, "provenance", Provenance);
         Records.Set (Value, "scope", (if Scope = "" then "project" else Scope));
         Records.Set (Value, "meaning", Meaning_Of (Text, Criteria));
         Stores.Put (Change, Area_Of (Kind), To_String (Id), Value);
      end;

      Events.Emit
        (Item, Change,
         (case Kind is
            when Specification => Events.Specification_Proposed,
            when Requirement   => Events.Requirement_Proposed,
            when Decision      => Events.Decision_Proposed),
         To_String (Id), Title, Event, Status);
   end Propose;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Stores.Store;
      Kind   : Intent_Kind;
      Id     : String;
      Value  : out Entity;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Records.Item;

      function Field (Name : String) return Unbounded_String
      is (To_Unbounded_String (Records.Get (Held, Name)));
   begin
      Value := (Kind => Kind, others => <>);
      Stores.Read (Item, Area_Of (Kind), Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Value :=
        (Kind          => Kind,
         Id            => To_Unbounded_String (Records.Entity_Id (Held)),
         Revision      => Records.Revision (Held),
         State         => Field ("state"),
         Title         => Field ("title"),
         Text          => Field ("text"),
         Criteria      => Field ("criteria"),
         Source        => Field ("source"),
         Provenance    => Field ("provenance"),
         Scope         => Field ("scope"),
         Meaning       => Field ("meaning"),
         Supersedes    => Field ("supersedes"),
         Superseded_By => Field ("superseded_by"));
   end Read;

   ----------
   -- Move --
   ----------

   procedure Move
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Kind    : Intent_Kind;
      Id      : String;
      Next    : String;
      Granted : Transitions.Permissions;
      Status  : out Model_Runner.Errors.Error_Info;
      Actor   : String := "") is
   begin
      --  A person does not make a requirement implemented or verified:
      --  those follow its tasks and their current evidence.
      if Kind = Requirement and then Transitions.By_Person (Actor)
        and then Next in "implemented" | "verified"
      then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", "");
         E.Add_Text (Status, "expected", Next);
         E.Add_Text (Status, "detail",
                     "a requirement is implemented by its tasks and verified by their current"
                     & " evidence, not by being said to be");
         return;
      end if;
      Keep_Earlier (Item, Change, Kind, Id);
      Transitions.Apply
        (Item, Change, Lifecycle_Of (Item, Kind), Area_Of (Kind), Id, Next, Granted,
         Event_For (Kind, Next), Status, Actor);
   end Move;

   ------------
   -- Revise --
   ------------

   procedure Revise
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Kind     : Intent_Kind;
      Id       : String;
      Title    : String;
      Text     : String;
      Criteria : String;
      Result   : out Impact;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
      Event : Unbounded_String;
   begin
      Result := (others => <>);
      Current (Item, Change, Kind, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         State     : constant String := Records.Get (Value, "state");
         Old_Text  : constant String := Records.Get (Value, "text");
         Old_Rules : constant String := Records.Get (Value, "criteria");
         New_Text  : constant Boolean := Old_Text /= Text;
         New_Rules : constant Boolean := Old_Rules /= Criteria;
         Next      : Unbounded_String := To_Unbounded_String (State);
      begin
         Result.Before := To_Unbounded_String (State);

         if State in "obsolete" | "superseded" then
            Status := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Status, "name", Id);
            E.Add_Text (Status, "value", State);
            E.Add_Text (Status, "expected", State);
            E.Add_Text (Status, "detail", "what has been replaced is not revised");
            return;
         end if;

         --  The revision it replaces stays, under a name of its own.
         Keep_Earlier (Item, Change, Kind, Id);

         Records.Set (Value, "title", Title);
         Records.Set (Value, "text", Text);
         Records.Set (Value, "criteria", Criteria);
         Records.Set (Value, "meaning", Meaning_Of (Text, Criteria));
         Result.Normative := New_Text or else New_Rules;

         --  What the new meaning leaves no longer true, for a requirement:
         --  an implementation made for other words, evidence gathered
         --  against other criteria.
         if Kind = Requirement then
            if New_Text and then State in "implemented" | "verified" then
               Next := To_Unbounded_String ("accepted");
            elsif New_Rules and then State = "verified" then
               Next := To_Unbounded_String ("implemented");
            end if;
            Result.Invalidated := State = "verified" and then Next /= State;
            Records.Set (Value, "state", To_String (Next));
         end if;
         Result.After := Next;

         Stores.Put (Change, Area_Of (Kind), Id, Value);
         Events.Emit
           (Item, Change,
            (case Kind is
               when Specification => Events.Specification_Revised,
               when Requirement   => Events.Requirement_Revised,
               when Decision      => Events.Decision_Revised),
            Id, State & " -> " & To_String (Next), Event, Status);
         if E.Is_Ok (Status) and then Result.Invalidated then
            Events.Emit
              (Item, Change, Events.Requirement_Verification_Invalidated, Id,
               "revision" & Natural'Image (Records.Revision (Value)), Event,
               Status);
         end if;
      end;
   end Revise;

   ----------
   -- Link --
   ----------

   procedure Link
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Kind     : Intent_Kind;
      Id       : String;
      Relation : Link_Kind;
      Target   : String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Current (Item, Change, Kind, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Field : constant String := Link_Field (Relation);
         Held  : constant String := Records.Get (Value, Field);
      begin
         for Existing of Split_Lines (Held) loop
            if Existing = Target then
               return;
            end if;
         end loop;
         Records.Set
           (Value, Field,
            (if Held = "" then Target else Held & ASCII.LF & Target));
         Keep_Earlier (Item, Change, Kind, Id);
         Stores.Put (Change, Area_Of (Kind), Id, Value);
      end;
   end Link;

   -----------
   -- Links --
   -----------

   function Links
     (Item     : Stores.Store;
      Kind     : Intent_Kind;
      Id       : String;
      Relation : Link_Kind) return Name_Lists.Vector
   is
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Held, Status);
      if E.Is_Error (Status) then
         return Name_Lists.Empty_Vector;
      end if;
      return Split_Lines (Records.Get (Held, Link_Field (Relation)));
   end Links;

   ------------
   -- Govern --
   ------------

   procedure Govern
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Kind      : Intent_Kind;
      Id        : String;
      Subject   : String;
      Ruling    : String;
      Overrides : String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
      Event : Unbounded_String;
   begin
      Current (Item, Change, Kind, Id, Value, Status);
      if E.Is_Ok (Status) then
         --  A revision, as any change to what it says is: the one before
         --  is kept, what it governs is part of what it means, and it is
         --  said.
         Keep_Earlier (Item, Change, Kind, Id);
         Records.Set (Value, "governs", Subject);
         Records.Set (Value, "ruling", Ruling);
         Records.Set (Value, "overrides", Overrides);
         Records.Set
           (Value, "meaning",
            Meaning_Of (Records.Get (Value, "text"),
                        Records.Get (Value, "criteria") & ASCII.LF & "governs " & Subject
                        & " = " & Ruling & (if Overrides = "" then "" else " over " & Overrides)));
         Stores.Put (Change, Area_Of (Kind), Id, Value);
         Events.Emit
           (Item, Change,
            (case Kind is
               when Specification => Events.Specification_Revised,
               when Requirement   => Events.Requirement_Revised,
               when Decision      => Events.Decision_Revised),
            Id, "governs " & Subject, Event, Status);
      end if;
   end Govern;

   ---------------
   -- Supersede --
   ---------------

   procedure Supersede
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Kind   : Intent_Kind;
      Old_Id : String;
      New_Id : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Move (Item, Change, Kind, Old_Id, "superseded", Transitions.Ordinary_Only,
            Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Current (Item, Change, Kind, New_Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Records.Get (Value, "state") = First_State (Kind) then
         Move (Item, Change, Kind, New_Id, "accepted", Transitions.Ordinary_Only,
               Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Current (Item, Change, Kind, New_Id, Value, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      Keep_Earlier (Item, Change, Kind, New_Id);
      Records.Set (Value, "supersedes", Old_Id);
      Stores.Put (Change, Area_Of (Kind), New_Id, Value);

      Current (Item, Change, Kind, Old_Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Records.Set (Value, "superseded_by", New_Id);
      Stores.Put (Change, Area_Of (Kind), Old_Id, Value);
   end Supersede;

   ----------
   -- List --
   ----------

   function List
     (Item  : Stores.Store;
      Kind  : Intent_Kind;
      State : String := "") return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Area_Of (Kind)) loop
         if not Contains (Name, History_Mark) then
            if State = "" then
               Result.Append (Name);
            else
               declare
                  Held   : Records.Item;
                  Status : E.Error_Info;
               begin
                  Stores.Read (Item, Area_Of (Kind), Name, Held, Status);
                  if E.Is_Ok (Status) and then Records.Get (Held, "state") = State
                  then
                     Result.Append (Name);
                  end if;
               end;
            end if;
         end if;
      end loop;
      return Result;
   end List;

   ------------------------
   -- Find_By_Provenance --
   ------------------------

   function Find_By_Provenance
     (Item       : Stores.Store;
      Kind       : Intent_Kind;
      Provenance : String) return String is
   begin
      if Provenance = "" then
         return "";
      end if;
      for Name of List (Item, Kind) loop
         declare
            Held   : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Area_Of (Kind), Name, Held, Status);
            if E.Is_Ok (Status)
              and then Records.Get (Held, "provenance") = Provenance
            then
               return Name;
            end if;
         end;
      end loop;
      return "";
   end Find_By_Provenance;

   --------------------------
   -- Applicable_Decisions --
   --------------------------

   function Applicable_Decisions
     (Item      : Stores.Store;
      Component : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Name of List (Item, Decision, "accepted") loop
         declare
            Held   : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Decisions_Area, Name, Held, Status);
            if E.Is_Ok (Status)
              and then Records.Get (Held, "scope") in "project" | Component
            then
               Result.Append (Name);
            end if;
         end;
      end loop;
      return Result;
   end Applicable_Decisions;

end Model_Runner.Framework.Intent;
