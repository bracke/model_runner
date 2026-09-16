with AUnit.Test_Cases;

--  Pictures and the vision encoder: the three file formats decoded and
--  refused, the resampling, a projector written small and run against a
--  reference computation, and a picture's rows standing behind their
--  markers in a prompt.
package Tests.Vision_Cases is

   type Case_Type is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Case_Type) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Vision_Cases;
