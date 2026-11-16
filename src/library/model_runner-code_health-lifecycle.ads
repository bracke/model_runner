with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Spec-driven task bindings for Code Health. The task gate reads immutable
--  assessment evidence; it never accepts a model's claim or runs a provider
--  while merely inspecting completion state.
package Model_Runner.Code_Health.Lifecycle is

   type Gate_Report is record
      Passed   : Boolean := False;
      Evidence : Ada.Strings.Unbounded.Unbounded_String;
      Reason   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Judge the newest full assessment for this task's current execution
   --  generation. Workspace-only, stale, unavailable and blocked evidence
   --  is retained but cannot satisfy the integrated project gate.
   --  @param Item Project store.
   --  @param Task_Id Task whose current generation is judged.
   --  @return Passing decision, evidence identity and reason.
   function Judge
     (Item    : Model_Runner.Framework.Stores.Store;
      Task_Id : String) return Gate_Report;

   --  Link the framework's mandatory completion verification to one full
   --  Code Health assessment in the same transaction. Disabled projects
   --  are unchanged. Verification remains authoritative for its checks;
   --  this record supplies task, generation, snapshot and gate provenance.
   --  @param Item Project store.
   --  @param Change Transaction receiving the immutable assessment.
   --  @param Task_Id Verified task.
   --  @param Agent_Id Agent provenance.
   --  @param Invocation_Id Invocation provenance.
   --  @param Verification_Evidence Linked verification evidence.
   --  @param Verification_Passed Whether formal verification passed.
   --  @param Assessment_Id Created assessment identity, or empty when disabled.
   --  @param Status Success or persistence failure.
   procedure Record_Full_Verification
     (Item                  : Model_Runner.Framework.Stores.Store;
      Change                : in out Model_Runner.Framework.Stores.Transaction;
      Task_Id               : String;
      Agent_Id              : String;
      Invocation_Id         : String;
      Verification_Evidence : String;
      Verification_Passed   : Boolean;
      Assessment_Id         : out Ada.Strings.Unbounded.Unbounded_String;
      Status                : out Model_Runner.Errors.Error_Info);

end Model_Runner.Code_Health.Lifecycle;
