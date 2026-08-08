with Interfaces;
with System;
with System.Storage_Elements;

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

   --  Elements per k-quant super-block.
   Super : constant := 256;

   --  Elements a decode-then-multiply span holds. Large enough that the cost
   --  of settling the format is spread thin, small enough to stay in the
   --  nearest cache and to keep the stack cost fixed.
   Span_Elements : constant Element_Count := 2048;

   --  Read one byte of a block. The caller has already checked that the whole
   --  block lies inside Data.
   function Raw
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Interfaces.Unsigned_8
   is (Interfaces.Unsigned_8 (Data (Data'First + Offset)));

   --  Read a signed byte of a block.
   --  One read, not three: deciding the sign used to re-read the byte.
   function Signed
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Integer
   is
      Value : constant Interfaces.Unsigned_8 := Raw (Data, Offset);
   begin
      return (if Value < 128 then Integer (Value) else Integer (Value) - 256);
   end Signed;

   --  Read a half-precision scale.
   function Scale
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Real
   is (N.To_Real
         (N.Half
            (Interfaces.Unsigned_16 (Raw (Data, Offset))
             or Interfaces.Shift_Left
                  (Interfaces.Unsigned_16 (Raw (Data, Offset + 1)), 8))));

   --  Unpack the six-bit scale and minimum of one k-quant sub-block.
   --
   --  The twelve scale bytes hold eight scale/minimum pairs: the first four
   --  pairs use six bits of one byte each, and the last four are split across
   --  the high bits of the earlier bytes. This is the layout every k-quant
   --  format shares.
   procedure Sub_Block_Scale
     (Data    : B.Byte_Array;
      Base    : B.Byte_Count;
      Index   : Natural;
      Factor  : out Interfaces.Unsigned_8;
      Minimum : out Interfaces.Unsigned_8)
   is
      function Byte_At (Position : Natural) return Interfaces.Unsigned_8
      is (Raw (Data, Base + B.Byte_Count (Position)));
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

   --  Decode exactly one block; defined below.
   --  Decodes into any slice of at least Block_Elements, so a caller with a
   --  destination already in hand need not copy through a scratch block.
   procedure Decode_One
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Target : out Real_Array;
      Ok     : out Boolean);

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
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Slot : Element_Count := Target'First;
               Step : B.Byte_Count := Offset;
            begin
               for Block in 1 .. Count loop
                  --  Straight into the destination. This used to decode into
                  --  a scratch block and copy 256 elements out of it, which
                  --  was the whole of the difference between this path and
                  --  the formats unpacked inline.
                  Decode_One
                    (Format, Data, Step, Target (Slot .. Slot + Per - 1), Ok);
                  exit when not Ok;
                  Slot := Slot + Per;
                  Step := Step + Width;
               end loop;
            end;
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
   is (Format in G.Type_F32 | G.Type_F16 | G.Type_Q4_0 | G.Type_Q8_0
                | G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K);

   -------------------
   -- Decode_Block --
   -------------------

   --  Decode exactly one block. This holds the layout of every format; the
   --  span decoder below uses it directly for the formats whose blocks are
   --  wide enough that a per-block call costs nothing measurable, and repeats
   --  its inner loop for the narrow ones.
   procedure Decode_One
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Target : out Real_Array;
      Ok     : out Boolean)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
   begin
      Ok := False;

      if not Is_Decodable (Format)
        or else not B.Has_Room (Data, Offset, Width)
      then
         --  Only the failure path leaves the buffer undefined, so only it has
         --  to define one. Every format branch below writes each of the
         --  elements its layout declares, and callers read no further: the
         --  buffer is sized for the widest format, not for this one.
         --
         --  Zeroing it unconditionally cost far more than the decode. A Q8_0
         --  block is 32 elements in a 256-element buffer, so eight of every
         --  nine bytes written were discarded, and at roughly a billion
         --  multiply-accumulates per token that came to tens of gigabytes of
         --  wasted stores for each token produced.
         Target := [others => 0.0];
         return;
      end if;

      --  Only the k-quant formats reach here: Decode_Blocks unpacks the
      --  others inline and delegates the rest to this. A second copy of the
      --  simple layouts lived here and nothing called it, so nothing tested
      --  it either.
      case Format is
         when G.Type_Q4_K =>
            declare
               --  The block was bounds-checked at entry, so every index below
               --  is inside it. The checks cost the vectorizer this loop, and
               --  unpacking is the larger half of a k-quant row's cost.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D       : constant Real := Scale (Data, Offset);
               Minimum : constant Real := Scale (Data, Offset + 2);
               Scales  : constant B.Byte_Count := Offset + 4;
               Quants  : constant B.Byte_Count := Offset + 16;
               Target_Index : Element_Count := 0;
               Sub     : Natural := 0;
            begin
               --  Eight sub-blocks of 32 elements, processed in pairs that
               --  share the same 32 packed bytes: the low nibbles form the
               --  first sub-block and the high nibbles the second.
               for Group in 0 .. 3 loop
                  declare
                     Base    : constant B.Byte_Count :=
                       Quants + B.Byte_Count (Group) * 32;
                     Factor1, Min1, Factor2, Min2 : Interfaces.Unsigned_8;
                  begin
                     Sub_Block_Scale (Data, Scales, Sub, Factor1, Min1);
                     Sub_Block_Scale (Data, Scales, Sub + 1, Factor2, Min2);

                     --  A sub-block's scale and offset are the same for all
                     --  thirty-two of its elements, so they are formed once
                     --  here rather than in the loop. They were four
                     --  multiplies and four conversions per element.
                     declare
                        Scale_1  : constant Real := D * Real (Factor1);
                        Scale_2  : constant Real := D * Real (Factor2);
                        Offset_1 : constant Real := Minimum * Real (Min1);
                        Offset_2 : constant Real := Minimum * Real (Min2);
                     begin
                        for L in 0 .. 31 loop
                           declare
                              --  Indexed directly rather than through Raw:
                              --  one read instead of a call per element.
                              Packed : constant Interfaces.Unsigned_8 :=
                                Data (Data'First + Base + B.Byte_Count (L));
                           begin
                              Target
                                (Target'First + Target_Index
                                 + Element_Count (L)) :=
                                Scale_1 * Real (Integer (Packed and 16#0F#))
                                - Offset_1;
                              Target
                                (Target'First + Target_Index + 32
                                 + Element_Count (L)) :=
                                Scale_2
                                  * Real (Integer
                                            (Interfaces.Shift_Right
                                               (Packed, 4)))
                                - Offset_2;
                           end;
                        end loop;
                     end;

                     Target_Index := Target_Index + 64;
                     Sub := Sub + 2;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q5_K =>
            declare
               --  As in Q4_K: the block was bounds-checked at entry, and
               --  the per-element checks cost the vectorizer this loop.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D       : constant Real := Scale (Data, Offset);
               Minimum : constant Real := Scale (Data, Offset + 2);
               Scales  : constant B.Byte_Count := Offset + 4;
               High    : constant B.Byte_Count := Offset + 16;
               Quants  : constant B.Byte_Count := Offset + 48;
               Target_Index : Element_Count := 0;
               Sub     : Natural := 0;
               Mask_Low  : Interfaces.Unsigned_8 := 1;
               Mask_High : Interfaces.Unsigned_8 := 2;
            begin
               for Group in 0 .. 3 loop
                  declare
                     Base    : constant B.Byte_Count :=
                       Quants + B.Byte_Count (Group) * 32;
                     Factor1, Min1, Factor2, Min2 : Interfaces.Unsigned_8;
                  begin
                     Sub_Block_Scale (Data, Scales, Sub, Factor1, Min1);
                     Sub_Block_Scale (Data, Scales, Sub + 1, Factor2, Min2);

                     --  Formed once per sub-block rather than once per
                     --  element, as in Q4_K.
                     declare
                        Scale_1  : constant Real := D * Real (Factor1);
                        Scale_2  : constant Real := D * Real (Factor2);
                        Offset_1 : constant Real := Minimum * Real (Min1);
                        Offset_2 : constant Real := Minimum * Real (Min2);
                     begin

                     for L in 0 .. 31 loop
                        declare
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + Base + B.Byte_Count (L));
                           Fifth  : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + High + B.Byte_Count (L));
                           Low    : constant Integer :=
                             Integer (Packed and 16#0F#)
                             + (if (Fifth and Mask_Low) /= 0 then 16 else 0);
                           Upper  : constant Integer :=
                             Integer (Interfaces.Shift_Right (Packed, 4))
                             + (if (Fifth and Mask_High) /= 0 then 16 else 0);
                        begin
                           Target
                             (Target'First + Target_Index
                              + Element_Count (L)) :=
                             Scale_1 * Real (Low) - Offset_1;
                           Target
                             (Target'First + Target_Index + 32
                              + Element_Count (L)) :=
                             Scale_2 * Real (Upper) - Offset_2;
                        end;
                     end loop;
                     end;

                     Target_Index := Target_Index + 64;
                     Sub := Sub + 2;
                     Mask_Low := Interfaces.Shift_Left (Mask_Low, 2);
                     Mask_High := Interfaces.Shift_Left (Mask_High, 2);
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q6_K =>
            declare
               --  As in Q4_K: the block was bounds-checked at entry, and
               --  the per-element checks cost the vectorizer this loop.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Low_Base  : constant B.Byte_Count := Offset;
               High_Base : constant B.Byte_Count := Offset + 128;
               Scale_Base : constant B.Byte_Count := Offset + 192;
               D : constant Real := Scale (Data, Offset + 208);
            begin
               --  Two halves of 128 elements. Within a half, each of the 32
               --  positions contributes four elements whose two high bits come
               --  from one byte of the high-bit array.
               for Half in 0 .. 1 loop
                  declare
                     Low_Half   : constant B.Byte_Count :=
                       Low_Base + B.Byte_Count (Half) * 64;
                     High_Half  : constant B.Byte_Count :=
                       High_Base + B.Byte_Count (Half) * 32;
                     Scale_Half : constant B.Byte_Count :=
                       Scale_Base + B.Byte_Count (Half) * 8;
                     Out_Half   : constant Element_Count :=
                       Element_Count (Half) * 128;
                  begin
                     --  The four scales depend only on which half of the
                     --  thirty-two positions L is in, so the loop is split
                     --  and they are formed twice rather than 128 times.
                     --
                     --  Each of the four runs below reads sixteen adjacent
                     --  bytes and writes sixteen adjacent elements. Doing
                     --  all four inside one loop, as this once did, wrote
                     --  four streams thirty-two elements apart on every
                     --  iteration, and that scattering is what left this
                     --  format decoding several times slower than the
                     --  others rather than at their speed.
                     for Sub in 0 .. 1 loop
                      declare
                        Low_Run  : constant B.Byte_Count :=
                          Low_Half + B.Byte_Count (Sub) * 16;
                        High_Run : constant B.Byte_Count :=
                          High_Half + B.Byte_Count (Sub) * 16;
                        Out_Run  : constant Element_Count :=
                          Out_Half + Element_Count (Sub) * 16;

                        Scale_1 : constant Real :=
                          D * Real (Signed (Data, Scale_Half
                                            + B.Byte_Count (Sub)));
                        Scale_2 : constant Real :=
                          D * Real (Signed (Data, Scale_Half
                                            + B.Byte_Count (Sub + 2)));
                        Scale_3 : constant Real :=
                          D * Real (Signed (Data, Scale_Half
                                            + B.Byte_Count (Sub + 4)));
                        Scale_4 : constant Real :=
                          D * Real (Signed (Data, Scale_Half
                                            + B.Byte_Count (Sub + 6)));
                      begin
                       --  Low nibble of the first thirty-two bytes, with the
                       --  lowest two bits of the shared byte.
                       for L in 0 .. 15 loop
                          Target (Target'First + Out_Run + Element_Count (L)) :=
                            Scale_1
                            * Real (Integer
                                      (Data (Data'First + Low_Run
                                             + B.Byte_Count (L)) and 16#0F#)
                                    + 16 * Integer
                                             (Data (Data'First + High_Run
                                                    + B.Byte_Count (L)) and 3)
                                    - 32);
                       end loop;

                       --  Low nibble of the second thirty-two bytes.
                       for L in 0 .. 15 loop
                          Target (Target'First + Out_Run + 32
                                  + Element_Count (L)) :=
                            Scale_2
                            * Real (Integer
                                      (Data (Data'First + Low_Run + 32
                                             + B.Byte_Count (L)) and 16#0F#)
                                    + 16 * Integer
                                             (Interfaces.Shift_Right
                                                (Data (Data'First + High_Run
                                                       + B.Byte_Count (L)), 2)
                                              and 3)
                                    - 32);
                       end loop;

                       --  High nibble of the first thirty-two bytes.
                       for L in 0 .. 15 loop
                          Target (Target'First + Out_Run + 64
                                  + Element_Count (L)) :=
                            Scale_3
                            * Real (Integer
                                      (Interfaces.Shift_Right
                                         (Data (Data'First + Low_Run
                                                + B.Byte_Count (L)), 4))
                                    + 16 * Integer
                                             (Interfaces.Shift_Right
                                                (Data (Data'First + High_Run
                                                       + B.Byte_Count (L)), 4)
                                              and 3)
                                    - 32);
                       end loop;

                       --  High nibble of the second thirty-two bytes.
                       for L in 0 .. 15 loop
                          Target (Target'First + Out_Run + 96
                                  + Element_Count (L)) :=
                            Scale_4
                            * Real (Integer
                                      (Interfaces.Shift_Right
                                         (Data (Data'First + Low_Run + 32
                                                + B.Byte_Count (L)), 4))
                                    + 16 * Integer
                                             (Interfaces.Shift_Right
                                                (Data (Data'First + High_Run
                                                       + B.Byte_Count (L)), 6)
                                              and 3)
                                    - 32);
                       end loop;
                      end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when others =>
            Ok := False;
      end case;

      pragma Assert (Super = 256);
   end Decode_One;

end Model_Runner.Quantization;
