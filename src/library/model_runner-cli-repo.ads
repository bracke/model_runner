with Model_Runner.CLI.Project_Requests;
with Model_Runner.Presentation;

--  A session's repository commands: the structure, asked of without a model.
--
--  Each run scans the project, so what it answers is the tree as it is;
--  in a project with state, the graph is kept in the indexes when it has
--  changed. /scan says what the scan found; /tree lists the files with
--  their language and role; /sym NAME finds a declared symbol; /refs NAME
--  lists where one is used; /deps UNIT and /users UNIT follow
--  the with clauses one way and the other.
package Model_Runner.CLI.Repo is

   --  Run a repository command.
   --
   --  @param Item The request.
   --  @param Screen Where to write.
   --  @param Status The exit status.
   procedure Run
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural);

end Model_Runner.CLI.Repo;
