with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
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
   is ("candidate");

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
               --  Retired with nothing in its place: it governs nothing
               --  from then on.
               Allow (Result, "accepted", "obsolete");
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

   ---------------
   -- Counts_As --
   ---------------

   function Counts_As (Item : Stores.Store; State : String) return String is
      Config : Records.Item;
      Read   : E.Error_Info;
   begin
      if State = "" or else Core_Requirement_States.Contains (State) then
         return State;
      end if;
      Configurations.Read (Item, Config, Read);
      declare
         Meaning : constant String := Records.Get (Config, "map.requirement.state." & State);
         Stop    : constant Natural := Ada.Strings.Fixed.Index (Meaning, ",");
         First   : constant String :=
           Ada.Strings.Fixed.Trim
             ((if Stop = 0 then Meaning else Meaning (Meaning'First .. Stop - 1)), Ada.Strings.Both);
      begin
         return (if Core_Requirement_States.Contains (First) then First else State);
      end;
   end Counts_As;

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
                    elsif Next in "superseded" | "obsolete" then Specification_Superseded
                    elsif Next = "rejected" then Specification_Rejected
                    else Specification_Reconsidered);
         when Decision =>
            return (if Next = "accepted" then Decision_Accepted
                    elsif Next in "superseded" | "obsolete" then Decision_Superseded
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

   --  The labels the project's code names -- REQ-2, DEC-7 -- each as its
   --  prefix and number, REQ-2 for REQ-002 alike: read once a scan, as
   --  numbers the project already uses for something.
   package Label_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (String, Ada.Strings.Hash, "=");

   Labels_Of_Scan : Unbounded_String;
   Labels_Held    : Label_Sets.Set;

   --  A label as its prefix and number without leading zeros; "" where it
   --  is not one.
   function Numbered (Label : String) return String is
      Dash : constant Natural := Ada.Strings.Fixed.Index (Label, "-", Ada.Strings.Backward);
   begin
      if Dash = 0 or else Dash = Label'Last
        or else not (for all C of Label (Dash + 1 .. Label'Last) => C in '0' .. '9')
        or else Label'Last - Dash > 9
      then
         return "";
      end if;
      return Label (Label'First .. Dash)
        & Ada.Strings.Fixed.Trim (Natural'Image (Natural'Value (Label (Dash + 1 .. Label'Last))), Ada.Strings.Both);
   end Numbered;

   function Code_Labels (Item : Stores.Store) return Label_Sets.Set is
      Fingerprint : constant String := Repository.Kept_Fingerprint (Item);
   begin
      if Fingerprint = "" then
         return Label_Sets.Empty_Set;
      elsif To_String (Labels_Of_Scan) = Fingerprint then
         return Labels_Held;
      end if;
      Labels_Held.Clear;
      declare
         Graph  : Repository.Graph;
         Status : E.Error_Info;
         Root   : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      begin
         Repository.Load (Item, Graph, Status);
         for Index in 1 .. Repository.File_Count (Graph) loop
            declare
               Path : constant String := To_String (Repository.File_At (Graph, Index).Path);
               Text : Unbounded_String;
               Read : E.Error_Info;
            begin
               if Ada.Directories.Exists (Root & "/" & Path)
                 and then Ada.Directories."<" (Ada.Directories.Size (Root & "/" & Path), 2_000_000)
               then
                  Files.Read_Text (Root & "/" & Path, Text, Read);
               end if;
               if E.Is_Ok (Read) then
                  declare
                     Whole : constant String := To_String (Text);
                     At_Char : Natural := Whole'First;
                  begin
                     --  Each run of capitals, a dash, and digits.
                     while At_Char <= Whole'Last loop
                        if Whole (At_Char) in 'A' .. 'Z'
                          and then (At_Char = Whole'First or else Whole (At_Char - 1) not in 'A' .. 'Z' | '-')
                        then
                           declare
                              Last : Natural := At_Char;
                           begin
                              while Last < Whole'Last and then Whole (Last + 1) in 'A' .. 'Z' loop
                                 Last := Last + 1;
                              end loop;
                              if Last + 1 < Whole'Last and then Whole (Last + 1) = '-'
                                and then Whole (Last + 2) in '0' .. '9'
                              then
                                 declare
                                    Digit : Natural := Last + 2;
                                 begin
                                    while Digit < Whole'Last and then Whole (Digit + 1) in '0' .. '9' loop
                                       Digit := Digit + 1;
                                    end loop;
                                    if Numbered (Whole (At_Char .. Digit)) /= "" then
                                       Labels_Held.Include (Numbered (Whole (At_Char .. Digit)));
                                    end if;
                                    At_Char := Digit;
                                 end;
                              else
                                 At_Char := Last;
                              end if;
                           end;
                        end if;
                        At_Char := At_Char + 1;
                     end loop;
                  end;
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
      end;
      Labels_Of_Scan := To_Unbounded_String (Fingerprint);
      return Labels_Held;
   end Code_Labels;

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

      In_Code : constant Label_Sets.Set := Code_Labels (Item);

      --  The register as it will be: what is kept, and what this change
      --  makes; a kept earlier revision is no entry.
      function Register_Now return Name_Lists.Vector is
         Result : Name_Lists.Vector := List (Item, Kind);
      begin
         for Name of Stores.Pending_Names (Change, Area_Of (Kind)) loop
            if Ada.Strings.Fixed.Index (Name, History_Mark) = 0 and then not Result.Contains (Name) then
               Result.Append (Name);
            end if;
         end loop;
         return Result;
      end Register_Now;

      --  Whether something has an identifier already, in the state or in
      --  this transaction.
      function Taken (Name : String) return Boolean is
         Held   : Records.Item;
         Staged : Boolean;
      begin
         Stores.Pending (Change, Area_Of (Kind), Name, Held, Staged);
         return Staged or else Stores.Exists (Item, Area_Of (Kind), Name);
      end Taken;

      --  Whether a new identifier's number is in use already: by one of
      --  the register written otherwise -- REQ-3 for REQ-003 -- or by a
      --  label the code names, which a new one would be mistaken for.
      function Number_Used (Name : String) return Boolean is
         Same : constant String := Numbered (Name);
      begin
         if Same = "" then
            return False;
         elsif In_Code.Contains (Same) then
            return True;
         end if;
         for Held of Register_Now loop
            if Held /= Name and then Numbered (Held) = Same then
               return True;
            end if;
         end loop;
         return False;
      end Number_Used;
      --  The next of a register that holds only unpadded numbers in the
      --  project's namespace -- REQ-1, REQ-2 -- and no others; "" when it
      --  holds none, or any of the harness's own.
      function Unpadded_Next return String is
         Prefix  : constant String := Namespace (Kind) & "-";
         Highest : Natural := 0;
         Plain   : Natural := 0;
         Padded  : Natural := 0;
      begin
         if Key /= "" and then Key /= Namespace (Kind) then
            return "";
         end if;
         --  The style most of the register is in: REQ-1 beside one REQ-001
         --  made before is still a register of REQ-n -- those made in this
         --  change too, as a document's REQ-1 to REQ-3 read just before.
         for Held of Register_Now loop
            if Held'Length > Prefix'Length and then Held (Held'First .. Held'First + Prefix'Length - 1) = Prefix
              and then (for all C of Held (Held'First + Prefix'Length .. Held'Last) => C in '0' .. '9')
              and then Held'Length - Prefix'Length <= 9
            then
               declare
                  Number : constant String := Held (Held'First + Prefix'Length .. Held'Last);
               begin
                  if Number'Length >= 3 or else Number (Number'First) = '0' then
                     Padded := Padded + 1;
                  else
                     Plain := Plain + 1;
                  end if;
                  Highest := Natural'Max (Highest, Natural'Value (Number));
               end;
            end if;
         end loop;
         if Plain = 0 or else Plain < Padded then
            return "";
         end if;
         for Next in Highest + 1 .. Highest + 100 loop
            declare
               Image : constant String := Ada.Strings.Fixed.Trim (Natural'Image (Next), Ada.Strings.Both);
            begin
               if not Taken (Prefix & Image) and then not Number_Used (Prefix & Image) then
                  return Prefix & Image;
               end if;
            end;
         end loop;
         return "";
      end Unpadded_Next;
   begin
      Status := E.Success;
      if Given /= "" and then Identifiers.Is_Valid (Given)
        and then Given'Length > Namespace (Kind)'Length
        and then Given (Given'First .. Given'First + Namespace (Kind)'Length) = Namespace (Kind) & "-"
        and then not Taken (Given)
        and then not (Numbered (Given) /= "" and then Number_Used (Given)
                      and then not In_Code.Contains (Numbered (Given)))
      then
         Id := To_Unbounded_String (Given);
      elsif Unpadded_Next /= "" then
         --  The register numbered as its documents number it -- REQ-1,
         --  REQ-2 -- goes on so: REQ-3, not REQ-001 beside them.
         Id := To_Unbounded_String (Unpadded_Next);
      else
         --  Made, and made again past any a source gave that has the number.
         loop
            --  A key that only says the register again -- spec.md's SPEC
            --  among specifications -- is no key: SPEC-001, not SPEC-SPEC-001.
            --  An identifier a document gives that is taken by then is made
            --  afresh, the document's own kept as its label.
            Stores.Allocate_Identifier
              (Item, Change, Namespace (Kind),
               (if Key = Namespace (Kind) or else Key & "S" = Namespace (Kind)
                            or else Key = Namespace (Kind) & "S"
                            or else Key = Namespace (Kind) & "IFICATIONS"
                            or else Key = Namespace (Kind) & "UIREMENTS"
                            or else Key = Namespace (Kind) & "ISIONS"
                then "" else Key),
               Id, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            exit when not Taken (To_String (Id)) and then not Number_Used (To_String (Id));
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

   -------------
   -- Governs --
   -------------

   function Blocked_Because (Item : Stores.Store; Kind : Intent_Kind; Id : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Value, Status);
      return (if E.Is_Error (Status) then "" else Records.Get (Value, "blocked_because"));
   end Blocked_Because;

   function Moved_By (Item : Stores.Store; Kind : Intent_Kind; Id : String; Move : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Value, Status);
      return (if E.Is_Error (Status) then "" else Records.Get (Value, Move & "_by"));
   end Moved_By;

   function Governs (Item : Stores.Store; Kind : Intent_Kind; Id : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Value, Status);
      if E.Is_Error (Status) or else Records.Get (Value, "governs") = "" then
         return "";
      end if;
      return Records.Get (Value, "governs") & " = " & Records.Get (Value, "ruling")
        & (if Records.Get (Value, "overrides") = "" then ""
           else " (over " & Records.Get (Value, "overrides") & ")");
   end Governs;

   ------------------
   -- Also_Governs --
   ------------------

   function Also_Governs (Item : Stores.Store; Kind : Intent_Kind; Id : String) return Name_Lists.Vector is
      Value  : Records.Item;
      Status : E.Error_Info;
      Result : Name_Lists.Vector;
   begin
      Stores.Read (Item, Area_Of (Kind), Id, Value, Status);
      if E.Is_Ok (Status) then
         for Line of Split_Lines (Records.Get (Value, "also_governs")) loop
            declare
               First  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
               Second : constant Natural :=
                 (if First = 0 then 0 else Ada.Strings.Fixed.Index (Line (First + 1 .. Line'Last), [1 => ASCII.HT]));
            begin
               if First > Line'First and then Second > First then
                  Result.Append (Line (Line'First .. First - 1) & " = " & Line (First + 1 .. Second - 1)
                                 & (if Second = Line'Last then ""
                                    else " (over " & Line (Second + 1 .. Line'Last) & ")"));
               end if;
            end;
         end loop;
      end if;
      return Result;
   end Also_Governs;

   --------------
   -- State_Of --
   --------------

   function State_Of (Item : Stores.Store; Kind : Intent_Kind; Id : String) return String is
      Held   : Entity;
      Status : E.Error_Info;
   begin
      Read (Item, Kind, Id, Held, Status);
      return (if E.Is_Ok (Status) then To_String (Held.State) else "");
   end State_Of;

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
         --  A decision waiting was once said proposed: a candidate, as
         --  every register's waiting entry is now.
         State         => (if Field ("state") = "proposed" then To_Unbounded_String ("candidate")
                           else Field ("state")),
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
      Actor   : String := "";
      Reason  : String := "") is
   begin
      --  A person does not make a requirement implemented or verified:
      --  those follow its tasks and their current evidence.
      if Kind = Requirement and then Transitions.By_Person (Actor)
        and then Next in "implemented" | "verified"
      then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", State_Of (Item, Kind, Id));
         E.Add_Text (Status, "expected", Next);
         E.Add_Text (Status, "detail",
                     "a requirement is implemented by its tasks and verified by their current"
                     & " evidence, not by being said to be");
         return;
      end if;
      Keep_Earlier (Item, Change, Kind, Id);
      Transitions.Apply
        (Item, Change, Lifecycle_Of (Item, Kind), Area_Of (Kind), Id, Next, Granted,
         Event_For (Kind, Next), Status, Actor, Reason => Reason);
      --  Why it is blocked, kept with it while it is; gone once it is not.
      if E.Is_Ok (Status) then
         declare
            Value  : Records.Item;
            Staged : Boolean;
         begin
            Stores.Pending (Change, Area_Of (Kind), Id, Value, Staged);
            if Staged then
               if Next = "blocked" and then Reason /= "" then
                  Records.Set (Value, "blocked_because", Reason);
               else
                  Records.Remove (Value, "blocked_because");
               end if;
               Stores.Put (Change, Area_Of (Kind), Id, Value);
            end if;
         end;
      end if;
   end Move;

   -------------
   -- Rescope --
   -------------

   procedure Rescope
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Kind   : Intent_Kind;
      Id     : String;
      Scope  : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Current (Item, Change, Kind, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      elsif Records.Get (Value, "state") in "obsolete" | "superseded" then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", Records.Get (Value, "state"));
         E.Add_Text (Status, "expected", "a new revision");
         E.Add_Text (Status, "detail", "what is retired is not placed anew");
         return;
      end if;
      Keep_Earlier (Item, Change, Kind, Id);
      Records.Set (Value, "scope", (if Scope = "" then "project" else Scope));
      Stores.Put (Change, Area_Of (Kind), Id, Value);
   end Rescope;

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
            E.Add_Text (Status, "expected", "a new revision");
            E.Add_Text (Status, "detail", "it is retired, and what is retired is not revised; "
                        & (case Kind is
                              when Requirement   => "/req",
                              when Specification => "/spec",
                              when Decision      => "/decision")
                        & " new """ & Records.Get (Value, "title") & """ text=... makes it anew");
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
         --  Where the policy says, by what no longer applies: new words
         --  leave no implementation standing (requirement.after_text_change,
         --  accepted unless it says blocked), new criteria no evidence
         --  (requirement.after_criteria_change, implemented unless it says
         --  accepted).
         if Kind = Requirement then
            declare
               Config : Records.Item;
               Read   : E.Error_Info;
            begin
               Configurations.Read (Item, Config, Read);
               declare
                  After_Text     : constant String :=
                    Records.Get (Config, "scalar.requirement.after_text_change");
                  After_Criteria : constant String :=
                    Records.Get (Config, "scalar.requirement.after_criteria_change");
               begin
                  if New_Text and then State in "implemented" | "verified" then
                     Next := To_Unbounded_String
                       (if After_Text = "blocked" then "blocked" else "accepted");
                  elsif New_Rules and then State in "implemented" | "verified" then
                     Next := To_Unbounded_String
                       (if After_Criteria = "accepted" then "accepted"
                        elsif State = "verified" then "implemented" else State);
                  end if;
               end;
            end;
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

   ------------
   -- Unlink --
   ------------

   procedure Unlink
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
         Kept  : Unbounded_String;
         Found : Boolean := False;
      begin
         for Existing of Split_Lines (Records.Get (Value, Field)) loop
            if Existing = Target then
               Found := True;
            else
               Append (Kept, (if Kept = Null_Unbounded_String then "" else ASCII.LF & "") & Existing);
            end if;
         end loop;
         if not Found then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Id & "'s link to " & Target);
            return;
         end if;
         if Kept = Null_Unbounded_String then
            Records.Remove (Value, Field);
         else
            Records.Set (Value, Field, To_String (Kept));
         end if;
         Keep_Earlier (Item, Change, Kind, Id);
         Stores.Put (Change, Area_Of (Kind), Id, Value);
      end;
   end Unlink;

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
         --  No ruling: it governs that setting no more -- another it rules
         --  on, if any, is the one it governs now.
         if Ruling = "" then
            declare
               Rest_Lines : constant Name_Lists.Vector := Split_Lines (Records.Get (Value, "also_governs"));
            begin
               if Records.Get (Value, "governs") = Subject or else Records.Get (Value, "governs") = "" then
                  if Rest_Lines.Is_Empty then
                     Records.Remove (Value, "governs");
                     Records.Remove (Value, "ruling");
                     Records.Remove (Value, "overrides");
                  else
                     declare
                        Line   : constant String := Rest_Lines.First_Element;
                        First  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                        Second : constant Natural :=
                          Ada.Strings.Fixed.Index (Line (First + 1 .. Line'Last), [1 => ASCII.HT]);
                        Rest   : Unbounded_String;
                     begin
                        Records.Set (Value, "governs", Line (Line'First .. First - 1));
                        Records.Set (Value, "ruling",
                                     Line (First + 1 .. (if Second = 0 then Line'Last else Second - 1)));
                        Records.Set (Value, "overrides", (if Second = 0 then "" else Line (Second + 1 .. Line'Last)));
                        for Index in 2 .. Natural (Rest_Lines.Length) loop
                           Append (Rest, Rest_Lines (Index) & ASCII.LF);
                        end loop;
                        if Rest = Null_Unbounded_String then
                           Records.Remove (Value, "also_governs");
                        else
                           Records.Set (Value, "also_governs", To_String (Rest));
                        end if;
                     end;
                  end if;
               else
                  --  One of the others it rules on: that one taken out.
                  declare
                     Kept : Unbounded_String;
                  begin
                     for Line of Rest_Lines loop
                        if Ada.Strings.Fixed.Index (Line, Subject & ASCII.HT) /= Line'First then
                           Append (Kept, Line & ASCII.LF);
                        end if;
                     end loop;
                     if Kept = Null_Unbounded_String then
                        Records.Remove (Value, "also_governs");
                     else
                        Records.Set (Value, "also_governs", To_String (Kept));
                     end if;
                  end;
               end if;
            end;
            Stores.Put (Change, Area_Of (Kind), Id, Value);
            Events.Emit
              (Item, Change,
               (case Kind is
                  when Specification => Events.Specification_Revised,
                  when Requirement   => Events.Requirement_Revised,
                  when Decision      => Events.Decision_Revised),
               Id, "governs " & Subject & " no more", Event, Status);
            return;
         end if;
         --  Ruling on another setting than the one it governs: that one is
         --  kept beside it, not dropped; on the same, it is replaced.
         declare
            Before : constant String := Records.Get (Value, "governs");
            Kept_Too : Unbounded_String;
         begin
            for Line of Split_Lines (Records.Get (Value, "also_governs")) loop
               declare
                  Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
               begin
                  if Tab > Line'First and then Line (Line'First .. Tab - 1) /= Subject then
                     Append (Kept_Too, Line & ASCII.LF);
                  end if;
               end;
            end loop;
            if Before /= "" and then Before /= Subject then
               Append (Kept_Too, Before & ASCII.HT & Records.Get (Value, "ruling") & ASCII.HT
                       & Records.Get (Value, "overrides") & ASCII.LF);
            end if;
            if Kept_Too = Null_Unbounded_String then
               Records.Remove (Value, "also_governs");
            else
               Records.Set (Value, "also_governs", To_String (Kept_Too));
            end if;
         end;
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
      Held  : Records.Item;
      Read  : E.Error_Info;
   begin
      --  Where its register has no superseded state -- requirements -- the
      --  one replaced is retired as the state it is in allows: rejected as
      --  a candidate, obsolete once accepted; the links say what replaced it.
      Current (Item, Change, Kind, Old_Id, Held, Read);
      --  One never agreed on is rejected, in any register: nothing it
      --  governed is taken over.
      Move (Item, Change, Kind, Old_Id,
            (if Records.Get (Held, "state") = First_State (Kind) then "rejected"
             elsif Transitions.Is_State (Lifecycle_Of (Item, Kind), "superseded") then "superseded"
             else "obsolete"),
            Transitions.Ordinary_Only, Status);
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
                  if E.Is_Ok (Status)
                    and then (Records.Get (Held, "state") = State
                              or else (State = "candidate" and then Records.Get (Held, "state") = "proposed"))
                  then
                     Result.Append (Name);
                  end if;
               end;
            end if;
         end if;
      end loop;
      --  In the order a person counts them: REQ-2 before REQ-10, and
      --  REQ-004 among REQ-3 and REQ-5, each prefix together.
      declare
         function Before (Left, Right : String) return Boolean is
            Left_Dash  : constant Natural := Ada.Strings.Fixed.Index (Left, "-", Ada.Strings.Backward);
            Right_Dash : constant Natural := Ada.Strings.Fixed.Index (Right, "-", Ada.Strings.Backward);
            function Number (Name : String; Dash : Natural) return Natural
            is (if Dash = 0 or else Dash = Name'Last or else Name'Last - Dash > 9
                  or else (for some C of Name (Dash + 1 .. Name'Last) => C not in '0' .. '9')
                then Natural'Last else Natural'Value (Name (Dash + 1 .. Name'Last)));
            Left_Stem  : constant String := (if Left_Dash = 0 then Left else Left (Left'First .. Left_Dash));
            Right_Stem : constant String := (if Right_Dash = 0 then Right else Right (Right'First .. Right_Dash));
         begin
            if Left_Stem /= Right_Stem then
               return Left_Stem < Right_Stem;
            elsif Number (Left, Left_Dash) /= Number (Right, Right_Dash) then
               return Number (Left, Left_Dash) < Number (Right, Right_Dash);
            end if;
            return Left < Right;
         end Before;
         package Counting is new Name_Lists.Generic_Sorting (Before);
      begin
         Counting.Sort (Result);
      end;
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
