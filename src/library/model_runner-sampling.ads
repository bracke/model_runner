private with Ada.Finalization;

with Interfaces;

with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

--  Token selection from raw logits.
--
--  Sampling knows nothing about model execution, token decoding, terminal
--  output or conversation management. It receives one vocabulary-sized raw
--  logit vector and returns one token identifier.
--
--  Pipeline. The order below is part of the behavioural contract and has
--  conformance tests; changing it changes which token a given seed produces.
--
--     1  validate the vocabulary size
--     2  reject non-finite logits
--     3  apply forbidden-token masks
--     3a apply the caller's per-token biases
--     3b penalize tokens that would continue a repeated sequence
--     4  apply the repetition penalty over the recent window
--     5  apply temperature
--     6  apply top-k filtering
--     6a apply tail-free filtering
--     6b apply locally typical filtering
--     7  apply top-p filtering
--     8  apply minimum-p filtering
--     8a exclude the top choices, some of the time
--     9  normalize the surviving probabilities
--    10  select a token
--    11  update the sampling history
--
--  Mirostat, when it is on, replaces steps 6 through 8a with one truncation
--  of its own and adds a state update after step 10. It is an alternative to
--  those filters and not an addition to them, which is why it is not a step
--  in the list.
--
--  Determinism. Temperature zero is greedy selection: it breaks ties towards
--  the lowest token identifier and does not consume random state, so a greedy
--  run is reproducible without a seed. Every other configuration draws from a
--  session-local generator seeded with an explicit 64-bit value; there is no
--  process-wide random state.
--
--  Task safety: a Sampler is mutable state owned by one session.
package Model_Runner.Sampling is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Seed_Value is Interfaces.Unsigned_64;

   use type Model_Runner.Numerics.Real;

   --  Validated, immutable sampling configuration.
   --
   --  Defaults match the values the CLI documents. A configuration is checked
   --  once, by Validate, before generation starts; nothing revalidates it per
   --  token.
   type Configuration is record
      --  Softmax temperature. Zero selects greedy mode.
      Temperature : Real := 0.8;

      --  Keep only the K highest-scoring candidates. Zero disables the filter.
      Top_K : Natural := 40;

      --  Keep the shortest prefix of the sorted candidates whose cumulative
      --  probability reaches this value. Must be greater than 0 and at most 1.
      Top_P : Real := 0.95;

      --  Drop candidates whose probability is below this fraction of the most
      --  probable candidate's. Must be in 0 .. 1.
      Min_P : Real := 0.05;

      --  Divide the logits of recently produced tokens by this value when they
      --  are positive and multiply when they are negative. One disables it.
      Repeat_Penalty : Real := 1.1;

      --  How many of the most recent tokens the penalty considers.
      Repeat_Window : Natural := 64;

      --  Subtracted from the logit of a token once for each time it appears
      --  in the window, so a token said four times is discouraged four times
      --  as much as one said once. Zero disables it. A negative value
      --  encourages repetition, which is why the range is not restricted to
      --  the positive side.
      Frequency_Penalty : Real := 0.0;

      --  Subtracted from the logit of a token that appears in the window at
      --  all, however often. Zero disables it.
      --
      --  The two differ in what they discourage. Frequency answers "how much
      --  has this been said", presence answers "has this been said", and a
      --  model that has fallen into a loop is usually better served by the
      --  first while one that keeps returning to a subject is served by the
      --  second. Both act on the same window as Repeat_Penalty, and all three
      --  compose: they are applied in turn to the same logit.
      Presence_Penalty : Real := 0.0;

      --  Keep the smallest set of candidates whose surprise is closest to
      --  the distribution's own entropy, until their probabilities reach
      --  this. One disables it.
      --
      --  The filters above ask which candidates are most likely. This asks
      --  which are least surprising, which is not the same question: a
      --  distribution with one overwhelming favourite is surprising when it
      --  is followed and dull when it is not, and text that always follows
      --  it reads as though the model had nothing to say.
      Typical_P : Real := 1.0;

      --  Keep the head of the sorted candidates up to where the curve stops
      --  falling steeply, measured by the second differences of the sorted
      --  probabilities. One disables it.
      --
      --  What it is for is the tail that top-p keeps when the head is flat:
      --  a hundred candidates each near a hundredth reach any threshold
      --  together, and cutting by cumulative probability cuts arbitrarily
      --  among equals. This cuts where the shape changes instead.
      Tail_Free : Real := 1.0;

      --  With this probability, at each step, remove every candidate above
      --  the threshold below except the least probable of them. Zero
      --  disables it.
      --
      --  Deliberately the opposite of every filter above: those keep the
      --  likeliest and this throws them away. It is for text that has to
      --  stop being predictable rather than stop being wrong, and it is a
      --  chance rather than a rule so that a sentence which needs its
      --  obvious word can still have it.
      XTC_Probability : Real := 0.0;

      --  How probable a candidate must be for XTC to consider removing it.
      XTC_Threshold : Real := 0.1;

      --  How hard to penalize a token that would continue a sequence
      --  already said. Zero disables it.
      --
      --  The repetition penalties above act on tokens; this acts on
      --  sequences. A model repeating a phrase is not saying one token too
      --  often -- each word of it may be perfectly ordinary -- it is
      --  following the same path again, and what this penalizes is the next
      --  step along a path already walked.
      DRY_Multiplier : Real := 0.0;

      --  Raised to the power of how far past the allowed length the
      --  repetition runs, so a longer repeat is penalized much harder than
      --  a shorter one.
      DRY_Base : Real := 1.75;

      --  How long a repeated sequence may be before it is penalized at all.
      --  Two or three words repeat innocently; ten do not.
      DRY_Allowed_Length : Natural := 2;

      --  Mirostat version: zero for none, two for the algorithm below.
      --  Version one is not implemented and naming it is refused rather
      --  than quietly treated as two.
      --
      --  Mirostat replaces the truncation filters rather than joining them:
      --  it keeps the candidates whose surprise is under a running target,
      --  and moves that target after every token by how surprising the one
      --  it chose turned out to be. What it holds steady is the surprise of
      --  the text, which is what the filters above only approximate by
      --  holding the shape of each step's distribution.
      Mirostat : Natural := 0;

      --  The surprise, in bits, that mirostat steers towards.
      Mirostat_Tau : Real := 5.0;

      --  How fast it steers. Larger reacts sooner and wanders more.
      Mirostat_Eta : Real := 0.1;
   end record;

   --  A configuration that always selects the most probable token.
   Greedy_Configuration : constant Configuration :=
     (Temperature       => 0.0,
      Top_K             => 0,
      Top_P             => 1.0,
      Min_P             => 0.0,
      Repeat_Penalty    => 1.0,
      Repeat_Window     => 0,
      Frequency_Penalty => 0.0,
      Presence_Penalty  => 0.0,
      Typical_P         => 1.0,
      Tail_Free         => 1.0,
      XTC_Probability   => 0.0,
      XTC_Threshold     => 0.1,
      DRY_Multiplier    => 0.0,
      DRY_Base          => 1.75,
      DRY_Allowed_Length => 2,
      Mirostat          => 0,
      Mirostat_Tau      => 5.0,
      Mirostat_Eta      => 0.1);

   --  Report whether a configuration selects greedily.
   --
   --  @param Item Configuration to inspect.
   --  @return True when temperature is zero.
   function Is_Greedy (Item : Configuration) return Boolean
   is (Item.Temperature = 0.0);

   --  Check a configuration.
   --
   --  @param Item Configuration to check.
   --  @param Status Success or Sampling_Invalid_Configuration naming the
   --    offending field.
   procedure Validate
     (Item   : Configuration;
      Status : out Model_Runner.Errors.Error_Info);

   --  Sampling state: the workspace, the generator and the token history.
   type Sampler is tagged limited private;

   --  Open a sampler over a vocabulary.
   --
   --  @param Item Sampler to open; closed first.
   --  @param Config Validated configuration.
   --  @param Vocabulary Number of tokens the logit vector will hold.
   --  @param Seed Generator seed. Ignored in greedy mode but still reported.
   --  @param Status Success, Sampling_Invalid_Configuration or
   --    Memory_Allocation_Failed.
   procedure Open
     (Item       : in out Sampler;
      Config     : Configuration;
      Vocabulary : Natural;
      Seed       : Seed_Value;
      Status     : out Model_Runner.Errors.Error_Info);

   --  Release a sampler. Idempotent.
   --
   --  @param Item Sampler to close.
   procedure Close (Item : in out Sampler);

   --  Clear the token history and restart the generator from its seed.
   --
   --  @param Item Sampler to reset.
   procedure Reset (Item : in out Sampler);

   --  Report whether a sampler is open.
   --
   --  @param Item Sampler to inspect.
   --  @return True when Open succeeded.
   function Is_Open (Item : Sampler) return Boolean;

   --  Seed the sampler was opened with.
   --
   --  @param Item Sampler to inspect.
   --  @return Seed value, reported in verbose statistics so that a run can be
   --    repeated exactly.
   function Seed_Used (Item : Sampler) return Seed_Value;

   --  Largest number of per-token biases one sampler will hold. A caller
   --  wanting more than this is asking for a vocabulary-sized table, which is
   --  a different feature: this is for nudging a handful of tokens.
   Max_Biases : constant := 64;

   --  A short list of tokens, for a caller carrying the other half of a
   --  bias table beside the amounts.
   type Token_List is array (Positive range <>) of Token_Id;

   --  Add a fixed amount to a token's logit, every step.
   --
   --  Applied before the penalties and the temperature, so a bias is a
   --  statement about the token and not about how hot the sampling is. It
   --  acts on the greedy path too: a bias that only worked above temperature
   --  zero would be a flag that quietly did nothing in the one mode a caller
   --  can check by hand.
   --
   --  Setting a bias for a token that already has one replaces it. A bias of
   --  Real'First forbids the token, which is what a caller writing minus
   --  infinity means; use Forbid for that instead, which says so.
   --
   --  @param Item Sampler to update.
   --  @param Token Token to bias.
   --  @param Amount Added to the token's logit.
   --  @param Status Success, or Sampling_Invalid_Configuration when there is
   --    no room for another and Sampling_Vocabulary_Mismatch when the token
   --    is outside the vocabulary.
   procedure Bias
     (Item   : in out Sampler;
      Token  : Token_Id;
      Amount : Real;
      Status : out Model_Runner.Errors.Error_Info);

   --  How many tokens carry a bias.
   --
   --  @param Item Sampler to inspect.
   --  @return Count of biased tokens.
   function Bias_Count (Item : Sampler) return Natural;

   --  Forbid a token from ever being selected.
   --
   --  Used for tokens that must not appear in generated text, such as a
   --  beginning-of-sequence marker.
   --
   --  @param Item Sampler to update.
   --  @param Token Token to mask.
   procedure Forbid (Item : in out Sampler; Token : Token_Id);

   --  Forget every mask that was set for one step.
   --
   --  A permanent mask -- the beginning-of-sequence marker, say -- is set
   --  once and meant to stay. A grammar's mask is different: it says what
   --  may follow *here*, and the next step has its own answer. This clears
   --  the second kind and leaves the first, so the two can be used together
   --  without one of them quietly outliving its step.
   --
   --  @param Item Sampler to update.
   procedure Release_Step_Mask (Item : in out Sampler);

   --  Forbid a token for this step only.
   --
   --  @param Item Sampler to update.
   --  @param Token Token to mask until the next release.
   procedure Forbid_For_Step (Item : in out Sampler; Token : Token_Id);

   --  Select one token from a logit vector.
   --
   --  The vector holds raw logits: no softmax has been applied by the
   --  architecture layer. Selection does not modify the caller's vector.
   --
   --  @param Item Sampler to use.
   --  @param Logits Raw logits indexed from 0, of length Vocabulary.
   --  @param Token Selected token; No_Token on failure.
   --  @param Status Success, Sampling_Vocabulary_Mismatch,
   --    Sampling_Non_Finite_Logit, Sampling_No_Candidates or
   --    Sampling_Invalid_Distribution.
   procedure Sample
     (Item   : in out Sampler;
      Logits : Real_Array;
      Token  : out Token_Id;
      Status : out Model_Runner.Errors.Error_Info);

   --  Largest number of alternatives an explanation will carry.
   Max_Alternatives : constant := 32;

   --  What the model made of one position, as probabilities.
   --
   --  The numbers are natural logarithms of probabilities from the model's
   --  own distribution: a plain softmax over the raw logits, with no
   --  temperature, no masks, no penalties and no filters. That is a
   --  deliberate choice and the only one worth publishing. A caller asking
   --  how sure the model was is asking about the model; the sampling
   --  pipeline is the caller's own doing, and reporting probabilities after
   --  it would answer a question about the configuration rather than about
   --  the text.
   --
   --  Chosen is the token the sampler actually returned, which is not always
   --  the first alternative: a token below the top of the distribution is
   --  what sampling above temperature zero is for.
   type Explanation is record
      Chosen  : Token_Id := Model_Runner.Tokenizer.No_Token;
      Log_Of  : Real := 0.0;

      Count      : Natural := 0;
      Tokens     : Token_List (1 .. Max_Alternatives) :=
        [others => Model_Runner.Tokenizer.No_Token];
      Log_Values : Model_Runner.Numerics.Real_List (1 .. Max_Alternatives) :=
        [others => 0.0];
   end record;

   --  Explain one position: what the model thought of the token that was
   --  chosen, and of the few it thought most likely.
   --
   --  Does not change the sampler and does not consume random state, so a
   --  run with explanations produces the same text as one without. That is
   --  worth more than the saving of folding it into Sample would buy.
   --
   --  @param Item Sampler, for the vocabulary size.
   --  @param Logits Raw logits, as they were given to Sample.
   --  @param Chosen Token that was selected.
   --  @param Wanted How many alternatives to report, capped at
   --    Max_Alternatives.
   --  @param Report What the model made of it.
   --  @param Status Success, Sampling_Vocabulary_Mismatch,
   --    Sampling_Non_Finite_Logit or Sampling_Invalid_Distribution.
   procedure Explain
     (Item   : Sampler;
      Logits : Real_Array;
      Chosen : Token_Id;
      Wanted : Natural;
      Report : out Explanation;
      Status : out Model_Runner.Errors.Error_Info);

   --  Append a token to the history the repetition penalty reads.
   --
   --  Called for prompt tokens as well as generated ones, so that a prompt
   --  influences the penalty exactly as generated text does.
   --
   --  @param Item Sampler to update.
   --  @param Token Token to record.
   procedure Record_Token (Item : in out Sampler; Token : Token_Id);

