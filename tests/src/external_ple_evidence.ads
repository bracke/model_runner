with Model_Runner.Errors;

--  The discriminating precondition for a real external-PLE comparison.
--  Kept outside the command harness so a small synthetic GGUF can prove the
--  evidence rule without downloading the multi-gigabyte reference artifact.
package External_PLE_Evidence is

   type Backbone_State is
     (External_PLE_Required,
      PLE_Still_In_Backbone,
      Backbone_Unreadable);

   --  Inspect the backbone alone, without any auxiliary files.
   --  @param Path Backbone GGUF path.
   --  @param State Whether the backbone requires an external PLE tensor.
   --  @param Status Parsing status; success for both readable states.
   procedure Check
     (Path   : String;
      State  : out Backbone_State;
      Status : out Model_Runner.Errors.Error_Info);

end External_PLE_Evidence;
