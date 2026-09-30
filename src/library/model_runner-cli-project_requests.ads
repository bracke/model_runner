with Model_Runner.CLI.Options;
with Model_Runner.Text;

--  What a session's project command asks for, read from the line typed:
--  /init, /task, /work and the repository commands. The command line has
--  no part in it -- these commands are a session's alone.
package Model_Runner.CLI.Project_Requests is

   --  One project command's request.
   type Request is record
      --  /init: the template to start the project from, empty to choose
      --  one; the project's directory, empty for the current one.
      Template_Name     : Model_Runner.Text.Bounded;
      Project_Directory : Model_Runner.Text.Bounded;

      --  The inputs given as NAME=VALUE.
      Inputs      : Model_Runner.CLI.Options.Guard_List := [others => Model_Runner.Text.Empty];
      Input_Count : Natural := 0;

      --  What to do, and what it is done with -- a task, a new task's
      --  title, a symbol, a unit.
      Action          : Model_Runner.Text.Bounded;
      Action_Argument : Model_Runner.Text.Bounded;

      --  How much to say.
      Level : Model_Runner.CLI.Options.Verbosity := Model_Runner.CLI.Options.Normal;
   end record;

end Model_Runner.CLI.Project_Requests;
