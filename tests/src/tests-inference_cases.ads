with AUnit.Test_Cases;

--  End-to-end tests of the Llama-compatible execution path.
--
--  Every case runs the tiny synthetic model: preparation, tokenization,
--  session allocation, evaluation and the transactional behaviour of the KV
--  cache. Nothing here needs a downloaded model or a network.
package Tests.Inference_Cases is

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

end Tests.Inference_Cases;
