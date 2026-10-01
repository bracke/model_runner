with Ada.Characters.Handling;
with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Text_IO;
with Interfaces.C_Streams;

with Hostkit.Descriptors;
with Hostkit.Terminal_Control;

with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Platform.Signals;

package body Model_Runner.CLI.Choosers is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Hostkit.Descriptors.Transfer_Outcome;

   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package Term renames Hostkit.Terminal_Control;

   ------------
   -- Append --
   ------------

   procedure Append (Into : in out Choice_List; Item : Choice) is
   begin
      Into.Items.Append (Item);
   end Append;

   function Length (From : Choice_List) return Natural
   is (Natural (From.Items.Length));

   --  Whether bytes are the start of a key's sequence and not all of it:
   --  an escape alone, or escape and [ or O, or escape, [ and a digit
   --  still waiting for its ~ -- what a terminal behind SSH or tmux, or a
   --  read that ended mid-key, hands over in two pieces.
   function Incomplete (Bytes : String) return Boolean
   is (Bytes'Length > 0 and then Bytes (Bytes'First) = ASCII.ESC
       and then (Bytes'Length = 1
                 or else (Bytes'Length = 2 and then Bytes (Bytes'First + 1) in '[' | 'O')
                 or else (Bytes'Length = 3 and then Bytes (Bytes'First + 1) = '['
                          and then Bytes (Bytes'First + 2) in '0' .. '9')));

   ------------
   -- Decode --
   ------------

   function Decode (Bytes : String; Used : out Natural) return Key is
      First : constant Character :=
        (if Bytes'Length = 0 then ASCII.NUL else Bytes (Bytes'First));
   begin
      Used := Natural'Min (1, Bytes'Length);
      if Bytes'Length = 0 then
         return (Kind => Nothing, Char => ' ');
      end if;

      case First is
         when ASCII.CR | ASCII.LF => return (Return_Key, ' ');
         when ASCII.HT            => return (Tab, ' ');
         when ASCII.BS | ASCII.DEL => return (Backspace, ' ');
         when ASCII.ETX           => return (Interrupt, ' ');
         when ASCII.ESC =>
            --  An escape alone is Escape; followed by [ or O it starts the
            --  sequence a cursor key sends.
            if Bytes'Length >= 3
              and then Bytes (Bytes'First + 1) in '[' | 'O'
            then
               Used := 3;
               case Bytes (Bytes'First + 2) is
                  when 'A' => return (Up, ' ');
                  when 'B' => return (Down, ' ');
                  when 'H' => return (Home, ' ');
                  when 'F' => return (End_Key, ' ');
                  when '1' | '4' | '5' | '6' | '7' | '8' =>
                     --  The keys that end in ~: page up and down, and the
                     --  home and end tmux and the Linux console send.
                     if Bytes'Length >= 4 and then Bytes (Bytes'First + 3) = '~'
                     then
                        Used := 4;
                        return
                          ((case Bytes (Bytes'First + 2) is
                              when '5'       => Page_Up,
                              when '6'       => Page_Down,
                              when '1' | '7' => Home,
                              when others    => End_Key), ' ');
                     end if;
                     return (Nothing, ' ');
                  when others => return (Nothing, ' ');
               end case;
            end if;
            return (Escape, ' ');
         when ' ' .. '~' =>
            return (Printable, First);
         when others =>
            --  A byte of a character outside ASCII, taken whole so a filter
            --  can hold it.
            return (Printable, First);
      end case;
   end Decode;

   --  Work out which choices the filter leaves, keeping the cursor on the
   --  choice it was on when that one is still there.
   procedure Refilter (Item : in out Selector) is
      Before : constant Natural :=
        (if Item.Cursor in 1 .. Natural (Item.Visible.Length)
         then Item.Visible (Item.Cursor) else 0);
      Wanted : constant String :=
        Ada.Characters.Handling.To_Lower (To_String (Item.Filter));
   begin
      Item.Visible.Clear;
      for Index in 1 .. Natural (Item.Items.Length) loop
         declare
            Said : constant String :=
              Ada.Characters.Handling.To_Lower
                (To_String (Item.Items (Index).Tag) & " "
                 & To_String (Item.Items (Index).Label));
         begin
            if Wanted = "" or else Ada.Strings.Fixed.Index (Said, Wanted) > 0 then
               Item.Visible.Append (Index);
            end if;
         end;
      end loop;

      Item.Cursor := (if Item.Visible.Is_Empty then 0 else 1);
      for Place in 1 .. Natural (Item.Visible.Length) loop
         if Item.Visible (Place) = Before then
            Item.Cursor := Place;
         end if;
      end loop;
      Item.Top := 1;
   end Refilter;

   -----------
   -- Start --
   -----------

   function Start (Items : Choice_List) return Selector is
      Result : Selector;
   begin
      Result.Items := Items.Items;
      Refilter (Result);
      return Result;
   end Start;

   -----------
   -- Press --
   -----------

   procedure Press (Item : in out Selector; Pressed : Key; Rows : Positive) is
      Count : constant Natural := Natural (Item.Visible.Length);
   begin
      if Item.Done then
         return;
      end if;
      --  The mark of a refused Enter lasts until the next key.
      if Pressed.Kind /= Return_Key then
         Item.Told := False;
      end if;

      --  Typing a filter takes the keys that are characters; the moves and
      --  Enter and Escape still mean what they mean, Escape ending the
      --  filter first and the selector only when there is none.
      if Item.Filtering then
         case Pressed.Kind is
            when Printable =>
               Append (Item.Filter, Pressed.Char);
               Refilter (Item);
               return;
            when Backspace =>
               if Length (Item.Filter) > 0 then
                  Head (Item.Filter, Length (Item.Filter) - 1);
                  Refilter (Item);
               else
                  Item.Filtering := False;
               end if;
               return;
            when Escape =>
               Item.Filtering := False;
               Item.Filter := Null_Unbounded_String;
               Refilter (Item);
               return;
            when others =>
               Item.Filtering := False;
         end case;
      end if;

      case Pressed.Kind is
         when Up =>
            Item.Cursor := Natural'Max (Natural'Min (1, Count), Item.Cursor - 1);
         when Down =>
            Item.Cursor := Natural'Min (Count, Item.Cursor + 1);
         when Page_Up =>
            Item.Cursor :=
              Natural'Max (Natural'Min (1, Count), Item.Cursor - Integer'Min
                             (Item.Cursor, Rows));
            Item.Cursor := Natural'Max (Natural'Min (1, Count), Item.Cursor);
         when Page_Down =>
            Item.Cursor := Natural'Min (Count, Item.Cursor + Rows);
         when Home =>
            Item.Cursor := Natural'Min (1, Count);
         when End_Key =>
            Item.Cursor := Count;
         when Tab =>
            Item.Details := not Item.Details;
         when Printable =>
            if Pressed.Char = '/' then
               Item.Filtering := True;
            elsif Pressed.Char = 'q' then
               Item.Done := True;

            --  A number is the choice of that number; any other character
            --  starts a filter with it.
            elsif Pressed.Char in '1' .. '9' then
               if Character'Pos (Pressed.Char) - Character'Pos ('0') <= Count then
                  Item.Cursor := Character'Pos (Pressed.Char) - Character'Pos ('0');
               end if;
            elsif Pressed.Char /= ' ' then
               Item.Filtering := True;
               Append (Item.Filter, Pressed.Char);
               Refilter (Item);
               return;
            end if;
         when Return_Key =>
            if Item.Cursor > 0 then
               if Item.Items (Item.Visible (Item.Cursor)).Selectable then
                  Item.Result := Item.Visible (Item.Cursor);
                  Item.Done := True;
               else
                  --  Why it cannot be taken, rather than taking it: shown
                  --  whether or not details were on already.
                  Item.Details := True;
                  Item.Told := True;
               end if;
            end if;
         when Escape =>
            --  A filter still narrowing the list is let go of first.
            if Length (Item.Filter) > 0 then
               Item.Filter := Null_Unbounded_String;
               Refilter (Item);
               return;
            end if;
            Item.Done := True;
            Item.Result := 0;
         when Interrupt =>
            Item.Done := True;
            Item.Result := 0;
         when Backspace | Nothing =>
            null;
      end case;

      --  Keep the cursor in the window.
      if Item.Cursor > 0 then
         if Item.Cursor < Item.Top then
            Item.Top := Item.Cursor;
         elsif Item.Cursor >= Item.Top + Rows then
            Item.Top := Item.Cursor - Rows + 1;
         end if;
      end if;
   end Press;

   function Finished (Item : Selector) return Boolean
   is (Item.Done);

   function Chosen (Item : Selector) return Natural
   is (if Item.Done then Item.Result else 0);

   function Visible_Count (Item : Selector) return Natural
   is (Natural (Item.Visible.Length));

   --  The cursor: two spaces, U+25B8 in UTF-8, a space.
   Marker : constant String :=
     "  " & Character'Val (16#E2#) & Character'Val (16#96#)
     & Character'Val (16#B8#) & " ";

   --  A line cut to a width counted in characters, not bytes.
   function Fit (Text : String; Columns : Positive) return String is
      Width : Natural := 0;
   begin
      for Index in Text'Range loop
         if Character'Pos (Text (Index)) not in 16#80# .. 16#BF# then
            Width := Width + 1;
            if Width > Columns then
               return Text (Text'First .. Index - 1);
            end if;
         end if;
      end loop;
      return Text;
   end Fit;

   --  A text's lines, each broken at a space where it is wider than the
   --  window: what does not fit is shown on the rows below, not cut off.
   function Wrapped (Text : String; Columns : Positive) return Framework.Name_Lists.Vector is
      Result : Framework.Name_Lists.Vector;

      procedure Add (Line : String) is
         Width : Natural := 0;
         Cut   : Natural := 0;
      begin
         for Index in Line'Range loop
            if Character'Pos (Line (Index)) not in 16#80# .. 16#BF# then
               Width := Width + 1;
            end if;
            if Line (Index) = ' ' then
               Cut := Index;
            end if;
            if Width > Columns then
               if Cut > Line'First then
                  Result.Append (Line (Line'First .. Cut - 1));
                  Add (Line (Cut + 1 .. Line'Last));
               else
                  Result.Append (Line (Line'First .. Index - 1));
                  Add (Line (Index .. Line'Last));
               end if;
               return;
            end if;
         end loop;
         Result.Append (Line);
      end Add;
   begin
      for Line of Framework.Lines_Of (Text) loop
         Add (Line);
      end loop;
      return Result;
   end Wrapped;

   ------------
   -- Render --
   ------------

   function Render
     (Item    : Selector;
      Words   : Wording;
      Rows    : Positive;
      Columns : Positive) return Framework.Name_Lists.Vector
   is
      Result  : Framework.Name_Lists.Vector;
      Details : Framework.Name_Lists.Vector;
      Room    : Integer;
   begin
      if Item.Details and then Item.Cursor > 0 then
         Details := Wrapped
           (To_String (Item.Items (Item.Visible (Item.Cursor)).Details), Positive'Max (1, Columns - 4));

      end if;

      --  The title -- a line or several, as a plan shown above its
      --  question -- the list, a blank, the details, the keys.
      declare
         Title : constant Framework.Name_Lists.Vector :=
           Wrapped (To_String (Words.Title), Columns);
         Extra : constant Integer :=
           Integer (Details.Length) + (if Details.Is_Empty then 0 else 1);
         --  A title too long for the window keeps its last lines, the
         --  question, and room for a few choices.
         Shown : constant Integer :=
           Integer'Max (1, Integer'Min (Integer (Title.Length),
                                        Rows - 2 - Extra - Integer'Min (Visible_Count (Item), 4)));
      begin
         Room := Integer'Max (1, Rows - 2 - Shown - Extra);
         if Title.Is_Empty then
            Result.Append ("");
         end if;
         for Index in Integer (Title.Length) - Shown + 1 .. Integer (Title.Length) loop
            if Index >= 1 then
               Result.Append (Fit (Title (Index), Columns));
            end if;
         end loop;
      end;
      if Visible_Count (Item) = 0 then
         Result.Append (Fit ("    " & To_String (Words.Nothing), Columns));
      end if;
      for Place in Item.Top .. Natural'Min
                                  (Natural (Item.Visible.Length),
                                   Item.Top + Room - 1)
      loop
         declare
            Shown : Choice renames Item.Items (Item.Visible (Place));
            Tag   : constant String := To_String (Shown.Tag);
         begin
            Result.Append
              (Fit ((if Place = Item.Cursor then Marker else "    ")
                    & (if Tag = "" then "" else Tag & "  ")
                    & To_String (Shown.Label),
                    Columns));
         end;
      end loop;
      Result.Append ("");
      if not Details.Is_Empty then
         for Line of Details loop
            Result.Append (Fit ("    " & Line, Columns));
         end loop;
         Result.Append ("");
      end if;
      --  The keys, wrapped where the window is narrow -- not cut, so
      --  what Esc does is always there to read.
      for Line of Wrapped ((if Item.Filtering or else Length (Item.Filter) > 0
                            then To_String (Words.Filter) & " " & To_String (Item.Filter)
                            else To_String (Words.Keys)),
                           Columns)
      loop
         Result.Append (Line);
      end loop;

      while Natural (Result.Length) > Rows loop
         Result.Delete_Last;
      end loop;
      return Result;
   end Render;

   ---------------------------------------------------------------------------
   --  The terminal.
   ---------------------------------------------------------------------------

   function Input return Hostkit.Descriptors.Descriptor
   renames Hostkit.Descriptors.Standard_Input;

   function Output return Hostkit.Descriptors.Descriptor
   renames Hostkit.Descriptors.Standard_Error;

   ------------------
   -- Is_Available --
   ------------------

   function Is_Available return Boolean
   is (Model_Runner.Platform.Is_Terminal (0)
       and then Model_Runner.Platform.Is_Terminal (2)
       and then Term.Supports_Cursor_Control (Output));

   function Is_Available (Screen : Model_Runner.Presentation.Console) return Boolean
   is (Is_Available and then not Pres.Is_Structured (Screen));

   --  The terminal's own mode, put back however the selector ends.
   type Raw_Guard is new Ada.Finalization.Limited_Controlled with record
      Saved     : Term.Mode;
      Held      : Boolean := False;

      --  Drawing on the alternate screen, to be left however it ends.
      Alternate : Boolean := False;
   end record;

   overriding procedure Finalize (Guard : in out Raw_Guard);

   overriding procedure Finalize (Guard : in out Raw_Guard) is
      Ignored : Boolean;
   begin
      if Guard.Held then
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         if Guard.Alternate then
            Ignored := Term.Control (Output, Term.Leave_Alternate_Screen);
            Guard.Alternate := False;
         end if;
         Ignored := Term.Control (Output, Term.Show_Cursor);
         Ignored := Term.Restore_Mode (Input, Guard.Saved);
         Guard.Held := False;
      end if;
   end Finalize;

   procedure Control (Action : Term.Cursor_Action; Count : Natural := 1) is
      Ignored : Boolean;
   begin
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      Ignored := Term.Control (Output, Action, Count);
   end Control;

   ------------
   -- Choose --
   ------------

   function Choose
     (Screen  : Model_Runner.Presentation.Console;
      Title   : String;
      Items   : Choice_List;
      Heading : String := "") return Natural
   is
      Guard : Raw_Guard;
      State : Selector := Start (Items);
      Drawn : Natural := 0;
      Words : constant Wording :=
        (Title   => To_Unbounded_String
                      (if Heading /= "" then Heading else Pres.Message_Value (Screen, Title)),
         Keys    => To_Unbounded_String
                      (Pres.Message_Value (Screen, "cli.choose.keys")),
         Filter  => To_Unbounded_String
                      (Pres.Message_Value (Screen, "cli.choose.filter")),
         Nothing => To_Unbounded_String
                      (Pres.Message_Value (Screen, "cli.choose.nothing")));

      Pending : String (1 .. 64);
      Held    : Natural := 0;

      --  Draw over what was drawn last.
      procedure Draw is
         Size  : Term.Window_Size;
         Rows  : Positive := 24;
         Width : Positive := 80;
      begin
         --  Measured every time, so a resize is drawn at its new size.
         if Term.Size (Output, Size) and then Size.Rows > 2
           and then Size.Columns > 8
         then
            Rows := Size.Rows - 1;
            Width := Size.Columns - 1;
         end if;

         if Drawn > 0 then
            Control (Term.Move_Up, Drawn);
         end if;
         Control (Term.To_First_Column);

         declare
            Lines : constant Framework.Name_Lists.Vector :=
              Render (State, Words, Rows, Width);
         begin
            for Line of Lines loop
               Control (Term.Erase_Line);
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Line & ASCII.CR);
               Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
            end loop;

            --  A shorter frame than the last leaves lines to wipe.
            for Extra in Natural (Lines.Length) + 1 .. Drawn loop
               Control (Term.Erase_Line);
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR);
               Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
            end loop;
            if Drawn > Natural (Lines.Length) then
               Control (Term.Move_Up, Drawn - Natural (Lines.Length));
            end if;
            Drawn := Natural (Lines.Length);
         end;
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      end Draw;

      function Window_Rows return Positive is
         Size : Term.Window_Size;
      begin
         return (if Term.Size (Output, Size) and then Size.Rows > 6
                 then Size.Rows - 5 else 10);
      end Window_Rows;
   begin
      if not Is_Available (Screen) or else Length (Items) = 0 then
         return 0;
      end if;

      if not Term.Save_Mode (Input, Guard.Saved) then
         return 0;
      end if;
      Guard.Held := True;
      if not Term.Set_Raw (Input) then
         return 0;
      end if;
      --  Drawn on a screen of its own where the terminal has one: the one
      --  there was is given back as it was, with nothing it scrolled left
      --  behind. Drawn from where the cursor is, so that a terminal with no
      --  second screen draws in place as before.
      Control (Term.Enter_Alternate_Screen);
      Guard.Alternate := True;
      Control (Term.Hide_Cursor);

      while not Finished (State) loop
         Draw;

         --  Wait for a key, and meanwhile watch the window: a resize while
         --  nobody types is drawn at once at the new size, not at the next
         --  key.
         declare
            Was, Now : Term.Window_Size;
            Measured : constant Boolean := Term.Size (Output, Was);
         begin
            while not Hostkit.Descriptors.Wait_Readable (Input, 200) loop
               if Measured and then Term.Size (Output, Now)
                 and then (Now.Rows /= Was.Rows or else Now.Columns /= Was.Columns)
               then
                  Draw;
                  Was := Now;
               end if;
            end loop;
         end;

         --  Read what is there, and act on every key it holds.
         declare
            Buffer : Ada.Streams.Stream_Element_Array (1 .. 32);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            if Hostkit.Descriptors.Read (Input, Buffer, Last)
                 /= Hostkit.Descriptors.Transfer_Ok
              or else Last < Buffer'First
            then
               State.Done := True;
               State.Result := 0;
            else
               for Byte of Buffer (Buffer'First .. Last) loop
                  if Held < Pending'Last then
                     Held := Held + 1;
                     Pending (Held) := Character'Val (Byte);
                  end if;
               end loop;
            end if;
         end;

         while Held > 0 and then not Finished (State) loop
            --  A key's sequence part way: the rest is waited for, briefly,
            --  before an escape is taken for Escape.
            exit when Incomplete (Pending (1 .. Held))
              and then Hostkit.Descriptors.Wait_Readable (Input, 50);
            declare
               Used    : Natural;
               Pressed : constant Key := Decode (Pending (1 .. Held), Used);
            begin
               Press (State, Pressed, Window_Rows);
               Pending (1 .. Held - Used) := Pending (Used + 1 .. Held);
               Held := Held - Used;
            end;
         end loop;
      end loop;

      --  Leave the terminal as the list found it: the drawing wiped, the
      --  cursor shown, the mode restored.
      if Drawn > 0 then
         Control (Term.Move_Up, Drawn);
         for Line in 1 .. Drawn loop
            Control (Term.Erase_Line);
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR);
            Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
         end loop;
         Control (Term.Move_Up, Drawn);
      end if;
      Finalize (Guard);
      return Chosen (State);
   end Choose;

   --  A line typed at the terminal, or nothing at the end of input.
   --  Given up by Ctrl-D, Ctrl-C or Esc: the question is, not whatever
   --  asked it -- a session goes on reading after it.
   function Line (Ended : out Boolean) return String is
      Before : constant Natural := Model_Runner.Platform.Signals.Interrupts;
   begin
      Ended := False;
      --  At a terminal, read raw: Escape and Ctrl-C give up at once.
      declare
         Ending : Line_End;
         Raw    : constant String := Typed_Line (Ending);
      begin
         if Ending /= Unavailable then
            Ended := Ending /= Entered;
            return Raw;
         end if;
      end;
      declare
         Typed : constant String := Ada.Text_IO.Get_Line;
      begin
         if Model_Runner.Platform.Signals.Interrupts /= Before
           or else Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ESC]) > 0
           or else Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ETX]) > 0
         then
            --  An Esc the terminal echoed as it is: its sequence cancelled,
            --  not ended by the next output's first character.
            if Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ESC]) > 0 then
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CAN);
            end if;
            Ended := True;
            return "";
         end if;
         return Typed;
      end;
   exception
      when Ada.Text_IO.End_Error =>
         --  Ctrl-D ends the answer, not the input: the terminal's end mark
         --  is let go of, so what reads after it reads on.
         Interfaces.C_Streams.clearerr (Interfaces.C_Streams.stdin);
         Ended := True;
         return "";
   end Line;

   ---------
   -- Ask --
   ---------

   procedure Ask
     (Screen  : in out Model_Runner.Presentation.Console;
      Label   : String;
      Detail  : String;
      Choices : String;
      Default : String;
      Answer  : out Ada.Strings.Unbounded.Unbounded_String;
      Given   : out Boolean;
      Secret  : Boolean := False;
      Required : Boolean := False)
   is
      Options : Choice_List;

      --  A line typed with nothing of it shown: raw, a mark for each
      --  character, Backspace taking one back, Enter ending it, Escape or
      --  Ctrl-C giving up. The terminal's own mode is put back however it
      --  ends.
      function Hidden_Line (Gave_Up : out Boolean) return String is
         Guard  : Raw_Guard;
         Typed  : Unbounded_String;
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last   : Ada.Streams.Stream_Element_Offset;
      begin
         Gave_Up := False;
         if not Term.Save_Mode (Input, Guard.Saved) then
            Gave_Up := True;
            return "";
         end if;
         Guard.Held := True;
         if not Term.Set_Raw (Input) then
            Gave_Up := True;
            return "";
         end if;
         loop
            if Hostkit.Descriptors.Read (Input, Buffer, Last) /= Hostkit.Descriptors.Transfer_Ok
              or else Last < Buffer'First
            then
               Gave_Up := True;
               exit;
            end if;
            declare
               Key : constant Character := Character'Val (Buffer (Buffer'First));
            begin
               if Key in ASCII.CR | ASCII.LF then
                  exit;
               elsif Key in ASCII.ESC | ASCII.ETX then
                  Gave_Up := True;
                  exit;
               elsif Key in ASCII.DEL | ASCII.BS then
                  if Length (Typed) > 0 then
                     Delete (Typed, Length (Typed), Length (Typed));
                     Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.BS & " " & ASCII.BS);
                  end if;
               elsif Key >= ' ' then
                  Append (Typed, Key);
                  Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, "*");
               end if;
               Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
            end;
         end loop;
         Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR);
         Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
         Finalize (Guard);
         return (if Gave_Up then "" else To_String (Typed));
      end Hidden_Line;
      procedure Put_Question is
         Shown : constant String := (if Secret then "" else Default);
      begin
         --  A question is asked however quiet: without it the answer is
         --  waited for unasked.
         Pres.Put_Aside
           (Screen,
            (if Detail /= "" and then Shown /= "" then "cli.choose.field"
             elsif Detail /= "" then "cli.choose.field.no_default"
             elsif Shown /= "" then "cli.choose.field.no_detail"
             else "cli.choose.field.bare"),
            [Loc.Named ("name", Label), Loc.Named ("detail", Detail),
             Loc.Named ("value", Shown)]);
      end Put_Question;

      --  Whether what was typed is a session's command, as /accept: one
      --  word after its slash. Typed where a value is asked for, it is not
      --  the value -- the question is given up and the command left alone.
      function Is_Command (Typed : String) return Boolean
      is (Typed'Length > 1 and then Typed (Typed'First) = '/'
          and then (for all C of Typed (Typed'First + 1 .. Typed'Last) =>
                      C in 'a' .. 'z' | ' ' | '-' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '='
                           | '"' | ''')
          and then Ada.Strings.Fixed.Index (Typed (Typed'First + 1 .. Typed'Last), "/") = 0);
   begin
      Answer := Null_Unbounded_String;
      Given := False;
      if not Is_Available (Screen) then
         return;
      end if;

      for Option of Framework.Lines_Of
                      (Ada.Strings.Fixed.Translate
                         (Choices, Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
      loop
         Append
           (Options,
            (Label  => To_Unbounded_String
                         (Ada.Strings.Fixed.Trim (Option, Ada.Strings.Both)),
             others => <>));
      end loop;

      --  One choice only: taken, and said, not asked.
      if Length (Options) = 1 then
         Answer := Options.Items (1).Label;
         Given := True;
         Pres.Put_Note
           (Screen, "cli.choose.only",
            [Loc.Named ("name", Label), Loc.Named ("value", To_String (Answer))]);
         return;
      end if;

      --  A choice among some: the list is the question, and what it came
      --  to is said after it -- nothing left asked and unanswered.
      if Length (Options) > 0 then
         declare
            Picked : constant Natural :=
              Choose (Screen, "cli.choose.one_of", Options,
                      Heading => Label & (if Detail = "" then "" else " (" & Detail & ")") & ":");
         begin
            if Picked > 0 then
               Answer := Options.Items (Picked).Label;
               Given := True;
               Pres.Put_Aside (Screen, "cli.choose.picked",
                               [Loc.Named ("name", Label), Loc.Named ("value", To_String (Answer))]);
            else
               Pres.Put_Aside (Screen, "cli.choose.left",
                               [Loc.Named ("name", Label),
                                Loc.Named ("value", (if Secret or else Default = "" then "unset" else Default))]);
            end if;
         end;
         return;
      end if;

      --  The question, with what it is for and what Enter takes where
      --  there are such: no empty brackets.
      Put_Question;

      loop
         declare
            Gave_Up : Boolean;
            Typed   : constant String :=
              (if Secret then Hidden_Line (Gave_Up)
               else Ada.Strings.Fixed.Trim (Line (Gave_Up), Ada.Strings.Both));
         begin
            if Gave_Up then
               return;
            elsif not Secret and then Is_Command (Typed) then
               Pres.Put_Note (Screen, "cli.choose.command_typed",
                              [Loc.Named ("name", Label), Loc.Named ("value", Typed)]);
               return;
            elsif Typed /= "" then
               Answer := To_Unbounded_String (Typed);
               Given := True;
               return;
            elsif Default /= "" then
               Answer := To_Unbounded_String (Default);
               Given := True;
               return;
            elsif not Required then
               return;
            end if;
            --  Nothing typed where something must be: asked again, the
            --  question with it.
            Pres.Put_Note (Screen, "cli.choose.needed", [Loc.Named ("name", Label)]);
            Put_Question;
         end;
      end loop;
   end Ask;

   ----------------
   -- Typed_Line --
   ----------------

   function Typed_Line (Outcome : out Line_End) return String is
      Guard  : Raw_Guard;
      Typed  : Unbounded_String;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Outcome := Unavailable;
      if not Is_Available or else not Term.Save_Mode (Input, Guard.Saved) then
         return "";
      end if;
      Guard.Held := True;
      if not Term.Set_Raw (Input) then
         return "";
      end if;
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      loop
         if Hostkit.Descriptors.Read (Input, Buffer, Last) /= Hostkit.Descriptors.Transfer_Ok
           or else Last < Buffer'First
         then
            Outcome := Ended;
            exit;
         end if;
         declare
            Key : constant Character := Character'Val (Buffer (Buffer'First));
         begin
            if Key in ASCII.CR | ASCII.LF then
               Outcome := Entered;
               exit;
            elsif Key = ASCII.ESC then
               --  The rest of a key's sequence -- an arrow -- is read and
               --  left: Escape alone, or a key that means nothing here.
               while Hostkit.Descriptors.Wait_Readable (Input, 30) loop
                  exit when Hostkit.Descriptors.Read (Input, Buffer, Last) /= Hostkit.Descriptors.Transfer_Ok;
               end loop;
               Outcome := Escaped;
               exit;
            elsif Key = ASCII.ETX then
               Outcome := Interrupted;
               exit;
            elsif Key = ASCII.EOT and then Length (Typed) = 0 then
               Outcome := Ended;
               exit;
            elsif Key in ASCII.DEL | ASCII.BS then
               if Length (Typed) > 0 then
                  Delete (Typed, Length (Typed), Length (Typed));
                  Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.BS & " " & ASCII.BS);
               end if;
            elsif Key >= ' ' then
               Append (Typed, Key);
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Key);
            end if;
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         end;
      end loop;
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR);
      Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
      Finalize (Guard);
      return (if Outcome = Entered then To_String (Typed) else "");
   end Typed_Line;

   function Confirmed_Line (Screen : in out Model_Runner.Presentation.Console; Question : String) return Boolean is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Question);
      return Answered_Yes (Screen);
   end Confirmed_Line;

   -----------------
   -- Edited_Line --
   -----------------

   --  The lines typed at the prompt this session, oldest first.
   History : Model_Runner.Framework.Name_Lists.Vector;

   function Edited_Line
     (Screen  : Model_Runner.Presentation.Console;
      Prompt  : String;
      Outcome : out Line_End) return String
   is
      Guard   : Raw_Guard;
      Text    : Unbounded_String;
      --  The cursor: the bytes before it.
      Cursor  : Natural := 0;
      --  The row the cursor was drawn on, counted from the prompt's.
      Drawn_Row : Natural := 0;
      --  Where Up and Down are in the history; past its end, the line
      --  being typed, kept while older ones are looked at.
      Looking : Natural := Natural (History.Length) + 1;
      Typing  : Unbounded_String;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last    : Ada.Streams.Stream_Element_Offset;

      procedure Put (Item : String) is
      begin
         Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Item);
      end Put;

      function Image (N : Natural) return String
      is (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));

      --  Characters, not bytes: a UTF-8 continuation byte is no column.
      function Width (Item : String) return Natural is
         Count : Natural := 0;
      begin
         for C of Item loop
            if Character'Pos (C) not in 16#80# .. 16#BF# then
               Count := Count + 1;
            end if;
         end loop;
         return Count;
      end Width;

      function Columns return Positive is
         Size : Term.Window_Size;
      begin
         if Term.Size (Hostkit.Descriptors.Standard_Error, Size) and then Size.Columns > 0 then
            return Size.Columns;
         end if;
         return 80;
      end Columns;

      --  The prompt and the line drawn again from the prompt's row, the
      --  cursor put where it is in the line.
      procedure Redraw is
         W        : constant Positive := Columns;
         Line     : constant String := To_String (Text);
         Before   : constant Natural := Width (Prompt);
         Total    : constant Natural := Before + Width (Line);
         At_Cursor : constant Natural := Before + Width (Line (Line'First .. Line'First + Cursor - 1));
         Wrapped  : Boolean := False;
         End_Row  : Natural;
      begin
         if Drawn_Row > 0 then
            Put (ASCII.ESC & "[" & Image (Drawn_Row) & "A");
         end if;
         Put (ASCII.CR & ASCII.ESC & "[J" & Prompt & Pres.Coloured_Commands (Screen, Line));
         --  Ended exactly at the edge with the cursor there: on to the next
         --  row, as the terminal would only once another character came.
         if Total > 0 and then Total mod W = 0 and then At_Cursor = Total then
            Put (ASCII.LF & ASCII.CR);
            Wrapped := True;
         end if;
         End_Row := (if Total > 0 and then Total mod W = 0 and then not Wrapped then Total / W - 1 else Total / W);
         if End_Row > At_Cursor / W then
            Put (ASCII.ESC & "[" & Image (End_Row - At_Cursor / W) & "A");
         end if;
         Put ([1 => ASCII.CR]);
         if At_Cursor mod W > 0 then
            Put (ASCII.ESC & "[" & Image (At_Cursor mod W) & "C");
         end if;
         Drawn_Row := At_Cursor / W;
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      end Redraw;

      --  One character back or on, a UTF-8 sequence whole.
      function Back (From : Natural) return Natural is
         At_Byte : Natural := From;
      begin
         if At_Byte = 0 then
            return 0;
         end if;
         At_Byte := At_Byte - 1;
         while At_Byte > 0 and then Character'Pos (Element (Text, At_Byte + 1)) in 16#80# .. 16#BF# loop
            At_Byte := At_Byte - 1;
         end loop;
         return At_Byte;
      end Back;

      function On (From : Natural) return Natural is
         At_Byte : Natural := From;
      begin
         if At_Byte >= Length (Text) then
            return Length (Text);
         end if;
         At_Byte := At_Byte + 1;
         while At_Byte < Length (Text) and then Character'Pos (Element (Text, At_Byte + 1)) in 16#80# .. 16#BF# loop
            At_Byte := At_Byte + 1;
         end loop;
         return At_Byte;
      end On;

      procedure Take (From, To : Natural) is
      begin
         if To > From then
            Delete (Text, From + 1, To);
         end if;
      end Take;

      procedure Show_History (Index : Positive) is
      begin
         Text := To_Unbounded_String (if Index > Natural (History.Length) then To_String (Typing)
                                      else History (Index));
         Cursor := Length (Text);
      end Show_History;

      --  Read one byte, where one comes within a wait in milliseconds.
      function Next (Wait : Integer := -1; Into : out Character) return Boolean is
      begin
         if Wait >= 0 and then not Hostkit.Descriptors.Wait_Readable (Input, Wait) then
            return False;
         end if;
         if Hostkit.Descriptors.Read (Input, Buffer, Last) /= Hostkit.Descriptors.Transfer_Ok
           or else Last < Buffer'First
         then
            return False;
         end if;
         Into := Character'Val (Buffer (Buffer'First));
         return True;
      end Next;

      Key : Character;
   begin
      Outcome := Unavailable;
      if not Is_Available (Screen) or else not Term.Save_Mode (Input, Guard.Saved) then
         return "";
      end if;
      Guard.Held := True;
      if not Term.Set_Raw (Input) then
         return "";
      end if;
      Redraw;
      loop
         if not Next (Into => Key) then
            Outcome := Ended;
            exit;
         end if;
         case Key is
            when ASCII.CR | ASCII.LF =>
               Outcome := Entered;
               exit;
            when ASCII.ETX =>
               Outcome := Interrupted;
               exit;
            when ASCII.EOT =>
               if Length (Text) = 0 then
                  Outcome := Ended;
                  exit;
               end if;
               Take (Cursor, On (Cursor));
            when ASCII.DEL | ASCII.BS =>
               declare
                  From : constant Natural := Back (Cursor);
               begin
                  Take (From, Cursor);
                  Cursor := From;
               end;
            when ASCII.SOH =>
               Cursor := 0;
            when ASCII.ENQ =>
               Cursor := Length (Text);
            when ASCII.STX =>
               Cursor := Back (Cursor);
            when ASCII.ACK =>
               Cursor := On (Cursor);
            when ASCII.VT =>
               Take (Cursor, Length (Text));
            when ASCII.NAK =>
               Take (0, Cursor);
               Cursor := 0;
            when ASCII.ETB =>
               declare
                  From : Natural := Cursor;
               begin
                  while From > 0 and then Element (Text, From) = ' ' loop
                     From := From - 1;
                  end loop;
                  while From > 0 and then Element (Text, From) /= ' ' loop
                     From := From - 1;
                  end loop;
                  Take (From, Cursor);
                  Cursor := From;
               end;
            when ASCII.FF =>
               Put (ASCII.ESC & "[H" & ASCII.ESC & "[2J");
               Drawn_Row := 0;
            when ASCII.DLE =>
               if Looking > 1 then
                  if Looking > Natural (History.Length) then
                     Typing := Text;
                  end if;
                  Looking := Looking - 1;
                  Show_History (Looking);
               end if;
            when ASCII.SO =>
               if Looking <= Natural (History.Length) then
                  Looking := Looking + 1;
                  Show_History (Looking);
               end if;
            when ASCII.ESC =>
               --  Escape alone drops the line; a key's sequence is that key.
               declare
                  Second : Character;
               begin
                  if not Next (30, Second) then
                     Outcome := Escaped;
                     exit;
                  elsif Second in '[' | 'O' then
                     declare
                        Number : Natural := 0;
                        Final  : Character := ASCII.NUL;
                        Part   : Character;
                     begin
                        while Next (30, Part) loop
                           if Part in '0' .. '9' then
                              Number := Number * 10 + (Character'Pos (Part) - Character'Pos ('0'));
                           elsif Part /= ';' then
                              Final := Part;
                              exit;
                           end if;
                        end loop;
                        case Final is
                           when 'A' =>
                              if Looking > 1 then
                                 if Looking > Natural (History.Length) then
                                    Typing := Text;
                                 end if;
                                 Looking := Looking - 1;
                                 Show_History (Looking);
                              end if;
                           when 'B' =>
                              if Looking <= Natural (History.Length) then
                                 Looking := Looking + 1;
                                 Show_History (Looking);
                              end if;
                           when 'C' =>
                              Cursor := On (Cursor);
                           when 'D' =>
                              Cursor := Back (Cursor);
                           when 'H' =>
                              Cursor := 0;
                           when 'F' =>
                              Cursor := Length (Text);
                           when '~' =>
                              if Number in 1 | 7 then
                                 Cursor := 0;
                              elsif Number in 4 | 8 then
                                 Cursor := Length (Text);
                              elsif Number = 3 then
                                 Take (Cursor, On (Cursor));
                              end if;
                           when others =>
                              null;
                        end case;
                     end;
                  elsif Second = 'b' then
                     while Cursor > 0 and then Element (Text, Cursor) = ' ' loop
                        Cursor := Cursor - 1;
                     end loop;
                     while Cursor > 0 and then Element (Text, Cursor) /= ' ' loop
                        Cursor := Cursor - 1;
                     end loop;
                  elsif Second = 'f' then
                     while Cursor < Length (Text) and then Element (Text, Cursor + 1) = ' ' loop
                        Cursor := Cursor + 1;
                     end loop;
                     while Cursor < Length (Text) and then Element (Text, Cursor + 1) /= ' ' loop
                        Cursor := Cursor + 1;
                     end loop;
                  end if;
               end;
            when ASCII.HT =>
               null;
            when others =>
               if Key >= ' ' then
                  Insert (Text, Cursor + 1, [1 => Key]);
                  Cursor := Cursor + 1;
               end if;
         end case;
         --  Bytes still coming -- a paste, the rest of a character -- are
         --  taken before it is drawn again.
         if not Hostkit.Descriptors.Wait_Readable (Input, 0) then
            Redraw;
         end if;
      end loop;
      --  Drawn as it ended, the cursor after it, and the line left.
      Cursor := Length (Text);
      Redraw;
      Put (ASCII.CR & ASCII.LF);
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      Finalize (Guard);
      if Outcome = Entered and then Length (Text) > 0
        and then (History.Is_Empty or else History.Last_Element /= To_String (Text))
      then
         History.Append (To_String (Text));
      end if;
      return To_String (Text);
   end Edited_Line;

   ------------------
   -- Answered_Yes --
   ------------------

   function Answered_Yes (Screen : in out Pres.Console) return Boolean is
   begin
      for Asked in 1 .. 3 loop
         declare
            --  Ctrl-C while it is asked: the question answered no, once
            --  Enter is pressed after it.
            procedure Waiting (On : Boolean) is
            begin
               Model_Runner.Platform.Signals.Set_Waiting_For_Input
                 (On, Note => (if On then ASCII.LF & Pres.Message_Value (Screen, "cli.choose.interrupted")
                               else ""));
            end Waiting;
            --  At a terminal, read raw: Escape and Ctrl-C answer at once.
            Ending : Line_End := Unavailable;
            function Read return String is
               Raw : constant String := Typed_Line (Ending);
            begin
               if Ending /= Unavailable then
                  return Raw;
               end if;
               Waiting (True);
               return Line : constant String := Ada.Text_IO.Get_Line do
                  Waiting (False);
               end return;
            end Read;
            Typed  : constant String := Ada.Strings.Fixed.Trim (Read, Ada.Strings.Both);
            Answer : constant String := Ada.Characters.Handling.To_Lower (Typed);
         begin
            --  Esc, or Ctrl-C: no. An Esc the terminal showed as it is
            --  starts a sequence the next output would end: cancelled.
            if Ending = Escaped then
               Pres.Put_Note (Screen, "cli.choose.escaped");
               return False;
            elsif Ending = Interrupted then
               Pres.Put_Note (Screen, "cli.choose.interrupted_at_once");
               return False;
            elsif Ending = Ended then
               return False;
            elsif Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ESC]) > 0
              or else Model_Runner.Platform.Signals.Interrupt_Noted
            then
               if Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ESC]) > 0 then
                  Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CAN);
                  Pres.Put_Note (Screen, "cli.choose.escaped");
               end if;
               return False;
            end if;
            --  Echoed as typed: a command's identifiers keep their case.
            if Answer'Length > 1 and then Answer (Answer'First) = '/' then
               Pres.Put_Note (Screen, "cli.choose.command_typed",
                              [Loc.Named ("value", Typed), Loc.Named ("name", "a yes or no")]);
               return False;
            elsif Answer in "y" | "yes" | "j" | "ja" then
               return True;
            elsif Answer in "" | "n" | "no" | "nej" or else Asked = 3 then
               return False;
            end if;
            Pres.Put_Note (Screen, "cli.choose.yes_or_no", [Loc.Named ("value", Answer)]);
         end;
      end loop;
      return False;
   exception
      when Ada.Text_IO.End_Error =>
         return False;
   end Answered_Yes;

end Model_Runner.CLI.Choosers;
