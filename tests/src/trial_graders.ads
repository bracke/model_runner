with Agent_Trial;
with Hostkit;

--  Verification runs after the agent has stopped, using a source kept outside its project.
package Trial_Graders is

   --  Require an exact complete capture with an actual successful reference edit
   --  of Calc.Add; passage edits, whole-file writes and delegation are refused.
   --  @param Capture_Path The explicitly selected completed root event stream.
   --  @return Whether the directed integration test exercised its required tool path.
   function Uses_Reference_Edit (Capture_Path : String) return Boolean;

   --  @param Root Fresh trial project whose verifier source is preserved outside it.
   --  @param Independent_Test Optional trusted Hidden_Test body, never exposed in the actor project.
   procedure Preserve (Root : String; Independent_Test : String := "");

   --  @param Root Project after trusted initialization, before its first /work call.
   --  @return True when its fixture baseline is sealed without replacing the preserved verifier sources.
   function Seal (Root : String) return Boolean;

   --  @param Root Trial project under version control.
   --  @param Task_Name Task defining the permitted source and document paths.
   --  @return Passed for a bounded diff, Failed for an unrelated change, or an infrastructure error.
   --  @param Allowed_Paths Exact replacement scope for a trusted custom fixture; empty keeps ordinary scope.
   function Check_Changes
     (Root, Task_Name : String;
      Allowed_Paths : Hostkit.String_Vectors.Vector := Hostkit.String_Vectors.Empty_Vector)
      return Agent_Trial.Verdict;

   --  @param Root Project after its native work session ended.
   --  @param Task_Name Which independently defined verifier to run.
   --  @param Expect Expected answer path for an external navigation task, or empty.
   --  @param Transcript Native session transcript, including the final report.
   --  @param Completed Whether the native workflow reported completion.
   --  @param Confine Require OS confinement for compilation and execution of the submitted code.
   --  @param Modern Compile a real-source fixture as Ada 2022 instead of retaining ordinary fixture flags.
   --  @param Hidden_Root Workspace hidden from the confined independent compiler and submitted program.
   --  @return Independent outcome, keeping infrastructure failures distinct from wrong work.
   function Verify
     (Root, Task_Name, Expect, Transcript : String;
      Completed : Boolean; Confine : Boolean := False; Modern : Boolean := False;
      Hidden_Root : String := "") return Agent_Trial.Verdict;

end Trial_Graders;
