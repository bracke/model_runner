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

   --  The task states the harness itself gives meaning to. A state is
   --  kept as its word -- a project may add states of its own, map
   --  task.state.NAME = MEANING, which no type here could list -- and code
   --  that asks about one of these asks by this type, so a state misspelt
   --  is a compilation that fails rather than a test that is never true.
   type Core_State is
     (Candidate, Accepted, Running, Blocked, Verification, Complete, Failed,
      Cancelled, Rejected);

   --  A core state's word, as the store keeps it: "candidate" and so on.
   --
   --  @param State The state.
   --  @return Its word.
   function Image (State : Core_State) return String;

   --  Whether a state's word is a core state's.
   --
   --  @param Left The word, as kept.
   --  @param Right The core state.
   --  @return True when the word is that state's.
   function "=" (Left : String; Right : Core_State) return Boolean
   is (Left = Image (Right));

   --  The task states the harness itself gives meaning to, as words:
   --  candidate, accepted, running, blocked, verification, complete,
   --  failed, cancelled and rejected.
   --
   --  @return Them.
   function Core_Task_States return Name_Lists.Vector;

   --  The core state a state counts as, for what waits on it -- dependencies,
   --  parents, gates: a core state itself, and a project's own state the
   --  core state its meaning begins with, as map task.state.parked =
   --  accepted, and set aside says it counts as accepted.
   --
   --  @param Item The store.
   --  @param State The state.
   --  @return The core state.
   function Counts_As (Item : Stores.Store; State : String) return String;

   --  Whether a project may forbid a move of the default lifecycle: only
   --  one a person makes -- rejecting a candidate, blocking or failing by
   --  hand, taking a failed task up again, reopening, reconsidering. The
   --  moves the harness makes as it works cannot be taken away from it.
   --
   --  @param From The state moved from.
   --  @param To The state moved to.
   --  @return True when the project may forbid it.
   function Forbiddable (From, To : String) return Boolean;

   --  The task lifecycle in a project: the default one, with the states
   --  it adds -- map task.state.NAME = MEANING -- and the moves, a line
   --  FROM -> TO each of set task.transitions, and without the moves set
   --  task.forbidden takes away, of those Forbiddable allows.
   --
   --  @param Item The store.
   --  @return The machine.
   function Lifecycle_Of (Item : Stores.Store) return Transitions.Machine;

   --  Whether a task field is one every task may have, whatever its kind:
   --  title, kind, component, requirements, depends_on, priority,
   --  acceptance, parent, notes, permissions. Any other is a kind's own.
   --
   --  @param Name The field.
   --  @return True for a core field.
   function Is_Core_Field (Name : String) return Boolean;

   --  Why a value does not read as a kind's own field says it must: the
   --  field's schema, map task_field.NAME = TYPE, where TYPE is text,
   --  number, identifier, path, list, or choice A|B|C. A field without a
   --  schema has no stated meaning, and nothing is taken for it.
   --
   --  @param Item The store.
   --  @param Name The field.
   --  @param Value Its value.
   --  @return The problem, or "" when it reads.
   function Field_Problem (Item : Stores.Store; Name, Value : String) return String;

   --  What a kind's own field's schema says it is, as map task_field.NAME
   --  writes it: text, number, identifier, path, list or choice A|B|C.
   --
   --  @param Item The store.
   --  @param Name The field.
   --  @return The schema; empty for a core field or one with none.
   function Field_Schema (Item : Stores.Store; Name : String) return String;

   --  Create a task: its definition, and its runtime state as a candidate
   --  -- or, where the configuration's set task.auto_accept names the
   --  task's class, accepted, with the policy recorded as who accepted it.
   --  A class is the task's kind or where it came from: user,
   --  requirement_derivation, agent, verification_engine. The older scalar
   --  task.auto_accept = true names requirement_derivation.
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
   --  @param Actor Who moved it: Transitions.User, a policy, an agent;
   --    kept with the state and in the event.
   procedure Move
     (Item         : Stores.Store;
      Change       : in out Stores.Transaction;
      Id           : String;
      Next         : String;
      Reason       : String;
      Granted      : Transitions.Permissions := Transitions.Ordinary_Only;
      Gates_Passed : Boolean := False;
      Status       : out Model_Runner.Errors.Error_Info;
      Actor        : String := "");

   --  Whether a task is ready, worked out from the state as it is.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @return Whether, and if not why not.
   function Ready (Item : Stores.Store; Id : String) return Readiness;

   --  What there is to do in a project, worked out once from its state so
   --  that every command that says it -- /work, /state, a way on -- says
   --  the same: the tasks that can run, in the order they are listed; the
   --  accepted ones that cannot yet, each with why; the candidates waiting
   --  to be accepted; what is running; and what failed and may be taken up
   --  again.
   type Next_Work is record
      Runnable  : Name_Lists.Vector;
      Blocked   : Name_Lists.Vector;
      Why_Not   : Name_Lists.Vector;
      Awaiting  : Name_Lists.Vector;
      Running   : Name_Lists.Vector;
      Retryable : Name_Lists.Vector;
   end record;

   --  The project's next work, as it stands.
   --
   --  @param Item The store.
   --  @return It; Why_Not holds a blocked task's first reason at its place
   --    in Blocked.
   function Next_Work_Of (Item : Stores.Store) return Next_Work;

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

   --  The reason a task blocked on its children gives: once none of them
   --  holds it and none waits to be decided, it goes back to work.
   --
   --  @param Children The children it waits for.
   --  @return The reason, as Recompute_Readiness knows it.
   function Waiting_For (Children : Name_Lists.Vector) return String;

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

   --  Whether a child holds its parent: it is still to be done -- not
   --  complete, cancelled or rejected -- and it is work someone took on. A
   --  part an agent proposed is proposal data until it is accepted, and
   --  holds nothing before then.
   --
   --  @param Item The store.
   --  @param Child The child.
   --  @param State Its state, as the caller sees it.
   --  @return True when it holds its parent.
   function Holds_Parent (Item : Stores.Store; Child : String; State : String) return Boolean;

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
   --  configuration accepts its class, as Create says.
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

   --  Stop one task waiting for another, as the next revision of its
   --  definition.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The task that waits.
   --  @param On The task it no longer waits for.
   --  @param Status Framework_Not_Found when Id is not there or does not
   --    wait for On.
   procedure Remove_Dependency
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      On     : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The project's components: those it lists, or, listing none, the
   --  project itself by its name.
   --
   --  @param Item The store.
   --  @return Their names; none when the project has no name either.
   function Components (Item : Stores.Store) return Name_Lists.Vector;

   --  The first task of a kind not ended yet: one to work on, where there
   --  is one.
   --
   --  @param Item The store.
   --  @param Kind The kind, as test.
   --  @return Its identifier; "" where none is open.
   function First_Open_Of_Kind (Item : Stores.Store; Kind : String) return String;

   --  The components a configuration names, as Components reads them: for
   --  a change not yet made.
   --
   --  @param Settings The configuration record.
   --  @return Their names.
   function Components_Of (Settings : Records.Item) return Name_Lists.Vector;

   --  The component a task is placed in.
   --
   --  @param Item The store.
   --  @param Id The task.
   --  @return Its component, or "(none)" where it names none.
   function Component_Of_Task (Item : Stores.Store; Id : String) return String;

   --  The lease an agent writing a component in the project itself holds
   --  on it, so that no second agent writes it at the same time.
   --
   --  @param Component The component.
   --  @return The lease's resource name.
   function Component_Lease (Component : String) return String
   is ("component." & Component);

   --  The lease an agent writing in the project itself, not a workspace of
   --  its own, holds on the whole of it: two writing in one tree would
   --  have each other's changes taken for their own.
   Project_Lease : constant String := "project.write";

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
   --  children, no_blocking_issue and integration. Beside those four a
   --  project may name implementation_present (its work changed a file),
   --  traceability_sufficient (each requirement it serves reaches what
   --  implements or tests it), documentation_current (source changed goes
   --  with documentation changed), and any NAME for which scalar gate.NAME
   --  names a profile that must have passed for it.
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

   --  Give the open tasks derived from a requirement its title as it is
   --  now: REQ-003 (FR-1): the new words. A title a person changed is
   --  theirs, and kept.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Requirement The requirement.
   --  @param Old_Title Its title before.
   --  @param New_Title Its title now.
   --  @param Retitled The tasks given the new title.
   procedure Retitle_Derived
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Requirement : String;
      Old_Title   : String;
      New_Title   : String;
      Retitled    : out Name_Lists.Vector);

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
