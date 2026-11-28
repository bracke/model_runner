--  Binary32 tanh/expm1 arithmetic adapted from the existing native Vulkan
--  reference_activation.comp implementation, itself adapted from SunPro fdlibm:
--  Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
--  Developed at SunPro, a Sun Microsystems, Inc. business.
--  Permission to use, copy, modify, and distribute this software is freely
--  granted, provided that this notice is preserved.
--  Exp reduction/table derived from Arm optimized-routines (MIT option):
--  Copyright (c) 2017-2026, Arm Limited. Full MIT notice:
--  src/shaders/reference_activation.LICENSE.
separate (Model_Runner.Kernels)
procedure Reference_SiTU
  (Gate : in out Real_Array; Up : Real_Array; Gate_Cap, Up_Cap : Real)
is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;
   function Bits is new Ada.Unchecked_Conversion (Real, U32);
   function From_Bits is new Ada.Unchecked_Conversion (U32, Real);
   function Double_From_Bits is new Ada.Unchecked_Conversion (U64, N.Wide_Real);
   pragma Inline_Always (Bits, From_Bits, Double_From_Bits);
   function Exp_F (Value : Real) return Real
     with Import, Convention => C, External_Name => "expf";
   function Tanh_F (Value : Real) return Real
     with Import, Convention => C, External_Name => "tanhf";
   Gate_Reciprocal : Real;
   Up_Reciprocal : Real;
   subtype Lane is Natural range 0 .. 15;
   type Float_Block is array (Lane) of Real;
   type Double_Block is array (Lane) of N.Wide_Real;
   type Integer_Block is array (Lane) of Integer;
   type Exp_Table is array (Natural range 0 .. 31) of U64;
   Table : constant Exp_Table := [
      16#3FF00000_00000000#,
      16#3FEFD9B0_D3158574#,
      16#3FEFB558_6CF9890F#,
      16#3FEF9301_D0125B51#,
      16#3FEF72B8_3C7D517B#,
      16#3FEF5487_3168B9AA#,
      16#3FEF387A_6E756238#,
      16#3FEF1E9D_F51FDEE1#,
      16#3FEF06FE_0A31B715#,
      16#3FEEF1A7_373AA9CB#,
      16#3FEEDEA6_4C123422#,
      16#3FEECE08_6061892D#,
      16#3FEEBFDA_D5362A27#,
      16#3FEEB42B_569D4F82#,
      16#3FEEAB07_DD485429#,
      16#3FEEA47E_B03A5585#,
      16#3FEEA09E_667F3BCD#,
      16#3FEE9F75_E8EC5F74#,
      16#3FEEA114_73EB0187#,
      16#3FEEA589_994CCE13#,
      16#3FEEACE5_422AA0DB#,
      16#3FEEB737_B0CDC5E5#,
      16#3FEEC491_82A3F090#,
      16#3FEED503_B23E255D#,
      16#3FEEE89F_995AD3AD#,
      16#3FEEFF76_F2FB5E47#,
      16#3FEF199B_DD85529C#,
      16#3FEF3720_DCEF9069#,
      16#3FEF5818_DCFBA487#,
      16#3FEF7C97_337B9B5F#,
      16#3FEFA4AF_A2A490DA#,
      16#3FEFD076_5B6E4540#];
   procedure Scalar (At_Index : Element_Count) is
      Raw : constant Real := Gate (Gate'First + At_Index);
      Gated : constant Real := Gate_Cap * Tanh_F (Raw * Gate_Reciprocal)
        * (if Raw <= -88.72283935546875 then 0.0 else 1.0 / (1.0 + Exp_F (-Raw)));
      Linear : constant Real := Up_Cap * Tanh_F (Up (Up'First + At_Index) * Up_Reciprocal);
   begin
      Gate (Gate'First + At_Index) := Gated * Linear;
   end Scalar;

   procedure Tanh_Block (Values : in out Float_Block);
   pragma Machine_Attribute (Tanh_Block, "target", "avx512f,avx512bw,avx512vl,avx512dq,avx2,fma");
   pragma No_Inline (Tanh_Block);
   procedure Tanh_Block (Values : in out Float_Block) is
      X, Correction, Hfx, Hxs, R1, Error, Answer : Float_Block;
      Power : Integer_Block;
      pragma Suppress (All_Checks);
   begin
      --  Tanh only needs expm1 on [-2,44]. Saturated/tiny lanes use a
      --  harmless zero here and recover their exact scalar result below.
      for I in Lane loop
         declare
            A : constant Real := abs Values (I);
            H : constant U32 := Bits (A);
            V : constant Real := (if H < 16#2400_0000# or else H >= 16#41B0_0000# then 0.0
                                 elsif A >= 1.0 then 2.0 * A else -2.0 * A);
            Negative : constant Boolean := V < 0.0;
            Hi, Lo : Real;
         begin
            if (Bits (V) and 16#7FFF_FFFF#) > 16#3EB1_7218# then
               if (Bits (V) and 16#7FFF_FFFF#) < 16#3F85_1592# then
                  Power (I) := (if Negative then -1 else 1);
                  Hi := (if Negative then V + 0.69313812256 else V - 0.69313812256);
                  Lo := (if Negative then -9.0580006145E-6 else 9.0580006145E-6);
               else
                  Power (I) := Integer (Real'Truncation
                    (1.4426950216 * V + (if Negative then -0.5 else 0.5)));
                  Hi := V - Real (Power (I)) * 0.69313812256;
                  Lo := Real (Power (I)) * 9.0580006145E-6;
               end if;
               X (I) := Hi - Lo; Correction (I) := (Hi - X (I)) - Lo;
            else
               Power (I) := 0; X (I) := V; Correction (I) := 0.0;
            end if;
         end;
      end loop;
      for I in Lane loop
         Hfx (I) := 0.5 * X (I); Hxs (I) := X (I) * Hfx (I);
         R1 (I) := 1.0 + Hxs (I) * (-0.033333335072 + Hxs (I) * (0.0015873016091
           + Hxs (I) * (-0.000079365076090 + Hxs (I) * (0.0000040082177293
           + Hxs (I) * (-0.00000020109921195)))));
      end loop;
      for I in Lane loop
         declare
            T : constant Real := 3.0 - R1 (I) * Hfx (I);
         begin
            Error (I) := Hxs (I) * ((R1 (I) - T) / (6.0 - X (I) * T));
         end;
      end loop;
      for I in Lane loop
         declare
            K : constant Integer := Power (I);
            E : Real := Error (I);
            Y, T : Real;
         begin
            if K = 0 then
               Y := X (I) - (X (I) * E - Hxs (I));
            else
               E := X (I) * (E - Correction (I)) - Correction (I); E := E - Hxs (I);
               if K = -1 then Y := 0.5 * (X (I) - E) - 0.5;
               elsif K = 1 then
                  Y := (if X (I) < -0.25 then -2.0 * (E - (X (I) + 0.5)) else 1.0 + 2.0 * (X (I) - E));
               elsif K <= -2 or else K > 56 then
                  Y := 1.0 - (E - X (I));
                  Y := From_Bits (Bits (Y) + Interfaces.Shift_Left (U32'Mod (K), 23)); Y := Y - 1.0;
               else
                  if K < 23 then
                     T := From_Bits (16#3F80_0000# - Interfaces.Shift_Right (16#0100_0000#, K));
                     Y := T - (E - X (I));
                  else
                     T := From_Bits (Interfaces.Shift_Left (U32 (127 - K), 23));
                     Y := X (I) - (E + T); Y := Y + 1.0;
                  end if;
                  Y := From_Bits (Bits (Y) + Interfaces.Shift_Left (U32'Mod (K), 23));
               end if;
            end if;
            Answer (I) := Y;
         end;
      end loop;
      for I in Lane loop
         declare
            Raw : constant Real := Values (I);
            H : constant U32 := Bits (Raw) and 16#7FFF_FFFF#;
            T : constant Real := Answer (I);
            Z : Real;
         begin
            if H = 0 then Z := Raw;
            elsif H < 16#2400_0000# then Z := Raw * (1.0 + Raw);
            elsif H >= 16#41B0_0000# then Z := (if Raw < 0.0 then -1.0 else 1.0);
            else
               Z := (if H >= 16#3F80_0000# then 1.0 - 2.0 / (T + 2.0) else -T / (T + 2.0));
               if (Bits (Raw) and 16#8000_0000#) /= 0 then Z := -Z; end if;
            end if;
            Values (I) := Z;
         end;
      end loop;
   end Tanh_Block;

   procedure Exp_Block (Values : in out Float_Block);
   pragma Machine_Attribute (Exp_Block, "target", "avx512f,avx512bw,avx512vl,avx512dq,avx2,fma");
   pragma No_Inline (Exp_Block);
   procedure Exp_Block (Values : in out Float_Block) is
      Z, Whole, Remainder, Scale, Polynomial, Square, Result : Double_Block;
      pragma Suppress (All_Checks);
   begin
      for I in Lane loop
         Z (I) := 46.16624130844683 * N.Wide_Real (Values (I));
         Whole (I) := Z (I) + 6755399441055744.0;
         Whole (I) := Whole (I) - 6755399441055744.0;
         Remainder (I) := Z (I) - Whole (I);
      end loop;
      for I in Lane loop
         declare
            K : constant Integer := Integer (Whole (I));
         begin
            Scale (I) := Double_From_Bits
              (Table (K mod 32) + Interfaces.Shift_Left (U64'Mod (K), 47));
         end;
      end loop;
      for I in Lane loop
         Polynomial (I) := 1.6938359250920212E-6 * Remainder (I) + 0.00023459809789509004;
         Square (I) := Remainder (I) * Remainder (I);
         Result (I) := 0.021660849396613134 * Remainder (I) + 1.0;
         Result (I) := Polynomial (I) * Square (I) + Result (I);
         Result (I) := Result (I) * Scale (I);
         Values (I) := Real (Result (I));
      end loop;
   end Exp_Block;

   procedure Run_Block (At_Index : Element_Count);
   pragma Machine_Attribute (Run_Block, "target", "avx512f,avx512bw,avx512vl,avx512dq,avx2,fma");
   pragma No_Inline (Run_Block);
   procedure Run_Block (At_Index : Element_Count) is
      Raw, G, U, E : Float_Block;
      pragma Suppress (All_Checks);
   begin
      for I in Lane loop
         Raw (I) := Gate (Gate'First + At_Index + Element_Count (I));
         G (I) := Raw (I) * Gate_Reciprocal;
         U (I) := Up (Up'First + At_Index + Element_Count (I)) * Up_Reciprocal;
         E (I) := (if Raw (I) <= -88.72283935546875 or else Raw (I) > 103.97208404541015625
                    then 0.0 else -Raw (I));
      end loop;
      Tanh_Block (G); Tanh_Block (U); Exp_Block (E);
      for I in Lane loop
         declare
            Sigmoid : constant Real := (if Raw (I) <= -88.72283935546875 then 0.0
                                       elsif Raw (I) > 103.97208404541015625 then 1.0
                                       else 1.0 / (1.0 + E (I)));
            Gated : constant Real := (Gate_Cap * G (I)) * Sigmoid;
            Linear : constant Real := Up_Cap * U (I);
         begin
            Gate (Gate'First + At_Index + Element_Count (I)) := Gated * Linear;
         end;
      end loop;
   end Run_Block;
   At_Index : Element_Count := 0;
begin
   if Up'Length < Gate'Length or else not N.Is_Finite (Gate_Cap) or else Gate_Cap <= 0.0
     or else not N.Is_Finite (Up_Cap) or else Up_Cap <= 0.0
   then raise Constraint_Error with "invalid reference SiTU dimensions or caps"; end if;
   Gate_Reciprocal := 1.0 / Gate_Cap; Up_Reciprocal := 1.0 / Up_Cap;
   if Model_Runner.Platform.Byte_Products then
      while Gate'Length - At_Index >= 16 loop
         declare
            Finite : Boolean := True;
         begin
            for I in Element_Count range 0 .. 15 loop
               if not N.Is_Finite (Gate (Gate'First + At_Index + I))
                 or else not N.Is_Finite (Up (Up'First + At_Index + I))
                 or else not N.Is_Finite (Gate (Gate'First + At_Index + I) * Gate_Reciprocal)
                 or else not N.Is_Finite (Up (Up'First + At_Index + I) * Up_Reciprocal)
               then Finite := False; exit; end if;
            end loop;
            if Finite then Run_Block (At_Index);
            else for I in Element_Count range 0 .. 15 loop Scalar (At_Index + I); end loop; end if;
         end;
         At_Index := At_Index + 16;
      end loop;
   end if;
   while At_Index < Gate'Length loop Scalar (At_Index); At_Index := At_Index + 1; end loop;
end Reference_SiTU;
