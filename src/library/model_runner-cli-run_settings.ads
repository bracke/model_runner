with Model_Runner.CLI.Options;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Templates;
with Model_Runner.Trajectories;
with Model_Runner.Agent;
with Model_Runner.Presentation;

--  Machine-readable settings from prepared models, open sessions and fitted requests.
package Model_Runner.CLI.Run_Settings is

   Marker : constant String := "MODEL_RUNNER_SETTINGS ";

   --  @param Item Resolved native command after backend selection.
   --  @param Prepared Prepared model, including resolved capabilities and attachments.
   --  @param Session Actual session used for this request.
   --  @param Request Generation settings after model defaults and policy fitting.
   --  @param Thinking Effective template thinking choice.
   --  @param Effort Effective template reasoning level.
   --  @param Role Session, root or helper.
   --  @param Round Native policy-fitting round, zero for a session snapshot.
   --  @param Policy Native fitted policy and its value sources, empty for a session snapshot.
   --  @param Steps Actual step allowance for this call.
   --  @param Tokens Actual remaining total-token allowance; zero means unbounded.
   --  @param Seconds Actual remaining work time; zero means unbounded.
   --  @return Version-one JSON with explicit effective runtime and sampling settings.
   function Describe
     (Item : Options.Command; Prepared : Llama.Model'Class; Session : Llama.Session;
      Request : Generation.Request; Thinking : Templates.Thinking_Choice;
      Effort : Templates.Reasoning_Effort; Role : String := "session"; Round : Natural := 0;
      Policy : String := ""; Steps : Natural := 0; Tokens : Natural := 0; Seconds : Duration := 0.0)
      return String;

   --  Opt-in capture provenance, including whole artifact digests and native settings.
   --  Hashing occurs only when MODEL_RUNNER_CAPTURE_DIR is set.
   --  @param Item Resolved command and artifact paths.
   --  @param Prepared Actual model used by the run.
   --  @param Session Actual session.
   --  @param Request Fitted generation request.
   --  @param Thinking Effective thinking choice.
   --  @param Effort Effective reasoning effort.
   --  @param Invocation Native invocation ID, empty outside project work.
   --  @param Task_Id Native task ID, empty outside project work.
   --  @param Project_Revision Revision frozen on the invocation, when known.
   --  @param Parent_Invocation Native parent invocation, when known.
   --  @return Capture options with artifact provenance, or disabled options.
   function Capture
     (Item : Options.Command; Prepared : Llama.Model'Class; Session : Llama.Session;
      Request : Generation.Request; Thinking : Templates.Thinking_Choice;
      Effort : Templates.Reasoning_Effort; Invocation : String := ""; Task_Id : String := "";
      Project_Revision : String := ""; Parent_Invocation : String := "") return Trajectories.Options;

   --  @param Screen Diagnostic destination.
   --  @param Result Agent result; capture errors are reported without changing its grade.
   procedure Report_Capture (Screen : in out Presentation.Console; Result : Agent.Outcome);

end Model_Runner.CLI.Run_Settings;
