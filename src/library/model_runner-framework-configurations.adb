with Ada.Strings.Fixed;
with Ada.Directories;

with Hostkit.Fs;

with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Indexes;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;

package body Model_Runner.Framework.Configurations is

   use Ada.Strings.Unbounded;
   use type Templates.Setting_Kind;
   use type Templates.Input_Kind;

   package E renames Model_Runner.Errors;

   Current_Name     : constant String := "resolved";
   First_History    : constant String := "revision-000001";
   Current_Entity   : constant String := "CONFIG";
   History_Entity   : constant String := "CONFIG-000001";
   Directory_Input  : constant String := "directory_name";
   Name_Input       : constant String := "project_name";
   Directories_Key  : constant String := "directories";

   --  The words of a comma-separated list, trimmed.
   function Choices_Of (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;

      function Trim (Part : String) return String is
         First : Natural := Part'First;
         Last  : Natural := Part'Last;
      begin
         while First <= Last and then Part (First) = ' ' loop
            First := First + 1;
         end loop;
         while Last >= First and then Part (Last) = ' ' loop
            Last := Last - 1;
         end loop;
         return Part (First .. Last);
      end Trim;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ',' then
            if Trim (Text (Start .. Index - 1)) /= "" then
               Result.Append (Trim (Text (Start .. Index - 1)));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Choices_Of;

   type Text_Access is access constant String;

   --  Where a configuration came from, which is not what it says: two
   --  templates that resolve to the same declarations configure a project
   --  the same way.
   Provenance : constant array (1 .. 5) of Text_Access :=
     [new String'("template_id"),
      new String'("template_version"),
      new String'("template_fingerprint"),
      new String'("template_origin"),
      new String'("template_order")];

   --  A record's fields copied onto another header.
   function Copy
     (Value     : Records.Item;
      Entity_Id : String) return Records.Item
   is
      Result : Records.Item :=
        Records.Create
          (Records.Schema_Id (Value), Records.Schema_Version (Value), Entity_Id,
           1);
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         Records.Set
           (Result, Records.Field_Name (Value, Index),
            Records.Get (Value, Records.Field_Name (Value, Index)));
      end loop;
      return Result;
   end Copy;

   -------------------------------
   -- Configuration_Fingerprint --
   -------------------------------

   function Configuration_Fingerprint (Value : Records.Item) return String is
      Meaning : Records.Item := Copy (Value, Current_Entity);
   begin
      Records.Remove (Meaning, "configuration_fingerprint");
      for Field of Provenance loop
         Records.Remove (Meaning, Field.all);
      end loop;
      return Records.Fingerprint_Of (Meaning);
   end Configuration_Fingerprint;

   -----------------
   -- Check_Input --
   -----------------

   package Sorting is new Name_Lists.Generic_Sorting;

   --------------
   -- Resolved --
   --------------

   function Resolved
     (Declared          : Templates.Input_Declaration;
      Project_Directory : String) return Templates.Input_Declaration
   is
      Result   : Templates.Input_Declaration := Declared;
      Provider : constant String := To_String (Declared.Provider);
      Found    : Unbounded_String;
      Names    : Name_Lists.Vector;
      Search   : Ada.Directories.Search_Type;
      Item     : Ada.Directories.Directory_Entry_Type;
      use type Ada.Directories.File_Kind;
   begin
      if Provider = "" or else not Ada.Directories.Exists (Project_Directory) then
         return Result;
      end if;
      Ada.Directories.Start_Search
        (Search, Project_Directory,
         (if Provider = "directories" then "" else Provider (Provider'First + 6 .. Provider'Last)),
         [Ada.Directories.Directory     => Provider = "directories",
          Ada.Directories.Ordinary_File => Provider /= "directories",
          others                        => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            --  Nothing hidden, the project's state and version control
            --  among it.
            if Name'Length > 0 and then Name (Name'First) /= '.' then
               Names.Append (Name);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Sorting.Sort (Names);
      for Name of Names loop
         Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Name);
      end loop;
      Result.Kind := Templates.Choice_Input;
      Result.Choices := Found;
      return Result;
   exception
      when others =>
         return Result;
   end Resolved;

   --  Whether a text matches a pattern: * any run of characters, ? any
   --  one, anything else itself.
   function Matches (Text, Pattern : String) return Boolean is
   begin
      if Pattern = "" then
         return Text = "";
      elsif Pattern (Pattern'First) = '*' then
         for Skip in 0 .. Text'Length loop
            if Matches (Text (Text'First + Skip .. Text'Last),
                        Pattern (Pattern'First + 1 .. Pattern'Last))
            then
               return True;
            end if;
         end loop;
         return False;
      elsif Text = "" then
         return False;
      elsif Pattern (Pattern'First) = '?' or else Pattern (Pattern'First) = Text (Text'First) then
         return Matches (Text (Text'First + 1 .. Text'Last), Pattern (Pattern'First + 1 .. Pattern'Last));
      end if;
      return False;
   end Matches;

   procedure Check_Input
     (Declared : Templates.Input_Declaration;
      Value    : String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", To_String (Declared.Id));
         E.Add_Text (Status, "value", Value);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Status := E.Success;

      if (for some Char of Value => Char < ' ') then
         Refuse ("it holds a control character");
         return;
      end if;

      case Declared.Kind is
         when Templates.Text_Input =>
            null;

         when Templates.Identifier_Input =>
            if Value = "" or else Value (Value'First) not in 'a' .. 'z' | 'A' .. 'Z'
              or else not (for all Char of Value =>
                             Char in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_')
            then
               Refuse ("it is not an identifier");
            end if;

         when Templates.Natural_Input =>
            if Value'Length not in 1 .. 9
              or else not (for all Char of Value => Char in '0' .. '9')
            then
               Refuse ("it is not a whole number");
            end if;

         when Templates.Path_Input =>
            if Value = "" then
               Refuse ("it is not a path");
            end if;

         when Templates.Choice_Input =>
            if not Choices_Of (To_String (Declared.Choices)).Contains (Value)
            then
               Refuse ("it is not one of " & To_String (Declared.Choices));
            end if;

         when Templates.Boolean_Input =>
            if Value not in "true" | "false" then
               Refuse ("it is not true or false");
            end if;
      end case;
      if E.Is_Error (Status) then
         return;
      end if;

      --  The rules beyond its type.
      if Value'Length > Declared.Max_Length then
         Refuse ("it is longer than" & Natural'Image (Declared.Max_Length) & " characters");
      elsif Declared.Kind = Templates.Natural_Input
        and then (Natural'Value (Value) < Declared.Minimum
                  or else Natural'Value (Value) > Declared.Maximum)
      then
         Refuse ("it is not between" & Natural'Image (Declared.Minimum) & " and"
                 & Natural'Image (Declared.Maximum));
      elsif Declared.Pattern /= Null_Unbounded_String
        and then not Matches (Value, To_String (Declared.Pattern))
      then
         Refuse ("it does not match " & To_String (Declared.Pattern));
      end if;
   end Check_Input;

   -------------
   -- Prepare --
   -------------

   procedure Prepare
     (Composed          : Templates.Composition;
      Project_Directory : String;
      Given             : Value_Maps.Map;
      Result            : out Plan;
      Status            : out Model_Runner.Errors.Error_Info)
   is
      Root_Template : constant Templates.Template := Templates.Root (Composed);

      Directory_Name : constant String :=
        (declare
           Full : constant String := Ada.Directories.Full_Name (Project_Directory);
         begin
           Ada.Directories.Simple_Name (Full));

      --  What ${name} may name: the inputs resolved so far, and the
      --  directory's name.
      Known   : Value_Maps.Map;
      Secrets : Name_Lists.Vector;
      Found   : Value_Maps.Map;

      procedure Invalid (Detail : String) is
      begin
         Status := E.Make (E.Framework_Template_Invalid);
         E.Add_Text
           (Status, "path", Templates.Origin (Root_Template), E.Param_Path);
         E.Add_Text (Status, "detail", Detail);
      end Invalid;

      --  A value with the inputs it names written in.
      function Substitute (Text : String) return String is
         Output : Unbounded_String;
         Index  : Natural := Text'First;
      begin
         while Index <= Text'Last loop
            if Index < Text'Last and then Text (Index .. Index + 1) = "${" then
               declare
                  Close : Natural := 0;
               begin
                  for Scan in Index + 2 .. Text'Last loop
                     if Text (Scan) = '}' then
                        Close := Scan;
                        exit;
                     end if;
                  end loop;

                  if Close = 0 then
                     Invalid ("a ${ in " & Text & " is never closed");
                     return "";
                  end if;

                  declare
                     Name : constant String := Text (Index + 2 .. Close - 1);
                  begin
                     if Secrets.Contains (Name) then
                        Invalid ("the secret " & Name
                                 & " would be written into the configuration");
                        return "";
                     elsif not Known.Contains (Name) then
                        Invalid ("${" & Name & "} names no input declared"
                                 & " before it");
                        return "";
                     end if;
                     Append (Output, Known (Name));
                  end;
                  Index := Close + 1;
               end;
            else
               Append (Output, Text (Index));
               Index := Index + 1;
            end if;
         end loop;
         return To_String (Output);
      end Substitute;
   begin
      Result := (others => <>);
      Status := E.Success;
      Known.Include (Directory_Input, Directory_Name);

      --  Discovery first: what the project already is decides inputs the
      --  caller then need not be asked.
      for Index in 1 .. Templates.Rule_Count (Composed) loop
         declare
            Rule : constant Templates.Discovery_Rule :=
              Templates.Rule_At (Composed, Index);
         begin
            if Ada.Directories.Exists
                 (Hostkit.Fs.Join (Project_Directory, To_String (Rule.Path)))
            then
               if Rule.To_Input then
                  Found.Include (To_String (Rule.Key), To_String (Rule.Value));
               else
                  Result.Discovered_Facts.Include
                    (To_String (Rule.Key), To_String (Rule.Value));
               end if;
            end if;
         end;
      end loop;

      --  An input given that no template asks for is a mistake to say, not
      --  a value to drop.
      for Position in Given.Iterate loop
         declare
            Name  : constant String := Value_Maps.Key (Position);
            Asked : Boolean := False;
         begin
            for Index in 1 .. Templates.Input_Count (Composed) loop
               Asked := Asked or else To_String
                 (Templates.Input_At (Composed, Index).Id) = Name;
            end loop;
            if not Asked then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", Name);
               E.Add_Text (Status, "value", Value_Maps.Element (Position));
               E.Add_Text (Status, "detail", "no template composed asks for it");
               return;
            end if;
         end;
      end loop;

      for Index in 1 .. Templates.Input_Count (Composed) loop
         declare
            Declared : constant Templates.Input_Declaration :=
              Resolved (Templates.Input_At (Composed, Index), Project_Directory);
            Id       : constant String := To_String (Declared.Id);
            Value    : Unbounded_String;
            Has      : Boolean := True;
         begin
            if Given.Contains (Id) then
               Value := To_Unbounded_String (Given (Id));
            elsif Found.Contains (Id) then
               Value := To_Unbounded_String (Found (Id));
            elsif Declared.Default /= Null_Unbounded_String then
               Value := To_Unbounded_String
                 (Substitute (To_String (Declared.Default)));
               if E.Is_Error (Status) then
                  return;
               end if;
            else
               Has := False;
            end if;

            if Has then
               Check_Input (Declared, To_String (Value), Status);

               --  A value the caller gave that the input does not take is
               --  their mistake to hear about. One a default or the project
               --  supplied is only a suggestion that did not fit -- a
               --  directory named my-app is no identifier -- and the input
               --  is still to be asked for.
               if E.Is_Error (Status) and then not Given.Contains (Id) then
                  Status := E.Success;
                  Has := False;
               elsif E.Is_Error (Status) then
                  return;
               end if;
            end if;

            if Has then
               Result.Inputs.Include (Id, To_String (Value));
               Known.Include (Id, To_String (Value));
               if Declared.Secret then
                  Secrets.Append (Id);
               end if;
            elsif Declared.Required then
               Result.Missing.Append (Id);
            end if;
         end;
      end loop;

      if not Result.Missing.Is_Empty then
         declare
            Names : Unbounded_String;
         begin
            for Name of Result.Missing loop
               if Names /= Null_Unbounded_String then
                  Append (Names, ", ");
               end if;
               Append (Names, Name);
            end loop;
            Status := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Status, "name", To_String (Names));
         end;
         return;
      end if;

      Result.Project_Name := To_Unbounded_String
        (if Result.Inputs.Contains (Name_Input)
         then Result.Inputs (Name_Input) else Directory_Name);

      --  The configuration itself.
      declare
         Config : Records.Item :=
           Records.Create (Schemas.Configuration_Schema, 1, Current_Entity, 1);
         Order  : Unbounded_String;
      begin
         Records.Set (Config, "template_id", Templates.Id (Root_Template));
         Records.Set
           (Config, "template_version", Templates.Version (Root_Template));
         Records.Set
           (Config, "template_fingerprint",
            Templates.Composition_Fingerprint (Composed));
         Records.Set
           (Config, "template_origin", Templates.Origin (Root_Template));
         for Name of Templates.Order (Composed) loop
            if Order /= Null_Unbounded_String then
               Append (Order, ", ");
            end if;
            Append (Order, Name);
         end loop;
         Records.Set (Config, "template_order", To_String (Order));

         for Index in 1 .. Templates.Setting_Count (Composed) loop
            declare
               Given_Setting : constant Templates.Setting :=
                 Templates.Setting_At (Composed, Index);
               Key   : constant String := To_String (Given_Setting.Key);
               Field : constant String :=
                 Templates.Kind_Word (Given_Setting.Kind) & "." & Key;
               Value : constant String :=
                 Substitute (To_String (Given_Setting.Value));
            begin
               if E.Is_Error (Status) then
                  return;
               end if;

               case Given_Setting.Kind is
                  when Templates.Set_Setting | Templates.List_Setting =>
                     Records.Set
                       (Config, Field,
                        (if Records.Has (Config, Field)
                         then Records.Get (Config, Field) & ASCII.LF & Value
                         else Value));
                     if Given_Setting.Kind = Templates.Set_Setting
                       and then Key = Directories_Key
                     then
                        Result.Directories.Append (Value);
                     end if;

                  when Templates.Fact_Setting =>
                     if not Facts.Is_Key (Key) then
                        Invalid (Key & " is not a fact's key");
                        return;
                     end if;
                     Result.Template_Facts.Include (Key, Value);
                     Records.Set (Config, Field, Value);

                  when Templates.File_Setting =>
                     declare
                        Path : constant String := Substitute (Key);
                     begin
                        if E.Is_Error (Status) then
                           return;
                        elsif not Templates.Is_Project_Path (Path) then
                           Invalid (Path & " is not a path inside the project");
                           return;
                        end if;
                        Result.Files.Include (Path, Value);
                        Records.Set (Config, "file." & Path, Value);
                     end;

                  when others =>
                     Records.Set (Config, Field, Value);
               end case;
            end;
         end loop;

         --  What the project turned out to be outweighs what a template
         --  expected it to be.
         for Position in Result.Discovered_Facts.Iterate loop
            declare
               Key : constant String := Value_Maps.Key (Position);
            begin
               if not Facts.Is_Key (Key) then
                  Invalid (Key & " is not a fact's key");
                  return;
               end if;
               Records.Set
                 (Config, "fact." & Key, Value_Maps.Element (Position));
            end;
         end loop;

         for Index in 1 .. Templates.Input_Count (Composed) loop
            declare
               Declared : constant Templates.Input_Declaration :=
                 Templates.Input_At (Composed, Index);
               Id       : constant String := To_String (Declared.Id);
            begin
               if Declared.Persist and then not Declared.Secret
                 and then Result.Inputs.Contains (Id)
               then
                  Records.Set (Config, "input." & Id, Result.Inputs (Id));
               end if;
            end;
         end loop;

         Records.Set
           (Config, "configuration_fingerprint",
            Configuration_Fingerprint (Config));
         Result.Configuration := Config;
      end;
   end Prepare;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Item              : in out Stores.Store;
      Project_Directory : String;
      Planned           : Plan;
      Done              : out Outcome;
      Status            : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;

      procedure Add_Fact
        (Key, Value : String;
         Source     : Facts.Derivation_Source;
         Level      : Facts.Confidence_Level) is
      begin
         if E.Is_Ok (Status) then
            Facts.Record_Fact
              (Item, Change,
               (Key        => To_Unbounded_String (Key),
                Value      => To_Unbounded_String (Value),
                Source     => Source,
                Confidence => Level),
               Status);
         end if;
      end Add_Fact;
   begin
      Done := (others => <>);
      Status := E.Success;

      if Stores.Is_Initialized (Project_Directory) then
         Status := E.Make (E.Framework_Already_Initialized);
         E.Add_Text
           (Status, "path", Stores.State_Root (Project_Directory), E.Param_Path);
         return;
      end if;

      Stores.Put (Change, Config_Area, Current_Name, Planned.Configuration);
      Stores.Put
        (Change, Config_Area, First_History,
         Copy (Planned.Configuration, History_Entity));

      for Position in Planned.Template_Facts.Iterate loop
         if not Planned.Discovered_Facts.Contains (Value_Maps.Key (Position))
         then
            Add_Fact
              (Value_Maps.Key (Position), Value_Maps.Element (Position),
               Facts.Template, Facts.Authoritative);
         end if;
      end loop;
      for Position in Planned.Discovered_Facts.Iterate loop
         Add_Fact
           (Value_Maps.Key (Position), Value_Maps.Element (Position),
            Facts.Build_Metadata, Facts.Certain);
      end loop;
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Event : Unbounded_String;
      begin
         Events.Emit
           (Item, Change, Events.Project_Initialized, "PROJECT",
            Records.Get (Planned.Configuration, "template_id"), Event, Status);
      end;
      if E.Is_Error (Status) then
         return;
      end if;

      Stores.Create
        (Item, Project_Directory, To_String (Planned.Project_Name), Status,
         Initial => Change);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The project's own files, after its state: the state says what the
      --  project is whether or not these could all be made, and a file the
      --  project already has is its own and is left as it is.
      for Directory of Planned.Directories loop
         declare
            Path : constant String := Hostkit.Fs.Join (Project_Directory, Directory);
         begin
            if not Ada.Directories.Exists (Path) then
               if not Files.Make_Directory (Path) then
                  Files.Write_Failed (Path, Status);
                  return;
               end if;
               Done.Made_Directories.Append (Directory);
            end if;
         end;
      end loop;

      for Position in Planned.Files.Iterate loop
         declare
            Name : constant String := Value_Maps.Key (Position);
            Path : constant String := Hostkit.Fs.Join (Project_Directory, Name);
         begin
            if Ada.Directories.Exists (Path) then
               Done.Kept_Files.Append (Name);
            else
               if not Files.Make_Directory
                        (Ada.Directories.Containing_Directory (Path))
               then
                  Files.Write_Failed (Path, Status);
                  return;
               end if;
               Files.Write_Text (Path, Value_Maps.Element (Position), Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Done.Written_Files.Append (Name);
            end if;
         end;
      end loop;

      --  The initial indexes, derived from the project as it now is -- its
      --  own files included -- so that the first session reads them rather
      --  than making them. Derived, so failing to keep them fails nothing.
      declare
         Graph  : Repository.Graph;
         Kept   : E.Error_Info;
         Change : Stores.Transaction;
      begin
         Repository.Current (Item, Graph, Kept);
         Indexes.Build (Item, Change, Graph, Kept);
         if E.Is_Ok (Kept) then
            Stores.Commit (Item, Change, Kept);
         end if;
      end;

      --  The result checked as any project's state is, before it is left
      --  standing. All it finds is said; a state that did not come out whole
      --  -- a record off its schema, an identifier twice, a change left
      --  half made, an index that disagrees -- undoes the initialization:
      --  the state, and the files and directories it made.
      declare
         use type Consistency.Finding_Kind;
         Found  : constant Consistency.Finding_List := Consistency.Check (Item);
         Broken : Boolean := False;
      begin
         for Index in 1 .. Consistency.Length (Found) loop
            Done.Findings.Append
              (To_String (Consistency.Element (Found, Index).Subject) & ": "
               & Consistency.Kind_Word (Consistency.Element (Found, Index).Kind) & ": "
               & To_String (Consistency.Element (Found, Index).Detail));
            Broken := Broken
              or else Consistency.Element (Found, Index).Kind
                        in Consistency.Schema_Mismatch | Consistency.Duplicate_Identifier
                         | Consistency.Incomplete_Transaction | Consistency.Index_Mismatch;
         end loop;
         if Broken then
            Stores.Close (Item);
            Files.Remove_Tree (Stores.State_Root (Project_Directory));
            for Name of Done.Written_Files loop
               Files.Discard (Hostkit.Fs.Join (Project_Directory, Name));
            end loop;
            for Index in reverse 1 .. Natural (Done.Made_Directories.Length) loop
               begin
                  Ada.Directories.Delete_Directory
                    (Hostkit.Fs.Join (Project_Directory, Done.Made_Directories (Index)));
               exception
                  when others =>
                     null;
               end;
            end loop;
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", "the project as initialized");
            E.Add_Text (Status, "detail", Done.Findings.First_Element
                        & (if Consistency.Length (Found) > 1
                           then " (and" & Natural'Image (Consistency.Length (Found) - 1) & " more)"
                           else "")
                        & "; nothing was kept");
         end if;
      end;
   end Initialize;

   --  The settings a reconfiguration may change, by the start of their name.
   Changeable : constant array (1 .. 10) of access constant String :=
     [new String'("scalar."), new String'("set."), new String'("list."),
      new String'("map."), new String'("profile."), new String'("fact."),
      new String'("adapter."), new String'("task_kind."), new String'("schema."),
      new String'("baseline.")];

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length > Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  A list written with commas, as the configuration keeps it: a line an
   --  item.
   function Lines_From (Text : String) return String is
      Result : Unbounded_String;
   begin
      for Part of Choices_Of (Text) loop
         Append (Result, (if Result = Null_Unbounded_String then "" else ASCII.LF & "") & Part);
      end loop;
      return To_String (Result);
   end Lines_From;

   --  A value of several lines, as one: its lines separated by commas.
   function On_One_Line (Text : String) return String is
      Result : Unbounded_String;
   begin
      for C of Text loop
         if C = ASCII.LF then
            Append (Result, ", ");
         else
            Append (Result, C);
         end if;
      end loop;
      return To_String (Result);
   end On_One_Line;

   --  What a change to a field reaches.
   function Reach (Name : String) return String is
   begin
      if Starts (Name, "profile.") or else Starts (Name, "scalar.verification.")
        or else Starts (Name, "scalar.task.profile.") or else Starts (Name, "set.execution.")
        or else Starts (Name, "list.verification.")
      then
         return "verification: how tasks are checked from now on";
      elsif Starts (Name, "map.permission.") then
         return "permissions: what agents started from now on may do";
      elsif Starts (Name, "task_kind.") then
         return "tasks of kind " & Name (Name'First + 10 .. Name'Last)
           & ": the fields new ones may have";
      elsif Starts (Name, "scalar.work.") or else Starts (Name, "scalar.agents.") then
         return "work: how agents run tasks from now on";
      elsif Starts (Name, "list.automation.") then
         return "automation: what happens on its own after an event";
      elsif Starts (Name, "set.repository.") then
         return "the repository graph and the indexes: files placed, left out or given"
           & " a role by the new roots are read again, and the indexes built again";
      elsif Starts (Name, "set.components") then
         return "components: the indexes built again, and what tasks may name";
      elsif Starts (Name, "baseline.") or else Starts (Name, "schema.") then
         return "authority: what governs " & Name & " in every task's effective view";
      elsif Starts (Name, "scalar.task.") or else Starts (Name, "set.task.") then
         return "tasks: how they are derived, accepted and judged ready from now on";
      else
         return "settings: " & Name;
      end if;
   end Reach;

   --  Whether a value reads as its field needs.
   function Problem (Name, Value : String) return String is
   begin
      if Starts (Name, "baseline.")
        and then not Starts (Name, "baseline.project.")
        and then not Starts (Name, "baseline.language.")
      then
         return "a baseline is baseline.project.SUBJECT or baseline.language.SUBJECT";
      elsif Starts (Name, "profile.") then
         declare
            Start : Natural := Value'First;
         begin
            for Index in Value'First .. Value'Last + 1 loop
               if Index > Value'Last or else Value (Index) = ';' then
                  declare
                     Check : constant String :=
                       Ada.Strings.Fixed.Trim (Value (Start .. Index - 1), Ada.Strings.Both);
                  begin
                     if Check /= "" and then Ada.Strings.Fixed.Index (Check, ":") = 0 then
                        return "a check is written LABEL: COMMAND, not " & Check;
                     end if;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
         end;
      elsif Starts (Name, "map.permission.") then
         declare
            Last_Dot : constant Natural :=
              Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
            Level    : Permissions.Permission_Set;
            Read     : E.Error_Info;
         begin
            Permissions.Restriction
              (Name (Last_Dot + 1 .. Name'Last) & ": " & Value, Level, Read);
            if E.Is_Error (Read) then
               return "no capability is called " & Name (Last_Dot + 1 .. Name'Last);
            end if;
         end;
      end if;
      return "";
   end Problem;

   --  What is wrong with a whole configuration: a setting naming a profile
   --  or a task kind that is not there, or a policy that is none of its
   --  words. The first found, or nothing. How each changed value reads is
   --  checked as it is given.
   function Whole_Problem (Config : Records.Item) return String is
      function Has (Field : String) return Boolean is (Records.Get (Config, Field) /= "");

      function Among (Field : String; Words : String) return Boolean
      is (Records.Get (Config, Field) = ""
          or else Choices_Of (Words).Contains (Records.Get (Config, Field)));
   begin
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name  : constant String := Records.Field_Name (Config, Index);
            Value : constant String := Records.Get (Config, Name);
         begin
            if Name = "scalar.verification.default" and then not Has ("profile." & Value) then
               return Name & " names the profile " & Value & ", which is not there";
            elsif Starts (Name, "scalar.task.profile.") then
               if not Has ("task_kind." & Name (Name'First + 20 .. Name'Last)) then
                  return Name & " is for a task kind that is not there";
               elsif not Has ("profile." & Value) then
                  return Name & " names the profile " & Value & ", which is not there";
               end if;
            elsif Name = "list.verification.full" then
               for Profile of Lines_Of (Value) loop
                  if not Has ("profile." & Profile) then
                     return Name & " names the profile " & Profile & ", which is not there";
                  end if;
               end loop;
            elsif Name = "scalar.task.derived_kind" and then not Has ("task_kind." & Value) then
               return Name & " names the task kind " & Value & ", which is not there";
            end if;
         end;
      end loop;
      --  A kind's own field has a schema that says what it is.
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name : constant String := Records.Field_Name (Config, Index);
         begin
            if Starts (Name, "task_kind.") then
               for Field of Choices_Of (Records.Get (Config, Name)) loop
                  declare
                     Plain : constant String :=
                       (if Field'Length > 0 and then Field (Field'Last) = '?'
                        then Field (Field'First .. Field'Last - 1) else Field);
                  begin
                     if not Tasks.Is_Core_Field (Plain) and then not Has ("map.task_field." & Plain)
                     then
                        return Name & " lists " & Plain
                          & ", a field of its own whose schema map task_field." & Plain
                          & " does not say";
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;

      --  A task move names states whose meaning is known, a core state's
      --  meaning is the harness's, and only a move a person makes may be
      --  forbidden.
      for Line of Lines_Of (Records.Get (Config, "set.task.transitions")) loop
         declare
            Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
         begin
            if Arrow = 0 then
               return "set.task.transitions is FROM -> TO a line, not " & Line;
            end if;
            for Side of Name_Lists.Vector'
              ([Ada.Strings.Fixed.Trim (Line (Line'First .. Arrow - 1), Ada.Strings.Both),
                Ada.Strings.Fixed.Trim (Line (Arrow + 2 .. Line'Last), Ada.Strings.Both)])
            loop
               if not Tasks.Core_Task_States.Contains (Side)
                 and then not Has ("map.task.state." & Side)
               then
                  return "set.task.transitions names " & Side
                    & ", a state whose meaning map task.state." & Side & " does not say";
               end if;
            end loop;
         end;
      end loop;
      for Line of Lines_Of (Records.Get (Config, "set.task.forbidden")) loop
         declare
            Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
         begin
            if Arrow = 0
              or else not Tasks.Forbiddable
                            (Ada.Strings.Fixed.Trim (Line (Line'First .. Arrow - 1), Ada.Strings.Both),
                             Ada.Strings.Fixed.Trim (Line (Arrow + 2 .. Line'Last), Ada.Strings.Both))
            then
               return "set.task.forbidden takes away " & Line
                 & ", which is no move a person makes; the harness's own moves stay";
            end if;
         end;
      end loop;
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name : constant String := Records.Field_Name (Config, Index);
         begin
            if Starts (Name, "map.task.state.")
              and then Tasks.Core_Task_States.Contains (Name (Name'First + 15 .. Name'Last))
            then
               return Name & ": a core state's meaning is the harness's";
            end if;
         end;
      end loop;

      --  A requirement move names states whose meaning is known: the core
      --  ones, or the project's, each said what it means.
      for Line of Lines_Of (Records.Get (Config, "set.requirement.transitions")) loop
         declare
            Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, "->");
         begin
            if Arrow = 0 then
               return "set.requirement.transitions is FROM -> TO a line, not " & Line;
            end if;
            for Side of Name_Lists.Vector'
              ([Ada.Strings.Fixed.Trim (Line (Line'First .. Arrow - 1), Ada.Strings.Both),
                Ada.Strings.Fixed.Trim (Line (Arrow + 2 .. Line'Last), Ada.Strings.Both)])
            loop
               if not Intent.Core_Requirement_States.Contains (Side)
                 and then not Has ("map.requirement.state." & Side)
               then
                  return "set.requirement.transitions names " & Side
                    & ", a state whose meaning map requirement.state." & Side & " does not say";
               end if;
            end loop;
         end;
      end loop;
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name : constant String := Records.Field_Name (Config, Index);
         begin
            if Starts (Name, "map.requirement.state.")
              and then Intent.Core_Requirement_States.Contains
                         (Name (Name'First + 22 .. Name'Last))
            then
               return Name & ": a core state's meaning is the harness's";
            end if;
         end;
      end loop;

      if not Among ("scalar.repository.state_policy", "portable, local, all") then
         return "scalar.repository.state_policy is portable, local or all";
      elsif not Among ("scalar.work.isolation", "project, workspace") then
         return "scalar.work.isolation is project or workspace";
      end if;
      return "";
   end Whole_Problem;

   -----------------
   -- Plan_Change --
   -----------------

   procedure Plan_Change
     (Item    : Stores.Store;
      Changes : Value_Maps.Map;
      Result  : out Change_Plan;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      function Refused (Name, Detail : String) return E.Error_Info is
         Made : E.Error_Info := E.Make (E.Framework_Schema_Violation);
      begin
         E.Add_Text (Made, "name", Name);
         E.Add_Text (Made, "detail", Detail);
         return Made;
      end Refused;
   begin
      Result := (others => <>);
      Read (Item, Result.Before, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Result.After := Result.Before;

      for Position in Changes.Iterate loop
         declare
            Name  : constant String := Value_Maps.Key (Position);
            Given : constant String := Value_Maps.Element (Position);
            Value : constant String :=
              (if Starts (Name, "set.") or else Starts (Name, "list.")
               then Lines_From (Given) else Given);
            Old   : constant String := Records.Get (Result.Before, Name);
         begin
            if not (for some Prefix of Changeable => Starts (Name, Prefix.all)) then
               Status := Refused (Name, "only the settings can be changed: "
                                  & "scalar., set., list., map., profile., fact., adapter."
                                  & " and task_kind. fields");
               return;
            elsif not Records.Is_Field_Name (Name) then
               Status := E.Make (E.Framework_Name_Invalid);
               E.Add_Text (Status, "value", Name);
               return;
            elsif Problem (Name, Value) /= "" then
               Status := Refused (Name, Problem (Name, Value));
               return;
            end if;

            if Value /= Old then
               if Value = "" then
                  Records.Remove (Result.After, Name);
               else
                  Records.Set (Result.After, Name, Value);
               end if;
               Result.Changed.Append
                 (Name & ": " & (if Old = "" then "(none)" else On_One_Line (Old)) & " -> "
                  & (if Value = "" then "(none)" else On_One_Line (Value)));
               if not Result.Impact.Contains (Reach (Name)) then
                  Result.Impact.Append (Reach (Name));
               end if;
            end if;
         end;
      end loop;

      --  The whole of it, as it would be.
      if not Result.Changed.Is_Empty and then Whole_Problem (Result.After) /= "" then
         Status := Refused ("the configuration", Whole_Problem (Result.After));
         return;
      end if;

      --  Evidence is taken against a configuration: any change leaves what
      --  was verified before to be verified again.
      if not Result.Changed.Is_Empty then
         Result.Impact.Append
           ("evidence: what was verified under revision"
            & Natural'Image (Records.Revision (Result.Before))
            & " no longer applies until it is checked again");
      end if;
      Records.Set_Revision (Result.After, Records.Revision (Result.Before) + 1);
      Records.Set
        (Result.After, "configuration_fingerprint", Configuration_Fingerprint (Result.After));
   end Plan_Change;

   ------------------
   -- Stage_Change --
   ------------------

   procedure Stage_Change
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Planned : Change_Plan;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Now    : Records.Item;
      Event  : Unbounded_String;
      Number : constant String := Natural'Image (Records.Revision (Planned.After));
      Padded : constant String :=
        [1 .. Integer'Max (0, 6 - (Number'Length - 1)) => '0']
        & Number (Number'First + 1 .. Number'Last);
      Kept   : Records.Item := Copy (Planned.After, History_Entity);
   begin
      Status := E.Success;
      if Planned.Changed.Is_Empty then
         return;
      end if;

      --  Made against the configuration it was planned from, or not at all.
      Read (Item, Now, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Records.Revision (Now) /= Records.Revision (Planned.Before) then
         Status := E.Make (E.Framework_Revision_Conflict);
         E.Add_Text (Status, "name", "the configuration");
         return;
      end if;

      Stores.Put (Change, Config_Area, Current_Name, Planned.After);
      --  A record of its own in the history, saying which revision it was.
      Records.Set (Kept, "configuration_revision", Number (Number'First + 1 .. Number'Last));
      Stores.Put (Change, Config_Area, "revision-" & Padded, Kept);
      declare
         Said : Unbounded_String := To_Unbounded_String ("revision" & Number);
      begin
         for Line of Planned.Changed loop
            Append (Said, ASCII.LF & Line);
         end loop;
         Events.Emit
           (Item, Change, Events.Configuration_Changed, "PROJECT", To_String (Said),
            Event, Status);
      end;
   end Stage_Change;

   -----------------
   -- Reconfigure --
   -----------------

   procedure Reconfigure
     (Item     : in out Stores.Store;
      Planned  : Change_Plan;
      Revision : out Natural;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
   begin
      Revision := Records.Revision (Planned.Before);
      Stage_Change (Item, Change, Planned, Status);
      if E.Is_Ok (Status) and then not Planned.Changed.Is_Empty then
         Stores.Commit (Item, Change, Status);
         if E.Is_Ok (Status) then
            Revision := Records.Revision (Planned.After);
         end if;
      end if;
   end Reconfigure;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Stores.Store;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Stores.Read (Item, Config_Area, Current_Name, Value, Status);
      if E.Is_Ok (Status)
        and then Records.Get (Value, "configuration_fingerprint")
                   /= Configuration_Fingerprint (Value)
      then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text
           (Status, "path", Directory_Name (Config_Area) & "/" & Current_Name,
            E.Param_Path);
      end if;
   end Read;

end Model_Runner.Framework.Configurations;
