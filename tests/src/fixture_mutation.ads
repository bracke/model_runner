--  Whether a fixture can fail at all.
--
--  A comparison is only worth what its fixture is worth. If a fixture writes
--  a tensor the engine never reads, that tensor's contents are free: the
--  sweep would agree with the reference just as well if they were nonsense,
--  and a reader that took them by mistake would disagree with a reader that
--  did not for reasons no comparison could name. That is not hypothetical.
--  The falcon fixture wrote its queries, keys and values fused into one
--  tensor and then wrote separate key and value tensors beside them, because
--  the guard that skipped those named an architecture rather than naming the
--  arrangement. The file said two different things about one projection, and
--  every logit disagreed.
--
--  So each tensor is moved and the model is evaluated again. A tensor
--  something reads changes the answer; a tensor nothing reads does not, and
--  that is what this reports. It is a check on the fixtures rather than on
--  the engine: a failure here says the sweep is weaker than it looks, not
--  that the arithmetic is wrong.
--
--  Every element of a tensor is moved rather than one of them, because a
--  single element may sit in a row no short sequence reaches -- an embedding
--  row for a token the prompt does not use answers to nothing, and would
--  read as an unread tensor if it were the element chosen.
--
--  Task safety: a run uses one task.
package Fixture_Mutation is

   --  How far each element is moved. Large enough that no logit can stay
   --  inside the comparison's own tolerance by arithmetic accident, and
   --  small enough that a quantized fixture still encodes it rather than
   --  saturating.
   Displacement : constant := 0.25;

   --  A logit has moved when it moves by more than this.
   --
   --  Just above what binary32 arithmetic does on its own, and deliberately
   --  far below anything a comparison would call a disagreement. An
   --  evaluation here is deterministic -- one task, one partitioning, the
   --  same input -- so a logit that differs at all differs because the model
   --  did, and that is the whole of the question this asks.
   --
   --  It was the conformance sweep's absolute tolerance, 1.0E-4, which
   --  conflated two questions: whether the program reads a tensor, and
   --  whether that sweep would catch a mistake in it. The second is what
   --  Faint below counts. Reading the first as the second hid six tensors of
   --  gemma3's sixth block, whose logits moved by two parts in a hundred
   --  thousand -- eleven orders of magnitude above the noise, and reported as
   --  read by nobody.
   Noticed : constant := 1.0E-9;

   --  What a run found.
   type Report is record
      --  Tensors moved, across every architecture.
      Examined : Natural := 0;

      --  Of those, the ones no logit answered to.
      Unread   : Natural := 0;

      --  And the ones that answered only to a move sixteen times the size.
      --  Read, so not a failure, but worth a count: a tensor a fixture makes
      --  this insensitive to is one that fixture's comparisons would not
      --  notice a small mistake in. It read twenty-nine while the deep
      --  fixture's attention was saturated, and reads zero now that the
      --  queries and keys it draws are drawn to suit its width.
      Faint    : Natural := 0;

      --  Fixtures that could not be built, parsed or evaluated at all. A
      --  run that cannot evaluate its own fixture has not checked anything,
      --  and saying so is the point of counting it separately from a tensor
      --  that read as unused.
      Refused  : Natural := 0;
   end record;

   --  Whether a run found nothing to report.
   --
   --  @param Item Report to judge.
   --  @return True when every tensor was read and nothing was refused.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Unread = 0 and then Item.Refused = 0
       and then Item.Examined > 0);

   --  Move every tensor of every architecture's fixture in turn and record
   --  which ones no logit answered to.
   --
   --  @param Result What the run found.
   --  @param Say    Called with a line naming each tensor nothing answered
   --                to, or null to report only the counts. The package does
   --                no output of its own: what a run says and where it says
   --                it belongs to whatever asked for the run.
   procedure Run
     (Result : out Report;
      Say    : access procedure (Line : String) := null);

end Fixture_Mutation;
