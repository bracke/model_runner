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
      Scale   : out N.Real;
      Weights : Real_Array;
      Told    : Boolean := False);

   procedure Fit_Run
     (Values  : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Scale   : out N.Real;
      Weights : Real_Array;
      Told    : Boolean := False)
   is
      --  What a value is worth to the fit: its own square where nobody
      --  said, and what an importance matrix says where somebody did. That
      --  one substitution is the whole of the reference's weighted Q6_K --
      --  `make_qx_quants(16, 32, x, L, 1, qw)` against the same call with a
      --  null weight -- and it is what a mixture's extra bits are spent
      --  through, so leaving it out quantized the twenty-one tensors a
      --  recipe lifts as though no matrix had been given.
      function Weight_At (Index : Element_Count) return N.Real
      is (if Told
          then Weights (Weights'First + (Index - Values'First))
          else Values (Index) * Values (Index));
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
            Weight : constant N.Real := Weight_At (Index);
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
                     Weight : constant N.Real := Weight_At (Index);
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
      Scale   : out N.Real;
      From    : N.Real := -1.0;
      By      : N.Real := 0.1;
      Steps   : Natural := 20;
      Weighed : Boolean := False;
      By_Size : Boolean := False);

   procedure Fit_Run_And_Min
     (Values  : Real_Array;
      Weights : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Least   : out N.Real;
      Scale   : out N.Real;
      From    : N.Real := -1.0;
      By      : N.Real := 0.1;
      Steps   : Natural := 20;
      Weighed : Boolean := False;
      By_Size : Boolean := False)
   is
      --  How far a level lands from its value, counted either way: the
      --  square of the miss, or its size. Q2_K asks for the size and every
      --  other format here asks for the square, which is `use_mad` in the
      --  reference and is one word rather than a second search.
      function Missed (Apart : N.Real) return N.Real
      is (if By_Size then abs Apart else Apart * Apart);
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

      --  The weighted path treats a run whose largest value is at or below
      --  its minimum as empty, where the plain one only treats an exactly
      --  flat run that way. It matters for a run that is all negative:
      --  the minimum is clamped to zero above it and the largest is not.
      if (if Weighed then Largest <= Smallest else Largest = Smallest) then
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
                * Missed (Apart);
         end;
      end loop;

      for Step in 0 .. Steps loop
         declare
            Try : constant N.Real :=
              (From + By * N.Real (Step) + N.Real (Most))
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
                               * Missed (Apart);
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

   --  A run of positive numbers quantized against their largest, refined --
   --  llama.cpp's make_qp_quants.
   --
   --  Where the searches above choose a scale for a run of weights, this
   --  chooses one for a run of SCALES: the eight or sixteen a super-block
   --  found, which have themselves to be written in six bits. Nine
   --  candidates, then five passes of moving one level at a time while any
   --  move improves the weighted fit.
   procedure Fit_Positives
     (Values  : Real_Array;
      Weights : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Scale   : out N.Real);

   procedure Fit_Positives
     (Values  : Real_Array;
      Weights : Real_Array;
      Most    : Integer;
      Levels  : out Level_Run;
      Scale   : out N.Real)
   is
      function Weight_Of (Index : Element_Count) return N.Real
      is (Weights (Weights'First + (Index - Values'First)));

      Largest : N.Real := 0.0;
      Over    : N.Real;

      Best   : N.Real := 0.0;
      Sum_LX : N.Real := 0.0;
      Sum_L2 : N.Real := 0.0;
   begin
      for Index in Values'Range loop
         Largest := N.Real'Max (Largest, Values (Index));
      end loop;

      if Largest < Nothing_There then
         Levels := [others => 0];
         Scale := 0.0;
         return;
      end if;

      Over := N.Real (Most) / Largest;

      for Index in Values'Range loop
         Levels (Integer (Index - Values'First)) :=
           Nearest (Over * Values (Index));
      end loop;

      Scale := 1.0 / Over;

      for Index in Values'Range loop
         declare
            Apart : constant N.Real :=
              Values (Index)
              - Scale * N.Real (Levels (Integer (Index - Values'First)));
         begin
            Best := Best + Weight_Of (Index) * Apart * Apart;
         end;
      end loop;

      for Step in -4 .. 4 loop
         if Step /= 0 then
            declare
               Try : constant N.Real :=
                 (0.1 * N.Real (Step) + N.Real (Most)) / Largest;
               Back : constant N.Real := 1.0 / Try;

               Error : N.Real := 0.0;
            begin
               for Index in Values'Range loop
                  declare
                     Level : constant Integer :=
                       Integer'Min (Most, Nearest (Try * Values (Index)));
                     Apart : constant N.Real :=
                       Values (Index) - Back * N.Real (Level);
                  begin
                     Error := Error + Weight_Of (Index) * Apart * Apart;
                  end;
               end loop;

               if Error < Best then
                  Best := Error;
                  Over := Try;
               end if;
            end;
         end if;
      end loop;

      for Index in Values'Range loop
         declare
            Level : constant Integer :=
              Integer'Min (Most, Nearest (Over * Values (Index)));
         begin
            Levels (Integer (Index - Values'First)) := Level;
            Sum_LX := Sum_LX
              + Weight_Of (Index) * Values (Index) * N.Real (Level);
            Sum_L2 := Sum_L2
              + Weight_Of (Index) * N.Real (Level) * N.Real (Level);
         end;
      end loop;

      --  And five passes of moving one level at a time. A move is kept when
      --  it improves the fit, which is asked as a comparison of products
      --  rather than of the two ratios they stand for.
      for Pass in 1 .. 5 loop
         declare
            Moved : Natural := 0;
         begin
            for Index in Values'Range loop
               declare
                  Slot   : constant Integer := Integer (Index - Values'First);
                  Weight : constant N.Real := Weight_Of (Index);

                  Less_LX : N.Real :=
                    Sum_LX - Weight * Values (Index) * N.Real (Levels (Slot));
                  Less_L2 : N.Real :=
                    Sum_L2
                    - Weight * N.Real (Levels (Slot)) * N.Real (Levels (Slot));
               begin
                  if Less_LX > 0.0 and then Less_L2 > 0.0 then
                     declare
                        Fresh : constant Integer :=
                          Integer'Min
                            (Most,
                             Nearest (Values (Index) * Less_L2 / Less_LX));
                     begin
                        if Fresh /= Levels (Slot) then
                           Less_LX := Less_LX
                             + Weight * Values (Index) * N.Real (Fresh);
                           Less_L2 := Less_L2
                             + Weight * N.Real (Fresh) * N.Real (Fresh);

                           if Less_LX * Less_LX * Sum_L2
                              > Sum_LX * Sum_LX * Less_L2
                           then
                              Levels (Slot) := Fresh;
                              Sum_LX := Less_LX;
                              Sum_L2 := Less_L2;
                              Moved := Moved + 1;
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            exit when Moved = 0;
         end;
      end loop;

      Scale := (if Sum_L2 > 0.0 then Sum_LX / Sum_L2 else 0.0);
   end Fit_Positives;

   --  A signed run fitted and then refined one level at a time --
   --  llama.cpp's make_q3_quants with its rmse pass on.
   --
   --  Where Fit_Run above sweeps candidate scales, this takes one scale
   --  from the largest magnitude and then improves the levels: five passes
   --  of moving each level to wherever the running fit says it should be,
   --  keeping the move when the fit improves. Q3_K is the only format here
   --  that asks for it.
   procedure Fit_Signed
     (Values : Real_Array;
      Most   : Integer;
      Levels : out Level_Run;
      Scale  : out N.Real);

   procedure Fit_Signed
     (Values : Real_Array;
      Most   : Integer;
      Levels : out Level_Run;
      Scale  : out N.Real)
   is
      Amax   : N.Real := 0.0;
      Signed : N.Real := 0.0;

      Sum_LX : N.Real := 0.0;
      Sum_L2 : N.Real := 0.0;
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

      declare
         Over : constant N.Real := N.Real (-Most) / Signed;
      begin
         for Index in Values'Range loop
            declare
               Level : constant Integer :=
                 Integer'Max
                   (-Most,
                    Integer'Min (Most - 1,
                                 Nearest (Over * Values (Index))));
               Weight : constant N.Real :=
                 Values (Index) * Values (Index);
            begin
               Levels (Integer (Index - Values'First)) := Level;
               Sum_LX := Sum_LX + Weight * Values (Index) * N.Real (Level);
               Sum_L2 := Sum_L2 + Weight * N.Real (Level) * N.Real (Level);
            end;
         end loop;
      end;

      for Pass in 1 .. 5 loop
         declare
            Moved : Natural := 0;
         begin
            for Index in Values'Range loop
               declare
                  Slot   : constant Integer := Integer (Index - Values'First);
                  Weight : constant N.Real :=
                    Values (Index) * Values (Index);

                  Less_LX : N.Real :=
                    Sum_LX - Weight * Values (Index) * N.Real (Levels (Slot));
               begin
                  if Less_LX > 0.0 then
                     declare
                        Less_L2 : N.Real :=
                          Sum_L2
                          - Weight * N.Real (Levels (Slot))
                            * N.Real (Levels (Slot));

                        Fresh : constant Integer :=
                          Integer'Max
                            (-Most,
                             Integer'Min
                               (Most - 1,
                                Nearest (Values (Index) * Less_L2 / Less_LX)));
                     begin
                        if Fresh /= Levels (Slot) then
                           Less_LX := Less_LX
                             + Weight * Values (Index) * N.Real (Fresh);
                           Less_L2 := Less_L2
                             + Weight * N.Real (Fresh) * N.Real (Fresh);

                           if Less_L2 > 0.0
                             and then Less_LX * Less_LX * Sum_L2
                                      > Sum_LX * Sum_LX * Less_L2
                           then
                              Levels (Slot) := Fresh;
                              Sum_LX := Less_LX;
                              Sum_L2 := Less_L2;
                              Moved := Moved + 1;
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            exit when Moved = 0;
         end;
      end loop;

      for Slot in Levels'Range loop
         Levels (Slot) := Levels (Slot) + Most;
      end loop;

      Scale := (if Sum_L2 > 0.0 then Sum_LX / Sum_L2 else 0.0);
   end Fit_Signed;

   --  The sixteen levels a non-linear nibble indexes, spaced finely near
   --  zero and coarsely away from it. This is the table itself and not a
   --  rule that generates it: llama.cpp writes the numbers out and so does
   --  this, because a table is what the format is.
   Levels_IQ4 : constant array (0 .. 15) of Integer :=
     [-127, -104, -83, -65, -49, -35, -22, -10,
        1,   13,  25,  38,  53,  69,  89, 113];

   --  Which level a value is nearest, by a binary search of the table and
   --  then a comparison of the two it falls between.
   function Nearest_Level (Item : N.Real) return Integer;

   function Nearest_Level (Item : N.Real) return Integer is
      Low  : Integer := 0;
      High : Integer := 15;
   begin
      if Item <= N.Real (Levels_IQ4 (0)) then
         return 0;
      end if;

      if Item >= N.Real (Levels_IQ4 (15)) then
         return 15;
      end if;

      while High - Low > 1 loop
         declare
            Middle : constant Integer := (Low + High) / 2;
         begin
            if Item < N.Real (Levels_IQ4 (Middle)) then
               High := Middle;
            else
               Low := Middle;
            end if;
         end;
      end loop;

      return (if Item - N.Real (Levels_IQ4 (High - 1))
                 < N.Real (Levels_IQ4 (High)) - Item
              then High - 1 else High);
   end Nearest_Level;

   --  One run of thirty-two fitted against the table.
   --
   --  A first scale from the largest magnitude, then fifteen candidates
   --  around it, each judged by how well the levels the table gives fit the
   --  values -- the same comparison of products the other searches use, so
   --  that a near-tie falls the same way.
   procedure Fit_Table_Run
     (Values  : Real_Array;
      Weights : Real_Array;
      Levels  : out Level_Run;
      Scale   : out N.Real);

   procedure Fit_Table_Run
     (Values  : Real_Array;
      Weights : Real_Array;
      Levels  : out Level_Run;
      Scale   : out N.Real)
   is
      Amax   : N.Real := 0.0;
      Signed : N.Real := 0.0;

      Sum_QX : N.Real := 0.0;
      Sum_Q2 : N.Real := 0.0;
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

      declare
         Over : constant N.Real :=
           1.0 / (-Signed / N.Real (Levels_IQ4 (0)));
      begin
         for Index in Values'Range loop
            declare
               Slot : constant Integer :=
                 Nearest_Level (Over * Values (Index));
               Level : constant N.Real := N.Real (Levels_IQ4 (Slot));
               Weight : constant N.Real :=
                 Weights (Weights'First + (Index - Values'First));
            begin
               Levels (Integer (Index - Values'First)) := Slot;
               Sum_QX := Sum_QX + Weight * Level * Values (Index);
               Sum_Q2 := Sum_Q2 + Weight * Level * Level;
            end;
         end loop;
      end;

      Scale := (if Sum_Q2 > 0.0 then Sum_QX / Sum_Q2 else 0.0);
      Best := Scale * Sum_QX;

      for Step in -7 .. 7 loop
         declare
            Try : constant N.Real :=
              (N.Real (Step) + N.Real (Levels_IQ4 (0))) / Signed;

            Try_QX : N.Real := 0.0;
            Try_Q2 : N.Real := 0.0;
         begin
            for Index in Values'Range loop
               declare
                  Level : constant N.Real :=
                    N.Real (Levels_IQ4 (Nearest_Level (Try * Values (Index))));
                  Weight : constant N.Real :=
                    Weights (Weights'First + (Index - Values'First));
               begin
                  Try_QX := Try_QX + Weight * Level * Values (Index);
                  Try_Q2 := Try_Q2 + Weight * Level * Level;
               end;
            end loop;

            if Try_Q2 > 0.0 and then Try_QX * Try_QX > Best * Try_Q2 then
               Scale := Try_QX / Try_Q2;
               Best := Scale * Try_QX;
            end if;
         end;
      end loop;
   end Fit_Table_Run;

   ------------
   -- Encode --
   ------------

   --  The whole encoding, with or without an importance matrix.
   --
   --  One body rather than two, because a weighted quantization differs
   --  from a plain one in a handful of places and duplicating a hundred
   --  lines of packing to reach them is how the two drift apart.
   function Encoded
     (Values  : Real_Array;
      Heft    : Real_Array;
      Told    : Boolean;
      Into    : Target) return Byte_Array
   is
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

               when Q3_K =>
                  declare
                     --  Sixteen runs of sixteen at three bits, signed: the
                     --  scale of each run comes from Fit_Signed, the
                     --  sixteen scales are themselves written as six-bit
                     --  signed numbers split across twelve bytes, and each
                     --  level's top bit lives in a mask of its own.
                     Runs : constant Element_Count := Span / 16;

                     Levels : Level_Run (0 .. Integer (Span) - 1) :=
                       [others => 0];
                     Scales : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];

                     Widest : N.Real := 0.0;
                     Signed : N.Real := 0.0;

                     Packed : array (0 .. 11) of Interfaces.Unsigned_8 :=
                       [others => 0];
                  begin
                     for Run in 0 .. Integer (Runs) - 1 loop
                        declare
                           At_Run : constant Element_Count :=
                             First + Element_Count (Run) * 16;

                           Here : Level_Run (0 .. 15);
                           Fit  : N.Real;
                        begin
                           Fit_Signed
                             (Values (At_Run .. At_Run + 15), 4, Here, Fit);

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

                     if Signed /= 0.0 then
                        declare
                           Over : constant N.Real := -32.0 / Signed;
                        begin
                           for Run in 0 .. Integer (Runs) - 1 loop
                              declare
                                 Level : Integer :=
                                   Integer'Max
                                     (-32,
                                      Integer'Min
                                        (31,
                                         Nearest (Over * Scales (Run))))
                                   + 32;
                              begin
                                 if Run < 8 then
                                    Packed (Run) := Packed (Run)
                                      or Interfaces.Unsigned_8
                                           (Level mod 16);
                                 else
                                    Packed (Run - 8) := Packed (Run - 8)
                                      or Interfaces.Shift_Left
                                           (Interfaces.Unsigned_8
                                              (Level mod 16), 4);
                                 end if;

                                 Level := Level / 16;
                                 Packed (Run mod 4 + 8) :=
                                   Packed (Run mod 4 + 8)
                                   or Interfaces.Shift_Left
                                        (Interfaces.Unsigned_8 (Level mod 256),
                                         2 * (Run / 4));
                              end;
                           end loop;

                           Put_Half (Result, At_Byte + 108, 1.0 / Over);
                        end;
                     else
                        Put_Half (Result, At_Byte + 108, 0.0);
                     end if;

                     for Which in Packed'Range loop
                        Result (At_Byte + 96 + B.Byte_Count (Which)) :=
                          B.Byte (Packed (Which));
                     end loop;

                     declare
                        Held_D : constant N.Real :=
                          N.To_Real
                            (N.To_Half
                               (if Signed /= 0.0
                                then Signed / (-32.0) else 0.0));
                     begin
                        for Run in 0 .. Integer (Runs) - 1 loop
                           declare
                              Low : constant Interfaces.Unsigned_8 :=
                                (if Run < 8
                                 then Packed (Run) and 16#0F#
                                 else Interfaces.Shift_Right
                                        (Packed (Run - 8), 4));

                              High : constant Interfaces.Unsigned_8 :=
                                Interfaces.Shift_Right
                                  (Packed (Run mod 4 + 8), 2 * (Run / 4))
                                and 3;

                              Step : constant Integer :=
                                Integer (Low)
                                + Integer (High) * 16 - 32;

                              Apart : constant N.Real :=
                                Held_D * N.Real (Step);
                           begin
                              if Apart /= 0.0 then
                                 for Index in 0 .. 15 loop
                                    Levels (Run * 16 + Index) :=
                                      Integer'Max
                                        (-4,
                                         Integer'Min
                                           (3,
                                            Nearest
                                              (Values
                                                 (First
                                                  + Element_Count
                                                      (Run * 16 + Index))
                                               / Apart)))
                                      + 4;
                                 end loop;
                              end if;
                           end;
                        end loop;
                     end;

                     --  The top bit of every level into a mask, eight
                     --  elements to a bit position and thirty-two bytes of
                     --  it; the two that remain into the quants.
                     declare
                        At_Mask : Integer := 0;
                        Bit     : Interfaces.Unsigned_8 := 1;
                     begin
                        for Index in 0 .. Integer (Span) - 1 loop
                           if Levels (Index) > 3 then
                              Result (At_Byte + B.Byte_Count (At_Mask)) :=
                                B.Byte
                                  (Interfaces.Unsigned_8
                                     (Result
                                        (At_Byte + B.Byte_Count (At_Mask)))
                                   or Bit);
                              Levels (Index) := Levels (Index) - 4;
                           end if;

                           At_Mask := At_Mask + 1;
                           if At_Mask = Integer (Span) / 8 then
                              At_Mask := 0;
                              Bit := Interfaces.Shift_Left (Bit, 1);
                           end if;
                        end loop;
                     end;

                     for Group in 0 .. Integer (Span) / 128 - 1 loop
                        for Index in 0 .. 31 loop
                           Result (At_Byte + 32
                                   + B.Byte_Count (Group * 32 + Index)) :=
                             B.Byte
                               (Levels (Group * 128 + Index)
                                + Levels (Group * 128 + Index + 32) * 4
                                + Levels (Group * 128 + Index + 64) * 16
                                + Levels (Group * 128 + Index + 96) * 64);
                        end loop;
                     end loop;
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

               when IQ4_NL | IQ4_XS =>
                  declare
                     Runs : constant Element_Count := Span / 32;

                     Levels : Level_Run (0 .. Integer (Span) - 1) :=
                       [others => 0];
                     Scales : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];

                     Widest : N.Real := 0.0;
                     Signed : N.Real := 0.0;

                     --  The whole super-block's spread, which the weights
                     --  are measured against for the wide format and is not
                     --  used by the narrow one.
                     Squared : N.Real := 0.0;
                     Sigma2  : N.Real;

                     At_Quants : constant B.Byte_Count :=
                       (if Into = IQ4_NL then 2 else 8);
                  begin
                     for Index in Element_Count range 0 .. Span - 1 loop
                        Squared := Squared
                          + Values (First + Index) * Values (First + Index);
                     end loop;
                     Sigma2 := 2.0 * Squared / N.Real (Span);
                     pragma Unreferenced (Sigma2);

                     for Run in 0 .. Integer (Runs) - 1 loop
                        declare
                           At_Run : constant Element_Count :=
                             First + Element_Count (Run) * 32;

                           Here    : Level_Run (0 .. 31);
                           Weights : Real_Array (0 .. 31);
                           Fit     : N.Real;
                        begin
                           --  Unweighted, the value squared is the weight,
                           --  which is what the reference uses where no
                           --  importance matrix was given.
                           for Index in Element_Count range 0 .. 31 loop
                              Weights (Index) :=
                                Values (At_Run + Index)
                                * Values (At_Run + Index);
                           end loop;

                           Fit_Table_Run
                             (Values (At_Run .. At_Run + 31), Weights,
                              Here, Fit);

                           Scales (Run) := Fit;

                           for Index in Here'Range loop
                              Levels (Run * 32 + Index) := Here (Index);
                           end loop;

                           if abs Fit > Widest then
                              Widest := abs Fit;
                              Signed := Fit;
                           end if;
                        end;
                     end loop;

                     if Into = IQ4_XS then
                        declare
                           Scale : constant N.Real := -Signed / 32.0;
                           Over  : constant N.Real :=
                             (if Scale /= 0.0 then 1.0 / Scale else 0.0);

                           Low_Half : array (0 .. 3) of Interfaces.Unsigned_8
                             := [others => 0];
                           High     : Interfaces.Unsigned_16 := 0;
                        begin
                           Put_Half (Result, At_Byte, Scale);

                           for Run in 0 .. Integer (Runs) - 1 loop
                              declare
                                 Step : Integer :=
                                   Integer'Max
                                     (-32,
                                      Integer'Min
                                        (31,
                                         Nearest (Over * Scales (Run))));
                                 Apart : constant N.Real :=
                                   Scale * N.Real (Step);
                                 Back : constant N.Real :=
                                   (if Apart /= 0.0 then 1.0 / Apart
                                    else 0.0);
                              begin
                                 for Index in 0 .. 31 loop
                                    Levels (Run * 32 + Index) :=
                                      Nearest_Level
                                        (Back
                                         * Values
                                             (First
                                              + Element_Count
                                                  (Run * 32 + Index)));
                                 end loop;

                                 Step := Step + 32;

                                 if Run mod 2 = 0 then
                                    Low_Half (Run / 2) :=
                                      Interfaces.Unsigned_8 (Step mod 16);
                                 else
                                    Low_Half (Run / 2) := Low_Half (Run / 2)
                                      or Interfaces.Shift_Left
                                           (Interfaces.Unsigned_8
                                              (Step mod 16), 4);
                                 end if;

                                 High := High
                                   or Interfaces.Shift_Left
                                        (Interfaces.Unsigned_16 (Step / 16),
                                         2 * (Run mod 8));
                              end;
                           end loop;

                           Result (At_Byte + 2) :=
                             B.Byte (High and 16#FF#);
                           Result (At_Byte + 3) :=
                             B.Byte (Interfaces.Shift_Right (High, 8));

                           for Which in Low_Half'Range loop
                              Result (At_Byte + 4 + B.Byte_Count (Which)) :=
                                B.Byte (Low_Half (Which));
                           end loop;
                        end;
                     else
                        declare
                           Over : constant N.Real :=
                             (if Scales (0) /= 0.0 then 1.0 / Scales (0)
                              else 0.0);
                        begin
                           Put_Half (Result, At_Byte, Scales (0));

                           for Index in 0 .. 31 loop
                              Levels (Index) :=
                                Nearest_Level
                                  (Over
                                   * Values
                                       (First + Element_Count (Index)));
                           end loop;
                        end;
                     end if;

                     --  Two levels to a byte, the second sixteen positions
                     --  along rather than one.
                     for Group in 0 .. Integer (Span) / 32 - 1 loop
                        for Index in 0 .. 15 loop
                           Result (At_Byte + At_Quants
                                   + B.Byte_Count (Group * 16 + Index)) :=
                             B.Byte
                               (Levels (Group * 32 + Index)
                                + Levels (Group * 32 + 16 + Index) * 16);
                        end loop;
                     end loop;
                  end;

               when Q2_K =>
                  declare
                     --  Sixteen runs of sixteen with two bits apiece, and
                     --  the sixteen scales and sixteen minimums packed four
                     --  bits each into one byte a run. The search is the
                     --  same one Q4_K and Q5_K use with the error counted
                     --  by size rather than by square, which is what two
                     --  bits a value make worth doing.
                     Runs : constant Element_Count := Span / 16;

                     Levels : Level_Run (0 .. Integer (Span) - 1) :=
                       [others => 0];
                     Scales : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];
                     Least  : array (0 .. Integer (Runs) - 1) of N.Real :=
                       [others => 0.0];

                     Widest_Scale : N.Real := 0.0;
                     Widest_Least : N.Real := 0.0;

                     Packed : array (0 .. 15) of Interfaces.Unsigned_8 :=
                       [others => 0];
                  begin
                     for Run in 0 .. Integer (Runs) - 1 loop
                        declare
                           At_Run : constant Element_Count :=
                             First + Element_Count (Run) * 16;

                           Here    : Level_Run (0 .. 15);
                           Weights : Real_Array (0 .. 15);
                           Fit     : N.Real;
                           Low     : N.Real;
                        begin
                           for Index in Element_Count range 0 .. 15 loop
                              Weights (Index) := abs Values (At_Run + Index);
                           end loop;

                           Fit_Run_And_Min
                             (Values (At_Run .. At_Run + 15), Weights, 3,
                              Here, Low, Fit,
                              From => -0.5, By => 0.1, Steps => 15,
                              By_Size => True);

                           Scales (Run) := Fit;
                           Least (Run) := Low;

                           for Index in Here'Range loop
                              Levels (Run * 16 + Index) := Here (Index);
                           end loop;

                           if Fit > Widest_Scale then
                              Widest_Scale := Fit;
                           end if;
                           if Low > Widest_Least then
                              Widest_Least := Low;
                           end if;
                        end;
                     end loop;

                     if Widest_Scale > 0.0 then
                        declare
                           Over : constant N.Real := 15.0 / Widest_Scale;
                        begin
                           for Run in 0 .. Integer (Runs) - 1 loop
                              Packed (Run) :=
                                Interfaces.Unsigned_8
                                  (Nearest (Over * Scales (Run)) mod 256);
                           end loop;
                        end;
                        Put_Half (Result, At_Byte + 80, Widest_Scale / 15.0);
                     else
                        Put_Half (Result, At_Byte + 80, 0.0);
                     end if;

                     if Widest_Least > 0.0 then
                        declare
                           Over : constant N.Real := 15.0 / Widest_Least;
                        begin
                           for Run in 0 .. Integer (Runs) - 1 loop
                              Packed (Run) := Packed (Run)
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_8
                                        (Nearest (Over * Least (Run))
                                         mod 256),
                                      4);
                           end loop;
                        end;
                        Put_Half (Result, At_Byte + 82, Widest_Least / 15.0);
                     else
                        Put_Half (Result, At_Byte + 82, 0.0);
                     end if;

                     for Which in Packed'Range loop
                        Result (At_Byte + B.Byte_Count (Which)) :=
                          B.Byte (Packed (Which));
                     end loop;

                     declare
                        Held_D : constant N.Real :=
                          N.To_Real
                            (N.To_Half
                               (if Widest_Scale > 0.0
                                then Widest_Scale / 15.0 else 0.0));
                        Held_M : constant N.Real :=
                          N.To_Real
                            (N.To_Half
                               (if Widest_Least > 0.0
                                then Widest_Least / 15.0 else 0.0));
                     begin
                        for Run in 0 .. Integer (Runs) - 1 loop
                           declare
                              Apart : constant N.Real :=
                                Held_D
                                * N.Real (Packed (Run) and 16#0F#);
                              Lift : constant N.Real :=
                                Held_M
                                * N.Real
                                    (Interfaces.Shift_Right (Packed (Run), 4));
                           begin
                              if Apart /= 0.0 then
                                 for Index in 0 .. 15 loop
                                    Levels (Run * 16 + Index) :=
                                      Integer'Max
                                        (0,
                                         Integer'Min
                                           (3,
                                            Nearest
                                              ((Values
                                                  (First
                                                   + Element_Count
                                                       (Run * 16 + Index))
                                                + Lift) / Apart)));
                                 end loop;
                              end if;
                           end;
                        end loop;
                     end;

                     --  Four levels to a byte, a hundred and twenty-eight
                     --  elements at a time.
                     for Group in 0 .. Integer (Span) / 128 - 1 loop
                        for Index in 0 .. 31 loop
                           Result (At_Byte + 16
                                   + B.Byte_Count (Group * 32 + Index)) :=
                             B.Byte
                               (Levels (Group * 128 + Index)
                                + Levels (Group * 128 + Index + 32) * 4
                                + Levels (Group * 128 + Index + 64) * 16
                                + Levels (Group * 128 + Index + 96) * 64);
                        end loop;
                     end loop;
                  end;

               when Q5_K =>
                  declare
                     --  Q4_K's search with a wider window and twice the
                     --  levels: sixteen candidates from a half below rather
                     --  than twenty-one from one below, and thirty-one
                     --  levels a run rather than fifteen. The fifth bit of
                     --  each level lives apart, two bits a byte across four
                     --  groups of sixty-four.
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
                           for Index in Element_Count range 0 .. 31 loop
                              Squared := Squared
                                + Values (At_Run + Index)
                                  * Values (At_Run + Index);
                           end loop;

                           declare
                              Middling : constant N.Real :=
                                N.Real (N.Sqrt
                                          (N.Wide_Real (Squared / 32.0)));
                           begin
                              for Index in Element_Count range 0 .. 31 loop
                                 Weights (Index) :=
                                   Middling + abs Values (At_Run + Index);
                              end loop;
                           end;

                           Fit_Run_And_Min
                             (Values (At_Run .. At_Run + 31), Weights, 31,
                              Here, Low, Fit,
                              From => -0.5, By => 0.1, Steps => 15);

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

                        declare
                           Held_D : constant N.Real :=
                             N.To_Real (N.To_Half (Widest_Scale / 63.0));
                           Held_M : constant N.Real :=
                             N.To_Real (N.To_Half (Widest_Least / 63.0));
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
                                                 (31,
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

                        --  Four bits a level in the nibbles, and the fifth
                        --  apart: two bits of each of the thirty-two bytes
                        --  of qh, one group of sixty-four at a time.
                        declare
                           Low_Bit  : Interfaces.Unsigned_8 := 1;
                           High_Bit : Interfaces.Unsigned_8 := 2;
                        begin
                           for Group in 0 .. Integer (Span) / 64 - 1 loop
                              for Index in 0 .. 31 loop
                                 declare
                                    A : Integer :=
                                      Levels (Group * 64 + Index);
                                    C : Integer :=
                                      Levels (Group * 64 + Index + 32);
                                    At_High : constant B.Byte_Count :=
                                      At_Byte + 16 + B.Byte_Count (Index);
                                 begin
                                    if A > 15 then
                                       A := A - 16;
                                       Result (At_High) :=
                                         B.Byte
                                           (Interfaces.Unsigned_8
                                              (Result (At_High)) or Low_Bit);
                                    end if;

                                    if C > 15 then
                                       C := C - 16;
                                       Result (At_High) :=
                                         B.Byte
                                           (Interfaces.Unsigned_8
                                              (Result (At_High))
                                            or High_Bit);
                                    end if;

                                    Result (At_Byte + 48
                                            + B.Byte_Count
                                                (Group * 32 + Index)) :=
                                      B.Byte (A + C * 16);
                                 end;
                              end loop;

                              Low_Bit := Interfaces.Shift_Left (Low_Bit, 2);
                              High_Bit := Interfaces.Shift_Left (High_Bit, 2);
                           end loop;
                        end;
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
                             (Values (At_Run .. At_Run + 15), 32, Here, Fit,
                              Weights =>
                                (if Told
                                 then Heft
                                        (Heft'First
                                         + ((At_Run - Values'First)
                                            mod Heft'Length)
                                         .. Heft'First
                                            + ((At_Run - Values'First)
                                               mod Heft'Length) + 15)
                                 else Values (At_Run .. At_Run + 15)),
                              Told => Told);
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
   end Encoded;

   ------------
   -- Encode --
   ------------

   function Encode (Values : Real_Array; Into : Target) return Byte_Array
   is (Encoded (Values, Values, False, Into));

   ---------------------
   -- Encode_Weighted --
   ---------------------

   function Encode_Weighted
     (Values  : Real_Array;
      Weights : Real_Array;
      Into    : Target) return Byte_Array
   is
      Span   : constant Element_Count := Block_Of (Into);
      Width  : constant B.Byte_Count := Bytes_Of (Into);
      Blocks : constant Element_Count := Values'Length / Span;

      Result : Byte_Array (0 .. B.Byte_Count (Blocks) * Width - 1) :=
        [others => 0];
   begin
      --  Q6_K's weighted path is its plain one with the matrix standing in
      --  for the value squared, so it goes through the same body. Q4_K's is
      --  a different search and has its own below. Everything else falls
      --  back to the plain encoding, which is what the reference does for a
      --  format whose weighted path it has not been given -- and which is
      --  now true of fewer formats than it was: a mixture spends its extra
      --  bits in Q6_K, so a file quantized with a matrix and a recipe had
      --  its most important twenty-one tensors quantized as though there
      --  were no matrix.
      if Into = Q6_K then
         return Encoded (Values, Weights, True, Into);
      end if;

      if Into /= Q4_K then
         return Encode (Values, Into);
      end if;

      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant Element_Count := Values'First + Block * Span;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * Width;

            Runs : constant Element_Count := Span / 32;

            Levels : Level_Run (0 .. Integer (Span) - 1) := [others => 0];

            Scales : Real_Array (0 .. Runs - 1) := [others => 0.0];
            Least  : Real_Array (0 .. Runs - 1) := [others => 0.0];

            --  What each run's weights add up to, which is what the fit of
            --  the scales below is itself weighted by: a run the corpus
            --  leaned on decides more of the super-block's scale.
            Heft : Real_Array (0 .. Runs - 1) := [others => 0.0];

            --  The whole super-block's spread, which the weighting is
            --  measured against rather than each run's own.
            Squared : N.Real := 0.0;
            Sigma2  : N.Real;
         begin
            for Index in Element_Count range 0 .. Span - 1 loop
               Squared := Squared
                 + Values (First + Index) * Values (First + Index);
            end loop;
            Sigma2 := 2.0 * Squared / N.Real (Span);

            for Run in 0 .. Runs - 1 loop
               declare
                  At_Run : constant Element_Count := First + Run * 32;

                  Here    : Level_Run (0 .. 31);
                  Mine    : Real_Array (0 .. 31);
                  Sum     : N.Real := 0.0;
                  Fit     : N.Real;
                  Low     : N.Real;
               begin
                  for Index in Element_Count range 0 .. 31 loop
                     Mine (Index) :=
                       --  The matrix is one row long and every row of the
                       --  matrix meets the same columns, so a position in
                       --  the whole tensor asks the matrix about its column
                       --  and not about itself.
                       Weights
                         (Weights'First
                          + (Block * Span + Run * 32 + Index)
                            mod Weights'Length)
                       * N.Real
                           (N.Sqrt
                              (N.Wide_Real
                                 (Sigma2
                                  + Values (At_Run + Index)
                                    * Values (At_Run + Index))));
                     Sum := Sum + Mine (Index);
                  end loop;

                  Heft (Run) := Sum;

                  Fit_Run_And_Min
                    (Values (At_Run .. At_Run + 31), Mine, 15, Here, Low, Fit,
                     From => -0.9, By => 0.05, Steps => 36, Weighed => True);

                  Scales (Run) := Fit;
                  Least (Run) := Low;

                  for Index in Here'Range loop
                     Levels (Integer (Run) * 32 + Index) := Here (Index);
                  end loop;
               end;
            end loop;

            declare
               Steps_S, Steps_M : Level_Run (0 .. Integer (Runs) - 1);
               Block_D, Block_M : N.Real;

               Packed : array (0 .. 11) of Interfaces.Unsigned_8 :=
                 [others => 0];
            begin
               Fit_Positives (Scales, Heft, 63, Steps_S, Block_D);
               Fit_Positives (Least, Heft, 63, Steps_M, Block_M);

               for Run in 0 .. Integer (Runs) - 1 loop
                  declare
                     Step_S : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8 (Steps_S (Run) mod 256);
                     Step_M : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8 (Steps_M (Run) mod 256);
                  begin
                     if Run < 4 then
                        Packed (Run) := Step_S;
                        Packed (Run + 4) := Step_M;
                     else
                        Packed (Run + 4) :=
                          (Step_S and 16#0F#)
                          or Interfaces.Shift_Left (Step_M and 16#0F#, 4);
                        Packed (Run - 4) := Packed (Run - 4)
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Step_S, 4), 6);
                        Packed (Run) := Packed (Run)
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Step_M, 4), 6);
                     end if;
                  end;
               end loop;

               Put_Half (Result, At_Byte, Block_D);
               Put_Half (Result, At_Byte + 2, Block_M);

               for Which in Packed'Range loop
                  Result (At_Byte + 4 + B.Byte_Count (Which)) :=
                    B.Byte (Packed (Which));
               end loop;

               declare
                  Held_D : constant N.Real :=
                    N.To_Real (N.To_Half (Block_D));
                  Held_M : constant N.Real :=
                    N.To_Real (N.To_Half (Block_M));
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
                             Interfaces.Shift_Right (Packed (Run + 4), 4)
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
                                                    (Run * 32 + Index))
                                             + Lift) / Apart)));
                              end loop;
                           end if;
                        end;
                     end;
                  end loop;
               end;

               for Pair in 0 .. Integer (Span) / 64 - 1 loop
                  for Index in 0 .. 31 loop
                     Result (At_Byte + 16
                             + B.Byte_Count (Pair * 32 + Index)) :=
                       B.Byte (Levels (Pair * 64 + Index)
                               + Levels (Pair * 64 + Index + 32) * 16);
                  end loop;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Weighted;

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
