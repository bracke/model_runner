--  Native packed integer activations and products.
with Model_Runner.Quantization.Grid_Integers;
with System;
with System.Machine_Code;

with Model_Runner.Quantization.Integers.Deep;
with Model_Runner.Quantization.Integers.Plain;
with Model_Runner.Quantization.Integers.Wide;

package body Model_Runner.Quantization.Integers is
   --  Packing retains the arithmetic of the source format.

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

   function Decodes_Dearly (Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q4_K)
       or else Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q5_K)
       or else Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q6_K)
       or else Model_Runner.Quantization.Grid_Integers.Is_Grid (Format));

   function Takes_Few_Together
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Deeper
       and then (Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q4_K)
                 --  The grid formats decode a block once for four vectors in
                 --  their registers; a vector at a time decoded it for each,
                 --  and a drafted check of four cost three tokens.
                 or else Model_Runner.Quantization.Grid_Integers.Is_Grid (Format)));

   procedure Use_Deep_Rows (Allowed : Boolean) is
   begin
      Deeper := Allowed;
   end Use_Deep_Rows;

   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Integer_32;
   use type G.Tensor_Type;

   ------------------------
   -- Has_Integer_Kernel --
   ------------------------

   function Has_Integer_Kernel
     (Format      : Model_Runner.GGUF.Tensor_Type;
      Interleaved : Boolean := False;
      Reference_Arithmetic : Boolean := False) return Boolean
   is (if Interleaved and then not Deeper then False
       --  The panel kernels are the deepest compilation's alone; the other
       --  two refuse a panel and the product falls to the floating-point
       --  path, so True there would pack activations nothing reads.
       else (Reference_Arithmetic and then (Wider or Deeper)
             and then Format = G.Type_Q5_0)
       or else (Deeper and then not Interleaved
                and then Format in G.Type_IQ4_NL | G.Type_Q2_0)
       or else Format = G.Type_Q8_0
       or else (not Interleaved
                and then Model_Runner.Quantization.Grid_Integers.Is_Grid (Format))
       or else Format = G.Type_Q4_0
       --  Ordinary K rows require the deep kernels. Reference arithmetic
       --  also has exact256-bit lanes; advertise those so disabling512-bit
       --  execution does not send their packed products to float fallback.
       or else ((Deeper or else (Reference_Arithmetic and then Wider))
                and then (Format = G.Type_Q4_K
                          or else Format = G.Type_Q5_K
                          or else Format = G.Type_Q6_K))
       or else (Interleaved
                and then (Format = G.Type_Q4_1
                          or else Format = G.Type_Q5_0
                          or else Format = G.Type_Q5_1
                          or else Format = G.Type_Q2_K
                          or else Format = G.Type_Q3_K
                          or else Format = G.Type_IQ4_NL
                          or else Format = G.Type_IQ4_XS
                          or else Format = G.Type_MXFP4)));

   --------------------
   -- Packs_Vectors --
   --------------------

   function Packs_Vectors
     (Format : Model_Runner.GGUF.Tensor_Type;
      Count  : Element_Count;
      Interleaved : Boolean := False;
      Reference_Arithmetic : Boolean := False) return Boolean
   is (Has_Integer_Kernel (Format, Interleaved, Reference_Arithmetic) and then Count >= 1);

   ---------------------
   -- Supers_Vectors --
   ---------------------

   function Supers_Vectors
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Format = G.Type_Q4_K
       or else Format = G.Type_Q5_K
       or else Format = G.Type_Q6_K
       or else Format = G.Type_Q2_K
       or else Format = G.Type_Q3_K
       or else Format = G.Type_IQ4_XS
       --  The grid formats as llama.cpp quantizes them for, one scale for
       --  256: the kernel that decodes in its registers then sums a block's
       --  sub-blocks as integers, each times its odd scale, and widens once.
       or else Model_Runner.Quantization.Grid_Integers.Is_Grid (Format));

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
      Halves  : out Sum_Array;
      Ok      : out Boolean;
      Super   : Boolean := False;
      Reference_Rounding : Boolean := False;
      Half_Scales : Boolean := False)
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
         Values, Scales, Totals, Halves, Ok, Super, Reference_Rounding, Half_Scales);
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
      Halves  : out Sum_Array;
      Ok      : out Boolean;
      Super   : Boolean := False;
      Reference_Rounding : Boolean := False;
      Half_Scales : Boolean := False)
   is
      Elements : constant Element_Count :=
        (if Count > 0 and then Columns > 0 then Count * Columns else 0);
      Blocks   : constant Element_Count := Elements / Activation_Block;

      --  Blocks to a super-block.
      Per_Super : constant Element_Count :=
        Activation_Super / Activation_Block;
   begin
      Ok := False;

      if Count = 0
        or else not Is_Packable (Columns)
        or else Vectors'Length < Elements
        or else Values'Length < Elements
        or else Scales'Length < Blocks
        or else Totals'Length < Blocks
        or else Halves'Length < Blocks * (Activation_Block / Activation_Half)
        or else Last >= Blocks
      then
         return;
      end if;

      --  A super-block is quantized whole or not at all, so a range that
      --  begins or ends inside one is a caller's mistake rather than a
      --  shape to accommodate. The one caller that cuts a run into pieces
      --  cuts it into super-blocks when this is asked for.
      if Super
        and then First <= Last
        and then (Columns mod Activation_Super /= 0
                  or else First mod Per_Super /= 0
                  or else (Last + 1) mod Per_Super /= 0)
      then
         return;
      end if;

      --  An empty range is not a refusal: a share past the end of a short
      --  run has nothing to do and has done it.
      if First > Last then
         Ok := True;
         return;
      end if;

      if Reference_Rounding and then Deeper then
         Deep.Reference_Pack (Vectors, First, Last, Values, Scales, Totals, Halves,
                              Ok, Super, Half_Scales);
         return;
      end if;

      if not Super and then Reference_Rounding then
         for Block in First .. Last loop
            declare
               Base : constant Element_Count := Block * Activation_Block;
               Largest : N.Real := 0.0;
               Inverse : N.Real;
               Earlier, Total : Interfaces.Integer_32 := 0;
            begin
               for Index in Element_Count range 0 .. Activation_Block - 1 loop
                  declare
                     Value : constant N.Real := Vectors (Vectors'First + Base + Index);
                  begin
                     if not N.Is_Finite (Value) then
                        return;
                     end if;
                     Largest := N.Real'Max (Largest, abs (Value));
                  end;
               end loop;
               Inverse := (if Largest = 0.0 then 0.0 else 127.0 / Largest);
               Scales (Scales'First + Block) :=
                 (if Half_Scales then N.To_Real (N.To_Half (Largest / 127.0)) else Largest / 127.0);
               for Index in Element_Count range 0 .. Activation_Block - 1 loop
                  declare
                     Rounded : constant Integer := Integer (N.Real'Unbiased_Rounding
                       (Vectors (Vectors'First + Base + Index) * Inverse));
                     Byte : constant Byte_Signed := Byte_Signed (Integer'Min (127, Rounded));
                  begin
                     Values (Values'First + Base + Index) := Byte;
                     Total := Total + Interfaces.Integer_32 (Byte);
                     if Index = Activation_Half - 1 then
                        Earlier := Total;
                     end if;
                  end;
               end loop;
               Totals (Totals'First + Block) := Total;
               Halves (Halves'First + Block * 2) := Earlier;
               Halves (Halves'First + Block * 2 + 1) := Total - Earlier;
            end;
         end loop;
         Ok := True;
         return;
      end if;

      if Super and then Reference_Rounding then
         for Group in First / Per_Super .. Last / Per_Super loop
            declare
               Base : constant Element_Count := Group * Activation_Super;
               Largest, Magnitude : N.Real := 0.0;
               Inverse, Scale : N.Real;
            begin
               for Index in Element_Count range 0 .. Activation_Super - 1 loop
                  declare
                     Value : constant N.Real := Vectors (Vectors'First + Base + Index);
                  begin
                     if not N.Is_Finite (Value) then
                        return;
                     end if;
                     if abs (Value) > Magnitude then
                        Magnitude := abs (Value);
                        Largest := Value;
                     end if;
                  end;
               end loop;
               Inverse := (if Magnitude = 0.0 then 0.0 else -127.0 / Largest);
               Scale := (if Magnitude = 0.0 then 0.0 else 1.0 / Inverse);
               if Half_Scales then Scale := N.To_Real (N.To_Half (Scale)); end if;
               for Part in 0 .. Per_Super - 1 loop
                  declare
                     Block : constant Element_Count := Group * Per_Super + Part;
                     Total, Earlier : Interfaces.Integer_32 := 0;
                  begin
                     for Index in Element_Count range 0 .. Activation_Block - 1 loop
                        declare
                           At_Element : constant Element_Count := Base + Part * Activation_Block + Index;
                           Rounded : constant Integer := Integer (N.Real'Unbiased_Rounding
                             (Vectors (Vectors'First + At_Element) * Inverse));
                           Byte : constant Byte_Signed := Byte_Signed (Integer'Min (127, Rounded));
                        begin
                           Values (Values'First + At_Element) := Byte;
                           Total := Total + Interfaces.Integer_32 (Byte);
                           if Index = Activation_Half - 1 then
                              Earlier := Total;
                           end if;
                        end;
                     end loop;
                     Scales (Scales'First + Block) := Scale;
                     Totals (Totals'First + Block) := Total;
                     Halves (Halves'First + Block * 2) := Earlier;
                     Halves (Halves'First + Block * 2 + 1) := Total - Earlier;
                  end;
               end loop;
            end;
         end loop;
         Ok := True;
         return;
      end if;

      --  One scale for two hundred and fifty-six, written into all eight of
      --  the blocks it covers so that every reader of Scales keeps its
      --  shape. The sums stay one for every thirty-two, because that is
      --  what a k-quant's minimum term wants them for.
      if Super then
         for Super_Block in First / Per_Super .. Last / Per_Super loop
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               At_Element : constant Element_Count :=
                 Super_Block * Activation_Super;

               Largest : N.Real := 0.0;
               Scale   : N.Real;
               Inverse : N.Real;
            begin
               --  Where the deep kernels are, the super-block is measured
               --  and rounded in two calls rather than sixteen: a block's
               --  calls each made their constants again, and a generated
               --  token packs a vector before every product it starts.
               if Deeper then
                  declare
                     Finite : Boolean;
                     Sums   : Deep.Block_Sums;
                  begin
                     Deep.Super_Extent (Vectors, At_Element, Largest, Finite);

                     if not Finite then
                        return;
                     end if;

                     Scale := Largest / 127.0;
                     Inverse := (if Scale > 0.0 then 1.0 / Scale else 0.0);

                     Deep.Super_Round
                       (Vectors, At_Element, Inverse, Values, At_Element,
                        Sums);

                     for Part in 0 .. Per_Super - 1 loop
                        declare
                           At_Half : constant Element_Count :=
                             (Super_Block * Per_Super + Part)
                             * (Activation_Block / Activation_Half);
                           Earlier : constant Interfaces.Integer_32 :=
                             Sums (Natural (2 * Part));
                           Total   : constant Interfaces.Integer_32 :=
                             Sums (Natural (2 * Part + 1));
                        begin
                           Scales (Scales'First + Super_Block * Per_Super
                                   + Part) := Scale;
                           Halves (Halves'First + At_Half) := Earlier;
                           Halves (Halves'First + At_Half + 1) :=
                             Total - Earlier;
                           Totals (Totals'First + Super_Block * Per_Super
                                   + Part) := Total;
                        end;
                     end loop;
                  end;

                  goto Super_Done;
               end if;

               for Part in 0 .. Per_Super - 1 loop
                  declare
                     Here   : N.Real;
                     Finite : Boolean;
                  begin
                     Block_Extent
                       (Vectors,
                        At_Element + Part * Activation_Block,
                        Here, Finite);

                     if not Finite then
                        return;
                     end if;

                     if Here > Largest then
                        Largest := Here;
                     end if;
                  end;
               end loop;

               Scale := Largest / 127.0;
               Inverse := (if Scale > 0.0 then 1.0 / Scale else 0.0);

               for Part in 0 .. Per_Super - 1 loop
                  declare
                     At_Part : constant Element_Count :=
                       At_Element + Part * Activation_Block;
                     At_Half : constant Element_Count :=
                       (Super_Block * Per_Super + Part)
                       * (Activation_Block / Activation_Half);
                     Total   : Interfaces.Integer_32 := 0;
                     Earlier : Interfaces.Integer_32 := 0;
                  begin
                     Scales (Scales'First + Super_Block * Per_Super + Part) :=
                       Scale;

                     if Deeper then
                        Deep.Block_Round
                          (Vectors, At_Part, Inverse, Values, At_Part,
                           Earlier, Total);

                        Halves (Halves'First + At_Half) := Earlier;
                        Halves (Halves'First + At_Half + 1) :=
                          Total - Earlier;
                        Totals (Totals'First + Super_Block * Per_Super + Part) :=
                          Total;

                        goto Part_Done;
                     end if;

                     for Index in 0 .. Element_Count (Activation_Half) - 1
                     loop

                        declare
                           Scaled : constant N.Real :=
                             Vectors (Vectors'First + At_Part + Index)
                             * Inverse;

                           Whole : constant Integer :=
                             Integer'Max
                               (-127,
                                Integer'Min
                                  (127,
                                   Integer (N.Real'Rounding (Scaled))));
                        begin
                           Values (Values'First + At_Part + Index) :=
                             Byte_Signed (Whole);
                           Total := Total + Interfaces.Integer_32 (Whole);
                        end;
                     end loop;

                     Halves (Halves'First + At_Half) := Total;
                     Earlier := Total;

                     for Index in Element_Count (Activation_Half)
                                  .. Element_Count (Activation_Block) - 1
                     loop
                        declare
                           Scaled : constant N.Real :=
                             Vectors (Vectors'First + At_Part + Index)
                             * Inverse;

                           Whole : constant Integer :=
                             Integer'Max
                               (-127,
                                Integer'Min
                                  (127,
                                   Integer (N.Real'Rounding (Scaled))));
                        begin
                           Values (Values'First + At_Part + Index) :=
                             Byte_Signed (Whole);
                           Total := Total + Interfaces.Integer_32 (Whole);
                        end;
                     end loop;

                     Totals (Totals'First + Super_Block * Per_Super + Part) :=
                       Total;
                     Halves (Halves'First + At_Half + 1) := Total - Earlier;

                     <<Part_Done>>
                     null;
                  end;
               end loop;

               <<Super_Done>>
               null;
            end;
         end loop;

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

            --  The running total at the halfway point, kept so that the
            --  second half is a subtraction rather than a second pass.
            Earlier    : Interfaces.Integer_32 := 0;
            At_Half    : constant Element_Count :=
              Block * (Activation_Block / Activation_Half);
         begin
            --  The whole block in two vectors where the host has them: its
            --  own scale, its bytes and its two sums in one pass over the
            --  hundred and twenty-eight bytes it holds.
            --
            --  A block holding anything that is not finite has no nearest
            --  byte. Refusing here rather than clamping is what keeps the
            --  caller's own finiteness checks the place such a value is
            --  reported, and both paths below refuse the same way.
            if Deeper then
               Deep.Block_Pack
                 (Vectors, At_Element, Values, At_Element,
                  Scale, Earlier, Total, Finite);

               if not Finite then
                  return;
               end if;

               Scales (Scales'First + Block) := Scale;
               Halves (Halves'First + At_Half) := Earlier;
               Halves (Halves'First + At_Half + 1) := Total - Earlier;
               Totals (Totals'First + Block) := Total;

               goto Block_Done;
            end if;

            Block_Extent (Vectors, At_Element, Largest, Finite);

            if not Finite then
               return;
            end if;

            Scale := Largest / 127.0;
            Inverse := (if Scale > 0.0 then 1.0 / Scale else 0.0);
            Scales (Scales'First + Block) := Scale;

            --  Two passes of sixteen rather than one of thirty-two with a
            --  test in it. The half-sum is wanted at the halfway point, and
            --  asking for it there put a compare on every element of every
            --  activation -- which measured, on paths that read none of it.
            for Index in 0 .. Element_Count (Activation_Half) - 1 loop

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

            Halves (Halves'First + At_Half) := Total;
            Earlier := Total;

            for Index in Element_Count (Activation_Half)
                         .. Element_Count (Activation_Block) - 1
            loop
               declare
                  Scaled : constant N.Real :=
                    Vectors (Vectors'First + At_Element + Index) * Inverse;

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
            Halves (Halves'First + At_Half + 1) := Total - Earlier;

            <<Block_Done>>
            null;
         end;
      end loop;

      Ok := True;
   end Quantize_Blocks;

   --  Q6_K's unsigned-code products and signed sixteen-coordinate scales
   --  retain the reference bias lanes before the binary32 FMA and fold.
   procedure Reference_Q6
     (Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array;
      Halves : Sum_Array; First, Stride, Count : Element_Count;
      Sums : in out Model_Runner.Numerics.Wide_Real_Array; Ok : out Boolean)
   is
      package B renames Model_Runner.Bytes;
      package N renames Model_Runner.Numerics;
      use type B.Byte_Count;
      use type B.Byte;
      use type N.Wide_Real;
      LF : constant Character := ASCII.LF;
      Biases : Sum_Array (0 .. Blocks * 8 - 1);
      Result : N.Real;
      function Signed (Raw : B.Byte) return Interfaces.Integer_32
      is (if Raw > 127 then Interfaces.Integer_32 (Raw) - 256 else Interfaces.Integer_32 (Raw));
   begin
      Ok := False;
      if Rows = 0 or else Blocks = 0 or else Count = 0
        or else First mod 256 /= 0 or else (Count > 1 and then Stride mod 256 /= 0)
        or else Sums'Length < Rows * Count
        or else Values'Length < First + (Count - 1) * Stride + Blocks * 256
        or else Scales'Length < (First + (Count - 1) * Stride) / 32 + Blocks * 8
        or else Halves'Length < (First + (Count - 1) * Stride) / 16 + Blocks * 16
        or else not B.Has_Room (Data, Offset,
                               (B.Byte_Count (Rows) - 1) * Row_Bytes + B.Byte_Count (Blocks) * 210)
      then return;
      end if;
      for Row in 0 .. Rows - 1 loop
         for Vector in 0 .. Count - 1 loop
            declare
               At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
               At_Value : constant Element_Count := Values'First + First + Vector * Stride;
               At_Scale : constant Element_Count := Scales'First + (First + Vector * Stride) / 32;
               At_Half : constant Element_Count := Halves'First + (First + Vector * Stride) / 16;
            begin
               for Block in 0 .. Blocks - 1 loop
                  for Pair in Element_Count range 0 .. 7 loop
                     declare
                        Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * 210
                          + 192 + B.Byte_Count (Pair) * 2;
                     begin
                        Biases (Block * 8 + Pair) := 32
                          * (Signed (Data (Base)) * Halves (At_Half + Block * 16 + Pair * 2)
                             + Signed (Data (Base + 1)) * Halves (At_Half + Block * 16 + Pair * 2 + 1));
                     end;
                  end loop;
               end loop;
               System.Machine_Code.Asm
                 (
                    "movq %1, %%r8" & LF
                     & "movq %2, %%r9" & LF
                     & "movq %3, %%r10" & LF
                     & "movq %4, %%r11" & LF
                     & "movq %5, %%r12" & LF
                     & "vxorps %%ymm8, %%ymm8, %%ymm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovd %%eax, %%xmm9" & LF
                     & "vpbroadcastd %%xmm9, %%ymm9" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vmovd %%eax, %%xmm10" & LF
                     & "vpbroadcastd %%xmm10, %%ymm10" & LF
                     & "1:" & LF
                     & "vpxor %%ymm7, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 0(%%r8), %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 128(%%r8), %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 0(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 192(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 193(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 32(%%r8), %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 128(%%r8), %%ymm1" & LF
                     & "vpsrlw $2, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 32(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 194(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 195(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 0(%%r8), %%ymm0" & LF
                     & "vpsrlw $4, %%ymm0, %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 128(%%r8), %%ymm1" & LF
                     & "vpsrlw $4, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 64(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 196(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 197(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 32(%%r8), %%ymm0" & LF
                     & "vpsrlw $4, %%ymm0, %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 128(%%r8), %%ymm1" & LF
                     & "vpsrlw $6, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 96(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 198(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 199(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 64(%%r8), %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 160(%%r8), %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 128(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 200(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 201(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 96(%%r8), %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 160(%%r8), %%ymm1" & LF
                     & "vpsrlw $2, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 160(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 202(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 203(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 64(%%r8), %%ymm0" & LF
                     & "vpsrlw $4, %%ymm0, %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 160(%%r8), %%ymm1" & LF
                     & "vpsrlw $4, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 192(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 204(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 205(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vmovdqu 96(%%r8), %%ymm0" & LF
                     & "vpsrlw $4, %%ymm0, %%ymm0" & LF
                     & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
                     & "vmovdqu 160(%%r8), %%ymm1" & LF
                     & "vpsrlw $6, %%ymm1, %%ymm1" & LF
                     & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
                     & "vpsllw $4, %%ymm1, %%ymm1" & LF
                     & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
                     & "vpmaddubsw 224(%%r9), %%ymm0, %%ymm3" & LF
                     & "vpbroadcastb 206(%%r8), %%xmm4" & LF
                     & "vpmovsxbw %%xmm4, %%ymm4" & LF
                     & "vpbroadcastb 207(%%r8), %%xmm5" & LF
                     & "vpmovsxbw %%xmm5, %%xmm5" & LF
                     & "vinserti128 $1, %%xmm5, %%ymm4, %%ymm4" & LF
                     & "vpmaddwd %%ymm4, %%ymm3, %%ymm3" & LF
                     & "vpaddd %%ymm3, %%ymm7, %%ymm7" & LF
                     & "vpsubd (%%r11), %%ymm7, %%ymm7" & LF
                     & "vcvtdq2ps %%ymm7, %%ymm7" & LF
                     & "vpbroadcastw 208(%%r8), %%xmm6" & LF
                     & "vcvtph2ps %%xmm6, %%xmm6" & LF
                     & "vmulss (%%r10), %%xmm6, %%xmm6" & LF
                     & "vbroadcastss %%xmm6, %%ymm6" & LF
                     & "vfmadd231ps %%ymm6, %%ymm7, %%ymm8" & LF
                     & "addq $210, %%r8" & LF
                     & "addq $256, %%r9" & LF
                     & "addq $32, %%r10" & LF
                     & "addq $32, %%r11" & LF
                     & "decq %%r12" & LF
                     & "jnz 1b" & LF
                     & "vextractf128 $1, %%ymm8, %%xmm0" & LF
                     & "vaddps %%xmm8, %%xmm0, %%xmm0" & LF
                     & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                     & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                     & "vmovshdup %%xmm0, %%xmm1" & LF
                     & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                     & "vmovss %%xmm0, %0" & LF
                     & "vzeroupper",
                  Outputs => [N.Real'Asm_Output ("=m", Result)],
                  Inputs => [System.Address'Asm_Input ("r", Data (At_Byte)'Address),
                             System.Address'Asm_Input ("r", Values (At_Value)'Address),
                             System.Address'Asm_Input ("r", Scales (At_Scale)'Address),
                             System.Address'Asm_Input ("r", Biases (0)'Address),
                             Element_Count'Asm_Input ("r", Blocks)],
                  Clobber => "rax,r8,r9,r10,r11,r12,ymm0,ymm1,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,"
                    & "cc,memory", Volatile => True);
               Sums (Sums'First + Row * Count + Vector) :=
                 Sums (Sums'First + Row * Count + Vector) + N.Wide_Real (Result);
            end;
         end loop;
      end loop;
      Ok := True;
   end Reference_Q6;

   --  Q4_K's reference reduction keeps the eight integer dot lanes and
   --  four paired minimum lanes separate until the final binary32 fold.
   procedure Reference_Q4
     (Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array;
      Totals : Sum_Array; First, Stride, Count : Element_Count;
      Sums : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok : out Boolean; Fifth : Boolean := False)
   is
      package B renames Model_Runner.Bytes;
      package N renames Model_Runner.Numerics;
      use type B.Byte_Count;
      use type N.Wide_Real;
      use type Interfaces.Unsigned_8;
      Weight_Block : constant B.Byte_Count := (if Fifth then 176 else 144);
      Code_Offset : constant B.Byte_Count := (if Fifth then 48 else 16);
      LF : constant Character := ASCII.LF;
      Factors : Sum_Array (0 .. Blocks * 8 - 1);
      Minimums : Sum_Array (0 .. Blocks * 8 - 1);
      Paired : Sum_Array (0 .. Blocks * 4 - 1);
      Both : N.Real_Array (0 .. Blocks * 2 - 1);
      Result : N.Real;
      Readable : Boolean;
   begin
      Ok := False;
      if Rows = 0 or else Blocks = 0 or else Count = 0
        or else First mod 256 /= 0 or else (Count > 1 and then Stride mod 256 /= 0)
        or else Sums'Length < Rows * Count
        or else Values'Length < First + (Count - 1) * Stride + Blocks * 256
        or else Scales'Length < (First + (Count - 1) * Stride) / 32 + Blocks * 8
        or else Totals'Length < (First + (Count - 1) * Stride) / 32 + Blocks * 8
        or else not B.Has_Room (Data, Offset,
                               (B.Byte_Count (Rows) - 1) * Row_Bytes + B.Byte_Count (Blocks) * Weight_Block)
      then return;
      end if;
      for Row in 0 .. Rows - 1 loop
         declare
            At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
         begin
            for Block in 0 .. Blocks - 1 loop
               declare
                  Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * Weight_Block;
               begin
                  for Group in Element_Count range 0 .. 7 loop
                     declare
                        At_Group : constant B.Byte_Count := B.Byte_Count (Group);
                        Scale, Minimum : Interfaces.Unsigned_8;
                     begin
                        if Group < 4 then
                           Scale := Data (Base + 4 + At_Group) and 63;
                           Minimum := Data (Base + 8 + At_Group) and 63;
                        else
                           Scale := (Data (Base + 8 + At_Group) and 15)
                             or Interfaces.Shift_Left (Interfaces.Shift_Right (Data (Base + At_Group), 6), 4);
                           Minimum := Interfaces.Shift_Right (Data (Base + 8 + At_Group), 4)
                             or Interfaces.Shift_Left (Interfaces.Shift_Right (Data (Base + 4 + At_Group), 6), 4);
                        end if;
                        Factors (Block * 8 + Group) := Interfaces.Integer_32 (Scale);
                        Minimums (Block * 8 + Group) := Interfaces.Integer_32 (Minimum);
                     end;
                  end loop;
               end;
            end loop;
            for Vector in 0 .. Count - 1 loop
               declare
                  At_Value : constant Element_Count := Values'First + First + Vector * Stride;
                  At_Scale : constant Element_Count := (First + Vector * Stride) / 32;
               begin
                  for Block in 0 .. Blocks - 1 loop
                     declare
                        Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * Weight_Block;
                        Scale : constant N.Real := Scales (Scales'First + At_Scale + Block * 8);
                     begin
                        Both (Block * 2) := Scale * N.To_Real
                          (N.Half (B.Get_U16 (Data, Base - Data'First, Readable)));
                        pragma Assert (Readable);
                        Both (Block * 2 + 1) := -Scale * N.To_Real
                          (N.Half (B.Get_U16 (Data, Base - Data'First + 2, Readable)));
                        pragma Assert (Readable);
                        for Pair in Element_Count range 0 .. 3 loop
                           Paired (Block * 4 + Pair) :=
                             Minimums (Block * 8 + Pair * 2)
                               * Totals (Totals'First + At_Scale + Block * 8 + Pair * 2)
                             + Minimums (Block * 8 + Pair * 2 + 1)
                               * Totals (Totals'First + At_Scale + Block * 8 + Pair * 2 + 1);
                        end loop;
                     end;
                  end loop;
                  declare
                     Weights_At : constant System.Address := Data (At_Byte + Code_Offset)'Address;
                     Values_At : constant System.Address := Values (At_Value)'Address;
                     Factors_At : constant System.Address := Factors (0)'Address;
                     Paired_At : constant System.Address := Paired (0)'Address;
                     Both_At : constant System.Address := Both (0)'Address;
                  begin
                     if Fifth then
                     System.Machine_Code.Asm
                       ("movq %1, %%r8" & LF
                        & "movq %2, %%r9" & LF
                        & "movq %3, %%r10" & LF
                        & "movq %4, %%r11" & LF
                        & "movq %5, %%r12" & LF
                        & "movq %6, %%r13" & LF
                        & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
                        & "vxorps %%xmm8, %%xmm8, %%xmm8" & LF
                        & "movl $0x0f0f0f0f, %%eax" & LF
                        & "vmovd %%eax, %%xmm9" & LF
                        & "vpbroadcastd %%xmm9, %%ymm9" & LF
                        & "movl $0x01010101, %%eax" & LF
                        & "vmovd %%eax, %%xmm13" & LF
                        & "vpbroadcastd %%xmm13, %%ymm13" & LF
                        & "1:" & LF
                        & "vmovdqu -32(%%r8), %%ymm12" & LF
                        & "vpxor %%ymm6, %%ymm6, %%ymm6" & LF
                        & "movl $4, %%r14d" & LF
                        & "2:" & LF
                        & "vmovdqu (%%r8), %%ymm0" & LF
                        & "vpand %%ymm9, %%ymm0, %%ymm1" & LF
                        & "vpand %%ymm13, %%ymm12, %%ymm4" & LF
                        & "vpsllw $4, %%ymm4, %%ymm4" & LF
                        & "vpor %%ymm4, %%ymm1, %%ymm1" & LF
                        & "vpsrlw $1, %%ymm12, %%ymm12" & LF
                        & "vpsrlw $4, %%ymm0, %%ymm2" & LF
                        & "vpand %%ymm9, %%ymm2, %%ymm2" & LF
                        & "vpand %%ymm13, %%ymm12, %%ymm4" & LF
                        & "vpsllw $4, %%ymm4, %%ymm4" & LF
                        & "vpor %%ymm4, %%ymm2, %%ymm2" & LF
                        & "vpsrlw $1, %%ymm12, %%ymm12" & LF
                        & "vpmaddubsw (%%r9), %%ymm1, %%ymm1" & LF
                        & "vpbroadcastw (%%r10), %%ymm5" & LF
                        & "vpmaddwd %%ymm5, %%ymm1, %%ymm1" & LF
                        & "vpmaddubsw 32(%%r9), %%ymm2, %%ymm2" & LF
                        & "vpbroadcastw 4(%%r10), %%ymm5" & LF
                        & "vpmaddwd %%ymm5, %%ymm2, %%ymm2" & LF
                        & "vpaddd %%ymm2, %%ymm1, %%ymm1" & LF
                        & "vpaddd %%ymm1, %%ymm6, %%ymm6" & LF
                        & "addq $32, %%r8" & LF
                        & "addq $64, %%r9" & LF
                        & "addq $8, %%r10" & LF
                        & "decl %%r14d" & LF
                        & "jnz 2b" & LF
                        & "vcvtdq2ps %%ymm6, %%ymm6" & LF
                        & "vbroadcastss (%%r12), %%ymm10" & LF
                        & "vfmadd231ps %%ymm10, %%ymm6, %%ymm7" & LF
                        & "vmovdqu (%%r11), %%xmm10" & LF
                        & "vpxor %%xmm11, %%xmm11, %%xmm11" & LF
                        & "vphaddd %%xmm11, %%xmm10, %%xmm10" & LF
                        & "vphaddd %%xmm11, %%xmm10, %%xmm10" & LF
                        & "vcvtdq2ps %%xmm10, %%xmm10" & LF
                        & "vbroadcastss 4(%%r12), %%xmm11" & LF
                        & "vfmadd231ss %%xmm11, %%xmm10, %%xmm8" & LF
                        & "addq $48, %%r8" & LF
                        & "addq $16, %%r11" & LF
                        & "addq $8, %%r12" & LF
                        & "decq %%r13" & LF
                        & "jnz 1b" & LF
                        & "vextractf128 $1, %%ymm7, %%xmm0" & LF
                        & "vaddps %%xmm7, %%xmm0, %%xmm0" & LF
                        & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                        & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                        & "vmovshdup %%xmm0, %%xmm1" & LF
                        & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                        & "vaddss %%xmm8, %%xmm0, %%xmm0" & LF
                        & "vmovss %%xmm0, %0" & LF
                        & "vzeroupper",
                        Outputs => [N.Real'Asm_Output ("=m", Result)],
                        Inputs => [System.Address'Asm_Input ("m", Weights_At),
                                   System.Address'Asm_Input ("m", Values_At),
                                   System.Address'Asm_Input ("m", Factors_At),
                                   System.Address'Asm_Input ("m", Paired_At),
                                   System.Address'Asm_Input ("m", Both_At),
                                   Element_Count'Asm_Input ("m", Blocks)],
                        Clobber => "rax,r8,r9,r10,r11,r12,r13,r14,"
                          & "ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,cc,memory",
                        Volatile => True);
                     else
                     System.Machine_Code.Asm
                       ("movq %1, %%r8" & LF
                        & "movq %2, %%r9" & LF
                        & "movq %3, %%r10" & LF
                        & "movq %4, %%r11" & LF
                        & "movq %5, %%r12" & LF
                        & "movq %6, %%r13" & LF
                        & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
                        & "vxorps %%xmm8, %%xmm8, %%xmm8" & LF
                        & "movl $0x0f0f0f0f, %%eax" & LF
                        & "vmovd %%eax, %%xmm9" & LF
                        & "vpbroadcastd %%xmm9, %%ymm9" & LF
                        & "1:" & LF
                        & "vpxor %%ymm6, %%ymm6, %%ymm6" & LF
                        & "movl $4, %%r14d" & LF
                        & "2:" & LF
                        & "vmovdqu (%%r8), %%ymm0" & LF
                        & "vpand %%ymm9, %%ymm0, %%ymm1" & LF
                        & "vpsrlw $4, %%ymm0, %%ymm2" & LF
                        & "vpand %%ymm9, %%ymm2, %%ymm2" & LF
                        & "vpmaddubsw (%%r9), %%ymm1, %%ymm1" & LF
                        & "vpbroadcastw (%%r10), %%ymm5" & LF
                        & "vpmaddwd %%ymm5, %%ymm1, %%ymm1" & LF
                        & "vpmaddubsw 32(%%r9), %%ymm2, %%ymm2" & LF
                        & "vpbroadcastw 4(%%r10), %%ymm5" & LF
                        & "vpmaddwd %%ymm5, %%ymm2, %%ymm2" & LF
                        & "vpaddd %%ymm2, %%ymm1, %%ymm1" & LF
                        & "vpaddd %%ymm1, %%ymm6, %%ymm6" & LF
                        & "addq $32, %%r8" & LF
                        & "addq $64, %%r9" & LF
                        & "addq $8, %%r10" & LF
                        & "decl %%r14d" & LF
                        & "jnz 2b" & LF
                        & "vcvtdq2ps %%ymm6, %%ymm6" & LF
                        & "vbroadcastss (%%r12), %%ymm10" & LF
                        & "vfmadd231ps %%ymm10, %%ymm6, %%ymm7" & LF
                        & "vmovdqu (%%r11), %%xmm10" & LF
                        & "vcvtdq2ps %%xmm10, %%xmm10" & LF
                        & "vbroadcastss 4(%%r12), %%xmm11" & LF
                        & "vfmadd231ps %%xmm11, %%xmm10, %%xmm8" & LF
                        & "addq $16, %%r8" & LF
                        & "addq $16, %%r11" & LF
                        & "addq $8, %%r12" & LF
                        & "decq %%r13" & LF
                        & "jnz 1b" & LF
                        & "vextractf128 $1, %%ymm7, %%xmm0" & LF
                        & "vaddps %%xmm7, %%xmm0, %%xmm0" & LF
                        & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                        & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                        & "vmovshdup %%xmm0, %%xmm1" & LF
                        & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                        & "vmovhlps %%xmm8, %%xmm8, %%xmm1" & LF
                        & "vaddps %%xmm1, %%xmm8, %%xmm8" & LF
                        & "vmovshdup %%xmm8, %%xmm1" & LF
                        & "vaddss %%xmm1, %%xmm8, %%xmm8" & LF
                        & "vaddss %%xmm8, %%xmm0, %%xmm0" & LF
                        & "vmovss %%xmm0, %0" & LF
                        & "vzeroupper",
                        Outputs => [N.Real'Asm_Output ("=m", Result)],
                        Inputs => [System.Address'Asm_Input ("m", Weights_At),
                                   System.Address'Asm_Input ("m", Values_At),
                                   System.Address'Asm_Input ("m", Factors_At),
                                   System.Address'Asm_Input ("m", Paired_At),
                                   System.Address'Asm_Input ("m", Both_At),
                                   Element_Count'Asm_Input ("m", Blocks)],
                        Clobber => "rax,r8,r9,r10,r11,r12,r13,r14,"
                          & "ymm0,ymm1,ymm2,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,cc,memory",
                        Volatile => True);
                     end if;
                  end;
                  Sums (Sums'First + Row * Count + Vector) :=
                    Sums (Sums'First + Row * Count + Vector) + N.Wide_Real (Result);
               end;
            end loop;
         end;
      end loop;
      Ok := True;
   end Reference_Q4;

   --  Q8_0 products for reference-calibrated activations. Four exact byte
   --  products feed each of eight binary32 FMA lanes, folded once per row.
   --  Guarded by the same AVX2/FMA/F16C capability as the wide integer path.
   procedure Reference_Q8
     (Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array;
      First, Stride, Count : Element_Count;
      Sums : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok : out Boolean)
   is
      package B renames Model_Runner.Bytes;
      package N renames Model_Runner.Numerics;
      use type B.Byte_Count;
      use type N.Wide_Real;
      LF : constant Character := ASCII.LF;
      Result : N.Real;
   begin
      Ok := False;
      if Rows = 0 or else Blocks = 0 or else Count = 0
        or else First mod 32 /= 0 or else (Count > 1 and then Stride mod 32 /= 0)
        or else Sums'Length < Rows * Count
        or else Values'Length < First + (Count - 1) * Stride + Blocks * 32
        or else Scales'Length < (First + (Count - 1) * Stride) / 32 + Blocks
        or else not B.Has_Room (Data, Offset,
                               (B.Byte_Count (Rows) - 1) * Row_Bytes + B.Byte_Count (Blocks) * 34)
      then
         return;
      end if;
      for Row in 0 .. Rows - 1 loop
         for Vector in 0 .. Count - 1 loop
            declare
               At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
               At_Value : constant Element_Count := Values'First + First + Vector * Stride;
               At_Scale : constant Element_Count := Scales'First + (First + Vector * Stride) / 32;
            begin
               System.Machine_Code.Asm
                 ("movq %1, %%r8" & LF
                  & "movq %2, %%r9" & LF
                  & "movq %3, %%r10" & LF
                  & "movq %4, %%r11" & LF
                  & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
                  & "movl $0x00010001, %%eax" & LF
                  & "vmovd %%eax, %%xmm5" & LF
                  & "vpbroadcastd %%xmm5, %%ymm5" & LF
                  & "1:" & LF
                  & "vmovdqu 2(%%r8), %%ymm1" & LF
                  & "vmovdqu (%%r9), %%ymm2" & LF
                  & "vpsignb %%ymm1, %%ymm1, %%ymm3" & LF
                  & "vpsignb %%ymm1, %%ymm2, %%ymm4" & LF
                  & "vpmaddubsw %%ymm4, %%ymm3, %%ymm3" & LF
                  & "vpmaddwd %%ymm5, %%ymm3, %%ymm3" & LF
                  & "vcvtdq2ps %%ymm3, %%ymm3" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vmulss (%%r10), %%xmm6, %%xmm6" & LF
                  & "vbroadcastss %%xmm6, %%ymm6" & LF
                  & "vfmadd231ps %%ymm6, %%ymm3, %%ymm0" & LF
                  & "addq $34, %%r8" & LF
                  & "addq $32, %%r9" & LF
                  & "addq $4, %%r10" & LF
                  & "decq %%r11" & LF
                  & "jnz 1b" & LF
                  & "vextractf128 $1, %%ymm0, %%xmm1" & LF
                  & "vaddps %%xmm0, %%xmm1, %%xmm0" & LF
                  & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                  & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovshdup %%xmm0, %%xmm1" & LF
                  & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovss %%xmm0, %0" & LF
                  & "vzeroupper",
                  Outputs => [N.Real'Asm_Output ("=m", Result)],
                  Inputs => [System.Address'Asm_Input ("r", Data (At_Byte)'Address),
                             System.Address'Asm_Input ("r", Values (At_Value)'Address),
                             System.Address'Asm_Input ("r", Scales (At_Scale)'Address),
                             Element_Count'Asm_Input ("r", Blocks)],
                  Clobber => "rax,r8,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,cc,memory",
                  Volatile => True);
               Sums (Sums'First + Row * Count + Vector) :=
                 Sums (Sums'First + Row * Count + Vector) + N.Wide_Real (Result);
            end;
         end loop;
      end loop;
      Ok := True;
   end Reference_Q8;

   procedure Reference_Q50
     (Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array;
      First, Stride, Count : Element_Count;
      Sums : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok : out Boolean)
   is
      package B renames Model_Runner.Bytes;
      package N renames Model_Runner.Numerics;
      use type B.Byte_Count;
      use type N.Wide_Real;
      Map : constant Model_Runner.Bytes.Byte_Array (0 .. 31) :=
        [0 .. 7 => 0, 8 .. 15 => 1, 16 .. 23 => 2, 24 .. 31 => 3];
      Bits : constant Model_Runner.Bytes.Byte_Array (0 .. 31) :=
        [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128,
         1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
      LF : constant Character := ASCII.LF;
      Result : N.Real;
   begin
      Ok := False;
      if Rows = 0 or else Blocks = 0 or else Count = 0
        or else First mod 32 /= 0 or else (Count > 1 and then Stride mod 32 /= 0)
        or else Sums'Length < Rows * Count
        or else Values'Length < First + (Count - 1) * Stride + Blocks * 32
        or else Scales'Length < (First + (Count - 1) * Stride) / 32 + Blocks
        or else not B.Has_Room (Data, Offset,
                               (B.Byte_Count (Rows) - 1) * Row_Bytes + B.Byte_Count (Blocks) * 22)
      then
         return;
      end if;
      for Row in 0 .. Rows - 1 loop
         for Vector in 0 .. Count - 1 loop
            declare
               At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
               At_Value : constant Element_Count := Values'First + First + Vector * Stride;
               At_Scale : constant Element_Count := Scales'First + (First + Vector * Stride) / 32;
            begin
               System.Machine_Code.Asm
                 ("movq %1, %%r8" & LF
                  & "movq %2, %%r9" & LF
                  & "movq %3, %%r10" & LF
                  & "movq %4, %%r11" & LF
                  & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
                  & "movl $0x00010001, %%eax" & LF
                  & "vmovd %%eax, %%xmm5" & LF
                  & "vpbroadcastd %%xmm5, %%ymm5" & LF
                  & "vmovdqu (%5), %%ymm12" & LF
                  & "vmovdqu (%6), %%ymm13" & LF
                  & "vpxor %%ymm14, %%ymm14, %%ymm14" & LF
                  & "movl $0x0f0f0f0f, %%eax" & LF
                  & "vmovd %%eax, %%xmm11" & LF
                  & "vpbroadcastd %%xmm11, %%ymm11" & LF
                  & "movl $0x10101010, %%eax" & LF
                  & "vmovd %%eax, %%xmm15" & LF
                  & "vpbroadcastd %%xmm15, %%ymm15" & LF
                  & "1:" & LF
                  & "vpbroadcastd 2(%%r8), %%ymm4" & LF
                  & "vpshufb %%ymm12, %%ymm4, %%ymm4" & LF
                  & "vpand %%ymm13, %%ymm4, %%ymm4" & LF
                  & "vpcmpeqb %%ymm14, %%ymm4, %%ymm4" & LF
                  & "vpand %%ymm15, %%ymm4, %%ymm4" & LF
                  & "vmovdqu 6(%%r8), %%xmm1" & LF
                  & "vpand %%xmm11, %%xmm1, %%xmm2" & LF
                  & "vpsrlw $4, %%xmm1, %%xmm3" & LF
                  & "vpand %%xmm11, %%xmm3, %%xmm3" & LF
                  & "vinserti128 $1, %%xmm3, %%ymm2, %%ymm1" & LF
                  & "vpsubb %%ymm4, %%ymm1, %%ymm1" & LF
                  & "vmovdqu (%%r9), %%ymm2" & LF
                  & "vpsignb %%ymm1, %%ymm1, %%ymm3" & LF
                  & "vpsignb %%ymm1, %%ymm2, %%ymm4" & LF
                  & "vpmaddubsw %%ymm4, %%ymm3, %%ymm3" & LF
                  & "vpmaddwd %%ymm5, %%ymm3, %%ymm3" & LF
                  & "vcvtdq2ps %%ymm3, %%ymm3" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vmulss (%%r10), %%xmm6, %%xmm6" & LF
                  & "vbroadcastss %%xmm6, %%ymm6" & LF
                  & "vfmadd231ps %%ymm6, %%ymm3, %%ymm0" & LF
                  & "addq $22, %%r8" & LF
                  & "addq $32, %%r9" & LF
                  & "addq $4, %%r10" & LF
                  & "decq %%r11" & LF
                  & "jnz 1b" & LF
                  & "vextractf128 $1, %%ymm0, %%xmm1" & LF
                  & "vaddps %%xmm0, %%xmm1, %%xmm0" & LF
                  & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                  & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovshdup %%xmm0, %%xmm1" & LF
                  & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovss %%xmm0, %0" & LF
                  & "vzeroupper",
                  Outputs => [N.Real'Asm_Output ("=m", Result)],
                  Inputs => [System.Address'Asm_Input ("r", Data (At_Byte)'Address),
                             System.Address'Asm_Input ("r", Values (At_Value)'Address),
                             System.Address'Asm_Input ("r", Scales (At_Scale)'Address),
                             Element_Count'Asm_Input ("r", Blocks),
                             System.Address'Asm_Input ("r", Map (0)'Address),
                             System.Address'Asm_Input ("r", Bits (0)'Address)],
                  Clobber => "rax,r8,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,"
                    & "ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
                  Volatile => True);
               Sums (Sums'First + Row * Count + Vector) :=
                 Sums (Sums'First + Row * Count + Vector) + N.Wide_Real (Result);
            end;
         end loop;
      end loop;
      Ok := True;
   end Reference_Q50;

   ----------------------
   -- Accumulate_Rows --
   ----------------------

   procedure Pack_Reference_Block
     (Vectors : N.Real_Array; Values : out Signed_Array; Scale : out N.Real;
      Earlier, Total : out Interfaces.Integer_32; Ok : out Boolean;
      Half_Scales : Boolean := False; Known_Peak : N.Real := N.Real'(-1.0))
   is
      Scaling : N.Real_Array (0 .. 0);
      Totals : Sum_Array (0 .. 0);
      Halves : Sum_Array (0 .. 1);
   begin
      Scale := 0.0; Earlier := 0; Total := 0; Ok := False;
      if Vectors'Length /= 32 or else Values'Length /= 32 then return; end if;
      if Deeper then
         Deep.Reference_Pack (Vectors, 0, 0, Values, Scaling, Totals, Halves,
                              Ok, False, Half_Scales, Known_Peak);
      else
         Quantize_Blocks (Vectors, 1, 32, 0, 0, Values, Scaling, Totals, Halves, Ok,
                          Reference_Rounding => True, Half_Scales => Half_Scales);
      end if;
      if Ok then Scale := Scaling (0); Earlier := Halves (0); Total := Totals (0); end if;
   end Pack_Reference_Block;

   procedure Reference_Coefficients
     (Format : Model_Runner.GGUF.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count; Into : out Model_Runner.Bytes.Byte_Array;
      Ok : out Boolean) is
   begin
      if Deeper then Deep.Reference_Coefficients (Format, Data, Offset, Into, Ok);
      else Plain.Reference_Coefficients (Format, Data, Offset, Into, Ok); end if;
   end Reference_Coefficients;

   procedure Small_Block_Rows
     (Format : G.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count; Values : Signed_Array; Scales : N.Real_Array;
      First, Stride, Count : Element_Count; Sums : in out N.Wide_Real_Array; Ok : out Boolean;
      Target : access N.Real_Array := null; Result_First, Result_Stride : Element_Count := 0;
      Result_Members : Model_Runner.Shares.Member_Rows := [];
      Input_Members : Model_Runner.Shares.Member_Rows := []);

   procedure IQ3_Reference_Products
     (Data : Model_Runner.Bytes.Byte_Array; Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count; Values : Signed_Array; Scales : N.Real_Array;
      First, Stride, Count : Element_Count; Target : access N.Real_Array;
      Result_First, Result_Stride : Element_Count; Ok : out Boolean;
      Result_Members, Input_Members : Model_Runner.Shares.Member_Rows) is separate;

   procedure Reference_Products
     (Format : Model_Runner.GGUF.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count; Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array; Totals, Halves : Sum_Array;
      First, Stride, Count : Element_Count; Target : access Model_Runner.Numerics.Real_Array;
      Result_First, Result_Stride : Element_Count; Ok : out Boolean;
      Interleaved : Boolean := False; Metadata : Model_Runner.Numerics.Real_Array := [];
      Partner : Model_Runner.Bytes.Byte_Array := []; Partner_Offset : Model_Runner.Bytes.Byte_Count := 0;
      Partner_Metadata : Model_Runner.Numerics.Real_Array := [];
      Partner_Target : access Model_Runner.Numerics.Real_Array := null;
      Result_Members : Model_Runner.Shares.Member_Rows := [];
      Input_Members : Model_Runner.Shares.Member_Rows := []) is
   begin
      Ok := False;
      if Deeper and then not Interleaved and then Format = G.Type_IQ3_S and then Count in 1 .. 16 then
         if Partner'Length /= 0 or else Partner_Target /= null or else Metadata'Length /= 0 then return; end if;
         IQ3_Reference_Products (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
           First, Stride, Count, Target, Result_First, Result_Stride, Ok, Result_Members, Input_Members);
         return;
      end if;

      if Deeper and then Format in G.Type_IQ4_NL | G.Type_Q2_0 then
         if Interleaved or else Partner'Length /= 0 or else Partner_Target /= null
           or else Target = null
         then return; end if;
         declare
            Unused : N.Wide_Real_Array (1 .. 0);
         begin
            Small_Block_Rows (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                              First, Stride, Count, Unused, Ok, Target, Result_First, Result_Stride,
                              Result_Members, Input_Members);
         end;
         return;
      end if;

      if not Deeper or else Format not in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K | G.Type_Q8_0 | G.Type_Q5_0
      then return; end if;
      Deep.Reference_Products
        (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales, Totals, Halves,
         First, Stride, Count, Target, Result_First, Result_Stride, Ok, Interleaved, Metadata,
         Partner, Partner_Offset, Partner_Metadata, Partner_Target, Result_Members, Input_Members);
   end Reference_Products;

   --  Row-major small-block products for GSQ-RCO expert down projections.
   --  Decode only to integer lanes, keep the independent reference's two
   --  FP32 FMA chains and fold, and accept every signed activation byte.
   --  Called only after the backend enables the validated byte-dot ISA.
   procedure Small_Block_Rows
     (Format : G.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows, Blocks : Element_Count; Values : Signed_Array; Scales : N.Real_Array;
      First, Stride, Count : Element_Count; Sums : in out N.Wide_Real_Array; Ok : out Boolean;
      Target : access N.Real_Array := null; Result_First, Result_Stride : Element_Count := 0;
      Result_Members : Model_Runner.Shares.Member_Rows := [];
      Input_Members : Model_Runner.Shares.Member_Rows := [])
   is
      package B renames Model_Runner.Bytes;
      use type B.Byte_Count;
      use type N.Wide_Real;
      LF : constant Character := ASCII.LF;
      Per : constant Element_Count := (if Format = G.Type_Q2_0 then 64 else 32);
      Columns, Reach : Element_Count;
      Required : B.Byte_Count;
      Result : N.Real;
      Levels : constant Signed_Array (0 .. 15) :=
        [-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113];

      function Source_Row (I : Element_Count) return Element_Count is
        (if Input_Members'Length = 0 then I
         else Element_Count (Input_Members (Input_Members'First + Natural (I))));
      procedure Put (Row, Vector : Element_Count; Value : N.Real) is
      begin
         if Target = null then
            Sums (Sums'First + Row * Count + Vector) :=
              Sums (Sums'First + Row * Count + Vector) + N.Wide_Real (Value);
         else
            declare
               Destination : constant Element_Count :=
                 (if Result_Members'Length = 0 then Vector
                  else Element_Count (Result_Members (Result_Members'First + Natural (Vector))));
            begin
               Target (Target.all'First + Destination * Result_Stride + Result_First + Row) :=
                 N.Real (0.0 + N.Wide_Real (Value));
            end;
         end if;
      end Put;

      --  IQ4_NL levels exclude -128: signing a weight cannot overflow.
      --  The unsigned magnitude still represents a -128 activation exactly.
      --  Decode each compressed block once for two or four independent vectors.
      --  Each retains its own even/odd FP32 chains and the original fold.
      procedure Few
        (At_Byte : B.Byte_Count; Vector : Element_Count; Taken : Positive; Result : out N.Real_Array) is
         type Addresses is array (0 .. 3) of System.Address;
         type Tile_Arguments is record
            Weights : System.Address;
            Block_Count : Element_Count;
            Inputs, Scaling : Addresses;
            Output, Table : System.Address;
         end record;
         for Tile_Arguments use record
            Weights at 0 range 0 .. 63;
            Block_Count at 8 range 0 .. 63;
            Inputs at 16 range 0 .. 255;
            Scaling at 48 range 0 .. 255;
            Output at 80 range 0 .. 63;
            Table at 88 range 0 .. 63;
         end record;
         Arguments : aliased Tile_Arguments;
         Argument_Pointer : aliased constant System.Address := Arguments'Address;
      begin
         Arguments.Weights := Data (At_Byte)'Address;
         Arguments.Block_Count := Blocks;
         Arguments.Output := Result (Result'First)'Address;
         Arguments.Table := Levels'Address;
         for I in Element_Count range 0 .. 3 loop
            declare
               Source : constant Element_Count := Source_Row (Vector + (if I < Element_Count (Taken) then I else 0));
            begin
               Arguments.Inputs (Natural (I)) := Values (Values'First + First + Source * Stride)'Address;
               Arguments.Scaling (Natural (I)) := Scales (Scales'First + (First + Source * Stride) / 32)'Address;
            end;
         end loop;
         Result := [others => 0.0];
         if Taken = 4 then
            if Format = G.Type_IQ4_NL then
            System.Machine_Code.Asm
              ("movq %0, %%rdi" & LF
               & "movq 0(%%rdi), %%r8" & LF
               & "movq 8(%%rdi), %%rcx" & LF
               & "movq 16(%%rdi), %%r9" & LF
               & "movq 24(%%rdi), %%r10" & LF
               & "movq 32(%%rdi), %%r11" & LF
               & "movq 40(%%rdi), %%r12" & LF
               & "movq 48(%%rdi), %%r13" & LF
               & "movq 56(%%rdi), %%r14" & LF
               & "movq 64(%%rdi), %%r15" & LF
               & "movq 72(%%rdi), %%rbx" & LF
               & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
               & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
               & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
               & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
               & "vxorps %%ymm5, %%ymm5, %%ymm5" & LF
               & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
               & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
               & "movl $0x0f0f0f0f, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm13" & LF
               & "movq 88(%%rdi), %%rax" & LF
               & "vmovdqu (%%rax), %%xmm14" & LF
               & "cmpq $2, %%rcx" & LF
               & "jb 2f" & LF
               & "1:" & LF
               & "vmovdqu 2(%%r8), %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm9" & LF
               & "vpshufb %%xmm9, %%xmm14, %%xmm9" & LF
               & "vpsrlw $4, %%xmm8, %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm8" & LF
               & "vpshufb %%xmm8, %%xmm14, %%xmm8" & LF
               & "vinserti128 $1, %%xmm8, %%ymm9, %%ymm8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm4" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm6" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "addq $18, %%r8" & LF
               & "vmovdqu 2(%%r8), %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm9" & LF
               & "vpshufb %%xmm9, %%xmm14, %%xmm9" & LF
               & "vpsrlw $4, %%xmm8, %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm8" & LF
               & "vpshufb %%xmm8, %%xmm14, %%xmm8" & LF
               & "vinserti128 $1, %%xmm8, %%ymm9, %%ymm8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm5" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm7" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "addq $18, %%r8" & LF
               & "subq $2, %%rcx" & LF
               & "cmpq $2, %%rcx" & LF
               & "jae 1b" & LF
               & "2:" & LF
               & "3:" & LF
               & "movq 80(%%rdi), %%rdx" & LF
               & "vaddps %%ymm1, %%ymm0, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 0(%%rdx)" & LF
               & "vaddps %%ymm3, %%ymm2, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 4(%%rdx)" & LF
               & "vaddps %%ymm5, %%ymm4, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 8(%%rdx)" & LF
               & "vaddps %%ymm7, %%ymm6, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 12(%%rdx)" & LF
               & "vzeroupper",
               Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
               Clobber => "rax,rbx,rcx,rdx,rdi,r8,r9,r10,r11,r12,r13,r14,r15,"
                 & "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory", Volatile => True);
            else
            System.Machine_Code.Asm
              ("movq %0, %%rdi" & LF
               & "movq 0(%%rdi), %%r8" & LF
               & "movq 8(%%rdi), %%rcx" & LF
               & "movq 16(%%rdi), %%r9" & LF
               & "movq 24(%%rdi), %%r10" & LF
               & "movq 32(%%rdi), %%r11" & LF
               & "movq 40(%%rdi), %%r12" & LF
               & "movq 48(%%rdi), %%r13" & LF
               & "movq 56(%%rdi), %%r14" & LF
               & "movq 64(%%rdi), %%r15" & LF
               & "movq 72(%%rdi), %%rbx" & LF
               & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
               & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
               & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
               & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
               & "vxorps %%ymm5, %%ymm5, %%ymm5" & LF
               & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
               & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
               & "movl $0x03030303, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm13" & LF
               & "movl $0x01010101, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm15" & LF
               & "cmpq $2, %%rcx" & LF
               & "jb 2f" & LF
               & "1:" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm4" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm6" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm4" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm6" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "addq $18, %%r8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm5" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm7" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm5" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm7" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "addq $18, %%r8" & LF
               & "subq $2, %%rcx" & LF
               & "cmpq $2, %%rcx" & LF
               & "jae 1b" & LF
               & "2:" & LF
               & "testq %%rcx, %%rcx" & LF
               & "jz 3f" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm4" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm6" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vmovdqu (%%r11), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r15), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm4" & LF
               & "addq $32, %%r11" & LF
               & "addq $4, %%r15" & LF
               & "vmovdqu (%%r12), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%rbx), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm6" & LF
               & "addq $32, %%r12" & LF
               & "addq $4, %%rbx" & LF
               & "addq $18, %%r8" & LF
               & "3:" & LF
               & "movq 80(%%rdi), %%rdx" & LF
               & "vaddps %%ymm1, %%ymm0, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 0(%%rdx)" & LF
               & "vaddps %%ymm3, %%ymm2, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 4(%%rdx)" & LF
               & "vaddps %%ymm5, %%ymm4, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 8(%%rdx)" & LF
               & "vaddps %%ymm7, %%ymm6, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 12(%%rdx)" & LF
               & "vzeroupper",
               Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
               Clobber => "rax,rbx,rcx,rdx,rdi,r8,r9,r10,r11,r12,r13,r14,r15,"
                 & "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory", Volatile => True);
            end if;
         else
            if Format = G.Type_IQ4_NL then
            System.Machine_Code.Asm
              ("movq %0, %%rdi" & LF
               & "movq 0(%%rdi), %%r8" & LF
               & "movq 8(%%rdi), %%rcx" & LF
               & "movq 16(%%rdi), %%r9" & LF
               & "movq 24(%%rdi), %%r10" & LF
               & "movq 32(%%rdi), %%r11" & LF
               & "movq 40(%%rdi), %%r12" & LF
               & "movq 48(%%rdi), %%r13" & LF
               & "movq 56(%%rdi), %%r14" & LF
               & "movq 64(%%rdi), %%r15" & LF
               & "movq 72(%%rdi), %%rbx" & LF
               & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
               & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
               & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
               & "movl $0x0f0f0f0f, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm13" & LF
               & "movq 88(%%rdi), %%rax" & LF
               & "vmovdqu (%%rax), %%xmm14" & LF
               & "cmpq $2, %%rcx" & LF
               & "jb 2f" & LF
               & "1:" & LF
               & "vmovdqu 2(%%r8), %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm9" & LF
               & "vpshufb %%xmm9, %%xmm14, %%xmm9" & LF
               & "vpsrlw $4, %%xmm8, %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm8" & LF
               & "vpshufb %%xmm8, %%xmm14, %%xmm8" & LF
               & "vinserti128 $1, %%xmm8, %%ymm9, %%ymm8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "addq $18, %%r8" & LF
               & "vmovdqu 2(%%r8), %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm9" & LF
               & "vpshufb %%xmm9, %%xmm14, %%xmm9" & LF
               & "vpsrlw $4, %%xmm8, %%xmm8" & LF
               & "vpand %%xmm13, %%xmm8, %%xmm8" & LF
               & "vpshufb %%xmm8, %%xmm14, %%xmm8" & LF
               & "vinserti128 $1, %%xmm8, %%ymm9, %%ymm8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpsignb %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpabsb %%ymm9, %%ymm11" & LF
               & "vpxor %%ymm9, %%ymm9, %%ymm9" & LF
               & "vpdpbusd %%ymm10, %%ymm11, %%ymm9" & LF
               & "vcvtdq2ps %%ymm9, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "addq $18, %%r8" & LF
               & "subq $2, %%rcx" & LF
               & "cmpq $2, %%rcx" & LF
               & "jae 1b" & LF
               & "2:" & LF
               & "3:" & LF
               & "movq 80(%%rdi), %%rdx" & LF
               & "vaddps %%ymm1, %%ymm0, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 0(%%rdx)" & LF
               & "vaddps %%ymm3, %%ymm2, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 4(%%rdx)" & LF
               & "vzeroupper",
               Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
               Clobber => "rax,rbx,rcx,rdx,rdi,r8,r9,r10,r11,r12,r13,r14,r15,"
                 & "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory", Volatile => True);
            else
            System.Machine_Code.Asm
              ("movq %0, %%rdi" & LF
               & "movq 0(%%rdi), %%r8" & LF
               & "movq 8(%%rdi), %%rcx" & LF
               & "movq 16(%%rdi), %%r9" & LF
               & "movq 24(%%rdi), %%r10" & LF
               & "movq 32(%%rdi), %%r11" & LF
               & "movq 40(%%rdi), %%r12" & LF
               & "movq 48(%%rdi), %%r13" & LF
               & "movq 56(%%rdi), %%r14" & LF
               & "movq 64(%%rdi), %%r15" & LF
               & "movq 72(%%rdi), %%rbx" & LF
               & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
               & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
               & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
               & "movl $0x03030303, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm13" & LF
               & "movl $0x01010101, %%eax" & LF
               & "vpbroadcastd %%eax, %%ymm15" & LF
               & "cmpq $2, %%rcx" & LF
               & "jb 2f" & LF
               & "1:" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "addq $18, %%r8" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm1" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm3" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "addq $18, %%r8" & LF
               & "subq $2, %%rcx" & LF
               & "cmpq $2, %%rcx" & LF
               & "jae 1b" & LF
               & "2:" & LF
               & "testq %%rcx, %%rcx" & LF
               & "jz 3f" & LF
               & "vpbroadcastw (%%r8), %%xmm12" & LF
               & "vcvtph2ps %%xmm12, %%xmm12" & LF
               & "vpmovzxbd 2(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "vpmovzxbd 10(%%r8), %%ymm8" & LF
               & "vpslld $12, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpslld $6, %%ymm8, %%ymm9" & LF
               & "vpor %%ymm9, %%ymm8, %%ymm8" & LF
               & "vpand %%ymm13, %%ymm8, %%ymm8" & LF
               & "vmovdqu (%%r9), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r13), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm0" & LF
               & "addq $32, %%r9" & LF
               & "addq $4, %%r13" & LF
               & "vmovdqu (%%r10), %%ymm9" & LF
               & "vpxor %%ymm10, %%ymm10, %%ymm10" & LF
               & "vpxor %%ymm11, %%ymm11, %%ymm11" & LF
               & "vpdpbusd %%ymm9, %%ymm8, %%ymm10" & LF
               & "vpdpbusd %%ymm9, %%ymm15, %%ymm11" & LF
               & "vpsubd %%ymm11, %%ymm10, %%ymm10" & LF
               & "vcvtdq2ps %%ymm10, %%ymm10" & LF
               & "vmulss (%%r14), %%xmm12, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "vfmadd231ps %%ymm11, %%ymm10, %%ymm2" & LF
               & "addq $32, %%r10" & LF
               & "addq $4, %%r14" & LF
               & "addq $18, %%r8" & LF
               & "3:" & LF
               & "movq 80(%%rdi), %%rdx" & LF
               & "vaddps %%ymm1, %%ymm0, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 0(%%rdx)" & LF
               & "vaddps %%ymm3, %%ymm2, %%ymm8" & LF
               & "vextractf128 $1, %%ymm8, %%xmm9" & LF
               & "vaddps %%xmm8, %%xmm9, %%xmm8" & LF
               & "vmovhlps %%xmm8, %%xmm8, %%xmm9" & LF
               & "vaddps %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovshdup %%xmm8, %%xmm9" & LF
               & "vaddss %%xmm9, %%xmm8, %%xmm8" & LF
               & "vmovss %%xmm8, 4(%%rdx)" & LF
               & "vzeroupper",
               Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
               Clobber => "rax,rbx,rcx,rdx,rdi,r8,r9,r10,r11,r12,r13,r14,r15,"
                 & "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory", Volatile => True);
            end if;
         end if;
      end Few;
   begin
      Ok := False;
      if Rows = 0 or else Blocks = 0 or else Count = 0
        or else Blocks > Element_Count'Last / Per or else First mod 32 /= 0
        or else ((Count > 1 or else Input_Members'Length /= 0) and then Stride mod 32 /= 0)
        or else (Input_Members'Length /= 0 and then Input_Members'Length /= Count)
        or else (Target = null and then Rows > Sums'Length / Count)
        or else (Format = G.Type_IQ4_NL and then Blocks mod 2 /= 0)
      then return; end if;
      Columns := Blocks * Per;
      Reach := 0;
      for I in 0 .. Count - 1 loop Reach := Element_Count'Max (Reach, Source_Row (I)); end loop;
      if Stride /= 0 and then Reach > (Element_Count'Last - First) / Stride then return; end if;
      Reach := First + Reach * Stride;
      if Reach > Element_Count'Last - Columns or else Values'Length < Reach + Columns
        or else Scales'Length < Reach / 32 + Columns / 32
        or else Blocks > Element_Count (B.Byte_Count'Last / 18)
      then return; end if;
      Required := B.Byte_Count (Blocks) * 18;
      if Row_Bytes < Required or else Offset > Data'Length
        or else Required > Data'Length - Offset
        or else B.Byte_Count (Rows - 1) > (Data'Length - Offset - Required) / Row_Bytes
      then return; end if;
      if Target /= null then
         if Result_Stride = 0 or else Rows > Result_Stride or else Result_First > Result_Stride - Rows
           or else (Result_Members'Length /= 0 and then Result_Members'Length /= Count)
         then return; end if;
         if Result_Members'Length = 0 then
            if Count > Target.all'Length / Result_Stride then return; end if;
         else
            for I in Result_Members'Range loop
               if Element_Count (Result_Members (I)) >= Target.all'Length / Result_Stride then return; end if;
               for J in Result_Members'First .. I - 1 loop
                  if Result_Members (I) = Result_Members (J) then return; end if;
               end loop;
            end loop;
         end if;
      end if;
      for Row in 0 .. Rows - 1 loop
         declare
            Vector : Element_Count := 0;
         begin
         while Vector < Count loop
            if Count - Vector >= 2 then
               declare
                  Taken : constant Positive := (if Count - Vector >= 4 then 4 else 2);
                  Results : N.Real_Array (0 .. 3);
                  At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
               begin
                  Few (At_Byte, Vector, Taken, Results);
                  for I in Element_Count range 0 .. Element_Count (Taken) - 1 loop
                     Put (Row, Vector + I, Results (I));
                  end loop;
                  Vector := Vector + Element_Count (Taken);
               end;
            else
            declare
               At_Byte : constant B.Byte_Count := Data'First + Offset + B.Byte_Count (Row) * Row_Bytes;
               At_Value : constant Element_Count := Values'First + First + Source_Row (Vector) * Stride;
               At_Scale : constant Element_Count := Scales'First + (First + Source_Row (Vector) * Stride) / 32;
            begin
               if Format = G.Type_IQ4_NL then
               System.Machine_Code.Asm
                 ("movq %1, %%r8" & LF
                  & "movq %2, %%r9" & LF
                  & "movq %3, %%r10" & LF
                  & "movq %4, %%r11" & LF
                  & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
                  & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
                  & "movl $0x0f0f0f0f, %%eax" & LF
                  & "vpbroadcastd %%eax, %%ymm7" & LF
                  & "vmovdqu (%5), %%xmm8" & LF
                  & "cmpq $2, %%r11" & LF
                  & "jb 2f" & LF
                  & "1:" & LF
                  & "vmovdqu 2(%%r8), %%xmm2" & LF
                  & "vpand %%xmm7, %%xmm2, %%xmm3" & LF
                  & "vpshufb %%xmm3, %%xmm8, %%xmm3" & LF
                  & "vpsrlw $4, %%xmm2, %%xmm2" & LF
                  & "vpand %%xmm7, %%xmm2, %%xmm2" & LF
                  & "vpshufb %%xmm2, %%xmm8, %%xmm2" & LF
                  & "vinserti128 $1, %%xmm2, %%ymm3, %%ymm2" & LF
                  & "vmovdqu (%%r9), %%ymm3" & LF
                  & "vpsignb %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpabsb %%ymm3, %%ymm5" & LF
                  & "vpxor %%ymm3, %%ymm3, %%ymm3" & LF
                  & "vpdpbusd %%ymm4, %%ymm5, %%ymm3" & LF
                  & "vcvtdq2ps %%ymm3, %%ymm4" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vmulss (%%r10), %%xmm6, %%xmm6" & LF
                  & "vbroadcastss %%xmm6, %%ymm6" & LF
                  & "vfmadd231ps %%ymm6, %%ymm4, %%ymm0" & LF
                  & "addq $18, %%r8" & LF
                  & "addq $32, %%r9" & LF
                  & "addq $4, %%r10" & LF
                  & "vmovdqu 2(%%r8), %%xmm2" & LF
                  & "vpand %%xmm7, %%xmm2, %%xmm3" & LF
                  & "vpshufb %%xmm3, %%xmm8, %%xmm3" & LF
                  & "vpsrlw $4, %%xmm2, %%xmm2" & LF
                  & "vpand %%xmm7, %%xmm2, %%xmm2" & LF
                  & "vpshufb %%xmm2, %%xmm8, %%xmm2" & LF
                  & "vinserti128 $1, %%xmm2, %%ymm3, %%ymm2" & LF
                  & "vmovdqu (%%r9), %%ymm3" & LF
                  & "vpsignb %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpabsb %%ymm3, %%ymm5" & LF
                  & "vpxor %%ymm3, %%ymm3, %%ymm3" & LF
                  & "vpdpbusd %%ymm4, %%ymm5, %%ymm3" & LF
                  & "vcvtdq2ps %%ymm3, %%ymm4" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vmulss (%%r10), %%xmm6, %%xmm6" & LF
                  & "vbroadcastss %%xmm6, %%ymm6" & LF
                  & "vfmadd231ps %%ymm6, %%ymm4, %%ymm1" & LF
                  & "addq $18, %%r8" & LF
                  & "addq $32, %%r9" & LF
                  & "addq $4, %%r10" & LF
                  & "subq $2, %%r11" & LF
                  & "cmpq $2, %%r11" & LF
                  & "jae 1b" & LF
                  & "2:" & LF
                  & "3:" & LF
                  & "vaddps %%ymm1, %%ymm0, %%ymm0" & LF
                  & "vextractf128 $1, %%ymm0, %%xmm1" & LF
                  & "vaddps %%xmm0, %%xmm1, %%xmm0" & LF
                  & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                  & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovshdup %%xmm0, %%xmm1" & LF
                  & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovss %%xmm0, %0" & LF
                  & "vzeroupper",
                  Outputs => N.Real'Asm_Output ("=m", Result),
                  Inputs => [System.Address'Asm_Input ("r", Data (At_Byte)'Address),
                             System.Address'Asm_Input ("r", Values (At_Value)'Address),
                             System.Address'Asm_Input ("r", Scales (At_Scale)'Address),
                             Element_Count'Asm_Input ("r", Blocks),
                             System.Address'Asm_Input ("r", Levels'Address)],
                  Clobber => "rax,r8,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,"
                    & "ymm7,ymm8,ymm9,ymm10,cc,memory", Volatile => True);
               else
               System.Machine_Code.Asm
                 ("movq %1, %%r8" & LF
                  & "movq %2, %%r9" & LF
                  & "movq %3, %%r10" & LF
                  & "movq %4, %%r11" & LF
                  & "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
                  & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
                  & "movl $0x03030303, %%eax" & LF
                  & "vpbroadcastd %%eax, %%ymm7" & LF
                  & "movl $0x01010101, %%eax" & LF
                  & "vpbroadcastd %%eax, %%ymm9" & LF
                  & "cmpq $2, %%r11" & LF
                  & "jb 2f" & LF
                  & "1:" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vpmovzxbd 2(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 0(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 0(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm0" & LF
                  & "vpmovzxbd 10(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 32(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 4(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm0" & LF
                  & "addq $18, %%r8" & LF
                  & "addq $64, %%r9" & LF
                  & "addq $8, %%r10" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vpmovzxbd 2(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 0(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 0(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm1" & LF
                  & "vpmovzxbd 10(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 32(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 4(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm1" & LF
                  & "addq $18, %%r8" & LF
                  & "addq $64, %%r9" & LF
                  & "addq $8, %%r10" & LF
                  & "subq $2, %%r11" & LF
                  & "cmpq $2, %%r11" & LF
                  & "jae 1b" & LF
                  & "2:" & LF
                  & "testq %%r11, %%r11" & LF
                  & "jz 3f" & LF
                  & "vpbroadcastw (%%r8), %%xmm6" & LF
                  & "vcvtph2ps %%xmm6, %%xmm6" & LF
                  & "vpmovzxbd 2(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 0(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 0(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm0" & LF
                  & "vpmovzxbd 10(%%r8), %%ymm2" & LF
                  & "vpslld $12, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpslld $6, %%ymm2, %%ymm3" & LF
                  & "vpor %%ymm3, %%ymm2, %%ymm2" & LF
                  & "vpand %%ymm7, %%ymm2, %%ymm2" & LF
                  & "vmovdqu 32(%%r9), %%ymm3" & LF
                  & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
                  & "vpxor %%ymm5, %%ymm5, %%ymm5" & LF
                  & "vpdpbusd %%ymm3, %%ymm2, %%ymm4" & LF
                  & "vpdpbusd %%ymm3, %%ymm9, %%ymm5" & LF
                  & "vpsubd %%ymm5, %%ymm4, %%ymm4" & LF
                  & "vcvtdq2ps %%ymm4, %%ymm4" & LF
                  & "vmulss 4(%%r10), %%xmm6, %%xmm10" & LF
                  & "vbroadcastss %%xmm10, %%ymm10" & LF
                  & "vfmadd231ps %%ymm10, %%ymm4, %%ymm0" & LF
                  & "addq $18, %%r8" & LF
                  & "addq $64, %%r9" & LF
                  & "addq $8, %%r10" & LF
                  & "3:" & LF
                  & "vaddps %%ymm1, %%ymm0, %%ymm0" & LF
                  & "vextractf128 $1, %%ymm0, %%xmm1" & LF
                  & "vaddps %%xmm0, %%xmm1, %%xmm0" & LF
                  & "vmovhlps %%xmm0, %%xmm0, %%xmm1" & LF
                  & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovshdup %%xmm0, %%xmm1" & LF
                  & "vaddss %%xmm1, %%xmm0, %%xmm0" & LF
                  & "vmovss %%xmm0, %0" & LF
                  & "vzeroupper",
                  Outputs => N.Real'Asm_Output ("=m", Result),
                  Inputs => [System.Address'Asm_Input ("r", Data (At_Byte)'Address),
                             System.Address'Asm_Input ("r", Values (At_Value)'Address),
                             System.Address'Asm_Input ("r", Scales (At_Scale)'Address),
                             Element_Count'Asm_Input ("r", Blocks),
                             System.Address'Asm_Input ("r", Levels'Address)],
                  Clobber => "rax,r8,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,"
                    & "ymm7,ymm8,ymm9,ymm10,cc,memory", Volatile => True);
               end if;
               Put (Row, Vector, Result);
            end;
            Vector := Vector + 1;
            end if;
         end loop;
         end;
      end loop;
      Ok := True;
   end Small_Block_Rows;

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
      Halves    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean;
      Interleaved : Boolean := False;
      Reference_Arithmetic : Boolean := False;
      Metadata : N.Real_Array := []) is
      use type Model_Runner.Bytes.Byte_Count;
   begin
      if Deeper and then not Interleaved and then Format in G.Type_IQ4_NL | G.Type_Q2_0 then
         Small_Block_Rows (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                           First, Stride, Count, Sums, Ok);
         return;
      end if;
      --  Prefetch valid following compressed rows without changing arithmetic.
      if Reference_Arithmetic and then Deeper and then not Interleaved
        and then Format in Model_Runner.GGUF.Type_Q4_K | Model_Runner.GGUF.Type_Q6_K
        and then Rows > 0 and then Row_Bytes > 0 and then Offset < Data'Length
        and then Row_Bytes <= (Data'Length - Offset) / Model_Runner.Bytes.Byte_Count (Rows)
      then
         declare
            Next_Row : constant Model_Runner.Bytes.Byte_Count :=
              Offset + Row_Bytes * Model_Runner.Bytes.Byte_Count (Rows);
         begin
            if Data'Length - Next_Row > 256 then
               System.Machine_Code.Asm
                 ("prefetcht0 (%0)" & ASCII.LF & "prefetcht0 64(%0)" & ASCII.LF
                  & "prefetcht0 128(%0)" & ASCII.LF & "prefetcht0 192(%0)",
                  Inputs => System.Address'Asm_Input ("r", Data (Data'First + Next_Row)'Address),
                  Volatile => True);
            end if;
         end;
      end if;
      if Reference_Arithmetic and then Deeper
        --  The deep compilation selects streaming or staged byte tiles
        --  from the native format, vector count and block width.
        and then Format in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K | G.Type_Q8_0 | G.Type_Q5_0
      then
         Deep.Rows (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales, Totals, Halves,
                    First, Stride, Count, Sums, Ok, Interleaved, Reference_Arithmetic => True, Metadata => Metadata);
         return;
      end if;
      if Reference_Arithmetic and then not Interleaved and then (Wider or Deeper)
        and then Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q5_0)
      then
         Reference_Q50 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                        First, Stride, Count, Sums, Ok);
         return;
      end if;
      if Reference_Arithmetic and then not Interleaved and then (Wider or Deeper)
        and then Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q5_K)
      then
         Reference_Q4 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                       Totals, First, Stride, Count, Sums, Ok, Fifth => True);
         return;
      end if;
      if Reference_Arithmetic and then not Interleaved and then (Wider or Deeper)
        and then Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q6_K)
      then
         Reference_Q6 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                       Halves, First, Stride, Count, Sums, Ok);
         return;
      end if;
      if Reference_Arithmetic and then not Interleaved and then (Wider or Deeper)
        and then Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q4_K)
      then
         Reference_Q4 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                       Totals, First, Stride, Count, Sums, Ok);
         return;
      end if;
      if Reference_Arithmetic and then not Interleaved and then (Wider or Deeper)
        and then Model_Runner.GGUF."=" (Format, Model_Runner.GGUF.Type_Q8_0)
      then
         Reference_Q8 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                       First, Stride, Count, Sums, Ok);
         return;
      end if;
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
            Totals, Halves, First, Stride, Count, Sums, Ok, Interleaved);
      elsif Wider then
         Wide.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, Halves, First, Stride, Count, Sums, Ok, Interleaved);
      else
         Plain.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, Halves, First, Stride, Count, Sums, Ok, Interleaved);
      end if;
   end Accumulate_Rows;

end Model_Runner.Quantization.Integers;
