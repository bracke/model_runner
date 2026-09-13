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
      Render_Failed,      --  the conversation would not render
      Grammar_Failed,     --  the tool grammar would not compile
      Generation_Failed,  --  a generation ended in a runtime error
      History_Failed,     --  a turn would not fit the history
      Cancelled);         --  the caller cancelled a generation

   --  What a run did.
   type Outcome is record
      Reason : Stop_Reason := Answered;

      --  Model turns taken: one per generation, whether it answered or
      --  called.
      Steps : Natural := 0;

      --  Tool calls run over the whole loop.
      Calls : Natural := 0;

      --  The diagnostic behind a failing reason, or Success.
      Error : Model_Runner.Errors.Error_Info;
   end record;

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
   --  @param Thinking Whether to ask the template for a thinking block.
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
      Thinking   : Model_Runner.Templates.Thinking_Choice :=
        Model_Runner.Templates.Thinking_Unstated;
      Bounds     : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Result     : out Outcome);

end Model_Runner.Agent;
