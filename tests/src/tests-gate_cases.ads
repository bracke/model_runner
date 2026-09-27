with AUnit.Test_Cases;

--  Tests for the gate's own reasoning.
--
--  The release gate decides what a run of it proves: which conformance
--  comparisons a short sweep owes, which crates a build compiled and may be
--  held to their warnings, and which line of a catalog stops it loading.
--  Each of those decisions went wrong on a host the developer's machine is
--  not -- a runner with no device, a job that never built the tools, a
--  checkout that ends lines the Windows way -- and each is asked here on
--  fixtures made for the question, with no device and no network.
package Tests.Gate_Cases is

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

end Tests.Gate_Cases;
