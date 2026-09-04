with Model_Runner.Backend.CPU;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Sampling;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

--  Several callers served from one model, a round at a time.
--
--  `Model_Runner.Llama.Evaluate_Round` is the primitive: one token from each
--  of several sessions in one pass over the weights. This is the policy over
--  it -- who is in the next round, what each of them is sampled with, and
--  when one of them is finished and leaves.
--
--  Why a round is worth having. A generated token reads every weight once
--  and multiplies each of them once, so the reading is the cost and the
--  multiplying is nearly free; two callers served in one pass get their
--  tokens at about one and a half times the rate of one, four at three
--  times, and eight on a device at four times what a single sequence gets.
--  What that buys is not a faster caller -- a single sequence is a chain of
--  dependent products and stays what it is -- but a second caller for
--  almost nothing.
--
--  What a member brings with it. Its own prompt, its own sampler, and its
--  own end: the temperature, the penalties, the biases and the seed are one
--  per member, and so are the stop tokens and the token limit. Nothing here
--  is shared between members but the model and the pass.
--
--  What this does not do. Members join by prefilling on their own, which is
--  the batched path exactly as it is today; a round is decode rows only.
--  Mixing a joining member's prompt into a round with everyone else's next
--  token needs a per-row token count as well as a per-row position, and it
--  is worth more than anything here -- see docs/serving-several-sequences.md
--  -- but it is not this.
package Model_Runner.Serving is

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;
   subtype Token_Array is Model_Runner.Tokenizer.Token_Array;

   --  Which caller. Zero is none, which is what an admission that failed
   --  hands back.
   type Member_Id is new Natural;
   No_Member : constant Member_Id := 0;

   --  Members a round gathers at once, at most.
   --
   --  Four rather than five or six, and it is a measurement rather than a
   --  preference: the processor's byte kernel takes vectors in fours, so a
   --  batch of six costs more in total than a batch of four and a batch of
   --  three costs nearly what four does. A server that gathers in fours
   --  spends every pass it makes on a full one.
   --
   --  A device does not have that kink and is still climbing at sixteen, so
   --  this is the floor of what to gather and not the ceiling: Step takes
   --  everything ready up to Gather, and Gather is the caller's to set.
   Default_Gather : constant := 8;

   --  What one member is served with.
   type Terms is record
      --  The sampler's whole configuration: temperature, the filters, the
      --  penalties and their window. Greedy is the default, which is what
      --  makes two members of a round with the same prompt say the same
      --  thing and is how the round is checked.
      Sampling : Model_Runner.Sampling.Configuration;

      --  Its seed, which greedy ignores and reports anyway.
      Seed : Model_Runner.Sampling.Seed_Value := 0;

      --  Most tokens this member may produce. Zero is the context's own
      --  room, which is what a caller that has not thought about it wants.
      Limit : Natural := 0;

      --  Tokens that end it. The model's own end-of-sequence is not assumed:
      --  a caller that wants it says so, because a caller pooling embeddings
      --  or continuing a document does not.
      Stops : Token_Array (1 .. 8) :=
        [others => Model_Runner.Tokenizer.No_Token];
   end record;

   --  Why a member stopped.
   type Ending is
     (Still_Going,
      Reached_A_Stop,
      Reached_Its_Limit,
      Filled_The_Context,
      Refused);

   --  A server: a model, a pool, and room for a fixed number of members.
   --
   --  Fixed because the sessions are the memory: a member's cache is tens of
   --  megabytes and a server that grew one on demand would be a server whose
   --  worst moment is an allocation. Capacity is decided when it opens.
   type Server (Capacity : Positive) is tagged limited private;

   --  Open a server on a model.
   --
   --  @param Item The server.
   --  @param Source The model every member reads.
   --  @param Workers The pool the members share. One pool, because the
   --    members take turns rather than run at once: a round is one pass and
   --    the pass is what the pool divides.
   --  @param Context Positions a member may hold, or zero for the model's.
   --  @param Gather Members a round takes at most.
   --  @param Status Success or the first refusal.
   procedure Open
     (Item    : in out Server;
      Source  : in out Model_Runner.Llama.Model'Class;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null;
      Context : Natural := 0;
      Gather  : Positive := Default_Gather;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Close it, and every member with it. Idempotent.
   --
   --  @param Item The server.
   procedure Close (Item : in out Server);

   --  Take a caller on: read its prompt and queue it.
   --
   --  The prompt is read on its own, in batches, which is prefill as it
   --  stands. What comes back is the first token this member will say, taken
   --  from the prompt's own last distribution through this member's sampler,
   --  so a member joins a round with a token to contribute rather than with
   --  a prompt to catch up on.
   --
   --  @param Item The server.
   --  @param Prompt The tokens this member starts from.
   --  @param With_Terms Its sampler, its stops and its limit.
   --  @param Who Which member it became, or No_Member on a refusal.
   --  @param Cancel Stops a long prefill, as evaluation does everywhere.
   --  @param Status Success, Generation_Batch_Too_Large where the server is
   --    full, or whatever reading the prompt refused with.
   procedure Admit
     (Item       : in out Server;
      Prompt     : Token_Array;
      With_Terms : Terms;
      Who        : out Member_Id;
      Cancel     : Model_Runner.Cancellation.Token_Reference := null;
      Status     : out Model_Runner.Errors.Error_Info);

   --  One round: everything ready says one token.
   --
   --  Gathers up to Gather members, evaluates them in a single pass, samples
   --  each with its own sampler, and retires the ones that ended. A server
   --  with nothing ready does nothing and says so through Gathered.
   --
   --  @param Item The server.
   --  @param Cancel Stops between layers.
   --  @param Status Success, or the first refusal. A member that refuses is
   --    retired as Refused and the rest of the round stands.
   procedure Step
     (Item   : in out Server;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out Model_Runner.Errors.Error_Info);

   --  What a member has produced and has not been handed yet.
   --
   --  @param Item The server.
   --  @param Who Which member.
   --  @param Into Receives the tokens.
   --  @param Last How many of Into were written.
   --  @param Done True where this member has finished, whatever the reason.
   procedure Take
     (Item : in out Server;
      Who  : Member_Id;
      Into : out Token_Array;
      Last : out Natural;
      Done : out Boolean);

   --  Let a member go, and free its room for the next caller.
   --
   --  Said of a member that has finished, to take its seat back, and of one
   --  that has not, to stop serving it: a caller that goes away is a caller
   --  whose remaining tokens are nobody's.
   --
   --  @param Item The server.
   --  @param Who Which member. No_Member and a member already gone are both
   --    nothing to do.
   procedure Retire (Item : in out Server; Who : Member_Id);

   --  How a member ended.
   --
   --  @param Item The server.
   --  @param Who Which member.
   --  @return Why it stopped, or Still_Going.
   function Ended (Item : Server; Who : Member_Id) return Ending;

   --  How many members the server is still serving.
   --
   --  @param Item The server.
   --  @return Members that have not finished.
   function Serving (Item : Server) return Natural;

   --  How many rounds the server has made.
   --
   --  @param Item The server.
   --  @return Rounds since it opened.
   function Rounds (Item : Server) return Natural;

   --  How many members were in the last round.
   --
   --  A server that gathers in eights and reports twos has a queue that is
   --  emptying, which is the thing to know about a scheduler: a round of two
   --  costs nearly what a round of eight costs.
   --
   --  @param Item The server.
   --  @return Members in the round Step last made.
   function Gathered (Item : Server) return Natural;

   --  How many tokens it has produced across every member.
   --
   --  With Rounds, this is what a rate is computed from.
   --
   --  @param Item The server.
   --  @return Tokens produced since it opened.
   function Produced (Item : Server) return Natural;

private

   type Member_State is (Free, Running, Finished);

   --  One member's own room. The session is aliased because a round names
   --  its members by access, which is what lets one call carry several.
   type Seat is limited record
      State   : Member_State := Free;
      Why     : Ending := Still_Going;
      Session : aliased Model_Runner.Llama.Session;
      Sampler : Model_Runner.Sampling.Sampler;
      Terms   : Model_Runner.Serving.Terms;

      --  The token this member will contribute to the next round, and the
      --  ones it has said that nobody has taken yet.
      Next    : Token_Id := Model_Runner.Tokenizer.No_Token;
      Said    : Model_Runner.Tokenizer.Token_Array (1 .. 256) :=
        [others => Model_Runner.Tokenizer.No_Token];
      Held    : Natural := 0;
      Total   : Natural := 0;
   end record;

   type Seat_Room is array (Positive range <>) of Seat;

   type Server (Capacity : Positive) is tagged limited record
      Source    : access Model_Runner.Llama.Model'Class := null;
      Workers   : Model_Runner.Backend.CPU.Pool_Reference := null;
      Context   : Natural := 0;
      Gather    : Positive := Default_Gather;
      Open_Now  : Boolean := False;

      --  Room for one round's logits, a row a member, allocated once.
      Rows      : Model_Runner.Tensors.Real_Array_Access := null;
      Width     : Model_Runner.Numerics.Element_Count := 0;

      Rounds_Made : Natural := 0;
      Last_Round  : Natural := 0;
      Tokens_Made : Natural := 0;

      Seats : Seat_Room (1 .. Capacity);
   end record;

end Model_Runner.Serving;
