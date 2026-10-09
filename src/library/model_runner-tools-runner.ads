with Ada.Real_Time;

with Model_Runner.Cancellation;
with Model_Runner.Errors;

--  The end of a tool call this package would not close.
--
--  The parent says a tool call is text the model wrote and a tool result is
--  text the caller hands back, and that the loop closes outside this program
--  or not at all. This is the shape of the thing that closes it: a caller
--  derives from Runner, and its one primitive turns a call the model wrote
--  into the text handed back to the model. What the derivation does to
--  produce that text is the caller's, and it is where a process is started
--  or a socket opened if one is -- so the parent's promise holds, because the
--  side effect lives in the caller's type and not in this library.
--
--  The agent loop asks a Runner to run each call the model made, appends what
--  it returns as a tool turn, and renders again. A Runner that answers every
--  call with a fixed reply is a mock; one that reaches a real tool is an
--  integration; the loop cannot tell them apart and does not try to.
--
--  Task safety: a Runner is used by the task that drives the loop it belongs
--  to. Whether two loops may share one is the derivation's to state.
package Model_Runner.Tools.Runner is

   --  Something that answers a tool call. Derive from it.
   type Instance is abstract tagged limited private;

   --  What a call runs within, set by whoever runs it: the cancellation it
   --  answers to, the time by which it must be done, and how many tokens a
   --  child agent it starts may still generate. A tool that waits -- on a
   --  process, a child agent -- stops at the first of these and says so; a
   --  run's budget is the budget of everything it does, not a check made
   --  between the things it does.
   type Tool_Context is record
      Cancel      : Model_Runner.Cancellation.Token_Reference := null;
      Deadline    : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Tokens_Left : Natural := Natural'Last;

      --  How deep the agent making the calls is: nought for the run's own,
      --  one for its helper, and so on.
      Depth       : Natural := 0;
   end record;

   --  No cancellation, no deadline, no token ceiling.
   No_Context : constant Tool_Context;

   --  Give a runner the context its next calls run within.
   --
   --  @param Self The runner.
   --  @param Context The context.
   procedure Set_Context (Self : in out Instance'Class; Context : Tool_Context);

   --  The context a runner's calls run within.
   --
   --  @param Self The runner.
   --  @return Its context; No_Context until one is set.
   function Context_Of (Self : Instance'Class) return Tool_Context;

   --  Whether a context says stop: cancelled, or past its deadline.
   --
   --  @param Context The context.
   --  @return Whether to stop now.
   function Stopped (Context : Tool_Context) return Boolean;

   --  How long a context leaves, at most Most.
   --
   --  @param Context The context.
   --  @param Most The longest wanted.
   --  @return The time left, never more than Most and never negative.
   function Time_Left (Context : Tool_Context; Most : Duration) return Duration;

   --  Make a context the one the calling task's waits answer to, for a wait
   --  that can only ask a function with no arguments whether to stop.
   --
   --  @param Context The context.
   procedure Enter (Context : Tool_Context);

   --  The context the calling task entered; No_Context when none.
   --
   --  @return It.
   function Entered_Context return Tool_Context;

   --  Whether the context the calling task entered says stop.
   --
   --  @return Whether to stop now.
   function Stop_Now return Boolean;

   --  What a call does to the state a later call reads, which decides
   --  whether a later identical call may be answered from an earlier one.
   --  Reads answers from that state and changes none of it: an identical
   --  call is answered the same until a call that Changes has run, and
   --  runs again after. Changes may change it -- a write, a process, a
   --  child agent -- and every answer given before it is stale once it has
   --  run; an identical call with nothing between is still not run twice.
   --  Varies answers differently each time though nothing changed -- a
   --  clock -- and always runs.
   type Call_Kind is (Reads, Changes, Varies);

   --  How a call ended, for the loop and whatever watches it to act on --
   --  never read back out of the words of the result, which are the
   --  model's. Answered: the tool did what was asked. Failed: it could not
   --  -- a file not there, a program that exited badly. Refused: it was
   --  not let -- and Refusal says by what.
   --  Timed_Out: it was stopped at its context's deadline. Cancelled: at
   --  its context's cancellation.
   type Answer_Kind is (Answered, Failed, Refused, Timed_Out, Cancelled);

   --  What refused a call. Outside_Project: a path out of the tree the
   --  agent works in, which no permission reaches. Harness_Owned: the
   --  project's state or its version control, which only the harness
   --  writes. Not_Permitted: the agent's permissions or a sandbox. Policy:
   --  the execution policy, which names the programs that may run.
   type Refusal_Kind is
     (Not_Refused, Outside_Project, Harness_Owned, Not_Permitted, Policy);

   --  A call's ending, beside the text the model is given. Changed says
   --  whether the state later calls read is different for it: a write of
   --  what a file already held changed nothing, and a run of a program or
   --  a child agent is taken to have changed what it may.
   --  Truncated says the text the model is given is not all the tool
   --  said; Tokens, what a child agent the call started generated, which
   --  is the caller's budget spent.
   type Call_Outcome is record
      Answer    : Answer_Kind := Answered;
      Refusal   : Refusal_Kind := Not_Refused;
      Changed   : Boolean := False;
      Truncated : Boolean := False;
      Tokens    : Natural := 0;
   end record;

   --  An answer that did what it was asked.
   Done : constant Call_Outcome :=
     (Answer => Answered, Refusal => Not_Refused, Changed => False,
      Truncated => False, Tokens => 0);

   --  Run one call and write back what the model should be told.
   --
   --  A result is text, whatever the tool is: a number is its digits, a
   --  table is its rows, a failure is a sentence saying so. The model reads
   --  it as the tool's answer either way, so an error is written into the
   --  result rather than raised out of it -- a tool that cannot answer has
   --  still answered, and the conversation goes on. Status is for the loop
   --  itself failing to hold the answer, not for the tool disagreeing with
   --  the call.
   --
   --  @param Self The runner.
   --  @param Named The function the model called.
   --  @param Arguments The arguments the model wrote, as one line of JSON.
   --  @param Result Buffer receiving the answer, written from its first
   --    index. Size it at least Model_Runner.Tools.Max_Call_Bytes.
   --  @param Last Number of bytes written; 0 when nothing was.
   --  @param Outcome How the call ended: answered, failed or refused, and
   --    by what. Set whatever Status says.
   --  @param Status Success, or Tools_Too_Large when the answer would not
   --    fit the buffer. A tool's own failure is not an error here: it is a
   --    result that says the tool failed, and an Outcome that says so too.
   procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info) is abstract;

   --  Run one call for its words alone, how it ended dropped: for a caller
   --  that hands the answer on and acts on nothing about it.
   --
   --  @param Self The runner.
   --  @param Named As the primitive.
   --  @param Arguments As the primitive.
   --  @param Result As the primitive.
   --  @param Last As the primitive.
   --  @param Status As the primitive.
   procedure Run
     (Self      : in out Instance'Class;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

   --  What a call to the named tool does to the state later calls read;
   --  see Call_Kind. Changes unless a runner says otherwise, since a tool
   --  nothing is known of may change anything.
   --
   --  @param Self The runner.
   --  @param Named The function the model called.
   --  @return Its kind.
   function Kind (Self : Instance; Named : String) return Call_Kind
   is (Changes);

   --  Whether a call to the named tool may run beside other calls the model
   --  made in the same turn, on another task. The loop runs a runner's calls
   --  one after another unless the runner marks a tool safe to overlap, so the
   --  default is False and a runner opts in tool by tool. Answer True only for
   --  a tool that, run beside another, touches nothing the other does -- none
   --  of the runner's own mutable state and no single resource two calls would
   --  share -- so the two may proceed at once; True is then also a promise
   --  that Run may be entered from more than one task at a time for that tool.
   --  A tool whose work is a process this program waits on is a common
   --  counter-example: waiting reaps whichever child ended, not a chosen one,
   --  so two such calls at once cross their results.
   --
   --  @param Self The runner.
   --  @param Named The function the model called.
   --  @return Whether a call to it may overlap another call in the turn.
   function Parallel_Safe
     (Self : Instance; Named : String) return Boolean is (False);

private

   No_Context : constant Tool_Context :=
     (Cancel => null, Deadline => Ada.Real_Time.Time_Last,
      Tokens_Left => Natural'Last, Depth => 0);

   type Instance is abstract tagged limited record
      Context : Tool_Context;
   end record;

end Model_Runner.Tools.Runner;
