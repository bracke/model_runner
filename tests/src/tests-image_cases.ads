with AUnit;
with Tests.Fresh_Cases;

--  Making a picture from a prompt: Qwen-Image 2.1's denoiser read from a
--  file that states nothing, its configuration off its shapes, and refused
--  where they are not its own (docs/plan-image-generation.md).
package Tests.Image_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   overriding function Name (T : Case_Type) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Image_Cases;
