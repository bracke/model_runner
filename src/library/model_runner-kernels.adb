with Ada.Unchecked_Conversion;
with Interfaces;
with System;
with System.Machine_Code;

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
   -- Head_Dot --
   --------------

   --  Set once at a backend's elaboration and read thereafter.
   Wide_Lanes : Boolean := False;

   procedure Use_Wide_Lanes (Allowed : Boolean) is
   begin
      Wide_Lanes := Allowed;
   end Use_Wide_Lanes;

   function Head_Dot
     (Left     : Real_Array;
      At_Left  : Element_Count;
      Right    : Real_Array;
      At_Right : Element_Count;
      Span     : Element_Count) return Real is
   begin
      --  Written as sums rather than differences: Element_Count starts at
      --  zero and an empty vector's Last is below its First.
      if Span = 0
        or else At_Left < Left'First
        or else At_Right < Right'First
        or else At_Left - Left'First + Span > Element_Count (Left'Length)
        or else At_Right - Right'First + Span > Element_Count (Right'Length)
      then
         return 0.0;
      end if;

      --  Eight pairs a turn, accumulated in the eight lanes and folded once
      --  at the end. The addresses it advances are its own copies and not
      --  the caller's, which is the rule every insertion here keeps.
      if Wide_Lanes and then Span mod 8 = 0 then
         declare
            LF : constant Character := ASCII.LF;

            Left_At  : System.Address := Left (At_Left)'Address;
            Right_At : System.Address := Right (At_Right)'Address;
            Blocks   : Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Span / 8);
            Result   : N.Real;
         begin
            System.Machine_Code.Asm
              ("vxorps %%ymm0, %%ymm0, %%ymm0"           & LF
               & "1:"                                    & LF
               & "vmovups (%1), %%ymm1"                  & LF
               & "vmovups (%2), %%ymm2"                  & LF
               & "vfmadd231ps %%ymm1, %%ymm2, %%ymm0"    & LF
               & "addq $32, %1"                          & LF
               & "addq $32, %2"                          & LF
               & "decq %3"                               & LF
               & "jnz 1b"                                & LF

               --  Eight lanes down to one: the high half onto the low, then
               --  two pairwise adds.
               & "vextractf128 $1, %%ymm0, %%xmm1"       & LF
               & "vaddps %%xmm1, %%xmm0, %%xmm0"         & LF
               & "vhaddps %%xmm0, %%xmm0, %%xmm0"        & LF
               & "vhaddps %%xmm0, %%xmm0, %%xmm0"        & LF
               & "vmovss %%xmm0, %0"                     & LF
               & "vzeroupper",
               Outputs =>
                 [N.Real'Asm_Output ("=m", Result),
                  System.Address'Asm_Output ("+r", Left_At),
                  System.Address'Asm_Output ("+r", Right_At),
                  Interfaces.Unsigned_64'Asm_Output ("+r", Blocks)],
               Clobber  => "ymm0, ymm1, ymm2, cc, memory",
               Volatile => True);

            return Result;
         end;
      end if;

      declare
         Sum : N.Wide_Real := 0.0;
      begin
         for Index in 0 .. Span - 1 loop
            Sum := Sum
              + N.Wide_Real (Left (At_Left + Index))
                * N.Wide_Real (Right (At_Right + Index));
         end loop;

         return N.Real (Sum);
      end;
   end Head_Dot;

   ------------------
   -- Head_Scores --
   ------------------

   --  Sixty-four wide and eight keys a turn, which is what the insertion
   --  below is written for.
   Held_Span : constant Element_Count := 64;
   Held_Keys : constant Element_Count := 8;

   procedure Head_Scores
     (Query    : Real_Array;
      At_Query : Element_Count;
      Keys     : Real_Array;
      At_Key   : Element_Count;
      Stride   : Element_Count;
      Steps    : Element_Count;
      Span     : Element_Count;
      Scale    : Real;
      Scores   : in out Real_Array;
      At_Score : Element_Count)
   is
      Groups : Element_Count := 0;
      Done   : Element_Count := 0;
   begin
      if Steps = 0
        or else Span = 0
        or else At_Query < Query'First
        or else At_Key < Keys'First
        or else At_Score < Scores'First
        or else At_Query - Query'First + Span > Element_Count (Query'Length)
        or else Stride < Span
        or else At_Key - Keys'First + (Steps - 1) * Stride + Span
                  > Element_Count (Keys'Length)
        or else At_Score - Scores'First + Steps
                  > Element_Count (Scores'Length)
      then
         return;
      end if;

      if Wide_Lanes and then Span = Held_Span then
         Groups := Steps / Held_Keys;
      end if;

      if Groups > 0 then
         declare
            LF : constant Character := ASCII.LF;

            Key_At   : System.Address := Keys (At_Key)'Address;
            Left     : Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Groups);
            Query_At : constant System.Address := Query (At_Query)'Address;
            Out_At   : System.Address := Scores (At_Score)'Address;
            Apart    : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Stride * (N.Real'Size / 8));
            Times    : constant N.Real := Scale;
         begin
            System.Machine_Code.Asm
              (--  The whole query head, once for the run.
               "vmovups 0(%3), %%ymm8"            & LF
               & "vmovups 32(%3), %%ymm9"           & LF
               & "vmovups 64(%3), %%ymm10"           & LF
               & "vmovups 96(%3), %%ymm11"           & LF
               & "vmovups 128(%3), %%ymm12"          & LF
               & "vmovups 160(%3), %%ymm13"          & LF
               & "vmovups 192(%3), %%ymm14"          & LF
               & "vmovups 224(%3), %%ymm15"          & LF
               & "1:"                                    & LF
               & "vxorps %%ymm0, %%ymm0, %%ymm0"  & LF
               & "vxorps %%ymm1, %%ymm1, %%ymm1"  & LF
               & "vxorps %%ymm2, %%ymm2, %%ymm2"  & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3"  & LF
               & "vxorps %%ymm4, %%ymm4, %%ymm4"  & LF
               & "vxorps %%ymm5, %%ymm5, %%ymm5"  & LF
               & "vxorps %%ymm6, %%ymm6, %%ymm6"  & LF
               & "vxorps %%ymm7, %%ymm7, %%ymm7"  & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm0"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm0"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm0"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm0"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm0"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm0"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm0"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm0"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm1"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm1"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm1"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm1"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm1"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm1"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm1"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm1"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm2"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm2"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm2"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm2"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm2"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm2"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm2"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm2"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm3"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm3"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm3"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm3"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm3"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm3"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm3"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm3"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm4"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm4"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm4"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm4"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm4"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm4"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm4"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm4"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm5"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm5"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm5"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm5"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm5"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm5"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm5"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm5"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm6"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm6"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm6"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm6"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm6"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm6"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm6"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm6"  & LF
               & "addq %4, %1"                          & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm7"   & LF
               & "vfmadd231ps 32(%1), %%ymm9, %%ymm7"   & LF
               & "vfmadd231ps 64(%1), %%ymm10, %%ymm7"   & LF
               & "vfmadd231ps 96(%1), %%ymm11, %%ymm7"   & LF
               & "vfmadd231ps 128(%1), %%ymm12, %%ymm7"  & LF
               & "vfmadd231ps 160(%1), %%ymm13, %%ymm7"  & LF
               & "vfmadd231ps 192(%1), %%ymm14, %%ymm7"  & LF
               & "vfmadd231ps 224(%1), %%ymm15, %%ymm7"  & LF
               & "addq %4, %1"                          & LF
               --  Eight accumulators folded together: pairs within each
               --  half, then pairs of those, then the two halves added.
               --  Twelve instructions where eight separate folds are
               --  forty-eight, and two dependent chains where there are
               --  eight.
               & "vhaddps %%ymm1, %%ymm0, %%ymm0"        & LF
               & "vhaddps %%ymm3, %%ymm2, %%ymm2"        & LF
               & "vhaddps %%ymm5, %%ymm4, %%ymm4"        & LF
               & "vhaddps %%ymm7, %%ymm6, %%ymm6"        & LF
               & "vhaddps %%ymm2, %%ymm0, %%ymm0"        & LF
               & "vhaddps %%ymm6, %%ymm4, %%ymm4"        & LF
               & "vextractf128 $1, %%ymm0, %%xmm1"       & LF
               & "vaddps %%xmm1, %%xmm0, %%xmm0"         & LF
               & "vextractf128 $1, %%ymm4, %%xmm5"       & LF
               & "vaddps %%xmm5, %%xmm4, %%xmm4"         & LF
               & "vbroadcastss %5, %%xmm6"               & LF
               & "vmulps %%xmm6, %%xmm0, %%xmm0"         & LF
               & "vmulps %%xmm6, %%xmm4, %%xmm4"         & LF
               & "vmovups %%xmm0, (%2)"                  & LF
               & "vmovups %%xmm4, 16(%2)"                & LF
               & "addq $32, %2"                          & LF
               & "decq %0"                               & LF
               & "jnz 1b"                                & LF
               & "vzeroupper",
               Outputs =>
                 [Interfaces.Unsigned_64'Asm_Output ("+r", Left),
                  System.Address'Asm_Output ("+r", Key_At),
                  System.Address'Asm_Output ("+r", Out_At)],
               Inputs   =>
                 [System.Address'Asm_Input ("r", Query_At),
                  Interfaces.Unsigned_64'Asm_Input ("r", Apart),
                  N.Real'Asm_Input ("m", Times)],
               Clobber  =>
                 "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
                 & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
                 & "cc, memory",
               Volatile => True);
         end;

         Done := Groups * Held_Keys;
      end if;

      --  Whatever the groups did not cover, a score at a time.
      for Step in Done .. Steps - 1 loop
         Scores (At_Score + Step) :=
           Head_Dot (Query, At_Query, Keys, At_Key + Step * Stride, Span)
           * Scale;
      end loop;
   end Head_Scores;

   ---------------
   -- Blend_Run --
   ---------------

   --  Sixty-four components, which is eight registers of eight lanes. A
   --  run of another width goes to the loop below, which is what every
   --  host without the instructions runs anyway.
   Held_Run : constant Element_Count := 64;

   procedure Blend_Run
     (Sums      : in out Real_Array;
      Weights   : Real_Array;
      At_Weight : Element_Count;
      Values    : Real_Array;
      At_Value  : Element_Count;
      Stride    : Element_Count;
      Steps     : Element_Count)
   is
      Span : constant Element_Count := Element_Count (Sums'Length);
   begin
      --  Written as sums rather than differences: Element_Count starts at
      --  zero and an empty vector's Last is below its First.
      if Steps = 0
        or else Span = 0
        or else At_Weight < Weights'First
        or else At_Value < Values'First
        or else At_Weight - Weights'First + Steps
                  > Element_Count (Weights'Length)
        or else Stride < Span
        or else At_Value - Values'First + (Steps - 1) * Stride + Span
                  > Element_Count (Values'Length)
      then
         return;
      end if;

      if Wide_Lanes and then Span = Held_Run then
         declare
            LF : constant Character := ASCII.LF;

            Sums_At   : constant System.Address := Sums (Sums'First)'Address;
            Weight_At : System.Address := Weights (At_Weight)'Address;
            Value_At  : System.Address := Values (At_Value)'Address;
            Left      : Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Steps);
            Apart     : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Stride * (N.Real'Size / 8));
         begin
            System.Machine_Code.Asm
              ("vmovups 0(%3), %%ymm0"                   & LF
               & "vmovups 32(%3), %%ymm1"                & LF
               & "vmovups 64(%3), %%ymm2"                & LF
               & "vmovups 96(%3), %%ymm3"                & LF
               & "vmovups 128(%3), %%ymm4"               & LF
               & "vmovups 160(%3), %%ymm5"               & LF
               & "vmovups 192(%3), %%ymm6"               & LF
               & "vmovups 224(%3), %%ymm7"               & LF

               --  One position a turn: its score into all eight lanes,
               --  then eight fused multiply-adds reading its values where
               --  they lie.
               & "1:"                                    & LF
               & "vbroadcastss (%0), %%ymm8"             & LF
               & "vfmadd231ps 0(%1), %%ymm8, %%ymm0"     & LF
               & "vfmadd231ps 32(%1), %%ymm8, %%ymm1"    & LF
               & "vfmadd231ps 64(%1), %%ymm8, %%ymm2"    & LF
               & "vfmadd231ps 96(%1), %%ymm8, %%ymm3"    & LF
               & "vfmadd231ps 128(%1), %%ymm8, %%ymm4"   & LF
               & "vfmadd231ps 160(%1), %%ymm8, %%ymm5"   & LF
               & "vfmadd231ps 192(%1), %%ymm8, %%ymm6"   & LF
               & "vfmadd231ps 224(%1), %%ymm8, %%ymm7"   & LF
               & "addq $4, %0"                           & LF
               & "addq %4, %1"                           & LF
               & "decq %2"                               & LF
               & "jnz 1b"                                & LF

               & "vmovups %%ymm0, 0(%3)"                 & LF
               & "vmovups %%ymm1, 32(%3)"                & LF
               & "vmovups %%ymm2, 64(%3)"                & LF
               & "vmovups %%ymm3, 96(%3)"                & LF
               & "vmovups %%ymm4, 128(%3)"               & LF
               & "vmovups %%ymm5, 160(%3)"               & LF
               & "vmovups %%ymm6, 192(%3)"               & LF
               & "vmovups %%ymm7, 224(%3)"               & LF
               & "vzeroupper",
               Outputs =>
                 [System.Address'Asm_Output ("+r", Weight_At),
                  System.Address'Asm_Output ("+r", Value_At),
                  Interfaces.Unsigned_64'Asm_Output ("+r", Left)],
               Inputs   =>
                 [System.Address'Asm_Input ("r", Sums_At),
                  Interfaces.Unsigned_64'Asm_Input ("r", Apart)],
               Clobber  =>
                 "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, ymm8, "
                 & "cc, memory",
               Volatile => True);

            return;
         end;
      end if;

      for Step in 0 .. Steps - 1 loop
         declare
            Weight : constant N.Real := Weights (At_Weight + Step);
            Here   : constant Element_Count := At_Value + Step * Stride;
         begin
            for Component in 0 .. Span - 1 loop
               Sums (Sums'First + Component) :=
                 Sums (Sums'First + Component)
                 + Weight * Values (Here + Component);
            end loop;
         end;
      end loop;
   end Blend_Run;

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

   --------------------
   -- Exponentiate --
   --------------------

   --  Two raised to a fraction in [-0.5, 0.5], to about the last bit
   --  binary32 keeps, with the whole part built as an exponent field.
   --
   --  Shared by Exponentiate and SiLU rather than written twice, and inline
   --  so that the loops around it stay one basic block and keep vectorizing:
   --  a call in either would put them back on one lane, which is the whole
   --  point of not calling the library's.
   --
   --  Clamped at both ends. Past eighty-seven either way the result is
   --  outside what binary32 holds, and the exponent this builds would wrap
   --  rather than saturate -- which for the softmax means a score far
   --  behind the leader coming back ahead of it, and for SiLU a large
   --  negative input coming back large instead of at zero.
   function Raised (X : N.Real) return N.Real with Inline;

   function Raised (X : N.Real) return N.Real is
      use type Interfaces.Unsigned_32;

      --  Neither check can fire and both stop the loops around this
      --  vectorizing: the clamp bounds what the exponent is built from,
      --  and an overflow check is a branch and a call.
      pragma Suppress (Overflow_Check);
      pragma Suppress (Range_Check);

      function To_Real is
        new Ada.Unchecked_Conversion (Interfaces.Unsigned_32, N.Real);

      Log2_E : constant N.Real := 1.44269504088896;
      Edge   : constant N.Real := 87.0;
      Magic  : constant N.Real := 12_582_912.0;

      C1 : constant N.Real := 0.693147180559945;
      C2 : constant N.Real := 0.240226506959101;
      C3 : constant N.Real := 0.055504108664822;
      C4 : constant N.Real := 0.009618129107629;
      C5 : constant N.Real := 0.001333355814643;

      Held  : constant N.Real :=
        N.Real'Min (N.Real'Max (X, -Edge), Edge) * Log2_E;
      Whole : constant N.Real := (Held + Magic) - Magic;
      F     : constant N.Real := Held - Whole;

      P : constant N.Real :=
        1.0 + F * (C1 + F * (C2 + F * (C3 + F * (C4 + F * C5))));

      Bits : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left
          (Interfaces.Unsigned_32 (Integer (Whole) + 127), 23);
   begin
      return P * To_Real (Bits);
   end Raised;

   --  The largest value of a run and whether every one of them is finite,
   --  in one pass over eight lanes.
   --
   --  What this replaces was a scalar loop and stayed one: the finiteness
   --  test is an integer test of the exponent field, and a compiler that
   --  sees a float array turned into bits one element at a time will not
   --  make eight lanes of it. Written out, both questions are lane work --
   --  a maximum, and an ordered compare of the magnitude against infinity
   --  whose mask is accumulated. A value that is not finite fails that
   --  compare whether it is infinite or a NaN, which is the whole of the
   --  test the caller wanted.
   procedure Largest_Finite
     (Target  : Real_Array;
      Largest : out Real;
      Finite  : out Boolean)
   is
      Count : constant Element_Count := Element_Count (Target'Length);
      Whole : constant Element_Count := (Count / 8) * 8;
      Index : Element_Count := 0;
   begin
      Largest := Target (Target'First);
      Finite  := True;

      if Wide_Lanes and then Whole > 0 then
         declare
            LF : constant Character := ASCII.LF;

            At_Value : System.Address := Target (Target'First)'Address;
            Blocks   : Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Whole / 8);
            Top      : N.Real;
            Flags    : Interfaces.Unsigned_32;
         begin
            System.Machine_Code.Asm
              ("movl $0x7fffffff, %%eax"                  & LF
               & "vmovd %%eax, %%xmm3"                    & LF
               & "vbroadcastss %%xmm3, %%ymm3"            & LF
               & "movl $0x7f800000, %%eax"                & LF
               & "vmovd %%eax, %%xmm4"                    & LF
               & "vbroadcastss %%xmm4, %%ymm4"            & LF
               & "vpcmpeqd %%ymm5, %%ymm5, %%ymm5"        & LF
               & "vbroadcastss (%2), %%ymm0"              & LF
               & "1:"                                     & LF
               & "vmovups (%2), %%ymm1"                   & LF
               & "vmaxps %%ymm1, %%ymm0, %%ymm0"          & LF
               & "vandps %%ymm3, %%ymm1, %%ymm2"          & LF
               & "vcmpltps %%ymm4, %%ymm2, %%ymm2"        & LF
               & "vandps %%ymm2, %%ymm5, %%ymm5"          & LF
               & "addq $32, %2"                           & LF
               & "decq %3"                                & LF
               & "jnz 1b"                                 & LF

               --  Eight lanes down to one, by halves.
               & "vextractf128 $1, %%ymm0, %%xmm1"        & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vmovhlps %%xmm0, %%xmm0, %%xmm1"        & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vshufps $1, %%xmm0, %%xmm0, %%xmm1"     & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vmovss %%xmm0, %0"                      & LF

               --  One bit a lane, and all eight set is all eight finite.
               & "vmovmskps %%ymm5, %%eax"                & LF
               & "movl %%eax, %1"                         & LF
               & "vzeroupper",
               Outputs =>
                 [N.Real'Asm_Output ("=m", Top),
                  Interfaces.Unsigned_32'Asm_Output ("=m", Flags),
                  System.Address'Asm_Output ("+r", At_Value),
                  Interfaces.Unsigned_64'Asm_Output ("+r", Blocks)],
               Clobber  =>
                 "rax, ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, cc, memory",
               Volatile => True);

            Largest := Top;
            Finite  := Interfaces."=" (Flags, 255);
            Index   := Whole;
         end;
      end if;

      while Index < Count loop
         declare
            Value : constant Real := Target (Target'First + Index);
         begin
            if not N.Is_Finite (Value) then
               Finite := False;
            elsif Value > Largest then
               Largest := Value;
            end if;
         end;

         Index := Index + 1;
      end loop;
   end Largest_Finite;

   procedure Exponentiate (Target : in out Real_Array; Less : Real) is
      --  Neither check can fire here and both stop the loop vectorizing:
      --  the exponent is built from a value Raised bounds, and the index
      --  walks the array it was given.
      pragma Suppress (Overflow_Check);
      pragma Suppress (Range_Check);
   begin
      for Index in Target'Range loop
         Target (Index) := Raised (Target (Index) - Less);
      end loop;
   end Exponentiate;

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

      declare
         Finite : Boolean;
      begin
         Largest_Finite (Target, Largest, Finite);

         if not Finite then
            return;
         end if;
      end;

      --  The exponentials as a map, then the total as a pass of its own.
      --  Written apart because they are different shapes: the first
      --  vectorizes and the second is a reduction, and leaving them
      --  together left the whole of it on one lane.
      Exponentiate (Target, Largest);

      --  Four running totals rather than one. Binary64 addition is not
      --  associative and the compiler will not split a reduction chain
      --  itself, so every add waited on the one before it -- four cycles
      --  each down the whole run of scores. Four independent chains cost
      --  the same instructions and wait for none of them, and the four are
      --  put back together in a fixed order so the answer is a function of
      --  the input and not of the length.
      declare
         pragma Suppress (Index_Check);
         pragma Suppress (Range_Check);

         Parts : array (0 .. 3) of Wide_Real := [others => 0.0];
         Index : N.Element_Index := Target'First;
      begin
         while Index + 3 <= Target'Last loop
            Parts (0) := Parts (0) + Wide_Real (Target (Index));
            Parts (1) := Parts (1) + Wide_Real (Target (Index + 1));
            Parts (2) := Parts (2) + Wide_Real (Target (Index + 2));
            Parts (3) := Parts (3) + Wide_Real (Target (Index + 3));
            Index := Index + 4;
         end loop;

         while Index <= Target'Last loop
            Parts (0) := Parts (0) + Wide_Real (Target (Index));
            Index := Index + 1;
         end loop;

         Sum := (Parts (0) + Parts (1)) + (Parts (2) + Parts (3));
      end;

      if Sum <= 0.0 or else not N.Is_Finite (Sum) then
         return;
      end if;

      --  One reciprocal, taken in the wide format and rounded once, then a
      --  narrow multiply for every score. What this replaces converted each
      --  score up, divided in binary64 and converted back down -- four
      --  values a turn on a machine this file is compiled baseline for, and
      --  a divide is not a multiply. The scores move by a rounding of the
      --  reciprocal and the sweep is what says that is close enough.
      declare
         Over : constant Real := Real (1.0 / Sum);
      begin
         for Index in Target'Range loop
            Target (Index) := Target (Index) * Over;
         end loop;
      end;

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
      --  As in Exponentiate, and for the same reason.
      pragma Suppress (Overflow_Check);
      pragma Suppress (Range_Check);
   begin
      --  In binary32 through the exponential above rather than in binary64
      --  through the library's.
      --
      --  This one is worth more than its share of a profile suggests. The
      --  gate's activation runs on the calling task while the workers wait,
      --  so what it costs is paid once on the clock rather than divided
      --  among eight: it is about two per cent of a prompt's samples and
      --  eleven per cent of a prompt's seconds.
      for Index in Target'Range loop
         declare
            Value : constant Real := Target (Index);
         begin
            Target (Index) := Value / (1.0 + Raised (-Value));
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
