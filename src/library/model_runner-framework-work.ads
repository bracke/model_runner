with Ada.Calendar;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Stores;

--  One task, run from ready to done by one agent.
--
--  A project whose configuration says scalar work.isolation = workspace
--  has its agents write in a workspace of their own, taken into the
--  project only by integration: by the harness at once when scalar
--  work.integrate = automatic, and otherwise by whoever has the right,
--  through Take_In. Verification then runs on the project as integrated.
--
--  Work on a task is a sequence the harness holds, not the agent: take a
--  lease on the task for a new agent record and start a new execution
--  generation; build the task's context and keep its manifest; record the
--  model invocation; let the agent work; read its answer against the work
--  contract; see for itself which files changed, whatever the answer says;
--  then run the task's verification and complete it through its gates, or
--  block it, or fail it, with the reason -- and let the lease go. Each step
--  is committed as it is taken, so a session that stops half way leaves a
--  state that says how far it got, and the next one finds a task whose
--  agent stopped and puts it back rather than leaving it running for ever.
--
--  The agent may write only where its permissions say: a file changed
--  outside its write_source roots, or inside a denied path, fails the task,
--  and its workspace, if it had one, is not taken in.
--
--  What the agent is, is the caller's: the command runs a model, a test runs
--  a script. The harness gives it the context in a file and takes an answer
--  back; it never gives it the right to change project state.
--
--  An agent that can have children of its own -- a Parenting_Runner -- is
--  handed a Child_Host with its context. A child is asked for there and
--  made by the harness, within what its parent was given; it gets a
--  context built for it alone, its answer is held to the child result
--  contract and kept, and its parent is told the result, never the
--  conversation that led to it. A required child that fails is run once
--  more (scalar agents.child_retries), and if it still fails its parent
--  cannot complete: the task is blocked, or failed where scalar
--  agents.on_child_failure = fail. A child left open when its parent stops
--  is recorded failed, so no child's failure goes unseen.
package Model_Runner.Framework.Work is

   --  Whatever does the work: given where its context is, it works in the
   --  project and answers.
   type Agent_Runner is interface;

   --  Run the agent.
   --
   --  @param Self The runner.
   --  @param Prompt_Path The file its context and instructions are in.
   --  @param Project The project directory it works in.
   --  @param Answer What it answered.
   --  @param Status A failure to run it at all.
   procedure Run
     (Self        : Agent_Runner;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is abstract;

   --  Where a working agent's children are made and answered for.
   type Child_Host (<>) is tagged limited private;

   --  Make a child of the agent now working -- the root, or the innermost
   --  child still open -- and build the context it is given.
   --
   --  @param Host The host.
   --  @param Role What the child is for, as the parent names it.
   --  @param Need required, optional or advisory; anything else is required.
   --  @param Brief What the child is asked, in the parent's words.
   --  @param Retry_Of The child this one is run again for, or "".
   --  @param Child_Id The child.
   --  @param Context What it is told.
   --  @param Budget The tokens it may generate.
   --  @param Status Framework_Permission_Denied when the parent may not
   --    create children, Framework_Limit_Exceeded past a limit.
   procedure Open_Child
     (Host     : in out Child_Host;
      Role     : String;
      Need     : String;
      Brief    : String;
      Retry_Of : String;
      Child_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Context  : out Ada.Strings.Unbounded.Unbounded_String;
      Budget   : out Natural;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Take the innermost open child's answer: hold it to the child result
   --  contract, keep it, charge what it used and record how it ended.
   --
   --  @param Host The host.
   --  @param Answer What it answered.
   --  @param Tokens The tokens it generated.
   --  @param Ran A failure to run it at all.
   --  @param Told What its parent is told: the result, not the transcript.
   --  @param Retry Whether it is to be run again, with Retry_Of naming it.
   --  @param Prompt_Tokens How long its conversation came to be, in tokens.
   procedure Close_Child
     (Host   : in out Child_Host;
      Answer : String;
      Tokens : Natural;
      Ran    : Model_Runner.Errors.Error_Info;
      Told   : out Ada.Strings.Unbounded.Unbounded_String;
      Retry  : out Boolean;
      Prompt_Tokens : Natural := 0);

   --  Record a tool call the agent now working made, on its invocation.
   --
   --  @param Host The host.
   --  @param Named The tool.
   --  @param Arguments Its arguments.
   --  @param Answer What it answered.
   procedure Note_Call
     (Host      : in out Child_Host;
      Named     : String;
      Arguments : String;
      Answer    : String);

   --  The agent now working: the root, or the innermost open child.
   --
   --  @param Host The host.
   --  @return Its id.
   function Current (Host : Child_Host) return String;

   --  Whether the agent now working may do something.
   --
   --  @param Host The host.
   --  @param What The capability.
   --  @param Path Where, for a capability with roots; "" for anywhere.
   --  @return True when it is granted there.
   function May
     (Host : Child_Host;
      What : Permissions.Capability;
      Path : String := "") return Boolean;

   --  How many model turns the root agent may take: the task kind's scalar
   --  task.max_steps.KIND, else agents.max_steps, else 24.
   --
   --  @param Host The host.
   --  @return The limit.
   function Steps (Host : Child_Host) return Positive;

   --  How many tool calls an agent on the task may make: the kind's scalar
   --  task.max_tool_calls.KIND, else agents.max_tool_calls; zero for no
   --  bound but its steps.
   --
   --  @param Host The host.
   --  @return The budget.
   function Tool_Budget (Host : Child_Host) return Natural;

   --  How long the agents on the task may still work, root and children
   --  together: from the kind's scalar task.max_seconds.KIND, else
   --  agents.max_seconds, else the task's lease, which work must not
   --  outlive. Never less than a second while any is left to give.
   --
   --  @param Host The host.
   --  @return The time left, or 0.0 for no bound.
   function Time_Left (Host : Child_Host) return Duration;

   --  The verification profile the task is checked with.
   --
   --  @param Host The host.
   --  @return Its name, or "" when none applies.
   function Task_Profile (Host : Child_Host) return String;

   --  Whether the agent now working may run a verification profile: run_build
   --  for a profile whose name says build, run_static_analysis for one that
   --  says analysis or lint, run_tests for any other -- each within its
   --  profiles -- and only where it works in the project itself, not in a
   --  workspace of its own the checks would not see.
   --
   --  @param Host The host.
   --  @param Profile The profile.
   --  @return True when it may.
   function May_Check (Host : Child_Host; Profile : String) return Boolean;

   --  Run a verification profile for the agent now working, and say how it
   --  went: each check, and for one that failed what it reported. The
   --  evidence is kept, as any other.
   --
   --  @param Host The host.
   --  @param Profile The profile.
   --  @param Report What the agent is told.
   --  @param Status A failure to run it at all.
   procedure Run_Checks
     (Host    : in out Child_Host;
      Profile : String;
      Report  : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Count tokens the agent now working generated against its budget.
   --
   --  @param Host The host.
   --  @param Tokens How many.
   --  @param Prompt_Tokens How long its conversation came to be.
   procedure Spend
     (Host          : in out Child_Host;
      Tokens        : Natural;
      Prompt_Tokens : Natural := 0);

   --  An agent that can have children: it is given the host they are made
   --  through as it runs.
   type Parenting_Runner is interface and Agent_Runner;

   --  The model it runs, as a context is budgeted for: its own limits, not
   --  a configured guess.
   --
   --  @param Self The runner.
   --  @return Its profile.
   function Profile (Self : Parenting_Runner) return Context.Model_Profile is abstract;

   --  Run the agent, with children made through Children.
   --
   --  @param Self The runner.
   --  @param Prompt_Path The file its context and instructions are in.
   --  @param Project The project directory it works in.
   --  @param Children Where its children are made.
   --  @param Answer What it answered.
   --  @param Status A failure to run it at all.
   procedure Run_Parenting
     (Self        : Parenting_Runner;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Child_Host'Class;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is abstract;

   --  What a run of work did.
   type Report is record
      Task_Id       : Ada.Strings.Unbounded.Unbounded_String;
      Agent_Id      : Ada.Strings.Unbounded.Unbounded_String;
      Invocation_Id : Ada.Strings.Unbounded.Unbounded_String;
      Manifest_Id   : Ada.Strings.Unbounded.Unbounded_String;
      Evidence_Id   : Ada.Strings.Unbounded.Unbounded_String;

      --  The workspace the agent wrote in, when the project isolates work.
      Workspace_Id  : Ada.Strings.Unbounded.Unbounded_String;

      --  What the agent claimed, and what the files show it changed.
      Claimed       : Ada.Strings.Unbounded.Unbounded_String;
      Summary       : Ada.Strings.Unbounded.Unbounded_String;
      Changed_Files : Name_Lists.Vector;

      --  Where the task ended, and why when not complete.
      Final_State   : Ada.Strings.Unbounded.Unbounded_String;
      Reason        : Ada.Strings.Unbounded.Unbounded_String;

      --  Requirements whose verification changed.
      Requirements  : Name_Lists.Vector;

      --  The agent's children, one a line: each one's need, how it ended,
      --  its result and summary.
      Children      : Name_Lists.Vector;

      --  The candidate tasks, decisions and specifications made from what it
      --  proposed.
      Proposed      : Name_Lists.Vector;

      --  The tasks it says this one should wait for: kept as said, not
      --  made so.
      Waits_For     : Name_Lists.Vector;

      --  How widely it was verified -- certain_tests, component_tests or
      --  full_suite -- and why.
      Scope         : Ada.Strings.Unbounded.Unbounded_String;
      Scope_Reason  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Put back the tasks whose agents stopped without finishing: a running
   --  task whose lease has run out is blocked, with why, and its agent and
   --  every child of it recorded as ended. Where scalar recovery.running
   --  says failed it is failed instead, and where it says accepted it is
   --  accepted again, for another try.
   --
   --  @param Item The store.
   --  @param Recovered The tasks put back.
   --  @param Status A failure committing it.
   procedure Recover
     (Item      : in out Stores.Store;
      Recovered : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Everything a project's state needs looked at when it is opened, with
   --  no conversation to go on: what the store's own recovery did to its
   --  transactions and index; tasks left running with no one running them
   --  (Recover); agents and invocations no one is running any more,
   --  recorded as abandoned; workspaces whose directory is gone or whose
   --  task has ended, abandoned; readiness and which requirements are
   --  verified, worked out again. What it cannot settle itself -- a
   --  workspace directory with no record -- it says, and leaves.
   --
   --  @param Item The store.
   --  @param Opened What opening the store recovered.
   --  @param Said What it found and did, one a line; empty when there was
   --    nothing to do.
   --  @param Status A failure committing it.
   procedure Recover_On_Opening
     (Item   : in out Stores.Store;
      Opened : Stores.Recovery_Report;
      Said   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info);

   --  Run one task.
   --
   --  @param Item The store.
   --  @param Task_Id The task, which must be ready.
   --  @param Runner The agent.
   --  @param Model The profile the context is budgeted for.
   --  @param Result What it did.
   --  @param Status Framework_Task_Not_Ready when the task is not ready,
   --    Framework_Lease_Held when another agent holds it; a failure of the
   --    agent itself ends the task failed and is reported in Result, not
   --    here.
   procedure Execute
     (Item    : aliased in out Stores.Store;
      Task_Id : String;
      Runner  : Agent_Runner'Class;
      Model   : Context.Model_Profile;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Take a task's workspace into the project, then verify the project as
   --  it now is and complete the task through its gates. Whoever asks is
   --  taken to have the right to integrate.
   --
   --  @param Item The store.
   --  @param Task_Id The task, in verification with a workspace waiting.
   --  @param Result What it did.
   --  @param Status Framework_Not_Found when the task has no workspace
   --    waiting, Framework_Integration_Conflict naming the files in
   --    conflict, or what the code joins when that is not accepted.
   --  @param Semantic_Accepted Whether the person takes it in whatever the
   --    code joins it to.
   procedure Take_In
     (Item    : in out Stores.Store;
      Task_Id : String;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False);

   --  Stop the work on a running task: its agent and every child of it
   --  still going are recorded cancelled, its lease let go, a workspace
   --  written for it abandoned, and the task cancelled.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Status Framework_Transition_Invalid when it is not in a state
   --    that can be cancelled.
   procedure Cancel
     (Item    : in out Stores.Store;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  What the state says about how a task came to be where it is, as
   --  question and answer, one a line -- the questions a completed task
   --  must answer without a conversation: the revisions that applied, why
   --  it could start, what the model was told and which model it was, what
   --  changed and where, what verified it and with which tools, what
   --  justified its completion, what integration took its work in, and
   --  what its requirements' verification became.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return The answers, as QUESTION: ANSWER.
   function Audit (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;

   --  What a child is told after its context: how to answer.
   --
   --  @return The text.
   function Child_Instructions return String;

   --  The instructions an agent is given after its context: how to answer.
   --
   --  @return The text.
   function Instructions return String;

private

   package Time_Vectors is new Ada.Containers.Vectors (Positive, Ada.Calendar.Time,
                                                        Ada.Calendar."=");

   type Child_Host (Item : not null access Stores.Store) is tagged limited record
      Task_Id : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether the agents write in a workspace apart from the project.
      Apart   : Boolean := False;

      --  What the checks run for the agents wrote, path and fingerprint
      --  separated by a tab: the agents' changes are what is left.
      Written : Name_Lists.Vector;

      --  The model contexts are budgeted for.
      Model   : Context.Model_Profile;

      --  Each open agent's invocation, and when it was opened, in step with
      --  Open.
      Calls   : Name_Lists.Vector;
      Opened  : Time_Vectors.Vector;

      --  How many turns the root may take, and tool calls each agent.
      Max_Steps   : Natural := 24;
      Max_Calls   : Natural := 0;

      --  When the work must be over, where it is bounded.
      Bounded     : Boolean := False;
      Deadline    : Ada.Calendar.Time := Ada.Calendar.Clock;

      --  What the root generated, and how long its conversation came to be.
      Root_Out    : Natural := 0;
      Root_Prompt : Natural := 0;

      --  The root, then each child still open, innermost last.
      Open    : Name_Lists.Vector;
   end record;

end Model_Runner.Framework.Work;
