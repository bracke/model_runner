with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Model_Runner.Tools.Todo is

   use Ada.Strings.Unbounded;

   Kept       : Unbounded_String;
   Was_Changed : Boolean := False;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   function Set (Items : String) return String is
      Result : Unbounded_String;
      Start  : Positive := Items'First;
      Open, Done, Count : Natural := 0;
   begin
      for Index in Items'First .. Items'Last + 1 loop
         if Index > Items'Last or else Items (Index) = ASCII.LF then
            declare
               Line : constant String :=
                 Ada.Strings.Fixed.Trim (Items (Start .. Index - 1), Ada.Strings.Both);
               --  "- [x] a", "* [ ] b", "1. [x] c": a list's own marks kept off.
               Bare : Natural := Line'First;
            begin
               while Bare <= Line'Last and then Line (Bare) in '-' | '*' | '.' | '0' .. '9' | ' ' loop
                  Bare := Bare + 1;
               end loop;
               if Bare <= Line'Last and then Count < Most_Items then
                  declare
                     Rest : constant String := Line (Bare .. Line'Last);
                     Ticked : constant Boolean :=
                       Rest'Length >= 3 and then Rest (Rest'First .. Rest'First + 2) in "[x]" | "[X]";
                     Unticked : constant Boolean :=
                       Rest'Length >= 3 and then Rest (Rest'First .. Rest'First + 2) = "[ ]";
                     Words : constant String :=
                       Ada.Strings.Fixed.Trim
                         ((if Ticked or Unticked then Rest (Rest'First + 3 .. Rest'Last) else Rest),
                          Ada.Strings.Both);
                  begin
                     if Words /= "" then
                        Append (Result, (if Ticked then "[x] " else "[ ] ") & Words & ASCII.LF);
                        Count := Count + 1;
                        if Ticked then
                           Done := Done + 1;
                        else
                           Open := Open + 1;
                        end if;
                     end if;
                  end;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      if Result /= Kept then
         Was_Changed := True;
      end if;
      Kept := Result;
      return "the list is kept: " & Image (Open) & " to do, " & Image (Done) & " done";
   end Set;

   function Items return String is (To_String (Kept));

   function Changed return Boolean is
      Was : constant Boolean := Was_Changed;
   begin
      Was_Changed := False;
      return Was;
   end Changed;

   procedure Clear is
   begin
      Kept := Null_Unbounded_String;
      Was_Changed := False;
   end Clear;

end Model_Runner.Tools.Todo;
