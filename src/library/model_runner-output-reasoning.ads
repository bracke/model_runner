--  A reply shown without its think block.
--
--  A model that reasons before it answers writes the reasoning between
--  <think> and </think> -- or, where its prompt opened the block, from the
--  reply's first token to the close. `run --hide-reasoning` shows what
--  follows the close alone; this sink stands between the generation and
--  the screen and leaves the block, and the space after its close, out.
package Model_Runner.Output.Reasoning is

   --  The filter, writing what it shows to Target.
   type Filter (Target : Sink_Reference) is limited new Sink with private;

   --  Ready the filter for a reply: Inside where the reply begins in a
   --  block its prompt opened.
   --
   --  @param Self Filter.
   --  @param Inside Whether the reply begins inside a think block.
   procedure Start_Reply (Self : in out Filter; Inside : Boolean);

   --  Whether nothing of the reply has been shown since it began: all of
   --  it so far reasoning, where the reasoning is left out -- a reply the
   --  token limit stopped there has no answer to show.
   --
   --  @param Self Filter.
   --  @return True when nothing has reached Target.
   function Showed_Nothing (Self : Filter) return Boolean;

   --  Take a fragment of the reply, showing what is not reasoning.
   --
   --  @param Self Filter.
   --  @param Item Generated text.
   --  @param Closed True when Target can accept no more output.
   overriding procedure Write
     (Self   : in out Filter;
      Item   : String;
      Closed : out Boolean);

   --  Flush Target. A marker half arrived is kept for the rest of it.
   --
   --  @param Self Filter.
   --  @param Closed True when Target can accept no more output.
   overriding procedure Flush (Self : in out Filter; Closed : out Boolean);

   --  @param Self Filter.
   --  @return Whether Target has closed.
   overriding function Is_Closed (Self : Filter) return Boolean;

private

   Opening : constant String := "<think>";
   Closing : constant String := "</think>";

   type Filter (Target : Sink_Reference) is limited new Sink with record
      Hidden  : Boolean := False;
      --  After a close, until the first text that is not space.
      Leading : Boolean := False;
      Held    : String (1 .. 8);
      Used    : Natural := 0;
      Shut    : Boolean := False;
      Shown   : Boolean := False;
   end record;

end Model_Runner.Output.Reasoning;
