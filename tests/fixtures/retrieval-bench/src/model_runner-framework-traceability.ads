private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;

--  How what the project is meant to be connects to what it is.
--
--  The traceability graph is worked out from the state and the repository:
--  a requirement at its revision to the tasks that serve it and the
--  evidence that verified it; a task to the files its work changed and the
--  evidence of its verification; a decision at its revision to its
--  component; a file to its units and their symbols, units to the units
--  they depend on, test files to what they exercise; and components to the
--  files named after them. Every edge says whether it was recorded or
--  derived and how sure it is; a derived edge never claims more than the
--  rule that found it.
--
--  Impact is read off the graph from a set of changed files: the symbols
--  they declare, the units that depend on them directly and through
--  others, the components, requirements, tasks, specifications and tests
--  that reach them -- each with the weakest confidence on the way, so an
--  uncertain link stays uncertain. Choosing what to test then follows the
--  project's policy and the confidence: the tests certainly affected when
--  that is all there is, the component's tests when something is only
--  probable, and everything when anything is uncertain or unknown.
--
--  Each of the three -- the graph, an impact, a selection -- is also a
--  derivation (Derivations): named by everything it was worked out from,
--  kept, and used again while all of that still matches. The selection a
--  verification ran with names the impact it came from, and the impact the
--  graph, so why only these tests ran can be followed back to the files
--  that changed.
package Model_Runner.Framework.Traceability is

   --  One edge.
   type Edge is record
      From       : Ada.Strings.Unbounded.Unbounded_String;
      To         : Ada.Strings.Unbounded.Unbounded_String;
      Kind       : Ada.Strings.Unbounded.Unbounded_String;
      Source     : Repository.Derivation := Repository.Explicit;
      Sure       : Repository.Confidence := Repository.Certain;

      --  The record it was read from, where there is one.
      Record_Of  : Ada.Strings.Unbounded.Unbounded_String;

      --  When it was worked out: the graph is derived from the records and
      --  the repository each time it is built, and its edges with it.
      Created_At : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The graph.
   type Graph is private;

   --  One thing a change reaches.
   type Reached is record
      Kind : Ada.Strings.Unbounded.Unbounded_String;
      Id   : Ada.Strings.Unbounded.Unbounded_String;
      Sure : Repository.Confidence := Repository.Certain;
   end record;

   --  What a change reaches.
   type Impact is private;

   --  How widely to test.
   type Scope is (Certain_Tests, Component_Tests, Full_Suite);

   --  What to test, and why that much.
   type Selection is record
      Width  : Scope := Full_Suite;
      Tests  : Name_Lists.Vector;
      Reason : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Work the graph out.
   --
   --  @param Item The store.
   --  @param Files The repository, as scanned.
   --  @return The graph.
   function Build
     (Item  : Stores.Store;
      Files : Repository.Graph) return Graph;

   --  How many edges a graph holds.
   --
   --  @param From The graph.
   --  @return The count.
   function Edge_Count (From : Graph) return Natural;

   --  One edge.
   --
   --  @param From The graph.
   --  @param Index 1 .. Edge_Count.
   --  @return The edge.
   function Edge_At (From : Graph; Index : Positive) return Edge;

   --  The edges that touch a node.
   --
   --  @param From The graph.
   --  @param Node The node, as REQ-X@3, TASK-X, file:src/x.adb, unit:X.
   --  @return Their positions, in order.
   function Touching (From : Graph; Node : String) return Name_Lists.Vector;

   --  What changing some files, or symbols, reaches.
   --
   --  @param From The graph.
   --  @param Changed The files, as paths within the project; a symbol or a
   --    unit is given as its node, symbol:Unit.Name or unit:Unit.
   --  @return The impact.
   function Impact_Of (From : Graph; Changed : Name_Lists.Vector) return Impact;

   --  How many things an impact reaches.
   --
   --  @param From The impact.
   --  @return The count.
   function Length (From : Impact) return Natural;

   --  One of them, grouped by kind.
   --
   --  @param From The impact.
   --  @param Index 1 .. Length.
   --  @return It.
   function Element (From : Impact; Index : Positive) return Reached;

   --  Choose the tests to run for an impact.
   --
   --  @param Item The store, whose configuration's scalar
   --    verification.escalation may be narrow, to test only what is
   --    certainly affected, or conservative, the default.
   --  @param From The impact.
   --  @return The selection.
   function Select_Tests (Item : Stores.Store; From : Impact) return Selection;

   --  The versions of how each is worked out: raised when what it works out
   --  from the same inputs changes, which makes every kept one stale.
   --  Graph 1: the first kept. Impact 1, selection 1: likewise.
   Graph_Version     : constant String := "1";
   Impact_Version    : constant String := "1";
   Selection_Version : constant String := "1";

   --  What the graph of a project is derived from: the repository's files
   --  at their fingerprints and how they were read, every requirement,
   --  specification, decision, task definition and piece of evidence as
   --  kept, what each task's work changed, and the configuration.
   --
   --  @param Item The store.
   --  @param Files The repository, as scanned.
   --  @return The description.
   function Graph_Specification
     (Item  : Stores.Store;
      Files : Repository.Graph) return Derivations.Specification;

   --  The graph, as kept where it is current, worked out where it is not.
   --
   --  @param Item The store.
   --  @param Files The repository, as scanned.
   --  @param Result The graph.
   --  @param Key Its derivation; "" when what it rests on could not all be
   --    read, and it was worked out without being kept.
   --  @param Kept What was worked out here, added to, for the caller to
   --    keep in its transaction.
   procedure Derive_Graph
     (Item   : Stores.Store;
      Files  : Repository.Graph;
      Result : out Graph;
      Key    : out Ada.Strings.Unbounded.Unbounded_String;
      Kept   : in out Derivations.Staged);

   --  What changing some files reaches, as kept where it is current.
   --
   --  @param Item The store.
   --  @param From The graph.
   --  @param Graph_Key Its derivation; "" works the impact out unkept.
   --  @param Changed As for Impact_Of; their order does not matter.
   --  @param Result The impact.
   --  @param Key Its derivation, or "".
   --  @param Kept As for Derive_Graph.
   --  @param Subject What the impact is for -- the task -- so a later one
   --    for it can be held against this.
   --  @param Version How it is worked out.
   procedure Derive_Impact
     (Item      : Stores.Store;
      From      : Graph;
      Graph_Key : String;
      Changed   : Name_Lists.Vector;
      Result    : out Impact;
      Key       : out Ada.Strings.Unbounded.Unbounded_String;
      Kept      : in out Derivations.Staged;
      Subject   : String := "project";
      Version   : String := Impact_Version);

   --  The tests to run for an impact, as kept where it is current.
   --
   --  @param Item The store.
   --  @param From The impact.
   --  @param Impact_Key Its derivation; "" chooses them unkept.
   --  @param Result The selection.
   --  @param Key Its derivation, or "".
   --  @param Kept As for Derive_Graph.
   --  @param Subject As for Derive_Impact.
   --  @param Version How it is chosen.
   procedure Derive_Selection
     (Item       : Stores.Store;
      From       : Impact;
      Impact_Key : String;
      Result     : out Selection;
      Key        : out Ada.Strings.Unbounded.Unbounded_String;
      Kept       : in out Derivations.Staged;
      Subject    : String := "project";
      Version    : String := Selection_Version);

   --  The tests a change calls for, through the three derivations.
   type Traced is record
      Chosen        : Selection;
      Graph_Key     : Ada.Strings.Unbounded.Unbounded_String;
      Impact_Key    : Ada.Strings.Unbounded.Unbounded_String;
      Selection_Key : Ada.Strings.Unbounded.Unbounded_String;

      --  What was worked out rather than found kept, to be kept.
      Kept          : Derivations.Staged;
   end record;

   --  Choose the tests a change calls for, using again what is kept.
   --
   --  @param Item The store.
   --  @param Files The repository, as scanned.
   --  @param Changed The files changed.
   --  @param Subject What it is for, as the task.
   --  @return The selection and the derivations it came from.
   function Select_For
     (Item    : Stores.Store;
      Files   : Repository.Graph;
      Changed : Name_Lists.Vector;
      Subject : String := "project") return Traced;

private

   package Edge_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Edge);

   package Reached_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Reached);

   type Graph is record
      Edges : Edge_Vectors.Vector;

      --  Every component the state names.
      Components : Name_Lists.Vector;

      --  The records that would not read as it was built: what they link
      --  is not in it, and so nothing it leaves out is known untouched.
      Unread : Name_Lists.Vector;

      --  The project's roots, as it was built: what a path is -- a test, a
      --  build file -- is as the project says.
      Roots : Repository.Roots := Repository.Default_Roots;

      --  The documents it looked for, each as present, missing or unknown,
      --  a tab, and the path: what the graph found it rested on.
      Looked_At : Name_Lists.Vector;
   end record;

   type Impact is record
      Items : Reached_Vectors.Vector;

      --  Changed files no rule reaches beyond themselves.
      Unknown : Name_Lists.Vector;
   end record;

end Model_Runner.Framework.Traceability;
