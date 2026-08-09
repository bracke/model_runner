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
   Lossy_Relative_Tolerance : constant := 5.0E-2;
   Lossy_Absolute_Tolerance : constant := 1.0E-1;

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

      Failures   : Natural := 0;
      Ran        : Boolean := False;
   end record;

   --  Report whether every compared logit was within tolerance.
   --
   --  @param Item Report to classify.
   --  @return True when the run completed and nothing exceeded tolerance.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Ran and then Item.Failures = 0);

   --  Compare the engine against the reference on the synthetic model.
   --
   --  Several token sequences of different lengths are evaluated, so that the
   --  comparison covers a single token, a short context and a context long
   --  enough to exercise attention over several past positions.
   --
   --  @param Result Totals, including the worst differences observed.
   procedure Run (Result : out Report);

end Conformance;
