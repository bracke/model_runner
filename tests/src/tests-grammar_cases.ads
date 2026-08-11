with AUnit.Test_Cases;

--  Tests for the output grammar engine.
--
--  A grammar arrives from a command line or a file, so it is untrusted input
--  with a parser behind it, and what it produces is a constraint on every
--  token the model may emit. Both halves are worth testing directly: that
--  the notation compiles to what it says, and that the matcher then accepts
--  exactly the texts the grammar describes.
--
--  These drive the engine rather than a generation, so a construct is
--  reached deliberately and a refusal is checked by code instead of being
--  inferred from text that did not appear.
package Tests.Grammar_Cases is

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

end Tests.Grammar_Cases;
