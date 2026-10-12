with Model_Runner.Llama;

--  How a run drafts when nobody said how: from the model's own block past
--  its stack where that is cheap, else from a draft model found in the
--  store, else out of its own context where a round pays; and how many
--  proposals a round. One decision, which the run command takes and a tool
--  measuring the run takes with it -- copies of it drifted apart, and a
--  tool then measured a run nobody starts.
package Model_Runner.Draft_Policy is

   --  The most of a token a draft from the block past the stack may cost
   --  and still be taken without being asked for, and the least a token
   --  must read for any unasked draft to pay.
   Next_Draft_Share : constant Float := 0.25;
   Next_Draft_Bytes : constant Float := 2.0 * 1024.0 ** 3;

   --  Proposals a round: three from the block, four where a split dense
   --  model streams its feed-forward for every check, three from a draft
   --  model found in the store (Steelman-14B with Qwen2.5-Coder-0.5B, 12.75
   --  tokens a second against 12.0, 11.8 and 11.3 for four, five and six).
   Next_Draft_Tokens       : constant := 3;
   Split_Next_Draft_Tokens : constant := 4;
   Store_Draft_Tokens      : constant := 3;

   --  What the caller asked of drafting.
   type Asked is record
      --  --draft-tokens, and whether it was named; 0 turns drafting off.
      Tokens      : Natural := 4;
      Tokens_Set  : Boolean := False;
      --  --draft-lookup.
      Lookup      : Boolean := False;
      --  A draft model named.
      Model_Named : Boolean := False;
   end record;

   --  Whether a draft the model names beside itself is looked for
   --  (Drafts.Paired).
   --
   --  @param Prepared The model.
   --  @param Request What was asked.
   --  @return True where run looks for one.
   function Seeks_Paired_Draft
     (Prepared : Model_Runner.Llama.Model; Request : Asked) return Boolean;

   --  Whether, with no draft named or paired, one is looked for in the
   --  store and beside the model (Drafts.Find): a dense model whose token
   --  reads Next_Draft_Bytes or more, with no block past its stack.
   --
   --  @param Prepared The model.
   --  @param Session A session open on it.
   --  @param Request What was asked.
   --  @return True where run looks for one.
   function Seeks_Store_Draft
     (Prepared : Model_Runner.Llama.Model;
      Session  : Model_Runner.Llama.Session;
      Request  : Asked) return Boolean;

   --  How a run drafts: from the block past the stack, out of its context,
   --  or (neither) from the draft model loaded, if any; how many proposals
   --  a round; whether that length follows what was kept.
   type Plan is record
      From_Next    : Boolean := False;
      From_Context : Boolean := False;
      Adapts       : Boolean := False;
      Tokens       : Natural := 0;
   end record;

   --  The drafting a run's request takes.
   --
   --  @param Prepared The model.
   --  @param Session The session the run generates in.
   --  @param Request What was asked.
   --  @param Draft_Ready A draft model, named or found, is loaded.
   --  @param Auto_Drafted That draft was found, not named.
   --  @return The plan: whence proposals come, how many a round, and
   --    whether the round length adapts.
   function Decide
     (Prepared     : Model_Runner.Llama.Model;
      Session      : Model_Runner.Llama.Session;
      Request      : Asked;
      Draft_Ready  : Boolean;
      Auto_Drafted : Boolean) return Plan;

   --  Get a model ready for the drafting a plan decided: a draft from the
   --  block past the stack reads a four-bit slice of the head, and on the
   --  device the block's own eight-bit matrices at four bits too
   --  (Llama.Lighten_Next_Block). Proposals only: nothing the run writes
   --  changes. The run command and a tool measuring it both call this.
   --
   --  @param Prepared The model.
   --  @param Decided The plan Decide returned.
   --  @param On_Device The run evaluates on the device.
   --  @param Threads Workers to encode with.
   procedure Prepare
     (Prepared  : in out Model_Runner.Llama.Model;
      Decided   : Plan;
      On_Device : Boolean;
      Threads   : Positive);

end Model_Runner.Draft_Policy;
