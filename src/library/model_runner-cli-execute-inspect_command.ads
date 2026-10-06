with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Inspect_Command is

   use Model_Runner.CLI.Execute.Support;

   --  The inspect command: what a model file holds.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Status The exit status.
   procedure Do_Inspect
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Status  : out Natural);

end Model_Runner.CLI.Execute.Inspect_Command;
