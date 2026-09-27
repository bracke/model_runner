with Model_Runner.CLI.Options;
with Model_Runner.Presentation;

--  The init command: start a project's state from an installed template.
--
--  Everything particular to a kind of project is in its template; this
--  knows only the steps -- find the templates, let the caller pick one,
--  compose it, find out what the project already says, ask for what is
--  still wanted, show the plan, and carry it out. On a terminal it asks;
--  anywhere else it takes what it was given and says by name what was not.
package Model_Runner.CLI.Init is

   --  Run the init command.
   --
   --  @param Item The parsed command.
   --  @param Screen Where to write.
   --  @param Status The exit status.
   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural);

end Model_Runner.CLI.Init;
