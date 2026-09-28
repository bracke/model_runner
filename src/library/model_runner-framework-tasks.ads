with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Transitions;

--  Units of work, kept as project state.
--
--  A task is two records. Its definition says what the work is -- title,
--  kind, component, the requirements it serves, the tasks it waits for,
--  its parent, where it came from -- and changes only when the work is
--  redefined. Its runtime state says where the work stands -- candidate,
--  accepted, running and so on, the execution generation, why it is
--  blocked -- and changes only through the moves of the task lifecycle,
--  each checked, each recorded as an event. Neither is written as
--  arbitrary data.
--
--  Whether a task is ready is worked out, not stored: accepted, every
--  task it depends on complete, no children still open, the requirements
--  it serves still standing, and nobody else holding it. A cache of it is
--  kept only so that a change of it can be announced.
--
--  Kinds of task are the project's: the resolved configuration defines
--  each as task_kind NAME = FIELDS, the fields it requires, and those
--  marked ? that it allows. A field no kind names is refused rather than
--  carried with no meaning.
package Model_Runner.Framework.Tasks is

   --  The fields a caller gives a new task, by name. Recognised: title,
   --  kind, component, requirements and depends_on (comma-separated),
   --  priority, acceptance, parent, notes; anything else is a custom field
   --  its kind must allow.
   subtype Field_Map is Configurations.Value_Maps.Map;

   --  Why a task is not ready, one reason a line.
   type Readiness is record
      Ready   : Boolean := False;
      Reasons : Name_Lists.Vector;
   end record;

   --  The task lifecycle as this project has it.
   --
   --  @return The default task machine.
   function Lifecycle return Transitions.Machine;

   --  The kinds of task a project defines.
   --
   --  @param Item The store.
   --  @return Their names, sorted.
   function Kinds (Item : Stores.Store) return Name_Lists.Vector;

   --  The fields a kind requires.
   --
   --  @param Item The store.
   --  @param Kind The kind.
   --  @return The required fields' names, as the kind lists them.
   function Required_Fields
     (Item : Stores.Store;
      Kind : String) return Name_Lists.Vector;

   --  The fields a kind allows, required or not, beside the fields every
   --  task has.
   --
   --  @param Item The store.
   --  @param Kind The kind.
   --  @return Their names.
   function Allowed_Fields
     (Item : Stores.Store;
      Kind : String) return Name_Lists.Vector;

   --  Create a task: its definition, and its runtime state as a candidate.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Fields What the task is.
   --  @param Created_By Who or what created it: user, requirement_derivation,
   --    an agent's identifier.
   --  @param Origin What it came from; may be empty.
   --  @param Id Its identifier: TASK-, the component in capitals, a number.
   --  @param Status Framework_Task_Kind_Unknown when the kind is not the
   --    project's, Framework_Input_Missing naming the fields the kind
   --    requires that were not given, Framework_Schema_Violation for a
   --    field it does not allow, Framework_Not_Found for a requirement,
   --    dependency or parent that is not there, and
   --    Framework_Dependency_Cycle when a dependency would wait on itself.
   procedure Create
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Fields     : Field_Map;
      Created_By : String;
      Origin     : String;
      Id         : out Ada.Strings.Unbounded.Unbounded_String;
      Status     : out Model_Runner.Errors.Error_Info);

   --  A task's definition.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @param Value Its definition record.
   --  @param Status Framework_Not_Found when there is none.
   procedure Definition
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info);

   --  Where a task stands.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @return Its state, or the empty string when there is no such task.
   function State_Of (Item : Stores.Store; Id : String) return String;

   --  Move a task through its lifecycle.
   --
   --  Starting needs the task to be ready, and begins a new execution
   --  generation; blocking records why; failing records what failed;
   --  completing needs the task's completion gates to have passed. The
   --  reopening moves need their policy.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The task.
   --  @param Next The state to move to.
   --  @param Reason Why: a blocking reason, a failure; may be empty.
   --  @param Granted The policies the move may use.
   --  @param Gates_Passed For a move to complete: whether the completion
   --    gates passed.
   --  @param Status Framework_Transition_Invalid when the move is not one,
   --    Framework_Task_Not_Ready when a task that is not ready is started or
   --    one whose gates did not pass is completed.
   procedure Move
     (Item         : Stores.Store;
      Change       : in out Stores.Transaction;
      Id           : String;
      Next         : String;
      Reason       : String;
      Granted      : Transitions.Permissions := Transitions.Ordinary_Only;
      Gates_Passed : Boolean := False;
      Status       : out Model_Runner.Errors.Error_Info);

   --  Whether a task is ready, worked out from the state as it is.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @return Whether, and if not why not.
   function Ready (Item : Stores.Store; Id : String) return Readiness;

   --  Work readiness out again for every task, and announce each task that
   --  became ready since it was last worked out.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Became The tasks that became ready.
   --  @param Status A failure staging the announcement.
   procedure Recompute_Readiness
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Became : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info);

   --  Block a parent on its children: the parent waits, with a reason
   --  naming them, while the children carry the work.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Parent The parent task.
   --  @param Status Framework_Not_Found when it has no children.
   procedure Block_On_Children
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The tasks, with their definitions' identifiers.
   --
   --  @param Item The store.
   --  @param State Only those in this state; empty for all.
   --  @return Their identifiers, sorted.
   function List
     (Item  : Stores.Store;
      State : String := "") return Name_Lists.Vector;

   --  The children of a task.
   --
   --  @param Item The store.
   --  @param Parent The task.
   --  @return Their identifiers, sorted.
   function Children
     (Item   : Stores.Store;
      Parent : String) return Name_Lists.Vector;

   --  The Effective Task: a task as it would be executed, worked out from
   --  its definition, its runtime state, its readiness, the revisions of the
   --  requirements it serves, the decisions that apply to its component and
   --  what its kind says; fingerprinted.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @param Value The view, as a record whose fields say each of those.
   --  @param Status Framework_Not_Found when there is no such task.
   procedure Effective
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info);

   --  Derive tasks from accepted requirements, once each: a requirement's
   --  meaning at a revision derives one implementation task, and deriving
   --  again -- from a replayed event, or a second run -- finds it and makes
   --  none. A derived task is a candidate unless the configuration's
   --  scalar task.auto_accept is true, and then its acceptance is recorded
   --  as the policy's.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Made The tasks derived.
   --  @param Status A failure creating one.
   procedure Derive
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Made   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info);

   --  Make one task wait for another, as the next revision of its
   --  definition.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The task that waits.
   --  @param On The task it waits for.
   --  @param Status Framework_Not_Found when either is not there, and
   --    Framework_Dependency_Cycle when On already waits, directly or
   --    through others, for Id.
   procedure Add_Dependency
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      On     : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The lease an agent writing a component in the project itself holds
   --  on it, so that no second agent writes it at the same time.
   --
   --  @param Component The component.
   --  @return The lease's resource name.
   function Component_Lease (Component : String) return String
   is ("component." & Component);

   --  A kind's own policy, where it has one: the configuration's scalar
   --  task.NAME.KIND -- isolation, token_budget, max_steps, coordination --
   --  which a caller falls back from to the project's.
   --
   --  @param Item The store.
   --  @param Kind The task kind.
   --  @param Name The policy.
   --  @return Its value, or "" when the kind says nothing.
   function Kind_Policy (Item : Stores.Store; Kind, Name : String) return String;

   --  The gates a task of a kind must pass to complete: the configuration's
   --  set task.gates.KIND, else set task.gates, else verification,
   --  children, no_blocking_issue and integration.
   --
   --  @param Item The store.
   --  @param Kind The task kind.
   --  @return Their names, in order.
   function Gate_Names (Item : Stores.Store; Kind : String) return Name_Lists.Vector;

   --  Revise what a task is: the next revision of its definition, with the
   --  fields given changed -- a field given empty is taken away. Its kind,
   --  its parent and what it depends on are not changed this way, and a
   --  task that is running, in verification or ended is not revised at all.
   --  What a revision may hold is checked as a new task's is.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The task.
   --  @param Fields The fields and their new values.
   --  @param Status Framework_Transition_Invalid for a task in a state that
   --    is not revised, Framework_Schema_Violation for a field it cannot
   --    have, Framework_Not_Found for a requirement that is not there.
   procedure Revise
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Fields : Field_Map;
      Status : out Model_Runner.Errors.Error_Info);

   --  Decompose a task into child tasks, one for each title, of its kind and
   --  component and recording it as their parent. An accepted parent is
   --  then blocked on them, its work theirs -- unless the project's
   --  coordination policy (scalar task.coordination, or task.coordination.KIND)
   --  is parent_runs, which leaves it to run beside them.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Parent The task.
   --  @param Titles The children's titles.
   --  @param Made The children.
   --  @param Status Framework_Not_Found when the parent is not there.
   procedure Decompose
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Titles : Name_Lists.Vector;
      Made   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info);

   --  Tasks whose dependencies, directly or through others, come back to
   --  themselves, or whose parents do.
   --
   --  @param Item The store.
   --  @return The tasks on a cycle.
   function Cycles (Item : Stores.Store) return Name_Lists.Vector;

end Model_Runner.Framework.Tasks;
