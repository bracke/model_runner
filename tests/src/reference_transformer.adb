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
         when Gemma     => "gemma.",
         when Gemma2    => "gemma2.",
         when Gemma3    => "gemma3.",
         when Phi3      => "phi3.",
         when Falcon    => "falcon.",
         when Phi2      => "phi2.",
         when GPT2      => "gpt2.");

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
      end;

      --  The period of the window pattern, which the architecture states by
      --  being what it is rather than by a key: two for Gemma2 and six for
      --  Gemma3.
      Item.Window_Every :=
        (case Item.Kind is
            when Gemma2 => 2,
            when Gemma3 => 6,
            when others => 0);

      Item.Experts := Metadata (Source, Prefix (Item) & "expert_count", 0);
      Item.Experts_Used :=
        Metadata (Source, Prefix (Item) & "expert_used_count", 0);
      Item.Expert_Feed :=
        Metadata
          (Source, Prefix (Item) & "expert_feed_forward_length",
           Item.Feed_Forward);
      if Item.Window >= Item.Context then
         Item.Window := 0;
      end if;
      Item.Rotary :=
        Metadata (Source, Prefix (Item) & "rope.dimension_count", Item.Head_Size);

      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Containers.Get_Float
           (Source, Prefix (Item) & "attention.layer_norm_rms_epsilon",
            0.0, 1.0, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Epsilon := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "rope.freq_base", 1.0, 1.0E12, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Rope_Base := Long_Float (Value);
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
      if Item.Kind = GPT2 then
         Item.Positions := Read_Matrix ("position_embd.weight", Present);
         if not Present then
            return;
         end if;
      end if;

      Item.Output_Norm := Read_Vector ("output_norm.weight", Present);
      if Present and then Item.Kind in Falcon | Phi2 | GPT2 then
         Item.Output_Norm_Bias :=
           Read_Vector ("output_norm.bias", Present);
      end if;
      if not Present then
         return;
      end if;

      --  The per-dimension divisors, when the file carries them. Absent is
      --  not a failure: most files have none.
      declare
         Ignored : Boolean;
      begin
         Item.Rope_Factors := Read_Vector ("rope_freqs.weight", Ignored);
      end;

      Item.Output := Read_Matrix ("output.weight", Present);
      if not Present then
         --  A tied model reuses the embedding table as the output projection.
         Item.Output := Item.Embeddings;
      elsif Item.Kind in Phi2 | GPT2 then
         Item.Output_Bias := Read_Vector ("output.bias", Present);
         if not Present then
            return;
         end if;
      end if;

      Item.Blocks := new Layer_Array (0 .. Item.Layers - 1);

      for Index in Item.Blocks'Range loop
         declare
            Current : Layer renames Item.Blocks (Index);
         begin
            Current.Attention_Norm :=
              Read_Vector (Layer_Name (Index, "attn_norm.weight"), Present);
            if not Present then
               return;
            end if;

            --  Gemma2's two extra normalizations, required where the
            --  architecture states them.
            if Item.Kind in Falcon | Phi2 | GPT2 then
               Current.Attention_Norm_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_norm.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            if Item.Kind in Gemma2 | Gemma3 then
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

            --  Phi3's three attention projections come out of one tensor,
            --  in the order the rows are written: queries, keys, values.
            if Item.Kind in Phi3 | Falcon | Phi2 | GPT2 then
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

            if Item.Kind in Phi3 | Falcon | Phi2 | GPT2 then
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

            if Item.Kind in Phi3 | Falcon | Phi2 | GPT2 then
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
            if Item.Kind in Phi2 | GPT2 then
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

            if Item.Kind = Qwen2 then
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
            if Item.Kind in Qwen3 | Qwen3_MoE | Gemma3 then
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

            Current.Attention_Out :=
              Read_Matrix (Layer_Name (Index, "attn_output.weight"), Present);
            if not Present then
               return;
            end if;

            if Item.Kind in Phi2 | GPT2 then
               Current.Out_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_output.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            --  Falcon and Phi2 have one normalization a block: their
            --  feed-forward reads what attention read.
            if Item.Kind not in Falcon | Phi2 then
               Current.Feed_Norm :=
                 Read_Vector (Layer_Name (Index, "ffn_norm.weight"), Present);
               if not Present then
                  return;
               end if;
            end if;

            if Item.Experts > 0 then
               Current.Router :=
                 Read_Matrix (Layer_Name (Index, "ffn_gate_inp.weight"),
                              Present);
               if not Present then
                  return;
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
            else
               if Item.Kind in Falcon | Phi2 | GPT2 then
                  --  No gate at all: one projection up, a Gaussian unit,
                  --  one projection down.
                  Current.Gate := null;
                  Present := True;
               elsif Item.Kind = Phi3 then
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

               if Item.Kind = Phi3 then
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

               --  A bias on each side of the block, which Phi2 has and
               --  Falcon does not.
               if Item.Kind in Phi2 | GPT2 then
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
            Free_Matrix (Item.Blocks (Index).Query);
            Free_Matrix (Item.Blocks (Index).Key);
            Free_Matrix (Item.Blocks (Index).Value);
            Free_Vector (Item.Blocks (Index).Query_Norm);
            Free_Vector (Item.Blocks (Index).Key_Norm);
            Free_Matrix (Item.Blocks (Index).Attention_Out);
            Free_Vector (Item.Blocks (Index).Feed_Norm);
            Free_Matrix (Item.Blocks (Index).Router);
            Free_Matrix (Item.Blocks (Index).Gate_Experts);
            Free_Matrix (Item.Blocks (Index).Up_Experts);
            Free_Matrix (Item.Blocks (Index).Down_Experts);
            Free_Matrix (Item.Blocks (Index).Gate);
            Free_Matrix (Item.Blocks (Index).Up);
            Free_Matrix (Item.Blocks (Index).Down);
         end loop;
         Free_Layers (Item.Blocks);
      end if;

      if not Tied then
         Free_Matrix (Item.Output);
      end if;
      Item.Output := null;

      Free_Matrix (Item.Embeddings);
      Free_Vector (Item.Output_Norm);
      Free_Vector (Item.Rope_Factors);
      Item.Loaded := False;
      Item.Words := 0;
   end Close;

   ----------------
   -- Vocabulary --
   ----------------

   function Vocabulary (Item : Model) return Natural is (Item.Words);

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : in out Model;
      Tokens : Token_Vector;
      Logits : out Real_Vector;
      Ok     : out Boolean)
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
         if Item.Kind in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 then
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

            --  Gemma stores its normalization weights around zero and uses
            --  one plus them as the gain. Written as the architecture states
            --  it rather than as the engine implements it: the engine has a
            --  flag on its kernel, and this has the addition where the
            --  formula puts it.
            Lift : constant Long_Float :=
              (if Item.Kind in Gemma | Gemma2 | Gemma3 then 1.0 else 0.0);
         begin
            for Index in Source'Range loop
               Target (Index) :=
                 Source (Index) * Scale * (Lift + Gain (Index));
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

                  --  The angle as trained, and the angle the model's factor
                  --  stretches it to.
                  Trained_Angle : constant Long_Float :=
                    Long_Float (Position) * Frequency;
                  Stretched : constant Long_Float :=
                    Item.Frequency * Trained_Angle;

                  --  Yarn keeps the fast dimensions as trained and stretches
                  --  the slow ones, mixing across the band between them. The
                  --  band's edges are the dimensions that turn Beta_Fast and
                  --  Beta_Slow times over the context the model was trained
                  --  on, which is what solving the frequency for the
                  --  dimension gives.
                  Mixed : constant Long_Float :=
                    (if Item.Stretch /= Yarn then 0.0
                     else Ramp (Long_Float (Pair), Base));

                  Angle : constant Long_Float :=
                    (if Item.Stretch = Yarn
                     then Stretched * (1.0 - Mixed) + Trained_Angle * Mixed
                     else Stretched);

                  --  And it scales what comes out, because interpolating
                  --  angles brings the scores they produce together.
                  Size : constant Long_Float :=
                    (if Item.Stretch = Yarn
                     then Item.Attenuation
                          * (1.0 + 0.1 * Functions.Log (1.0 / Item.Frequency))
                     else 1.0);
                  --  Llama pairs an element with its neighbour; Qwen2
                  --  pairs it with the one half a rotation later. Written
                  --  out here rather than shared with the engine: the point
                  --  of this implementation is to be arrived at separately,
                  --  and a shared rotation would agree with itself.
                  Even  : constant Natural :=
                    (if Item.Kind = Llama
                     then Head * Item.Head_Size + 2 * Pair
                     else Head * Item.Head_Size + Pair);
                  Odd   : constant Natural :=
                    (if Item.Kind = Llama
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

   begin
      Ok := False;
      Logits := [others => 0.0];

      if not Item.Loaded or else Steps = 0
        or else Logits'Length /= Item.Words
      then
         return;
      end if;

      for Token of Tokens loop
         if Token >= Item.Words then
            return;
         end if;
      end loop;

      Keys := new History (0 .. Item.Layers * Steps - 1, 0 .. KV_Width - 1);
      Values := new History (0 .. Item.Layers * Steps - 1, 0 .. V_Width - 1);

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
         end;

         for Block in 0 .. Item.Layers - 1 loop
            declare
               Current : Layer renames Item.Blocks (Block);
               Query   : Real_Vector (0 .. Q_Width - 1) := [others => 0.0];
               Key_Row : Real_Vector (0 .. KV_Width - 1) := [others => 0.0];
               Val_Row : Real_Vector (0 .. V_Width - 1) := [others => 0.0];
               Blended : Real_Vector (0 .. B_Width - 1) := [others => 0.0];
               Slot    : constant Natural := Block * Steps + Step;
            begin
               if Item.Kind in Falcon | Phi2 | GPT2 then
                  Normalize_Centred
                    (State, Current.Attention_Norm.all,
                     Current.Attention_Norm_Bias, Normed);
               else
                  Normalize (State, Current.Attention_Norm.all, Normed);
               end if;

               --  Kept, because Falcon's feed-forward reads this and not
               --  what attention produced.
               if Current.Feed_Norm = null then
                  Held_Norm (0 .. Width - 1) := Normed (0 .. Width - 1);
               end if;
               Project (Current.Query.all, Normed, Query);
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

               Rotate (Query, Item.Heads, Step, Block);
               Rotate (Key_Row, Item.KV_Heads, Step, Block);

               for Index in 0 .. KV_Width - 1 loop
                  Keys (Slot, Index) := Key_Row (Index);
               end loop;
               for Index in 0 .. V_Width - 1 loop
                  Values (Slot, Index) := Val_Row (Index);
               end loop;

               --  Attention. The key and value heads are expanded to one per
               --  query head rather than mapped, so a grouping mistake in the
               --  engine cannot be reproduced here.
               declare
                  Group : constant Natural := Item.Heads / Item.KV_Heads;
                  Scale : constant Long_Float :=
                    1.0 / Functions.Sqrt (Long_Float (Item.Head_Size));
               begin
                  for Head in 0 .. Item.Heads - 1 loop
                     declare
                        Source_Head : constant Natural := Head / Group;
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

                        First : constant Natural :=
                          (if not Windowed or else Step < Item.Window
                           then 0 else Step - Item.Window + 1);

                        Scores : Real_Vector (First .. Step) :=
                          [others => 0.0];
                        Largest : Long_Float;
                        Total   : Long_Float := 0.0;
                     begin
                        for Past in First .. Step loop
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
                              --  Held under the bound the architecture
                              --  states, before the softmax reads it: a
                              --  bound applied afterwards would be a bound
                              --  on a probability and mean something else.
                              Scores (Past) :=
                                (if Item.Attention_Cap > 0.0
                                 then Item.Attention_Cap
                                      * Hyperbolic
                                          (Total_Score * Scale
                                           / Item.Attention_Cap)
                                 else Total_Score * Scale);
                           end;
                        end loop;

                        Largest := Scores (First);
                        for Past in Scores'Range loop
                           if Scores (Past) > Largest then
                              Largest := Scores (Past);
                           end if;
                        end loop;

                        for Past in Scores'Range loop
                           Scores (Past) := Functions.Exp (Scores (Past) - Largest);
                           Total := Total + Scores (Past);
                        end loop;

                        for Component in 0 .. Item.Value_Size - 1 loop
                           declare
                              Sum : Long_Float := 0.0;
                           begin
                              for Past in First .. Step loop
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

               Project (Current.Attention_Out.all, Blended, Normed);

               if Current.Out_Bias /= null then
                  for Index in 0 .. Width - 1 loop
                     Normed (Index) :=
                       Normed (Index) + Current.Out_Bias.all (Index);
                  end loop;
               end if;

               --  Gemma2 normalizes what the sublayer produced before it
               --  goes back into the residual. Written where the addition
               --  is, because that is where the architecture puts it.
               if Current.Post_Attention_Norm /= null then
                  declare
                     Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                  begin
                     Normalize (Normed, Current.Post_Attention_Norm.all, Room);
                     Normed (0 .. Width - 1) := Room;
                  end;
               end if;

               for Index in 0 .. Width - 1 loop
                  State (Index) := State (Index) + Normed (Index);
               end loop;

               --  Feed-forward block.
               if Current.Feed_Norm = null then
                  Normed (0 .. Width - 1) := Held_Norm (0 .. Width - 1);
               else
                  Normalize (State, Current.Feed_Norm.all, Normed);
               end if;

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
                        Share (Slot) := Share (Slot) / Total;
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

                           --  Through the same gate the dense block uses,
                           --  which is the architecture's and not a copy of
                           --  one. This was the logistic written out, and a
                           --  mixture under an architecture with a
                           --  different gate then disagreed with the engine
                           --  by two logits in three -- while every gate
                           --  either implementation printed matched, because
                           --  the dense blocks were never the ones that
                           --  differed.
                           for Index in Gate'Range loop
                              Gate (Index) :=
                                Gated (Gate (Index)) * Up (Index);
                           end loop;

                           Project_Rows
                             (Current.Down_Experts.all, Rows_Down, Gate,
                              Out_Row);

                           for Index in Sum'Range loop
                              Sum (Index) :=
                                Sum (Index) + Share (Slot) * Out_Row (Index);
                           end loop;
                        end;
                     end loop;

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

               if Current.Post_Feed_Norm /= null then
                  declare
                     Room : Real_Vector (0 .. Width - 1) := [others => 0.0];
                  begin
                     Normalize (Normed, Current.Post_Feed_Norm.all, Room);
                     Normed (0 .. Width - 1) := Room;
                  end;
               end if;

               for Index in 0 .. Width - 1 loop
                  State (Index) := State (Index) + Normed (Index);
               end loop;
            end;
         end loop;
      end loop;

      if Item.Kind in Falcon | Phi2 | GPT2 then
         Normalize_Centred
           (State, Item.Output_Norm.all, Item.Output_Norm_Bias, Normed);
      else
         Normalize (State, Item.Output_Norm.all, Normed);
      end if;
      Project (Item.Output.all, Normed, Logits);

      if Item.Output_Bias /= null then
         for Index in Logits'Range loop
            Logits (Index) :=
              Logits (Index)
              + Item.Output_Bias.all
                  (Item.Output_Bias'First + Index - Logits'First);
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
      Ok := True;
   exception
      when others =>
         Free_History (Keys);
         Free_History (Values);
         Ok := False;
   end Run;

end Reference_Transformer;
