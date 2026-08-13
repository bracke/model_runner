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
   procedure Run
     (Seconds : Duration := 0.5;
      Rounds  : Positive := 3;
      Anyway  : Boolean := False);

   --  The load above which a figure is refused.
   --
   --  One and a half rather than one: a machine with nothing on it still
   --  shows the last minute of whatever ran before, and refusing the first
   --  run after a build would refuse most first runs.
   Too_Busy : constant := 1.5;

   --  Whether a figure taken at this load is worth publishing.
   --
   --  A function rather than the comparison written where it is used,
   --  because a bound that only exists inside a procedure that spends a
   --  minute measuring cannot be checked by anything: the suite would have
   --  to arrange for a busy machine to see the refusal, which it cannot do.
   --
   --  @param Load The host's one-minute load average, as Host_Load reports
   --    it, where zero means the host keeps no such number.
   --  @return True when the load is low enough, or unknown.
   function Publishable (Load : Long_Float) return Boolean
   is (Load <= Too_Busy);

end Benchmarks;
