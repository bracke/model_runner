with AUnit.Test_Cases;

--  Tests for the command parser and the generation coordinator.
--
--  The parser is driven with an exact argument vector rather than a process,
--  and generation is driven through a sink that accumulates text, so both are
--  checked without touching a terminal or a pipe.
package Tests.CLI_Cases is

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

end Tests.CLI_Cases;
