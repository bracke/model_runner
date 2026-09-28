with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Moving a project along without asking a model what is routine.
--
--  Automation rules say what the harness does when something happens: the
--  configuration's list automation.rules holds lines of EVENT: ACTION, with
--  * for any event, and the actions are derive_tasks, recompute_readiness,
--  reevaluate_requirements and verify. A project that says nothing gets the
--  ones every project needs: tasks derived when a requirement is accepted
--  or revised, requirements reevaluated when a task completes or the source
--  changes, readiness worked out after anything. A step consumes each event
--  once, as the orchestrator, in the transaction that acts on it, so a step
--  run twice does nothing twice.
--
--  Dispatch plans what can run: the ready tasks, most important first, as
--  many as there are agent slots, and no two writing the same component at
--  once unless each writes in a workspace of its own. What is left for
--  judgment -- candidates waiting for acceptance, blocked tasks, conflicts
--  of authority -- is listed, because that is where a person or a model is
--  needed and nowhere else.
package Model_Runner.Framework.Orchestration is

   --  One rule.
   type Rule is record
      Event  : Ada.Strings.Unbounded.Unbounded_String;
      Action : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  What a step did.
   type Step_Report is record
      Events_Seen     : Natural := 0;
      Actions_Taken   : Natural := 0;
      Derived         : Name_Lists.Vector;
      Became_Ready    : Name_Lists.Vector;
      Requirements    : Name_Lists.Vector;
      Evidence        : Name_Lists.Vector;
   end record;

   --  The tasks to start, in order.
   type Dispatch_Plan is record
      Start   : Name_Lists.Vector;

      --  Ready tasks held back, and why, one a line.
      Held    : Name_Lists.Vector;
      Slots   : Natural := 0;
   end record;

   --  The rules in force.
   --
   --  @param Item The store.
   --  @return The rules, one a line as EVENT: ACTION.
   function Rules (Item : Stores.Store) return Name_Lists.Vector;

   --  Act on every event not yet acted on, by the rules, and work out
   --  readiness.
   --
   --  @param Item The store.
   --  @param Result What was done.
   --  @param Status A failure acting, which leaves the events not acted on
   --    to be acted on next time.
   procedure Step
     (Item   : in out Stores.Store;
      Result : out Step_Report;
      Status : out Model_Runner.Errors.Error_Info);

   --  Plan which ready tasks to start.
   --
   --  @param Item The store.
   --  @return The plan.
   function Plan (Item : Stores.Store) return Dispatch_Plan;

   --  What needs judgment: candidates to accept or reject, blocked tasks
   --  and why, and conflicts of authority.
   --
   --  @param Item The store.
   --  @return One line each.
   function Needs_Judgment (Item : Stores.Store) return Name_Lists.Vector;

end Model_Runner.Framework.Orchestration;
