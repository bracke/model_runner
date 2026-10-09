with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Framework.Events;

--  What the harness does on its own when something happens, as values.
--
--  A rule is written EVENT: ACTION -- an event kind as the log names it, or
--  * for any, and one of the actions below -- and is read here once, into a
--  kind and an action, where the configuration is accepted. A rule this
--  cannot read is a configuration refused, by name: a misspelt action read
--  as text at the moment it was due did nothing and was counted as done,
--  and the event that called for it was consumed with it.
--
--  Task safety: no state.
package Model_Runner.Framework.Automation is

   --  What a rule may call for.
   type Action is
     (Derive_Tasks,              --  tasks from accepted requirements
      Recompute_Readiness,       --  which tasks can run
      Reevaluate_Requirements,   --  which requirements still hold as met
      Verify);                   --  the default verification profile

   --  An action as a rule writes it: derive_tasks.
   --
   --  @param Item The action.
   --  @return Its word.
   function Action_Name (Item : Action) return String;

   --  One rule.
   type Rule is record
      --  Whether it is for any event: written *.
      Any   : Boolean := False;

      --  The event kind it is for, where it is not for any.
      Event : Events.Event_Kind := Events.Project_Initialized;

      Act   : Action := Recompute_Readiness;
   end record;

   package Rule_Lists is new Ada.Containers.Vectors (Positive, Rule);

   --  A rule read from its line.
   --
   --  @param Line The line, EVENT: ACTION.
   --  @param Item The rule.
   --  @param Refusal Why the line is no rule; "" when it is one.
   procedure Read (Line : String; Item : out Rule; Refusal : out Ada.Strings.Unbounded.Unbounded_String);

   --  A rule as its line.
   --
   --  @param Item The rule.
   --  @return EVENT: ACTION.
   function Image (Item : Rule) return String;

   --  Whether a rule is for an event of a kind, written as the log writes
   --  it. A kind this build does not know is matched only by *.
   --
   --  @param Item The rule.
   --  @param Kind_Word The event's kind as written.
   --  @return True when the rule is for it.
   function Matches (Item : Rule; Kind_Word : String) return Boolean;

   --  The rules every project needs, where its configuration names none:
   --  tasks derived when a requirement is accepted or revised, requirements
   --  reevaluated when a task completes, the source changes, or what
   --  governs the work changes its meaning, and readiness after anything.
   --
   --  @return The rules.
   function Defaults return Rule_Lists.Vector;

end Model_Runner.Framework.Automation;
