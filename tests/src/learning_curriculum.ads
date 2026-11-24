--  Fresh teaching families, separate from all existing evaluation fixtures.
package Learning_Curriculum is
   Families : constant := 5;
   --  @param Which Teaching family, with family five reserved for validation.
   --  @return Stable family identifier.
   function Family (Which : Positive) return String;
   --  @param Which Teaching family.
   --  @return Ordinary task instructions without an imposed editing mode.
   function Notes (Which : Positive) return String;
   --  @param Root New project destination; existing directories are refused.
   --  @param Which Teaching family.
   --  @param Reference Whether to install the independently tested reference implementation.
   procedure Make_Project (Root : String; Which : Positive; Reference : Boolean := False);
   --  @param Root New control directory.
   --  @param Clean Whether every reference passes and every unchanged implementation fails.
   procedure Validate (Root : String; Clean : out Boolean);
end Learning_Curriculum;
