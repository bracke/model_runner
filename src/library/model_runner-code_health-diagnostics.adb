with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.UTF8;

package body Model_Runner.Code_Health.Diagnostics is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package R renames Model_Runner.Framework.Records;

   Maximum_Field_Bytes : constant := 64 * 1024;

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
      Texts : constant array (Positive range 1 .. 10) of Unbounded_String :=
        [Item.Provider, Item.Rule_Id, Item.Path, Item.Symbol, Item.Message,
         Item.Explanation, Item.Remediation, Item.Native_Code, Item.Snapshot, Item.Evidence_Id];

      function Name_Of (Index : Positive) return String is
        (case Index is
            when 1 => "provider", when 2 => "rule", when 3 => "path", when 4 => "symbol",
            when 5 => "message", when 6 => "explanation", when 7 => "remediation",
            when 8 => "native_code", when 9 => "snapshot", when others => "evidence");
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
      for Place of Item.Related loop
         if not Model_Runner.UTF8.Is_Valid (To_String (Place.Path)) then
            Status := E.Make (E.IO_Invalid_UTF8);
            E.Add_Text (Status, "path", "related location");
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
         Item.Path := To_Unbounded_String (Normalized);
      end;
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

end Model_Runner.Code_Health.Diagnostics;
