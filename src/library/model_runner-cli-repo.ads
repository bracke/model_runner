with Model_Runner.CLI.Options;
with Model_Runner.Presentation;

--  The repo command: the repository's structure, asked of without a model.
--
--  Each run scans the project, so what it answers is the tree as it is;
--  in a project with state, the graph is kept in the indexes when it has
--  changed. repo scan says what the scan found; repo tree lists the files
--  with their language and role; repo sym NAME finds a declared symbol;
--  repo refs NAME lists where one is used; repo deps UNIT and repo users
--  UNIT follow the with clauses one way and the other.
package Model_Runner.CLI.Repo is

   --  Run the repo command.
   --
   --  @param Item The parsed command.
   --  @param Screen Where to write.
   --  @param Status The exit status.
   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural);

end Model_Runner.CLI.Repo;
