with Model_Runner.Text;
with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Models_Command is

   use Model_Runner.CLI.Execute.Support;

   --  Offer the models on hand at a terminal and let the user pick one;
   --  Picked is false where there is nothing to offer or no answer.
   --
   --  @param Screen Where the list goes.
   --  @param Path The chosen model's file.
   --  @param Picked Whether one was chosen.
   procedure Choose_Model
     (Screen : in out Pres.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean);

   --  The models command: list the models on hand with their sizes, or
   --  remove one and all its shards.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Status The exit status.
   procedure Do_Models
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural);

end Model_Runner.CLI.Execute.Models_Command;
