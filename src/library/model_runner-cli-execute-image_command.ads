with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Image_Command is

   use Model_Runner.CLI.Execute.Support;

   --  The image command: a picture drawn from a prompt by Qwen-Image 2.1.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Status The exit status.
   procedure Do_Image
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural);

end Model_Runner.CLI.Execute.Image_Command;
