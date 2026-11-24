with Learning_Lora;
with Model_Runner.Errors;

--  Explicit artifact operations for the local output-projection training experiment.
package Learning_Lora_Files is
   --  @param Path Read-only regular input file.
   --  @return Whole-file SHA-256, or empty on failure.
   function Digest (Path : String) return String;
   --  @param Item Trained factors, with alpha equal to rank.
   --  @param Path New adapter destination; existing paths are refused.
   --  @param Base_SHA256 Exact training base identity.
   --  @param Architecture Original GGUF architecture.
   --  @param Status Success or a structured artifact error.
   procedure Save
     (Item : Learning_Lora.Adapter; Path, Base_SHA256, Architecture : String;
      Status : out Model_Runner.Errors.Error_Info);
   --  @param Item Receives validated factor data.
   --  @param Path Adapter artifact to load, at most 64 MiB.
   --  @param Expected_Base Exact required base identity.
   --  @param Status Success or a structured artifact error.
   procedure Load
     (Item : in out Learning_Lora.Adapter; Path, Expected_Base : String;
      Status : out Model_Runner.Errors.Error_Info);
   --  @param Base_Path Original read-only quantized GGUF.
   --  @param Adapter_Path Actual trained output-projection adapter.
   --  @param Output_Path New GGUF destination, never the original file.
   --  @param Status Success or a shape, lineage, quantization or I/O diagnostic.
   procedure Merge
     (Base_Path, Adapter_Path, Output_Path : String; Status : out Model_Runner.Errors.Error_Info);
end Learning_Lora_Files;
