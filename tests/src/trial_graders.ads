with Agent_Trial;

--  Verification runs after the agent has stopped, using a source kept outside its project.
package Trial_Graders is

   --  @param Root Fresh trial project whose verifier source is preserved outside it.
   procedure Preserve (Root : String);

   --  @param Root Trial project under version control.
   --  @param Task_Name Task defining the permitted source and document paths.
   --  @return Passed for a bounded diff, Failed for an unrelated change, or an infrastructure error.
   function Check_Changes (Root, Task_Name : String) return Agent_Trial.Verdict;

   --  @param Root Project after its native work session ended.
   --  @param Task_Name Which independently defined verifier to run.
   --  @param Expect Expected answer path for an external navigation task, or empty.
   --  @param Transcript Native session transcript, including the final report.
   --  @param Completed Whether the native workflow reported completion.
   --  @return Independent outcome, keeping infrastructure failures distinct from wrong work.
   function Verify
     (Root, Task_Name, Expect, Transcript : String;
      Completed : Boolean) return Agent_Trial.Verdict;

end Trial_Graders;
