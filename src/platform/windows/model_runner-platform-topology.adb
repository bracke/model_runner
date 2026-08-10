--  Core count on a host this does not ask.
--
--  Windows will answer, through GetLogicalProcessorInformationEx, but the
--  answer arrives as a walk over variable-length records containing a union,
--  and a binding to that written without a Windows machine to run it on is a
--  guess wearing a type. Returning zero is not a guess: the caller falls back
--  to the processor count, which is exactly what every host did before any of
--  this existed, so this host is no worse off than it was.
--
--  What it costs is worth stating. On a machine that reports two processors
--  per core, the default worker count is twice what the work can use, and the
--  second worker on each core spends processor time to return nothing.
--  Measured on Linux that is 26.7 s of processor time against 14.9 for the
--  same wall.
--
--  Whoever has such a machine and half an hour can fix it here. What the
--  answer has to satisfy is in the tests crate, in
--  Core_Count_Keeps_Its_Contract: a count in one .. the processor count, the
--  same on a second call, and zero from here rather than a number this file
--  half believes. That sentence used to say the test already existed, and it
--  did not -- so anybody who came to do this work would have gone looking
--  for a contract nobody had written.
package body Model_Runner.Platform.Topology is

   ---------------------
   -- Physical_Cores --
   ---------------------

   function Physical_Cores (Processors : Positive) return Natural is
      pragma Unreferenced (Processors);
   begin
      return 0;
   end Physical_Cores;

end Model_Runner.Platform.Topology;
