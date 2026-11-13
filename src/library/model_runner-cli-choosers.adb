with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Directories;
with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Text_IO;
with Ada.Wide_Wide_Characters.Handling;
with Interfaces.C_Streams;

with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Terminal_Control;

with Model_Runner.CLI.Partials;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Text;
with Model_Runner.UTF8;
with Model_Runner.Platform.Signals;
with Model_Runner.Platform.Signals.Waiting;

package body Model_Runner.CLI.Choosers is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Hostkit.Descriptors.Transfer_Outcome;

   package Loc renames Model_Runner.Localization;
   package T renames Model_Runner.Text;
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

   --  Where a control sequence after ESC [ ends: the index of its final
   --  byte (40 to 7E), past its parameter (30 to 3F) and intermediate
   --  (20 to 2F) bytes, or zero when the bytes stop before one comes.
   function CSI_Final (Bytes : String) return Natural is
   begin
      for Index in Bytes'First + 2 .. Bytes'Last loop
         case Bytes (Index) is
            when '@' .. '~' => return Index;
            when ' ' .. '?' => null;
            when others     => return Index - 1;
         end case;
      end loop;
      return 0;
   end CSI_Final;

   --  Whether bytes are the start of a key's sequence and not all of it:
   --  an escape alone, escape and O, or escape, [ and what has come of
   --  its parameters still waiting for the final byte -- what a terminal
   --  behind SSH or tmux, or a read that ended mid-key, hands over in two
   --  pieces.
   function Incomplete (Bytes : String) return Boolean
   is (Bytes'Length > 0 and then Bytes (Bytes'First) = ASCII.ESC
       and then (Bytes'Length = 1
                 or else (Bytes'Length = 2 and then Bytes (Bytes'First + 1) = 'O')
                 or else (Bytes (Bytes'First + 1) = '[' and then CSI_Final (Bytes) = 0)));

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
         --  Ctrl-P and Ctrl-N move as they do in a shell's history.
         when ASCII.DLE           => return (Up, ' ');
         when ASCII.SO            => return (Down, ' ');
         when ASCII.ESC =>
            if Bytes'Length = 1 then
               return (Escape, ' ');
            end if;
            case Bytes (Bytes'First + 1) is
               when '[' =>
                  --  The whole sequence is taken, whatever it is: Delete
                  --  (ESC [ 3 ~), F5 (ESC [ 1 5 ~) or Ctrl-Up (ESC [ 1 ; 5 A)
                  --  left their tails behind, and the tails were typed.
                  declare
                     Final : constant Natural := CSI_Final (Bytes);
                     Last  : constant Natural := (if Final = 0 then Bytes'Last else Final);
                     --  The first parameter, up to a ; -- a modifier after
                     --  it does not change which key it is.
                     Number : Natural := 0;
                  begin
                     Used := Last - Bytes'First + 1;
                     if Final = 0 then
                        return (Nothing, ' ');
                     end if;
                     for Index in Bytes'First + 2 .. Final - 1 loop
                        exit when Bytes (Index) not in '0' .. '9' or else Number > 1_000;
                        Number := Number * 10 + Character'Pos (Bytes (Index)) - Character'Pos ('0');
                     end loop;
                     case Bytes (Final) is
                        when 'A' => return (Up, ' ');
                        when 'B' => return (Down, ' ');
                        when 'H' => return (Home, ' ');
                        when 'F' => return (End_Key, ' ');
                        --  The keys that end in ~: page up and down, and the
                        --  home and end tmux and the Linux console send.
                        when '~' =>
                           case Number is
                              when 5      => return (Page_Up, ' ');
                              when 6      => return (Page_Down, ' ');
                              when 1 | 7  => return (Home, ' ');
                              when 4 | 8  => return (End_Key, ' ');
                              when others => return (Nothing, ' ');
                           end case;
                        when others => return (Nothing, ' ');
                     end case;
                  end;
               when 'O' =>
                  if Bytes'Length < 3 then
                     Used := Bytes'Length;
                     return (Nothing, ' ');
                  end if;
                  Used := 3;
                  case Bytes (Bytes'First + 2) is
                     when 'A' => return (Up, ' ');
                     when 'B' => return (Down, ' ');
                     when 'H' => return (Home, ' ');
                     when 'F' => return (End_Key, ' ');
                     when others => return (Nothing, ' ');
                  end case;
               when others =>
                  --  Alt and a key: neither Escape, which would close the
                  --  list, nor the key, which would start a filter.
                  Used := 2;
                  return (Nothing, ' ');
            end case;
         when ' ' .. '~' =>
            return (Printable, First);
         when others =>
            --  Any other control is not a character a filter can hold; a
            --  byte of a character outside ASCII is, taken whole.
            if First < ' ' then
               return (Nothing, ' ');
            end if;
            return (Printable, First);
      end case;
   end Decode;

   --  Text in lower case a character at a time, not a byte at a time: a
   --  byte of UTF-8 lowered as Latin-1 is another byte, and É matched
   --  nothing an é was typed for. Text that is not UTF-8 is lowered in
   --  its ASCII letters only.
   function Lowered (Text : String) return String is
      package Coding renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   begin
      return Coding.Encode (Ada.Wide_Wide_Characters.Handling.To_Lower (Coding.Decode (Text)));
   exception
      when others =>
         return Result : String := Text do
            for C of Result loop
               if C in 'A' .. 'Z' then
                  C := Ada.Characters.Handling.To_Lower (C);
               end if;
            end loop;
         end return;
   end Lowered;

   --  A filter less its last character, not its last byte: after an é
   --  a byte left a lone lead byte that matched nothing.
   procedure Drop_Last_Character (Filter : in out Unbounded_String) is
      Text : constant String := To_String (Filter);
   begin
      if Text'Length > 0 then
         Filter := To_Unbounded_String
           (Text (Text'First .. Model_Runner.UTF8.Last_Character_First (Text) - 1));
      end if;
   end Drop_Last_Character;

   --  Work out which choices the filter leaves, keeping the cursor on the
   --  choice it was on when that one is still there.
   procedure Refilter (Item : in out Selector) is
      Before : constant Natural :=
        (if Item.Cursor in 1 .. Natural (Item.Visible.Length)
         then Item.Visible (Item.Cursor) else 0);
      Wanted : constant String := Lowered (To_String (Item.Filter));
   begin
      Item.Visible.Clear;
      for Index in 1 .. Natural (Item.Items.Length) loop
         declare
            Said : constant String :=
              Lowered (To_String (Item.Items (Index).Tag) & " "
                       & To_String (Item.Items (Index).Label));
         begin
            --  A choice for any language is one for every language named.
            if Wanted = "" or else Ada.Strings.Fixed.Index (Said, Wanted) > 0
              or else Ada.Strings.Fixed.Index (Said, "any language") > 0
            then
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
                  Drop_Last_Character (Item.Filter);
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
         when Backspace =>
            --  A filter left by Enter is taken up again where it stood.
            if Length (Item.Filter) > 0 then
               Item.Filtering := True;
               Drop_Last_Character (Item.Filter);
               Refilter (Item);
            end if;
         when Printable =>
            if Pressed.Char = '/' then
               Item.Filtering := True;
            --  q quits where no filter stands; with one, it is a letter of it.
            elsif Pressed.Char = 'q' and then Length (Item.Filter) = 0 then
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
         when Nothing =>
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

   --  A line as the list draws it: its controls shown, not obeyed -- a
   --  label or a title can be a task's, which a model wrote -- and cut to
   --  the columns a terminal gives it, a wide character two.
   function Fit (Text : String; Columns : Positive) return String is
      Shown : constant String := T.Escape_Controls (Text);
   begin
      return Shown (Shown'First .. Shown'First + Model_Runner.UTF8.Fitting (Shown, Columns) - 1);
   end Fit;

   --  A text's lines, each broken at a space where it is wider than the
   --  window: what does not fit is shown on the rows below, not cut off.
   --  Widths are in columns, so the rows counted are the rows drawn.
   function Wrapped (Text : String; Columns : Positive) return Framework.Name_Lists.Vector is
      Result : Framework.Name_Lists.Vector;

      procedure Add (Line : String) is
         Fits : constant Natural := Model_Runner.UTF8.Fitting (Line, Columns);
         Cut  : Natural := 0;
      begin
         if Fits >= Line'Length then
            Result.Append (Line);
            return;
         end if;
         for Index in Line'First .. Line'First + Fits loop
            if Line (Index) = ' ' then
               Cut := Index;
            end if;
         end loop;
         if Cut > Line'First then
            Result.Append (Line (Line'First .. Cut - 1));
            Add (Line (Cut + 1 .. Line'Last));
         else
            --  One code point at the least, so a window narrower than a
            --  wide character still ends.
            declare
               Taken : constant Natural :=
                 Natural'Max (Fits, Natural'Max (1, Model_Runner.UTF8.Sequence_Length (Line (Line'First))));
               Last  : constant Natural := Natural'Min (Line'Last, Line'First + Taken - 1);
            begin
               Result.Append (Line (Line'First .. Last));
               if Last < Line'Last then
                  Add (Line (Last + 1 .. Line'Last));
               end if;
            end;
         end if;
      end Add;
   begin
      for Line of Framework.Lines_Of (Text) loop
         Add (T.Escape_Controls (Line));
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
      --  The rows drawn hold the cursor: Press scrolls by the rows the
      --  window has, and a title of several lines, the details, or a
      --  filter that put Top back to the first leave fewer -- the marker
      --  was below the last row drawn, and Enter took what no one saw.
      declare
         Top : Positive := Positive'Max (1, Item.Top);
      begin
         if Item.Cursor > 0 then
            if Item.Cursor < Top then
               Top := Item.Cursor;
            elsif Item.Cursor >= Top + Room then
               Top := Item.Cursor - Room + 1;
            end if;
         end if;
         for Place in Top .. Natural'Min (Natural (Item.Visible.Length), Top + Room - 1) loop
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
      end;
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
      --  Filtering, the keys too: how to take it back, and how to leave.
      if Item.Filtering or else Length (Item.Filter) > 0 then
         for Line of Wrapped (To_String (Words.Keys), Columns) loop
            Result.Append (Line);
         end loop;
      end if;

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

      --  Pasted text marked, to be unmarked however it ends.
      Bracketed : Boolean := False;
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
         if Guard.Bracketed then
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.ESC & "[?2004l");
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
            Guard.Bracketed := False;
         end if;
         Ignored := Term.Control (Output, Term.Show_Cursor);
         Ignored := Term.Restore_Mode (Input, Guard.Saved);
         Model_Runner.Platform.Signals.Release_Terminal_Mode;
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
      Heading : String := "";
      Initial : Positive := 1) return Natural
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
      --  The cursor where the caller puts it: the safe choice, where one is.
      procedure Place_Cursor is
      begin
         if Initial > 1 and then Initial <= Natural (State.Visible.Length) then
            State.Cursor := Initial;
         end if;
      end Place_Cursor;
   begin
      Place_Cursor;
      if not Is_Available (Screen) or else Length (Items) = 0 then
         return 0;
      end if;

      if not Term.Save_Mode (Input, Guard.Saved) then
         return 0;
      end if;
      Guard.Held := True;
      Model_Runner.Platform.Signals.Hold_Terminal_Mode (Guard.Saved);
      if not Term.Set_Raw (Input) then
         return 0;
      end if;
      --  Drawn on a screen of its own where the terminal has one: the one
      --  there was is given back as it was, with nothing it scrolled left
      --  behind. Drawn from where the cursor is, so that a terminal with no
      --  second screen draws in place as before.
      Control (Term.Enter_Alternate_Screen);
      Guard.Alternate := True;
      Model_Runner.Platform.Signals.Note_Alternate_Screen (True);
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
               --  Told to end while the list waits: chosen nothing, and the
               --  guard gives the terminal back -- not the ten seconds the
               --  run is given to stop and then the program ended raw.
               exit when Model_Runner.Platform.Signals.Ending_Asked;
               if Measured and then Term.Size (Output, Now)
                 and then (Now.Rows /= Was.Rows or else Now.Columns /= Was.Columns)
               then
                  Draw;
                  Was := Now;
               end if;
            end loop;
         end;

         if Model_Runner.Platform.Signals.Ending_Asked then
            State.Done := True;
            State.Result := 0;
            exit;
         end if;

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
              and then Hostkit.Descriptors.Wait_Readable (Input, 250);
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

   --  Where the last character of Text begins; see UTF8.
   function Last_Character (Text : Unbounded_String) return Positive
   is (Model_Runner.UTF8.Last_Character_First (To_String (Text)));

   --  After an escape read a byte at a time: whether a key's sequence
   --  follows it -- an arrow, Home, Delete, Alt and a letter -- read here
   --  to its end and dropped, or the escape was Escape alone. A cursor key
   --  pressed to mend a typo gave the question up: Left answered no, and
   --  in a hidden prompt the rest of its sequence was left in the
   --  terminal for the next prompt to take as typed.
   --
   --  @return True when the escape began a key, which means nothing here.
   function Key_Sequence_Skipped return Boolean is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last   : Ada.Streams.Stream_Element_Offset;

      function Next (Byte : out Character) return Boolean is
      begin
         if not Hostkit.Descriptors.Wait_Readable (Input, 30)
           or else Hostkit.Descriptors.Read (Input, Buffer, Last) /= Hostkit.Descriptors.Transfer_Ok
           or else Last < Buffer'First
         then
            return False;
         end if;
         Byte := Character'Val (Buffer (Buffer'First));
         return True;
      end Next;

      Byte : Character;
   begin
      if not Next (Byte) then
         return False;
      end if;
      if Byte = '[' then
         --  Parameters and intermediates, then the final byte.
         for Count in 1 .. 32 loop
            exit when not Next (Byte) or else Byte in '@' .. '~';
         end loop;
      elsif Byte = 'O' then
         --  One byte more names the key; none, and the escape was a key
         --  all the same.
         return Next (Byte) or else True;
      end if;
      return True;
   end Key_Sequence_Skipped;

   --  Take back the last character typed at a line on the screen: as many
   --  cells as it took, two for a wide one.
   procedure Erase_Last (Typed : in out Unbounded_String) is
      From  : constant Positive := Last_Character (Typed);
      Cells : constant Natural :=
        Model_Runner.UTF8.Columns (Slice (Typed, From, Length (Typed)));
   begin
      Delete (Typed, From, Length (Typed));
      for Cell in 1 .. Cells loop
         Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.BS & " " & ASCII.BS);
      end loop;
   end Erase_Last;

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
         Model_Runner.Platform.Signals.Hold_Terminal_Mode (Guard.Saved);
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
               elsif Key = ASCII.ESC and then Key_Sequence_Skipped then
                  null;
               elsif Key in ASCII.ESC | ASCII.ETX then
                  Gave_Up := True;
                  exit;
               elsif Key in ASCII.DEL | ASCII.BS then
                  if Length (Typed) > 0 then
                     Delete (Typed, Last_Character (Typed), Length (Typed));
                     Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.BS & " " & ASCII.BS);
                  end if;
               elsif Key >= ' ' then
                  Append (Typed, Key);
                  --  A star a character, as a backspace takes one back.
                  if Model_Runner.UTF8.Begins_Character (Key) then
                     Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, "*");
                  end if;
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
      Model_Runner.Platform.Signals.Hold_Terminal_Mode (Guard.Saved);
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
               --  A key's sequence -- an arrow -- means nothing here and
               --  is let go; Escape alone gives the question up.
               if not Key_Sequence_Skipped then
                  Outcome := Escaped;
                  exit;
               end if;
            elsif Key = ASCII.ETX then
               Outcome := Interrupted;
               exit;
            elsif Key = ASCII.EOT and then Length (Typed) = 0 then
               Outcome := Ended;
               exit;
            elsif Key in ASCII.DEL | ASCII.BS then
               if Length (Typed) > 0 then
                  Erase_Last (Typed);
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

   --  The lines typed at the prompt, oldest first: this session's, after
   --  those kept in the project from the sessions before.
   History : Model_Runner.Framework.Name_Lists.Vector;

   --  Whether the line read last was added to History: a line the same as
   --  the one before it is not, and forgetting it then would take away an
   --  older one -- a line from another session, perhaps.
   Last_Read_Kept : Boolean := False;

   --  Between the terminal's marks around pasted text (bracketed paste,
   --  asked for by the editor and put back by its guard). Kept across
   --  lines: a pasted block's Enter ends a line, and the next line read is
   --  still the paste's until its closing mark -- its tabs were taken for
   --  completion from the second line on.
   Pasting : Boolean := False;
   History_Read : Boolean := False;

   --  Where the project here keeps them; "" outside a project.
   function History_File return String is
      State : constant String := Ada.Directories.Current_Directory & "/.model_runner";
   begin
      return (if Ada.Directories.Exists (State & "/runtime") then State & "/runtime/prompt-history" else "");
   exception
      when others =>
         return "";
   end History_File;

   procedure Read_History is
      File : Ada.Text_IO.File_Type;
   begin
      History_Read := True;
      if History_File = "" or else not Ada.Directories.Exists (History_File) then
         return;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, History_File, Form => "shared=no");
      while not Ada.Text_IO.End_Of_File (File) loop
         History.Append (Ada.Text_IO.Get_Line (File));
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_History;

   --  The history read, once, before it is first stepped through.
   function History_Ready return Boolean is
   begin
      if not History_Read then
         Read_History;
      end if;
      return True;
   end History_Ready;

   --  The most lines kept for recall: past it, the oldest go.
   Most_Kept : constant := 500;

   --  The history file written again: read as it stands now -- another
   --  session in the project may have added to it since this one read it,
   --  and a rewrite from this session's lines erased those -- the line
   --  being forgotten taken out, the oldest past the bound dropped, and
   --  the result renamed over the file, so a crash part way leaves the
   --  file as it was rather than half of it.
   --
   --  @param Forget A line to take out, its last appearance; or "" with
   --    Forgetting False for none.
   --  @param Forgetting Whether Forget is to be taken out.
   procedure Rewrite_History (Forget : String; Forgetting : Boolean) is
      Path    : constant String := History_File;
      File    : Ada.Text_IO.File_Type;
      Lines   : Model_Runner.Framework.Name_Lists.Vector;
   begin
      if Path = "" then
         return;
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path, Form => "shared=no");
         while not Ada.Text_IO.End_Of_File (File) loop
            Lines.Append (Ada.Text_IO.Get_Line (File));
         end loop;
         Ada.Text_IO.Close (File);
      end if;
      if Forgetting then
         for Index in reverse 1 .. Natural (Lines.Length) loop
            if Lines (Index) = Forget then
               Lines.Delete (Index);
               exit;
            end if;
         end loop;
      end if;
      if Natural (Lines.Length) > Most_Kept then
         Lines.Delete_First (Ada.Containers.Count_Type (Natural (Lines.Length) - Most_Kept));
      end if;
      declare
         Partial : constant String := Model_Runner.CLI.Partials.Beside (Path);
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Partial, Form => "shared=no");
         for One of Lines loop
            Ada.Text_IO.Put_Line (File, One);
         end loop;
         Ada.Text_IO.Close (File);
         if not Hostkit.Fs.Replace_File (Partial, Path) and then Ada.Directories.Exists (Partial) then
            Ada.Directories.Delete_File (Partial);
         end if;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Rewrite_History;

   ----------------------
   -- Forget_Last_Line --
   ----------------------

   procedure Forget_Last_Line is
   begin
      if History.Is_Empty or else not Last_Read_Kept then
         return;
      end if;
      declare
         Forgotten : constant String := History.Last_Element;
      begin
         History.Delete_Last;
         Last_Read_Kept := False;
         Rewrite_History (Forgotten, Forgetting => True);
      end;
   end Forget_Last_Line;

   --  A line kept for the next session, the last 500 kept.
   procedure Keep_In_History (Line : String) is
      File : Ada.Text_IO.File_Type;
      Over : constant Boolean := Natural (History.Length) > Most_Kept;
   begin
      --  Held to its bound whether or not there is a file to keep it in:
      --  trimmed only where there was, a session outside a project kept
      --  every line, and every keystroke searched them all.
      if Over then
         History.Delete_First (Ada.Containers.Count_Type (Natural (History.Length) - Most_Kept));
      end if;
      if History_File = "" then
         return;
      end if;
      --  Added at the end, as any session adds; trimmed, when the file
      --  holds more than it keeps, by a rewrite of what it holds now.
      if Ada.Directories.Exists (History_File) then
         Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, History_File, Form => "shared=no");
      else
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, History_File, Form => "shared=no");
      end if;
      Ada.Text_IO.Put_Line (File, Line);
      Ada.Text_IO.Close (File);
      if Over then
         Rewrite_History ("", Forgetting => False);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Keep_In_History;

   -------------------
   -- Insert_Spoken --
   -------------------

   procedure Insert_Spoken
     (Line   : in out Unbounded_String;
      Cursor : in out Natural;
      Spoken : String;
      Most   : Natural;
      Done   : out Boolean)
   is
      Flat : String := Spoken;
   begin
      Done := False;
      for C of Flat loop
         if C in ASCII.CR | ASCII.LF | ASCII.HT then
            C := ' ';
         end if;
      end loop;
      declare
         Said  : constant String := Ada.Strings.Fixed.Trim (Flat, Ada.Strings.Both);
         Has_Before : constant Boolean := Cursor > 0;
         Has_After  : constant Boolean := Cursor < Length (Line);
         Before : constant Character := (if Has_Before then Element (Line, Cursor) else ' ');
         After  : constant Character := (if Has_After then Element (Line, Cursor + 1) else ' ');
         Lead   : constant String :=
           (if Said = "" then ""
            elsif Has_Before and then Before /= ' ' then " "
            --  A command is typed, not dictated.
            elsif not Has_Before and then Said (Said'First) = '/' then " "
            else "");
         Trail  : constant String :=
           (if Has_After
              and then (Ada.Characters.Handling.Is_Alphanumeric (After) or else Character'Pos (After) >= 128)
            then " " else "");
      begin
         if Said = "" or else not Model_Runner.UTF8.Is_Valid (Said)
           or else Length (Line) + Lead'Length + Said'Length + Trail'Length > Most
         then
            return;
         end if;
         Insert (Line, Cursor + 1, Lead & Said & Trail);
         Cursor := Cursor + Lead'Length + Said'Length;
         Done := True;
      end;
   end Insert_Spoken;

   function Edited_Line
     (Screen   : Model_Runner.Presentation.Console;
      Prompt   : String;
      Outcome  : out Line_End;
      Complete : Completer := null;
      Describe : Describer := null;
      Dictate  : Dictation_Access := null;
      Shortcut : Character := Character'Val (7)) return String
   is
      Guard   : Raw_Guard;
      Text    : Unbounded_String;
      --  The cursor: the bytes before it.
      Cursor  : Natural := 0;
      --  The row the cursor was drawn on, counted from the prompt's; the
      --  width it was drawn at and what came before the cursor, so that
      --  after the window is resized -- the terminal reflowing the rows --
      --  the way back to the prompt's row is counted at the new width.
      Drawn_Row    : Natural := 0;
      Drawn_Width  : Positive := 1;
      Drawn_Before : Unbounded_String;
      --  Where Up and Down are in the history; past its end, the line
      --  being typed, kept while older ones are looked at.
      Ready   : constant Boolean := History_Ready;
      pragma Unreferenced (Ready);
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

      --  Columns, not bytes nor characters: a wide character takes two, a
      --  combining mark none, a colour sequence in the prompt none.
      function Width (Item : String) return Natural renames Model_Runner.UTF8.Columns;

      function Columns return Positive is
         Size : Term.Window_Size;
      begin
         if Term.Size (Hostkit.Descriptors.Standard_Error, Size) and then Size.Columns > 0 then
            return Size.Columns;
         end if;
         return 80;
      end Columns;

      --  A line cut to the window, at a code point and by columns.
      function Cut_To_Window (Said : String) return String is
        (if Width (Said) > Columns - 1
         then Said (Said'First .. Said'First - 1
                    + Model_Runner.UTF8.Fitting (Said, Integer'Max (Columns - 5, 0))) & "..."
         else Said);

      --  A command's line of help, cut to the window: "" where it has none.
      function Described (Command : String) return String is
         Key  : constant String := "cli.interactive.help." & Command (Command'First + 1 .. Command'Last);
         Said : constant String := Pres.Message_Value (Screen, Key);
      begin
         if Said = "" or else Ada.Strings.Fixed.Index (Said, "cli.interactive.help.") > 0 then
            return "";
         end if;
         return Cut_To_Window (Said);
      end Described;

      --  What the word at the end would be completed to, shown dimmed after
      --  it: Right or End takes it.
      Ghost : Unbounded_String;

      --  Whether the word a line typed before goes on with is one Tab
      --  would offer now: a link taken off since, a task done, is not
      --  suggested again. Where Tab offers nothing, any word is.
      function Still_Offered (Line, Rest : String) return Boolean is
         --  An identifier as typed or as listed, alike: req-4 is REQ-004.
         function Normal (Word : String) return String is
            Upper : constant String := Ada.Characters.Handling.To_Upper (Word);
            Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-", Ada.Strings.Backward);
            First : Natural := Dash + 1;
         begin
            if Dash = 0 or else Dash = Upper'Last
              or else not (for all C of Upper (Dash + 1 .. Upper'Last) => C in '0' .. '9')
            then
               return Upper;
            end if;
            while First < Upper'Last and then Upper (First) = '0' loop
               First := First + 1;
            end loop;
            return Upper (Upper'First .. Dash) & Upper (First .. Upper'Last);
         end Normal;

         --  The word that goes on from Before is one Tab offers there.
         function Offered_At (Before, Word : String) return Boolean is
            Choices : constant Model_Runner.Framework.Name_Lists.Vector := Complete (Before);
         begin
            return Choices.Is_Empty or else Word = ""
              or else (for some One of Choices => Normal (One) = Normal (Word))
              --  A number for an ID, a NAME= with its value: as typed then.
              or else (for all C of Word => C in '0' .. '9')
              or else (for some One of Choices =>
                         One'Length > 0 and then One (One'Last) = '=' and then Word'Length > One'Length
                         and then Word (Word'First .. Word'First + One'Length - 1) = One);
         end Offered_At;

         Partial : constant Natural := Ada.Strings.Fixed.Index (Line, " ", Ada.Strings.Backward);
         Typed   : constant String := (if Partial = 0 then Line else Line (Partial + 1 .. Line'Last));
         Whole   : constant String := Line & Rest;
         Start   : Natural := (if Partial = 0 then Line'First else Partial + 1);
      begin
         --  Each word from the one begun on: an identifier among them that
         --  is no longer offered -- a task cancelled since -- and the line
         --  is not suggested again.
         pragma Unreferenced (Typed);
         for Index in Start .. Whole'Last + 1 loop
            if Index > Whole'Last or else Whole (Index) = ' ' then
               if Index > Start + 1
                 and then Whole (Start) /= '/'
                 --  Only an identifier's: free words -- a title, a note --
                 --  are what they were.
                 and then Ada.Strings.Fixed.Index (Whole (Start .. Index - 1), "-") > 0
                 and then Whole (Index - 1) in '0' .. '9'
                 and then not Offered_At (Whole (Whole'First .. Start - 1) & Whole (Start .. Start),
                                          Whole (Start .. Index - 1))
               then
                  return False;
               end if;
               Start := Index + 1;
            end if;
         end loop;
         return True;
      exception
         when others =>
            return True;
      end Still_Offered;

      procedure Find_Ghost is
         Line  : constant String := To_String (Text);
      begin
         Ghost := Null_Unbounded_String;
         --  A line typed before that this one begins, the newest: the rest
         --  of it, as it was typed.
         if Complete /= null and then Line /= "" and then Cursor = Line'Length and then Line (Line'First) = '/' then
            for Index in reverse 1 .. Natural (History.Length) loop
               declare
                  Earlier : constant String := History (Index);
               begin
                  if Earlier'Length > Line'Length
                    and then Earlier (Earlier'First .. Earlier'First + Line'Length - 1) = Line
                    and then Still_Offered (Line, Earlier (Earlier'First + Line'Length .. Earlier'Last))
                  then
                     Ghost := To_Unbounded_String (Earlier (Earlier'First + Line'Length .. Earlier'Last));
                     return;
                  end if;
               end;
            end loop;
         end if;
         --  Only at the end of the line, a word begun, and only for the
         --  command and its action: the words a person types most.
         if Complete = null or else Line = "" or else Cursor /= Line'Length or else Line (Line'Last) = ' '
           or else Line (Line'First) /= '/' or else Ada.Strings.Fixed.Count (Line, " ") > 1
         then
            return;
         end if;
         declare
            Start   : constant Natural := Ada.Strings.Fixed.Index (Line, " ", Ada.Strings.Backward);
            Word    : constant String := Line ((if Start = 0 then Line'First else Start + 1) .. Line'Last);
            Choices : constant Model_Runner.Framework.Name_Lists.Vector := Complete (Line);
            Shared  : Unbounded_String;
         begin
            if Choices.Is_Empty
              or else not (for all One of Choices =>
                             One'Length >= Word'Length and then One (One'First .. One'First + Word'Length - 1) = Word)
            then
               return;
            end if;
            Shared := To_Unbounded_String (Choices.First_Element);
            for One of Choices loop
               declare
                  Same : Natural := 0;
               begin
                  while Same < Length (Shared) and then Same < One'Length
                    and then Element (Shared, Same + 1) = One (One'First + Same)
                  loop
                     Same := Same + 1;
                  end loop;
                  Shared := Head (Shared, Same);
               end;
            end loop;
            if Length (Shared) > Word'Length then
               Ghost := To_Unbounded_String (Slice (Shared, Word'Length + 1, Length (Shared)));
            end if;
         end;
      exception
         when others =>
            Ghost := Null_Unbounded_String;
      end Find_Ghost;

      --  What speech is doing, or what it said, shown dimmed after the
      --  line until the next key.
      Status : Unbounded_String;

      function Status_Shown return String is
        (if Status = Null_Unbounded_String then "" else "  " & To_String (Status));

      --  The prompt and the line drawn again from the prompt's row, the
      --  cursor put where it is in the line.
      procedure Redraw is
         W        : constant Positive := Columns;
         Line     : constant String := To_String (Text);
         --  Measured from the prompt on, as one text: a tab in the line
         --  goes to a stop counted from the row's start.
         --  Counted as the terminal wraps it, a wide character that met
         --  the edge on the next row.
         Shown_Total : constant Natural :=
           Model_Runner.UTF8.Wrapped_Columns (Prompt & Line & To_String (Ghost) & Status_Shown, W);
         At_Cursor : constant Natural :=
           Model_Runner.UTF8.Wrapped_Columns (Prompt & Line (Line'First .. Line'First + Cursor - 1), W);
         Wrapped  : Boolean := False;
         End_Row  : Natural;
      begin
         if Drawn_Row > 0 and then W /= Drawn_Width then
            Drawn_Row := Model_Runner.UTF8.Wrapped_Columns (To_String (Drawn_Before), W) / W;
         end if;
         if Drawn_Row > 0 then
            Put (ASCII.ESC & "[" & Image (Drawn_Row) & "A");
         end if;
         Put (ASCII.CR & ASCII.ESC & "[J" & Prompt & Pres.Coloured_Commands (Screen, Line));
         --  What Right would take, dimmed after it.
         if Ghost /= Null_Unbounded_String then
            Put (ASCII.ESC & "[2m" & To_String (Ghost) & ASCII.ESC & "[0m");
         end if;
         if Status /= Null_Unbounded_String then
            Put (ASCII.ESC & "[2m" & Status_Shown & ASCII.ESC & "[0m");
         end if;
         --  Ended exactly at the edge with the cursor there: on to the next
         --  row, as the terminal would only once another character came.
         if Shown_Total > 0 and then Shown_Total mod W = 0 and then At_Cursor = Shown_Total then
            Put (ASCII.LF & ASCII.CR);
            Wrapped := True;
         end if;
         End_Row := (if Shown_Total > 0 and then Shown_Total mod W = 0 and then not Wrapped
                     then Shown_Total / W - 1 else Shown_Total / W);
         if End_Row > At_Cursor / W then
            Put (ASCII.ESC & "[" & Image (End_Row - At_Cursor / W) & "A");
         end if;
         Put ([1 => ASCII.CR]);
         if At_Cursor mod W > 0 then
            Put (ASCII.ESC & "[" & Image (At_Cursor mod W) & "C");
         end if;
         Drawn_Row := At_Cursor / W;
         Drawn_Width := W;
         Drawn_Before := To_Unbounded_String (Prompt & Line (Line'First .. Line'First + Cursor - 1));
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

      --  Keys pressed while speech was recorded or heard, to be acted on
      --  as though typed now.
      Held_Keys : Unbounded_String;

      --  The line before the last transcript went in, and the line it
      --  made: Ctrl-_ puts the first back while the line is still the
      --  second.
      Before_Spoken, After_Spoken : Unbounded_String;
      Cursor_Before_Spoken        : Natural := 0;
      Undoable                    : Boolean := False;

      --  Read one byte from the terminal, where one comes within a wait in
      --  milliseconds.
      function Read_Terminal (Wait : Integer; Into : out Character) return Boolean is
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
      end Read_Terminal;

      --  Read one byte, the held keys first, where one comes within a wait
      --  in milliseconds.
      function Next (Wait : Integer := -1; Into : out Character) return Boolean is
      begin
         if Held_Keys /= Null_Unbounded_String then
            Into := Element (Held_Keys, 1);
            Delete (Held_Keys, 1, 1);
            return True;
         end if;
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

      --  Whether the key before was a Tab that completed nothing more:
      --  a second lists what the word may be.
      Tabbed : Boolean := False;

      --  The word at the cursor completed: to the one word it can be, with
      --  a space after unless it goes on; to what several share; or, asked
      --  again, those listed under the line and the line drawn again.
      procedure Complete_Word is
         Line     : constant String := To_String (Text);
         Before   : constant String := Line (Line'First .. Line'First + Cursor - 1);

         --  The space the word being completed follows: the last one not
         --  inside quotes, so "my dir/x is one word as the commands read it.
         function Word_Start return Natural is
            Open  : Boolean := False;
            Space : Natural := 0;
         begin
            for Index in Before'Range loop
               if Before (Index) = '"' and then (Index = Before'First or else Before (Index - 1) /= '\') then
                  Open := not Open;
               elsif Before (Index) = ' ' and then not Open then
                  Space := Index;
               end if;
            end loop;
            return Space;
         end Word_Start;

         Start    : constant Natural := Word_Start;
         Word     : constant String := Before ((if Start = 0 then Before'First else Start + 1) .. Before'Last);
         Choices  : constant Model_Runner.Framework.Name_Lists.Vector := Complete (Before);
         Shared   : Unbounded_String;
      begin
         if Choices.Is_Empty then
            Put ([1 => ASCII.BEL]);
            return;
         end if;
         --  What every choice begins with.
         Shared := To_Unbounded_String (Choices.First_Element);
         for One of Choices loop
            declare
               Same : Natural := 0;
            begin
               while Same < Length (Shared) and then Same < One'Length
                 and then Element (Shared, Same + 1) = One (One'First + Same)
               loop
                  Same := Same + 1;
               end loop;
               Shared := Head (Shared, Same);
            end;
         end loop;
         --  Shared to a whole character: notes-ä and notes-ö share the
         --  first byte of their last letters, and a lone lead byte is no
         --  text to insert.
         Shared := Head (Shared, Model_Runner.UTF8.Safe_Prefix_Length (To_String (Shared)));
         if Natural (Choices.Length) = 1 then
            declare
               Whole : constant String := Choices.First_Element;
               After : constant String :=
                 (if Whole (Whole'Last) in '/' | '=' then "" else " ");
               Begun : constant Boolean :=
                 Whole'Length >= Word'Length and then Whole (Whole'First .. Whole'First + Word'Length - 1) = Word;
            begin
               if Begun then
                  Insert (Text, Cursor + 1, Whole (Whole'First + Word'Length .. Whole'Last) & After);
               else
                  --  Matched otherwise -- its case, a part of it: the word
                  --  typed becomes it.
                  Delete (Text, Cursor - Word'Length + 1, Cursor);
                  Insert (Text, Cursor - Word'Length + 1, Whole & After);
               end if;
               Cursor := Cursor + Whole'Length - Word'Length + After'Length;
            end;
            Tabbed := False;
         elsif Length (Shared) > Word'Length
           and then Slice (Shared, 1, Word'Length) = Word
         then
            Insert (Text, Cursor + 1, Slice (Shared, Word'Length + 1, Length (Shared)));
            Cursor := Cursor + Length (Shared) - Word'Length;
            --  The next Tab lists what is left, as a shell's does.
            Tabbed := True;
         --  What they share, begun otherwise -- a short name, map.permission.
         --  -- the word typed becomes it.
         elsif Length (Shared) > Word'Length then
            Delete (Text, Cursor - Word'Length + 1, Cursor);
            Insert (Text, Cursor - Word'Length + 1, To_String (Shared));
            Cursor := Cursor + Length (Shared) - Word'Length;
            Tabbed := True;
         elsif not Tabbed then
            Put ([1 => ASCII.BEL]);
            Tabbed := True;
         else
            --  Listed, a few to a row, under the line as it ends.
            declare
               Saved  : constant Natural := Cursor;
               Widest : Natural := 0;
               Across : Positive;
               Column : Natural := 0;
               Shown  : Natural := 0;
            begin
               for One of Choices loop
                  Widest := Natural'Max (Widest, Model_Runner.UTF8.Columns (T.Escape_Controls (One)));
               end loop;
               Across := Positive'Max (1, Columns / (Widest + 2));
               Cursor := Length (Text);
               Ghost := Null_Unbounded_String;
               Redraw;
               Put (ASCII.CR & ASCII.LF);
               --  Commands each with what it does, a line each.
               if (for all One of Choices => One'Length > 1 and then One (One'First) = '/')
                 and then (for all One of Choices => Described (One) /= "")
               then
                  for One of Choices loop
                     exit when Shown = 200;
                     Put (Pres.Coloured_Commands (Screen, Described (One)) & ASCII.CR & ASCII.LF);
                     Shown := Shown + 1;
                  end loop;
               --  Identifiers each with what it is, a line each.
               elsif Describe /= null and then Natural (Choices.Length) <= 40
                 and then (for some One of Choices => Describe (One) /= "")
               then
                  --  Each identifier a line, with what it is; the words beside
                  --  them -- all, model= -- on one line after.
                  declare
                     Words_Beside : Unbounded_String;
                  begin
                     for One of Choices loop
                        declare
                           Said : constant String := Describe (One);
                        begin
                           if Said = "" then
                              Append (Words_Beside, (if Words_Beside = Null_Unbounded_String then "" else "  ")
                                                    & T.Escape_Controls (One));
                           else
                              Put (Cut_To_Window (T.Escape_Controls (Said)) & ASCII.CR & ASCII.LF);
                           end if;
                        end;
                     end loop;
                     if Words_Beside /= Null_Unbounded_String then
                        Put (To_String (Words_Beside) & ASCII.CR & ASCII.LF);
                     end if;
                  end;
               else
                  for Whole of Choices loop
                     exit when Shown = 200;
                     declare
                        --  After NAME= or a directory, what differs only.
                        Cut : constant Natural :=
                          Natural'Max (Ada.Strings.Fixed.Index (Word, "=", Ada.Strings.Backward),
                                       Ada.Strings.Fixed.Index (Word, "/", Ada.Strings.Backward));
                        One : constant String :=
                          (if Cut > Word'First and then Whole'Length > Cut - Word'First + 1
                             and then Whole (Whole'First .. Whole'First + Cut - Word'First) = Word (Word'First .. Cut)
                           then Whole (Whole'First + Cut - Word'First + 1 .. Whole'Last) else Whole);
                        --  A file's name is shown, not obeyed.
                        Shown : constant String := T.Escape_Controls (One);
                     begin
                        Put (Shown & [1 .. Natural'Max (2, Widest + 2 - Model_Runner.UTF8.Columns (Shown)) => ' ']);
                     end;
                     Column := Column + 1;
                     Shown := Shown + 1;
                     if Column = Across then
                        Put (ASCII.CR & ASCII.LF);
                        Column := 0;
                     end if;
                  end loop;
               end if;
               if Column > 0 then
                  Put (ASCII.CR & ASCII.LF);
               end if;
               Drawn_Row := 0;
               Cursor := Saved;
               Tabbed := False;
            end;
         end if;
      end Complete_Word;

      --  Speech into the line: recorded until the shortcut comes again,
      --  heard, and put in at the cursor. Escape or Ctrl-C drop it; any
      --  other key is held, to be acted on once the transcript is in.
      procedure Dictation_Round is
         Problem : Model_Runner.Errors.Error_Info;
         Heard   : Unbounded_String;
         Limit   : Boolean;
         Byte    : Character;

         --  The shortcut as a person names it: Ctrl-G.
         Key_Name : constant String :=
           "Ctrl-" & Character'Val (Character'Pos (Shortcut) + Character'Pos ('A') - 1);

         function Recording_Line return String is
           (Pres.Next_Step_Value
              (Screen, "cli.speech.recording",
               [Model_Runner.Localization.Named
                  ("count", Ada.Strings.Fixed.Trim (Natural'Image (Dictate.Seconds), Ada.Strings.Left)),
                Model_Runner.Localization.Named ("key", Key_Name)]));

         --  A key read while speech works: True where it gives speech up --
         --  Ctrl-C, or Escape on its own -- else kept, with the rest of an
         --  escape sequence. The shortcut is dropped while it is heard.
         function Gives_Up (Key : Character; Hearing : Boolean) return Boolean is
            Second : Character;
         begin
            if Key = ASCII.ETX then
               return True;
            elsif Key = ASCII.ESC then
               if not Read_Terminal (30, Second) then
                  return True;
               end if;
               Append (Held_Keys, [ASCII.ESC, Second]);
               while Read_Terminal (0, Second) loop
                  Append (Held_Keys, Second);
               end loop;
            elsif not (Hearing and then Key = Shortcut) then
               Append (Held_Keys, Key);
            end if;
            return False;
         end Gives_Up;
      begin
         Dictate.Begin_Dictation (Problem);
         if Model_Runner.Errors.Is_Error (Problem) then
            Status := To_Unbounded_String (Pres.Described (Screen, Problem));
            return;
         end if;
         loop
            Status := To_Unbounded_String (Recording_Line);
            Redraw;
            if Dictate.Ended_Itself then
               Dictate.End_Dictation;
               exit;
            end if;
            if Read_Terminal (200, Byte) then
               if Byte = Shortcut then
                  Dictate.End_Dictation;
                  exit;
               elsif Gives_Up (Byte, Hearing => False) then
                  Dictate.Abandon;
                  Status := Null_Unbounded_String;
                  return;
               end if;
            end if;
         end loop;
         Status := To_Unbounded_String (Pres.Message_Value (Screen, "cli.speech.hearing"));
         loop
            Redraw;
            exit when Dictate.Is_Done;
            if Read_Terminal (100, Byte) and then Gives_Up (Byte, Hearing => True) then
               Dictate.Abandon;
            end if;
         end loop;
         Dictate.Take (Heard, Problem, Limit);
         Status := Null_Unbounded_String;
         if Model_Runner.Errors."=" (Problem.Code, Model_Runner.Errors.Generation_Cancelled) then
            return;
         elsif Model_Runner.Errors.Is_Error (Problem) then
            Status := To_Unbounded_String (Pres.Described (Screen, Problem));
         elsif Ada.Strings.Fixed.Trim (To_String (Heard), Ada.Strings.Both) = "" then
            Status := To_Unbounded_String (Pres.Message_Value (Screen, "cli.speech.nothing"));
         else
            declare
               Done : Boolean;
               Was  : constant Unbounded_String := Text;
               At_Cursor : constant Natural := Cursor;
            begin
               Insert_Spoken (Text, Cursor, To_String (Heard), Most => 1_048_576, Done => Done);
               if Done then
                  Before_Spoken := Was;
                  Cursor_Before_Spoken := At_Cursor;
                  After_Spoken := Text;
                  Undoable := True;
               end if;
               if not Done then
                  Status := To_Unbounded_String (Pres.Message_Value (Screen, "cli.speech.not_inserted"));
               elsif Limit then
                  Status := To_Unbounded_String (Pres.Message_Value (Screen, "cli.speech.limit"));
               end if;
            end;
         end if;
      end Dictation_Round;

      Key : Character;

   begin
      Outcome := Unavailable;
      Last_Read_Kept := False;
      if not Is_Available (Screen) or else not Term.Save_Mode (Input, Guard.Saved) then
         return "";
      end if;
      Guard.Held := True;
      Model_Runner.Platform.Signals.Hold_Terminal_Mode (Guard.Saved);
      if not Term.Set_Raw (Input) then
         return "";
      end if;
      Put (ASCII.ESC & "[?2004h");
      Guard.Bracketed := True;
      Redraw;
      loop
         if not Next (Into => Key) then
            Outcome := Ended;
            exit;
         end if;
         Status := Null_Unbounded_String;
         if Dictate /= null and then Key = Shortcut and then not Pasting then
            Dictation_Round;
         elsif Key = Character'Val (16#1F#) then
            --  Ctrl-_: the last transcript taken out again, where nothing
            --  has changed the line since it went in.
            if Undoable and then Text = After_Spoken then
               Text := Before_Spoken;
               Cursor := Cursor_Before_Spoken;
            end if;
            Undoable := False;
         else
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
                  if Cursor = Length (Text) and then Ghost /= Null_Unbounded_String then
                     Append (Text, Ghost);
                     Cursor := Length (Text);
                  else
                     Cursor := On (Cursor);
                  end if;
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
                                 --  Held, not grown past: a pasted run of digits
                                 --  is no key, and overflowed out of the editor.
                                 if Number <= 9_999 then
                                    Number := Number * 10 + (Character'Pos (Part) - Character'Pos ('0'));
                                 end if;
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
                                 --  At the end, with a suggestion: taken -- with
                                 --  Ctrl or Alt, only its next word.
                                 if Number in 13 | 15 and then Cursor = Length (Text)
                                   and then Ghost /= Null_Unbounded_String
                                 then
                                    declare
                                       Rest : constant String := To_String (Ghost);
                                       Upto : Natural := Rest'First;
                                    begin
                                       while Upto <= Rest'Last and then Rest (Upto) = ' ' loop
                                          Upto := Upto + 1;
                                       end loop;
                                       while Upto <= Rest'Last and then Rest (Upto) /= ' ' loop
                                          Upto := Upto + 1;
                                       end loop;
                                       Append (Text, Rest (Rest'First .. Upto - 1));
                                       Cursor := Length (Text);
                                    end;
                                 elsif Cursor = Length (Text) and then Ghost /= Null_Unbounded_String then
                                    Append (Text, Ghost);
                                    Cursor := Length (Text);
                                 else
                                    Cursor := On (Cursor);
                                 end if;
                              when 'D' =>
                                 Cursor := Back (Cursor);
                              when 'H' =>
                                 Cursor := 0;
                              when 'F' =>
                                 if Cursor = Length (Text) and then Ghost /= Null_Unbounded_String then
                                    Append (Text, Ghost);
                                 end if;
                                 Cursor := Length (Text);
                              when '~' =>
                                 if Number in 1 | 7 then
                                    Cursor := 0;
                                 elsif Number in 4 | 8 then
                                    Cursor := Length (Text);
                                 elsif Number = 3 then
                                    Take (Cursor, On (Cursor));
                                 elsif Number = 200 then
                                    Pasting := True;
                                 elsif Number = 201 then
                                    Pasting := False;
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
                  --  A tab in pasted text is the text's, not a key asking for
                  --  completion -- a pasted block of code completed itself.
                  if Pasting then
                     Insert (Text, Cursor + 1, [1 => Key]);
                     Cursor := Cursor + 1;
                  elsif Complete /= null then
                     Complete_Word;
                  end if;
               when others =>
                  if Key >= ' ' then
                     Insert (Text, Cursor + 1, [1 => Key]);
                     Cursor := Cursor + 1;
                  end if;
            end case;
         end if;
         if Key /= ASCII.HT then
            Tabbed := False;
         end if;
         --  Bytes still coming -- a paste, the rest of a character, keys
         --  held while speech worked -- are taken before it is drawn again.
         if Held_Keys = Null_Unbounded_String and then not Hostkit.Descriptors.Wait_Readable (Input, 0) then
            Find_Ghost;
            Redraw;
         end if;
      end loop;
      --  Drawn as it ended, the cursor after it, and the line left: no
      --  suggestion on it.
      Cursor := Length (Text);
      Ghost := Null_Unbounded_String;
      Redraw;
      Put (ASCII.CR & ASCII.LF);
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      Finalize (Guard);
      Last_Read_Kept := False;
      --  A line not entered -- dropped, interrupted, ended -- ends any paste
      --  too: a closing mark that never came does not hold every later tab.
      if Outcome /= Entered then
         Pasting := False;
      end if;
      --  A line of more than 64 KiB -- a paste of a file -- is sent and not
      --  remembered: recall is for what was typed.
      if Outcome = Entered and then Length (Text) > 0
        and then Length (Text) <= 64 * 1024
        and then (History.Is_Empty or else History.Last_Element /= To_String (Text))
      then
         History.Append (To_String (Text));
         Keep_In_History (To_String (Text));
         Last_Read_Kept := True;
      end if;
      return To_String (Text);
   exception
      --  Whatever a key did to the editor, the session is not ended for it:
      --  the line is dropped, as Escape drops it, the guard puts the
      --  terminal back, and the prompt comes again.
      when others =>
         Outcome := Escaped;
         Pasting := False;
         return "";
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
            --  Ended however this is left: a line that never came -- the
            --  input closed -- raised past Waiting (False).
            Held : Model_Runner.Platform.Signals.Waiting.Guard;
            procedure Waiting (On : Boolean) is
            begin
               if On then
                  Model_Runner.Platform.Signals.Waiting.Begin_Wait
                    (Held, Note => ASCII.LF & Pres.Message_Value (Screen, "cli.choose.interrupted"));
               else
                  Model_Runner.Platform.Signals.Waiting.Stop_Wait (Held);
               end if;
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
            --  Asked again where the answer goes, not on a bare line.
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, "(yes/no) ");
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         end;
      end loop;
      return False;
   exception
      when Ada.Text_IO.End_Error =>
         return False;
   end Answered_Yes;

end Model_Runner.CLI.Choosers;
