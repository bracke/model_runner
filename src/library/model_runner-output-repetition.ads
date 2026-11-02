--  A thought that goes round.
--
--  A model reasoning at length may come back to the same line again and
--  again -- gpt-oss wrote "We can use Ada.Numerics.Long_Long_Integer? Not."
--  dozens of times through one analysis, and the task ran out of its time
--  in it. This sink stands between the generation and the screen, passes
--  everything on, and watches each whole line of a thought: one that comes
--  again a rule's Limit times within the same thought, once that has run
--  long, closes the sink, which ends the generation there, for the caller
--  to close the thought and ask for the rest. Only thought is watched -- a
--  call's text or an answer may hold the same line as often as it likes --
--  and only lines of some length: a blank, a brace, "end if;" come round in
--  any reasoning.
private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Strings.Hash;
private with Ada.Strings.Unbounded;

package Model_Runner.Output.Repetition is

   --  The shortest line counted.
   Shortest : constant Positive := 20;

   --  When a line coming round closes a thought. Models reason in their
   --  own ways -- a line a model comes back to and out of by itself is
   --  another's loop -- so a rule is measured for a model family and kept
   --  to it (Agent.Round_Rule_For); a family not measured has none.
   type Rule is record
      --  Whether thoughts are watched at all.
      Watching    : Boolean := False;
      --  How often a line may come in one thought before it is a loop.
      Limit       : Positive := Positive'Last;
      --  How long a thought may be, in bytes, before a line coming round
      --  closes it.
      Free_Length : Natural := 0;
   end record;

   --  No thought closed.
   Unwatched : constant Rule := (others => <>);

   --  The watch, writing what it is given to Target, which may be null.
   type Watch (Target : Sink_Reference) is limited new Sink with private;

   --  Keep the watch to a rule, for every reply after.
   --
   --  @param Self Watch.
   --  @param Item The rule.
   procedure Keep_To (Self : in out Watch; Item : Rule);

   --  Ready the watch for a reply.
   --
   --  @param Self Watch.
   --  @param Inside Whether the reply begins inside a thought its prompt
   --    opened.
   procedure Start_Reply (Self : in out Watch; Inside : Boolean);

   --  Whether the reply's thought went round, closing the watch.
   --
   --  @param Self Watch.
   --  @return True once a line came the rule's Limit times in one thought
   --    past its Free_Length.
   function Looped (Self : Watch) return Boolean;

   --  The line that came round, trimmed; empty until one did.
   --
   --  @param Self Watch.
   --  @return The line.
   function Repeated (Self : Watch) return String;

   --  Pass a fragment on, and watch it.
   --
   --  @param Self Watch.
   --  @param Item Generated text.
   --  @param Closed True when Target can accept no more output, or the
   --    thought went round.
   overriding procedure Write
     (Self   : in out Watch;
      Item   : String;
      Closed : out Boolean);

   --  @param Self Watch.
   --  @param Closed True when Target can accept no more output.
   overriding procedure Flush (Self : in out Watch; Closed : out Boolean);

   --  @param Self Watch.
   --  @return Whether Target has closed, or the thought went round.
   overriding function Is_Closed (Self : Watch) return Boolean;

private

   package Counts is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Positive,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Watch (Target : Sink_Reference) is limited new Sink with record
      Inside : Boolean := False;
      Line   : Ada.Strings.Unbounded.Unbounded_String;
      Seen   : Counts.Map;
      Round  : Boolean := False;
      Again  : Ada.Strings.Unbounded.Unbounded_String;
      Length : Natural := 0;
      Kept   : Rule;
   end record;

end Model_Runner.Output.Repetition;
