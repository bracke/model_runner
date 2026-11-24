with Model_Runner.Errors;
with Hostkit;
package Learning_Report is
   --  @param Root Completed original-pilot or predeclared transfer evaluation directory.
   --  @param Output New summary JSON, with every original attempt and paired descriptive statistics.
   --  @param Status Success or an incomplete/mismatched evidence diagnostic.
   --  @param Task_Names Explicit frozen transfer tasks, or empty for the original nine-pair pilot.
   --  @param First_Seed First paired sampling seed.
   --  @param Seed_Count Number of predeclared seeds per task.
   procedure Run
     (Root, Output : String; Status : out Model_Runner.Errors.Error_Info;
      Task_Names : Hostkit.String_Vectors.Vector := Hostkit.String_Vectors.Empty_Vector;
      First_Seed : Natural := 51; Seed_Count : Positive := 3);
end Learning_Report;
