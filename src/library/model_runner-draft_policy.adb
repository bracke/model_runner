with Model_Runner.Errors;
with Model_Runner.Backend;

package body Model_Runner.Draft_Policy is

   package L renames Model_Runner.Llama;

   --  Whether the model runs on the processor, where a draft model costs
   --  more than it keeps: checking several positions there is several
   --  positions' arithmetic, and the draft's own tokens are the processor's
   --  too. Alternated rounds of a story, plain against the draft found
   --  unasked: Steelman-14B with its paired draft 5.05-5.23 against
   --  4.65-4.68 tokens a second (three), qwen3-8b with the draft the
   --  store offered 9.45-9.49 against 6.93-7.14 (two). Drafting from the context costs
   --  nothing where nothing repeats and pays where it does, so it is the
   --  processor's draft instead (Decide).
   function On_Processor (Prepared : L.Model) return Boolean
   is (Model_Runner.Backend."="
         (L.Capability (Prepared).Kind, Model_Runner.Backend.Backend_CPU));

   function Seeks_Paired_Draft
     (Prepared : L.Model; Request : Asked) return Boolean
   is (not Request.Model_Named
       and then not On_Processor (Prepared)
       and then not Request.Lookup
       and then Request.Tokens > 0
       and then L.Rewinds_Drafts (Prepared)
       and then L.Vocabulary (Prepared) /= null);

   function Seeks_Store_Draft
     (Prepared : L.Model; Session : L.Session; Request : Asked) return Boolean
   is (not Request.Model_Named
       and then not On_Processor (Prepared)
       and then not Request.Lookup
       and then not Request.Tokens_Set
       and then Request.Tokens > 0
       and then L.Config (Prepared).Experts = 0
       and then not L.Drafts_Next (Session)
       and then L.Token_Bytes (Prepared) >= Next_Draft_Bytes
       and then L.Rewinds_Drafts (Prepared)
       and then L.Vocabulary (Prepared) /= null);

   function Decide
     (Prepared     : L.Model;
      Session      : L.Session;
      Request      : Asked;
      Draft_Ready  : Boolean;
      Auto_Drafted : Boolean) return Plan
   is
      Result : Plan;
   begin
      --  Nothing drafts where a round could not be rewound: a model whose
      --  linear layers read one state keeps no ring (L.Rewinds_Drafts).
      if not L.Rewinds_Drafts (Prepared) then
         return Result;
      end if;

      --  From the block past the stack, on its own, unless a draft costs
      --  too much of a token to pay: the block and the head over the stack
      --  and the head, which is 0.19 on Qwen3.5-4B, where three proposals a
      --  round read 13.3 -> 17.4 tokens a second sampling, and 0.38 on the
      --  0.8B, whose head is a third of the file and where one proposal a
      --  round already reads 57 -> 52 -- and a dense model whose token
      --  reads less than Next_Draft_Bytes, whose token is its fixed costs.
      --  Not a mixture: its token reads a few experts' bytes and costs far
      --  more than they say -- qwen3.6-35B-A3B at UD-IQ3_XXS reads 1.8 GB a
      --  token and drafting three a round from its block reads 24.9 ->
      --  30.8 tokens a second on text its context does not repeat, and
      --  39.5 against the lookup's 36.7 on text it does. A --draft-tokens
      --  named is taken as asked.
      Result.From_Next :=
        Request.Tokens > 0
        and then not Draft_Ready
        and then not Request.Lookup
        and then L.Drafts_Next (Session)
        and then (Request.Tokens_Set
                  or else (L.Draft_Share (Prepared) <= Next_Draft_Share
                           and then (L.Token_Bytes (Prepared) >= Next_Draft_Bytes
                                     or else L.Config (Prepared).Experts > 0)));

      Result.Tokens :=
        (if Result.From_Next
           and then not Request.Tokens_Set
           and then L.Batch_Limit (Prepared) = L.Dense_Streamed_Batch
         --  A split dense model's round streams its feed-forward once for
         --  every proposal it checks, so a longer round pays: ThinkingCap
         --  7.80 -> 7.93 tokens a second at four over three.
         then Split_Next_Draft_Tokens
         elsif Result.From_Next and then not Request.Tokens_Set
         then Next_Draft_Tokens
         --  A found draft starts at its own length -- but a length named
         --  is the length, whichever draft it is: a paired sidecar took
         --  the store's three over --draft-tokens.
         elsif Auto_Drafted and then not Request.Tokens_Set
         then Store_Draft_Tokens
         --  A named draft model starts where a found one does unless a
         --  length was named: three, then adapting.
         elsif Draft_Ready and then not Request.Tokens_Set
         then Store_Draft_Tokens
         elsif Draft_Ready or else Request.Lookup or else Result.From_Next
         then Request.Tokens else 0);
      Result.From_Context := Request.Lookup and then not Draft_Ready;

      --  A draft model asks the text first, every round it last proposed
      --  well (Generation.Draft_Lookup_First): a thinking model restates
      --  its question, and qwen3-8b's story read 28.9 tokens a second
      --  drafted by Qwen3-0.6B, 35.6 asking the text first; gemma-3-4b's
      --  29.7 -> 29.2, Steelman-14B's level.
      Result.Lookup_First := Draft_Ready;

      --  A draft model's rounds follow what the rounds before kept, and
      --  the block's but a large dense model's (see Next_Adapts), unless a
      --  length was named.
      Result.Adapts :=
        not Request.Tokens_Set
        and then (Draft_Ready
                  or else (Result.From_Next
                           and then Next_Adapts
                                      (L.Config (Prepared).Experts,
                                       L.Token_Bytes (Prepared))));

      --  And where nothing drafts, a model large enough that a round pays
      --  -- a dense one of Next_Draft_Bytes a token, or a mixture -- drafts
      --  out of its own context: what followed this phrase the last time.
      --  On the processor a dense one only, where checking several
      --  positions costs several positions' arithmetic yet a story's
      --  proposals still pay or about break even -- alternated rounds,
      --  plain against drafting from the context: LFM3-1.7B BF16 12.96
      --  against 13.87 tokens a second and qwen3-8b 9.47 against 9.90
      --  (two each), Steelman-14B 5.21 against 5.15 (medians of three)
      --  -- and text that repeats doubles (LFM3 continuing the README,
      --  12.8 -> 27.6). A mixture's check
      --  there reads the union of its positions' experts, unmeasured.
      if not Result.From_Context
        and then not Result.From_Next
        and then not Draft_Ready
        and then not Request.Tokens_Set
        and then Request.Tokens > 0
        and then (if On_Processor (Prepared)
                  then L.Config (Prepared).Experts = 0
                       and then L.Token_Bytes (Prepared) >= Next_Draft_Bytes
                  else L.Config (Prepared).Experts > 0
                       or else L.Token_Bytes (Prepared) >= Next_Draft_Bytes)
      then
         Result.From_Context := True;
         Result.Tokens := Request.Tokens;
      end if;
      return Result;
   end Decide;

   -------------
   -- Prepare --
   -------------

   procedure Prepare
     (Prepared  : in out Model_Runner.Llama.Model;
      Decided   : Plan;
      On_Device : Boolean;
      Threads   : Positive)
   is
      Lighter : Model_Runner.Errors.Error_Info;
   begin
      if Decided.From_Next then
         L.Lighten_Draft_Head (Prepared, Threads, Lighter);
         if On_Device then
            L.Lighten_Next_Block (Prepared, Threads, Lighter);
         end if;
      end if;
   end Prepare;

end Model_Runner.Draft_Policy;
