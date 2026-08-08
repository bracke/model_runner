--  Validation against a model the user supplies.
--
--  Nothing is downloaded and no model is committed to this repository. The
--  runner is pointed at a file that already exists on the machine and reports
--  what the engine makes of it. A missing file is a skip, not a failure, so
--  this can never become a mandatory test that only passes on one machine.
--
--  What it checks, in order, stopping at the first failure:
--
--    the container parses and validates
--    the architecture and tokenizer are within the supported profile
--    a session allocates at the requested context
--    greedy generation runs and produces valid UTF-8
--    the same seed produces the same tokens twice
--    the worker count does not change the result
--    where an expectation file is supplied, the tokenization, the greedy
--    output and any recorded logits match what a trusted reference runtime
--    produced for the same model
--
--  That last check is what turns "it produced plausible text" into evidence.
--  Without an expectation file the runner still validates everything else and
--  says plainly that no reference comparison was made, rather than implying
--  one.
--
--  Task safety: a run uses one task.
package External_Model is

   --  How a run ended.
   type Outcome is
     (Skipped,        --  no file at the given path
      Rejected,       --  the engine declined the model, with a reason
      Ran,            --  generation worked and every check passed
      Failed);        --  a check did not hold

   --  What a run found.
   type Report is record
      Result        : Outcome := Skipped;
      Prompt_Tokens : Natural := 0;
      Generated     : Natural := 0;
      Deterministic : Boolean := False;
      --  Whether varying the worker count was tried, and what it found. A
      --  run with one worker cannot try it, and saying so beats reporting a
      --  check that never ran as one that held.
      Thread_Checked : Boolean := False;
      Thread_Stable  : Boolean := False;
      Compared      : Natural := 0;
      Worst_Gap     : Long_Float := 0.0;
      Reference_Run : Boolean := False;
      Tokens_Match  : Boolean := False;
      Greedy_Match  : Boolean := False;
      Text_Match    : Boolean := False;
      Detail        : String (1 .. 256) := [others => ' '];
      Detail_Last   : Natural := 0;
   end record;

   --  Run every check against a model file.
   --
   --  @param Path Model file to validate.
   --  @param Prompt Prompt to generate from.
   --  @param Tokens Number of tokens to generate.
   --  @param Threads Worker count for the second generation pass.
   --  @param Expect Path to an expectation file recorded from a trusted
   --    reference runtime, or an empty string for no comparison. When present,
   --    its prompt overrides the Prompt argument so that both sides see the
   --    same input.
   --  @param Result What the run found.
   procedure Run
     (Path    : String;
      Prompt  : String;
      Tokens  : Positive;
      Threads : Positive;
      Expect  : String := "";
      Result  : out Report);

   --  Human-readable detail from a run.
   --
   --  @param Item Report to read.
   --  @return Detail text, or an empty string.
   function Detail_Text (Item : Report) return String
   is (Item.Detail (1 .. Item.Detail_Last));

   --  The one-line summary of a run, as the runner prints it.
   --
   --  Here rather than at the call site because the README publishes it, and
   --  a test replays a run and compares. Two copies of this format would let
   --  the published one agree with a copy while disagreeing with the runner.
   --
   --  @param Item Report to describe.
   --  @return Summary line, without a trailing newline.
   function Summary (Item : Report) return String;

end External_Model;
