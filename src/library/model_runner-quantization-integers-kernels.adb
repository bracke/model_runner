with Ada.Unchecked_Conversion;

with System;
with System.Machine_Code;

with Model_Runner.Quantization.Interleave;

package body Model_Runner.Quantization.Integers.Kernels is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Unsigned_8;
   use type B.Byte_Count;
   use type G.Tensor_Type;
   use type N.Real;
   use type N.Wide_Real;
   use type Interfaces.Unsigned_32;

   --  One block's scale, widened from the two bytes the file holds it in.
   --
   --  The portable widening in Model_Runner.Numerics computes the normal
   --  case and the subnormal case and selects between them -- about sixteen
   --  instructions of shifting, masking and two multiplies, and it has to
   --  be, because Ada has no half-precision type and the source is bit
   --  arithmetic rather than a conversion the compiler can recognise.
   --
   --  Both wider compilations are built for instruction sets that have
   --  F16C, whose VCVTPH2PS does the whole of it in one instruction and
   --  exactly -- subnormals, infinities and not-a-number included, which is
   --  what lets the test comparing the compilations still ask for the same
   --  bits. Two instructions here against sixteen, on a scale read once for
   --  every row and block of every strip: a profile put that widening at
   --  most of the quarter of the strip kernel that was neither the byte dot
   --  product nor the arithmetic around it.
   --
   --  The baseline compilation keeps the portable form, because it is the
   --  one that runs where the host said it had none of this. Wider is a
   --  static generic formal, so the test below is not a test at run time.
   function Scale_At
     (Data : B.Byte_Array;
      Here : B.Byte_Index) return N.Real
     with Inline;

   --  A byte read as the signed number it holds.
   --
   --  The six-bit k-quant keeps a sub-block's scale as a signed byte, and
   --  reading it as unsigned and correcting with a test puts a branch in a
   --  loop of sixteen -- which a profile found among the hottest
   --  instructions here, and which is what stops the loop being lanes.
   function To_Signed (Raw : Interfaces.Unsigned_8) return Interfaces.Integer_8
   is (if Raw < 128
       then Interfaces.Integer_8 (Raw)
       else Interfaces.Integer_8 (Integer (Raw) - 256))
     with Inline_Always;

   --  Not merely Inline. Taking the block size out of the driver's scale
   --  loop left the loop tight enough that the compiler stopped inlining
   --  this and gave it a symbol of its own, and a profile found it there
   --  costing what the call it replaced had cost: a two-byte load, an or, a
   --  move and a convert, behind a call and a return.
   pragma Inline_Always (Scale_At);

   function Scale_At
     (Data : B.Byte_Array;
      Here : B.Byte_Index) return N.Real
   is
      Bits : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Data (Here))
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (Data (Here + 1)), 8);
   begin
      if Wider then
         declare
            LF     : constant Character := ASCII.LF;
            Result : N.Real;
         begin
            --  Not volatile: it reads its operand and writes its answer and
            --  does nothing else, so the compiler may hoist it, fold two of
            --  them together, or drop one whose answer goes unread.
            System.Machine_Code.Asm
              ("vmovd %1, %0" & LF
               & "vcvtph2ps %0, %0",
               Outputs => N.Real'Asm_Output ("=x", Result),
               Inputs  => Interfaces.Unsigned_32'Asm_Input ("r", Bits));

            return Result;
         end;
      else
         return N.To_Real (N.Half (Interfaces.Unsigned_16 (Bits)));
      end if;
   end Scale_At;

   --  One vector against a tile of rows, with the block loop inside.
   --
   --  Written separately from Rows because it is a different shape rather
   --  than a different instruction: there, a block is loaded, multiplied and
   --  its result put back to memory before the next one; here a row's whole
   --  run of blocks is one insertion and the accumulator is a register from
   --  the first block to the last. The caller has already established that
   --  every index below is in range.
   --
   --  Only for one vector. With two the accumulators double, with a hundred
   --  and twenty-eight there are a thousand of them and no register file
   --  holds that -- which is why a prompt cannot have this and needs the
   --  weights packed into cache-sized panels instead.
   --  The eight partial sums a byte dot product leaves, which both
   --  insertions below keep in a register across a whole row and reduce
   --  once at the end of it. Thirty-two bytes, aligned to thirty-two,
   --  because they are stored with an aligned move.
   type Lanes_8 is array (0 .. 7) of N.Real with Alignment => 32;

   --  A block's two scales, side by side, so that the unpack below reaches
   --  both from one address and broadcasts them without a second operand.
   type Lanes_2 is array (0 .. 1) of N.Real with Alignment => 8;

   --  The three masks the k-quant scale unpack works with, kept here so
   --  that the block below broadcasts them from memory rather than
   --  building them again for every one of a row's blocks.
   Unpack_Masks : constant array (0 .. 2) of Interfaces.Unsigned_32 :=
     [16#3F3F_3F3F#, 16#0F0F_0F0F#, 16#3030_3030#];

   --  Each of eight numbers taken twice, in order.
   --
   --  A six-bit k-quant keeps a scale for every sixteen elements and the
   --  activation keeps one for every thirty-two, so two of the weight's
   --  halves share one of the activation's scales. Read as eight and
   --  permuted by this, the eight become the sixteen the halves want
   --  without a loop.
   --  A whole number in both halves of a thirty-two bit word, which is
   --  what the sixteen-bit multiply-accumulate wants of a scale that is the
   --  same for both of the pairs it folds.
   function To_Signed_32 is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_32, Interfaces.Integer_32);

   function Twice (Value : Integer) return Interfaces.Integer_32;

   function Twice (Value : Integer) return Interfaces.Integer_32 is
      Half : constant := 16;

      --  Biased into range before the conversion, because the value is
      --  signed and the type it goes through is not.
      Low : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value + 2 ** Half)
        and Interfaces.Unsigned_32 (2 ** Half - 1);
   begin
      return To_Signed_32 (Low or Interfaces.Shift_Left (Low, 16));
   end Twice;

   Doubling : constant array (0 .. 15) of Interfaces.Unsigned_32 :=
     [0, 0, 1, 1, 2, 2, 3, 3,
      4, 4, 5, 5, 6, 6, 7, 7];

   --  One vector against a tile of rows, for the four-bit k-quant.
   procedure Rows_Singly_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  One vector against a tile of rows, for the six-bit k-quant.
   procedure Rows_Singly_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      --  The activation summed over every sixteen, from the quantizer.
      --  This kernel used to form these itself, once for every row tile.
      Half_Sums : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  Two rows against four vectors, for the six-bit k-quant.
   procedure Rows_By_Strips_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      Steps     : Model_Runner.Numerics.Real_Array;

      --  The half's signed scale as a whole number, held twice in the
      --  thirty-two bits, and the block's own scale apart from it.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;

      --  The activation summed over every sixteen, from the quantizer.
      Half_Sums : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  A panel of eight rows against a strip of eight vectors, for the
   --  five-bit k-quant laid out a panel at a time.
   procedure Rows_By_Panels_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  A panel of eight rows against a strip of eight vectors, for the
   --  six-bit k-quant laid out a panel at a time.
   procedure Rows_By_Panels_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Halves    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  A panel of eight rows against a strip of eight vectors, for the
   --  legacy four-bit format laid out a panel at a time.
   procedure Rows_By_Panels_Q40
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  A panel of eight rows against a strip of eight vectors, for the
   --  four-bit k-quant laid out a panel at a time.
   procedure Rows_By_Panels_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  Two rows against four vectors, for the four-bit k-quant.
   procedure Rows_By_Strips_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      --  The sub-block factor as a whole number, held twice in the
      --  thirty-two bits, and the block's own scale. The factor multiplies
      --  the integer dot product and the scale is applied once a
      --  super-block, so neither is folded into the other and the table
      --  below has an entry for every sub-block and row rather than for
      --  every sub-block, row and vector.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;
      Downs     : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  One vector against a tile of rows, for the five-bit k-quant.
   procedure Rows_Singly_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  Two rows against four vectors, for the five-bit k-quant.
   procedure Rows_By_Strips_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      --  As for the four-bit strip: the factor as a whole number held twice
      --  in the thirty-two bits, and the block's own scale apart from it.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;
      Downs     : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  Two rows against four vectors, with the block loop inside the
   --  insertion. Only for the byte dot product.
   --
   --  @param Weights The weight side of every scale, one for each row and
   --    block of the tile, row major. Handed in rather than read here
   --    because it is the same for every strip and there are as many strips
   --    as the batch is long divided by four: reading it here decoded a
   --    half-precision number twenty-eight times over on a 110-token
   --    prompt, and the counter said so.
   procedure Rows_By_Strips
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Weights   : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   --  The same, four vectors wide, for the three to seven a strip of
   --  eight cannot reach. A batch is 128 and divides by eight; the last
   --  batch of a prompt is whatever is left of it, and sending four of
   --  those through the single-vector kernel instead cost a sixth of a
   --  six-token prompt and moved its answer.
   procedure Rows_By_Strips_Four
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Weights   : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean);

   procedure Rows_Singly
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      First     : Element_Count;

      --  Where this call's answers go and how far apart they lie. A
      --  generated token has one vector and one answer a row, so the two
      --  are zero and one; called for one vector of a batch they are that
      --  vector's place and the batch's length, because a batch keeps its
      --  answers a row at a time with the vectors inside.
      At_Sum    : Element_Count;
      Sum_Step  : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array);

   procedure Rows_Singly
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      First     : Element_Count;
      At_Sum    : Element_Count;
      Sum_Step  : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      --  Eight partial sums, reduced once when the row is done.
      Landed : Lanes_8 := [others => 0.0];
   begin
      for Row in 0 .. Rows - 1 loop
         declare
            Base : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (Row);
         begin
            Landed := [others => 0.0];

            --  The whole row: a running accumulator in a register, one
            --  multiply-add a block, and nothing written until the end.
            --
            --  The byte instruction reads its first operand as unsigned
            --  and a weight is signed, and there are two ways to give it
            --  one. The bias -- add a hundred and twenty-eight to every
            --  weight, and take a hundred and twenty-eight times the
            --  activation's block total back off at the end -- is what
            --  this kernel did, and it cost a second loop over the blocks:
            --  a widening of the block's total to binary64, the scale
            --  written to a table, read back, widened again, and a serial
            --  multiply-add into a running correction. Eighteen
            --  instructions a block, where the dot product itself is ten.
            --
            --  The other way is to move the weight's sign onto the
            --  activation instead. VPSIGNB negates a byte where the
            --  controlling byte is negative, zeroes it where that byte is
            --  zero, and leaves it alone otherwise: applied to the weight
            --  by itself it gives the magnitude, which is the unsigned
            --  operand, and applied to the activation by the weight it
            --  gives the signed one. Two instructions, and the whole
            --  correction goes -- no table, no second loop, no binary64
            --  chain, and the scale is worked out where it is used.
            --
            --  It also drops a term that was cancelling. The bias put a
            --  hundred and twenty-eight times the activation total into a
            --  binary32 accumulator and took it out again in binary64
            --  afterwards, and that term is routinely larger than the
            --  answer: this is fewer instructions and closer to the
            --  reference at the same time. The digests move once, and the
            --  conformance sweep is what says which way.
            --
            --  What VPSIGNB cannot represent is a weight applied to an
            --  activation of minus a hundred and twenty-eight, which
            --  negates to itself. The activation quantizer clamps to minus
            --  a hundred and twenty-seven so that value does not exist; a
            --  weight of minus a hundred and twenty-eight is fine, because
            --  its magnitude read as unsigned is a hundred and
            --  twenty-eight, which is what it should be.
            System.Machine_Code.Asm
              ("vpxor %%ymm6, %%ymm6, %%ymm6"        & LF &
               "xorq %%rcx, %%rcx"                   & LF &
               "xorq %%rdx, %%rdx"                   & LF &
               "movq %4, %%rax"                      & LF &
               "1:"                                  & LF &
               "vmovdqu 2(%1,%%rdx,1), %%ymm0"       & LF &
               "vpsignb %%ymm0, %%ymm0, %%ymm3"      & LF &
               "vmovdqu (%2,%%rcx,8), %%ymm4"        & LF &
               "vpsignb %%ymm0, %%ymm4, %%ymm4"      & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1"        & LF &
               "vpdpbusd %%ymm4, %%ymm3, %%ymm1"     & LF &
               "vcvtdq2ps %%ymm1, %%ymm1"            & LF &
               "vpbroadcastw (%1,%%rdx,1), %%xmm5"   & LF &
               "vcvtph2ps %%xmm5, %%ymm5"            & LF &
               "vbroadcastss (%3,%%rcx,1), %%ymm2"   & LF &
               "vmulps %%ymm5, %%ymm2, %%ymm2"       & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6"  & LF &
               "addq $4, %%rcx"                      & LF &
               "addq $34, %%rdx"                     & LF &
               "decq %%rax"                          & LF &
               "jnz 1b"                              & LF &
               "vmovaps %%ymm6, (%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First)'Address),
                  System.Address'Asm_Input
                    ("r",
                     Scales
                       (Scales'First + First / Activation_Block)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + At_Sum + Row * Sum_Step) :=
                 Sums (Sums'First + At_Sum + Row * Sum_Step) + Total;
            end;
         end;
      end loop;
   end Rows_Singly;

   ---------------------
   -- Rows_By_Strips --
   ---------------------

   --  What Rows_Singly does for one vector, done for four at a time.
   --
   --  The single-vector kernel keeps a row's accumulator in a register from
   --  its first block to its last, reads the weights where the file holds
   --  them, and takes the bias correction out once for the whole row. A
   --  batch could not have any of that while it kept one accumulator for
   --  every row and every vector at once -- a hundred and twenty-eight
   --  vectors against eight rows is a thousand accumulators and no register
   --  file holds that. A strip of four does: two rows against four vectors
   --  is eight accumulators, and this instruction set has thirty-two
   --  registers to keep them in.
   --
   --  So the batch is swept a strip at a time instead, and what the strip
   --  costs per row, vector and block is five instructions where the shape
   --  it replaces cost twelve and a half:
   --
   --    four   the two indices, the counter and the branch
   --    four   the two rows' weights, loaded and biased -- shared by the
   --           four vectors, which is what a strip is for
   --    thirty-two  a zeroed accumulator, the byte dot product against the
   --           activation where the quantizer left it, a convert, and one
   --           fused multiply-add whose scale is broadcast out of memory by
   --           the instruction itself rather than by an instruction before
   --           it
   --
   --  No panel is packed and none is needed: two rows of this model are
   --  under five kilobytes, so a panel stays in the nearest cache across
   --  every strip of the batch, and the order of the loops is the packing.
   procedure Rows_By_Strips
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Weights   : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Panel_Rows : constant := 2;
      Strip      : constant := 8;

      --  As in Rows_Singly: the widest row this reads, so that nothing is
      --  allocated inside a loop.
      Scale_Room : constant := 1024;

      --  Both scales multiplied together for every row of the panel, vector
      --  of the strip and block of the row, laid out with the block outside
      --  so that one index register walks it beside the activations. Sixteen
      --  numbers a block, which is sixty-four bytes -- twice the step the
      --  activations take, which is why the index register carrying it is
      --  scaled by two and there are still only two of them.
      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1) of N.Real;
      --  Not initialized. Every entry the insertion reads is written by
      --  the loop below, and giving it a value first was sixteen per cent
      --  of a prompt spent in memset -- sixty-four kilobytes zeroed for
      --  every strip of four vectors, which a profile found and no reading
      --  of the source would have.
      Scaling : Strip_Scales;

      --  Where each vector of the strip keeps its scales, the scale itself,
      --  and the block total the bias correction wants. Eight numbers a
      --  block for the last two, which is the same thirty-two byte step the
      --  activations take.
      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Scale_Room - 1) of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;
      Vector_Total : Vector_Numbers;

      --  Sixteen sums and sixteen corrections, all thirty-two folded by the
      --  insertion rather than by a loop here. The corrections need no fold
      --  at all: a row's eight of them are the eight lanes of one
      --  accumulator, one to a vector, and go out as one store.
      type Landing is array (0 .. 2 * Panel_Rows * Strip - 1) of N.Real
        with Alignment => 32;
      Landed : Landing;

      --  What separates the strip's fifth vector from its first, in bytes.
      --  Four pointers reach eight vectors: the second index register
      --  starts here and steps beside the first, which is what keeps this
      --  shape inside the general-purpose registers a machine has.
      Vector_Step : Interfaces.Unsigned_64;

      Block_Count : Interfaces.Unsigned_64;

   begin
      Taken := False;

      if Blocks > Scale_Room or else Rows mod Panel_Rows /= 0 then
         return;
      end if;

      Block_Count := Interfaces.Unsigned_64 (Blocks);

      --  What the strip's eight vectors contribute, worked out once for the
      --  whole call rather than once for every row panel: where each
      --  vector's scales begin, the scale itself, and the block total the
      --  bias correction wants, already narrowed. Every one of these is the
      --  same for every row, and leaving them in the innermost loop cost
      --  about as much as the insertion saved -- which is what the counter
      --  said the first time this was built.
      for Vector in Element_Count range 0 .. Strip - 1 loop
         Vector_At (Natural (Vector)) :=
           (First + (At_Vector + Vector) * Stride) / Activation_Block;
      end loop;

      --  A quantized activation is one byte, so the distance in bytes is
      --  the distance in elements.
      Vector_Step := Interfaces.Unsigned_64 (4 * Stride);

      for Vector in 0 .. Strip - 1 loop
         for Block in 0 .. Blocks - 1 loop
            declare
               At_Scale : constant Element_Count :=
                 Vector_At (Vector) + Block;
            begin
               Vector_Scale (Natural (Block) * Strip + Vector) :=
                 Scales (Scales'First + At_Scale);
               Vector_Total (Natural (Block) * Strip + Vector) :=
                 N.Real (Totals (Totals'First + At_Scale));
            end;
         end loop;
      end loop;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            At_Row : constant Element_Count := Panel * Panel_Rows;
            Base   : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (At_Row);
         begin
            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     Scale : constant N.Real :=
                       Weights (Weights'First
                                + (At_Row + Row) * Blocks + Block);

                     At_Vec : constant Natural := Natural (Block) * Strip;
                     At_Out : constant Natural :=
                       Natural (Block) * (Panel_Rows * Strip)
                       + Natural (Row) * Strip;
                  begin
                     --  A map and nothing else. The correction that used
                     --  to share these turns is the insertion's now.
                     for Vector in 0 .. Strip - 1 loop
                        Scaling (At_Out + Vector) :=
                          Scale * Vector_Scale (At_Vec + Vector);
                     end loop;
                  end;
               end loop;
            end loop;

            System.Machine_Code.Asm
              ("movl $0x80808080, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %8, %%rax" & LF &
               "movq %10, %%rsi" & LF &
               "1:" & LF &
               "vmovdqu (%1,%%rcx,1), %%ymm0" & LF &
               "vpxor %%ymm3, %%ymm0, %%ymm0" & LF &
               "vmovdqu (%2,%%rcx,1), %%ymm1" & LF &
               "vpxor %%ymm3, %%ymm1, %%ymm1" & LF &

               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 0(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm8" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 4(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 8(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm10" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 12(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm11" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rsi,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 16(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rsi,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 20(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rsi,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 24(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rsi,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 28(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm15" & LF &

               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 32(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 36(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 40(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 44(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rsi,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 48(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rsi,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 52(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rsi,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 56(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rsi,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 60(%7,%%rdx,2)%{1to8%}, %%ymm2, %%ymm23" & LF &

               --  Both rows' corrections, one lane a vector, in four.
               "vmovups 0(%7,%%rdx,2), %%ymm4" & LF &
               "vfmadd231ps (%9,%%rdx,1), %%ymm4, %%ymm24" & LF &
               "vmovups 32(%7,%%rdx,2), %%ymm5" & LF &
               "vfmadd231ps (%9,%%rdx,1), %%ymm5, %%ymm25" & LF &

               "addq $34, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "addq $32, %%rsi" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &

               --  The corrections need no fold: eight lanes, one a vector.
               "vmovups %%ymm24, 64(%0)" & LF &
               "vmovups %%ymm25, 96(%0)" & LF &

               --  Eight accumulators a row down to eight numbers, by the
               --  same pairwise tree as before, run once for each row.
               "vhaddps %%ymm9, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm11, %%ymm10, %%ymm10" & LF &
               "vhaddps %%ymm13, %%ymm12, %%ymm12" & LF &
               "vhaddps %%ymm15, %%ymm14, %%ymm14" & LF &
               "vhaddps %%ymm10, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm14, %%ymm12, %%ymm12" & LF &
               "vextractf128 $1, %%ymm8, %%xmm1" & LF &
               "vaddps %%xmm1, %%xmm8, %%xmm8" & LF &
               "vextractf128 $1, %%ymm12, %%xmm5" & LF &
               "vaddps %%xmm5, %%xmm12, %%xmm12" & LF &
               "vmovups %%xmm8, 0(%0)" & LF &
               "vmovups %%xmm12, 16(%0)" & LF &

               --  The second row's eight live above the sixteenth register,
               --  which the horizontal add cannot encode, so they come down
               --  first. Once a panel, against a hundred and seventy-six
               --  blocks of work.
               "vmovaps %%ymm16, %%ymm8" & LF &
               "vmovaps %%ymm17, %%ymm9" & LF &
               "vmovaps %%ymm18, %%ymm10" & LF &
               "vmovaps %%ymm19, %%ymm11" & LF &
               "vmovaps %%ymm20, %%ymm12" & LF &
               "vmovaps %%ymm21, %%ymm13" & LF &
               "vmovaps %%ymm22, %%ymm14" & LF &
               "vmovaps %%ymm23, %%ymm15" & LF &
               "vhaddps %%ymm9, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm11, %%ymm10, %%ymm10" & LF &
               "vhaddps %%ymm13, %%ymm12, %%ymm12" & LF &
               "vhaddps %%ymm15, %%ymm14, %%ymm14" & LF &
               "vhaddps %%ymm10, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm14, %%ymm12, %%ymm12" & LF &
               "vextractf128 $1, %%ymm8, %%xmm1" & LF &
               "vaddps %%xmm1, %%xmm8, %%xmm8" & LF &
               "vextractf128 $1, %%ymm12, %%xmm5" & LF &
               "vaddps %%xmm5, %%xmm12, %%xmm12" & LF &
               "vmovups %%xmm8, 32(%0)" & LF &
               "vmovups %%xmm12, 48(%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base + 2)'Address),
                  System.Address'Asm_Input
                    ("r", Data (Base + Row_Bytes + 2)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + At_Vector * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 1) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 2) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 3) * Stride)'Address),
                  System.Address'Asm_Input ("r", Scaling (0)'Address),
                  Interfaces.Unsigned_64'Asm_Input ("m", Block_Count),
                  System.Address'Asm_Input ("r", Vector_Total (0)'Address),
                  Interfaces.Unsigned_64'Asm_Input ("m", Vector_Step)],
               Clobber  =>
                 "rax,rcx,rdx,rsi,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
                 & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                 & "ymm24,ymm25,memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Strip - 1 loop
                  declare
                     Which : constant Natural :=
                       Natural (Row) * Strip + Natural (Vector);
                     At_It : constant Element_Count :=
                       (At_Row + Row) * Count + At_Vector + Vector;
                  begin
                     --  Both already folded: the sum in the first sixteen
                     --  of Landed and the correction in the sixteen after.
                     Sums (Sums'First + At_It) :=
                       Sums (Sums'First + At_It)
                       + N.Wide_Real (Landed (Which))
                       - 128.0
                         * N.Wide_Real
                             (Landed (Panel_Rows * Strip + Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips;

   ------------------------
   -- Rows_By_Strips_Four --
   ------------------------

   procedure Rows_By_Strips_Four
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Weights   : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Panel_Rows : constant := 2;
      Strip      : constant := 4;

      --  As in Rows_Singly: the widest row this reads, so that nothing is
      --  allocated inside a loop.
      Scale_Room : constant := 1024;

      --  Both scales multiplied together for every row of the panel, vector
      --  of the strip and block of the row, laid out with the block outside
      --  so that one index register walks it beside the activations. Eight
      --  numbers a block, which is thirty-two bytes -- the same step the
      --  activations take, which is why there are two index registers here
      --  and not three.
      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1) of N.Real;
      --  Not initialized. Every entry the insertion reads is written by
      --  the loop below, and giving it a value first was sixteen per cent
      --  of a prompt spent in memset -- sixty-four kilobytes zeroed for
      --  every strip of four vectors, which a profile found and no reading
      --  of the source would have.
      Scaling : Strip_Scales;

      --  The bias the instruction's unsigned operand put in, taken out once
      --  for a whole row rather than added back on every block.
      --  Accumulated in binary32 rather than the wider form the
      --  single-vector kernel uses. It is a correction of about a
      --  thousandth of the sum it corrects; the sweep's bound is what says
      --  whether that is close enough, and it says it is.
      --  Both of them are the insertion's business now and neither is
      --  declared here: the sums land in the first eight of Landed and the
      --  corrections in the eight after them.

      --  Where each vector of the strip keeps its scales, and the two
      --  numbers read from there for every block of every row.
      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Scale_Room - 1) of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;

      --  The block's total, written twice over: eight to a block rather
      --  than four, so that a thirty-two byte read of it lines up lane for
      --  lane with the eight scales the insertion reads at the same block,
      --  the first four being the panel's first row and the second four
      --  its second. That is what lets one fused multiply-add a block
      --  accumulate all eight corrections at once.
      type Doubled_Numbers is
        array (0 .. 2 * Strip * Scale_Room - 1) of N.Real;
      Vector_Total : Doubled_Numbers;

      --  Eight sums and eight corrections, both folded by the insertion
      --  rather than by a loop here. What Ada did with these was a quarter
      --  of a prompt between them: the correction's array read-and-write
      --  became a shuffle network -O3 built and no arrangement of Ada
      --  could talk it out of, and the reduction widened eight binary32
      --  lanes to binary64 one at a time. The insertion already holds both
      --  in registers when its block loop ends.
      type Landing is array (0 .. 2 * Panel_Rows * Strip - 1) of N.Real
        with Alignment => 32;
      Landed : Landing := [others => 0.0];

   begin
      Taken := False;

      if Blocks > Scale_Room or else Rows mod Panel_Rows /= 0 then
         return;
      end if;

      --  What the strip's four vectors contribute, worked out once for the
      --  whole call rather than once for every row panel: where each
      --  vector's scales begin, the scale itself, and the block total the
      --  bias correction wants, already widened. Every one of these is the
      --  same for every row, and leaving them in the innermost loop cost
      --  about as much as the insertion saved -- which is what the counter
      --  said the first time this was built.
      for Vector in Element_Count range 0 .. Strip - 1 loop
         Vector_At (Natural (Vector)) :=
           (First + (At_Vector + Vector) * Stride) / Activation_Block;
      end loop;

      for Vector in 0 .. Strip - 1 loop
         for Block in 0 .. Blocks - 1 loop
            declare
               At_Scale : constant Element_Count :=
                 Vector_At (Vector) + Block;
            begin
               Vector_Scale (Natural (Block) * Strip + Vector) :=
                 Scales (Scales'First + At_Scale);
               Vector_Total (Natural (Block) * 2 * Strip + Vector) :=
                 N.Real (Totals (Totals'First + At_Scale));
               Vector_Total
                 (Natural (Block) * 2 * Strip + Strip + Vector) :=
                 N.Real (Totals (Totals'First + At_Scale));
            end;
         end loop;
      end loop;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            At_Row : constant Element_Count := Panel * Panel_Rows;
            Base   : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (At_Row);
         begin
            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     Scale : constant N.Real :=
                       Weights (Weights'First
                                + (At_Row + Row) * Blocks + Block);

                     At_Vec : constant Natural := Natural (Block) * Strip;
                     At_Out : constant Natural :=
                       Natural (Block) * (Panel_Rows * Strip)
                       + Natural (Row) * Strip;
                  begin
                     --  A map and nothing else. The correction that used
                     --  to share these four turns is the insertion's now.
                     for Vector in 0 .. Strip - 1 loop
                        Scaling (At_Out + Vector) :=
                          Scale * Vector_Scale (At_Vec + Vector);
                     end loop;
                  end;
               end loop;
            end loop;

            Landed := [others => 0.0];

            System.Machine_Code.Asm
              ("movl $0x80808080, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %8, %%rax" & LF &
               "1:" & LF &
               "vmovdqu (%1,%%rcx,1), %%ymm0" & LF &
               "vpxor %%ymm3, %%ymm0, %%ymm0" & LF &
               "vmovdqu (%2,%%rcx,1), %%ymm1" & LF &
               "vpxor %%ymm3, %%ymm1, %%ymm1" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm8" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm10" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm11" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vmovups (%7,%%rdx,1), %%ymm4" & LF &
               "vfmadd231ps (%9,%%rdx,1), %%ymm4, %%ymm24" & LF &
               "addq $34, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vhaddps %%ymm9, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm11, %%ymm10, %%ymm10" & LF &
               "vhaddps %%ymm13, %%ymm12, %%ymm12" & LF &
               "vhaddps %%ymm15, %%ymm14, %%ymm14" & LF &
               "vhaddps %%ymm10, %%ymm8, %%ymm8" & LF &
               "vhaddps %%ymm14, %%ymm12, %%ymm12" & LF &
               "vextractf128 $1, %%ymm8, %%xmm1" & LF &
               "vaddps %%xmm1, %%xmm8, %%xmm8" & LF &
               "vextractf128 $1, %%ymm12, %%xmm5" & LF &
               "vaddps %%xmm5, %%xmm12, %%xmm12" & LF &
               "vmovups %%xmm8, 0(%0)" & LF &
               "vmovups %%xmm12, 16(%0)" & LF &
               "vmovups %%ymm24, 32(%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base + 2)'Address),
                  System.Address'Asm_Input
                    ("r", Data (Base + Row_Bytes + 2)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + At_Vector * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 1) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 2) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + (At_Vector + 3) * Stride)'Address),
                  System.Address'Asm_Input ("r", Scaling (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks),
                  System.Address'Asm_Input
                    ("r", Vector_Total (0)'Address)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,"
                 & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
                 & "ymm24,memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Strip - 1 loop
                  declare
                     Which : constant Natural :=
                       Natural (Row) * Strip + Natural (Vector);
                     At_It : constant Element_Count :=
                       (At_Row + Row) * Count + At_Vector + Vector;
                  begin
                     --  Both already folded: the sum in the first eight of
                     --  Landed and the correction in the eight after them.
                     Sums (Sums'First + At_It) :=
                       Sums (Sums'First + At_It)
                       + N.Wide_Real (Landed (Which))
                       - 128.0
                         * N.Wide_Real
                             (Landed (Panel_Rows * Strip + Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips_Four;

   ----------------------------
   -- Rows_By_Panels_Q5K --
   ----------------------------

   --  What Rows_By_Strips_Q5K does for two rows and four vectors, done for
   --  eight and eight -- which is not a wider strip of the same kernel but a
   --  different one, and the layout is why.
   --
   --  There a lane of the accumulator is an eighth of one row's sum, and the
   --  eight are added together when the row ends. Here the panel's bytes are
   --  arranged so that a thirty-two byte load holds four consecutive
   --  elements of each of eight rows, four to a lane, and the byte dot
   --  product against those four activations broadcast as one word leaves
   --  lane L holding row L. Nothing is reduced horizontally at all.
   --
   --  What that buys is the register file. Eight accumulators covered two
   --  rows against four vectors; the same eight now cover eight rows against
   --  eight, so a strip reads the weights once for eight vectors where it
   --  read them once for four. On a prompt that is half the passes over the
   --  matrix.
   --
   --  The sub-block factor cannot ride the multiply-accumulate here, because
   --  each lane is a different row and wants a different factor: the
   --  eight-element groups are summed into a pair of partials and the pair
   --  is multiplied by a vector of eight factors at the end of every
   --  sub-block. That is two multiplies and two adds for every thirty-two
   --  byte dot products, which is what the broadcast form was saving.
   --
   --  And the minimum's term, which the other kernel does in Ada, is here as
   --  four sixteen-bit multiply-accumulates a vector: a sub-block's minimum
   --  is six bits and an activation total is under twelve, so the eight
   --  sub-blocks of a super-block are one dot product of eight pairs. Left
   --  in Ada it measured a quarter of the kernel, because the panel is eight
   --  rows and the strip is eight vectors and the term has one of everything.
   --
   --  There is no scale prologue. The six-bit fields were taken apart when
   --  the panel was written, so a sub-block's eight scales are eight
   --  consecutive bytes and one widening instruction; unpacking them here
   --  cost two and a half times the kernel itself for a generated token,
   --  which has one vector to amortize it over and measured forty per cent
   --  slower than the row-major kernel it replaced.
   procedure Rows_By_Panels_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      package IL renames Model_Runner.Quantization.Interleave;

      Panel : constant Element_Count := IL.Panel_Rows;
      Strip : constant := 8;
      Subs  : constant := 8;

      Span  : constant B.Byte_Count := IL.Five_Block_Bytes;

      --  The widest row this reads, in super-blocks. Thirty-two thousand
      --  elements, which is past every input width a model here carries.
      Block_Room : constant := 128;

      --  What one insertion writes and reads, in one buffer because one
      --  buffer is one register: the strip's products at nought, its
      --  minimum terms at sixty-four, and the activation totals it forms
      --  them from at a hundred and twenty-eight.
      type Work_Table is
        array (0 .. 159) of Interfaces.Integer_32 with Alignment => 32;

      type Scale_Table is
        array (0 .. Block_Room * 8 - 1) of N.Real with Alignment => 32;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;

      --  Twenty-four words a block, which the insertion reads as ninety-six
      --  bytes: eight scaled block scales, eight scaled minima, four packed
      --  pairs of activation totals, and eight words of nothing so that the
      --  next block's scales are aligned again. Marks is the same storage
      --  read as whole numbers, because four of the twenty-four are.
      type Band_Table is
        array (0 .. Block_Room * 24 - 1) of N.Real with Alignment => 32;
      type Mark_Table is
        array (0 .. Block_Room * 24 - 1) of Interfaces.Integer_32;

      --  And the panel's eight sums, which is what the single-vector
      --  insertion leaves where the strip leaves whole numbers.
      type Answer_Table is array (0 .. 7) of N.Real;

      Wholes : Scale_Table;
      Leasts : Scale_Table;
      Work   : Work_Table;
      Bands  : Band_Table;

      Marks : Mark_Table with Import, Address => Bands'Address;
      Answers : Answer_Table with Import, Address => Work'Address;

      function To_Unsigned_32 is new Ada.Unchecked_Conversion
        (Interfaces.Integer_32, Interfaces.Unsigned_32);

      --  Two whole numbers in the two halves of a word, which is what the
      --  sixteen-bit multiply-accumulate reads a pair of activation totals
      --  as. Both are inside twelve bits and the sign of each is its own.
      function Paired
        (Low, High : Interfaces.Integer_32) return Interfaces.Integer_32
      is (To_Signed_32
            ((To_Unsigned_32 (Low) and 16#FFFF#)
             or Interfaces.Shift_Left
                  (To_Unsigned_32 (High) and 16#FFFF#, 16)));

      At_Vector : Element_Count := 0;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));

      Places : Vector_Places;

      Base   : B.Byte_Index;
      At_Row : Element_Count;

      --  Where a vector's activations for one super-block begin.
      function Reading
        (Vector : Element_Count; Block : Element_Count) return Element_Count
      is (Values'First + First + Held (Vector) * Stride + Block * 256);

      --  One strip of the batch against the panel that is standing, adding
      --  lanes From through Last into the sums.
      --
      --  A batch that is not a whole number of strips takes its last strip
      --  from the end rather than the ragged edge: the strip overlaps the
      --  one before it, and the lanes the two have in common are added once,
      --  by the first of them. Recomputing a few vectors is cheaper than a
      --  second kernel for the remainder and cannot answer differently,
      --  because the lanes are independent.
      procedure Run_Strip (From : Element_Count; Last : Element_Count) is
      begin
         for Vector in Element_Count range 0 .. Strip - 1 loop
            Places (Natural (Vector)) :=
              (First + Held (Vector) * Stride) / Activation_Block;
         end loop;

         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               Head : constant B.Byte_Index :=
                 Base + B.Byte_Count (Block) * Span;
            begin
               for Vector in 0 .. Strip - 1 loop
                  declare
                     At_Tot : constant Element_Count :=
                       Places (Vector) + Block * Subs;
                  begin
                     for Pair in 0 .. 3 loop
                        Work (128 + Vector * 4 + Pair) :=
                          Paired
                            (Totals (Totals'First + At_Tot
                                     + Element_Count (Pair) * 2),
                             Totals (Totals'First + At_Tot
                                     + Element_Count (Pair) * 2 + 1));
                     end loop;
                  end;
               end loop;

               System.Machine_Code.Asm
                 (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vpcmpeqd %%ymm4, %%ymm4, %%ymm4" & LF &
               "vpsrlw $15, %%ymm4, %%ymm4" & LF &
               "vpsllw $8, %%ymm4, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 160(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 32(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 0(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 32(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 0(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 32(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 0(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 32(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 0(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 32(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 0(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 32(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 0(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 32(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 0(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 32(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovzxbd 32(%1), %%ymm6" & LF &
               "vpmovzxbd 40(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 416(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 96(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 64(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 96(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 64(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 96(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 64(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 96(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 64(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 96(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 64(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 96(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 64(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 96(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 64(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 96(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovzxbd 48(%1), %%ymm6" & LF &
               "vpmovzxbd 56(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 672(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 128(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 160(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 128(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 160(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 128(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 160(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 128(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 160(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 128(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 160(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 128(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 160(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 128(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 160(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovzxbd 64(%1), %%ymm6" & LF &
               "vpmovzxbd 72(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 928(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 192(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 224(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 192(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 224(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 192(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 224(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 192(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 224(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 192(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 224(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 192(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 224(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 192(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 224(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovzxbd 80(%1), %%ymm6" & LF &
               "vpmovzxbd 88(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vmovdqu32 %%ymm24, 0(%0)" & LF &
               "vmovdqu32 %%ymm25, 32(%0)" & LF &
               "vmovdqu32 %%ymm26, 64(%0)" & LF &
               "vmovdqu32 %%ymm27, 96(%0)" & LF &
               "vmovdqu32 %%ymm28, 128(%0)" & LF &
               "vmovdqu32 %%ymm29, 160(%0)" & LF &
               "vmovdqu32 %%ymm30, 192(%0)" & LF &
               "vmovdqu32 %%ymm31, 224(%0)" & LF &
               "vpmovzxbd 96(%1), %%ymm4" & LF &
               "vpmovzxbd 104(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpmovzxbd 112(%1), %%ymm5" & LF &
               "vpmovzxbd 120(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm5, %%ymm5" & LF &
               "vpmovzxbd 128(%1), %%ymm6" & LF &
               "vpmovzxbd 136(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm6, %%ymm6" & LF &
               "vpmovzxbd 144(%1), %%ymm7" & LF &
               "vpmovzxbd 152(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm7, %%ymm7" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpdpwssd 512(%0)%{1to8%}, %%ymm4, %%ymm8" & LF &
               "vpdpwssd 516(%0)%{1to8%}, %%ymm5, %%ymm8" & LF &
               "vpdpwssd 520(%0)%{1to8%}, %%ymm6, %%ymm8" & LF &
               "vpdpwssd 524(%0)%{1to8%}, %%ymm7, %%ymm8" & LF &
               "vmovdqu32 %%ymm8, 256(%0)" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpdpwssd 528(%0)%{1to8%}, %%ymm4, %%ymm9" & LF &
               "vpdpwssd 532(%0)%{1to8%}, %%ymm5, %%ymm9" & LF &
               "vpdpwssd 536(%0)%{1to8%}, %%ymm6, %%ymm9" & LF &
               "vpdpwssd 540(%0)%{1to8%}, %%ymm7, %%ymm9" & LF &
               "vmovdqu32 %%ymm9, 288(%0)" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpdpwssd 544(%0)%{1to8%}, %%ymm4, %%ymm10" & LF &
               "vpdpwssd 548(%0)%{1to8%}, %%ymm5, %%ymm10" & LF &
               "vpdpwssd 552(%0)%{1to8%}, %%ymm6, %%ymm10" & LF &
               "vpdpwssd 556(%0)%{1to8%}, %%ymm7, %%ymm10" & LF &
               "vmovdqu32 %%ymm10, 320(%0)" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpdpwssd 560(%0)%{1to8%}, %%ymm4, %%ymm11" & LF &
               "vpdpwssd 564(%0)%{1to8%}, %%ymm5, %%ymm11" & LF &
               "vpdpwssd 568(%0)%{1to8%}, %%ymm6, %%ymm11" & LF &
               "vpdpwssd 572(%0)%{1to8%}, %%ymm7, %%ymm11" & LF &
               "vmovdqu32 %%ymm11, 352(%0)" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpdpwssd 576(%0)%{1to8%}, %%ymm4, %%ymm12" & LF &
               "vpdpwssd 580(%0)%{1to8%}, %%ymm5, %%ymm12" & LF &
               "vpdpwssd 584(%0)%{1to8%}, %%ymm6, %%ymm12" & LF &
               "vpdpwssd 588(%0)%{1to8%}, %%ymm7, %%ymm12" & LF &
               "vmovdqu32 %%ymm12, 384(%0)" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpdpwssd 592(%0)%{1to8%}, %%ymm4, %%ymm13" & LF &
               "vpdpwssd 596(%0)%{1to8%}, %%ymm5, %%ymm13" & LF &
               "vpdpwssd 600(%0)%{1to8%}, %%ymm6, %%ymm13" & LF &
               "vpdpwssd 604(%0)%{1to8%}, %%ymm7, %%ymm13" & LF &
               "vmovdqu32 %%ymm13, 416(%0)" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpdpwssd 608(%0)%{1to8%}, %%ymm4, %%ymm14" & LF &
               "vpdpwssd 612(%0)%{1to8%}, %%ymm5, %%ymm14" & LF &
               "vpdpwssd 616(%0)%{1to8%}, %%ymm6, %%ymm14" & LF &
               "vpdpwssd 620(%0)%{1to8%}, %%ymm7, %%ymm14" & LF &
               "vmovdqu32 %%ymm14, 448(%0)" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpdpwssd 624(%0)%{1to8%}, %%ymm4, %%ymm15" & LF &
               "vpdpwssd 628(%0)%{1to8%}, %%ymm5, %%ymm15" & LF &
               "vpdpwssd 632(%0)%{1to8%}, %%ymm6, %%ymm15" & LF &
               "vpdpwssd 636(%0)%{1to8%}, %%ymm7, %%ymm15" & LF &
               "vmovdqu32 %%ymm15, 480(%0)",
                  Inputs =>
                    [System.Address'Asm_Input ("r", Work'Address),
                     System.Address'Asm_Input ("r", Data (Head)'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (0, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (1, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (2, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (3, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (4, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (5, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (6, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (7, Block))'Address)],
                  Clobber  =>
                    "rcx,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                    & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
                    & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                    & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                    & "memory",
                  Volatile => True);

               --  A super-block's contribution, which is the whole scale
               --  against the product and the least against the minimum's
               --  term, both of them integers until here.
               for Vector in From .. Last loop
                  declare
                     Scale : constant N.Real :=
                       Scales
                         (Scales'First + Places (Natural (Vector))
                          + Block * Subs);
                     At_It : constant Element_Count :=
                       At_Row * Count + At_Vector + Vector;
                  begin
                     for Row in Element_Count range 0 .. Panel - 1 loop
                        Sums (Sums'First + At_It + Row * Count) :=
                          Sums (Sums'First + At_It + Row * Count)
                          + N.Wide_Real
                              (Scale
                               * (Wholes (Natural (Block * Panel + Row))
                                  * N.Real
                                      (Work (Natural (Vector * Panel + Row)))
                                  - Leasts (Natural (Block * Panel + Row))
                                    * N.Real
                                        (Work
                                           (64 + Natural
                                                   (Vector * Panel + Row)))));
                     end loop;
                  end;
               end loop;
            end;
         end loop;
      end Run_Strip;

      --  The same panel against one vector, which is what a generated token
      --  multiplies. A strip of eight would read the weights once and do
      --  eight times the arithmetic; this reads them once and does one.
      --
      --  And its block loop is inside the insertion, where the strip's is
      --  in Ada. That is the shape the row-major single-vector kernel has
      --  and for the same reason: with one vector the accumulator is one
      --  register, so it can stay in one from a row's first block to its
      --  last, and the scaling that a strip does eight rows at a time in Ada
      --  becomes four instructions a block here. Written the other way it
      --  measured seven per cent behind the kernel it replaced.
      procedure Run_One is
      begin
         Places (0) := (First + At_Vector * Stride) / Activation_Block;

         --  What the insertion wants for each block, laid out the way it
         --  reads it: the panel's eight block scales against this vector's,
         --  the eight minima likewise, and the four packed pairs of
         --  activation totals. Ninety-six bytes so that both halves of the
         --  scale land on a thirty-two byte boundary.
         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               At_Tot : constant Element_Count :=
                 Places (0) + Block * Subs;
               Scale  : constant N.Real :=
                 Scales (Scales'First + At_Tot);
               At_Band : constant Natural := Natural (Block) * 24;
            begin
               for Row in Element_Count range 0 .. Panel - 1 loop
                  Bands (At_Band + Natural (Row)) :=
                    Wholes (Natural (Block * Panel + Row)) * Scale;
                  Bands (At_Band + 8 + Natural (Row)) :=
                    Leasts (Natural (Block * Panel + Row)) * Scale;
               end loop;

               for Pair in 0 .. 3 loop
                  Marks (At_Band + 16 + Pair) :=
                    Paired
                      (Totals (Totals'First + At_Tot
                               + Element_Count (Pair) * 2),
                       Totals (Totals'First + At_Tot
                               + Element_Count (Pair) * 2 + 1));
               end loop;
            end;
         end loop;

         System.Machine_Code.Asm
           (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vpcmpeqd %%ymm4, %%ymm4, %%ymm4" & LF &
               "vpsrlw $15, %%ymm4, %%ymm4" & LF &
               "vpsllw $8, %%ymm4, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vxorps %%ymm25, %%ymm25, %%ymm25" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %4, %%rax" & LF &
               "2:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 160(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 32(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 192(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1216(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 4(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 36(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 224(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1248(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 8(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 40(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 256(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1280(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 12(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 44(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 288(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1312(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 16(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 48(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 320(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1344(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 20(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 52(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 352(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1376(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 24(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 56(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 384(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1408(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $1, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 28(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 60(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovzxbd 32(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 40(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 416(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 96(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 448(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1216(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 68(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 100(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 480(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1248(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 72(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 104(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 512(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1280(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 76(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 108(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 544(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1312(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 80(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 112(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 576(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1344(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 84(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 116(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 608(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1376(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 88(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 120(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 640(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1408(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $3, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 92(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 124(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovzxbd 48(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 56(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 672(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 704(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1216(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 132(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 164(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 736(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1248(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 136(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 168(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 768(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1280(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 140(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 172(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 800(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1312(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 144(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 176(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 832(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1344(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 148(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 180(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 864(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1376(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 152(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 184(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 896(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1408(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $5, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 156(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 188(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovzxbd 64(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 72(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 928(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1184(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 960(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1216(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 196(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 228(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 992(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1248(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 200(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 232(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1024(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1280(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 204(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 236(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1056(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1312(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 208(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 240(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1088(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1344(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 212(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 244(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1120(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1376(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 216(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 248(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1152(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1408(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $7, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 220(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 252(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovzxbd 80(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 88(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpmovzxbd 96(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 104(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 64(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovzxbd 112(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 120(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 68(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovzxbd 128(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 136(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 72(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovzxbd 144(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 152(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 76(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vcvtdq2ps %%ymm24, %%ymm26" & LF &
               "vcvtdq2ps %%ymm16, %%ymm27" & LF &
               "vmulps 0(%3,%%rsi,1), %%ymm26, %%ymm26" & LF &
               "vmulps 32(%3,%%rsi,1), %%ymm27, %%ymm27" & LF &
               "vsubps %%ymm27, %%ymm26, %%ymm26" & LF &
               "vaddps %%ymm26, %%ymm25, %%ymm25" & LF &
               "addq $1440, %%rcx" & LF &
               "addq $256, %%rdx" & LF &
               "addq $96, %%rsi" & LF &
               "decq %%rax" & LF &
               "jne 2b" & LF &
               "vmovups %%ymm25, (%0)",
            Inputs =>
              [System.Address'Asm_Input ("r", Work'Address),
               System.Address'Asm_Input ("r", Data (Base)'Address),
               System.Address'Asm_Input
                 ("r", Values (Reading (0, 0))'Address),
               System.Address'Asm_Input ("r", Bands'Address),
               Element_Count'Asm_Input ("r", Blocks)],
            Clobber  =>
              "rax,rcx,rdx,rsi,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
              & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
              & "ymm16,ymm24,ymm25,ymm26,ymm27,memory",
            Volatile => True);

         declare
            At_It : constant Element_Count := At_Row * Count + At_Vector;
         begin
            for Row in Element_Count range 0 .. Panel - 1 loop
               Sums (Sums'First + At_It + Row * Count) :=
                 Sums (Sums'First + At_It + Row * Count)
                 + N.Wide_Real (Answers (Natural (Row)));
            end loop;
         end;
      end Run_One;
   begin
      Taken := False;

      if Rows = 0
        or else Rows mod Panel /= 0
        or else Blocks = 0
        or else Blocks > Block_Room
        or else Count = 0
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                      (Data, Offset,
                       IL.Panel_Bytes (G.Type_Q5_K, Rows, Blocks))
      then
         return;
      end if;

      for At_Panel in Element_Count range 0 .. Rows / Panel - 1 loop
         Base :=
           Data'First + Offset
           + B.Byte_Count (At_Panel) * B.Byte_Count (Blocks) * Span;
         At_Row := At_Panel * Panel;

         --  The panel's two block-wide scales, widened eight rows at a time
         --  because that is how the panel holds them. This is the whole of
         --  what a panel costs before its first product; the sub-block
         --  scales the kernel wants are bytes it reads itself.
         for Block in Element_Count range 0 .. Blocks - 1 loop
            System.Machine_Code.Asm
              (
               "vcvtph2ps 0(%2), %%ymm0" & LF &
               "vmovups %%ymm0, (%0)" & LF &
               "vcvtph2ps 16(%2), %%ymm0" & LF &
               "vmovups %%ymm0, (%1)",
               Inputs   =>
                 [System.Address'Asm_Input
                    ("r", Wholes (Natural (Block * Panel))'Address),
                  System.Address'Asm_Input
                    ("r", Leasts (Natural (Block * Panel))'Address),
                  System.Address'Asm_Input
                    ("r",
                     Data (Base + B.Byte_Count (Block) * Span)'Address)],
               Clobber  => "ymm0,memory",
               Volatile => True);
         end loop;

         if Count = 1 then
            At_Vector := 0;
            Run_One;
         else
            for Which in Element_Count range 0 .. (Count / Strip) - 1 loop
               At_Vector := Which * Strip;
               Run_Strip (0, Strip - 1);
            end loop;

            if Count mod Strip /= 0 then
               if Count < Strip then
                  At_Vector := 0;
                  Run_Strip (0, Count - 1);
               else
                  At_Vector := Count - Strip;
                  Run_Strip (Strip - Count mod Strip, Strip - 1);
               end if;
            end if;
         end if;
      end loop;

      Taken := True;
   end Rows_By_Panels_Q5K;

   ----------------------------
   -- Rows_By_Panels_Q6K --
   ----------------------------

   --  What Rows_By_Panels_Q4K does for the four-bit k-quant, done for the
   --  six-bit one -- and it is here because a "_M" file is a mixture. With
   --  the four-bit path in panels a profile put Q6_K at a quarter of a
   --  prompt: its output projection and about half its feed-forward are in
   --  that format, and they were the only thing left being read a row at a
   --  time.
   --
   --  The lanes are the same idea and the unpack is not. A six-bit quant is
   --  four bits in one run and two in another, so a group of four elements a
   --  lane costs eleven instructions where the four-bit format's costs
   --  three: mask the low nibbles, shift and mask the two bits, put them
   --  above the four, and again for the paired group. The two bits go four
   --  groups to a byte rather than two, so one load of them serves four
   --  groups at four shifts -- which is why a sub-block's shift is decided
   --  by whether its index is below four.
   --
   --  And the bias is the other difference. A four-bit k-quant's correction
   --  is a minimum a sub-block; a six-bit one's is that every quant is
   --  thirty-two low, so what is missing is the sub-block's scale against
   --  the activation's sum over the same sixteen -- which is the Halves
   --  table, and the same eight sixteen-bit multiply-accumulates a vector
   --  the other kernel spends on its minima.
   procedure Rows_By_Panels_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Halves    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      package IL renames Model_Runner.Quantization.Interleave;

      Panel : constant Element_Count := IL.Panel_Rows;
      Strip : constant := 8;
      Subs  : constant := 16;

      Span  : constant B.Byte_Count := IL.Six_Block_Bytes;

      Block_Room : constant := 128;

      --  The strip's products at nought, its bias terms at sixty-four, and
      --  the activation sums it forms them from at a hundred and
      --  twenty-eight -- eight pairs a vector, because the sums go into a
      --  sixteen-bit multiply-accumulate two at a time.
      type Work_Table is
        array (0 .. 191) of Interfaces.Integer_32 with Alignment => 32;

      type Scale_Table is
        array (0 .. Block_Room * 8 - 1) of N.Real with Alignment => 32;

      --  Twenty-four words a block for the single-vector insertion: eight
      --  scaled block scales, the same again times thirty-two for the bias,
      --  and eight packed pairs of activation sums.
      type Band_Table is
        array (0 .. Block_Room * 24 - 1) of N.Real with Alignment => 32;
      type Mark_Table is
        array (0 .. Block_Room * 24 - 1) of Interfaces.Integer_32;

      type Answer_Table is array (0 .. 7) of N.Real;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;

      Wholes : Scale_Table;
      Work   : Work_Table;
      Bands  : Band_Table;

      Marks   : Mark_Table with Import, Address => Bands'Address;
      Answers : Answer_Table with Import, Address => Work'Address;

      function To_Unsigned_32 is new Ada.Unchecked_Conversion
        (Interfaces.Integer_32, Interfaces.Unsigned_32);

      function Paired
        (Low, High : Interfaces.Integer_32) return Interfaces.Integer_32
      is (To_Signed_32
            ((To_Unsigned_32 (Low) and 16#FFFF#)
             or Interfaces.Shift_Left
                  (To_Unsigned_32 (High) and 16#FFFF#, 16)));

      At_Vector : Element_Count := 0;

      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));

      Places : Vector_Places;

      Base   : B.Byte_Index;
      At_Row : Element_Count;

      function Reading
        (Vector : Element_Count; Block : Element_Count) return Element_Count
      is (Values'First + First + Held (Vector) * Stride + Block * 256);

      --  Where a vector's sixteen activation sums for one super-block are.
      function Summing
        (Vector : Element_Count; Block : Element_Count) return Element_Count
      is ((First + Held (Vector) * Stride) / Activation_Half
          + Block * Subs);

      procedure Run_Strip (From : Element_Count; Last : Element_Count) is
      begin
         for Vector in Element_Count range 0 .. Strip - 1 loop
            Places (Natural (Vector)) :=
              (First + Held (Vector) * Stride) / Activation_Block;
         end loop;

         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               Head : constant B.Byte_Index :=
                 Base + B.Byte_Count (Block) * Span;
            begin
               for Vector in 0 .. Strip - 1 loop
                  declare
                     At_Sum : constant Element_Count :=
                       Summing (Element_Count (Vector), Block);
                  begin
                     for Pair in 0 .. 7 loop
                        Work (128 + Vector * 8 + Pair) :=
                          Paired
                            (Halves (Halves'First + At_Sum
                                     + Element_Count (Pair) * 2),
                             Halves (Halves'First + At_Sum
                                     + Element_Count (Pair) * 2 + 1));
                     end loop;
                  end;
               end loop;

               System.Machine_Code.Asm
                 (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vpcmpeqd %%ymm4, %%ymm4, %%ymm4" & LF &
               "vpsrlw $14, %%ymm4, %%ymm4" & LF &
               "vpsllw $8, %%ymm4, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 144(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1168(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 128(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 0(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 128(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 0(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 128(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 0(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 128(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 0(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 128(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 0(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 128(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 0(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 128(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 0(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 128(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 16(%1), %%ymm6" & LF &
               "vpmovsxbd 80(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 272(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1296(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 16(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 144(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 16(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 144(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 16(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 144(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 16(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 144(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 16(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 144(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 16(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 144(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 16(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 144(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 16(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 144(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 24(%1), %%ymm6" & LF &
               "vpmovsxbd 88(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 400(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1424(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 32(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 160(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 32(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 160(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 32(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 160(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 32(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 160(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 32(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 160(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 32(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 160(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 32(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 160(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 32(%1), %%ymm6" & LF &
               "vpmovsxbd 96(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 528(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1552(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 48(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 176(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 48(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 176(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 48(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 176(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 48(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 176(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 48(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 176(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 48(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 176(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 48(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 176(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 48(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 176(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 40(%1), %%ymm6" & LF &
               "vpmovsxbd 104(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 656(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1168(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 192(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 64(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 192(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 64(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 192(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 64(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 192(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 64(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 192(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 64(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 192(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 64(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 192(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 64(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 192(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 48(%1), %%ymm6" & LF &
               "vpmovsxbd 112(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 784(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1296(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 80(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 208(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 80(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 208(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 80(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 208(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 80(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 208(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 80(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 208(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 80(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 208(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 80(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 208(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 80(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 208(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 56(%1), %%ymm6" & LF &
               "vpmovsxbd 120(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 912(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1424(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 96(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 224(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 96(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 224(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 96(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 224(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 96(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 224(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 96(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 224(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 96(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 224(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 96(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 224(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 64(%1), %%ymm6" & LF &
               "vpmovsxbd 128(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 1040(%1,%%rcx,8), %%ymm0" & LF &
               "vmovdqu 1552(%1,%%rcx,8), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 112(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 240(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 112(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 240(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 112(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 240(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 112(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 240(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 112(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 240(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 112(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 240(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 112(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 240(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 112(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 240(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $16, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmovsxbd 72(%1), %%ymm6" & LF &
               "vpmovsxbd 136(%1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm16, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm6, %%ymm9, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm7, %%ymm17, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm6, %%ymm10, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm7, %%ymm18, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm6, %%ymm11, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm7, %%ymm19, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm6, %%ymm12, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm7, %%ymm20, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm6, %%ymm13, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm7, %%ymm21, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm6, %%ymm14, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm7, %%ymm22, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm6, %%ymm15, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm7, %%ymm23, %%ymm0" & LF &
               "vpaddd %%ymm0, %%ymm31, %%ymm31" & LF &
               "vmovdqu32 %%ymm24, 0(%0)" & LF &
               "vmovdqu32 %%ymm25, 32(%0)" & LF &
               "vmovdqu32 %%ymm26, 64(%0)" & LF &
               "vmovdqu32 %%ymm27, 96(%0)" & LF &
               "vmovdqu32 %%ymm28, 128(%0)" & LF &
               "vmovdqu32 %%ymm29, 160(%0)" & LF &
               "vmovdqu32 %%ymm30, 192(%0)" & LF &
               "vmovdqu32 %%ymm31, 224(%0)" & LF &
               "vpcmpeqd %%ymm4, %%ymm4, %%ymm4" & LF &
               "vpsrld $16, %%ymm4, %%ymm4" & LF &
               "vpmovsxbd 16(%1), %%ymm8" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm8" & LF &
               "vpmovsxbd 24(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm8, %%ymm8" & LF &
               "vpmovsxbd 32(%1), %%ymm9" & LF &
               "vpand %%ymm4, %%ymm9, %%ymm9" & LF &
               "vpmovsxbd 40(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm9, %%ymm9" & LF &
               "vpmovsxbd 48(%1), %%ymm10" & LF &
               "vpand %%ymm4, %%ymm10, %%ymm10" & LF &
               "vpmovsxbd 56(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm10, %%ymm10" & LF &
               "vpmovsxbd 64(%1), %%ymm11" & LF &
               "vpand %%ymm4, %%ymm11, %%ymm11" & LF &
               "vpmovsxbd 72(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm11, %%ymm11" & LF &
               "vpmovsxbd 80(%1), %%ymm12" & LF &
               "vpand %%ymm4, %%ymm12, %%ymm12" & LF &
               "vpmovsxbd 88(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm12, %%ymm12" & LF &
               "vpmovsxbd 96(%1), %%ymm13" & LF &
               "vpand %%ymm4, %%ymm13, %%ymm13" & LF &
               "vpmovsxbd 104(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm13, %%ymm13" & LF &
               "vpmovsxbd 112(%1), %%ymm14" & LF &
               "vpand %%ymm4, %%ymm14, %%ymm14" & LF &
               "vpmovsxbd 120(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm14, %%ymm14" & LF &
               "vpmovsxbd 128(%1), %%ymm15" & LF &
               "vpand %%ymm4, %%ymm15, %%ymm15" & LF &
               "vpmovsxbd 136(%1), %%ymm0" & LF &
               "vpslld $16, %%ymm0, %%ymm0" & LF &
               "vpor %%ymm0, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpdpwssd 512(%0)%{1to8%}, %%ymm8, %%ymm16" & LF &
               "vpdpwssd 516(%0)%{1to8%}, %%ymm9, %%ymm16" & LF &
               "vpdpwssd 520(%0)%{1to8%}, %%ymm10, %%ymm16" & LF &
               "vpdpwssd 524(%0)%{1to8%}, %%ymm11, %%ymm16" & LF &
               "vpdpwssd 528(%0)%{1to8%}, %%ymm12, %%ymm16" & LF &
               "vpdpwssd 532(%0)%{1to8%}, %%ymm13, %%ymm16" & LF &
               "vpdpwssd 536(%0)%{1to8%}, %%ymm14, %%ymm16" & LF &
               "vpdpwssd 540(%0)%{1to8%}, %%ymm15, %%ymm16" & LF &
               "vmovdqu32 %%ymm16, 256(%0)" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpdpwssd 544(%0)%{1to8%}, %%ymm8, %%ymm17" & LF &
               "vpdpwssd 548(%0)%{1to8%}, %%ymm9, %%ymm17" & LF &
               "vpdpwssd 552(%0)%{1to8%}, %%ymm10, %%ymm17" & LF &
               "vpdpwssd 556(%0)%{1to8%}, %%ymm11, %%ymm17" & LF &
               "vpdpwssd 560(%0)%{1to8%}, %%ymm12, %%ymm17" & LF &
               "vpdpwssd 564(%0)%{1to8%}, %%ymm13, %%ymm17" & LF &
               "vpdpwssd 568(%0)%{1to8%}, %%ymm14, %%ymm17" & LF &
               "vpdpwssd 572(%0)%{1to8%}, %%ymm15, %%ymm17" & LF &
               "vmovdqu32 %%ymm17, 288(%0)" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpdpwssd 576(%0)%{1to8%}, %%ymm8, %%ymm18" & LF &
               "vpdpwssd 580(%0)%{1to8%}, %%ymm9, %%ymm18" & LF &
               "vpdpwssd 584(%0)%{1to8%}, %%ymm10, %%ymm18" & LF &
               "vpdpwssd 588(%0)%{1to8%}, %%ymm11, %%ymm18" & LF &
               "vpdpwssd 592(%0)%{1to8%}, %%ymm12, %%ymm18" & LF &
               "vpdpwssd 596(%0)%{1to8%}, %%ymm13, %%ymm18" & LF &
               "vpdpwssd 600(%0)%{1to8%}, %%ymm14, %%ymm18" & LF &
               "vpdpwssd 604(%0)%{1to8%}, %%ymm15, %%ymm18" & LF &
               "vmovdqu32 %%ymm18, 320(%0)" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpdpwssd 608(%0)%{1to8%}, %%ymm8, %%ymm19" & LF &
               "vpdpwssd 612(%0)%{1to8%}, %%ymm9, %%ymm19" & LF &
               "vpdpwssd 616(%0)%{1to8%}, %%ymm10, %%ymm19" & LF &
               "vpdpwssd 620(%0)%{1to8%}, %%ymm11, %%ymm19" & LF &
               "vpdpwssd 624(%0)%{1to8%}, %%ymm12, %%ymm19" & LF &
               "vpdpwssd 628(%0)%{1to8%}, %%ymm13, %%ymm19" & LF &
               "vpdpwssd 632(%0)%{1to8%}, %%ymm14, %%ymm19" & LF &
               "vpdpwssd 636(%0)%{1to8%}, %%ymm15, %%ymm19" & LF &
               "vmovdqu32 %%ymm19, 352(%0)" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpdpwssd 640(%0)%{1to8%}, %%ymm8, %%ymm20" & LF &
               "vpdpwssd 644(%0)%{1to8%}, %%ymm9, %%ymm20" & LF &
               "vpdpwssd 648(%0)%{1to8%}, %%ymm10, %%ymm20" & LF &
               "vpdpwssd 652(%0)%{1to8%}, %%ymm11, %%ymm20" & LF &
               "vpdpwssd 656(%0)%{1to8%}, %%ymm12, %%ymm20" & LF &
               "vpdpwssd 660(%0)%{1to8%}, %%ymm13, %%ymm20" & LF &
               "vpdpwssd 664(%0)%{1to8%}, %%ymm14, %%ymm20" & LF &
               "vpdpwssd 668(%0)%{1to8%}, %%ymm15, %%ymm20" & LF &
               "vmovdqu32 %%ymm20, 384(%0)" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpdpwssd 672(%0)%{1to8%}, %%ymm8, %%ymm21" & LF &
               "vpdpwssd 676(%0)%{1to8%}, %%ymm9, %%ymm21" & LF &
               "vpdpwssd 680(%0)%{1to8%}, %%ymm10, %%ymm21" & LF &
               "vpdpwssd 684(%0)%{1to8%}, %%ymm11, %%ymm21" & LF &
               "vpdpwssd 688(%0)%{1to8%}, %%ymm12, %%ymm21" & LF &
               "vpdpwssd 692(%0)%{1to8%}, %%ymm13, %%ymm21" & LF &
               "vpdpwssd 696(%0)%{1to8%}, %%ymm14, %%ymm21" & LF &
               "vpdpwssd 700(%0)%{1to8%}, %%ymm15, %%ymm21" & LF &
               "vmovdqu32 %%ymm21, 416(%0)" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpdpwssd 704(%0)%{1to8%}, %%ymm8, %%ymm22" & LF &
               "vpdpwssd 708(%0)%{1to8%}, %%ymm9, %%ymm22" & LF &
               "vpdpwssd 712(%0)%{1to8%}, %%ymm10, %%ymm22" & LF &
               "vpdpwssd 716(%0)%{1to8%}, %%ymm11, %%ymm22" & LF &
               "vpdpwssd 720(%0)%{1to8%}, %%ymm12, %%ymm22" & LF &
               "vpdpwssd 724(%0)%{1to8%}, %%ymm13, %%ymm22" & LF &
               "vpdpwssd 728(%0)%{1to8%}, %%ymm14, %%ymm22" & LF &
               "vpdpwssd 732(%0)%{1to8%}, %%ymm15, %%ymm22" & LF &
               "vmovdqu32 %%ymm22, 448(%0)" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpdpwssd 736(%0)%{1to8%}, %%ymm8, %%ymm23" & LF &
               "vpdpwssd 740(%0)%{1to8%}, %%ymm9, %%ymm23" & LF &
               "vpdpwssd 744(%0)%{1to8%}, %%ymm10, %%ymm23" & LF &
               "vpdpwssd 748(%0)%{1to8%}, %%ymm11, %%ymm23" & LF &
               "vpdpwssd 752(%0)%{1to8%}, %%ymm12, %%ymm23" & LF &
               "vpdpwssd 756(%0)%{1to8%}, %%ymm13, %%ymm23" & LF &
               "vpdpwssd 760(%0)%{1to8%}, %%ymm14, %%ymm23" & LF &
               "vpdpwssd 764(%0)%{1to8%}, %%ymm15, %%ymm23" & LF &
               "vmovdqu32 %%ymm23, 480(%0)",
                  Inputs =>
                    [System.Address'Asm_Input ("r", Work'Address),
                     System.Address'Asm_Input ("r", Data (Head)'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (0, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (1, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (2, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (3, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (4, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (5, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (6, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (7, Block))'Address)],
                  Clobber  =>
                    "rcx,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                    & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
                    & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                    & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                    & "memory",
                  Volatile => True);

               for Vector in From .. Last loop
                  declare
                     Scale : constant N.Real :=
                       Scales
                         (Scales'First + Places (Natural (Vector))
                          + Block * 8);
                     At_It : constant Element_Count :=
                       At_Row * Count + At_Vector + Vector;
                  begin
                     for Row in Element_Count range 0 .. Panel - 1 loop
                        Sums (Sums'First + At_It + Row * Count) :=
                          Sums (Sums'First + At_It + Row * Count)
                          + N.Wide_Real
                              (Scale
                               * Wholes (Natural (Block * Panel + Row))
                               * (N.Real
                                    (Work (Natural (Vector * Panel + Row)))
                                  - 32.0
                                    * N.Real
                                        (Work
                                           (64 + Natural
                                                   (Vector * Panel + Row)))));
                     end loop;
                  end;
               end loop;
            end;
         end loop;
      end Run_Strip;

      procedure Run_One is
      begin
         Places (0) := (First + At_Vector * Stride) / Activation_Block;

         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               Scale : constant N.Real :=
                 Scales (Scales'First + Places (0) + Block * 8);
               At_Sum : constant Element_Count := Summing (0, Block);
               At_Band : constant Natural := Natural (Block) * 24;
            begin
               for Row in Element_Count range 0 .. Panel - 1 loop
                  Bands (At_Band + Natural (Row)) :=
                    Wholes (Natural (Block * Panel + Row)) * Scale;
                  Bands (At_Band + 8 + Natural (Row)) :=
                    Wholes (Natural (Block * Panel + Row)) * Scale * 32.0;
               end loop;

               for Pair in 0 .. 7 loop
                  Marks (At_Band + 16 + Pair) :=
                    Paired
                      (Halves (Halves'First + At_Sum
                               + Element_Count (Pair) * 2),
                       Halves (Halves'First + At_Sum
                               + Element_Count (Pair) * 2 + 1));
               end loop;
            end;
         end loop;

         System.Machine_Code.Asm
           (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vpcmpeqd %%ymm4, %%ymm4, %%ymm4" & LF &
               "vpsrlw $14, %%ymm4, %%ymm4" & LF &
               "vpsllw $8, %%ymm4, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpcmpeqd %%ymm0, %%ymm0, %%ymm0" & LF &
               "vpsrld $16, %%ymm0, %%ymm17" & LF &
               "vxorps %%ymm25, %%ymm25, %%ymm25" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %4, %%rax" & LF &
               "2:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 144(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1168(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 128(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 176(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1200(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 4(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 132(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 208(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1232(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 8(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 136(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 240(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1264(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 12(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 140(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 16(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 80(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 272(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1296(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 16(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 144(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 304(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1328(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 20(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 148(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 336(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1360(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 24(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 152(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 368(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1392(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 28(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 156(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 24(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 88(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 400(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1424(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 432(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1456(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 36(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 164(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 464(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1488(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 40(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 168(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 496(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1520(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 44(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 172(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 32(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 96(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 528(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1552(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 48(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 176(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 560(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1584(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 52(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 180(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 592(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1616(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 56(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 184(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 624(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1648(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpand %%ymm4, %%ymm5, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $4, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 60(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 188(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 40(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 104(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 656(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1168(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 192(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 688(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1200(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 68(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 196(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 720(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1232(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 72(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 200(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 752(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1264(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 76(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 204(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 48(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 112(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 784(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1296(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 80(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 208(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 816(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1328(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 84(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 212(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 848(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1360(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 88(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 216(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 880(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1392(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 92(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 220(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 56(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 120(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 912(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1424(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 944(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1456(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 100(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 228(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 976(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1488(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 104(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 232(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1008(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1520(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 108(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 236(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 64(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 128(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vmovdqu 1040(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1552(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 112(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 240(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1072(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1584(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 116(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 244(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1104(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1616(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 120(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 248(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vmovdqu 1136(%1,%%rcx,1), %%ymm0" & LF &
               "vmovdqu 1648(%1,%%rcx,1), %%ymm5" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $2, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm1, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpsrlw $6, %%ymm5, %%ymm6" & LF &
               "vpand %%ymm4, %%ymm6, %%ymm6" & LF &
               "vpsllw $4, %%ymm6, %%ymm6" & LF &
               "vpor %%ymm6, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 124(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 252(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm9" & LF &
               "vpmovsxbd 72(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovsxbd 136(%1,%%rcx,1), %%ymm7" & LF &
               "vpmulld %%ymm6, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm7, %%ymm9, %%ymm7" & LF &
               "vpaddd %%ymm7, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpmovsxbd 16(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 24(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 64(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 32(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 40(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 68(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 48(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 56(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 72(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 64(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 72(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 76(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 80(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 88(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 80(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 96(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 104(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 84(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 112(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 120(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 88(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpmovsxbd 128(%1,%%rcx,1), %%ymm6" & LF &
               "vpandd %%ymm17, %%ymm6, %%ymm6" & LF &
               "vpmovsxbd 136(%1,%%rcx,1), %%ymm7" & LF &
               "vpslld $16, %%ymm7, %%ymm7" & LF &
               "vpor %%ymm7, %%ymm6, %%ymm6" & LF &
               "vpdpwssd 92(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vcvtdq2ps %%ymm24, %%ymm26" & LF &
               "vcvtdq2ps %%ymm16, %%ymm27" & LF &
               "vmulps 0(%3,%%rsi,1), %%ymm26, %%ymm26" & LF &
               "vmulps 32(%3,%%rsi,1), %%ymm27, %%ymm27" & LF &
               "vsubps %%ymm27, %%ymm26, %%ymm26" & LF &
               "vaddps %%ymm26, %%ymm25, %%ymm25" & LF &
               "addq $1680, %%rcx" & LF &
               "addq $256, %%rdx" & LF &
               "addq $96, %%rsi" & LF &
               "decq %%rax" & LF &
               "jne 2b" & LF &
               "vmovups %%ymm25, (%0)",
            Inputs =>
              [System.Address'Asm_Input ("r", Work'Address),
               System.Address'Asm_Input ("r", Data (Base)'Address),
               System.Address'Asm_Input
                 ("r", Values (Reading (0, 0))'Address),
               System.Address'Asm_Input ("r", Bands'Address),
               Element_Count'Asm_Input ("r", Blocks)],
            Clobber  =>
              "rax,rcx,rdx,rsi,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
              & "ymm8,ymm9,ymm16,ymm17,ymm24,ymm25,ymm26,ymm27,memory",
            Volatile => True);

         declare
            At_It : constant Element_Count := At_Row * Count + At_Vector;
         begin
            for Row in Element_Count range 0 .. Panel - 1 loop
               Sums (Sums'First + At_It + Row * Count) :=
                 Sums (Sums'First + At_It + Row * Count)
                 + N.Wide_Real (Answers (Natural (Row)));
            end loop;
         end;
      end Run_One;
   begin
      Taken := False;

      if Rows = 0
        or else Rows mod Panel /= 0
        or else Blocks = 0
        or else Blocks > Block_Room
        or else Count = 0
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                      (Data, Offset,
                       IL.Panel_Bytes (G.Type_Q6_K, Rows, Blocks))
      then
         return;
      end if;

      for At_Panel in Element_Count range 0 .. Rows / Panel - 1 loop
         Base :=
           Data'First + Offset
           + B.Byte_Count (At_Panel) * B.Byte_Count (Blocks) * Span;
         At_Row := At_Panel * Panel;

         --  The panel's block scale, widened eight rows at a time. The
         --  sub-block scales the kernel wants are signed bytes it reads
         --  itself, which is what the layout is for.
         for Block in Element_Count range 0 .. Blocks - 1 loop
            System.Machine_Code.Asm
              (
               "vcvtph2ps 0(%1), %%ymm0" & LF &
               "vmovups %%ymm0, (%0)",
               Inputs   =>
                 [System.Address'Asm_Input
                    ("r", Wholes (Natural (Block * Panel))'Address),
                  System.Address'Asm_Input
                    ("r",
                     Data (Base + B.Byte_Count (Block) * Span)'Address)],
               Clobber  => "ymm0,memory",
               Volatile => True);
         end loop;

         if Count = 1 then
            At_Vector := 0;
            Run_One;
         else
            for Which in Element_Count range 0 .. (Count / Strip) - 1 loop
               At_Vector := Which * Strip;
               Run_Strip (0, Strip - 1);
            end loop;

            if Count mod Strip /= 0 then
               if Count < Strip then
                  At_Vector := 0;
                  Run_Strip (0, Count - 1);
               else
                  At_Vector := Count - Strip;
                  Run_Strip (Strip - Count mod Strip, Strip - 1);
               end if;
            end if;
         end if;
      end loop;

      Taken := True;
   end Rows_By_Panels_Q6K;

   ----------------------------
   -- Rows_By_Panels_Q4K --
   ----------------------------

   --  What Rows_By_Strips_Q4K does for two rows and four vectors, done for
   --  eight and eight -- which is not a wider strip of the same kernel but a
   --  different one, and the layout is why.
   --
   --  There a lane of the accumulator is an eighth of one row's sum, and the
   --  eight are added together when the row ends. Here the panel's bytes are
   --  arranged so that a thirty-two byte load holds four consecutive
   --  elements of each of eight rows, four to a lane, and the byte dot
   --  product against those four activations broadcast as one word leaves
   --  lane L holding row L. Nothing is reduced horizontally at all.
   --
   --  What that buys is the register file. Eight accumulators covered two
   --  rows against four vectors; the same eight now cover eight rows against
   --  eight, so a strip reads the weights once for eight vectors where it
   --  read them once for four. On a prompt that is half the passes over the
   --  matrix.
   --
   --  The sub-block factor cannot ride the multiply-accumulate here, because
   --  each lane is a different row and wants a different factor: the
   --  eight-element groups are summed into a pair of partials and the pair
   --  is multiplied by a vector of eight factors at the end of every
   --  sub-block. That is two multiplies and two adds for every thirty-two
   --  byte dot products, which is what the broadcast form was saving.
   --
   --  And the minimum's term, which the other kernel does in Ada, is here as
   --  four sixteen-bit multiply-accumulates a vector: a sub-block's minimum
   --  is six bits and an activation total is under twelve, so the eight
   --  sub-blocks of a super-block are one dot product of eight pairs. Left
   --  in Ada it measured a quarter of the kernel, because the panel is eight
   --  rows and the strip is eight vectors and the term has one of everything.
   --
   --  There is no scale prologue. The six-bit fields were taken apart when
   --  the panel was written, so a sub-block's eight scales are eight
   --  consecutive bytes and one widening instruction; unpacking them here
   --  cost two and a half times the kernel itself for a generated token,
   --  which has one vector to amortize it over and measured forty per cent
   --  slower than the row-major kernel it replaced.
   procedure Rows_By_Panels_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      package IL renames Model_Runner.Quantization.Interleave;

      Panel : constant Element_Count := IL.Panel_Rows;
      Strip : constant := 8;
      Subs  : constant := 8;

      Span  : constant B.Byte_Count := IL.Panel_Block_Bytes;

      --  The widest row this reads, in super-blocks. Thirty-two thousand
      --  elements, which is past every input width a model here carries.
      Block_Room : constant := 128;

      --  What one insertion writes and reads, in one buffer because one
      --  buffer is one register: the strip's products at nought, its
      --  minimum terms at sixty-four, and the activation totals it forms
      --  them from at a hundred and twenty-eight.
      type Work_Table is
        array (0 .. 159) of Interfaces.Integer_32 with Alignment => 32;

      type Scale_Table is
        array (0 .. Block_Room * 8 - 1) of N.Real with Alignment => 32;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;

      --  Twenty-four words a block, which the insertion reads as ninety-six
      --  bytes: eight scaled block scales, eight scaled minima, four packed
      --  pairs of activation totals, and eight words of nothing so that the
      --  next block's scales are aligned again. Marks is the same storage
      --  read as whole numbers, because four of the twenty-four are.
      type Band_Table is
        array (0 .. Block_Room * 24 - 1) of N.Real with Alignment => 32;
      type Mark_Table is
        array (0 .. Block_Room * 24 - 1) of Interfaces.Integer_32;

      --  And the panel's eight sums, which is what the single-vector
      --  insertion leaves where the strip leaves whole numbers.
      type Answer_Table is array (0 .. 7) of N.Real;

      Wholes : Scale_Table;
      Leasts : Scale_Table;
      Work   : Work_Table;
      Bands  : Band_Table;

      Marks : Mark_Table with Import, Address => Bands'Address;
      Answers : Answer_Table with Import, Address => Work'Address;

      function To_Unsigned_32 is new Ada.Unchecked_Conversion
        (Interfaces.Integer_32, Interfaces.Unsigned_32);

      --  Two whole numbers in the two halves of a word, which is what the
      --  sixteen-bit multiply-accumulate reads a pair of activation totals
      --  as. Both are inside twelve bits and the sign of each is its own.
      function Paired
        (Low, High : Interfaces.Integer_32) return Interfaces.Integer_32
      is (To_Signed_32
            ((To_Unsigned_32 (Low) and 16#FFFF#)
             or Interfaces.Shift_Left
                  (To_Unsigned_32 (High) and 16#FFFF#, 16)));

      At_Vector : Element_Count := 0;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));

      Places : Vector_Places;

      Base   : B.Byte_Index;
      At_Row : Element_Count;

      --  Where a vector's activations for one super-block begin.
      function Reading
        (Vector : Element_Count; Block : Element_Count) return Element_Count
      is (Values'First + First + Held (Vector) * Stride + Block * 256);

      --  One strip of the batch against the panel that is standing, adding
      --  lanes From through Last into the sums.
      --
      --  A batch that is not a whole number of strips takes its last strip
      --  from the end rather than the ragged edge: the strip overlaps the
      --  one before it, and the lanes the two have in common are added once,
      --  by the first of them. Recomputing a few vectors is cheaper than a
      --  second kernel for the remainder and cannot answer differently,
      --  because the lanes are independent.
      procedure Run_Strip (From : Element_Count; Last : Element_Count) is
      begin
         for Vector in Element_Count range 0 .. Strip - 1 loop
            Places (Natural (Vector)) :=
              (First + Held (Vector) * Stride) / Activation_Block;
         end loop;

         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               Head : constant B.Byte_Index :=
                 Base + B.Byte_Count (Block) * Span;
            begin
               for Vector in 0 .. Strip - 1 loop
                  declare
                     At_Tot : constant Element_Count :=
                       Places (Vector) + Block * Subs;
                  begin
                     for Pair in 0 .. 3 loop
                        Work (128 + Vector * 4 + Pair) :=
                          Paired
                            (Totals (Totals'First + At_Tot
                                     + Element_Count (Pair) * 2),
                             Totals (Totals'First + At_Tot
                                     + Element_Count (Pair) * 2 + 1));
                     end loop;
                  end;
               end loop;

               System.Machine_Code.Asm
                 (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpmovzxbd 32(%1), %%ymm4" & LF &
               "vpmovzxbd 40(%1), %%ymm5" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 160(%1,%%rcx,8), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 32(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 0(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 32(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 0(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 32(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 0(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 32(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 0(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 32(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 0(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 32(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 0(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 32(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 0(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 32(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm16, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm4, %%ymm9, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm5, %%ymm17, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm4, %%ymm10, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm5, %%ymm18, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm4, %%ymm11, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm5, %%ymm19, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm4, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm5, %%ymm20, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm4, %%ymm13, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm5, %%ymm21, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm4, %%ymm14, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm5, %%ymm22, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm4, %%ymm15, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm5, %%ymm23, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpmovzxbd 48(%1), %%ymm4" & LF &
               "vpmovzxbd 56(%1), %%ymm5" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 416(%1,%%rcx,8), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 96(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 64(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 96(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 64(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 96(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 64(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 96(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 64(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 96(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 64(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 96(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 64(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 96(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 64(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 96(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm16, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm4, %%ymm9, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm5, %%ymm17, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm4, %%ymm10, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm5, %%ymm18, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm4, %%ymm11, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm5, %%ymm19, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm4, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm5, %%ymm20, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm4, %%ymm13, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm5, %%ymm21, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm4, %%ymm14, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm5, %%ymm22, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm4, %%ymm15, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm5, %%ymm23, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpmovzxbd 64(%1), %%ymm4" & LF &
               "vpmovzxbd 72(%1), %%ymm5" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 672(%1,%%rcx,8), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 128(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 160(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 128(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 160(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 128(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 160(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 128(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 160(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 128(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 160(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 128(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 160(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 128(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 160(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm16, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm4, %%ymm9, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm5, %%ymm17, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm4, %%ymm10, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm5, %%ymm18, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm4, %%ymm11, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm5, %%ymm19, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm4, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm5, %%ymm20, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm4, %%ymm13, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm5, %%ymm21, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm4, %%ymm14, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm5, %%ymm22, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm4, %%ymm15, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm5, %%ymm23, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "vpmovzxbd 80(%1), %%ymm4" & LF &
               "vpmovzxbd 88(%1), %%ymm5" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "1:" & LF &
               "vmovdqu 928(%1,%%rcx,8), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%2,%%rcx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rcx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpdpbusd 192(%3,%%rcx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 224(%3,%%rcx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpdpbusd 192(%4,%%rcx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 224(%4,%%rcx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpdpbusd 192(%5,%%rcx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 224(%5,%%rcx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpdpbusd 192(%6,%%rcx,1)%{1to8%}, %%ymm1, %%ymm12" & LF &
               "vpdpbusd 224(%6,%%rcx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpdpbusd 192(%7,%%rcx,1)%{1to8%}, %%ymm1, %%ymm13" & LF &
               "vpdpbusd 224(%7,%%rcx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpdpbusd 192(%8,%%rcx,1)%{1to8%}, %%ymm1, %%ymm14" & LF &
               "vpdpbusd 224(%8,%%rcx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpdpbusd 192(%9,%%rcx,1)%{1to8%}, %%ymm1, %%ymm15" & LF &
               "vpdpbusd 224(%9,%%rcx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $4, %%rcx" & LF &
               "cmpq $32, %%rcx" & LF &
               "jne 1b" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm16, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm4, %%ymm9, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm5, %%ymm17, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm25, %%ymm25" & LF &
               "vpmulld %%ymm4, %%ymm10, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm5, %%ymm18, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm26, %%ymm26" & LF &
               "vpmulld %%ymm4, %%ymm11, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm5, %%ymm19, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm27, %%ymm27" & LF &
               "vpmulld %%ymm4, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm5, %%ymm20, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm28, %%ymm28" & LF &
               "vpmulld %%ymm4, %%ymm13, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm5, %%ymm21, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm29, %%ymm29" & LF &
               "vpmulld %%ymm4, %%ymm14, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm5, %%ymm22, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm30, %%ymm30" & LF &
               "vpmulld %%ymm4, %%ymm15, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vpmulld %%ymm5, %%ymm23, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm31, %%ymm31" & LF &
               "vmovdqu32 %%ymm24, 0(%0)" & LF &
               "vmovdqu32 %%ymm25, 32(%0)" & LF &
               "vmovdqu32 %%ymm26, 64(%0)" & LF &
               "vmovdqu32 %%ymm27, 96(%0)" & LF &
               "vmovdqu32 %%ymm28, 128(%0)" & LF &
               "vmovdqu32 %%ymm29, 160(%0)" & LF &
               "vmovdqu32 %%ymm30, 192(%0)" & LF &
               "vmovdqu32 %%ymm31, 224(%0)" & LF &
               "vpmovzxbd 96(%1), %%ymm4" & LF &
               "vpmovzxbd 104(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpmovzxbd 112(%1), %%ymm5" & LF &
               "vpmovzxbd 120(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm5, %%ymm5" & LF &
               "vpmovzxbd 128(%1), %%ymm6" & LF &
               "vpmovzxbd 136(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm6, %%ymm6" & LF &
               "vpmovzxbd 144(%1), %%ymm7" & LF &
               "vpmovzxbd 152(%1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm7, %%ymm7" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpdpwssd 512(%0)%{1to8%}, %%ymm4, %%ymm8" & LF &
               "vpdpwssd 516(%0)%{1to8%}, %%ymm5, %%ymm8" & LF &
               "vpdpwssd 520(%0)%{1to8%}, %%ymm6, %%ymm8" & LF &
               "vpdpwssd 524(%0)%{1to8%}, %%ymm7, %%ymm8" & LF &
               "vmovdqu %%ymm8, 256(%0)" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpdpwssd 528(%0)%{1to8%}, %%ymm4, %%ymm9" & LF &
               "vpdpwssd 532(%0)%{1to8%}, %%ymm5, %%ymm9" & LF &
               "vpdpwssd 536(%0)%{1to8%}, %%ymm6, %%ymm9" & LF &
               "vpdpwssd 540(%0)%{1to8%}, %%ymm7, %%ymm9" & LF &
               "vmovdqu %%ymm9, 288(%0)" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpdpwssd 544(%0)%{1to8%}, %%ymm4, %%ymm10" & LF &
               "vpdpwssd 548(%0)%{1to8%}, %%ymm5, %%ymm10" & LF &
               "vpdpwssd 552(%0)%{1to8%}, %%ymm6, %%ymm10" & LF &
               "vpdpwssd 556(%0)%{1to8%}, %%ymm7, %%ymm10" & LF &
               "vmovdqu %%ymm10, 320(%0)" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpdpwssd 560(%0)%{1to8%}, %%ymm4, %%ymm11" & LF &
               "vpdpwssd 564(%0)%{1to8%}, %%ymm5, %%ymm11" & LF &
               "vpdpwssd 568(%0)%{1to8%}, %%ymm6, %%ymm11" & LF &
               "vpdpwssd 572(%0)%{1to8%}, %%ymm7, %%ymm11" & LF &
               "vmovdqu %%ymm11, 352(%0)" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpdpwssd 576(%0)%{1to8%}, %%ymm4, %%ymm12" & LF &
               "vpdpwssd 580(%0)%{1to8%}, %%ymm5, %%ymm12" & LF &
               "vpdpwssd 584(%0)%{1to8%}, %%ymm6, %%ymm12" & LF &
               "vpdpwssd 588(%0)%{1to8%}, %%ymm7, %%ymm12" & LF &
               "vmovdqu %%ymm12, 384(%0)" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpdpwssd 592(%0)%{1to8%}, %%ymm4, %%ymm13" & LF &
               "vpdpwssd 596(%0)%{1to8%}, %%ymm5, %%ymm13" & LF &
               "vpdpwssd 600(%0)%{1to8%}, %%ymm6, %%ymm13" & LF &
               "vpdpwssd 604(%0)%{1to8%}, %%ymm7, %%ymm13" & LF &
               "vmovdqu %%ymm13, 416(%0)" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpdpwssd 608(%0)%{1to8%}, %%ymm4, %%ymm14" & LF &
               "vpdpwssd 612(%0)%{1to8%}, %%ymm5, %%ymm14" & LF &
               "vpdpwssd 616(%0)%{1to8%}, %%ymm6, %%ymm14" & LF &
               "vpdpwssd 620(%0)%{1to8%}, %%ymm7, %%ymm14" & LF &
               "vmovdqu %%ymm14, 448(%0)" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpdpwssd 624(%0)%{1to8%}, %%ymm4, %%ymm15" & LF &
               "vpdpwssd 628(%0)%{1to8%}, %%ymm5, %%ymm15" & LF &
               "vpdpwssd 632(%0)%{1to8%}, %%ymm6, %%ymm15" & LF &
               "vpdpwssd 636(%0)%{1to8%}, %%ymm7, %%ymm15" & LF &
               "vmovdqu %%ymm15, 480(%0)",
                  Inputs =>
                    [System.Address'Asm_Input ("r", Work'Address),
                     System.Address'Asm_Input ("r", Data (Head)'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (0, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (1, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (2, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (3, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (4, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (5, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (6, Block))'Address),
                     System.Address'Asm_Input
                       ("r", Values (Reading (7, Block))'Address)],
                  Clobber  =>
                    "rcx,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                    & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
                    & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                    & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                    & "memory",
                  Volatile => True);

               --  A super-block's contribution, which is the whole scale
               --  against the product and the least against the minimum's
               --  term, both of them integers until here.
               for Vector in From .. Last loop
                  declare
                     Scale : constant N.Real :=
                       Scales
                         (Scales'First + Places (Natural (Vector))
                          + Block * Subs);
                     At_It : constant Element_Count :=
                       At_Row * Count + At_Vector + Vector;
                  begin
                     for Row in Element_Count range 0 .. Panel - 1 loop
                        Sums (Sums'First + At_It + Row * Count) :=
                          Sums (Sums'First + At_It + Row * Count)
                          + N.Wide_Real
                              (Scale
                               * (Wholes (Natural (Block * Panel + Row))
                                  * N.Real
                                      (Work (Natural (Vector * Panel + Row)))
                                  - Leasts (Natural (Block * Panel + Row))
                                    * N.Real
                                        (Work
                                           (64 + Natural
                                                   (Vector * Panel + Row)))));
                     end loop;
                  end;
               end loop;
            end;
         end loop;
      end Run_Strip;

      --  The same panel against one vector, which is what a generated token
      --  multiplies. A strip of eight would read the weights once and do
      --  eight times the arithmetic; this reads them once and does one.
      --
      --  And its block loop is inside the insertion, where the strip's is
      --  in Ada. That is the shape the row-major single-vector kernel has
      --  and for the same reason: with one vector the accumulator is one
      --  register, so it can stay in one from a row's first block to its
      --  last, and the scaling that a strip does eight rows at a time in Ada
      --  becomes four instructions a block here. Written the other way it
      --  measured seven per cent behind the kernel it replaced.
      procedure Run_One is
      begin
         Places (0) := (First + At_Vector * Stride) / Activation_Block;

         --  What the insertion wants for each block, laid out the way it
         --  reads it: the panel's eight block scales against this vector's,
         --  the eight minima likewise, and the four packed pairs of
         --  activation totals. Ninety-six bytes so that both halves of the
         --  scale land on a thirty-two byte boundary.
         for Block in Element_Count range 0 .. Blocks - 1 loop
            declare
               At_Tot : constant Element_Count :=
                 Places (0) + Block * Subs;
               Scale  : constant N.Real :=
                 Scales (Scales'First + At_Tot);
               At_Band : constant Natural := Natural (Block) * 24;
            begin
               for Row in Element_Count range 0 .. Panel - 1 loop
                  Bands (At_Band + Natural (Row)) :=
                    Wholes (Natural (Block * Panel + Row)) * Scale;
                  Bands (At_Band + 8 + Natural (Row)) :=
                    Leasts (Natural (Block * Panel + Row)) * Scale;
               end loop;

               for Pair in 0 .. 3 loop
                  Marks (At_Band + 16 + Pair) :=
                    Paired
                      (Totals (Totals'First + At_Tot
                               + Element_Count (Pair) * 2),
                       Totals (Totals'First + At_Tot
                               + Element_Count (Pair) * 2 + 1));
               end loop;
            end;
         end loop;

         System.Machine_Code.Asm
           (
               "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
               "vpsrlw $12, %%ymm3, %%ymm3" & LF &
               "vpsllw $8, %%ymm3, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
               "vxorps %%ymm25, %%ymm25, %%ymm25" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %4, %%rax" & LF &
               "2:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpmovzxbd 32(%1,%%rcx,1), %%ymm4" & LF &
               "vpmovzxbd 40(%1,%%rcx,1), %%ymm5" & LF &
               "vmovdqu 160(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 32(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 192(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 4(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 36(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 224(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 8(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 40(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 256(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 12(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 44(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vmovdqu 288(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 16(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 48(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 320(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 20(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 52(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 352(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 24(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 56(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 384(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 28(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 60(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vpaddd %%ymm9, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm11, %%ymm10, %%ymm10" & LF &
               "vpaddd %%ymm10, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm13, %%ymm12, %%ymm12" & LF &
               "vpaddd %%ymm15, %%ymm14, %%ymm14" & LF &
               "vpaddd %%ymm14, %%ymm12, %%ymm12" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpmovzxbd 48(%1,%%rcx,1), %%ymm4" & LF &
               "vpmovzxbd 56(%1,%%rcx,1), %%ymm5" & LF &
               "vmovdqu 416(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 96(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 448(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 68(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 100(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 480(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 72(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 104(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 512(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 76(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 108(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vmovdqu 544(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 80(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 112(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 576(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 84(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 116(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 608(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 88(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 120(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 640(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 92(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 124(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vpaddd %%ymm9, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm11, %%ymm10, %%ymm10" & LF &
               "vpaddd %%ymm10, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm13, %%ymm12, %%ymm12" & LF &
               "vpaddd %%ymm15, %%ymm14, %%ymm14" & LF &
               "vpaddd %%ymm14, %%ymm12, %%ymm12" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpmovzxbd 64(%1,%%rcx,1), %%ymm4" & LF &
               "vpmovzxbd 72(%1,%%rcx,1), %%ymm5" & LF &
               "vmovdqu 672(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 160(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 704(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 132(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 164(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 736(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 136(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 168(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 768(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 140(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 172(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vmovdqu 800(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 144(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 176(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 832(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 148(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 180(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 864(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 152(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 184(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 896(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 156(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 188(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vpaddd %%ymm9, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm11, %%ymm10, %%ymm10" & LF &
               "vpaddd %%ymm10, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm13, %%ymm12, %%ymm12" & LF &
               "vpaddd %%ymm15, %%ymm14, %%ymm14" & LF &
               "vpaddd %%ymm14, %%ymm12, %%ymm12" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm8, %%ymm8, %%ymm8" & LF &
               "vpxord %%ymm9, %%ymm9, %%ymm9" & LF &
               "vpxord %%ymm10, %%ymm10, %%ymm10" & LF &
               "vpxord %%ymm11, %%ymm11, %%ymm11" & LF &
               "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
               "vpxord %%ymm13, %%ymm13, %%ymm13" & LF &
               "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
               "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
               "vpmovzxbd 80(%1,%%rcx,1), %%ymm4" & LF &
               "vpmovzxbd 88(%1,%%rcx,1), %%ymm5" & LF &
               "vmovdqu 928(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 224(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 960(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 196(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 228(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 992(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 200(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 232(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 1024(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 204(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 236(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vmovdqu 1056(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 208(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm8" & LF &
               "vpdpbusd 240(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm12" & LF &
               "vmovdqu 1088(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 212(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9" & LF &
               "vpdpbusd 244(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm13" & LF &
               "vmovdqu 1120(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 216(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm10" & LF &
               "vpdpbusd 248(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm14" & LF &
               "vmovdqu 1152(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm1" & LF &
               "vpsrlw $4, %%ymm0, %%ymm2" & LF &
               "vpand %%ymm3, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 220(%2,%%rdx,1)%{1to8%}, %%ymm1, %%ymm11" & LF &
               "vpdpbusd 252(%2,%%rdx,1)%{1to8%}, %%ymm2, %%ymm15" & LF &
               "vpaddd %%ymm9, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm11, %%ymm10, %%ymm10" & LF &
               "vpaddd %%ymm10, %%ymm8, %%ymm8" & LF &
               "vpaddd %%ymm13, %%ymm12, %%ymm12" & LF &
               "vpaddd %%ymm15, %%ymm14, %%ymm14" & LF &
               "vpaddd %%ymm14, %%ymm12, %%ymm12" & LF &
               "vpmulld %%ymm4, %%ymm8, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmulld %%ymm5, %%ymm12, %%ymm6" & LF &
               "vpaddd %%ymm6, %%ymm24, %%ymm24" & LF &
               "vpmovzxbd 96(%1,%%rcx,1), %%ymm4" & LF &
               "vpmovzxbd 104(%1,%%rcx,1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm4, %%ymm4" & LF &
               "vpmovzxbd 112(%1,%%rcx,1), %%ymm5" & LF &
               "vpmovzxbd 120(%1,%%rcx,1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm5, %%ymm5" & LF &
               "vpmovzxbd 128(%1,%%rcx,1), %%ymm6" & LF &
               "vpmovzxbd 136(%1,%%rcx,1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm6, %%ymm6" & LF &
               "vpmovzxbd 144(%1,%%rcx,1), %%ymm7" & LF &
               "vpmovzxbd 152(%1,%%rcx,1), %%ymm2" & LF &
               "vpslld $16, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm7, %%ymm7" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpdpwssd 64(%3,%%rsi,1)%{1to8%}, %%ymm4, %%ymm16" & LF &
               "vpdpwssd 68(%3,%%rsi,1)%{1to8%}, %%ymm5, %%ymm16" & LF &
               "vpdpwssd 72(%3,%%rsi,1)%{1to8%}, %%ymm6, %%ymm16" & LF &
               "vpdpwssd 76(%3,%%rsi,1)%{1to8%}, %%ymm7, %%ymm16" & LF &
               "vcvtdq2ps %%ymm24, %%ymm26" & LF &
               "vcvtdq2ps %%ymm16, %%ymm27" & LF &
               "vmulps 0(%3,%%rsi,1), %%ymm26, %%ymm26" & LF &
               "vmulps 32(%3,%%rsi,1), %%ymm27, %%ymm27" & LF &
               "vsubps %%ymm27, %%ymm26, %%ymm26" & LF &
               "vaddps %%ymm26, %%ymm25, %%ymm25" & LF &
               "addq $1184, %%rcx" & LF &
               "addq $256, %%rdx" & LF &
               "addq $96, %%rsi" & LF &
               "decq %%rax" & LF &
               "jne 2b" & LF &
               "vmovups %%ymm25, (%0)",
            Inputs =>
              [System.Address'Asm_Input ("r", Work'Address),
               System.Address'Asm_Input ("r", Data (Base)'Address),
               System.Address'Asm_Input
                 ("r", Values (Reading (0, 0))'Address),
               System.Address'Asm_Input ("r", Bands'Address),
               Element_Count'Asm_Input ("r", Blocks)],
            Clobber  =>
              "rax,rcx,rdx,rsi,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
              & "ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
              & "ymm16,ymm24,ymm25,ymm26,ymm27,memory",
            Volatile => True);

         declare
            At_It : constant Element_Count := At_Row * Count + At_Vector;
         begin
            for Row in Element_Count range 0 .. Panel - 1 loop
               Sums (Sums'First + At_It + Row * Count) :=
                 Sums (Sums'First + At_It + Row * Count)
                 + N.Wide_Real (Answers (Natural (Row)));
            end loop;
         end;
      end Run_One;
   begin
      Taken := False;

      if Rows = 0
        or else Rows mod Panel /= 0
        or else Blocks = 0
        or else Blocks > Block_Room
        or else Count = 0
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                      (Data, Offset,
                       IL.Panel_Bytes (G.Type_Q4_K, Rows, Blocks))
      then
         return;
      end if;

      for At_Panel in Element_Count range 0 .. Rows / Panel - 1 loop
         Base :=
           Data'First + Offset
           + B.Byte_Count (At_Panel) * B.Byte_Count (Blocks) * Span;
         At_Row := At_Panel * Panel;

         --  The panel's two block-wide scales, widened eight rows at a time
         --  because that is how the panel holds them. This is the whole of
         --  what a panel costs before its first product; the sub-block
         --  scales the kernel wants are bytes it reads itself.
         for Block in Element_Count range 0 .. Blocks - 1 loop
            System.Machine_Code.Asm
              (
               "vcvtph2ps 0(%2), %%ymm0" & LF &
               "vmovups %%ymm0, (%0)" & LF &
               "vcvtph2ps 16(%2), %%ymm0" & LF &
               "vmovups %%ymm0, (%1)",
               Inputs   =>
                 [System.Address'Asm_Input
                    ("r", Wholes (Natural (Block * Panel))'Address),
                  System.Address'Asm_Input
                    ("r", Leasts (Natural (Block * Panel))'Address),
                  System.Address'Asm_Input
                    ("r",
                     Data (Base + B.Byte_Count (Block) * Span)'Address)],
               Clobber  => "ymm0,memory",
               Volatile => True);
         end loop;

         if Count = 1 then
            At_Vector := 0;
            Run_One;
         else
            for Which in Element_Count range 0 .. (Count / Strip) - 1 loop
               At_Vector := Which * Strip;
               Run_Strip (0, Strip - 1);
            end loop;

            if Count mod Strip /= 0 then
               if Count < Strip then
                  At_Vector := 0;
                  Run_Strip (0, Count - 1);
               else
                  At_Vector := Count - Strip;
                  Run_Strip (Strip - Count mod Strip, Strip - 1);
               end if;
            end if;
         end if;
      end loop;

      Taken := True;
   end Rows_By_Panels_Q4K;

   ----------------------------
   -- Rows_By_Panels_Q40 --
   ----------------------------

   --  What Rows_By_Panels_Q4K does for the four-bit k-quant, done for the
   --  legacy four-bit format -- and the two are less alike than the layouts
   --  are, because this format's block is thirty-two elements and the
   --  k-quant's is two hundred and fifty-six.
   --
   --  That one number decides the shape of this kernel. A k-quant block
   --  carries eight sub-block scales and one block scale, so the conversion
   --  to floating point happens once for every two hundred and fifty-six
   --  elements and everything between is integer. Here there is one scale
   --  for every thirty-two, so the conversion happens eight times as often
   --  per element and the kernel is arranged around making it cheap rather
   --  than around making the dot product cheap.
   --
   --  Three things come out of that.
   --
   --  The block loop is inside the insertion, as the single-vector kernel's
   --  is, because a strip's eight running sums have to stay in registers
   --  from a row's first block to its last: written the other way they
   --  would be stored and reloaded eight times as often as the k-quant
   --  stores and reloads its own.
   --
   --  The whole block is unpacked into eight registers before any vector
   --  reads it. A block is four groups of four elements, low nibbles and
   --  high, and the eight vectors of a strip all want the same eight
   --  vectors of quants -- so they are masked once and held in ymm24
   --  through ymm31 while the strip walks past them. That is what makes a
   --  vector's turn one pointer, one broadcast and eight dot products.
   --
   --  And the format's centring is the accumulator's starting value. Every
   --  quant here is a nibble that means itself minus eight, so a block's
   --  true sum is the byte dot product less eight times the activation's
   --  own total over that block -- and rather than subtract that at the
   --  end, the accumulator is loaded with the negative of it before the
   --  first product. One broadcast where the k-quant's minimum takes four
   --  multiply-accumulates, because this format has a minimum of one shape
   --  and the k-quant's is eight of another.
   --
   --  This is what llama.cpp reaches with `ggml_gemv_q4_0_8x8_q8_0` over
   --  its own `block_q4_0x8`. The eight is the same eight.
   procedure Rows_By_Panels_Q40
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      package IL renames Model_Runner.Quantization.Interleave;

      Panel : constant Element_Count := IL.Panel_Rows;
      Strip : constant := 8;

      Span  : constant B.Byte_Count := IL.Legacy_Block_Bytes;

      --  Blocks one call of the insertion covers. A row is walked in chunks
      --  of this many rather than in one pass, because the table below is
      --  sixty-four bytes a block and a row of thirty-two thousand elements
      --  is a thousand of them: chunking keeps the table inside the first
      --  level cache and costs one extra load and store of the eight
      --  running sums for every chunk.
      Chunk_Room : constant := 128;

      --  What the insertion reads for each block, in the order it reads it:
      --  the eight vectors' activation scales, then the eight starting
      --  values of their accumulators, which is minus eight times each
      --  vector's activation total over the block. Sixteen words a block so
      --  that both halves land on a thirty-two byte boundary.
      type Band_Table is
        array (0 .. Chunk_Room * 16 - 1) of N.Real with Alignment => 32;
      type Mark_Table is
        array (0 .. Chunk_Room * 16 - 1) of Interfaces.Integer_32;

      --  The strip's eight running sums, eight rows apiece: what the
      --  insertion loads at entry and stores at exit.
      type Work_Table is
        array (0 .. Strip * 8 - 1) of N.Real with Alignment => 32;

      --  Where each vector of the strip reads. One pointer is live in the
      --  insertion at a time -- the quants are in registers, so a vector's
      --  turn needs only its own activations -- and this is where it comes
      --  from.
      type Feed_Table is array (0 .. Strip - 1) of System.Address;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;

      Bands : Band_Table;
      Marks : Mark_Table with Import, Address => Bands'Address;
      Work  : Work_Table;
      Feeds : Feed_Table;

      At_Vector : Element_Count := 0;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));

      Places : Vector_Places;

      Base   : B.Byte_Index;
      At_Row : Element_Count;

      --  Where a vector's activations for one block begin.
      function Reading
        (Vector : Element_Count; Block : Element_Count) return Element_Count
      is (Values'First + First + Held (Vector) * Stride + Block * 32);

      --  One pass of the strip over the panel that is standing, adding
      --  lanes From through Last into the sums.
      --
      --  A batch that is not a whole number of strips takes its last strip
      --  from the end rather than the ragged edge, as the k-quant's kernel
      --  does: the lanes the two strips have in common are added once, by
      --  the first of them.
      procedure Run_Wide (From : Element_Count; Last : Element_Count) is
         At_Block : Element_Count := 0;
      begin
         for Vector in Element_Count range 0 .. Strip - 1 loop
            Places (Natural (Vector)) :=
              (First + Held (Vector) * Stride) / Activation_Block;
         end loop;

         Work := [others => 0.0];

         while At_Block < Blocks loop
            declare
               Chunk : constant Element_Count :=
                 Element_Count'Min (Chunk_Room, Blocks - At_Block);
               Head  : constant B.Byte_Index :=
                 Base + B.Byte_Count (At_Block) * Span;
            begin
               for Vector in Element_Count range 0 .. Strip - 1 loop
                  Feeds (Natural (Vector)) :=
                    Values (Reading (Vector, At_Block))'Address;
               end loop;

               for Block in Element_Count range 0 .. Chunk - 1 loop
                  for Vector in Element_Count range 0 .. Strip - 1 loop
                     declare
                        use type Interfaces.Integer_32;

                        At_It : constant Element_Count :=
                          Places (Natural (Vector)) + At_Block + Block;
                     begin
                        Bands
                          (Natural (Block * 16 + Vector)) :=
                            Scales (Scales'First + At_It);
                        Marks
                          (Natural (Block * 16 + 8 + Vector)) :=
                            Interfaces.Integer_32 (-8)
                            * Totals (Totals'First + At_It);
                     end;
                  end loop;
               end loop;

               System.Machine_Code.Asm
                 (
                  "vmovups 0(%0), %%ymm16" & LF &
                  "vmovups 32(%0), %%ymm17" & LF &
                  "vmovups 64(%0), %%ymm18" & LF &
                  "vmovups 96(%0), %%ymm19" & LF &
                  "vmovups 128(%0), %%ymm20" & LF &
                  "vmovups 160(%0), %%ymm21" & LF &
                  "vmovups 192(%0), %%ymm22" & LF &
                  "vmovups 224(%0), %%ymm23" & LF &
                  "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
                  "vpsrlw $12, %%ymm3, %%ymm3" & LF &
                  "vpsllw $8, %%ymm3, %%ymm2" & LF &
                  "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
                  "movq %1, %%r11" & LF &
                  "movq %2, %%r9" & LF &
                  "xorq %%rdx, %%rdx" & LF &
                  "movq %4, %%rcx" & LF &
                  "1:" & LF &
                  "vcvtph2ps 0(%%r11), %%ymm4" & LF &
                  "vmovdqu 16(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm24" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm25" & LF &
                  "vmovdqu 48(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm26" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm27" & LF &
                  "vmovdqu 80(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm28" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm29" & LF &
                  "vmovdqu 112(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm30" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm31" & LF &
                  "movq 0(%3), %%r10" & LF &
                  "vpbroadcastd 32(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 0(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm16" & LF &
                  "movq 8(%3), %%r10" & LF &
                  "vpbroadcastd 36(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 4(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm17" & LF &
                  "movq 16(%3), %%r10" & LF &
                  "vpbroadcastd 40(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 8(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm18" & LF &
                  "movq 24(%3), %%r10" & LF &
                  "vpbroadcastd 44(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 12(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm19" & LF &
                  "movq 32(%3), %%r10" & LF &
                  "vpbroadcastd 48(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 16(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm20" & LF &
                  "movq 40(%3), %%r10" & LF &
                  "vpbroadcastd 52(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 20(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm21" & LF &
                  "movq 48(%3), %%r10" & LF &
                  "vpbroadcastd 56(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 24(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm22" & LF &
                  "movq 56(%3), %%r10" & LF &
                  "vpbroadcastd 60(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 28(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm23" & LF &
                  "addq $144, %%r11" & LF &
                  "addq $64, %%r9" & LF &
                  "addq $32, %%rdx" & LF &
                  "decq %%rcx" & LF &
                  "jne 1b" & LF &
                  "vmovups %%ymm16, 0(%0)" & LF &
                  "vmovups %%ymm17, 32(%0)" & LF &
                  "vmovups %%ymm18, 64(%0)" & LF &
                  "vmovups %%ymm19, 96(%0)" & LF &
                  "vmovups %%ymm20, 128(%0)" & LF &
                  "vmovups %%ymm21, 160(%0)" & LF &
                  "vmovups %%ymm22, 192(%0)" & LF &
                  "vmovups %%ymm23, 224(%0)",
                  Inputs   =>
                    [System.Address'Asm_Input ("r", Work'Address),
                     System.Address'Asm_Input ("r", Data (Head)'Address),
                     System.Address'Asm_Input ("r", Bands'Address),
                     System.Address'Asm_Input ("r", Feeds'Address),
                     Element_Count'Asm_Input ("r", Chunk)],
                  Clobber  =>
                    "rcx,rdx,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,"
                    & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                    & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                    & "memory",
                  Volatile => True);

               At_Block := At_Block + Chunk;
            end;
         end loop;

         for Vector in From .. Last loop
            declare
               At_It : constant Element_Count :=
                 At_Row * Count + At_Vector + Vector;
            begin
               for Row in Element_Count range 0 .. Panel - 1 loop
                  Sums (Sums'First + At_It + Row * Count) :=
                    Sums (Sums'First + At_It + Row * Count)
                    + N.Wide_Real
                        (Work (Natural (Vector * Panel + Row)));
               end loop;
            end;
         end loop;
      end Run_Wide;

      --  The same panel against one vector, which is what a generated token
      --  multiplies. The strip above would read the weights once and do
      --  eight times the arithmetic; this reads them once and does one.
      procedure Run_One is
         At_Block : Element_Count := 0;
      begin
         Places (0) := First / Activation_Block;
         Work := [others => 0.0];

         while At_Block < Blocks loop
            declare
               Chunk : constant Element_Count :=
                 Element_Count'Min (Chunk_Room, Blocks - At_Block);
               Head  : constant B.Byte_Index :=
                 Base + B.Byte_Count (At_Block) * Span;
            begin
               Feeds (0) := Values (Reading (0, At_Block))'Address;

               for Block in Element_Count range 0 .. Chunk - 1 loop
                  declare
                     use type Interfaces.Integer_32;

                     At_It : constant Element_Count :=
                       Places (0) + At_Block + Block;
                  begin
                     Bands (Natural (Block * 16)) :=
                       Scales (Scales'First + At_It);
                     Marks (Natural (Block * 16 + 8)) :=
                       Interfaces.Integer_32 (-8)
                       * Totals (Totals'First + At_It);
                  end;
               end loop;

               System.Machine_Code.Asm
                 (
                  "vmovups 0(%0), %%ymm16" & LF &
                  "vpcmpeqd %%ymm3, %%ymm3, %%ymm3" & LF &
                  "vpsrlw $12, %%ymm3, %%ymm3" & LF &
                  "vpsllw $8, %%ymm3, %%ymm2" & LF &
                  "vpor %%ymm2, %%ymm3, %%ymm3" & LF &
                  "movq %1, %%r11" & LF &
                  "movq %2, %%r9" & LF &
                  "xorq %%rdx, %%rdx" & LF &
                  "movq %4, %%rcx" & LF &
                  "1:" & LF &
                  "vcvtph2ps 0(%%r11), %%ymm4" & LF &
                  "vmovdqu 16(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm24" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm25" & LF &
                  "vmovdqu 48(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm26" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm27" & LF &
                  "vmovdqu 80(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm28" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm29" & LF &
                  "vmovdqu 112(%%r11), %%ymm0" & LF &
                  "vpandd %%ymm3, %%ymm0, %%ymm30" & LF &
                  "vpsrlw $4, %%ymm0, %%ymm1" & LF &
                  "vpandd %%ymm3, %%ymm1, %%ymm31" & LF &
                  "movq 0(%3), %%r10" & LF &
                  "vpbroadcastd 32(%%r9), %%ymm6" & LF &
                  "vpdpbusd 0(%%r10,%%rdx,1)%{1to8%}, %%ymm24, %%ymm6" & LF &
                  "vpdpbusd 16(%%r10,%%rdx,1)%{1to8%}, %%ymm25, %%ymm6" & LF &
                  "vpdpbusd 4(%%r10,%%rdx,1)%{1to8%}, %%ymm26, %%ymm6" & LF &
                  "vpdpbusd 20(%%r10,%%rdx,1)%{1to8%}, %%ymm27, %%ymm6" & LF &
                  "vpdpbusd 8(%%r10,%%rdx,1)%{1to8%}, %%ymm28, %%ymm6" & LF &
                  "vpdpbusd 24(%%r10,%%rdx,1)%{1to8%}, %%ymm29, %%ymm6" & LF &
                  "vpdpbusd 12(%%r10,%%rdx,1)%{1to8%}, %%ymm30, %%ymm6" & LF &
                  "vpdpbusd 28(%%r10,%%rdx,1)%{1to8%}, %%ymm31, %%ymm6" & LF &
                  "vmulps 0(%%r9)%{1to8%}, %%ymm4, %%ymm5" & LF &
                  "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                  "vfmadd231ps %%ymm5, %%ymm6, %%ymm16" & LF &
                  "addq $144, %%r11" & LF &
                  "addq $64, %%r9" & LF &
                  "addq $32, %%rdx" & LF &
                  "decq %%rcx" & LF &
                  "jne 1b" & LF &
                  "vmovups %%ymm16, 0(%0)",
                  Inputs   =>
                    [System.Address'Asm_Input ("r", Work'Address),
                     System.Address'Asm_Input ("r", Data (Head)'Address),
                     System.Address'Asm_Input ("r", Bands'Address),
                     System.Address'Asm_Input ("r", Feeds'Address),
                     Element_Count'Asm_Input ("r", Chunk)],
                  Clobber  =>
                    "rcx,rdx,r9,r10,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,"
                    & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                    & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                    & "memory",
                  Volatile => True);

               At_Block := At_Block + Chunk;
            end;
         end loop;

         declare
            At_It : constant Element_Count := At_Row * Count + At_Vector;
         begin
            for Row in Element_Count range 0 .. Panel - 1 loop
               Sums (Sums'First + At_It + Row * Count) :=
                 Sums (Sums'First + At_It + Row * Count)
                 + N.Wide_Real (Work (Natural (Row)));
            end loop;
         end;
      end Run_One;
   begin
      Taken := False;

      if Rows = 0
        or else Rows mod Panel /= 0
        or else Blocks = 0
        or else Count = 0
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                      (Data, Offset,
                       IL.Panel_Bytes (G.Type_Q4_0, Rows, Blocks))
      then
         return;
      end if;

      for At_Panel in Element_Count range 0 .. Rows / Panel - 1 loop
         Base :=
           Data'First + Offset
           + B.Byte_Count (At_Panel) * B.Byte_Count (Blocks) * Span;
         At_Row := At_Panel * Panel;

         if Count = 1 then
            At_Vector := 0;
            Run_One;
         else
            for Which in Element_Count range 0 .. (Count / Strip) - 1 loop
               At_Vector := Which * Strip;
               Run_Wide (0, Strip - 1);
            end loop;

            if Count mod Strip /= 0 then
               if Count < Strip then
                  At_Vector := 0;
                  Run_Wide (0, Count - 1);
               else
                  At_Vector := Count - Strip;
                  Run_Wide (Strip - Count mod Strip, Strip - 1);
               end if;
            end if;
         end if;
      end loop;

      Taken := True;
   end Rows_By_Panels_Q40;

   --------------------------
   -- Rows_By_Strips_Q4K --
   --------------------------

   --  What Rows_By_Strips does for the eight-bit format, done for the
   --  four-bit k-quant.
   --
   --  The two are the same shape and differ in three things, and none of
   --  them changes the arithmetic around the instruction.
   --
   --  A quant is a nibble rather than a byte, so one thirty-two byte read
   --  serves two sub-blocks: the low nibbles are the first and the high
   --  nibbles the second, which is the order the format stores them in and
   --  the same pairing the decoder beside this reads them in. Masking gives
   --  the one and a shift with the same mask gives the other, which is four
   --  instructions where the eight-bit format needs two -- and they serve
   --  twice as many sub-blocks, so it is the same cost per multiply.
   --
   --  A nibble is *already* what the instruction's unsigned operand wants.
   --  The eight-bit format has to be biased by a hundred and twenty-eight
   --  and the bias taken back out of the answer; a four-bit quant is zero
   --  to fifteen and goes in as it lies. The correction this format needs
   --  instead is its own: a value is the scale times the quant less a
   --  minimum, and the minimum's term is the sub-block's activation total
   --  again -- the same Totals table, used for the format it was put there
   --  for.
   --
   --  A block is two hundred and fifty-six elements rather than thirty-two,
   --  so the insertion walks eight sub-blocks to a turn and the weights
   --  advance by a hundred and forty-four bytes where the activations
   --  advance by two hundred and fifty-six.
   procedure Rows_By_Strips_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      --  The sub-block factor as a whole number, held twice in the
      --  thirty-two bits, and the block's own scale. The factor multiplies
      --  the integer dot product and the scale is applied once a
      --  super-block, so neither is folded into the other and the table
      --  below has an entry for every sub-block and row rather than for
      --  every sub-block, row and vector.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;
      Downs     : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;

      --  How many of the strip's four vectors are real. A batch is not a
      --  multiple of four and the instruction has no shorter form, so the
      --  last strip recomputes a vector it has already done rather than
      --  reading past the end of the batch, and drops the answer.
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Panel_Rows : constant := 2;
      Strip      : constant := 4;

      --  Sub-blocks to a block of this format.
      Deep       : constant := 8;

      --  The widest row this reads, in sub-blocks.
      Scale_Room : constant := 1024;

      --  One slot for every sub-block, row and vector as before, and the
      --  same stride, so the insertion still walks it with the counter it
      --  walks the activation with. What is in it changed: the first
      --  sixteen of every sixty-four are the sub-block factors of the two
      --  rows as whole numbers, the next eight are the block's scale
      --  against each vector's, and the rest is unused. A quarter of the
      --  entries and a quarter of the arithmetic that fills them.
      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1)
        of Interfaces.Integer_32;
      Scaling : Strip_Scales;

      function As_Bits is new Ada.Unchecked_Conversion
        (N.Real, Interfaces.Integer_32);

      type Undo_Table is
        array (0 .. Panel_Rows * Strip - 1) of N.Real;
      Undo : Undo_Table;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Scale_Room - 1) of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;
      Vector_Total : Vector_Numbers;

      type Strip_Lanes is array (0 .. Panel_Rows * Strip - 1) of Lanes_8;
      Landed : Strip_Lanes;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));
   begin
      Taken := False;

      if Blocks * Deep > Scale_Room
        or else Rows mod Panel_Rows /= 0
        or else Live = 0
      then
         return;
      end if;

      --  What the strip's four vectors contribute, once for the whole call:
      --  where each begins, its scale for every sub-block, and that scale
      --  against the sub-block's activation total, which is what the
      --  minimum's term wants.
      for Vector in Element_Count range 0 .. Strip - 1 loop
         Vector_At (Natural (Vector)) :=
           (First + Held (Vector) * Stride) / Activation_Block;
      end loop;

      for Vector in 0 .. Strip - 1 loop
         for Sub in 0 .. Blocks * Deep - 1 loop
            declare
               At_Scale : constant Element_Count :=
                 Vector_At (Vector) + Sub;

               Held : constant N.Real := Scales (Scales'First + At_Scale);
            begin
               Vector_Scale (Natural (Sub) * Strip + Vector) := Held;
               Vector_Total (Natural (Sub) * Strip + Vector) :=
                 Held * N.Real (Totals (Totals'First + At_Scale));
            end;
         end loop;
      end loop;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            At_Row : constant Element_Count := Panel * Panel_Rows;
            Base   : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (At_Row);
         begin
            Undo := [others => 0.0];

            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     --  Where this row's scales were worked out, once
                     --  for the whole call rather than once for each of
                     --  the batch's strips.
                     At_Scale : constant Element_Count :=
                       ((At_Row + Row) * Blocks + Block) * Deep;

                     At_Undo : constant Natural := Natural (Row) * Strip;

                     --  This block's sixty-four slots.
                     At_Slot : constant Natural :=
                       Natural (Block) * (Panel_Rows * Strip * Deep);

                     Whole : constant N.Real :=
                       Wholes (Wholes'First
                               + (At_Row + Row) * Blocks + Block);
                  begin
                     for Sub in 0 .. Deep - 1 loop
                        declare
                           At_Vec : constant Natural :=
                             (Natural (Block) * Deep + Sub) * Strip;

                           Down : constant N.Real :=
                             Downs (Downs'First + At_Scale
                                    + Element_Count (Sub));
                        begin
                           --  The factor, which does not depend on the
                           --  vector: one entry where there were four.
                           Scaling (At_Slot + Natural (Row) * Deep + Sub) :=
                             Factors (Factors'First + At_Scale
                                      + Element_Count (Sub));

                           for K in 0 .. Strip - 1 loop
                              Undo (At_Undo + K) :=
                                Undo (At_Undo + K)
                                + Down * Vector_Total (At_Vec + K);
                           end loop;
                        end;
                     end loop;

                     --  And the two scales, once for the whole
                     --  super-block: the activation's is the same for all
                     --  eight of its sub-blocks, which is what quantizing
                     --  a k-quant's activations by super-block bought.
                     for K in 0 .. Strip - 1 loop
                        Scaling
                          (At_Slot + Panel_Rows * Deep
                           + Natural (Row) * Strip + K) :=
                          As_Bits
                            (Whole
                             * Vector_Scale
                                 (Natural (Block) * Deep * Strip + K));
                     end loop;
                  end;
               end loop;
            end loop;

            Landed := [others => [others => 0.0]];

            System.Machine_Code.Asm
              ("movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %8, %%rax" & LF &
               "1:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vmovdqu 16(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vmovdqu 16(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vmovdqu 48(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vmovdqu 80(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm27" & LF &
               "vmovdqu 112(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm4, %%ymm1" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm5, %%ymm1" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm31" & LF &
               "vcvtdq2ps %%ymm24, %%ymm1" & LF &
               "vfmadd231ps 64(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm16" & LF &
               "vcvtdq2ps %%ymm25, %%ymm1" & LF &
               "vfmadd231ps 68(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm17" & LF &
               "vcvtdq2ps %%ymm26, %%ymm1" & LF &
               "vfmadd231ps 72(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm18" & LF &
               "vcvtdq2ps %%ymm27, %%ymm1" & LF &
               "vfmadd231ps 76(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm19" & LF &
               "vcvtdq2ps %%ymm28, %%ymm1" & LF &
               "vfmadd231ps 80(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm20" & LF &
               "vcvtdq2ps %%ymm29, %%ymm1" & LF &
               "vfmadd231ps 84(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm21" & LF &
               "vcvtdq2ps %%ymm30, %%ymm1" & LF &
               "vfmadd231ps 88(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm22" & LF &
               "vcvtdq2ps %%ymm31, %%ymm1" & LF &
               "vfmadd231ps 92(%7,%%rdx,1)%{1to8%}, %%ymm1, %%ymm23" & LF &
               "addq $144, %%rcx" & LF &
               "addq $256, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm16, 0(%0)" & LF &
               "vmovaps %%ymm17, 32(%0)" & LF &
               "vmovaps %%ymm18, 64(%0)" & LF &
               "vmovaps %%ymm19, 96(%0)" & LF &
               "vmovaps %%ymm20, 128(%0)" & LF &
               "vmovaps %%ymm21, 160(%0)" & LF &
               "vmovaps %%ymm22, 192(%0)" & LF &
               "vmovaps %%ymm23, 224(%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Data (Base + Row_Bytes)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (0) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (1) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (2) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (3) * Stride)'Address),
                  System.Address'Asm_Input ("r", Scaling (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm3,ymm4,ymm5,ymm16,ymm17,"
                 & "ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,ymm24,ymm25,"
                 & "ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Live - 1 loop
                  declare
                     Which : constant Natural :=
                       Natural (Row) * Strip + Natural (Vector);
                     Total : N.Wide_Real := 0.0;
                     At_It : constant Element_Count :=
                       (At_Row + Row) * Count + At_Vector + Vector;
                  begin
                     for Lane in Landed (Which)'Range loop
                        Total := Total + N.Wide_Real (Landed (Which) (Lane));
                     end loop;

                     Sums (Sums'First + At_It) :=
                       Sums (Sums'First + At_It)
                       + Total - N.Wide_Real (Undo (Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips_Q4K;

   --------------------------
   -- Rows_By_Strips_Q5K --
   --------------------------

   --  What Rows_By_Strips_Q4K does, done for the five-bit k-quant, and the
   --  same shape: two rows against four vectors, eight accumulators held in
   --  registers from a panel's first block to its last.
   --
   --  The one difference is the fifth bit, which the format keeps in
   --  thirty-two bytes of its own at the head of the block rather than in
   --  the quant. It is read once a row a block and stays in a register
   --  across the four groups; each of the eight sub-blocks then costs a
   --  word shift, a mask and an or to put its bit back on the nibble --
   --  twenty-four instructions a block against the two hundred and
   --  eighty-eight the multiply-adds cost, which is what makes this worth
   --  doing rather than decoding the block into binary32 first.
   procedure Rows_By_Strips_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      --  As for the four-bit strip: the factor as a whole number held twice
      --  in the thirty-two bits, and the block's own scale apart from it.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;
      Downs     : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;

      --  How many of the strip's four vectors are real. A batch is not a
      --  multiple of four and the instruction has no shorter form, so the
      --  last strip recomputes a vector it has already done rather than
      --  reading past the end of the batch, and drops the answer.
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Panel_Rows : constant := 2;
      Strip      : constant := 4;

      --  Sub-blocks to a block of this format.
      Deep       : constant := 8;

      --  The widest row this reads, in sub-blocks.
      Scale_Room : constant := 1024;

      --  As for the four-bit strip: the same sixty-four slots a block and
      --  the same stride, holding the two rows' sub-block factors as whole
      --  numbers and then the eight scales of the block against each
      --  vector.
      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1)
        of Interfaces.Integer_32;
      Scaling : Strip_Scales;

      function As_Bits is new Ada.Unchecked_Conversion
        (N.Real, Interfaces.Integer_32);

      type Undo_Table is
        array (0 .. Panel_Rows * Strip - 1) of N.Real;
      Undo : Undo_Table;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Scale_Room - 1) of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;
      Vector_Total : Vector_Numbers;

      type Strip_Lanes is array (0 .. Panel_Rows * Strip - 1) of Lanes_8;
      Landed : Strip_Lanes;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));
   begin
      Taken := False;

      if Blocks * Deep > Scale_Room
        or else Rows mod Panel_Rows /= 0
        or else Live = 0
      then
         return;
      end if;

      --  What the strip's four vectors contribute, once for the whole call:
      --  where each begins, its scale for every sub-block, and that scale
      --  against the sub-block's activation total, which is what the
      --  minimum's term wants.
      for Vector in Element_Count range 0 .. Strip - 1 loop
         Vector_At (Natural (Vector)) :=
           (First + Held (Vector) * Stride) / Activation_Block;
      end loop;

      for Vector in 0 .. Strip - 1 loop
         for Sub in 0 .. Blocks * Deep - 1 loop
            declare
               At_Scale : constant Element_Count :=
                 Vector_At (Vector) + Sub;

               Held : constant N.Real := Scales (Scales'First + At_Scale);
            begin
               Vector_Scale (Natural (Sub) * Strip + Vector) := Held;
               Vector_Total (Natural (Sub) * Strip + Vector) :=
                 Held * N.Real (Totals (Totals'First + At_Scale));
            end;
         end loop;
      end loop;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            At_Row : constant Element_Count := Panel * Panel_Rows;
            Base   : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (At_Row);
         begin
            Undo := [others => 0.0];

            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     At_Scale : constant Element_Count :=
                       ((At_Row + Row) * Blocks + Block) * Deep;

                     At_Undo : constant Natural := Natural (Row) * Strip;

                     At_Slot : constant Natural :=
                       Natural (Block) * (Panel_Rows * Strip * Deep);

                     Whole : constant N.Real :=
                       Wholes (Wholes'First
                               + (At_Row + Row) * Blocks + Block);
                  begin
                     for Sub in 0 .. Deep - 1 loop
                        declare
                           At_Vec : constant Natural :=
                             (Natural (Block) * Deep + Sub) * Strip;

                           Down : constant N.Real :=
                             Downs (Downs'First + At_Scale
                                    + Element_Count (Sub));
                        begin
                           Scaling (At_Slot + Natural (Row) * Deep + Sub) :=
                             Factors (Factors'First + At_Scale
                                      + Element_Count (Sub));

                           for K in 0 .. Strip - 1 loop
                              Undo (At_Undo + K) :=
                                Undo (At_Undo + K)
                                + Down * Vector_Total (At_Vec + K);
                           end loop;
                        end;
                     end loop;

                     for K in 0 .. Strip - 1 loop
                        Scaling
                          (At_Slot + Panel_Rows * Deep
                           + Natural (Row) * Strip + K) :=
                          As_Bits
                            (Whole
                             * Vector_Scale
                                 (Natural (Block) * Deep * Strip + K));
                     end loop;
                  end;
               end loop;
            end loop;

            Landed := [others => [others => 0.0]];

            System.Machine_Code.Asm
              ("movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "movl $0x10101010, %%eax" & LF &
               "vmovd %%eax, %%xmm10" & LF &
               "vpbroadcastd %%xmm10, %%ymm10" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %8, %%rax" & LF &
               "1:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vmovdqu 16(%1,%%rcx,1), %%ymm8" & LF &
               "vmovdqu 16(%2,%%rcx,1), %%ymm9" & LF &
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsllw $4, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsllw $3, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vmovdqu 48(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsllw $4, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsllw $3, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsllw $2, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsllw $1, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vmovdqu 80(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsllw $2, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsllw $1, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpand %%ymm10, %%ymm8, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $1, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vmovdqu 112(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpand %%ymm10, %%ymm9, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $1, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vmovdqu 144(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsrlw $2, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $3, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm24" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm25" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm26" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm27" & LF &
               "vmovdqu 144(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpsrlw $2, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $3, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vpdpwssd 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm28" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm29" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm30" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vpdpwssd 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm31" & LF &
               "vcvtdq2ps %%ymm24, %%ymm2" & LF &
               "vfmadd231ps 64(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vcvtdq2ps %%ymm25, %%ymm2" & LF &
               "vfmadd231ps 68(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vcvtdq2ps %%ymm26, %%ymm2" & LF &
               "vfmadd231ps 72(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vcvtdq2ps %%ymm27, %%ymm2" & LF &
               "vfmadd231ps 76(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vcvtdq2ps %%ymm28, %%ymm2" & LF &
               "vfmadd231ps 80(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vcvtdq2ps %%ymm29, %%ymm2" & LF &
               "vfmadd231ps 84(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vcvtdq2ps %%ymm30, %%ymm2" & LF &
               "vfmadd231ps 88(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vcvtdq2ps %%ymm31, %%ymm2" & LF &
               "vfmadd231ps 92(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $176, %%rcx" & LF &
               "addq $256, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm16, 0(%0)" & LF &
               "vmovaps %%ymm17, 32(%0)" & LF &
               "vmovaps %%ymm18, 64(%0)" & LF &
               "vmovaps %%ymm19, 96(%0)" & LF &
               "vmovaps %%ymm20, 128(%0)" & LF &
               "vmovaps %%ymm21, 160(%0)" & LF &
               "vmovaps %%ymm22, 192(%0)" & LF &
               "vmovaps %%ymm23, 224(%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Data (Base + Row_Bytes)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (0) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (1) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (2) * Stride)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First
                                  + Held (3) * Stride)'Address),
                  System.Address'Asm_Input ("r", Scaling (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm2,ymm3,ymm4,ymm5,ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,ymm8,ymm9,"
                 & "ymm10,ymm11,ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,"
                 & "ymm22,ymm23,memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Live - 1 loop
                  declare
                     Which : constant Natural :=
                       Natural (Row) * Strip + Natural (Vector);
                     Total : N.Wide_Real := 0.0;
                     At_It : constant Element_Count :=
                       (At_Row + Row) * Count + At_Vector + Vector;
                  begin
                     for Lane in Landed (Which)'Range loop
                        Total := Total + N.Wide_Real (Landed (Which) (Lane));
                     end loop;

                     Sums (Sums'First + At_It) :=
                       Sums (Sums'First + At_It)
                       + Total - N.Wide_Real (Undo (Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips_Q5K;

   --------------------------
   -- Rows_By_Strips_Q6K --
   --------------------------

   --  The same strip, for the six-bit k-quant, which is the format a
   --  "_M" file puts on its output projection and a few of its other
   --  tensors. That is a sixth of such a file by weight and was half of it
   --  by time, because it was the only format left in one taking the
   --  floating-point path.
   --
   --  Three things differ from the four-bit kernel beside it.
   --
   --  A quant is six bits and lives in two places: four in a nibble of the
   --  low array and two in a field of the shared byte, at a shift the group
   --  decides. Assembling thirty-two of them is a mask, a shift, a second
   --  mask, a shift and an or -- five instructions for a block, against the
   --  four-bit format's two, and still nothing beside the twenty the four
   --  vectors then spend multiplying them.
   --
   --  A scale covers sixteen elements where an activation block covers
   --  thirty-two, so one block wants two of them. The instruction is what
   --  makes that free: the byte dot product sums four bytes into each of
   --  eight lanes, so the first sixteen bytes land in lanes nought to three
   --  and the second sixteen in lanes four to seven -- the two halves are
   --  already apart when the sums arrive. Two masked multiply-adds, one per
   --  half of the register, and nothing has to be split.
   --
   --  The quants go in unsigned, without the thirty-two the format takes
   --  off them, because unsigned is what the instruction's first operand
   --  wants. Taking it back out needs the activation's sum over each
   --  sixteen -- not over each thirty-two, which is what Totals holds -- so
   --  this one is summed here rather than read. That is four vectors' worth
   --  of adds a strip, against the twenty multiplies each of those adds
   --  serves.
   procedure Rows_By_Strips_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;

      Steps     : Model_Runner.Numerics.Real_Array;

      --  The half's signed scale as a whole number, held twice in the
      --  thirty-two bits, and the block's own scale apart from it.
      Factors   : Sum_Array;
      Wholes    : Model_Runner.Numerics.Real_Array;

      --  The activation summed over every sixteen, from the quantizer.
      Half_Sums : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Live      : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Panel_Rows : constant := 2;
      Strip      : constant := 4;

      --  Sixteen scales to a block, and eight activation blocks.
      Halves     : constant := 16;
      Deep       : constant := 8;

      Scale_Room : constant := 64;

      --  A hundred and thirty-six words a block: a hundred and
      --  twenty-eight of whole numbers, being each of the eight
      --  thirty-two element groups' two half scales replicated four times
      --  for each of the two rows, and then eight floating-point numbers,
      --  being the block's own scale against each vector's for each row.
      --  The byte instruction's result spans two halves, so the operand
      --  that scales it has to as well -- which a full register can do and
      --  a broadcast cannot.
      Slot : constant := Panel_Rows * Strip * Halves + Panel_Rows * Strip;

      type Strip_Scales is
        array (0 .. Slot * Scale_Room - 1) of Interfaces.Integer_32;
      Scaling : Strip_Scales;

      function As_Bits is new Ada.Unchecked_Conversion
        (N.Real, Interfaces.Integer_32);

      type Undo_Table is
        array (0 .. Panel_Rows * Strip - 1) of N.Real;
      Undo : Undo_Table;

      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Deep * Scale_Room - 1)
        of N.Real;

      --  The activation sum over every sixteen elements, times that
      --  block's activation scale, which is what the bias correction wants.
      type Half_Numbers is array (0 .. Strip * Halves * Scale_Room - 1)
        of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;
      Vector_Half  : Half_Numbers;

      type Strip_Lanes is array (0 .. Panel_Rows * Strip - 1) of Lanes_8;
      Landed : Strip_Lanes;

      --  The vector a lane of the strip reads: its own where the batch
      --  reaches that far, and the last real one where it does not.
      function Held (Vector : Element_Count) return Element_Count
      is (Element_Count'Min (At_Vector + Vector, Count - 1));
   begin
      Taken := False;

      if Blocks > Scale_Room
        or else Rows mod Panel_Rows /= 0
        or else Live = 0
      then
         return;
      end if;

      for Vector in Element_Count range 0 .. Strip - 1 loop
         Vector_At (Natural (Vector)) := First + Held (Vector) * Stride;
      end loop;

      for Vector in 0 .. Strip - 1 loop
         declare
            Origin : constant Element_Count := Vector_At (Vector);
         begin
            for Block in 0 .. Blocks * Deep - 1 loop
               Vector_Scale (Natural (Block) * Strip + Vector) :=
                 Scales (Scales'First + Origin / Activation_Block
                         + Block);
            end loop;

            --  The same sums the single-vector kernel wants, and from
            --  the same place: the quantizer. A strip formed them for four
            --  vectors, for every row tile, out of sixteen byte additions
            --  apiece.
            for Half in 0 .. Blocks * Halves - 1 loop
               Vector_Half (Natural (Half) * Strip + Vector) :=
                 N.Real (Half_Sums (Half_Sums'First
                                    + Origin / Activation_Half + Half))
                 * Scales (Scales'First + Origin / Activation_Block
                           + Half / 2);
            end loop;
         end;
      end loop;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            At_Row : constant Element_Count := Panel * Panel_Rows;
            Base   : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (At_Row);
         begin
            Undo := [others => 0.0];

            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     --  Where this row's sixteen sub-block scales were
                     --  worked out, once for the whole call rather than
                     --  once for each of the batch's strips.
                     At_Step : constant Element_Count :=
                       ((At_Row + Row) * Blocks + Block) * Halves;

                     At_Slot : constant Natural := Natural (Block) * Slot;

                     Whole : constant N.Real :=
                       Wholes (Wholes'First
                               + (At_Row + Row) * Blocks + Block);
                  begin
                     for Half in 0 .. Halves - 1 loop
                        declare
                           Step : constant Interfaces.Integer_32 :=
                             Factors (Factors'First + At_Step
                                      + Element_Count (Half));

                           Sub : constant N.Real :=
                             Steps (Steps'First + At_Step
                                    + Element_Count (Half));

                           At_Half : constant Natural :=
                             (Natural (Block) * Halves + Half) * Strip;
                           At_Undo : constant Natural :=
                             Natural (Row) * Strip;

                           --  Four lanes of the group's eight: the low
                           --  half's scale in the first four and the high
                           --  half's in the second.
                           At_Out : constant Natural :=
                             At_Slot
                             + ((Half / 2) * Panel_Rows + Natural (Row)) * 8
                             + (Half rem 2) * 4;
                        begin
                           for Lane in 0 .. 3 loop
                              Scaling (At_Out + Lane) := Step;
                           end loop;

                           for K in 0 .. Strip - 1 loop
                              Undo (At_Undo + K) :=
                                Undo (At_Undo + K)
                                + 32.0 * Sub * Vector_Half (At_Half + K);
                           end loop;
                        end;
                     end loop;

                     --  And the two scales, once for the whole block: the
                     --  activation's is the same for all eight of its
                     --  thirty-two element groups, which is what
                     --  Supers_Vectors buys this format.
                     for K in 0 .. Strip - 1 loop
                        Scaling
                          (At_Slot + Panel_Rows * Strip * Halves
                           + Natural (Row) * Strip + K) :=
                          As_Bits
                            (Whole
                             * Vector_Scale
                                 (Natural (Block) * Deep * Strip + K));
                     end loop;
                  end;
               end loop;
            end loop;

            Landed := [others => [others => 0.0]];

            System.Machine_Code.Asm
              ("movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "movl $0x03030303, %%eax" & LF &
               "vmovd %%eax, %%xmm4" & LF &
               "vpbroadcastd %%xmm4, %%ymm4" & LF &
               "movl $15, %%eax" & LF &
               "kmovw %%eax, %%k1" & LF &
               "movl $240, %%eax" & LF &
               "kmovw %%eax, %%k2" & LF &
               "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
               "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
               "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
               "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
               "vpxord %%ymm20, %%ymm20, %%ymm20" & LF &
               "vpxord %%ymm21, %%ymm21, %%ymm21" & LF &
               "vpxord %%ymm22, %%ymm22, %%ymm22" & LF &
               "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %8, %%rax" & LF &
               "1:" & LF &
               "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
               "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
               "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
               "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
               "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
               "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
               "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
               "vpxord %%ymm31, %%ymm31, %%ymm31" & LF &
               "vmovdqu 0(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 32(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 128(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 0(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 64(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 64(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 64(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 64(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 128(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 128(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 128(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 128(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 192(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 192(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 192(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 192(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vmovdqu 0(%2,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 32(%2,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 128(%2,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 0(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 0(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 0(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 0(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 32(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 32(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 96(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 32(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 96(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 32(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 96(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 32(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 96(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 64(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 160(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 64(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 160(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 64(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 160(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 64(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 160(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 96(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 224(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 96(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 224(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 96(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 224(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 96(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 224(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vmovdqu 64(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 96(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 160(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 256(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 256(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 256(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 256(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 320(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 320(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 320(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 320(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 384(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 384(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 384(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 384(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 448(%7,%%rsi,1), %%ymm1, %%ymm24" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 448(%7,%%rsi,1), %%ymm1, %%ymm25" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 448(%7,%%rsi,1), %%ymm1, %%ymm26" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 448(%7,%%rsi,1), %%ymm1, %%ymm27" & LF &
               "vmovdqu 64(%2,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 96(%2,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 160(%2,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 128(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 288(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 128(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 288(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 128(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 288(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 128(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 288(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 160(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 352(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 160(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 352(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 160(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 352(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 160(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 352(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 192(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 416(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 192(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 416(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 192(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 416(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 192(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 416(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpmaddubsw 224(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 480(%7,%%rsi,1), %%ymm1, %%ymm28" & LF &
               "vpmaddubsw 224(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 480(%7,%%rsi,1), %%ymm1, %%ymm29" & LF &
               "vpmaddubsw 224(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 480(%7,%%rsi,1), %%ymm1, %%ymm30" & LF &
               "vpmaddubsw 224(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vpdpwssd 480(%7,%%rsi,1), %%ymm1, %%ymm31" & LF &
               "vcvtdq2ps %%ymm24, %%ymm1" & LF &
               "vfmadd231ps 512(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm16" & LF &
               "vcvtdq2ps %%ymm25, %%ymm1" & LF &
               "vfmadd231ps 516(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm17" & LF &
               "vcvtdq2ps %%ymm26, %%ymm1" & LF &
               "vfmadd231ps 520(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm18" & LF &
               "vcvtdq2ps %%ymm27, %%ymm1" & LF &
               "vfmadd231ps 524(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm19" & LF &
               "vcvtdq2ps %%ymm28, %%ymm1" & LF &
               "vfmadd231ps 528(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm20" & LF &
               "vcvtdq2ps %%ymm29, %%ymm1" & LF &
               "vfmadd231ps 532(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm21" & LF &
               "vcvtdq2ps %%ymm30, %%ymm1" & LF &
               "vfmadd231ps 536(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm22" & LF &
               "vcvtdq2ps %%ymm31, %%ymm1" & LF &
               "vfmadd231ps 540(%7,%%rsi,1)%{1to8%}, %%ymm1, %%ymm23" & LF &
               "addq $210, %%rcx" & LF &
               "addq $544, %%rsi" & LF &
               "addq $256, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm16, 0(%0)" & LF &
               "vmovaps %%ymm17, 32(%0)" & LF &
               "vmovaps %%ymm18, 64(%0)" & LF &
               "vmovaps %%ymm19, 96(%0)" & LF &
               "vmovaps %%ymm20, 128(%0)" & LF &
               "vmovaps %%ymm21, 160(%0)" & LF &
               "vmovaps %%ymm22, 192(%0)" & LF &
               "vmovaps %%ymm23, 224(%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Data (Base + Row_Bytes)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + Vector_At (0))'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + Vector_At (1))'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + Vector_At (2))'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + Vector_At (3))'Address),
                  System.Address'Asm_Input ("r", Scaling (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,rsi,k1,k2,ymm0,ymm1,ymm2,ymm3,ymm4,ymm6,ymm7,"
                 & "ymm8,ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
                 & "ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
                 & "memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Live - 1 loop
                  declare
                     Which : constant Natural :=
                       Natural (Row) * Strip + Natural (Vector);
                     Total : N.Wide_Real := 0.0;
                     At_It : constant Element_Count :=
                       (At_Row + Row) * Count + At_Vector + Vector;
                  begin
                     for Lane in Landed (Which)'Range loop
                        Total := Total + N.Wide_Real (Landed (Which) (Lane));
                     end loop;

                     Sums (Sums'First + At_It) :=
                       Sums (Sums'First + At_It)
                       + Total - N.Wide_Real (Undo (Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips_Q6K;

   ------------------------
   -- Rows_Singly_Q6K --
   ------------------------

   --  The six-bit k-quant against one vector, which is what a generated
   --  token multiplies.
   --
   --  The last floating-point path in a "_M" file. Giving the format a
   --  batch kernel took that file's prompt to a quarter of what it was and
   --  left its generated token where it stood, because a token is one
   --  vector and had nowhere to go: a profile put the unpacking and the
   --  floating-point dot product together at forty-one per cent of one.
   --
   --  The same shape as the four-bit single-vector kernel beside it, with
   --  the six-bit assembly of the batch kernel above it: five instructions
   --  to build a block's thirty-two quants, one byte dot product, and two
   --  masked multiply-adds because a scale covers sixteen elements where a
   --  block covers thirty-two -- the halves arriving in separate lanes of
   --  the sum, which is what makes that free.
   procedure Rows_Singly_Q6K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Half_Sums : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Halves     : constant := 16;
      Scale_Room : constant := 64;

      --  Every scale a row needs, multiplied by the activation scale of the
      --  block it falls in: the insertion reads two of these a block.
      --  Not initialised: the block below writes every entry the insertion
      --  reads before it is read.
      Row_Scale : array (0 .. Halves * Scale_Room - 1) of N.Real;

      --  The activation's sum over every sixteen elements, times the same
      --  activation scale. One vector, so it is formed once for the whole
      --  tile rather than once a row.
      Half_Total : array (0 .. Halves * Scale_Room - 1) of N.Real;

      Landed : Lanes_8 := [others => 0.0];

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q6_K));
   begin
      Taken := False;

      if Blocks > Scale_Room then
         return;
      end if;

      --  The activation's sum over every sixteen elements, which the
      --  quantizer now hands over.
      --
      --  This was a loop of sixteen signed byte additions a half, and it
      --  ran for every row tile of every product rather than once for the
      --  vector: a thirty-two thousand row output projection is a thousand
      --  tiles, and the same hundred and twenty-eight sums were formed a
      --  thousand times. A profile found its compare and its addition at
      --  better than a quarter of every instruction the program executed.
      --  Vectorizing it took twelve instructions a half; the sums coming
      --  from the quantizer, which walks the activation once and already
      --  carries a running total, takes none.
      for Half in 0 .. Blocks * Halves - 1 loop
         Half_Total (Natural (Half)) :=
           N.Real (Half_Sums (Half_Sums'First
                              + First / Activation_Half + Half))
           * Scales (Scales'First + First / Activation_Block + Half / 2);
      end loop;

      for Row in 0 .. Rows - 1 loop
         declare
            Base : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (Row);

            Undo : N.Wide_Real := 0.0;
         begin
            for Block in 0 .. Blocks - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Base + Width * B.Byte_Count (Block);

                  Whole : constant N.Real :=
                    Scale_At (Data, At_Byte + 208);

                  --  What the minimum's term wants, summed over the block's
                  --  sixteen halves before it leaves the registers.
                  Summed_Halves : N.Real;
               begin
                  --  Sixteen halves in lanes.
                  --
                  --  A block keeps a signed byte of scale for each of its
                  --  sixteen halves, and each has to become a floating-point
                  --  number, take the block's own scale, take the
                  --  activation's scale for the thirty-two it falls in, and
                  --  be stored -- and its product with the activation's
                  --  half-total has to join a running sum. Written a half at
                  --  a time that is about ten instructions apiece and a
                  --  hundred and sixty a block, against a dot product of
                  --  sixty: a profile of a four-bit model, whose output
                  --  projection is this format, found this loop's compare
                  --  and its floating-point store among the hottest
                  --  instructions in the program, at better than a fifth of
                  --  everything it executed.
                  --
                  --  It is twenty-six here. Two sign-extending widenings
                  --  take the sixteen bytes to whole numbers eight at a
                  --  time, one convert each takes them to floating point,
                  --  the block's scale is a broadcast multiply, and the
                  --  activation's eight scales become the sixteen the
                  --  halves want by a permutation rather than by a division
                  --  in an index. The minimum's term is a multiply, a
                  --  fused multiply-add and a reduction of eight lanes to
                  --  one, in place of sixteen widening multiply-adds.
                  System.Machine_Code.Asm
                    ("vpmovsxbd (%1), %%ymm0" & LF &
                     "vpmovsxbd 8(%1), %%ymm1" & LF &
                     "vcvtdq2ps %%ymm0, %%ymm0" & LF &
                     "vcvtdq2ps %%ymm1, %%ymm1" & LF &
                     "vbroadcastss %4, %%ymm2" & LF &
                     "vmulps %%ymm2, %%ymm0, %%ymm0" & LF &
                     "vmulps %%ymm2, %%ymm1, %%ymm1" & LF &
                     "vmulps (%3), %%ymm0, %%ymm4" & LF &
                     "vfmadd231ps 32(%3), %%ymm1, %%ymm4" & LF &
                     "vextractf128 $1, %%ymm4, %%xmm5" & LF &
                     "vaddps %%xmm5, %%xmm4, %%xmm4" & LF &
                     "vmovshdup %%xmm4, %%xmm5" & LF &
                     "vaddps %%xmm5, %%xmm4, %%xmm4" & LF &
                     "vmovhlps %%xmm4, %%xmm4, %%xmm5" & LF &
                     "vaddss %%xmm5, %%xmm4, %%xmm4" & LF &
                     "vmovss %%xmm4, (%5)" & LF &
                     "vmovups (%2), %%ymm6" & LF &
                     "vmovdqu (%6), %%ymm8" & LF &
                     "vpermps %%ymm6, %%ymm8, %%ymm2" & LF &
                     "vmulps %%ymm2, %%ymm0, %%ymm0" & LF &
                     "vmovups %%ymm0, (%0)" & LF &
                     "vmovdqu 32(%6), %%ymm8" & LF &
                     "vpermps %%ymm6, %%ymm8, %%ymm2" & LF &
                     "vmulps %%ymm2, %%ymm1, %%ymm1" & LF &
                     "vmovups %%ymm1, 32(%0)",
                     Inputs   =>
                       [System.Address'Asm_Input
                          ("r", Row_Scale (Natural (Block) * Halves)'Address),
                        System.Address'Asm_Input
                          ("r", Data (At_Byte + 192)'Address),
                        System.Address'Asm_Input
                          ("r",
                           Scales
                             (Scales'First + First / Activation_Block
                              + Block * 8)'Address),
                        System.Address'Asm_Input
                          ("r", Half_Total (Natural (Block) * Halves)'Address),
                        N.Real'Asm_Input ("m", Whole),
                        System.Address'Asm_Input ("r", Summed_Halves'Address),
                        System.Address'Asm_Input ("r", Doubling (0)'Address)],
                     Clobber  =>
                       "ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,ymm8,memory",
                     Volatile => True);

                  Undo := Undo + N.Wide_Real (32.0 * Summed_Halves);
               end;
            end loop;

            Landed := [others => 0.0];

            System.Machine_Code.Asm
              ("movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm3" & LF &
               "vpbroadcastd %%xmm3, %%ymm3" & LF &
               "movl $0x03030303, %%eax" & LF &
               "vmovd %%eax, %%xmm4" & LF &
               "vpbroadcastd %%xmm4, %%ymm4" & LF &
               "movl $15, %%eax" & LF &
               "kmovw %%eax, %%k1" & LF &
               "movl $240, %%eax" & LF &
               "kmovw %%eax, %%k2" & LF &
               "vpxor %%ymm9, %%ymm9, %%ymm9" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %4, %%rax" & LF &
               "1:" & LF &
               "vmovdqu 0(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 32(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 128(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 0(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 4(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 8(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 12(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 16(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 20(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 24(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 28(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vmovdqu 64(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 96(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 160(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 32(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 36(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 40(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 44(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 48(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 52(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%2,%%rdx,4), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 56(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k1%}" & LF &
               "vfmadd231ps 60(%3,%%rdx,1)%{1to8%}, %%ymm1, %%ymm9%{%%k2%}" & LF &
               "addq $210, %%rcx" & LF &
               "addq $64, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm9, (%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First)'Address),
                  System.Address'Asm_Input ("r", Row_Scale (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,k1,k2,ymm0,ymm1,ymm2,ymm3,ymm4,ymm6,ymm7,"
                 & "ymm8,ymm9,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + Row) :=
                 Sums (Sums'First + Row) + Total - Undo;
            end;
         end;
      end loop;

      Taken := True;
   end Rows_Singly_Q6K;

   ------------------------
   -- Rows_Singly_Q4K --
   ------------------------

   --  What Rows_Singly does for the eight-bit format, done for the four-bit
   --  k-quant: one vector, and the block loop inside the insertion, with the
   --  accumulator a register from a row's first sub-block to its last.
   --
   --  A generated token is where this format was furthest behind, and for a
   --  reason worth writing down. The eight-bit format's generated token is
   --  bound by the memory path and stops getting faster at four workers;
   --  this one kept getting faster all the way to seven -- 1.510 s at two
   --  shares, 1.130 at four, 0.993 at seven -- because the floating-point
   --  path it was taking spends its time unpacking and multiplying rather
   --  than waiting for bytes. A kernel cannot help a token that is waiting.
   --  It can help one that is working.
   --
   --  The three differences from the eight-bit kernel are the three the
   --  batch kernel beside this already records: a nibble needs no bias, one
   --  read serves two sub-blocks, and the minimum's term is the sub-block's
   --  activation total taken out once at the end.
   procedure Rows_Singly_Q4K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Deep       : constant := 8;
      Scale_Room : constant := 1024;

      --  The sub-block's own six-bit factor, as a whole number and held
      --  twice in the thirty-two bits so that the insertion reads it as the
      --  broadcast operand of a sixteen-bit multiply. It never becomes a
      --  floating-point number: the insertion multiplies the integer dot
      --  product by it and keeps the running sum a whole number, which is
      --  what llama.cpp does and what takes the accumulator's dependency
      --  from four cycles a sub-block to one.
      --  Not initialised: every entry the insertion reads is written by
      --  the prologue below before it is read, and this is four kilobytes
      --  zeroed on every call otherwise -- which a profile finds as a
      --  string store at the top of the kernel.
      Row_Factor : array (0 .. Scale_Room - 1) of Interfaces.Integer_32;

      --  And the two scales a whole super-block shares, one number a
      --  block, applied once when its eight sub-blocks have been summed.
      Row_Both : array (0 .. Scale_Room / Deep - 1) of N.Real;

      Landed : Lanes_8 := [others => 0.0];

   begin
      Taken := False;

      if Blocks * Deep > Scale_Room then
         return;
      end if;

      for Row in 0 .. Rows - 1 loop
         declare
            Base : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (Row);

            --  The minimum's term, summed over the row rather than added
            --  back on every sub-block.
            Undo : N.Wide_Real := 0.0;
         begin
            --  Every block's scales, in one insertion rather than one a
            --  block.
            --
            --  What is here was already vector code -- the twelve packed
            --  bytes taken apart in lanes, the minimum's term as an integer
            --  dot product -- but it was reached from an Ada loop that ran
            --  once for each of a row's blocks. That loop is not free, and a
            --  profile made it visible: its counter, its bound and the six
            --  operand addresses it works out for an insertion it may not
            --  hoist across came to about an eighth of everything this
            --  kernel executed. The dot product below has always walked a
            --  whole row inside one insertion with two pointer increments;
            --  this now does the same.
            --
            --  Three cursors are what the four tables want: a hundred and
            --  forty-four bytes a block through the weights, thirty-two
            --  through the activation's sums and scales and the factor
            --  table they fill, and four through the one number a block
            --  that carries both scales multiplied together.
            --
            --  The minimum's term is summed here as well, in binary64 and
            --  block by block, which is the order it was summed in before.
            --  Everything this computes it computed already and in the same
            --  order, so no answer moves.
            System.Machine_Code.Asm
              ("vpxor %%xmm12, %%xmm12, %%xmm12" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %6, %%rax" & LF &
               "2:" & LF &
               "vmovdqu 4(%1,%%rcx,1), %%xmm0" & LF &
               "vpsrldq $4, %%xmm0, %%xmm1" & LF &
               "vpsrldq $8, %%xmm0, %%xmm2" & LF &
               "vpbroadcastd 0(%5), %%xmm3" & LF &
               "vpbroadcastd 4(%5), %%xmm4" & LF &
               "vpbroadcastd 8(%5), %%xmm5" & LF &
               "vpand %%xmm3, %%xmm0, %%xmm6" & LF &
               "vpand %%xmm3, %%xmm1, %%xmm7" & LF &
               "vpsrld $2, %%xmm0, %%xmm8" & LF &
               "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
               "vpand %%xmm4, %%xmm2, %%xmm9" & LF &
               "vpor %%xmm8, %%xmm9, %%xmm9" & LF &
               "vpsrld $2, %%xmm1, %%xmm8" & LF &
               "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
               "vpsrld $4, %%xmm2, %%xmm10" & LF &
               "vpand %%xmm4, %%xmm10, %%xmm10" & LF &
               "vpor %%xmm8, %%xmm10, %%xmm10" & LF &
               "vpmovzxbd %%xmm6, %%xmm6" & LF &
               "vpmovzxbd %%xmm9, %%xmm9" & LF &
               "vinserti128 $1, %%xmm9, %%ymm6, %%ymm6" & LF &
               "vpmovzxbd %%xmm7, %%xmm7" & LF &
               "vpmovzxbd %%xmm10, %%xmm10" & LF &
               "vinserti128 $1, %%xmm10, %%ymm7, %%ymm7" & LF &
               "vpmulld (%2,%%rdx,1), %%ymm7, %%ymm7" & LF &
               "vextracti128 $1, %%ymm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpshufd $0x4e, %%xmm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpshufd $0xb1, %%xmm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpbroadcastw (%1,%%rcx,1), %%xmm11" & LF &
               "vcvtph2ps %%xmm11, %%xmm11" & LF &
               "vpbroadcastw 2(%1,%%rcx,1), %%xmm13" & LF &
               "vcvtph2ps %%xmm13, %%xmm13" & LF &
               "vmulss (%4,%%rdx,1), %%xmm11, %%xmm11" & LF &
               "vmulss (%4,%%rdx,1), %%xmm13, %%xmm13" & LF &
               "vmovss %%xmm11, (%3,%%rsi,1)" & LF &
               "vcvtdq2pd %%xmm7, %%xmm7" & LF &
               "vcvtss2sd %%xmm13, %%xmm13, %%xmm13" & LF &
               "vmulsd %%xmm13, %%xmm7, %%xmm7" & LF &
               "vaddsd %%xmm7, %%xmm12, %%xmm12" & LF &
               "vpslld $16, %%ymm6, %%ymm9" & LF &
               "vpor %%ymm9, %%ymm6, %%ymm6" & LF &
               "vmovups %%ymm6, (%0,%%rdx,1)" & LF &
               "addq $144, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "addq $4, %%rsi" & LF &
               "decq %%rax" & LF &
               "jnz 2b" & LF &
               "vmovsd %%xmm12, (%7)",
               Inputs   =>
                 [System.Address'Asm_Input ("r", Row_Factor (0)'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r",
                     Totals
                       (Totals'First + First / Activation_Block)'Address),
                  System.Address'Asm_Input ("r", Row_Both (0)'Address),
                  System.Address'Asm_Input
                    ("r",
                     Scales
                       (Scales'First + First / Activation_Block)'Address),
                  System.Address'Asm_Input
                    ("r", Unpack_Masks (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks),
                  System.Address'Asm_Input ("r", Undo'Address)],
               Clobber  =>
                 "rax,rcx,rdx,rsi,xmm0,xmm1,xmm2,xmm3,xmm4,xmm5,xmm6,"
                 & "xmm7,xmm8,xmm9,xmm10,xmm11,xmm12,xmm13,ymm6,ymm7,"
                 & "ymm9,memory",
               Volatile => True);

            Landed := [others => 0.0];

            System.Machine_Code.Asm
              ("vpxor %%ymm6, %%ymm6, %%ymm6" & LF &
               "movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm7" & LF &
               "vpbroadcastd %%xmm7, %%ymm7" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "xorq %%rsi, %%rsi" & LF &
               "movq %5, %%rax" & LF &
               "1:" & LF &
               "vpxor %%ymm8, %%ymm8, %%ymm8" & LF &
               "vmovdqu 16(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 0(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vpbroadcastd 0(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vpmaddubsw 32(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vpbroadcastd 4(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 64(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vpbroadcastd 8(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vpmaddubsw 96(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vpbroadcastd 12(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 128(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vpbroadcastd 16(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vpmaddubsw 160(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vpbroadcastd 20(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpmaddubsw 192(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vpbroadcastd 24(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vpmaddubsw 224(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vpbroadcastd 28(%3,%%rdx,1), %%ymm2" & LF &
               "vpmaddwd %%ymm2, %%ymm1, %%ymm1" & LF &
               "vpaddd %%ymm1, %%ymm8, %%ymm8" & LF &
               "vcvtdq2ps %%ymm8, %%ymm8" & LF &
               "vfmadd231ps 0(%4,%%rsi,1)%{1to8%}, %%ymm8, %%ymm6" & LF &
               "addq $144, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "addq $4, %%rsi" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm6, (%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First)'Address),
                  System.Address'Asm_Input ("r", Row_Factor (0)'Address),
                  System.Address'Asm_Input ("r", Row_Both (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,rsi,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + Row) :=
                 Sums (Sums'First + Row) + Total - Undo;
            end;
         end;
      end loop;

      Taken := True;
   end Rows_Singly_Q4K;

   ------------------------
   -- Rows_Singly_Q5K --
   ------------------------

   --  What Rows_Singly_Q4K does, done for the five-bit k-quant.
   --
   --  The format is the four-bit one with a bit taken out of every quant
   --  and kept apart: two scales, twelve bytes of packed six-bit scale and
   --  minimum pairs, then thirty-two bytes holding the fifth bit of all two
   --  hundred and fifty-six elements, then the nibbles. Every field the
   --  four-bit kernel reads is in the same place and read by the same code;
   --  the block is thirty-two bytes longer and the quants start at
   --  forty-eight rather than sixteen.
   --
   --  Putting the fifth bit back costs three instructions a sub-block and
   --  one constant register. The bit wanted for sub-block s is bit s of the
   --  byte, so a word shift brings it to bit four of its own byte -- left
   --  by four for the first sub-block, right by three for the last -- a
   --  mask of one in sixteen per byte drops whatever the shift dragged in
   --  from the neighbour, and an or puts it on the nibble. The quant is
   --  then zero to thirty-one, which is still what the byte dot product's
   --  unsigned operand wants, so everything around the instruction is the
   --  four-bit kernel's unchanged: no bias, and the minimum's term taken
   --  out once a row against the sub-block's activation total.
   procedure Rows_Singly_Q5K
     (Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Taken     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      Deep       : constant := 8;
      Scale_Room : constant := 1024;

      --  Both scales multiplied together, one for every sub-block, so the
      --  insertion reads one number a sub-block rather than three.
      --  Not initialised: every entry the insertion reads is written by
      --  the prologue below before it is read, and this is four kilobytes
      --  zeroed on every call otherwise -- which a profile finds as a
      --  string store at the top of the kernel.
      Row_Scale : array (0 .. Scale_Room - 1) of N.Real;

      Landed : Lanes_8 := [others => 0.0];

   begin
      Taken := False;

      if Blocks * Deep > Scale_Room then
         return;
      end if;

      for Row in 0 .. Rows - 1 loop
         declare
            Base : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (Row);

            --  The minimum's term, summed over the row rather than added
            --  back on every sub-block.
            Undo : N.Wide_Real := 0.0;
         begin
            --  Every block's scales, in one insertion rather than one a
            --  block, exactly as the four-bit kernel's are.
            --
            --  The dot product below has always walked a whole row inside
            --  one insertion with two pointer increments; this was called
            --  once a block from Ada and paid for the call each time -- its
            --  counter, its bound, and the operand addresses it works out
            --  for an insertion it may not hoist across. Two cursors
            --  replace them: a hundred and seventy-six bytes a block
            --  through the weights, and thirty-two through the activation's
            --  sums and scales and the scale table they fill.
            --
            --  The minimum's term is summed here as well, in binary64 and
            --  block by block, which is the order it was summed in before.
            --  Everything this computes it computed already and in the same
            --  order, so no answer moves.
            System.Machine_Code.Asm
              ("vpxor %%xmm12, %%xmm12, %%xmm12" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %6, %%rax" & LF &
               "2:" & LF &
               "vmovdqu 4(%1,%%rcx,1), %%xmm0" & LF &
               "vpsrldq $4, %%xmm0, %%xmm1" & LF &
               "vpsrldq $8, %%xmm0, %%xmm2" & LF &
               "vpbroadcastd 0(%3), %%xmm3" & LF &
               "vpbroadcastd 4(%3), %%xmm4" & LF &
               "vpbroadcastd 8(%3), %%xmm5" & LF &
               "vpand %%xmm3, %%xmm0, %%xmm6" & LF &
               "vpand %%xmm3, %%xmm1, %%xmm7" & LF &
               "vpsrld $2, %%xmm0, %%xmm8" & LF &
               "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
               "vpand %%xmm4, %%xmm2, %%xmm9" & LF &
               "vpor %%xmm8, %%xmm9, %%xmm9" & LF &
               "vpsrld $2, %%xmm1, %%xmm8" & LF &
               "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
               "vpsrld $4, %%xmm2, %%xmm10" & LF &
               "vpand %%xmm4, %%xmm10, %%xmm10" & LF &
               "vpor %%xmm8, %%xmm10, %%xmm10" & LF &
               "vpmovzxbd %%xmm6, %%xmm6" & LF &
               "vpmovzxbd %%xmm9, %%xmm9" & LF &
               "vinserti128 $1, %%xmm9, %%ymm6, %%ymm6" & LF &
               "vpmovzxbd %%xmm7, %%xmm7" & LF &
               "vpmovzxbd %%xmm10, %%xmm10" & LF &
               "vinserti128 $1, %%xmm10, %%ymm7, %%ymm7" & LF &
               "vpmulld (%2,%%rdx,1), %%ymm7, %%ymm7" & LF &
               "vextracti128 $1, %%ymm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpshufd $0x4e, %%xmm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpshufd $0xb1, %%xmm7, %%xmm8" & LF &
               "vpaddd %%xmm8, %%xmm7, %%xmm7" & LF &
               "vpbroadcastw (%1,%%rcx,1), %%xmm11" & LF &
               "vcvtph2ps %%xmm11, %%xmm11" & LF &
               "vpbroadcastw 2(%1,%%rcx,1), %%xmm13" & LF &
               "vcvtph2ps %%xmm13, %%xmm13" & LF &
               "vmulss (%4,%%rdx,1), %%xmm11, %%xmm11" & LF &
               "vmulss (%4,%%rdx,1), %%xmm13, %%xmm13" & LF &
               "vcvtdq2pd %%xmm7, %%xmm7" & LF &
               "vcvtss2sd %%xmm13, %%xmm13, %%xmm13" & LF &
               "vmulsd %%xmm13, %%xmm7, %%xmm7" & LF &
               "vaddsd %%xmm7, %%xmm12, %%xmm12" & LF &
               "vcvtdq2ps %%ymm6, %%ymm6" & LF &
               "vbroadcastss %%xmm11, %%ymm8" & LF &
               "vmulps %%ymm8, %%ymm6, %%ymm6" & LF &
               "vmovups %%ymm6, (%0,%%rdx,1)" & LF &
               "addq $176, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 2b" & LF &
               "vmovsd %%xmm12, (%5)",
               Inputs   =>
                 [System.Address'Asm_Input ("r", Row_Scale (0)'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r",
                     Totals
                       (Totals'First + First / Activation_Block)'Address),
                  System.Address'Asm_Input
                    ("r", Unpack_Masks (0)'Address),
                  System.Address'Asm_Input
                    ("r",
                     Scales
                       (Scales'First + First / Activation_Block)'Address),
                  System.Address'Asm_Input ("r", Undo'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,xmm0,xmm1,xmm2,xmm3,xmm4,xmm5,xmm6,xmm7,"
                 & "xmm8,xmm9,xmm10,xmm11,xmm12,xmm13,ymm6,ymm7,ymm8,"
                 & "memory",
               Volatile => True);

            Landed := [others => 0.0];

            System.Machine_Code.Asm
              ("vpxor %%ymm6, %%ymm6, %%ymm6" & LF &
               "movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm7" & LF &
               "vpbroadcastd %%xmm7, %%ymm7" & LF &
               "movl $0x10101010, %%eax" & LF &
               "vmovd %%eax, %%xmm9" & LF &
               "vpbroadcastd %%xmm9, %%ymm9" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %4, %%rax" & LF &
               "1:" & LF &
               "vmovdqu 16(%1,%%rcx,1), %%ymm8" & LF &
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpsllw $4, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm4, %%ymm4" & LF &
               "vpsllw $3, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 0(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 4(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpsllw $2, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm4, %%ymm4" & LF &
               "vpsllw $1, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 8(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 12(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpand %%ymm9, %%ymm8, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm4, %%ymm4" & LF &
               "vpsrlw $1, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 16(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 20(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vmovdqu 144(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
               "vpsrlw $2, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm4, %%ymm4" & LF &
               "vpsrlw $3, %%ymm8, %%ymm10" & LF &
               "vpand %%ymm9, %%ymm10, %%ymm10" & LF &
               "vpor %%ymm10, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%2,%%rdx,8), %%ymm4, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 24(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%2,%%rdx,8), %%ymm5, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vbroadcastss 28(%3,%%rdx,1), %%ymm2" & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6" & LF &
               "addq $176, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "decq %%rax" & LF &
               "jnz 1b" & LF &
               "vmovaps %%ymm6, (%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First)'Address),
                  System.Address'Asm_Input ("r", Row_Scale (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,ymm7,"
                 & "ymm8,ymm9,ymm10,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + Row) :=
                 Sums (Sums'First + Row) + Total - Undo;
            end;
         end;
      end loop;

      Taken := True;
   end Rows_Singly_Q5K;

   ----------
   -- Rows --
   ----------

   procedure Rows
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
      Interleaved : Boolean := False)
   is
      LF : constant Character := ASCII.LF;

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (Format));
      Per   : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Ok := False;

      if not Has_Integer_Kernel (Format)
        or else Blocks = 0
        or else Count = 0
        or else Rows = 0
        or else Rows > Row_Tile
        or else Per mod Activation_Block /= 0
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                     (Data, Offset,
                      Row_Bytes * B.Byte_Count (Rows - 1)
                      + Width * B.Byte_Count (Blocks))
      then
         return;
      end if;

      --  The two k-quants written a panel of rows at a time.
      --
      --  Nothing else reaches this: those are the only formats ever laid
      --  out this way, and a matrix that is takes this kernel or none. A
      --  refusal is a share nobody has computed, which the caller sends to
      --  the floating-point path -- and that path reads a panel's row
      --  through Interleave.Extract_Row, so it is slow and it is right.
      if Interleaved then
         if not Deep
           or else (if Format = G.Type_Q4_0 then Per /= 32 else Per /= 256)
           or else (Format /= G.Type_Q4_K
                    and then Format /= G.Type_Q5_K
                    and then Format /= G.Type_Q6_K
                    and then Format /= G.Type_Q4_0)
         then
            return;
         end if;

         declare
            Reach : constant Element_Count :=
              First + (Count - 1) * Stride + Blocks * Per;

            --  Eight sub-blocks to a block, and a scale and a total for
            --  each of them; the six-bit format keeps a scale for every
            --  sixteen elements instead, so its own table is twice as long,
            --  and the legacy four-bit format's block IS an activation
            --  block, so its own is an eighth.
            Blocks_Reach : constant Element_Count :=
              (First + (Count - 1) * Stride) / Activation_Block
              + Blocks * (if Format = G.Type_Q4_0 then 1 else 8);
            Halves_Reach : constant Element_Count :=
              (First + (Count - 1) * Stride) / Activation_Half + Blocks * 16;

            Done : Boolean;
         begin
            if First < Values'First
              or else First mod Activation_Block /= 0
              or else Stride mod Activation_Block /= 0
              or else Reach < First
              or else Reach - 1 > Values'Last
              or else Scales'Length < Blocks_Reach
            then
               return;
            end if;

            if Format = G.Type_Q4_0 then
               if Totals'Length < Blocks_Reach then
                  return;
               end if;

               Rows_By_Panels_Q40
                 (Data, Offset, Rows, Blocks, Values, Scales, Totals,
                  First, Stride, Count, Sums, Done);
            elsif Format = G.Type_Q4_K or else Format = G.Type_Q5_K then
               if Totals'Length < Blocks_Reach then
                  return;
               end if;

               if Format = G.Type_Q4_K then
                  Rows_By_Panels_Q4K
                    (Data, Offset, Rows, Blocks, Values, Scales, Totals,
                     First, Stride, Count, Sums, Done);
               else
                  Rows_By_Panels_Q5K
                    (Data, Offset, Rows, Blocks, Values, Scales, Totals,
                     First, Stride, Count, Sums, Done);
               end if;
            else
               if Halves'Length < Halves_Reach then
                  return;
               end if;

               Rows_By_Panels_Q6K
                 (Data, Offset, Rows, Blocks, Values, Scales, Halves,
                  First, Stride, Count, Sums, Done);
            end if;

            Ok := Done;
            return;
         end;
      end if;

      --  The six-bit k-quant, which is a strip and nothing else: what a
      --  "_M" file puts on its output projection and a handful of its other
      --  tensors, and the only format left in such a file taking the
      --  floating-point path.
      if Format = G.Type_Q6_K then
         if not Deep or else Per /= 256 then
            return;
         end if;

         --  One vector, which is a generated token, and the last of this
         --  format's products that went the other way.
         if Count = 1 then
            declare
               Reach : constant Element_Count := First + Blocks * Per;
               Done  : Boolean;
            begin
               if First < Values'First
                 or else First mod Activation_Block /= 0
                 or else Reach < First
                 or else Reach - 1 > Values'Last
                 or else Scales'Length
                           < First / Activation_Block + Blocks * 8
               then
                  return;
               end if;

               Rows_Singly_Q6K
                 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                  Halves, First, Sums, Done);

               if not Done then
                  return;
               end if;
            end;

            Ok := True;
            return;
         end if;

         if Count < 4 or else Rows mod 2 /= 0 then
            return;
         end if;

         declare
            Reach : constant Element_Count :=
              First + (Count - 1) * Stride + Blocks * Per;
            Blocks_Reach : constant Element_Count :=
              (First + (Count - 1) * Stride) / Activation_Block + Blocks * 8;
            Done : Boolean;
         begin
            if First < Values'First
              or else First mod Activation_Block /= 0
              or else Stride mod Activation_Block /= 0
              or else Reach < First
              or else Reach - 1 > Values'Last
              or else Scales'Length < Blocks_Reach
            then
               return;
            end if;

            --  Every sub-block scale of the tile, worked out once for the
            --  whole call: sixteen a block, and a batch has a quarter of
            --  its length of strips that each wanted the same ones.
            declare
               Room : constant Element_Count := Rows * Blocks * 16;

               Held : N.Real_Array (0 .. Room - 1);

               --  The same half's signed byte as a whole number, held twice
               --  in the thirty-two bits so that the strip kernel reads
               --  four of them as one operand of a sixteen-bit multiply.
               --  Kept beside the folded form rather than instead of it:
               --  the dot product wants the factor apart from the block's
               --  scale and the minimum's term wants them together, and one
               --  extra store a half is cheaper than reconstructing either.
               Held_Factor : Sum_Array (0 .. Room - 1);

               --  And the block's own scale, apart from both.
               Held_Whole : N.Real_Array (0 .. Rows * Blocks - 1);
            begin
               for Row in 0 .. Rows - 1 loop
                  for Block in 0 .. Blocks - 1 loop
                     declare
                        At_Byte : constant B.Byte_Index :=
                          Data'First + Offset
                          + Row_Bytes * B.Byte_Count (Row)
                          + Width * B.Byte_Count (Block);

                        Whole : constant N.Real :=
                          Scale_At (Data, At_Byte + 208);

                        At_Step : constant Element_Count :=
                          (Row * Blocks + Block) * 16;
                     begin
                        for Half in 0 .. 15 loop
                           declare
                              --  Read as the signed byte it is rather than
                              --  as an unsigned one corrected by a test:
                              --  the test is a branch in a loop of sixteen
                              --  that a profile finds among the hottest
                              --  instructions in this file, and it stops
                              --  the loop being lanes.
                              Signed : constant Integer :=
                                Integer
                                  (To_Signed
                                     (Data
                                        (At_Byte + 192
                                         + B.Byte_Count (Half))));
                           begin
                              Held (At_Step + Element_Count (Half)) :=
                                Whole * N.Real (Signed);

                              Held_Factor (At_Step + Element_Count (Half)) :=
                                Twice (Signed);
                           end;
                        end loop;

                        Held_Whole (Row * Blocks + Block) := Whole;
                     end;
                  end loop;
               end loop;

               for At_Strip in Element_Count range 0 .. (Count + 3) / 4 - 1
               loop
                  Rows_By_Strips_Q6K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Held, Held_Factor, Held_Whole, Halves, First, Stride,
                     Count, At_Strip * 4,
                     Element_Count'Min (4, Count - At_Strip * 4), Sums,
                     Done);

                  if not Done then
                     return;
                  end if;
               end loop;
            end;
         end;

         Ok := True;
         return;
      end if;

      --  The two k-quants that carry a scale and a minimum: four bits to a
      --  quant, and four with a fifth kept apart. They take the same two
      --  shapes, read the same twelve packed scale bytes and correct the
      --  same way, so they share this branch and differ only in which pair
      --  of insertions it enters.
      --
      --  Neither has a baseline kernel: a host without the byte dot product
      --  goes back to the floating-point path for both.
      if Format = G.Type_Q4_K or else Format = G.Type_Q5_K then
         if not Deep or else Per /= 256 then
            return;
         end if;

         --  One vector, which is a generated token, and which has a kernel
         --  of its own for the same reason the eight-bit format does: the
         --  accumulators are one to a row rather than one to a row and a
         --  vector, so the sub-block loop lives inside the insertion.
         if Count = 1 then
            declare
               Reach : constant Element_Count := First + Blocks * Per;
               Done  : Boolean;
            begin
               if First < Values'First
                 or else First mod Activation_Block /= 0
                 or else Reach < First
                 or else Reach - 1 > Values'Last
                 or else Scales'Length
                           < First / Activation_Block + Blocks * 8
                 or else Totals'Length
                           < First / Activation_Block + Blocks * 8
               then
                  return;
               end if;

               if Format = G.Type_Q4_K then
                  Rows_Singly_Q4K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Totals, First, Sums, Done);
               else
                  Rows_Singly_Q5K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Totals, First, Sums, Done);
               end if;

               if not Done then
                  return;
               end if;
            end;

            Ok := True;
            return;
         end if;

         if Count < 4 or else Rows mod 2 /= 0 then
            return;
         end if;

         declare
            Reach : constant Element_Count :=
              First + (Count - 1) * Stride + Blocks * Per;

            --  Eight sub-blocks to a block, and a scale and a total for
            --  each of them.
            Blocks_Reach : constant Element_Count :=
              (First + (Count - 1) * Stride) / Activation_Block + Blocks * 8;

            Done : Boolean;
         begin
            if First < Values'First
              or else First mod Activation_Block /= 0
              or else Stride mod Activation_Block /= 0
              or else Reach < First
              or else Reach - 1 > Values'Last
              or else Scales'Length < Blocks_Reach
              or else Totals'Length < Blocks_Reach
            then
               return;
            end if;

            --  Both sides of every sub-block's scale, worked out once for
            --  the whole call. Every strip wants the same numbers, and a
            --  batch has a quarter of its length of strips: reading them
            --  in the strip meant unpacking twelve bytes of six-bit fields
            --  twenty-eight times over on a 110-token prompt.
            declare
               Room : constant Element_Count := Rows * Blocks * 8;

               Held_Up   : N.Real_Array (0 .. Room - 1);
               Held_Down : N.Real_Array (0 .. Room - 1);

               --  The sub-block factor as a whole number, held twice in the
               --  thirty-two bits so that the four-bit strip kernel reads it
               --  as the broadcast operand of a sixteen-bit multiply. Three
               --  instructions and a store beside what this block already
               --  does: the numbers are in the register before the convert.
               Held_Factor : Sum_Array (0 .. Room - 1);

               --  And the block's own scale, one for every row and block,
               --  which the same kernel applies once a super-block rather
               --  than folding into every sub-block's factor.
               Held_Whole : N.Real_Array (0 .. Rows * Blocks - 1);
            begin
               for Row in 0 .. Rows - 1 loop
                  for Block in 0 .. Blocks - 1 loop
                     declare
                        At_Byte : constant B.Byte_Index :=
                          Data'First + Offset
                          + Row_Bytes * B.Byte_Count (Row)
                          + Width * B.Byte_Count (Block);

                        Whole : constant N.Real := Scale_At (Data, At_Byte);
                        Least : constant N.Real :=
                          Scale_At (Data, At_Byte + 2);

                        At_Scale : constant Element_Count :=
                          (Row * Blocks + Block) * 8;

                        --  The block's scale and its least, together, so
                        --  that the block below broadcasts both from one
                        --  address.
                        Pair : constant Lanes_2 := [Whole, Least];
                     begin
                        --  The same unpack the single-vector kernels do,
                        --  and the same thirty-one instructions, less the
                        --  activation's scale: a strip applies that itself,
                        --  once for each of the four vectors it carries.
                        --
                        --  Sub_Block_Scale is what this replaces, and it
                        --  had a branch on the sub-block's number inside a
                        --  loop of eight as well as reading the same twelve
                        --  bytes five and twenty times. Here the branch was
                        --  the worse half: the first four fields and the
                        --  last four are different shapes, so the loop
                        --  could not be one thing, and a profile put this
                        --  loop's masking and shifting at about a tenth of
                        --  a four-bit run on its own.
                        --
                        --  Nothing here is a running sum, so unlike the
                        --  single-vector kernels there is no part of it
                        --  that has to stay scalar.
                        System.Machine_Code.Asm
                          ("vmovdqu (%1), %%xmm0" & LF &
                           "vpsrldq $4, %%xmm0, %%xmm1" & LF &
                           "vpsrldq $8, %%xmm0, %%xmm2" & LF &
                           "vpbroadcastd 0(%4), %%xmm3" & LF &
                           "vpbroadcastd 4(%4), %%xmm4" & LF &
                           "vpbroadcastd 8(%4), %%xmm5" & LF &
                           "vpand %%xmm3, %%xmm0, %%xmm6" & LF &
                           "vpand %%xmm3, %%xmm1, %%xmm7" & LF &
                           "vpsrld $2, %%xmm0, %%xmm8" & LF &
                           "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
                           "vpand %%xmm4, %%xmm2, %%xmm9" & LF &
                           "vpor %%xmm8, %%xmm9, %%xmm9" & LF &
                           "vpsrld $2, %%xmm1, %%xmm8" & LF &
                           "vpand %%xmm5, %%xmm8, %%xmm8" & LF &
                           "vpsrld $4, %%xmm2, %%xmm10" & LF &
                           "vpand %%xmm4, %%xmm10, %%xmm10" & LF &
                           "vpor %%xmm8, %%xmm10, %%xmm10" & LF &
                           "vpmovzxbd %%xmm6, %%xmm6" & LF &
                           "vpmovzxbd %%xmm9, %%xmm9" & LF &
                           "vinserti128 $1, %%xmm9, %%ymm6, %%ymm6" & LF &
                           "vpmovzxbd %%xmm7, %%xmm7" & LF &
                           "vpmovzxbd %%xmm10, %%xmm10" & LF &
                           "vinserti128 $1, %%xmm10, %%ymm7, %%ymm7" & LF &
                           "vpslld $16, %%ymm6, %%ymm11" & LF &
                           "vpor %%ymm11, %%ymm6, %%ymm11" & LF &
                           "vmovups %%ymm11, (%5)" & LF &
                           "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                           "vcvtdq2ps %%ymm7, %%ymm7" & LF &
                           "vbroadcastss 0(%3), %%ymm8" & LF &
                           "vbroadcastss 4(%3), %%ymm9" & LF &
                           "vmulps %%ymm8, %%ymm6, %%ymm6" & LF &
                           "vmulps %%ymm9, %%ymm7, %%ymm7" & LF &
                           "vmovups %%ymm6, (%0)" & LF &
                           "vmovups %%ymm7, (%2)",
                           Inputs   =>
                             [System.Address'Asm_Input
                                ("r", Held_Up (At_Scale)'Address),
                              System.Address'Asm_Input
                                ("r", Data (At_Byte + 4)'Address),
                              System.Address'Asm_Input
                                ("r", Held_Down (At_Scale)'Address),
                              System.Address'Asm_Input ("r", Pair'Address),
                              System.Address'Asm_Input
                                ("r", Unpack_Masks (0)'Address),
                              System.Address'Asm_Input
                                ("r", Held_Factor (At_Scale)'Address)],
                           Clobber  =>
                             "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,"
                             & "ymm8,ymm9,ymm10,ymm11,memory",
                           Volatile => True);

                        Held_Whole (Row * Blocks + Block) := Whole;
                     end;
                  end loop;
               end loop;

               for At_Strip in Element_Count range 0 .. (Count + 3) / 4 - 1 loop
                  if Format = G.Type_Q4_K then
                     Rows_By_Strips_Q4K
                       (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                        Held_Factor, Held_Whole, Held_Down,
                        Totals, First, Stride, Count, At_Strip * 4,
                        Element_Count'Min (4, Count - At_Strip * 4), Sums,
                        Done);
                  else
                     Rows_By_Strips_Q5K
                       (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                        Held_Factor, Held_Whole, Held_Down,
                        Totals, First, Stride, Count, At_Strip * 4,
                        Element_Count'Min (4, Count - At_Strip * 4), Sums,
                        Done);
                  end if;

                  if not Done then
                     return;
                  end if;
               end loop;
            end;
         end;

         Ok := True;
         return;
      end if;

      --  One vector, and the block loop inside the insertion.
      --
      --  A generated token multiplies one vector, so the accumulators are
      --  one for each row of the tile rather than one for each row and each
      --  vector of a batch -- four against a thousand, which is the whole
      --  reason this shape is possible here and not for a prompt. Four fit
      --  in registers, so the block loop can live inside the insertion and
      --  the accumulator never touch memory.
      --
      --  That is worth three of the eleven instructions a block costs
      --  otherwise: the load and the store of the accumulator go, and the
      --  separate multiply and add become one fused multiply-add.
      if Deep and then Count = 1 and then Format = G.Type_Q8_0 then
         Rows_Singly
           (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            First, 0, 1, Sums);
         Ok := True;
         return;
      end if;

      --  Every element this call will read, proved once, exactly as the
      --  single-row entry proves its own. The loops below run with the
      --  runtime checks suppressed.
      declare
         Reach : constant Element_Count :=
           First + (Count - 1) * Stride + Blocks * Per;
         Blocks_Reach : constant Element_Count :=
           (First + (Count - 1) * Stride) / Activation_Block + Blocks;
      begin
         if First < Values'First
           or else First mod Activation_Block /= 0
           or else Stride mod Activation_Block /= 0
           or else Reach < First
           or else Reach - 1 > Values'Last
           or else Scales'Length < Blocks_Reach
           or else Totals'Length < Blocks_Reach
         then
            return;
         end if;
      end;

      --  A batch, swept four vectors at a time.
      --
      --  This is the single-vector kernel's shape made to fit a batch: the
      --  accumulators stay in registers for a whole row, the weights are
      --  read where the file holds them, and the bias comes out once at the
      --  end rather than on every block. What made that impossible for a
      --  batch was the number of accumulators, and a strip of four vectors
      --  is the answer -- eight live sums against a thousand.
      --
      --  The vectors a strip of four does not reach go one at a time
      --  through the single-vector kernel, which computes the same thing by
      --  the same instructions and needs only to be told where its answers
      --  belong.
      if Deep and then Rows mod 2 = 0 and then Count >= 4
        and then Format = G.Type_Q8_0
      then
         declare
            Full : constant Element_Count := (Count / 8) * 8;
            Four : Element_Count := Full;
            Done : Boolean;

            --  The weight side of every scale, worked out once for the
            --  whole call. Every strip wants the same numbers, and there
            --  are a quarter of the batch's length of them.
            Held : N.Real_Array (0 .. Rows * Blocks - 1);
         begin
            for Row in 0 .. Rows - 1 loop
               declare
                  --  Width is the block's size, worked out once at the top
                  --  of this procedure. Asking for it again inside the loop
                  --  was a call that did not inline and a third of what
                  --  this procedure cost: a profile found it there,
                  --  between an overflow check and a bounds compare that
                  --  are gone with it.
                  pragma Suppress (Index_Check);
                  pragma Suppress (Range_Check);
                  pragma Suppress (Overflow_Check);

                  Base : constant B.Byte_Index :=
                    Data'First + Offset + Row_Bytes * B.Byte_Count (Row);
                  At_Row : constant Element_Count := Row * Blocks;
               begin
                  for Block in 0 .. Blocks - 1 loop
                     Held (At_Row + Block) :=
                       Scale_At
                         (Data, Base + Width * B.Byte_Count (Block));
                  end loop;
               end;
            end loop;

            for At_Strip in Element_Count range 0 .. Full / 8 - 1 loop
               Rows_By_Strips
                 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                  Held, Totals, First, Stride, Count, At_Strip * 8, Sums,
                  Done);

               if not Done then
                  return;
               end if;
            end loop;

            --  Four of what a strip of eight could not reach, and then the
            --  three or fewer left after that one at a time.
            if Count - Full >= 4 then
               Rows_By_Strips_Four
                 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                  Held, Totals, First, Stride, Count, Full, Sums, Done);

               if not Done then
                  return;
               end if;

               Four := Full + 4;
            end if;

            for Which in Four .. Count - 1 loop
               Rows_Singly
                 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                  First + Which * Stride, Which, Count, Sums);
            end loop;

            Ok := True;
            return;
         end;
      end if;

      --  A block of four rows against a block of the activation, which is
      --  loaded once and multiplied four times. A row at a time loaded it
      --  once per row: the bytes are in the nearest cache either way, and
      --  being in the nearest cache is not the same as being in a register.
      --
      --  Four sums are live at once as well, which is what gives the
      --  processor four independent chains to interleave where one row gave
      --  it one and a multiply-add latency to wait out.
      declare
         pragma Suppress (Index_Check);
         pragma Suppress (Range_Check);
         pragma Suppress (Overflow_Check);

         subtype Block_Range is Element_Count range 0 .. Activation_Block - 1;

         --  Aligned to thirty-two bytes because the insertion below reads
         --  them with an aligned move. The compiled loop does not care, and
         --  the alignment costs it nothing.
         type Wide_Block is array (Block_Range) of Interfaces.Integer_16
           with Alignment => 32;
         subtype Row_Range is Element_Count range 0 .. Row_Tile - 1;
         type Row_Blocks is array (Row_Range) of Wide_Block
           with Alignment => 32;
         type Row_Scales is array (Row_Range) of N.Real;

         --  Whether the format keeps two elements to a byte, and what a
         --  quant is centred on. The eight-bit format holds a signed byte
         --  and is biased into range by 128; the four-bit one holds a
         --  nibble that is already in range and is centred on eight. Every
         --  other difference between the two is none: a block is
         --  thirty-two elements behind one half-precision scale in both.
         Nibbled : constant Boolean := Format = G.Type_Q4_0;
         Bias    : constant Interfaces.Integer_32 :=
           (if Nibbled then 8 else 128);

         --  The eight partial sums the multiply-add leaves, kept across a
         --  row's blocks rather than reduced at each of them.
         --  Four rather than the eight the instruction leaves, because
         --  these live in memory and are walked once per block: eight of
         --  them for every row and vector of a tile is thirty-two kilobytes,
         --  which is the whole of this machine's first-level cache. Folding
         --  the halves together costs two instructions a block and halves
         --  what the block loop streams.
         Lane_Count : constant := 4;
         subtype Lane_Range is Element_Count range 0 .. Lane_Count - 1;
         --  Sixteen, which is what four binary32 values occupy, and not
         --  thirty-two. Asking for more than the data needs pads every entry
         --  out to the alignment, and the insertion below walks these by
         --  hand with a stride of sixteen: a stride the type does not have
         --  is wrong answers, which is what it gave, twice, before the test
         --  that compares the compilations said so.
         type Lanes is array (Lane_Range) of N.Real with Alignment => 16;

         --  One set for every vector and row of this tile, laid out with the
         --  rows together so that a block's pass over them is sequential.
         type Lane_Table is array (Element_Count range <>) of Lanes;

         --  The same thirty-two weights as bytes, which is what the byte
         --  dot product wants and what the file already holds. Biased into
         --  unsigned where they are read, because the instruction is
         --  unsigned against signed and the bias comes back out below.
         type Byte_Block is array (Block_Range) of Interfaces.Unsigned_8
           with Alignment => 32;
         type Row_Bytes_Table is array (Row_Range) of Byte_Block
           with Alignment => 32;

         Weights : Row_Blocks;
         Raw     : Row_Bytes_Table;
         Scaling : Row_Scales;
         Active  : Wide_Block;

         --  What the bias costs, in the shape the instruction can take it.
         --
         --  Biasing the weight byte by 128 makes the instruction's unsigned
         --  operand and turns sum(w*a) into sum(w*a) + 128*sum(a). The
         --  second term wants the activation block's own sum, which is the
         --  Totals table this is already handed -- it was put there for the
         --  formats that carry a minimum and is unread for this one.
         --
         --  Held as a vector with the whole correction in its first lane and
         --  nothing in the others, so that undoing the bias is one integer
         --  add inside the insertion. Accumulating it outside instead -- a
         --  multiply and a read-modify-write of memory for every row, vector
         --  and block -- cost fifteen per cent of a prompt, which was more
         --  than the instruction saved. It is built once for each vector and
         --  block, and every row of the tile adds the same one.
         type Fix_Lanes is array (Lane_Range) of Interfaces.Integer_32
           with Alignment => 16;

         Fixing : Fix_Lanes := [others => 0];

         Running : Lane_Table (0 .. Count * Rows - 1)
           := [others => [others => 0.0]];
      begin
         for Block in 0 .. Blocks - 1 loop
            for Row in 0 .. Rows - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Data'First + Offset
                    + Row_Bytes * B.Byte_Count (Row)
                    + Width * B.Byte_Count (Block);
               begin
                  Scaling (Row) :=
                    Scale_At (Data, At_Byte);

                  if Nibbled then
                     --  A nibble is already what the instruction's unsigned
                     --  operand wants, and what comes off it is eight rather
                     --  than a hundred and twenty-eight -- the format's own
                     --  centring, taken out below against the activation's
                     --  block total exactly as the eight-bit format's bias
                     --  is. The low nibble of byte j is element j and the
                     --  high nibble is element j + 16, which is the layout
                     --  the four-bit decoder beside this reads.
                     for Index in Element_Count range
                       0 .. Activation_Block / 2 - 1
                     loop
                        declare
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + 2 + B.Byte_Count (Index));

                           Upper : constant Element_Count :=
                             Index + Activation_Block / 2;
                        begin
                           if Deep then
                              Raw (Row) (Index) := Packed and 16#0F#;
                              Raw (Row) (Upper) :=
                                Interfaces.Shift_Right (Packed, 4);
                           else
                              Weights (Row) (Index) :=
                                Interfaces.Integer_16
                                  (Integer (Packed and 16#0F#) - 8);
                              Weights (Row) (Upper) :=
                                Interfaces.Integer_16
                                  (Integer
                                     (Interfaces.Shift_Right (Packed, 4))
                                   - 8);
                           end if;
                        end;
                     end loop;
                  elsif Deep then
                     --  No widening at all: the byte the file holds, with
                     --  its sign bit flipped, is the operand. Flipping that
                     --  bit is adding 128 to a two's complement byte, which
                     --  is exactly the bias the instruction's unsigned
                     --  operand needs.
                     for Index in Block_Range loop
                        Raw (Row) (Index) :=
                          Data (At_Byte + 2 + B.Byte_Count (Index))
                          xor 16#80#;
                     end loop;
                  else
                     for Index in Block_Range loop
                        declare
                           U : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + 2 + B.Byte_Count (Index));
                        begin
                           Weights (Row) (Index) :=
                             Interfaces.Integer_16
                               (if U < 128 then Integer (U)
                                else Integer (U) - 256);
                        end;
                     end loop;
                  end if;
               end;
            end loop;

            for Which in 0 .. Count - 1 loop
               declare
                  At_Value : constant Element_Count :=
                    First + Which * Stride + Block * Activation_Block;
                  At_Scale : constant Element_Count :=
                    At_Value / Activation_Block;
                  Scaled   : constant N.Real :=
                    Scales (Scales'First + At_Scale);
               begin
                  if Deep then
                     --  No copy: the byte instruction's memory operand needs
                     --  no alignment, so it reads the activations where the
                     --  quantizer left them.
                     --
                     --  Copying them into a block of their own cost about
                     --  four instructions for every multiply-add the kernel
                     --  performs -- thirty-two moves shared between eight
                     --  rows -- which a counter found and no amount of
                     --  reading the source had.
                     declare
                        use type Interfaces.Integer_32;
                     begin
                        Fixing (0) :=
                          (-Bias) * Totals (Totals'First + At_Scale);
                     end;
                  else
                     for Index in Block_Range loop
                        Active (Index) :=
                          Interfaces.Integer_16
                            (Values (Values'First + At_Value + Index));
                     end loop;
                  end if;

                  --  Four rows to an insertion, and what that is really
                  --  for is the three operands it stops re-reading.
                  --
                  --  A counter said so. Reading the loop the compiler
                  --  produced, one row at a time cost eighteen instructions
                  --  and one of them multiplied: the rest were the
                  --  activations loaded again, the bias correction loaded
                  --  again, four pointers advanced and a branch -- all of
                  --  which are the same for every row of the group. Loading
                  --  them once and holding them in registers is twelve and a
                  --  half instructions a row instead.
                  --
                  --  The operands, which the insertion names by number:
                  --  %0 the group's four running lane sums, %1 its four
                  --  rows of weight bytes, %2 the activation block where
                  --  the quantizer left it, %3 the group's four weight
                  --  scales, %4 the bias correction, %5 the activation
                  --  scale. Only %5 is a register the compiler chose; the
                  --  rest are addresses this walks by hand, which is why
                  --  the stride of the type they point into is a fact this
                  --  code depends on.
                  if Deep and then Rows mod 4 = 0 then
                     for Group in 0 .. Rows / 4 - 1 loop
                        declare
                           LF : constant Character := ASCII.LF;
                        begin
                           System.Machine_Code.Asm
                             ("vmovdqu (%2), %%ymm4" & LF &
                              "vmovdqa (%4), %%xmm3" & LF &
                              "vmulss 0(%3), %5, %%xmm5" & LF &
                              "vmovdqa 0(%1), %%ymm0" & LF &
                              "vpxor %%xmm1, %%xmm1, %%xmm1" & LF &
                              "vpdpbusd %%ymm4, %%ymm0, %%ymm1" & LF &
                              "vextracti128 $1, %%ymm1, %%xmm2" & LF &
                              "vpaddd %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vpaddd %%xmm3, %%xmm1, %%xmm1" & LF &
                              "vcvtdq2ps %%xmm1, %%xmm1" & LF &
                              "vbroadcastss %%xmm5, %%xmm2" & LF &
                              "vmulps %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vaddps 0(%0), %%xmm1, %%xmm1" & LF &
                              "vmovaps %%xmm1, 0(%0)" & LF &
                              "vmulss 4(%3), %5, %%xmm5" & LF &
                              "vmovdqa 32(%1), %%ymm0" & LF &
                              "vpxor %%xmm1, %%xmm1, %%xmm1" & LF &
                              "vpdpbusd %%ymm4, %%ymm0, %%ymm1" & LF &
                              "vextracti128 $1, %%ymm1, %%xmm2" & LF &
                              "vpaddd %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vpaddd %%xmm3, %%xmm1, %%xmm1" & LF &
                              "vcvtdq2ps %%xmm1, %%xmm1" & LF &
                              "vbroadcastss %%xmm5, %%xmm2" & LF &
                              "vmulps %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vaddps 16(%0), %%xmm1, %%xmm1" & LF &
                              "vmovaps %%xmm1, 16(%0)" & LF &
                              "vmulss 8(%3), %5, %%xmm5" & LF &
                              "vmovdqa 64(%1), %%ymm0" & LF &
                              "vpxor %%xmm1, %%xmm1, %%xmm1" & LF &
                              "vpdpbusd %%ymm4, %%ymm0, %%ymm1" & LF &
                              "vextracti128 $1, %%ymm1, %%xmm2" & LF &
                              "vpaddd %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vpaddd %%xmm3, %%xmm1, %%xmm1" & LF &
                              "vcvtdq2ps %%xmm1, %%xmm1" & LF &
                              "vbroadcastss %%xmm5, %%xmm2" & LF &
                              "vmulps %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vaddps 32(%0), %%xmm1, %%xmm1" & LF &
                              "vmovaps %%xmm1, 32(%0)" & LF &
                              "vmulss 12(%3), %5, %%xmm5" & LF &
                              "vmovdqa 96(%1), %%ymm0" & LF &
                              "vpxor %%xmm1, %%xmm1, %%xmm1" & LF &
                              "vpdpbusd %%ymm4, %%ymm0, %%ymm1" & LF &
                              "vextracti128 $1, %%ymm1, %%xmm2" & LF &
                              "vpaddd %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vpaddd %%xmm3, %%xmm1, %%xmm1" & LF &
                              "vcvtdq2ps %%xmm1, %%xmm1" & LF &
                              "vbroadcastss %%xmm5, %%xmm2" & LF &
                              "vmulps %%xmm2, %%xmm1, %%xmm1" & LF &
                              "vaddps 48(%0), %%xmm1, %%xmm1" & LF &
                              "vmovaps %%xmm1, 48(%0)",
                              Inputs =>
                                [System.Address'Asm_Input
                                   ("r", Running (Which * Rows
                                                  + Group * 4)'Address),
                                 System.Address'Asm_Input
                                   ("r", Raw (Group * 4)'Address),
                                 System.Address'Asm_Input
                                   ("r", Values (Values'First
                                                 + At_Value)'Address),
                                 System.Address'Asm_Input
                                   ("r", Scaling (Group * 4)'Address),
                                 System.Address'Asm_Input
                                   ("r", Fixing'Address),
                                 N.Real'Asm_Input ("x", Scaled)],
                              Clobber  =>
                                "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,memory",
                              Volatile => True);
                        end;
                     end loop;
                  else
                     for Row in 0 .. Rows - 1 loop
                        --  Both scales at once, because the insertion
                        --  multiplies the eight sums by one number.
                        declare
                           Both : constant N.Real := Scaling (Row) * Scaled;

                           Into : Lanes renames Running (Which * Rows + Row);

                           LF : constant Character := ASCII.LF;
                        begin
                           if Deep then
                              --  Four byte products a lane where the other two
                              --  do two sixteen-bit ones, against operands half
                              --  the width and with no widening to reach them.
                              System.Machine_Code.Asm
                                ("vpxor %%xmm1, %%xmm1, %%xmm1"     & LF &
                                 "vmovdqa (%1), %%ymm0"             & LF &
                                 "vpdpbusd (%2), %%ymm0, %%ymm1"    & LF &
                                 "vextracti128 $1, %%ymm1, %%xmm2"  & LF &
                                 "vpaddd %%xmm2, %%xmm1, %%xmm1"    & LF &
                                 "vpaddd (%4), %%xmm1, %%xmm1"      & LF &
                                 "vcvtdq2ps %%xmm1, %%xmm1"         & LF &
                                 "vbroadcastss %3, %%xmm2"          & LF &
                                 "vmulps %%xmm2, %%xmm1, %%xmm1"    & LF &
                                 "vaddps (%0), %%xmm1, %%xmm1"      & LF &
                                 "vmovaps %%xmm1, (%0)",
                                 Inputs =>
                                   [System.Address'Asm_Input
                                      ("r", Into'Address),
                                    System.Address'Asm_Input
                                      ("r", Raw (Row)'Address),
                                    System.Address'Asm_Input
                                      ("r", Values (Values'First
                                                    + At_Value)'Address),
                                    --  In a register, not in memory. Asking
                                    --  for "m" makes the compiler put Both
                                    --  somewhere addressable, which it does by
                                    --  storing it to the stack one instruction
                                    --  before this reads it back: that reload
                                    --  was the hottest instruction in the
                                    --  kernel at nine per cent, for a value
                                    --  that never left the register file.
                                    N.Real'Asm_Input ("x", Both),
                                    System.Address'Asm_Input
                                      ("r", Fixing'Address)],
                                 Clobber  => "ymm0,ymm1,ymm2,memory",
                                 Volatile => True);
                           elsif Wider then
                              --  Two multiply-adds over the block, their
                              --  results added, widened to binary32, scaled and
                              --  added to what this row and vector have so far.
                              --  What is not here is the reduction to a scalar:
                              --  that happens once a row and a vector, below,
                              --  rather than once for each of a row's blocks.
                              System.Machine_Code.Asm
                                ("vmovdqa (%1), %%ymm0"            & LF &
                                 "vmovdqa 32(%1), %%ymm1"          & LF &
                                 "vpmaddwd (%2), %%ymm0, %%ymm0"   & LF &
                                 "vpmaddwd 32(%2), %%ymm1, %%ymm1" & LF &
                                 "vpaddd %%ymm1, %%ymm0, %%ymm0"   & LF &
                                 "vextracti128 $1, %%ymm0, %%xmm1" & LF &
                                 "vpaddd %%xmm1, %%xmm0, %%xmm0"   & LF &
                                 "vcvtdq2ps %%xmm0, %%xmm0"        & LF &
                                 "vbroadcastss %3, %%xmm2"         & LF &
                                 "vmulps %%xmm2, %%xmm0, %%xmm0"   & LF &
                                 "vaddps (%0), %%xmm0, %%xmm0"     & LF &
                                 "vmovaps %%xmm0, (%0)",
                                 Inputs =>
                                   [System.Address'Asm_Input
                                      ("r", Into'Address),
                                    System.Address'Asm_Input
                                      ("r", Weights (Row)'Address),
                                    System.Address'Asm_Input
                                      ("r", Active'Address),
                                    N.Real'Asm_Input ("m", Both)],
                                 Clobber  => "ymm0,ymm1,ymm2,memory",
                                 Volatile => True);
                           else
                              --  The same eight sums, in a set every x86-64
                              --  has. Four multiply-adds of eight elements
                              --  rather than two of sixteen, and the halves
                              --  added in the pairs that make the lanes come
                              --  out where the wide one puts them: the first
                              --  quarter with the third, the second with the
                              --  fourth. Everything after that is elementwise,
                              --  so the two answer the same bits.
                              System.Machine_Code.Asm
                                ("movdqa (%1), %%xmm0"        & LF &
                                 "movdqa 16(%1), %%xmm1"      & LF &
                                 "movdqa 32(%1), %%xmm2"      & LF &
                                 "movdqa 48(%1), %%xmm3"      & LF &
                                 "pmaddwd (%2), %%xmm0"       & LF &
                                 "pmaddwd 16(%2), %%xmm1"     & LF &
                                 "pmaddwd 32(%2), %%xmm2"     & LF &
                                 "pmaddwd 48(%2), %%xmm3"     & LF &
                                 "paddd %%xmm2, %%xmm0"       & LF &
                                 "paddd %%xmm3, %%xmm1"       & LF &
                                 "paddd %%xmm1, %%xmm0"       & LF &
                                 "cvtdq2ps %%xmm0, %%xmm0"    & LF &
                                 "movss %3, %%xmm4"           & LF &
                                 "shufps $0, %%xmm4, %%xmm4"  & LF &
                                 "mulps %%xmm4, %%xmm0"       & LF &
                                 "addps (%0), %%xmm0"         & LF &
                                 "movaps %%xmm0, (%0)",
                                 Inputs =>
                                   [System.Address'Asm_Input
                                      ("r", Into'Address),
                                    System.Address'Asm_Input
                                      ("r", Weights (Row)'Address),
                                    System.Address'Asm_Input
                                      ("r", Active'Address),
                                    N.Real'Asm_Input ("m", Both)],
                                 Clobber  =>
                                   "xmm0,xmm1,xmm2,xmm3,xmm4,memory",
                                 Volatile => True);
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
         end loop;

         --  And the reduction the insertions left out: once a row and a
         --  vector rather than once for each of a row's blocks.
         declare
            pragma Suppress (Index_Check);
         begin
            for Row in 0 .. Rows - 1 loop
               for Which in 0 .. Count - 1 loop
                  declare
                     Total : N.Wide_Real := 0.0;
                  begin
                     for Lane in Lane_Range loop
                        Total := Total
                          + N.Wide_Real (Running (Which * Rows + Row) (Lane));
                     end loop;

                     Sums (Sums'First + Row * Count + Which) :=
                       Sums (Sums'First + Row * Count + Which) + Total;
                  end;
               end loop;
            end loop;
         end;
      end;

      if Totals'Length = 0 then
         return;
      end if;

      Ok := True;
   end Rows;

end Model_Runner.Quantization.Integers.Kernels;
