package body Model_Runner.Kernels is

   --  Every value here derives from weights a model file supplied, so a
   --  not-a-number or an infinity is possible input, and this package guards
   --  against it explicitly: RMS_Norm rejects a non-finite gain, Softmax a
   --  non-finite term or total, and All_Finite exists for callers to ask.
   --  Validity checking raises when such a value is read, which is before any
   --  of those guards can run, so it would replace each diagnostic with an
   --  exception. Bounds and range checking are untouched.
   pragma Suppress (Validity_Check);

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;

   package N renames Model_Runner.Numerics;

   --  Written out rather than taken from Ada.Numerics, which declares it in
   --  a fixed precision this package does not otherwise depend on.
   Pi : constant N.Wide_Real := 3.14159_26535_89793_23846;

   ---------
   -- Add --
   ---------

   procedure Add (Target : in out Real_Array; Addend : Real_Array) is
   begin
      if Target'Length /= Addend'Length then
         return;
      end if;

      for Index in 0 .. Element_Count (Target'Length) - 1 loop
         Target (Target'First + Index) :=
           Target (Target'First + Index) + Addend (Addend'First + Index);
      end loop;
   end Add;

   --------------
   -- Multiply --
   --------------

   procedure Multiply (Target : in out Real_Array; Factor : Real_Array) is
   begin
      if Target'Length /= Factor'Length then
         return;
      end if;

      for Index in 0 .. Element_Count (Target'Length) - 1 loop
         Target (Target'First + Index) :=
           Target (Target'First + Index) * Factor (Factor'First + Index);
      end loop;
   end Multiply;

   -----------
   -- Scale --
   -----------

   procedure Scale (Target : in out Real_Array; Factor : Real) is
   begin
      for Index in Target'Range loop
         Target (Index) := Target (Index) * Factor;
      end loop;
   end Scale;

   ---------
   -- Dot --
   ---------

   function Dot (Left, Right : Real_Array) return Real is
      Sum : Wide_Real := 0.0;
   begin
      if Left'Length /= Right'Length then
         return 0.0;
      end if;

      for Index in 0 .. Element_Count (Left'Length) - 1 loop
         Sum := Sum
           + Wide_Real (Left (Left'First + Index))
             * Wide_Real (Right (Right'First + Index));
      end loop;

      return Real (Sum);
   end Dot;

   --------------
   -- RMS_Norm --
   --------------

   procedure RMS_Norm
     (Source  : Real_Array;
      Weight  : Real_Array;
      Epsilon : Real;
      Target  : out Real_Array;
      Lifted  : Boolean := False)
   is
      Sum   : Wide_Real := 0.0;
      Gain  : Wide_Real;
   begin
      Target := [others => 0.0];

      if Source'Length /= Weight'Length
        or else Source'Length /= Target'Length
        or else Source'Length = 0
      then
         return;
      end if;

      for Index in 0 .. Element_Count (Source'Length) - 1 loop
         declare
            Value : constant Wide_Real :=
              Wide_Real (Source (Source'First + Index));
         begin
            Sum := Sum + Value * Value;
         end;
      end loop;

      Gain := N.Sqrt (Sum / Wide_Real (Source'Length) + Wide_Real (Epsilon));

      --  A zero or non-finite scale means the input was degenerate. Falling
      --  back to a unit gain keeps the layer's output finite so that the
      --  caller's own finiteness check reports the condition rather than the
      --  arithmetic trapping here.
      if Gain = 0.0 or else not N.Is_Finite (Gain) then
         Gain := 1.0;
      else
         Gain := 1.0 / Gain;
      end if;

      --  Two loops rather than one with a test in it: the test is the same
      --  every element, and this one is read once per token per layer.
      if Lifted then
         for Index in 0 .. Element_Count (Source'Length) - 1 loop
            Target (Target'First + Index) :=
              Real (Wide_Real (Source (Source'First + Index)) * Gain)
              * (1.0 + Weight (Weight'First + Index));
         end loop;
      else
         for Index in 0 .. Element_Count (Source'Length) - 1 loop
            Target (Target'First + Index) :=
              Real (Wide_Real (Source (Source'First + Index)) * Gain)
              * Weight (Weight'First + Index);
         end loop;
      end if;
   end RMS_Norm;

   -----------------
   -- Layer_Norm --
   -----------------

   procedure Layer_Norm
     (Source  : Real_Array;
      Weight  : Real_Array;
      Bias    : Real_Array;
      Epsilon : Real;
      Target  : out Real_Array)
   is
      Count : constant Element_Count := Element_Count (Source'Length);
      Mean  : Wide_Real := 0.0;
      Spread : Wide_Real := 0.0;
   begin
      Target := [others => 0.0];

      if Weight'Length /= Source'Length
        or else Bias'Length /= Source'Length
        or else Target'Length /= Source'Length
        or else Count = 0
      then
         return;
      end if;

      for Value of Source loop
         Mean := Mean + Wide_Real (Value);
      end loop;
      Mean := Mean / Wide_Real (Count);

      for Value of Source loop
         declare
            Off : constant Wide_Real := Wide_Real (Value) - Mean;
         begin
            Spread := Spread + Off * Off;
         end;
      end loop;
      Spread := Spread / Wide_Real (Count) + Wide_Real (Epsilon);

      --  A vector with no spread at all has nothing to divide by. The same
      --  answer the root-mean-square form gives in that case: leave the
      --  scale at one rather than divide by zero, and let the caller's
      --  finiteness check speak if the input was already wrong.
      declare
         Scale : constant Wide_Real :=
           (if Spread > 0.0 and then N.Is_Finite (Spread)
            then 1.0 / N.Sqrt (Spread) else 1.0);
      begin
         for Index in 0 .. Count - 1 loop
            Target (Target'First + Index) :=
              Real ((Wide_Real (Source (Source'First + Index)) - Mean)
                    * Scale
                    * Wide_Real (Weight (Weight'First + Index)))
              + Bias (Bias'First + Index);
         end loop;
      end;
   end Layer_Norm;

   -------------
   -- Softmax --
   -------------

   procedure Softmax (Target : in out Real_Array; Ok : out Boolean) is
      Largest : Real;
      Sum     : Wide_Real := 0.0;
   begin
      Ok := False;

      if Target'Length = 0 then
         return;
      end if;

      Largest := Target (Target'First);
      for Value of Target loop
         if not N.Is_Finite (Value) then
            return;
         end if;
         if Value > Largest then
            Largest := Value;
         end if;
      end loop;

      for Index in Target'Range loop
         declare
            Weighted : constant Wide_Real :=
              N.Exp (Wide_Real (Target (Index)) - Wide_Real (Largest));
         begin
            Target (Index) := Real (Weighted);
            Sum := Sum + Weighted;
         end;
      end loop;

      if Sum <= 0.0 or else not N.Is_Finite (Sum) then
         return;
      end if;

      for Index in Target'Range loop
         Target (Index) := Real (Wide_Real (Target (Index)) / Sum);
      end loop;

      Ok := True;
   end Softmax;

   ----------
   -- SiLU --
   ----------

   --  Both of these spend nearly all their time in Exp, and replacing it with
   --  arithmetic was tried and measured slower. A branchless series in
   --  binary64 -- the usual one, a power of two from the exponent field times
   --  a polynomial in what is left -- cost softmax about ten per cent and the
   --  activation about ten, and the same in binary32, which halves the work
   --  and doubles the lanes, still lost.
   --
   --  The reason is that the call is not what it looks like. The mathematics
   --  library resolves Exp at load time to an implementation chosen for the
   --  processor it finds, so on this machine it runs an AVX2 one, while this
   --  crate is compiled for baseline x86-64 and cannot emit those
   --  instructions -- and compiling it for the host measured slower
   --  everywhere else, which is in the README. A call into hand-written wide
   --  code beats inline narrow code, even counting the call.
   --
   --  So the cost stands, and it is the largest one left in these kernels:
   --  five nanoseconds an element against half a nanosecond for a quantized
   --  row product. Anyone attacking it again needs either wider instructions
   --  than the build allows or an approximation loose enough to change what
   --  models say, and the second is a decision rather than an optimization.
   procedure SiLU (Target : in out Real_Array) is
   begin
      for Index in Target'Range loop
         declare
            Value : constant Wide_Real := Wide_Real (Target (Index));
         begin
            Target (Index) := Real (Value / (1.0 + N.Exp (-Value)));
         end;
      end loop;
   end SiLU;

   ----------
   -- GELU --
   ----------

   procedure GELU (Target : in out Real_Array) is
      --  Square root of two over pi, and the cubic term's weight. Both are
      --  the constants of the approximation rather than anything derived,
      --  and are written out so that a reader can compare them with the
      --  paper rather than with a computation.
      Root : constant Wide_Real := 0.797_884_560_802_865_4;
      Bend : constant Wide_Real := 0.044_715;
   begin
      for Index in Target'Range loop
         declare
            Value : constant Wide_Real := Wide_Real (Target (Index));
            Inner : constant Wide_Real :=
              Root * (Value + Bend * Value * Value * Value);
         begin
            Target (Index) :=
              Real (0.5 * Value * (1.0 + N.Tanh (Inner)));
         end;
      end loop;

   end GELU;

   -------------------
   -- Apply_Rotary --
   -------------------

   procedure Apply_Rotary
     (Vector          : in out Real_Array;
      Heads           : Element_Count;
      Head_Size       : Element_Count;
      Rotary          : Element_Count;
      Position        : Natural;
      Base            : Wide_Real;
      Scaling         : Rotary_Scaling := No_Scaling;
      Factors         : Real_Array := No_Factors;
      Pairing         : Rotary_Pairing := Interleaved;
      Backwards       : Boolean := False)
   is
      --  A pair's frequency divisor, when the model carries one. A table of
      --  the wrong length is not used at all: applying the part that fits
      --  would rotate some dimensions by a model's numbers and the rest by
      --  nobody's.
      Divided : constant Boolean := Factors'Length = Rotary / 2;

      --  The band of dimensions Yarn ramps across, in pairs.
      --
      --  A dimension makes Original / (2 pi b ** (2 i / D)) turns over the
      --  context the model was trained on. Solving that for the dimension
      --  that makes a given number of turns is what names the two edges of
      --  the band, and everything between them is mixed rather than either
      --  extrapolated or interpolated.
      function Edge (Turns : Wide_Real) return Wide_Real is
        (Wide_Real (Rotary)
         * N.Log (Wide_Real (Scaling.Original)
                  / (Turns * 2.0 * Pi))
         / (2.0 * N.Log (Base)));

      Ramped : constant Boolean :=
        Scaling.Kind = Yarn
        and then Scaling.Original > 0
        and then Scaling.Frequency > 0.0
        and then Base > 1.0;

      Low  : Wide_Real := 0.0;
      High : Wide_Real := 0.0;

      --  What Yarn multiplies the rotated vector by. Interpolating the
      --  angles brings the dot products they produce closer together, and
      --  this is the correction the method states for that; a file may scale
      --  it further, which is what Attenuation is.
      Magnitude : Wide_Real := 1.0;

      --  How many pairs there are, how many of them are tabulated at once,
      --  and where the run being tabulated begins.
      Pairs   : constant Element_Count := Rotary / 2;
      Run     : constant Element_Count := 128;
      At_Pair : Element_Count := 0;
   begin
      if Heads = 0 or else Head_Size = 0 or else Rotary = 0
        or else Rotary > Head_Size
        or else Rotary mod 2 /= 0
        or else Vector'Length /= Heads * Head_Size
        or else Base <= 0.0
      then
         return;
      end if;

      if Ramped then
         Low := Wide_Real'Max (0.0, Wide_Real'Floor (Edge (Scaling.Beta_Fast)));
         High := Wide_Real'Min
           (Wide_Real (Rotary / 2 - 1),
            Wide_Real'Ceiling (Edge (Scaling.Beta_Slow)));
         Magnitude :=
           Scaling.Attenuation
           * (1.0 + 0.1 * N.Log (1.0 / Scaling.Frequency));
      else
         Magnitude := 1.0;
      end if;

      --  The angles first, then every head against them.
      --
      --  An angle depends on the pair and the position and on nothing else,
      --  so a head loop outside a pair loop computed the whole table once
      --  for each head: a power, a cosine and a sine per pair per head,
      --  where a power, a cosine and a sine per pair is all there is to
      --  know. On a model with thirty-two heads that is thirty-two times
      --  the transcendental calls the rotation needs, and they are the most
      --  expensive arithmetic in this package.
      --
      --  Bit for bit what it replaces. The same angle is computed by the
      --  same expression and kept in the same format -- rounding the table
      --  to Real would round twice where the rotation below rounds once,
      --  and move every rotated vector off the bits every other path
      --  produces. A pair touches two elements of one head and no other
      --  pair or head touches them, so the order the two loops run in is
      --  not part of the answer.
      --
      --  A run of pairs at a time because the table is on the stack and a
      --  head's width is a model's to choose.
      while At_Pair < Pairs loop
         declare
            Here    : constant Element_Count :=
              Element_Count'Min (Run, Pairs - At_Pair);
            Cosines : N.Wide_Real_Array (0 .. Here - 1);
            Sines   : N.Wide_Real_Array (0 .. Here - 1);
         begin
            for Index in 0 .. Here - 1 loop
               declare
                  Pair : constant Element_Count := At_Pair + Index;

                  Exponent : constant Wide_Real :=
                    -2.0 * Wide_Real (Pair) / Wide_Real (Rotary);

                  --  The angle as trained, and the angle the model's factor
                  --  stretches it to. Unscaled and linear are the same
                  --  arithmetic with a frequency of one and of the factor.
                  Extended : constant Wide_Real :=
                    (if Divided
                     then Wide_Real (Position) * N.Power (Base, Exponent)
                          / Wide_Real (Factors (Factors'First + Pair))
                     else Wide_Real (Position) * N.Power (Base, Exponent));
                  Between  : constant Wide_Real :=
                    Scaling.Frequency * Extended;

                  --  Where this pair sits in the ramped band: one at the
                  --  fast edge, where the angle is left as trained, and zero
                  --  at the slow edge, where it is fully stretched.
                  Mix : constant Wide_Real :=
                    (if not Ramped
                     then 0.0
                     else Wide_Real'Max
                            (0.0,
                             Wide_Real'Min
                               (1.0,
                                1.0
                                - (Wide_Real (Pair) - Low)
                                  / Wide_Real'Max (0.001, High - Low))));

                  Theta    : constant Wide_Real :=
                    Between * (1.0 - Mix) + Extended * Mix;
                  --  Turning back is the angle negated and the magnitude
                  --  left alone. A stretch that attenuates applies its
                  --  factor when a vector is rotated; a vector being moved
                  --  has been rotated once already and carries it, so
                  --  applying it again -- or dividing it out -- would leave
                  --  a vector no position would have produced. Both were
                  --  tried and both were caught by asking the kernel whether
                  --  turning back by N equals rotating N earlier, which is
                  --  the identity a shifted context rests on.
               begin
                  Cosines (Index) :=
                    (if Backwards then N.Cos (Theta)
                     else N.Cos (Theta) * Magnitude);
                  Sines (Index) :=
                    (if Backwards then -N.Sin (Theta)
                     else N.Sin (Theta) * Magnitude);
               end;
            end loop;

            for Head in 0 .. Heads - 1 loop
               declare
                  Origin : constant Element_Count :=
                    Vector'First + Head * Head_Size;
               begin
                  for Index in 0 .. Here - 1 loop
                     declare
                        Pair   : constant Element_Count := At_Pair + Index;
                        Even   : constant Element_Count :=
                          (if Pairing = Interleaved
                           then Origin + 2 * Pair
                           else Origin + Pair);
                        Odd    : constant Element_Count :=
                          (if Pairing = Interleaved
                           then Even + 1
                           else Even + Pairs);
                        First  : constant Wide_Real :=
                          Wide_Real (Vector (Even));
                        Second : constant Wide_Real :=
                          Wide_Real (Vector (Odd));
                     begin
                        Vector (Even) :=
                          Real (First * Cosines (Index)
                                - Second * Sines (Index));
                        Vector (Odd) :=
                          Real (First * Sines (Index)
                                + Second * Cosines (Index));
                     end;
                  end loop;
               end;
            end loop;

            At_Pair := At_Pair + Here;
         end;
      end loop;
   end Apply_Rotary;

   -----------------
   -- All_Finite --
   -----------------

   function All_Finite (Item : Real_Array) return Boolean is
   begin
      for Value of Item loop
         if not N.Is_Finite (Value) then
            return False;
         end if;
      end loop;
      return True;
   end All_Finite;

end Model_Runner.Kernels;
