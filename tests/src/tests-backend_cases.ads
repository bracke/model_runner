with AUnit.Test_Cases;

--  Tests for the CPU backend and its worker pool.
--
--  The property that matters most is that the worker count cannot change a
--  result: these tests compare a parallel product against the serial one
--  element by element, and check that the partition is a disjoint cover of the
--  rows for every count.
package Tests.Backend_Cases is

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

end Tests.Backend_Cases;
