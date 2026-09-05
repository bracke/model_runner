with System;
with System.Machine_Code;

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

   --  The same two bytes, taken by the hardware in one go.
   --
   --  Scale_At above asks Ada for a sixteen-bit number out of two bytes of
   --  a Byte_Array, which is two loads, a shift and an or before the
   --  convert can start: six instructions, and it is called once for every
   --  block of every row of every product. vpinsrw takes exactly the two
   --  bytes at the address, which with the zeroing and the convert is
   --  three, and a generated token executes eight and four tenths per cent
   --  fewer instructions for it.
   --
   --  Only Rows_Singly calls it, and the reason is measured rather than
   --  cautious. Put in Scale_At, where every format would take it, it is
   --  worth 1.7 per cent of a Q8_0 generation at the worker count this
   --  program chooses and 5.6 per cent at one worker -- and it costs Q4_K
   --  generation twenty-one per cent and a Q4_K prompt fourteen. Three
   --  instructions on a longer chain: vpinsrw is a load and an insert into
   --  one register and the convert waits behind both, where two byte loads
   --  issue beside whatever else is in flight. The eight-bit kernel has the
   --  work to hide that behind and the k-quant one does not.
   --
   --  Exactly two bytes, which matters: the wider load vcvtph2ps offers
   --  would read eight, and Q6_K keeps its scale in a block's last two.
   --
   --  The lanes above the first are zeroed rather than left as they were,
   --  so the convert is given numbers rather than whatever the register
   --  held. Only the first is read.
   function Scale_Pair_At
     (Data : B.Byte_Array;
      Here : B.Byte_Index) return N.Real
     with Inline;
   pragma Inline_Always (Scale_Pair_At);

   function Scale_Pair_At
     (Data : B.Byte_Array;
      Here : B.Byte_Index) return N.Real
   is
      LF     : constant Character := ASCII.LF;
      Result : N.Real;
   begin
      --  Not volatile: it reads its operand and writes its answer and does
      --  nothing else, so the compiler may hoist it, fold two of them
      --  together, or drop one whose answer goes unread.
      System.Machine_Code.Asm
        ("vpxor %0, %0, %0" & LF
         & "vpinsrw $0, %1, %0, %0" & LF
         & "vcvtph2ps %0, %0",
         Outputs => N.Real'Asm_Output ("=x", Result),
         Inputs  => B.Byte'Asm_Input ("m", Data (Here)));

      return Result;
   end Scale_Pair_At;

   --  The six-bit scale and minimum a Q4_K or Q5_K sub-block carries.
   --
   --  Twelve bytes hold sixteen six-bit numbers: the first four pairs whole
   --  in a byte each, and the last four split, four bits in one byte and
   --  two in the top of another that a lower sub-block is already using.
   --
   --  At body scope rather than inside a kernel because the tables the
   --  strip kernels read are built once for a whole call now, and the
   --  building is done where the call is dispatched.
   procedure Sub_Block_Scale
     (Data    : Model_Runner.Bytes.Byte_Array;
      Base    : Model_Runner.Bytes.Byte_Index;
      Index   : Natural;
      Factor  : out Interfaces.Unsigned_8;
      Minimum : out Interfaces.Unsigned_8)
   is
      function Byte_At (Position : Natural) return Interfaces.Unsigned_8
      is (Data (Base + B.Byte_Count (Position)));
   begin
      if Index < 4 then
         Factor := Byte_At (Index) and 63;
         Minimum := Byte_At (Index + 4) and 63;
      else
         Factor :=
           (Byte_At (Index + 4) and 16#0F#)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Byte_At (Index - 4), 6), 4);
         Minimum :=
           Interfaces.Shift_Right (Byte_At (Index + 4), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Byte_At (Index), 6), 4);
      end if;
   end Sub_Block_Scale;

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
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      At_Vector : Element_Count;
      Live      : Element_Count;
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
      Ups       : Model_Runner.Numerics.Real_Array;
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
      Ups       : Model_Runner.Numerics.Real_Array;
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
      Totals    : Sum_Array;
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
      Totals    : Sum_Array;
      First     : Element_Count;
      At_Sum    : Element_Count;
      Sum_Step  : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      LF : constant Character := ASCII.LF;

      --  Room for the largest run of blocks a row can have here, so that
      --  nothing is allocated inside the loop. A row of a model this reads
      --  is at most this many blocks wide; a wider one is refused above.
      Scale_Room : constant := 1024;

      --  Both scales multiplied together, one for each block, so the
      --  insertion below reads one number a block rather than two. Built
      --  once for a row, which is sixty-four multiplies against the two
      --  thousand the row itself costs.
      --  Not initialised: every entry the insertion reads is written by
      --  the prologue below before it is read, and this is four kilobytes
      --  zeroed on every call otherwise -- which a profile finds as a
      --  string store at the top of the kernel.
      Row_Scale : array (0 .. Scale_Room - 1) of N.Real;

      --  Eight partial sums, reduced once when the row is done.
      Landed : Lanes_8 := [others => 0.0];

      --  A block of this format, in bytes: a scale and thirty-two quants.
      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q8_0));
   begin
      if Blocks > Scale_Room then
         return;
      end if;

      for Row in 0 .. Rows - 1 loop
         declare
            Base : constant B.Byte_Index :=
              Data'First + Offset + Row_Bytes * B.Byte_Count (Row);

            --  What the bias put in, taken out once for the whole row: a
            --  sum over blocks of the scale against the block's own
            --  activation total.
            Undo : N.Wide_Real := 0.0;
         begin
            for Block in 0 .. Blocks - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Base + Width * B.Byte_Count (Block);

                  Scaled : constant N.Real :=
                    Scales (Scales'First + First / Activation_Block + Block);

                  Weighted : constant N.Real :=
                    (if Wider then Scale_Pair_At (Data, At_Byte)
                     else Scale_At (Data, At_Byte));
               begin
                  Row_Scale (Natural (Block)) := Weighted * Scaled;
                  Undo := Undo
                    + N.Wide_Real (Row_Scale (Natural (Block)))
                      * N.Wide_Real
                          (Totals (Totals'First
                                   + First / Activation_Block + Block));
               end;
            end loop;

            Landed := [others => 0.0];

            --  The whole row: a running accumulator in a register, one
            --  multiply-add a block, and nothing written until the end.
            System.Machine_Code.Asm
              ("vpxor %%ymm6, %%ymm6, %%ymm6"        & LF &
               "movl $0x80808080, %%eax"             & LF &
               "vmovd %%eax, %%xmm7"                 & LF &
               "vpbroadcastd %%xmm7, %%ymm7"         & LF &
               "xorq %%rcx, %%rcx"                   & LF &
               "xorq %%rdx, %%rdx"                   & LF &
               "movq %4, %%rax"                      & LF &
               "1:"                                  & LF &
               "vmovdqu (%1,%%rdx,1), %%ymm0"        & LF &
               "vpxor %%ymm7, %%ymm0, %%ymm0"        & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1"        & LF &
               "vpdpbusd (%2,%%rcx,8), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1"            & LF &
               "vbroadcastss (%3,%%rcx,1), %%ymm2"   & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6"  & LF &
               "addq $4, %%rcx"                      & LF &
               "addq $34, %%rdx"                     & LF &
               "decq %%rax"                          & LF &
               "jnz 1b"                              & LF &
               "vmovaps %%ymm6, (%0)",
               Inputs =>
                 [System.Address'Asm_Input ("r", Landed'Address),
                  System.Address'Asm_Input ("r", Data (Base + 2)'Address),
                  System.Address'Asm_Input
                    ("r", Values (Values'First + First)'Address),
                  System.Address'Asm_Input ("r", Row_Scale (0)'Address),
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm6,ymm7,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + At_Sum + Row * Sum_Step) :=
                 Sums (Sums'First + At_Sum + Row * Sum_Step)
                 + Total - 128.0 * Undo;
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
      Ups       : Model_Runner.Numerics.Real_Array;
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

      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1) of N.Real;
      Scaling : Strip_Scales;

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
                  begin
                     for Sub in 0 .. Deep - 1 loop
                        declare
                           At_Vec : constant Natural :=
                             (Natural (Block) * Deep + Sub) * Strip;
                           At_Out : constant Natural :=
                             (Natural (Block) * Deep + Sub)
                             * (Panel_Rows * Strip)
                             + Natural (Row) * Strip;
                        begin
                           declare
                              Up   : constant N.Real :=
                                Ups (Ups'First + At_Scale
                                     + Element_Count (Sub));
                              Down : constant N.Real :=
                                Downs (Downs'First + At_Scale
                                       + Element_Count (Sub));
                           begin
                              for K in 0 .. Strip - 1 loop
                                 Scaling (At_Out + K) :=
                                   Up * Vector_Scale (At_Vec + K);

                                 Undo (At_Undo + K) :=
                                   Undo (At_Undo + K)
                                   + Down * Vector_Total (At_Vec + K);
                              end loop;
                           end;
                        end;
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
               "vmovdqu 16(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vmovdqu 16(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 64(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 68(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 72(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 76(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 96(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 100(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 104(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 108(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vmovdqu 48(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 80(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 84(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 88(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 92(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 112(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 116(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 120(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 124(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 128(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 132(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 136(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 140(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 160(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 164(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 168(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 172(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vmovdqu 80(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 144(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 148(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 152(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 156(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 176(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 180(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 184(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 188(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 192(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 196(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 200(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 204(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 224(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 228(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 232(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 236(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vmovdqu 112(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 208(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 212(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 216(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 220(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 240(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 244(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 248(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 252(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
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
                 "rax,rcx,rdx,ymm0,ymm2,ymm3,ymm4,ymm5,ymm16,ymm17,ymm18,"
                 & "ymm19,ymm20,ymm21,ymm22,ymm23,memory",
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
      Ups       : Model_Runner.Numerics.Real_Array;
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

      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Scale_Room - 1) of N.Real;
      Scaling : Strip_Scales;

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
                  begin
                     for Sub in 0 .. Deep - 1 loop
                        declare
                           At_Vec : constant Natural :=
                             (Natural (Block) * Deep + Sub) * Strip;
                           At_Out : constant Natural :=
                             (Natural (Block) * Deep + Sub)
                             * (Panel_Rows * Strip)
                             + Natural (Row) * Strip;
                        begin
                           declare
                              Up   : constant N.Real :=
                                Ups (Ups'First + At_Scale
                                     + Element_Count (Sub));
                              Down : constant N.Real :=
                                Downs (Downs'First + At_Scale
                                       + Element_Count (Sub));
                           begin
                              for K in 0 .. Strip - 1 loop
                                 Scaling (At_Out + K) :=
                                   Up * Vector_Scale (At_Vec + K);

                                 Undo (At_Undo + K) :=
                                   Undo (At_Undo + K)
                                   + Down * Vector_Total (At_Vec + K);
                              end loop;
                           end;
                        end;
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 32(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 36(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 40(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 44(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 48(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 52(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 56(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 60(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 64(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 68(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 72(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 76(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 96(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 100(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 104(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 108(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 80(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 84(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 88(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 92(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 112(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 116(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 120(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 124(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpand %%ymm10, %%ymm8, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $1, %%ymm8, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 128(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 132(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 136(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 140(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 160(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 164(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 168(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 172(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vmovdqu 112(%2,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm3, %%ymm5, %%ymm5" & LF &
               "vpand %%ymm10, %%ymm9, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm4, %%ymm4" & LF &
               "vpsrlw $1, %%ymm9, %%ymm11" & LF &
               "vpand %%ymm10, %%ymm11, %%ymm11" & LF &
               "vpor %%ymm11, %%ymm5, %%ymm5" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 144(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 148(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 152(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 156(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 176(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 180(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 184(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 188(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 192(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 196(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 200(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 204(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 224(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 228(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 232(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 236(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
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
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 208(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 212(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 216(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm4, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 220(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 240(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 244(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 248(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm5, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 252(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
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
                 "rax,rcx,rdx,ymm0,ymm2,ymm3,ymm4,ymm5,ymm8,ymm9,"
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

      type Strip_Scales is
        array (0 .. Panel_Rows * Strip * Halves * Scale_Room - 1) of N.Real;
      Scaling : Strip_Scales;

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

            for Half in 0 .. Blocks * Halves - 1 loop
               declare
                  Base  : constant Element_Count :=
                    Values'First + Origin + Half * 16;
                  Total : Integer := 0;
               begin
                  for Index in Element_Count range 0 .. 15 loop
                     Total := Total + Integer (Values (Base + Index));
                  end loop;

                  Vector_Half (Natural (Half) * Strip + Vector) :=
                    N.Real (Total)
                    * Scales (Scales'First + Origin / Activation_Block
                              + Half / 2);
               end;
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
                  begin
                     for Half in 0 .. Halves - 1 loop
                        declare
                           Sub : constant N.Real :=
                             Steps (Steps'First + At_Step
                                    + Element_Count (Half));

                           At_Vec : constant Natural :=
                             (Natural (Block) * Deep + Half / 2) * Strip;
                           At_Half : constant Natural :=
                             (Natural (Block) * Halves + Half) * Strip;
                           At_Out : constant Natural :=
                             (Natural (Block) * Deep + Half / 2)
                             * (Panel_Rows * Strip * 2)
                             + Natural (Row) * (Strip * 2);
                           At_Undo : constant Natural :=
                             Natural (Row) * Strip;
                        begin
                           for K in 0 .. Strip - 1 loop
                              Scaling (At_Out + K * 2 + Half mod 2) :=
                                Sub * Vector_Scale (At_Vec + K);

                              Undo (At_Undo + K) :=
                                Undo (At_Undo + K)
                                + 32.0 * Sub * Vector_Half (At_Half + K);
                           end loop;
                        end;
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
               "movq %8, %%rax" & LF &
               "1:" & LF &
               "vmovdqu 0(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 32(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 128(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 0(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 4(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 8(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 12(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 16(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 20(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 24(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 28(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 64(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 68(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 72(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 76(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 80(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 84(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 88(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 92(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 128(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 132(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 136(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 140(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 144(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 148(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 152(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 156(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 192(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 196(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 200(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 204(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 208(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 212(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 216(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 220(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vmovdqu 0(%2,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 32(%2,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 128(%2,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 32(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 36(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 40(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 44(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 48(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 52(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 0(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 56(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 60(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 96(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 100(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 104(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 108(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 112(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 116(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 32(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 120(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 124(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 160(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 164(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 168(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 172(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 176(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 180(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 64(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 184(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 188(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 224(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 228(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 232(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 236(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 240(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 244(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 96(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 248(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 252(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vmovdqu 64(%1,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 96(%1,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 160(%1,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 256(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 260(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 264(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 268(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 272(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 276(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 280(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 284(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 320(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 324(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 328(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 332(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 336(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 340(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 344(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 348(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 384(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 388(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 392(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 396(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 400(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 404(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 408(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 412(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 448(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k1%}" & LF &
               "vfmadd231ps 452(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm16%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 456(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k1%}" & LF &
               "vfmadd231ps 460(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm17%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 464(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k1%}" & LF &
               "vfmadd231ps 468(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm18%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 472(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k1%}" & LF &
               "vfmadd231ps 476(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm19%{%%k2%}" & LF &
               "vmovdqu 64(%2,%%rcx,1), %%ymm6" & LF &
               "vmovdqu 96(%2,%%rcx,1), %%ymm7" & LF &
               "vmovdqu 160(%2,%%rcx,1), %%ymm8" & LF &
               "vpand %%ymm3, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm4, %%ymm8, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 288(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 292(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 296(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 300(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 304(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 308(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 128(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 312(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 316(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpand %%ymm3, %%ymm7, %%ymm0" & LF &
               "vpsrlw $2, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 352(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 356(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 360(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 364(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 368(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 372(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 160(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 376(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 380(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm6, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $4, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 416(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 420(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 424(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 428(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 432(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 436(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 192(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 440(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 444(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "vpsrlw $4, %%ymm7, %%ymm0" & LF &
               "vpand %%ymm3, %%ymm0, %%ymm0" & LF &
               "vpsrlw $6, %%ymm8, %%ymm2" & LF &
               "vpand %%ymm4, %%ymm2, %%ymm2" & LF &
               "vpsllw $4, %%ymm2, %%ymm2" & LF &
               "vpor %%ymm2, %%ymm0, %%ymm0" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%3,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 480(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k1%}" & LF &
               "vfmadd231ps 484(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm20%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%4,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 488(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k1%}" & LF &
               "vfmadd231ps 492(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm21%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%5,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 496(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k1%}" & LF &
               "vfmadd231ps 500(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm22%{%%k2%}" & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1" & LF &
               "vpdpbusd 224(%6,%%rdx,1), %%ymm0, %%ymm1" & LF &
               "vcvtdq2ps %%ymm1, %%ymm1" & LF &
               "vfmadd231ps 504(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k1%}" & LF &
               "vfmadd231ps 508(%7,%%rdx,2)%{1to8%}, %%ymm1, %%ymm23%{%%k2%}" & LF &
               "addq $210, %%rcx" & LF &
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
                 "rax,rcx,rdx,k1,k2,ymm0,ymm1,ymm2,ymm3,ymm4,ymm6,ymm7,"
                 & "ymm8,ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,"
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
      Row_Scale : array (0 .. Halves * Scale_Room - 1) of N.Real :=
        [others => 0.0];

      --  The activation's sum over every sixteen elements, times the same
      --  activation scale. One vector, so it is formed once for the whole
      --  tile rather than once a row.
      Half_Total : array (0 .. Halves * Scale_Room - 1) of N.Real :=
        [others => 0.0];

      Landed : Lanes_8 := [others => 0.0];

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q6_K));
   begin
      Taken := False;

      if Blocks > Scale_Room then
         return;
      end if;

      for Half in 0 .. Blocks * Halves - 1 loop
         declare
            Base  : constant Element_Count :=
              Values'First + First + Half * 16;
            Total : Integer := 0;
         begin
            for Index in Element_Count range 0 .. 15 loop
               Total := Total + Integer (Values (Base + Index));
            end loop;

            Half_Total (Natural (Half)) :=
              N.Real (Total)
              * Scales (Scales'First + First / Activation_Block + Half / 2);
         end;
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
               begin
                  for Half in 0 .. Halves - 1 loop
                     declare
                        Raw : constant Interfaces.Unsigned_8 :=
                          Data (At_Byte + 192 + B.Byte_Count (Half));

                        Signed : constant Integer :=
                          (if Raw < 128 then Integer (Raw)
                           else Integer (Raw) - 256);

                        At_Half : constant Natural :=
                          Natural (Block) * Halves + Half;

                        --  Without the activation's own scale, which the
                        --  half-total below already carries. Putting it in
                        --  both is squaring it, and squaring it is a run
                        --  that does not complete.
                        Sub : constant N.Real := Whole * N.Real (Signed);
                     begin
                        Row_Scale (At_Half) :=
                          Sub * Scales (Scales'First
                                        + First / Activation_Block
                                        + Element_Count (At_Half / 2));

                        Undo := Undo
                          + N.Wide_Real (32.0 * Sub
                                         * Half_Total (At_Half));
                     end;
                  end loop;
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

      --  Both scales multiplied together, one for every sub-block, so the
      --  insertion reads one number a sub-block rather than three.
      --  Not initialised: every entry the insertion reads is written by
      --  the prologue below before it is read, and this is four kilobytes
      --  zeroed on every call otherwise -- which a profile finds as a
      --  string store at the top of the kernel.
      Row_Scale : array (0 .. Scale_Room - 1) of N.Real;

      Landed : Lanes_8 := [others => 0.0];

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q4_K));

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
            for Block in 0 .. Blocks - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Base + Width * B.Byte_Count (Block);

                  At_Base : constant Element_Count :=
                    First / Activation_Block + Block * Deep;

                  --  The block's scale and the block's least, together.
                  Pair : constant Lanes_2 :=
                    [Scale_At (Data, At_Byte), Scale_At (Data, At_Byte + 2)];

                  --  The minimum's side of the product, one for every
                  --  sub-block, kept for the running sum below.
                  Lowered : Lanes_8;

               begin
                  --  The twelve packed bytes taken apart in lanes.
                  --
                  --  Asked one sub-block at a time, the first four read two
                  --  bytes each and the last four read three, and the bytes
                  --  they read are the same twelve over again -- five and
                  --  twenty reads where twelve will do, with a branch on
                  --  the sub-block's number around each. Ablating this
                  --  prologue away entirely -- the wrong answer, and none
                  --  of the unpacking -- took a generated token from 2.277
                  --  to 1.642 s, so it is twenty-eight per cent of what
                  --  this format costs the processor.
                  --
                  --  Taking the twelve apart a byte at a time and then
                  --  widening each byte to a floating-point number is a
                  --  hundred and twenty instructions a block, and every one
                  --  of them is the same operation on eight neighbouring
                  --  values. Written first as two Ada loops -- one to
                  --  unpack, one to multiply, with the scales read once --
                  --  it measured one to two per cent worse than the single
                  --  scalar loop it replaced, because the compiler
                  --  vectorised neither: the byte-to-float widening and the
                  --  six-bit fields split across two bytes are not shapes
                  --  it recognises.
                  --
                  --  Written by hand it is thirty-one instructions. The
                  --  twelve arrive as one unaligned sixteen-byte read --
                  --  which is inside the block, since a block is a hundred
                  --  and forty-four bytes and this reads twenty of them.
                  --  The first four fields are a mask; the last four are a
                  --  nibble from the top third of the twelve with two high
                  --  bits from the first third laid above it, which is a
                  --  shift, a mask and an or on all four at once. Both
                  --  sets widen from bytes to whole numbers in one
                  --  instruction apiece, join into a register of eight,
                  --  convert to floating point together, and take the
                  --  block's scale and the activation's scale as two
                  --  multiplies over the eight.
                  --
                  --  Bit for bit what the scalar loop computed: the same
                  --  two multiplies in the same order, on the same numbers.
                  --  The running sum below is what is not done here, and
                  --  is left in the order it was in.
                  System.Machine_Code.Asm
                    ("vmovdqu (%1), %%xmm0" & LF &
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
                     "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                     "vcvtdq2ps %%ymm7, %%ymm7" & LF &
                     "vbroadcastss 0(%4), %%ymm8" & LF &
                     "vbroadcastss 4(%4), %%ymm9" & LF &
                     "vmulps %%ymm8, %%ymm6, %%ymm6" & LF &
                     "vmulps %%ymm9, %%ymm7, %%ymm7" & LF &
                     "vmovups (%2), %%ymm10" & LF &
                     "vmulps %%ymm10, %%ymm6, %%ymm6" & LF &
                     "vmulps %%ymm10, %%ymm7, %%ymm7" & LF &
                     "vmovups %%ymm6, (%0)" & LF &
                     "vmovups %%ymm7, (%3)",
                     Inputs   =>
                       [System.Address'Asm_Input
                          ("r", Row_Scale (Natural (Block) * Deep)'Address),
                        System.Address'Asm_Input
                          ("r", Data (At_Byte + 4)'Address),
                        System.Address'Asm_Input
                          ("r", Scales (Scales'First + At_Base)'Address),
                        System.Address'Asm_Input ("r", Lowered'Address),
                        System.Address'Asm_Input ("r", Pair'Address),
                        System.Address'Asm_Input
                          ("r", Unpack_Masks (0)'Address)],
                     Clobber  =>
                       "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,"
                       & "ymm9,ymm10,memory",
                     Volatile => True);

                  --  The minimum's term, which is a running sum and stays
                  --  in the order it was summed in.
                  for Sub in 0 .. Deep - 1 loop
                     Undo := Undo
                       + N.Wide_Real (Lowered (Sub))
                         * N.Wide_Real
                             (Totals
                                (Totals'First + At_Base
                                 + Element_Count (Sub)));
                  end loop;
               end;
            end loop;

            Landed := [others => 0.0];

            System.Machine_Code.Asm
              ("vpxor %%ymm6, %%ymm6, %%ymm6" & LF &
               "movl $0x0F0F0F0F, %%eax" & LF &
               "vmovd %%eax, %%xmm7" & LF &
               "vpbroadcastd %%xmm7, %%ymm7" & LF &
               "xorq %%rcx, %%rcx" & LF &
               "xorq %%rdx, %%rdx" & LF &
               "movq %4, %%rax" & LF &
               "1:" & LF &
               "vmovdqu 16(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
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
               "vmovdqu 48(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
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
               "vmovdqu 80(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
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
               "vmovdqu 112(%1,%%rcx,1), %%ymm0" & LF &
               "vpand %%ymm7, %%ymm0, %%ymm4" & LF &
               "vpsrlw $4, %%ymm0, %%ymm5" & LF &
               "vpand %%ymm7, %%ymm5, %%ymm5" & LF &
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
               "addq $144, %%rcx" & LF &
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
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,ymm7,memory",
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

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q5_K));

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
            for Block in 0 .. Blocks - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Base + Width * B.Byte_Count (Block);

                  At_Base : constant Element_Count :=
                    First / Activation_Block + Block * Deep;

                  --  The block's scale and the block's least, together.
                  Pair : constant Lanes_2 :=
                    [Scale_At (Data, At_Byte), Scale_At (Data, At_Byte + 2)];

                  --  The minimum's side of the product, one for every
                  --  sub-block, kept for the running sum below.
                  Lowered : Lanes_8;

               begin
                  --  The twelve packed bytes taken apart in lanes.
                  --
                  --  Asked one sub-block at a time, the first four read two
                  --  bytes each and the last four read three, and the bytes
                  --  they read are the same twelve over again -- five and
                  --  twenty reads where twelve will do, with a branch on
                  --  the sub-block's number around each. Ablating this
                  --  prologue away entirely -- the wrong answer, and none
                  --  of the unpacking -- took a generated token from 2.277
                  --  to 1.642 s, so it is twenty-eight per cent of what
                  --  this format costs the processor.
                  --
                  --  Taking the twelve apart a byte at a time and then
                  --  widening each byte to a floating-point number is a
                  --  hundred and twenty instructions a block, and every one
                  --  of them is the same operation on eight neighbouring
                  --  values. Written first as two Ada loops -- one to
                  --  unpack, one to multiply, with the scales read once --
                  --  it measured one to two per cent worse than the single
                  --  scalar loop it replaced, because the compiler
                  --  vectorised neither: the byte-to-float widening and the
                  --  six-bit fields split across two bytes are not shapes
                  --  it recognises.
                  --
                  --  Written by hand it is thirty-one instructions. The
                  --  twelve arrive as one unaligned sixteen-byte read --
                  --  which is inside the block, since a block is a hundred
                  --  and forty-four bytes and this reads twenty of them.
                  --  The first four fields are a mask; the last four are a
                  --  nibble from the top third of the twelve with two high
                  --  bits from the first third laid above it, which is a
                  --  shift, a mask and an or on all four at once. Both
                  --  sets widen from bytes to whole numbers in one
                  --  instruction apiece, join into a register of eight,
                  --  convert to floating point together, and take the
                  --  block's scale and the activation's scale as two
                  --  multiplies over the eight.
                  --
                  --  Bit for bit what the scalar loop computed: the same
                  --  two multiplies in the same order, on the same numbers.
                  --  The running sum below is what is not done here, and
                  --  is left in the order it was in.
                  System.Machine_Code.Asm
                    ("vmovdqu (%1), %%xmm0" & LF &
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
                     "vcvtdq2ps %%ymm6, %%ymm6" & LF &
                     "vcvtdq2ps %%ymm7, %%ymm7" & LF &
                     "vbroadcastss 0(%4), %%ymm8" & LF &
                     "vbroadcastss 4(%4), %%ymm9" & LF &
                     "vmulps %%ymm8, %%ymm6, %%ymm6" & LF &
                     "vmulps %%ymm9, %%ymm7, %%ymm7" & LF &
                     "vmovups (%2), %%ymm10" & LF &
                     "vmulps %%ymm10, %%ymm6, %%ymm6" & LF &
                     "vmulps %%ymm10, %%ymm7, %%ymm7" & LF &
                     "vmovups %%ymm6, (%0)" & LF &
                     "vmovups %%ymm7, (%3)",
                     Inputs   =>
                       [System.Address'Asm_Input
                          ("r", Row_Scale (Natural (Block) * Deep)'Address),
                        System.Address'Asm_Input
                          ("r", Data (At_Byte + 4)'Address),
                        System.Address'Asm_Input
                          ("r", Scales (Scales'First + At_Base)'Address),
                        System.Address'Asm_Input ("r", Lowered'Address),
                        System.Address'Asm_Input ("r", Pair'Address),
                        System.Address'Asm_Input
                          ("r", Unpack_Masks (0)'Address)],
                     Clobber  =>
                       "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,"
                       & "ymm9,ymm10,memory",
                     Volatile => True);

                  --  The minimum's term, which is a running sum and stays
                  --  in the order it was summed in.
                  for Sub in 0 .. Deep - 1 loop
                     Undo := Undo
                       + N.Wide_Real (Lowered (Sub))
                         * N.Wide_Real
                             (Totals
                                (Totals'First + At_Base
                                 + Element_Count (Sub)));
                  end loop;
               end;
            end loop;

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
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean)
   is
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
                  First, Sums, Done);

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
                           end;
                        end loop;
                     end;
                  end loop;
               end loop;

               for At_Strip in Element_Count range 0 .. (Count + 3) / 4 - 1
               loop
                  Rows_By_Strips_Q6K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Held, First, Stride, Count, At_Strip * 4,
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

                        Factor, Minimum : Interfaces.Unsigned_8;
                     begin
                        for Sub in 0 .. 7 loop
                           Sub_Block_Scale
                             (Data, At_Byte + 4, Sub, Factor, Minimum);

                           Held_Up (At_Scale + Element_Count (Sub)) :=
                             Whole * N.Real (Natural (Factor));
                           Held_Down (At_Scale + Element_Count (Sub)) :=
                             Least * N.Real (Natural (Minimum));
                        end loop;
                     end;
                  end loop;
               end loop;

            for At_Strip in Element_Count range 0 .. (Count + 3) / 4 - 1 loop
               if Format = G.Type_Q4_K then
                  Rows_By_Strips_Q4K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Held_Up, Held_Down,
                     Totals, First, Stride, Count, At_Strip * 4,
                     Element_Count'Min (4, Count - At_Strip * 4), Sums,
                     Done);
               else
                  Rows_By_Strips_Q5K
                    (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                     Held_Up, Held_Down,
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
      if Deep and then Count = 1 then
         Rows_Singly
           (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales, Totals,
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
      if Deep and then Rows mod 2 = 0 and then Count >= 4 then
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
                  Totals, First + Which * Stride, Which, Count, Sums);
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

                  if Deep then
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
                          (-128) * Totals (Totals'First + At_Scale);
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
