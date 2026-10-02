with Model_Runner.Framework.Stores;
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

   --  The open tasks that wait for a task, and its parts still open, said
   --  for a question about ending it: "; TASK-003 waits on it", or "" for
   --  none.
   --
   --  @param Store The project's state.
   --  @param Id The task.
   --  @return The words.
   function Waiting_On_It (Store : Model_Runner.Framework.Stores.Store; Id : String) return String;

   --  The document's label of a requirement a task serves that its document
   --  ticks as done -- FR-1, from bootstrap's issue -- with where.
   --
   --  @param Store The project's state.
   --  @param Task_Id The task.
   --  @return As "FR-1 in README.md"; "" where none is.
   function Ticked_Done (Store : Model_Runner.Framework.Stores.Store; Task_Id : String) return String;

end Model_Runner.CLI.Tasks;
