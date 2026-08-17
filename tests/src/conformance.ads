--  Conformance of the engine against the independent reference.
--
--  The engine and Reference_Transformer compute the same logits by different
--  routes, in different arithmetic. Agreement between them is the strongest
--  correctness evidence available without an external model, because a shared
--  mistake would have to be made twice, differently.
--
--  Tolerance. The engine stores weights as binary32 and accumulates
--  length-dependent reductions in binary64; the reference computes entirely in
--  binary64. The two therefore agree closely but not bit for bit, and the
--  comparison is relative with an absolute floor for logits near zero.
--
--  Task safety: a run uses one task.
package Conformance is

   --  Largest accepted relative difference between an engine logit and the
   --  reference logit for the same token.
   Relative_Tolerance : constant := 1.0E-3;

   --  Absolute floor, so that a logit near zero is not judged by a relative
   --  difference that has no meaning there.
   Absolute_Tolerance : constant := 1.0E-4;

   --  What repacking to brain floats is allowed to move a logit by.
   --
   --  A brain float keeps eight mantissa bits where binary32 keeps
   --  twenty-three, so a weight rounded into one carries about a thousandth
   --  of relative error, and a matrix product over thousands of them
   --  accumulates. It is the one lossy thing this program does, and it had
   --  no number attached to it: the README said it "can change what the
   --  model says" and reported that the text happened not to change, which
   --  is an anecdote. These are what the comparison measured, rounded up to
   --  the next round figure.
   --  Raised from 1.0E-1 when the three-bit superblock arrived: its weights
   --  are the coarsest here, so rounding them again into eight mantissa bits
   --  moves a logit furthest. It read 0.254 then and 0.137 once the widest
   --  fixtures were narrowed, which is a reminder that the figure describes
   --  the fixture as much as the flag. The bound is what has been measured,
   --  rounded up, and left there rather than tightened after every change.
   Lossy_Relative_Tolerance : constant := 5.0E-2;
   Lossy_Absolute_Tolerance : constant := 3.0E-1;

   --  What storing the context in half precision is allowed to move a logit
   --  by. A binary16 keeps ten mantissa bits where binary32 keeps
   --  twenty-three, and what is rounded is not a weight but a key or a value
   --  that attention reads back, so the error enters once per position
   --  rather than once per product. Measured over this sweep and rounded up,
   --  as the repacking bound was.
   Cached_Relative_Tolerance : constant := 5.0E-2;
   Cached_Absolute_Tolerance : constant := 1.0E-1;

   --  And what storing it in one byte an element is allowed to move a logit
   --  by. A byte with a scale for its row keeps about seven bits of a
   --  number where a binary16 keeps eleven, and what is rounded is a key or
   --  a value that attention reads back at every later position -- so this
   --  is the loosest bound here by some way. Measured over this sweep and
   --  rounded up, as the two above were.
   Eighth_Relative_Tolerance : constant := 5.0E-2;
   Eighth_Absolute_Tolerance : constant := 4.0E-1;

   --  What a comparison found.
   type Report is record
      Sequences  : Natural := 0;
      Compared   : Natural := 0;
      Worst_Abs  : Long_Float := 0.0;
      Worst_Rel  : Long_Float := 0.0;

      --  The same, for the comparisons where the weights were rounded into
      --  brain floats. Kept apart because mixing them would let the lossy
      --  path's error hide the exact path's.
      Lossy_Compared  : Natural := 0;
      Lossy_Worst_Abs : Long_Float := 0.0;
      Lossy_Worst_Rel : Long_Float := 0.0;

      --  And again for the comparisons where the session stored what it had
      --  committed in half precision. A third bucket rather than a share of
      --  the second, because rounding the weights and rounding the context
      --  are different things to have measured: one is decided at load and
      --  affects every product, the other is decided per session and affects
      --  what attention reads back.
      Cached_Compared  : Natural := 0;
      Cached_Worst_Abs : Long_Float := 0.0;
      Cached_Worst_Rel : Long_Float := 0.0;

      Failures   : Natural := 0;

      --  Comparisons whose evaluation ended in a diagnostic rather than in
      --  logits. These used to be passed over in silence: the sequence was
      --  not counted, nothing was compared, and the only trace was that the
      --  total came up short against what the sweep expected to run. Three
      --  hundred of them hid a null buffer in a new architecture for an
      --  afternoon, so they are counted and reported now, and a run with
      --  any of them is not clean.
      Refused    : Natural := 0;

      --  Fixtures the independent implementation would not load or would not
      --  run. A comparison whose reference has no answer returns before it
      --  compares anything, so an architecture the reference could not read
      --  was skipped in silence and the totals came out to the digit of a
      --  run without it -- which is how an architecture's first sweep
      --  reported the figures of the sweep before it, and read as a pass.
      --  The same, for the comparisons where the context was stored in one
      --  byte an element. Kept apart from the halved ones for the reason
      --  those are kept apart from the exact ones: one bound must not be
      --  read as evidence for another.
      Eighth_Compared  : Natural := 0;
      Eighth_Worst_Abs : Long_Float := 0.0;
      Eighth_Worst_Rel : Long_Float := 0.0;

      --  Where the sweep's time goes, in seconds. Building fixtures,
      --  loading and running the independent implementation, and everything
      --  else -- which is the engine loading each fixture and evaluating it.
      --  Measured because the sweep is most of the gate and nobody knew
      --  which part of it was most of the sweep.
      Built      : Duration := 0.0;
      Learned    : Duration := 0.0;
      Evaluated  : Duration := 0.0;

      Unlearned  : Natural := 0;

      --  Sequences the sweep's own arithmetic says it should have run. Kept
      --  so that a run which came up short can say by how much: "compared
      --  nothing" was all the gate could report, whatever the shortfall.
      Wanted     : Natural := 0;
      Ran        : Boolean := False;
   end record;

   --  Report whether every compared logit was within tolerance.
   --
   --  @param Item Report to classify.
   --  @return True when the run completed and nothing exceeded tolerance.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Ran and then Item.Failures = 0 and then Item.Refused = 0
       and then Item.Unlearned = 0);

   --  Compare the engine against the reference on the synthetic model.
   --
   --  Several token sequences of different lengths are evaluated, so that the
   --  comparison covers a single token, a short context and a context long
   --  enough to exercise attention over several past positions.
   --
   --  @param Result Totals, including the worst differences observed.
   procedure Run (Result : out Report);

end Conformance;
