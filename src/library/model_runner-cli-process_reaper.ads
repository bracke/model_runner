with Hostkit.Spawn;

--  Children that did not finish within a foreground cleanup's deadline.
--  Keeping them here lets a conversation or server stop promptly without
--  losing the only handle by which the child can later be collected.
private package Model_Runner.CLI.Process_Reaper is

   --  Take ownership of Child and keep asking it to stop until it can be
   --  collected. Output, where given, is removed only after the child and its
   --  process tree have let it go. Child is invalid on return.
   --
   --  @param Child Process handle transferred to the reaper.
   --  @param Output Passing output to remove after the process tree ends.
   procedure Adopt
     (Child  : in out Hostkit.Spawn.Process_Handle;
      Output : String := "");

   --  Remove a passing-output file once no descendant holds it. This is the
   --  output-only form of Adopt, for a process leader already collected before
   --  releasing its Windows Job Object asynchronously stopped descendants.
   --
   --  @param Output Passing output to remove when the host permits it.
   procedure Remove_When_Free (Output : String);

end Model_Runner.CLI.Process_Reaper;
