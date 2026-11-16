with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Templates;
with Model_Runner.UTF8;

package body Model_Runner.Code_Health.Diagnostics is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package R renames Model_Runner.Framework.Records;

   Maximum_Field_Bytes : constant := 64 * 1024;
   Maximum_Provenance  : constant := 1_000;

   function Redacted (Text : String) return String is
      Lower  : constant String := Ada.Characters.Handling.To_Lower (Text);
      Result : Unbounded_String;
      Position : Natural := Text'First;

      function Boundary (Position : Natural) return Boolean is
        (Position = Text'First
         or else Lower (Position - 1) not in 'a' .. 'z' | '0' .. '9' | '_');

      function Secret_Key_At (Position : Natural) return Natural is
      begin
         if not Boundary (Position) then
            return 0;
         end if;
         for Key of String_Lists.Vector'
           (["password", "passwd", "secret", "token", "api_key", "apikey",
             "authorization", "access_key"])
         loop
            if Position + Key'Length - 1 <= Text'Last
              and then Lower (Position .. Position + Key'Length - 1) = Key
            then
               return Key'Length;
            end if;
         end loop;
         return 0;
      end Secret_Key_At;
   begin
      while Position <= Text'Last loop
         declare
            Key_Length : constant Natural := Secret_Key_At (Position);
            Separator  : Natural := Position + Key_Length;
         begin
            if Key_Length > 0 then
               while Separator <= Text'Last and then Text (Separator) in ' ' | ASCII.HT loop
                  Separator := Separator + 1;
               end loop;
            end if;
            if Key_Length > 0 and then Separator <= Text'Last and then Text (Separator) in '=' | ':' then
               Append (Result, Text (Position .. Separator));
               Separator := Separator + 1;
               while Separator <= Text'Last and then Text (Separator) in ' ' | ASCII.HT loop
                  Append (Result, Text (Separator));
                  Separator := Separator + 1;
               end loop;
               if Separator <= Text'Last and then Text (Separator) in ''' | '"' then
                  declare
                     Quote : constant Character := Text (Separator);
                  begin
                     Append (Result, Quote);
                     Separator := Separator + 1;
                     while Separator <= Text'Last and then Text (Separator) /= Quote loop
                        Separator := Separator + 1;
                     end loop;
                     Append (Result, "[REDACTED]");
                     if Separator <= Text'Last then
                        Append (Result, Quote);
                        Separator := Separator + 1;
                     end if;
                  end;
               else
                  while Separator <= Text'Last
                    and then Text (Separator) not in ' ' | ASCII.HT | ASCII.LF | ASCII.CR | ',' | ';' | '}' | ']'
                  loop
                     Separator := Separator + 1;
                  end loop;
                  Append (Result, "[REDACTED]");
               end if;
               Position := Separator;
            else
               Append (Result, Text (Position));
               Position := Position + 1;
            end if;
         end;
      end loop;
      return To_String (Result);
   end Redacted;

   function Normal_Identity (Text : String) return String is
      Result : Unbounded_String;
      Space  : Boolean := True;
   begin
      for Letter of Text loop
         if Letter in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
            if not Space then
               Append (Result, ' ');
               Space := True;
            end if;
         else
            Append (Result, Ada.Characters.Handling.To_Lower (Letter));
            Space := False;
         end if;
      end loop;
      return Ada.Strings.Fixed.Trim (To_String (Result), Ada.Strings.Both);
   end Normal_Identity;

   function Fingerprint_Of (Item : Diagnostic) return String is
      Meaning : R.Item := R.Create ("code_health.diagnostic", 1, "DIAGNOSTIC", 1);
   begin
      R.Set (Meaning, "provider", To_String (Item.Provider));
      R.Set (Meaning, "rule", To_String (Item.Rule_Id));
      R.Set (Meaning, "path", To_String (Item.Path));
      R.Set (Meaning, "symbol", Normal_Identity (To_String (Item.Symbol)));
      R.Set (Meaning, "native_code", To_String (Item.Native_Code));
      R.Set (Meaning, "identity", Normal_Identity (To_String (Item.Message)));
      return R.Fingerprint_Of (Meaning);
   end Fingerprint_Of;

   procedure Refuse
     (Status : out E.Error_Info;
      Name   : String;
      Detail : String) is
   begin
      Status := E.Make (E.Framework_Schema_Violation);
      E.Add_Text (Status, "name", Name);
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   procedure Prepare
     (Item         : in out Diagnostic;
      Status       : out E.Error_Info;
      Project_Root : String := "")
   is
      Texts : constant array (Positive range 1 .. 11) of Unbounded_String :=
        [Item.Provider, Item.Check_Id, Item.Rule_Id, Item.Path, Item.Symbol, Item.Message,
         Item.Explanation, Item.Remediation, Item.Native_Code, Item.Snapshot, Item.Evidence_Id];

      function Name_Of (Index : Positive) return String is
        (case Index is
            when 1 => "provider", when 2 => "check", when 3 => "rule", when 4 => "path",
            when 5 => "symbol", when 6 => "message", when 7 => "explanation",
            when 8 => "remediation", when 9 => "native_code", when 10 => "snapshot",
            when others => "evidence");
   begin
      if Length (Item.Provider) = 0 then
         Refuse (Status, "provider", "diagnostic provider is missing");
         return;
      elsif Length (Item.Rule_Id) = 0 then
         Refuse (Status, "rule", "diagnostic rule is missing");
         return;
      elsif Length (Item.Message) = 0 then
         Refuse (Status, "message", "diagnostic message is missing");
         return;
      elsif Length (Item.Snapshot) = 0 then
         Refuse (Status, "snapshot", "diagnostic snapshot is missing");
         return;
      end if;

      for Index in Texts'Range loop
         if Length (Texts (Index)) > Maximum_Field_Bytes then
            Refuse (Status, Name_Of (Index), "diagnostic field exceeds the storage limit");
            return;
         elsif not Model_Runner.UTF8.Is_Valid (To_String (Texts (Index))) then
            Status := E.Make (E.IO_Invalid_UTF8);
            E.Add_Text (Status, "path", Name_Of (Index));
            return;
         end if;
      end loop;
      if Natural (Item.Related.Length) > Maximum_Provenance
        or else Natural (Item.Provenance.Length) > Maximum_Provenance
      then
         Refuse (Status, "diagnostic", "diagnostic provenance exceeds the retained item limit");
         return;
      end if;
      for Place of Item.Related loop
         if Length (Place.Path) > Maximum_Field_Bytes
           or else not Model_Runner.UTF8.Is_Valid (To_String (Place.Path))
         then
            Status := E.Make (E.IO_Invalid_UTF8);
            E.Add_Text (Status, "path", "related location");
            return;
         end if;
      end loop;
      for Source of Item.Provenance loop
         if Source'Length > Maximum_Field_Bytes or else not Model_Runner.UTF8.Is_Valid (Source) then
            Refuse (Status, "provenance", "diagnostic provenance is invalid or too large");
            return;
         end if;
      end loop;

      declare
         Path : constant String := To_String (Item.Path);
         Normalized : constant String :=
           (if Path = "" then ""
            elsif Project_Root /= ""
            then Model_Runner.Framework.Repository.Relative_Path (Project_Root, Path)
            else Model_Runner.Framework.Permissions.Normal (Path));
      begin
         if Normalized /= ""
           and then not Model_Runner.Framework.Templates.Is_Project_Path (Normalized)
         then
            Refuse (Status, "path", "diagnostic location is outside the project");
            return;
         end if;
         Item.Path := To_Unbounded_String (Normalized);
      end;
      for Index in 1 .. Natural (Item.Related.Length) loop
         declare
            Place      : Source_Location := Item.Related.Element (Index);
            Path       : constant String := To_String (Place.Path);
            Normalized : constant String :=
              (if Project_Root /= ""
               then Model_Runner.Framework.Repository.Relative_Path (Project_Root, Path)
               else Model_Runner.Framework.Permissions.Normal (Path));
         begin
            if not Model_Runner.Framework.Templates.Is_Project_Path (Normalized) then
               Refuse (Status, "related path", "related diagnostic location is outside the project");
               return;
            end if;
            Place.Path := To_Unbounded_String (Normalized);
            Item.Related.Replace_Element (Index, Place);
         end;
      end loop;
      Item.Symbol := To_Unbounded_String (Redacted (To_String (Item.Symbol)));
      Item.Message := To_Unbounded_String (Redacted (To_String (Item.Message)));
      Item.Explanation := To_Unbounded_String (Redacted (To_String (Item.Explanation)));
      Item.Remediation := To_Unbounded_String (Redacted (To_String (Item.Remediation)));
      Item.Native_Code := To_Unbounded_String (Redacted (To_String (Item.Native_Code)));
      Item.Evidence_Id := To_Unbounded_String (Redacted (To_String (Item.Evidence_Id)));
      for Index in 1 .. Natural (Item.Provenance.Length) loop
         Item.Provenance.Replace_Element (Index, Redacted (Item.Provenance.Element (Index)));
      end loop;
      Item.Fingerprint := To_Unbounded_String (Fingerprint_Of (Item));
      if Item.Provenance.Is_Empty then
         Item.Provenance.Append
           (To_String (Item.Provider)
            & (if Length (Item.Native_Code) = 0 then "" else ":" & To_String (Item.Native_Code)));
      end if;
      Status := E.Success;
   end Prepare;

   procedure Append_Validated
     (To           : in out Diagnostic_List;
      Item         : Diagnostic;
      Status       : out E.Error_Info;
      Project_Root : String := "")
   is
      Checked : Diagnostic := Item;
   begin
      Prepare (Checked, Status, Project_Root);
      if E.Is_Ok (Status) then
         To.Items.Append (Checked);
      end if;
   end Append_Validated;

   function Length (From : Diagnostic_List) return Natural is
     (Natural (From.Items.Length));

   function Element
     (From  : Diagnostic_List;
      Index : Positive) return Diagnostic is
     (From.Items.Element (Index));

   function Blocks
     (Item      : Diagnostic;
      Threshold : Diagnostic_Severity) return Boolean is
     (Diagnostic_Severity'Pos (Item.Severity) >= Diagnostic_Severity'Pos (Threshold));

   function Count
     (From     : Diagnostic_List;
      Severity : Diagnostic_Severity) return Natural
   is
      Result : Natural := 0;
   begin
      for Item of From.Items loop
         if Item.Severity = Severity then
            Result := Result + 1;
         end if;
      end loop;
      return Result;
   end Count;

   function Less (Left, Right : Diagnostic) return Boolean is
   begin
      if Left.Severity /= Right.Severity then
         return Diagnostic_Severity'Pos (Left.Severity) > Diagnostic_Severity'Pos (Right.Severity);
      elsif To_String (Left.Path) /= To_String (Right.Path) then
         return To_String (Left.Path) < To_String (Right.Path);
      elsif To_String (Left.Rule_Id) /= To_String (Right.Rule_Id) then
         return To_String (Left.Rule_Id) < To_String (Right.Rule_Id);
      elsif Left.Line /= Right.Line then
         return Left.Line < Right.Line;
      elsif Left.Column /= Right.Column then
         return Left.Column < Right.Column;
      else
         return To_String (Left.Fingerprint) < To_String (Right.Fingerprint);
      end if;
   end Less;

   package Sorting is new Diagnostic_Vectors.Generic_Sorting (Less);

   procedure Sort (Item : in out Diagnostic_List) is
   begin
      Sorting.Sort (Item.Items);
   end Sort;

   function Equivalent (Left, Right : Diagnostic) return Boolean is
     (To_String (Left.Snapshot) = To_String (Right.Snapshot)
      and then To_String (Left.Path) = To_String (Right.Path)
      and then To_String (Left.Symbol) = To_String (Right.Symbol)
      and then Normal_Identity (To_String (Left.Message)) = Normal_Identity (To_String (Right.Message))
      and then ((Length (Left.Native_Code) > 0
                 and then To_String (Left.Native_Code) = To_String (Right.Native_Code))
                or else To_String (Left.Rule_Id) = To_String (Right.Rule_Id)));

   procedure Deduplicate (Item : in out Diagnostic_List) is
      Result : Diagnostic_Vectors.Vector;
   begin
      Sort (Item);
      for Candidate of Item.Items loop
         declare
            Found : Natural := 0;
         begin
            for Index in 1 .. Natural (Result.Length) loop
               if Equivalent (Result.Element (Index), Candidate) then
                  Found := Index;
                  exit;
               end if;
            end loop;
            if Found = 0 then
               Result.Append (Candidate);
            else
               declare
                  Kept : Diagnostic := Result.Element (Found);
               begin
                  if Diagnostic_Severity'Pos (Candidate.Severity) > Diagnostic_Severity'Pos (Kept.Severity) then
                     Kept.Severity := Candidate.Severity;
                  end if;
                  for Source of Candidate.Provenance loop
                     if not Kept.Provenance.Contains (Source) then
                        Kept.Provenance.Append (Source);
                     end if;
                  end loop;
                  Result.Replace_Element (Found, Kept);
               end;
            end if;
         end;
      end loop;
      Item.Items := Result;
      Sort (Item);
   end Deduplicate;

   function Image (Value : Natural) return String is
      Said : constant String := Natural'Image (Value);
   begin
      return Said (Said'First + 1 .. Said'Last);
   end Image;

   function Severity_Word (Value : Diagnostic_Severity) return String is
     (case Value is
         when Information => "information",
         when Warning     => "warning",
         when Error       => "error",
         when Critical    => "critical");

   function Serialize (Item : Diagnostic) return String is
      Value : R.Item := R.Create ("code_health.diagnostic", 1, "DIAGNOSTIC", 1);
   begin
      R.Set (Value, "provider", To_String (Item.Provider));
      R.Set (Value, "check", To_String (Item.Check_Id));
      R.Set (Value, "rule", To_String (Item.Rule_Id));
      R.Set (Value, "severity", Severity_Word (Item.Severity));
      R.Set (Value, "path", To_String (Item.Path));
      R.Set (Value, "line", Image (Item.Line));
      R.Set (Value, "column", Image (Item.Column));
      R.Set (Value, "symbol", To_String (Item.Symbol));
      R.Set (Value, "message", To_String (Item.Message));
      R.Set (Value, "explanation", To_String (Item.Explanation));
      R.Set (Value, "remediation", To_String (Item.Remediation));
      R.Set (Value, "fingerprint", To_String (Item.Fingerprint));
      R.Set (Value, "evidence", To_String (Item.Evidence_Id));
      R.Set (Value, "native_code", To_String (Item.Native_Code));
      R.Set (Value, "snapshot", To_String (Item.Snapshot));
      for Index in 1 .. Natural (Item.Related.Length) loop
         declare
            Place : constant Source_Location := Item.Related.Element (Index);
            Name  : constant String := R.Numbered (Index, Natural (Item.Related.Length));
         begin
            R.Set (Value, "related." & Name & ".path", To_String (Place.Path));
            R.Set (Value, "related." & Name & ".line", Image (Place.Line));
            R.Set (Value, "related." & Name & ".column", Image (Place.Column));
         end;
      end loop;
      for Index in 1 .. Natural (Item.Provenance.Length) loop
         R.Set
           (Value, "provenance." & R.Numbered (Index, Natural (Item.Provenance.Length)),
            Item.Provenance.Element (Index));
      end loop;
      return R.Serialize (Value);
   end Serialize;

   function Number (Text : String; Good : out Boolean) return Natural is
      Result : Natural := 0;
   begin
      Good := Text /= "";
      for Letter of Text loop
         if Letter not in '0' .. '9' or else Result > (Natural'Last - 9) / 10 then
            Good := False;
            return 0;
         end if;
         Result := Result * 10 + Character'Pos (Letter) - Character'Pos ('0');
      end loop;
      return Result;
   end Number;

   procedure Parse
     (Text   : String;
      Item   : out Diagnostic;
      Status : out E.Error_Info)
   is
      Value : R.Item;
      Good  : Boolean;
   begin
      Item := (others => <>);
      R.Parse (Text, "Code Health diagnostic evidence", Value, Status);
      if E.Is_Error (Status) then
         return;
      elsif R.Schema_Id (Value) /= "code_health.diagnostic" then
         Refuse (Status, "diagnostic", "evidence has the wrong embedded record type");
         return;
      end if;

      Item.Provider := To_Unbounded_String (R.Get (Value, "provider"));
      Item.Check_Id := To_Unbounded_String (R.Get (Value, "check"));
      Item.Rule_Id := To_Unbounded_String (R.Get (Value, "rule"));
      Item.Severity :=
        (if R.Get (Value, "severity") = "critical" then Critical
         elsif R.Get (Value, "severity") = "error" then Error
         elsif R.Get (Value, "severity") = "warning" then Warning
         else Information);
      if R.Get (Value, "severity") not in "information" | "warning" | "error" | "critical" then
         Refuse (Status, "severity", "diagnostic evidence has an invalid severity");
         return;
      end if;
      Item.Path := To_Unbounded_String (R.Get (Value, "path"));
      Item.Line := Number (R.Get (Value, "line"), Good);
      if not Good then
         Refuse (Status, "line", "diagnostic evidence has an invalid line");
         return;
      end if;
      Item.Column := Number (R.Get (Value, "column"), Good);
      if not Good then
         Refuse (Status, "column", "diagnostic evidence has an invalid column");
         return;
      end if;
      Item.Symbol := To_Unbounded_String (R.Get (Value, "symbol"));
      Item.Message := To_Unbounded_String (R.Get (Value, "message"));
      Item.Explanation := To_Unbounded_String (R.Get (Value, "explanation"));
      Item.Remediation := To_Unbounded_String (R.Get (Value, "remediation"));
      Item.Fingerprint := To_Unbounded_String (R.Get (Value, "fingerprint"));
      Item.Evidence_Id := To_Unbounded_String (R.Get (Value, "evidence"));
      Item.Native_Code := To_Unbounded_String (R.Get (Value, "native_code"));
      Item.Snapshot := To_Unbounded_String (R.Get (Value, "snapshot"));
      for Index in 1 .. R.Field_Count (Value) loop
         declare
            Field : constant String := R.Field_Name (Value, Index);
         begin
            if Field'Length > 11 and then Field (Field'First .. Field'First + 10) = "provenance." then
               Item.Provenance.Append (R.Get (Value, Field));
            elsif Field'Length > 13
              and then Field (Field'First .. Field'First + 7) = "related."
              and then Field (Field'Last - 4 .. Field'Last) = ".path"
            then
               declare
                  Stem : constant String := Field (Field'First .. Field'Last - 5);
                  Place : Source_Location;
               begin
                  Place.Path := To_Unbounded_String (R.Get (Value, Field));
                  Place.Line := Number (R.Get (Value, Stem & ".line"), Good);
                  if not Good then
                     Refuse (Status, "related line", "diagnostic evidence has an invalid location");
                     return;
                  end if;
                  Place.Column := Number (R.Get (Value, Stem & ".column"), Good);
                  if not Good then
                     Refuse (Status, "related column", "diagnostic evidence has an invalid location");
                     return;
                  end if;
                  Item.Related.Append (Place);
               end;
            end if;
         end;
      end loop;

      declare
         Stored : constant String := To_String (Item.Fingerprint);
      begin
         Prepare (Item, Status);
         if E.Is_Ok (Status) and then Stored /= "" and then Stored /= To_String (Item.Fingerprint) then
            Refuse (Status, "fingerprint", "diagnostic evidence does not match its contents");
         end if;
      end;
   end Parse;

end Model_Runner.Code_Health.Diagnostics;
