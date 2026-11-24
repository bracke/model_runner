with Model_Runner.Errors;
package Learning_Report is
   --  @param Root Completed nine-pair native evaluation directory.
   --  @param Output New summary JSON, with every original attempt and paired descriptive statistics.
   --  @param Status Success or an incomplete/mismatched evidence diagnostic.
   procedure Run (Root, Output : String; Status : out Model_Runner.Errors.Error_Info);
end Learning_Report;
