with AUnit;
with Tests.Fresh_Cases;

package Tests.Adapter_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   --  @param T Test instance.
   --  @return Name displayed by AUnit.
   overriding function Name (T : Case_Type) return AUnit.Message_String;

   --  @param T Test instance receiving numerical and malformed-input checks.
   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Adapter_Cases;
