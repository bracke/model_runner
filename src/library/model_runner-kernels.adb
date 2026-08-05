package body Model_Runner.Kernels is

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
      Frequency_Scale : Wide_Real := 1.0)
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
                  Even     : constant Element_Count := Origin + 2 * Pair;
                  Odd      : constant Element_Count := Even + 1;
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
