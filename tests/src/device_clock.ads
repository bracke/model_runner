--  What the device was clocked at while a figure was taken.
--
--  A timing on a device is a fact about a machine at a moment, and this is
--  the half of the moment that was missing. Every device figure in
--  docs/measured-figures.txt carries the load and the temperature; none of
--  them carried the clock, and on 2026-09-04 that cost a sitting: the same
--  binary read a 1419-token prompt at 0.829 s in the morning and 1.155 s in
--  the evening, on a quiet machine and a part at 58 C, and the difference
--  was a clock that swung between 800 and 2700 MHz and spent a third of the
--  prompt at the bottom of that range.
--
--  A prompt is a long dispatch and a generated token is not, which is why
--  that afternoon moved the prompt rows and left the generating ones alone.
--  A figure that says what the part was clocked at can be compared with
--  another; one that does not has to be believed.
--
--  This reads what the host offers about an AMD device through the kernel's
--  own files. A host that offers nothing says so, and a figure taken there
--  is exactly where it was before this existed.
--
--  Task safety: the reader is a function of two files and holds no state.
--  The watcher below is a task and is used by one caller at a time.
package Device_Clock is

   --  What a device did while something was measured.
   --
   --  Seen is False where the host keeps no such numbers, which is not the
   --  same as a device that stood still: zero samples is unknown and a mean
   --  of nothing is not a slow part.
   type Reading is record
      Seen    : Boolean := False;
      Samples : Natural := 0;

      --  Megahertz: the mean over the samples, the lowest and highest seen,
      --  and the highest state the part offers.
      Mean    : Natural := 0;
      Least   : Natural := 0;
      Most    : Natural := 0;
      Top     : Natural := 0;

      --  What the part drew, averaged over the samples, in watts. Zero
      --  where the host does not say. It is here because the clock is a
      --  symptom and the power budget is usually the cause: an integrated
      --  part shares fifteen watts with the processor it is helping.
      Watts   : Long_Float := 0.0;
   end record;

   --  Whether this host says anything about a device's clock at all.
   --
   --  @return True where the numbers are there to read.
   function Offered return Boolean;

   --  One look, for a caller that wants the state rather than a run's worth
   --  of it.
   --
   --  @return A reading of one sample, or one with Seen False.
   function Look return Reading;

   --  Reported and not gated on, which is a decision this took a
   --  measurement to make.
   --
   --  The load has a bound and refusing above it is right, because a busy
   --  machine is a busy machine whatever is being measured. A clock has no
   --  such bound: on this host a 1419-token prompt holds 1705 MHz of 2700
   --  and a 110-token prompt holds 949, never reaching half -- and the
   --  short one is a published figure the README keeps deliberately, under
   --  `### A prompt too short to wake the machine`. A threshold that
   --  refused it would refuse the very row it explains.
   --
   --  So this says what the part held and leaves the reader to compare like
   --  with like, which is what the load and the temperature beside it do.
   --  What it ends is a class of confusion rather than a class of figure:
   --  the same binary read the same file forty per cent apart in one day,
   --  and neither reading said why.

   --  A reading as a figure should carry it.
   --
   --  @param Of_Reading What was seen.
   --  @return A phrase for the summary line, or the empty string where the
   --    host said nothing.
   function Shown (Of_Reading : Reading) return String;

   --  Watch the device while something else runs.
   --
   --  A single look says nothing here: the clock moves between one dispatch
   --  and the next, and what a figure wants is what the part held over the
   --  run. Started and stopped around the same region the wall time is
   --  taken around, so the two answer about the same work.
   task type Watcher is
      --  Begin. Said once, and said whether to sample at all: a watcher
      --  that is not wanted still has to be told, because a task nobody
      --  starts is a block nobody leaves.
      --
      --  @param Watching False to sample nothing, which is what a run on a
      --    processor wants: a hundred reads a second of the kernel's files
      --    is little, and little is not nothing on a machine whose figure
      --    is what is being taken.
      entry Start (Watching : Boolean);

      --  Stop, and give back what was seen.
      entry Stop (Got : out Reading);
   end Watcher;

end Device_Clock;
