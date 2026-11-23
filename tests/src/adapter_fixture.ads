--  Synthetic adapters for execution and memory checks; these carry no trained behavior.
package Adapter_Fixture is
   --  @param Model_Path GGUF whose architecture and named matrix determine the fixture shape.
   --  @param Output_Path New destination for a synthetic F16 adapter; existing files are refused.
   --  @param Tensor_Name Main-layer linear projection to adapt.
   --  @param Clean Whether the bounded fixture was written successfully.
   --  @param Rank Rank from one through 64; default two preserves the original fixture.
   --  @param All_Targets Include every present supported main-layer projection, excluding next-layer drafts.
   procedure Run
     (Model_Path, Output_Path, Tensor_Name : String; Clean : out Boolean;
      Rank : Positive := 2; All_Targets : Boolean := False);
end Adapter_Fixture;
