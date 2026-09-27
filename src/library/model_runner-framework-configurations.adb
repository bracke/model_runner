with Ada.Directories;

with Hostkit.Fs;

with Model_Runner.Framework.Events;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Schemas;

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
              Templates.Input_At (Composed, Index);
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
   end Initialize;

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
