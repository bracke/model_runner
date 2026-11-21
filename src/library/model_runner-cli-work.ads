with Model_Runner.CLI.Project_Requests;
with Model_Runner.Errors;
with Model_Runner.Framework.Work;
with Model_Runner.Presentation;

--  A session's /work: run one ready task, from context to completion.
--
--  /work TASK runs that task; /work alone offers the accepted tasks to
--  choose from on a terminal, ready ones first and blocked ones shown with
--  why, and anywhere else says it must be named. The agent is the
--  session's own model, or one named with model=PATH; an outside program
--  as the agent is out of scope. What happened is said step by step: the agent,
--  the context, the call, the files that changed, the verification, and
--  where the task ended.
package Model_Runner.CLI.Work is

   --  Run the work command with an agent the caller supplies: the
   --  interactive session's own model, already loaded.
   --
   --  @param Item The request.
   --  @param Screen Where to write.
   --  @param Runner The agent.
   --  @param Status The exit status.
   procedure Run_With
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Runner : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural);

   --  Run one exact task noninteractively with the same model-backed agent
   --  implementation used when /work names a model. The project configuration
   --  must select scalar.work.model; no alternate inference engine is used.
   --
   --  @param Project_Directory Initialized model_runner project.
   --  @param Task_Id Exact native task identity.
   --  @param Timeout_Seconds Caller ceiling; zero retains the native ceiling.
   --  @param Result Native work report.
   --  @param Status Framework or runner setup failure.
   procedure Run_Headless
     (Project_Directory : String;
      Task_Id           : String;
      Timeout_Seconds   : Natural;
      Result            : out Model_Runner.Framework.Work.Report;
      Status            : out Model_Runner.Errors.Error_Info);

end Model_Runner.CLI.Work;
