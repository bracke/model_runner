with Interfaces;

--  GGUF mutation fuzzing.
--
--  A valid synthetic container is mutated and fed to the whole path: the
--  parser, then the tokenizer, then the chat-template compiler, then model
--  preparation, and then a forward pass over the mutated weights.
--
--  The forward pass matters most. It is where the quantization kernels run,
--  and those are the one place in this project that suppresses index, range
--  and overflow checks -- the place SECURITY.md names as where a validation
--  mistake would become memory unsafety rather than a clean Constraint_Error.
--  Weight bytes are among the bytes being mutated, and until now nothing
--  drove them through those loops.
--
--  Half the cases therefore work on a model of quantized weights and half on
--  binary32. Those loops exist only on the quantized path, so a campaign that
--  always used the binary32 fixture ran the forward pass down a path where
--  every check is still in force -- it drove the arithmetic but not the part
--  the suppression makes dangerous. Which half a case falls in comes from its
--  number, so a failure still replays from its seed and case alone. Stopping at the parser left the campaign short of the gate its
--  own contract names -- an invalid model must not reach an executable state
--  -- and left the template compiler, which is the most program-like thing a
--  file carries, never driven by a mutated template at all.
--
--  The load path is allowed exactly four outcomes, and anything else is a
--  defect:
--
--    accepted        the mutation happened to produce a valid file
--    rejected        a structured diagnostic
--    resource limit  a structured limit diagnostic
--    cancelled       an explicit cancellation
--
--  A case that runs past Case_Time_Limit is reported. That catches a stage
--  which stops making progress; a stage that never returns at all cannot be
--  interrupted from the one task a run uses, and is caught by whatever bounds
--  the run from outside.
--
--  Unacceptable outcomes are an escaped exception, a deadlock, an unbounded
--  allocation, an out-of-bounds access, or an invalid model accepted into an
--  executable state. The first is detected directly; the limits carried
--  through every stage bound the rest, and a wall-clock bound catches a loop
--  that fails to terminate.
--
--  Preparation is what makes a case expensive: it allocates the tensor arena
--  and reads the weights, so a campaign costs roughly ten times what parsing
--  alone cost. The case count is the knob; the coverage is worth the seconds.
--
--  Reproducibility. Every case is derived from the run seed and the case
--  number alone, so a reported failure can be replayed with the same
--  `--seed` and `--cases`.
--
--  Task safety: a run uses one task.
package Fuzzing is

   --  Longest one case may take. A case works on a container of a few
   --  kilobytes, so anything approaching this is not slow, it is a loop that
   --  has stopped making progress -- the chat-template engine's own bound is
   --  what stands between a nested loop and a render that never ends.
   Case_Time_Limit : constant Duration := 5.0;

   --  What one mutated case produced.
   type Outcome is
     (Accepted,
      Rejected,
      Resource_Limited,
      Escaped_Exception,
      Accepted_But_Invalid,
      Took_Too_Long);

   --  Totals for a run.
   type Report is record
      Cases     : Natural := 0;
      Accepted  : Natural := 0;
      Rejected  : Natural := 0;
      Bounded   : Natural := 0;
      Escaped   : Natural := 0;
      Invalid   : Natural := 0;
      Slow      : Natural := 0;
      First_Bad : Natural := 0;
   end record;

   --  Report whether a run found only acceptable outcomes.
   --
   --  @param Item Report to classify.
   --  @return True when nothing escaped, nothing invalid was accepted and no
   --    case ran past the time limit.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Escaped = 0 and then Item.Invalid = 0 and then Item.Slow = 0);

   --  Run one mutated case.
   --
   --  @param Seed Run seed.
   --  @param Case_Number Case index within the run.
   --  @return What the parser did with the mutated bytes.
   function Run_Case
     (Seed        : Interfaces.Unsigned_64;
      Case_Number : Positive) return Outcome;

   --  Run a whole campaign.
   --
   --  @param Seed Run seed.
   --  @param Cases Number of cases to run.
   --  @param Result Totals, including the first offending case number.
   procedure Run
     (Seed   : Interfaces.Unsigned_64;
      Cases  : Positive;
      Result : out Report);

end Fuzzing;
