with Agent_Trial;
with Model_Runner.Numerics;

--  Paired four-arm campaigns over Agent_Trial, using its deployed /work workflow.
package Agent_Campaign is

   --  @param Path File to hash without loading it whole.
   --  @return SHA-256 hex digest, or empty when the file cannot be read.
   function File_Digest (Path : String) return String;

   --  @param Id Stable attempt identity within a campaign.
   --  @param Arm Which model and thinking setting ran.
   --  @param Seed Sampling seed for this attempt.
   --  @param Item Independently graded attempt and native measurements.
   --  @param Manifest_SHA256 Digest binding this result to the exact campaign configuration.
   --  @return Version-one JSON, with unavailable measurements represented as null.
   function Attempt_JSON
     (Id, Arm : String; Seed : Natural; Item : Agent_Trial.Attempt;
      Manifest_SHA256 : String := "") return String;

   --  @param Base Original complete model file.
   --  @param Adapted Adapted complete model file.
   --  @param Program Native model_runner executable.
   --  @param Output_Directory Campaign manifest, attempt records and retained projects.
   --  @param Clean True only when every planned attempt passed.
   --  @param Only Comma-separated task names, without duplicates.
   --  @param Options Shared inference options, excluding campaign-owned controls.
   --  @param Repeats Attempts per task and arm.
   --  @param Max_Seconds Work budget per attempt.
   --  @param Context_Size Context capacity for every arm.
   --  @param Seed First paired seed; later repeats increment it.
   --  @param Check_Only Rebuild the report without starting missing attempts.
   --  @param Base_Adapter Optional runtime adapter for both base thinking settings.
   --  @param Adapted_Adapter Optional runtime adapter for both adapted thinking settings.
   --  @param Base_Scale Native-representable finite scale; must be one when no adapter is selected.
   --  @param Adapted_Scale Native-representable finite scale; must be one when no adapter is selected.
   procedure Run
     (Base, Adapted, Program, Output_Directory : String;
      Clean : out Boolean;
      Only : String := "edit,find,delegate";
      Options : String := "--backend cpu --threads 8 --kv-cache q4t";
      Repeats : Positive := 3;
      Max_Seconds : Positive := 300;
      Context_Size : Positive := 8_192;
      Seed : Natural := 42;
      Check_Only : Boolean := False;
      Base_Adapter : String := "";
      Adapted_Adapter : String := "";
      Base_Scale : Model_Runner.Numerics.Real := 1.0;
      Adapted_Scale : Model_Runner.Numerics.Real := 1.0);

end Agent_Campaign;
