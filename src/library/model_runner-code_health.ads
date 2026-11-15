with Ada.Containers.Indefinite_Vectors;

--  Continuous, deterministic assessment of source changes made by agents.
--
--  This root package contains the vocabulary shared by the change capture,
--  provider, evidence and remediation layers.  It deliberately contains no
--  model-facing or presentation operations: the harness owns completion
--  decisions and providers only report observations.
package Model_Runner.Code_Health is

   type Check_Level is (Fast, Focused, Full);

   type Trigger_Kind is
     (After_File_Change,
      After_Command,
      After_Delegation,
      Before_Agent_Answer,
      Before_Task_Completion,
      Explicit_Request);

   type Health_State is
     (Not_Started,
      Checking,
      Passed,
      Findings_Present,
      Blocked,
      Unavailable,
      Stale,
      Cancelled);

   type Gate_Decision is
     (Allow_Completion,
      Require_Remediation,
      Refuse_Completion);

   type Diagnostic_Severity is
     (Information,
      Warning,
      Error,
      Critical);

   --  Strings used in provider requests and profile definitions.  Their
   --  order is part of a request unless the owning contract says otherwise.
   package String_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

end Model_Runner.Code_Health;
