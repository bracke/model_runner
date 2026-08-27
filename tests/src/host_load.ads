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

   --  Processor time this program has used, in seconds.
   --
   --  Wall time says how long a run took and processor time says what it
   --  cost, and the two answer different questions: a worker count that
   --  buys six per cent of the wall for seventy per cent more processor
   --  time is a bad bargain that a wall figure alone calls a good one.
   --
   --  Here for the same reason the load is: it is a fact about this machine
   --  and this moment, read the same way, and a tool that publishes a
   --  timing should be able to publish both without binding a host call of
   --  its own. The README said this number was the one the tool could not
   --  produce, and it was right until this.
   --
   --  Zero where the host does not say, which is honest as far as it goes
   --  and is why a tool that prints it should say where it came from.
   --
   --  @return Processor seconds used by this process and its tasks, or zero.
   function Processor_Seconds return Long_Float;

   --  The load above which a figure is not worth publishing.
   --
   --  One and a half rather than one: a machine with nothing on it still
   --  shows the last minute of whatever ran before, and refusing the first
   --  run after a build would refuse most first runs.
   --
   --  Here rather than in one tool, because the rule is about figures and
   --  not about any one measurement: `tests benchmark` refused above this
   --  and `tests speed` did not, so the same machine was too busy for one
   --  set of published numbers and fine for another.
   Too_Busy : constant := 1.5;

   --  Whether a figure taken at this load is worth publishing.
   --
   --  @param Load The load average, as Now reports it, where zero means the
   --    host keeps no such number.
   --  @return True when the load is low enough, or unknown.
   function Publishable (Load : Long_Float) return Boolean
   is (Load <= Too_Busy);

   --  Whether the machine is quiet enough to take a figure on, now.
   --
   --  This is the gate every tool asks; Publishable above is one of the two
   --  ways it answers, and is kept as the plain predicate of a number
   --  because a gate that depends on the machine cannot be tested and this
   --  one can.
   --
   --  **A load average lags in both directions**, and this was written
   --  after watching it do both. It is an average over the minute behind,
   --  so a machine that went idle the instant a run finished still reads
   --  two or three for minutes: every figure here is taken in a sitting of
   --  runs back to back, so the number the gate used to read was nearly
   --  always the *previous run's own load* decaying, and what the gate did
   --  was wait for arithmetic rather than for the machine -- a six-group
   --  re-measure spent most of its half hour that way. It lags the other
   --  way too, and that is the half that mattered: with eight spinners
   --  started on this machine the average was still 1.06 three seconds
   --  later, and the gate let the run through.
   --
   --  So the question goes to the processors: what share of them was busy
   --  over a fifth of a second just now. That is what the gate always meant
   --  -- is anything else running -- and it answers about now, in a fifth
   --  of a second, in both directions.
   --
   --  The bound is the same Too_Busy either way, once as an average of
   --  runnable processes and once as a count of busy processors, which is
   --  the same quantity over different windows.
   --
   --  A host that keeps no per-processor times falls back to Publishable of
   --  the load average, and is left exactly where it was before this
   --  existed.
   --
   --  @return True when a figure taken now is worth publishing.
   function Quiet_Enough return Boolean;

   --  Wait for the machine to be quiet enough to publish a figure from.
   --
   --  Every figure retaken this week came through a loop that polled the
   --  load and started the tool when it dropped -- a shell script outside
   --  the repository, which is both the wrong language for this project and
   --  the wrong place for a thing every measurement needs. The tools refused
   --  and exited; what a caller wanted was to be told when.
   --
   --  Polled rather than waited on, because there is nothing to wait on: the
   --  load average is a number in a file that other people's work moves.
   --  Once a second is often enough for a number that is an average over a
   --  minute.
   --
   --  @param Minutes How long to keep looking. Zero looks once.
   --  @param Say Called with each load seen, so a caller can show that it is
   --    waiting rather than hung. Not called at all when the first look
   --    succeeds.
   --  @return True when the machine went quiet, False when the time ran out.
   function Wait_For_Quiet
     (Minutes : Natural;
      Say     : access procedure (Load : Long_Float) := null) return Boolean;

end Host_Load;
