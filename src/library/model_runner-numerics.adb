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

   function From_Bits (Item : Interfaces.Unsigned_32) return Real
   is (To_Value (Item));

   ---------------
   -- Is_Finite --
   ---------------

   function Is_Finite (Item : Real) return Boolean
   is ((To_Bits (Item) and Exponent_Mask) /= Exponent_Mask);

   ---------------
   -- Is_Finite --
   ---------------

   function Is_Finite (Item : Wide_Real) return Boolean
   is ((Wide_To_Bits (Item) and 16#7FF0_0000_0000_0000#)
       /= 16#7FF0_0000_0000_0000#);

   ------------
   -- Is_NaN --
   ------------

   function Is_NaN (Item : Real) return Boolean
   is ((To_Bits (Item) and Exponent_Mask) = Exponent_Mask
       and then (To_Bits (Item) and Mantissa_Mask) /= 0);

   -------------
   -- To_Real --
   -------------

   function To_Real (Item : Half) return Real is
      Raw       : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Item);
      Sign      : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Interfaces.Shift_Right (Raw, 15)) * 2 ** 31;
      Exponent  : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Interfaces.Shift_Right (Raw, 10) and 16#1F#);
      Mantissa  : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Raw and 16#03FF#);
   begin
      if Exponent = 0 then
         if Mantissa = 0 then
            --  Signed zero.
            return To_Value (Sign);
         end if;

         --  Subnormal. Shift the mantissa left until the implicit leading bit
         --  appears, decrementing the binary32 exponent to match. binary32 has
         --  ample exponent range, so the result is normal and exact.
         declare
            Shifted  : Interfaces.Unsigned_32 := Mantissa;
            Adjusted : Interfaces.Unsigned_32 := 127 - 15 + 1;
         begin
            while (Shifted and 16#0000_0400#) = 0 loop
               Shifted := Interfaces.Shift_Left (Shifted, 1);
               Adjusted := Adjusted - 1;
            end loop;
            Shifted := Shifted and 16#0000_03FF#;
            return
              To_Value
                (Sign
                 or Interfaces.Shift_Left (Adjusted, 23)
                 or Interfaces.Shift_Left (Shifted, 13));
         end;

      elsif Exponent = 16#1F# then
         --  Infinity or NaN. The payload's leading bits are preserved.
         return
           To_Value
             (Sign or Exponent_Mask or Interfaces.Shift_Left (Mantissa, 13));

      else
         return
           To_Value
             (Sign
              or Interfaces.Shift_Left (Exponent + (127 - 15), 23)
              or Interfaces.Shift_Left (Mantissa, 13));
      end if;
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
