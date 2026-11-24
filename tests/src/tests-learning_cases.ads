with AUnit;
with AUnit.Test_Cases;
package Tests.Learning_Cases is
   type Case_Type is new AUnit.Test_Cases.Test_Case with null record;
   overriding function Name (T : Case_Type) return AUnit.Message_String;
   overriding procedure Register_Tests (T : in out Case_Type);
end Tests.Learning_Cases;
