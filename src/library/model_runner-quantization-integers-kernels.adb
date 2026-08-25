with System;
with System.Machine_Code;

package body Model_Runner.Quantization.Integers.Kernels is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type B.Byte_Count;
   use type N.Real;
   use type N.Wide_Real;

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
      Row_Scale : array (0 .. Scale_Room - 1) of N.Real := [others => 0.0];

      --  Eight partial sums, reduced once when the row is done.
      type Lanes_8 is array (0 .. 7) of N.Real with Alignment => 32;
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
                    N.To_Real
                      (N.Half
                         (Interfaces.Unsigned_16 (Data (At_Byte))
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_16
                                  (Data (At_Byte + 1)), 8)));
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
               "1:"                                  & LF &
               "vmovdqu (%1,%%rcx,1), %%ymm0"        & LF &
               "vpxor %%ymm7, %%ymm0, %%ymm0"        & LF &
               "vpxor %%ymm1, %%ymm1, %%ymm1"        & LF &
               "vpdpbusd (%2), %%ymm0, %%ymm1"       & LF &
               "vcvtdq2ps %%ymm1, %%ymm1"            & LF &
               "vbroadcastss (%3), %%ymm2"           & LF &
               "vfmadd231ps %%ymm2, %%ymm1, %%ymm6"  & LF &
               "addq $34, %1"                        & LF &
               "addq $32, %2"                        & LF &
               "addq $4, %3"                         & LF &
               "decq %4"                             & LF &
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
                 "rax,rcx,ymm0,ymm1,ymm2,ymm6,ymm7,memory",
               Volatile => True);

            declare
               Total : N.Wide_Real := 0.0;
            begin
               for Lane in Landed'Range loop
                  Total := Total + N.Wide_Real (Landed (Lane));
               end loop;

               Sums (Sums'First + Row) :=
                 Sums (Sums'First + Row) + Total - 128.0 * Undo;
            end;
         end;
      end loop;
   end Rows_Singly;

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
        or else Per /= Activation_Block
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                     (Data, Offset,
                      Row_Bytes * B.Byte_Count (Rows - 1)
                      + Width * B.Byte_Count (Blocks))
      then
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
            First, Sums);
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
         type Lanes is array (Lane_Range) of N.Real with Alignment => 32;

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
                    N.To_Real
                      (N.Half
                         (Interfaces.Unsigned_16 (Data (At_Byte))
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_16
                                  (Data (At_Byte + 1)), 8)));

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
                                 N.Real'Asm_Input ("m", Both),
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
