with Ada.Strings.Unbounded;
with Model_Runner.Cancellation;
with Model_Runner.Presentation;

--  A model's text written as it comes, with what may be a call held back:
--  a line that opens with {, ``` or < is kept from where it starts, dropped
--  when the call it was is made -- the call is shown in its own line -- and
--  written out when it was only text. Shared by /work and run --agent.
package Model_Runner.CLI.Held_Output is

   use Ada.Strings.Unbounded;
   package Pres renames Model_Runner.Presentation;

   --  Generated text written as it comes, and between its pieces the work
   --  asked after: ended elsewhere -- cancelled from another terminal --
   --  the turn stops there, not at its next call.
   type Watching_Sink is limited new Pres.Standard_Output_Sink with record
      Stop : Model_Runner.Cancellation.Token_Reference := null;

      --  A line that may open a call -- {, ``` or <tool_call> -- held back
      --  from where it starts: dropped when the call is made, as the call
      --  is shown in its own line; written out when it was only text.
      Held          : Unbounded_String;
      Holding       : Boolean := False;
      At_Line_Start : Boolean := True;

      --  A helper's run: what it writes is its report, which the agent
      --  that asked reads and the screen shows as that call's answer.
      Quiet         : Boolean := False;

      --  Whether standard output shows colour: an answer's JSON coloured.
      Styled        : Boolean := False;
   end record;

   --  What was held back was a call: not written.
   --
   --  @param Self The sink.
   procedure Drop_Held (Self : in out Watching_Sink'Class);

   --  What was held back was text: written now.
   --
   --  @param Self The sink.
   procedure Release_Held (Self : in out Watching_Sink'Class);

   --  Write a piece of generated text, holding back what may be a call.
   --
   --  @param Self The sink.
   --  @param Item The text.
   --  @param Closed Whether standard output has closed.
   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean);

end Model_Runner.CLI.Held_Output;
