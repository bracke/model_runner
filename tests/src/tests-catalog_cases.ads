with AUnit.Test_Cases;

--  Message-catalog completeness and localization behaviour.
--
--  These tests are what make "no user-facing prose bypasses the catalog"
--  checkable rather than aspirational: every diagnostic code must resolve, and
--  every key the presentation layer looks up must exist.
package Tests.Catalog_Cases is

   type Case_Type is new AUnit.Test_Cases.Test_Case with null record;

   --  Name shown by the reporter.
   --
   --  @param T Test case instance.
   --  @return Case name.
   overriding function Name (T : Case_Type) return AUnit.Message_String;

   --  Register the routines of this case.
   --
   --  @param T Test case instance.
   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Catalog_Cases;
