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
      for Char of Item loop
         if Is_Control (Char) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Controls;

   ----------------------
   -- Escape_Controls --
   ----------------------

   function Escape_Controls (Item : String) return String is
      Result : String (1 .. Item'Length * 4);
      Last   : Natural := 0;
   begin
      for Char of Item loop
         if Is_Control (Char) then
            declare
               Code : constant Natural := Character'Pos (Char);
            begin
               Result (Last + 1) := '\';
               Result (Last + 2) := 'x';
               Result (Last + 3) := Hex_Digits (Code / 16 + 1);
               Result (Last + 4) := Hex_Digits (Code mod 16 + 1);
               Last := Last + 4;
            end;
         else
            Last := Last + 1;
            Result (Last) := Char;
         end if;
      end loop;
      return Result (1 .. Last);
   end Escape_Controls;

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

end Model_Runner.Text;
