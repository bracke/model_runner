with Ada.Numerics.Long_Elementary_Functions;

package body Model_Runner.Philox is

   use Interfaces;

   package N renames Model_Runner.Numerics;

   use type N.Real;

   M_0 : constant Unsigned_64 := 16#D251_1F53#;
   M_1 : constant Unsigned_64 := 16#CD9E_8D57#;
   W_0 : constant Unsigned_32 := 16#9E37_79B9#;
   W_1 : constant Unsigned_32 := 16#BB67_AE85#;

   --  2^-32 and 2^-32 * 2 pi, rounded to binary32 as the reference has them.
   Inverse     : constant N.Real := 2.328_306_4E-10;
   Inverse_Arc : constant N.Real := 2.328_306_4E-10 * 6.283_185_5;

   function Seeded (Seed : Unsigned_64) return Generator is ((Seed => Seed, Offset => 0));

   procedure Draw (Self : in out Generator; Values : out N.Real_Array) is
      use Ada.Numerics.Long_Elementary_Functions;
      use type N.Element_Count;
   begin
      for I in Values'Range loop
         declare
            C_0   : Unsigned_32 := Self.Offset;
            C_1   : Unsigned_32 := 0;
            C_2   : Unsigned_32 := Unsigned_32 (I - Values'First);
            C_3   : Unsigned_32 := 0;
            Key_0 : Unsigned_32 := Unsigned_32 (Self.Seed and 16#FFFF_FFFF#);
            Key_1 : Unsigned_32 := Unsigned_32 (Shift_Right (Self.Seed, 32));
         begin
            for Round in 1 .. 10 loop
               declare
                  V_1 : constant Unsigned_64 := Unsigned_64 (C_0) * M_0;
                  V_2 : constant Unsigned_64 := Unsigned_64 (C_2) * M_1;
               begin
                  C_0 := Unsigned_32 (Shift_Right (V_2, 32)) xor C_1 xor Key_0;
                  C_1 := Unsigned_32 (V_2 and 16#FFFF_FFFF#);
                  C_2 := Unsigned_32 (Shift_Right (V_1, 32)) xor C_3 xor Key_1;
                  C_3 := Unsigned_32 (V_1 and 16#FFFF_FFFF#);
               end;
               Key_0 := Key_0 + W_0;
               Key_1 := Key_1 + W_1;
            end loop;
            declare
               U : constant N.Real := N.Real (C_0) * Inverse + Inverse / 2.0;
               V : constant N.Real := N.Real (C_1) * Inverse_Arc + Inverse_Arc / 2.0;
               --  The reference's logarithm, root and sine are binary64's;
               --  the root is rounded to binary32 before the product.
               S : constant N.Real := N.Real (Sqrt (-2.0 * Log (Long_Float (U))));
            begin
               Values (I) := N.Real (Long_Float (S) * Sin (Long_Float (V)));
            end;
         end;
      end loop;
      Self.Offset := Self.Offset + 1;
   end Draw;

end Model_Runner.Philox;
