with Model_Runner.Backend;
with Model_Runner.Llama;
with Model_Runner.Memory;
with Model_Runner.Numerics;

--  What a quantization costs the model's predictions.
--
--  This repository measures what every format costs to run to three decimal
--  places and has never measured what any of them costs to be right. The
--  format table's closing sentence -- "the table is what these formats buy
--  their accuracy with, and this is what it costs" -- has a measured half
--  and an asserted one, and this is the asserted half.
--
--  TWO NUMBERS, and the second is the one to read. Perplexity is the
--  exponential of the mean surprise: how many equally likely tokens the
--  model was effectively choosing between at each position. It is a fact
--  about a model and a text together, so a number here is comparable with
--  another number here and with nothing outside this repository, which does
--  not carry the corpus everyone else quotes.
--
--  The divergence is the one that answers the question actually being
--  asked. Given the same model in two formats, at each position the higher
--  precision one has a distribution and the lower one has another, and the
--  Kullback-Leibler divergence from the first to the second says how much
--  of the first's information the second throws away. It needs no standard
--  corpus to mean something, because both sides read the same text: it is a
--  measurement of the format and not of the text. That is why llama.cpp's
--  own guidance prefers it for comparing quantizations, and why the table
--  this produces leads with it.
--
--  A file comparison uses the precision of the file named by --against. A
--  cache comparison is different: it prepares one model once, then opens two
--  sessions whose key/value caches use the two requested storages. Thus the
--  reported divergence isolates cache storage rather than confounding it
--  with a second copy or quantization of the weights.
--
--  WHICH POSITIONS ARE SCORED. The second half of each chunk, which is
--  llama.cpp's rule -- `const int first = n_ctx/2` -- and the reason for it
--  is that the first token of a chunk has no context at all and the second
--  has one token of it. Scoring those would measure the chunking rather
--  than the model.
package Perplexity_Run is

   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  The natural logarithm of the probability this row gives that token.
   --
   --  A log-sum-exp in Long_Float over the raw logits: the maximum is taken
   --  out first, so a logit far from the others cannot overflow the
   --  exponential and the sum is formed among numbers no larger than one.
   --
   --  @param Logits One position's raw logits, indexed from zero.
   --  @param Token Which token to report the probability of.
   --  @return The log probability, which is at most zero.
   function Log_Probability
     (Logits : Real_Array; Token : Element_Count) return Long_Float;

   --  The Kullback-Leibler divergence from one row to another, in nats.
   --
   --  Sum over the vocabulary of p * (log p - log q), where p is the
   --  baseline's distribution and q the other's. Zero exactly when the two
   --  distributions are the same, positive otherwise, and never negative --
   --  which is what the checks on it are.
   --
   --  Both rows are softmaxed here rather than by the caller, for the same
   --  reason Log_Probability takes raw logits: the caller has what the
   --  engine produced and nothing else.
   --
   --  @param Baseline The distribution being diverged from.
   --  @param Other The distribution being measured.
   --  @return The divergence in nats, or a negative number where the two
   --    rows are not the same width.
   function Divergence
     (Baseline : Real_Array; Other : Real_Array) return Long_Float;

   --  What one run measured.
   type Report is record
      Ran     : Boolean := False;
      Missing : Boolean := False;

      Detail    : String (1 .. 160) := [others => ' '];
      Detail_Up : Natural := 0;

      --  The corpus, and how much of it was scored.
      Tokens  : Natural := 0;
      Chunks  : Natural := 0;
      Scored  : Natural := 0;

      --  Exp of the mean surprise, and the mean surprise itself in nats.
      Perplexity : Long_Float := 0.0;
      Entropy    : Long_Float := 0.0;

      --  The baseline's corresponding figures. They are zero where no
      --  comparison was requested.
      Baseline_Perplexity : Long_Float := 0.0;
      Baseline_Entropy    : Long_Float := 0.0;

      --  Set only when a baseline was given.
      Compared   : Boolean := False;
      Divergence : Long_Float := 0.0;

      --  How often the two models' most likely token is the same one, which
      --  is the coarse measure beside the fine one: a format can move every
      --  probability and still choose the same word every time.
      Agreed     : Natural := 0;

      --  And the worst single position, because a mean hides the case a
      --  reader of this table would want to know about.
      Worst      : Long_Float := 0.0;
      Worst_Position : Natural := 0;
      Worst_Wanted : Natural := 0;
      Worst_Candidate_Top : Natural := 0;
      Worst_Baseline_Top : Natural := 0;
      Worst_Candidate_Wanted_Logp : Long_Float := 0.0;
      Worst_Baseline_Wanted_Logp : Long_Float := 0.0;

      --  Planned KV bytes and elapsed evaluation time for each arm. For a
      --  cache comparison these are the direct price and speed of the two
      --  storages; for a file comparison both caches use the requested
      --  candidate storage.
      Cache_Bytes          : Model_Runner.Memory.U64 := 0;
      Baseline_Cache_Bytes : Model_Runner.Memory.U64 := 0;
      Candidate_Seconds    : Duration := 0.0;
      Baseline_Seconds     : Duration := 0.0;

      Candidate_Cache  : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Candidate_Values : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Baseline_Cache   : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Baseline_Values  : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Cache_Comparison : Boolean := False;

      Seconds : Duration := 0.0;
      Load_Before, Load_After : Long_Float := 0.0;
      Warm_Before, Warm_After : Long_Float := -1.0;
   end record;

   --  Score a corpus, and optionally compare against another format of the
   --  same model.
   --
   --  @param Path Model file to measure.
   --  @param Against A second model file to measure the first against, or
   --    the empty string for none. It must be the same model in another
   --    format: two models with different vocabularies would be compared
   --    position by position over distributions about different things.
   --  @param Text File holding the corpus.
   --  @param Chunk Tokens read in one pass, of which the second half is
   --    scored.
   --  @param Chunks How many chunks to read, or zero for as many as the
   --    corpus holds.
   --  @param Threads Workers the products are divided across.
   --  @param Backend Which backend runs them.
   --  @param Anyway True to measure on a busy machine anyway.
   --  @param Waiting Minutes to wait for the machine to go quiet, or zero.
   --  @param Result What it measured.
   --  @param Stretch What to ask of the rotation: none, linear, yarn, or
   --    the empty string to leave the file to decide as it always did. A
   --    chunk longer than the context the model was trained on cannot be
   --    scored at all without one, because the session that would hold it
   --    is refused.
   --  @param Factor What to stretch it by, where two is twice the context.
   --    Zero is unasked.
   --  @param Repack The weights' layout, as Llama.Prepare takes it: the
   --    command passes run's unasked one, the panels on the processor.
   --  @param Cache Storage used by the measured session's keys.
   --  @param Values Optional storage used by its values.
   --  @param Compare_Cache Compare two sessions of Path rather than two
   --    model files. Against must then be empty.
   --  @param Against_Cache Storage used by the baseline session's keys.
   --  @param Against_Values Optional storage used by its values.
   procedure Run
     (Path    : String;
      Against : String;
      Text    : String;
      Chunk   : Positive := 512;
      Chunks  : Natural := 0;
      Threads : Positive;
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Anyway  : Boolean := False;
      Waiting : Natural := 0;
      Result  : out Report;
      Stretch : String := "";
      Factor  : Model_Runner.Numerics.Wide_Real := 0.0;
      Repack  : Model_Runner.Llama.Repack_Mode :=
        Model_Runner.Llama.No_Repack;
      Cache   : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Values  : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Compare_Cache : Boolean := False;
      Against_Cache : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Against_Values : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys);

   --  One line saying what it found.
   --
   --  @param Item What Run measured.
   --  @return The line.
   function Summary (Item : Report) return String;

end Perplexity_Run;
