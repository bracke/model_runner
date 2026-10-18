with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Verification;

package body Model_Runner.Framework.Observations is

   package E renames Model_Runner.Errors;
   use Ada.Strings.Unbounded;

   Tab : constant Character := ASCII.HT;
   LF  : constant Character := ASCII.LF;

   --  How many files and symbols one observation is about at most.
   Ties_Most : constant := 24;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Word (Kind : Observation_Kind) return String
   is (Lower (Observation_Kind'Image (Kind)));

   function Word (Status : Lifecycle) return String
   is (Lower (Lifecycle'Image (Status)));

   function Word (Standing : Applicability) return String
   is (Lower (Applicability'Image (Standing)));

   function Word (Ground : Grounding) return String
   is (Lower (Grounding'Image (Ground)));

   function Word (Producer : Producer_Kind) return String
   is (case Producer is
          when Agent_Producer   => "agent",
          when Harness_Producer => "harness",
          when User_Producer    => "user");

   procedure Kind_Of (Text : String; Kind : out Observation_Kind; Found : out Boolean) is
   begin
      for One in Observation_Kind loop
         if Word (One) = Lower (Trim (Text)) then
            Kind := One;
            Found := True;
            return;
         end if;
      end loop;
      Kind := Finding;
      Found := False;
   end Kind_Of;

   function Joined (Lines : Name_Lists.Vector; Between : String := ", ") return String is
      Text : Unbounded_String;
   begin
      for Line of Lines loop
         Append (Text, (if Length (Text) = 0 then "" else Between) & Line);
      end loop;
      return To_String (Text);
   end Joined;

   package Sorting is new Name_Lists.Generic_Sorting;

   function Sorted (Lines : Name_Lists.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector := Lines;
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted;

   --  A summary as one line, its spacing made single.
   function One_Line (Text : String) return String is
      Result : Unbounded_String;
      Space  : Boolean := False;
   begin
      for C of Text loop
         if C in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
            Space := Length (Result) > 0;
         elsif C >= ' ' then
            if Space then
               Append (Result, ' ');
               Space := False;
            end if;
            Append (Result, C);
         end if;
      end loop;
      return To_String (Result);
   end One_Line;

   --------------
   -- Claim_Of --
   --------------

   function Claim_Of (Said : Draft) return String is
      Text : constant String := Lower (One_Line (To_String (Said.Summary)));
      Last : Natural := Text'Last;
   begin
      --  How a sentence ends is not what it claims.
      while Last >= Text'First and then Text (Last) in '.' | '!' | ';' | ':' | ' ' loop
         Last := Last - 1;
      end loop;
      return Fingerprint
        (Word (Said.Kind) & LF & Text (Text'First .. Last) & LF
         & Joined (Sorted (Said.Files), [1 => Tab]) & LF & Joined (Sorted (Said.Symbols), [1 => Tab]));
   end Claim_Of;

   ---------------------------------------------------------------------------
   --  Records.
   ---------------------------------------------------------------------------

   function From_Record (Value : Records.Item) return Observation is
      Result : Observation;
   begin
      Result.Id := To_Unbounded_String (Records.Entity_Id (Value));
      Result.Revision := Records.Revision (Value);
      declare
         Found : Boolean;
      begin
         Kind_Of (Records.Get (Value, "kind"), Result.Kind, Found);
      end;
      Result.Summary := To_Unbounded_String (Records.Get (Value, "summary"));
      for One in Lifecycle loop
         if Word (One) = Records.Get (Value, "status") then
            Result.Status := One;
         end if;
      end loop;
      Result.Ground := (if Records.Get (Value, "grounding") = "observed" then Observed else Reported);
      for One in Producer_Kind loop
         if Word (One) = Records.Get (Value, "producer") then
            Result.Producer := One;
         end if;
      end loop;
      Result.Task_Id := To_Unbounded_String (Records.Get (Value, "task"));
      Result.Generation := To_Unbounded_String (Records.Get (Value, "generation"));
      Result.Agent := To_Unbounded_String (Records.Get (Value, "agent"));
      Result.Parent := To_Unbounded_String (Records.Get (Value, "parent"));
      Result.Invocation := To_Unbounded_String (Records.Get (Value, "invocation"));
      Result.Sightings := Lines_Of (Records.Get (Value, "sightings"));
      Result.Component := To_Unbounded_String (Records.Get (Value, "component"));
      Result.Evidence := Lines_Of (Records.Get (Value, "evidence"));
      Result.Symbols := Lines_Of (Records.Get (Value, "symbols"));
      for Line of Lines_Of (Records.Get (Value, "files")) loop
         declare
            At_Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => Tab]);
         begin
            if At_Tab > 0 then
               Result.Files.Append (Line (Line'First .. At_Tab - 1));
               Result.File_Prints.Append (Line (At_Tab + 1 .. Line'Last));
            else
               Result.Files.Append (Line);
               Result.File_Prints.Append ("?");
            end if;
         end;
      end loop;
      Result.Configuration := To_Unbounded_String (Records.Get (Value, "configuration"));
      Result.Created_At := To_Unbounded_String (Records.Get (Value, "created_at"));
      Result.Seen_At := To_Unbounded_String (Records.Get (Value, "seen_at"));
      declare
         Count : constant String := Records.Get (Value, "occurrences");
      begin
         Result.Occurrences :=
           (if Count /= "" and then Count'Length <= 9 and then (for all C of Count => C in '0' .. '9')
              and then Natural'Value (Count) > 0
            then Natural'Value (Count) else 1);
      end;
      Result.Superseded_By := To_Unbounded_String (Records.Get (Value, "superseded_by"));
      Result.Similar_To := To_Unbounded_String (Records.Get (Value, "similar_to"));
      Result.Promoted_To := To_Unbounded_String (Records.Get (Value, "promoted_to"));
      Result.Reason := To_Unbounded_String (Records.Get (Value, "reason"));
      Result.Retired := To_Unbounded_String (Records.Get (Value, "retired"));
      return Result;
   end From_Record;

   function To_Record (Value : Observation; Claim : String) return Records.Item is
      Result : Records.Item :=
        Records.Create (Schemas.Observation_Schema, 1, To_String (Value.Id), Value.Revision);

      procedure Set (Name, Text : String) is
      begin
         if Text /= "" then
            Records.Set (Result, Name, Text);
         end if;
      end Set;

      Files_Text : Unbounded_String;
   begin
      Set ("kind", Word (Value.Kind));
      Set ("summary", To_String (Value.Summary));
      Set ("status", Word (Value.Status));
      Set ("grounding", Word (Value.Ground));
      Set ("producer", Word (Value.Producer));
      Set ("claim", Claim);
      Set ("task", To_String (Value.Task_Id));
      Set ("generation", To_String (Value.Generation));
      Set ("agent", To_String (Value.Agent));
      Set ("parent", To_String (Value.Parent));
      Set ("invocation", To_String (Value.Invocation));
      Set ("sightings", Joined (Value.Sightings, [1 => LF]));
      Set ("component", To_String (Value.Component));
      Set ("evidence", Joined (Value.Evidence, [1 => LF]));
      Set ("symbols", Joined (Value.Symbols, [1 => LF]));
      for Index in 1 .. Natural (Value.Files.Length) loop
         Append (Files_Text, (if Index = 1 then "" else [1 => LF])
                 & Value.Files (Index) & Tab & Value.File_Prints (Index));
      end loop;
      Set ("files", To_String (Files_Text));
      Set ("configuration", To_String (Value.Configuration));
      Set ("created_at", To_String (Value.Created_At));
      Set ("seen_at", To_String (Value.Seen_At));
      Set ("occurrences", Image (Value.Occurrences));
      Set ("superseded_by", To_String (Value.Superseded_By));
      Set ("similar_to", To_String (Value.Similar_To));
      Set ("promoted_to", To_String (Value.Promoted_To));
      Set ("reason", To_String (Value.Reason));
      Set ("retired", To_String (Value.Retired));
      return Result;
   end To_Record;

   ----------
   -- Read --
   ----------

   procedure Read_Record
     (Item   : Stores.Store;
      Id     : String;
      Held   : out Records.Item;
      Value  : out Observation;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Value := (others => <>);
      if not Stores.Exists (Item, Observations_Area, Id) then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Id);
         return;
      end if;
      Stores.Read (Item, Observations_Area, Id, Held, Status);
      if E.Is_Ok (Status) then
         Value := From_Record (Held);
      end if;
   end Read_Record;

   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Observation;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Records.Item;
   begin
      Read_Record (Item, Id, Held, Value, Status);
   end Read;

   ----------
   -- List --
   ----------

   function List (Item : Stores.Store) return Name_Lists.Vector is
      function Before (Left, Right : String) return Boolean
      is (Later (Right, Left) and then Left /= Right);
      package By_Number is new Name_Lists.Generic_Sorting (Before);
      Result : Name_Lists.Vector := Stores.Names (Item, Observations_Area);
   begin
      By_Number.Sort (Result);
      return Result;
   end List;

   --  Where a file is read: the tree an origin names, or the project.
   function Tree_Of (Item : Stores.Store; Tree : String) return String
   is (if Tree /= "" then Tree else Ada.Directories.Containing_Directory (Stores.Root (Item)));

   --  A file's print as an observation keeps it: its fingerprint, "-" for
   --  one not there, "?" for one that would not read.
   function Print_Of (Root, Path : String) return String is
      Print  : Unbounded_String;
      Status : E.Error_Info;
   begin
      if not Ada.Directories.Exists (Root & "/" & Path) then
         return "-";
      end if;
      Files.Print_Of (Root & "/" & Path, Print, Status);
      return (if E.Is_Ok (Status) then To_String (Print) else "?");
   exception
      when others =>
         return "?";
   end Print_Of;

   function Configuration_Print (Item : Stores.Store) return String is
   begin
      return Records.Get (Configurations.Required (Item), "configuration_fingerprint");
   exception
      when Configurations.Configuration_Unavailable =>
         return "?";
   end Configuration_Print;

   function Sighting_Of (From : Origin) return String is
      function Or_Dash (Text : Unbounded_String) return String
      is (if Length (Text) = 0 then "-" else To_String (Text));
   begin
      return Or_Dash (From.Task_Id) & " " & Or_Dash (From.Generation) & " " & Or_Dash (From.Agent)
        & " " & Or_Dash (From.Invocation);
   end Sighting_Of;

   procedure Refuse (Status : out E.Error_Info; Name, Value, Detail : String) is
   begin
      Status := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Status, "name", Name);
      E.Add_Text (Status, "value", (if Value = "" then "nothing" else Value));
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   ------------------------
   -- Record_Observation --
   ------------------------

   -----------------
   -- Nearly_Same --
   -----------------

   function Nearly_Same (Left, Right : Observation) return Boolean is

      --  The words of three letters or more, lower case, once each.
      function Words_Of (Text : String) return Name_Lists.Vector is
         Found : Name_Lists.Vector;
         Start : Natural := 0;
         Plain : constant String := Lower (Text);
      begin
         for Index in Plain'First .. Plain'Last + 1 loop
            if Index <= Plain'Last and then Plain (Index) in 'a' .. 'z' | '0' .. '9' | '_' then
               if Start = 0 then
                  Start := Index;
               end if;
            elsif Start /= 0 then
               if Index - Start >= 3 and then not Found.Contains (Plain (Start .. Index - 1)) then
                  Found.Append (Plain (Start .. Index - 1));
               end if;
               Start := 0;
            end if;
         end loop;
         return Found;
      end Words_Of;

      Ours   : constant Name_Lists.Vector := Words_Of (To_String (Left.Summary));
      Theirs : constant Name_Lists.Vector := Words_Of (To_String (Right.Summary));
      Shared : Natural := 0;
   begin
      if Left.Kind /= Right.Kind
        or else (not Left.Files.Is_Empty and then not Right.Files.Is_Empty
                 and then not (for some Path of Left.Files => Right.Files.Contains (Path)))
      then
         return False;
      end if;
      for Word of Ours loop
         if Theirs.Contains (Word) then
            Shared := Shared + 1;
         end if;
      end loop;
      --  Shared over all the words there are, at least three in five.
      return Shared >= 3
        and then 5 * Shared >= 3 * (Natural (Ours.Length) + Natural (Theirs.Length) - Shared);
   end Nearly_Same;

   procedure Record_Observation
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Said   : Draft;
      From   : Origin;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Fresh  : out Boolean;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Summary : constant String := One_Line (To_String (Said.Summary));
      Clean   : Draft := Said;
      Root    : constant String := Tree_Of (Item, To_String (From.Tree));
   begin
      Id := Null_Unbounded_String;
      Fresh := False;
      Status := E.Success;

      if Summary = "" then
         Refuse (Status, "summary", "", "an observation says what was found");
         return;
      elsif Summary'Length > Summary_Most then
         Refuse (Status, "summary", Summary (Summary'First .. Summary'First + 39) & "...",
                 "it is" & Natural'Image (Summary'Length) & " characters; an observation keeps"
                 & Natural'Image (Summary_Most) & " -- say what was found, and name its evidence");
         return;
      elsif Natural (Said.Files.Length) > Ties_Most or else Natural (Said.Symbols.Length) > Ties_Most then
         Refuse (Status, "files", "more than" & Natural'Image (Ties_Most),
                 "an observation is about" & Natural'Image (Ties_Most) & " files and symbols at most");
         return;
      end if;
      Clean.Summary := To_Unbounded_String (Summary);
      Clean.Files.Clear;
      for Path of Said.Files loop
         declare
            Given : constant String := Trim (Path);
         begin
            if Given = "" or else Is_Rooted (Given) or else Given = ".."
              or else Starts (Given, "../") or else Ada.Strings.Fixed.Index (Given, "/../") > 0
              or else (Given'Length >= 3 and then Given (Given'Last - 2 .. Given'Last) = "/..")
            then
               Refuse (Status, "files", Given, "it is not a path within the project");
               return;
            elsif not Clean.Files.Contains (Given) then
               Clean.Files.Append (Given);
            end if;
         end;
      end loop;
      Clean.Symbols.Clear;
      for Symbol of Said.Symbols loop
         if Trim (Symbol) /= "" and then not Clean.Symbols.Contains (Trim (Symbol)) then
            Clean.Symbols.Append (Trim (Symbol));
         end if;
      end loop;
      --  Evidence is what the store keeps: a result or a verification, by
      --  its identifier; anything else is not evidence.
      Clean.Evidence.Clear;
      for Named of Said.Evidence loop
         declare
            Given : constant String := Trim (Named);
         begin
            if not Identifiers.Is_Valid (Given)
              or else not (Starts (Given, "RES-") or else Starts (Given, "VER-"))
            then
               Refuse (Status, "evidence", Given,
                       "evidence is a result (RES-) or a verification (VER-) the project keeps");
               return;
            elsif not Stores.Exists (Item, (if Starts (Given, "RES-") then Results_Area else Verification_Area),
                                     Given)
            then
               Status := E.Make (E.Framework_Not_Found);
               E.Add_Text (Status, "name", Given);
               return;
            elsif not Clean.Evidence.Contains (Given) then
               Clean.Evidence.Append (Given);
            end if;
         end;
      end loop;

      declare
         Claim   : constant String := Claim_Of (Clean);
         Now     : constant String := Timestamp;
         Prints  : Name_Lists.Vector;
         Known   : Unbounded_String;
         Held    : Records.Item;
         Value   : Observation;
         Read    : E.Error_Info;
      begin
         for Path of Clean.Files loop
            Prints.Append (Print_Of (Root, Path));
         end loop;

         --  The same claim, staged in this change or kept: seen again.
         for Name of Stores.Pending_Names (Change, Observations_Area) loop
            declare
               Staged : Boolean;
            begin
               Stores.Pending (Change, Observations_Area, Name, Held, Staged);
               if Staged and then Records.Get (Held, "claim") = Claim then
                  Known := To_Unbounded_String (Name);
               end if;
            end;
         end loop;
         if Length (Known) = 0 then
            for Name of List (Item) loop
               Stores.Read (Item, Observations_Area, Name, Held, Read);
               if E.Is_Ok (Read) and then Records.Get (Held, "claim") = Claim then
                  Known := To_Unbounded_String (Name);
                  exit;
               end if;
            end loop;
         end if;

         if Length (Known) > 0 then
            declare
               Staged : Boolean;
            begin
               Stores.Pending (Change, Observations_Area, To_String (Known), Held, Staged);
               if not Staged then
                  Stores.Read (Item, Observations_Area, To_String (Known), Held, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end if;
            end;
            Value := From_Record (Held);
            Value.Revision := Value.Revision + 1;
            Value.Occurrences := Value.Occurrences + 1;
            Value.Seen_At := To_Unbounded_String (Now);
            if not Value.Sightings.Contains (Sighting_Of (From)) then
               Value.Sightings.Append (Sighting_Of (From));
            end if;
            for One of Clean.Evidence loop
               if not Value.Evidence.Contains (One) then
                  Value.Evidence.Append (One);
               end if;
            end loop;
            if not Clean.Evidence.Is_Empty or else From.Producer = Harness_Producer then
               Value.Ground := Observed;
            end if;
            --  Seen again on these bytes: it holds of them.
            Value.File_Prints := Prints;
            Value.Configuration := To_Unbounded_String (Configuration_Print (Item));
            Stores.Put (Change, Observations_Area, To_String (Known), To_Record (Value, Claim));
            Id := Known;
            return;
         end if;

         Stores.Allocate_Identifier (Item, Change, "OBS", "", Id, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Value :=
           (Id            => Id,
            Revision      => 1,
            Kind          => Clean.Kind,
            Summary       => Clean.Summary,
            Status        => Active,
            Ground        => (if not Clean.Evidence.Is_Empty or else From.Producer = Harness_Producer
                              then Observed else Reported),
            Producer      => From.Producer,
            Task_Id       => From.Task_Id,
            Generation    => From.Generation,
            Agent         => From.Agent,
            Parent        => From.Parent,
            Invocation    => From.Invocation,
            Sightings     => Name_Lists.To_Vector (Sighting_Of (From), 1),
            Component     => Null_Unbounded_String,
            Evidence      => Clean.Evidence,
            Files         => Clean.Files,
            File_Prints   => Prints,
            Symbols       => Clean.Symbols,
            Configuration => To_Unbounded_String (Configuration_Print (Item)),
            Created_At    => To_Unbounded_String (Now),
            Seen_At       => To_Unbounded_String (Now),
            Occurrences   => 1,
            others        => <>);
         if Length (From.Task_Id) > 0 then
            declare
               Defined : Records.Item;
            begin
               Tasks.Definition (Item, To_String (From.Task_Id), Defined, Read);
               if E.Is_Ok (Read) then
                  Value.Component := To_Unbounded_String (Records.Get (Defined, "component"));
               end if;
            end;
         end if;
         --  One that says nearly the same, still active: named, so the two
         --  are not told side by side.
         for Name of List (Item) loop
            declare
               Other : Observation;
               Got   : E.Error_Info;
            begin
               Observations.Read (Item, Name, Other, Got);
               if E.Is_Ok (Got) and then Other.Status = Active and then Nearly_Same (Value, Other) then
                  Value.Similar_To := To_Unbounded_String (Name);
                  exit;
               end if;
            end;
         end loop;
         Stores.Put (Change, Observations_Area, To_String (Id), To_Record (Value, Claim));
         declare
            Event : Unbounded_String;
         begin
            Events.Emit (Item, Change, Events.Observation_Recorded, To_String (Id),
                         Word (Value.Kind) & " by " & Word (From.Producer)
                         & (if Length (From.Task_Id) > 0 then " in " & To_String (From.Task_Id) else ""),
                         Event, Status);
         end;
         Fresh := E.Is_Ok (Status);
      end;
   end Record_Observation;

   ----------------------
   -- Applicability_Of --
   ----------------------

   function Applicability_Of
     (Item  : Stores.Store;
      Value : Observation;
      Why   : out Ada.Strings.Unbounded.Unbounded_String) return Applicability
   is
      Root    : constant String := Tree_Of (Item, "");
      Changed : Name_Lists.Vector;
   begin
      Why := Null_Unbounded_String;
      case Value.Status is
         when Superseded =>
            Why := To_Unbounded_String ("superseded by " & To_String (Value.Superseded_By));
            return Superseded;
         when Dismissed =>
            Why := To_Unbounded_String ("dismissed: " & To_String (Value.Reason));
            return Dismissed;
         when Active | Promoted =>
            null;
      end case;
      for Index in 1 .. Natural (Value.Files.Length) loop
         declare
            Path : constant String := Value.Files (Index);
            Now  : constant String := Print_Of (Root, Path);
            Then_Print : constant String := Value.File_Prints (Index);
         begin
            if Now = "?" or else Then_Print = "?" then
               Why := To_Unbounded_String (Path & " could not be read");
               return Unreadable;
            elsif Now /= Then_Print then
               Changed.Append
                 (Path & (if Now = "-" then " is gone" elsif Then_Print = "-" then " is there now"
                          else " changed") & " since it was seen");
            end if;
         end;
      end loop;
      if not Changed.Is_Empty then
         Why := To_Unbounded_String (Joined (Changed, "; "));
         return Stale;
      end if;
      declare
         Now : constant String := Configuration_Print (Item);
      begin
         if Now = "?" then
            Why := To_Unbounded_String ("the configuration could not be read");
            return Unreadable;
         elsif Value.Kind in Failure_Pattern | Environment_Constraint | Tool_Behavior
           and then Now /= To_String (Value.Configuration)
         then
            Why := To_Unbounded_String ("the configuration changed since it was seen");
            return Uncertain;
         end if;
      end;
      return Applicable;
   end Applicability_Of;

   ---------------------------------------------------------------------------
   --  Its life.
   ---------------------------------------------------------------------------

   --  An observation that can still change: active.
   procedure Take_Active
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String;
      Value  : out Observation;
      Claim  : out Unbounded_String;
      Status : out E.Error_Info)
   is
      Held   : Records.Item;
      Staged : Boolean;
   begin
      Stores.Pending (Change, Observations_Area, Id, Held, Staged);
      if Staged then
         Value := From_Record (Held);
         Status := E.Success;
      else
         Read_Record (Item, Id, Held, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;
      Claim := To_Unbounded_String (Records.Get (Held, "claim"));
      if Value.Status /= Active then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", Word (Value.Status));
         E.Add_Text (Status, "expected", "another state");
         E.Add_Text (Status, "detail", "it is " & Word (Value.Status) & " already, and only an active observation"
                     & " is dismissed, superseded or promoted");
      end if;
   end Take_Active;

   procedure Move
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : in out Observation;
      Claim  : String;
      To     : Lifecycle;
      Event  : Events.Event_Kind;
      Detail : String;
      Status : out E.Error_Info)
   is
      Emitted : Unbounded_String;
   begin
      Value.Status := To;
      Value.Revision := Value.Revision + 1;
      Stores.Put (Change, Observations_Area, To_String (Value.Id), To_Record (Value, Claim));
      Events.Emit (Item, Change, Event, To_String (Value.Id), Detail, Emitted, Status);
   end Move;

   procedure Dismiss
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Reason : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Observation;
      Claim : Unbounded_String;
   begin
      Take_Active (Item, Change, Id, Value, Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Value.Reason := To_Unbounded_String (One_Line (Reason));
      Move (Item, Change, Value, To_String (Claim), Dismissed, Events.Observation_Dismissed,
            One_Line (Reason), Status);
   end Dismiss;

   procedure Supersede
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      By     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Observation;
      Other : Observation;
      Claim : Unbounded_String;
      Other_Claim : Unbounded_String;
   begin
      if Id = By then
         Refuse (Status, "what supersedes " & Id, By, "an observation is not superseded by itself");
         return;
      end if;
      Take_Active (Item, Change, By, Other, Other_Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Take_Active (Item, Change, Id, Value, Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Value.Superseded_By := To_Unbounded_String (By);
      Move (Item, Change, Value, To_String (Claim), Superseded, Events.Observation_Superseded,
            "by " & By, Status);
   end Supersede;

   --  Mark an observation promoted into something made from it.
   procedure Mark_Promoted
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : in out Observation;
      Claim  : String;
      Into   : String;
      Status : out E.Error_Info) is
   begin
      Value.Promoted_To := To_Unbounded_String (Into);
      Move (Item, Change, Value, Claim, Promoted, Events.Observation_Promoted, "into " & Into, Status);
   end Mark_Promoted;

   function Title_Of (Summary : String) return String
   is (if Summary'Length <= 80 then Summary else Summary (Summary'First .. Summary'First + 76) & "...");

   procedure Promote_To_Task
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Id      : String;
      Fields  : Tasks.Field_Map;
      Task_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Value  : Observation;
      Claim  : Unbounded_String;
      Filled : Tasks.Field_Map := Fields;
   begin
      Task_Id := Null_Unbounded_String;
      Take_Active (Item, Change, Id, Value, Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if not Filled.Contains ("title") then
         Filled.Include ("title", Title_Of (To_String (Value.Summary)));
      end if;
      if not Filled.Contains ("component") and then Length (Value.Component) > 0 then
         Filled.Include ("component", To_String (Value.Component));
      end if;
      Tasks.Create (Item, Change, Filled, "observation_promotion", Id, Task_Id, Status);
      if E.Is_Ok (Status) then
         Mark_Promoted (Item, Change, Value, To_String (Claim), To_String (Task_Id), Status);
      end if;
   end Promote_To_Task;

   procedure Promote_To_Fact
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Key    : String;
      Value  : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held  : Observation;
      Claim : Unbounded_String;
   begin
      Take_Active (Item, Change, Id, Held, Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Facts.Record_Fact
        (Item, Change,
         Facts.Fact'(Key        => To_Unbounded_String (Key),
                     Value      => To_Unbounded_String (Value),
                     Source     => Facts.Observation,
                     --  As sure as what it rests on: never authoritative.
                     Confidence => (if Held.Ground = Observed then Facts.Probable else Facts.Uncertain),
                     Origin     => To_Unbounded_String (Id)),
         Status);
      if E.Is_Ok (Status) then
         Mark_Promoted (Item, Change, Held, To_String (Claim), "fact:" & Key, Status);
      end if;
   end Promote_To_Fact;

   procedure Promote_To_Decision
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Id          : String;
      Key         : String;
      Title       : String;
      Text        : String;
      Scope       : String;
      Decision_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Held  : Observation;
      Claim : Unbounded_String;
   begin
      Decision_Id := Null_Unbounded_String;
      Take_Active (Item, Change, Id, Held, Claim, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Intent.Propose
        (Item, Change, Intent.Decision, Key,
         (if Title /= "" then Title else Title_Of (To_String (Held.Summary))),
         (if Text /= "" then Text else To_String (Held.Summary)),
         "", "user", "observation " & Id,
         (if Scope /= "" then Scope
          elsif Length (Held.Component) > 0 then To_String (Held.Component) else "project"),
         Decision_Id, Status);
      if E.Is_Ok (Status) then
         Mark_Promoted (Item, Change, Held, To_String (Claim), To_String (Decision_Id), Status);
      end if;
   end Promote_To_Decision;

   ---------------------------------------------------------------------------
   --  What work is told.
   ---------------------------------------------------------------------------

   --  The text an observation is told as.
   function Told
     (Value    : Observation;
      Standing : Applicability;
      Why      : String;
      Heat     : Temperature;
      Reason   : String) return String
   is
      Text : Unbounded_String :=
        To_Unbounded_String
          (To_String (Value.Id) & " -- an observation, not authoritative ("
           & Word (Value.Kind) & ", " & Word (Value.Ground)
           & (if Value.Occurrences > 1 then ", seen" & Natural'Image (Value.Occurrences) & " times" else "")
           & (if Length (Value.Task_Id) > 0 then ", first in " & To_String (Value.Task_Id) else "")
           & (if Length (Value.Generation) > 0 then " generation " & To_String (Value.Generation) else "")
           & (if Length (Value.Agent) > 0 then " by " & To_String (Value.Agent) else "")
           & "; " & Lower (Temperature'Image (Heat)) & ": " & Reason & "):" & LF
           & To_String (Value.Summary) & LF);
   begin
      if not Value.Evidence.Is_Empty then
         Append (Text, "evidence: " & Joined (Value.Evidence) & LF);
      end if;
      if not Value.Files.Is_Empty then
         Append (Text, "files: " & Joined (Value.Files) & LF);
      end if;
      if not Value.Symbols.Is_Empty then
         Append (Text, "symbols: " & Joined (Value.Symbols) & LF);
      end if;
      if Standing /= Applicable then
         Append (Text, "now " & Word (Standing) & ": " & Why
                 & " -- what it says held then, and may not now" & LF);
      end if;
      return To_String (Text);
   end Told;

   function Scalar (Item : Stores.Store; Name : String) return String is
   begin
      return Records.Get (Configurations.Required (Item), "scalar." & Name);
   exception
      when Configurations.Configuration_Unavailable =>
         return "";
   end Scalar;

   function Count_Of (Text : String; Default : Natural) return Natural
   is (if Text /= "" and then Text'Length <= 9 and then (for all C of Text => C in '0' .. '9')
       then Natural'Value (Text) else Default);

   --------------
   -- Relevant --
   --------------

   function Relevant
     (Item     : Stores.Store;
      Task_Id  : String;
      Excluded : out Name_Lists.Vector) return Considered_Vectors.Vector
   is
      Defined    : Records.Item;
      State      : Records.Item;
      Read       : E.Error_Info;
      Component  : Unbounded_String;
      Serves     : Name_Lists.Vector;
      Touches    : Name_Lists.Vector;
      Hot_List   : Considered_Vectors.Vector;
      Warm_List  : Considered_Vectors.Vector;
      Result     : Considered_Vectors.Vector;

      package Requirement_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (String, Name_Lists.Vector, "<", Name_Lists."=");
      Served_By : Requirement_Maps.Map;

      --  The requirements another task serves, read once each.
      function Served (Other : String) return Name_Lists.Vector is
         Held : Records.Item;
         Got  : E.Error_Info;
      begin
         if not Served_By.Contains (Other) then
            Tasks.Definition (Item, Other, Held, Got);
            Served_By.Include
              (Other, (if E.Is_Ok (Got) then Lines_Of (Records.Get (Held, "requirements"))
                       else Name_Lists.Empty_Vector));
         end if;
         return Served_By (Other);
      end Served;

   begin
      Excluded.Clear;
      if Lower (Scalar (Item, "knowledge.observations")) = "off" then
         return Result;
      end if;
      Tasks.Definition (Item, Task_Id, Defined, Read);
      if E.Is_Ok (Read) then
         Component := To_Unbounded_String (Records.Get (Defined, "component"));
         Serves := Lines_Of (Records.Get (Defined, "requirements"));
      end if;
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Read);
      if E.Is_Ok (Read) then
         Touches := Lines_Of (Records.Get (State, "changed_files"));
         if Records.Get (State, "current_verification") /= "" then
            declare
               Said : constant Verification.Diagnostic_List :=
                 Verification.Diagnostics_Of (Item, Records.Get (State, "current_verification"));
            begin
               for Index in 1 .. Verification.Length (Said) loop
                  declare
                     Path : constant String := To_String (Verification.Element (Said, Index).File);
                  begin
                     if Path /= "" and then not Touches.Contains (Path) then
                        Touches.Append (Path);
                     end if;
                  end;
               end loop;
            end;
         end if;
      end if;

      for Id of List (Item) loop
         declare
            Value : Observation;
            Got   : E.Error_Info;
            Held  : Records.Item;
         begin
            Read_Record (Item, Id, Held, Value, Got);
            if E.Is_Error (Got) then
               --  Not read is not irrelevant: said, so the manifest shows it.
               Excluded.Append (Id & ": would not read");
            elsif Length (Value.Retired) > 0 then
               Excluded.Append (Id & ": cold, retired");
            elsif Value.Status /= Active then
               Excluded.Append
                 (Id & ": cold, " & Word (Value.Status)
                  & (if Value.Status = Promoted then " into " & To_String (Value.Promoted_To)
                       & ", which says it with authority"
                     elsif Value.Status = Superseded then " by " & To_String (Value.Superseded_By)
                     else ""));
            else
               declare
                  Heat   : Temperature := Cold;
                  Reason : Unbounded_String;
                  Why    : Unbounded_String;
                  Standing : constant Applicability := Applicability_Of (Item, Value, Why);
               begin
                  --  Hot: about this very work.
                  if To_String (Value.Task_Id) = Task_Id
                    or else (for some Line of Value.Sightings => Starts (Line, Task_Id & " "))
                  then
                     Heat := Hot;
                     Reason := To_Unbounded_String ("found in this task");
                  else
                     for Path of Value.Files loop
                        if Touches.Contains (Path) then
                           Heat := Hot;
                           Reason := To_Unbounded_String ("about " & Path & ", which this task's work touches");
                           exit;
                        end if;
                     end loop;
                     if Heat = Cold and then Length (Value.Task_Id) > 0 then
                        for Requirement of Served (To_String (Value.Task_Id)) loop
                           if Serves.Contains (Requirement) then
                              Heat := Hot;
                              Reason := To_Unbounded_String ("found serving " & Requirement & ", as this task does");
                              exit;
                           end if;
                        end loop;
                     end if;
                  end if;
                  --  Warm: the same part of the project, or the whole of it.
                  if Heat = Cold then
                     if Length (Component) > 0 and then Value.Component = Component then
                        Heat := Warm;
                        Reason := To_Unbounded_String ("found in its component " & To_String (Component));
                     elsif Length (Component) > 0
                       and then not Repository.Component_Roots (Item, To_String (Component)).Is_Empty
                       and then (for some Path of Value.Files =>
                                   Repository.In_Component (Item, To_String (Component), Path))
                     then
                        Heat := Warm;
                        Reason := To_Unbounded_String ("about a file of its component " & To_String (Component));
                     elsif Value.Kind in Environment_Constraint | Tool_Behavior then
                        Heat := Warm;
                        Reason := To_Unbounded_String ("a caveat of the project's tools or machine");
                     end if;
                  end if;
                  --  What may no longer hold is not pressed on the work.
                  if Heat = Hot and then Standing /= Applicable then
                     Heat := Warm;
                     Append (Reason, "; " & Word (Standing));
                  end if;

                  if Heat = Cold then
                     Excluded.Append (Id & ": cold, unrelated to " & Task_Id);
                  else
                     declare
                        One : constant Considered :=
                          (Id       => Value.Id,
                           Revision => Value.Revision,
                           Heat     => Heat,
                           Standing => Standing,
                           Reason   => Reason,
                           Seen_At  => Value.Seen_At,
                           Text     => To_Unbounded_String
                             (Told (Value, Standing, To_String (Why), Heat, To_String (Reason))));
                     begin
                        if Heat = Hot then
                           Hot_List.Append (One);
                        else
                           Warm_List.Append (One);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  The most recently seen first; by number among the same moment.
      declare
         function Newer (Left, Right : Considered) return Boolean
         is (Left.Seen_At > Right.Seen_At
             or else (Left.Seen_At = Right.Seen_At and then Left.Id /= Right.Id
                      and then Later (To_String (Right.Id), To_String (Left.Id))));
         package By_Seen is new Considered_Vectors.Generic_Sorting (Newer);
         Max_Hot  : constant Natural := Count_Of (Scalar (Item, "knowledge.max_hot"), 5);
         Max_Warm : constant Natural := Count_Of (Scalar (Item, "knowledge.max_warm"), 5);
      begin
         By_Seen.Sort (Hot_List);
         By_Seen.Sort (Warm_List);
         for Index in 1 .. Natural (Hot_List.Length) loop
            if Index <= Max_Hot then
               Result.Append (Hot_List (Index));
            else
               Excluded.Append (To_String (Hot_List (Index).Id) & ": past knowledge.max_hot");
            end if;
         end loop;
         for Index in 1 .. Natural (Warm_List.Length) loop
            if Index <= Max_Warm then
               Result.Append (Warm_List (Index));
            else
               Excluded.Append (To_String (Warm_List (Index).Id) & ": past knowledge.max_warm");
            end if;
         end loop;
      end;
      return Result;
   end Relevant;

   --  What a failed verification failed on first: its first error, as
   --  file and message -- where it is, not which line, which moves -- or,
   --  where it reported none, the first of anything it reported: a build
   --  that takes its warnings for errors, a style rule, fails on those.
   procedure First_Error (Item : Stores.Store; Of_Evidence : String; File, Message : out Unbounded_String) is
      Said : constant Verification.Diagnostic_List := Verification.Diagnostics_Of (Item, Of_Evidence);
   begin
      File := Null_Unbounded_String;
      Message := Null_Unbounded_String;
      for Errors_Only in reverse Boolean loop
         for Index in 1 .. Verification.Length (Said) loop
            declare
               One : constant Verification.Diagnostic := Verification.Element (Said, Index);
            begin
               if not Errors_Only or else Lower (To_String (One.Severity)) = "error" then
                  File := One.File;
                  Message := To_Unbounded_String (One_Line (To_String (One.Message)));
                  return;
               end if;
            end;
         end loop;
      end loop;
   end First_Error;

   --  The last line a failed check wrote, where its log is kept: what a
   --  check that reports no diagnostic -- a test that raised -- said.
   function Last_Said (Item : Stores.Store; Value : Records.Item; Label : String) return String is
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field  : constant String := Records.Field_Name (Value, Index);
            Line   : constant String := Records.Get (Value, Field);
            Fields : Name_Lists.Vector;
            Start  : Positive := Line'First;
         begin
            if Starts (Field, "check.") then
               for At_Char in Line'First .. Line'Last + 1 loop
                  if At_Char > Line'Last or else Line (At_Char) = Tab then
                     Fields.Append (Line (Start .. At_Char - 1));
                     Start := At_Char + 1;
                  end if;
               end loop;
               if Natural (Fields.Length) >= 7 and then Fields (1) = Label
                 and then Starts (Fields (7), "RES-")
               then
                  declare
                     Log  : Results.Result;
                     Read : E.Error_Info;
                     Last : Unbounded_String;
                  begin
                     Results.Read (Item, Fields (7), Log, Read);
                     if E.Is_Ok (Read) then
                        for One of Lines_Of (To_String (Log.Payload)) loop
                           if Trim (One) /= "" then
                              Last := To_Unbounded_String (One_Line (One));
                           end if;
                        end loop;
                     end if;
                     return To_String (Last);
                  end;
               end if;
            end if;
         end;
      end loop;
      return "";
   end Last_Said;

   --  The first required check a verification failed, by its label; "".
   function Failed_Check (Value : Records.Item) return String is
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field  : constant String := Records.Field_Name (Value, Index);
            Fields : Name_Lists.Vector;
            Start  : Positive;
         begin
            if Starts (Field, "check.") then
               declare
                  Line : constant String := Records.Get (Value, Field);
               begin
                  Start := Line'First;
                  for At_Char in Line'First .. Line'Last + 1 loop
                     if At_Char > Line'Last or else Line (At_Char) = Tab then
                        Fields.Append (Line (Start .. At_Char - 1));
                        Start := At_Char + 1;
                     end if;
                  end loop;
                  if Natural (Fields.Length) >= 6 and then Fields (5) /= "passed" and then Fields (6) = "required" then
                     return Fields (1);
                  end if;
               end;
            end if;
         end;
      end loop;
      return "";
   end Failed_Check;

   --  Names as a sentence lists them: a, b and c.
   function Listed (Names : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Index in 1 .. Natural (Names.Length) loop
         Append (Text, (if Index = 1 then ""
                        elsif Index = Natural (Names.Length) then " and " else ", ") & Names (Index));
      end loop;
      return To_String (Text);
   end Listed;

   --  A harness's finding kept: its summary held to the length kept, its
   --  files those of the project, at most as many as one is about.
   procedure Keep_Harness
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Kind   : Observation_Kind;
      Summary : String;
      Files_Of : Name_Lists.Vector;
      Evidence : Name_Lists.Vector;
      From   : Origin;
      Id     : out Unbounded_String;
      Status : out E.Error_Info)
   is
      Said  : Draft;
      Fresh : Boolean;
   begin
      Said.Kind := Kind;
      Said.Summary := To_Unbounded_String
        (if Summary'Length > Summary_Most then Summary (Summary'First .. Summary'First + Summary_Most - 1)
         else Summary);
      for Path of Files_Of loop
         exit when Natural (Said.Files.Length) = Ties_Most;
         if Path /= "" and then not Is_Rooted (Path) and then not Starts (Path, "../")
           and then not Said.Files.Contains (Path)
         then
            Said.Files.Append (Path);
         end if;
      end loop;
      Said.Evidence := Evidence;
      Record_Observation (Item, Change, Said, From, Id, Fresh, Status);
   end Keep_Harness;

   ----------------
   -- Files_Said --
   ----------------

   function Files_Said (Root : String; Paths : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Path of Paths loop
         declare
            Held : Unbounded_String;
            Read : E.Error_Info;
            Full : constant String := Root & "/" & Path;
         begin
            if not Is_Rooted (Path) and then Ada.Directories.Exists (Full) then
               Files.Read_Text (Full, Held, Read);
               if E.Is_Ok (Read) then
                  Append (Text, Derivations.Coded (Path) & Tab & Derivations.Coded (To_String (Held)) & LF);
               end if;
            end if;
         exception
            when others =>
               --  A file the host will not let be read is not kept: what
               --  is said of the fix is then said without it.
               null;
         end;
      end loop;
      return To_String (Text);
   end Files_Said;

   ------------------
   -- Change_Since --
   ------------------

   function Change_Since (Root, Said : String) return String is
      Text : Unbounded_String;
   begin
      for Line of Lines_Of (Said) loop
         declare
            Fields : constant Name_Lists.Vector := Derivations.Fields_Of (Line);
         begin
            if Natural (Fields.Length) = 2 then
               declare
                  Now  : Unbounded_String;
                  Read : E.Error_Info;
                  Full : constant String := Root & "/" & Fields (1);
               begin
                  if Ada.Directories.Exists (Full) then
                     Files.Read_Text (Full, Now, Read);
                  end if;
                  declare
                     One : constant String := Change_Said (Fields (1), Fields (2), To_String (Now));
                  begin
                     if One /= "" then
                        Append (Text, (if Length (Text) = 0 then "" else " / ") & One);
                     end if;
                  end;
               exception
                  when others =>
                     --  A file the host will not let be read now says no
                     --  change: the fix is said without it.
                     null;
               end;
            end if;
         end;
      end loop;
      return To_String (Text);
   end Change_Since;

   -----------------
   -- Change_Said --
   -----------------

   function Change_Said (Path, Before, After : String) return String is
      Old_Lines : Name_Lists.Vector;
      New_Lines : Name_Lists.Vector;
      Said      : Unbounded_String;
      Count     : Natural := 0;
      Line_Most : constant := 100;
      Lines_Most : constant := 8;

      function Kept_Lines (Text : String) return Name_Lists.Vector is
         Result : Name_Lists.Vector;
      begin
         for One of Lines_Of (Text) loop
            if Trim (One) /= "" then
               Result.Append (Trim (One));
            end if;
         end loop;
         return Result;
      end Kept_Lines;

      --  Each line of From not matched by one of Against, once each.
      procedure Say (From, Against : Name_Lists.Vector; Mark : String) is
         Left : Name_Lists.Vector := Against;
      begin
         for One of From loop
            declare
               At_It : constant Name_Lists.Extended_Index := Left.Find_Index (One);
            begin
               if At_It /= Name_Lists.No_Index then
                  Left.Delete (At_It);
               elsif Count < Lines_Most then
                  Count := Count + 1;
                  Append (Said, (if Length (Said) = 0 then "" else " | ") & Mark & " "
                          & (if One'Length > Line_Most then One (One'First .. One'First + Line_Most - 1) & "..."
                             else One));
               end if;
            end;
         end loop;
      end Say;
   begin
      Old_Lines := Kept_Lines (Before);
      New_Lines := Kept_Lines (After);
      Say (Old_Lines, New_Lines, "-");
      Say (New_Lines, Old_Lines, "+");
      return (if Length (Said) = 0 then "" else Path & ": " & To_String (Said));
   end Change_Said;

   -----------------
   -- Observe_Fix --
   -----------------

   procedure Observe_Fix
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      Changed  : Name_Lists.Vector;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info;
      Fixed_By : String := "")
   is
      Value   : Records.Item;
      Read    : E.Error_Info;
      Before  : Unbounded_String;
   begin
      Id := Null_Unbounded_String;
      Status := E.Success;
      Stores.Read (Item, Verification_Area, Evidence, Value, Read);
      if E.Is_Error (Read) or else Records.Get (Value, "passed") /= "true" or else Changed.Is_Empty then
         return;
      end if;
      --  The task's verification just before this one.
      for Name of Stores.Names (Item, Verification_Area) loop
         if Name /= Evidence and then Later (Evidence, Name) and then Later (Name, To_String (Before)) then
            declare
               Earlier : Records.Item;
               Got     : E.Error_Info;
            begin
               Stores.Read (Item, Verification_Area, Name, Earlier, Got);
               if E.Is_Ok (Got) and then Records.Get (Earlier, "task") = Task_Id then
                  Before := To_Unbounded_String (Name);
               end if;
            end;
         end if;
      end loop;
      if Length (Before) = 0 then
         return;
      end if;
      declare
         Earlier : Records.Item;
         File, Message : Unbounded_String;
         Files_Of : Name_Lists.Vector;
      begin
         Stores.Read (Item, Verification_Area, To_String (Before), Earlier, Read);
         if E.Is_Error (Read) or else Records.Get (Earlier, "passed") /= "false" then
            return;
         end if;
         First_Error (Item, To_String (Before), File, Message);
         if Length (Message) = 0 and then Failed_Check (Earlier) = "" then
            return;
         end if;
         --  A compiler names a file as it was given it: calc.adb for
         --  src/calc.adb. The changed file it is, where one is.
         for Path of Changed loop
            if Length (File) > 0 and then Path /= To_String (File)
              and then Path'Length > Length (File)
              and then Path (Path'Last - Length (File) .. Path'Last) = "/" & To_String (File)
            then
               File := To_Unbounded_String (Path);
            end if;
         end loop;
         Files_Of.Append (To_String (File));
         for Path of Changed loop
            Files_Of.Append (Path);
         end loop;
         declare
            Check : constant String := Failed_Check (Earlier);
            Said  : constant String :=
              (if Length (Message) > 0
               then (if Length (File) > 0 then To_String (File) & ": " else "") & To_String (Message)
               elsif Check /= "" then Last_Said (Item, Earlier, Check) else "");
         begin
            Keep_Harness
              (Item, Change, Finding,
               "the checks of " & Records.Get (Earlier, "profile") & " failed"
               & (if Check /= "" then " at " & Check else "")
               & (if Said /= "" then ": " & Said else "")
               & ", and passed after changes to " & Listed (Changed)
               & (if Fixed_By /= "" then " -- " & Fixed_By else ""),
               Files_Of, [To_String (Before), Evidence], From, Id, Status);
         end;
      end;
   end Observe_Fix;

   ---------------------
   -- Observe_Refusal --
   ---------------------

   procedure Observe_Refusal
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Tool   : String;
      Why    : String;
      Path   : String;
      From   : Origin;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Keep_Harness
        (Item, Change, Environment_Constraint,
         Tool & (if Path /= "" then " of " & One_Line (Path) else "") & " was refused: " & One_Line (Why),
         [Path], Name_Lists.Empty_Vector, From, Id, Status);
   end Observe_Refusal;

   ------------------
   -- Observe_Done --
   ------------------

   procedure Observe_Done
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      Changed  : Name_Lists.Vector;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Defined : Records.Item;
      Value   : Records.Item;
      Read    : E.Error_Info;
   begin
      Id := Null_Unbounded_String;
      Status := E.Success;
      if Changed.Is_Empty then
         return;
      end if;
      Tasks.Definition (Item, Task_Id, Defined, Read);
      if E.Is_Error (Read) then
         return;
      end if;
      Stores.Read (Item, Verification_Area, Evidence, Value, Read);
      declare
         Kept_Read : constant E.Error_Info := Read;
      begin
         Keep_Harness
           (Item, Change, Implementation_Note,
            Task_Id & " (" & One_Line (Records.Get (Defined, "title")) & ") was done by changing "
            & Listed (Changed)
            & (if E.Is_Ok (Kept_Read) and then Records.Get (Value, "passed") = "true"
               then "; the checks of " & Records.Get (Value, "profile") & " passed" else ""),
            Changed, (if E.Is_Ok (Kept_Read) then Name_Lists.To_Vector (Evidence, 1) else Name_Lists.Empty_Vector),
            From, Id, Status);
      end;
      if E.Is_Error (Status) or else Length (Id) = 0 then
         return;
      end if;
      --  What it says of its files is newer than what an earlier task's
      --  note said of the same ones, or of some of them: that note is
      --  superseded by this, so a file worked on often is told once.
      for Name of List (Item) loop
         if Name /= To_String (Id) then
            declare
               Other : Observation;
               Got   : E.Error_Info;
            begin
               Observations.Read (Item, Name, Other, Got);
               if E.Is_Ok (Got) and then Other.Status = Active and then Other.Kind = Implementation_Note
                 and then Other.Producer = Harness_Producer and then not Other.Files.Is_Empty
                 and then (for all Path of Other.Files => Changed.Contains (Path))
               then
                  Supersede (Item, Change, Name, To_String (Id), Got);
                  if E.Is_Error (Got) then
                     Status := Got;
                     return;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Observe_Done;

   ---------------------
   -- Observe_Failure --
   ---------------------

   procedure Observe_Failure
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Value   : Records.Item;
      Read    : E.Error_Info;
      File    : Unbounded_String;
      Message : Unbounded_String;
   begin
      Id := Null_Unbounded_String;
      Status := E.Success;
      Stores.Read (Item, Verification_Area, Evidence, Value, Read);
      if E.Is_Error (Read) or else Records.Get (Value, "passed") /= "false" then
         return;
      end if;
      First_Error (Item, Evidence, File, Message);
      if Length (Message) = 0 then
         return;
      end if;
      --  The same first error in an earlier verification of the task.
      for Name of Stores.Names (Item, Verification_Area) loop
         if Name /= Evidence and then Later (Evidence, Name) then
            declare
               Earlier : Records.Item;
               Got     : E.Error_Info;
               Then_File, Then_Message : Unbounded_String;
            begin
               Stores.Read (Item, Verification_Area, Name, Earlier, Got);
               if E.Is_Ok (Got) and then Records.Get (Earlier, "task") = Task_Id
                 and then Records.Get (Earlier, "passed") = "false"
                 and then Records.Get (Earlier, "profile") = Records.Get (Value, "profile")
               then
                  First_Error (Item, Name, Then_File, Then_Message);
                  if Then_File = File and then Then_Message = Message then
                     declare
                        Said  : Draft;
                        Fresh : Boolean;
                     begin
                        Said.Kind := Failure_Pattern;
                        Said.Summary := To_Unbounded_String
                          ("the checks of " & Records.Get (Value, "profile") & " fail again as they failed before: "
                           & (if Length (File) > 0 then To_String (File) & ": " else "") & To_String (Message));
                        if Length (Said.Summary) > Summary_Most then
                           Said.Summary := Unbounded_Slice (Said.Summary, 1, Summary_Most);
                        end if;
                        Said.Evidence.Append (Name);
                        Said.Evidence.Append (Evidence);
                        if Length (File) > 0 and then not Is_Rooted (To_String (File)) then
                           Said.Files.Append (To_String (File));
                        end if;
                        Record_Observation (Item, Change, Said, From, Id, Fresh, Status);
                        return;
                     end;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Observe_Failure;

   -----------
   -- Prune --
   -----------

   procedure Prune
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Days    : Natural;
      Retired : out Natural)
   is
      use type Ada.Calendar.Time;
      Cut : Unbounded_String;
   begin
      Retired := 0;
      if Days = 0 then
         return;
      end if;
      declare
         Text : String := Ada.Calendar.Formatting.Image (Ada.Calendar.Clock - Duration (Days) * 86_400.0);
      begin
         Text (Text'First + 10) := 'T';
         Cut := To_Unbounded_String (Text & "Z");
      end;
      for Id of List (Item) loop
         declare
            Held  : Records.Item;
            Value : Observation;
            Got   : E.Error_Info;
         begin
            Read_Record (Item, Id, Held, Value, Got);
            if E.Is_Ok (Got) and then Value.Status in Superseded | Dismissed
              and then Length (Value.Retired) = 0
              and then To_String (Value.Seen_At) < To_String (Cut)
            then
               --  A tombstone: what it was, and why it went, not what it said.
               Value.Summary := Null_Unbounded_String;
               Value.Files.Clear;
               Value.File_Prints.Clear;
               Value.Symbols.Clear;
               Value.Retired := To_Unbounded_String ("retention.observation_days " & Timestamp);
               Value.Revision := Value.Revision + 1;
               Stores.Put (Change, Observations_Area, Id, To_Record (Value, Records.Get (Held, "claim")));
               Retired := Retired + 1;
            end if;
         end;
      end loop;
   end Prune;

   ------------------
   -- Retire_Stale --
   ------------------

   procedure Retire_Stale
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Days      : Natural;
      Dismissed : out Natural)
   is
      use type Ada.Calendar.Time;
      Cut : Unbounded_String;
   begin
      Dismissed := 0;
      if Days = 0 then
         return;
      end if;
      declare
         Text : String := Ada.Calendar.Formatting.Image (Ada.Calendar.Clock - Duration (Days) * 86_400.0);
      begin
         Text (Text'First + 10) := 'T';
         Cut := To_Unbounded_String (Text & "Z");
      end;
      for Id of List (Item) loop
         declare
            Value  : Observation;
            Got    : E.Error_Info;
            Why    : Unbounded_String;
         begin
            Read (Item, Id, Value, Got);
            if E.Is_Ok (Got) and then Value.Status = Active
              and then To_String (Value.Seen_At) < To_String (Cut)
              and then Applicability_Of (Item, Value, Why) = Stale
            then
               Dismiss (Item, Change, Id,
                        "stale and not seen again for" & Natural'Image (Days) & " days (retention.stale_days): "
                        & To_String (Why), Got);
               if E.Is_Ok (Got) then
                  Dismissed := Dismissed + 1;
               end if;
            end if;
         end;
      end loop;
   end Retire_Stale;

end Model_Runner.Framework.Observations;
