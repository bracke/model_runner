with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Agent;
with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;

--  Bounded, deterministic repair and recheck orchestration. This package
--  never edits source; it decides whether the harness accepts an answer,
--  returns findings for another model turn, or stops incomplete.
package Model_Runner.Code_Health.Remediation is

   type Limits is record
      Max_Stagnant   : Positive := 3;
      Max_Assessments : Positive := 12;
      Threshold      : Diagnostic_Severity := Error;
      Feedback_Limit : Positive := 8 * 1_024;
   end record;

   type Assessment is record
      State              : Health_State := Not_Started;
      Snapshot           : Ada.Strings.Unbounded.Unbounded_String;
      Policy_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Diagnostics        : Model_Runner.Code_Health.Diagnostics.Diagnostic_List;
      Checks             : Model_Runner.Code_Health.Providers.Check_Result_Lists.Vector;
      Permissions_Valid  : Boolean := True;
   end record;

   type Remediation_State is record
      Assessments       : Natural := 0;
      Repair_Attempts   : Natural := 0;
      Stagnant_Attempts : Natural := 0;
      Best_Blockers     : Natural := Natural'Last;
      Last_Snapshot     : Ada.Strings.Unbounded.Unbounded_String;
      Last_Findings     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Action is (Proceed, Repair_And_Recheck, Stop_Incomplete);

   type Stop_Cause is
     (No_Stop,
      Stagnation_Limit,
      Oscillation_Detected,
      Assessment_Limit,
      Analysis_Cancelled,
      Permission_Lost,
      Policy_Changed);

   type Controller is private;

   --  @param Self Controller to initialize.
   --  @param Rules Bounded repair policy.
   procedure Initialize (Self : out Controller; Rules : Limits := (others => <>));

   --  @param Self Controller retaining history.
   --  @param Result Current assessment.
   --  @param Decision Next harness action.
   --  @param Cause Stop cause, when any.
   procedure Observe
     (Self     : in out Controller;
      Result   : Assessment;
      Decision : out Action;
      Cause    : out Stop_Cause);

   --  @param Self Controller.
   --  @return Current progress counters.
   function State_Of (Self : Controller) return Remediation_State;
   --  @param Self Controller.
   --  @return Terminal stop cause, or No_Stop.
   function Last_Stop (Self : Controller) return Stop_Cause;
   --  @param Cause Stop cause.
   --  @return Human-readable cause.
   function Stop_Words (Cause : Stop_Cause) return String;

   --  The boundary assessor runs the configured current checks and returns
   --  trusted, bounded model feedback. Tests use a scripted implementation;
   --  production dispatchers adapt the provider/evidence engine.
   type Assessment_Source is limited interface;
   type Assessment_Source_Reference is access all Assessment_Source'Class;

   --  @param Self Boundary assessment source.
   --  @param Trigger Lifecycle boundary.
   --  @param Answer Candidate model answer.
   --  @param Result Current structured assessment.
   --  @param Feedback Bounded trusted feedback.
   --  @param Status Success or assessment failure.
   procedure Assess
     (Self     : in out Assessment_Source;
      Trigger  : Trigger_Kind;
      Answer   : String;
      Result   : out Assessment;
      Feedback : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info) is abstract;

   type Completion_Gate is limited new Model_Runner.Agent.Answer_Gate with private;

   --  @param Self Gate to initialize.
   --  @param Source Current assessment source.
   --  @param Rules Bounded repair policy.
   procedure Initialize
     (Self   : out Completion_Gate;
      Source : not null Assessment_Source_Reference;
      Rules  : Limits := (others => <>));

   overriding procedure Evaluate
     (Self     : in out Completion_Gate;
      Answer   : String;
      Decision : out Model_Runner.Agent.Answer_Decision;
      Feedback : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Self Completion gate.
   --  @return Current progress counters.
   function Progress_Of (Self : Completion_Gate) return Remediation_State;
   --  @param Self Completion gate.
   --  @return Terminal stop cause, or No_Stop.
   function Stop_Of (Self : Completion_Gate) return Stop_Cause;

private

   type Assessment_Summary is record
      Signature       : Ada.Strings.Unbounded.Unbounded_String;
      Blockers        : Natural := 0;
      Required_Failed : Natural := 0;
      Highest         : Diagnostic_Severity := Information;
      Available       : Boolean := False;
   end record;

   package Summary_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Assessment_Summary);

   type Controller is record
      Rules           : Limits;
      Progress        : Remediation_State;
      Active_Policy   : Ada.Strings.Unbounded.Unbounded_String;
      History         : Summary_Lists.Vector;
      Previous        : Assessment_Summary;
      Has_Previous    : Boolean := False;
      Awaiting_Repair : Boolean := False;
      Stopped         : Stop_Cause := No_Stop;
   end record;

   type Completion_Gate is limited new Model_Runner.Agent.Answer_Gate with record
      Source     : Assessment_Source_Reference;
      Controller : Remediation.Controller;
   end record;

end Model_Runner.Code_Health.Remediation;
