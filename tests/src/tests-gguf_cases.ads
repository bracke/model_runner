with AUnit.Test_Cases;

--  Structural tests for the GGUF container parser.
--
--  Every case builds a valid file in memory and then edits exactly one field,
--  so a failure names the property that was violated rather than "the file is
--  broken".
package Tests.GGUF_Cases is

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

end Tests.GGUF_Cases;
