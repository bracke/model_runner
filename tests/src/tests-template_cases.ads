with AUnit.Test_Cases;

--  Tests for the chat template engine.
--
--  A chat template is the most program-like thing a model file carries: it has
--  loops, conditionals and expressions, and it arrives from a file the program
--  did not write. The engine states five bounds -- template size, instruction
--  count, nesting depth, loop iterations and output size -- and eleven refusal
--  codes, and none of them had a test. A bound that is documented but does not
--  fire is worse than one that was never claimed.
--
--  These tests drive the engine directly rather than through generation, so
--  each bound is reached deliberately and the refusal is checked by code.
package Tests.Template_Cases is

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

end Tests.Template_Cases;
