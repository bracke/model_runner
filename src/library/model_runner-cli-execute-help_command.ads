with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Help_Command is

   use Model_Runner.CLI.Execute.Support;

   --  Print the version and what this build reads and runs.
   --
   --  @param Screen Where it goes.
   procedure Show_Version (Screen : in out Pres.Console);

   --  Print help, whole or on one topic.
   --
   --  @param Screen Where it goes.
   --  @param Topic The topic, or empty for the overview.
   procedure Show_Help
     (Screen : in out Pres.Console;
      Topic  : String);

end Model_Runner.CLI.Execute.Help_Command;
