with Model_Runner.Errors;
with Model_Runner.Backend;
--  Deterministic curation and frozen-feature extraction for the declared local experiment.
package Learning_Data is
   --  @param Collection Completed fixed-seed native attempt directory.
   --  @param Output New dataset directory; all prior attempts remain untouched.
   --  @param Status Success or a bounded evidence/curation diagnostic.
   --  @param Only_Family Zero for the complete dataset; one through five for an incomplete diagnostic preview.
   procedure Curate
     (Collection, Output : String; Status : out Model_Runner.Errors.Error_Info; Only_Family : Natural := 0);
   --  @param Model Exact frozen base GGUF.
   --  @param Dataset Curated train/validation JSON-lines directory.
   --  @param Output New native feature directory.
   --  @param Status Success or a model, evidence, shape or I/O diagnostic.
   --  @param Backend Native device by default; CPU permits independent numerical controls.
   --  @param Expected_Base Exact required identity, defaulting to the user's Mellum model.
   procedure Extract
     (Model, Dataset, Output : String; Status : out Model_Runner.Errors.Error_Info;
      Backend : Model_Runner.Backend.Backend_Kind := Model_Runner.Backend.Backend_Device;
      Expected_Base : String := "ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755");
end Learning_Data;
