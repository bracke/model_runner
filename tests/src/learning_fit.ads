with Model_Runner.Errors;
package Learning_Fit is
   --  @param Model Exact base identity used for the frozen features.
   --  @param Features Native train.features and validation.features directory.
   --  @param Output New checkpoint and learning-curve directory.
   --  @param Status Success or a bounded feature, shape, numerical or I/O diagnostic.
   procedure Run (Model, Features, Output : String; Status : out Model_Runner.Errors.Error_Info);
end Learning_Fit;
