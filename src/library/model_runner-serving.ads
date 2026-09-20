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
--  WHAT AN ARRIVING CALLER KEEPS. A seat's session outlives the member in
--  it, and a second caller whose prompt begins the way the first one's did
--  keeps that much of the context instead of reading it again. Sixteen
--  callers through eight seats, all sending the same 208-token prompt and
--  each generating thirty-two tokens, cost 11.562 seconds on this host
--  where eight cost 5.844 and thirty-two cost 23.380 -- dead linear at 0.73
--  seconds a caller, of which 0.53 is reading a prompt the seat had just
--  finished reading. What the reuse leaves is the prompt read once a seat
--  rather than once a caller, so what it saves grows with the ratio of the
--  two and is nothing when they are equal.
--
--  WHAT IT KEEPS IS ONLY WHAT BOTH CALLERS SENT. The agreement is a prefix
--  comparison against the tokens the seat still holds, and everything above
--  it is left uncommitted and written over by what this caller says. So no
--  caller reads another's text through the cache. What it does mean is that
--  a seat no longer wipes between callers, which Reset does deliberately
--  and which Reuse => False restores.
--
--  A SLIDING WINDOW BOUNDS IT. A layer that has slid holds the newest
--  positions and no others, so keeping a prefix shorter than what it holds
--  would leave it attending to keys that are gone.
--  Model_Runner.Llama.Reusable_From says where that floor is and a seat
--  below it reads its prompt from nothing, which is correct and slower.
--
--  Joining costs one pass, not one a caller. A member arriving has a prompt
--  to read, and reading it on its own was the largest thing a server spent
--  its time on: seventy per cent of a run at a hundred and ten tokens a
--  prompt, because a pass that reads one caller's prompt reads every weight
--  in the model for that one caller. A round carries the arrivals instead --
--  a joining member's next hundred and twenty-eight prompt tokens are rows
--  of the same round as everyone else's next token -- so a caller's prompt
--  costs its own arithmetic and no pass of its own.
package Model_Runner.Serving is

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;
   subtype Token_Array is Model_Runner.Tokenizer.Token_Array;

   --  Which caller. Zero is none, which is what an admission that failed
   --  hands back.
   type Member_Id is new Natural;
   No_Member : constant Member_Id := 0;

   --  Members a round gathers at once, at most, where the caller leaves it
   --  to the backend -- four on the processor, eight on the device.
   --
   --  Four on the processor rather than five or six, and it is a measurement
   --  rather than a preference: the processor's byte kernel takes vectors in
   --  fours, so a batch of six costs more in total than a batch of four and
   --  a batch of three costs nearly what four does. A server that gathers in
   --  fours spends every pass it makes on a full one.
   --
   --  A device does not have that kink and is still climbing at sixteen, so
   --  four would cap it below where it wants to be: it is dealt eight, and a
   --  caller that knows its workload sets its own. Step takes everything
   --  ready up to Gather.
   Default_Gather : constant := 4;
   Device_Gather  : constant := 8;

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
   --  Tokens a caller's prompt may have.
   --
   --  A prompt is copied into the seat rather than read where it lies,
   --  because the caller's array is gone by the time the next round reads
   --  the rest of it. Eight kilobytes a seat, which is nothing beside the
   --  cache a seat already holds; a longer prompt is refused by name rather
   --  than truncated.
   Max_Prompt : constant := 2048;

   type Server (Capacity : Positive) is tagged limited private;

   --  Open a server on a model.
   --
   --  @param Item The server.
   --  @param Source The model every member reads.
   --  @param Workers The pool the members share. One pool, because the
   --    members take turns rather than run at once: a round is one pass and
   --    the pass is what the pool divides.
   --  @param Context Positions a member may hold, or zero for the model's.
   --  @param Gather Members a round takes at most, or zero to leave it to
   --    the backend -- four on the processor, at its strip-of-four kink,
   --    and eight on the device, which keeps climbing past four.
   --  @param Budget True to keep the phase clock on every seat, so that
   --    Time_Spent can say where a server's time went. Off by default,
   --    because it reads the clock at every phase boundary of every pass
   --    and a server is not a measurement.
   --  @param Reuse True to let an arriving caller keep whatever its prompt
   --    has in common with the one the seat last held, instead of reading
   --    its prompt from nothing. See the note below.
   --  @param Cache What each seat keeps its keys in. The default is the
   --    exact cache: packing trades accuracy for room, and only the caller
   --    knows what its answers are worth, so it asks for a packed cache
   --    rather than being given one. Where cache is what bounds how many
   --    seats fit, a caller passes q8 or q4 to fit more.
   --  @param Values What each seat keeps its values in. Same_As_Keys by
   --    default. Where the keys are packed, values bear a step coarser
   --    better than keys -- a weighted sum averages a value's rounding
   --    where a dot product carries a key's into every score -- so a caller
   --    trading accuracy for room may pass Value_Fourth against q8 keys.
   --  @param Paged True to deal each seat's cache in pages rather than one
   --    block, the default: a caller filling little of its context holds
   --    little, so far more seats fit, or a lone one holds less, for the
   --    same answer to the bit -- paging gives up no precision. Only the
   --    device pages; a seat on the processor is dealt a block regardless.
   --  @param Status Success or the first refusal.
   procedure Open
     (Item    : in out Server;
      Source  : in out Model_Runner.Llama.Model'Class;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null;
      Context : Natural := 0;
      Gather  : Natural := 0;
      Budget  : Boolean := False;
      Reuse   : Boolean := True;
      Cache   : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Values  : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Paged   : Boolean := True;
      Status  : out Model_Runner.Errors.Error_Info);

   --  How many prompt tokens arriving callers have not had to read.
   --
   --  The measure of what Reuse is worth on the traffic a server actually
   --  saw, which is the only place that can be known: it is a property of
   --  how alike the prompts are and of nothing else.
   --
   --  @param Item The server.
   --  @return Prompt tokens kept rather than read, since it opened.
   function Kept (Item : Server) return Natural;

   --  Where the server's time went, phase by phase.
   --
   --  Summed across the seats, because a round charges its phases to the
   --  session the call was made on and which seat that is changes with who
   --  is in the round. A seat keeps its session for the server's life, so
   --  the sum is the whole of it however many callers passed through.
   --
   --  Zero everywhere unless the server was opened with Budget.
   --
   --  @param Item The server.
   --  @return The phases, summed.
   function Time_Taken
     (Item : Server) return Model_Runner.Llama.Phase_Times;

   --  Close it, and every member with it. Idempotent.
   --
   --  @param Item The server.
   procedure Close (Item : in out Server);

   --  Take a caller on: give it a seat and its prompt.
   --
   --  Nothing is evaluated here. The prompt is read by the rounds that
   --  follow, a hundred and twenty-eight tokens at a time, as rows of the
   --  same pass that carries everyone else's next token -- which is why
   --  admitting a caller costs a copy and returns at once.
   --
   --  @param Item The server.
   --  @param Prompt The tokens this member starts from.
   --  @param With_Terms Its sampler, its stops and its limit.
   --  @param Given The rows standing in for embeddings at the prompt's
   --    marker tokens -- a picture's rows -- or none. The rows are the
   --    caller's, read by the rounds that carry this member's prompt and
   --    not copied, so they must outlive the member. A member with rows
   --    reuses no prefix of the seat's last caller, and the caller after it
   --    reuses none of its: two prompts alike token for token may show two
   --    pictures.
   --  @param Who Which member it became, or No_Member on a refusal.
   --  @param Status Success, Generation_Batch_Too_Large where the server is
   --    full, Tensor_Shape_Mismatch where the prompt is longer than the room
   --    a seat has for one, or Generation_Empty_Prompt.
   procedure Admit
     (Item       : in out Server;
      Prompt     : Token_Array;
      With_Terms : Terms;
      Who        : out Member_Id;
      Status     : out Model_Runner.Errors.Error_Info;
      Given      : Model_Runner.Llama.Given_Rows :=
        Model_Runner.Llama.No_Given_Rows);

   --  One round: everything ready moves one step.
   --
   --  Gathers up to Gather members and evaluates them in a single pass. A
   --  member that is generating contributes one row and gets a token back; a
   --  member that is still reading its prompt contributes the next stretch
   --  of it and gets nothing back until the prompt is done, at which point
   --  its first token comes out of the same pass. A server with nothing
   --  ready does nothing and says so through Gathered.
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
   --
   --  A seat's session outlives the member sitting in it. Opening one costs
   --  a whole context's keys and values -- a hundred and thirty-eight
   --  megabytes for a small model at two thousand positions, allocated,
   --  zeroed and given back -- and a server that did that per caller spent
   --  a hundred and fifty milliseconds a caller on it, which at a
   --  seven-token prompt was more than half of what serving cost. The seat
   --  keeps it and rewinds it instead: Reset invalidates the cache and the
   --  history and releases nothing.
   --
   --  It keeps the seat's block of a device's cache with it, which is the
   --  same argument a second time: a block given back is a block the next
   --  caller takes and fills.
   type Seat is limited record
      State   : Member_State := Free;

      --  How much of this member's prompt was already in the seat when it
      --  arrived, which is what it did not have to read.
      Kept    : Natural := 0;

      --  Whether that session has been opened at all. A seat that has never
      --  held a member has nothing to rewind.
      Seated  : Boolean := False;
      Why     : Ending := Still_Going;
      Session : aliased Model_Runner.Llama.Session;
      Sampler : Model_Runner.Sampling.Sampler;
      Terms   : Model_Runner.Serving.Terms;

      --  The caller's prompt and how much of it has been read. A member
      --  with more to read contributes that much of it to the next round
      --  instead of a token, which is what makes a caller's arrival cost
      --  its own arithmetic and no pass of its own.
      Prompt  : Model_Runner.Tokenizer.Token_Array (1 .. Max_Prompt) :=
        [others => Model_Runner.Tokenizer.No_Token];
      Length  : Natural := 0;
      Read    : Natural := 0;

      --  The rows given at the prompt's marker tokens, the caller's own,
      --  and whether the seat's last caller gave any: a prefix read with
      --  one picture's rows is no prefix for another's.
      Given   : Model_Runner.Llama.Given_Rows := Model_Runner.Llama.No_Given_Rows;
      Gave    : Boolean := False;

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
      Budget    : Boolean := False;
      Reuse     : Boolean := True;
      Cache     : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Values    : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Paged     : Boolean := True;
      Open_Now  : Boolean := False;

      --  Room for one round's logits, a row a member, allocated once.
      Rows      : Model_Runner.Tensors.Real_Array_Access := null;
      Width     : Model_Runner.Numerics.Element_Count := 0;

      Rounds_Made : Natural := 0;
      Last_Round  : Natural := 0;
      Tokens_Made : Natural := 0;
      Tokens_Kept : Natural := 0;

      Seats : Seat_Room (1 .. Capacity);
   end record;

end Model_Runner.Serving;
