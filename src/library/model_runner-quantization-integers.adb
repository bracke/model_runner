with System;
with System.Machine_Code;

with Model_Runner.Quantization.Integers.Deep;
with Model_Runner.Quantization.Integers.Plain;
with Model_Runner.Quantization.Integers.Wide;

package body Model_Runner.Quantization.Integers is

   --  Whether the wider compilation may be entered. Written by one task
   --  before the workers exist and read by all of them after, which is the
   --  protocol Model_Runner.Quantization states for its own such flag.
   Wider : Boolean := False;

   --  And whether the deepest one may be, which is a narrower promise: it
   --  needs the byte dot product and the whole of the instruction set that
   --  carries it.
   Deeper : Boolean := False;

   ---------------------
   -- Use_Wide_Rows --
   ---------------------

   procedure Use_Wide_Rows (Allowed : Boolean) is
   begin
      Wider := Allowed;
   end Use_Wide_Rows;

   --------------------
   -- Use_Deep_Rows --
   --------------------

   procedure Use_Deep_Rows (Allowed : Boolean) is
   begin
      Deeper := Allowed;
   end Use_Deep_Rows;

   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Integer_32;
   use type G.Tensor_Type;
   use type N.Real;

   ------------------------
   -- Has_Integer_Kernel --
   ------------------------

   function Has_Integer_Kernel
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Format = G.Type_Q8_0
       or else Format = G.Type_Q4_K
       or else Format = G.Type_Q5_K
       or else Format = G.Type_Q6_K);

   --------------------
   -- Packs_Vectors --
   --------------------

   function Packs_Vectors
     (Format : Model_Runner.GGUF.Tensor_Type;
      Count  : Element_Count) return Boolean
   is (Has_Integer_Kernel (Format)
       and then (Format = G.Type_Q8_0
                 or else Count = 1
                 or else Count >= 4));

   ----------------------
   -- Quantize_Vectors --
   ----------------------

   function Packed_Blocks
     (Count : Element_Count; Columns : Element_Count) return Element_Count
   is
      Elements : constant Element_Count :=
        (if Count > 0 and then Columns > 0 then Count * Columns else 0);
   begin
      if Count = 0 or else not Is_Packable (Columns) then
         return 0;
      end if;

      return Elements / Activation_Block;
   end Packed_Blocks;

   procedure Quantize_Vectors
     (Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Columns : Element_Count;
      Values  : out Signed_Array;
      Scales  : out Model_Runner.Numerics.Real_Array;
      Totals  : out Sum_Array;
      Ok      : out Boolean)
   is
      Blocks : constant Element_Count := Packed_Blocks (Count, Columns);
   begin
      --  A shape this cannot pack has no blocks, and asking for its last
      --  one would take one from zero.
      if Blocks = 0 then
         Ok := False;
         return;
      end if;

      --  The whole of it is the first block to the last, which is the one
      --  place the two entry points differ.
      Quantize_Blocks
        (Vectors, Count, Columns, 0, Blocks - 1,
         Values, Scales, Totals, Ok);
   end Quantize_Vectors;

   --  The largest magnitude of one activation block and whether every one
   --  of its thirty-two numbers is finite, in four reads of eight lanes.
   --
   --  Written out for the reason softmax's first pass was: the finiteness
   --  test is an integer test of the exponent field, and a compiler that
   --  sees a float turned into bits one element at a time will not make
   --  eight lanes of it -- so it made none, and a profile found this loop
   --  running a magnitude, a maximum and a bit test one number at a time.
   --  As lanes both questions are lane work: a bitwise and for the
   --  magnitude, an ordered compare of it against infinity whose mask is
   --  accumulated, and a maximum. A value that is not finite fails that
   --  compare whether it is an infinity or a NaN.
   --
   --  Entered only where the host said it has the instructions, which this
   --  package is told rather than asks.
   procedure Block_Extent
     (Vectors : Model_Runner.Numerics.Real_Array;
      At_It   : Element_Count;
      Largest : out N.Real;
      Finite  : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);
   begin
      if Wider then
         declare
            LF : constant Character := ASCII.LF;

            At_Value : constant System.Address :=
              Vectors (Vectors'First + At_It)'Address;
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
               & "vandps 0(%2), %%ymm3, %%ymm0"           & LF
               & "vandps 32(%2), %%ymm3, %%ymm1"          & LF
               & "vandps 64(%2), %%ymm3, %%ymm2"          & LF
               & "vandps 96(%2), %%ymm3, %%ymm5"          & LF
               & "vcmpltps %%ymm4, %%ymm0, %%ymm6"        & LF
               & "vcmpltps %%ymm4, %%ymm1, %%ymm7"        & LF
               & "vandps %%ymm7, %%ymm6, %%ymm6"          & LF
               & "vcmpltps %%ymm4, %%ymm2, %%ymm7"        & LF
               & "vandps %%ymm7, %%ymm6, %%ymm6"          & LF
               & "vcmpltps %%ymm4, %%ymm5, %%ymm7"        & LF
               & "vandps %%ymm7, %%ymm6, %%ymm6"          & LF
               & "vmaxps %%ymm1, %%ymm0, %%ymm0"          & LF
               & "vmaxps %%ymm5, %%ymm2, %%ymm2"          & LF
               & "vmaxps %%ymm2, %%ymm0, %%ymm0"          & LF
               & "vextractf128 $1, %%ymm0, %%xmm1"        & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vmovhlps %%xmm0, %%xmm0, %%xmm1"        & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vshufps $1, %%xmm0, %%xmm0, %%xmm1"     & LF
               & "vmaxps %%xmm1, %%xmm0, %%xmm0"          & LF
               & "vmovss %%xmm0, %0"                      & LF
               & "vmovmskps %%ymm6, %%eax"                & LF
               & "movl %%eax, %1"                         & LF
               & "vzeroupper",
               Outputs =>
                 [N.Real'Asm_Output ("=m", Top),
                  Interfaces.Unsigned_32'Asm_Output ("=m", Flags)],
               Inputs   => [System.Address'Asm_Input ("r", At_Value)],
               Clobber  =>
                 "rax, ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7,"
                 & " cc, memory",
               Volatile => True);

            Largest := Top;
            Finite  := Interfaces."=" (Flags, 255);
            return;
         end;
      end if;

      Largest := 0.0;
      Finite  := True;

      for Index in 0 .. Element_Count (Activation_Block) - 1 loop
         declare
            Value : constant N.Real :=
              Vectors (Vectors'First + At_It + Index);
         begin
            if not N.Is_Finite (Value) then
               Finite := False;
            elsif abs Value > Largest then
               Largest := abs Value;
            end if;
         end;
      end loop;
   end Block_Extent;

   procedure Quantize_Blocks
     (Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Columns : Element_Count;
      First   : Element_Count;
      Last    : Element_Count;
      Values  : out Signed_Array;
      Scales  : out Model_Runner.Numerics.Real_Array;
      Totals  : out Sum_Array;
      Ok      : out Boolean)
   is
      Elements : constant Element_Count :=
        (if Count > 0 and then Columns > 0 then Count * Columns else 0);
      Blocks   : constant Element_Count := Elements / Activation_Block;
   begin
      Ok := False;

      if Count = 0
        or else not Is_Packable (Columns)
        or else Vectors'Length < Elements
        or else Values'Length < Elements
        or else Scales'Length < Blocks
        or else Totals'Length < Blocks
        or else Last >= Blocks
      then
         return;
      end if;

      --  An empty range is not a refusal: a share past the end of a short
      --  run has nothing to do and has done it.
      if First > Last then
         Ok := True;
         return;
      end if;

      --  Two passes over a block: the largest magnitude, then the rounding.
      --  Every index below is inside the lengths proved above, which is what
      --  lets the rounding loop run without a check per element.
      for Block in First .. Last loop
         declare
            pragma Suppress (Index_Check);
            pragma Suppress (Range_Check);
            pragma Suppress (Overflow_Check);

            At_Element : constant Element_Count :=
              Block * Activation_Block;
            Largest    : N.Real;
            Finite     : Boolean;
            Scale      : N.Real;
            Inverse    : N.Real;
            Total      : Interfaces.Integer_32 := 0;
         begin
            --  A block holding anything that is not finite has no nearest
            --  byte. Refusing here rather than clamping is what keeps the
            --  caller's own finiteness checks the place such a value is
            --  reported.
            Block_Extent (Vectors, At_Element, Largest, Finite);

            if not Finite then
               return;
            end if;

            Scale := Largest / 127.0;
            Inverse := (if Scale > 0.0 then 1.0 / Scale else 0.0);
            Scales (Scales'First + Block) := Scale;

            for Index in 0 .. Element_Count (Activation_Block) - 1 loop
               declare
                  Scaled : constant N.Real :=
                    Vectors (Vectors'First + At_Element + Index) * Inverse;

                  --  Rounded to nearest with ties away from zero, which is
                  --  what Ada's rounding attribute does, and clamped: the
                  --  scale is the largest magnitude over 127, so nothing
                  --  should reach 128, and the clamp is what makes that a
                  --  fact about the code rather than about the arithmetic.
                  --
                  --  Clamped at minus a hundred and twenty-seven rather
                  --  than minus a hundred and twenty-eight, which the type
                  --  would allow. The byte dot product applies the weight's
                  --  sign to the activation, and minus a hundred and
                  --  twenty-eight negated in a byte is itself -- so that one
                  --  value would come out with the wrong sign. It cannot
                  --  arise from the arithmetic above and now it cannot arise
                  --  at all.
                  Whole  : constant Integer :=
                    Integer'Max (-127,
                                 Integer'Min (127, Integer (N.Real'Rounding
                                                              (Scaled))));
               begin
                  Values (Values'First + At_Element + Index) :=
                    Byte_Signed (Whole);
                  Total := Total + Interfaces.Integer_32 (Whole);
               end;
            end loop;

            Totals (Totals'First + Block) := Total;
         end;
      end loop;

      Ok := True;
   end Quantize_Blocks;

   ----------------------
   -- Accumulate_Rows --
   ----------------------

   procedure Accumulate_Rows
     (Format    : Model_Runner.GGUF.Tensor_Type;
      Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean) is
   begin
      --  One source, three compilations, and the host decides which. Each
      --  is entered only where the host says it has the instructions, which
      --  it is asked once and told here rather than reading a machine
      --  itself: this package interprets what a model file holds and may not
      --  reach a host.
      --
      --  Deepest first, because the deeper promise implies the wider one.
      if Deeper then
         Deep.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      elsif Wider then
         Wide.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      else
         Plain.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      end if;
   end Accumulate_Rows;

end Model_Runner.Quantization.Integers;
