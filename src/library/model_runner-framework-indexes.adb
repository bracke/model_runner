with Ada.Characters.Handling;
with Ada.Strings.Fixed;
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

   function Six (Value : Natural) return String is
      Plain : constant String := Image (Value);
   begin
      return (if Plain'Length >= 6 then Plain else [1 .. 6 - Plain'Length => '0'] & Plain);
   end Six;

   --  What the indexes are built from: the repository's fingerprint and
   --  the last change the state recorded.
   function Source_Of (Item : Stores.Store; Found : Repository.Graph) return String is
      Listed : constant Events.Event_List := Events.Since (Item, 0);
      Last   : constant String :=
        (if Events.Length (Listed) = 0 then "0"
         else To_String (Events.Element (Listed, Events.Length (Listed)).Id));
   begin
      return Repository.Graph_Fingerprint (Found) & " " & Last;
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

      procedure Keep (Which : Index_Name; Lines : Name_Lists.Vector) is
         Value : Records.Item :=
           Records.Create
             (Schemas.Derived_Index_Schema, 1, "INDEX-" & Ada.Characters.Handling.To_Upper (Name_Of (Which)),
              Stores.Current_Revision (Item, Indexes_Area, Name_Of (Which)) + 1);
      begin
         Records.Set (Value, "source", Source);
         for Index in 1 .. Natural (Lines.Length) loop
            Records.Set (Value, "entry." & Six (Index), Lines (Index));
         end loop;
         Stores.Put (Change, Indexes_Area, Name_Of (Which), Value);
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
      if E.Is_Ok (Read) then
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
      end if;
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

      --  A test file, and the units it depends on.
      Lines.Clear;
      for Index in 1 .. Repository.File_Count (Found) loop
         declare
            use type Repository.File_Role;
            use type Repository.Relation_Kind;
            File  : constant Repository.File_Entry := Repository.File_At (Found, Index);
            Units : Unbounded_String;
         begin
            if File.Role = Repository.Test then
               for At_Index in 1 .. Repository.Relation_Count (Found) loop
                  declare
                     Link : constant Repository.Relation := Repository.Relation_At (Found, At_Index);
                  begin
                     if Link.Kind = Repository.Depends_On and then Link.Origin = File.Path then
                        Append (Units, (if Units = Null_Unbounded_String then "" else " ") & Link.To);
                     end if;
                  end;
               end loop;
               Lines.Append (To_String (File.Path) & Tab & To_String (Units));
            end if;
         end;
      end loop;
      Keep (Tests_Index, Lines);

      Lines.Clear;
      declare
         Traced : constant Traceability.Graph := Traceability.Build (Item, Found);
      begin
         for Index in 1 .. Traceability.Edge_Count (Traced) loop
            declare
               One : constant Traceability.Edge := Traceability.Edge_At (Traced, Index);
            begin
               Lines.Append (To_String (One.From) & Tab & To_String (One.Kind) & Tab & To_String (One.To));
            end;
         end loop;
      end;
      Keep (Traceability_Index, Lines);

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
   end Build;

   -------------
   -- Current --
   -------------

   function Current (Item : Stores.Store; Found : Repository.Graph) return Boolean is
      Source : constant String := Source_Of (Item, Found);
   begin
      for Which in Index_Name loop
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            if not Stores.Exists (Item, Indexes_Area, Name_Of (Which)) then
               return False;
            end if;
            Stores.Read (Item, Indexes_Area, Name_Of (Which), Value, Read);
            if E.Is_Error (Read) or else Records.Get (Value, "source") /= Source then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Current;

   -------------
   -- Entries --
   -------------

   function Entries (Item : Stores.Store; Which : Index_Name) return Name_Lists.Vector is
      Value  : Records.Item;
      Read   : E.Error_Info;
      Result : Name_Lists.Vector;
   begin
      if Stores.Exists (Item, Indexes_Area, Name_Of (Which)) then
         Stores.Read (Item, Indexes_Area, Name_Of (Which), Value, Read);
         if E.Is_Ok (Read) then
            for Index in 1 .. Records.Field_Count (Value) loop
               if Ada.Strings.Fixed.Index (Records.Field_Name (Value, Index), "entry.") = 1 then
                  Result.Append (Records.Get (Value, Records.Field_Name (Value, Index)));
               end if;
            end loop;
         end if;
      end if;
      return Result;
   end Entries;

end Model_Runner.Framework.Indexes;
