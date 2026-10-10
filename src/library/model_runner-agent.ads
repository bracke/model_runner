with Ada.Strings.Unbounded;

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
      Timed_Out,          --  the wall-clock budget ran out
      Token_Limit,        --  the cumulative token budget ran out
      Repeating,          --  a turn made only calls already made, and got
                          --  no further, so the loop stopped rather than
                          --  circle
      Render_Failed,      --  the conversation would not render
      Grammar_Failed,     --  the tool grammar would not compile
      Generation_Failed,  --  a generation ended in a runtime error
      History_Failed,     --  a turn would not fit the history
      Cancelled,          --  the caller cancelled a generation
      Declined);          --  an approver stopped the run before a call ran

   --  What a stop asks of whoever acts on it, decided here once rather
   --  than by each caller for itself. Finished: the run answered.
   --  Exhausted: a budget ran out -- steps, tokens, time -- and more of it
   --  takes the run on from where it is. Retryable: the same again may go
   --  through, a backend's failure being passing. Needs_Change: the same
   --  again would end the same way -- the run went round, or its
   --  conversation would not render -- so going on wants a changed context
   --  or approach. Needs_User: a person stopped it, by cancelling or by
   --  declining a call, and it waits on them.
   type Stop_Traits is record
      Finished     : Boolean := False;
      Exhausted    : Boolean := False;
      Retryable    : Boolean := False;
      Needs_Change : Boolean := False;
      Needs_User   : Boolean := False;
   end record;

   --  A stop's traits.
   --
   --  @param Reason Why the loop stopped.
   --  @return What it asks.
   function Traits_Of (Reason : Stop_Reason) return Stop_Traits
   is (case Reason is
         when Answered          => (Finished => True, others => False),
         when Step_Limit | Token_Limit | Timed_Out =>
           (Exhausted => True, others => False),
         when Generation_Failed => (Retryable => True, others => False),
         when Repeating | Render_Failed | Grammar_Failed | History_Failed =>
           (Needs_Change => True, others => False),
         when Cancelled | Declined => (Needs_User => True, others => False));

   --  A reply as an answer: what follows its reasoning. A model whose
   --  template opens a think block before the reply -- Qwen3.5's -- writes
   --  its reasoning and closes the block with "</think>"; the answer is
   --  what comes after the last such close, and a reply with none is its
   --  answer whole.
   --
   --  @param Reply The reply's text.
   --  @return The answer.
   function Answer_Of (Reply : String) return String;

   --  A stop in words: "step limit", "timed out".
   --
   --  @param Reason Why the loop stopped.
   --  @return It, in lower case with spaces.
   function Reason_Words (Reason : Stop_Reason) return String;

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

      --  Tokens child agents generated for the run's calls: its budget
      --  spent, though not by its own model turns.
      Delegated_Tokens : Natural := 0;

      --  The prompt token count of the last turn -- the whole conversation,
      --  tools and all, as it stood when the loop ended. How much of the
      --  context the run came to occupy, rather than a sum that would count
      --  the reused prefix once per turn.
      Prompt_Tokens : Natural := 0;

      --  How many times the conversation was compacted to keep rendering --
      --  the oldest turns dropped to make room. Zero for a run that stayed
      --  within its space, or one that was not asked to compact.
      Compactions : Natural := 0;

      --  How many replies' thoughts reached Think_Budget and were closed
      --  for them.
      Thoughts_Closed : Natural := 0;

      --  The diagnostic behind a failing reason, or Success.
      Error : Model_Runner.Errors.Error_Info;

      --  The work as the loop saw it happen -- what was changed, read,
      --  failed and not answered since, refused -- the record a compacted
      --  conversation carries, for the caller to show; empty when no call
      --  ran.
      Work_Record : Ada.Strings.Unbounded.Unbounded_String;
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

   --  One call the model made, as the loop knows it: its number in the run
   --  -- every call its own, in the order made, a repeat too -- and its
   --  place among the calls its turn asked for. A watcher reads which call
   --  a result answers, and whether calls came several at once, from this
   --  rather than working it out from the order things arrived in.
   type Invocation is record
      Id      : Positive := 1;
      In_Turn : Positive := 1;
      Of_Turn : Positive := 1;

      --  Whether the runner says the call may change state: a watcher
      --  that keeps a record notes such a call as started before it runs.
      Changes : Boolean := False;
   end record;

   --  A turn the model took that asked for calls, before any is run: how
   --  many it asked for, so a watcher knows a batch for one before its
   --  first call arrives. The default does nothing.
   --
   --  @param Self The observer.
   --  @param Step The model's turn, counting from one.
   --  @param Calls How many calls it asked for.
   procedure On_Turn
     (Self  : in out Observer;
      Step  : Positive;
      Calls : Positive) is null;

   --  A call the model made, about to be run.
   --
   --  @param Self The observer.
   --  @param Call Which call.
   --  @param Named The function the model called.
   --  @param Arguments The arguments, as one line of JSON.
   procedure On_Call
     (Self      : in out Observer;
      Call      : Invocation;
      Named     : String;
      Arguments : String) is abstract;

   --  What running that call returned, about to be fed back to the model.
   --  The results of a turn come in the order its calls were made.
   --
   --  @param Self The observer.
   --  @param Call Which call it answers.
   --  @param Named The function that was run.
   --  @param Arguments Its arguments, as On_Call had them.
   --  @param Result The text the tool answered with.
   --  @param Ended How it ended -- answered, failed, or refused and by
   --    what, and whether it changed state -- for a watcher to act on
   --    rather than the words; a repeat answered from an earlier call
   --    ends as that call did.
   procedure On_Result
     (Self      : in out Observer;
      Call      : Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Model_Runner.Tools.Runner.Call_Outcome) is abstract;

   --  A step has finished: the model's turn and every tool result it drew are
   --  in the history now. Called once at the close of each step that ran
   --  tools, before the next begins, so a watcher can persist the run's
   --  progress as it goes. The default does nothing.
   --
   --  @param Self The observer.
   procedure On_Step (Self : in out Observer) is null;

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

   --  What the loop holds of the calls made -- what each answered, the
   --  revisions each file was seen at, whether anything has changed --
   --  kept by a caller that runs the loop again on the same conversation,
   --  so the second run knows what the first saw. Recall.Carried is the
   --  one there is.
   type Run_Memory is abstract tagged limited null record;

   --  A reference to the memory carried between runs.
   type Memory_Reference is access all Run_Memory'Class;

   --  What closes a thought held to its budget, the rest of the reply
   --  asked for after it.
   Thought_Closing : constant String := ASCII.LF & "</think>" & ASCII.LF & ASCII.LF;

   --  Whether a reply is inside a thought it has not closed: one it opened,
   --  or one the prompt opened for it, its last bytes holding the opening.
   --
   --  @param Reply What the reply has said.
   --  @param Prompt The prompt it follows.
   --  @return True when the thought is open.
   function Thought_Open (Reply, Prompt : String) return Boolean;

   --  What went wrong in a step, as the loop decides what to do about it:
   --  a conversation too large to render, a generation that ran out of
   --  context, a backend that failed in a way trying again may mend, a
   --  reply whose call could not be read, a cancellation, or anything else.
   type Failure_Class is
     (Too_Large_To_Render, Context_Exhausted, Backend_Error, Unreadable_Call,
      Interrupted, Other_Failure);

   --  What the loop does about it: make room and try the step again, try
   --  it again as it was, tell the model what went wrong and let it try
   --  again, or stop.
   type Recovery_Action is (Compact_And_Retry, Retry_Same, Return_To_Model, Stop);

   --  The class of a failure's diagnostic.
   --
   --  @param Status What failed.
   --  @return Its class.
   function Class_Of (Status : Model_Runner.Errors.Error_Info) return Failure_Class;

   --  The loop's answer to a failure: the harness decides, not the model.
   --  Room is made where the caller lets the loop compact; a backend error
   --  is tried again while retries are left; a call that would not read is
   --  given back to the model while chances are left; nothing else is
   --  tried again.
   --
   --  @param Failure What went wrong.
   --  @param May_Compact Whether the loop may drop old turns.
   --  @param Retries_Left Generation retries left.
   --  @param Chances_Left Times left to give an unreadable call back.
   --  @return What to do.
   function Recovery_For
     (Failure      : Failure_Class;
      May_Compact  : Boolean;
      Retries_Left : Natural;
      Chances_Left : Natural) return Recovery_Action
   is (case Failure is
         when Too_Large_To_Render | Context_Exhausted =>
           (if May_Compact then Compact_And_Retry else Stop),
         when Backend_Error =>
           (if Retries_Left > 0 then Retry_Same else Stop),
         when Unreadable_Call =>
           (if Chances_Left > 0 then Return_To_Model else Stop),
         when Interrupted | Other_Failure => Stop);

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
   --    none. It is the deadline everything the run does runs within: a
   --    reply stops at it between tokens, and a tool's process and a child
   --    agent stop at it, so neither a long reply nor a call that hangs
   --    outlasts the run. Needs Time; with no clock there is nothing to
   --    measure and the budget is ignored.
   --  @param Max_Total_Tokens A ceiling on the tokens generated over the whole
   --    loop, child agents' included, or 0 for none. Each generation is asked
   --    for no more than is left, so the ceiling holds; a turn the ceiling
   --    cut short ends the loop with Token_Limit.
   --  @param Max_Parallel How many of a turn's calls may run at once. One, the
   --    default, runs them one after another as before. More lets calls the
   --    Executor marks parallel-safe (see Runner.Parallel_Safe) overlap on up
   --    to this many worker tasks; every other call, and every dedup and
   --    approval decision, stays on this task, and results are appended in
   --    call order whatever order they finished in.
   --  @param Tool_Syntax The shape the model writes its calls in, which the
   --    loop reads them back by and the call grammar shapes. The default,
   --    Tool_Call_JSON, is the <tool_call> convention; Function_XML
   --    (MiniCPM's <function>/<param>) and Qwen_XML (Qwen3-Coder's
   --    <function=..>/<parameter=..>) are shaped as tags, a <think> block
   --    admitted ahead of the reply; Open_JSON (Gemma's) reads the envelope
   --    and the bare or fenced object a model writes instead, and is left
   --    free where tools are offered.
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
   --  @param Answer_Schema A JSON schema the model's final answer must match,
   --    or the empty string for a free-text answer. When given, every reply
   --    is constrained to a tool call or an object in this shape, so the
   --    answer the loop ends on is valid against the schema. Honoured when
   --    the tools' own schema grammar can be built, or when no tools are
   --    offered; a tool that forces the looser call grammar leaves the answer
   --    free. Left as the empty string, the answer is prose as before.
   --  @param Bounds Session limits applied to rendering and generation.
   --  @param Pictures The pictures the task shows, or none: the same rows
   --    stand behind the prompt's markers at every step.
   --  @param Think_Budget The tokens a reply may think for before its
   --    thought is closed for it and the rest of the reply is asked for:
   --    a reasoning model spent minutes a call thinking. 0 for no bound.
   --  @param Carry What an earlier run on this conversation held of its
   --    calls, carried on and added to; null for a run that starts afresh.
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
      Max_Total_Tokens : Natural := 0;
      Max_Parallel : Positive := 1;
      Tool_Syntax : Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Tools.Tool_Call_JSON;
      Thinking   : Model_Runner.Templates.Thinking_Choice :=
        Model_Runner.Templates.Thinking_Unstated;
      Watch      : Observer_Reference := null;
      Approve    : Approver_Reference := null;
      Max_Retries : Natural := 0;
      Compact     : Boolean := False;
      Keep_Recent : Positive := 6;
      Answer_Schema : String := "";
      Pictures    : Model_Runner.Generation.Picture_Set :=
        Model_Runner.Generation.No_Pictures;
      Bounds     : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Think_Budget : Natural := 0;
      Carry      : Memory_Reference := null;
      Result     : out Outcome);

end Model_Runner.Agent;
