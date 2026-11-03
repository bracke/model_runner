private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Presentation;

--  The one terminal interface every command that asks shares.
--
--  A selector lists choices, a cursor on one of them. The arrow keys move
--  it, page keys move a screen at a time, / starts a filter that narrows
--  the list as it is typed, Tab shows the details of the choice under the
--  cursor, Enter chooses and Escape gives up. A choice that cannot be
--  taken -- a blocked task -- is shown, and Enter on it shows why rather
--  than taking it. The window is measured again at every key, so a
--  resized terminal is drawn to its new size.
--
--  The selector itself is a value moved by keys and drawn as lines, with
--  no terminal in it, so what it does can be tested key by key. Choose is
--  what puts it on a terminal: raw mode for as long as it runs, and the
--  terminal's own mode back on every way out -- a choice, a cancel, an
--  interrupt, an exception.
--
--  Nothing here is used where there is no terminal to ask at. A command
--  run from a script says what it needs and stops instead; Is_Available
--  is how it knows which it is.
package Model_Runner.CLI.Choosers is

   --  One thing to choose.
   type Choice is record
      Label      : Ada.Strings.Unbounded.Unbounded_String;

      --  Shown before the label, as [ready]; may be empty.
      Tag        : Ada.Strings.Unbounded.Unbounded_String;

      --  What Tab shows, one line a line.
      Details    : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether Enter takes it, or only shows its details.
      Selectable : Boolean := True;
   end record;

   --  Things to choose, in the order shown.
   type Choice_List is private;

   --  Add a choice.
   --
   --  @param Into The list.
   --  @param Item The choice.
   procedure Append (Into : in out Choice_List; Item : Choice);

   --  How many choices a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Length (From : Choice_List) return Natural;

   --  What a key press means.
   type Key_Kind is
     (Up, Down, Page_Up, Page_Down, Home, End_Key, Return_Key, Escape, Tab,
      Backspace, Printable, Interrupt, Nothing);

   --  A key press.
   type Key is record
      Kind : Key_Kind := Nothing;

      --  The character, for a printable key.
      Char : Character := ' ';
   end record;

   --  The key a run of bytes read from a terminal starts with.
   --
   --  @param Bytes What was read.
   --  @param Used How many of them the key took; at least one when Bytes is
   --    not empty.
   --  @return The key; Nothing for bytes that mean none this knows.
   function Decode (Bytes : String; Used : out Natural) return Key;

   --  A selector over some choices.
   type Selector is private;

   --  Start a selector.
   --
   --  @param Items The choices.
   --  @return The selector, its cursor on the first choice.
   function Start (Items : Choice_List) return Selector;

   --  Move a selector by a key.
   --
   --  @param Item The selector.
   --  @param Pressed The key.
   --  @param Rows How many choices fit on the screen, for the page keys.
   procedure Press (Item : in out Selector; Pressed : Key; Rows : Positive);

   --  Whether a selector has finished: chosen or given up.
   --
   --  @param Item The selector.
   --  @return True when it has.
   function Finished (Item : Selector) return Boolean;

   --  What was chosen.
   --
   --  @param Item The selector.
   --  @return The chosen choice's position in the list given to Start, or
   --    zero when nothing was.
   function Chosen (Item : Selector) return Natural;

   --  How many choices the filter leaves.
   --
   --  @param Item The selector.
   --  @return The count.
   function Visible_Count (Item : Selector) return Natural;

   --  The words a selector is drawn with, in the reader's language.
   type Wording is record
      Title   : Ada.Strings.Unbounded.Unbounded_String;
      Keys    : Ada.Strings.Unbounded.Unbounded_String;
      Filter  : Ada.Strings.Unbounded.Unbounded_String;
      Nothing : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  A selector as lines to draw, fitted to a window.
   --
   --  @param Item The selector.
   --  @param Words What it says around the choices.
   --  @param Rows The window's height.
   --  @param Columns The window's width; each line is cut to fit it.
   --  @return The lines, at most Rows of them.
   function Render
     (Item    : Selector;
      Words   : Wording;
      Rows    : Positive;
      Columns : Positive) return Framework.Name_Lists.Vector;

   --  Whether a selector can be put on the terminal: standard input and
   --  standard error are both one, and it can be drawn on.
   --
   --  @return True when Choose would ask.
   function Is_Available return Boolean;

   --  Whether a selector can be put on the terminal for a console: one can,
   --  and the console is not writing for a program -- a command asked for
   --  --format json answers, and never asks.
   --
   --  @param Screen The console.
   --  @return True when Choose would ask.
   function Is_Available (Screen : Model_Runner.Presentation.Console) return Boolean;

   --  Ask on the terminal.
   --
   --  @param Screen Where the words come from.
   --  @param Title What is being chosen, as a catalog key.
   --  @param Items The choices.
   --  @param Heading Words that say what is chosen, in place of the
   --    title's, where the caller has them.
   --  @param Initial The choice the cursor starts on.
   --  @return The chosen choice's position, or zero when the reader gave
   --    up or there is no terminal to ask at.
   function Choose
     (Screen  : Model_Runner.Presentation.Console;
      Title   : String;
      Items   : Choice_List;
      Heading : String := "";
      Initial : Positive := 1) return Natural;

   --  How a line typed by Typed_Line ended.
   type Line_End is (Entered, Escaped, Interrupted, Ended, Unavailable);

   --  A short answer typed at the terminal, shown as it is typed: Enter
   --  ends it, Backspace takes a character back, and Escape or Ctrl-C end
   --  it at once, with nothing more to press. Unavailable where there is no
   --  terminal to read it from that way; the caller reads a line then.
   --
   --  @param Outcome How it ended.
   --  @return What was typed; empty unless it was Entered.
   function Typed_Line (Outcome : out Line_End) return String;

   --  A question said, then a yes or no read as Answered_Yes reads one.
   --
   --  @param Screen Where it is asked.
   --  @param Question The question, with its (yes/no).
   --  @return Whether the answer was yes.
   function Confirmed_Line (Screen : in out Model_Runner.Presentation.Console; Question : String) return Boolean;

   --  Speech into the line being typed: the editor's side of it.
   --
   --  The shortcut starts a recording; pressed again it stops, and what was
   --  said is heard while the editor waits, then put into the line at the
   --  cursor as one edit -- typed text before and after it kept, a space
   --  between where there is none -- to be edited and entered as any line
   --  is. Nothing is entered, run or sent by it: a transcript that begins
   --  with a slash is not a command until the person makes it one.
   --
   --  Escape or Ctrl-C while it records drops the recording; while it is
   --  heard, stops hearing it. Ctrl-_ takes the last transcript out again,
   --  the line as it was before it, while nothing else has changed the
   --  line. Every other key pressed meanwhile is kept, in
   --  order, and acted on once the transcript is in -- typed after it, so
   --  nothing typed is lost and nothing the transcript lands on moves.
   --
   --  The calls return at once, the work being elsewhere; what the person
   --  is shown -- that it records and for how long, that it is heard, why
   --  it failed -- the editor says, in the reader's language.
   type Dictation is limited interface;

   --  Begin recording.
   --
   --  @param Item The dictation.
   --  @param Status Success, or why not: speech off, already busy.
   procedure Begin_Dictation (Item : in out Dictation; Status : out Model_Runner.Errors.Error_Info) is abstract;

   --  How long the recording under way has run.
   --
   --  @param Item The dictation.
   --  @return Whole seconds.
   function Seconds (Item : Dictation) return Natural is abstract;

   --  Whether the recording stopped of itself: at its longest, or the
   --  microphone failing.
   --
   --  @param Item The dictation.
   --  @return True once it has.
   function Ended_Itself (Item : Dictation) return Boolean is abstract;

   --  Stop recording and begin hearing it.
   --
   --  @param Item The dictation.
   procedure End_Dictation (Item : in out Dictation) is abstract;

   --  Drop the recording, or stop hearing it.
   --
   --  @param Item The dictation.
   procedure Abandon (Item : in out Dictation) is abstract;

   --  Whether what was recorded has been heard, or hearing it failed.
   --
   --  @param Item The dictation.
   --  @return True when Take has something to give.
   function Is_Done (Item : Dictation) return Boolean is abstract;

   --  What was heard.
   --
   --  @param Item The dictation.
   --  @param Text The transcript; empty where nothing was heard or it failed.
   --  @param Status Success, Generation_Cancelled where it was given up, or
   --    why it failed.
   --  @param Limit_Reached Whether the recording stopped at its longest.
   procedure Take
     (Item          : in out Dictation;
      Text          : out Ada.Strings.Unbounded.Unbounded_String;
      Status        : out Model_Runner.Errors.Error_Info;
      Limit_Reached : out Boolean) is abstract;

   type Dictation_Access is access all Dictation'Class;

   --  How a transcript goes into a line: the editor's policy, apart so that
   --  it can be held to.
   --
   --  Line ends and tabs in it become spaces, and it is trimmed. A space is
   --  put before it where the character before the cursor is not one, and
   --  after it where the character after is a letter or a digit. Where it
   --  would begin the line with a slash, a space goes before it: a command
   --  is typed, not dictated. The cursor ends after it.
   --
   --  @param Line The line; the transcript is put into it.
   --  @param Cursor Bytes before the cursor; after the transcript once in.
   --  @param Spoken The transcript.
   --  @param Most The longest the line may become, in bytes.
   --  @param Done False, the line untouched, where the transcript is empty
   --    once trimmed, is not valid UTF-8, or would make the line too long.
   procedure Insert_Spoken
     (Line   : in out Ada.Strings.Unbounded.Unbounded_String;
      Cursor : in out Natural;
      Spoken : String;
      Most   : Natural;
      Done   : out Boolean);

   --  What Tab completes the last word of a line to: each whole word it
   --  may become, given what is typed before the cursor.
   type Completer is access function (Before : String) return Model_Runner.Framework.Name_Lists.Vector;

   --  What a word Tab lists stands for, shown beside it: empty for none.
   type Describer is access function (Word : String) return String;

   --  A line typed at the session's prompt, edited as it is typed and its
   --  commands coloured as they are: the cursor moves with the arrows,
   --  Home and End (Ctrl-A, Ctrl-E), Backspace and Delete take a character,
   --  Ctrl-U, Ctrl-K and Ctrl-W what is before or after the cursor or the
   --  word before it, Up and Down step through the lines typed before,
   --  Ctrl-L clears the screen. Enter ends it; Escape and Ctrl-C end it at
   --  once, dropping it; Ctrl-D on an empty line ends the input. Tab
   --  completes the word at the cursor: the one word it can be, or what
   --  those it can be share, and pressed again, those words listed. A line
   --  typed before that this one begins, or what Tab would complete to, is
   --  shown dimmed after the cursor: Right takes it, Ctrl-Right its next
   --  word.
   --  Unavailable where there is no terminal to read it from that way; the
   --  caller shows the prompt and reads a line then.
   --
   --  @param Screen Where it is shown, and how commands are coloured.
   --  @param Prompt The prompt, as shown before the line.
   --  @param Outcome How it ended.
   --  @param Complete What Tab completes a word to; null, Tab completes nothing.
   --  @param Describe What a listed word stands for: identifiers listed a
   --    line each with it; null, they are listed bare.
   --  @param Dictate Speech into the line, or null: the shortcut then does
   --    nothing.
   --  @param Shortcut The key that starts and stops a recording: Ctrl-G
   --    unless said.
   --  @return What was typed.
   function Edited_Line
     (Screen   : Model_Runner.Presentation.Console;
      Prompt   : String;
      Outcome  : out Line_End;
      Complete : Completer := null;
      Describe : Describer := null;
      Dictate  : Dictation_Access := null;
      Shortcut : Character := Character'Val (7)) return String;

   --  Take the line typed last out of what Up and the dimmed suggestion
   --  offer again: a command refused is not one to be offered back.
   procedure Forget_Last_Line;

   --  A yes or no read from the person: anything else asked again, a
   --  command typed in its place said and not run, and no answer, Escape
   --  or Ctrl-C a no -- at a terminal at once, with nothing more to press.
   --
   --  @param Screen Where to say what was understood.
   --  @return True for a yes.
   function Answered_Yes (Screen : in out Model_Runner.Presentation.Console) return Boolean;

   --  Ask for one value on the terminal: from the choices by the selector
   --  when there are any, typed on a line when there are none.
   --
   --  @param Screen Where to write.
   --  @param Label What is asked for.
   --  @param Detail What it is for; may be empty.
   --  @param Choices The values it may take, separated by commas; empty for
   --    any.
   --  @param Default What an empty answer takes; may be empty.
   --  @param Answer The value.
   --  @param Given Whether one was given, rather than the reader giving up.
   --  @param Secret Whether what is typed is a secret: not shown as it is
   --    typed, a mark standing for each character, and given up on with
   --    Escape or Ctrl-C.
   --  @param Required Whether an empty answer with no default is asked
   --    again, said so, rather than taken as giving up: only the end of
   --    input -- Ctrl-D -- or Escape gives up then.
   procedure Ask
     (Screen  : in out Model_Runner.Presentation.Console;
      Label   : String;
      Detail  : String;
      Choices : String;
      Default : String;
      Answer  : out Ada.Strings.Unbounded.Unbounded_String;
      Given   : out Boolean;
      Secret  : Boolean := False;
      Required : Boolean := False);

private

   package Choice_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Choice);

   package Index_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Positive);

   type Choice_List is record
      Items : Choice_Vectors.Vector;
   end record;

   type Selector is record
      Items     : Choice_Vectors.Vector;

      --  The positions of the choices the filter leaves, in order.
      Visible   : Index_Vectors.Vector;

      --  Where the cursor is in Visible, and the first shown.
      Cursor    : Natural := 0;
      Top       : Natural := 1;

      Filter    : Ada.Strings.Unbounded.Unbounded_String;
      Filtering : Boolean := False;
      Details   : Boolean := False;
      Told      : Boolean := False;
      Done      : Boolean := False;
      Result    : Natural := 0;
   end record;

end Model_Runner.CLI.Choosers;
