private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

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

private

   package Edge_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Edge);

   package Reached_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Reached);

   type Graph is record
      Edges : Edge_Vectors.Vector;

      --  Every component the state names.
      Components : Name_Lists.Vector;
   end record;

   type Impact is record
      Items : Reached_Vectors.Vector;

      --  Changed files no rule reaches beyond themselves.
      Unknown : Name_Lists.Vector;
   end record;

end Model_Runner.Framework.Traceability;
