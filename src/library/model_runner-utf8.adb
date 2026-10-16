package body Model_Runner.UTF8 is

   subtype Byte_Value is Natural range 0 .. 255;

   function Code (Item : Character) return Byte_Value
   is (Character'Pos (Item));

   --  Report whether Item is a UTF-8 continuation byte (10xxxxxx).
   function Is_Continuation (Item : Character) return Boolean
   is (Code (Item) in 16#80# .. 16#BF#);

   ---------------------
   -- Sequence_Length --
   ---------------------

   function Sequence_Length (Lead : Character) return Natural is
      Value : constant Byte_Value := Code (Lead);
   begin
      if Value <= 16#7F# then
         return 1;
      elsif Value in 16#C2# .. 16#DF# then
         return 2;
      elsif Value in 16#E0# .. 16#EF# then
         return 3;
      elsif Value in 16#F0# .. 16#F4# then
         return 4;
      else
         --  16#80# .. 16#C1# are continuation bytes or overlong two-byte
         --  leads; 16#F5# .. 16#FF# would exceed U+10FFFF.
         return 0;
      end if;
   end Sequence_Length;

   --  Validate one sequence starting at Index. Length is the consumed byte
   --  count on success and 0 on failure.
   procedure Scan_Sequence
     (Item   : String;
      Index  : Positive;
      Length : out Natural)
   is
      Needed : constant Natural := Sequence_Length (Item (Index));
      Lead   : constant Byte_Value := Code (Item (Index));
   begin
      Length := 0;

      if Needed = 0 or else Index + Needed - 1 > Item'Last then
         return;
      end if;

      for Offset in 1 .. Needed - 1 loop
         if not Is_Continuation (Item (Index + Offset)) then
            return;
         end if;
      end loop;

      --  Reject the encodings that a length check alone would admit:
      --  overlong three-byte forms, UTF-16 surrogates, overlong four-byte
      --  forms and code points above U+10FFFF.
      if Needed = 3 then
         declare
            Second : constant Byte_Value := Code (Item (Index + 1));
         begin
            if Lead = 16#E0# and then Second < 16#A0# then
               return;
            elsif Lead = 16#ED# and then Second > 16#9F# then
               return;
            end if;
         end;
      elsif Needed = 4 then
         declare
            Second : constant Byte_Value := Code (Item (Index + 1));
         begin
            if Lead = 16#F0# and then Second < 16#90# then
               return;
            elsif Lead = 16#F4# and then Second > 16#8F# then
               return;
            end if;
         end;
      end if;

      Length := Needed;
   end Scan_Sequence;

   --------------
   -- Validate --
   --------------

   procedure Validate
     (Item        : String;
      Valid       : out Boolean;
      Error_Index : out Natural)
   is
      Index  : Natural := Item'First;
      Length : Natural;
   begin
      while Index <= Item'Last loop
         Scan_Sequence (Item, Index, Length);
         if Length = 0 then
            Valid := False;
            Error_Index := Index;
            return;
         end if;
         Index := Index + Length;
      end loop;

      Valid := True;
      Error_Index := 0;
   end Validate;

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (Item : String) return Boolean is
      Valid       : Boolean;
      Error_Index : Natural;
   begin
      Validate (Item, Valid, Error_Index);
      return Valid;
   end Is_Valid;

   --------------------------
   -- Safe_Prefix_Length --
   --------------------------

   function Safe_Prefix_Length (Item : String) return Natural is
      Index  : Natural := Item'First;
      Length : Natural;
   begin
      while Index <= Item'Last loop
         Scan_Sequence (Item, Index, Length);

         if Length > 0 then
            Index := Index + Length;
         else
            declare
               Needed    : constant Natural := Sequence_Length (Item (Index));
               Available : constant Natural := Item'Last - Index + 1;
               Complete  : Boolean := True;
            begin
               --  A truncated but so-far-consistent sequence at the end is
               --  withheld: more bytes may complete it. Anything else is
               --  malformed no matter what follows: that byte is released
               --  for the caller to observe, and the scan goes on past it,
               --  so a truncated sequence after it is still withheld.
               if Needed > 1 and then Available < Needed then
                  for Offset in 1 .. Available - 1 loop
                     if not Is_Continuation (Item (Index + Offset)) then
                        Complete := False;
                        exit;
                     end if;
                  end loop;

                  if Complete then
                     return Index - Item'First;
                  end if;
               end if;

               Index := Index + 1;
            end;
         end if;
      end loop;

      return Item'Length;
   end Safe_Prefix_Length;

   --------------
   -- Repaired --
   --------------

   function Repaired (Item : String) return String is
      Replacement : constant String :=
        Character'Val (16#EF#) & Character'Val (16#BF#) & Character'Val (16#BD#);
      Result : String (1 .. 3 * Item'Length);
      Last   : Natural := 0;
      Index  : Natural := Item'First;
      Length : Natural;
   begin
      if Is_Valid (Item) then
         return Item;
      end if;
      while Index <= Item'Last loop
         Scan_Sequence (Item, Index, Length);
         if Length > 0 then
            Result (Last + 1 .. Last + Length) := Item (Index .. Index + Length - 1);
            Last := Last + Length;
            Index := Index + Length;
         else
            Result (Last + 1 .. Last + 3) := Replacement;
            Last := Last + 3;
            Index := Index + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Repaired;

   ----------------------
   -- Code_Point_Count --
   ----------------------

   function Code_Point_Count (Item : String) return Natural is
      Index  : Natural := Item'First;
      Length : Natural;
      Count  : Natural := 0;
   begin
      while Index <= Item'Last loop
         Scan_Sequence (Item, Index, Length);
         if Length = 0 then
            return 0;
         end if;
         Count := Count + 1;
         Index := Index + Length;
      end loop;
      return Count;
   end Code_Point_Count;

   --------------------
   -- Decode_First --
   --------------------

   procedure Decode_First
     (Item       : String;
      Code_Point : out Natural;
      Length     : out Natural)
   is
      Consumed : Natural;
   begin
      Code_Point := 0;
      Length := 0;

      if Item'Length = 0 then
         return;
      end if;

      Scan_Sequence (Item, Item'First, Consumed);
      if Consumed = 0 then
         return;
      end if;

      declare
         Lead  : constant Byte_Value := Code (Item (Item'First));
         Value : Natural;
      begin
         case Consumed is
            when 1 => Value := Lead;
            when 2 => Value := Lead - 16#C0#;
            when 3 => Value := Lead - 16#E0#;
            when others => Value := Lead - 16#F0#;
         end case;

         for Offset in 1 .. Consumed - 1 loop
            Value := Value * 64 + (Code (Item (Item'First + Offset)) - 16#80#);
         end loop;

         Code_Point := Value;
         Length := Consumed;
      end;
   end Decode_First;

   ------------
   -- Encode --
   ------------

   function Encode (Code_Point : Natural) return String is
   begin
      if Code_Point <= 16#7F# then
         return [1 => Character'Val (Code_Point)];
      elsif Code_Point <= 16#7FF# then
         return
           [1 => Character'Val (16#C0# + Code_Point / 64),
            2 => Character'Val (16#80# + Code_Point mod 64)];
      elsif Code_Point in 16#D800# .. 16#DFFF# then
         return "";
      elsif Code_Point <= 16#FFFF# then
         return
           [1 => Character'Val (16#E0# + Code_Point / 4096),
            2 => Character'Val (16#80# + (Code_Point / 64) mod 64),
            3 => Character'Val (16#80# + Code_Point mod 64)];
      elsif Code_Point <= 16#10FFFF# then
         return
           [1 => Character'Val (16#F0# + Code_Point / 262144),
            2 => Character'Val (16#80# + (Code_Point / 4096) mod 64),
            3 => Character'Val (16#80# + (Code_Point / 64) mod 64),
            4 => Character'Val (16#80# + Code_Point mod 64)];
      else
         return "";
      end if;
   end Encode;

   ------------------------
   -- Code_Point_Columns --
   ------------------------

   function Code_Point_Columns (Code_Point : Natural) return Natural is
   begin
      case Code_Point is
         when 16#0300# .. 16#036F# | 16#0483# .. 16#0489# | 16#0591# .. 16#05BD#
            | 16#0610# .. 16#061A# | 16#064B# .. 16#065F# | 16#0E31# | 16#0E34# .. 16#0E3A#
            | 16#1AB0# .. 16#1AFF# | 16#1DC0# .. 16#1DFF# | 16#200B# .. 16#200F#
            | 16#20D0# .. 16#20FF# | 16#FE00# .. 16#FE0F# | 16#FE20# .. 16#FE2F#
            | 16#E0100# .. 16#E01EF# =>
            return 0;
         when 16#1100# .. 16#115F# | 16#231A# .. 16#231B# | 16#2329# .. 16#232A#
            | 16#2E80# .. 16#303E# | 16#3041# .. 16#33FF# | 16#3400# .. 16#4DBF#
            | 16#4E00# .. 16#9FFF# | 16#A000# .. 16#A4CF# | 16#A960# .. 16#A97F#
            | 16#AC00# .. 16#D7A3# | 16#F900# .. 16#FAFF# | 16#FE10# .. 16#FE19#
            | 16#FE30# .. 16#FE6F# | 16#FF00# .. 16#FF60# | 16#FFE0# .. 16#FFE6#
            | 16#1F300# .. 16#1F64F# | 16#1F900# .. 16#1F9FF# | 16#20000# .. 16#3FFFD# =>
            return 2;
         when others =>
            return 1;
      end case;
   end Code_Point_Columns;

   --  One step of Columns and Fitting: the bytes the thing at From takes
   --  and the columns it is drawn in.
   procedure Step (Item : String; From : Positive; Bytes, Width : out Natural) is
      Point : Natural;
   begin
      if Item (From) = ASCII.ESC
        and then From < Item'Last
        and then Item (From + 1) = '['
      then
         Bytes := 2;
         while From + Bytes <= Item'Last
           and then Character'Pos (Item (From + Bytes)) in 16#20# .. 16#3F#
         loop
            Bytes := Bytes + 1;
         end loop;
         if From + Bytes <= Item'Last then
            Bytes := Bytes + 1;
         end if;
         Width := 0;
      elsif Character'Pos (Item (From)) < 16#20# or else Character'Pos (Item (From)) = 16#7F# then
         Bytes := 1;
         Width := 0;
      else
         Decode_First (Item (From .. Item'Last), Point, Bytes);
         if Bytes = 0 then
            Bytes := 1;
            Width := 1;
         else
            Width := Code_Point_Columns (Point);
         end if;
      end if;
   end Step;

   -------------
   -- Columns --
   -------------

   function Columns (Item : String) return Natural is
      Index : Natural := Item'First;
      Total : Natural := 0;
      Bytes, Width : Natural;
   begin
      while Index <= Item'Last loop
         Step (Item, Index, Bytes, Width);
         --  A tab to the next stop of eight, as the terminal moves it.
         Total := (if Item (Index) = ASCII.HT then (Total / 8 + 1) * 8 else Total + Width);
         Index := Index + Bytes;
      end loop;
      return Total;
   end Columns;

   -------------
   -- Fitting --
   -------------

   function Fitting (Item : String; Room : Natural) return Natural is
      Index : Natural := Item'First;
      Total : Natural := 0;
      Bytes, Width : Natural;
   begin
      while Index <= Item'Last loop
         Step (Item, Index, Bytes, Width);
         if Item (Index) = ASCII.HT then
            Width := (Total / 8 + 1) * 8 - Total;
         end if;
         exit when Total + Width > Room;
         Total := Total + Width;
         Index := Index + Bytes;
      end loop;
      return Index - Item'First;
   end Fitting;

   --------------------------
   -- Last_Character_First --
   --------------------------

   function Last_Character_First (Item : String) return Positive is
      At_Byte : Positive := Item'Last;
   begin
      while At_Byte > Item'First and then not Begins_Character (Item (At_Byte))
      loop
         At_Byte := At_Byte - 1;
      end loop;
      return At_Byte;
   end Last_Character_First;

end Model_Runner.UTF8;
