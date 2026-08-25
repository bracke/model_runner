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
   --  The eight partial sums a byte dot product leaves, which both
   --  insertions below keep in a register across a whole row and reduce
   --  once at the end of it. Thirty-two bytes, aligned to thirty-two,
   --  because they are stored with an aligned move.
   type Lanes_8 is array (0 .. 7) of N.Real with Alignment => 32;

   --  Two rows against four vectors, with the block loop inside the
   --  insertion. Only for the byte dot product.
   procedure Rows_By_Strips
     (Data      : Model_Runner.Bytes.Byte_Array;
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
      Row_Scale : array (0 .. Scale_Room - 1) of N.Real := [others => 0.0];

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
      type Undo_Table is
        array (0 .. Panel_Rows * Strip - 1) of N.Real;
      Undo : Undo_Table;

      --  Where each vector of the strip keeps its scales, and the two
      --  numbers read from there for every block of every row.
      type Vector_Places is array (0 .. Strip - 1) of Element_Count;
      type Vector_Numbers is array (0 .. Strip * Scale_Room - 1) of N.Real;

      Vector_At    : Vector_Places;
      Vector_Scale : Vector_Numbers;
      Vector_Total : Vector_Numbers;

      --  Eight partial sums a piece, reduced when the row is done.
      type Strip_Lanes is array (0 .. Panel_Rows * Strip - 1) of Lanes_8;
      Landed : Strip_Lanes := [others => [others => 0.0]];

      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (G.Type_Q8_0));
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
            Undo := [others => 0.0];

            for Block in 0 .. Blocks - 1 loop
               for Row in Element_Count range 0 .. Panel_Rows - 1 loop
                  declare
                     At_Byte : constant B.Byte_Index :=
                       Base + Row_Bytes * B.Byte_Count (Row)
                       + Width * B.Byte_Count (Block);

                     Scale : constant N.Real :=
                       N.To_Real
                         (N.Half
                            (Interfaces.Unsigned_16 (Data (At_Byte))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_16
                                     (Data (At_Byte + 1)), 8)));

                     At_Vec : constant Natural := Natural (Block) * Strip;
                     At_Out : constant Natural :=
                       Natural (Block) * (Panel_Rows * Strip)
                       + Natural (Row) * Strip;
                     At_Undo : constant Natural := Natural (Row) * Strip;
                  begin
                     for Vector in 0 .. Strip - 1 loop
                        declare
                           Both : constant N.Real :=
                             Scale * Vector_Scale (At_Vec + Vector);
                        begin
                           Scaling (At_Out + Vector) := Both;

                           Undo (At_Undo + Vector) :=
                             Undo (At_Undo + Vector)
                             + Both * Vector_Total (At_Vec + Vector);
                        end;
                     end loop;
                  end;
               end loop;
            end loop;

            Landed := [others => [others => 0.0]];

            System.Machine_Code.Asm
              ("movl $0x80808080, %%eax" & LF &
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
               "1:" & LF &
               "vmovdqu (%1,%%rcx,1), %%ymm0" & LF &
               "vpxor %%ymm3, %%ymm0, %%ymm0" & LF &
               "vmovdqu (%2,%%rcx,1), %%ymm1" & LF &
               "vpxor %%ymm3, %%ymm1, %%ymm1" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 0(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm16" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 4(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm17" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 8(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm18" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm0, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 12(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm19" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%3,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 16(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm20" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%4,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 20(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm21" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%5,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 24(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm22" & LF &
               "vpxor %%ymm2, %%ymm2, %%ymm2" & LF &
               "vpdpbusd (%6,%%rdx,1), %%ymm1, %%ymm2" & LF &
               "vcvtdq2ps %%ymm2, %%ymm2" & LF &
               "vfmadd231ps 28(%7,%%rdx,1)%{1to8%}, %%ymm2, %%ymm23" & LF &
               "addq $34, %%rcx" & LF &
               "addq $32, %%rdx" & LF &
               "decq %8" & LF &
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
                  Element_Count'Asm_Input ("r", Blocks)],
               Clobber  =>
                 "rax,rcx,rdx,ymm0,ymm1,ymm2,ymm3,ymm16,ymm17,ymm18,ymm19,"
                 & "ymm20,ymm21,ymm22,ymm23,memory",
               Volatile => True);

            for Row in Element_Count range 0 .. Panel_Rows - 1 loop
               for Vector in Element_Count range 0 .. Strip - 1 loop
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
                       + Total - 128.0 * N.Wide_Real (Undo (Which));
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Taken := True;
   end Rows_By_Strips;

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
            Full : constant Element_Count := (Count / 4) * 4;
            Done : Boolean;
         begin
            for At_Strip in Element_Count range 0 .. Full / 4 - 1 loop
               Rows_By_Strips
                 (Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
                  Totals, First, Stride, Count, At_Strip * 4, Sums, Done);

               if not Done then
                  return;
               end if;
            end loop;

            for Which in Full .. Count - 1 loop
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
