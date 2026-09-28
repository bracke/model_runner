with Model_Runner.CLI.Options;
with Model_Runner.Presentation;

--  The work command: run one ready task, from context to completion.
--
--  work TASK runs that task; work alone offers the accepted tasks to
--  choose from on a terminal, ready ones first and blocked ones shown with
--  why, and anywhere else says it must be named. The agent is a model --
--  --set model=PATH, or the configuration's scalar work.model -- run as
--  this program's own agent with no shell, no network and no delegation,
--  or a command the configuration names as scalar work.agent, run through
--  the execution policy with ${prompt} standing for its context's file.
--  What happened is said step by step: the agent, the context, the call,
--  the files that changed, the verification, and where the task ended.
package Model_Runner.CLI.Work is

   --  Run the work command.
   --
   --  @param Item The parsed command.
   --  @param Screen Where to write.
   --  @param Status The exit status.
   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural);

end Model_Runner.CLI.Work;
