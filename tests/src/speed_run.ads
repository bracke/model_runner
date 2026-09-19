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
with Interfaces;

with Device_Clock;

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
   --    round's attention as well, up to the member count its push
   --    constants hold; past that a round attends on the host.
   --  @param Cache What each member stores its context in, as --kv-cache
   --    names it: a round of packed members attends through a kernel of
   --    its own and unpacks nothing, where a batch of one packed session
   --    unpacks a layer into the room the half-precision copy would have
   --    had. What that costs a round had never been asked.
   --  @param Budget True to report where the round's time went, phase by
   --    phase, as the single-sequence measurement does. The phases are
   --    charged to the first member's session, which for a round is where
   --    the whole round's work is counted.
   --  @param Timeline True to report what the device's own clock said
   --    each step of each sequence cost, as the single-sequence
   --    measurement does. A round's whole layer is one sequence, so the
   --    phase clock above charges all of it to one phase and this is the
   --    only instrument that says which step a round spends its time in.
   --  @param Spread True to give the members prompts of different
   --    lengths, from a fraction of the file to the whole of it, rather
   --    than the same prompt a token apart. What a round costs is set by
   --    its longest row -- the kernel sweeps to the last position any row
   --    asks for and the shorter rows mask what they may not see -- and
   --    every round measured here had every member at the same length,
   --    which is the one shape a server does not have.
   procedure Round
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Members     : Positive;
      Cache       : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Budget      : Boolean := False;
      Timeline    : Boolean := False;
      Spread      : Boolean := False);

   --  Several sessions taking turns, a token each, rather than stepped
   --  together.
   --
   --  What Round measures is a round: every member's token in one pass,
   --  which is what a server does when its callers arrive together. This
   --  measures the other shape -- callers whose turns do not line up, each
   --  asking for a token of its own -- and it is the one the device's
   --  sixteen blocks of cache are a limit on. Seventeen sessions taking
   --  turns is sixteen blocks and a session without one; more than that is
   --  a session turned out of a block for every one turned into it, and
   --  what that costs is a cache written across the bus.
   --
   --  Greedy, each session on its own answer, so a session says the same
   --  thing whatever the others do and the digest holds every turn.
   --
   --  Task safety: run from one task.
   --
   --  @param Path The model file.
   --  @param Prompt_Path The prompt every session is given, or the empty
   --    string for a short one built in.
   --  @param Tokens Turns each session takes.
   --  @param Threads Workers the sessions share.
   --  @param Sessions How many take turns.
   --  @param Context How long a context each session keeps, or zero for
   --    the model's own. Sixteen blocks of a long context is memory the
   --    device may not have, and this is how a measurement of the turns
   --    asks for less of it.
   --  @param Churn How many turns apart a session closes and a fresh one
   --    takes its place, or zero for a fixed set. What arrives asks for
   --    twice the context, then half of it, then the whole of it, and
   --    round again: twice is the arrival no gap a departure leaves can
   --    hold, which is what makes the buffer grow or the blocks pack, and
   --    half is the other half of the question -- an arrival that fits
   --    any gap going.
   --  @param Spread True to give the sessions prompts of different
   --    lengths, from a fraction of the file to the whole of it, rather
   --    than the same prompt a token apart.
   --  @param Backend Which backend runs the products.
   procedure Turns
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Sessions    : Positive;
      Context     : Natural := 0;
      Churn       : Natural := 0;
      Spread      : Boolean := False;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU);

   --  Serve several callers from one model, arriving and leaving.
   --
   --  What Round measures is the primitive: a fixed set of members stepped
   --  together for a fixed number of tokens. What this measures is the
   --  policy over it -- members with different limits, so they finish at
   --  different times and the rounds shrink, and a member admitted for every
   --  one that leaves, so the server is asked to re-form rather than to run
   --  a set it was handed.
   --
   --  @param Path The model file.
   --  @param Prompt_Path The prompt every member starts from, or the empty
   --    string for a short one built in.
   --  @param Tokens Most tokens a member may produce. The members are given
   --    limits below it as well, so that they end at different rounds.
   --  @param Threads Workers the members share.
   --  @param Members How many are served at once.
   --  @param Arrivals How many callers in all, so that Members of them are
   --    being served and the rest are waiting to take a seat.
   --  @param Backend Which backend the model runs on.
   --  @param Budget True to report where the server's time went, phase by
   --    phase, summed across the seats.
   --  @param Reuse True to let a caller keep whatever its prompt has in
   --    common with the one its seat last held. On, as the server has it;
   --    --no-reuse takes the other side of the comparison.
   procedure Serve
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Members     : Positive;
      Arrivals    : Positive;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Budget      : Boolean := False;
      Reuse       : Boolean := True);

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

      --  How warm the parts that did the work were, before and after.
      --  Negative where the host exposes no such sensor. Carried for the
      --  reason the load is: a reading on a cold part flatters by about
      --  eight per cent for one reading, and a figure that says how warm
      --  it was can be compared with the sitting before it.
      Warm_Before : Long_Float := -1.0;
      Warm_After  : Long_Float := -1.0;

      --  And what the device was clocked at while it ran, where the run was
      --  on one and the host says. The other half of the moment: a figure
      --  taken while the part held two thirds of its top state is not the
      --  same figure as one taken while it held all of it, and until this
      --  existed nothing said which had happened. See Device_Clock.
      Clock : Device_Clock.Reading;

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
   --  @param Draft_Lookup Propose those tokens out of the context instead,
   --    with no draft model: what followed the last two the last time they
   --    occurred.
   --  @param Draft_Next Propose them from the model's own block past its
   --    stack, where the file carries one, with no draft model.
   --  @param Repeats How many times to run, for the median.
   --  @param Budget True to report where the time went, phase by phase, on
   --    standard error as each run ends. Off by default: the clock reads it
   --    turns on are small but a run nobody asked should not pay them.
   --  @param Timeline True to report, on standard error after the runs,
   --    what the device's own clock said each step of each sequence cost,
   --    summed by the sequence's shape across every run. Device runs only;
   --    the sequences are waited for one by one while it is kept, so the
   --    token rate measured alongside it is a little below the published
   --    one and the report says which steps the device spent it on.
   --  @param Context Positions the session holds, as --context-size
   --    selects, or zero for the model's own. Named because a mixture
   --    model's own is forty thousand, whose cache the device counts twice,
   --    and a measurement that has to be taken on that model needs a way to
   --    ask for less.
   --  @param Device_Bytes Bytes of its own memory the device may fill with
   --    weights, as --device-memory selects, or zero for the engine's own
   --    share. Named for the same model: its stacks are eleven gigabytes,
   --    the share is less, and whether they fit decides which path a
   --    mixture takes on the device.
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
      Draft_Lookup : Boolean := False;
      Draft_Next   : Boolean := False;
      Repeats     : Positive;
      Budget      : Boolean := False;
      Timeline    : Boolean := False;
      Context     : Natural := 0;
      Device_Bytes : Interfaces.Unsigned_64 := 0;
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
