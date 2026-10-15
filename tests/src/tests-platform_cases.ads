with AUnit;
with Tests.Fresh_Cases;

--  The platform layer: interrupts and endings, descriptors, mappings,
--  the cache folders and how many processors a run takes.
package Tests.Platform_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   overriding function Name (T : Case_Type) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Platform_Cases;
