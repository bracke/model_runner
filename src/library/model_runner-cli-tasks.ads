with Model_Runner.CLI.Project_Requests;
with Model_Runner.Presentation;

--  A session's /task: the project's persistent work, listed and managed.
--
--  /task, or /task list, lists every task with where it stands, ready
--  shown as if it were a state; /task new TITLE creates one from
--  NAME=VALUE fields, asking a terminal for what its kind requires and
--  naming what is missing anywhere else; /task accept, reject and cancel
--  move one; /task show prints the Effective Task; /task derive makes
--  the tasks the accepted requirements imply. After every change,
--  readiness is worked out again and each task that became ready is said.
package Model_Runner.CLI.Tasks is

   --  Run /task.
   --
   --  @param Item The request.
   --  @param Screen Where to write.
   --  @param Status The exit status.
   procedure Run
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural);

end Model_Runner.CLI.Tasks;
