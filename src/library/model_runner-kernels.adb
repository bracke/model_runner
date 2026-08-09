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
      Target  : out Real_Array)
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

      for Index in 0 .. Element_Count (Source'Length) - 1 loop
         Target (Target'First + Index) :=
           Real (Wide_Real (Source (Source'First + Index)) * Gain)
           * Weight (Weight'First + Index);
      end loop;
   end RMS_Norm;

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
      Frequency_Scale : Wide_Real := 1.0;
      Pairing         : Rotary_Pairing := Interleaved)
   is
      Effective : constant Wide_Real :=
        Wide_Real (Position) * Frequency_Scale;
   begin
      if Heads = 0 or else Head_Size = 0 or else Rotary = 0
        or else Rotary > Head_Size
        or else Rotary mod 2 /= 0
        or else Vector'Length /= Heads * Head_Size
        or else Base <= 0.0
      then
         return;
      end if;

      for Head in 0 .. Heads - 1 loop
         declare
            Origin : constant Element_Count :=
              Vector'First + Head * Head_Size;
         begin
            for Pair in 0 .. Rotary / 2 - 1 loop
               declare
                  Exponent : constant Wide_Real :=
                    -2.0 * Wide_Real (Pair) / Wide_Real (Rotary);
                  Theta    : constant Wide_Real :=
                    Effective * N.Power (Base, Exponent);
                  Cosine   : constant Wide_Real := N.Cos (Theta);
                  Sine     : constant Wide_Real := N.Sin (Theta);
                  Even     : constant Element_Count :=
                    (if Pairing = Interleaved
                     then Origin + 2 * Pair
                     else Origin + Pair);
                  Odd      : constant Element_Count :=
                    (if Pairing = Interleaved
                     then Even + 1
                     else Even + Rotary / 2);
                  First    : constant Wide_Real := Wide_Real (Vector (Even));
                  Second   : constant Wide_Real := Wide_Real (Vector (Odd));
               begin
                  Vector (Even) := Real (First * Cosine - Second * Sine);
                  Vector (Odd) := Real (First * Sine + Second * Cosine);
               end;
            end loop;
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
