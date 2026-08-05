with Interfaces;

--  GGUF mutation fuzzing.
--
--  A valid synthetic container is mutated and fed to the parser. The parser is
--  allowed exactly four outcomes, and anything else is a defect:
--
--    accepted        the mutation happened to produce a valid file
--    rejected        a structured diagnostic
--    resource limit  a structured limit diagnostic
--    cancelled       an explicit cancellation
--
--  Unacceptable outcomes are an escaped exception, a deadlock, an unbounded
--  allocation, an out-of-bounds access, or an invalid model accepted into an
--  executable state. The first is detected directly; the parser's own limits
--  bound the rest, and a wall-clock bound catches a loop that fails to
--  terminate.
--
--  Reproducibility. Every case is derived from the run seed and the case
--  number alone, so a reported failure can be replayed with the same
--  `--seed` and `--cases`.
--
--  Task safety: a run uses one task.
package Fuzzing is

   --  What one mutated case produced.
   type Outcome is
     (Accepted,
      Rejected,
      Resource_Limited,
      Escaped_Exception,
      Accepted_But_Invalid);

   --  Totals for a run.
   type Report is record
      Cases     : Natural := 0;
      Accepted  : Natural := 0;
      Rejected  : Natural := 0;
      Bounded   : Natural := 0;
      Escaped   : Natural := 0;
      Invalid   : Natural := 0;
      First_Bad : Natural := 0;
   end record;

   --  Report whether a run found only acceptable outcomes.
   --
   --  @param Item Report to classify.
   --  @return True when nothing escaped and nothing invalid was accepted.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Escaped = 0 and then Item.Invalid = 0);

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
