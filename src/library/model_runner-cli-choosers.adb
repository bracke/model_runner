with Ada.Characters.Handling;
with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Text_IO;

with Hostkit.Descriptors;
with Hostkit.Terminal_Control;

with Model_Runner.Localization;
with Model_Runner.Platform;

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
                  when '5' | '6' =>
                     if Bytes'Length >= 4 and then Bytes (Bytes'First + 3) = '~'
                     then
                        Used := 4;
                        return
                          ((if Bytes (Bytes'First + 2) = '5' then Page_Up
                            else Page_Down), ' ');
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
            end if;
         when Return_Key =>
            if Item.Cursor > 0 then
               if Item.Items (Item.Visible (Item.Cursor)).Selectable then
                  Item.Result := Item.Visible (Item.Cursor);
                  Item.Done := True;
               else
                  --  Why it cannot be taken, rather than taking it.
                  Item.Details := True;
               end if;
            end if;
         when Escape | Interrupt =>
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
         Details := Framework.Lines_Of
           (To_String (Item.Items (Item.Visible (Item.Cursor)).Details));
      end if;

      --  The title, the list, a blank, the details, the keys.
      Room := Rows - 3 - Integer (Details.Length)
        - (if Details.Is_Empty then 0 else 1);
      Room := Integer'Max (1, Room);

      Result.Append (Fit (To_String (Words.Title), Columns));
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
      Result.Append
        (Fit ((if Item.Filtering or else Length (Item.Filter) > 0
               then To_String (Words.Filter) & " " & To_String (Item.Filter)
               else To_String (Words.Keys)),
              Columns));

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

   --  The terminal's own mode, put back however the selector ends.
   type Raw_Guard is new Ada.Finalization.Limited_Controlled with record
      Saved : Term.Mode;
      Held  : Boolean := False;
   end record;

   overriding procedure Finalize (Guard : in out Raw_Guard);

   overriding procedure Finalize (Guard : in out Raw_Guard) is
      Ignored : Boolean;
   begin
      if Guard.Held then
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
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
     (Screen : Model_Runner.Presentation.Console;
      Title  : String;
      Items  : Choice_List) return Natural
   is
      Guard : Raw_Guard;
      State : Selector := Start (Items);
      Drawn : Natural := 0;
      Words : constant Wording :=
        (Title   => To_Unbounded_String (Pres.Message_Value (Screen, Title)),
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
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Line & ASCII.CR & ASCII.LF);
            end loop;

            --  A shorter frame than the last leaves lines to wipe.
            for Extra in Natural (Lines.Length) + 1 .. Drawn loop
               Control (Term.Erase_Line);
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR & ASCII.LF);
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
      if not Is_Available or else Length (Items) = 0 then
         return 0;
      end if;

      if not Term.Save_Mode (Input, Guard.Saved) then
         return 0;
      end if;
      Guard.Held := True;
      if not Term.Set_Raw (Input) then
         return 0;
      end if;
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
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR & ASCII.LF);
         end loop;
         Control (Term.Move_Up, Drawn);
      end if;
      Finalize (Guard);
      return Chosen (State);
   end Choose;

   --  A line typed at the terminal, or nothing at the end of input.
   function Line return String is
   begin
      return Ada.Text_IO.Get_Line;
   exception
      when Ada.Text_IO.End_Error =>
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
      Secret  : Boolean := False)
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
         Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CR & ASCII.LF);
         Finalize (Guard);
         return (if Gave_Up then "" else To_String (Typed));
      end Hidden_Line;
   begin
      Answer := Null_Unbounded_String;
      Given := False;
      if not Is_Available then
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

      Pres.Put_Note
        (Screen, "cli.choose.field",
         [Loc.Named ("name", Label), Loc.Named ("detail", Detail),
          Loc.Named ("value", (if Secret then "" else Default))]);

      if Length (Options) > 0 then
         declare
            Picked : constant Natural :=
              Choose (Screen, "cli.choose.one_of", Options);
         begin
            if Picked > 0 then
               Answer := Options.Items (Picked).Label;
               Given := True;
            end if;
         end;
         return;
      end if;

      if Secret then
         declare
            Gave_Up : Boolean;
            Typed   : constant String := Hidden_Line (Gave_Up);
         begin
            if Gave_Up then
               return;
            elsif Typed /= "" then
               Answer := To_Unbounded_String (Typed);
               Given := True;
            elsif Default /= "" then
               Answer := To_Unbounded_String (Default);
               Given := True;
            end if;
         end;
         return;
      end if;

      declare
         Typed : constant String :=
           Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
      begin
         if Typed /= "" then
            Answer := To_Unbounded_String (Typed);
            Given := True;
         elsif Default /= "" then
            Answer := To_Unbounded_String (Default);
            Given := True;
         end if;
      end;
   end Ask;

end Model_Runner.CLI.Choosers;
