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
with Model_Runner.Backend;
with Model_Runner.Llama;

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

      --  The pooled embedding, where the recording carries one. Counted
      --  apart from the logits because it answers a different question: a
      --  logit is the last position's state through one more matrix, and
      --  this is every position's before that matrix, pooled.
      Components    : Natural := 0;
      Worst_Component : Long_Float := 0.0;
      Cosine        : Long_Float := 0.0;
      Reference_Run : Boolean := False;
      --  Whether the same model was run again without repacking, and
      --  whether it produced the same text. Only a model of a useful size
      --  answers what rounding to brain floats does; the conformance figure
      --  is taken on a fixture eight wide and two deep.
      Repack_Checked : Boolean := False;
      Repack_Match   : Boolean := False;

      --  Whether the model was run again with a draft proposing for it, and
      --  whether that produced the same text. A drafted run that differs is
      --  a fault in the checking, not a difference of opinion between two
      --  models: every proposal is checked by this one.
      Draft_Checked  : Boolean := False;
      Draft_Match    : Boolean := False;
      Draft_Proposed : Natural := 0;
      Draft_Accepted : Natural := 0;

      --  Which backend ran it, and whether that backend partitions rows.
      --  A backend that does not cannot be asked whether the worker count
      --  changes its answer, and reporting an unrun check as a held one is
      --  the failure this pair exists to prevent.
      Backend        : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Partitions     : Boolean := True;

      Tokens_Match  : Boolean := False;
      Greedy_Match  : Boolean := False;
      Text_Match    : Boolean := False;
      --  A digest of the greedy text, in the same shape `tests speed`
      --  prints, so that what this runner generated can be compared with
      --  what the command generates from the same inputs.
      Digest        : String (1 .. 16) := [others => '0'];

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
   --  @param Backend Which backend evaluates the model, as --backend
   --    selects. A device is opened before the model loads and released
   --    after, and a machine without one is a skip rather than a failure:
   --    this runner exists to be pointed at a caller's own machine, and
   --    refusing there for want of hardware would make it a test that only
   --    passes in one place.
   --  @param Draft Path to a smaller model to propose tokens for this one to
   --    check, or empty for none. What it validates is the claim drafting
   --    makes: that a drafted run produces exactly what the same run
   --    produces without a draft. On a caller's own model, which is the only
   --    place that claim can be checked against a model anybody cares about.
   --  @param Draft_Tokens How many that model may propose at a time.
   --  @param Repack What to decode the weights into first. The conformance
   --    figures for repacking are taken on fixtures at most 256 wide and two
   --    deep; what rounding does to a model of a useful size is a question
   --    only a model of a useful size answers, and this is where somebody
   --    with one can ask it. Given a mode, the model is run again without
   --    repacking and the two texts are compared.
   --  @param Result What the run found.
   procedure Run
     (Path    : String;
      Prompt  : String;
      Tokens  : Positive;
      Threads : Positive;
      Expect  : String := "";
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Draft   : String := "";
      Draft_Tokens : Positive := 4;
      Repack  : Model_Runner.Llama.Repack_Mode :=
        Model_Runner.Llama.No_Repack;
      Result  : out Report);

   --  Human-readable detail from a run.
   --
   --  @param Item Report to read.
   --  @return Detail text, or an empty string.
   function Detail_Text (Item : Report) return String
   is (Item.Detail (1 .. Item.Detail_Last));

   --  No load average here, unlike the tools that publish timings. This
   --  reports counts and answers -- whether the text matched, whether the
   --  worker count changed it -- and none of them depends on what else the
   --  machine was doing. A line that carried a load would also be a line
   --  that differs between two runs of the same check, which is exactly what
   --  the published transcripts are compared against.
   --
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
