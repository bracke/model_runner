with Model_Runner.Framework.Repository;

--  The repository engine's names, found as a reader asks for them.
procedure Repository_Tests is

   package Rp renames Model_Runner.Framework.Repository;

   --  A symbol is found by its full name and by its last part.
   procedure Symbols_Are_Found_By_Name (Found : Rp.Graph) is
   begin
      if Rp.Find_Symbols (Found, "next").Is_Empty then
         raise Program_Error with "a symbol was not found by its name";
      end if;
      if Rp.Find_Symbols (Found, "crate::fnv::fnv1a").Is_Empty then
         raise Program_Error with "a Rust path was not found";
      end if;
   end Symbols_Are_Found_By_Name;

   --  What a unit depends on, as its context clause says.
   procedure Dependencies_Are_Read (Found : Rp.Graph) is
   begin
      if Rp.Dependencies_Of (Found, "Parser").Is_Empty then
         raise Program_Error with "a with was not read";
      end if;
   end Dependencies_Are_Read;

   Empty : Rp.Graph;
begin
   Symbols_Are_Found_By_Name (Empty);
   Dependencies_Are_Read (Empty);
end Repository_Tests;
