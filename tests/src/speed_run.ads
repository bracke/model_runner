--  The published speed figures, taken again.
--
--  The README publishes what twelve tokens cost from a short prompt. That
--  figure named no prompt, no token count and no worker count, so nobody
--  could reproduce it -- and the fingerprint duty in
--  `docs/measured-figures.txt`, which fires when the sources behind a figure
--  change, asks for a re-measurement that there was no way to take. Running
--  the repository's own long prompt gave four times the published number,
--  which tells a reader nothing except that they guessed the input wrong.
--
--  This runs the published measurement: a prompt from a file, a token count,
--  a worker count, repeated, reporting the median. It needs a model the
--  caller already has, so it is not part of the mandatory suite and nothing
--  is downloaded; a missing file is a skip.
--
--  It reports a digest of the generated text as well as the times, because
--  the batch-size table publishes one: --batch-size is a performance control
--  and the column showing that it changes no output is the point of the
--  table. A digest that moves between batch sizes is the table's claim
--  failing, and it fails here rather than in a reader's head.
--
--  Every measurement it takes is --raw. The published figures were mixed:
--  the headline one was raw and the batch table was rendered through the
--  model's chat template, which is where its "131-token prompt" came from --
--  the file is 110 tokens and the template wraps it. Neither table said
--  which, so following one and reading the other was worth about a quarter
--  of the number. What is measured here is the engine, and the template is
--  not part of it.
--
--  It reports wall clock and the engine's own split between evaluating the
--  prompt and generating. Processor time is not among them: totalling it
--  across the worker tasks needs a host call this crate would have to bind
--  per platform, and the figure it would produce is one the operating
--  system's own timing tool already gives. The README says which command it
--  used.
--
--  Task safety: run from one task.
with Model_Runner.Backend;
with Model_Runner.Llama;
with Model_Runner.Numerics;

package Speed_Run is

   --  What several sequences cost when they are served in one pass.
   --
   --  A generated token reads every weight once, so two tokens out of one
   --  reading cost barely more than one. This opens Members sessions on one
   --  prepared model, gives each the same prompt, and then generates by
   --  rounds -- one token from each member a pass -- reporting what a token
   --  cost a member. Against the same command with one member it is what a
   --  second caller is worth, and the figure it should approach is in
   --  docs/serving-several-sequences.md.
   --
   --  Greedy, so every member says the same thing and any member differing
   --  from another is a collision rather than a sampler.
   --
   --  Task safety: run from one task.
   --
   --  @param Path Model file to serve.
   --  @param Prompt_Path File holding the prompt every member is given, or
   --    the empty string for a short one built in.
   --  @param Tokens Rounds to generate, which is tokens a member.
   --  @param Threads Workers the members share.
   --  @param Members How many sequences are served at once.
   --  @param Backend Which backend runs the products. A device runs a
   --    round's products and not its attention, which stays on the host.
   procedure Round
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Members     : Positive;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU);


   --  What one set of repetitions measured. Times are seconds.
   type Report is record
      Ran       : Boolean := False;
      Missing   : Boolean := False;
      Detail    : String (1 .. 120) := [others => ' '];
      Detail_Up : Natural := 0;

      Runs      : Natural := 0;
      Prompt    : Natural := 0;   --  prompt tokens
      Produced  : Natural := 0;   --  tokens generated

      Digest    : String (1 .. 16) := [others => '0'];

      --  What the machine was doing while this was measured: the load
      --  average, before the first run and after the last.
      --
      --  Recorded because it decides the figure. The processor column of
      --  every comparison here has moved by forty per cent between
      --  otherwise identical runs, and the only way anybody could tell one
      --  measurement from another was prose written beside it by hand. A
      --  figure that carries its own conditions can be compared with
      --  another; one that does not has to be believed.
      Load_Before : Long_Float := 0.0;
      Load_After  : Long_Float := 0.0;

      --  Processor seconds the whole run spent, which is what a worker
      --  count is really a question about: wall time says how long it took
      --  and this says what it cost. The README said this was the one
      --  number the tool could not produce and quoted the shell's timer for
      --  it, which meant the figure beside every other one here came from
      --  somewhere else and carried no load of its own.
      --  The median of the runs, taken around the same region the wall
      --  time is taken around, so the two answer about the same work.
      Processor : Duration := 0.0;

      --  What a draft model proposed and how much of it was taken, for a
      --  measurement with one. Both zero without.
      Drafted   : Natural := 0;
      Accepted  : Natural := 0;

      Wall      : Duration := 0.0;
      Evaluate  : Duration := 0.0;
      Generate  : Duration := 0.0;
      Load      : Duration := 0.0;
   end record;

   --  Take the measurement.
   --
   --  @param Path Model file the caller already has; empty or absent skips.
   --  @param Prompt_Path File holding the prompt, read whole.
   --  @param Tokens How many tokens to generate.
   --  @param Threads Worker tasks; one means the serial path.
   --  @param Batch Tokens per prefill batch, as --batch-size selects.
   --  @param Repack What to decode the weights into first, as --repack
   --    selects. The published comparison between the stored layout
   --    and the repacked one was taken by hand before this existed, which
   --    is the same gap the reference-backend ratio had.
   --  @param Cache What the session stores its context in, as --kv-cache
   --    names it. Varied here because a storage holding a quarter of the
   --    bytes is offered for what it saves, and what it saved in time was
   --    arithmetic about memory and nothing about time until this could
   --    take the figure. The published figures are taken at the default,
   --    which is the exact storage.
   --  @param Backend Which backend evaluates the model, as --backend
   --    selects. The device figures were taken by hand before this existed,
   --    which is the same gap the reference-backend ratio had and the same
   --    answer: a figure that is a command can be taken again.
   --  @param Penalty The repetition penalty, as --repeat-penalty selects.
   --    Named because the default one changes what a long prompt produces:
   --    with it, this model answers the long prompt with its
   --    end-of-sequence token and generates nothing, which measures a
   --    prompt and nothing else. A table about batching needs a token to
   --    compare.
   --  @param Draft Path to a smaller model to propose tokens, or empty for
   --    none. The figures a draft produces are a comparison -- the same run
   --    with and without -- so this exists to make both halves of it one
   --    command rather than two hand-taken numbers.
   --  @param Draft_Tokens How many that model may propose at a time.
   --  @param Repeats How many times to run, for the median.
   --  @param Budget True to report where the time went, phase by phase, on
   --    standard error as each run ends. Off by default: the clock reads it
   --    turns on are small but a run nobody asked should not pay them.
   --  @param Result What it measured.
   procedure Run
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Batch       : Positive;
      Repack      : Model_Runner.Llama.Repack_Mode;
      Cache       : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Penalty     : Model_Runner.Numerics.Real := 1.1;
      Draft       : String := "";
      Draft_Tokens : Positive := 4;
      Repeats     : Positive;
      Budget      : Boolean := False;
      Result      : out Report);

   --  The digest this tool prints, over any text.
   --
   --  Public so that a caller comparing this tool against the command it
   --  reproduces can hash the command's output the same way. Two copies of a
   --  hash are two hashes that can drift, and the whole point of such a
   --  comparison is that nothing between them differs.
   --
   --  @param Text Generated text.
   --  @return Sixteen hexadecimal digits.
   function Digest_Of (Text : String) return String;

   --  One line describing what happened.
   --
   --  @param Item Report to describe.
   --  @return Human-readable summary.
   function Summary (Item : Report) return String;

end Speed_Run;
