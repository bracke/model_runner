--  How the host's processors map onto physical cores.
--
--  Only the answer differs between hosts, and only the way of asking is
--  host-specific, so this is one spec with one body per host beside the
--  mapping and signal bodies. The parent turns the answer into the worker
--  default; nothing else uses it.
--
--  Task safety: a call reads the host and holds no state.
private package Model_Runner.Platform.Topology is

   --  Physical cores, where the host will say how many it has.
   --
   --  Zero means the host was not asked, could not be asked, or answered
   --  something this did not understand. It is not an error and not a guess:
   --  the caller falls back to the processor count, which is what it used
   --  before any of this was here. An implementation that is unsure returns
   --  zero rather than a number it half believes.
   --
   --  @param Processors Processors the host reports, as an upper bound.
   --  @return Core count in 1 .. Processors, or 0 when unknown.
   function Physical_Cores (Processors : Positive) return Natural;

end Model_Runner.Platform.Topology;
