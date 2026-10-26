with Interfaces;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Traceability;

package body Model_Runner.Framework.Indexes is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   Tab : constant Character := ASCII.HT;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  Its name in the indexes: requirements, tasks and so on.
   function Name_Of (Which : Index_Name) return String is
      Full : constant String := Lower (Index_Name'Image (Which));
   begin
      return Full (Full'First .. Full'Last - 6);
   end Name_Of;

   --  The record that says what the indexes were last built from.
   Built_Name : constant String := "built";

   --  The name a part of an index's entries is kept under.
   function Part_Name (Which : Index_Name; Part : Positive) return String
   is (Name_Of (Which) & "-part-" & Records.Numbered (Part, Part));

   --  What a field takes in a record past its value, about.
   Field_Bytes : constant := 32;

   package Unit_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Unbounded_String,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  How the indexes are made from the graph: built by a builder that
   --  makes them otherwise, they are built again. 1: the first counted.
   Builder_Version : constant String := "1";

   --  What the indexes are built from: the repository's fingerprint, the
   --  last change the state recorded -- and how the source was read and
   --  the indexes made from it: a reader that reads the same bytes into
   --  other units and uses left indexes of the old reading current.
   function Source_Of (Item : Stores.Store; Found : Repository.Graph) return String is
      --  The newest alone: the log is not read whole for one name.
      Listed : constant Events.Event_List := Events.Latest (Item, 1);
      Last   : constant String :=
        (if Events.Length (Listed) = 0 then "0"
         else To_String (Events.Element (Listed, Events.Length (Listed)).Id));
   begin
      return Repository.Graph_Fingerprint (Found) & " " & Last
        & " reader " & Repository.Reader_Version & " builder " & Builder_Version;
   end Source_Of;

   -----------
   -- Build --
   -----------

   procedure Build
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Repository.Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Source : constant String := Source_Of (Item, Found);

      --  An index is written only where what it lists changed: most
      --  changes touch one of them, and the others are megabytes.
      procedure Keep (Which : Index_Name; Lines : Name_Lists.Vector) is
         Count : constant Natural := Natural (Lines.Length);

         --  Its entries' bytes: whether they go in parts.
         Spread : Long_Long_Integer := 0;
         Parts  : Natural := 0;

         --  The fields of the entries from First to Last, in Into.
         procedure Set_Entries (Into : in out Records.Item; First, Last : Natural) is
         begin
            for Index in First .. Last loop
               Records.Set (Into, "entry." & Records.Numbered (Index, Count), Lines (Index));
            end loop;
         end Set_Entries;

         --  The part of the entries from First to Last, kept.
         procedure Put_Part (First, Last : Natural) is
            Part : Records.Item :=
              Records.Create
                (Schemas.Derived_Index_Schema, 1,
                 "INDEX-" & Ada.Characters.Handling.To_Upper (Name_Of (Which))
                 & "-PART-" & Records.Numbered (Parts + 1, Parts + 1),
                 Stores.Current_Revision (Item, Indexes_Area, Part_Name (Which, Parts + 1)) + 1);
         begin
            Parts := Parts + 1;
            Records.Set (Part, "source", Source);
            Set_Entries (Part, First, Last);
            Stores.Put (Change, Indexes_Area, Part_Name (Which, Parts), Part);
         end Put_Part;
         --  The fingerprint of its lines, each with its line break, kept in
         --  its record: an index whose lines are the ones kept is not written
         --  again -- nor read back to be compared, which for humanize's
         --  traceability was 320 MB at every opening after a change.
         Lines_Print : Interfaces.Unsigned_64 := Model_Runner.Framework.Hash ("");
      begin
         for Line of Lines loop
            Spread := Spread + Long_Long_Integer (Line'Length + Field_Bytes);
            Lines_Print := Model_Runner.Framework.Hash_On (Line & ASCII.LF, Lines_Print);
         end loop;
         if Stores.Exists (Item, Indexes_Area, Name_Of (Which)) then
            declare
               Held : Records.Item;
               Read : E.Error_Info;
            begin
               Stores.Read (Item, Indexes_Area, Name_Of (Which), Held, Read);
               if E.Is_Ok (Read)
                 and then Records.Get (Held, "print") = Model_Runner.Framework.Fingerprint_Of (Lines_Print)
               then
                  return;
               end if;
            end;
         end if;
         declare
            Value : Records.Item :=
              Records.Create
                (Schemas.Derived_Index_Schema, 1,
                 "INDEX-" & Ada.Characters.Handling.To_Upper (Name_Of (Which)),
                 Stores.Current_Revision (Item, Indexes_Area, Name_Of (Which)) + 1);
         begin
            --  Past what a record holds -- humanize's traceability, 2.5
            --  million edges and 320 MB, was refused, and every index with
            --  it -- the entries go in parts of their own; within it, in the
            --  index's record as always.
            if Spread <= Long_Long_Integer (Repository.Parts_At_Most) then
               Set_Entries (Value, 1, Count);
            else
               declare
                  First : Positive := 1;
                  Bytes : Long_Long_Integer := 0;
               begin
                  for Index in 1 .. Count loop
                     declare
                        Line : constant String := Lines (Index);
                        Size : constant Long_Long_Integer := Long_Long_Integer (Line'Length + Field_Bytes);
                     begin
                        if Bytes + Size > Long_Long_Integer (Repository.Parts_At_Most) and then Index > First then
                           Put_Part (First, Index - 1);
                           First := Index;
                           Bytes := 0;
                        end if;
                        Bytes := Bytes + Size;
                     end;
                  end loop;
                  Put_Part (First, Count);
               end;
               Records.Set (Value, "parts", Image (Parts));
            end if;
            Records.Set (Value, "print", Model_Runner.Framework.Fingerprint_Of (Lines_Print));
            Records.Set (Value, "source", Source);
            Stores.Put (Change, Indexes_Area, Name_Of (Which), Value);
         end;

         --  The parts a larger index kept past these: let go.
         declare
            Next : Positive := Parts + 1;
         begin
            while Stores.Exists (Item, Indexes_Area, Part_Name (Which, Next)) loop
               Stores.Remove (Change, Indexes_Area, Part_Name (Which, Next));
               Next := Next + 1;
            end loop;
         end;
      end Keep;

      function Register (Kind : Intent.Intent_Kind) return Name_Lists.Vector is
         Lines : Name_Lists.Vector;
      begin
         for Id of Intent.List (Item, Kind) loop
            declare
               Held : Intent.Entity;
               Read : E.Error_Info;
            begin
               Intent.Read (Item, Kind, Id, Held, Read);
               if E.Is_Ok (Read) then
                  Lines.Append (Id & Tab & To_String (Held.State) & Tab & To_String (Held.Scope)
                                & Tab & To_String (Held.Title));
               end if;
            end;
         end loop;
         return Lines;
      end Register;

      Lines : Name_Lists.Vector;
      Config : Records.Item;
      Read   : E.Error_Info;
   begin
      Status := E.Success;

      Keep (Requirements_Index, Register (Intent.Requirement));
      Keep (Decisions_Index, Register (Intent.Decision));

      for Id of Tasks.List (Item) loop
         declare
            Defined : Records.Item;
            Got     : E.Error_Info;
         begin
            Tasks.Definition (Item, Id, Defined, Got);
            Lines.Append (Id & Tab & Tasks.State_Of (Item, Id) & Tab & Records.Get (Defined, "kind")
                          & Tab & Records.Get (Defined, "title"));
         end;
      end loop;
      Keep (Tasks_Index, Lines);

      Lines.Clear;
      Configurations.Read (Item, Config, Read);
      if Configurations.Unreadable (Read) then
         Status := Read;
         return;
      end if;
      --  A component, and how many tasks are its.
      for Name of Lines_Of (Records.Get (Config, "set.components")) loop
         declare
            Held : Natural := 0;
         begin
            for Id of Tasks.List (Item) loop
               declare
                  Defined : Records.Item;
                  Got     : E.Error_Info;
               begin
                  Tasks.Definition (Item, Id, Defined, Got);
                  if Records.Get (Defined, "component") = Name then
                     Held := Held + 1;
                  end if;
               end;
            end loop;
            Lines.Append (Name & Tab & Image (Held));
         end;
      end loop;
      Keep (Components_Index, Lines);

      Lines.Clear;
      for Index in 1 .. Repository.Symbol_Count (Found) loop
         declare
            Named : constant Repository.Symbol := Repository.Symbol_At (Found, Index);
         begin
            Lines.Append (To_String (Named.Name) & Tab & To_String (Named.Kind) & Tab
                          & To_String (Named.Path) & ":" & Image (Named.Line));
         end;
      end loop;
      Keep (Symbols_Index, Lines);

      --  A test file, and the units it depends on: what each file depends
      --  on gathered in one walk of the relations.
      Lines.Clear;
      declare
         use type Repository.File_Role;
         use type Repository.Relation_Kind;
         Tests_Of : Unit_Maps.Map;
      begin
         for Index in 1 .. Repository.File_Count (Found) loop
            if Repository.File_At (Found, Index).Role = Repository.Test then
               Tests_Of.Include (To_String (Repository.File_At (Found, Index).Path),
                                 Null_Unbounded_String);
            end if;
         end loop;
         if not Tests_Of.Is_Empty then
            for At_Index in 1 .. Repository.Relation_Count (Found) loop
               declare
                  Link : constant Repository.Relation := Repository.Relation_At (Found, At_Index);
                  Place : constant Unit_Maps.Cursor := Tests_Of.Find (To_String (Link.Origin));
               begin
                  if Link.Kind = Repository.Depends_On and then Unit_Maps.Has_Element (Place) then
                     declare
                        Units : Unbounded_String renames Tests_Of.Reference (Place);
                     begin
                        Append (Units, (if Units = Null_Unbounded_String then "" else " ") & Link.To);
                     end;
                  end if;
               end;
            end loop;
         end if;
         for Index in 1 .. Repository.File_Count (Found) loop
            declare
               File : constant Repository.File_Entry := Repository.File_At (Found, Index);
            begin
               if File.Role = Repository.Test then
                  Lines.Append (To_String (File.Path) & Tab
                                & To_String (Tests_Of.Element (To_String (File.Path))));
               end if;
            end;
         end loop;
      end;
      Keep (Tests_Index, Lines);

      --  Traceability is made when asked (Entries), not kept: millions of
      --  edges in a large tree -- 2.57 million, 320 MB, for humanize --
      --  built and written at every change, and read by nothing. A copy an
      --  earlier version kept, and its parts, are let go.
      if Stores.Exists (Item, Indexes_Area, Name_Of (Traceability_Index)) then
         Stores.Remove (Change, Indexes_Area, Name_Of (Traceability_Index));
         declare
            Next : Positive := 1;
         begin
            while Stores.Exists (Item, Indexes_Area, Part_Name (Traceability_Index, Next)) loop
               Stores.Remove (Change, Indexes_Area, Part_Name (Traceability_Index, Next));
               Next := Next + 1;
            end loop;
         end;
      end if;

      Lines.Clear;
      for Index in 1 .. Repository.Relation_Count (Found) loop
         declare
            use type Repository.Relation_Kind;
            Link : constant Repository.Relation := Repository.Relation_At (Found, Index);
         begin
            if Link.Kind = Repository.Depends_On then
               Lines.Append (To_String (Link.From) & Tab & To_String (Link.To));
            end if;
         end;
      end loop;
      Keep (Dependency_Index, Lines);

      --  Every name, by its last part in lower case, and what it is.
      Lines.Clear;
      for Index in 1 .. Repository.Symbol_Count (Found) loop
         declare
            Full : constant String := To_String (Repository.Symbol_At (Found, Index).Name);
            Dot  : constant Natural := Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
         begin
            Lines.Append (Lower (if Dot = 0 then Full else Full (Dot + 1 .. Full'Last)) & Tab & Full);
         end;
      end loop;
      Keep (Search_Index, Lines);

      --  What they were built from, said once for them all.
      declare
         Built : Records.Item :=
           Records.Create
             (Schemas.Derived_Index_Schema, 1, "INDEX-BUILT",
              Stores.Current_Revision (Item, Indexes_Area, Built_Name) + 1);
      begin
         Records.Set (Built, "source", Source);
         Stores.Put (Change, Indexes_Area, Built_Name, Built);
      end;
   end Build;

   -------------
   -- Current --
   -------------

   function Current (Item : Stores.Store; Found : Repository.Graph) return Boolean is
      Value : Records.Item;
      Read  : E.Error_Info;
   begin
      for Which in Index_Name loop
         if Which /= Traceability_Index
           and then not Stores.Exists (Item, Indexes_Area, Name_Of (Which))
         then
            return False;
         end if;
      end loop;
      if not Stores.Exists (Item, Indexes_Area, Built_Name) then
         return False;
      end if;
      Stores.Read (Item, Indexes_Area, Built_Name, Value, Read);
      return E.Is_Ok (Read) and then Records.Get (Value, "source") = Source_Of (Item, Found);
   end Current;

   -------------
   -- Entries --
   -------------

   function Entries (Item : Stores.Store; Which : Index_Name) return Name_Lists.Vector is
      Value  : Records.Item;
      Read   : E.Error_Info;
      Result : Name_Lists.Vector;

      procedure Take (From : Records.Item) is
      begin
         for Index in 1 .. Records.Field_Count (From) loop
            if Ada.Strings.Fixed.Index (Records.Field_Name (From, Index), "entry.") = 1 then
               Result.Append (Records.Field_Value (From, Index));
            end if;
         end loop;
      end Take;
   begin
      --  Traceability, made now from the graph as it is.
      if Which = Traceability_Index then
         declare
            Traced : constant Traceability.Graph := Traceability.Build (Item, Repository.Now (Item));
         begin
            for Index in 1 .. Traceability.Edge_Count (Traced) loop
               declare
                  One : constant Traceability.Edge := Traceability.Edge_At (Traced, Index);
               begin
                  Result.Append (To_String (One.From) & Tab & To_String (One.Kind) & Tab & To_String (One.To));
               end;
            end loop;
            return Result;
         end;
      end if;
      if Stores.Exists (Item, Indexes_Area, Name_Of (Which)) then
         Stores.Read (Item, Indexes_Area, Name_Of (Which), Value, Read);
         if E.Is_Ok (Read) then
            Take (Value);
            --  Its entries in parts: each built from what the index was,
            --  or the index is taken to say nothing.
            if Records.Get (Value, "parts") /= "" then
               for Part in 1 .. Natural'Value (Records.Get (Value, "parts")) loop
                  declare
                     Held : Records.Item;
                  begin
                     Stores.Read (Item, Indexes_Area, Part_Name (Which, Part), Held, Read);
                     if E.Is_Error (Read) or else Records.Get (Held, "source") /= Records.Get (Value, "source") then
                        Result.Clear;
                        return Result;
                     end if;
                     Take (Held);
                  end;
               end loop;
            end if;
         end if;
      end if;
      return Result;
   exception
      when Constraint_Error =>
         Result.Clear;
         return Result;
   end Entries;

end Model_Runner.Framework.Indexes;
