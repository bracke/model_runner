with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Errors;
with Model_Runner.Numerics;

package body Reference_Transformer is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package Functions is
     new Ada.Numerics.Generic_Elementary_Functions (Long_Float);

   --  A row rounded to four bits an element in blocks of thirty-two, as
   --  the spec describes: what a value becomes when the engine's nibble
   --  cache keeps it and hands it back.
   procedure Round_To_Nibbles (Row : in out Real_Vector) is
      Block : constant := 32;
      Offset : Natural := Row'First;
   begin
      while Offset <= Row'Last loop
         declare
            Last    : constant Natural := Natural'Min (Row'Last, Offset + Block - 1);
            Largest : Long_Float := 0.0;
            Signed  : Long_Float := 0.0;
            Scale   : Long_Float;
         begin
            for Index in Offset .. Last loop
               if abs Row (Index) > Largest then
                  Largest := abs Row (Index);
                  Signed := Row (Index);
               end if;
            end loop;
            Scale := Signed / (-8.0);
            for Index in Offset .. Last loop
               declare
                  Level : constant Long_Float :=
                    (if Scale /= 0.0
                     then Long_Float'Floor (Row (Index) / Scale + 8.5)
                     else 8.0);
                  Held : constant Long_Float :=
                    Long_Float'Max (0.0, Long_Float'Min (15.0, Level));
               begin
                  Row (Index) := (Held - 8.0) * Scale;
               end;
            end loop;
            Offset := Last + 1;
         end;
      end loop;
   end Round_To_Nibbles;

   --  A row rounded to a signed byte an element with the row's one scale,
   --  as the spec describes: what a value becomes when the engine's byte
   --  cache keeps it and hands it back.
   procedure Round_To_Bytes (Row : in out Real_Vector) is
      Largest : Long_Float := 0.0;
      Scale   : Long_Float;
   begin
      for Value of Row loop
         Largest := Long_Float'Max (Largest, abs Value);
      end loop;
      Scale := (if Largest > 0.0 then Largest / 127.0 else 1.0);
      for Index in Row'Range loop
         declare
            Step : constant Long_Float := Long_Float'Rounding (Row (Index) / Scale);
            Held : constant Long_Float :=
              Long_Float'Max (-127.0, Long_Float'Min (127.0, Step));
         begin
            Row (Index) := Held * Scale;
         end;
      end loop;
   end Round_To_Bytes;

   --  A row rounded as one side's rounding says.
   procedure Round_As (Row : in out Real_Vector; How : Cache_Rounding) is
   begin
      case How is
         when Unrounded  => null;
         when To_Bytes   => Round_To_Bytes (Row);
         when To_Nibbles => Round_To_Nibbles (Row);
      end case;
   end Round_As;

   procedure Free_Matrix is
     new Ada.Unchecked_Deallocation (Matrix, Matrix_Access);
   procedure Free_Vector is
     new Ada.Unchecked_Deallocation (Real_Vector, Vector_Access);
   procedure Free_Layers is
     new Ada.Unchecked_Deallocation (Layer_Array, Layer_Array_Access);

   -------------------
   -- Decode_Float --
   -------------------

   function Decode_Float
     (Image  : B.Byte_Array;
      Offset : Interfaces.Unsigned_64) return Long_Float
   is
      Base : constant B.Byte_Count := Image'First + B.Byte_Count (Offset);
      Raw  : Interfaces.Unsigned_32 := 0;
   begin
      --  Assemble the little-endian word by hand rather than reusing the
      --  engine's primitive decoding, so that a decoding mistake cannot be
      --  common to both implementations.
      for Index in reverse 0 .. 3 loop
         Raw := Interfaces.Shift_Left (Raw, 8)
           + Interfaces.Unsigned_32 (Image (Base + B.Byte_Count (Index)));
      end loop;

      declare
         Sign     : constant Long_Float :=
           (if (Raw and 16#8000_0000#) /= 0 then -1.0 else 1.0);
         Exponent : constant Integer :=
           Integer (Interfaces.Shift_Right (Raw, 23) and 16#FF#);
         Mantissa : constant Interfaces.Unsigned_32 := Raw and 16#7F_FFFF#;
      begin
         --  Reconstruct the value arithmetically from its fields. This is the
         --  definition of binary32 rather than a reinterpretation of the host
         --  representation, which is what makes it an independent decode.
         if Exponent = 0 then
            if Mantissa = 0 then
               return Sign * 0.0;
            end if;
            return Sign * Long_Float (Mantissa) * 2.0 ** (-149);
         elsif Exponent = 16#FF# then
            --  The synthetic models carry no non-finite weights; report a zero
            --  rather than inventing an infinity the comparison cannot use.
            return 0.0;
         else
            return Sign
              * (1.0 + Long_Float (Mantissa) / 8_388_608.0)
              * 2.0 ** (Exponent - 127);
         end if;
      end;
   end Decode_Float;

   --  Decode one Q8_0 element, independently of the engine.
   --
   --  The layout says: thirty-two elements to a block of thirty-four bytes,
   --  a half-precision scale first, then one signed byte each. This works the
   --  half out arithmetically from its sign, exponent and mantissa rather than
   --  reusing the engine's conversion, so a fault in that conversion cannot
   --  hide by being made twice.
   function Decode_Q8_0
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is

      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;
      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 34;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Raw_Half : constant Natural :=
        Byte_At (At_Block) + 256 * Byte_At (At_Block + 1);

      Sign     : constant Long_Float :=
        (if Raw_Half >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw_Half / 1024) mod 32;
      Mantissa : constant Integer := Raw_Half mod 1024;

      Scale : Long_Float;

      Quant : constant Integer :=
        (if Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within)) < 128
         then Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within))
         else Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within)) - 256);
   begin
      if Exponent = 0 then
         --  Subnormal, or zero when the mantissa is zero too.
         Scale := Sign * Long_Float (Mantissa) * (2.0 ** (-24));
      elsif Exponent = 31 then
         --  Infinity or not-a-number; a fixture never contains one, and
         --  answering zero keeps this from inventing a value.
         Scale := 0.0;
      else
         Scale :=
           Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
           * (2.0 ** (Exponent - 15));
      end if;

      return Scale * Long_Float (Quant);
   end Decode_Q8_0;

   --  Decode one half-precision element, independently of the engine.
   --
   --  Five exponent bits biased by fifteen and ten of mantissa, worked out
   --  from the fields the way the Q8_0 decoder does its scale.
   function Decode_Half
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64) return Long_Float
   is
      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Raw      : constant Natural := Byte_At (Base) + 256 * Byte_At (Base + 1);
      Sign     : constant Long_Float :=
        (if Raw >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw / 1024) mod 32;
      Mantissa : constant Integer := Raw mod 1024;
   begin
      if Exponent = 0 then
         return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
      elsif Exponent = 31 then
         return 0.0;
      else
         return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
           * (2.0 ** (Exponent - 15));
      end if;
   end Decode_Half;

   --  Decode one BF16 element, independently of the engine.
   --
   --  A brain float is the top half of a binary32: the same sign and
   --  exponent, and seven mantissa bits where binary32 has twenty-three.
   --  Worked out from those fields rather than by shifting into a float,
   --  which is what the engine does.
   function Decode_BF16
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64) return Long_Float
   is
      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Raw      : constant Natural := Byte_At (Base) + 256 * Byte_At (Base + 1);
      Sign     : constant Long_Float :=
        (if Raw >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw / 128) mod 256;
      Mantissa : constant Integer := Raw mod 128;
   begin
      if Exponent = 0 then
         return Sign * Long_Float (Mantissa) * (2.0 ** (-133));
      elsif Exponent = 255 then
         return 0.0;
      else
         return Sign * (1.0 + Long_Float (Mantissa) / 128.0)
           * (2.0 ** (Exponent - 127));
      end if;
   end Decode_BF16;

   --  Decode one four-bit element, independently of the engine.
   --
   --  Thirty-two to a block: a half-precision scale, then for Q4_1 a
   --  half-precision minimum, then sixteen bytes in which element j is the
   --  low nibble and element j + 16 the high one. Q4_0 centres the level on
   --  eight; Q4_1 lifts it from the minimum.
   function Decode_Four_Bit
     (Image   : Model_Runner.Bytes.Byte_Array;
      Base    : Interfaces.Unsigned_64;
      Index   : Natural;
      Centred : Boolean) return Long_Float
   is
      Width  : constant Interfaces.Unsigned_64 := (if Centred then 18 else 20);
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * Width;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale   : constant Long_Float := Half_At (At_Block);
      Lowest  : constant Long_Float :=
        (if Centred then 0.0 else Half_At (At_Block + 2));
      Quants  : constant Interfaces.Unsigned_64 :=
        At_Block + (if Centred then 2 else 4);

      Packed  : constant Natural :=
        Byte_At (Quants + Interfaces.Unsigned_64 (Within mod 16));
      Level   : constant Natural :=
        (if Within < 16 then Packed mod 16 else Packed / 16);
   begin
      if Centred then
         return Scale * Long_Float (Level - 8);
      else
         return Scale * Long_Float (Level) + Lowest;
      end if;
   end Decode_Four_Bit;

   --  Decode one five-bit element, independently of the engine.
   --
   --  Thirty-two to a block: a half-precision scale, for Q5_1 a
   --  half-precision minimum, then four bytes read as one thirty-two bit
   --  word in which bit j is the fifth bit of element j, then sixteen bytes
   --  of nibbles. Q5_0 centres the level on sixteen; Q5_1 lifts it.
   function Decode_Five_Bit
     (Image   : Model_Runner.Bytes.Byte_Array;
      Base    : Interfaces.Unsigned_64;
      Index   : Natural;
      Centred : Boolean) return Long_Float
   is
      Width  : constant Interfaces.Unsigned_64 := (if Centred then 22 else 24);
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * Width;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale  : constant Long_Float := Half_At (At_Block);
      Lowest : constant Long_Float :=
        (if Centred then 0.0 else Half_At (At_Block + 2));

      Fifths_At : constant Interfaces.Unsigned_64 :=
        At_Block + (if Centred then 2 else 4);
      Quants_At : constant Interfaces.Unsigned_64 :=
        At_Block + (if Centred then 6 else 8);

      Word : constant Natural :=
        Byte_At (Fifths_At)
        + 256 * Byte_At (Fifths_At + 1)
        + 65_536 * Byte_At (Fifths_At + 2);
      Top  : constant Natural := Byte_At (Fifths_At + 3);

      --  Bit j of the word, taking the fourth byte separately so that this
      --  needs no thirty-two bit arithmetic.
      function Fifth (Position : Natural) return Natural
      is (if Position < 24
          then (Word / (2 ** Position)) mod 2
          else (Top / (2 ** (Position - 24))) mod 2);

      Packed : constant Natural :=
        Byte_At (Quants_At + Interfaces.Unsigned_64 (Within mod 16));
      Level  : constant Natural :=
        (if Within < 16 then Packed mod 16 else Packed / 16)
        + 16 * Fifth (Within);
   begin
      if Centred then
         return Scale * Long_Float (Level - 16);
      else
         return Scale * Long_Float (Level) + Lowest;
      end if;
   end Decode_Five_Bit;

   --  Decode one Q3_K element, independently of the engine.
   --
   --  Three bits in two pieces: the low two packed four to a byte as in the
   --  two-bit format, the third in a mask of thirty-two bytes whose bit for
   --  a sub-block is set when the level is zero or above -- its absence is
   --  what takes four away. Sixteen six-bit signed scales, stored biased by
   --  thirty-two across twelve bytes.
   function Decode_Q3_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;

      Half   : constant Natural := Within / 128;
      Rest   : constant Natural := Within mod 128;
      Group  : constant Natural := Rest / 32;
      Upper  : constant Natural := (Rest mod 32) / 16;
      In_Sub : constant Natural := Within mod 16;
      Sub    : constant Natural := Half * 8 + Group * 2 + Upper;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 110;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Scales : constant Interfaces.Unsigned_64 := At_Block + 96;
      Place  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Sub mod 4);
      Nibble : constant Interfaces.Unsigned_64 :=
        (if (Sub / 4) mod 2 = 0 then Place else Place + 4);

      Low_Bits : constant Natural :=
        (if Sub / 4 < 2
         then Byte_At (Scales + Nibble) mod 16
         else Byte_At (Scales + Nibble) / 16);
      Top_Bits : constant Natural :=
        (Byte_At (Scales + Place + 8) / (2 ** (2 * (Sub / 4)))) mod 4;
      Factor   : constant Integer := Low_Bits + 16 * Top_Bits - 32;

      From : constant Interfaces.Unsigned_64 :=
        At_Block + 32 + Interfaces.Unsigned_64 (Half * 32 + Upper * 16)
        + Interfaces.Unsigned_64 (In_Sub);
      Mask_At : constant Interfaces.Unsigned_64 :=
        At_Block + Interfaces.Unsigned_64 (Upper * 16)
        + Interfaces.Unsigned_64 (In_Sub);

      Low    : constant Natural := (Byte_At (From) / (2 ** (2 * Group))) mod 4;
      Lifted : constant Boolean :=
        (Byte_At (Mask_At) / (2 ** (Half * 4 + Group))) mod 2 = 1;
      Level  : constant Integer := (if Lifted then Low else Low - 4);

      Raw      : constant Natural := Byte_At (At_Block + 108)
        + 256 * Byte_At (At_Block + 109);
      Sign     : constant Long_Float :=
        (if Raw >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw / 1024) mod 32;
      Mantissa : constant Integer := Raw mod 1024;
      D        : Long_Float;
   begin
      if Exponent = 0 then
         D := Sign * Long_Float (Mantissa) * (2.0 ** (-24));
      elsif Exponent = 31 then
         D := 0.0;
      else
         D := Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
           * (2.0 ** (Exponent - 15));
      end if;

      return D * Long_Float (Factor) * Long_Float (Level);
   end Decode_Q3_K;

   --  Decode one Q5_K element, independently of the engine.
   --
   --  Q4_K's shape with a bit kept aside: two half-precision factors, twelve
   --  bytes of six-bit scales and minimums, thirty-two bytes in which bit
   --  2g of byte L is the fifth bit of element 64g + L and bit 2g + 1 the
   --  fifth of element 64g + 32 + L, then a hundred and twenty-eight bytes
   --  of nibbles paired the way Q4_K pairs them.
   function Decode_Q5_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;
      Sub    : constant Natural := Within / 32;
      In_Sub : constant Natural := Within mod 32;
      Group  : constant Natural := Sub / 2;
      Upper  : constant Natural := Sub mod 2;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 176;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale   : constant Long_Float := Half_At (At_Block);
      Minimum : constant Long_Float := Half_At (At_Block + 2);
      Scales  : constant Interfaces.Unsigned_64 := At_Block + 4;

      Factor, Offset_Level : Natural;

      Packed : constant Natural :=
        Byte_At (At_Block + 48 + Interfaces.Unsigned_64 (Group) * 32
                 + Interfaces.Unsigned_64 (In_Sub));
      Fifth  : constant Natural :=
        (Byte_At (At_Block + 16 + Interfaces.Unsigned_64 (In_Sub))
         / (2 ** (2 * Group + Upper))) mod 2;
      Level  : constant Natural :=
        (if Upper = 0 then Packed mod 16 else Packed / 16) + 16 * Fifth;
   begin
      if Sub < 4 then
         Factor := Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) mod 64;
         Offset_Level :=
           Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 64;
      else
         Factor :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) - 4) / 64);
         Offset_Level :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) / 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) / 64);
      end if;

      return Scale * Long_Float (Factor) * Long_Float (Level)
        - Minimum * Long_Float (Offset_Level);
   end Decode_Q5_K;

   --  Decode one Q6_K element, independently of the engine.
   --
   --  Two hundred and fifty-six elements to two hundred and ten bytes: a
   --  hundred and twenty-eight of low nibbles, sixty-four of high pairs,
   --  sixteen signed scales and one half-precision factor. A half of the
   --  elements is walked as two sub-runs of four runs of sixteen, and the
   --  scale of a run is its own byte.
   function Decode_Q6_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 210;

      --  Undo the walk: which half, which sub-run, which of the four runs,
      --  and which of the sixteen elements.
      Half   : constant Natural := Within / 128;
      Rest   : constant Natural := Within mod 128;
      Run    : constant Natural := Rest / 32;
      Sub    : constant Natural := (Rest mod 32) / 16;
      In_Run : constant Natural := Within mod 16;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Factor : constant Integer :=
        (if Byte_At (At_Block + 192
                     + Interfaces.Unsigned_64 (Half * 8 + Sub + Run * 2))
              < 128
         then Byte_At (At_Block + 192
                       + Interfaces.Unsigned_64 (Half * 8 + Sub + Run * 2))
         else Byte_At (At_Block + 192
                       + Interfaces.Unsigned_64 (Half * 8 + Sub + Run * 2))
              - 256);

      Low_At  : constant Interfaces.Unsigned_64 :=
        At_Block + Interfaces.Unsigned_64 (Half) * 64
        + Interfaces.Unsigned_64 (Sub) * 16
        + Interfaces.Unsigned_64 (Run mod 2) * 32
        + Interfaces.Unsigned_64 (In_Run);
      High_At : constant Interfaces.Unsigned_64 :=
        At_Block + 128 + Interfaces.Unsigned_64 (Half) * 32
        + Interfaces.Unsigned_64 (Sub) * 16
        + Interfaces.Unsigned_64 (In_Run);

      Low  : constant Natural :=
        (if Run < 2 then Byte_At (Low_At) mod 16 else Byte_At (Low_At) / 16);
      High : constant Natural := (Byte_At (High_At) / (2 ** (2 * Run))) mod 4;

      Raw      : constant Natural := Byte_At (At_Block + 208)
        + 256 * Byte_At (At_Block + 209);
      Sign     : constant Long_Float :=
        (if Raw >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw / 1024) mod 32;
      Mantissa : constant Integer := Raw mod 1024;
      D        : Long_Float;
   begin
      if Exponent = 0 then
         D := Sign * Long_Float (Mantissa) * (2.0 ** (-24));
      elsif Exponent = 31 then
         D := 0.0;
      else
         D := Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
           * (2.0 ** (Exponent - 15));
      end if;

      return D * Long_Float (Factor) * Long_Float (Low + 16 * High - 32);
   end Decode_Q6_K;

   --  Decode one Q2_K element, independently of the engine.
   --
   --  The layout says: two hundred and fifty-six elements to a superblock of
   --  eighty-four bytes. Sixteen bytes of packed scales -- a four-bit factor
   --  and a four-bit offset sharing each byte, one pair per sixteen elements
   --  -- then sixty-four bytes of quants at two bits each, then the two
   --  half-precision factors. The sub-blocks are consumed in halves, then
   --  groups, then the upper half of each group, and one byte carries the
   --  same element of four groups.
   function Decode_Q2_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 84;

      --  Which sub-block holds this element, undoing the reader's walk.
      Half   : constant Natural := Within / 128;
      Rest   : constant Natural := Within mod 128;
      Group  : constant Natural := Rest / 32;
      Upper  : constant Natural := (Rest mod 32) / 16;
      In_Sub : constant Natural := Within mod 16;
      Sub    : constant Natural := Half * 8 + Group * 2 + Upper;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Packed  : constant Natural :=
        Byte_At (At_Block + Interfaces.Unsigned_64 (Sub));
      Factor  : constant Natural := Packed mod 16;
      Lowest  : constant Natural := Packed / 16;

      Quants  : constant Interfaces.Unsigned_64 := At_Block + 16;
      From    : constant Interfaces.Unsigned_64 :=
        Quants + Interfaces.Unsigned_64 (Half * 32 + Upper * 16)
        + Interfaces.Unsigned_64 (In_Sub);
      Level   : constant Natural :=
        (Byte_At (From) / (2 ** (2 * Group))) mod 4;

      D       : constant Long_Float := Half_At (At_Block + 80);
      Minimum : constant Long_Float := Half_At (At_Block + 82);
   begin
      return D * Long_Float (Factor) * Long_Float (Level)
        - Minimum * Long_Float (Lowest);
   end Decode_Q2_K;

   --  Decode one Q4_K element, independently of the engine.
   --
   --  The layout says: two hundred and fifty-six elements to a superblock of
   --  one hundred and forty-four bytes. A half-precision scale, a
   --  half-precision minimum, twelve bytes carrying a six-bit factor and a
   --  six-bit offset for each of eight sub-blocks, then one hundred and
   --  twenty-eight bytes of four-bit quants, two to a byte, in which
   --  sub-blocks 2g and 2g+1 share thirty-two bytes -- low nibbles first.
   --  A value is factor * scale * quant - offset * minimum.
   --
   --  Worked out from the layout rather than by calling the engine, like the
   --  Q8_0 decoder above and for the same reason: a fault made twice is a
   --  fault that agrees with itself.
   function Decode_Q4_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;
      Sub    : constant Natural := Within / 32;
      In_Sub : constant Natural := Within mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 144;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      --  A half-precision value, from its fields.
      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale   : constant Long_Float := Half_At (At_Block);
      Minimum : constant Long_Float := Half_At (At_Block + 2);
      Scales  : constant Interfaces.Unsigned_64 := At_Block + 4;

      Factor, Offset_Level : Natural;

      Quants : constant Interfaces.Unsigned_64 := At_Block + 16;
      Pair   : constant Interfaces.Unsigned_64 :=
        Quants + Interfaces.Unsigned_64 (Sub / 2) * 32
        + Interfaces.Unsigned_64 (In_Sub);
      Packed : constant Natural := Byte_At (Pair);
      Quant  : constant Natural :=
        (if Sub mod 2 = 0 then Packed mod 16 else Packed / 16);
   begin
      --  The first four sub-blocks keep six bits in a byte of their own; the
      --  last four take four bits from one byte and two from another.
      if Sub < 4 then
         Factor := Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) mod 64;
         Offset_Level :=
           Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 64;
      else
         Factor :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) - 4) / 64);
         Offset_Level :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) / 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) / 64);
      end if;

      return Scale * Long_Float (Factor) * Long_Float (Quant)
        - Minimum * Long_Float (Offset_Level);
   end Decode_Q4_K;

   --  The sixteen levels a non-linear four-bit quant takes. Written out
   --  again here: this implementation exists to be arrived at separately,
   --  and a table it borrowed would agree with its source by construction.
   IQ4_Levels : constant array (0 .. 15) of Integer :=
     [-127, -104, -83, -65, -49, -35, -22, -10,
         1,   13,  25,  38,  53,  69,  89, 113];

   --  One element of an IQ4_NL block: thirty-two elements, a half-precision
   --  scale, then sixteen bytes whose low nibbles are the first sixteen
   --  elements and whose high nibbles are the last sixteen. A nibble is an
   --  index into the levels, not a number.
   function Decode_IQ4_NL
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 18;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale  : constant Long_Float := Half_At (At_Block);
      Packed : constant Natural :=
        Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within mod 16));
      Level  : constant Natural :=
        (if Within < 16 then Packed mod 16 else Packed / 16);
   begin
      return Scale * Long_Float (IQ4_Levels (Level));
   end Decode_IQ4_NL;

   --  MXFP4's own sixteen: the E2M1 values at twice their size, so that a
   --  level is a whole number and the scale carries the halving.
   MX_Levels : constant array (0 .. 15) of Integer :=
     [0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12];

   --  One element of an MXFP4 block: thirty-two elements in seventeen bytes,
   --  one exponent byte and sixteen laid out as IQ4_NL lays its nibbles out.
   --
   --  The scale is a power of two and the byte is its exponent, biased by a
   --  hundred and twenty-seven -- and by one more here, because the levels
   --  above are twice the values the format names. That is the whole of what
   --  makes this format different from the one above it: no half to widen,
   --  no table of irregular levels, and a scale that cannot be anything but
   --  a power of two.
   function Decode_MXFP4
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 17;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Scale  : constant Long_Float :=
        2.0 ** (Byte_At (At_Block) - 128);
      Packed : constant Natural :=
        Byte_At (At_Block + 1 + Interfaces.Unsigned_64 (Within mod 16));
      Level  : constant Natural :=
        (if Within < 16 then Packed mod 16 else Packed / 16);
   begin
      return Scale * Long_Float (MX_Levels (Level));
   end Decode_MXFP4;

   --  One element of an IQ4_XS super-block: two hundred and fifty-six
   --  elements in eight sub-blocks of thirty-two, one half-precision scale
   --  for the block and six bits of scale for each sub-block, four of them
   --  in a nibble and two in a field of a sixteen-bit word, signed by an
   --  offset of thirty-two.
   function Decode_IQ4_XS
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;
      Sub    : constant Natural := Within / 32;
      In_Sub : constant Natural := Within mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 136;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale : constant Long_Float := Half_At (At_Block);

      Upper : constant Natural :=
        Byte_At (At_Block + 2) + 256 * Byte_At (At_Block + 3);

      Nibble : constant Natural :=
        (if Sub mod 2 = 0
         then Byte_At (At_Block + 4 + Interfaces.Unsigned_64 (Sub / 2)) mod 16
         else Byte_At (At_Block + 4 + Interfaces.Unsigned_64 (Sub / 2)) / 16);

      Level : constant Integer :=
        Nibble + 16 * ((Upper / (2 ** (2 * Sub))) mod 4);

      Packed : constant Natural :=
        Byte_At (At_Block + 8 + Interfaces.Unsigned_64 (Sub) * 16
                 + Interfaces.Unsigned_64 (In_Sub mod 16));
      Quant  : constant Natural :=
        (if In_Sub < 16 then Packed mod 16 else Packed / 16);
   begin
      return Scale * Long_Float (Level - 32)
        * Long_Float (IQ4_Levels (Quant));
   end Decode_IQ4_XS;

   --  The IQ3_S grid, carried here independently of the engine's copy: 512
   --  entries, each four small odd magnitudes as the bytes of a word, low
   --  byte first. A nine-bit index -- a qs byte and a high bit -- selects one.
   IQ3S_Grid_Ref : constant array (0 .. 511) of Interfaces.Unsigned_32 :=
     [
      16#01010101#, 16#01010103#, 16#01010105#, 16#0101010B#, 16#0101010F#, 16#01010301#,
      16#01010303#, 16#01010305#, 16#01010309#, 16#0101030D#, 16#01010501#, 16#01010503#,
      16#0101050B#, 16#01010707#, 16#01010901#, 16#01010905#, 16#0101090B#, 16#0101090F#,
      16#01010B03#, 16#01010B07#, 16#01010D01#, 16#01010D05#, 16#01010F03#, 16#01010F09#,
      16#01010F0F#, 16#01030101#, 16#01030103#, 16#01030105#, 16#01030109#, 16#01030301#,
      16#01030303#, 16#0103030B#, 16#01030501#, 16#01030507#, 16#0103050F#, 16#01030703#,
      16#0103070B#, 16#01030909#, 16#01030D03#, 16#01030D0B#, 16#01030F05#, 16#01050101#,
      16#01050103#, 16#0105010B#, 16#0105010F#, 16#01050301#, 16#01050307#, 16#0105030D#,
      16#01050503#, 16#0105050B#, 16#01050701#, 16#01050709#, 16#01050905#, 16#0105090B#,
      16#0105090F#, 16#01050B03#, 16#01050B07#, 16#01050F01#, 16#01050F07#, 16#01070107#,
      16#01070303#, 16#0107030B#, 16#01070501#, 16#01070505#, 16#01070703#, 16#01070707#,
      16#0107070D#, 16#01070909#, 16#01070B01#, 16#01070B05#, 16#01070D0F#, 16#01070F03#,
      16#01070F0B#, 16#01090101#, 16#01090307#, 16#0109030F#, 16#01090503#, 16#01090509#,
      16#01090705#, 16#01090901#, 16#01090907#, 16#01090B03#, 16#01090F01#, 16#010B0105#,
      16#010B0109#, 16#010B0501#, 16#010B0505#, 16#010B050D#, 16#010B0707#, 16#010B0903#,
      16#010B090B#, 16#010B090F#, 16#010B0D0D#, 16#010B0F07#, 16#010D010D#, 16#010D0303#,
      16#010D0307#, 16#010D0703#, 16#010D0B05#, 16#010D0F03#, 16#010F0101#, 16#010F0105#,
      16#010F0109#, 16#010F0501#, 16#010F0505#, 16#010F050D#, 16#010F0707#, 16#010F0B01#,
      16#010F0B09#, 16#03010101#, 16#03010103#, 16#03010105#, 16#03010109#, 16#03010301#,
      16#03010303#, 16#03010307#, 16#0301030B#, 16#0301030F#, 16#03010501#, 16#03010505#,
      16#03010703#, 16#03010709#, 16#0301070D#, 16#03010B09#, 16#03010B0D#, 16#03010D03#,
      16#03010F05#, 16#03030101#, 16#03030103#, 16#03030107#, 16#0303010D#, 16#03030301#,
      16#03030309#, 16#03030503#, 16#03030701#, 16#03030707#, 16#03030903#, 16#03030B01#,
      16#03030B05#, 16#03030F01#, 16#03030F0D#, 16#03050101#, 16#03050305#, 16#0305030B#,
      16#0305030F#, 16#03050501#, 16#03050509#, 16#03050705#, 16#03050901#, 16#03050907#,
      16#03050B0B#, 16#03050D01#, 16#03050F05#, 16#03070103#, 16#03070109#, 16#0307010F#,
      16#03070301#, 16#03070307#, 16#03070503#, 16#0307050F#, 16#03070701#, 16#03070709#,
      16#03070903#, 16#03070D05#, 16#03070F01#, 16#03090107#, 16#0309010B#, 16#03090305#,
      16#03090309#, 16#03090703#, 16#03090707#, 16#03090905#, 16#0309090D#, 16#03090B01#,
      16#03090B09#, 16#030B0103#, 16#030B0301#, 16#030B0307#, 16#030B0503#, 16#030B0701#,
      16#030B0705#, 16#030B0B03#, 16#030D0501#, 16#030D0509#, 16#030D050F#, 16#030D0909#,
      16#030D090D#, 16#030F0103#, 16#030F0107#, 16#030F0301#, 16#030F0305#, 16#030F0503#,
      16#030F070B#, 16#030F0903#, 16#030F0D05#, 16#030F0F01#, 16#05010101#, 16#05010103#,
      16#05010107#, 16#0501010B#, 16#0501010F#, 16#05010301#, 16#05010305#, 16#05010309#,
      16#0501030D#, 16#05010503#, 16#05010507#, 16#0501050F#, 16#05010701#, 16#05010705#,
      16#05010903#, 16#05010907#, 16#0501090B#, 16#05010B01#, 16#05010B05#, 16#05010D0F#,
      16#05010F01#, 16#05010F07#, 16#05010F0B#, 16#05030101#, 16#05030105#, 16#05030301#,
      16#05030307#, 16#0503030F#, 16#05030505#, 16#0503050B#, 16#05030703#, 16#05030709#,
      16#05030905#, 16#05030B03#, 16#05050103#, 16#05050109#, 16#0505010F#, 16#05050503#,
      16#05050507#, 16#05050701#, 16#0505070F#, 16#05050903#, 16#05050B07#, 16#05050B0F#,
      16#05050F03#, 16#05050F09#, 16#05070101#, 16#05070105#, 16#0507010B#, 16#05070303#,
      16#05070505#, 16#05070509#, 16#05070703#, 16#05070707#, 16#05070905#, 16#05070B01#,
      16#05070D0D#, 16#05090103#, 16#0509010F#, 16#05090501#, 16#05090507#, 16#05090705#,
      16#0509070B#, 16#05090903#, 16#05090F05#, 16#05090F0B#, 16#050B0109#, 16#050B0303#,
      16#050B0505#, 16#050B070F#, 16#050B0901#, 16#050B0B07#, 16#050B0F01#, 16#050D0101#,
      16#050D0105#, 16#050D010F#, 16#050D0503#, 16#050D0B0B#, 16#050D0D03#, 16#050F010B#,
      16#050F0303#, 16#050F050D#, 16#050F0701#, 16#050F0907#, 16#050F0B01#, 16#07010105#,
      16#07010303#, 16#07010307#, 16#0701030B#, 16#0701030F#, 16#07010505#, 16#07010703#,
      16#07010707#, 16#0701070B#, 16#07010905#, 16#07010909#, 16#0701090F#, 16#07010B03#,
      16#07010D07#, 16#07010F03#, 16#07030103#, 16#07030107#, 16#0703010B#, 16#07030309#,
      16#07030503#, 16#07030507#, 16#07030901#, 16#07030D01#, 16#07030F05#, 16#07030F0D#,
      16#07050101#, 16#07050305#, 16#07050501#, 16#07050705#, 16#07050709#, 16#07050B01#,
      16#07070103#, 16#07070301#, 16#07070309#, 16#07070503#, 16#07070507#, 16#0707050F#,
      16#07070701#, 16#07070903#, 16#07070907#, 16#0707090F#, 16#07070B0B#, 16#07070F07#,
      16#07090107#, 16#07090303#, 16#0709030D#, 16#07090505#, 16#07090703#, 16#07090B05#,
      16#07090D01#, 16#07090D09#, 16#070B0103#, 16#070B0301#, 16#070B0305#, 16#070B050B#,
      16#070B0705#, 16#070B0909#, 16#070B0B0D#, 16#070B0F07#, 16#070D030D#, 16#070D0903#,
      16#070F0103#, 16#070F0107#, 16#070F0501#, 16#070F0505#, 16#070F070B#, 16#09010101#,
      16#09010109#, 16#09010305#, 16#09010501#, 16#09010509#, 16#0901050F#, 16#09010705#,
      16#09010903#, 16#09010B01#, 16#09010F01#, 16#09030105#, 16#0903010F#, 16#09030303#,
      16#09030307#, 16#09030505#, 16#09030701#, 16#0903070B#, 16#09030907#, 16#09030B03#,
      16#09030B0B#, 16#09050103#, 16#09050107#, 16#09050301#, 16#0905030B#, 16#09050503#,
      16#09050707#, 16#09050901#, 16#09050B0F#, 16#09050D05#, 16#09050F01#, 16#09070109#,
      16#09070303#, 16#09070307#, 16#09070501#, 16#09070505#, 16#09070703#, 16#0907070B#,
      16#09090101#, 16#09090105#, 16#09090509#, 16#0909070F#, 16#09090901#, 16#09090F03#,
      16#090B010B#, 16#090B010F#, 16#090B0503#, 16#090B0D05#, 16#090D0307#, 16#090D0709#,
      16#090D0D01#, 16#090F0301#, 16#090F030B#, 16#090F0701#, 16#090F0907#, 16#090F0B03#,
      16#0B010105#, 16#0B010301#, 16#0B010309#, 16#0B010505#, 16#0B010901#, 16#0B010909#,
      16#0B01090F#, 16#0B010B05#, 16#0B010D0D#, 16#0B010F09#, 16#0B030103#, 16#0B030107#,
      16#0B03010B#, 16#0B030305#, 16#0B030503#, 16#0B030705#, 16#0B030F05#, 16#0B050101#,
      16#0B050303#, 16#0B050507#, 16#0B050701#, 16#0B05070D#, 16#0B050B07#, 16#0B070105#,
      16#0B07010F#, 16#0B070301#, 16#0B07050F#, 16#0B070909#, 16#0B070B03#, 16#0B070D0B#,
      16#0B070F07#, 16#0B090103#, 16#0B090109#, 16#0B090501#, 16#0B090705#, 16#0B09090D#,
      16#0B0B0305#, 16#0B0B050D#, 16#0B0B0B03#, 16#0B0B0B07#, 16#0B0D0905#, 16#0B0F0105#,
      16#0B0F0109#, 16#0B0F0505#, 16#0D010303#, 16#0D010307#, 16#0D01030B#, 16#0D010703#,
      16#0D010707#, 16#0D010D01#, 16#0D030101#, 16#0D030501#, 16#0D03050F#, 16#0D030D09#,
      16#0D050305#, 16#0D050709#, 16#0D050905#, 16#0D050B0B#, 16#0D050D05#, 16#0D050F01#,
      16#0D070101#, 16#0D070309#, 16#0D070503#, 16#0D070901#, 16#0D09050B#, 16#0D090907#,
      16#0D090D05#, 16#0D0B0101#, 16#0D0B0107#, 16#0D0B0709#, 16#0D0B0D01#, 16#0D0D010B#,
      16#0D0D0901#, 16#0D0F0303#, 16#0D0F0307#, 16#0F010101#, 16#0F010109#, 16#0F01010F#,
      16#0F010501#, 16#0F010505#, 16#0F01070D#, 16#0F010901#, 16#0F010B09#, 16#0F010D05#,
      16#0F030105#, 16#0F030303#, 16#0F030509#, 16#0F030907#, 16#0F03090B#, 16#0F050103#,
      16#0F050109#, 16#0F050301#, 16#0F05030D#, 16#0F050503#, 16#0F050701#, 16#0F050B03#,
      16#0F070105#, 16#0F070705#, 16#0F07070B#, 16#0F070B07#, 16#0F090103#, 16#0F09010B#,
      16#0F090307#, 16#0F090501#, 16#0F090B01#, 16#0F0B0505#, 16#0F0B0905#, 16#0F0D0105#,
      16#0F0D0703#, 16#0F0F0101#
];

   --  One element of an IQ3_S super-block: two hundred and fifty-six elements
   --  in eight sub-blocks of thirty-two, a half-precision block scale, and a
   --  four-bit sub-block scale that multiplies it by an odd number one to
   --  thirty-one. Each group of four elements reads a nine-bit grid index --
   --  a qs byte and a high bit out of a qh byte -- and takes its four
   --  magnitudes from the entry, each signed by a bit of a sign byte.
   function Decode_IQ3_S
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;
      Sub    : constant Natural := Within / 32;
      In_Sub : constant Natural := Within mod 32;
      L      : constant Natural := In_Sub / 8;
      Is_G2  : constant Boolean := (In_Sub mod 8) >= 4;
      G      : constant Natural := 2 * L + (if Is_G2 then 1 else 0);
      J      : constant Natural := In_Sub mod 4;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 110;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      D : constant Long_Float := Half_At (At_Block);

      Scale_Byte : constant Natural :=
        Byte_At (At_Block + 106 + Interfaces.Unsigned_64 (Sub / 2));
      Nibble : constant Natural :=
        (if Sub mod 2 = 0 then Scale_Byte mod 16 else Scale_Byte / 16);
      DB : constant Long_Float := D * Long_Float (1 + 2 * Nibble);

      QS   : constant Natural :=
        Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Sub * 8 + G));
      QH   : constant Natural :=
        Byte_At (At_Block + 66 + Interfaces.Unsigned_64 (Sub));
      High : constant Natural := (if (QH / (2 ** G)) mod 2 = 1 then 256 else 0);

      Entry_Word : constant Interfaces.Unsigned_32 :=
        IQ3S_Grid_Ref (QS + High);
      Magnitude  : constant Natural :=
        (Natural (Entry_Word) / (2 ** (8 * J))) mod 256;

      Sign_Byte : constant Natural :=
        Byte_At (At_Block + 74 + Interfaces.Unsigned_64 (Sub * 4 + L));
      Bit  : constant Natural := (if Is_G2 then J + 4 else J);
      Sign : constant Long_Float :=
        (if (Sign_Byte / (2 ** Bit)) mod 2 = 1 then -1.0 else 1.0);
   begin
      return DB * Long_Float (Magnitude) * Sign;
   end Decode_IQ3_S;

   --  Read a metadata integer, or a default.
   function Metadata
     (Source  : Containers.Container;
      Key     : String;
      Default : Natural) return Natural
   is
      Value  : Long_Long_Integer;
      Status : Model_Runner.Errors.Error_Info;
   begin
      Containers.Get_Integer (Source, Key, 0, 1_000_000, Value, Status);
      if Model_Runner.Errors.Is_Ok (Status) then
         return Natural (Value);
      else
         return Default;
      end if;
   end Metadata;

   ----------
   -- Load --
   ----------

   --  The prefix a model's metadata keys carry.
   function Prefix (Item : Model) return String
   is (case Item.Kind is
         when Llama     => "llama.",
         when Qwen2     => "qwen2.",
         when Qwen3     => "qwen3.",
         when Qwen3_MoE => "qwen3moe.",
         when GPT_OSS   => "gpt-oss.",
         when Gemma     => "gemma.",
         when Gemma2    => "gemma2.",
         when Gemma3    => "gemma3.",
         when Phi3      => "phi3.",
         when Falcon    => "falcon.",
         when Phi2      => "phi2.",
         when GPT2      => "gpt2.",
         when Bert      => "bert.",
         when Nomic_Bert => "nomic-bert.",
         when Jina_Bert_V2 => "jina-bert-v2.",
         when Qwen35 => "qwen35.",
         when Qwen35_MoE => "qwen35moe.",
         when Granite => "granite.",
         when Olmo2 => "olmo2.",
         when Glm4 => "glm4.",
         when Starcoder2 => "starcoder2.",
         when Granite_MoE => "granitemoe.",
         when Stablelm => "stablelm.",
         when Gptneox => "gptneox.",
         when Internlm2 => "internlm2.",
         when Baichuan => "baichuan.",
         when Mpt => "mpt.",
         when Chatglm => "chatglm.");

   --  The largest power of two not above a head count, which is where the
   --  slope ladder changes step.
   function Ladder (Heads : Natural) return Natural is
      Power : Natural := 1;
   begin
      while Power * 2 <= Heads loop
         Power := Power * 2;
      end loop;
      return Power;
   end Ladder;

   procedure Load
     (Item   : in out Model;
      Source : Containers.Container;
      Image  : B.Byte_Array;
      Ok     : out Boolean;
      Asked  : access Ada.Strings.Unbounded.Unbounded_String := null)
   is
      use type Model_Runner.GGUF.Tensor_Type;

      --  Read a two-dimensional tensor. GGUF dimension 1 is contiguous and is
      --  the input width; the remaining extent is the output width.
      --  Every lookup goes through one of the two readers below, so
      --  recording the name here records every name this asked for.
      procedure Note (Name : String) is
      begin
         if Asked /= null then
            Ada.Strings.Unbounded.Append (Asked.all, Name & Character'Val (10));
         end if;
      end Note;

      function Read_Matrix (Name : String; Present : out Boolean)
        return Matrix_Access
      is
         Index : constant Natural := Containers.Find_Tensor (Source, Name);
      begin
         Note (Name);
         Present := False;

         if Index = 0
           or else Containers.Tensor_Format (Source, Index)
                   not in Model_Runner.GGUF.Type_F32
                        | Model_Runner.GGUF.Type_Q8_0
                        | Model_Runner.GGUF.Type_Q4_K
                        | Model_Runner.GGUF.Type_Q2_K
                        | Model_Runner.GGUF.Type_BF16
                        | Model_Runner.GGUF.Type_Q4_0
                        | Model_Runner.GGUF.Type_Q4_1
                        | Model_Runner.GGUF.Type_F16
                        | Model_Runner.GGUF.Type_Q5_0
                        | Model_Runner.GGUF.Type_Q5_1
                        | Model_Runner.GGUF.Type_Q6_K
                        | Model_Runner.GGUF.Type_Q5_K
                        | Model_Runner.GGUF.Type_Q3_K
                        | Model_Runner.GGUF.Type_IQ4_NL
                        | Model_Runner.GGUF.Type_IQ4_XS
                        | Model_Runner.GGUF.Type_IQ3_S
                        | Model_Runner.GGUF.Type_MXFP4
         then
            return null;
         end if;

         declare
            Columns : constant Natural :=
              Natural (Containers.Tensor_Dimension (Source, Index, 1));
            Rows    : Natural := 1;
            Offset  : constant Interfaces.Unsigned_64 :=
              Containers.Tensor_Offset (Source, Index);
            Result  : Matrix_Access;
         begin
            for Axis in 2 .. Containers.Tensor_Rank (Source, Index) loop
               Rows :=
                 Rows * Natural (Containers.Tensor_Dimension (Source, Index, Axis));
            end loop;

            Result := new Matrix (0 .. Rows - 1, 0 .. Columns - 1);

            for Row in 0 .. Rows - 1 loop
               for Column in 0 .. Columns - 1 loop
                  if Containers.Tensor_Format (Source, Index)
                       = Model_Runner.GGUF.Type_Q8_0
                  then
                     Result (Row, Column) :=
                       Decode_Q8_0
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 34
                            * Interfaces.Unsigned_64 (Columns / 32),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          in Model_Runner.GGUF.Type_Q5_0
                           | Model_Runner.GGUF.Type_Q5_1
                  then
                     declare
                        Centred : constant Boolean :=
                          Containers.Tensor_Format (Source, Index)
                            = Model_Runner.GGUF.Type_Q5_0;
                        Width   : constant Interfaces.Unsigned_64 :=
                          (if Centred then 22 else 24);
                     begin
                        Result (Row, Column) :=
                          Decode_Five_Bit
                            (Image,
                             Offset
                             + Interfaces.Unsigned_64 (Row) * Width
                               * Interfaces.Unsigned_64 (Columns / 32),
                             Column, Centred);
                     end;
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q3_K
                  then
                     Result (Row, Column) :=
                       Decode_Q3_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 110
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q5_K
                  then
                     Result (Row, Column) :=
                       Decode_Q5_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 176
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q6_K
                  then
                     Result (Row, Column) :=
                       Decode_Q6_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 210
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_F16
                  then
                     Result (Row, Column) :=
                       Decode_Half
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row * Columns + Column)
                            * 2);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_BF16
                  then
                     Result (Row, Column) :=
                       Decode_BF16
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row * Columns + Column)
                            * 2);
                  elsif Containers.Tensor_Format (Source, Index)
                          in Model_Runner.GGUF.Type_Q4_0
                           | Model_Runner.GGUF.Type_Q4_1
                  then
                     declare
                        Centred : constant Boolean :=
                          Containers.Tensor_Format (Source, Index)
                            = Model_Runner.GGUF.Type_Q4_0;
                        Width   : constant Interfaces.Unsigned_64 :=
                          (if Centred then 18 else 20);
                     begin
                        Result (Row, Column) :=
                          Decode_Four_Bit
                            (Image,
                             Offset
                             + Interfaces.Unsigned_64 (Row) * Width
                               * Interfaces.Unsigned_64 (Columns / 32),
                             Column, Centred);
                     end;
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q2_K
                  then
                     Result (Row, Column) :=
                       Decode_Q2_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 84
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q4_K
                  then
                     Result (Row, Column) :=
                       Decode_Q4_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 144
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_IQ4_NL
                  then
                     Result (Row, Column) :=
                       Decode_IQ4_NL
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 18
                            * Interfaces.Unsigned_64 (Columns / 32),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_IQ4_XS
                  then
                     Result (Row, Column) :=
                       Decode_IQ4_XS
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 136
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_IQ3_S
                  then
                     Result (Row, Column) :=
                       Decode_IQ3_S
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 110
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_MXFP4
                  then
                     Result (Row, Column) :=
                       Decode_MXFP4
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 17
                            * Interfaces.Unsigned_64 (Columns / 32),
                          Column);
                  else
                     Result (Row, Column) :=
                       Decode_Float
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row * Columns + Column) * 4);
                  end if;
               end loop;
            end loop;

            Present := True;
            return Result;
         end;
      end Read_Matrix;

      --  Read a one-dimensional tensor.
      --  One projection out of a tensor that holds several.
      --
      --  Phi3 writes its queries, keys and values as one tensor and its gate
      --  and up projection as another. This reads the whole thing and takes
      --  the rows it wants, which is the slow and obvious way -- the engine
      --  makes a view at an offset instead, and the two agreeing is the
      --  point of doing it differently.
      --
      --  @param First Row the part starts at.
      --  @param Count Rows the part holds.
      function Read_Part
        (Name : String; First, Count : Natural; Present : out Boolean)
        return Matrix_Access
      is
         Whole : Matrix_Access := Read_Matrix (Name, Present);
      begin
         if not Present or else Whole = null then
            Present := False;
            return null;
         end if;

         if Whole'Last (1) < First + Count - 1 then
            Free_Matrix (Whole);
            Present := False;
            return null;
         end if;

         declare
            Part : constant Matrix_Access :=
              new Matrix (0 .. Count - 1, Whole'Range (2));
         begin
            for Row in 0 .. Count - 1 loop
               for Column in Whole'Range (2) loop
                  Part (Row, Column) := Whole (First + Row, Column);
               end loop;
            end loop;

            Free_Matrix (Whole);
            Present := True;
            return Part;
         end;
      end Read_Part;

      --  A run of elements of a one-dimensional tensor, for the
      --  architectures whose fused projections carry a fused bias. Written
      --  here rather than shared with the engine's own splitting, for the
      --  reason the whole of this file exists.
      function Read_Vector_Part
        (Name : String; First, Count : Natural; Present : out Boolean)
        return Vector_Access;

      function Read_Vector (Name : String; Present : out Boolean)
        return Vector_Access
      is
         Index : constant Natural := Containers.Find_Tensor (Source, Name);
      begin
         Note (Name);
         Present := False;

         if Index = 0
           or else Containers.Tensor_Format (Source, Index)
                   /= Model_Runner.GGUF.Type_F32
         then
            return null;
         end if;

         declare
            Width  : constant Natural :=
              Natural (Containers.Tensor_Dimension (Source, Index, 1));
            Offset : constant Interfaces.Unsigned_64 :=
              Containers.Tensor_Offset (Source, Index);
            Result : constant Vector_Access := new Real_Vector (0 .. Width - 1);
         begin
            for Position in 0 .. Width - 1 loop
               Result (Position) :=
                 Decode_Float
                   (Image, Offset + Interfaces.Unsigned_64 (Position) * 4);
            end loop;
            Present := True;
            return Result;
         end;
      end Read_Vector;

      function Read_Vector_Part
        (Name : String; First, Count : Natural; Present : out Boolean)
        return Vector_Access
      is
         Whole : Vector_Access := Read_Vector (Name, Present);
      begin
         if not Present or else Whole = null then
            Present := False;
            return null;
         end if;

         if Whole'Length < First + Count then
            Free_Vector (Whole);
            Present := False;
            return null;
         end if;

         declare
            Part : constant Vector_Access :=
              new Real_Vector (0 .. Count - 1);
         begin
            for Index in Part'Range loop
               Part (Index) := Whole (Whole'First + First + Index);
            end loop;
            Free_Vector (Whole);
            Present := True;
            return Part;
         end;
      end Read_Vector_Part;

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Digits_Text : constant String := Natural'Image (Index);
      begin
         return "blk." & Digits_Text (Digits_Text'First + 1 .. Digits_Text'Last)
           & "." & Suffix;
      end Layer_Name;

      Present : Boolean;
   begin
      Close (Item);
      Ok := False;

      --  The architectures this reference knows, which must be the ones the
      --  engine knows: a conformance run compares two implementations of
      --  the same function, and a reference that computes a different one
      --  reports the engine as wrong. Qwen2 was added to the engine and not
      --  to here, so its arithmetic had nothing independent to be checked
      --  against at all.
      declare
         Named : constant String :=
           Containers.String_Value (Source, "general.architecture");
      begin
         if Named = "llama" then
            Item.Kind := Llama;
         elsif Named = "qwen2" then
            Item.Kind := Qwen2;
         elsif Named = "qwen3" then
            Item.Kind := Qwen3;
         elsif Named = "qwen3moe" then
            Item.Kind := Qwen3_MoE;
         elsif Named = "gpt-oss" then
            Item.Kind := GPT_OSS;
         elsif Named = "gemma" then
            Item.Kind := Gemma;
         elsif Named = "gemma2" then
            Item.Kind := Gemma2;
         elsif Named = "gemma3" then
            Item.Kind := Gemma3;
         elsif Named = "phi3" then
            Item.Kind := Phi3;
         elsif Named = "falcon" then
            Item.Kind := Falcon;
         elsif Named = "phi2" then
            Item.Kind := Phi2;
         elsif Named = "gpt2" then
            Item.Kind := GPT2;
         elsif Named = "bert" then
            Item.Kind := Bert;
         elsif Named = "nomic-bert" then
            Item.Kind := Nomic_Bert;
         elsif Named = "jina-bert-v2" then
            Item.Kind := Jina_Bert_V2;

            --  Not read from the file. No published jina-bert-v2 states a
            --  bias, and the architecture carries eight.
            Item.Max_Bias := 8.0;
         elsif Named = "qwen35" then
            Item.Kind := Qwen35;
         elsif Named = "qwen35moe" then
            Item.Kind := Qwen35_MoE;
         elsif Named = "granite" then
            Item.Kind := Granite;
         elsif Named = "olmo2" then
            Item.Kind := Olmo2;
         elsif Named = "glm4" then
            Item.Kind := Glm4;
         elsif Named = "starcoder2" then
            Item.Kind := Starcoder2;
         elsif Named = "granitemoe" then
            Item.Kind := Granite_MoE;
         elsif Named = "stablelm" then
            Item.Kind := Stablelm;
         elsif Named = "gptneox" then
            Item.Kind := Gptneox;
         elsif Named = "internlm2" then
            Item.Kind := Internlm2;
         elsif Named = "baichuan" then
            Item.Kind := Baichuan;
         elsif Named = "mpt" then
            Item.Kind := Mpt;

            --  Not read from the file for MPT either: the architecture
            --  carries eight, and the fixture states its own to prove it.
            Item.Max_Bias := 8.0;
         elsif Named = "chatglm" then
            Item.Kind := Chatglm;
         else
            return;
         end if;
      end;

      Item.Embedding := Metadata (Source, Prefix (Item) & "embedding_length", 0);
      Item.Feed_Forward := Metadata (Source, Prefix (Item) & "feed_forward_length", 0);
      Item.Layers := Metadata (Source, Prefix (Item) & "block_count", 0);
      Item.Heads := Metadata (Source, Prefix (Item) & "attention.head_count", 0);
      Item.KV_Heads :=
        Metadata (Source, Prefix (Item) & "attention.head_count_kv", Item.Heads);
      Item.Context := Metadata (Source, Prefix (Item) & "context_length", 0);

      if Item.Embedding = 0 or else Item.Layers = 0 or else Item.Heads = 0
        or else Item.KV_Heads = 0
        or else Item.Heads mod Item.KV_Heads /= 0
      then
         return;
      end if;

      --  The key width the file states, or the embedding divided by the
      --  head count when it states none; and the value width beside it.
      Item.Head_Size :=
        Metadata
          (Source, Prefix (Item) & "attention.key_length",
           Item.Embedding / Item.Heads);
      Item.Value_Size :=
        Metadata
          (Source, Prefix (Item) & "attention.value_length", Item.Head_Size);

      --  A window at least as wide as the context sees everything the
      --  context holds, which is no window at all. The engine folds that
      --  case away too; here it is folded for the same reason and not
      --  because the engine does.
      Item.Window :=
        Metadata (Source, Prefix (Item) & "attention.sliding_window", 0);

      --  Read as floats, because that is what they are: a bound on a score
      --  rather than a count of anything.
      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Containers.Get_Float
           (Source, Prefix (Item) & "rope.local_freq_base",
            1.0, 1.0E12, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Local_Base := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "attn_logit_softcapping",
            1.0, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Attention_Cap := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "final_logit_softcapping",
            1.0, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Logit_Cap := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "embedding_scale",
            1.0E-6, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Embedding_Mul := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "residual_scale",
            1.0E-6, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Residual_Mul := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "attention.scale",
            1.0E-6, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Attention_Mul := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "logit_scale",
            1.0E-6, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Logit_Mul := Long_Float (Value);
         end if;
      end;

      --  The period of the window pattern, which the architecture states by
      --  being what it is rather than by a key: two for Gemma2 and six for
      --  Gemma3.
      Item.Window_Every :=
        (case Item.Kind is
            when Gemma2 | GPT_OSS => 2,
            when Gemma3 => 6,
            when others => 0);

      --  GPT_OSS turns its windowed layers on a base of its own, stated
      --  under a name of its own: Gemma3 calls it rope.local_freq_base and
      --  this calls it rope.freq_base_swa, and they mean the same thing.
      if Item.Kind = GPT_OSS then
         declare
            Value  : Model_Runner.Numerics.Wide_Real;
            Status : Model_Runner.Errors.Error_Info;
         begin
            Containers.Get_Float
              (Source, Prefix (Item) & "rope.freq_base_swa",
               1.0, 1.0E12, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status) then
               Item.Local_Base := Long_Float (Value);
            end if;
         end;
      end if;

      Item.Experts := Metadata (Source, Prefix (Item) & "expert_count", 0);
      Item.Experts_Used :=
        Metadata (Source, Prefix (Item) & "expert_used_count", 0);
      Item.Expert_Feed :=
        Metadata
          (Source, Prefix (Item) & "expert_feed_forward_length",
           Item.Feed_Forward);
      Item.Shared_Feed :=
        Metadata
          (Source, Prefix (Item) & "expert_shared_feed_forward_length", 0);

      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Containers.Get_Float
           (Source, Prefix (Item) & "expert_weights_scale",
            1.0E-6, 1.0E6, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Expert_Scale := Long_Float (Value);
         end if;
      end;

      --  GPT-NeoX's parallel residual, on by default where the file says
      --  nothing, as its published files leave it.
      if Item.Kind = Gptneox then
         Item.Parallel := True;
         declare
            Flag   : Boolean;
            Status : Model_Runner.Errors.Error_Info;
         begin
            Containers.Get_Boolean
              (Source, Prefix (Item) & "use_parallel_residual", Flag, Status);
            if Model_Runner.Errors.Is_Ok (Status) then
               Item.Parallel := Flag;
            end if;
         end;
      end if;

      --  The hybrid's shape, all of it required but the interval, which
      --  the architecture puts at four when the file is silent; and the
      --  blocks past the stack, which the block count includes and the
      --  stack does not run. A hybrid's gate beside each attention head
      --  has the head's width and scales the head's blend, so its value
      --  width is its head size and a file saying otherwise describes no
      --  model of this kind.
      if Item.Kind in Qwen35 | Qwen35_MoE then
         Item.Linear_Every :=
           Metadata (Source, Prefix (Item) & "full_attention_interval", 4);
         Item.State_Size :=
           Metadata (Source, Prefix (Item) & "ssm.state_size", 0);
         Item.Key_Heads :=
           Metadata (Source, Prefix (Item) & "ssm.group_count", 0);
         Item.Value_Heads :=
           Metadata (Source, Prefix (Item) & "ssm.time_step_rank", 0);
         Item.Conv_Taps :=
           Metadata (Source, Prefix (Item) & "ssm.conv_kernel", 0);
         Item.Next_Layers :=
           Metadata (Source, Prefix (Item) & "nextn_predict_layers", 0);

         if Item.Linear_Every = 0 or else Item.State_Size = 0
           or else Item.Key_Heads = 0 or else Item.Value_Heads = 0
           or else Item.Value_Heads mod Item.Key_Heads /= 0
           or else Item.Conv_Taps < 2
           or else Item.Next_Layers >= Item.Layers
           or else Item.Value_Size /= Item.Head_Size
         then
            return;
         end if;

         Item.Layers := Item.Layers - Item.Next_Layers;
      end if;
      if Item.Window >= Item.Context then
         Item.Window := 0;
      end if;
      --  How wide the rotation is. An absent key means the head's whole
      --  width for the architectures that rotate -- and nothing at all for
      --  the one that does not, which states no such key because it is told
      --  where a token is by a fall-off in its attention scores. Read the
      --  other way it rotates a model that never rotates, which is the same
      --  trap bert's absent key was and is why the fixture states nothing
      --  here either.
      Item.Rotary :=
        (if Item.Kind in Jina_Bert_V2 | Mpt then 0
         else Metadata
                (Source, Prefix (Item) & "rope.dimension_count",
                 Item.Head_Size));

      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         --  Bert names the key after the normalization it belongs to,
         --  which is not the root-mean-square one. Read from the file's own
         --  key rather than from the other with a fallback, because this
         --  implementation is here to disagree with the engine when the
         --  engine is wrong, and inheriting its fallback would be one
         --  fewer thing that can.
         Containers.Get_Float
           (Source,
            Prefix (Item)
            & (if Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2 | Starcoder2 | Stablelm | Gptneox | Mpt
               then "attention.layer_norm_epsilon"
               else "attention.layer_norm_rms_epsilon"),
            0.0, 1.0, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Epsilon := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "rope.freq_base", 1.0, 1.0E12, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Rope_Base := Long_Float (Value);
         end if;

         --  The alibi bias, where the file states its own rather than
         --  leaving the eight the architecture defaults to.
         if Item.Kind in Jina_Bert_V2 | Mpt then
            Containers.Get_Float
              (Source, Prefix (Item) & "attention.max_alibi_bias",
               0.0, 1.0E6, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status) then
               Item.Max_Bias := Long_Float (Value);
            end if;
         end if;

         --  MPT's clamp on the queries, keys and values, where the file
         --  states one.
         if Item.Kind = Mpt then
            Containers.Get_Float
              (Source, Prefix (Item) & "attention.clamp_kqv",
               0.0, 1.0E6, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status) then
               Item.Clip_QKV := Long_Float (Value);
            end if;
         end if;

         --  How the rotation is stretched, read from the same keys the
         --  method is described by.
         declare
            Named : constant String :=
              Containers.String_Value
                (Source, Prefix (Item) & "rope.scaling.type");
         begin
            if Named = "yarn" then
               Item.Stretch := Yarn;
            elsif Named = "linear" then
               Item.Stretch := Linear;
            end if;

            Containers.Get_Float
              (Source, Prefix (Item) & "rope.scaling.factor",
               0.0, 1.0E6, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status)
              and then Long_Float (Value) > 0.0
            then
               Item.Frequency := 1.0 / Long_Float (Value);
               if Named = "" and then Long_Float (Value) /= 1.0 then
                  Item.Stretch := Linear;
               end if;
            end if;

            Containers.Get_Float
              (Source, Prefix (Item) & "rope.scaling.attn_factor",
               0.0, 1.0E3, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status) then
               Item.Attenuation := Long_Float (Value);
            end if;

            Containers.Get_Float
              (Source, Prefix (Item) & "rope.scaling.beta_fast",
               0.0, 1.0E6, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status)
              and then Long_Float (Value) > 0.0
            then
               Item.Beta_Fast := Long_Float (Value);
            end if;

            Containers.Get_Float
              (Source, Prefix (Item) & "rope.scaling.beta_slow",
               0.0, 1.0E6, Value, Status);
            if Model_Runner.Errors.Is_Ok (Status)
              and then Long_Float (Value) > 0.0
            then
               Item.Beta_Slow := Long_Float (Value);
            end if;
         end;
      end;

      Item.Trained :=
        Metadata
          (Source, Prefix (Item) & "rope.scaling.original_context_length",
           Item.Context);

      Item.Embeddings := Read_Matrix ("token_embd.weight", Present);
      if not Present then
         return;
      end if;
      Item.Words := Item.Embeddings'Length (1);

      --  The table of positions, for the architecture that learns where a
      --  token is rather than rotating for it.
      if Item.Kind in GPT2 | Bert then
         Item.Positions := Read_Matrix ("position_embd.weight", Present);
         if not Present then
            return;
         end if;
      end if;

      --  Bert's segment table and the normalization over the sum of the
      --  three embeddings.
      if Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
         Item.Segments := Read_Matrix ("token_types.weight", Present);
         if not Present then
            return;
         end if;

         Item.Embedding_Norm := Read_Vector ("token_embd_norm.weight", Present);
         if not Present then
            return;
         end if;

         Item.Embedding_Norm_Bias :=
           Read_Vector ("token_embd_norm.bias", Present);
         if not Present then
            return;
         end if;
      end if;

      --  Every architecture but Bert normalizes between the last layer and
      --  whatever reads it. Bert's last layer normalized what it produced.
      if Item.Kind not in Bert | Nomic_Bert | Jina_Bert_V2 then
         Item.Output_Norm := Read_Vector ("output_norm.weight", Present);
         if Present and then Item.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox then
            Item.Output_Norm_Bias :=
              Read_Vector ("output_norm.bias", Present);
         end if;
         if not Present then
            return;
         end if;
      end if;

      --  The per-dimension divisors, when the file carries them. Absent is
      --  not a failure: most files have none.
      declare
         Ignored : Boolean;
      begin
         Item.Rope_Factors := Read_Vector ("rope_freqs.weight", Ignored);
      end;

      Item.Output := Read_Matrix ("output.weight", Present);
      if not Present and then Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
         --  No projection and nothing to tie one to. What this model
         --  produces is states, and the comparison against the engine is of
         --  those rather than of logits.
         Item.Output := null;
      elsif not Present then
         --  A tied model reuses the embedding table as the output projection.
         Item.Output := Item.Embeddings;
      elsif Item.Kind = Phi2 then
         Item.Output_Bias := Read_Vector ("output.bias", Present);
         if not Present then
            return;
         end if;
      end if;

      Item.Blocks := new Layer_Array (0 .. Item.Layers + Item.Next_Layers - 1);

      for Index in Item.Blocks'Range loop
         declare
            Current : Layer renames Item.Blocks (Index);

            --  Whether this block of a hybrid keeps a state: every
            --  Linear_Every-th attends in full, counting from one, and
            --  the blocks past the stack attend in full whatever their
            --  number.
            Is_Linear : constant Boolean :=
              Item.Kind in Qwen35 | Qwen35_MoE
              and then Index < Item.Layers
              and then (Index + 1) mod Item.Linear_Every /= 0;
         begin
            Current.Linear := Is_Linear;
            --  Every architecture but Bert normalizes on the way into the
            --  block; Bert's two normalizations are on the way out of its
            --  two sublayers and are read below.
            if Item.Kind not in Bert | Nomic_Bert | Jina_Bert_V2 | Olmo2 then
               Current.Attention_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_norm.weight"), Present);
               if not Present then
                  return;
               end if;
            end if;

            if Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
               Current.Post_Attention_Norm :=
                 Read_Vector
                   (Layer_Name (Index, "attn_output_norm.weight"), Present);
               if not Present then
                  return;
               end if;

               Current.Post_Attention_Norm_Bias :=
                 Read_Vector
                   (Layer_Name (Index, "attn_output_norm.bias"), Present);
               if not Present then
                  return;
               end if;

               Current.Post_Feed_Norm :=
                 Read_Vector
                   (Layer_Name (Index, "layer_output_norm.weight"), Present);
               if not Present then
                  return;
               end if;

               Current.Post_Feed_Norm_Bias :=
                 Read_Vector
                   (Layer_Name (Index, "layer_output_norm.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            --  Gemma2's two extra normalizations, required where the
            --  architecture states them.
            if Item.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox then
               Current.Attention_Norm_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_norm.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            if Item.Kind in Gemma2 | Gemma3 | Olmo2 | Glm4 then
               Current.Post_Attention_Norm :=
                 Read_Vector
                   (Layer_Name (Index, "post_attention_norm.weight"),
                    Present);
               if not Present then
                  return;
               end if;

               Current.Post_Feed_Norm :=
                 Read_Vector
                   (Layer_Name (Index, "post_ffw_norm.weight"), Present);
               if not Present then
                  return;
               end if;
            end if;

            --  A linear block's own tensors, and none of attention's.
            if Is_Linear then
               Current.Mix :=
                 Read_Matrix (Layer_Name (Index, "attn_qkv.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.Z_Gate :=
                 Read_Matrix (Layer_Name (Index, "attn_gate.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.Alpha :=
                 Read_Matrix (Layer_Name (Index, "ssm_alpha.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.Beta :=
                 Read_Matrix (Layer_Name (Index, "ssm_beta.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.A_Log :=
                 Read_Vector (Layer_Name (Index, "ssm_a"), Present);
               if not Present then
                  return;
               end if;
               Current.DT_Bias :=
                 Read_Vector (Layer_Name (Index, "ssm_dt.bias"), Present);
               if not Present then
                  return;
               end if;
               Current.Conv :=
                 Read_Matrix (Layer_Name (Index, "ssm_conv1d.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.State_Norm :=
                 Read_Vector (Layer_Name (Index, "ssm_norm.weight"), Present);
               if not Present then
                  return;
               end if;
               Current.Linear_Out :=
                 Read_Matrix (Layer_Name (Index, "ssm_out.weight"), Present);
               if not Present then
                  return;
               end if;

               --  The shapes the file has to have, checked here because
               --  the loops below index by them: the projection over the
               --  three at once, the gate over the values, the decay and
               --  the rate a value head, the taps a channel.
               declare
                  Keys_Wide : constant Natural :=
                    Item.Key_Heads * Item.State_Size;
                  Vals_Wide : constant Natural :=
                    Item.Value_Heads * Item.State_Size;
                  Mix_Wide  : constant Natural := 2 * Keys_Wide + Vals_Wide;
               begin
                  if Current.Mix'Length (1) /= Mix_Wide
                    or else Current.Mix'Length (2) /= Item.Embedding
                    or else Current.Z_Gate'Length (1) /= Vals_Wide
                    or else Current.Alpha'Length (1) /= Item.Value_Heads
                    or else Current.Beta'Length (1) /= Item.Value_Heads
                    or else Current.A_Log'Length /= Item.Value_Heads
                    or else Current.DT_Bias'Length /= Item.Value_Heads
                    or else Current.Conv'Length (1) /= Mix_Wide
                    or else Current.Conv'Length (2) /= Item.Conv_Taps
                    or else Current.State_Norm'Length /= Item.State_Size
                    or else Current.Linear_Out'Length (1) /= Item.Embedding
                    or else Current.Linear_Out'Length (2) /= Vals_Wide
                  then
                     return;
                  end if;
               end;
            end if;

            --  Phi3's three attention projections come out of one tensor,
            --  in the order the rows are written: queries, keys, values.
            if Is_Linear then
               Present := True;
            elsif Item.Kind in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Mpt
              | Chatglm
            then
               Current.Query :=
                 Read_Part (Layer_Name (Index, "attn_qkv.weight"),
                            0, Item.Heads * Item.Head_Size, Present);
            else
               Current.Query :=
                 Read_Matrix (Layer_Name (Index, "attn_q.weight"), Present);
            end if;
            if not Present then
               return;
            end if;

            if Is_Linear then
               Present := True;
            elsif Item.Kind in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Mpt
              | Chatglm
            then
               Current.Key :=
                 Read_Part (Layer_Name (Index, "attn_qkv.weight"),
                            Item.Heads * Item.Head_Size,
                            Item.KV_Heads * Item.Head_Size, Present);
            else
               Current.Key :=
                 Read_Matrix (Layer_Name (Index, "attn_k.weight"), Present);
            end if;
            if not Present then
               return;
            end if;

            if Is_Linear then
               Present := True;
            elsif Item.Kind in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Mpt
              | Chatglm
            then
               Current.Value :=
                 Read_Part (Layer_Name (Index, "attn_qkv.weight"),
                            (Item.Heads + Item.KV_Heads) * Item.Head_Size,
                            Item.KV_Heads * Item.Value_Size, Present);
            else
               Current.Value :=
                 Read_Matrix (Layer_Name (Index, "attn_v.weight"), Present);
            end if;
            if not Present then
               return;
            end if;

            --  The projection biases, required for the architecture that
            --  has them and absent from the one that does not.
            --  Phi2 carries the same three biases in one vector, taken at
            --  the offsets its matrices are taken at.
            if Item.Kind in Phi2 | GPT2 | Gptneox | Chatglm then
               Current.Query_Bias :=
                 Read_Vector_Part
                   (Layer_Name (Index, "attn_qkv.bias"),
                    0, Item.Heads * Item.Head_Size, Present);
               if not Present then
                  return;
               end if;

               Current.Key_Bias :=
                 Read_Vector_Part
                   (Layer_Name (Index, "attn_qkv.bias"),
                    Item.Heads * Item.Head_Size,
                    Item.KV_Heads * Item.Head_Size, Present);
               if not Present then
                  return;
               end if;

               Current.Value_Bias :=
                 Read_Vector_Part
                   (Layer_Name (Index, "attn_qkv.bias"),
                    (Item.Heads + Item.KV_Heads) * Item.Head_Size,
                    Item.KV_Heads * Item.Value_Size, Present);
               if not Present then
                  return;
               end if;
            end if;

            --  Bert biases the same three and writes them apart, as
            --  Qwen2 does.
            if Item.Kind in Qwen2 | Bert | Jina_Bert_V2 | Glm4 | Starcoder2 | Stablelm
            then
               Current.Query_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_q.bias"), Present);
               if not Present then
                  return;
               end if;

               Current.Key_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_k.bias"), Present);
               if not Present then
                  return;
               end if;

               Current.Value_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_v.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            --  Gemma3 normalizes query and key heads as Qwen3 does. The
            --  application below is keyed on the gain being there rather
            --  than on the architecture, so loading it is all that this
            --  needs -- which is why the engine and this disagreed by two
            --  logits in three when only the engine loaded it.
            if Item.Kind in Qwen3 | Qwen3_MoE | Gemma3
              or else (Item.Kind in Qwen35 | Qwen35_MoE and then not Is_Linear)
            then
               Current.Query_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_q_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;

               Current.Key_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_k_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;
            end if;

            --  The code variant of jina-bert-v2, told from the text one by
            --  its tensors: six of them, and all six once any is there.
            if Item.Kind = Jina_Bert_V2
              and then Containers.Find_Tensor
                         (Source, Layer_Name (Index, "attn_norm_2.weight"))
                       /= 0
            then
               Current.Query_Whole_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_q_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Query_Whole_Norm_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_q_norm.bias"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Key_Whole_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_k_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Key_Whole_Norm_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_k_norm.bias"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Second_Attention_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_norm_2.weight"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Second_Attention_Norm_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_norm_2.bias"),
                              Present);
               if not Present then
                  return;
               end if;

            elsif Item.Kind = Olmo2 then
               --  OLMo2 normalizes the whole of the query and key
               --  projections, root-mean-square and without a shift.
               Current.Query_Whole_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_q_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;
               Current.Key_Whole_Norm :=
                 Read_Vector (Layer_Name (Index, "attn_k_norm.weight"),
                              Present);
               if not Present then
                  return;
               end if;
            end if;

            if Is_Linear then
               Present := True;
            else
               Current.Attention_Out :=
                 Read_Matrix (Layer_Name (Index, "attn_output.weight"),
                              Present);
            end if;
            if not Present then
               return;
            end if;

            if Item.Kind in Phi2 | GPT2 | Bert | Jina_Bert_V2 | GPT_OSS
                          | Starcoder2 | Gptneox
            then
               Current.Out_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_output.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            if Item.Kind = GPT_OSS then
               Current.Sinks :=
                 Read_Vector (Layer_Name (Index, "attn_sinks.weight"),
                              Present);
               if not Present then
                  return;
               end if;
            end if;

            --  Falcon and Phi2 have one normalization a block: their
            --  feed-forward reads what attention read.
            --  Bert has none either, for the other reason: it normalizes
            --  on the way out of each sublayer rather than into it.
            --  The hybrids name the normalization before the feed-forward
            --  for what it follows rather than what it precedes: it is the
            --  same normalization in the same place.
            if Item.Kind
                 not in Falcon | Phi2 | Bert | Nomic_Bert | Jina_Bert_V2
                        | Olmo2
            then
               Current.Feed_Norm :=
                 Read_Vector
                   (Layer_Name
                      (Index,
                       (if Item.Kind in Qwen35 | Qwen35_MoE
                        then "post_attention_norm.weight"
                        else "ffn_norm.weight")),
                    Present);
               if not Present then
                  return;
               end if;

               --  The shift beside it, for the architectures that centre.
               --  Optional: a file need not carry one, and this reads what
               --  is there rather than what a fixture happens to write.
               if Item.Kind in GPT2 | Starcoder2 | Stablelm | Gptneox then
                  Current.Feed_Norm_Bias :=
                    Read_Vector
                      (Layer_Name (Index, "ffn_norm.bias"), Present);
               end if;
            end if;

            if Item.Experts > 0 then
               Current.Router :=
                 Read_Matrix (Layer_Name (Index, "ffn_gate_inp.weight"),
                              Present);
               if not Present then
                  return;
               end if;

               if Item.Kind = GPT_OSS then
                  Current.Router_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_gate_inp.bias"),
                                 Present);
                  if not Present then
                     return;
                  end if;

                  Current.Gate_Expert_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_gate_exps.bias"),
                                 Present);
                  if not Present then
                     return;
                  end if;

                  Current.Up_Expert_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_up_exps.bias"),
                                 Present);
                  if not Present then
                     return;
                  end if;

                  Current.Down_Expert_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_down_exps.bias"),
                                 Present);
                  if not Present then
                     return;
                  end if;
               end if;

               Current.Gate_Experts :=
                 Read_Matrix (Layer_Name (Index, "ffn_gate_exps.weight"),
                              Present);
               if not Present then
                  return;
               end if;

               Current.Up_Experts :=
                 Read_Matrix (Layer_Name (Index, "ffn_up_exps.weight"),
                              Present);
               if not Present then
                  return;
               end if;

               Current.Down_Experts :=
                 Read_Matrix (Layer_Name (Index, "ffn_down_exps.weight"),
                              Present);
               if not Present then
                  return;
               end if;

               --  The shared expert, where the mixture has one: the same
               --  gate-up-down block and the row that gates it.
               if Item.Shared_Feed > 0 then
                  Current.Shared_Gate :=
                    Read_Matrix (Layer_Name (Index, "ffn_gate_shexp.weight"),
                                 Present);
                  if not Present then
                     return;
                  end if;
                  Current.Shared_Up :=
                    Read_Matrix (Layer_Name (Index, "ffn_up_shexp.weight"),
                                 Present);
                  if not Present then
                     return;
                  end if;
                  Current.Shared_Down :=
                    Read_Matrix (Layer_Name (Index, "ffn_down_shexp.weight"),
                                 Present);
                  if not Present then
                     return;
                  end if;
                  Current.Shared_Router :=
                    Read_Vector
                      (Layer_Name (Index, "ffn_gate_inp_shexp.weight"),
                       Present);
                  if not Present then
                     return;
                  end if;
               end if;
            else
               if Item.Kind in Falcon | Phi2 | GPT2 | Bert | Starcoder2 | Gptneox | Mpt then
                  --  No gate at all: one projection up, a Gaussian unit,
                  --  one projection down.
                  Current.Gate := null;
                  Present := True;
               elsif Item.Kind in Phi3 | Glm4 | Chatglm then
                  Current.Gate :=
                    Read_Part (Layer_Name (Index, "ffn_up.weight"),
                               0, Item.Feed_Forward, Present);
               else
                  Current.Gate :=
                    Read_Matrix
                      (Layer_Name (Index, "ffn_gate.weight"), Present);
               end if;
               if not Present then
                  return;
               end if;

               if Item.Kind in Phi3 | Glm4 | Chatglm then
                  Current.Up :=
                    Read_Part (Layer_Name (Index, "ffn_up.weight"),
                               Item.Feed_Forward, Item.Feed_Forward, Present);
               else
                  Current.Up :=
                    Read_Matrix (Layer_Name (Index, "ffn_up.weight"), Present);
               end if;
               if not Present then
                  return;
               end if;

               Current.Down :=
                 Read_Matrix (Layer_Name (Index, "ffn_down.weight"), Present);
               if not Present then
                  return;
               end if;

               --  The one gated architecture here that shifts what it
               --  projects down, and shifts nothing else.
               if Item.Kind = Jina_Bert_V2 then
                  Current.Down_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_down.bias"), Present);
                  if not Present then
                     return;
                  end if;
               end if;

               --  A bias on each side of the block, which Phi2 has and
               --  Falcon does not.
               if Item.Kind in Phi2 | GPT2 | Bert | Starcoder2 | Gptneox then
                  Current.Up_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_up.bias"), Present);
                  if not Present then
                     return;
                  end if;

                  Current.Down_Bias :=
                    Read_Vector (Layer_Name (Index, "ffn_down.bias"), Present);
                  if not Present then
                     return;
                  end if;
               end if;
            end if;
         end;
      end loop;

      --  What the block past the stack reads besides a full attention
      --  block's own: the projection of the next token's embedding beside
      --  the state, each normalized, and the normalization of the state
      --  it hands on.
      if Item.Next_Layers > 0 then
         Item.Next_Proj :=
           Read_Matrix (Layer_Name (Item.Layers, "nextn.eh_proj.weight"),
                        Present);
         if not Present then
            return;
         end if;
         Item.Next_Enorm :=
           Read_Vector (Layer_Name (Item.Layers, "nextn.enorm.weight"),
                        Present);
         if not Present then
            return;
         end if;
         Item.Next_Hnorm :=
           Read_Vector (Layer_Name (Item.Layers, "nextn.hnorm.weight"),
                        Present);
         if not Present then
            return;
         end if;
         Item.Next_Head_Norm :=
           Read_Vector
             (Layer_Name (Item.Layers, "nextn.shared_head_norm.weight"),
              Present);
         if not Present then
            return;
         end if;
      end if;

      Item.Loaded := True;
      Ok := True;
   end Load;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Model) is
      Tied : constant Boolean := Item.Output = Item.Embeddings;
   begin
      if Item.Blocks /= null then
         for Index in Item.Blocks'Range loop
            Free_Vector (Item.Blocks (Index).Attention_Norm);
            Free_Vector (Item.Blocks (Index).Post_Attention_Norm);
            Free_Vector (Item.Blocks (Index).Attention_Norm_Bias);
            Free_Vector (Item.Blocks (Index).Post_Feed_Norm);
            Free_Vector (Item.Blocks (Index).Post_Attention_Norm_Bias);
            Free_Vector (Item.Blocks (Index).Post_Feed_Norm_Bias);
            Free_Matrix (Item.Blocks (Index).Query);
            Free_Matrix (Item.Blocks (Index).Key);
            Free_Matrix (Item.Blocks (Index).Value);
            Free_Vector (Item.Blocks (Index).Query_Norm);
            Free_Vector (Item.Blocks (Index).Key_Norm);
            Free_Vector (Item.Blocks (Index).Query_Whole_Norm);
            Free_Vector (Item.Blocks (Index).Query_Whole_Norm_Bias);
            Free_Vector (Item.Blocks (Index).Key_Whole_Norm);
            Free_Vector (Item.Blocks (Index).Key_Whole_Norm_Bias);
            Free_Vector (Item.Blocks (Index).Second_Attention_Norm);
            Free_Vector (Item.Blocks (Index).Second_Attention_Norm_Bias);
            Free_Matrix (Item.Blocks (Index).Attention_Out);
            Free_Vector (Item.Blocks (Index).Feed_Norm);
            Free_Vector (Item.Blocks (Index).Feed_Norm_Bias);
            Free_Matrix (Item.Blocks (Index).Router);
            Free_Matrix (Item.Blocks (Index).Gate_Experts);
            Free_Matrix (Item.Blocks (Index).Up_Experts);
            Free_Matrix (Item.Blocks (Index).Down_Experts);
            Free_Matrix (Item.Blocks (Index).Shared_Gate);
            Free_Matrix (Item.Blocks (Index).Shared_Up);
            Free_Matrix (Item.Blocks (Index).Shared_Down);
            Free_Vector (Item.Blocks (Index).Shared_Router);
            Free_Matrix (Item.Blocks (Index).Gate);
            Free_Matrix (Item.Blocks (Index).Up);
            Free_Matrix (Item.Blocks (Index).Down);
            Free_Matrix (Item.Blocks (Index).Mix);
            Free_Matrix (Item.Blocks (Index).Z_Gate);
            Free_Matrix (Item.Blocks (Index).Alpha);
            Free_Matrix (Item.Blocks (Index).Beta);
            Free_Vector (Item.Blocks (Index).A_Log);
            Free_Vector (Item.Blocks (Index).DT_Bias);
            Free_Matrix (Item.Blocks (Index).Conv);
            Free_Vector (Item.Blocks (Index).State_Norm);
            Free_Matrix (Item.Blocks (Index).Linear_Out);
         end loop;
         Free_Layers (Item.Blocks);
      end if;
      Free_Matrix (Item.Next_Proj);
      Free_Vector (Item.Next_Enorm);
      Free_Vector (Item.Next_Hnorm);
      Free_Vector (Item.Next_Head_Norm);

      if not Tied then
         Free_Matrix (Item.Output);
      end if;
      Item.Output := null;

      Free_Matrix (Item.Embeddings);
      Free_Matrix (Item.Positions);
      Free_Matrix (Item.Segments);
      Free_Vector (Item.Embedding_Norm);
      Free_Vector (Item.Embedding_Norm_Bias);
      Free_Vector (Item.Output_Norm);
      Free_Vector (Item.Output_Norm_Bias);
      Free_Vector (Item.Rope_Factors);
      Item.Loaded := False;
      Item.Words := 0;
   end Close;

   ----------------
   -- Vocabulary --
   ----------------

   function Vocabulary (Item : Model) return Natural is (Item.Words);

   -----------
   -- Width --
   -----------

   function Width (Item : Model) return Natural is (Item.Embedding);

   --------------
   -- Evaluate --
   --------------

   --  One pass, for both of the things a caller may want out of it: the
   --  distribution after the last position, and what the model made of
   --  every position. Written once because they are one computation, and a
   --  model that has only one of them to give -- Bert has no projection at
   --  all -- would otherwise be a second forward pass to keep in step with
   --  this one.
   procedure Evaluate
     (Item        : in out Model;
      Tokens      : Token_Vector;
      Logits      : out Real_Vector;
      States      : out Real_Vector;
      Want_States : Boolean;
      Ok          : out Boolean;
      Draft_Token : Integer := -1)
   is
      Width    : constant Natural := Item.Embedding;
      KV_Width : constant Natural := Item.KV_Heads * Item.Head_Size;
      V_Width  : constant Natural := Item.KV_Heads * Item.Value_Size;
      Q_Width  : constant Natural := Item.Heads * Item.Head_Size;
      B_Width  : constant Natural := Item.Heads * Item.Value_Size;
      Steps    : constant Natural := Tokens'Length;

      --  The whole key and value history, rather than a cache with reserved
      --  and committed positions.
      type History is array (Natural range <>, Natural range <>) of Long_Float;
      type History_Access is access History;
      procedure Free_History is
        new Ada.Unchecked_Deallocation (History, History_Access);

      Keys   : History_Access := null;
      Values : History_Access := null;

      --  What a block-major pass has to hold that a token-major one did
      --  not: every position's state between blocks, and between a block's
      --  two passes its queries and the input its feed-forward reads.
      Whole   : History_Access := null;
      Queries : History_Access := null;
      Kept    : History_Access := null;

      --  What a hybrid's linear block made of each position, held for the
      --  second pass where the residual is joined and the feed-forward
      --  runs, as an attention block's blend is.
      Linear_Rows : History_Access := null;

      --  The logistic unit and the softplus, each saturating where the
      --  exponential would not be worth taking: past twenty the logistic
      --  is one to this format's precision, and softplus is its argument.
      function Logistic (Value : Long_Float) return Long_Float is
      begin
         if Value > 20.0 then
            return 1.0;
         elsif Value < -20.0 then
            return 0.0;
         else
            return 1.0 / (1.0 + Functions.Exp (-Value));
         end if;
      end Logistic;

      function Softplus (Value : Long_Float) return Long_Float is
      begin
         if Value > 20.0 then
            return Value;
         else
            return Functions.Log (1.0 + Functions.Exp (Value));
         end if;
      end Softplus;

      State  : Real_Vector (0 .. Width - 1) := [others => 0.0];
      Normed : Real_Vector (0 .. Width - 1) := [others => 0.0];

      --  What the block normalized on the way in, for the architecture whose
      --  two sublayers both read it.
      Held_Norm : Real_Vector (0 .. Width - 1) := [others => 0.0];

      --  Root-mean-square normalization with a per-element gain.
      --  The hyperbolic tangent, for the two bounds Gemma2 states.
      --
      --  Saturating past twenty rather than computing an exponential that
      --  cannot be represented, for the reason written beside the gate: the
      --  difference from one is below what this format holds well before
      --  the exponential overflows.
      function Hyperbolic (Value : Long_Float) return Long_Float is
      begin
         if Value > 20.0 then
            return 1.0;
         elsif Value < -20.0 then
            return -1.0;
         end if;

         declare
            Twice : constant Long_Float := Functions.Exp (2.0 * Value);
         begin
            return (Twice - 1.0) / (Twice + 1.0);
         end;
      end Hyperbolic;

      --  The gate this architecture was trained with, written as the two
      --  formulas rather than as a call into the engine's kernels.
      --
      --  Gemma's is the Gaussian error unit in its hyperbolic-tangent form,
      --  which is what the models were trained against; everything else here
      --  is the logistic one. They agree to about a hundredth of the input
      --  at the worst, which is near enough to look right in generated text
      --  and far enough to be a different model.
      function Gated (Value : Long_Float) return Long_Float is
         Root : constant Long_Float := 0.797_884_560_802_865_4;
         Bend : constant Long_Float := 0.044_715;
      begin
         if Item.Kind
            in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
               | Jina_Bert_V2 | Starcoder2 | Gptneox | Mpt
         then
            declare
               Inner : constant Long_Float :=
                 Root * (Value + Bend * Value * Value * Value);
            begin
               --  The tangent saturates, and this says so rather than
               --  computing an exponential that cannot be represented. Past
               --  about twenty the difference from one is below what this
               --  format holds, and the cubic inside makes twenty a value
               --  an ordinary activation reaches: at an input of three the
               --  argument is already four, and at eight it is over three
               --  hundred, where the exponential of twice it overflows.
               --
               --  Found by the engine and this disagreeing about Gemma by
               --  six logits, with both computing the same function for
               --  every input either of them printed. What they did not
               --  agree about was the inputs neither of them prints.
               if Inner > 20.0 then
                  return Value;
               elsif Inner < -20.0 then
                  return 0.0;
               end if;

               declare
                  Twice : constant Long_Float := Functions.Exp (2.0 * Inner);
               begin
                  return 0.5 * Value * (1.0 + (Twice - 1.0) / (Twice + 1.0));
               end;
            end;
         end if;

         return Value / (1.0 + Functions.Exp (-Value));
      end Gated;

      --  Falcon centres and biases; everything else divides by the root
      --  mean square. Written as the two formulas rather than as a flag on
      --  one of them, because they are two different normalizations that
      --  happen to agree on a vector whose mean is zero.
      procedure Normalize_Centred
        (Source : Real_Vector;
         Gain   : Real_Vector;
         Bias   : Vector_Access;
         Target : out Real_Vector)
      is
         Mean   : Long_Float := 0.0;
         Spread : Long_Float := 0.0;
      begin
         for Value of Source loop
            Mean := Mean + Value;
         end loop;
         Mean := Mean / Long_Float (Source'Length);

         for Value of Source loop
            Spread := Spread + (Value - Mean) * (Value - Mean);
         end loop;
         Spread := Spread / Long_Float (Source'Length) + Item.Epsilon;

         declare
            Scale : constant Long_Float :=
              (if Spread > 0.0 then 1.0 / Functions.Sqrt (Spread) else 1.0);
         begin
            for Index in Source'Range loop
               Target (Index) :=
                 (Source (Index) - Mean) * Scale * Gain (Index)
                 + (if Bias = null then 0.0
                    else Bias (Bias'First + Index - Source'First));
            end loop;
         end;
      end Normalize_Centred;

      procedure Normalize
        (Source : Real_Vector;
         Gain   : Real_Vector;
         Target : out Real_Vector)
      is
         Total : Long_Float := 0.0;
      begin
         for Index in Source'Range loop
            Total := Total + Source (Index) * Source (Index);
         end loop;

         declare
            Scale : constant Long_Float :=
              1.0 / Functions.Sqrt
                      (Total / Long_Float (Source'Length) + Item.Epsilon);

         begin
            --  The gain as the file stores it, for every architecture.
            --  Gemma trains its gains around zero and adds one at the
            --  point of use, and this used to add that one here as the
            --  architecture states it -- but the converter that writes a
            --  Gemma file has already added it to every norm weight, so
            --  the addition here made the gain two plus the weight. The
            --  engine had the same belief, which is why crossing the two
            --  found nothing: what tells them apart from the published
            --  runtime is the file, which neither of them was asked about.
            for Index in Source'Range loop
               Target (Index) := Source (Index) * Scale * Gain (Index);
            end loop;
         end;
      end Normalize;

      --  Matrix-vector product, one row at a time.
      procedure Project
        (Weight : Matrix;
         Input  : Real_Vector;
         Target : out Real_Vector)
      is
      begin
         for Row in Weight'Range (1) loop
            declare
               Total : Long_Float := 0.0;
            begin
               for Column in Weight'Range (2) loop
                  Total := Total + Weight (Row, Column) * Input (Column);
               end loop;
               Target (Row) := Total;
            end;
         end loop;
      end Project;

      --  The same product over a band of rows starting at First, which is
      --  how one expert is reached inside the stack the file writes.
      procedure Project_Rows
        (Weight : Matrix;
         First  : Natural;
         Input  : Real_Vector;
         Target : out Real_Vector)
      is
      begin
         for Row in Target'Range loop
            declare
               Total : Long_Float := 0.0;
            begin
               for Column in Weight'Range (2) loop
                  Total := Total
                    + Weight (First + Row, Column) * Input (Column);
               end loop;
               Target (Row) := Total;
            end;
         end loop;
      end Project_Rows;

      --  Rotary encoding over the leading Rotary elements of each head.
      --  Root-mean-square normalization of each head of a projection,
      --  against itself, with one gain per element of a head.
      procedure Normalize_Heads
        (Vector : in out Real_Vector;
         Heads  : Natural;
         Width  : Natural;
         Gain   : Real_Vector)
      is
      begin
         for Head in 0 .. Heads - 1 loop
            declare
               Origin : constant Natural := Vector'First + Head * Width;
               Total  : Long_Float := 0.0;
               Factor : Long_Float;
            begin
               for Index in 0 .. Width - 1 loop
                  Total := Total
                    + Vector (Origin + Index) * Vector (Origin + Index);
               end loop;

               Factor :=
                 1.0 / Functions.Sqrt (Total / Long_Float (Width)
                                       + Item.Epsilon);

               for Index in 0 .. Width - 1 loop
                  Vector (Origin + Index) :=
                    Vector (Origin + Index) * Factor
                    * Gain (Gain'First + Index);
               end loop;
            end;
         end loop;
      end Normalize_Heads;

      --  Where a pair sits in the band Yarn mixes across: one where the
      --  angle is kept as trained, zero where it is fully stretched.
      --
      --  The band's edges are worked out from the base the layer turns on,
      --  not from the model's, because they are the dimensions that turn a
      --  given number of times over the trained context and that depends on
      --  the base being used. Gemma3 is the first architecture here where
      --  the two differ; the engine passes one base into its kernel and
      --  uses it throughout, and this used the model's for the edges and
      --  the layer's for the frequency, which disagreed on eight logits of
      --  a stretched fixture.
      function Ramp (Pair : Long_Float; Base : Long_Float)
                     return Long_Float is
         --  The dimension that turns Turns times over the trained context.
         function Edge (Turns : Long_Float) return Long_Float is
           (Long_Float (Item.Rotary)
            * Functions.Log
                (Long_Float (Item.Trained) / (Turns * 2.0 * Ada.Numerics.Pi))
            / (2.0 * Functions.Log (Base)));

         Low  : constant Long_Float :=
           Long_Float'Max (0.0, Long_Float'Floor (Edge (Item.Beta_Fast)));
         High : constant Long_Float :=
           Long_Float'Min
             (Long_Float (Item.Rotary / 2 - 1),
              Long_Float'Ceiling (Edge (Item.Beta_Slow)));
      begin
         return Long_Float'Max
           (0.0,
            Long_Float'Min
              (1.0,
               1.0 - (Pair - Low) / Long_Float'Max (0.001, High - Low)));
      end Ramp;

      procedure Rotate
        (Vector   : in out Real_Vector;
         Heads    : Natural;
         Position : Natural;

         --  Which layer is turning, because Gemma3's windowed layers turn
         --  on a base of their own.
         Layer    : Natural)
      is
      begin
         for Head in 0 .. Heads - 1 loop
            for Pair in 0 .. Item.Rotary / 2 - 1 loop
               declare
                  Divisor : constant Long_Float :=
                    (if Item.Rope_Factors /= null
                       and then Item.Rope_Factors'Length = Item.Rotary / 2
                     then Item.Rope_Factors (Item.Rope_Factors'First + Pair)
                     else 1.0);

                  --  The base this layer turns on. Gemma3 gives its
                  --  windowed layers one of their own -- a small base for a
                  --  layer that looks a few positions back -- and the layer
                  --  that sees everything turns on the model's.
                  Base : constant Long_Float :=
                    (if Item.Local_Base > 0.0
                       and then Item.Window_Every > 0
                       and then Layer mod Item.Window_Every
                                /= Item.Window_Every - 1
                     then Item.Local_Base
                     else Item.Rope_Base);

                  Frequency : constant Long_Float :=
                    1.0 / Functions."**"
                            (Base,
                             2.0 * Long_Float (Pair)
                             / Long_Float (Item.Rotary))
                    / Divisor;

                  --  Whether this layer is a windowed one of Gemma3's,
                  --  which the file's stretch does not reach: the factor a
                  --  Gemma 3 states is for the layers that see the whole
                  --  context, and a windowed layer turns as it was trained.
                  --  The other family that windows on a base of its own,
                  --  GPT-OSS, stretches every layer.
                  Unstretched : constant Boolean :=
                    Item.Kind = Gemma3
                    and then Item.Window_Every > 0
                    and then Layer mod Item.Window_Every
                             /= Item.Window_Every - 1;

                  --  The angle as trained, and the angle the model's factor
                  --  stretches it to.
                  Trained_Angle : constant Long_Float :=
                    Long_Float (Position) * Frequency;
                  Stretched : constant Long_Float :=
                    (if Unstretched then Trained_Angle
                     else Item.Frequency * Trained_Angle);

                  --  Yarn keeps the fast dimensions as trained and stretches
                  --  the slow ones, mixing across the band between them. The
                  --  band's edges are the dimensions that turn Beta_Fast and
                  --  Beta_Slow times over the context the model was trained
                  --  on, which is what solving the frequency for the
                  --  dimension gives.
                  Mixed : constant Long_Float :=
                    (if Item.Stretch /= Yarn or else Unstretched then 0.0
                     else Ramp (Long_Float (Pair), Base));

                  Angle : constant Long_Float :=
                    (if Item.Stretch = Yarn and then not Unstretched
                     then Stretched * (1.0 - Mixed) + Trained_Angle * Mixed
                     else Stretched);

                  --  And it scales what comes out, because interpolating
                  --  angles brings the scores they produce together.
                  Size : constant Long_Float :=
                    (if Item.Stretch = Yarn and then not Unstretched
                     then Item.Attenuation
                          * (1.0 + 0.1 * Functions.Log (1.0 / Item.Frequency))
                     else 1.0);
                  --  Llama pairs an element with its neighbour; Qwen2
                  --  pairs it with the one half a rotation later. Written
                  --  out here rather than shared with the engine: the point
                  --  of this implementation is to be arrived at separately,
                  --  and a shared rotation would agree with itself.
                  Even  : constant Natural :=
                    (if Item.Kind in Llama | Granite | Granite_MoE | Glm4 | Internlm2 | Chatglm
                        | Baichuan
                     then Head * Item.Head_Size + 2 * Pair
                     else Head * Item.Head_Size + Pair);
                  Odd   : constant Natural :=
                    (if Item.Kind in Llama | Granite | Granite_MoE | Glm4 | Internlm2 | Chatglm
                        | Baichuan
                     then Even + 1
                     else Even + Item.Rotary / 2);
                  Left  : constant Long_Float := Vector (Even);
                  Right : constant Long_Float := Vector (Odd);
               begin
                  Vector (Even) :=
                    (Left * Functions.Cos (Angle)
                     - Right * Functions.Sin (Angle)) * Size;
                  Vector (Odd) :=
                    (Left * Functions.Sin (Angle)
                     + Right * Functions.Cos (Angle)) * Size;
               end;
            end loop;
         end loop;
      end Rotate;

      --  The feed-forward of a block, dense or a mixture, over what the
      --  block normalized for it and back into the same vector. Factored
      --  out of the second pass so that the block past the stack, which
      --  is a full attention block with a feed-forward of its own, can
      --  take it too.
      procedure Feed_Forward (Current : Layer; Normed : in out Real_Vector);

      procedure Feed_Forward (Current : Layer; Normed : in out Real_Vector)
      is
      begin
         if Item.Experts > 0 then
            --  A mixture: the router scores the experts, the softmax
            --  turns the scores into shares, the highest few are kept
            --  and their shares put back on a scale of one, and each
            --  of them runs the block a dense model has one of.
            declare
               Width_Feed : constant Natural := Item.Expert_Feed;

               Scores : Real_Vector (0 .. Item.Experts - 1) :=
                 [others => 0.0];
               Taken  : array (0 .. Item.Experts - 1) of Boolean :=
                 [others => False];
               Picked : array (0 .. Item.Experts_Used - 1) of Natural :=
                 [others => 0];
               Share  : array (0 .. Item.Experts_Used - 1) of Long_Float
                 := [others => 0.0];

               Input  : constant Real_Vector := Normed;
               Sum    : Real_Vector (0 .. Width - 1) := [others => 0.0];

               Largest, Total : Long_Float;
            begin
               Project (Current.Router.all, Input, Scores);

               if Current.Router_Bias /= null then
                  for Index in Scores'Range loop
                     Scores (Index) := Scores (Index)
                       + Current.Router_Bias.all (Index);
                  end loop;
               end if;

               Largest := Scores (0);
               for Index in Scores'Range loop
                  if Scores (Index) > Largest then
                     Largest := Scores (Index);
                  end if;
               end loop;

               Total := 0.0;
               for Index in Scores'Range loop
                  Scores (Index) := Functions.Exp (Scores (Index)
                                                   - Largest);
                  Total := Total + Scores (Index);
               end loop;
               for Index in Scores'Range loop
                  Scores (Index) := Scores (Index) / Total;
               end loop;

               --  The highest few, ties going to the lower-numbered
               --  expert.
               Total := 0.0;
               for Slot in Picked'Range loop
                  declare
                     Best : Integer := -1;
                  begin
                     for Index in Scores'Range loop
                        if not Taken (Index)
                          and then (Best < 0
                                    or else Scores (Index)
                                            > Scores (Best))
                        then
                           Best := Index;
                        end if;
                     end loop;

                     Taken (Best) := True;
                     Picked (Slot) := Best;
                     Share (Slot) := Scores (Best);
                     Total := Total + Share (Slot);
                  end;
               end loop;

               for Slot in Share'Range loop
                  Share (Slot) :=
                    Share (Slot) / Total * Item.Expert_Scale;
               end loop;

               for Slot in Picked'Range loop
                  declare
                     --  Where this expert's rows start in each stack.
                     Rows_Feed : constant Natural :=
                       Picked (Slot) * Width_Feed;
                     Rows_Down : constant Natural :=
                       Picked (Slot) * Width;

                     Gate : Real_Vector (0 .. Width_Feed - 1) :=
                       [others => 0.0];
                     Up   : Real_Vector (0 .. Width_Feed - 1) :=
                       [others => 0.0];
                     Out_Row : Real_Vector (0 .. Width - 1) :=
                       [others => 0.0];
                  begin
                     Project_Rows
                       (Current.Gate_Experts.all, Rows_Feed, Input,
                        Gate);
                     Project_Rows
                       (Current.Up_Experts.all, Rows_Feed, Input, Up);

                     --  The biases, where the architecture carries
                     --  them, indexed as the weights are: one
                     --  expert's run at its own place in an array
                     --  holding every expert's.
                     if Current.Gate_Expert_Bias /= null then
                        for Index in Gate'Range loop
                           Gate (Index) := Gate (Index)
                             + Current.Gate_Expert_Bias.all
                                 (Rows_Feed + Index);
                           Up (Index) := Up (Index)
                             + Current.Up_Expert_Bias.all
                                 (Rows_Feed + Index);
                        end loop;
                     end if;

                     --  Through the same gate the dense block uses,
                     --  which is the architecture's and not a copy of
                     --  one. This was the logistic written out, and a
                     --  mixture under an architecture with a
                     --  different gate then disagreed with the engine
                     --  by two logits in three -- while every gate
                     --  either implementation printed matched, because
                     --  the dense blocks were never the ones that
                     --  differed.
                     --
                     --  GPT_OSS is the exception and cannot go
                     --  through Gated at all: it holds both
                     --  projections at a limit, takes the logistic
                     --  at a steeper slope, and adds one to the up
                     --  projection, so the gate reaches the second
                     --  vector as well as the first.
                     if Item.Kind = GPT_OSS then
                        for Index in Gate'Range loop
                           declare
                              Limit : constant Long_Float := 7.0;
                              Alpha : constant Long_Float := 1.702;

                              X : constant Long_Float :=
                                Long_Float'Min (Gate (Index), Limit);
                              Y : constant Long_Float :=
                                Long_Float'Max
                                  (-Limit,
                                   Long_Float'Min (Up (Index),
                                                   Limit));
                           begin
                              Gate (Index) :=
                                X / (1.0 + Functions.Exp (-Alpha * X))
                                * (Y + 1.0);
                           end;
                        end loop;
                     else
                        for Index in Gate'Range loop
                           Gate (Index) :=
                             Gated (Gate (Index)) * Up (Index);
                        end loop;
                     end if;

                     Project_Rows
                       (Current.Down_Experts.all, Rows_Down, Gate,
                        Out_Row);

                     if Current.Down_Expert_Bias /= null then
                        for Index in Out_Row'Range loop
                           Out_Row (Index) := Out_Row (Index)
                             + Current.Down_Expert_Bias.all
                                 (Rows_Down + Index);
                        end loop;
                     end if;

                     for Index in Sum'Range loop
                        Sum (Index) :=
                          Sum (Index) + Share (Slot) * Out_Row (Index);
                     end loop;
                  end;
               end loop;

               --  The shared expert, where the mixture has one: the same
               --  gate-up-down block over the whole input, scaled by the
               --  sigmoid of its own router row against the input, and
               --  added to what the chosen experts said.
               if Current.Shared_Gate /= null then
                  declare
                     S_Feed : constant Natural := Item.Shared_Feed;
                     S_Gate : Real_Vector (0 .. S_Feed - 1) :=
                       [others => 0.0];
                     S_Up   : Real_Vector (0 .. S_Feed - 1) :=
                       [others => 0.0];
                     S_Out  : Real_Vector (0 .. Width - 1) :=
                       [others => 0.0];
                     G_Sum  : Long_Float := 0.0;
                     Scale  : Long_Float;
                  begin
                     Project (Current.Shared_Gate.all, Input, S_Gate);
                     Project (Current.Shared_Up.all, Input, S_Up);
                     for Index in S_Gate'Range loop
                        S_Gate (Index) := Gated (S_Gate (Index)) * S_Up (Index);
                     end loop;
                     Project (Current.Shared_Down.all, S_Gate, S_Out);
                     for Index in Input'Range loop
                        G_Sum := G_Sum
                          + Input (Index) * Current.Shared_Router (Index);
                     end loop;
                     Scale := 1.0 / (1.0 + Functions.Exp (-G_Sum));
                     for Index in Sum'Range loop
                        Sum (Index) := Sum (Index) + Scale * S_Out (Index);
                     end loop;
                  end;
               end if;

               Normed := Sum;
            end;
         else
            declare
               Gate : Real_Vector (0 .. Item.Feed_Forward - 1) :=
                 [others => 0.0];
               Up   : Real_Vector (0 .. Item.Feed_Forward - 1) :=
                 [others => 0.0];
            begin
               --  No gate is its own arrangement, not a gate of ones:
               --  one projection up, a Gaussian unit, one down.
               if Current.Gate = null then
                  Project (Current.Up.all, Normed, Gate);

                  --  The bias belongs to the projection, so it is
                  --  added before the unit rather than after it.
                  if Current.Up_Bias /= null then
                     for Index in Gate'Range loop
                        Gate (Index) :=
                          Gate (Index) + Current.Up_Bias.all (Index);
                     end loop;
                  end if;

                  for Index in Gate'Range loop
                     Gate (Index) := Gated (Gate (Index));
                  end loop;
               else
                  Project (Current.Gate.all, Normed, Gate);
                  Project (Current.Up.all, Normed, Up);

                  for Index in Gate'Range loop
                     Gate (Index) := Gated (Gate (Index)) * Up (Index);
                  end loop;
               end if;

               Project (Current.Down.all, Gate, Normed);

               if Current.Down_Bias /= null then
                  for Index in 0 .. Width - 1 loop
                     Normed (Index) :=
                       Normed (Index) + Current.Down_Bias.all (Index);
                  end loop;
               end if;
            end;
         end if;
      end Feed_Forward;

   begin
      Ok := False;
      Logits := [others => 0.0];
      States := [others => 0.0];

      if not Item.Loaded or else Steps = 0 then
         return;
      end if;

      --  What the caller asked for has to be the size of what there is. A
      --  model with no projection has no vocabulary-sized answer, so the
      --  logits are not checked against one.
      if Want_States then
         if States'Length /= Steps * Width then
            return;
         end if;
      elsif Logits'Length /= Item.Words then
         return;
      end if;

      for Token of Tokens loop
         if Token >= Item.Words then
            return;
         end if;
      end loop;

      Keys := new History (0 .. Item.Layers * Steps - 1, 0 .. KV_Width - 1);
      Values := new History (0 .. Item.Layers * Steps - 1, 0 .. V_Width - 1);

      --  Every position's state, its queries and the normalized input its
      --  feed-forward reads, all held across the two passes a block takes.
      Whole   := new History (0 .. Steps - 1, 0 .. Width - 1);
      Queries :=
        new History
          (0 .. Steps - 1,
           0 .. (if Item.Kind in Qwen35 | Qwen35_MoE then 2 * Q_Width
                 else Q_Width) - 1);
      Linear_Rows := new History (0 .. Steps - 1, 0 .. Width - 1);
      Kept    := new History (0 .. Steps - 1, 0 .. Width - 1);

      --  Every position embedded before any block runs, because a
      --  model that attends both ways cannot be evaluated a position
      --  at a time: position zero reads the last position of the text
      --  and there is no order in which each is computed after what it
      --  reads. Block-major is the order that works for both, and for
      --  a causal model it is the same arithmetic in the same order --
      --  every key a position reads was written before it looks.
      for Step in 0 .. Steps - 1 loop
         --  Embedding lookup, scaled by what the architecture says.
         --
         --  Gemma multiplies the row by the square root of the embedding
         --  width before the first layer. Written as the square root of the
         --  width because that is what the architecture states; the engine
         --  computes the same number once per token from the same field.
         declare
            Lift : constant Long_Float :=
              (if Item.Kind in Gemma | Gemma2 | Gemma3
               then Functions.Sqrt (Long_Float (Width))
               elsif Item.Kind in Granite | Granite_MoE and then Item.Embedding_Mul /= 0.0
               then Item.Embedding_Mul
               else 1.0);
         begin
            for Index in 0 .. Width - 1 loop
               State (Index) :=
                 Item.Embeddings (Tokens (Tokens'First + Step), Index) * Lift;
            end loop;

            --  And where the token is, for the architecture that learns it.
            --  A model with a table of positions has no rotation and a model
            --  with rotation has no table, so this and Rotate below are
            --  never both at work.
            if Item.Positions /= null then
               for Index in 0 .. Width - 1 loop
                  State (Index) :=
                    State (Index) + Item.Positions (Step, Index);
               end loop;
            end if;

            --  And which segment the token belongs to, which is the first
            --  of them for every position of a text embedded here.
            if Item.Segments /= null then
               for Index in 0 .. Width - 1 loop
                  State (Index) := State (Index) + Item.Segments (0, Index);
               end loop;
            end if;

            --  Bert normalizes the sum of the three before layer zero sees
            --  it, and the normalization centres and carries a shift.
            if Item.Embedding_Norm /= null then
               declare
                  Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
               begin
                  Normalize_Centred
                    (State, Item.Embedding_Norm.all,
                     Item.Embedding_Norm_Bias, Room);
                  State (0 .. Width - 1) := Room;
               end;
            end if;
         end;

         for Index in 0 .. Width - 1 loop
            Whole (Step, Index) := State (Index);
         end loop;
      end loop;

      for Block in 0 .. Item.Layers - 1 loop
         declare
            Current : Layer renames Item.Blocks (Block);
         begin
            --  A hybrid's linear block: the whole of its attention half,
            --  position by position in order, since each position's state
            --  is the one before decayed and corrected. Written out from
            --  the architecture's description -- the state S_t = a_t S_t-1
            --  + k_t u_t', with u_t = b_t (v_t - a_t S_t-1' k_t), read at
            --  the query, normalized, and gated -- one position and one
            --  head at a time over the state itself, which is the plain
            --  form the engine's chunked one unrolls.
            if Current.Linear then
               declare
                  S_Size    : constant Natural := Item.State_Size;
                  Keys_Wide : constant Natural := Item.Key_Heads * S_Size;
                  Vals_Wide : constant Natural := Item.Value_Heads * S_Size;
                  Mix_Wide  : constant Natural := 2 * Keys_Wide + Vals_Wide;
                  Taps      : constant Natural := Item.Conv_Taps;

                  --  The last Taps - 1 positions' projections a channel,
                  --  oldest first, zero before the first position; and a
                  --  state a value head, zero at the start of the text.
                  Memory : Real_Vector (0 .. (Taps - 1) * Mix_Wide - 1) :=
                    [others => 0.0];
                  States : Real_Vector
                    (0 .. Item.Value_Heads * S_Size * S_Size - 1) :=
                    [others => 0.0];
               begin
                  for Step in 0 .. Steps - 1 loop
                     declare
                        Mixed  : Real_Vector (0 .. Mix_Wide - 1) :=
                          [others => 0.0];
                        Made   : Real_Vector (0 .. Mix_Wide - 1) :=
                          [others => 0.0];
                        Gate   : Real_Vector (0 .. Vals_Wide - 1) :=
                          [others => 0.0];
                        Alphas : Real_Vector (0 .. Item.Value_Heads - 1) :=
                          [others => 0.0];
                        Betas  : Real_Vector (0 .. Item.Value_Heads - 1) :=
                          [others => 0.0];
                        Blend  : Real_Vector (0 .. Vals_Wide - 1) :=
                          [others => 0.0];
                     begin
                        for Index in 0 .. Width - 1 loop
                           State (Index) := Whole (Step, Index);
                        end loop;
                        Normalize (State, Current.Attention_Norm.all, Normed);

                        Project (Current.Mix.all, Normed, Mixed);
                        Project (Current.Z_Gate.all, Normed, Gate);
                        Project (Current.Alpha.all, Normed, Alphas);
                        Project (Current.Beta.all, Normed, Betas);

                        --  The convolution a channel over this position and
                        --  the remembered ones, the last tap on this one;
                        --  then the memory moved up a position.
                        for C in 0 .. Mix_Wide - 1 loop
                           declare
                              Total : Long_Float :=
                                Mixed (C) * Current.Conv (C, Taps - 1);
                           begin
                              for K in 0 .. Taps - 2 loop
                                 Total := Total
                                   + Memory (K * Mix_Wide + C)
                                     * Current.Conv (C, K);
                              end loop;
                              Made (C) := Total;
                           end;
                        end loop;
                        for K in 0 .. Taps - 3 loop
                           for C in 0 .. Mix_Wide - 1 loop
                              Memory (K * Mix_Wide + C) :=
                                Memory ((K + 1) * Mix_Wide + C);
                           end loop;
                        end loop;
                        for C in 0 .. Mix_Wide - 1 loop
                           Memory ((Taps - 2) * Mix_Wide + C) := Mixed (C);
                        end loop;

                        --  The unit, and each query and key head to unit
                        --  length, the length floored at the epsilon.
                        for C in 0 .. Mix_Wide - 1 loop
                           Made (C) := Made (C) * Logistic (Made (C));
                        end loop;
                        for H in 0 .. 2 * Item.Key_Heads - 1 loop
                           declare
                              Total : Long_Float := 0.0;
                              Unit  : Long_Float;
                           begin
                              for C in 0 .. S_Size - 1 loop
                                 Total := Total
                                   + Made (H * S_Size + C) * Made (H * S_Size + C);
                              end loop;
                              Unit :=
                                1.0 / Long_Float'Max
                                        (Functions.Sqrt (Total), Item.Epsilon);
                              for C in 0 .. S_Size - 1 loop
                                 Made (H * S_Size + C) :=
                                   Made (H * S_Size + C) * Unit;
                              end loop;
                           end;
                        end loop;

                        --  The rule, a value head at a time, each reading
                        --  the key head it shares with the others of its
                        --  group. The file keeps minus the exponential of
                        --  the decay's shape, so what it stores is what
                        --  multiplies the rate's softplus.
                        for H in 0 .. Item.Value_Heads - 1 loop
                           declare
                              KH : constant Natural := H mod Item.Key_Heads;
                              Q0 : constant Natural := KH * S_Size;
                              K0 : constant Natural := Keys_Wide + KH * S_Size;
                              V0 : constant Natural :=
                                2 * Keys_Wide + H * S_Size;
                              S0 : constant Natural := H * S_Size * S_Size;
                              Decay : constant Long_Float :=
                                Functions.Exp
                                  (Current.A_Log (H)
                                   * Softplus
                                       (Alphas (H) + Current.DT_Bias (H)));
                              Rate  : constant Long_Float :=
                                Logistic (Betas (H));
                              Fix   : Real_Vector (0 .. S_Size - 1) :=
                                [others => 0.0];
                              Read  : Real_Vector (0 .. S_Size - 1) :=
                                [others => 0.0];
                              Total : Long_Float := 0.0;
                           begin
                              --  u = b (v - a S' k)
                              for J in 0 .. S_Size - 1 loop
                                 declare
                                    Of_Key : Long_Float := 0.0;
                                 begin
                                    for I in 0 .. S_Size - 1 loop
                                       Of_Key := Of_Key
                                         + States (S0 + I * S_Size + J)
                                           * Made (K0 + I);
                                    end loop;
                                    Fix (J) :=
                                      Rate * (Made (V0 + J) - Decay * Of_Key);
                                 end;
                              end loop;

                              --  S = a S + k u'
                              for I in 0 .. S_Size - 1 loop
                                 for J in 0 .. S_Size - 1 loop
                                    States (S0 + I * S_Size + J) :=
                                      Decay * States (S0 + I * S_Size + J)
                                      + Made (K0 + I) * Fix (J);
                                 end loop;
                              end loop;

                              --  o = S' q, scaled by the root of the width
                              for J in 0 .. S_Size - 1 loop
                                 declare
                                    Of_Query : Long_Float := 0.0;
                                 begin
                                    for I in 0 .. S_Size - 1 loop
                                       Of_Query := Of_Query
                                         + States (S0 + I * S_Size + J)
                                           * Made (Q0 + I);
                                    end loop;
                                    Read (J) :=
                                      Of_Query
                                      / Functions.Sqrt (Long_Float (S_Size));
                                    Total := Total + Read (J) * Read (J);
                                 end;
                              end loop;

                              --  Normalized over the head with the shared
                              --  gain, and gated by the unit of the gate.
                              declare
                                 Root : constant Long_Float :=
                                   1.0 / Functions.Sqrt
                                           (Total / Long_Float (S_Size)
                                            + Item.Epsilon);
                              begin
                                 for J in 0 .. S_Size - 1 loop
                                    Blend (H * S_Size + J) :=
                                      Read (J) * Root * Current.State_Norm (J)
                                      * Gate (H * S_Size + J)
                                      * Logistic (Gate (H * S_Size + J));
                                 end loop;
                              end;
                           end;
                        end loop;

                        Project (Current.Linear_Out.all, Blend, Normed);
                        for Index in 0 .. Width - 1 loop
                           Linear_Rows (Step, Index) := Normed (Index);
                        end loop;
                     end;
                  end loop;
               end;
            end if;

            --  What every position projects, and its keys and values
            --  written into the history before any attention reads one.
            for Step in 0 .. Steps - 1 loop
               declare
                  Query   : Real_Vector (0 .. Q_Width - 1) :=
                    [others => 0.0];
                  Key_Row : Real_Vector (0 .. KV_Width - 1) :=
                    [others => 0.0];
                  Val_Row : Real_Vector (0 .. V_Width - 1) :=
                    [others => 0.0];
                  Slot    : constant Natural := Block * Steps + Step;

                  --  A hybrid's query projection is twice as wide: each
                  --  head's queries and then its gate.
                  Wide_Query : Real_Vector
                    (0 .. (if Item.Kind in Qwen35 | Qwen35_MoE
                           then 2 * Q_Width else Q_Width) - 1) :=
                    [others => 0.0];
               begin
                  if Current.Linear then
                     goto Projected;
                  end if;
                  for Index in 0 .. Width - 1 loop
                     State (Index) := Whole (Step, Index);
                  end loop;

                  --  Bert's block reads the residual as it stands: what
                  --  normalized it was the block before this one, on the
                  --  way out.
                  if Current.Attention_Norm = null then
                     Normed (0 .. Width - 1) := State (0 .. Width - 1);
                  elsif Item.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox | Mpt then
                     Normalize_Centred
                       (State, Current.Attention_Norm.all,
                        Current.Attention_Norm_Bias, Normed);
                  else
                     Normalize (State, Current.Attention_Norm.all, Normed);
                  end if;

                  --  Kept, because Falcon's feed-forward reads this and not
                  --  what attention produced. Asked of the architecture and
                  --  not of the feed normalization being absent: Bert has
                  --  none either and does not run its sublayers in
                  --  parallel.
                  if Item.Kind in Falcon | Phi2 then
                     Held_Norm (0 .. Width - 1) := Normed (0 .. Width - 1);
                  end if;
                  if Item.Kind in Qwen35 | Qwen35_MoE then
                     Project (Current.Query.all, Normed, Wide_Query);
                     for Head in 0 .. Item.Heads - 1 loop
                        for Index in 0 .. Item.Head_Size - 1 loop
                           Query (Head * Item.Head_Size + Index) :=
                             Wide_Query (Head * 2 * Item.Head_Size + Index);
                           Queries (Step, Q_Width + Head * Item.Head_Size + Index)
                             := Wide_Query
                                  (Head * 2 * Item.Head_Size + Item.Head_Size
                                   + Index);
                        end loop;
                     end loop;
                  else
                     Project (Current.Query.all, Normed, Query);
                  end if;
                  Project (Current.Key.all, Normed, Key_Row);
                  Project (Current.Value.all, Normed, Val_Row);

                  --  The bias belongs to the projection, so it is added to
                  --  what the projection produced and before the rotation acts
                  --  on it. That ordering is the one thing the engine's own
                  --  tests cannot check, because a fixture has nothing to be
                  --  right against; this is the something.
                  if Current.Query_Bias /= null then
                     for Index in Query'Range loop
                        Query (Index) :=
                          Query (Index) + Current.Query_Bias.all (Index);
                     end loop;
                     for Index in Key_Row'Range loop
                        Key_Row (Index) :=
                          Key_Row (Index) + Current.Key_Bias.all (Index);
                     end loop;
                     for Index in Val_Row'Range loop
                        Val_Row (Index) :=
                          Val_Row (Index) + Current.Value_Bias.all (Index);
                     end loop;
                  end if;

                  --  MPT clamps the queries, keys and values to a magnitude
                  --  the file states, on what the projection produced and
                  --  before anything reads them. Written out here as the two
                  --  bounds rather than shared with the engine's clamp.
                  if Item.Clip_QKV > 0.0 then
                     for Index in Query'Range loop
                        Query (Index) :=
                          Long_Float'Max
                            (-Item.Clip_QKV,
                             Long_Float'Min (Item.Clip_QKV, Query (Index)));
                     end loop;
                     for Index in Key_Row'Range loop
                        Key_Row (Index) :=
                          Long_Float'Max
                            (-Item.Clip_QKV,
                             Long_Float'Min (Item.Clip_QKV, Key_Row (Index)));
                     end loop;
                     for Index in Val_Row'Range loop
                        Val_Row (Index) :=
                          Long_Float'Max
                            (-Item.Clip_QKV,
                             Long_Float'Min (Item.Clip_QKV, Val_Row (Index)));
                     end loop;
                  end if;

                  --  Qwen3 normalizes each head against itself before the
                  --  rotation, with a gain shared across the heads. Written out
                  --  here rather than shared with the engine, as the rotation
                  --  is.
                  if Current.Query_Norm /= null then
                     Normalize_Heads
                       (Query, Item.Heads, Item.Head_Size,
                        Current.Query_Norm.all);
                     Normalize_Heads
                       (Key_Row, Item.KV_Heads, Item.Head_Size,
                        Current.Key_Norm.all);
                  end if;

                  --  The code variant of jina-bert-v2 normalizes the whole
                  --  of the queries and the whole of the keys instead --
                  --  centred, with a shift, over the projection and not a
                  --  head of it -- after the bias and before the heads are
                  --  cut.
                  --  OLMo2 divides by the root mean square and carries no
                  --  shift; jina-bert-v2's code variant centres and carries
                  --  one. The same two tensors, two different normalizations.
                  if Current.Query_Whole_Norm /= null then
                     declare
                        Room : Real_Vector (Query'Range) := [others => 0.0];
                     begin
                        if Item.Kind = Olmo2 then
                           Normalize
                             (Query, Current.Query_Whole_Norm.all, Room);
                        else
                           Normalize_Centred
                             (Query, Current.Query_Whole_Norm.all,
                              Current.Query_Whole_Norm_Bias, Room);
                        end if;
                        Query := Room;
                     end;
                     declare
                        Room : Real_Vector (Key_Row'Range) := [others => 0.0];
                     begin
                        if Item.Kind = Olmo2 then
                           Normalize
                             (Key_Row, Current.Key_Whole_Norm.all, Room);
                        else
                           Normalize_Centred
                             (Key_Row, Current.Key_Whole_Norm.all,
                              Current.Key_Whole_Norm_Bias, Room);
                        end if;
                        Key_Row := Room;
                     end;
                  end if;

                  Rotate (Query, Item.Heads, Step, Block);
                  Rotate (Key_Row, Item.KV_Heads, Step, Block);

                  Round_As (Key_Row, Item.Key_Rounding);
                  Round_As (Val_Row, Item.Value_Rounding);
                  for Index in 0 .. KV_Width - 1 loop
                     Keys (Slot, Index) := Key_Row (Index);
                  end loop;
                  for Index in 0 .. V_Width - 1 loop
                     Values (Slot, Index) := Val_Row (Index);
                  end loop;

                  --  Held for the second pass, which is where this
                  --  position attends: the queries it just made, and
                  --  the normalized input its feed-forward reads where
                  --  the architecture runs its two sublayers from the
                  --  same one.
                  for Index in 0 .. Q_Width - 1 loop
                     Queries (Step, Index) := Query (Index);
                  end loop;

                  if Item.Kind in Falcon | Phi2 then
                     for Index in 0 .. Width - 1 loop
                        Kept (Step, Index) := Held_Norm (Index);
                     end loop;
                  end if;
                  <<Projected>>
               end;
            end loop;

            --  And now that every key and value of this block is
            --  written, what each position makes of them.
            for Step in 0 .. Steps - 1 loop
               declare
                  Query   : Real_Vector (0 .. Q_Width - 1) :=
                    [others => 0.0];
                  Blended : Real_Vector (0 .. B_Width - 1) :=
                    [others => 0.0];
               begin
                  for Index in 0 .. Width - 1 loop
                     State (Index) := Whole (Step, Index);
                  end loop;

                  --  A linear block's answer was made in the first pass,
                  --  and it wrote no queries to read.
                  if Current.Linear then
                     for Index in 0 .. Width - 1 loop
                        Normed (Index) := Linear_Rows (Step, Index);
                     end loop;
                     goto Attended;
                  end if;

                  for Index in 0 .. Q_Width - 1 loop
                     Query (Index) := Queries (Step, Index);
                  end loop;
                  if Item.Kind in Falcon | Phi2 then
                     for Index in 0 .. Width - 1 loop
                        Held_Norm (Index) := Kept (Step, Index);
                     end loop;
                  end if;

                  --  Attention. The key and value heads are expanded to one per
                  --  query head rather than mapped, so a grouping mistake in the
                  --  engine cannot be reproduced here.
                  --  The scores are scaled by the root of the head's width,
                  --  except in Gemma 3's 27B, which scales by the root of
                  --  the width its embedding implies -- 168 to its heads'
                  --  128, the reference's query_pre_attn_scalar. No key in
                  --  the file says which; the depth does, sixty-two layers.
                  declare
                     Group : constant Natural := Item.Heads / Item.KV_Heads;
                     Scale : constant Long_Float :=
                       (if Item.Kind in Granite | Granite_MoE
                          and then Item.Attention_Mul /= 0.0
                        then Item.Attention_Mul
                        elsif Item.Kind = Gemma3 and then Item.Layers = 62
                        then 1.0 / Functions.Sqrt
                                     (Long_Float (Item.Embedding / Item.Heads))
                        else 1.0 / Functions.Sqrt (Long_Float (Item.Head_Size)));
                  begin
                     for Head in 0 .. Item.Heads - 1 loop
                        declare
                           Source_Head : constant Natural := Head / Group;

                           --  How steeply this head's attention falls off
                           --  with distance, for the one architecture told
                           --  where a token is by the scores.
                           --
                           --  Written as one exponent rather than as a base
                           --  raised to a rung: the heads below the largest
                           --  power of two not above the head count step
                           --  down by max_bias over that power a head, and
                           --  the heads above it step down by the same
                           --  amount offset half a step, which is what
                           --  interleaving the odd rungs of twice the
                           --  ladder comes to. Twelve heads and a bias of
                           --  eight give exponents 1 through 8 and then
                           --  0.5, 1.5, 2.5, 3.5.
                           Rungs : constant Natural := Ladder (Item.Heads);
                           Falls : constant Long_Float :=
                             (if Item.Max_Bias <= 0.0 then 0.0
                              else Item.Max_Bias / Long_Float (Rungs));
                           Slope : constant Long_Float :=
                             (if Falls = 0.0 then 0.0
                              elsif Head < Rungs
                              then Functions."**"
                                     (2.0,
                                      -(Falls * Long_Float (Head + 1)))
                              else Functions."**"
                                     (2.0,
                                      -(Falls
                                        * (Long_Float (Head - Rungs)
                                           + 0.5))));
                           --  The earliest position this one may look at. With
                           --  a window of four, a query at position ten reads
                           --  seven through ten.
                           --  Gemma2 windows every other layer, starting with
                           --  the first; everything else here windows all of
                           --  them or none.
                           --  Which layers slide a window: all of them where
                           --  the architecture states no pattern, and where it
                           --  does, all but the last of each period -- every
                           --  second layer for Gemma2 and every sixth for
                           --  Gemma3.
                           Windowed : constant Boolean :=
                             Item.Window /= 0
                             and then (Item.Window_Every = 0
                                       or else Block mod Item.Window_Every
                                               /= Item.Window_Every - 1);

                           --  The last position this query may read: its
                           --  own where the model generates, and the end of
                           --  the text where it attends both ways.
                           Ends : constant Natural :=
                             (if Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2
                              then Steps - 1 else Step);

                           First : constant Natural :=
                             (if not Windowed or else Step < Item.Window
                              then 0 else Step - Item.Window + 1);

                           Scores : Real_Vector (First .. Ends) :=
                             [others => 0.0];
                           Largest : Long_Float;
                           Total   : Long_Float := 0.0;
                        begin
                           for Past in First .. Ends loop
                              declare
                                 Where : constant Natural := Block * Steps + Past;
                                 Total_Score : Long_Float := 0.0;
                              begin
                                 for Component in 0 .. Item.Head_Size - 1 loop
                                    Total_Score := Total_Score
                                      + Query (Head * Item.Head_Size + Component)
                                        * Keys (Where,
                                                Source_Head * Item.Head_Size
                                                + Component);
                                 end loop;
                                 --  Scaled, then the fall-off with
                                 --  distance, then the bound: that is the
                                 --  order, and it is not free -- a bias
                                 --  taken off before the scale would be
                                 --  scaled with the score.
                                 --
                                 --  Held under the bound the architecture
                                 --  states, before the softmax reads it: a
                                 --  bound applied afterwards would be a bound
                                 --  on a probability and mean something else.
                                 declare
                                    Sized : constant Long_Float :=
                                      Total_Score * Scale
                                      - Slope
                                        * Long_Float (abs (Step - Past));
                                 begin
                                    Scores (Past) :=
                                      (if Item.Attention_Cap > 0.0
                                       then Item.Attention_Cap
                                            * Hyperbolic
                                                (Sized / Item.Attention_Cap)
                                       else Sized);
                                 end;
                              end;
                           end loop;

                           Largest := Scores (First);
                           for Past in Scores'Range loop
                              if Scores (Past) > Largest then
                                 Largest := Scores (Past);
                              end if;
                           end loop;

                           --  This head's sink, where the architecture
                           --  states one: a score that joins the maximum
                           --  and the total and takes none of the weight,
                           --  so a head with nothing worth attending to
                           --  answers small rather than answering with
                           --  whatever is nearest.
                           if Current.Sinks /= null then
                              declare
                                 Sink : constant Long_Float :=
                                   Current.Sinks.all (Head);
                              begin
                                 if Sink > Largest then
                                    Largest := Sink;
                                 end if;
                              end;
                           end if;

                           for Past in Scores'Range loop
                              Scores (Past) := Functions.Exp (Scores (Past) - Largest);
                              Total := Total + Scores (Past);
                           end loop;

                           if Current.Sinks /= null then
                              Total := Total
                                + Functions.Exp
                                    (Current.Sinks.all (Head) - Largest);
                           end if;

                           for Component in 0 .. Item.Value_Size - 1 loop
                              declare
                                 Sum : Long_Float := 0.0;
                              begin
                                 for Past in First .. Ends loop
                                    Sum := Sum + Scores (Past)
                                      * Values (Block * Steps + Past,
                                                Source_Head * Item.Value_Size
                                                + Component);
                                 end loop;
                                 Blended (Head * Item.Value_Size + Component) :=
                                   Sum / Total;
                              end;
                           end loop;
                        end;
                     end loop;
                  end;

                  --  Each head's blend through the unit of its gate, where
                  --  the query projection carried one.
                  if Item.Kind in Qwen35 | Qwen35_MoE then
                     for Index in 0 .. B_Width - 1 loop
                        Blended (Index) :=
                          Blended (Index)
                          * Logistic (Queries (Step, Q_Width + Index));
                     end loop;
                  end if;

                  Project (Current.Attention_Out.all, Blended, Normed);

                  <<Attended>>
                  if Current.Out_Bias /= null then
                     for Index in 0 .. Width - 1 loop
                        Normed (Index) :=
                          Normed (Index) + Current.Out_Bias.all (Index);
                     end loop;
                  end if;

                  --  Gemma2 normalizes what the sublayer produced before it
                  --  goes back into the residual; Bert adds it and then
                  --  normalizes the sum. The same tensor on either side of
                  --  the same addition, and two different models.
                  if Current.Post_Attention_Norm /= null
                    and then Item.Kind not in Bert | Nomic_Bert | Jina_Bert_V2
                  then
                     declare
                        Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                     begin
                        Normalize (Normed, Current.Post_Attention_Norm.all, Room);
                        Normed (0 .. Width - 1) := Room;
                     end;
                  end if;

                  --  Granite damps each sublayer's output before it joins
                  --  the residual; every other architecture adds it whole.
                  for Index in 0 .. Width - 1 loop
                     State (Index) := State (Index)
                       + (if Item.Kind in Granite | Granite_MoE
                            and then Item.Residual_Mul /= 0.0
                          then Item.Residual_Mul * Normed (Index)
                          else Normed (Index));
                  end loop;

                  if Current.Post_Attention_Norm /= null
                    and then Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2
                  then
                     declare
                        Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                     begin
                        Normalize_Centred
                          (State, Current.Post_Attention_Norm.all,
                           Current.Post_Attention_Norm_Bias, Room);
                        State (0 .. Width - 1) := Room;
                     end;
                  end if;

                  --  And the code variant's second: the layer's input,
                  --  which Whole still holds for this step, is added once
                  --  more to what the first normalized, and the sum is
                  --  normalized again by a gain and shift of its own.
                  if Current.Second_Attention_Norm /= null then
                     declare
                        Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                     begin
                        for Index in 0 .. Width - 1 loop
                           State (Index) := State (Index) + Whole (Step, Index);
                        end loop;
                        Normalize_Centred
                          (State, Current.Second_Attention_Norm.all,
                           Current.Second_Attention_Norm_Bias, Room);
                        State (0 .. Width - 1) := Room;
                     end;
                  end if;

                  --  Feed-forward block. It reads the block's own
                  --  normalized input where the two sublayers run in
                  --  parallel, the residual as it stands where the block
                  --  normalized it on the way out of attention, and a fresh
                  --  normalization of the residual where they run one after
                  --  the other.
                  if Item.Kind = Gptneox and then Item.Parallel then
                     --  Parallel residual: the feed-forward reads the layer's
                     --  input, still held in Whole, normalized by its own
                     --  centred normalization -- not the residual the
                     --  attention was added to.
                     declare
                        Original : Real_Vector (0 .. Width - 1);
                     begin
                        for Index in 0 .. Width - 1 loop
                           Original (Index) := Whole (Step, Index);
                        end loop;
                        Normalize_Centred
                          (Original, Current.Feed_Norm.all,
                           Current.Feed_Norm_Bias, Normed);
                     end;
                  elsif Item.Kind in Falcon | Phi2 then
                     Normed (0 .. Width - 1) := Held_Norm (0 .. Width - 1);
                  elsif Current.Feed_Norm = null then
                     Normed (0 .. Width - 1) := State (0 .. Width - 1);
                  elsif Item.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox | Mpt then
                     Normalize_Centred
                       (State, Current.Feed_Norm.all,
                        Current.Feed_Norm_Bias, Normed);
                  else
                     Normalize (State, Current.Feed_Norm.all, Normed);
                  end if;

                  Feed_Forward (Current, Normed);

                  if Current.Post_Feed_Norm /= null
                    and then Item.Kind not in Bert | Nomic_Bert | Jina_Bert_V2
                  then
                     declare
                        Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                     begin
                        Normalize (Normed, Current.Post_Feed_Norm.all, Room);
                        Normed (0 .. Width - 1) := Room;
                     end;
                  end if;

                  --  Granite damps the feed-forward output the same way it
                  --  damps the attention output before the residual add.
                  for Index in 0 .. Width - 1 loop
                     State (Index) := State (Index)
                       + (if Item.Kind in Granite | Granite_MoE
                            and then Item.Residual_Mul /= 0.0
                          then Item.Residual_Mul * Normed (Index)
                          else Normed (Index));
                  end loop;

                  if Current.Post_Feed_Norm /= null
                    and then Item.Kind in Bert | Nomic_Bert | Jina_Bert_V2
                  then
                     declare
                        Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                     begin
                        Normalize_Centred
                          (State, Current.Post_Feed_Norm.all,
                           Current.Post_Feed_Norm_Bias, Room);
                        State (0 .. Width - 1) := Room;
                     end;
                  end if;

                  for Index in 0 .. Width - 1 loop
                     Whole (Step, Index) := State (Index);
                  end loop;
               end;
            end loop;
         end;
      end loop;

      --  The last position, which is the one a caller asking for a
      --  distribution is asking about.
      for Index in 0 .. Width - 1 loop
         State (Index) := Whole (Steps - 1, Index);
      end loop;

      --  Every position's state, for the caller who asked for those. Taken
      --  from what the last block left rather than from a normalization
      --  after it: Bert is the model this is for and Bert's last block
      --  normalized what it produced.
      if Want_States then
         for Step in 0 .. Steps - 1 loop
            for Index in 0 .. Width - 1 loop
               States (States'First + Step * Width + Index) :=
                 Whole (Step, Index);
            end loop;
         end loop;
      end if;

      --  The block past the stack, asked for a draft: run through every
      --  position of the text in order, each position given the token
      --  after it beside the stack's state at it, both normalized and
      --  projected together into one input; then a full attention block
      --  over its own keys and values, with the gate beside each head;
      --  and at the last position the token the caller proposes for the
      --  one after the text, whose successor the head then draws. The
      --  stack's state is what the model's own head would read: the
      --  residual through the output normalization.
      if Draft_Token >= 0 then
         if Item.Next_Layers = 0 or else Draft_Token >= Item.Words
           or else Item.Output = null
           or else Logits'Length /= Item.Words
         then
            raise Constraint_Error;
         end if;

         declare
            Block : Layer renames Item.Blocks (Item.Layers);
            Group : constant Natural := Item.Heads / Item.KV_Heads;
            Scale : constant Long_Float :=
              1.0 / Functions.Sqrt (Long_Float (Item.Head_Size));

            Block_Keys   : History_Access :=
              new History (0 .. Steps - 1, 0 .. KV_Width - 1);
            Block_Values : History_Access :=
              new History (0 .. Steps - 1, 0 .. V_Width - 1);

            Input   : Real_Vector (0 .. Width - 1) := [others => 0.0];
            Joined  : Real_Vector (0 .. 2 * Width - 1) := [others => 0.0];
            Row     : Real_Vector (0 .. Width - 1) := [others => 0.0];
         begin
            for Step in 0 .. Steps - 1 loop
               declare
                  Tok : constant Natural :=
                    (if Step < Steps - 1
                     then Tokens (Tokens'First + Step + 1)
                     else Draft_Token);

                  Wide_Query : Real_Vector (0 .. 2 * Q_Width - 1) :=
                    [others => 0.0];
                  Query      : Real_Vector (0 .. Q_Width - 1) :=
                    [others => 0.0];
                  Head_Gate  : Real_Vector (0 .. Q_Width - 1) :=
                    [others => 0.0];
                  Key_Row    : Real_Vector (0 .. KV_Width - 1) :=
                    [others => 0.0];
                  Val_Row    : Real_Vector (0 .. V_Width - 1) :=
                    [others => 0.0];
                  Blended    : Real_Vector (0 .. B_Width - 1) :=
                    [others => 0.0];
               begin
                  --  The next token's embedding and the stack's state at
                  --  this position, each normalized, side by side.
                  for Index in 0 .. Width - 1 loop
                     Row (Index) := Item.Embeddings (Tok, Index);
                  end loop;
                  Normalize (Row, Item.Next_Enorm.all, Normed);
                  Joined (0 .. Width - 1) := Normed;

                  for Index in 0 .. Width - 1 loop
                     State (Index) := Whole (Step, Index);
                  end loop;
                  Normalize (State, Item.Output_Norm.all, Row);
                  Normalize (Row, Item.Next_Hnorm.all, Normed);
                  Joined (Width .. 2 * Width - 1) := Normed;

                  Project (Item.Next_Proj.all, Joined, Input);

                  --  The block's attention, as the stack's full blocks
                  --  attend, over what the block was given at the
                  --  positions before.
                  Normalize (Input, Block.Attention_Norm.all, Normed);
                  Project (Block.Query.all, Normed, Wide_Query);
                  for Head in 0 .. Item.Heads - 1 loop
                     for Index in 0 .. Item.Head_Size - 1 loop
                        Query (Head * Item.Head_Size + Index) :=
                          Wide_Query (Head * 2 * Item.Head_Size + Index);
                        Head_Gate (Head * Item.Head_Size + Index) :=
                          Wide_Query
                            (Head * 2 * Item.Head_Size + Item.Head_Size
                             + Index);
                     end loop;
                  end loop;
                  Project (Block.Key.all, Normed, Key_Row);
                  Project (Block.Value.all, Normed, Val_Row);
                  Normalize_Heads
                    (Query, Item.Heads, Item.Head_Size, Block.Query_Norm.all);
                  Normalize_Heads
                    (Key_Row, Item.KV_Heads, Item.Head_Size,
                     Block.Key_Norm.all);
                  Rotate (Query, Item.Heads, Step, Item.Layers);
                  Rotate (Key_Row, Item.KV_Heads, Step, Item.Layers);
                  for Index in 0 .. KV_Width - 1 loop
                     Block_Keys (Step, Index) := Key_Row (Index);
                  end loop;
                  for Index in 0 .. V_Width - 1 loop
                     Block_Values (Step, Index) := Val_Row (Index);
                  end loop;

                  for Head in 0 .. Item.Heads - 1 loop
                     declare
                        Source_Head : constant Natural := Head / Group;
                        Scores  : Real_Vector (0 .. Step) := [others => 0.0];
                        Largest : Long_Float;
                        Total   : Long_Float := 0.0;
                     begin
                        for Past in 0 .. Step loop
                           for Component in 0 .. Item.Head_Size - 1 loop
                              Scores (Past) := Scores (Past)
                                + Query (Head * Item.Head_Size + Component)
                                  * Block_Keys
                                      (Past,
                                       Source_Head * Item.Head_Size
                                       + Component);
                           end loop;
                           Scores (Past) := Scores (Past) * Scale;
                        end loop;

                        Largest := Scores (0);
                        for Past in 0 .. Step loop
                           if Scores (Past) > Largest then
                              Largest := Scores (Past);
                           end if;
                        end loop;
                        for Past in 0 .. Step loop
                           Scores (Past) :=
                             Functions.Exp (Scores (Past) - Largest);
                           Total := Total + Scores (Past);
                        end loop;

                        for Component in 0 .. Item.Value_Size - 1 loop
                           declare
                              Sum : Long_Float := 0.0;
                           begin
                              for Past in 0 .. Step loop
                                 Sum := Sum
                                   + Scores (Past)
                                     * Block_Values
                                         (Past,
                                          Source_Head * Item.Value_Size
                                          + Component);
                              end loop;
                              Blended (Head * Item.Value_Size + Component) :=
                                Sum / Total;
                           end;
                        end loop;
                     end;
                  end loop;

                  for Index in 0 .. B_Width - 1 loop
                     Blended (Index) :=
                       Blended (Index) * Logistic (Head_Gate (Index));
                  end loop;
                  Project (Block.Attention_Out.all, Blended, Normed);
                  for Index in 0 .. Width - 1 loop
                     Input (Index) := Input (Index) + Normed (Index);
                  end loop;

                  Normalize (Input, Block.Feed_Norm.all, Normed);
                  Feed_Forward (Block, Normed);
                  for Index in 0 .. Width - 1 loop
                     Input (Index) := Input (Index) + Normed (Index);
                  end loop;
               end;
            end loop;

            --  What the block made at the last position, through the
            --  block's own normalization and the model's head.
            Normalize (Input, Item.Next_Head_Norm.all, Normed);
            Project (Item.Output.all, Normed, Logits);

            Free_History (Block_Keys);
            Free_History (Block_Values);
         end;
      elsif Item.Output /= null then
         if Item.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox | Mpt then
            Normalize_Centred
              (State, Item.Output_Norm.all, Item.Output_Norm_Bias, Normed);
         else
            Normalize (State, Item.Output_Norm.all, Normed);
         end if;
         Project (Item.Output.all, Normed, Logits);
      end if;

      if Item.Output_Bias /= null then
         for Index in Logits'Range loop
            Logits (Index) :=
              Logits (Index)
              + Item.Output_Bias.all
                  (Item.Output_Bias'First + Index - Logits'First);
         end loop;
      end if;

      --  Granite divides its logits by a scalar the file carries, before
      --  any bound. It states no bound, so the order is moot, but the
      --  division is the last thing the model does to them.
      if Item.Kind in Granite | Granite_MoE and then Item.Logit_Mul /= 0.0 then
         for Index in Logits'Range loop
            Logits (Index) := Logits (Index) / Item.Logit_Mul;
         end loop;
      end if;

      --  And the bound on the logits, which is the last thing the model
      --  does and the first thing a caller sees.
      if Item.Logit_Cap > 0.0 then
         for Index in Logits'Range loop
            Logits (Index) :=
              Item.Logit_Cap * Hyperbolic (Logits (Index) / Item.Logit_Cap);
         end loop;
      end if;

      Free_History (Keys);
      Free_History (Values);
      Free_History (Whole);
      Free_History (Queries);
      Free_History (Kept);
      Free_History (Linear_Rows);
      Ok := True;
   exception
      when others =>
         Free_History (Keys);
         Free_History (Values);
         Free_History (Whole);
         Free_History (Queries);
         Free_History (Kept);
         Free_History (Linear_Rows);
         Ok := False;
   end Evaluate;

   ----------------------------
   -- Round_Cache_To_Nibbles --
   ----------------------------

   procedure Round_Cache_To_Nibbles (Item : in out Model; On : Boolean) is
   begin
      Item.Key_Rounding := (if On then To_Nibbles else Unrounded);
      Item.Value_Rounding := Item.Key_Rounding;
   end Round_Cache_To_Nibbles;

   -----------------
   -- Round_Cache --
   -----------------

   procedure Round_Cache
     (Item : in out Model; Keys, Values : Cache_Rounding) is
   begin
      Item.Key_Rounding := Keys;
      Item.Value_Rounding := Values;
   end Round_Cache;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : in out Model;
      Tokens : Token_Vector;
      Logits : out Real_Vector;
      Ok     : out Boolean)
   is
      Nothing : Real_Vector (1 .. 0);
   begin
      Evaluate (Item, Tokens, Logits, Nothing, False, Ok);
   end Run;

   ----------------
   -- Run_States --
   ----------------

   function Drafts (Item : Model) return Boolean
   is (Item.Loaded and then Item.Next_Layers > 0);

   -----------
   -- Draft --
   -----------

   procedure Draft
     (Item   : in out Model;
      Tokens : Token_Vector;
      Next   : Natural;
      Logits : out Real_Vector;
      Ok     : out Boolean)
   is
      Nothing : Real_Vector (1 .. 0);
   begin
      Evaluate (Item, Tokens, Logits, Nothing, False, Ok, Draft_Token => Next);
   end Draft;

   procedure Run_States
     (Item   : in out Model;
      Tokens : Token_Vector;
      States : out Real_Vector;
      Ok     : out Boolean)
   is
      Nothing : Real_Vector (1 .. 0);
   begin
      Evaluate (Item, Tokens, Nothing, States, True, Ok);
   end Run_States;

end Reference_Transformer;
