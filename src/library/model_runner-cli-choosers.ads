private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

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
   --  @return The chosen choice's position, or zero when the reader gave
   --    up or there is no terminal to ask at.
   function Choose
     (Screen : Model_Runner.Presentation.Console;
      Title  : String;
      Items  : Choice_List) return Natural;

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
      Done      : Boolean := False;
      Result    : Natural := 0;
   end record;

end Model_Runner.CLI.Choosers;
