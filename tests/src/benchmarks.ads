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
   --  @param Seconds Approximate time to spend on each measurement.
   procedure Run (Seconds : Duration := 0.5);

end Benchmarks;
