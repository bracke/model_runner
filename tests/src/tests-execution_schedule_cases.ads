with AUnit;
with Tests.Fresh_Cases;

--  Logical execution and state ownership, without a model checkpoint.
package Tests.Execution_Schedule_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   --  Reporter identity.
   --
   --  @param T Test case instance.
   --  @return Case name.
   overriding function Name (T : Case_Type) return AUnit.Message_String;

   --  Register schedule, identity and malformed-input cases.
   --
   --  @param T Test case instance.
   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Execution_Schedule_Cases;
