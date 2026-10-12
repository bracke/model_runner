with Model_Runner.Quantization.Grid_Tables;

package body Model_Runner.Quantization.Grid_Integers is

   use Model_Runner.Quantization.Grid_Tables;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Numerics.Real;

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   Ones : constant U64 := 16#0101_0101_0101_0101#;

   type Word_Table is array (Natural range <>) of U64;

   --  A sign byte as eight bytes: all ones where its bit is set.
   function Make_Masks return Word_Table is
      Result : Word_Table (0 .. 255);
   begin
      for Bits in Result'Range loop
         Result (Bits) := 0;
         for J in 0 .. 7 loop
            if (U8 (Bits) and U8 (2 ** J)) /= 0 then
               Result (Bits) := Result (Bits) or Interfaces.Shift_Left (U64 (16#FF#), 8 * J);
            end if;
         end loop;
      end loop;
      return Result;
   end Make_Masks;

   Masks : constant Word_Table := Make_Masks;

   --  The two-bit grids' seven-bit sign indices straight to their masks:
   --  one table read where the pattern and then its mask were two in a
   --  chain, eight elements apiece.
   function Make_Sign_Masks return Word_Table is
      Result : Word_Table (0 .. 127);
   begin
      for Index in Result'Range loop
         Result (Index) := Masks (Natural (KSigns_IQ2XS (Index)));
      end loop;
      return Result;
   end Make_Sign_Masks;

   Sign_Masks : constant Word_Table := Make_Sign_Masks;

   function Make_Sign_Ones return Word_Table is
      Result : Word_Table (0 .. 127);
   begin
      for Index in Result'Range loop
         Result (Index) := Sign_Masks (Index) or Ones;
      end loop;
      return Result;
   end Make_Sign_Ones;

   Sign_Ones : aliased constant Word_Table := Make_Sign_Ones;

   function Make_Byte_Sign_Ones return Word_Table is
      Result : Word_Table (0 .. 255);
   begin
      for Index in Result'Range loop
         Result (Index) := Masks (Index) or Ones;
      end loop;
      return Result;
   end Make_Byte_Sign_Ones;

   Byte_Sign_Ones : aliased constant Word_Table := Make_Byte_Sign_Ones;
   Offset_Words   : aliased constant Word_Table (0 .. 1) := [Ones, 16#FFFF_FFFF_FFFF_FFFF#];

   function Grid_Address (Format : G.Tensor_Type) return System.Address
   is (case Format is
         when G.Type_IQ2_XXS => IQ2XXS_Grid'Address,
         when G.Type_IQ2_XS => IQ2XS_Grid'Address,
         when G.Type_IQ2_S => IQ2S_Grid'Address,
         when G.Type_IQ3_XXS => IQ3XXS_Grid'Address,
         when G.Type_IQ3_S => IQ3S_Grid'Address,
         when others => IQ1S_Grid'Address);
   function Sign_Ones_Address return System.Address is (Sign_Ones (0)'Address);
   function Byte_Sign_Ones_Address return System.Address is (Byte_Sign_Ones (0)'Address);
   function Offset_Words_Address return System.Address is (Offset_Words (0)'Address);

   function Make_Bit_Bytes return Word_Table is
      Result : Word_Table (0 .. 255);
   begin
      for Index in Result'Range loop
         Result (Index) := Masks (Index) and Ones;
      end loop;
      return Result;
   end Make_Bit_Bytes;

   Bit_Bytes : aliased constant Word_Table := Make_Bit_Bytes;

   function Bit_Bytes_Address return System.Address is (Bit_Bytes (0)'Address);

   --  Byte 8K + J reads sign byte K and its bit J: the byte selectors, then
   --  the bits, four quadwords each.
   Sign_Shuffle : aliased constant Word_Table (0 .. 7) :=
     [16#0000_0000_0000_0000#, 16#0101_0101_0101_0101#, 16#0202_0202_0202_0202#, 16#0303_0303_0303_0303#,
      16#8040_2010_0804_0201#, 16#8040_2010_0804_0201#, 16#8040_2010_0804_0201#, 16#8040_2010_0804_0201#];

   function Sign_Shuffle_Address return System.Address is (Sign_Shuffle (0)'Address);

   function Make_Scale_Shuffle return Word_Table is
      Result : Word_Table (0 .. 31);
   begin
      for Sub in 0 .. 7 loop
         declare
            Pair : constant U64 := U64 (2 * Sub) or Interfaces.Shift_Left (U64 (2 * Sub + 1), 8);
            Word : constant U64 := Pair * 16#0001_0001_0001_0001#;
         begin
            Result (4 * Sub .. 4 * Sub + 3) := [others => Word];
         end;
      end loop;
      return Result;
   end Make_Scale_Shuffle;

   Scale_Shuffle : aliased constant Word_Table := Make_Scale_Shuffle;

   function Scale_Shuffle_Address return System.Address is (Scale_Shuffle (0)'Address);

   function Make_Offset_Signs return Word_Table is
      Result : Word_Table (0 .. 63);
   begin
      for Bits in 0 .. 15 loop
         for K in 0 .. 3 loop
            Result (4 * Bits + K) :=
              (if (Bits / 2 ** K) mod 2 = 1 then 16#FFFF_FFFF_FFFF_FFFF# else Ones);
         end loop;
      end loop;
      return Result;
   end Make_Offset_Signs;

   Offset_Signs : aliased constant Word_Table (0 .. 63) := Make_Offset_Signs;

   function Offset_Signs_Address return System.Address is (Offset_Signs (0)'Address);

   function Make_IQ1M_Scales return Word_Table is
      Result : Word_Table (0 .. 35);
   begin
      Result (0 .. 3) := [0, 6, 3, 9];
      for Sub in 0 .. 7 loop
         declare
            Word : constant U64 := U64 (if Sub mod 2 = 0 then Sub / 2 else 4 + Sub / 2);
            Pair : constant U64 := (2 * Word) or Interfaces.Shift_Left (2 * Word + 1, 8);
         begin
            Result (4 + 4 * Sub .. 4 + 4 * Sub + 3) := [others => Pair * 16#0001_0001_0001_0001#];
         end;
      end loop;
      return Result;
   end Make_IQ1M_Scales;

   IQ1M_Scales : aliased constant Word_Table (0 .. 35) := Make_IQ1M_Scales;

   function IQ1M_Scales_Address return System.Address is (IQ1M_Scales (0)'Address);

   --  IQ1's grid entry at eight times, its offset added or taken: each
   --  byte is -1, 0 or 1 and becomes 8g + 1 or 8g - 1, worked out in the
   --  word -- the low five bits of each byte shifted up three is 8g without
   --  a carry, and the offset is a bytewise add that cannot carry either
   --  (the top bit is added apart). Two tables of the results were 32 KB
   --  that pushed the other grids out of the first-level cache.
   Lows  : constant U64 := 16#1F1F_1F1F_1F1F_1F1F#;
   Seven : constant U64 := 16#7F7F_7F7F_7F7F_7F7F#;
   Highs : constant U64 := 16#8080_8080_8080_8080#;

   function Ones_Up (Index : Natural) return U64
   is (Interfaces.Shift_Left (IQ1S_Grid (Index) and Lows, 3) + Ones)
     with Inline_Always;

   function Ones_Down (Index : Natural) return U64 is
      Eight : constant U64 := Interfaces.Shift_Left (IQ1S_Grid (Index) and Lows, 3);
   begin
      --  Eight + 0xFF in every byte, no carry between them.
      return ((Eight and Seven) + Seven) xor ((not Eight) and Highs);
   end Ones_Down;
   pragma Inline_Always (Ones_Down);

   function Is_Grid (Format : G.Tensor_Type) return Boolean
   is (Format in G.Type_IQ1_S | G.Type_IQ1_M | G.Type_IQ2_XXS | G.Type_IQ2_XS
                | G.Type_IQ2_S | G.Type_IQ3_XXS | G.Type_IQ3_S);

   procedure Decode
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Words  : out Word_Block;
      Lanes  : out Lane_Block)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      function Raw (At_Byte : B.Byte_Count) return U8
      is (Data (Data'First + Offset + At_Byte))
        with Inline_Always;

      function Read_16 (At_Byte : B.Byte_Count) return U16
      is (U16 (Raw (At_Byte)) or Interfaces.Shift_Left (U16 (Raw (At_Byte + 1)), 8))
        with Inline_Always;

      function Read_32 (At_Byte : B.Byte_Count) return U32
      is (U32 (Read_16 (At_Byte)) or Interfaces.Shift_Left (U32 (Read_16 (At_Byte + 2)), 16))
        with Inline_Always;

      function Half_At (At_Byte : B.Byte_Count) return N.Real
      is (N.To_Real (N.Half (Read_16 (At_Byte))))
        with Inline_Always;

      --  Magnitudes signed by a mask: the bytes the mask sets negated. A
      --  magnitude is never nought in these grids, so no byte carries.
      function Signed (Magnitudes : U64; Mask : U64) return U64
      is ((Magnitudes xor Mask) + (Mask and Ones))
        with Inline_Always;

      --  The factor of the four lanes from First on.
      procedure Set_Lanes (First : Natural; Count : Natural; Factor : N.Real)
        with Inline_Always;

      procedure Set_Lanes (First : Natural; Count : Natural; Factor : N.Real) is
      begin
         for K in First .. First + Count - 1 loop
            Lanes (K) := Factor;
         end loop;
      end Set_Lanes;
   begin
      case Format is
         when G.Type_IQ2_XXS =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Base : constant B.Byte_Count := 2 + B.Byte_Count (Sub) * 8;
                     Aux  : constant U32 := Read_32 (Base + 4);
                  begin
                     for L in 0 .. 3 loop
                        Words (4 * Sub + L) :=
                          Signed (IQ2XXS_Grid (Natural (Raw (Base + B.Byte_Count (L)))),
                                  Sign_Masks (Natural (Interfaces.Shift_Right (Aux, 7 * L) and 127)));
                     end loop;
                     Set_Lanes (8 * Sub, 8, D * N.Real (2 * Integer (Interfaces.Shift_Right (Aux, 28)) + 1) * 0.125);
                  end;
               end loop;
            end;

         when G.Type_IQ2_XS =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     SB : constant U8 := Raw (66 + B.Byte_Count (Sub));
                  begin
                     for L in 0 .. 3 loop
                        declare
                           Word : constant U16 := Read_16 (2 + B.Byte_Count (2 * (4 * Sub + L)));
                        begin
                           Words (4 * Sub + L) :=
                             Signed (IQ2XS_Grid (Natural (Word and 511)),
                                     Sign_Masks (Natural (Interfaces.Shift_Right (Word, 9))));
                        end;
                     end loop;
                     Set_Lanes (8 * Sub, 4, D * N.Real (2 * Integer (SB and 16#0F#) + 1) * 0.125);
                     Set_Lanes (8 * Sub + 4, 4, D * N.Real (2 * Integer (Interfaces.Shift_Right (SB, 4)) + 1) * 0.125);
                  end;
               end loop;
            end;

         when G.Type_IQ2_S =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     SB  : constant U8 := Raw (74 + B.Byte_Count (Sub));
                     QHb : constant U16 := U16 (Raw (66 + B.Byte_Count (Sub)));
                  begin
                     for L in 0 .. 3 loop
                        declare
                           Low  : constant U16 := U16 (Raw (2 + B.Byte_Count (4 * Sub + L)));
                           High : constant U16 := Interfaces.Shift_Left (QHb, 8 - 2 * L) and 16#300#;
                        begin
                           Words (4 * Sub + L) :=
                             Signed (IQ2S_Grid (Natural (Low or High)),
                                     Masks (Natural (Raw (2 + B.Byte_Count (32 + 4 * Sub + L)))));
                        end;
                     end loop;
                     Set_Lanes (8 * Sub, 4, D * N.Real (2 * Integer (SB and 16#0F#) + 1) * 0.125);
                     Set_Lanes (8 * Sub + 4, 4, D * N.Real (2 * Integer (Interfaces.Shift_Right (SB, 4)) + 1) * 0.125);
                  end;
               end loop;
            end;

         when G.Type_IQ3_XXS =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Aux : constant U32 := Read_32 (66 + B.Byte_Count (4 * Sub));
                  begin
                     for L in 0 .. 3 loop
                        declare
                           G1 : constant U32 := IQ3XXS_Grid (Natural (Raw (2 + B.Byte_Count (8 * Sub + 2 * L))));
                           G2 : constant U32 := IQ3XXS_Grid (Natural (Raw (2 + B.Byte_Count (8 * Sub + 2 * L + 1))));
                        begin
                           Words (4 * Sub + L) :=
                             Signed (U64 (G1) or Interfaces.Shift_Left (U64 (G2), 32),
                                     Sign_Masks (Natural (Interfaces.Shift_Right (Aux, 7 * L) and 127)));
                        end;
                     end loop;
                     Set_Lanes (8 * Sub, 8, D * N.Real (2 * Integer (Interfaces.Shift_Right (Aux, 28)) + 1) * 0.25);
                  end;
               end loop;
            end;

         when G.Type_IQ3_S =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Scale_Byte : constant U8 := Raw (106 + B.Byte_Count (Sub / 2));
                     Nibble     : constant U8 :=
                       (if Sub mod 2 = 0 then Scale_Byte and 16#0F# else Interfaces.Shift_Right (Scale_Byte, 4));
                     QH_Byte    : constant U8 := Raw (66 + B.Byte_Count (Sub));
                  begin
                     for L in 0 .. 3 loop
                        declare
                           High_1 : constant U32 := (if (QH_Byte and U8 (2 ** (2 * L))) /= 0 then 256 else 0);
                           High_2 : constant U32 := (if (QH_Byte and U8 (2 ** (2 * L + 1))) /= 0 then 256 else 0);
                           G1 : constant U32 :=
                             IQ3S_Grid (Natural (U32 (Raw (2 + B.Byte_Count (8 * Sub + 2 * L))) or High_1));
                           G2 : constant U32 :=
                             IQ3S_Grid (Natural (U32 (Raw (2 + B.Byte_Count (8 * Sub + 2 * L + 1))) or High_2));
                        begin
                           Words (4 * Sub + L) :=
                             Signed (U64 (G1) or Interfaces.Shift_Left (U64 (G2), 32),
                                     Masks (Natural (Raw (74 + B.Byte_Count (4 * Sub + L)))));
                        end;
                     end loop;
                     Set_Lanes (8 * Sub, 8, D * N.Real (2 * Integer (Nibble) + 1));
                  end;
               end loop;
            end;

         when G.Type_IQ1_S =>
            declare
               D : constant N.Real := Half_At (0);
            begin
               for Sub in 0 .. 7 loop
                  declare
                     QHw  : constant U16 := Read_16 (34 + B.Byte_Count (2 * Sub));
                     Down : constant Boolean := (QHw and 16#8000#) /= 0;
                  begin
                     for L in 0 .. 3 loop
                        declare
                           Index : constant Natural :=
                             Natural (Raw (2 + B.Byte_Count (4 * Sub + L)))
                             + Natural (Interfaces.Shift_Left (Interfaces.Shift_Right (QHw, 3 * L) and 7, 8));
                        begin
                           Words (4 * Sub + L) := (if Down then Ones_Down (Index) else Ones_Up (Index));
                        end;
                     end loop;
                     Set_Lanes
                       (8 * Sub, 8,
                        D * N.Real (2 * Integer (Interfaces.Shift_Right (QHw, 12) and 7) + 1) * 0.125);
                  end;
               end loop;
            end;

         when G.Type_IQ1_M =>
            declare
               SC  : constant array (0 .. 3) of U16 := [Read_16 (48), Read_16 (50), Read_16 (52), Read_16 (54)];
               Bits : constant U16 :=
                 Interfaces.Shift_Right (SC (0), 12)
                 or (Interfaces.Shift_Right (SC (1), 8) and 16#00F0#)
                 or (Interfaces.Shift_Right (SC (2), 4) and 16#0F00#)
                 or (SC (3) and 16#F000#);
               D : constant N.Real := N.To_Real (N.Half (Bits));
            begin
               for Sub in 0 .. 7 loop
                  declare
                     SW  : constant U16 := SC (Sub / 2);
                     Sh  : constant Natural := 6 * (Sub mod 2);
                     QH0 : constant U16 := U16 (Raw (32 + B.Byte_Count (2 * Sub)));
                     QH1 : constant U16 := U16 (Raw (32 + B.Byte_Count (2 * Sub + 1)));
                  begin
                     for L in 0 .. 3 loop
                        declare
                           QHx  : constant U16 := (if L < 2 then QH0 else QH1);
                           High : constant U16 :=
                             (if L mod 2 = 0 then Interfaces.Shift_Left (QHx, 8) and 16#700#
                              else Interfaces.Shift_Left (QHx, 4) and 16#700#);
                           Index : constant Natural := Natural (U16 (Raw (B.Byte_Count (4 * Sub + L))) or High);
                           Down  : constant Boolean :=
                             (QHx and (if L mod 2 = 0 then 16#08# else 16#80#)) /= 0;
                        begin
                           Words (4 * Sub + L) := (if Down then Ones_Down (Index) else Ones_Up (Index));
                        end;
                     end loop;
                     Set_Lanes
                       (8 * Sub, 4,
                        D * N.Real (2 * Integer (Interfaces.Shift_Right (SW, Sh) and 7) + 1) * 0.125);
                     Set_Lanes
                       (8 * Sub + 4, 4,
                        D * N.Real (2 * Integer (Interfaces.Shift_Right (SW, Sh + 3) and 7) + 1) * 0.125);
                  end;
               end loop;
            end;

         when others =>
            Words := [others => 0];
            Lanes := [others => 0.0];
      end case;
   end Decode;

end Model_Runner.Quantization.Grid_Integers;
