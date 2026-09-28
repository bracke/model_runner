with Ada.Characters.Handling;

with Hostkit.Fs;

with Model_Runner.Framework.Files;

package body Model_Runner.Framework.Templates is

   package E renames Model_Runner.Errors;

   Suffix : constant String := ".template";

   function Trim (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT | ASCII.CR
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trim;

   --  A value as written, with its escapes read.
   function Unescape (Text : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = '\' and then Index < Text'Last then
            case Text (Index + 1) is
               when 'n'    => Append (Result, ASCII.LF);
               when 't'    => Append (Result, ASCII.HT);
               when '\'    => Append (Result, '\');
               when others => Append (Result, Text (Index .. Index + 1));
            end case;
            Index := Index + 2;
         else
            Append (Result, Text (Index));
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Unescape;

   --  Whether a string is a template identifier: lower-case words of
   --  letters and digits joined by hyphens.
   function Is_Template_Id (Text : String) return Boolean
   is (Text'Length in 1 .. 64
       and then Text (Text'First) in 'a' .. 'z'
       and then Text (Text'Last) /= '-'
       and then (for all Char of Text => Char in 'a' .. 'z' | '0' .. '9' | '-'));

   --  Whether a string is a key a declaration can have.
   function Is_Key (Text : String) return Boolean
   is (Text'Length in 1 .. 200
       and then Text (Text'First) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'
       and then (for all Char of Text =>
                   Char in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
                         | '_' | '.' | '-' | '/'));

   ---------------------
   -- Is_Project_Path --
   ---------------------

   function Is_Project_Path (Text : String) return Boolean is
   begin
      if Text'Length not in 1 .. 200
        or else Text (Text'First) = '/'
        or else not (for all Char of Text =>
                       Char in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
                             | '_' | '.' | '-' | '/')
      then
         return False;
      end if;

      --  A segment of only dots is here or up, and neither names a file.
      declare
         Start : Natural := Text'First;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = '/' then
               if Index = Start
                 or else (for all Char of Text (Start .. Index - 1) =>
                            Char = '.')
               then
                  return False;
               end if;
               Start := Index + 1;
            end if;
         end loop;
      end;
      return True;
   end Is_Project_Path;

   --  A text with each ${name} in it written as one letter, which is what
   --  a path naming an input is checked as before the input is known.
   function Without_Inputs (Text : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Index < Text'Last and then Text (Index .. Index + 1) = "${" then
            Append (Result, 'x');
            while Index <= Text'Last and then Text (Index) /= '}' loop
               Index := Index + 1;
            end loop;
         else
            Append (Result, Text (Index));
         end if;
         Index := Index + 1;
      end loop;
      return To_String (Result);
   end Without_Inputs;

   --  The words of a comma-separated list, trimmed, empty ones left out.
   function Split (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ',' then
            declare
               Part : constant String := Trim (Text (Start .. Index - 1));
            begin
               if Part /= "" then
                  Result.Append (Part);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split;

   --  Whether a text begins with another.
   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   ---------------
   -- Kind_Word --
   ---------------

   function Kind_Word (Kind : Setting_Kind) return String is
      Image : constant String :=
        Ada.Characters.Handling.To_Lower (Setting_Kind'Image (Kind));
   begin
      return Image (Image'First .. Image'Last - 8);
   end Kind_Word;

   --  The kind a word names, if it names one.
   procedure Kind_Of
     (Word  : String;
      Kind  : out Setting_Kind;
      Found : out Boolean) is
   begin
      for Candidate in Setting_Kind loop
         if Kind_Word (Candidate) = Word then
            Kind := Candidate;
            Found := True;
            return;
         end if;
      end loop;
      Kind := Scalar_Setting;
      Found := False;
   end Kind_Of;

   --  Whether a kind has one value per key.
   function Keyed (Kind : Setting_Kind) return Boolean
   is (Kind not in Set_Setting | List_Setting);

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Text   : String;
      Origin : String;
      Value  : out Template;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Line_Number : Natural := 0;
      In_Input    : Boolean := False;
      Start       : Natural := Text'First;

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Template_Invalid);
         E.Add_Text (Status, "path", Origin, E.Param_Path);
         E.Add_Text
           (Status, "detail",
            (if Line_Number = 0 then Detail
             else "line" & Natural'Image (Line_Number) & ": " & Detail));
      end Refuse;

      --  The part of a line before " = ", and the part after.
      procedure Assignment
        (Line  : String;
         Left  : out Unbounded_String;
         Right : out Unbounded_String;
         Found : out Boolean) is
      begin
         for Index in Line'Range loop
            if Line (Index) = '=' then
               Left := To_Unbounded_String (Trim (Line (Line'First .. Index - 1)));
               Right := To_Unbounded_String
                 (Unescape (Trim (Line (Index + 1 .. Line'Last))));
               Found := True;
               return;
            end if;
         end loop;
         Left := Null_Unbounded_String;
         Right := Null_Unbounded_String;
         Found := False;
      end Assignment;

      function Truth (Word : String; Result : out Boolean) return Boolean is
      begin
         Result := Word = "true";
         return Word in "true" | "false";
      end Truth;

      --  One line of an input's block.
      procedure Input_Line (Line : String) is
         Left, Right : Unbounded_String;
         Found       : Boolean;
         Flag        : Boolean;
         Held        : Input_Declaration renames
           Value.Inputs (Value.Inputs.Last_Index);
      begin
         Assignment (Line, Left, Right, Found);
         if not Found then
            Refuse ("an input's line has no value");
            return;
         end if;

         declare
            Key  : constant String := To_String (Left);
            Said : constant String := To_String (Right);
         begin
            if Key = "type" then
               if Said = "text" then
                  Held.Kind := Text_Input;
               elsif Said = "identifier" then
                  Held.Kind := Identifier_Input;
               elsif Said = "natural" then
                  Held.Kind := Natural_Input;
               elsif Said = "path" then
                  Held.Kind := Path_Input;
               elsif Said = "choice" then
                  Held.Kind := Choice_Input;
               elsif Said = "boolean" then
                  Held.Kind := Boolean_Input;
               else
                  Refuse ("no input is of type " & Said);
               end if;
            elsif Key = "label" then
               Held.Label := Right;
            elsif Key = "description" then
               Held.Description := Right;
            elsif Key = "default" then
               Held.Default := Right;
            elsif Key = "choices" then
               Held.Choices := Right;
            elsif Key in "minimum" | "maximum" | "max_length" then
               if Said'Length not in 1 .. 9 or else not (for all C of Said => C in '0' .. '9') then
                  Refuse (Key & " is a whole number");
               elsif Key = "minimum" then
                  Held.Minimum := Natural'Value (Said);
               elsif Key = "maximum" then
                  Held.Maximum := Natural'Value (Said);
               else
                  Held.Max_Length := Natural'Value (Said);
               end if;
            elsif Key = "pattern" then
               Held.Pattern := Right;
            elsif Key in "required" | "secret" | "persist" then
               if not Truth (Said, Flag) then
                  Refuse (Key & " is true or false");
               elsif Key = "required" then
                  Held.Required := Flag;
               elsif Key = "secret" then
                  Held.Secret := Flag;
               else
                  Held.Persist := Flag;
               end if;
            else
               Refuse ("an input has no " & Key);
            end if;
         end;
      end Input_Line;

      --  A declaration: [override] kind key = value.
      procedure Declaration (Line : String; Override : Boolean) is
         Left, Right : Unbounded_String;
         Found       : Boolean;
         Kind        : Setting_Kind;
      begin
         Assignment (Line, Left, Right, Found);
         if not Found then
            Refuse ("a declaration has no value");
            return;
         end if;

         declare
            Words : constant String := To_String (Left);
            Space : Natural := 0;
         begin
            for Index in Words'Range loop
               if Words (Index) = ' ' then
                  Space := Index;
                  exit;
               end if;
            end loop;
            if Space = 0 then
               Refuse ("a declaration names no key");
               return;
            end if;

            Kind_Of (Words (Words'First .. Space - 1), Kind, Found);
            declare
               Key : constant String := Trim (Words (Space + 1 .. Words'Last));
            begin
               if not Found then
                  Refuse (Words (Words'First .. Space - 1)
                          & " is not something a template declares");
               elsif (if Kind = File_Setting
                      then not Is_Project_Path (Without_Inputs (Key))
                      else not Is_Key (Key))
               then
                  Refuse (Key & " is not a key");
               elsif Kind = Baseline_Setting
                 and then not Starts (Key, "project.") and then not Starts (Key, "language.")
               then
                  Refuse (Key & " is not a project. or language. baseline");
               else
                  Value.Settings.Append
                    (Setting'(Kind     => Kind,
                      Key      => To_Unbounded_String (Key),
                      Value    => Right,
                      Override => Override,
                      From     => Value.Id));
               end if;
            end;
         end;
      end Declaration;

      procedure Header (Key, Said : String) is
      begin
         if Key = "template" then
            if not Is_Template_Id (Said) then
               Refuse (Said & " is not a template identifier");
            end if;
            Value.Id := To_Unbounded_String (Said);
         elsif Key = "name" then
            Value.Name := To_Unbounded_String (Said);
         elsif Key = "description" then
            Value.Description := To_Unbounded_String (Said);
         elsif Key = "version" then
            Value.Version := To_Unbounded_String (Said);
         elsif Key = "category" then
            Value.Category := To_Unbounded_String (Said);
         elsif Key = "language" then
            Value.Language := To_Unbounded_String (Said);
         elsif Key = "tags" then
            Value.Tags := To_Unbounded_String (Said);
         elsif Key = "includes" then
            for Name of Split (Said) loop
               if not Is_Template_Id (Name) then
                  Refuse (Name & " is not a template identifier");
                  return;
               end if;
               Value.Includes.Append (Name);
            end loop;
         else
            Refuse ("a template says nothing about " & Key);
         end if;
      end Header;

      --  discover PATH fact|input KEY = VALUE
      procedure Discovery (Line : String) is
         Left, Right : Unbounded_String;
         Found       : Boolean;
      begin
         Assignment (Line, Left, Right, Found);
         declare
            Words : constant String := To_String (Left);
            Parts : Name_Lists.Vector;
            Start : Natural := Words'First;
         begin
            for Index in Words'First .. Words'Last + 1 loop
               if Index > Words'Last or else Words (Index) = ' ' then
                  if Index > Start then
                     Parts.Append (Words (Start .. Index - 1));
                  end if;
                  Start := Index + 1;
               end if;
            end loop;

            if not Found or else Natural (Parts.Length) /= 4
              or else Parts (3) not in "fact" | "input"
            then
               Refuse ("a discovery is: discover PATH fact|input KEY = VALUE");
            elsif not Is_Project_Path (Parts (2)) then
               Refuse (Parts (2) & " is not a path inside the project");
            elsif not Is_Key (Parts (4)) then
               Refuse (Parts (4) & " is not a key");
            else
               Value.Rules.Append
                 (Discovery_Rule'(Path     => To_Unbounded_String (Parts (2)),
                   To_Input => Parts (3) = "input",
                   Key      => To_Unbounded_String (Parts (4)),
                   Value    => Right));
            end if;
         end;
      end Discovery;

      procedure Line_Of (Raw : String) is
         Line  : constant String := Trim (Raw);
         Indented : constant Boolean :=
           Raw'Length > 0 and then Raw (Raw'First) in ' ' | ASCII.HT;
      begin
         if Line = "" or else Line (Line'First) = '#' then
            return;
         end if;

         if Indented and then In_Input then
            Input_Line (Line);
            return;
         end if;
         In_Input := False;

         declare
            First_Space : Natural := 0;
         begin
            for Index in Line'Range loop
               if Line (Index) = ' ' then
                  First_Space := Index;
                  exit;
               end if;
            end loop;

            declare
               Word : constant String :=
                 (if First_Space = 0 then Line
                  else Line (Line'First .. First_Space - 1));
               Rest : constant String :=
                 (if First_Space = 0 then ""
                  else Trim (Line (First_Space + 1 .. Line'Last)));
            begin
               if Word = "input" then
                  if not Is_Key (Rest) then
                     Refuse (Rest & " is not an input identifier");
                  else
                     Value.Inputs.Append
                       (Input_Declaration'(Id     => To_Unbounded_String (Rest),
                         Label  => To_Unbounded_String (Rest),
                         others => <>));
                     In_Input := True;
                  end if;
               elsif Word = "discover" then
                  Discovery (Line);
               elsif Word = "directory" then
                  if not Is_Project_Path (Rest) then
                     Refuse (Rest & " is not a path inside the project");
                  else
                     Value.Settings.Append
                       (Setting'(Kind     => Set_Setting,
                         Key      => To_Unbounded_String ("directories"),
                         Value    => To_Unbounded_String (Rest),
                         Override => False,
                         From     => Value.Id));
                  end if;
               elsif Word = "override" then
                  Declaration (Rest, Override => True);
               else
                  declare
                     Kind  : Setting_Kind;
                     Known : Boolean;
                     Left, Right : Unbounded_String;
                     Found : Boolean;
                  begin
                     Kind_Of (Word, Kind, Known);
                     if Known then
                        Declaration (Line, Override => False);
                     else
                        Assignment (Line, Left, Right, Found);
                        if Found then
                           Header (To_String (Left), To_String (Right));
                        else
                           Refuse ("this line is not understood");
                        end if;
                     end if;
                  end;
               end if;
            end;
         end;
      end Line_Of;
   begin
      Value := (others => <>);
      Value.Origin := To_Unbounded_String (Origin);
      Status := E.Success;

      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            Line_Number := Line_Number + 1;
            Line_Of (Text (Start .. Index - 1));
            if E.Is_Error (Status) then
               Value.Broken := Status;
               return;
            end if;
            Start := Index + 1;
         end if;
      end loop;

      --  Every declaration made before the identifier was read belongs to
      --  it as much as those after.
      for Held of Value.Settings loop
         Held.From := Value.Id;
      end loop;

      if Value.Id = Null_Unbounded_String then
         Refuse ("it does not say which template it is");
      elsif Value.Name = Null_Unbounded_String then
         Refuse ("it has no name to be shown by");
      elsif Value.Version = Null_Unbounded_String then
         Refuse ("it has no version");
      end if;

      for Held of Value.Inputs loop
         if Held.Kind = Choice_Input and then Split (To_String (Held.Choices))
                                                .Is_Empty
         then
            Line_Number := 0;
            Refuse ("input " & To_String (Held.Id) & " offers no choices");
         end if;
      end loop;

      Value.Fingerprint := To_Unbounded_String (Fingerprint (Text));
      Value.Broken := Status;
   end Parse;

   function Id (Value : Template) return String
   is (To_String (Value.Id));

   function Display_Name (Value : Template) return String
   is (To_String (Value.Name));

   function Description (Value : Template) return String
   is (To_String (Value.Description));

   function Version (Value : Template) return String
   is (To_String (Value.Version));

   function Origin (Value : Template) return String
   is (To_String (Value.Origin));

   function Template_Fingerprint (Value : Template) return String
   is (To_String (Value.Fingerprint));

   -------------
   -- Details --
   -------------

   function Details (Value : Template) return String is
      Result : Unbounded_String;

      procedure Add (Part : Unbounded_String) is
      begin
         if Part /= Null_Unbounded_String then
            if Result /= Null_Unbounded_String then
               Append (Result, ", ");
            end if;
            Append (Result, Part);
         end if;
      end Add;
   begin
      Add (Value.Category);
      Add (Value.Language);
      Add (Value.Tags);
      return To_String (Result);
   end Details;

   ---------------------------------------------------------------------------
   --  The registry.
   ---------------------------------------------------------------------------

   function Position (From : Registry; Id : String) return Natural is
   begin
      for Index in 1 .. Natural (From.Templates.Length) loop
         if To_String (From.Templates (Index).Id) = Id then
            return Index;
         end if;
      end loop;
      return 0;
   end Position;

   ---------
   -- Add --
   ---------

   procedure Add (Into : in out Registry; Value : Template) is
      Id    : constant String := To_String (Value.Id);
      Place : Positive := 1;
   begin
      if Position (Into, Id) /= 0 then
         return;
      end if;
      while Place <= Natural (Into.Templates.Length)
        and then To_String (Into.Templates (Place).Id) < Id
      loop
         Place := Place + 1;
      end loop;
      Into.Templates.Insert (Place, Value);
   end Add;

   --------------
   -- Discover --
   --------------

   procedure Discover
     (Directories : Name_Lists.Vector;
      Into        : out Registry) is
   begin
      Into := (others => <>);
      for Directory of Directories loop
         for File of Files.Files_In (Directory) loop
            if Files.Ends_With (File, Suffix) then
               declare
                  Path   : constant String := Hostkit.Fs.Join (Directory, File);
                  Text   : Unbounded_String;
                  Status : E.Error_Info;
                  Value  : Template;
               begin
                  Files.Read_Text (Path, Text, Status);
                  if E.Is_Ok (Status) then
                     Parse (To_String (Text), Path, Value, Status);
                  end if;

                  --  Kept under its file's name when it says no other, so
                  --  that a listing can say it is there and why it cannot
                  --  be used.
                  if E.Is_Error (Status) then
                     if not Is_Template_Id (To_String (Value.Id)) then
                        Value.Id := To_Unbounded_String
                          (File (File'First .. File'Last - Suffix'Length));
                     end if;
                     Value.Origin := To_Unbounded_String (Path);
                     Value.Broken := Status;
                  end if;
                  Add (Into, Value);
               end;
            end if;
         end loop;
      end loop;
   end Discover;

   function Count (From : Registry) return Natural
   is (Natural (From.Templates.Length));

   function Template_At (From : Registry; Index : Positive) return Template
   is (From.Templates (Index));

   -------------
   -- Problem --
   -------------

   function Problem
     (From  : Registry;
      Index : Positive) return Model_Runner.Errors.Error_Info
   is
      Result : Composition;
      Status : E.Error_Info;
   begin
      Compose (From, To_String (From.Templates (Index).Id), Result, Status);
      return Status;
   end Problem;

   ---------------------------------------------------------------------------
   --  Composition.
   ---------------------------------------------------------------------------

   -------------
   -- Compose --
   -------------

   procedure Compose
     (From   : Registry;
      Id     : String;
      Result : out Composition;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Visiting : Name_Lists.Vector;
      Prints   : Unbounded_String;

      procedure Conflict (Key, Detail : String) is
      begin
         Status := E.Make (E.Framework_Template_Conflict);
         E.Add_Text (Status, "name", Key);
         E.Add_Text (Status, "detail", Detail);
      end Conflict;

      --  Fold one template's declarations into what is composed so far.
      procedure Merge (Next : Template) is
      begin
         for Given of Next.Settings loop
            declare
               Held : Natural := 0;
            begin
               for Index in 1 .. Natural (Result.Settings.Length) loop
                  declare
                     Other : Setting renames Result.Settings (Index);
                  begin
                     if Other.Kind = Given.Kind and then Other.Key = Given.Key
                       and then (Keyed (Given.Kind)
                                 or else Other.Value = Given.Value)
                     then
                        Held := Index;
                        exit;
                     end if;
                  end;
               end loop;

               if Held = 0 then
                  Result.Settings.Append (Given);
               elsif not Keyed (Given.Kind) then
                  --  A set's or a list's value it already has: kept where
                  --  it was first.
                  null;
               elsif Result.Settings (Held).Value = Given.Value then
                  null;
               elsif Given.Override then
                  Result.Settings (Held) := Given;
               else
                  Conflict
                    (Kind_Word (Given.Kind) & " " & To_String (Given.Key),
                     To_String (Result.Settings (Held).From) & " gives "
                     & To_String (Result.Settings (Held).Value) & ", "
                     & To_String (Given.From) & " gives "
                     & To_String (Given.Value)
                     & ", and neither says override");
                  return;
               end if;
            end;
         end loop;

         for Given of Next.Inputs loop
            declare
               Held : Natural := 0;
            begin
               for Index in 1 .. Natural (Result.Inputs.Length) loop
                  if Result.Inputs (Index).Id = Given.Id then
                     Held := Index;
                  end if;
               end loop;

               if Held = 0 then
                  Result.Inputs.Append (Given);
               elsif Result.Inputs (Held) /= Given then
                  Conflict
                    ("input " & To_String (Given.Id),
                     To_String (Next.Id) & " declares it differently");
                  return;
               end if;
            end;
         end loop;

         for Given of Next.Rules loop
            Result.Rules.Append (Given);
         end loop;
      end Merge;

      procedure Visit (Name : String) is
         Place : constant Natural := Position (From, Name);
      begin
         if E.Is_Error (Status) or else Result.Order.Contains (Name) then
            return;
         elsif Place = 0 then
            Status := E.Make (E.Framework_Template_Not_Found);
            E.Add_Text (Status, "name", Name);
            return;
         elsif Visiting.Contains (Name) then
            Status := E.Make (E.Framework_Template_Invalid);
            E.Add_Text
              (Status, "path", Origin (From.Templates (Place)), E.Param_Path);
            E.Add_Text (Status, "detail", "it includes itself through " & Name);
            return;
         elsif E.Is_Error (From.Templates (Place).Broken) then
            Status := From.Templates (Place).Broken;
            return;
         end if;

         Visiting.Append (Name);
         for Included of From.Templates (Place).Includes loop
            Visit (Included);
         end loop;
         Visiting.Delete_Last;

         if E.Is_Ok (Status) then
            Merge (From.Templates (Place));
            Result.Order.Append (Name);
            Append (Prints, Name & "=" & Template_Fingerprint
                                            (From.Templates (Place)) & ";");
         end if;
      end Visit;
   begin
      Result := (others => <>);
      Status := E.Success;

      Visit (Id);
      if E.Is_Error (Status) then
         return;
      end if;

      Result.Root := From.Templates (Position (From, Id));
      Result.Fingerprint := To_Unbounded_String (Fingerprint (To_String (Prints)));

      --  Sorted by kind and key, so what two orders of the same
      --  declarations compose to is one thing. A list keeps its values in
      --  the order they were composed, and a set is sorted by value.
      declare
         function Before (Left, Right : Setting) return Boolean
         is (if Left.Kind /= Right.Kind then Left.Kind < Right.Kind
             elsif Left.Key /= Right.Key then Left.Key < Right.Key
             elsif Left.Kind = Set_Setting then Left.Value < Right.Value
             else False);

         Sorted : Setting_Vectors.Vector;
      begin
         --  An insertion sort that keeps equal elements in order, which is
         --  what a list's values need; there are tens of them, not
         --  thousands.
         for Next of Result.Settings loop
            declare
               Place : Positive := Natural (Sorted.Length) + 1;
            begin
               while Place > 1 and then Before (Next, Sorted (Place - 1)) loop
                  Place := Place - 1;
               end loop;
               Sorted.Insert (Place, Next);
            end;
         end loop;
         Result.Settings := Sorted;
      end;
   end Compose;

   function Root (Value : Composition) return Template
   is (Value.Root);

   function Order (Value : Composition) return Name_Lists.Vector
   is (Value.Order);

   function Composition_Fingerprint (Value : Composition) return String
   is (To_String (Value.Fingerprint));

   function Input_Count (Value : Composition) return Natural
   is (Natural (Value.Inputs.Length));

   function Input_At
     (Value : Composition;
      Index : Positive) return Input_Declaration
   is (Value.Inputs (Index));

   function Setting_Count (Value : Composition) return Natural
   is (Natural (Value.Settings.Length));

   function Setting_At
     (Value : Composition;
      Index : Positive) return Setting
   is (Value.Settings (Index));

   function Rule_Count (Value : Composition) return Natural
   is (Natural (Value.Rules.Length));

   function Rule_At
     (Value : Composition;
      Index : Positive) return Discovery_Rule
   is (Value.Rules (Index));

end Model_Runner.Framework.Templates;
