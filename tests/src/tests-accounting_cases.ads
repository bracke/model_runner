with AUnit.Test_Cases;

--  Tests for memory accounting and the monotonic clock.
--
--  Neither had any test. Both are small, and both are the kind of small that
--  matters: the memory plan is what turns a model file declaring impossible
--  dimensions into a refusal instead of an attempted allocation, and the clock
--  is what keeps a statistics line from reporting a negative duration when the
--  host's timer misbehaves.
package Tests.Accounting_Cases is

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

end Tests.Accounting_Cases;
