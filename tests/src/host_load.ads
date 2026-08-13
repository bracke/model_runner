--  What the machine is busy with, for figures to carry.
--
--  A timing is a fact about a machine at a moment, and the moment is half of
--  it: the processor side of the comparisons this repository publishes has
--  moved by forty per cent between otherwise identical runs. A figure that
--  carries the load it was taken under can be compared with another; one
--  that does not has to be believed.
--
--  One reader, used by every tool that publishes a timing, because three
--  copies of it would be three things to keep in step and two of them would
--  drift.
--
--  Task safety: reads a file and returns a number; no state.
package Host_Load is

   --  The host's one-minute load average.
   --
   --  Zero where the host keeps no such number, which is honest as far as it
   --  goes and is why a tool that prints it should say where it came from: a
   --  zero means unknown, not quiet.
   --
   --  @return The load average, or zero.
   function Now return Long_Float;

end Host_Load;
