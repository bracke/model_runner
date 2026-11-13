with Ada.Unchecked_Deallocation;
package body Model_Runner.Text is

   Hex_Digits : constant String := "0123456789ABCDEF";

   --  Report whether a character is an ASCII control character.
   function Is_Control (Item : Character) return Boolean
   is (Character'Pos (Item) < 16#20# or else Character'Pos (Item) = 16#7F#);

   ----------------
   -- To_Bounded --
   ----------------

   function To_Bounded (Item : String) return Bounded is
      Result : Bounded;
      Count  : constant Natural :=
        (if Item'Length > Max_Length then Max_Length else Item'Length);
   begin
      if Count > 0 then
         Result.Data (1 .. Count) := Item (Item'First .. Item'First + Count - 1);
      end if;
      Result.Last := Count;
      Result.Truncated := Item'Length > Max_Length;
      return Result;
   end To_Bounded;

   ------------------
   -- Has_Controls --
   ------------------

   function Has_Controls (Item : String) return Boolean is
   begin
      for Index in Item'Range loop
         if Is_Control (Item (Index))
           or else (Character'Pos (Item (Index)) = 16#C2#
                    and then Index < Item'Last
                    and then Character'Pos (Item (Index + 1)) in 16#80# .. 16#9F#)
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Controls;

   ----------------------
   -- Escape_Controls --
   ----------------------

   function Escape_Controls
     (Item             : String;
      Keep_Line_Breaks : Boolean := False;
      Indent           : Boolean := True;
      Keep_Tabs        : Boolean := False) return String
   is
      Margin : constant String := (if Indent then "    " else "");

      --  What each byte becomes, written into Into from its start, or
      --  only counted where Into is empty.
      procedure Fill (Into : in out String; Last : out Natural) is
         Index : Natural := Item'First;
         Count : constant Boolean := Into'Length = 0;

         procedure Put (Text : String) is
         begin
            if not Count then
               Into (Into'First + Last .. Into'First + Last + Text'Length - 1) := Text;
            end if;
            Last := Last + Text'Length;
         end Put;

         procedure Put_Escaped (Char : Character) is
            Code : constant Natural := Character'Pos (Char);
         begin
            Put ("\x" & Hex_Digits (Code / 16 + 1) & Hex_Digits (Code mod 16 + 1));
         end Put_Escaped;
      begin
         Last := 0;
         while Index <= Item'Last loop
            declare
               Char : constant Character := Item (Index);
            begin
               if Keep_Line_Breaks and then Char = ASCII.LF then
                  Put (ASCII.LF & Margin);
               elsif Keep_Tabs and then Char = ASCII.HT then
                  Put ([1 => Char]);
               elsif Is_Control (Char) then
                  Put_Escaped (Char);
               --  A C1 control, U+0080 to U+009F: in UTF-8 it is C2 and a
               --  byte of 80 to 9F, and a terminal that honours it -- 9B
               --  begins a sequence as ESC [ does -- is obeyed as surely.
               elsif Character'Pos (Char) = 16#C2#
                 and then Index < Item'Last
                 and then Character'Pos (Item (Index + 1)) in 16#80# .. 16#9F#
               then
                  Put_Escaped (Char);
                  Put_Escaped (Item (Index + 1));
                  Index := Index + 1;
               else
                  Put ([1 => Char]);
               end if;
            end;
            Index := Index + 1;
         end loop;
      end Fill;

      --  Past this many bytes the result is built on the heap: a tool's
      --  result or a context of a megabyte, made five times over on the
      --  stack for the worst case, overflowed it.
      On_Stack : constant := 64 * 1024;
      Nothing  : String (1 .. 0);
      Needed   : Natural;
   begin
      --  Nothing to show otherwise: the text as it is, from 1 as an
      --  escaped one is.
      if not Has_Controls (Item) then
         declare
            subtype From_One is String (1 .. Item'Length);
         begin
            return From_One (Item);
         end;
      end if;
      Fill (Nothing, Needed);
      if Needed <= On_Stack then
         declare
            Result : String (1 .. Needed);
            Last   : Natural;
         begin
            Fill (Result, Last);
            return Result;
         end;
      end if;
      declare
         type Text_Access is access String;
         procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);
         Built : Text_Access := new String (1 .. Needed);
         Last  : Natural;
      begin
         Fill (Built.all, Last);
         return Result : constant String := Built.all do
            Free (Built);
         end return;
      end;
   end Escape_Controls;

   -------------------
   -- Show_Controls --
   -------------------

   function Show_Controls (Item : String; Lead : in out Boolean) return String is
      Held : Boolean := False;
      Said : constant String := Show_Controls (Item, Lead, Held);
   begin
      --  No piece after it: a carriage return at the end is one alone.
      return (if Held then Said & "\x0D" else Said);
   end Show_Controls;

   function Show_Controls
     (Item    : String;
      Lead    : in out Boolean;
      Held_CR : in out Boolean) return String
   is
      Lead_Byte : constant Character := Character'Val (16#C2#);
      Whole     : constant String :=
        (if Lead then [1 => Lead_Byte] else "") & (if Held_CR then [1 => ASCII.CR] else "") & Item;
      Result    : String (1 .. Whole'Length * 8);
      Last      : Natural := 0;
      Index     : Natural := Whole'First;

      procedure Put_Escaped (Char : Character) is
         Code : constant Natural := Character'Pos (Char);
      begin
         Result (Last + 1 .. Last + 2) := "\x";
         Result (Last + 3) := Hex_Digits (Code / 16 + 1);
         Result (Last + 4) := Hex_Digits (Code mod 16 + 1);
         Last := Last + 4;
      end Put_Escaped;
   begin
      Lead := False;
      Held_CR := False;
      while Index <= Whole'Last loop
         declare
            Char : constant Character := Whole (Index);
         begin
            if Char = Lead_Byte and then Index = Whole'Last then
               Lead := True;
            --  The piece's last byte a carriage return: whether a line feed
            --  follows is the next piece's to say -- a tokenizer gives the
            --  two as two tokens.
            elsif Char = ASCII.CR and then Index = Whole'Last then
               Held_CR := True;
            elsif Char = Lead_Byte
              and then Character'Pos (Whole (Index + 1)) in 16#80# .. 16#9F#
            then
               Put_Escaped (Char);
               Put_Escaped (Whole (Index + 1));
               Index := Index + 1;
            --  A carriage return before a line feed is a line's end; one
            --  alone returns the cursor, and what follows is written over
            --  what was shown -- a command made to read as another.
            elsif Is_Control (Char)
              and then Char not in ASCII.LF | ASCII.HT
              and then not (Char = ASCII.CR and then Index < Whole'Last and then Whole (Index + 1) = ASCII.LF)
            then
               Put_Escaped (Char);
            else
               Last := Last + 1;
               Result (Last) := Char;
            end if;
         end;
         Index := Index + 1;
      end loop;
      return Result (1 .. Last);
   end Show_Controls;

   -----------
   -- Image --
   -----------

   function Image (Value : Interfaces.Unsigned_64) return String is
      Raw : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      if Raw'Length > 0 and then Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      else
         return Raw;
      end if;
   end Image;

   -----------
   -- Image --
   -----------

   function Image (Value : Long_Long_Integer) return String is
      Raw : constant String := Long_Long_Integer'Image (Value);
   begin
      if Raw'Length > 0 and then Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      else
         return Raw;
      end if;
   end Image;

   -----------
   -- Image --
   -----------

   function Image (Value : Long_Float; Decimals : Natural := 2) return String is
      Scale     : Long_Float := 1.0;
      Negative  : constant Boolean := Value < 0.0;
      Magnitude : constant Long_Float := abs Value;
      Scaled    : Long_Float;
   begin
      --  A non-finite value has no fixed-point image. Report it with a stable
      --  ASCII token rather than raising inside a diagnostic path.
      if not (Magnitude = Magnitude) then
         return "nan";
      elsif Magnitude > Long_Float (Long_Long_Integer'Last) / 2.0 then
         return (if Negative then "-inf" else "inf");
      end if;

      for Ignored in 1 .. Decimals loop
         Scale := Scale * 10.0;
      end loop;

      --  Too large to scale to whole units of the last decimal -- an
      --  unnormalized embedding's component past nine million million at
      --  six decimals -- and the conversion below raised: the whole part
      --  alone, its decimals what is left of it, which at that size is
      --  nothing a binary64 still holds.
      if Magnitude * Scale > Long_Float (Long_Long_Integer'Last) / 2.0 then
         declare
            Sign : constant String := (if Negative then "-" else "");
            Zeros : constant String (1 .. Decimals) := [others => '0'];
         begin
            return Sign
              & Image (Long_Long_Integer (Long_Float'Floor (Magnitude)))
              & (if Decimals = 0 then "" else "." & Zeros);
         end;
      end if;

      Scaled := Long_Float'Floor (Magnitude * Scale + 0.5);

      declare
         Units    : constant Long_Long_Integer := Long_Long_Integer (Scaled);
         Whole    : constant Long_Long_Integer :=
           Units / Long_Long_Integer (Scale);
         Fraction : constant Long_Long_Integer :=
           Units mod Long_Long_Integer (Scale);
         Sign     : constant String := (if Negative then "-" else "");
      begin
         if Decimals = 0 then
            return Sign & Image (Whole);
         end if;

         declare
            Digits_Text : String (1 .. Decimals) := [others => '0'];
            Remaining   : Long_Long_Integer := Fraction;
         begin
            for Index in reverse 1 .. Decimals loop
               Digits_Text (Index) :=
                 Character'Val (Character'Pos ('0') + Natural (Remaining mod 10));
               Remaining := Remaining / 10;
            end loop;
            return Sign & Image (Whole) & "." & Digits_Text;
         end;
      end;
   end Image;

   --------------
   -- To_Lower --
   --------------

   function To_Lower (Item : String) return String is
      Result : String (Item'Range);
   begin
      for Index in Item'Range loop
         if Item (Index) in 'A' .. 'Z' then
            Result (Index) :=
              Character'Val
                (Character'Pos (Item (Index))
                 - Character'Pos ('A') + Character'Pos ('a'));
         else
            Result (Index) := Item (Index);
         end if;
      end loop;
      return Result;
   end To_Lower;

   -------------------------
   -- Equal_Ignore_Case --
   -------------------------

   function Equal_Ignore_Case (Left, Right : String) return Boolean is
   begin
      return Left'Length = Right'Length and then To_Lower (Left) = To_Lower (Right);
   end Equal_Ignore_Case;

   ----------
   -- Trim --
   ----------

   function Trim (Item : String) return String is
      First : Natural := Item'First;
      Last  : Natural := Item'Last;
   begin
      while First <= Last
        and then (Item (First) = ' ' or else Item (First) = ASCII.HT)
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then (Item (Last) = ' ' or else Item (Last) = ASCII.HT)
      loop
         Last := Last - 1;
      end loop;
      return Item (First .. Last);
   end Trim;

   --------------------
   -- Leading_Number --
   --------------------

   function Leading_Number (Item : String) return Integer is
      --  Bounded so that a line of digits cannot overflow on its way to
      --  being refused. Anything past what a Natural holds is not a
      --  processor number and the answer is that there is none.
      Ceiling : constant Natural := Natural'Last / 10;
      Value   : Natural := 0;
      Seen    : Boolean := False;
   begin
      for Position in Item'Range loop
         exit when Item (Position) not in '0' .. '9';

         if Value > Ceiling then
            return -1;
         end if;

         Value := Value * 10 + (Character'Pos (Item (Position))
                                - Character'Pos ('0'));
         Seen := True;
      end loop;

      return (if Seen then Value else -1);
   end Leading_Number;

   -----------------
   -- Starts_With --
   -----------------

   function Starts_With (Item : String; Prefix : String) return Boolean is
   begin
      return Prefix'Length <= Item'Length
        and then Item (Item'First .. Item'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   ---------------
   -- Ends_With --
   ---------------

   function Ends_With (Item : String; Suffix : String) return Boolean is
   begin
      return Suffix'Length <= Item'Length
        and then Item (Item'Last - Suffix'Length + 1 .. Item'Last) = Suffix;
   end Ends_With;

   -----------------
   -- JSON_Quoted --
   -----------------

   function JSON_Quoted (Item : String) return String is
      Digits_16 : constant String := "0123456789abcdef";
      Room   : String (1 .. 6 * Item'Length + 2);
      Filled : Natural := 0;

      procedure Put (Piece : String) is
      begin
         Room (Filled + 1 .. Filled + Piece'Length) := Piece;
         Filled := Filled + Piece'Length;
      end Put;
   begin
      Put ("""");
      for C of Item loop
         case C is
            when '"'      => Put ("\""");
            when '\'      => Put ("\\");
            when ASCII.LF => Put ("\n");
            when ASCII.CR => Put ("\r");
            when ASCII.HT => Put ("\t");
            when Character'Val (0) .. Character'Val (8)
               | Character'Val (11) .. Character'Val (12)
               | Character'Val (14) .. Character'Val (31) =>
               Put ("\u00"
                    & Digits_16 (Digits_16'First + Character'Pos (C) / 16)
                    & Digits_16 (Digits_16'First + Character'Pos (C) mod 16));
            when others   => Put ([1 => C]);
         end case;
      end loop;
      Put ("""");
      return Room (1 .. Filled);
   end JSON_Quoted;

end Model_Runner.Text;
