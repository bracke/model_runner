with Model_Runner.Errors;
with Model_Runner.Backend;

package body Model_Runner.Draft_Policy is

   package L renames Model_Runner.Llama;

   function Seeks_Paired_Draft
     (Prepared : L.Model; Request : Asked) return Boolean
   is (not Request.Model_Named
       and then not Request.Lookup
       and then Request.Tokens > 0
       and then L.Vocabulary (Prepared) /= null);

   function Seeks_Store_Draft
     (Prepared : L.Model; Session : L.Session; Request : Asked) return Boolean
   is (not Request.Model_Named
       and then not Request.Lookup
       and then not Request.Tokens_Set
       and then Request.Tokens > 0
       and then L.Config (Prepared).Experts = 0
       and then not L.Drafts_Next (Session)
       and then L.Token_Bytes (Prepared) >= Next_Draft_Bytes
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

      --  A draft model's rounds follow what the rounds before kept, unless
      --  a length was named.
      Result.Adapts := Draft_Ready and then not Request.Tokens_Set;

      --  And where nothing drafts, a model large enough that a round pays
      --  -- a dense one of Next_Draft_Bytes a token, or a mixture -- drafts
      --  out of its own context: what followed this phrase the last time.
      --  Not on the processor, where checking several positions costs
      --  several positions' arithmetic and too little is kept to pay.
      if not Result.From_Context
        and then not Result.From_Next
        and then not Draft_Ready
        and then not Request.Tokens_Set
        and then Request.Tokens > 0
        and then (L.Config (Prepared).Experts > 0
                  or else L.Token_Bytes (Prepared) >= Next_Draft_Bytes)
        and then not Model_Runner.Backend."="
                       (L.Capability (Prepared).Kind,
                        Model_Runner.Backend.Backend_CPU)
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
