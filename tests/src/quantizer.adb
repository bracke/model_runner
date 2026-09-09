with Interfaces;

with Model_Runner.Text;

package body Quantizer is

   package B renames Model_Runner.Bytes;
   package N renames Model_Runner.Numerics;

   use type B.Byte_Count;
   use type Element_Count;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type N.Real;

   --  The reference truncates toward zero after adding a half, which is not
   --  a rounding to nearest and is what the file format's own encoder does:
   --  `(int8_t)(x0 + 8.5f)`. A value of -0.4 lands one level lower than a
   --  rounding would put it, and every file anyone has quantized carries
   --  that. Written out here rather than reached for, so that a reader of
   --  this package can see it was copied on purpose.
   --  Bounded, because the conversion is not. |x * id| cannot exceed the
   --  number of steps when the scale came from the block's own largest
   --  magnitude -- but a block whose largest magnitude underflows to zero in
   --  binary32 makes the reciprocal infinite, and an infinity converted to
   --  an integer raises where C's cast merely does something. A value no
   --  rounding could produce is clamped to one an integer holds, and one
   --  that is not a number -- which no comparison is true of -- falls to the
   --  zero at the end.
   function Toward_Zero (Item : N.Real) return Integer is
      Value : constant Long_Float := Long_Float (Item);
   begin
      if Value >= 1.0E9 then
         return Integer'Last / 2;
      elsif Value <= -1.0E9 then
         return -(Integer'Last / 2);
      elsif Value > 0.0 then
         return Integer (Long_Float'Floor (Value));
      elsif Value < 0.0 then
         return Integer (Long_Float'Ceiling (Value));
      else
         return 0;
      end if;
   end Toward_Zero;

   --  And the clamp is on the high side only, which the reference also
   --  writes: MIN(15, ...) with nothing under it. A block whose largest
   --  magnitude is negative can produce a level below zero, and the low
   --  nibble it is written into takes the bottom four bits of it.
   function Held (Item : Integer; Upto : Integer) return Interfaces.Unsigned_8
   is (Interfaces.Unsigned_8 (Integer'Min (Item, Upto) mod 256));

   --  Two half-precision bytes, least significant first, as the file
   --  format writes them.
   procedure Put_Half
     (Into : in out Byte_Array; At_Byte : B.Byte_Count; Value : N.Real)
   is
      Bits : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (N.To_Half (Value));
   begin
      Into (At_Byte) := B.Byte (Bits and 16#FF#);
      Into (At_Byte + 1) := B.Byte (Interfaces.Shift_Right (Bits, 8));
   end Put_Half;

   ------------
   -- Encode --
   ------------

   function Encode (Values : Real_Array; Into : Target) return Byte_Array is
      Span   : constant Element_Count := Block;
      Width  : constant B.Byte_Count := Bytes_Of (Into);
      Blocks : constant Element_Count := Values'Length / Span;

      Result : Byte_Array (0 .. B.Byte_Count (Blocks) * Width - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant Element_Count := Values'First + Block * Span;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * Width;

            --  The two ways a block finds its scale. Q8_0, Q4_0 and Q5_0
            --  take the largest magnitude and keep its sign; Q4_1 and Q5_1
            --  take the smallest and the largest.
            Amax     : N.Real := 0.0;
            Signed   : N.Real := 0.0;
            Smallest : N.Real := N.Real'Last;
            Largest  : N.Real := N.Real'First;
         begin
            for Index in 0 .. Span - 1 loop
               declare
                  Value : constant N.Real := Values (First + Index);
               begin
                  if Amax < abs Value then
                     Amax := abs Value;
                     Signed := Value;
                  end if;
                  Smallest := N.Real'Min (Smallest, Value);
                  Largest := N.Real'Max (Largest, Value);
               end;
            end loop;

            case Into is
               when Q8_0 =>
                  declare
                     Scale : constant N.Real := Amax / 127.0;
                     Over  : constant N.Real :=
                       (if Scale /= 0.0 then 1.0 / Scale else 0.0);
                  begin
                     Put_Half (Result, At_Byte, Scale);

                     for Index in 0 .. Span - 1 loop
                        declare
                           --  Nearest, ties away from zero, which is what
                           --  roundf does and what this one format uses.
                           Level : constant N.Real :=
                             N.Real'Rounding (Values (First + Index) * Over);
                        begin
                           Result (At_Byte + 2 + B.Byte_Count (Index)) :=
                             B.Byte (Integer (Level) mod 256);
                        end;
                     end loop;
                  end;

               when Q4_0 | Q5_0 =>
                  declare
                     Steps : constant N.Real :=
                       (if Into = Q4_0 then 8.0 else 16.0);
                     Ceiling : constant Integer :=
                       (if Into = Q4_0 then 15 else 31);
                     Nibbles : constant B.Byte_Count :=
                       (if Into = Q4_0 then 2 else 6);

                     Scale : constant N.Real := Signed / (-Steps);
                     Over  : constant N.Real :=
                       (if Scale /= 0.0 then 1.0 / Scale else 0.0);

                     Fifth : Interfaces.Unsigned_32 := 0;
                  begin
                     Put_Half (Result, At_Byte, Scale);

                     for Index in 0 .. Span / 2 - 1 loop
                        declare
                           Low : constant Interfaces.Unsigned_8 :=
                             Held (Toward_Zero
                                     (Values (First + Index) * Over
                                      + Steps + 0.5),
                                   Ceiling);
                           High : constant Interfaces.Unsigned_8 :=
                             Held (Toward_Zero
                                     (Values (First + Span / 2 + Index) * Over
                                      + Steps + 0.5),
                                   Ceiling);
                        begin
                           Result (At_Byte + Nibbles + B.Byte_Count (Index)) :=
                             B.Byte ((Low and 16#0F#)
                                     or Interfaces.Shift_Left
                                          (High and 16#0F#, 4));

                           if Into = Q5_0 then
                              Fifth := Fifth
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Interfaces.Shift_Right
                                           (Low and 16#10#, 4)),
                                      Natural (Index));
                              Fifth := Fifth
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Interfaces.Shift_Right
                                           (High and 16#10#, 4)),
                                      Natural (Index) + Natural (Span / 2));
                           end if;
                        end;
                     end loop;

                     if Into = Q5_0 then
                        for Byte in 0 .. 3 loop
                           Result (At_Byte + 2 + B.Byte_Count (Byte)) :=
                             B.Byte
                               (Interfaces.Shift_Right (Fifth, 8 * Byte)
                                and 16#FF#);
                        end loop;
                     end if;
                  end;

               when Q4_1 | Q5_1 =>
                  declare
                     Levels : constant N.Real :=
                       (if Into = Q4_1 then 15.0 else 31.0);
                     Ceiling : constant Integer :=
                       (if Into = Q4_1 then 15 else 31);
                     Nibbles : constant B.Byte_Count :=
                       (if Into = Q4_1 then 4 else 8);

                     Scale : constant N.Real :=
                       (Largest - Smallest) / Levels;
                     Over  : constant N.Real :=
                       (if Scale /= 0.0 then 1.0 / Scale else 0.0);

                     Fifth : Interfaces.Unsigned_32 := 0;
                  begin
                     Put_Half (Result, At_Byte, Scale);
                     Put_Half (Result, At_Byte + 2, Smallest);

                     for Index in 0 .. Span / 2 - 1 loop
                        declare
                           Low : constant Interfaces.Unsigned_8 :=
                             Held (Toward_Zero
                                     ((Values (First + Index) - Smallest)
                                      * Over + 0.5),
                                   Ceiling);
                           High : constant Interfaces.Unsigned_8 :=
                             Held (Toward_Zero
                                     ((Values (First + Span / 2 + Index)
                                       - Smallest) * Over + 0.5),
                                   Ceiling);
                        begin
                           Result (At_Byte + Nibbles + B.Byte_Count (Index)) :=
                             B.Byte ((Low and 16#0F#)
                                     or Interfaces.Shift_Left
                                          (High and 16#0F#, 4));

                           if Into = Q5_1 then
                              Fifth := Fifth
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Interfaces.Shift_Right
                                           (Low and 16#10#, 4)),
                                      Natural (Index));
                              Fifth := Fifth
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Interfaces.Shift_Right
                                           (High and 16#10#, 4)),
                                      Natural (Index) + Natural (Span / 2));
                           end if;
                        end;
                     end loop;

                     if Into = Q5_1 then
                        for Byte in 0 .. 3 loop
                           Result (At_Byte + 4 + B.Byte_Count (Byte)) :=
                             B.Byte
                               (Interfaces.Shift_Right (Fifth, 8 * Byte)
                                and 16#FF#);
                        end loop;
                     end if;
                  end;
            end case;
         end;
      end loop;

      return Result;
   end Encode;

   -----------
   -- Named --
   -----------

   procedure Named (Text : String; Item : out Target; Known : out Boolean) is
      Said : constant String := Model_Runner.Text.To_Lower (Text);
   begin
      Known := True;
      for Which in Target loop
         if Name_Of (Which) = Said then
            Item := Which;
            return;
         end if;
      end loop;

      Item := Q8_0;
      Known := False;
   end Named;

end Quantizer;
