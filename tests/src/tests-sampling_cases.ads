with AUnit.Test_Cases;

--  Tests for the sampling pipeline, stop conditions and chat templates.
--
--  Sampling is tested without a model: the logit vectors are written by hand,
--  so an assertion names the pipeline stage that misbehaved rather than a
--  model that produced surprising numbers.
package Tests.Sampling_Cases is

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

end Tests.Sampling_Cases;
