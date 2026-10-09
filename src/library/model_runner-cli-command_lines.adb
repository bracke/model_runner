with Ada.Strings.Fixed;

package body Model_Runner.CLI.Command_Lines is

   use Ada.Strings.Unbounded;

   ---------------
   -- Canonical --
   ---------------

   function Canonical (Item : Request) return String is
      Said : Unbounded_String := Item.Word;
   begin
      for Index in Item.Positional.First_Index .. Item.Positional.Last_Index loop
         declare
            One  : constant String := Item.Positional (Index);
            Free : constant Boolean := Item.Free_Last and then Index = Item.Positional.Last_Index;
         begin
            Append (Said, " " & (if not Free and then Ada.Strings.Fixed.Index (One, " ") > 0
                                 then '"' & One & '"' else One));
         end;
      end loop;
      for One of Item.Settings loop
         Append (Said, " " & One);
      end loop;
      return To_String (Said);
   end Canonical;

end Model_Runner.CLI.Command_Lines;
