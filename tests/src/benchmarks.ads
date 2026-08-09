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
   --  @param Seconds Approximate time to spend on each round.
   --  @param Rounds How many rounds to take the median of.
   procedure Run (Seconds : Duration := 0.5; Rounds : Positive := 3);

end Benchmarks;
