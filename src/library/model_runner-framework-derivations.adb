with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Derivations is

   package E renames Model_Runner.Errors;

   Tab : constant Character := ASCII.HT;
   LF  : constant Character := ASCII.LF;

   --  How deep an explanation follows derivations into the ones they rest
   --  on, and how many differences it names at each.
   Explain_Depth : constant := 8;
   Explain_Width : constant := 12;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Six (Value : Natural) return String is
      Plain : constant String := Image (Value);
   begin
      return (if Plain'Length >= 6 then Plain else [1 .. 6 - Plain'Length => '0'] & Plain);
   end Six;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Coded (Text : String) return String is
      Result : Unbounded_String;
   begin
      for C of Text loop
         case C is
            when ASCII.HT => Append (Result, "%09");
            when ASCII.LF => Append (Result, "%0A");
            when ASCII.CR => Append (Result, "%0D");
            when '%'      => Append (Result, "%25");
            when others   => Append (Result, C);
         end case;
      end loop;
      return To_String (Result);
   end Coded;

   function Decoded (Text : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = '%' and then Index + 2 <= Text'Last then
            declare
               Code : constant String := Text (Index + 1 .. Index + 2);
            begin
               Append (Result, (if Code = "09" then [1 => ASCII.HT]
                                elsif Code = "0A" then [1 => ASCII.LF]
                                elsif Code = "0D" then [1 => ASCII.CR]
                                elsif Code = "25" then "%"
                                else Text (Index .. Index + 2)));
            end;
            Index := Index + 3;
         else
            Append (Result, Text (Index));
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Decoded;

   function Fields_Of (Line : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Line'First;
   begin
      for Index in Line'First .. Line'Last + 1 loop
         if Index > Line'Last or else Line (Index) = Tab then
            Result.Append (Decoded (Line (Start .. Index - 1)));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Fields_Of;

   function Class_Word (Class : Dependency_Class) return String
   is (Lower (Dependency_Class'Image (Class)));

   function State_Word (State : Presence) return String
   is (Lower (Presence'Image (State)));

   --  A dependency as one line: class, kind, state, position, name, print.
   function Line_Of (One : Dependency) return String
   is (Class_Word (One.Class) & Tab & Coded (To_String (One.Kind)) & Tab
       & State_Word (One.State) & Tab & Image (One.Position) & Tab
       & Coded (To_String (One.Name)) & Tab & Coded (To_String (One.Print)));

   --  The line read back; Valid false when it is not one.
   procedure From_Line (Line : String; One : out Dependency; Valid : out Boolean) is
      Parts : Name_Lists.Vector;
      Start : Natural := Line'First;
   begin
      One := (others => <>);
      Valid := False;
      for Index in Line'First .. Line'Last + 1 loop
         if Index > Line'Last or else Line (Index) = Tab then
            Parts.Append (Line (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      if Natural (Parts.Length) /= 6 then
         return;
      end if;
      for Class in Dependency_Class loop
         if Class_Word (Class) = Parts (1) then
            One.Class := Class;
            Valid := True;
         end if;
      end loop;
      if not Valid then
         return;
      end if;
      Valid := False;
      for State in Presence loop
         if State_Word (State) = Parts (3) then
            One.State := State;
            Valid := True;
         end if;
      end loop;
      declare
         Place : constant String := Parts (4);
      begin
         if not Valid or else Place = ""
           or else (for some C of Place => C not in '0' .. '9')
           or else Place'Length > 9
         then
            Valid := False;
            return;
         end if;
         One.Position := Natural'Value (Place);
      end;
      One.Kind := To_Unbounded_String (Decoded (Parts (2)));
      One.Name := To_Unbounded_String (Decoded (Parts (5)));
      One.Print := To_Unbounded_String (Decoded (Parts (6)));
   end From_Line;

   --  What a dependency is, without what it was: class, kind, name and
   --  place. Two dependencies of one identity are the same thing read twice.
   function Identity (One : Dependency) return String
   is (Class_Word (One.Class) & Tab & Coded (To_String (One.Kind)) & Tab
       & Image (One.Position) & Tab & Coded (To_String (One.Name)));

   function Said (One : Dependency) return String
   is ((if One.Class = Input then "" else Class_Word (One.Class) & " ")
       & To_String (One.Kind) & " " & To_String (One.Name)
       & (if One.Position > 0 then " #" & Image (One.Position) else ""));

   package Sorting is new Name_Lists.Generic_Sorting;

   --  The lines of a list of dependencies, sorted and each once.
   function Sorted_Lines (From : Dependency_Vectors.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Unique : Name_Lists.Vector;
   begin
      for One of From loop
         Result.Append (Line_Of (One));
      end loop;
      Sorting.Sort (Result);
      for Line of Result loop
         if Unique.Is_Empty or else Unique.Last_Element /= Line then
            Unique.Append (Line);
         end if;
      end loop;
      return Unique;
   end Sorted_Lines;

   function Canonical_Text
     (Kind, Algorithm, Version : String;
      Lines                    : Name_Lists.Vector) return String
   is
      Text : Unbounded_String :=
        To_Unbounded_String ("derivation 1" & LF & "kind " & Coded (Kind) & LF
                             & "algorithm " & Coded (Algorithm) & LF
                             & "version " & Coded (Version) & LF);
   begin
      for Line of Lines loop
         Append (Text, Line & LF);
      end loop;
      return To_String (Text);
   end Canonical_Text;

   function Key_From (Canonical_Form : String) return String
   is ("DRV-" & Ada.Characters.Handling.To_Upper (Fingerprint (Canonical_Form)));

   -------------
   -- Specify --
   -------------

   function Specify
     (Kind      : String;
      Algorithm : String;
      Version   : String;
      Subject   : String := "project") return Specification
   is (Kind      => To_Unbounded_String (Kind),
       Algorithm => To_Unbounded_String (Algorithm),
       Version   => To_Unbounded_String (Version),
       Subject   => To_Unbounded_String (Subject),
       Needs     => Dependency_Vectors.Empty_Vector,
       Confirms  => Dependency_Vectors.Empty_Vector);

   ------------
   -- Depend --
   ------------

   procedure Depend
     (Spec     : in out Specification;
      Class    : Dependency_Class;
      Kind     : String;
      Name     : String;
      Print    : String;
      State    : Presence := Present;
      Position : Natural := 0) is
   begin
      Spec.Needs.Append
        (Dependency'(Class    => Class,
                     Kind     => To_Unbounded_String (Kind),
                     Name     => To_Unbounded_String (Name),
                     --  Not there, it has no print to compare: absent is
                     --  absent whatever a caller passed with it.
                     Print    => (if State = Present then To_Unbounded_String (Print)
                                  else Null_Unbounded_String),
                     State    => State,
                     Position => Position));
   end Depend;

   -------------
   -- Confirm --
   -------------

   procedure Confirm
     (Spec  : in out Specification;
      Kind  : String;
      Name  : String;
      Print : String;
      State : Presence) is
   begin
      Spec.Confirms.Append
        (Dependency'(Class    => Input,
                     Kind     => To_Unbounded_String (Kind),
                     Name     => To_Unbounded_String (Name),
                     Print    => (if State = Present then To_Unbounded_String (Print)
                                  else Null_Unbounded_String),
                     State    => State,
                     Position => 0));
   end Confirm;

   function Readable (Spec : Specification) return Boolean
   is (for all One of Spec.Needs => One.State /= Unreadable);

   function Kind_Of (Spec : Specification) return String
   is (To_String (Spec.Kind));

   function Canonical (Spec : Specification) return String
   is (Canonical_Text (To_String (Spec.Kind), To_String (Spec.Algorithm),
                       To_String (Spec.Version), Sorted_Lines (Spec.Needs)));

   function Key_Of (Spec : Specification) return String
   is (Key_From (Canonical (Spec)));

   function Word (Standing : Currentness) return String
   is (Lower (Currentness'Image (Standing)));

   ---------------------------------------------------------------------------
   --  Records.
   ---------------------------------------------------------------------------

   --  The record saying which derivation of a kind and subject is the
   --  latest.
   function Head_Name (Kind, Subject : String) return String
   is ("head-" & Fingerprint (Kind & LF & Subject));

   function Record_Path (Item : Stores.Store; Name : String) return String
   is (Stores.Root (Item) & "/" & Directory_Name (Derivations_Area) & "/" & Name & ".rec");

   function Project_Path (Item : Stores.Store; Path : String) return String
   is (Ada.Directories.Containing_Directory (Stores.Root (Item)) & "/" & Path);

   --  The fields of a kept record whose names begin with a prefix, in
   --  order, read back as dependencies; Valid false when one will not.
   procedure Dependencies_Of
     (Value  : Records.Item;
      Prefix : String;
      Into   : out Dependency_Vectors.Vector;
      Valid  : out Boolean) is
   begin
      Into.Clear;
      Valid := True;
      for Index in 1 .. Records.Field_Count (Value) loop
         if Starts (Records.Field_Name (Value, Index), Prefix) then
            declare
               One  : Dependency;
               Read : Boolean;
            begin
               From_Line (Records.Get (Value, Records.Field_Name (Value, Index)), One, Read);
               if not Read then
                  Valid := False;
                  return;
               end if;
               Into.Append (One);
            end;
         end if;
      end loop;
   end Dependencies_Of;

   --  A kept derivation, read back as a description: its key checked
   --  against what it says, so that a record changed under its name is
   --  damaged rather than believed.
   procedure Read_Kept
     (Item   : Stores.Store;
      Key    : String;
      Value  : out Records.Item;
      Spec   : out Specification;
      Status : out E.Error_Info)
   is
      Valid : Boolean;
   begin
      Spec := Specify ("", "", "", "");
      Stores.Read (Item, Derivations_Area, Key, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Spec := Specify (Records.Get (Value, "kind"), Records.Get (Value, "algorithm"),
                       Records.Get (Value, "version"), Records.Get (Value, "subject"));
      Dependencies_Of (Value, "need.", Spec.Needs, Valid);
      if Valid then
         Dependencies_Of (Value, "confirm.", Spec.Confirms, Valid);
      end if;
      if not Valid then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "path", Directory_Name (Derivations_Area) & "/" & Key);
         E.Add_Text (Status, "detail", "a dependency it lists is not one");
      elsif Key_Of (Spec) /= Key then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "path", Directory_Name (Derivations_Area) & "/" & Key);
         E.Add_Text (Status, "detail", "what it says it was derived from makes " & Key_Of (Spec));
      end if;
   end Read_Kept;

   --  The latest derivation of a kind and subject, as its key; "" when
   --  none is kept or its pointer will not read.
   function Latest (Item : Stores.Store; Kind, Subject : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      if not Stores.Exists (Item, Derivations_Area, Head_Name (Kind, Subject)) then
         return "";
      end if;
      Stores.Read (Item, Derivations_Area, Head_Name (Kind, Subject), Value, Status);
      return (if E.Is_Ok (Status) then Records.Get (Value, "key") else "");
   end Latest;

   --  How a confirmation stands now.
   function Probe (Item : Stores.Store; One : Dependency) return Dependency is
      Now : Dependency := One;
   begin
      Now.Print := Null_Unbounded_String;
      if To_String (One.Kind) = "presence" then
         begin
            Now.State :=
              (if Ada.Directories.Exists (Project_Path (Item, To_String (One.Name)))
               then Present else Absent);
         exception
            when others =>
               Now.State := Unreadable;
         end;
      elsif To_String (One.Kind) = "file" then
         declare
            Print  : Unbounded_String;
            Status : E.Error_Info;
            Path   : constant String := Project_Path (Item, To_String (One.Name));
         begin
            if not Ada.Directories.Exists (Path) then
               Now.State := Absent;
            else
               Files.Print_Of (Path, Print, Status);
               if E.Is_Ok (Status) then
                  Now.State := Present;
                  Now.Print := Print;
               else
                  Now.State := Unreadable;
               end if;
            end if;
         exception
            when others =>
               Now.State := Unreadable;
         end;
      else
         --  A kind nobody knows how to look at is not known to hold.
         Now.State := Unreadable;
      end if;
      return Now;
   end Probe;

   --  What changed from one list of dependencies to another, a line each,
   --  and the derived ones among them as the keys they were and became.
   procedure Differences
     (Before, After : Dependency_Vectors.Vector;
      Lines         : out Name_Lists.Vector;
      Classes       : out Name_Lists.Vector;
      Derived_Pairs : out Name_Lists.Vector)
   is
      package Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, Dependency);
      Old_Map : Maps.Map;
      New_Map : Maps.Map;

      procedure Say (One : Dependency; Text : String) is
      begin
         Lines.Append (Text);
         Classes.Append (Class_Word (One.Class));
      end Say;
   begin
      Lines.Clear;
      Classes.Clear;
      Derived_Pairs.Clear;
      for One of Before loop
         Old_Map.Include (Identity (One), One);
      end loop;
      for One of After loop
         New_Map.Include (Identity (One), One);
      end loop;
      for Cursor in New_Map.Iterate loop
         declare
            Now : constant Dependency := Maps.Element (Cursor);
            Was : constant Maps.Cursor := Old_Map.Find (Maps.Key (Cursor));
         begin
            if not Maps.Has_Element (Was) then
               Say (Now, Said (Now) & " is new");
            else
               declare
                  Then_One : constant Dependency := Maps.Element (Was);
               begin
                  if Then_One.State /= Now.State then
                     Say (Now, Said (Now) & " was " & State_Word (Then_One.State)
                          & " and is " & State_Word (Now.State));
                  elsif Then_One.Print /= Now.Print then
                     if To_String (Now.Kind) = Derived_Kind then
                        Say (Now, Said (Now) & " changed from " & To_String (Then_One.Print)
                             & " to " & To_String (Now.Print));
                        Derived_Pairs.Append (To_String (Then_One.Print) & " " & To_String (Now.Print));
                     else
                        Say (Now, Said (Now) & " changed");
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
      for Cursor in Old_Map.Iterate loop
         if not New_Map.Contains (Maps.Key (Cursor)) then
            Say (Maps.Element (Cursor), Said (Maps.Element (Cursor)) & " is gone");
         end if;
      end loop;
   end Differences;

   ------------------
   -- Find_Current --
   ------------------

   function Find_Current (Item : Stores.Store; Spec : Specification) return Finding is
      Result : Finding;
   begin
      Result.Key := To_Unbounded_String (Key_Of (Spec));

      --  An input that could not be read is not one that is absent: what
      --  rests on it cannot be said current, nor stale.
      for One of Spec.Needs loop
         if One.State = Unreadable then
            Result.Standing := Input_Unavailable;
            Result.Causes.Append (Said (One) & " could not be read");
         end if;
      end loop;
      if Result.Standing = Input_Unavailable then
         return Result;
      end if;

      if Stores.Exists (Item, Derivations_Area, To_String (Result.Key)) then
         declare
            Value  : Records.Item;
            Kept   : Specification;
            Status : E.Error_Info;
         begin
            Read_Kept (Item, To_String (Result.Key), Value, Kept, Status);
            if E.Is_Error (Status) then
               Result.Standing := Corrupt;
               Result.Causes.Append
                 (To_String (Result.Key) & " would not read: " & E.Text_Of (Status, "detail"));
               return Result;
            end if;

            --  What it found as it was made, as it is now.
            for One of Kept.Confirms loop
               declare
                  Now : constant Dependency := Probe (Item, One);
               begin
                  if Now.State = Unreadable then
                     Result.Standing := Input_Unavailable;
                     Result.Causes.Append (Said (One) & " could not be looked at");
                  elsif Now.State /= One.State or else Now.Print /= One.Print then
                     if Result.Standing /= Input_Unavailable then
                        Result.Standing := Stale_Input;
                     end if;
                     Result.Causes.Append
                       (Said (One)
                        & (if Now.State /= One.State
                           then " was " & State_Word (One.State) & " and is " & State_Word (Now.State)
                           else " changed"));
                  end if;
               end;
            end loop;
            if not Result.Causes.Is_Empty then
               Result.Prior := Result.Key;
               return Result;
            end if;

            declare
               Answer_Id : constant String := Records.Get (Value, "result");
               Held      : Results.Result;
            begin
               Results.Read (Item, Answer_Id, Held, Status, With_Payload => False);
               if E.Is_Error (Status) and then E."=" (Status.Code, E.Framework_Not_Found) then
                  Result.Standing := Missing;
                  Result.Causes.Append ("its answer " & Answer_Id & " is gone");
               elsif E.Is_Error (Status) then
                  Result.Standing := Corrupt;
                  Result.Causes.Append ("its answer " & Answer_Id & " would not read");
               elsif To_String (Held.Retired) /= "" then
                  Result.Standing := Missing;
                  Result.Causes.Append ("its answer " & Answer_Id & " was let go");
               else
                  Result.Standing := Current;
                  Result.Result := To_Unbounded_String (Answer_Id);
               end if;
            end;
         end;
         return Result;
      end if;

      --  None of this key: what is new, against the last of its kind.
      declare
         Prior : constant String := Latest (Item, To_String (Spec.Kind), To_String (Spec.Subject));
         Value  : Records.Item;
         Kept   : Specification;
         Status : E.Error_Info;
      begin
         Result.Standing := Missing;
         if Prior = "" then
            return Result;
         end if;
         Read_Kept (Item, Prior, Value, Kept, Status);
         if E.Is_Error (Status) then
            Result.Causes.Append ("the last of its kind, " & Prior & ", would not read");
            return Result;
         end if;
         Result.Prior := To_Unbounded_String (Prior);
         declare
            Lines, Classes, Pairs : Name_Lists.Vector;
         begin
            if Kept.Algorithm /= Spec.Algorithm or else Kept.Version /= Spec.Version then
               Result.Standing := Stale_Algorithm;
               Result.Causes.Append
                 ("its algorithm was " & To_String (Kept.Algorithm) & "/" & To_String (Kept.Version)
                  & " and is " & To_String (Spec.Algorithm) & "/" & To_String (Spec.Version));
            end if;
            Differences (Kept.Needs, Spec.Needs, Lines, Classes, Pairs);
            for Index in 1 .. Natural (Lines.Length) loop
               Result.Causes.Append (Lines (Index));
               if Result.Standing = Missing
                 or else (Result.Standing in Stale_Input | Stale_Environment
                          and then Classes (Index) = "policy")
                 or else (Result.Standing = Stale_Input and then Classes (Index) = "environment")
               then
                  Result.Standing :=
                    (if Classes (Index) = "policy" then Stale_Policy
                     elsif Classes (Index) = "environment" then Stale_Environment
                     else Stale_Input);
               end if;
            end loop;
         end;
      end;
      return Result;
   end Find_Current;

   -------------
   -- Explain --
   -------------

   function Explain (Item : Stores.Store; Key : String) return Name_Lists.Vector is
      Lines   : Name_Lists.Vector;
      Visited : Name_Lists.Vector;

      function Pad (Depth : Natural) return String
      is ([1 .. 2 * Depth => ' ']);

      --  What changed from one derivation to its successor, followed into
      --  what each rests on.
      procedure Changes (Before, After : String; Depth : Natural) is
         Old_Value, New_Value : Records.Item;
         Old_Spec, New_Spec   : Specification;
         Old_Read, New_Read   : E.Error_Info;
         Diff, Classes, Pairs : Name_Lists.Vector;
      begin
         if Depth > Explain_Depth then
            Lines.Append (Pad (Depth) & "... deeper than" & Natural'Image (Explain_Depth)
                          & " derivations, not followed");
            return;
         elsif Visited.Contains (Before & " " & After) then
            Lines.Append (Pad (Depth) & Before & " to " & After & " again: the chain loops, cut here");
            return;
         end if;
         Visited.Append (Before & " " & After);
         Read_Kept (Item, Before, Old_Value, Old_Spec, Old_Read);
         Read_Kept (Item, After, New_Value, New_Spec, New_Read);
         if E.Is_Error (Old_Read) or else E.Is_Error (New_Read) then
            Lines.Append (Pad (Depth) & "what changed is not known: "
                          & (if E.Is_Error (Old_Read) then Before else After)
                          & (if Stores.Exists (Item, Derivations_Area,
                                               (if E.Is_Error (Old_Read) then Before else After))
                             then " would not read" else " is not kept"));
            return;
         end if;
         if Old_Spec.Algorithm /= New_Spec.Algorithm or else Old_Spec.Version /= New_Spec.Version then
            Lines.Append (Pad (Depth) & "its algorithm " & To_String (Old_Spec.Algorithm) & "/"
                          & To_String (Old_Spec.Version) & " became "
                          & To_String (New_Spec.Algorithm) & "/" & To_String (New_Spec.Version));
         end if;
         Differences (Old_Spec.Needs, New_Spec.Needs, Diff, Classes, Pairs);
         for Index in 1 .. Natural (Diff.Length) loop
            exit when Index > Explain_Width;
            Lines.Append (Pad (Depth) & Diff (Index));
         end loop;
         if Natural (Diff.Length) > Explain_Width then
            Lines.Append (Pad (Depth) & "... and" & Natural'Image (Natural (Diff.Length) - Explain_Width)
                          & " more");
         end if;
         for Pair of Pairs loop
            declare
               Space : constant Natural := Ada.Strings.Fixed.Index (Pair, " ");
            begin
               Lines.Append (Pad (Depth) & Pair (Pair'First .. Space - 1) & " became "
                             & Pair (Space + 1 .. Pair'Last) & " because");
               Changes (Pair (Pair'First .. Space - 1), Pair (Space + 1 .. Pair'Last), Depth + 1);
            end;
         end loop;
      end Changes;

      --  A derivation, what it rests on, and whether it is the latest.
      procedure Visit (Name : String; Depth : Natural) is
         Value  : Records.Item;
         Spec   : Specification;
         Status : E.Error_Info;
      begin
         if Depth > Explain_Depth then
            Lines.Append (Pad (Depth) & "... deeper than" & Natural'Image (Explain_Depth)
                          & " derivations, not followed");
            return;
         elsif Visited.Contains (Name) then
            Lines.Append (Pad (Depth) & Name & " again: the chain loops, cut here");
            return;
         end if;
         Visited.Append (Name);
         if not Stores.Exists (Item, Derivations_Area, Name) then
            Lines.Append (Pad (Depth) & Name & " is not kept");
            return;
         end if;
         Read_Kept (Item, Name, Value, Spec, Status);
         if E.Is_Error (Status) then
            Lines.Append (Pad (Depth) & Name & " would not read: " & E.Text_Of (Status, "detail"));
            return;
         end if;
         Lines.Append (Pad (Depth) & Name & ": " & To_String (Spec.Kind) & " of "
                       & To_String (Spec.Subject) & " by " & To_String (Spec.Algorithm) & "/"
                       & To_String (Spec.Version) & ", made " & Records.Get (Value, "created_at")
                       & ", answer " & Records.Get (Value, "result"));
         declare
            Head : constant String := Latest (Item, To_String (Spec.Kind), To_String (Spec.Subject));
         begin
            if Head = Name then
               Lines.Append (Pad (Depth + 1) & "the latest of its kind");
            elsif Head /= "" then
               Lines.Append (Pad (Depth + 1) & "stale: " & Head & " is the latest, made since because");
               Changes (Name, Head, Depth + 2);
            end if;
         end;
         declare
            Inputs   : Natural := 0;
            Policies : Natural := 0;
         begin
            for One of Spec.Needs loop
               if To_String (One.Kind) = Derived_Kind then
                  Lines.Append (Pad (Depth + 1) & "rests on " & To_String (One.Name) & " "
                                & To_String (One.Print));
                  Visit (To_String (One.Print), Depth + 2);
               elsif One.Class = Input then
                  Inputs := Inputs + 1;
               else
                  Policies := Policies + 1;
               end if;
            end loop;
            Lines.Append (Pad (Depth + 1) & "made from" & Natural'Image (Inputs) & " inputs and"
                          & Natural'Image (Policies) & " policy and environment values");
         end;
      end Visit;
   begin
      Visit (Key, 0);
      return Lines;
   end Explain;

   ---------------------------------------------------------------------------
   --  Keeping.
   ---------------------------------------------------------------------------

   procedure Add
     (Into    : in out Staged;
      Spec    : Specification;
      Payload : String;
      Summary : String) is
   begin
      Into.Items.Append
        (Staged_One'(Spec    => Spec,
                     Payload => To_Unbounded_String (Payload),
                     Summary => To_Unbounded_String (Summary)));
   end Add;

   procedure Add (Into : in out Staged; From : Staged) is
   begin
      Into.Items.Append (From.Items);
   end Add;

   function Length (From : Staged) return Natural
   is (Natural (From.Items.Length));

   --  The revision to write a derived record at: one past what the
   --  transaction or the area holds, a damaged one discarded first -- a
   --  cache that will not read is thrown away, not left to refuse every
   --  change that touches it.
   function Next_Revision
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Name   : String) return Positive
   is
      Held   : Records.Item;
      Found  : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Derivations_Area, Name, Held, Found);
      if Found then
         return Records.Revision (Held) + 1;
      elsif not Stores.Exists (Item, Derivations_Area, Name) then
         return 1;
      end if;
      Stores.Read (Item, Derivations_Area, Name, Held, Status);
      if E.Is_Ok (Status) then
         return Records.Revision (Held) + 1;
      end if;
      Files.Discard (Record_Path (Item, Name));
      return 1;
   end Next_Revision;

   procedure Keep
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Spec    : Specification;
      Payload : String;
      Summary : String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Key    : constant String := Key_Of (Spec);
      Answer : Results.Result :=
        (Kind       => Results.Derived_Artifact,
         Producer   => To_Unbounded_String (To_String (Spec.Algorithm) & "/" & To_String (Spec.Version)),
         Summary    => To_Unbounded_String (Summary),
         Payload    => To_Unbounded_String (Payload),
         --  The kind, not the key: one answer two derivations came to is
         --  kept once, and named by both.
         Provenance => To_Unbounded_String ("derivation " & To_String (Spec.Kind)),
         others     => <>);
      Held   : Records.Item;
      Found  : Boolean;
      Read   : E.Error_Info;
   begin
      Results.Add (Item, Change, Answer, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  Its record, unless the same is kept or staged: same key, same
      --  confirmations, same answer.
      Stores.Pending (Change, Derivations_Area, Key, Held, Found);
      if not Found and then Stores.Exists (Item, Derivations_Area, Key) then
         Stores.Read (Item, Derivations_Area, Key, Held, Read);
         Found := E.Is_Ok (Read);
      end if;
      declare
         Value : Records.Item :=
           Records.Create (Schemas.Derivation_Schema, 1, Key, 1);
         Lines : constant Name_Lists.Vector := Sorted_Lines (Spec.Needs);
         Confirms : constant Name_Lists.Vector := Sorted_Lines (Spec.Confirms);
         Same  : Boolean := Found and then Records.Get (Held, "result") = To_String (Answer.Id);
      begin
         Records.Set (Value, "kind", To_String (Spec.Kind));
         Records.Set (Value, "subject", To_String (Spec.Subject));
         Records.Set (Value, "algorithm", To_String (Spec.Algorithm));
         Records.Set (Value, "version", To_String (Spec.Version));
         Records.Set (Value, "created_at", Timestamp);
         Records.Set (Value, "result", To_String (Answer.Id));
         for Index in 1 .. Natural (Lines.Length) loop
            Records.Set (Value, "need." & Six (Index), Lines (Index));
         end loop;
         for Index in 1 .. Natural (Confirms.Length) loop
            Records.Set (Value, "confirm." & Six (Index), Confirms (Index));
            Same := Same and then Records.Get (Held, "confirm." & Six (Index)) = Confirms (Index);
         end loop;
         Same := Same and then not Records.Has (Held, "confirm." & Six (Natural (Confirms.Length) + 1));
         if not Same then
            Records.Set_Revision (Value, Next_Revision (Item, Change, Key));
            Stores.Put (Change, Derivations_Area, Key, Value);
         end if;
      end;

      --  And the latest of its kind and subject.
      declare
         Name  : constant String := Head_Name (To_String (Spec.Kind), To_String (Spec.Subject));
         Head  : Records.Item;
         Kept  : Boolean;
      begin
         Stores.Pending (Change, Derivations_Area, Name, Head, Kept);
         if not Kept and then Stores.Exists (Item, Derivations_Area, Name) then
            Stores.Read (Item, Derivations_Area, Name, Head, Read);
            Kept := E.Is_Ok (Read);
         end if;
         if not Kept or else Records.Get (Head, "key") /= Key then
            declare
               Value : Records.Item :=
                 Records.Create (Schemas.Derivation_Head_Schema, 1,
                                 "DRVHEAD-" & Ada.Characters.Handling.To_Upper
                                   (Fingerprint (To_String (Spec.Kind) & LF & To_String (Spec.Subject))),
                                 Next_Revision (Item, Change, Name));
            begin
               Records.Set (Value, "kind", To_String (Spec.Kind));
               Records.Set (Value, "subject", To_String (Spec.Subject));
               Records.Set (Value, "key", Key);
               Stores.Put (Change, Derivations_Area, Name, Value);
            end;
         end if;
      end;
   end Keep;

   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      From   : Staged;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Status := E.Success;
      for One of From.Items loop
         Keep (Item, Change, One.Spec, To_String (One.Payload), To_String (One.Summary), Status);
         exit when E.Is_Error (Status);
      end loop;
   end Keep;

   ------------
   -- Answer --
   ------------

   procedure Answer
     (Item    : Stores.Store;
      Found   : Finding;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Held : Results.Result;
   begin
      Payload := Null_Unbounded_String;
      if Found.Standing /= Current then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", To_String (Found.Key));
         return;
      end if;
      Results.Read (Item, To_String (Found.Result), Held, Status);
      if E.Is_Ok (Status) then
         Payload := Held.Payload;
      end if;
   end Answer;

   ---------------------------------------------------------------------------
   --  What this process holds.
   ---------------------------------------------------------------------------

   Held_Most : constant := 16;

   type Held_One is record
      Key     : Unbounded_String;
      Spec    : Specification;
      Payload : Unbounded_String;
   end record;

   package Held_Vectors is new Ada.Containers.Vectors (Positive, Held_One);

   type Tally is record
      Computed : Natural := 0;
      Reused   : Natural := 0;
   end record;

   package Tally_Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, Tally);

   protected Memory is
      procedure Put (One : Held_One);
      procedure Get (Key : String; One : out Held_One; Found : out Boolean);
      procedure Clear;
      procedure Note (Kind : String; Again : Boolean);
      function Counted (Kind : String; Again : Boolean) return Natural;
   private
      Items   : Held_Vectors.Vector;
      Tallies : Tally_Maps.Map;
   end Memory;

   protected body Memory is
      procedure Put (One : Held_One) is
      begin
         for Index in 1 .. Natural (Items.Length) loop
            if Items (Index).Key = One.Key then
               Items.Delete (Index);
               exit;
            end if;
         end loop;
         Items.Append (One);
         if Natural (Items.Length) > Held_Most then
            Items.Delete_First;
         end if;
      end Put;

      procedure Get (Key : String; One : out Held_One; Found : out Boolean) is
      begin
         for Held of Items loop
            if To_String (Held.Key) = Key then
               One := Held;
               Found := True;
               return;
            end if;
         end loop;
         One := (Key => Null_Unbounded_String, Payload => Null_Unbounded_String,
                 Spec => Specify ("", "", "", ""));
         Found := False;
      end Get;

      procedure Clear is
      begin
         Items.Clear;
         Tallies.Clear;
      end Clear;

      procedure Note (Kind : String; Again : Boolean) is
         Now : Tally := (if Tallies.Contains (Kind) then Tallies (Kind) else (others => <>));
      begin
         if Again then
            Now.Reused := Now.Reused + 1;
         else
            Now.Computed := Now.Computed + 1;
         end if;
         Tallies.Include (Kind, Now);
      end Note;

      function Counted (Kind : String; Again : Boolean) return Natural is
      begin
         if not Tallies.Contains (Kind) then
            return 0;
         end if;
         return (if Again then Tallies (Kind).Reused else Tallies (Kind).Computed);
      end Counted;
   end Memory;

   procedure Remember (Spec : Specification; Payload : String) is
   begin
      Memory.Put (Held_One'(Key     => To_Unbounded_String (Key_Of (Spec)),
                            Spec    => Spec,
                            Payload => To_Unbounded_String (Payload)));
   end Remember;

   procedure Recall
     (Item    : Stores.Store;
      Spec    : Specification;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Found   : out Boolean)
   is
      One : Held_One;
   begin
      Payload := Null_Unbounded_String;
      Memory.Get (Key_Of (Spec), One, Found);
      if not Found then
         return;
      end if;
      for Confirmed of One.Spec.Confirms loop
         declare
            Now : constant Dependency := Probe (Item, Confirmed);
         begin
            if Now.State /= Confirmed.State or else Now.Print /= Confirmed.Print then
               Found := False;
               return;
            end if;
         end;
      end loop;
      Payload := One.Payload;
   end Recall;

   procedure Forget is
   begin
      Memory.Clear;
   end Forget;

   function Computed (Kind : String) return Natural
   is (Memory.Counted (Kind, Again => False));

   function Reused (Kind : String) return Natural
   is (Memory.Counted (Kind, Again => True));

   procedure Count (Kind : String; Again : Boolean) is
   begin
      Memory.Note (Kind, Again);
   end Count;

   ----------
   -- Kept --
   ----------

   function Kept (Item : Stores.Store) return Name_Lists.Vector is
      Lines : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Derivations_Area) loop
         if not Starts (Name, "head-") then
            declare
               Value  : Records.Item;
               Spec   : Specification;
               Status : E.Error_Info;
            begin
               Read_Kept (Item, Name, Value, Spec, Status);
               if E.Is_Error (Status) then
                  Lines.Append (Name & Tab & "-" & Tab & "-" & Tab & "-" & Tab & "-" & Tab & "-" & Tab
                                & "damaged");
               else
                  Lines.Append
                    (Name & Tab & To_String (Spec.Kind) & Tab & To_String (Spec.Subject) & Tab
                     & To_String (Spec.Algorithm) & "/" & To_String (Spec.Version) & Tab
                     & Records.Get (Value, "created_at") & Tab & Records.Get (Value, "result") & Tab
                     & (if Latest (Item, To_String (Spec.Kind), To_String (Spec.Subject)) = Name
                        then "latest" else "earlier"));
               end if;
            end;
         end if;
      end loop;
      return Lines;
   end Kept;

   -----------
   -- Prune --
   -----------

   procedure Prune
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Days    : Natural;
      Removed : out Natural)
   is
      use type Ada.Calendar.Time;
      Named    : Name_Lists.Vector;
      Gone     : Name_Lists.Vector;
      Unread   : Boolean := False;
      Cut      : Unbounded_String;
   begin
      Removed := 0;
      if Days = 0 then
         return;
      end if;
      declare
         Text : String := Ada.Calendar.Formatting.Image (Ada.Calendar.Clock - Duration (Days) * 86_400.0);
      begin
         Text (Text'First + 10) := 'T';
         Cut := To_Unbounded_String (Text & "Z");
      end;

      for Name of Stores.Names (Item, Derivations_Area) loop
         if not Starts (Name, "head-") then
            declare
               Value  : Records.Item;
               Status : E.Error_Info;
            begin
               Stores.Read (Item, Derivations_Area, Name, Value, Status);
               if E.Is_Error (Status) then
                  Unread := True;
               elsif Records.Get (Value, "created_at") < To_String (Cut) then
                  Stores.Remove (Change, Derivations_Area, Name, Records.Revision (Value));
                  Gone.Append (Name);
                  Removed := Removed + 1;
               else
                  Named.Append (Records.Get (Value, "result"));
               end if;
            end;
         end if;
      end loop;

      --  A pointer to one gone goes with it.
      for Name of Stores.Names (Item, Derivations_Area) loop
         if Starts (Name, "head-") then
            declare
               Value  : Records.Item;
               Status : E.Error_Info;
            begin
               Stores.Read (Item, Derivations_Area, Name, Value, Status);
               if E.Is_Ok (Status) and then Gone.Contains (Records.Get (Value, "key")) then
                  Stores.Remove (Change, Derivations_Area, Name, Records.Revision (Value));
                  Removed := Removed + 1;
               end if;
            end;
         end if;
      end loop;

      --  Answers nothing kept names; none while a derivation will not read,
      --  since it may name any of them.
      if Unread then
         return;
      end if;
      for Id of Stores.Names (Item, Results_Area) loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Results_Area, Id, Value, Status);
            if E.Is_Ok (Status)
              and then Records.Get (Value, "result_type") = Results.Kind_Word (Results.Derived_Artifact)
              and then not Named.Contains (Id)
            then
               Stores.Remove (Change, Results_Area, Id, Records.Revision (Value));
               Removed := Removed + 1;
            end if;
         end;
      end loop;
   end Prune;

end Model_Runner.Framework.Derivations;
