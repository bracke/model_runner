with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Clocks;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Output;
with Model_Runner.Progress;
with Model_Runner.Numerics;
with Model_Runner.Sampling;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Grammar;
with Model_Runner.Stops;

--  Generation coordination.
--
--  This package runs the loop that turns a rendered prompt into streamed text:
--  tokenize, validate the context budget, prefill, then repeatedly sample,
--  check stop conditions, evaluate, decode and emit.
--
--  Output discipline. Nothing here writes to standard output or standard
--  error. Generated text goes to an Output.Sink and progress goes to a
--  Progress.Observer; the caller decides what either of those does. Text
--  written to the sink is passed through exactly as the tokenizer decoded it:
--  no styling, no localization, no trimming, no wrapping, nothing appended.
--
--  Immutability. A Request is a value. It is read at the start of Generate and
--  never consulted again in a way that would let a change mid-run alter
--  behaviour.
--
--  Task safety: Generate runs on the calling task and takes exclusive use of
--  the session for its duration.
package Model_Runner.Generation is

   subtype Token_Id is Model_Runner.Llama.Token_Id;
   subtype Seed_Value is Model_Runner.Entropy.Seed_Value;

   --  Why generation stopped. Every run ends with exactly one of these.
   type Completion_Reason is
     (End_Of_Sequence,
      Stop_Token,
      Stop_String,
      Maximum_Tokens,
      Context_Full,
      Cancelled,
      Output_Closed,
      Runtime_Error);

   --  Somewhere for per-token explanations to go.
   --
   --  An interface rather than a callback record, and separate from the text
   --  sink, because the two answer to different destinations: the text is
   --  what the program produced and the explanation is a report about it.
   --  A caller wanting neither passes null and pays for nothing.
   type Explainer is limited interface;

   --  Receive what the model made of one position.
   --
   --  @param Item Explainer to write through.
   --  @param Report The position, as probabilities.
   procedure Explain
     (Item   : in out Explainer;
      Report : Model_Runner.Sampling.Explanation) is abstract;

   --  A reference to whatever is receiving the explanations.
   type Explainer_Reference is access all Explainer'Class;

   --  What to generate and how.
   type Request is record
      --  Largest number of tokens to produce. Must be greater than zero.
      Max_Tokens : Natural := 256;

      --  Validated sampling configuration.
      Sampling : Model_Runner.Sampling.Configuration;

      --  Tokens the caller wants nudged, and by how much. Applied before
      --  everything else the sampler does, on the greedy path as well as the
      --  probabilistic one.
      Bias_Tokens  : Model_Runner.Sampling.Token_List
        (1 .. Model_Runner.Sampling.Max_Biases) :=
          [others => Model_Runner.Tokenizer.No_Token];
      Bias_Amounts : Model_Runner.Numerics.Real_List
        (1 .. Model_Runner.Sampling.Max_Biases) := [others => 0.0];
      Bias_Count   : Natural := 0;

      --  How many alternatives to report for each generated token, or zero
      --  for no reporting at all. The chosen token is reported whenever this
      --  is above zero, whether or not it is among the alternatives.
      Logprobs : Natural := 0;

      --  How many of the oldest positions to drop when the context fills,
      --  or zero to stop there instead.
      --
      --  A run that stops for want of room has stopped for want of room and
      --  not for want of anything to say. With this set, the session drops
      --  that many positions after the ones kept below, slides the rest
      --  down, and carries on -- so a long run costs the beginning of its
      --  own context rather than ending.
      --
      --  What it loses is what it drops. The model cannot attend to those
      --  tokens again and a question about them is answered from what is
      --  left, which is why this is off unless a caller asks for it.
      Context_Shift : Natural := 0;

      --  How many positions at the front to keep when shifting: the
      --  beginning-of-text marker, and whatever else must not go.
      Context_Keep : Natural := 1;

      --  How many tokens a draft model may propose at a time, or zero for no
      --  drafting. Reached only when Generate is given a draft model and a
      --  session on it.
      --
      --  What drafting buys is that a batch of proposals costs one pass over
      --  the target's weights where the same tokens one at a time cost one
      --  each -- so a draft that guesses well turns several tokens into the
      --  price of one. What it costs is the draft model's own passes, which
      --  is why the draft has to be much the smaller of the two for this to
      --  be worth anything.
      --
      --  Only at temperature zero, and only without a grammar. Both
      --  restrictions are about being able to say what this produces: at
      --  temperature zero a proposal is either what the target would have
      --  chosen or it is not, so accepting the ones that match gives exactly
      --  the text the target would have produced alone. Above it, keeping
      --  that guarantee needs an acceptance test written against the
      --  sampler's own distribution, which this does not have.
      Draft_Tokens : Natural := 0;

      --  Propose those tokens from the context rather than from a model.
      --
      --  What followed the last two tokens the last time they occurred, for
      --  as many tokens as Draft_Tokens asks for. It costs no second model,
      --  no memory and no pass of anything: the proposal is a search over
      --  the tokens this run has already read. See Model_Runner.Lookup for
      --  what it is worth and what it is not.
      --
      --  A draft model, where one is given, is the better guesser and wins
      --  this. Both at once is a caller asking for two things and getting
      --  one, so the command refuses that pair rather than choosing for it.
      Draft_From_Context : Boolean := False;

      --  Propose those tokens from the model's own block past its stack,
      --  where the file carries one: a model trained to draft the token
      --  after the next, run once a proposal from the stack's last state
      --  and chained on its own answer for the ones after. No second
      --  model and no search; the same round of checking as the other
      --  two, and the same text as without. A draft model given as well
      --  wins this, as it wins the context.
      Draft_From_Next : Boolean := False;

      --  Explicit seed. When Has_Seed is False the seed comes from the entropy
      --  source, and the value actually used is reported in the result.
      Seed     : Seed_Value := 0;
      Has_Seed : Boolean := False;

      --  Prepend the tokenizer's beginning-of-sequence token to the prompt.
      Add_Beginning : Boolean := True;

      --  Keep a copy of the generated text in the result. Bounded by
      --  Max_Retained_Bytes; text beyond that is streamed but not retained.
      Retain_Text : Boolean := False;

      --  Prompt tokens evaluated in one pass over the weights. Larger
      --  batches make prefill faster and hold more activations at once; the
      --  engine caps it at Llama.Max_Batch whatever is asked for. It also
      --  sets how often cancellation is observed and progress reported.
      --
      --  The cap, because that is what measured fastest on both backends and
      --  because on the device it is not close. A 110-token prompt there
      --  reads 2.767 s at a batch of eight, 1.973 s at thirty-two and
      --  1.054 s at a hundred and twenty-eight, on the same weights and the
      --  same number of passes over them -- what changes is how many times
      --  the host tells the device to do something, and telling it costs
      --  more than this program had assumed. On the processor the same sweep
      --  reads 1.899 s at thirty-two and 1.730 s at the cap.
      --
      --  What it costs is how often a run can be cancelled and how often it
      --  reports progress while reading a prompt: five hundred and twelve
      --  tokens rather than thirty-two, which on this model is about half a
      --  second of wall on the device and four on the processor. A caller
      --  who wants a finer grain than that asks for a smaller batch and pays
      --  for it in prefill -- a batch is one pass over the weights, so four
      --  batches of a hundred and twenty-eight read them four times where
      --  one of five hundred and twelve reads them once.
      Batch_Size : Natural := 512;

      --  Reuse the session's committed context when the tokenized prompt is
      --  an exact prefix extension of it, and re-evaluate only the new
      --  suffix. When the sequences diverge the session is reset and the whole
      --  prompt is re-evaluated, so the cache never describes a conversation
      --  that differs from the one being rendered.
      Reuse_Committed_Prefix : Boolean := False;
   end record;

   --  What a run produced.
   --
   --  Release the result with Release when Retain_Text was requested.
   type Result is record
      Reason           : Completion_Reason := Runtime_Error;
      Prompt_Tokens    : Natural := 0;
      Generated_Tokens : Natural := 0;
      Final_Position   : Natural := 0;
      Seed             : Seed_Value := 0;
      Prefill_Ns       : Model_Runner.Clocks.Nanoseconds := 0;
      Decode_Ns        : Model_Runner.Clocks.Nanoseconds := 0;
      Prefill_Rate     : Long_Float := 0.0;
      Decode_Rate      : Long_Float := 0.0;
      Peak_Bytes       : Interfaces.Unsigned_64 := 0;

      --  Which backend evaluated this run, and how many worker tasks it had.
      --  Reported rather than derived by the caller: the caller asked for a
      --  backend and a thread count, and what it asked for is not always what
      --  it got -- a backend that does not run in parallel takes one worker
      --  whatever --threads said. A run that cannot be told apart from a run
      --  on the other backend is a run whose figures mean nothing.
      Backend          : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Workers          : Positive := 1;

      --  Whether the weights this run read were the model file's own pages
      --  or a copy of them. It is the difference between a load that costs
      --  nothing and one that costs the whole file, and between a resident
      --  set the size of what was touched and one the size of the model, so
      --  a reader comparing two runs wants to know which they are looking
      --  at.
      Weights_Mapped   : Boolean := False;

      --  How many tokens a draft model proposed and how many of those the
      --  real one agreed with. Both zero without a draft.
      --
      --  Reported because it is the only number that says whether a draft is
      --  worth having. A draft that guesses well turns several tokens into
      --  the price of one; a draft that guesses badly costs its own passes
      --  and buys nothing, and the two are indistinguishable from the text.
      Drafted          : Natural := 0;
      Accepted         : Natural := 0;

      --  How many times the context was shifted to make room. Zero for a run
      --  that never filled it, and the number of times the beginning of the
      --  conversation was dropped for one that did.
      Shifted          : Natural := 0;
      Text             : Model_Runner.Bytes.Byte_Array_Access := null;
      Text_Length      : Natural := 0;
      Error            : Model_Runner.Errors.Error_Info;
   end record;

   --  Release the retained text of a result. Idempotent.
   --
   --  @param Item Result to release.
   procedure Release (Item : in out Result);

   --  Retained generated text.
   --
   --  @param Item Result to read.
   --  @return Retained text, or an empty string when retention was not
   --    requested.
   function Generated_Text (Item : Result) return String;

   --  Report whether a completion reason describes an ordinary end.
   --
   --  Cancellation and output closure are ordinary: the caller asked for them,
   --  or the destination went away. A runtime error is not.
   --
   --  @param Item Reason to classify.
   --  @return True when the run ended without a failure.
   function Is_Normal (Item : Completion_Reason) return Boolean
   is (Item /= Runtime_Error);

   --  Stable machine-readable name of a completion reason, such as
   --  "stop_string". Never localized; the presentation layer looks up a
   --  message by this name.
   --
   --  @param Item Reason to name.
   --  @return Lower-case identifier.
   function Reason_Name (Item : Completion_Reason) return String;

   --  Check a request without running it.
   --
   --  @param Item Request to check.
   --  @param Status Success, Generation_Invalid_Request or a sampling
   --    diagnostic.
   procedure Validate
     (Item   : Request;
      Status : out Model_Runner.Errors.Error_Info);

   --  A grammar the generation must obey, or null for none.
   --
   --  A reference rather than a copy: a compiled grammar is immutable and
   --  one belongs to the command that read it, which outlives the runs it
   --  constrains.
   type Grammar_Reference is access constant Model_Runner.Grammar.Compiled;

   --  The pictures a prompt shows: the rows an encoder made of each, laid
   --  end to end in the order their markers stand in the prompt, and the
   --  tokens that frame them in the model's vocabulary -- the marker the
   --  template writes where a picture is, the soft token each row stands
   --  behind, and the closer.
   --
   --  The marker is also given as text, Marker_Text, because the
   --  reference processor rewrites the rendered prompt before it
   --  tokenizes: every marker becomes Frame_Before, the marker and
   --  Frame_After -- two line breaks either side, for Gemma 3 -- and the
   --  tokenizer meets the whole, so that the template's own line break
   --  and the frame's run together into the one token the model was
   --  trained on. The rewrite is done here, on the text, for the same
   --  reason.
   --
   --  A picture may come with crops -- pan-and-scan, the reference's name
   --  for showing a wide or tall picture whole and then in pieces, each
   --  piece encoded as a picture of its own. Crops holds, per picture,
   --  how many crops follow it, and the rows of a picture with crops are
   --  the whole picture's rows and then each crop's. In the prompt such a
   --  picture is written the way the reference writes it: Crop_Lead, the
   --  whole picture's frame, Crop_Bridge, and then each crop's frame with
   --  Crop_Gap between two -- the words being the processor's own, which
   --  the model was trained to see -- and the frames opened out as above.
   --  A video is shown as the reference processor shows one: its frames
   --  in pairs, each pair encoded as a picture of its own -- a slot --
   --  and stood in the prompt among the words that say when it was. The
   --  template writes one video marker for the video; the rewrite makes
   --  of it, for every slot, the seconds the slot stands at, the opener,
   --  the marker and the closer -- "<0.2 seconds><|vision_start|>
   --  <|video_pad|><|vision_end|>" -- and each slot's marker then opens
   --  out to its rows as a picture's does, behind the video marker as its
   --  own soft token. The slots take their places among the pictures in
   --  the order the markers stand: Kinds says, entry by entry, which is
   --  which, Video_Slots how many slots each video has, and Slot_Times
   --  the seconds of every slot in order.
   type Crop_Counts is array (Positive range <>) of Natural;
   type Crop_Counts_Access is access Crop_Counts;

   type Entry_Kind is (Still, Slot);
   type Entry_Kinds is array (Positive range <>) of Entry_Kind;
   type Entry_Kinds_Access is access Entry_Kinds;

   type Slot_Times is array (Positive range <>) of Long_Float;
   type Slot_Times_Access is access Slot_Times;

   --  The seconds a slot stands at, written as the reference processor
   --  writes them: to one decimal, a half going to the even digit, which
   --  is what a slot a quarter second in -- the first of a video sampled
   --  at two frames a second -- turns on: "0.2", not "0.3".
   --
   --  @param Seconds The time.
   --  @return The text, without its angle brackets or the word.
   function Seconds_Text (Seconds : Long_Float) return String;

   type Picture_Set is record
      Marker      : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Soft        : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Closer      : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Per_Picture : Natural := 0;

      --  How many entries the set holds -- a still, or a slot of a video,
      --  each with rows of its own -- and how many parts of the
      --  conversation they came from, a video being one part of as many
      --  entries as it has slots.
      Count       : Natural := 0;
      Parts       : Natural := 0;
      Rows        : Model_Runner.Tensors.Real_Array_Access := null;

      --  How many rows each picture has, where the count is the picture's
      --  own rather than Per_Picture for all -- a Qwen picture's is its
      --  shape's; null where every picture has Per_Picture.
      Counts      : Crop_Counts_Access := null;

      --  Where each row stands in its picture, indexed as Rows are, for
      --  a model whose positions have three parts; null for one whose
      --  positions have one.
      Places      : Model_Runner.Llama.Row_Places_Access := null;

      --  Whether the marker stays in the prompt ahead of the soft tokens
      --  -- Gemma's <start_of_image> does -- or is itself replaced by
      --  them, as Qwen's <|image_pad|> is, the marker and the soft token
      --  being one token there.
      Keep_Marker : Boolean := True;

      --  Whether a picture's rows attend to each other causally, as any
      --  text does and as Qwen's do, or both ways, as Gemma's do.
      Causal_Rows : Boolean := False;
      Marker_Text : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Frame_Before : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Frame_After : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Crops       : Crop_Counts_Access := null;
      Crop_Lead   : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Crop_Bridge : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Crop_Gap    : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;

      --  MiniCPM-V's slices, where a picture is shown as an overview and a
      --  grid of them: the marker and closer a slice stands between --
      --  <slice> and </slice>, apart from the overview's <image> -- the
      --  row-end token written after each grid row but the last, and how
      --  many slices a row each picture has. No_Token and null where a
      --  projector has no slices, so a still with crops falls to the words
      --  above instead.
      Slice_Marker : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Slice_Closer : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Slice_Marker_Text : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Slice_Row_End     : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Slice_Cols        : Crop_Counts_Access := null;

      --  The videos, as described above: their marker, which is their
      --  soft token too; its text and the opener and closer the rewrite
      --  sets a slot between; which entries are slots, how many slots
      --  each video has, and when each slot is. Null and No_Token where
      --  the model reads no video, or none was shown.
      Video_Marker : Model_Runner.Tokenizer.Token_Id :=
        Model_Runner.Tokenizer.No_Token;
      Video_Marker_Text : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      --  Whether a video's frames are shown as plain pictures, each behind
      --  the picture marker -- MiniCPM-V has no video of its own, so its
      --  frames are pictures -- rather than as the slots a video reader
      --  writes. Then a video marker opens out to one picture marker a
      --  frame instead of a framed slot a frame.
      Video_As_Frames : Boolean := False;
      Video_Open  : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Video_Close : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Kinds       : Entry_Kinds_Access := null;
      Video_Slots : Crop_Counts_Access := null;
      Times       : Slot_Times_Access := null;
   end record;

   No_Pictures : constant Picture_Set := (others => <>);

   --  Run one generation request to completion.
   --
   --  The prompt is text that has already been rendered: raw mode passes the
   --  user's text unchanged, and conversation mode passes the template's
   --  output. Tokenization happens here so that the token count that the
   --  context check uses is exactly the one that is evaluated.
   --
   --  @param Source Prepared model.
   --  @param Session Open session on that model; advanced by this call.
   --  @param Prompt Rendered prompt, UTF-8.
   --  @param Item Request to run.
   --  @param Stop_Set Stop tokens and stop strings.
   --  @param Sink Destination for generated text, or null to discard it.
   --  @param Observer Progress observer, or null.
   --  @param Time Monotonic clock used for the reported durations, or null.
   --  @param Seeds Entropy source used when the request has no explicit seed.
   --  @param Rules Grammar the generated text must obey, or null. Every
   --    token whose text cannot continue it is removed from the distribution
   --    before anything is sampled, and the end-of-sequence token is removed
   --    until the grammar may end, so a run cannot stop half way through
   --    what it was told to produce.
   --  @param Draft A smaller model proposing tokens for this one to check,
   --    or null for none. It must have the same vocabulary: a proposal is a
   --    token identifier and two models that number their tokens
   --    differently would be agreeing about numbers rather than about text.
   --  @param Draft_Session An open session on that model, at the same
   --    position as Session. The prompt is evaluated on both.
   --  @param Cancel Cancellation token, or null.
   --  @param Reporter Where per-token explanations go, or null for none.
   --    Reached only when Logprobs is above zero, so a caller that wants
   --    them has to say both what it wants and where to put it.
   --  @param Bounds Session limits applied to retention and batching.
   --  @param Pictures The pictures the prompt shows, or none. Each marker
   --    token the template wrote is opened out into the marker, Per_Picture
   --    soft tokens and the closer, and the soft tokens read the picture's
   --    rows in place of their embedding; the prompt must mark as many
   --    pictures as are given, in their order. Before the prompt is
   --    tokenized each marker's text is set between Frame_Before and
   --    Frame_After, and a picture with crops among the reference's
   --    words, the whole picture and each crop framed the same way.
   --  @param Outcome Completion reason, counts, timings and any diagnostic.
   procedure Generate
     (Source   : Model_Runner.Llama.Model'Class;
      Session  : in out Model_Runner.Llama.Session;
      Prompt   : String;
      Item     : Request;
      Stop_Set : Model_Runner.Stops.Set;
      Rules    : Grammar_Reference := null;
      Sink     : Model_Runner.Output.Sink_Reference;
      Observer : Model_Runner.Progress.Observer_Reference;
      Time     : Model_Runner.Clocks.Clock_Reference;
      Seeds    : Model_Runner.Entropy.Source_Reference;
      Cancel   : Model_Runner.Cancellation.Token_Reference;
      Draft    : access Model_Runner.Llama.Model'Class := null;
      Draft_Session : access Model_Runner.Llama.Session := null;
      Reporter : Explainer_Reference := null;
      Bounds   : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Pictures : Picture_Set := No_Pictures;
      Outcome  : out Result);

end Model_Runner.Generation;
