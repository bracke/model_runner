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

   --  Levels for one run of a super-block, indexed from zero.
   type Level_Run is array (Integer range <>) of Integer;

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

   --  Nearest, ties to even, in the arithmetic the reference does it in.
   --
   --  It writes `nearest_int` as an addition of 1.5 x 2**23 followed by a
   --  read of the mantissa bits, which is a rounding to nearest with ties to
   --  even because that is what the addition itself does. Said here as what
   --  it is rather than as the trick that achieves it: the trick is a way of
   --  getting the rounding without a conversion, and the rounding is the
   --  part that has to match.
   function Nearest (Item : N.Real) return Integer
   is (if Item >= 4.0E6 then 4_000_000
       elsif Item <= -4.0E6 then -4_000_000
       elsif Item > -4.0E6 and then Item < 4.0E6
       then Integer (N.Real'Unbiased_Rounding (Item))
       else 0);

   --  A block whose largest magnitude is under this is all zeros as far as
   --  the reference is concerned: GROUP_MAX_EPS.
   Nothing_There : constant N.Real := 1.0E-15;

   --  The scale a run of values is best fitted by, and the levels that go
   --  with it -- llama.cpp's make_qx_quants with an rmse type of one.
   --
   --  A first scale is taken from the largest magnitude, then nineteen
   --  candidates around it are tried and the best weighted fit kept. The
   --  weight is the value squared, which is what an rmse type of one asks
   --  for, so a run's larger values decide its scale.
   --
   --  THE COMPARISON IS THE WHOLE OF THE SEARCH, and it is written the way
   --  the reference writes it: sumlx*sumlx > best*suml2 rather than the
   --  division those two stand for, so that a candidate is judged without a
   --  divide and two implementations agree about which side of it a
   --  near-tie falls.
   procedure Fit_Run
     (Values  : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Scale   : out N.Real);

   procedure Fit_Run
     (Values  : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Scale   : out N.Real)
   is
      Amax   : N.Real := 0.0;
      Signed : N.Real := 0.0;

      Over   : N.Real;
      Sum_LX : N.Real := 0.0;
      Sum_L2 : N.Real := 0.0;
      Best   : N.Real;
   begin
      for Index in Values'Range loop
         if abs Values (Index) > Amax then
            Amax := abs Values (Index);
            Signed := Values (Index);
         end if;
      end loop;

      if Amax < Nothing_There then
         Levels := [others => 0];
         Scale := 0.0;
         return;
      end if;

      Over := N.Real (-Most) / Signed;

      for Index in Values'Range loop
         declare
            Level : constant Integer :=
              Integer'Max (-Most,
                           Integer'Min (Most - 1,
                                        Nearest (Over * Values (Index))));
            Weight : constant N.Real :=
              Values (Index) * Values (Index);
         begin
            Levels (Integer (Index - Values'First)) := Level + Most;
            Sum_LX := Sum_LX + Weight * Values (Index) * N.Real (Level);
            Sum_L2 := Sum_L2
              + Weight * N.Real (Level) * N.Real (Level);
         end;
      end loop;

      Scale := (if Sum_L2 /= 0.0 then Sum_LX / Sum_L2 else 0.0);
      Best := Scale * Sum_LX;

      for Step in -9 .. 9 loop
         if Step /= 0 then
            declare
               Try : constant N.Real :=
                 -(N.Real (Most) + 0.1 * N.Real (Step)) / Signed;

               Try_LX : N.Real := 0.0;
               Try_L2 : N.Real := 0.0;
            begin
               for Index in Values'Range loop
                  declare
                     Level : constant Integer :=
                       Integer'Max
                         (-Most,
                          Integer'Min (Most - 1,
                                       Nearest (Try * Values (Index))));
                     Weight : constant N.Real :=
                       Values (Index) * Values (Index);
                  begin
                     Try_LX := Try_LX
                       + Weight * Values (Index) * N.Real (Level);
                     Try_L2 := Try_L2
                       + Weight * N.Real (Level) * N.Real (Level);
                  end;
               end loop;

               if Try_L2 > 0.0
                 and then Try_LX * Try_LX > Best * Try_L2
               then
                  for Index in Values'Range loop
                     Levels (Integer (Index - Values'First)) :=
                       Most
                       + Integer'Max
                           (-Most,
                            Integer'Min
                              (Most - 1,
                               Nearest (Try * Values (Index))));
                  end loop;
                  Scale := Try_LX / Try_L2;
                  Best := Scale * Try_LX;
               end if;
            end;
         end if;
      end loop;
   end Fit_Run;

   --  A scale and a minimum fitted to a run together -- llama.cpp's
   --  make_qkx2_quants, with the arguments Q4_K gives it.
   --
   --  Where Fit_Run above fits one number, this fits two: the levels a run
   --  is written as are `scale * level + min`, so both have to be chosen at
   --  once. Each of twenty-one candidate inverse scales gives a set of
   --  levels, the pair that best fits those levels is solved for exactly by
   --  two-by-two least squares, and the candidate whose pair has the
   --  smallest weighted error wins.
   --
   --  The minimum is held at or below zero throughout, which is what makes
   --  the levels unsigned: a run whose values are all positive is written
   --  from a minimum of nothing.
   procedure Fit_Run_And_Min
     (Values  : Real_Array;
      Weights : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Least   : out N.Real;
      Scale   : out N.Real);

   procedure Fit_Run_And_Min
     (Values  : Real_Array;
      Weights : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Least   : out N.Real;
      Scale   : out N.Real)
   is
      Smallest : N.Real := Values (Values'First);
      Largest  : N.Real := Values (Values'First);
      Sum_W    : N.Real := Weights (Weights'First);
      Sum_X    : N.Real := Weights (Weights'First) * Values (Values'First);

      Over  : N.Real;
      Best  : N.Real := 0.0;

      Try_Levels : Level_Run (Levels'Range);
   begin
      for Index in Values'First + 1 .. Values'Last loop
         declare
            Value  : constant N.Real := Values (Index);
            Weight : constant N.Real :=
              Weights (Weights'First + (Index - Values'First));
         begin
            Smallest := N.Real'Min (Smallest, Value);
            Largest := N.Real'Max (Largest, Value);
            Sum_W := Sum_W + Weight;
            Sum_X := Sum_X + Weight * Value;
         end;
      end loop;

      if Smallest > 0.0 then
         Smallest := 0.0;
      end if;

      if Largest = Smallest then
         Levels := [others => 0];
         Least := -Smallest;
         Scale := 0.0;
         return;
      end if;

      Over := N.Real (Most) / (Largest - Smallest);
      Scale := 1.0 / Over;

      for Index in Values'Range loop
         declare
            Level : constant Integer :=
              Integer'Max
                (0,
                 Integer'Min
                   (Most,
                    Nearest (Over * (Values (Index) - Smallest))));
            Apart : constant N.Real :=
              Scale * N.Real (Level) + Smallest - Values (Index);
         begin
            Levels (Integer (Index - Values'First)) := Level;
            Best := Best
              + Weights (Weights'First + (Index - Values'First))
                * Apart * Apart;
         end;
      end loop;

      for Step in 0 .. 20 loop
         declare
            Try : constant N.Real :=
              (-1.0 + 0.1 * N.Real (Step) + N.Real (Most))
              / (Largest - Smallest);

            Sum_L  : N.Real := 0.0;
            Sum_L2 : N.Real := 0.0;
            Sum_XL : N.Real := 0.0;
         begin
            for Index in Values'Range loop
               declare
                  Level : constant Integer :=
                    Integer'Max
                      (0,
                       Integer'Min
                         (Most,
                          Nearest (Try * (Values (Index) - Smallest))));
                  Weight : constant N.Real :=
                    Weights (Weights'First + (Index - Values'First));
               begin
                  Try_Levels (Integer (Index - Values'First)) := Level;
                  Sum_L := Sum_L + Weight * N.Real (Level);
                  Sum_L2 := Sum_L2
                    + Weight * N.Real (Level) * N.Real (Level);
                  Sum_XL := Sum_XL
                    + Weight * N.Real (Level) * Values (Index);
               end;
            end loop;

            declare
               Under : constant N.Real :=
                 Sum_W * Sum_L2 - Sum_L * Sum_L;
            begin
               if Under > 0.0 then
                  declare
                     This_Scale : N.Real :=
                       (Sum_W * Sum_XL - Sum_X * Sum_L) / Under;
                     This_Min : N.Real :=
                       (Sum_L2 * Sum_X - Sum_L * Sum_XL) / Under;

                     Error : N.Real := 0.0;
                  begin
                     if This_Min > 0.0 then
                        This_Min := 0.0;
                        This_Scale := Sum_XL / Sum_L2;
                     end if;

                     for Index in Values'Range loop
                        declare
                           Apart : constant N.Real :=
                             This_Scale
                               * N.Real
                                   (Try_Levels
                                      (Integer (Index - Values'First)))
                             + This_Min - Values (Index);
                        begin
                           Error := Error
                             + Weights
                                 (Weights'First + (Index - Values'First))
                               * Apart * Apart;
                        end;
                     end loop;

                     if Error < Best then
                        Levels := Try_Levels;
                        Best := Error;
                        Scale := This_Scale;
                        Smallest := This_Min;
                     end if;
                  end;
               end if;
            end;
         end;
      end loop;

      Least := -Smallest;
   end Fit_Run_And_Min;

   ------------
   -- Encode --
   ------------

   function Encode (Values : Real_Array; Into : Target) return Byte_Array is
      Span   : constant Element_Count := Block_Of (Into);
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

               when Q4_K =>
                  declare
                     --  Eight runs of thirty-two, each fitted for a scale
                     --  and a minimum of its own, and then those sixteen
                     --  numbers quantized to six bits apiece against the
                     --  largest of each kind.
                     Runs : constant Element_Count := Span / 32;

                     Levels : Level_Run (0 .. Integer (Span) - 1) :=
                       [others => 0];
                     Scales : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];
                     Least  : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];

                     Widest_Scale : N.Real := 0.0;
                     Widest_Least : N.Real := 0.0;
                  begin
                     for Run in 0 .. Integer (Runs) - 1 loop
                        declare
                           At_Run : constant Element_Count :=
                             First + Element_Count (Run) * 32;

                           Here    : Level_Run (0 .. 31);
                           Weights : Real_Array (0 .. 31);

                           Squared : N.Real := 0.0;
                           Fit     : N.Real;
                           Low     : N.Real;
                        begin
                           --  The weight a run's values carry: the root
                           --  mean square of the run plus each value's own
                           --  magnitude, so a run's larger values pull the
                           --  fit without its smaller ones being ignored.
                           for Index in 0 .. 31 loop
                              Squared := Squared
                                + Values (At_Run + Element_Count (Index))
                                  * Values (At_Run + Element_Count (Index));
                           end loop;

                           declare
                              Middling : constant N.Real :=
                                N.Real (N.Sqrt
                                          (N.Wide_Real (Squared / 32.0)));
                           begin
                              for Index in 0 .. 31 loop
                                 Weights (Element_Count (Index)) :=
                                   Middling
                                   + abs Values
                                           (At_Run + Element_Count (Index));
                              end loop;
                           end;

                           Fit_Run_And_Min
                             (Values (At_Run .. At_Run + 31), Weights, 15,
                              Here, Low, Fit);

                           Scales (Run) := Fit;
                           Least (Run) := Low;

                           for Index in Here'Range loop
                              Levels (Run * 32 + Index) := Here (Index);
                           end loop;

                           if Fit > Widest_Scale then
                              Widest_Scale := Fit;
                           end if;
                           if Low > Widest_Least then
                              Widest_Least := Low;
                           end if;
                        end;
                     end loop;

                     declare
                        Over_Scale : constant N.Real :=
                          (if Widest_Scale > 0.0
                           then 63.0 / Widest_Scale else 0.0);
                        Over_Least : constant N.Real :=
                          (if Widest_Least > 0.0
                           then 63.0 / Widest_Least else 0.0);

                        --  Twelve bytes holding eight six-bit scales and
                        --  eight six-bit minimums, four of each plainly and
                        --  four split across a nibble and a pair of top
                        --  bits.
                        Packed : array (0 .. 11) of Interfaces.Unsigned_8 :=
                          [others => 0];
                     begin
                        for Run in 0 .. Integer (Runs) - 1 loop
                           declare
                              Step_S : constant Interfaces.Unsigned_8 :=
                                Interfaces.Unsigned_8
                                  (Integer'Min
                                     (63,
                                      Nearest (Over_Scale * Scales (Run))));
                              Step_M : constant Interfaces.Unsigned_8 :=
                                Interfaces.Unsigned_8
                                  (Integer'Min
                                     (63,
                                      Nearest (Over_Least * Least (Run))));
                           begin
                              if Run < 4 then
                                 Packed (Run) := Step_S;
                                 Packed (Run + 4) := Step_M;
                              else
                                 Packed (Run + 4) :=
                                   (Step_S and 16#0F#)
                                   or Interfaces.Shift_Left
                                        (Step_M and 16#0F#, 4);
                                 Packed (Run - 4) := Packed (Run - 4)
                                   or Interfaces.Shift_Left
                                        (Interfaces.Shift_Right (Step_S, 4),
                                         6);
                                 Packed (Run) := Packed (Run)
                                   or Interfaces.Shift_Left
                                        (Interfaces.Shift_Right (Step_M, 4),
                                         6);
                              end if;
                           end;
                        end loop;

                        Put_Half (Result, At_Byte, Widest_Scale / 63.0);
                        Put_Half (Result, At_Byte + 2, Widest_Least / 63.0);

                        for Which in Packed'Range loop
                           Result (At_Byte + 4 + B.Byte_Count (Which)) :=
                             B.Byte (Packed (Which));
                        end loop;

                        --  And the levels again, against the scales as the
                        --  file now holds them rather than as they were
                        --  fitted.
                        declare
                           Held_D : constant N.Real :=
                             N.To_Real
                               (N.To_Half (Widest_Scale / 63.0));
                           Held_M : constant N.Real :=
                             N.To_Real
                               (N.To_Half (Widest_Least / 63.0));
                        begin
                           for Run in 0 .. Integer (Runs) - 1 loop
                              declare
                                 Step_S, Step_M : Interfaces.Unsigned_8;
                              begin
                                 if Run < 4 then
                                    Step_S := Packed (Run) and 63;
                                    Step_M := Packed (Run + 4) and 63;
                                 else
                                    Step_S :=
                                      (Packed (Run + 4) and 16#0F#)
                                      or Interfaces.Shift_Left
                                           (Interfaces.Shift_Right
                                              (Packed (Run - 4), 6), 4);
                                    Step_M :=
                                      Interfaces.Shift_Right
                                        (Packed (Run + 4), 4)
                                      or Interfaces.Shift_Left
                                           (Interfaces.Shift_Right
                                              (Packed (Run), 6), 4);
                                 end if;

                                 declare
                                    Apart : constant N.Real :=
                                      Held_D * N.Real (Step_S);
                                    Lift  : constant N.Real :=
                                      Held_M * N.Real (Step_M);
                                 begin
                                    if Apart /= 0.0 then
                                       for Index in 0 .. 31 loop
                                          Levels (Run * 32 + Index) :=
                                            Integer'Max
                                              (0,
                                               Integer'Min
                                                 (15,
                                                  Nearest
                                                    ((Values
                                                        (First
                                                         + Element_Count
                                                             (Run * 32
                                                              + Index))
                                                      + Lift) / Apart)));
                                       end loop;
                                    end if;
                                 end;
                              end;
                           end loop;
                        end;

                        --  Two runs to a byte, the second in the high
                        --  nibble, sixty-four elements at a time.
                        for Pair in 0 .. Integer (Span) / 64 - 1 loop
                           for Index in 0 .. 31 loop
                              Result (At_Byte + 16
                                      + B.Byte_Count (Pair * 32 + Index)) :=
                                B.Byte
                                  (Levels (Pair * 64 + Index)
                                   + Levels (Pair * 64 + Index + 32) * 16);
                           end loop;
                        end loop;
                     end;
                  end;

               when Q6_K =>
                  declare
                     --  Sixteen runs of sixteen, each fitted on its own, and
                     --  then the sixteen scales quantized against the
                     --  largest of them.
                     Runs : constant Element_Count := Span / 16;

                     Levels : Level_Run (0 .. Integer (Span) - 1) :=
                       [others => 0];
                     Scales : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];

                     Widest : N.Real := 0.0;
                     Signed : N.Real := 0.0;
                  begin
                     for Run in 0 .. Integer (Runs) - 1 loop
                        declare
                           At_Run : constant Element_Count :=
                             First + Element_Count (Run) * 16;

                           Here : Level_Run (0 .. 15);
                           Fit  : N.Real;
                        begin
                           Fit_Run
                             (Values (At_Run .. At_Run + 15), 32, Here, Fit);
                           Scales (Run) := Fit;

                           for Index in Here'Range loop
                              Levels (Run * 16 + Index) := Here (Index);
                           end loop;

                           if abs Fit > Widest then
                              Widest := abs Fit;
                              Signed := Fit;
                           end if;
                        end;
                     end loop;

                     --  A super-block with nothing in it is written as
                     --  nothing, which the reference does by clearing the
                     --  whole block: the bytes are already zero here.
                     if Widest >= Nothing_There then
                        declare
                           Over  : constant N.Real := -128.0 / Signed;
                           Scale : constant N.Real := 1.0 / Over;

                           --  The factor as the file will hold it, because
                           --  the levels below are taken against what a
                           --  reader will see and not against what was
                           --  computed.
                           Held_D : constant N.Real :=
                             N.To_Real (N.To_Half (Scale));

                           Steps : array (0 .. Integer (Runs) - 1) of Integer;
                        begin
                           Put_Half (Result, At_Byte + 208, Scale);

                           for Run in Steps'Range loop
                              Steps (Run) :=
                                Integer'Min
                                  (127, Nearest (Over * Scales (Run)));
                              Result (At_Byte + 128 + 64
                                      + B.Byte_Count (Run)) :=
                                B.Byte (Steps (Run) mod 256);
                           end loop;

                           for Run in Steps'Range loop
                              declare
                                 Apart : constant N.Real :=
                                   Held_D * N.Real (Steps (Run));
                              begin
                                 if Apart /= 0.0 then
                                    for Index in 0 .. 15 loop
                                       Levels (Run * 16 + Index) :=
                                         32 + Integer'Max
                                           (-32,
                                            Integer'Min
                                              (31,
                                               Nearest
                                                 (Values
                                                    (First
                                                     + Element_Count
                                                         (Run * 16 + Index))
                                                  / Apart)));
                                    end loop;
                                 end if;
                              end;
                           end loop;

                           --  Two halves of a hundred and twenty-eight, each
                           --  packing four runs of thirty-two: the low four
                           --  bits into a nibble apiece and the top two into
                           --  a byte shared by all four.
                           for Half in 0 .. 1 loop
                              declare
                                 At_Level : constant Integer := Half * 128;
                                 At_Low   : constant B.Byte_Count :=
                                   At_Byte + B.Byte_Count (Half) * 64;
                                 At_High  : constant B.Byte_Count :=
                                   At_Byte + 128 + B.Byte_Count (Half) * 32;
                              begin
                                 for Index in 0 .. 31 loop
                                    declare
                                       A : constant Integer :=
                                         Levels (At_Level + Index);
                                       C : constant Integer :=
                                         Levels (At_Level + Index + 32);
                                       D : constant Integer :=
                                         Levels (At_Level + Index + 64);
                                       F : constant Integer :=
                                         Levels (At_Level + Index + 96);
                                    begin
                                       Result (At_Low + B.Byte_Count (Index)) :=
                                         B.Byte ((A mod 16)
                                                 + (D mod 16) * 16);
                                       Result (At_Low + 32
                                               + B.Byte_Count (Index)) :=
                                         B.Byte ((C mod 16)
                                                 + (F mod 16) * 16);
                                       Result (At_High
                                               + B.Byte_Count (Index)) :=
                                         B.Byte ((A / 16)
                                                 + (C / 16) * 4
                                                 + (D / 16) * 16
                                                 + (F / 16) * 64);
                                    end;
                                 end loop;
                              end;
                           end loop;
                        end;
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
