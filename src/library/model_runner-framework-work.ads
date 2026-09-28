with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Context;
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
   end record;

   --  Put back the tasks whose agents stopped without finishing: a running
   --  task whose lease has run out is blocked, with why, and its agent
   --  recorded as failed.
   --
   --  @param Item The store.
   --  @param Recovered The tasks put back.
   --  @param Status A failure committing it.
   procedure Recover
     (Item      : in out Stores.Store;
      Recovered : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info);

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
     (Item    : in out Stores.Store;
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
   --    conflict.
   procedure Take_In
     (Item    : in out Stores.Store;
      Task_Id : String;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Stop the work on a running task: its agent is recorded cancelled, its
   --  lease let go, a workspace written for it abandoned, and the task
   --  cancelled.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Status Framework_Transition_Invalid when it is not in a state
   --    that can be cancelled.
   procedure Cancel
     (Item    : in out Stores.Store;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The instructions an agent is given after its context: how to answer.
   --
   --  @return The text.
   function Instructions return String;

end Model_Runner.Framework.Work;
