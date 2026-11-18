with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Run_Command is

   use Model_Runner.CLI.Execute.Support;

   --  The run command: generate from a prompt, chat, or work as an agent.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Catalog The message catalog.
   --  @param Status The exit status.
   procedure Do_Run
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Catalog : Loc.Catalog;
      Status  : out Natural);

end Model_Runner.CLI.Execute.Run_Command;
