with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Conversion;

package body Model_Runner.Numerics is

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   package Wide_Functions is
     new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   function To_Bits is
     new Ada.Unchecked_Conversion (Real, Interfaces.Unsigned_32);
   function To_Value is
     new Ada.Unchecked_Conversion (Interfaces.Unsigned_32, Real);
   function Wide_To_Bits is
     new Ada.Unchecked_Conversion (Wide_Real, Interfaces.Unsigned_64);
   function Wide_To_Value is
     new Ada.Unchecked_Conversion (Interfaces.Unsigned_64, Wide_Real);

   ---------------
   -- Wide_Bits --
   ---------------

   function Wide_Bits (Item : Wide_Real) return Interfaces.Unsigned_64
   is (Wide_To_Bits (Item));

   --------------------
   -- Wide_From_Bits --
   --------------------

   function Wide_From_Bits (Item : Interfaces.Unsigned_64) return Wide_Real
   is (Wide_To_Value (Item));

   Exponent_Mask : constant Interfaces.Unsigned_32 := 16#7F80_0000#;
   Mantissa_Mask : constant Interfaces.Unsigned_32 := 16#007F_FFFF#;

   ----------
   -- Bits --
   ----------

   function Bits (Item : Real) return Interfaces.Unsigned_32
   is (To_Bits (Item));

   ---------------
   -- From_Bits --
   ---------------

   --  This is the boundary where arbitrary bytes from a model file become a
   --  number, so a not-a-number or an infinity is an expected result, not a
   --  fault: Is_Finite and Is_NaN exist to test for exactly that, and the
   --  kernels reject non-finite values with a diagnostic. Validity checking
   --  would instead raise here, turning a hostile file into an exception
   --  before anything could report what was wrong with it.
   function From_Bits (Item : Interfaces.Unsigned_32) return Real is
      pragma Suppress (Validity_Check);
   begin
      return To_Value (Item);
   end From_Bits;

   ---------------
   -- Is_Finite --
   ---------------

   --  Asking whether a value is a number is not a use of it as one, but
   --  validity checking cannot tell those apart and would raise here -- in
   --  the very predicate written to answer the question. Every caller that
   --  handles hostile input reaches a non-finite value through this.
   function Is_Finite (Item : Real) return Boolean is
      pragma Suppress (Validity_Check);
   begin
      return (To_Bits (Item) and Exponent_Mask) /= Exponent_Mask;
   end Is_Finite;

   ---------------
   -- Is_Finite --
   ---------------

   function Is_Finite (Item : Wide_Real) return Boolean is
      pragma Suppress (Validity_Check);
   begin
      return (Wide_To_Bits (Item) and 16#7FF0_0000_0000_0000#)
        /= 16#7FF0_0000_0000_0000#;
   end Is_Finite;

   ------------
   -- Is_NaN --
   ------------

   function Is_NaN (Item : Real) return Boolean is
      pragma Suppress (Validity_Check);
      Raw : constant Interfaces.Unsigned_32 := To_Bits (Item);
   begin
      return (Raw and Exponent_Mask) = Exponent_Mask
        and then (Raw and Mantissa_Mask) /= 0;
   end Is_NaN;

   -------------
   -- To_Real --
   -------------

   --  Half precision has infinities and not-a-numbers, and a model file may
   --  carry either as a block scale. Producing one is this function's job --
   --  Is_Finite exists so callers can ask -- but validity checking raises on
   --  the result before any caller can look at it, turning a hostile file into
   --  an exception instead of a diagnostic. Same reason as From_Bits below.
   function To_Real (Item : Half) return Real is
      pragma Suppress (Validity_Check);

      --  Widening without deciding anything.
      --
      --  The old form asked which kind of value it had -- zero, subnormal,
      --  infinity, normal -- and normalised a subnormal by shifting one bit
      --  at a time until the leading bit appeared. A loop whose length
      --  depends on the value cannot be vectorised, and that is why this
      --  format decoded slower than the quantized ones.
      --
      --  This computes both answers and takes one. The normal case is the
      --  exponent and mantissa shifted into binary32 places and scaled by
      --  the difference in bias; the subnormal case is the mantissa read as
      --  the fraction of a number just above one, less that one. Infinity
      --  and not-a-number come out of the normal case unchanged, because
      --  scaling by a power of two leaves the widest exponent widest.
      Raw   : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Interfaces.Unsigned_16 (Item));
      Wide  : constant Interfaces.Unsigned_32 := Interfaces.Shift_Left (Raw, 16);
      Sign  : constant Interfaces.Unsigned_32 := Wide and 16#8000_0000#;
      Twice : constant Interfaces.Unsigned_32 := Wide + Wide;

      --  2.0**(-112), the bias correction, as a binary32.
      Bias_Scale : constant Real := To_Value (Interfaces.Shift_Left (15, 23));

      Normal : constant Real :=
        To_Value (Interfaces.Shift_Right (Twice, 4)
                  + Interfaces.Shift_Left (16#E0#, 23))
        * Bias_Scale;

      Small : constant Real :=
        To_Value (Interfaces.Shift_Right (Twice, 17)
                  or Interfaces.Shift_Left (126, 23))
        - 0.5;

      --  Below this, the exponent was zero and the value is subnormal.
      Cutoff : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left (1, 27);
   begin
      return
        To_Value
          (Sign
           or To_Bits (if Twice < Cutoff then Small else Normal));
   end To_Real;

   -------------
   -- To_Half --
   -------------

   function To_Half (Item : Real) return Half is
      pragma Suppress (Validity_Check);
      Raw      : constant Interfaces.Unsigned_32 := To_Bits (Item);
      Sign     : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Interfaces.Shift_Right (Raw, 16) and 16#8000#);
      Exponent : constant Integer :=
        Integer (Interfaces.Shift_Right (Raw, 23) and 16#FF#);
      Mantissa : constant Interfaces.Unsigned_32 := Raw and Mantissa_Mask;
   begin
      if Exponent = 16#FF# then
         if Mantissa = 0 then
            return Half (Sign or 16#7C00#);
         else
            --  Keep NaN a NaN even when the truncated payload would be zero.
            return
              Half
                (Sign or 16#7C00#
                 or Interfaces.Unsigned_16
                      (Interfaces.Shift_Right (Mantissa, 13))
                 or 1);
         end if;
      end if;

      declare
         Unbiased : constant Integer := Exponent - 127;
      begin
         if Unbiased > 15 then
            --  Overflow to infinity.
            return Half (Sign or 16#7C00#);

         elsif Unbiased >= -14 then
            --  Normal in binary16. Round to nearest, ties to even.
            declare
               Low       : constant Interfaces.Unsigned_32 :=
                 Mantissa and 16#1FFF#;
               Truncated : Interfaces.Unsigned_32 :=
                 Interfaces.Shift_Right (Mantissa, 13);
               Biased    : Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Unbiased + 15);
            begin
               if Low > 16#1000#
                 or else (Low = 16#1000# and then (Truncated and 1) = 1)
               then
                  Truncated := Truncated + 1;
                  if Truncated = 16#400# then
                     Truncated := 0;
                     Biased := Biased + 1;
                     if Biased >= 16#1F# then
                        return Half (Sign or 16#7C00#);
                     end if;
                  end if;
               end if;

               return
                 Half
                   (Sign
                    or Interfaces.Unsigned_16
                         (Interfaces.Shift_Left (Biased, 10))
                    or Interfaces.Unsigned_16 (Truncated));
            end;

         elsif Unbiased >= -25 then
            --  Include the interval between zero and the smallest subnormal:
            --  values above its midpoint round up, while the tie rounds to
            --  even zero. Reinstate the leading bit before rounding.
            declare
               Full  : constant Interfaces.Unsigned_32 :=
                 Mantissa or 16#0080_0000#;
               Shift : constant Natural := Natural (-Unbiased - 14 + 13);
               Value : Interfaces.Unsigned_32 :=
                 Interfaces.Shift_Right (Full, Shift);
               Rest  : constant Interfaces.Unsigned_32 :=
                 Full and (Interfaces.Shift_Left (1, Shift) - 1);
               Halfway : constant Interfaces.Unsigned_32 :=
                 Interfaces.Shift_Left (1, Shift - 1);
            begin
               if Rest > Halfway
                 or else (Rest = Halfway and then (Value and 1) = 1)
               then
                  Value := Value + 1;
               end if;
               return Half (Sign or Interfaces.Unsigned_16 (Value));
            end;

         else
            --  Underflow to a signed zero.
            return Half (Sign);
         end if;
      end;
   end To_Half;

   ------------------
   -- E4M3 To_Real --
   ------------------

   function To_Real (Item : E4M3) return Real is
      pragma Suppress (Validity_Check);
      Raw      : constant Interfaces.Unsigned_8 := Interfaces.Unsigned_8 (Item);
      Negative : constant Boolean := (Raw and 16#80#) /= 0;
      Exponent : constant Interfaces.Unsigned_8 :=
        Interfaces.Shift_Right (Raw and 16#78#, 3);
      Fraction : constant Interfaces.Unsigned_8 := Raw and 7;
      Bits      : Interfaces.Unsigned_32;
   begin
      if Exponent = 0 then
         if Fraction = 0 then
            Bits := (if Negative then 16#8000_0000# else 0);
         else
            declare
               Value : constant Real := Real (Fraction) / 512.0;
            begin
               Bits := Model_Runner.Numerics.Bits (Value);
               if Negative then
                  Bits := Bits or 16#8000_0000#;
               end if;
            end;
         end if;
      elsif Exponent = 15 and then Fraction = 7 then
         Bits := 16#7FC0_0000#
           or (if Negative then 16#8000_0000# else 0);
      else
         Bits :=
           (if Negative then 16#8000_0000# else 0)
           or Interfaces.Shift_Left
                (Interfaces.Unsigned_32 (Exponent) + 120, 23)
           or Interfaces.Shift_Left
                (Interfaces.Unsigned_32 (Fraction), 20);
      end if;
      return From_Bits (Bits);
   end To_Real;

   -------------
   -- To_E4M3 --
   -------------

   function To_E4M3 (Item : Real) return E4M3 is
      pragma Suppress (Validity_Check);
      Raw      : constant Interfaces.Unsigned_32 := To_Bits (Item);
      Sign     : constant Interfaces.Unsigned_8 :=
        (if (Raw and 16#8000_0000#) /= 0 then 16#80# else 0);
      Exponent : constant Integer :=
        Integer (Interfaces.Shift_Right (Raw, 23) and 16#FF#);
      Mantissa : constant Interfaces.Unsigned_32 := Raw and Mantissa_Mask;

      function Nearest_Even (Value : Real) return Integer is
         Below : constant Real := Real'Floor (Value);
         Whole : constant Integer := Integer (Below);
         Part  : constant Real := Value - Below;
      begin
         if Part > 0.5 or else (Part = 0.5 and then Whole mod 2 /= 0) then
            return Whole + 1;
         else
            return Whole;
         end if;
      end Nearest_Even;
   begin
      if Exponent = 16#FF# then
         return E4M3 (Sign or (if Mantissa = 0 then 16#7E# else 16#7F#));
      elsif Exponent = 0 and then Mantissa = 0 then
         return E4M3 (Sign);
      end if;

      declare
         Magnitude : constant Real :=
           From_Bits (Raw and 16#7FFF_FFFF#);
         Power     : constant Integer := Exponent - 127;
         Quantized : Integer;
         Encoded   : Interfaces.Unsigned_8;
      begin
         if Power < -6 then
            Quantized := Nearest_Even (Magnitude * 512.0);
            Encoded := Interfaces.Unsigned_8
              (Integer'Min (8, Integer'Max (0, Quantized)));
         elsif Power > 8 then
            Encoded := 16#7E#;
         else
            Quantized := Nearest_Even
              (Magnitude / (2.0 ** (Power - 3)));
            if Quantized = 16 then
               Quantized := 8;
               if Power = 8 then
                  Encoded := 16#7E#;
               else
                  Encoded := Interfaces.Unsigned_8
                    ((Power + 8) * 8 + Quantized - 8);
               end if;
            elsif Power = 8 then
               Encoded := Interfaces.Unsigned_8
                 (Integer'Min (16#7E#, 15 * 8 + Quantized - 8));
            else
               Encoded := Interfaces.Unsigned_8
                 ((Power + 7) * 8 + Quantized - 8);
            end if;
         end if;
         return E4M3 (Sign or Encoded);
      end;
   end To_E4M3;

   ---------
   -- Exp --
   ---------

   ----------
   -- Tanh --
   ----------

   function Tanh (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) then
         return (if Item > 0.0 then 1.0 else -1.0);
      elsif Item > 20.0 then
         return 1.0;
      elsif Item < -20.0 then
         return -1.0;
      end if;

      declare
         Twice : constant Wide_Real := Exp (2.0 * Item);
      begin
         return (Twice - 1.0) / (Twice + 1.0);
      end;
   end Tanh;

   function Exp (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) then
         return (if Item > 0.0 then Item else 0.0);
      elsif Item < -700.0 then
         return 0.0;
      elsif Item > 700.0 then
         return Wide_Real'Last;
      else
         return Wide_Functions.Exp (Item);
      end if;
   exception
      when others =>
         return 0.0;
   end Exp;

   ----------
   -- Sqrt --
   ----------

   function Sqrt (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) or else Item < 0.0 then
         return 0.0;
      else
         return Wide_Functions.Sqrt (Item);
      end if;
   exception
      when others =>
         return 0.0;
   end Sqrt;

   ---------
   -- Cos --
   ---------

   function Cos (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) then
         return 1.0;
      else
         return Wide_Functions.Cos (Item);
      end if;
   exception
      when others =>
         return 1.0;
   end Cos;

   ---------
   -- Sin --
   ---------

   function Sin (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) then
         return 0.0;
      else
         return Wide_Functions.Sin (Item);
      end if;
   exception
      when others =>
         return 0.0;
   end Sin;

   -----------
   -- Power --
   -----------

   function Power (Base, Exponent : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Base) or else not Is_Finite (Exponent)
        or else Base <= 0.0
      then
         return 0.0;
      else
         return Wide_Functions."**" (Base, Exponent);
      end if;
   exception
      when others =>
         return 0.0;
   end Power;

   ---------
   -- Log --
   ---------

   function Log (Item : Wide_Real) return Wide_Real is
   begin
      if not Is_Finite (Item) or else Item <= 0.0 then
         return 0.0;
      else
         return Wide_Functions.Log (Item);
      end if;
   exception
      when others =>
         return 0.0;
   end Log;

end Model_Runner.Numerics;
