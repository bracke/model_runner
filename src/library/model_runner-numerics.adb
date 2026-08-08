with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Conversion;

package body Model_Runner.Numerics is

   use type Interfaces.Unsigned_16;
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

   function Is_NaN (Item : Real) return Boolean
   is ((To_Bits (Item) and Exponent_Mask) = Exponent_Mask
       and then (To_Bits (Item) and Mantissa_Mask) /= 0);

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

      --  Widening by arithmetic rather than by cases.
      --
      --  The obvious form asks which kind of value it has and, for a
      --  subnormal, shifts the mantissa one bit at a time until the leading
      --  bit appears. A loop whose length depends on the value is why this
      --  format decoded slower than the quantized ones, which do fixed work
      --  per element.
      --
      --  Instead: the sign moves to the top, the exponent and mantissa move
      --  to their wider places, and the bias is corrected by adding the
      --  difference of the two biases to the exponent field. That is exact
      --  for every normal value. Two exponents need more: the widest, which
      --  means infinity or not-a-number and must stay widest rather than
      --  become a large finite number, and zero, whose value is the mantissa
      --  read as the fraction of a number just above one, less that one.
      Raw : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Interfaces.Unsigned_16 (Item));

      Sign : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left (Raw and 16#8000#, 16);

      --  The widest binary16 exponent, moved to its binary32 place.
      Widest : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left (16#7C00#, 13);

      Rest : Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left (Raw and 16#7FFF#, 13);

      Exponent : constant Interfaces.Unsigned_32 := Rest and Widest;
   begin
      Rest := Rest + Interfaces.Shift_Left (127 - 15, 23);

      if Exponent = Widest then
         --  Infinity or not-a-number: undo the bias correction by carrying
         --  the exponent the rest of the way to its own widest.
         Rest := Rest + Interfaces.Shift_Left (128 - 16, 23);

      elsif Exponent = 0 then
         --  Zero or subnormal: read the mantissa as the fraction of the
         --  smallest normal binary16 and subtract that number, which leaves
         --  the subnormal value and leaves zero as zero.
         Rest := Rest + Interfaces.Shift_Left (1, 23);
         Rest := To_Bits (To_Value (Rest)
                          - To_Value (Interfaces.Shift_Left (113, 23)));
      end if;

      return To_Value (Sign or Rest);
   end To_Real;

   -------------
   -- To_Half --
   -------------

   function To_Half (Item : Real) return Half is
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

         elsif Unbiased >= -24 then
            --  Subnormal in binary16. Reinstate the implicit leading bit and
            --  shift it down into the subnormal field, rounding to nearest.
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

   ---------
   -- Exp --
   ---------

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
