--  Kernel measurements.
--
--  This exists because the engine was slow and reading the code produced two
--  confident wrong answers about why. It measures the kernels directly, on
--  synthetic tensors built in memory, so it needs no model file, no network
--  and no fixture. It is not part of the mandatory suite: it reports numbers
--  rather than passing or failing, and timings are not reproducible enough to
--  assert on.
--
--  Task safety: run from one task.
package Benchmarks is

   --  Measure the row kernels and report to standard output.
   --
   --  Each measurement is taken Rounds times and the median is reported.
   --  Every figure this feeds is published as a median of three and this
   --  reported a single pass, which on a laptop part is worth about ten per
   --  cent either way -- enough to read as a regression that is not there.
   --
   --  Refused on a machine already busy, because a figure taken there
   --  cannot be compared with one taken anywhere else -- and every other
   --  guard in this repository refuses rather than warns. What counts as
   --  busy is the host's one-minute load average against the bound below.
   --
   --  @param Seconds Approximate time to spend on each round.
   --  @param Rounds How many rounds to take the median of.
   --  @param Anyway Measure even on a busy machine, for a caller who wants
   --    the shape of an answer rather than a figure to publish.
   --  @param Wait Minutes to wait for the machine to go quiet before giving
   --    up on it. Zero refuses at once, which is what a caller who is
   --    watching wants; a caller who is not wants to come back to figures.
   procedure Run
     (Seconds : Duration := 0.5;
      Rounds  : Positive := 3;
      Anyway  : Boolean := False;
      Wait    : Natural := 0);

end Benchmarks;
