with AUnit.Test_Cases;

--  Tests for the project state a development session keeps.
--
--  The state is what a session is recovered from, so what is tested here
--  is what recovery rests on: a record reads back as it was written, a
--  record that breaks its schema is refused, a change interrupted at any
--  point leaves the state either as it was or as it became, and what is
--  derived can be thrown away and built again to the same thing.
package Tests.Framework_Cases is

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

end Tests.Framework_Cases;
