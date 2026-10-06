with Model_Runner.Cancellation;
with Model_Runner.Progress;
with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Acquisition is

   use Model_Runner.CLI.Execute.Support;

   --  A model named by an alias in the settings file becomes what the alias
   --  stands for; a name with no such alias is itself.
   --
   --  @param Named The name given.
   --  @return What to load.
   function Resolve_Alias (Named : String) return String;

   --  Open a model's files and prepare it for a command, with the
   --  command's limits and refusals.
   --
   --  @param Item The command.
   --  @param Screen Where progress and notes go.
   --  @param Source The model's shards, opened.
   --  @param Container The parsed container.
   --  @param Prepared The prepared model.
   --  @param Full Whether to prepare the weights, not only read the metadata.
   --  @param Observer Progress reporting.
   --  @param Cancel Cancellation.
   --  @param Status A failure, or success.
   --  @param Instead A file to load in place of the command's model -- a
   --         draft -- with the same limits; empty for the command's own.
   procedure Load
     (Item      : Opt.Command;
      Screen    : in out Pres.Console;
      Source    : in out Shards.Shard_Set;
      Container : in out Containers.Container;
      Prepared  : in out L.Model;
      Full      : Boolean;
      Observer  : Model_Runner.Progress.Observer_Reference;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Status    : out E.Error_Info;
      Instead   : String := "");

end Model_Runner.CLI.Execute.Acquisition;
