--  gpt-oss's harmony form, shown as text.
--
--  A harmony reply is messages, each a header and a body between special
--  tokens: <|channel|>analysis<|message|> and the reasoning, <|end|>,
--  <|start|>assistant<|channel|>commentary to=functions.NAME ...
--  <|message|> and a call's arguments, <|call|>; and the answer on the
--  final channel. Streamed as it is generated, a run's screen showed every
--  marker. This sink stands between the generation and the screen: it
--  shows the reasoning and the answer as text, a message's end as the end
--  of a line, and nothing of a call's header or arguments -- the run says
--  the call itself, as it says every model's.
--
--  Text that never opens a message's body -- a reply not in the harmony
--  form at all -- is shown as it came once it is longer than any header.
package Model_Runner.Output.Harmony is

   --  The filter, writing what it shows to Target.
   type Filter (Target : Sink_Reference) is limited new Sink with private;

   --  Show the final channel's messages alone, the reasoning left out --
   --  run --hide-reasoning. Off, every message but a call's is shown.
   --
   --  @param Self Filter.
   --  @param On Whether only the answer is shown.
   procedure Answer_Only (Self : in out Filter; On : Boolean);

   --  Take a fragment of the reply, showing what is not markup.
   --
   --  @param Self Filter.
   --  @param Item Generated text.
   --  @param Closed True when Target can accept no more output.
   overriding procedure Write
     (Self   : in out Filter;
      Item   : String;
      Closed : out Boolean);

   --  Flush Target. A marker half arrived is kept for the rest of it;
   --  text held as a header that holds no marker is shown.
   --
   --  @param Self Filter.
   --  @param Closed True when Target can accept no more output.
   overriding procedure Flush (Self : in out Filter; Closed : out Boolean);

   --  @param Self Filter.
   --  @return Whether Target has closed.
   overriding function Is_Closed (Self : Filter) return Boolean;

private

   --  Where in a message the stream is: its header, a body shown, or a
   --  call's body, which is not.
   type Place is (In_Header, Showing, Hiding);

   --  The longest header kept before the text is taken for no header at
   --  all, and the longest marker.
   Header_Room : constant := 256;
   Marker_Room : constant := 32;

   type Filter (Target : Sink_Reference) is limited new Sink with record
      Where : Place := In_Header;
      Held  : String (1 .. Header_Room);
      Used  : Natural := 0;
      Shut  : Boolean := False;
      Only_Final : Boolean := False;
   end record;

end Model_Runner.Output.Harmony;
