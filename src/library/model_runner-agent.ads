with Model_Runner.Cancellation;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Output;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Tools;
with Model_Runner.Tools.Runner;

--  The loop the rest of the tool packages were waiting for.
--
--  Model_Runner.Tools reads the definitions a caller offers and the calls a
--  model writes back, and says the loop closes outside this program or not at
--  all. Model_Runner.Tools.Runner is the thing that closes it. This is the
--  loop itself: render the conversation with the tools in it, generate a
--  reply the grammar keeps to prose or a readable call, take the reply apart
--  into what the model said and what it asked for, run each call through the
--  caller's runner, hand the answers back as tool turns, and render again --
--  until the model answers with no call left to run, or the step budget is
--  spent.
--
--  It is orchestration and nothing else. Every piece it drives already
--  existed: the template renders, the generator constrains, the history
--  parses a reply and holds a tool turn, the runner answers a call. What was
--  missing was the thing that ran them in a circle, and this is only that.
--
--  The reply is always grammar-constrained. A model offered tools is
--  generated against a grammar compiled from those tools, so a call it writes
--  always parses and always names a tool the caller has. That is the property
--  the loop relies on: it never has to wonder whether a call it read is one
--  it can run.
--
--  Task safety: Run executes on the calling task and takes the session, the
--  history and the runner for its duration.
package Model_Runner.Agent is

   --  Why the loop stopped. Every run ends with exactly one of these.
   type Stop_Reason is
     (Answered,           --  the model replied with no call to run
      Step_Limit,         --  the step budget ran out with a call still open
      Timed_Out,          --  the wall-clock budget ran out between steps
      Repeating,          --  a turn made only calls already made, and got
                          --  no further, so the loop stopped rather than
                          --  circle
      Render_Failed,      --  the conversation would not render
      Grammar_Failed,     --  the tool grammar would not compile
      Generation_Failed,  --  a generation ended in a runtime error
      History_Failed,     --  a turn would not fit the history
      Cancelled,          --  the caller cancelled a generation
      Declined);          --  an approver stopped the run before a call ran

   --  What a run did.
   type Outcome is record
      Reason : Stop_Reason := Answered;

      --  Model turns taken: one per generation, whether it answered or
      --  called.
      Steps : Natural := 0;

      --  Tool calls run over the whole loop.
      Calls : Natural := 0;

      --  Generations that failed with a runtime error and were retried. A
      --  run that never stumbled reports zero.
      Retries : Natural := 0;

      --  Tokens the model generated over the whole loop, summed across the
      --  turns it took. The decode cost of the run in one number.
      Generated_Tokens : Natural := 0;

      --  The prompt token count of the last turn -- the whole conversation,
      --  tools and all, as it stood when the loop ended. How much of the
      --  context the run came to occupy, rather than a sum that would count
      --  the reused prefix once per turn.
      Prompt_Tokens : Natural := 0;

      --  How many times the conversation was compacted to keep rendering --
      --  the oldest turns dropped to make room. Zero for a run that stayed
      --  within its space, or one that was not asked to compact.
      Compactions : Natural := 0;

      --  The diagnostic behind a failing reason, or Success.
      Error : Model_Runner.Errors.Error_Info;
   end record;

   --  Somewhere for the loop to report what it does as it does it.
   --
   --  The loop leaves the whole transcript in the history for a caller to
   --  read after, but a caller that wants to watch it happen -- print a call
   --  as the model makes it, log a tool's answer as it comes back -- reads
   --  it here instead of waiting for the end. A caller that wants neither
   --  passes null and pays for nothing.
   --
   --  Task safety: the loop calls these on its own task, in order, one at a
   --  time.
   type Observer is limited interface;

   --  A call the model made, about to be run.
   --
   --  @param Self The observer.
   --  @param Named The function the model called.
   --  @param Arguments The arguments, as one line of JSON.
   procedure On_Call
     (Self      : in out Observer;
      Named     : String;
      Arguments : String) is abstract;

   --  What running that call returned, about to be fed back to the model.
   --
   --  @param Self The observer.
   --  @param Named The function that was run.
   --  @param Result The text the tool answered with.
   procedure On_Result
     (Self   : in out Observer;
      Named  : String;
      Result : String) is abstract;

   --  A reference to whatever is watching the loop.
   type Observer_Reference is access all Observer'Class;

   --  What an approver decides about a call the model wants to make.
   type Verdict is
     (Allow,    --  run the call
      Deny,     --  do not run it; the model is told and may try another way
      Halt);   --  do not run it and stop the whole loop

   --  Something the loop asks before it runs a call.
   --
   --  The built-in tools reach the world -- a shell, a file, the network --
   --  and a caller that wants a hand on that gate passes an approver. The
   --  loop asks it once for each fresh call the model makes, before the call
   --  is run, and does what the verdict says: Allow runs it, Deny declines it
   --  and tells the model so (which may make it try another way), Halt stops
   --  the run with Reason => Declined. A repeat of a call already made, and a
   --  call to a tool not offered, are not asked about -- they never run. A
   --  caller that wants no gate passes null, and every call runs.
   --
   --  Task safety: the loop calls this on its own task, once per fresh call,
   --  after it has announced the call to any observer and before it runs it.
   type Approver is limited interface;

   --  Decide whether a call may run.
   --
   --  @param Self The approver.
   --  @param Named The function the model called.
   --  @param Arguments The arguments, as one line of JSON.
   --  @return Allow to run it, Deny to decline it, Halt to stop the run.
   function Consider
     (Self      : in out Approver;
      Named     : String;
      Arguments : String) return Verdict is abstract;

   --  A reference to whatever is gating the loop's calls.
   type Approver_Reference is access all Approver'Class;

   --  Run a conversation to an answer.
   --
   --  The history is the caller's to seed and the caller's to read after.
   --  Seed it with the system message and the first user turn; this appends
   --  the assistant turns and the tool turns, and leaves the whole
   --  transcript in it when it returns, answered or not.
   --
   --  @param Source Prepared model. Its template must be renderable.
   --  @param Session Open session on that model; advanced by this call.
   --  @param Messages The conversation, seeded by the caller; extended here.
   --  @param Offered The tools on offer. May be empty, in which case the
   --    first reply answers and the loop is one step.
   --  @param Executor What runs a call. Asked once per call the model makes;
   --    a call to a tool not offered is answered here without asking it.
   --  @param Generation The sampling and token budget for each reply. Its
   --    Add_Beginning, Retain_Text and Reuse_Committed_Prefix are set by the
   --    loop and whatever the caller put in them is ignored: a conversation
   --    is always rendered through the template, the reply is always read
   --    back, and the cache always holds a prefix of the growing prompt.
   --  @param Stop_Set Stop tokens and strings for each reply.
   --  @param Sink Where each reply's text is streamed, or null to discard
   --    it. The text is retained regardless, because the loop has to read it.
   --  @param Time Monotonic clock, or null.
   --  @param Seeds Entropy source used when a request has no explicit seed.
   --  @param Cancel Cancellation token, or null.
   --  @param Max_Steps Most model turns before the loop gives up on an open
   --    call. A task that needs one tool and an answer takes two.
   --  @param Max_Seconds A wall-clock budget for the whole loop, or 0.0 for
   --    none. It is checked between steps -- a single generation is bounded
   --    by its token budget, not this -- so the loop may overrun by the one
   --    generation in flight when the budget passes, and then stops. Needs
   --    Time; with no clock there is nothing to measure and the budget is
   --    ignored.
   --  @param Thinking Whether to ask the template for a thinking block.
   --  @param Watch Where the loop reports each call and each tool result as
   --    they happen, or null for none.
   --  @param Approve The gate asked before each fresh call runs, or null to
   --    run every call. A Deny declines the one call and tells the model; an
   --    Halt stops the run with Reason => Declined.
   --  @param Max_Retries How many times a generation that ends in a runtime
   --    error is reset and tried again before the loop gives up. The retried
   --    step is not counted against Max_Steps, and the count of retries is in
   --    the outcome. Zero, the default, fails on the first runtime error as
   --    the loop always did.
   --  @param Compact Whether to compact the conversation and carry on when it
   --    grows too large to render, rather than stopping. With it on, a render
   --    that overflows drops the oldest turns -- keeping the system message,
   --    the task, and the most recent Keep_Recent turns -- and renders again;
   --    off, the default, such an overflow stops the loop with Render_Failed
   --    as it always did.
   --  @param Keep_Recent How many recent turns compaction keeps whole. Only
   --    consulted when Compact is on.
   --  @param Bounds Session limits applied to rendering and generation.
   --  @param Result Why it stopped, how far it got, and any diagnostic.
   procedure Run
     (Source     : Model_Runner.Llama.Model'Class;
      Session    : in out Model_Runner.Llama.Session;
      Messages   : in out Model_Runner.Conversation.History;
      Offered    : Model_Runner.Tools.Definitions;
      Executor   : in out Model_Runner.Tools.Runner.Instance'Class;
      Generation : Model_Runner.Generation.Request;
      Stop_Set   : Model_Runner.Stops.Set;
      Sink       : Model_Runner.Output.Sink_Reference;
      Time       : Model_Runner.Clocks.Clock_Reference;
      Seeds      : Model_Runner.Entropy.Source_Reference;
      Cancel     : Model_Runner.Cancellation.Token_Reference := null;
      Max_Steps  : Positive := 8;
      Max_Seconds : Duration := 0.0;
      Thinking   : Model_Runner.Templates.Thinking_Choice :=
        Model_Runner.Templates.Thinking_Unstated;
      Watch      : Observer_Reference := null;
      Approve    : Approver_Reference := null;
      Max_Retries : Natural := 0;
      Compact     : Boolean := False;
      Keep_Recent : Positive := 6;
      Bounds     : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Result     : out Outcome);

end Model_Runner.Agent;
