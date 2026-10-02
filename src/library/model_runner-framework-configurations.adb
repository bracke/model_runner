with Ada.Characters.Handling;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Directories;

with Hostkit.Fs;
with Hostkit.Process;

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
   --  Each revision kept in the history is an entity of its own:
   --  CONFIG-REV- and its revision.
   History_Entity   : constant String := "CONFIG-REV-";
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

   ------------------------------
   -- Verification_Fingerprint --
   ------------------------------

   function Verification_Fingerprint (Value : Records.Item) return String is
      --  What the checks read: their profiles and what runs them, the
      --  verification policy, the project's build and adapters, what the
      --  repository holds, and the environment and programs they run with.
      Bearing : constant Name_Lists.Vector :=
        ["profile.", "list.verification.", "scalar.verification.", "scalar.profile_capability.",
         "scalar.build.", "adapter.", "set.repository.", "set.source", "set.directories",
         "set.execution.shell", "set.execution.environment", "scalar.execution.network",
         "scalar.execution.memory", "scalar.execution.cpu", "scalar.execution.processes",
         "scalar.execution.file", "map.component.", "set.components", "input.project_name"];
      Meaning : Records.Item := Records.Create (Current_Entity, 1, "", 1);
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Name : constant String := Records.Field_Name (Value, Index);
         begin
            if (for some Prefix of Bearing =>
                  Name'Length >= Prefix'Length
                  and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix)
            then
               Records.Set (Meaning, Name, Records.Get (Value, Name));
            end if;
         end;
      end loop;
      return Records.Fingerprint_Of (Meaning);
   end Verification_Fingerprint;

   -----------------
   -- Check_Input --
   -----------------

   package Sorting is new Name_Lists.Generic_Sorting;

   --------------
   -- Resolved --
   --------------

   --  What a project is called where nothing is given: the name its own
   --  manifest gives it -- alire.toml, Cargo.toml, pyproject.toml,
   --  package.json -- and else its directory's.
   function Project_Named (Project_Directory : String) return String is
      Full : constant String := Ada.Directories.Full_Name (Project_Directory);

      --  The first name = "x" (or "name": "x") line of a manifest.
      function Named_In (File_Name : String) return String is
         use Ada.Streams.Stream_IO;
         Path : constant String := Hostkit.Fs.Join (Full, File_Name);
         File : File_Type;
      begin
         if not Ada.Directories.Exists (Path) then
            return "";
         end if;
         Open (File, In_File, Path);
         declare
            Text : String (1 .. Natural'Min (Natural (Size (File)), 65_536));
         begin
            String'Read (Stream (File), Text);
            Close (File);
            --  JSON as it comes, on one line or many: its first "name" key.
            if File_Name = "package.json" then
               declare
                  At_Key : constant Natural := Ada.Strings.Fixed.Index (Text, """name""");
                  Colon  : constant Natural :=
                    (if At_Key = 0 then 0 else Ada.Strings.Fixed.Index (Text (At_Key + 6 .. Text'Last), ":"));
                  Open_Q : constant Natural :=
                    (if Colon = 0 then 0 else Ada.Strings.Fixed.Index (Text (Colon + 1 .. Text'Last), """"));
                  Shut_Q : constant Natural :=
                    (if Open_Q = 0 then 0 else Ada.Strings.Fixed.Index (Text (Open_Q + 1 .. Text'Last), """"));
               begin
                  if Shut_Q > Open_Q + 1
                    and then Ada.Strings.Fixed.Trim (Text (At_Key + 6 .. Colon - 1), Ada.Strings.Both) = ""
                    and then Ada.Strings.Fixed.Trim (Text (Colon + 1 .. Open_Q - 1), Ada.Strings.Both) = ""
                  then
                     return Text (Open_Q + 1 .. Shut_Q - 1);
                  end if;
                  return "";
               end;
            end if;
            for Raw of Lines_Of (Text) loop
               declare
                  Line  : constant String := Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both);
                  Key   : constant String := (if File_Name = "package.json" then """name""" else "name");
                  First : constant Natural :=
                    (if Line'Length > Key'Length then Ada.Strings.Fixed.Index (Line, """", Line'First + Key'Length)
                     else 0);
               begin
                  if Line'Length > Key'Length + 3 and then Line (Line'First .. Line'First + Key'Length - 1) = Key
                    and then Line (Line'First + Key'Length) in ' ' | '=' | ':'
                    and then First > 0
                  then
                     declare
                        Last : constant Natural := Ada.Strings.Fixed.Index (Line (First + 1 .. Line'Last), """");
                     begin
                        if Last > First + 1 then
                           return Line (First + 1 .. Last - 1);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
         return "";
      exception
         when others =>
            if Is_Open (File) then
               Close (File);
            end if;
            return "";
      end Named_In;
   begin
      for Manifest of Name_Lists.Vector'(["alire.toml", "Cargo.toml", "pyproject.toml", "package.json"]) loop
         if Named_In (Manifest) /= "" then
            return Named_In (Manifest);
         end if;
      end loop;
      return Ada.Directories.Simple_Name (Full);
   end Project_Named;

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

   --  A text made an identifier: what is not a letter, digit or _ an _,
   --  no two together and none at either end; lower case for a crate.
   function Nearest_Identifier (Text : String; Lower : Boolean) return String is
      Result : Unbounded_String;
   begin
      for Char of Text loop
         if Char in 'a' .. 'z' | '0' .. '9' then
            Append (Result, Char);
         elsif Char in 'A' .. 'Z' then
            Append (Result, (if Lower then Ada.Characters.Handling.To_Lower (Char) else Char));
         elsif Length (Result) > 0 and then Element (Result, Length (Result)) /= '_' then
            Append (Result, '_');
         end if;
      end loop;
      while Length (Result) > 0 and then Element (Result, Length (Result)) = '_' loop
         Delete (Result, Length (Result), Length (Result));
      end loop;
      return To_String (Result);
   end Nearest_Identifier;

   procedure Check_Input
     (Declared : Templates.Input_Declaration;
      Value    : String;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      procedure Refuse (Detail : String) is
         --  A name refused: the one nearest it that would do, said.
         Near  : constant String :=
           (if Declared.Kind in Templates.Identifier_Input | Templates.Crate_Input
            then Nearest_Identifier (Value, Declared.Kind = Templates.Crate_Input) else "");
         Takes : E.Error_Info := E.Success;
      begin
         if Near /= "" and then Near /= Value then
            Check_Input (Declared, Near, Takes);
         end if;
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", To_String (Declared.Id));
         E.Add_Text (Status, "value", Value);
         E.Add_Text (Status, "detail", Detail
                     & (if Near /= "" and then Near /= Value and then E.Is_Ok (Takes)
                        then "; " & Near & " would do" else ""));
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

         when Templates.Crate_Input =>
            if Value'Length not in 3 .. 64 then
               Refuse ("a crate's name is 3 to 64 characters");
            elsif Value (Value'First) not in 'a' .. 'z'
              or else not (for all Char of Value => Char in 'a' .. 'z' | '0' .. '9' | '_')
            then
               Refuse ("a crate's name is lower-case letters, digits and _, a letter first");
            elsif Value (Value'Last) = '_' or else Ada.Strings.Fixed.Index (Value, "__") > 0 then
               Refuse ("a crate's name has no _ last and no two together");

            --  Its name is its main program's and its project's: not one
            --  the language keeps for itself.
            elsif Value in "ada" | "system" | "interfaces" | "standard" then
               Refuse ("it is the name of a unit the language defines, which a project of its own"
                       & " cannot take");
            elsif Value = "gnat" then
               Refuse ("it is the name of the compiler's own units, which a project of its own cannot take");
            --  The template's own crates beside it: the test crate and its
            --  harness would be named the same, and neither builds.
            elsif Value in "tests" | "aunit" then
               Refuse ("the test crate beside it is " & (if Value = "tests" then "called tests" else "built on aunit")
                       & ", and a project of that name clashes with it");
            elsif Value in "abort" | "abs" | "abstract" | "accept" | "access" | "aliased" | "all"
                         | "and" | "array" | "at" | "begin" | "body" | "case" | "constant"
                         | "declare" | "delay" | "delta" | "digits" | "do" | "else" | "elsif"
                         | "end" | "entry" | "exception" | "exit" | "for" | "function" | "generic"
                         | "goto" | "if" | "in" | "interface" | "is" | "limited" | "loop" | "mod"
                         | "new" | "not" | "null" | "of" | "or" | "others" | "out" | "overriding"
                         | "package" | "parallel" | "pragma" | "private" | "procedure"
                         | "protected" | "raise" | "range" | "record" | "rem" | "renames"
                         | "requeue" | "return" | "reverse" | "select" | "separate" | "some"
                         | "subtype" | "synchronized" | "tagged" | "task" | "terminate" | "then"
                         | "type" | "until" | "use" | "when" | "while" | "with" | "xor"
            then
               Refuse ("it is an Ada reserved word, which no program can be called");
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

   --  Whether a file at the top of a directory matches a pattern, as
   --  *.gpr: what a discovery rule that names no one file looks for.
   function Matches_Any (Directory, Pattern : String) return Boolean is
      use Ada.Directories;
      Search : Search_Type;
      Found  : Boolean;
   begin
      Start_Search (Search, Directory, Pattern, [Ordinary_File => True, others => False]);
      Found := More_Entries (Search);
      End_Search (Search);
      return Found;
   exception
      when others =>
         return False;
   end Matches_Any;

   --  A profile's LABEL in DIR: COMMAND parts moved to where the crate
   --  is, where DIR holds no alire.toml and exactly one directory in it
   --  does.
   function Crate_Located (Project_Directory, Profile : String) return String is
      Output : Unbounded_String;
      Start  : Natural := Profile'First;
   begin
      while Start <= Profile'Last loop
         declare
            Semicolon : constant Natural := Ada.Strings.Fixed.Index (Profile (Start .. Profile'Last), ";");
            Part_End  : constant Natural := (if Semicolon = 0 then Profile'Last else Semicolon - 1);
            Part      : constant String := Profile (Start .. Part_End);
            In_At     : constant Natural := Ada.Strings.Fixed.Index (Part, " in ");
            Colon     : constant Natural := Ada.Strings.Fixed.Index (Part, ":");
            Moved     : Unbounded_String := To_Unbounded_String (Part);
         begin
            if In_At > 0 and then Colon > In_At then
               declare
                  Dir   : constant String := Ada.Strings.Fixed.Trim (Part (In_At + 4 .. Colon - 1), Ada.Strings.Both);
                  Where : constant String := Hostkit.Fs.Join (Project_Directory, Dir);
                  Found : Unbounded_String;
                  Count : Natural := 0;
               begin
                  if Dir /= "" and then Ada.Directories.Exists (Where)
                    and then Ada.Directories."=" (Ada.Directories.Kind (Where), Ada.Directories.Directory)
                    and then not Ada.Directories.Exists (Hostkit.Fs.Join (Where, "alire.toml"))
                  then
                     declare
                        Search : Ada.Directories.Search_Type;
                        Next   : Ada.Directories.Directory_Entry_Type;
                     begin
                        Ada.Directories.Start_Search
                          (Search, Where, "", [Ada.Directories.Directory => True, others => False]);
                        while Ada.Directories.More_Entries (Search) loop
                           Ada.Directories.Get_Next_Entry (Search, Next);
                           declare
                              Simple : constant String := Ada.Directories.Simple_Name (Next);
                           begin
                              if Simple (Simple'First) /= '.'
                                and then Ada.Directories.Exists
                                           (Hostkit.Fs.Join (Hostkit.Fs.Join (Where, Simple), "alire.toml"))
                              then
                                 Count := Count + 1;
                                 Found := To_Unbounded_String (Simple);
                              end if;
                           end;
                        end loop;
                        Ada.Directories.End_Search (Search);
                     end;
                     if Count = 1 then
                        Moved := To_Unbounded_String
                          (Part (Part'First .. In_At + 3) & Dir & "/" & To_String (Found)
                           & Part (Colon .. Part'Last));
                     end if;
                  end if;
               end;
            end if;
            Append (Output, Moved & (if Semicolon = 0 then "" else ";"));
            exit when Semicolon = 0;
            Start := Semicolon + 1;
         end;
      end loop;
      return To_String (Output);
   exception
      when others =>
         return Profile;
   end Crate_Located;

   --  Whether a Makefile there has a rule for Target.
   function Make_Rule (Directory, Target : String) return Boolean is
      Text  : Unbounded_String;
      Read  : E.Error_Info;
      Start : Natural := 1;
   begin
      Files.Read_Text (Hostkit.Fs.Join (Directory, "Makefile"), Text, Read);
      if E.Is_Error (Read) then
         return False;
      end if;
      declare
         Whole : constant String := To_String (Text);
      begin
         while Start <= Whole'Last loop
            declare
               Stop : constant Natural := Ada.Strings.Fixed.Index (Whole (Start .. Whole'Last), [1 => ASCII.LF]);
               Line : constant String := Whole (Start .. (if Stop = 0 then Whole'Last else Stop - 1));
            begin
               if Line'Length > Target'Length
                 and then Line (Line'First .. Line'First + Target'Length - 1) = Target
                 and then Line (Line'First + Target'Length) in ':' | ' '
                 and then Ada.Strings.Fixed.Index (Line, ":") > 0
               then
                  return True;
               end if;
               exit when Stop = 0;
               Start := Stop + 1;
            end;
         end loop;
      end;
      return False;
   end Make_Rule;

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

      Directory_Name : constant String := Project_Named (Project_Directory);

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
                     elsif Name'Length > 8
                       and then Name (Name'Last - 7 .. Name'Last) = ".program"
                       and then Known.Contains (Name (Name'First .. Name'Last - 8))
                     then
                        --  The program a command runs: its first word, by
                        --  its simple name.
                        declare
                           Command : constant String :=
                             Ada.Strings.Fixed.Trim (Known (Name (Name'First .. Name'Last - 8)),
                                                     Ada.Strings.Both);
                           Blank   : constant Natural := Ada.Strings.Fixed.Index (Command, " ");
                           First   : constant String :=
                             (if Blank = 0 then Command else Command (Command'First .. Blank - 1));
                        begin
                           Append (Output, (if First = "" then "" else Ada.Directories.Simple_Name (First)));
                        end;
                        Index := Close + 1;
                        goto Next_Character;
                     elsif Name'Length > 4
                       and then Name (Name'Last - 3 .. Name'Last) = ".ada"
                       and then Known.Contains (Name (Name'First .. Name'Last - 4))
                     then
                        --  As an Ada name is written: each word's first
                        --  letter a capital -- greetings is Greetings,
                        --  my_lib My_Lib.
                        declare
                           Value : String := Known (Name (Name'First .. Name'Last - 4));
                        begin
                           for At_Index in Value'Range loop
                              if At_Index = Value'First or else Value (At_Index - 1) in '_' | '.' then
                                 Value (At_Index) := Ada.Characters.Handling.To_Upper (Value (At_Index));
                              end if;
                           end loop;
                           Append (Output, Value);
                        end;
                        Index := Close + 1;
                        goto Next_Character;
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
            <<Next_Character>>
         end loop;
         return To_String (Output);
      end Substitute;
      --  Tests written for pytest -- a [tool.pytest] table, or a test
      --  module that imports pytest or never imports unittest: unittest
      --  would run none of them, so pytest stays, said missing at /init.
      function Pytest_Style (Directory : String) return Boolean is
         Found_Test : Boolean := False;
         Unittest   : Boolean := False;

         function Holds (Path, Text : String) return Boolean is
            Held : Unbounded_String;
            Read : E.Error_Info;
         begin
            Files.Read_Text (Path, Held, Read);
            return E.Is_Ok (Read) and then Index (Held, Text) > 0;
         end Holds;

         procedure Walk (Dir : String; Depth : Natural) is
            Search : Ada.Directories.Search_Type;
            Found  : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search (Search, Dir, "");
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Found);
               declare
                  Name : constant String := Ada.Directories.Simple_Name (Found);
               begin
                  if Name (Name'First) = '.' or else Name in "node_modules" | "venv" | "__pycache__" then
                     null;
                  elsif Ada.Directories."=" (Ada.Directories.Kind (Found), Ada.Directories.Directory) then
                     if Depth < 3 then
                        Walk (Ada.Directories.Full_Name (Found), Depth + 1);
                     end if;
                  elsif Name'Length > 8 and then Name (Name'First .. Name'First + 4) = "test_"
                    and then Name (Name'Last - 2 .. Name'Last) = ".py"
                  then
                     Found_Test := True;
                     Unittest := Unittest or else Holds (Ada.Directories.Full_Name (Found), "import unittest");
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         exception
            when others =>
               null;
         end Walk;
      begin
         if Ada.Directories.Exists (Hostkit.Fs.Join (Directory, "pyproject.toml"))
           and then Holds (Hostkit.Fs.Join (Directory, "pyproject.toml"), "[tool.pytest")
         then
            return True;
         end if;
         Walk (Directory, 0);
         return Found_Test and then not Unittest;
      end Pytest_Style;
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
            if (if Ada.Strings.Fixed.Index (To_String (Rule.Path), "*") > 0
                then Matches_Any (Project_Directory, To_String (Rule.Path))
                else Ada.Directories.Exists
                       (Hostkit.Fs.Join (Project_Directory, To_String (Rule.Path))))
            then
               if Rule.To_Input and then To_String (Rule.Value) = "make test"
                 and then not Make_Rule (Project_Directory, "test")
               then
                  --  The rule a Makefile has: check, or its first one.
                  Found.Include (To_String (Rule.Key),
                                 (if Make_Rule (Project_Directory, "check") then "make check" else "make"));
               elsif Rule.To_Input and then To_String (Rule.Value) = "python3 -m pytest"
                 and then Hostkit.Process.Locate ("pytest") = ""
                 and then not Pytest_Style (Project_Directory)
               then
                  --  No pytest here: the runner Python has of its own.
                  Found.Include (To_String (Rule.Key), "python3 -m unittest discover");
               elsif Rule.To_Input then
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
               --  Named as the input it is not, with the ones there are.
               declare
                  Inputs : Name_Lists.Vector;
                  Listed : Unbounded_String;
               begin
                  for Index in 1 .. Templates.Input_Count (Composed) loop
                     Inputs.Append (To_String (Templates.Input_At (Composed, Index).Id));
                     Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                                     & To_String (Templates.Input_At (Composed, Index).Id));
                  end loop;
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "the template's inputs");
                  E.Add_Text (Status, "value", Name & "=" & Value_Maps.Element (Position));
                  E.Add_Text
                    (Status, "detail",
                     "it has no input " & Name
                     & (if Nearest (Name, Inputs) /= "" then "; did you mean " & Nearest (Name, Inputs) & "?"
                        else "")
                     & (if Listed = Null_Unbounded_String then "; it takes none"
                        else "; its inputs: " & To_String (Listed)));
               end;
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
            Deferred : Boolean := False;

            --  Whether a default names the program of an input not known
            --  yet: ${check_command.program} before check_command is given.
            function Waits_On_Missing (Default : String) return Boolean is
               Open  : constant Natural := Ada.Strings.Fixed.Index (Default, "${");
               Close : constant Natural := Ada.Strings.Fixed.Index (Default, "}");
            begin
               if Open = 0 or else Close <= Open + 10 then
                  return False;
               end if;
               declare
                  Name : constant String := Default (Open + 2 .. Close - 1);
               begin
                  return Name'Length > 8 and then Name (Name'Last - 7 .. Name'Last) = ".program"
                    and then not Known.Contains (Name (Name'First .. Name'Last - 8));
               end;
            end Waits_On_Missing;
         begin
            if Given.Contains (Id) then
               Value := To_Unbounded_String (Given (Id));
            elsif Found.Contains (Id) then
               Value := To_Unbounded_String (Found (Id));
            elsif Declared.Default /= Null_Unbounded_String
              and then Waits_On_Missing (To_String (Declared.Default))
            then
               --  Its default is read from an input still to be given: it is
               --  worked out once that is, and not asked for itself.
               Has := False;
               Deferred := True;
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

               --  A default that does not fit as it is may as its nearest
               --  identifier: My-App is the crate my_app.
               if E.Is_Error (Status) and then not Given.Contains (Id)
                 and then not Found.Contains (Id)
                 and then Declared.Kind in Templates.Identifier_Input | Templates.Crate_Input
               then
                  declare
                     Near : constant String :=
                       Nearest_Identifier (To_String (Value), Declared.Kind = Templates.Crate_Input);
                     Again : E.Error_Info;
                  begin
                     Check_Input (Declared, Near, Again);
                     if E.Is_Ok (Again) then
                        Value := To_Unbounded_String (Near);
                        Status := E.Success;
                     else
                        --  Too short a name -- a directory called p1 -- as one
                        --  that is long enough: p1_app, or p1_lib for a library.
                        declare
                           Padded : constant String :=
                             Near & (if Ada.Strings.Fixed.Index (Templates.Id (Root_Template), "library") > 0
                                     then "_lib" else "_app");
                        begin
                           Check_Input (Declared, Padded, Again);
                           if E.Is_Ok (Again) then
                              Value := To_Unbounded_String (Padded);
                              Status := E.Success;
                           end if;
                        end;
                     end if;
                  end;
               end if;

               --  A value the caller gave that the input does not take is
               --  their mistake to hear about. One a default or the project
               --  supplied is only a suggestion that did not fit -- a
               --  directory named p1 is no crate -- and the input is still
               --  to be asked for, with why.
               if E.Is_Error (Status) and then not Given.Contains (Id) then
                  Result.Missing_Why.Include
                    (Id, To_String (Value) & " does not do: " & E.Text_Of (Status, "detail"));
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
            elsif Declared.Required and then not Deferred then
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
         --  Whether the directory holds code of its own already: at its top
         --  or in src/, a file a compiler or an interpreter reads.
         function Has_Own_Sources return Boolean is
            function Holds (Where : String) return Boolean is
               Search : Ada.Directories.Search_Type;
               Found  : Ada.Directories.Directory_Entry_Type;
               Result : Boolean := False;
            begin
               if not Ada.Directories.Exists (Where) then
                  return False;
               end if;
               Ada.Directories.Start_Search
                 (Search, Where, "", [Ada.Directories.Ordinary_File => True, others => False]);
               while Ada.Directories.More_Entries (Search) and then not Result loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  Result := Ada.Directories.Extension (Ada.Directories.Simple_Name (Found))
                    in "adb" | "ads" | "c" | "h" | "cc" | "cpp" | "hpp" | "py" | "rs" | "go" | "js" | "ts"
                     | "java" | "kt" | "rb" | "cs" | "swift";
               end loop;
               Ada.Directories.End_Search (Search);
               return Result;
            exception
               when others =>
                  return Result;
            end Holds;
            --  src/ and the directories in it: src/library, src/main.
            function Holds_Below (Where : String) return Boolean is
               Search : Ada.Directories.Search_Type;
               Found  : Ada.Directories.Directory_Entry_Type;
               Result : Boolean := Holds (Where);
            begin
               if Result or else not Ada.Directories.Exists (Where) then
                  return Result;
               end if;
               Ada.Directories.Start_Search
                 (Search, Where, "", [Ada.Directories.Directory => True, others => False]);
               while Ada.Directories.More_Entries (Search) and then not Result loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  if Ada.Directories.Simple_Name (Found) not in "." | ".." then
                     Result := Holds (Ada.Directories.Full_Name (Found));
                  end if;
               end loop;
               Ada.Directories.End_Search (Search);
               return Result;
            exception
               when others =>
                  return Result;
            end Holds_Below;
         begin
            return Holds (Project_Directory) or else Holds_Below (Hostkit.Fs.Join (Project_Directory, "src"));
         end Has_Own_Sources;
         Own_Sources : constant Boolean := Has_Own_Sources;
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

                        --  Two files that are one once the inputs are in:
                        --  the same text is one file, different text is a
                        --  conflict nothing in the templates resolves.
                        elsif Result.Files.Contains (Path) and then Result.Files (Path) /= Value then
                           Status := E.Make (E.Framework_Template_Conflict);
                           E.Add_Text (Status, "name", "file " & Path);
                           E.Add_Text (Status, "detail",
                                       Key & " is " & Path & " with these inputs, which another"
                                       & " file of the templates already is");
                           return;
                        end if;
                        --  A project that has code of its own keeps its own
                        --  layout: no stub sources or test scaffold beside
                        --  it -- only the dotfiles a template keeps tidy.
                        if Own_Sources and then Path'Length > 0 and then Path (Path'First) /= '.' then
                           Result.Skipped_Files.Append (Path);
                           goto Next_Setting;
                        end if;
                        Result.Files.Include (Path, Value);
                        Records.Set (Config, "file." & Path, Value);
                     end;

                  when others =>
                     Records.Set (Config, Field, Value);
               end case;
            end;
            <<Next_Setting>>
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

         --  A check run in a directory of the project that is there already
         --  runs where its crate is: tests/cache_tests, when tests holds no
         --  alire.toml of its own and one directory below it does.
         for Index in 1 .. Records.Field_Count (Config) loop
            declare
               Field : constant String := Records.Field_Name (Config, Index);
            begin
               if Field'Length > 8 and then Field (Field'First .. Field'First + 7) = "profile." then
                  Records.Set (Config, Field, Crate_Located (Project_Directory, Records.Get (Config, Field)));
               end if;
            end;
         end loop;

         Records.Set
           (Config, "configuration_fingerprint",
            Configuration_Fingerprint (Config));
         Result.Configuration := Config;
      end;
   end Prepare;

   --  What makes a configuration one the project cannot keep, or "".
   function Whole_Problem (Config : Records.Item) return String;

   ----------------
   -- Initialize --
   ----------------

   --  Whether a directory holds anything of its own: a file or a
   --  directory other than version control's and the project's state.
   function Has_Own_Files (Directory : String) return Boolean is
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
      Any    : Boolean := False;
   begin
      Ada.Directories.Start_Search (Search, Directory, "");
      while Ada.Directories.More_Entries (Search) and then not Any loop
         Ada.Directories.Get_Next_Entry (Search, Found);
         Any := Ada.Directories.Simple_Name (Found) not in "." | ".." | ".git" | ".model_runner";
      end loop;
      Ada.Directories.End_Search (Search);
      return Any;
   exception
      when others =>
         return False;
   end Has_Own_Files;

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
                Confidence => Level,
                Origin     => <>),
               Status);
         end if;
      end Add_Fact;

      --  Take back what was made: the state, and the files and directories
      --  it made -- a project half made is refused when made again.
      procedure Undo is
      begin
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
      end Undo;
   begin
      Done := (others => <>);
      Status := E.Success;

      if Stores.Is_Initialized (Project_Directory) then
         Status := E.Make (E.Framework_Already_Initialized);
         E.Add_Text
           (Status, "path", Stores.State_Root (Project_Directory), E.Param_Path);
         return;
      end if;

      --  A project starts with settings it can keep, as a change to them
      --  must leave it.
      if Whole_Problem (Planned.Configuration) /= "" then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "the configuration");
         E.Add_Text (Status, "detail", Whole_Problem (Planned.Configuration));
         return;
      end if;

      --  The project's own files, before its state: a project stopped part
      --  way is one with files and no state, which init makes again -- not
      --  one with state and files missing, which it refuses. A file the
      --  project already has is its own and is left as it is.
      for Directory of Planned.Directories loop
         declare
            Path : constant String := Hostkit.Fs.Join (Project_Directory, Directory);
            --  In a project with files of its own, a directory nothing
            --  planned goes into is not made empty: its scaffold was left out.
            Needed : constant Boolean :=
              (for some Position in Planned.Files.Iterate =>
                 Ada.Strings.Fixed.Index (Value_Maps.Key (Position), Directory & "/") = 1)
              or else not Has_Own_Files (Project_Directory);
         begin
            if Needed and then not Ada.Directories.Exists (Path) then
               if not Files.Make_Directory (Path) then
                  Files.Write_Failed (Path, Status);
                  Undo;
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
                  Undo;
                  return;
               end if;
               Files.Write_Text (Path, Value_Maps.Element (Position), Status);
               if E.Is_Error (Status) then
                  Undo;
                  return;
               end if;
               Done.Written_Files.Append (Name);
            end if;
         end;
      end loop;

      Stores.Put (Change, Config_Area, Current_Name, Planned.Configuration);
      Stores.Put
        (Change, Config_Area, First_History,
         Copy (Planned.Configuration, History_Entity & "000001"));

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
         Undo;
         return;
      end if;

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
            Undo;
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

   --  The settings the harness reads, by their whole names: where a name
   --  is given without its kind and the configuration holds none of it
   --  yet, the one of these it is.
   Known_Settings : constant array (1 .. 49) of access constant String :=
     [new String'("list.automation.rules"),
      new String'("list.verification.full"),
      new String'("scalar.agents.child_retries"),
      new String'("scalar.agents.max_active"),
      new String'("scalar.agents.max_children"),
      new String'("scalar.agents.max_depth"),
      new String'("scalar.agents.max_invocations"),
      new String'("scalar.agents.max_steps"),
      new String'("scalar.agents.max_tool_calls"),
      new String'("scalar.agents.max_seconds"),
      new String'("scalar.agents.on_child_failure"),
      new String'("scalar.agents.token_budget"),
      new String'("scalar.bootstrap.import"),
      new String'("scalar.context.rules"),
      new String'("scalar.execution.max_cpu_seconds"),
      new String'("scalar.execution.max_file_mb"),
      new String'("scalar.execution.max_memory_mb"),
      new String'("scalar.execution.max_processes"),
      new String'("scalar.execution.network"),
      new String'("scalar.execution.output_limit"),
      new String'("scalar.execution.process_slots"),
      new String'("scalar.execution.shell"),
      new String'("scalar.execution.timeout"),
      new String'("scalar.init.confirm"),
      new String'("scalar.model.default"),
      new String'("scalar.recovery.running"),
      new String'("scalar.repository.state_policy"),
      new String'("scalar.requirement.after_criteria_change"),
      new String'("scalar.requirement.after_text_change"),
      new String'("scalar.task.auto_accept"),
      new String'("scalar.task.coordination"),
      new String'("scalar.task.derived_kind"),
      new String'("scalar.verification.default"),
      new String'("scalar.verification.escalation"),
      new String'("scalar.verification.requirements"),
      new String'("scalar.verification.toolchain"),
      new String'("scalar.work.isolation"),
      new String'("scalar.work.lease"),
      new String'("scalar.work.max_workspaces"),
      new String'("set.bootstrap.propose"),
      new String'("set.bootstrap.sources"),
      new String'("set.components"),
      new String'("set.execution.allowed"),
      new String'("set.execution.environment"),
      new String'("set.requirement.transitions"),
      new String'("set.task.auto_accept"),
      new String'("set.task.forbidden"),
      new String'("set.task.gates"),
      new String'("set.task.transitions")];

   -----------------
   -- Default_Of --
   -----------------

   function Default_Of (Name : String) return String is
   begin
      if Name = "scalar.agents.max_depth" then
         return "2";
      elsif Name = "scalar.agents.max_children" then
         return "3";
      elsif Name = "scalar.agents.max_active" then
         return "4";
      elsif Name = "scalar.agents.child_retries" then
         return "1: a required helper that fails is run once more";
      elsif Name = "scalar.agents.token_budget" then
         return "200000";
      elsif Name = "scalar.agents.max_steps" then
         return "24";
      elsif Name in "scalar.agents.max_tool_calls" | "scalar.agents.max_invocations"
                  | "scalar.work.max_workspaces"
      then
         return "no limit";
      elsif Name = "scalar.agents.max_seconds" then
         return "the lease, scalar.work.lease";
      elsif Name = "scalar.agents.on_child_failure" then
         return "block: the task is blocked once a required helper fails twice";
      elsif Name = "scalar.work.lease" then
         return "3600 seconds";
      elsif Name = "scalar.work.isolation" then
         return "project: agents work in the project itself";
      elsif Name = "scalar.execution.timeout" then
         return "600 seconds";
      elsif Name = "scalar.execution.output_limit" then
         return "1048576 bytes";
      elsif Name = "scalar.execution.shell" then
         return "not allowed";
      elsif Name = "scalar.execution.network" then
         return "as the host has it";
      elsif Name in "scalar.execution.max_cpu_seconds" | "scalar.execution.max_file_mb"
                  | "scalar.execution.max_memory_mb" | "scalar.execution.max_processes"
                  | "scalar.execution.process_slots"
      then
         return "no limit";
      elsif Name = "set.execution.allowed" then
         return "none: checks may run no program";
      elsif Name = "scalar.verification.toolchain" then
         return "the tools' versions are recorded, not held to";
      elsif Name = "scalar.init.confirm" then
         return "no";
      elsif Name = "scalar.bootstrap.import" then
         return "accepted: an item a document names by its own identifier is imported accepted";
      elsif Name = "set.bootstrap.sources" then
         return "the Markdown at the top and in docs and below it, a changelog left out";
      elsif Name = "set.bootstrap.propose" then
         return "everything bootstrap finds";
      elsif Name = "set.components" then
         return "one: the project itself";
      elsif Name = "scalar.model.default" then
         return "none: a run's context is planned with the session model's own room; a profile named here --"
           & " default, or one map.model.NAME sets -- plans it within that profile's limits; the model /work"
           & " runs is this session's, or model=PATH";
      elsif Name = "scalar.verification.default" then
         return "none: it must name a profile";
      end if;
      return "";
   end Default_Of;

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
      elsif Starts (Name, "map.permission.") and then Ada.Strings.Fixed.Index (Name, "create_children") > 0
      then
         return "permissions: how many helpers an agent at that level makes and parts it splits its"
           & " task into, and how deep, within agents.max_children and agents.max_depth -- a person's"
           & " /task split is not bounded by them";
      elsif Starts (Name, "map.permission.") then
         return "permissions: what agents started from now on may do";
      elsif Starts (Name, "task_kind.") then
         return "tasks of kind " & Name (Name'First + 10 .. Name'Last)
           & ": the fields new ones may have";
      elsif Name in "scalar.agents.max_children" | "scalar.agents.max_depth" then
         return "agents: the most helpers any agent makes, and parts an agent splits a task into, and"
           & " how deep -- the project's bound, below which a level's create_children max_children"
           & " and max_depth hold; a person's /task split is not bounded by it";
      elsif Starts (Name, "scalar.work.") or else Starts (Name, "scalar.agents.")
        or else Starts (Name, "scalar.task.max_seconds.") or else Starts (Name, "scalar.task.max_tool_calls.")
        or else Starts (Name, "scalar.task.max_steps.") or else Starts (Name, "scalar.task.token_budget.")
      then
         return "work: how agents run tasks from now on";
      elsif Starts (Name, "map.model.") or else Name = "scalar.model.default" then
         return "context: the room a run's context is planned with, from the next /work or /task context on";
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
      --  A constraint a capability does not take: places for reading and
      --  writing, helpers' bounds for helpers.
      if Starts (Name, "map.permission.") then
         declare
            Word : constant String := Name (Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward) + 1 .. Name'Last);
         begin
            if (Ada.Strings.Fixed.Index (Value, "roots=") > 0 or else Ada.Strings.Fixed.Index (Value, "deny=") > 0)
              and then (for some One in Permissions.Capability => Permissions.Word (One) = Word)
              and then Word not in "read_source" | "write_source" | "read_specs" | "write_specs"
            then
               return Word & " takes no roots= or deny=: places are for read_source, write_source, read_specs and"
                 & " write_specs; on grants it whole";
            elsif (Ada.Strings.Fixed.Index (Value, "max_depth=") > 0
                   or else Ada.Strings.Fixed.Index (Value, "max_children=") > 0)
              and then (for some One in Permissions.Capability => Permissions.Word (One) = Word)
              and then Word /= "create_children"
            then
               return Word & " takes no max_depth= or max_children=: those bound create_children";
            end if;
         end;
      end if;
         --  A name in the agents', work's or tasks' family that nothing
         --  reads: refused, not kept to do nothing.
         if Value /= ""
           and then (Starts (Name, "scalar.agents.") or else Starts (Name, "scalar.work.")
                     or else Starts (Name, "scalar.task."))
           and then not (for some Known of Known_Settings => Known.all = Name)
           and then not Starts (Name, "scalar.task.profile.")
           and then not (for some Limit of Name_Lists.Vector'
                           (["max_seconds", "max_tool_calls", "max_steps", "token_budget", "coordination",
                             "output_reserve", "isolation"]) =>
                           Starts (Name, "scalar.task." & Limit & ".")
                           and then Name'Length > 13 + Limit'Length)
           --  What /work takes, set for every run: model, steps, profile.
           and then Name not in "scalar.work.model" | "scalar.work.steps" | "scalar.work.profile"
                              | "scalar.work.agent"
         then
            declare
               Rest : constant String := Name (Ada.Strings.Fixed.Index (Name, ".", Name'First + 7) + 1 .. Name'Last);
               --  The settings there are, a kind's own limits for the kind it
               --  ends with among them.
               function Near_Names return Name_Lists.Vector is
                  Result : Name_Lists.Vector := Known_Names;
                  Last   : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
               begin
                  for Limit of Name_Lists.Vector'(["max_seconds", "max_tool_calls", "max_steps", "token_budget"]) loop
                     Result.Append ("scalar.task." & Limit & Name (Last .. Name'Last));
                  end loop;
                  return Result;
               end Near_Names;
            begin
               return (if Starts (Name, "scalar.task.")
                         and then Rest in "max_seconds" | "max_tool_calls" | "max_steps" | "token_budget"
                       then Name & " is not read: a limit for one kind of task is " & Name
                            & ".KIND, and scalar.agents." & Rest & " is the one for every task"
                       elsif Starts (Name, "scalar.task.max_depth") or else Starts (Name, "scalar.task.max_children")
                       then "there is no setting " & Name & "; how deep helpers go and how many there are is"
                            & " scalar.agents.max_depth and max_children for every agent, and a kind's"
                            & " map.permission.kind.KIND.create_children=max_depth=N max_children=N"
                       elsif Nearest (Name, Near_Names) /= ""
                       then "there is no setting " & Name & "; did you mean " & Nearest (Name, Near_Names) & "?"
                       else "nothing reads " & Name & "; /config lists the settings there are");
            end;
         end if;
      --  A limit of nothing lets an agent do nothing: refused, with what
      --  leaving it unset gives.
      if Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both) = "0"
        and then (Name in "scalar.agents.max_steps" | "scalar.agents.max_seconds" | "scalar.agents.token_budget"
                  or else Starts (Name, "scalar.task.max_steps.") or else Starts (Name, "scalar.task.max_seconds.")
                  or else Starts (Name, "scalar.task.token_budget."))
      then
         return "0 would let an agent do nothing; give the most it may, or leave it unset for "
           & (if Starts (Name, "scalar.task.") then "the agents' own" else "the default");
      end if;
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
      --  A kind's or a role's level whole: none of it, or the level above's.
      elsif (((Starts (Name, "map.permission.kind.") or else Starts (Name, "map.permission.role."))
              and then Ada.Strings.Fixed.Count (Name (Name'First + 20 .. Name'Last), ".") = 0)
             --  The project's whole too: each capability off, or its default.
             or else Name = "map.permission.project")
        and then Value in "none" | "inherit"
      then
         null;
      elsif Starts (Name, "map.permission.") and then Value not in "off" | "inherit" then
         declare
            Last_Dot : constant Natural :=
              Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
            Level    : Permissions.Permission_Set;
            Read     : E.Error_Info;
         begin
            Permissions.Restriction
              (Name (Last_Dot + 1 .. Name'Last) & ": " & Value, Level, Read);
            --  Bounds of nothing: no helper made, so withheld in all but name.
            if E.Is_Ok (Read) and then Name (Last_Dot + 1 .. Name'Last) = "create_children"
              and then (Ada.Strings.Fixed.Index (Value & " ", "max_depth=0 ") > 0
                        or else Ada.Strings.Fixed.Index (Value & " ", "max_children=0 ") > 0)
            then
               return "a bound of 0 lets it make no helper -- " & Name & "=off withholds it so, and"
                 & " max_depth=1 lets it make helpers that make none";
            end if;
            if E.Is_Error (Read)
              and then Name (Last_Dot + 1 .. Name'Last) in "project" | "kind" | "role" | "task"
            then
               --  A whole level at once: each of its capabilities is set.
               return "a level is not set whole: set each capability as " & Name
                 & ".CAPABILITY=..., as " & Name & ".read_source=off"
                 & ", or " & Name & "=none to withhold all, " & Name & "=inherit for "
                 & (if Name = "map.permission.project" then "the defaults" else "the level above's");
            elsif E.Is_Error (Read)
              and then (Starts (Name, "map.permission.kind.") or else Starts (Name, "map.permission.role."))
              and then Ada.Strings.Fixed.Count (Name (Name'First + 20 .. Name'Last), ".") = 0
            then
               return "a level is not set whole: set each capability as " & Name
                 & ".CAPABILITY=..., or " & Name & "=none to withhold all, " & Name & "=inherit to follow the"
                 & " level above";
            elsif E.Is_Error (Read) then
               return E.Text_Of (Read, "detail");
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

      --  What a meaning begins with, up to its first comma.
      function First_Word (Meaning : String) return String is
         Stop : constant Natural := Ada.Strings.Fixed.Index (Meaning, ",");
      begin
         return Ada.Strings.Fixed.Trim
           ((if Stop = 0 then Meaning else Meaning (Meaning'First .. Stop - 1)), Ada.Strings.Both);
      end First_Word;

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
            elsif Starts (Name, "map.task.state.")
              and then not Tasks.Core_Task_States.Contains (First_Word (Records.Get (Config, Name)))
            then
               return Name & " says first the core state it counts as -- for what waits on it --"
                 & " as accepted, and set aside";
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
            elsif Starts (Name, "map.requirement.state.")
              and then not Intent.Core_Requirement_States.Contains
                             (First_Word (Records.Get (Config, Name)))
            then
               return Name & " says first the core state it counts as -- for the work serving it"
                 & " -- as accepted, and waiting for sign-off";
            end if;
         end;
      end loop;

      if not Among ("scalar.repository.state_policy", "portable, local, all") then
         return "scalar.repository.state_policy is portable, local or all";
      elsif not Among ("scalar.work.isolation", "project, workspace") then
         return "scalar.work.isolation is project or workspace";
      end if;

      --  What the harness reads as one of some words is one of them: any
      --  other is read as none, and would change what it does unsaid.
      declare
         function Off (Field, Words : String) return Boolean is (not Among (Field, Words));
         function Said (Field, Words : String) return String
         is (Field & " is one of " & Words & ", not " & Records.Get (Config, Field));
      begin
         if Off ("scalar.bootstrap.import", "candidate, accepted") then
            return Said ("scalar.bootstrap.import", "candidate, accepted");
         elsif Off ("scalar.execution.network", "allowed, denied") then
            return Said ("scalar.execution.network", "allowed, denied");
         elsif Off ("scalar.execution.shell", "allowed, denied") then
            return Said ("scalar.execution.shell", "allowed, denied");
         elsif Off ("scalar.task.auto_accept", "true, false") then
            return Said ("scalar.task.auto_accept", "true, false");
         elsif Off ("scalar.task.coordination", "parent_waits, parent_runs") then
            return Said ("scalar.task.coordination", "parent_waits, parent_runs");
         elsif Off ("scalar.verification.escalation", "conservative, narrow") then
            return Said ("scalar.verification.escalation", "conservative, narrow");
         elsif Off ("scalar.verification.toolchain", "recorded, strict") then
            return Said ("scalar.verification.toolchain", "recorded, strict");
         elsif Off ("scalar.agents.on_child_failure", "block, fail, continue") then
            return Said ("scalar.agents.on_child_failure", "block, fail, continue");
         elsif Off ("scalar.recovery.running", "blocked, failed, accepted") then
            return Said ("scalar.recovery.running", "blocked, failed, accepted");
         elsif Off ("scalar.requirement.after_text_change", "accepted, blocked") then
            return Said ("scalar.requirement.after_text_change", "accepted, blocked");
         elsif Off ("scalar.requirement.after_criteria_change", "implemented, accepted") then
            return Said ("scalar.requirement.after_criteria_change", "implemented, accepted");
         end if;
      end;

      --  And what it reads as a count is one: a word there is read as the
      --  default, which is not what was set.
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name  : constant String := Records.Field_Name (Config, Index);
            Value : constant String := Records.Get (Config, Name);
         begin
            if Starts (Name, "scalar.profile_capability.")
              and then Value not in "run_build" | "run_tests" | "run_static_analysis"
            then
               return Name & " is one of run_build, run_tests, run_static_analysis, not " & Value;
            end if;
            --  A per-kind limit under the agents' family, where it is not
            --  read: said, with where one is.
            if Starts (Name, "scalar.agents.max_steps.") or else Starts (Name, "scalar.agents.token_budget.")
              or else Starts (Name, "scalar.agents.max_tool_calls.")
              or else Starts (Name, "scalar.agents.max_seconds.")
            then
               declare
                  Rest : constant String := Name (Name'First + 14 .. Name'Last);
                  Dot  : constant Natural := Ada.Strings.Fixed.Index (Rest, ".");
               begin
                  return Name & " is not read: a limit for one kind of task is scalar.task."
                    & Rest (Rest'First .. Dot - 1) & "." & Rest (Dot + 1 .. Rest'Last);
               end;
            end if;
            --  A limit for one kind of task is a count as the whole one is.
            if (Starts (Name, "scalar.task.max_seconds.") or else Starts (Name, "scalar.task.max_tool_calls.")
                or else Starts (Name, "scalar.task.max_steps.") or else Starts (Name, "scalar.task.token_budget."))
              and then (Value'Length not in 1 .. 9
                        or else (for some C of Value => C not in '0' .. '9'))
            then
               return Name & " is a count"
                 & (if Starts (Name, "scalar.task.max_seconds.") then " of seconds"
                    elsif Starts (Name, "scalar.task.token_budget.") then " of tokens" else "")
                 & ", 1 or more in digits, not " & Value;
            end if;
            --  A model profile says what Context reads, each in its kind:
            --  a word it does not know would be dropped without a word.
            if Starts (Name, "map.model.") then
               declare
                  Start : Natural := Value'First;
               begin
                  for Index in Value'First .. Value'Last + 1 loop
                     if Index > Value'Last or else Value (Index) = ',' then
                        declare
                           Pair  : constant String := Ada.Strings.Fixed.Trim (Value (Start .. Index - 1),
                                                                             Ada.Strings.Both);
                           Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
                           Key   : constant String :=
                             (if Equal = 0 then Pair
                              else Ada.Characters.Handling.To_Lower (Pair (Pair'First .. Equal - 1)));
                           Given : constant String := (if Equal = 0 then "" else Pair (Equal + 1 .. Pair'Last));
                        begin
                           if Pair = "" then
                              null;
                           elsif Key not in "context" | "reserve" | "overhead" | "tools" | "structured"
                                          | "reasoning" | "streaming" | "parallel" | "class" | "provider"
                           then
                              return Name & " takes context=N, reserve=N, overhead=N, tools=yes|no,"
                                & " structured=yes|no, reasoning=yes|no, streaming=yes|no, parallel=yes|no,"
                                & " class=NAME and provider=NAME, a comma apart; " & Key & " is none of them";
                           elsif Key in "context" | "reserve" | "overhead"
                             and then (Given'Length not in 1 .. 9
                                       or else (for some C of Given => C not in '0' .. '9'))
                           then
                              return Name & ": " & Key & " is a whole number of tokens, not " & Given;
                           elsif Key = "context" and then (for all C of Given => C = '0') then
                              return Name & ": context is 1 or more tokens, not " & Given;
                           elsif Key in "tools" | "structured" | "reasoning" | "streaming" | "parallel"
                             and then Ada.Characters.Handling.To_Lower (Given) not in "yes" | "no" | "true" | "false"
                           then
                              return Name & ": " & Key & " is yes or no, not " & Given;
                           end if;
                        end;
                        Start := Index + 1;
                     end if;
                  end loop;
                  --  Room kept for the answer is less than the whole room.
                  declare
                     function Number (Key : String) return Natural is
                        At_Key : constant Natural := Ada.Strings.Fixed.Index (Value, Key & "=");
                        Stop   : Natural;
                     begin
                        if At_Key = 0 or else (At_Key > Value'First and then Value (At_Key - 1) not in ',' | ' ')
                        then
                           return 0;
                        end if;
                        Stop := At_Key + Key'Length + 1;
                        while Stop <= Value'Last and then Value (Stop) in '0' .. '9' loop
                           Stop := Stop + 1;
                        end loop;
                        return (if Stop = At_Key + Key'Length + 1 or else Stop - (At_Key + Key'Length + 1) > 9 then 0
                                else Natural'Value (Value (At_Key + Key'Length + 1 .. Stop - 1)));
                     end Number;
                  begin
                     if Number ("context") > 0 and then Number ("reserve") >= Number ("context") then
                        return Name & ": reserve must be less than context, as the answer's room is kept of the"
                          & " whole --" & Natural'Image (Number ("reserve")) & " is not less than"
                          & Natural'Image (Number ("context"));
                     --  No reserve named: the built-in 1024 is kept all the same.
                     elsif Number ("context") > 0 and then Ada.Strings.Fixed.Index (Value, "reserve=") = 0
                       and then 1024 + Number ("overhead") >= Number ("context")
                     then
                        return Name & ": context=" & Ada.Strings.Fixed.Trim (Natural'Image (Number ("context")),
                                                                           Ada.Strings.Both)
                          & " leaves no room: the answer's reserve, built in, is 1024 -- give more context, or"
                          & " a smaller reserve= with it";
                     end if;
                  end;
               end;
            end if;
            --  The model profile used names one the configuration has: a
            --  file name there is no profile, and nothing would read it.
            if Name = "scalar.model.default" and then Value not in "" | "default"
              and then not Records.Has (Config, "map.model." & Value)
            then
               declare
                  Known : Unbounded_String :=
                    (if Records.Has (Config, "map.model.default") then Null_Unbounded_String
                     else To_Unbounded_String ("default (built in)"));
               begin
                  for Other in 1 .. Records.Field_Count (Config) loop
                     if Starts (Records.Field_Name (Config, Other), "map.model.") then
                        Append (Known, (if Known = Null_Unbounded_String then "" else ", ")
                                & Records.Field_Name (Config, Other)
                                    (Records.Field_Name (Config, Other)'First + 10
                                     .. Records.Field_Name (Config, Other)'Last));
                     end if;
                  end loop;
                  return Name & " names a model profile, map.model.ID -- the limits a run's context is"
                    & " planned with, not the model file -- and there is no map.model." & Value
                    & (if Known = Null_Unbounded_String then "" else "; there are " & To_String (Known))
                    & "; /work model=PATH runs a model file";
               end;
            end if;
            --  None at once, or no workspace at all: nothing could run.
            if Name in "scalar.agents.max_active" | "scalar.work.max_workspaces"
              and then Value'Length in 1 .. 9 and then (for all C of Value => C = '0')
            then
               return Name & " is 1 or more, not " & Value & " -- with none, no task could be worked";
            end if;
            --  A lease of nothing would end every run as it starts: not
            --  taken for the default it would fall back to.
            if Name = "scalar.work.lease" and then Value'Length in 1 .. 9
              and then (for all C of Value => C = '0')
            then
               return Name & " is at least 1 second, not " & Value
                 & " -- a lease of nothing is out as it is taken, and the project could be taken back from"
                 & " a run as it starts";
            end if;
            if (Starts (Name, "scalar.agents.max_") or else Starts (Name, "scalar.execution.max_")
                or else Starts (Name, "scalar.retention.")
                or else Name in "scalar.agents.token_budget" | "scalar.execution.output_limit"
                              | "scalar.execution.process_slots" | "scalar.execution.timeout"
                              | "scalar.work.lease" | "scalar.work.max_workspaces")
              and then (Value'Length not in 1 .. 9
                        or else (for some C of Value => C not in '0' .. '9'))
            then
               return Name & " is a count"
                 & (if Ada.Strings.Fixed.Index (Name, "seconds") > 0 or else Name in "scalar.work.lease"
                         | "scalar.execution.timeout"
                    then " of seconds" elsif Ada.Strings.Fixed.Index (Name, "token") > 0 then " of tokens"
                    elsif Name = "scalar.execution.output_limit" then " of bytes" else "")
                 --  As the check of 0 below has it: 1 or more where 0 is refused.
                 & (if Name in "scalar.agents.max_steps" | "scalar.agents.token_budget" | "scalar.work.lease"
                             | "scalar.agents.max_seconds" | "scalar.agents.max_active" | "scalar.work.max_workspaces"
                    then ", 1 or more" else ", 0 or more")
                 & " in digits, not " & Value;
            end if;
         end;
      end loop;
      return "";
   end Whole_Problem;

   --  How many letters apart two names are: added, taken out or changed.
   function Distance (Left, Right : String) return Natural is
      Row : array (0 .. Right'Length) of Natural;
      Before, Diagonal : Natural;
   begin
      for J in Row'Range loop
         Row (J) := J;
      end loop;
      for I in 1 .. Left'Length loop
         Diagonal := Row (0);
         Row (0) := I;
         for J in 1 .. Right'Length loop
            Before := Row (J);
            Row (J) := Natural'Min
              (Natural'Min (Row (J) + 1, Row (J - 1) + 1),
               Diagonal + (if Left (Left'First + I - 1) = Right (Right'First + J - 1) then 0 else 1));
            Diagonal := Before;
         end loop;
      end loop;
      return Row (Right'Length);
   end Distance;

   ----------------
   -- Known_Names --
   ----------------

   function Known_Names return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Known of Known_Settings loop
         Result.Append (Known.all);
      end loop;
      return Result;
   end Known_Names;

   ----------------
   -- Meaning_Of --
   ----------------

   function Meaning_Of (Name : String) return String is
   begin
      --  A kind's own limit: the agents' one, for that kind, over it.
      for Limit of Name_Lists.Vector'(["max_seconds", "max_tool_calls", "max_steps", "token_budget"]) loop
         if Starts (Name, "scalar.task." & Limit & ".")
           and then Name'Length > 13 + Limit'Length
           and then Meaning_Of ("scalar.agents." & Limit) /= ""
         then
            return Meaning_Of ("scalar.agents." & Limit) & " -- for tasks of kind "
              & Name (Name'First + 13 + Limit'Length .. Name'Last) & ", over agents." & Limit;
         end if;
      end loop;
      if Name = "list.automation.rules" then
         return "rules run when something happens, one a line: WHEN -> DO";
      elsif Name = "list.verification.full" then
         return "the profiles /check full runs, in order";
      elsif Name = "scalar.agents.child_retries" then
         return "how often a helper that failed is run again: a count";
      elsif Name = "scalar.agents.max_active" then
         return "how many agents may run at once: a count, 1 or more";
      elsif Name = "scalar.agents.max_children" then
         return "how many helpers an agent may make: a count, 0 for none";
      elsif Name = "scalar.agents.max_depth" then
         return "how deep helpers may make helpers: a count";
      elsif Name = "scalar.agents.max_invocations" then
         return "how many model calls a run may make: a count, 0 for no limit";
      elsif Name = "scalar.agents.max_steps" then
         return "how many steps an agent may take on a task: a count, 1 or more";
      elsif Name = "scalar.agents.max_tool_calls" then
         return "how many tool calls an agent may make: a count, 0 for no limit";
      elsif Name = "scalar.agents.max_seconds" then
         return "how long an agent may work on a task: seconds";
      elsif Name = "scalar.agents.on_child_failure" then
         return "what a failed helper does to its task: block, fail or continue";
      elsif Name = "scalar.agents.token_budget" then
         return "how many tokens an agent may spend on a task: a count";
      elsif Name = "scalar.bootstrap.import" then
         return "what bootstrap makes of an item a document names by its own identifier: accepted or candidate";
      elsif Name = "scalar.context.rules" then
         return "which standing rules an agent is told: all, or those of its task";
      elsif Name = "scalar.execution.max_cpu_seconds" then
         return "how much processor time a check may use: seconds";
      elsif Name = "scalar.execution.max_file_mb" then
         return "how large a file a check may write: megabytes";
      elsif Name = "scalar.execution.max_memory_mb" then
         return "how much memory a check may use: megabytes";
      elsif Name = "scalar.execution.max_processes" then
         return "how many processes a check may start: a count";
      elsif Name = "scalar.execution.network" then
         return "whether a check may reach the network: allowed or denied";
      elsif Name = "scalar.execution.output_limit" then
         return "how much of a check's output is kept: bytes";
      elsif Name = "scalar.execution.process_slots" then
         return "how many checks run at once: a count";
      elsif Name = "scalar.execution.shell" then
         return "whether a check runs in a shell: allowed or denied";
      elsif Name = "scalar.execution.timeout" then
         return "how long a check may run: seconds";
      elsif Name = "scalar.init.confirm" then
         return "whether /init asks before it writes: yes or no";
      elsif Name = "scalar.model.default" then
         return "the model profile, map.model.NAME, a run's context is planned with";
      elsif Name = "scalar.recovery.running" then
         return "what a task left running when the session ended becomes: blocked, failed or accepted";
      elsif Name = "scalar.repository.state_policy" then
         return "what of .model_runner/ goes into git: what its .gitignore leaves in";
      elsif Name = "scalar.requirement.after_criteria_change" then
         return "what an implemented requirement becomes when its criteria change: implemented or accepted";
      elsif Name = "scalar.requirement.after_text_change" then
         return "what a requirement becomes when its text changes: accepted or blocked";
      elsif Name = "scalar.task.auto_accept" then
         return "whether every task made is accepted on its own: true or false";
      elsif Name = "scalar.task.coordination" then
         return "whether a parent waits for its parts: parent_waits or parent_runs";
      elsif Name = "scalar.task.derived_kind" then
         return "the kind of the tasks derived from requirements";
      elsif Name = "scalar.verification.default" then
         return "the profile that checks a task when its kind names none";
      elsif Name = "scalar.verification.escalation" then
         return "how far a failed check widens what is run again: conservative or narrow";
      elsif Name = "scalar.verification.requirements" then
         return "the profile requirements themselves are checked by";
      elsif Name = "scalar.verification.toolchain" then
         return "whether the tools a check ran are only recorded or must match: recorded or strict";
      elsif Name = "scalar.work.isolation" then
         return "where agents write: project, the project itself, or workspace, one apart per task";
      elsif Name = "scalar.work.lease" then
         return "how long a task is held for a run: seconds, 1 or more";
      elsif Name = "scalar.work.max_workspaces" then
         return "how many workspaces may be open at once: a count";
      elsif Name = "set.bootstrap.propose" then
         return "what bootstrap proposes: requirements, specifications, decisions";
      elsif Name = "set.bootstrap.sources" then
         return "the documents bootstrap reads: files and patterns, * one directory, dir/** all below";
      elsif Name = "set.components" then
         return "the project's components, by name";
      elsif Name = "set.execution.allowed" then
         return "the programs a check may run, by name";
      elsif Name = "set.execution.environment" then
         return "the environment variables a check is given";
      elsif Name = "set.requirement.transitions" then
         return "the moves a requirement may make beyond the harness's own";
      elsif Name = "set.task.auto_accept" then
         return "the kinds of task accepted on their own when made";
      elsif Name = "set.task.forbidden" then
         return "the moves a task may not make";
      elsif Name = "set.task.gates" then
         return "what must hold before a task is complete";
      elsif Name = "set.task.transitions" then
         return "the moves a task may make beyond the harness's own";
      end if;
      return "";
   end Meaning_Of;

   -----------------
   -- Plan_Change --
   -----------------

   --  A setting left unset, as /config says it: what holds then.
   function Not_Set (Name : String) return String
   is (if Default_Of (Name) = "" then "(not set)"
       else "(not set: " & Default_Of (Name) & ")");

   procedure Plan_Normalized
     (Item    : Stores.Store;
      Changes : Value_Maps.Map;
      Result  : out Change_Plan;
      Status  : out Model_Runner.Errors.Error_Info);

   procedure Plan_Change
     (Item    : Stores.Store;
      Changes : Value_Maps.Map;
      Result  : out Change_Plan;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      --  A kind's or a role's level emptied -- LEVEL= -- is inherit: it
      --  follows the level above, as NAME= takes any setting's own away.
      Normal : Value_Maps.Map := Changes;
   begin
      for Position in Changes.Iterate loop
         declare
            Name : constant String := Value_Maps.Key (Position);
         begin
            if Value_Maps.Element (Position) = ""
              and then (Starts (Name, "map.permission.kind.") or else Starts (Name, "map.permission.role."))
              and then Ada.Strings.Fixed.Count (Name (Name'First + 20 .. Name'Last), ".") = 0
            then
               Normal.Include (Name, "inherit");
            --  The project's level whole: none, written so, as a kind's is --
            --  nothing granted -- or inherit, its own taken away, the
            --  harness's defaults holding. What it says of each capability
            --  goes either way.
            elsif Name = "map.permission.project" and then Value_Maps.Element (Position) in "none" | "inherit" then
               declare
                  Config : Records.Item;
                  Got    : E.Error_Info;
               begin
                  Read (Item, Config, Got);
                  if Value_Maps.Element (Position) = "inherit" then
                     Normal.Delete (Name);
                  end if;
                  if E.Is_Ok (Got) then
                     for Index in 1 .. Records.Field_Count (Config) loop
                        if Starts (Records.Field_Name (Config, Index), "map.permission.project.")
                          or else (Value_Maps.Element (Position) = "inherit"
                                   and then Records.Field_Name (Config, Index) = "map.permission.project")
                        then
                           Normal.Include (Records.Field_Name (Config, Index), "");
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
      Plan_Normalized (Item, Normal, Result, Status);
   end Plan_Change;

   procedure Plan_Normalized
     (Item    : Stores.Store;
      Changes : Value_Maps.Map;
      Result  : out Change_Plan;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      --  The permissions this change takes away: taken away after all else,
      --  so that one level's defaults written out do not grant them again.
      Taken_Away : Name_Lists.Vector;

      --  Whether the level a permission belongs to grants anything: a level
      --  that says something grants only what it says.
      function Level_Said (Name : String) return Boolean is
         Dot    : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
         Prefix : constant String := (if Dot = 0 then Name else Name (Name'First .. Dot));
      begin
         --  A level said to grant none says so: what it names is all it has.
         if Dot > Name'First and then Records.Get (Result.Before, Name (Name'First .. Dot - 1)) = "none" then
            return True;
         end if;
         for Index in 1 .. Records.Field_Count (Result.Before) loop
            if Starts (Records.Field_Name (Result.Before, Index), Prefix) then
               return True;
            end if;
         end loop;
         return False;
      end Level_Said;

      --  Whether the word from From on says NAME=VALUE: the roots end
      --  there; any other word after a space or a comma is one more root.
      function Setting_At (Text : String; From : Positive) return Boolean is
      begin
         for Index in From .. Text'Last loop
            exit when Text (Index) in '|' | ',' | ' ';
            if Text (Index) = '=' then
               return True;
            end if;
         end loop;
         return False;
      end Setting_At;

      function Is_Capability (Word : String) return Boolean is
      begin
         return (for some One in Permissions.Capability => Permissions.Word (One) = Word);
      end Is_Capability;

      --  What is wrong with the level a permission is set at: only the
      --  project, a kind of task the project has, and a role are read; a
      --  task's own are its permissions field.
      function Level_Problem (Name : String) return String is
         Rest  : constant String := Name (Name'First + 15 .. Name'Last);
         Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
         Whole : constant Boolean := Dot = 0 or else not Is_Capability (Rest (Dot + 1 .. Rest'Last));
         Level : constant String :=
           (if Whole then Rest else Rest (Rest'First .. Dot - 1));
      begin
         if Level = "project" or else (Dot = 0 and then not Whole) then
            return "";
         elsif Starts (Level, "kind.") then
            if Records.Has (Result.Before, "task_kind." & Level (Level'First + 5 .. Level'Last)) then
               return "";
            end if;
            declare
               Known : Unbounded_String;
            begin
               for Index in 1 .. Records.Field_Count (Result.Before) loop
                  if Starts (Records.Field_Name (Result.Before, Index), "task_kind.") then
                     declare
                        Field : constant String := Records.Field_Name (Result.Before, Index);
                     begin
                        Append (Known, (if Known = Null_Unbounded_String then "" else ", ")
                                & Field (Field'First + 10 .. Field'Last));
                     end;
                  end if;
               end loop;
               declare
                  Kinds : Name_Lists.Vector;
               begin
                  for Index in 1 .. Records.Field_Count (Result.Before) loop
                     if Starts (Records.Field_Name (Result.Before, Index), "task_kind.") then
                        Kinds.Append (Records.Field_Name (Result.Before, Index)
                                        (Records.Field_Name (Result.Before, Index)'First + 10
                                         .. Records.Field_Name (Result.Before, Index)'Last));
                     end if;
                  end loop;
                  return Level (Level'First + 5 .. Level'Last) & " is no kind of task the project has"
                    & (if Nearest (Level (Level'First + 5 .. Level'Last), Kinds) /= ""
                       then " -- did you mean " & Nearest (Level (Level'First + 5 .. Level'Last), Kinds) & "?"
                       else "")
                    & "; they are " & To_String (Known);
               end;
            end;
         elsif Starts (Level, "role.")
           and then Ada.Strings.Fixed.Index (Level (Level'First + 5 .. Level'Last), ".") = 0
         then
            --  The role an agent works in is worker: another is read by nothing.
            return (if Level (Level'First + 5 .. Level'Last) = "worker"
                      or else (for some Index in 1 .. Records.Field_Count (Result.Before) =>
                                 Starts (Records.Field_Name (Result.Before, Index), "map.permission." & Level))
                    then ""
                    else Level (Level'First + 5 .. Level'Last) & " is no role an agent works in, so nothing would"
                         & " read it; the role there is is worker: map.permission.role.worker.CAPABILITY=...");
         elsif Starts (Level, "task.") then
            return "a task's permissions are its own field: /task edit "
              & Level (Level'First + 5 .. Level'Last) & " permissions=... sets them";
         else
            return Level & " is no level permissions are read at: they are project, kind.KIND and"
              & " role.ROLE";
         end if;
      end Level_Problem;

      --  A new profile nothing runs -- no kind's profile, not the default,
      --  not the full verification, in the configuration or this change:
      --  refused, with the profiles there are, as it would change nothing.
      function Unused_Profile (Name : String) return String is
         Profile : constant String := (if Starts (Name, "profile.") then Name (Name'First + 8 .. Name'Last) else "");
         Known   : Unbounded_String;

         function Names_It (Field, Value : String) return Boolean
         is ((Starts (Field, "scalar.task.profile.") or else Field = "scalar.verification.default"
              or else Field = "list.verification.full")
             and then Lines_Of (Value).Contains (Profile));
      begin
         if Profile = "" or else Records.Has (Result.Before, Name) then
            return "";
         end if;
         for Index in 1 .. Records.Field_Count (Result.Before) loop
            declare
               Field : constant String := Records.Field_Name (Result.Before, Index);
            begin
               if Names_It (Field, Records.Get (Result.Before, Field)) then
                  return "";
               end if;
               if Starts (Field, "profile.") then
                  Append (Known, (if Known = Null_Unbounded_String then "" else ", ") & Field);
               end if;
            end;
         end loop;
         for Position in Changes.Iterate loop
            if Names_It ((if Starts (Value_Maps.Key (Position), "scalar.")
                            or else Starts (Value_Maps.Key (Position), "list.")
                          then Value_Maps.Key (Position) else "scalar." & Value_Maps.Key (Position)),
                         Value_Maps.Element (Position))
            then
               return "";
            end if;
         end loop;
         return "no task kind, nor the default or the full verification, runs a profile called " & Profile
           & (if Known = Null_Unbounded_String then "" else "; the profiles are " & To_String (Known))
           & " -- change one of those, or add task.profile.KIND=" & Profile & " in the same /reconfigure";
      end Unused_Profile;

      --  A setting a task kind has its own of, named for a kind the
      --  project does not have: refused as a level of one is.
      function Kind_Problem (Name : String) return String is
      begin
         for Family of Name_Lists.Vector'
           (["scalar.task.max_seconds.", "scalar.task.max_tool_calls.", "scalar.task.max_steps.",
             "scalar.task.token_budget.", "scalar.task.coordination.", "scalar.task.profile."])
         loop
            if Starts (Name, Family) and then Name'Length > Family'Length then
               return Level_Problem ("map.permission.kind." & Name (Name'First + Family'Length .. Name'Last));
            end if;
         end loop;
         return "";
      end Kind_Problem;

      --  A root the value names that another component has already, the
      --  same place however written (src and src/): two cannot both own it.
      function Shared_Root (Name, Value : String) return String is
         function Bare (Root : String) return String is
            Last : Natural := Root'Last;
         begin
            while Last > Root'First and then Root (Last) = '/' loop
               Last := Last - 1;
            end loop;
            return (if Root'Length > 2 and then Root (Root'First .. Root'First + 1) = "./"
                    then Root (Root'First + 2 .. Last) else Root (Root'First .. Last));
         end Bare;

         function Roots (Text : String) return Name_Lists.Vector is
            Result : Name_Lists.Vector;
            Mark   : constant Natural := Ada.Strings.Fixed.Index (Text, "roots=");
            Start  : Natural;
         begin
            if Mark = 0 then
               return Result;
            end if;
            Start := Mark + 6;
            for Index in Mark + 6 .. Text'Last + 1 loop
               if Index > Text'Last or else Text (Index) in '|' | ',' | ' ' then
                  if Index > Start then
                     Result.Append (Bare (Text (Start .. Index - 1)));
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            return Result;
         end Roots;

         Mine : constant Name_Lists.Vector := Roots (Value);
      begin
         for Index in 1 .. Records.Field_Count (Result.After) loop
            declare
               Field : constant String := Records.Field_Name (Result.After, Index);
            begin
               if Starts (Field, "map.component.") and then Field /= Name then
                  for Theirs of Roots (Records.Get (Result.After, Field)) loop
                     if Mine.Contains (Theirs) then
                        return Theirs & " is " & Field (Field'First + 14 .. Field'Last)
                          & "'s root already, and two components cannot both own its files; name a"
                          & " narrower root, or change " & Field (Field'First + 14 .. Field'Last) & "'s";
                     end if;
                  end loop;
               end if;
            end;
         end loop;
         return "";
      end Shared_Root;

      --  The first root a component's placing names that is not there.
      function Missing_Root (Value : String) return String is
         Mark  : constant Natural := Ada.Strings.Fixed.Index (Value, "roots=");
         Start : Natural;
         Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      begin
         if Mark = 0 then
            return "";
         end if;
         Start := Mark + 6;
         for Index in Mark + 6 .. Value'Last + 1 loop
            if Index > Value'Last or else Value (Index) in '|' | ',' | ' ' then
               if Index > Start then
                  declare
                     Root : constant String := Value (Start .. Index - 1);
                  begin
                     if not Ada.Directories.Exists (Hostkit.Fs.Join (Project, Root))
                       or else Root (Root'First) = '/' or else Ada.Strings.Fixed.Index (Root, "..") > 0
                     then
                        return Root;
                     end if;
                  end;
               end if;
               Start := Index + 1;
               exit when Index <= Value'Last and then Value (Index) in ',' | ' '
                 and then Setting_At (Value, Index + 1);
            end if;
         end loop;
         return "";
      end Missing_Root;

      --  A change asked for that cannot be made: the caller's to put right.
      --  A name that is no setting: said as a name, not as a value.
      function Unknown (Name, Detail : String) return E.Error_Info is
         Made : E.Error_Info := E.Make (E.Framework_Input_Invalid);
      begin
         E.Add_Text (Made, "name", "a setting's name");
         E.Add_Text (Made, "value", Name);
         E.Add_Text (Made, "detail", Detail);
         return Made;
      end Unknown;

      function Refused (Name, Detail : String) return E.Error_Info is
         Made : E.Error_Info := E.Make (E.CLI_Invalid_Option_Value);
      begin
         E.Add_Text (Made, "option", Name);
         E.Add_Text (Made, "value", Detail);
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
            Written : constant String := Value_Maps.Key (Position);

            --  NAME+=VALUE adds to a set or a list what it holds already;
            --  NAME-=VALUE takes out of it.
            Adding  : constant Boolean :=
              Written'Length > 1 and then Written (Written'Last) = '+';
            Taking  : constant Boolean :=
              Written'Length > 1 and then Written (Written'Last) = '-';
            Short   : constant String :=
              (if Adding or else Taking then Written (Written'First .. Written'Last - 1)
               else Written);

            --  A name without its kind is the setting of that name there
            --  is: work.lease is scalar.work.lease when that is the one.
            function Full_Name return String is
               Found : Unbounded_String;
               Count : Natural := 0;
            begin
               --  A capability named with no level is the project's:
               --  map.permission.use_network is map.permission.project.use_network.
               for Level_Prefix of Name_Lists.Vector'(["map.permission.", "permission."]) loop
                  if Starts (Short, Level_Prefix)
                    and then Ada.Strings.Fixed.Index (Short (Short'First + Level_Prefix'Length .. Short'Last), ".") = 0
                    and then (for some One in Permissions.Capability =>
                                Permissions.Word (One) = Short (Short'First + Level_Prefix'Length .. Short'Last))
                  then
                     return "map.permission.project." & Short (Short'First + Level_Prefix'Length .. Short'Last);
                  end if;
               end loop;
               if (for some Prefix of Changeable => Starts (Short, Prefix.all)) then
                  return Short;
               end if;
               for Prefix of Changeable loop
                  if Records.Get (Result.Before, Prefix.all & Short) /= "" then
                     Found := To_Unbounded_String (Prefix.all & Short);
                     Count := Count + 1;
                  end if;
               end loop;
               if Count = 0 then
                  for Known of Known_Settings loop
                     if Known'Length > Short'Length
                       and then Known (Known'Last - Short'Length + 1 .. Known'Last) = Short
                       and then Known (Known'Last - Short'Length) = '.'
                       and then (for some Prefix of Changeable =>
                                   Prefix.all & Short = Known.all)
                     then
                        Found := To_Unbounded_String (Known.all);
                        Count := Count + 1;
                     end if;
                  end loop;
               end if;
               --  A setting a task kind has its own of: task.max_seconds.KIND
               --  is scalar.task.max_seconds.KIND, as the whole of it is.
               if Count = 0 then
                  for Family of Name_Lists.Vector'
                    (["task.max_seconds.", "task.max_tool_calls.", "task.max_steps.",
                      "task.token_budget.", "task.coordination.", "task.profile."])
                  loop
                     if Starts (Short, Family) and then Short'Length > Family'Length then
                        return "scalar." & Short;
                     end if;
                  end loop;
               end if;
               return (if Count = 1 then To_String (Found) else Short);
            end Full_Name;

            Name  : constant String := Full_Name;
            --  A permission's places as the levels write them: ./src and src,
            --  a directory, are src/.
            function Normal_Places (Text : String) return String is
               Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
               Result  : Unbounded_String;
               Start   : Natural := Text'First;

               function One_Place (Place : String) return String is
                  Bare : constant String :=
                    (if Place'Length > 2 and then Place (Place'First .. Place'First + 1) = "./"
                     then Place (Place'First + 2 .. Place'Last) else Place);
                  Whole : constant String := Hostkit.Fs.Join (Project, Bare);
               begin
                  return (if Bare /= "" and then Bare (Bare'Last) /= '/' and then Ada.Directories.Exists (Whole)
                            and then Ada.Directories."=" (Ada.Directories.Kind (Whole), Ada.Directories.Directory)
                          then Bare & "/" else Bare);
               exception
                  when others =>
                     return Bare;
               end One_Place;

               function One_Word (Word : String) return String is
                  Eq : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
               begin
                  if Eq = 0 or else Word (Word'First .. Eq) not in "roots=" | "deny=" then
                     return Word;
                  end if;
                  declare
                     Said : Unbounded_String := To_Unbounded_String (Word (Word'First .. Eq));
                     From : Natural := Eq + 1;
                  begin
                     for Index in Eq + 1 .. Word'Last + 1 loop
                        if Index > Word'Last or else Word (Index) = '|' then
                           Append (Said, (if From = Eq + 1 then "" else "|") & One_Place (Word (From .. Index - 1)));
                           From := Index + 1;
                        end if;
                     end loop;
                     return To_String (Said);
                  end;
               end One_Word;
            begin
               if not Starts (Full_Name, "map.permission.") then
                  return Text;
               end if;
               for Index in Text'First .. Text'Last + 1 loop
                  if Index > Text'Last or else Text (Index) = ' ' then
                     if Index > Start then
                        Append (Result, (if Result = Null_Unbounded_String then "" else " ")
                                & One_Word (Text (Start .. Index - 1)));
                     end if;
                     Start := Index + 1;
                  end if;
               end loop;
               return To_String (Result);
            end Normal_Places;

            Raw   : constant String := Normal_Places (Value_Maps.Element (Position));

            --  One capability of a permission level: NAME= takes its entry
            --  out, as it does any setting's -- not granted there -- and on
            --  grants it with nothing more.
            One_Capability : constant Boolean :=
              Starts (Name, "map.permission.")
              and then Is_Capability
                         (Name (Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward) + 1 .. Name'Last))
              and then Ada.Strings.Fixed.Index (Name (Name'First + 15 .. Name'Last), ".") > 0;
            --  The roots a capability holds now, as roots=...; "" where
            --  it holds none.
            function Roots_Held return String is
               Held : constant String := Records.Get (Result.Before, Name);
               At_Roots : constant Natural := Ada.Strings.Fixed.Index (Held, "roots=");
               Stop : Natural;
            begin
               if At_Roots = 0 then
                  return "";
               end if;
               Stop := Ada.Strings.Fixed.Index (Held (At_Roots .. Held'Last), " ");
               return Held (At_Roots .. (if Stop = 0 then Held'Last else Stop - 1));
            end Roots_Held;
            --  What it denies now, as deny=...; "" where nothing.
            function Deny_Held return String is
               Held    : constant String := Records.Get (Result.Before, Name);
               At_Deny : constant Natural := Ada.Strings.Fixed.Index (Held, "deny=");
               Stop    : Natural;
            begin
               if At_Deny = 0 then
                  return "";
               end if;
               Stop := Ada.Strings.Fixed.Index (Held (At_Deny .. Held'Last), " ");
               return Held (At_Deny .. (if Stop = 0 then Held'Last else Stop - 1));
            end Deny_Held;
            --  A helpers' bound it holds now -- set, or the project's
            --  default -- as KEY=N; "" where none.
            function Bound_Held (Key : String) return String is
               Held : constant String :=
                 (if Records.Has (Result.Before, Name) then Records.Get (Result.Before, Name)
                  elsif Starts (Name, "map.permission.project.")
                  then Permissions.Grant_Text (Permissions.Project_Default (Permissions.Create_Children))
                  else "");
               At_Key : constant Natural := Ada.Strings.Fixed.Index (Held, Key & "=");
               Stop   : Natural;
            begin
               if At_Key = 0 then
                  return "";
               end if;
               Stop := Ada.Strings.Fixed.Index (Held (At_Key .. Held'Last), " ");
               return Held (At_Key .. (if Stop = 0 then Held'Last else Stop - 1));
            end Bound_Held;
            Helpers : constant Boolean := One_Capability and then Name'Length > 16
              and then Name (Name'Last - 15 .. Name'Last) = ".create_children";
            --  deny= alone, or deny=none, takes the deny away: what is left.
            No_Deny : constant Boolean :=
              One_Capability
              and then (Raw in "deny=" | "deny=none"
                        or else (Ada.Strings.Fixed.Index (Raw, " deny=none") > 0
                                 and then Ada.Strings.Fixed.Index (Raw, " deny=none") + 9 = Raw'Last));
            Given : constant String :=
              (if No_Deny and then Raw in "deny=" | "deny=none"
               then (if Roots_Held = "" then "" else Roots_Held)
               elsif No_Deny then Raw (Raw'First .. Ada.Strings.Fixed.Index (Raw, " deny=none") - 1)
               elsif One_Capability and then Raw = "" then "off"
               --  One bound of the helpers given keeps the other it had.
               elsif Helpers and then Ada.Strings.Fixed.Index (Raw, "max_children=") > 0
                 and then Ada.Strings.Fixed.Index (Raw, "max_depth=") = 0 and then Bound_Held ("max_depth") /= ""
               then Raw & " " & Bound_Held ("max_depth")
               elsif Helpers and then Ada.Strings.Fixed.Index (Raw, "max_depth=") > 0
                 and then Ada.Strings.Fixed.Index (Raw, "max_children=") = 0
                 and then Bound_Held ("max_children") /= ""
               then Raw & " " & Bound_Held ("max_children")
               elsif One_Capability and then Raw = "on" then ""
               --  A deny alone adds to the roots held: it takes out of
               --  them, it does not open the rest of the project.
               elsif One_Capability and then Starts (Raw, "deny=")
                 and then Ada.Strings.Fixed.Index (Raw, "roots=") = 0 and then Roots_Held /= ""
               then Roots_Held & " " & Raw
               --  New roots alone keep what it denies: a narrowing is not
               --  undone by naming where it may write.
               elsif One_Capability and then Starts (Raw, "roots=")
                 and then Ada.Strings.Fixed.Index (Raw, "deny=") = 0 and then Deny_Held /= ""
               then Raw & " " & Deny_Held
               else Raw);
            --  A set's items however they were written -- a space apart
            --  in a template, a line apart once changed: one a line.
            Old   : constant String :=
              --  No components listed is one: the project itself, by its
              --  name -- what one added is added beside.
              (if Name = "set.components" and then Records.Get (Result.Before, Name) = ""
                 and then not Tasks.Components_Of (Result.Before).Is_Empty
               then Tasks.Components_Of (Result.Before).First_Element
               elsif Starts (Name, "set.")
               then Lines_From (Ada.Strings.Fixed.Translate
                                  (Records.Get (Result.Before, Name),
                                   Ada.Strings.Maps.To_Mapping (" " & ASCII.LF, ",,")))
               else Records.Get (Result.Before, Name));
            --  A set of names -- components, programs -- is taken apart at
            --  spaces as at commas: none of them holds a space.
            function Spaced_As_Commas return String is
               Result : String := Given;
            begin
               if Name in "set.components" | "set.execution.allowed" then
                  for C of Result loop
                     if C = ' ' then
                        C := ',';
                     end if;
                  end loop;
               end if;
               return Result;
            end Spaced_As_Commas;

            --  The items of a set or list after the change: each once.
            function Items_After return String is
               Held   : Name_Lists.Vector := Lines_Of (Old);
               Result : Unbounded_String;
            begin
               if not (Adding or else Taking) then
                  Held.Clear;
               end if;
               for Item of Lines_Of (Lines_From (Spaced_As_Commas)) loop
                  if Taking then
                     if Held.Contains (Item) then
                        Held.Delete (Held.Find_Index (Item));
                     end if;
                  elsif not Held.Contains (Item) then
                     Held.Append (Item);
                  end if;
               end loop;
               for Item of Held loop
                  Append (Result, (if Result = Null_Unbounded_String then "" else ASCII.LF & "") & Item);
               end loop;
               return To_String (Result);
            end Items_After;

            Value : constant String :=
              (if Starts (Name, "set.") or else Starts (Name, "list.") then Items_After
               else Given);

            --  The settings a name that is none may have meant: those whose
            --  name holds it.
            function Near return String is
               Found : Unbounded_String;
               Count : Natural := 0;
            begin
               --  Those it is the last part of first; else, at most three
               --  that hold it.
               for Known of Known_Settings loop
                  if Known'Length > Short'Length
                    and then Known (Known'Last - Short'Length .. Known'Last) = "." & Short
                  then
                     Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Known.all
                             & (if Meaning_Of (Known.all) = "" then "" else " (" & Meaning_Of (Known.all) & ")"));
                     Count := Count + 1;
                  end if;
               end loop;
               --  Then those a letter or two from it, the kind left out.
               if Count = 0 then
                  for Known of Known_Settings loop
                     declare
                        Dot  : constant Natural := Ada.Strings.Fixed.Index (Known.all, ".");
                        Bare : constant String := Known (Dot + 1 .. Known'Last);
                     begin
                        if Count < 3
                          and then (Distance (Bare, Short) <= 2 or else Distance (Known.all, Short) <= 2)
                        then
                           Append (Found, (if Found = Null_Unbounded_String then "" else ", ")
                                   & Known.all);
                           Count := Count + 1;
                        end if;
                     end;
                  end loop;
               end if;
               if Count = 0 then
                  for Known of Known_Settings loop
                     if Count < 3 and then Ada.Strings.Fixed.Index (Known.all, Short) > 0 then
                        Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Known.all);
                        Count := Count + 1;
                     end if;
                  end loop;
               end if;
               return (if Found = Null_Unbounded_String then "" else "; did you mean " & To_String (Found) & "?");
            end Near;
         begin
            if Starts (Name, "input.")
              or else (not (for some Prefix of Changeable => Starts (Name, Prefix.all))
                       and then Records.Has (Result.Before, "input." & Name))
            then
               --  An input is what /init was given, kept as said: the
               --  settings it made are what is changed -- named, those whose
               --  value holds what it was given.
               declare
                  Input : constant String := (if Starts (Name, "input.") then Name else "input." & Name);
                  Given_Value : constant String := Records.Get (Result.Before, Input);
                  Made  : Unbounded_String;
               begin
                  for Index in 1 .. Records.Field_Count (Result.Before) loop
                     declare
                        Field : constant String := Records.Field_Name (Result.Before, Index);
                     begin
                        if Given_Value'Length > 1 and then not Starts (Field, "input.")
                          and then not Starts (Field, "file.")
                          and then (for some Prefix of Changeable => Starts (Field, Prefix.all))
                          and then Ada.Strings.Fixed.Index (Records.Get (Result.Before, Field), Given_Value) > 0
                        then
                           Append (Made, (if Made = Null_Unbounded_String then "" else ", ") & Field);
                        end if;
                     end;
                  end loop;
                  --  The project's own name is what its state is kept under:
                  --  fixed once the project is made.
                  if Input = "input.project_name" then
                     Status := Refused
                       (Name, "the project's name is fixed when /init makes it; a project under another"
                        & " name is a new /init");
                     return;
                  end if;
                  Status := Refused
                    (Name, Input & " is what /init was given, kept as it was; what it set is changed by"
                     & " the setting's own name"
                     & (if Made = Null_Unbounded_String then " -- /config lists them"
                        else ": " & To_String (Made)
                             & (if Ada.Strings.Fixed.Index (To_String (Made), "profile.") > 0
                                then " -- a profile is written LABEL: COMMAND, as profile.checks=""check: make test"""
                                else "")));
               end;
               return;
            --  The profile tasks are checked by has no default to fall back
            --  to: changed, not taken away.
            elsif Name in "scalar.verification.default" | "verification.default"
              and then Given in "" | "off"
            then
               declare
                  Profiles : Unbounded_String;
               begin
                  for Index in 1 .. Records.Field_Count (Result.Before) loop
                     if Starts (Records.Field_Name (Result.Before, Index), "profile.") then
                        Append (Profiles, (if Profiles = Null_Unbounded_String then "" else ", ")
                                & Records.Field_Name (Result.Before, Index)
                                    (Records.Field_Name (Result.Before, Index)'First + 8
                                     .. Records.Field_Name (Result.Before, Index)'Last));
                     end if;
                  end loop;
                  Status := Refused
                    (Name, "it names the profile tasks are checked by, and there is nothing to fall back"
                     & " to; /reconfigure verification.default=PROFILE names another"
                     & (if Profiles = Null_Unbounded_String then "" else " -- of " & To_String (Profiles)));
                  return;
               end;
            --  An outside program as the agent is out of scope: refused,
            --  and one an earlier version kept can only be taken out.
            elsif Name in "scalar.work.agent" | "work.agent"
              and then not (Given = "off" and then Records.Has (Result.Before, "scalar.work.agent"))
            then
               Status := Refused
                 (Name, "an outside program as the agent is out of scope: /work uses this session's"
                  & " model, or the one work model=PATH names"
                  & (if Records.Has (Result.Before, "scalar.work.agent") then "; work.agent=off takes it out"
                     else ""));
               return;
            elsif not (for some Prefix of Changeable => Starts (Name, Prefix.all)) then
               declare
                  Dot   : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
                  First : constant String := (if Dot = 0 then Name else Name (Name'First .. Dot - 1));
               begin
                  --  A family the harness reads has only the settings it
                  --  reads: no new one is made there.
                  Status := Unknown (Name, "there is no setting " & Name & Near
                                     & (if First in "agents" | "task" | "work" | "model" | "permission" | "execution"
                                                  | "verification" | "repository" | "bootstrap" | "requirement"
                                        then ""
                                        else "; a new one is named with its kind: scalar." & Name
                                             & " for one value, set." & Name & " for several"));
               end;
               return;
            --  Named with its kind, and none such is set or known, but one
            --  is a letter or two from it: the one meant, most likely.
            elsif not Records.Has (Result.Before, Name)
              and then not (for some Known of Known_Settings => Known.all = Name)
              and then (for some Known of Known_Settings =>
                          Distance (Known.all, Name) in 1 .. 2)
              and then not Starts (Name, "profile.") and then not Starts (Name, "fact.")
              and then not Starts (Name, "map.") and then not Starts (Name, "task_kind.")
            then
               Status := Unknown (Name, "there is no setting " & Name & Near);
               return;
            elsif (Adding or else Taking)
              and then not (Starts (Name, "set.") or else Starts (Name, "list."))
            then
               Status := Refused (Name, "/reconfigure add and remove change a set. or a list.; this is one value,"
                                 & " set as " & Name & "=VALUE");
               return;
            elsif Taking
              and then (for some Taken of Lines_Of (Lines_From (Given)) =>
                          not Lines_Of (Old).Contains (Taken))
            then
               --  What is not there is not taken out: said, with what is.
               declare
                  Held : Unbounded_String;
               begin
                  for One of Lines_Of (Old) loop
                     Append (Held, (if Held = Null_Unbounded_String then "" else ", ") & One);
                  end loop;
                  for Taken of Lines_Of (Lines_From (Given)) loop
                     if not Lines_Of (Old).Contains (Taken) then
                        Status := Refused
                          (Name, Taken & " is not in " & Name
                           & (if Held = Null_Unbounded_String then ", which is empty"
                              else " (it holds " & To_String (Held) & ")"));
                        return;
                     end if;
                  end loop;
               end;
            elsif not Records.Is_Field_Name (Name)
              or else (Starts (Name, "fact.") and then not Facts.Is_Key (Name (Name'First + 5 .. Name'Last)))
            then
               Status := E.Make (E.Framework_Name_Invalid);
               E.Add_Text (Status, "value", Name);
               return;
            --  A name nothing reads, or a kind there is not: the name is
            --  what is wrong, said so.
            elsif Problem (Name, Value) /= ""
              and then (Ada.Strings.Fixed.Index (Problem (Name, Value), "nothing reads") = 1
                        or else Ada.Strings.Fixed.Index (Problem (Name, Value), "there is no setting") = 1
                        or else Ada.Strings.Fixed.Index (Problem (Name, Value), " is not read: a limit for one kind")
                                > 0)
            then
               Status := Unknown (Name, Problem (Name, Value));
               return;
            elsif Problem (Name, Value) /= "" then
               Status := Refused (Name, Problem (Name, Value));
               return;
            elsif Starts (Name, "map.permission.") and then Level_Problem (Name) /= "" then
               Status := Refused (Name, Level_Problem (Name));
            elsif Kind_Problem (Name) /= "" then
               Status := Unknown (Name, Kind_Problem (Name));
               return;
            elsif Unused_Profile (Name) /= "" then
               Status := Refused (Name, Unused_Profile (Name));
               return;
            --  A model profile taken out that the default names: in use.
            elsif Starts (Name, "map.model.") and then Given = ""
              and then Records.Get (Result.Before, "scalar.model.default") = Name (Name'First + 10 .. Name'Last)
              and then not Changes.Contains ("scalar.model.default")
            then
               Status := Refused (Name, Name & " is in use: scalar.model.default names it -- /reconfigure"
                                  & " scalar.model.default= first, or both in one line");
               return;
            elsif Starts (Name, "map.permission.") and then Given = "off"
              and then (Ada.Strings.Fixed.Index (Name (Name'First + 15 .. Name'Last), ".") = 0
                        or else not Is_Capability
                                      (Name (Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward) + 1
                                             .. Name'Last)))
            then
               --  A level is not taken away whole: each capability is.
               Status := Refused (Name, "a level is not taken away whole: " & Name & "=none withholds all it"
                                  & " grants, " & Name & ".CAPABILITY=off one, and " & Name & "=inherit has it"
                                  & " follow the level above");
               return;
            elsif Starts (Name, "map.component.") and then Missing_Root (Value) /= ""
              and then (Missing_Root (Value) (Missing_Root (Value)'First) = '/'
                        or else Ada.Strings.Fixed.Index (Missing_Root (Value), "..") > 0)
            then
               declare
                  Root    : constant String := Missing_Root (Value);
                  Project : constant String :=
                    Ada.Directories.Containing_Directory (Stores.Root (Item));
                  Here    : constant String := Repository.Relative_Path (Project, Root);
               begin
                  Status := Refused
                    (Name, "its root " & Root & " is "
                     & (if Here /= Root and then Here /= ""
                        then "named from outside the project: name it from the project, as " & Here
                        else "outside the project; a root is a directory or a file within it, as"
                             & " src/terminal"));
                  return;
               end;
            elsif Starts (Name, "map.component.") and then Shared_Root (Name, Value) /= "" then
               Status := Refused (Name, Shared_Root (Name, Value));
               return;
            elsif Starts (Name, "map.component.") and then Missing_Root (Value) /= "" then
               Status := Refused
                 (Name, "its root " & Missing_Root (Value) & " is no file or directory in the"
                  & " project; a root is a directory, as src/terminal, or a file");
               return;
            end if;

            --  NAME=inherit: a level, or one capability of it, goes back to
            --  what the level above gives -- the level's own entries taken
            --  out, or the one written as the level above has it.
            if Starts (Name, "map.permission.") and then Given = "inherit" then
               declare
                  Rest  : constant String := Name (Name'First + 15 .. Name'Last);
                  Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
                  Whole : constant Boolean :=
                    Dot = 0 or else not Is_Capability (Rest (Dot + 1 .. Rest'Last));
                  Gone  : Name_Lists.Vector;
               begin
                  if Whole then
                     for Index in 1 .. Records.Field_Count (Result.After) loop
                        if Starts (Records.Field_Name (Result.After, Index), Name & ".") then
                           Gone.Append (Records.Field_Name (Result.After, Index));
                        end if;
                     end loop;
                     for Field of Gone loop
                        Records.Remove (Result.After, Field);
                     end loop;
                     if not Gone.Is_Empty then
                        Result.Changed.Append (Name & ": its own grants -> those of the level above");
                     end if;
                  --  A level below the project that says nothing of its own
                  --  has the level above's already: inherit changes nothing.
                  elsif not Records.Has (Result.Before, Name) and then not Level_Said (Name)
                    and then Rest (Rest'First .. Dot - 1) /= "project"
                  then
                     null;
                  elsif Records.Get (Result.After, Name) /= "inherit" then
                     --  Written as inherit: what the level above gives,
                     --  whenever it is asked; the project's default for the
                     --  project, which has none above it.
                     Records.Set (Result.After, Name, "inherit");
                     declare
                        --  What the level above gives this capability, which
                        --  it now has: said, as it is what changes.
                        Above : constant Permissions.Permission_Set :=
                          Permissions.Effective (Item, "", "", Within_Sandbox => False);
                        Project_Level : constant Boolean := Rest (Rest'First .. Dot - 1) = "project";
                        --  For the project, inherit is the harness's default
                        --  grant; for a level below, what the project gives.
                        Granted_Above : constant Boolean :=
                          (for some One in Permissions.Capability =>
                             Permissions.Word (One) = Rest (Dot + 1 .. Rest'Last)
                             and then (if Project_Level then Permissions.Project_Default (One).Granted
                                       else Above (One).Granted));
                        --  What it is now, as it holds: off where the level
                        --  names others and not this one.
                        Had_It : constant Boolean :=
                          (for some One in Permissions.Capability =>
                             Permissions.Word (One) = Rest (Dot + 1 .. Rest'Last) and then Above (One).Granted);
                     begin
                        Result.Changed.Append
                          (Name & ": " & (if Old /= "" then Old
                                          --  Set, with no limits: granted, as /config says.
                                          elsif Records.Has (Result.Before, Name) then "granted, no limits"
                                          elsif Project_Level then (if Had_It then "granted" else "withheld")
                                          elsif Level_Said (Name)
                                          then "withheld (this level grants only what it names)"
                                          else "(as the level above has it)") & " -> inherit, "
                           & (if Project_Level then "the harness's default"
                              else "as the level above gives it")
                           & (if Granted_Above then ": granted" else ": not granted"));
                     end;
                  end if;
                  if not Result.Impact.Contains (Reach (Name)) then
                     Result.Impact.Append (Reach (Name));
                  end if;
               end;
            elsif Starts (Name, "map.permission.") then
               if Given = "off" then
                  Taken_Away.Append (Name);
               end if;
               declare
                  Was : constant Boolean := Records.Has (Result.Before, Name);
                  Now : constant Boolean := Given /= "off";

                  --  The level it belongs to, and what that level has from
                  --  the one above while it says nothing itself.
                  Dot   : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
                  Level : constant String := Name (Name'First + 15 .. Dot - 1);
                  Above : constant Permissions.Permission_Set :=
                    Permissions.Effective (Item, "", "", Within_Sandbox => False);
                  Capable : Boolean := False;
                  Which   : Permissions.Capability := Permissions.Capability'First;

                  function Inherited return String is
                     Whence : constant String :=
                       (if Level = "project" then "the default" else "the level above");
                  begin
                     if not Capable or else not Above (Which).Granted then
                        return "withheld (by " & Whence & ")";
                     end if;
                     return "(" & Whence & ": "
                       & (if Permissions.Grant_Text (Above (Which)) = "" then "granted"
                          else Permissions.Grant_Text (Above (Which))) & ")";
                  end Inherited;
               begin
                  for One in Permissions.Capability loop
                     if Permissions.Word (One) = Name (Dot + 1 .. Name'Last) then
                        Capable := True;
                        Which := One;
                     end if;
                  end loop;

                  --  Withheld already, by the project's default: off is no
                  --  change, and nothing is written out for it.
                  if Level = "project" and then Capable and then Given = "off" and then not Was
                    and then not Permissions.Project_Default (Which).Granted
                  then
                     goto Name_Done;
                  end if;
                  --  A level that says nothing yet has what the one above
                  --  gives it; saying one thing there would take the rest
                  --  away, so what it had is written there first.
                  --  A level that says nothing yet has what the one above
                  --  gives it -- the project, its defaults. Saying one thing
                  --  there would take the rest away, so the rest is written
                  --  as inherit: read from above whenever it is asked, and
                  --  so following it when it changes, not frozen as it is.
                  if not Level_Said (Name) then
                     declare
                        Any : Boolean := False;
                     begin
                        for One in Permissions.Capability loop
                           declare
                              Field : constant String :=
                                "map.permission." & Level & "." & Permissions.Word (One);
                           begin
                              if Field /= Name and then not Records.Has (Result.After, Field)
                                and then (Level /= "project" or else Permissions.Project_Default (One).Granted)
                              then
                                 --  The project has nothing above it: its
                                 --  defaults are written out as they are.
                                 Records.Set
                                   (Result.After, Field,
                                    (if Level = "project"
                                     then Permissions.Grant_Text (Permissions.Project_Default (One))
                                     else "inherit"));
                                 Any := True;
                              end if;
                           end;
                        end loop;
                        if Any
                          and then not Result.Changed.Contains
                                         ("map.permission." & Level & ": the capabilities not named keep "
                                          & (if Level = "project" then "the defaults they had, now written out"
                                             else "following the level above, now written out as inherit"))
                        then
                           Result.Changed.Append
                             ("map.permission." & Level & ": the capabilities not named keep "
                              & (if Level = "project" then "the defaults they had, now written out"
                                 else "following the level above, now written out as inherit"));
                        end if;
                     end;
                  end if;
                  if Was /= Now or else (Now and then Given /= Old) then
                     if Now then
                        Records.Set (Result.After, Name, Given);
                     else
                        Records.Remove (Result.After, Name);
                     end if;
                     Result.Changed.Append
                       (Name & ": " & (if not Was and then Name = "map.permission.project"
                                       then "the defaults (not written)"
                                       elsif not Was and then Level_Said (Name)
                                         and then Records.Get (Result.Before,
                                                               Name (Name'First .. Ada.Strings.Fixed.Index
                                                                       (Name, ".", Ada.Strings.Backward) - 1))
                                                  = "none"
                                       then "withheld (this level grants none)"
                                       elsif not Was and then Level_Said (Name)
                                         and then Ada.Strings.Fixed.Index (Name, "map.permission.project.") = 0
                                       then "withheld (this level grants only what it names)"
                                       elsif not Was and then Level_Said (Name) then "withheld"
                                       elsif not Was then Inherited
                                       elsif Old = "" and then Level = "project" and then Capable
                                         and then not Above (Which).Granted
                                       then "withheld"
                                       elsif Old = "" then "granted" else Old)
                        & " -> " & (if not Now then "withheld" elsif Given = "" then "granted"
                                    else Given));
                     if not Result.Impact.Contains (Reach (Name)) then
                        Result.Impact.Append (Reach (Name));
                     end if;
                  end if;
                  <<Name_Done>>
               end;
            --  A component placed is unplaced by NAME=off, and a scalar or
            --  a set the harness has a default for goes back to it: its entry
            --  goes.
            elsif (Starts (Name, "map.component.") or else Starts (Name, "set.")
                   or else Starts (Name, "list.")
                   or else Name in "scalar.work.agent" | "scalar.model.default" | "scalar.work.model")
              and then Given = "off" and then not (Adding or else Taking)
            then
               if Old /= "" then
                  Records.Remove (Result.After, Name);
                  Result.Changed.Append
                    (Name & ": " & On_One_Line (Old) & " -> "
                     & (if (for some Known of Known_Settings => Known.all = Name)
                        then Not_Set (Name) else "(none)"));
                  if not Result.Impact.Contains (Reach (Name)) then
                     Result.Impact.Append (Reach (Name));
                  end if;
               end if;
            elsif Value /= Old then
               if Value = "" then
                  Records.Remove (Result.After, Name);
               else
                  Records.Set (Result.After, Name, Value);
               end if;
               declare
                  --  A kind's own limit, not set: the agents' one holds, as
                  --  it stands now.
                  Limit : constant String :=
                    (if Starts (Name, "scalar.task.max_steps.") then "max_steps"
                     elsif Starts (Name, "scalar.task.token_budget.") then "token_budget"
                     elsif Starts (Name, "scalar.task.max_tool_calls.") then "max_tool_calls"
                     elsif Starts (Name, "scalar.task.max_seconds.") then "max_seconds"
                     else "");
                  Kind  : constant String :=
                    (if Limit = "" then "" else Name (Name'First + 13 + Limit'Length .. Name'Last));
                  Whole_Limit : constant String :=
                    (if Limit = "" then ""
                     elsif Records.Get (Result.Before, "scalar.agents." & Limit) /= ""
                     then Records.Get (Result.Before, "scalar.agents." & Limit)
                     else Default_Of ("scalar.agents." & Limit));
                  Reached : Unbounded_String;
               begin
                  if Limit /= "" and then Old = "" then
                     Result.Changed.Append
                       (Name & ": (not set: agents." & Limit
                        & (if Whole_Limit = "" then "" else ", " & Whole_Limit & " now") & ") -> "
                        & (if Value = "" then "(none)" else On_One_Line (Value)));
                     --  The open tasks of that kind it reaches, by name.
                     for Id of Tasks.List (Item) loop
                        declare
                           Defined : Records.Item;
                           Got     : E.Error_Info;
                        begin
                           Tasks.Definition (Item, Id, Defined, Got);
                           if E.Is_Ok (Got) and then Records.Get (Defined, "kind") = Kind
                             and then Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected"
                           then
                              Append (Reached, (if Reached = Null_Unbounded_String then "" else ", ") & Id);
                           end if;
                        end;
                     end loop;
                     if Reached /= Null_Unbounded_String then
                        Result.Impact.Append ("tasks of kind " & Kind & ": " & To_String (Reached));
                     end if;
                     goto Changed_Said;
                  end if;
               end;
               Result.Changed.Append
                 (Name & ": "
                  & (if Old = "" and then (for some Known of Known_Settings => Known.all = Name)
                     then Not_Set (Name)
                     --  The model profile built in: there before it is written.
                     elsif Old = "" and then Name = "map.model.default"
                     then "(built in: context=8192, reserve=1024, overhead=0, tools=no, structured=yes,"
                          & " reasoning=no, streaming=yes, parallel=no)"
                     elsif Old = "" then "(none)" else On_One_Line (Old)) & " -> "
                  & (if Value = "" and then (for some Known of Known_Settings => Known.all = Name)
                     then Not_Set (Name)
                     elsif Value = "" then "(none)"
                     elsif Starts (Name, "map.model.") then On_One_Line (Value) & " (what it does not name as built in)"
                     else On_One_Line (Value)));
               <<Changed_Said>>
               if not Result.Impact.Contains (Reach (Name)) then
                  Result.Impact.Append (Reach (Name));
               end if;
            end if;
         end;
      end loop;

      --  What is taken away is away, whatever a level's defaults written
      --  out for another change put back; and the lines that said so kept
      --  are not said.
      for Name of Taken_Away loop
         if Records.Has (Result.After, Name) then
            Records.Remove (Result.After, Name);
         end if;
         declare
            Kept : Name_Lists.Vector;
         begin
            for Line of Result.Changed loop
               if not (Starts (Line, Name & ": (")
                       and then (Ada.Strings.Fixed.Index (Line, "-> kept") > 0
                                 or else Ada.Strings.Fixed.Index (Line, "-> inherit") > 0))
               then
                  Kept.Append (Line);
               end if;
            end loop;
            Result.Changed := Kept;
         end;
         --  Withheld already by the project's default: no change at all.
         if not (for some Line of Result.Changed => Starts (Line, Name & ":"))
           and then not (Starts (Name, "map.permission.project.") and then not Records.Has (Result.Before, Name)
                         and then (for some One in Permissions.Capability =>
                                     Permissions.Word (One) = Name (Name'First + 23 .. Name'Last)
                                     and then not Permissions.Project_Default (One).Granted))
         then
            Result.Changed.Append (Name & ": granted -> withheld");
         end if;
      end loop;

      --  A kind or role left with nothing named would take the level
      --  above's whole grant: what was taken away is kept taken, as a
      --  level that grants none.
      for Name of Taken_Away loop
         declare
            Dot   : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
            Level : constant String := Name (Name'First .. Dot - 1);
         begin
            if Level /= "map.permission.project"
              and then not (for some Index in 1 .. Records.Field_Count (Result.After) =>
                              Starts (Records.Field_Name (Result.After, Index), Level & "."))
              and then not Records.Has (Result.After, Level)
            then
               Records.Set (Result.After, Level, "none");
               Result.Changed.Append (Level & ": -> none, nothing granted (not the level above's grant)");
            end if;
         end;
      end loop;
      --  A level set whole: none takes each capability it named away and
      --  keeps the mark; inherit takes them all away, mark too, so the level
      --  above holds.
      for Position in Changes.Iterate loop
         declare
            Level_Name : constant String := Value_Maps.Key (Position);
            Whole      : constant String := Value_Maps.Element (Position);
         begin
            if (Starts (Level_Name, "map.permission.kind.") or else Starts (Level_Name, "map.permission.role."))
              and then Ada.Strings.Fixed.Count (Level_Name (Level_Name'First + 20 .. Level_Name'Last), ".") = 0
              and then Whole in "none" | "inherit"
            then
               declare
                  Had : constant Boolean :=
                    Records.Has (Result.Before, Level_Name)
                    or else (for some Index in 1 .. Records.Field_Count (Result.Before) =>
                               Starts (Records.Field_Name (Result.Before, Index), Level_Name & "."));
               begin
                  --  What it grants now, named, in place of any line said
                  --  of the level as if it were one capability.
                  for Index in reverse Result.Changed.First_Index .. Result.Changed.Last_Index loop
                     if Starts (Result.Changed (Index), Level_Name & ": ") then
                        Result.Changed.Delete (Index);
                     end if;
                  end loop;
                  if Had then
                     declare
                        Named : Unbounded_String;
                     begin
                        for Index in 1 .. Records.Field_Count (Result.Before) loop
                           declare
                              Field : constant String := Records.Field_Name (Result.Before, Index);
                              Value : constant String := Records.Get (Result.Before, Field);
                           begin
                              if Starts (Field, Level_Name & ".") and then Value not in "off" | "inherit" then
                                 Append (Named, (if Named = Null_Unbounded_String then "" else "; ")
                                         & Field (Field'First + Level_Name'Length + 1 .. Field'Last)
                                         & (if Value in "" | "on" then "" else " " & Value));
                              end if;
                           end;
                        end loop;
                        Result.Changed.Append
                          (Level_Name & ": "
                           & (if Records.Get (Result.Before, Level_Name) = "none" then "none"
                              elsif Named = Null_Unbounded_String then "nothing granted"
                              else To_String (Named))
                           & " -> " & (if Whole = "inherit" then "inherit, as the level above gives it"
                                       else "none (every capability withheld)"));
                     end;
                  --  Nothing of its own, taking the level above's: none
                  --  withholds all of that.
                  elsif Whole = "none" then
                     Result.Changed.Append
                       (Level_Name & ": as the level above gives it -> none (every capability withheld)");
                     if not Result.Impact.Contains (Reach (Level_Name)) then
                        Result.Impact.Append (Reach (Level_Name));
                     end if;
                  end if;
               end;
               for Index in reverse 1 .. Records.Field_Count (Result.After) loop
                  if Starts (Records.Field_Name (Result.After, Index), Level_Name & ".") then
                     Records.Remove (Result.After, Records.Field_Name (Result.After, Index));
                  end if;
               end loop;
               if Whole = "inherit" then
                  if Records.Has (Result.After, Level_Name) then
                     Records.Remove (Result.After, Level_Name);
                  end if;
               else
                  Records.Set (Result.After, Level_Name, "none");
               end if;
            end if;
         end;
      end loop;
      --  A level granted something again is no longer one that grants none.
      for Index in reverse 1 .. Records.Field_Count (Result.After) loop
         declare
            Name : constant String := Records.Field_Name (Result.After, Index);
         begin
            if Starts (Name, "map.permission.") and then Records.Get (Result.After, Name) = "none"
              and then (for some Other in 1 .. Records.Field_Count (Result.After) =>
                          Starts (Records.Field_Name (Result.After, Other), Name & "."))
            then
               Records.Remove (Result.After, Name);
            end if;
         end;
      end loop;

      --  The whole of it, as it would be.
      if not Result.Changed.Is_Empty and then Whole_Problem (Result.After) /= "" then
         --  Said of the setting it is about, where it names one first.
         declare
            Whole : constant String := Whole_Problem (Result.After);
            Space : constant Natural := Ada.Strings.Fixed.Index (Whole, " ");
            Named : constant String := (if Space = 0 then "" else Whole (Whole'First .. Space - 1));
         begin
            --  NAME: what is wrong -- the setting named, what is wrong said.
            if Named'Length > 1 and then Named (Named'Last) = ':' then
               Status := Refused (Named (Named'First .. Named'Last - 1), Whole (Space + 1 .. Whole'Last));
            elsif Named /= "" and then Ada.Strings.Fixed.Index (Named, ".") > 0 then
               Status := Refused (Named, "it" & Whole (Space .. Whole'Last));
            else
               Status := Refused ("reconfigure", Whole);
            end if;
         end;
         return;
      end if;

      --  Evidence is taken against what of a configuration bears on its
      --  checks: a change to that leaves what was verified before to be
      --  verified again; one to who works and how leaves it as it is.
      if not Result.Changed.Is_Empty
        and then Verification_Fingerprint (Result.Before) /= Verification_Fingerprint (Result.After)
      then
         Result.Impact.Append
           ("evidence: what its checks read changes, so each requirement's evidence is judged"
            & " again against it -- evidence taken under other settings may apply, or stop"
            & " applying");
      end if;
      Records.Set_Revision (Result.After, Records.Revision (Result.Before) + 1);
      Records.Set
        (Result.After, "configuration_fingerprint", Configuration_Fingerprint (Result.After));
   end Plan_Normalized;

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
      Kept   : Records.Item := Copy (Planned.After, History_Entity & Padded);
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

      --  A fact set here is the registry's too, as the person's word: the
      --  two do not drift apart, and what bootstrap compares with is this.
      for Index in 1 .. Records.Field_Count (Planned.After) loop
         declare
            Name  : constant String := Records.Field_Name (Planned.After, Index);
            Value : constant String := Records.Get (Planned.After, Name);
         begin
            if Starts (Name, "fact.") and then Value /= Records.Get (Planned.Before, Name) then
               Facts.Record_Fact
                 (Item, Change,
                  (Key        => To_Unbounded_String (Name (Name'First + 5 .. Name'Last)),
                   Value      => To_Unbounded_String (Value),
                   Source     => Facts.Explicit,
                   Confidence => Facts.Authoritative,
                   Origin     => To_Unbounded_String ("reconfiguration")),
                  Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;
      end loop;
      --  And one no longer set is no longer the registry's.
      for Index in 1 .. Records.Field_Count (Planned.Before) loop
         declare
            Name : constant String := Records.Field_Name (Planned.Before, Index);
         begin
            if Starts (Name, "fact.") and then Records.Get (Planned.After, Name) = "" then
               Facts.Retire (Item, Change, Name (Name'First + 5 .. Name'Last));
            end if;
         end;
      end loop;
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

   -------------
   -- Recover --
   -------------

   procedure Recover
     (Item     : in out Stores.Store;
      Restored : out Natural;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      use type Model_Runner.Errors.Error_Code;
      Current : Records.Item;
      Best    : Records.Item;
      Found   : Natural := 0;
   begin
      Restored := 0;
      Read (Item, Current, Status);
      if E.Is_Ok (Status) then
         return;
      end if;

      --  The newest revision the history keeps whole.
      for Name of Stores.Names (Item, Config_Area) loop
         if Starts (Name, "revision-") then
            declare
               Kept : Records.Item;
               Got  : E.Error_Info;
               Rev  : constant Natural :=
                 Natural'Value ("0" & Name (Name'First + 9 .. Name'Last));
            begin
               Stores.Read (Item, Config_Area, Name, Kept, Got);
               if E.Is_Ok (Got) and then Rev > Found
                 and then Records.Get (Kept, "configuration_fingerprint")
                            = Configuration_Fingerprint (Kept)
               then
                  Found := Rev;
                  Best := Kept;
               end if;
            end;
         end if;
      end loop;
      if Found = 0 then
         return;
      end if;

      --  A record that cannot be read at all is no revision to follow: it
      --  goes, and the history's takes its place from the first.
      if Status.Code /= E.Framework_Integrity_Failed then
         Files.Discard
           (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), Directory_Name (Config_Area)),
                             Current_Name & ".rec"));
      end if;
      declare
         Change : Stores.Transaction;
         Back   : Records.Item := Copy (Best, Current_Entity);
         Now    : constant Natural :=
           (if Status.Code = E.Framework_Integrity_Failed
            then Stores.Current_Revision (Item, Config_Area, Current_Name) else 0);
      begin
         Records.Remove (Back, "configuration_revision");
         Records.Set_Revision (Back, Now + 1);
         Stores.Put (Change, Config_Area, Current_Name, Back);
         Stores.Commit (Item, Change, Status);
         if E.Is_Ok (Status) then
            Restored := Found;
         end if;
      end;
   exception
      when Constraint_Error =>
         Restored := 0;
   end Recover;

end Model_Runner.Framework.Configurations;
