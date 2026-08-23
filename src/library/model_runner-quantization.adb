with Interfaces;
with System;
with System.Storage_Elements;

with Model_Runner.Quantization.Plain;
with Model_Runner.Quantization.Wide;

package body Model_Runner.Quantization is

   --  Validity checking is not suppressed here, unlike in the packages that
   --  read a file's floats back: the byte decoder, the metadata accessors,
   --  the tokenizer, the engine and the kernels all had to, because a
   --  not-a-number in a weight is ordinary input and the check fired before
   --  the guard that refuses it.
   --
   --  This package decodes bytes into floats and multiplies them, and a
   --  not-a-number reaches those loops as readily. It was checked rather
   --  than assumed: a weight whose bits spell one, put through the fused dot
   --  product, comes back with no exception and no refusal. What raises is
   --  compiler-chosen and not visible in the source, so the answer here is
   --  what running it says, and it says this package needs nothing.

   package Storage renames System.Storage_Elements;

   use type System.Bit_Order;
   use type Storage.Integer_Address;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   --  Elements a decode-then-multiply span holds. Large enough that the cost
   --  of settling the format is spread thin, small enough to stay in the
   --  nearest cache and to keep the stack cost fixed.
   Span_Elements : constant Element_Count := 2048;

   --  Whether the wider decoders may be used, which the backend says once
   --  before any model is read and nothing changes afterwards. Written by
   --  one task before the workers exist and read by all of them after, which
   --  is what makes a plain Boolean enough.
   Wide_Available : Boolean := False;

   ------------------------
   -- Use_Wide_Decoders --
   ------------------------

   procedure Use_Wide_Decoders (Allowed : Boolean) is
   begin
      Wide_Available := Allowed;
   end Use_Wide_Decoders;

   -------------------
   -- Decode_Block --
   -------------------

   procedure Decode_Block
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Target : out Block_Buffer;
      Ok     : out Boolean)
   is
      Per : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      --  A span of one. Routing through the same code is what keeps a format
      --  from having two implementations, one of them untested: it did, and
      --  an error injected into the unused copy went unnoticed.
      if Per = 0 or else Per > Target'Length then
         Target := [others => 0.0];
         Ok := False;
         return;
      end if;

      Decode_Blocks (Format, Data, Offset, 1, Target (0 .. Per - 1), Ok);

      if not Ok then
         Target := [others => 0.0];
      end if;
   end Decode_Block;

   --------------------
   -- Decode_Blocks --
   --------------------

   procedure Decode_Blocks
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Count  : Element_Count;
      Target : out Real_Array;
      Ok     : out Boolean)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
      Per   : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Ok := False;

      if not Is_Decodable (Format)
        or else Count = 0
        or else Target'Length < Count * Per
        or else not B.Has_Room (Data, Offset, Width * B.Byte_Count (Count))
      then
         Target := [others => 0.0];
         return;
      end if;

      --  The format is decided once here rather than once per block. For a
      --  thirty-two element block that decision, its bounds check and the call
      --  around them cost more than the arithmetic they guard.
      --
      --  The unpacking loops below run with the runtime checks suppressed.
      --  Every index they compute lies inside the ranges established above --
      --  Has_Room for the packed bytes, Target'Length for the output -- and
      --  leaving the checks in place costs the vectorizer these loops
      --  entirely, because each check is a call it must treat as touching
      --  memory. Unpacking is the larger half of a quantized row's cost, so
      --  that matters more here than anywhere else in the engine.
      case Format is
         when G.Type_Q8_0 =>
            --  One half-precision scale, then thirty-two signed bytes. Each
            --  byte is read exactly once; the earlier helper read it three
            --  times to decide its sign.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               At_Byte : B.Byte_Index := Data'First + Offset;
               Slot    : Element_Count := Target'First;
            begin
               for Block in 1 .. Count loop
                  declare
                     D : constant Real :=
                       N.To_Real
                         (N.Half
                            (Interfaces.Unsigned_16 (Data (At_Byte))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_16
                                     (Data (At_Byte + 1)), 8)));
                  begin
                     for J in 0 .. 31 loop
                        declare
                           U : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + 2 + B.Byte_Count (J));
                        begin
                           Target (Slot + Element_Count (J)) :=
                             D * Real (if U < 128
                                       then Integer (U)
                                       else Integer (U) - 256);
                        end;
                     end loop;
                  end;
                  At_Byte := At_Byte + Width;
                  Slot := Slot + 32;
               end loop;
               Ok := True;
            end;

         when G.Type_Q4_0 =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               At_Byte : B.Byte_Index := Data'First + Offset;
               Slot    : Element_Count := Target'First;
            begin
               for Block in 1 .. Count loop
                  declare
                     D : constant Real :=
                       N.To_Real
                         (N.Half
                            (Interfaces.Unsigned_16 (Data (At_Byte))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_16
                                     (Data (At_Byte + 1)), 8)));
                  begin
                     for J in 0 .. 15 loop
                        declare
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + 2 + B.Byte_Count (J));
                        begin
                           Target (Slot + Element_Count (J)) :=
                             D * Real (Integer (Packed and 16#0F#) - 8);
                           Target (Slot + Element_Count (J) + 16) :=
                             D * Real
                                   (Integer
                                      (Interfaces.Shift_Right (Packed, 4)) - 8);
                        end;
                     end loop;
                  end;
                  At_Byte := At_Byte + Width;
                  Slot := Slot + 32;
               end loop;
               Ok := True;
            end;

         when G.Type_F16 =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               At_Byte : B.Byte_Index := Data'First + Offset;
            begin
               for Index in 0 .. Count - 1 loop
                  Target (Target'First + Index) :=
                    N.To_Real
                      (N.Half
                         (Interfaces.Unsigned_16 (Data (At_Byte))
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_16
                                  (Data (At_Byte + 1)), 8)));
                  At_Byte := At_Byte + 2;
               end loop;
               Ok := True;
            end;

         when G.Type_BF16 =>
            --  A brain float is the top half of a binary32: the same sign and
            --  the same eight exponent bits, with the mantissa cut from
            --  twenty-three bits to seven. Widening it is therefore a shift
            --  and nothing else -- no exponent to rebias, and no case for
            --  infinity or not-a-number, because those patterns are already
            --  in the place binary32 keeps them. It is the one format here
            --  that cannot round.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               At_Byte : B.Byte_Index := Data'First + Offset;
            begin
               for Index in 0 .. Count - 1 loop
                  Target (Target'First + Index) :=
                    N.From_Bits
                      (Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Data (At_Byte))
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_32 (Data (At_Byte + 1)),
                                8),
                          16));
                  At_Byte := At_Byte + 2;
               end loop;
               Ok := True;
            end;

         when G.Type_F32 =>
            --  A single element per block, so this format suffered most from
            --  a per-block decision: every float paid for one.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Start : constant B.Byte_Index := Data'First + Offset;

               --  A binary32 in the file is a binary32 in memory here: the
               --  format stores them little-endian, Real is IEEE_Float_32 by
               --  its own assertion, and this host agrees about byte order.
               --  Where that holds and the bytes are aligned, the run is the
               --  values already and is read as such.
               --
               --  Assembling each float from its four bytes cost this format
               --  more per element than Q8_0 pays to decode one, which made
               --  the unquantized path the slowest of them: 696 against 2602
               --  Me/s in a row dot product. Read directly it is 3885, and
               --  the fastest, which is what it should have been.
               Direct : constant Boolean :=
                 System.Default_Bit_Order = System.Low_Order_First
                 and then Storage.To_Integer (Data (Start)'Address)
                          mod Storage.Integer_Address (4) = 0;

               At_Byte : B.Byte_Index := Start;
            begin
               if Direct then
                  declare
                     Words : constant Real_Array (0 .. Count - 1)
                       with Import, Address => Data (Start)'Address;
                  begin
                     Target (Target'First .. Target'First + Count - 1) := Words;
                  end;
               else
                  --  A host that orders bytes the other way, or a run the
                  --  alignment does not allow, takes them one at a time.
                  for Index in 0 .. Count - 1 loop
                     Target (Target'First + Index) :=
                       N.From_Bits
                         (Interfaces.Unsigned_32 (Data (At_Byte))
                          or Interfaces.Shift_Left
                                (Interfaces.Unsigned_32 (Data (At_Byte + 1)), 8)
                          or Interfaces.Shift_Left
                                (Interfaces.Unsigned_32 (Data (At_Byte + 2)), 16)
                          or Interfaces.Shift_Left
                                (Interfaces.Unsigned_32 (Data (At_Byte + 3)), 24));
                     At_Byte := At_Byte + 4;
                  end loop;
               end if;
               Ok := True;
            end;

         when others =>
            --  The k-quant formats pack 256 elements into a block, so the
            --  per-block cost this routine exists to remove is already spread
            --  thin. They use the single-block decoder unchanged.
            --  One call for the whole span rather than one a block: the
            --  loop is inside whichever compilation of the decoders this
            --  format wants, where it costs nothing to enter.
            if Wide_Available
              and then Format in G.Type_Q5_0 | G.Type_Q5_1
                               | G.Type_IQ4_NL | G.Type_IQ4_XS
            then
               Wide.Decode_Span
                 (Format, Data, Offset, Count, Width, Per, Target, Ok);
            else
               Plain.Decode_Span
                 (Format, Data, Offset, Count, Width, Per, Target, Ok);
            end if;
      end case;
   end Decode_Blocks;

   ---------------------
   -- Accumulate_Dot --
   ---------------------

   procedure Accumulate_Dot
     (Format  : G.Tensor_Type;
      Data    : B.Byte_Array;
      Offset  : B.Byte_Count;
      Blocks  : Element_Count;
      Vectors : Real_Array;
      First   : Element_Count;
      Stride  : Element_Count;
      Count   : Element_Count;
      Sums    : in out N.Wide_Real_Array;
      Ok      : out Boolean)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
      Per   : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));

   begin
      Ok := False;

      if not Is_Decodable (Format)
        or else Blocks = 0
        or else Count = 0
        or else Sums'Length < Count
        or else not B.Has_Room (Data, Offset, Width * B.Byte_Count (Blocks))
      then
         return;
      end if;

      --  Every element this call will read from Vectors, checked once here
      --  rather than once per element. The inner loops run with the runtime
      --  checks suppressed so that they can be vectorized, and this is what
      --  makes that safe: nothing below computes an index outside the range
      --  proved here, and a caller that gets it wrong is refused rather than
      --  allowed to read past the end. Accumulate_Dot did not check this at
      --  all before; it relied on its callers.
      declare
         Reach : constant Element_Count :=
           First + (Count - 1) * Stride + Blocks * Per;
      begin
         if First < Vectors'First
           or else Reach < First
           or else Reach - 1 > Vectors'Last
         then
            return;
         end if;
      end;

      --  Decode a span, then multiply it by each vector.
      --
      --  The buffer looks like waste when one vector is passed, because every
      --  value is stored and then read back one instruction later and never
      --  used again. Decoding straight into the sum instead was written and
      --  measured, and it is 44 per cent slower: 1487 Me/s against 2657. The
      --  buffer is what leaves two simple loops the compiler can vectorize --
      --  bytes to floats, then floats to a sum -- and fusing them produces
      --  one loop it will not touch. The same reason Q8_0 is not in
      --  the note above Accumulate_Dot.
      declare
         Scratch  : Real_Array (0 .. Span_Elements - 1);
         Per_Span : constant Element_Count :=
           Element_Count'Max (1, Span_Elements / Per);
         At_Byte  : B.Byte_Count := Offset;
         Column   : Element_Count := 0;
         Done     : Element_Count := 0;
      begin
         while Done < Blocks loop
            declare
               Take : constant Element_Count :=
                 Element_Count'Min (Per_Span, Blocks - Done);
               Span : constant Element_Count := Take * Per;
            begin
               Decode_Blocks
                 (Format, Data, At_Byte, Take, Scratch (0 .. Span - 1), Ok);
               exit when not Ok;

               --  Accumulated here rather than through a call: passing a
               --  span as an array parameter cost about half a nanosecond
               --  per element, which is a sixth of the whole kernel.
               for Which in 0 .. Count - 1 loop
                  declare
                     --  Bounds and ranges were established for the whole call
                     --  above. Leaving the checks here costs the vectorizer
                     --  the loop entirely: each one is a call the optimizer
                     --  must treat as touching memory, so it cannot prove the
                     --  iterations independent.
                     pragma Suppress (Index_Check);
                     pragma Suppress (Range_Check);
                     pragma Suppress (Overflow_Check);

                     At_Vec : constant Element_Count :=
                       First + Which * Stride + Column;
                     Whole  : constant Element_Count := Span - Span mod 4;
                     Sum_0  : N.Wide_Real := 0.0;
                     Sum_1  : N.Wide_Real := 0.0;
                     Sum_2  : N.Wide_Real := 0.0;
                     Sum_3  : N.Wide_Real := 0.0;
                  begin
                     for Index in 0 .. Whole / 4 - 1 loop
                        declare
                           At_Elt : constant Element_Count := Index * 4;
                        begin
                           Sum_0 := Sum_0 + N.Wide_Real (Scratch (At_Elt))
                             * N.Wide_Real (Vectors (At_Vec + At_Elt));
                           Sum_1 := Sum_1 + N.Wide_Real (Scratch (At_Elt + 1))
                             * N.Wide_Real (Vectors (At_Vec + At_Elt + 1));
                           Sum_2 := Sum_2 + N.Wide_Real (Scratch (At_Elt + 2))
                             * N.Wide_Real (Vectors (At_Vec + At_Elt + 2));
                           Sum_3 := Sum_3 + N.Wide_Real (Scratch (At_Elt + 3))
                             * N.Wide_Real (Vectors (At_Vec + At_Elt + 3));
                        end;
                     end loop;

                     for Index in Whole .. Span - 1 loop
                        Sum_0 := Sum_0 + N.Wide_Real (Scratch (Index))
                          * N.Wide_Real (Vectors (At_Vec + Index));
                     end loop;

                     Sums (Sums'First + Which) := Sums (Sums'First + Which)
                       + (Sum_0 + Sum_1 + Sum_2 + Sum_3);
                  end;
               end loop;

               Done := Done + Take;
               Column := Column + Span;
               At_Byte := At_Byte + Width * B.Byte_Count (Take);
            end;
         end loop;
      end;
   end Accumulate_Dot;

   -------------------
   -- Is_Decodable --
   -------------------

   function Is_Decodable (Format : G.Tensor_Type) return Boolean
   is (Format in G.Type_F32 | G.Type_F16 | G.Type_BF16 | G.Type_Q4_0
                | G.Type_Q8_0 | G.Type_Q4_1 | G.Type_Q5_0 | G.Type_Q5_1
                | G.Type_Q2_K | G.Type_Q3_K
                | G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K
                | G.Type_IQ4_NL | G.Type_IQ4_XS);

   -------------------
   -- Decode_Block --
   -------------------

   --  Decode exactly one block. This holds the layout of every format; the

end Model_Runner.Quantization;
