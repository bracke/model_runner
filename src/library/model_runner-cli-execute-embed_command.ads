with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Embed_Command is

   use Model_Runner.CLI.Execute.Support;

   --  The embed command: a text's embedding, or a ranking against a query.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Status The exit status.
   procedure Do_Embed
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural);

end Model_Runner.CLI.Execute.Embed_Command;
