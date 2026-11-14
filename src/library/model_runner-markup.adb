with Ada.Strings.Unbounded;

with Model_Runner.UTF8;

package body Model_Runner.Markup is

   use Ada.Strings.Unbounded;

   --  The marks: controls Localization escapes in any catalog text, so only
   --  Marked puts them in.
   Bold_On    : constant Character := Character'Val (16#11#);
   Bold_Off   : constant Character := Character'Val (16#12#);
   Italic_On  : constant Character := Character'Val (16#13#);
   Italic_Off : constant Character := Character'Val (16#14#);
   Code_On    : constant Character := Character'Val (16#15#);
   Code_Off   : constant Character := Character'Val (16#16#);
   Item_Mark  : constant Character := Character'Val (16#17#);

   subtype Mark is Character range Bold_On .. Item_Mark;

   --  A character of the template, and whether an escape made it literal.
   type Unit is record
      Char    : Character;
      Literal : Boolean;
   end record;

   type Unit_Array is array (Positive range <>) of Unit;

   ------------
   -- Marked --
   ------------

   function Marked (Template : String) return String is
      Units : Unit_Array (1 .. Template'Length);
      Count : Natural := 0;
      Index : Natural := Template'First;
      Result : Unbounded_String;

      function Is_Marker (At_Unit : Positive; C : Character) return Boolean
      is (Units (At_Unit).Char = C and then not Units (At_Unit).Literal);

      function Is_Space (At_Unit : Positive) return Boolean
      is (Units (At_Unit).Char = ' ');

      --  The units From .. Upto, their markup read, appended.
      procedure Inline (From, Upto : Natural) is
         I : Natural := From;
      begin
         while I <= Upto loop
            --  Code: to the next backquote, nothing inside it markup.
            if Is_Marker (I, '`') then
               declare
                  Close : Natural := 0;
               begin
                  for K in I + 1 .. Upto loop
                     if Is_Marker (K, '`') then
                        Close := K;
                        exit;
                     end if;
                  end loop;
                  if Close > I + 1 then
                     Append (Result, Code_On);
                     for K in I + 1 .. Close - 1 loop
                        Append (Result, Units (K).Char);
                     end loop;
                     Append (Result, Code_Off);
                     I := Close + 1;
                  else
                     Append (Result, '`');
                     I := I + 1;
                  end if;
               end;

            --  Bold: two asterisks with text after them, closed by two with
            --  text before them.
            elsif I + 1 <= Upto and then Is_Marker (I, '*') and then Is_Marker (I + 1, '*')
              and then I + 2 <= Upto and then not Is_Space (I + 2) and then not Is_Marker (I + 2, '*')
            then
               declare
                  Close : Natural := 0;
               begin
                  for K in I + 3 .. Upto - 1 loop
                     if Is_Marker (K, '*') and then Is_Marker (K + 1, '*')
                       and then not Is_Space (K - 1)
                     then
                        Close := K;
                        exit;
                     end if;
                  end loop;
                  if Close > 0 then
                     Append (Result, Bold_On);
                     Inline (I + 2, Close - 1);
                     Append (Result, Bold_Off);
                     I := Close + 2;
                  else
                     Append (Result, "**");
                     I := I + 2;
                  end if;
               end;

            --  Italic: one asterisk with text after it, closed by one --
            --  not half of a pair -- with text before it.
            elsif Is_Marker (I, '*') and then I + 1 <= Upto
              and then not Is_Space (I + 1) and then not Is_Marker (I + 1, '*')
            then
               declare
                  Close : Natural := 0;
               begin
                  for K in I + 2 .. Upto loop
                     if Is_Marker (K, '*') and then not Is_Space (K - 1)
                       and then not Is_Marker (K - 1, '*')
                       and then (K = Upto or else not Is_Marker (K + 1, '*'))
                     then
                        Close := K;
                        exit;
                     end if;
                  end loop;
                  if Close > 0 then
                     Append (Result, Italic_On);
                     Inline (I + 1, Close - 1);
                     Append (Result, Italic_Off);
                     I := Close + 1;
                  else
                     Append (Result, '*');
                     I := I + 1;
                  end if;
               end;

            else
               Append (Result, Units (I).Char);
               I := I + 1;
            end if;
         end loop;
      end Inline;

   begin
      --  The escapes first: a line break, or a character made literal.
      while Index <= Template'Last loop
         Count := Count + 1;
         if Template (Index) = '\' and then Index < Template'Last
           and then Template (Index + 1) in 'n' | '\' | '*' | '`'
         then
            Units (Count) :=
              (Char    => (if Template (Index + 1) = 'n' then ASCII.LF else Template (Index + 1)),
               Literal => True);
            Index := Index + 2;
         else
            Units (Count) := (Char => Template (Index), Literal => False);
            Index := Index + 1;
         end if;
      end loop;

      --  Then line by line: an item's hyphen, and the line's markup.
      declare
         Start : Positive := 1;
      begin
         for Line_End in 1 .. Count + 1 loop
            if Line_End = Count + 1 or else Units (Line_End).Char = ASCII.LF then
               declare
                  From : Positive := Start;
               begin
                  if Line_End - Start >= 2 and then Is_Marker (Start, '-') and then Is_Space (Start + 1) then
                     Append (Result, Item_Mark);
                     From := Start + 2;
                  end if;
                  Inline (From, Line_End - 1);
               end;
               if Line_End <= Count then
                  Append (Result, ASCII.LF);
               end if;
               Start := Line_End + 1;
            end if;
         end loop;
      end;
      return To_String (Result);
   end Marked;

   function Is_Mark (C : Character) return Boolean is (C in Mark);

   ---------------
   -- Has_Marks --
   ---------------

   function Has_Marks (Item : String) return Boolean is
   begin
      for C of Item loop
         if C in Mark then
            return True;
         end if;
      end loop;
      return False;
   end Has_Marks;

   ------------
   -- Render --
   ------------

   function Render (Item : String; Styled : Boolean; Width : Natural := 0) return String is
      ESC    : constant Character := ASCII.ESC;
      Bullet : constant String :=
        Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#A2#);
      Result : Unbounded_String;

      --  A mark as it is drawn.
      function Drawn (C : Character) return String is
      begin
         if not Styled then
            return "";
         end if;
         case C is
            when Bold_On    => return ESC & "[1m";
            when Bold_Off   => return ESC & "[22m";
            when Italic_On  => return ESC & "[3m";
            when Italic_Off => return ESC & "[23m";
            when Code_On    => return ESC & "[36m";
            when Code_Off   => return ESC & "[39m";
            when others     => return "";
         end case;
      end Drawn;

      --  Text with its marks drawn.
      function Shown (Part : String) return String is
         Out_Text : Unbounded_String;
      begin
         for C of Part loop
            if C in Mark then
               Append (Out_Text, Drawn (C));
            else
               Append (Out_Text, C);
            end if;
         end loop;
         return To_String (Out_Text);
      end Shown;

      --  Columns a part takes on the screen: its marks and any style's
      --  sequence already in it -- a command coloured -- taking none.
      function Columns (Part : String) return Natural is
         Bare  : Unbounded_String;
         Index : Natural := Part'First;
      begin
         while Index <= Part'Last loop
            if Part (Index) = ESC and then Index < Part'Last and then Part (Index + 1) = '[' then
               Index := Index + 2;
               while Index <= Part'Last and then Part (Index) not in '@' .. '~' loop
                  Index := Index + 1;
               end loop;
               Index := Index + 1;
            else
               if Part (Index) not in Mark then
                  Append (Bare, Part (Index));
               end if;
               Index := Index + 1;
            end if;
         end loop;
         return Model_Runner.UTF8.Wrapped_Columns (To_String (Bare), Positive'Last);
      end Columns;

      --  One line: an item's bullet before it, and its words wrapped to the
      --  window under its text.
      procedure Line (Text : String) is
         --  An item may stand indented -- a note's lines after its first
         --  are -- its mark after the spaces.
         Spaces : Natural := 0;
      begin
         while Text'First + Spaces <= Text'Last and then Text (Text'First + Spaces) = ' ' loop
            Spaces := Spaces + 1;
         end loop;
         if Text'First + Spaces > Text'Last or else Text (Text'First + Spaces) /= Item_Mark then
            Append (Result, Shown (Text));
            return;
         end if;
         declare
            Indent : constant String (1 .. Spaces) := [others => ' '];
            Lead   : constant String := Indent & (if Styled then Bullet else "-") & " ";
            Body_Text : constant String := Text (Text'First + Spaces + 1 .. Text'Last);
            Room   : constant Natural := (if Width > Spaces + 3 then Width - 1 else 0);
            Used   : Natural := Spaces + 2;
            From   : Positive := Body_Text'First;
            First  : Boolean := True;
         begin
            Append (Result, Lead);
            if Room = 0 or else Used + Columns (Body_Text) <= Room then
               Append (Result, Shown (Body_Text));
               return;
            end if;
            --  Word by word, a space before each but the first on a row.
            while From <= Body_Text'Last loop
               declare
                  Stop : Natural := From;
               begin
                  while Stop <= Body_Text'Last and then Body_Text (Stop) /= ' ' loop
                     Stop := Stop + 1;
                  end loop;
                  declare
                     Word  : constant String := Body_Text (From .. Stop - 1);
                     Wide  : constant Natural := Columns (Word);
                  begin
                     if First then
                        Append (Result, Shown (Word));
                        Used := Used + Wide;
                        First := False;
                     elsif Used + 1 + Wide <= Room then
                        Append (Result, " " & Shown (Word));
                        Used := Used + 1 + Wide;
                     else
                        Append (Result, ASCII.LF & Indent & "  " & Shown (Word));
                        Used := Spaces + 2 + Wide;
                     end if;
                  end;
                  From := Stop + 1;
               end;
            end loop;
         end;
      end Line;

      Start : Positive := Item'First;
   begin
      for Index in Item'First .. Item'Last + 1 loop
         if Index > Item'Last or else Item (Index) = ASCII.LF then
            Line (Item (Start .. Index - 1));
            if Index <= Item'Last then
               Append (Result, ASCII.LF);
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Render;

   -----------
   -- Plain --
   -----------

   function Plain (Item : String) return String is
     (if Has_Marks (Item) then Render (Item, Styled => False) else Item);

end Model_Runner.Markup;
