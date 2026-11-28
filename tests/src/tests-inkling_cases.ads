with AUnit;
with Tests.Fresh_Cases;

--  Native Inkling structural and numerical regression cases.
package Tests.Inkling_Cases is
   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   --  @param T Test instance.
   --  @return Reporter identity.
   overriding function Name (T : Case_Type) return AUnit.Message_String;

   --  @param T Test instance receiving the registered routines.
   overriding procedure Register_Tests (T : in out Case_Type);
end Tests.Inkling_Cases;
