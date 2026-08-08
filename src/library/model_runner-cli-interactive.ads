with Model_Runner.CLI.Options;
with Model_Runner.Llama;
with Model_Runner.Presentation;

--  Interactive conversation.
--
--  Interactive mode keeps a structured committed history and renders it
--  through the model's own chat template on every turn. The history and the
--  KV cache are kept in step by verifying, before each turn, that the freshly
--  tokenized conversation is an exact prefix extension of what the cache
--  already holds; when it is not, the session is reset and the whole
--  conversation is re-evaluated. There is never a displayed history that
--  differs from the model's context.
--
--  Commands. The command tokens are protocol and are never localized; their
--  descriptions and responses are. An unknown command produces a localized
--  diagnostic and the session continues.
--
--    /exit   /reset   /help   /settings   /stats   /context   /system [TEXT]
--
--  /system with no text removes the system message, which is otherwise the
--  one thing a session cannot undo: --system sets one before the first turn
--  and /system TEXT replaces it, and without this there is no way back to a
--  conversation that has none.
--
--  Input policy. Non-empty lines accumulate; a blank line submits. An empty
--  submission is ignored. At end of file a pending non-empty prompt is
--  submitted and then the session ends.
--
--  Cancellation. A cancelled assistant response is not committed to the
--  structured history, the session is reset, and the prior committed
--  conversation is re-evaluated on the next turn. Text that was already
--  streamed stays visible.
--
--  Nothing is written to disk: the conversation is not persisted.
--
--  Task safety: the loop runs on the calling task.
package Model_Runner.CLI.Interactive is

   --  What a line of input asks for.
   type Command_Kind is
     (Not_A_Command,
      Leave,
      Reset,
      Help,
      Settings,
      Statistics,
      Context,
      Set_System,
      Unknown);

   --  Where the argument of a command sits in the line.
   type Parsed_Command is record
      Kind  : Command_Kind := Not_A_Command;
      First : Natural := 0;
      Last  : Natural := 0;
   end record;

   --  Read one line of input as a command.
   --
   --  Separated from the loop that acts on it so that it can be tested:
   --  the loop itself needs a terminal at both ends and no test drives it.
   --
   --  @param Line One line of input, already stripped of its terminator.
   --  @return What the line asks for. First and Last bound the argument
   --    within Line, and are zero when there is none. A line that does not
   --    begin with a slash is Not_A_Command, which is ordinary text.
   function Parse (Line : String) return Parsed_Command;

   --  Largest prompt one turn may accumulate before it is submitted.
   Max_Turn_Bytes : constant := 65_536;

   --  What one line of input did to the turn being built.
   type Line_Effect is
     (Held,        --  added to the turn, which is not finished
      Submits,     --  a blank line: the turn, if any, is complete
      Is_Command,  --  a slash command, to be read with Parse
      Too_Long);   --  the line would push the turn past Max_Turn_Bytes

   --  A turn being typed. Release with Close, which is idempotent.
   type Turn is tagged limited private;

   --  Begin an empty turn.
   --
   --  @param Item Turn to open; released first.
   --  @param Ok False when the buffer could not be allocated.
   procedure Open (Item : in out Turn; Ok : out Boolean);

   --  Release a turn.
   --
   --  @param Item Turn to release.
   procedure Close (Item : in out Turn);

   --  Offer one line of input to the turn.
   --
   --  This is the whole input policy: non-empty lines accumulate, separated
   --  by line feeds; a blank line submits; and a line is read as a command
   --  only when nothing is pending, so that a slash on the second line of a
   --  prompt is the text it looks like rather than a command interrupting a
   --  half-typed thought.
   --
   --  A line that would push the turn past Max_Turn_Bytes is refused and the
   --  turn is emptied, because a turn that kept the part that fit would send
   --  the model half a sentence.
   --
   --  @param Item Turn to add to.
   --  @param Line One line of input, already stripped of its terminator.
   --  @param Effect What the line did.
   procedure Offer
     (Item   : in out Turn;
      Line   : String;
      Effect : out Line_Effect);

   --  The prompt accumulated so far, empty when there is none.
   --
   --  @param Item Turn to read.
   --  @return The accumulated text.
   function Pending (Item : Turn) return String;

   --  Empty the turn, after its prompt has been taken.
   --
   --  @param Item Turn to empty.
   procedure Taken (Item : in out Turn);

   --  Hold a conversation until the user leaves or input ends.
   --
   --  @param Item Typed command supplying the sampling and stop settings.
   --  @param Screen Console for prompts, diagnostics and statistics.
   --  @param Prepared Prepared model.
   --  @param Session Open session on that model.
   --  @param Status Process exit status.
   procedure Run
     (Item     : Model_Runner.CLI.Options.Command;
      Screen   : in out Model_Runner.Presentation.Console;
      Prepared : in out Model_Runner.Llama.Model;
      Session  : in out Model_Runner.Llama.Session;
      Status   : out Natural);

private

   type Text_Access is access String;

   --  Held on the heap rather than inline: a turn is sixty-four kilobytes,
   --  and the loop that owns one runs on the calling task.
   type Turn is tagged limited record
      Room : Text_Access := null;
      Used : Natural := 0;
   end record;

end Model_Runner.CLI.Interactive;
