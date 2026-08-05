--  Destination for generated model text.
--
--  The generation coordinator never writes to standard output. It writes
--  decoded text fragments to a sink, and the CLI supplies a sink that targets
--  standard output while the tests crate supplies one that accumulates into a
--  buffer or one that reports closure after a configured number of bytes.
--
--  Closure. A sink reports closure rather than raising, so that a broken pipe
--  becomes the completion reason Output_Closed instead of an exception and an
--  Ada traceback. Once a sink reports closure it must keep reporting it.
--
--  Content. Text written to a sink is generated model output. It is passed
--  through unchanged: no styling, no localization, no trimming, no wrapping,
--  no appended explanation.
--
--  Task safety: a sink is written by the task that runs generation.
package Model_Runner.Output is

   --  A destination for generated text.
   type Sink is limited interface;

   --  Write a fragment of generated text.
   --
   --  @param Self Sink instance.
   --  @param Item Text to write, passed through unchanged.
   --  @param Closed True when the destination can accept no more output.
   procedure Write
     (Self   : in out Sink;
      Item   : String;
      Closed : out Boolean) is abstract;

   --  Release any buffered text towards the destination.
   --
   --  @param Self Sink instance.
   --  @param Closed True when the destination can accept no more output.
   procedure Flush (Self : in out Sink; Closed : out Boolean) is abstract;

   --  Report whether the destination has already been closed.
   --
   --  @param Self Sink instance.
   --  @return True once closure has been observed.
   function Is_Closed (Self : Sink) return Boolean is abstract;

   type Sink_Reference is access all Sink'Class;

   --  Write to a possibly absent sink.
   --
   --  A null sink discards the text and never reports closure, which is what a
   --  caller that only wants the token sequence expects.
   --
   --  @param Item Sink reference, possibly null.
   --  @param Value Text to write.
   --  @param Closed True when the destination can accept no more output.
   procedure Emit
     (Item   : Sink_Reference;
      Value  : String;
      Closed : out Boolean);

   --  Flush a possibly absent sink.
   --
   --  @param Item Sink reference, possibly null.
   --  @param Closed True when the destination can accept no more output.
   procedure Flush_Sink (Item : Sink_Reference; Closed : out Boolean);

   --  A sink that discards everything written to it.
   type Null_Sink is limited new Sink with private;

   --  Discard a fragment.
   --
   --  @param Self Sink instance.
   --  @param Item Text to discard.
   --  @param Closed Always False.
   overriding procedure Write
     (Self   : in out Null_Sink;
      Item   : String;
      Closed : out Boolean);

   --  Do nothing.
   --
   --  @param Self Sink instance.
   --  @param Closed Always False.
   overriding procedure Flush (Self : in out Null_Sink; Closed : out Boolean);

   --  Report that the sink is open.
   --
   --  @param Self Sink instance.
   --  @return Always False.
   overriding function Is_Closed (Self : Null_Sink) return Boolean;

private

   type Null_Sink is limited new Sink with null record;

end Model_Runner.Output;
