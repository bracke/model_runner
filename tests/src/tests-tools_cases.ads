with AUnit.Test_Cases;

--  Tests for the built-in tools and the tool-call grammar.
--
--  Neither needs a model. A built-in tool answers from its arguments, so its
--  answer can be asserted directly; the call grammar is text in and a
--  compiled grammar out, so what it accepts can be matched directly. The
--  loop that joins them to a model is exercised by the agent-eval command
--  against a real one; what is here is the two ends of it that a machine can
--  check without weights.
package Tests.Tools_Cases is

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

end Tests.Tools_Cases;
