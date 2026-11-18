with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Run_Command is

   use Model_Runner.CLI.Execute.Support;

   --  Apply an exact retained expert-cache qualification, unless the caller
   --  explicitly selected a cache or disabled automatic recommendations.
   --  Called after backend resolution, when the actual device is known.
   --  @param Item Resolved command.
   --  @param Screen Where an applied recommendation is reported.
   --  @return Command with the qualified reserve, or Item unchanged.
   function With_Expert_Cache_Recommendation
     (Item   : Opt.Command;
      Screen : in out Pres.Console) return Opt.Command;

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