private

   --  A candidate token and its running score. Probability is meaningful only
   --  after the softmax step.
   type Candidate is record
      Token       : Token_Id := Model_Runner.Tokenizer.No_Token;
      Logit       : Real := 0.0;
      Probability : Real := 0.0;
   end record;

   type Candidate_Array is
     array (Model_Runner.Numerics.Element_Count range <>) of Candidate;
   type Candidate_Array_Access is access Candidate_Array;

   type History_Array is array (Natural range <>) of Token_Id;
   type History_Array_Access is access History_Array;

   type Mask_Array is array (Natural range <>) of Boolean;
   type Mask_Array_Access is access Mask_Array;

   type Bias_Entry is record
      Token  : Token_Id := Model_Runner.Tokenizer.No_Token;
      Amount : Real := 0.0;
   end record;

   type Bias_Array is array (1 .. Max_Biases) of Bias_Entry;

   --  xoshiro256++ state. Chosen because it is small, fast, has no rejected
   --  seeds once initialized through SplitMix64, and produces the same stream
   --  on every host.
   type Generator_State is array (0 .. 3) of Interfaces.Unsigned_64;

   type Sampler is limited new Ada.Finalization.Limited_Controlled with record
      Open_Flag  : Boolean := False;
      Settings   : Configuration;
      Vocabulary : Natural := 0;
      Seed       : Seed_Value := 0;
      State      : Generator_State := [others => 0];
      Working    : Candidate_Array_Access := null;

      --  Room for the highest few, when a top-k small enough to be worth
      --  selecting rather than sorting was asked for. Null otherwise.
      Chosen     : Candidate_Array_Access := null;
      History    : History_Array_Access := null;
      Used       : Natural := 0;
      Next_Slot  : Natural := 0;

      --  The same window, sorted and without repeats, so that asking
      --  whether a token is in it is a binary search rather than a walk.
      --
      --  The repetition penalty is on by default and the question is asked
      --  once for every token of the vocabulary at every step: thirty-two
      --  thousand walks of a sixty-four-entry ring is two million
      --  comparisons a token, which measured a fifth of everything a
      --  generated token spends off the device. Sorting the window costs a
      --  couple of thousand operations once a token.
      Ordered    : History_Array_Access := null;
      Ordered_Held : Natural := 0;
      Masked     : Mask_Array_Access := null;

      --  The masks that belong to one step, kept apart from the permanent
      --  ones so that clearing them cannot clear those.
      Stepped    : Mask_Array_Access := null;

      --  Mirostat's running target, in bits. Meaningless when mirostat is
      --  off, and reset with the sampler.
      Mu         : Real := 0.0;

      --  What the caller added to particular tokens. A short list rather
      --  than a vocabulary-sized array: a caller biases a handful of tokens
      --  and paying thirty-two thousand reals for that would be paying for
      --  the feature nobody asked for.
      Biases     : Bias_Array := [others => (Model_Runner.Tokenizer.No_Token,
                                             0.0)];
      Bias_Used  : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Sampler);

end Model_Runner.Sampling;
