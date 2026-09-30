with Model_Runner.CLI.Project_Requests;
with Model_Runner.Framework.Work;
with Model_Runner.Presentation;

--  A session's /work: run one ready task, from context to completion.
--
--  /work TASK runs that task; /work alone offers the accepted tasks to
--  choose from on a terminal, ready ones first and blocked ones shown with
--  why, and anywhere else says it must be named. The agent is the
--  session's own model, or a command the configuration names as scalar
--  work.agent, run through the execution policy with ${prompt} standing
--  for its context's file. What happened is said step by step: the agent,
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

end Model_Runner.CLI.Work;
