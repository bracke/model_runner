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
with Model_Runner.Llama;

package Speed_Run is

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
   --  @param Repeats How many times to run, for the median.
   --  @param Result What it measured.
   procedure Run
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Batch       : Positive;
      Repack      : Model_Runner.Llama.Repack_Mode;
      Repeats     : Positive;
      Result      : out Report);

   --  One line describing what happened.
   --
   --  @param Item Report to describe.
   --  @return Human-readable summary.
   function Summary (Item : Report) return String;

end Speed_Run;
