with Interfaces;

package body Model_Runner.Quantization is

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
      Ok     : out Boolean) is
   begin
      Decode_One (Format, Data, Offset, Target, Ok);
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

               At_Byte : B.Byte_Index := Data'First + Offset;
            begin
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

   -------------------
   -- Fused_Formats --
   -------------------

   --  Measured, not assumed. Fusing forces the sum to break at every block
   --  so the scale can be applied there, which costs the flat inner loop the
   --  span path gets. For Q4_0 that trade wins clearly: unpacking two nibbles
   --  and scaling each of them per element costs more than the flat loop
   --  saves. For Q8_0, whose element is already a byte, it loses, and for the
   --  rest there is either no scale to fold or far too much layout to reread.
   --  So only Q4_0 is fused.
   function Fused_Formats (Format : G.Tensor_Type) return Boolean
   is (Format = G.Type_Q4_0);

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

      --  Read a half-precision value at an absolute index.
      function Half_At (At_Byte : B.Byte_Index) return Real
      is (N.To_Real
            (N.Half
               (Interfaces.Unsigned_16 (Data (At_Byte))
                or Interfaces.Shift_Left
                     (Interfaces.Unsigned_16 (Data (At_Byte + 1)), 8))));
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

      --  Fusing means the scale never reaches an individual weight: a Q4_0 or
      --  Q8_0 value is its block's scale times a small integer, so the sum
      --  over a block is the scale times the sum of integer times input. That
      --  is one multiply by the scale for each block instead of one for each
      --  of its thirty-two elements, and one rounding fewer per element.
      --
      --  The integers are unpacked a span at a time and the scales kept
      --  beside them, so a vector runs through a thousand elements before it
      --  gives way to the next. Unpacking per block instead would make a
      --  batch revisit every vector every thirty-two elements, which measured
      --  slower end to end than not fusing at all.
      --
      --  One vector or many, the arithmetic is the same, which is what keeps
      --  --batch-size from changing what a model says.
      if Fused_Formats (Format) then
         declare
            --  As in the span path: the ranges are established at entry, and
            --  the per-element checks would cost the vectorizer these loops.
            pragma Suppress (Index_Check);
            pragma Suppress (Range_Check);
            pragma Suppress (Overflow_Check);

            Values   : Real_Array (0 .. Span_Elements - 1);
            Scales   : Real_Array (0 .. Span_Elements / 32 - 1);
            Per_Span : constant Element_Count := Span_Elements / 32;
            At_Byte  : B.Byte_Index := Data'First + Offset;
            Column   : Element_Count := 0;
            Done     : Element_Count := 0;
         begin
            while Done < Blocks loop
               declare
                  Take : constant Element_Count :=
                    Element_Count'Min (Per_Span, Blocks - Done);
               begin
                  for Block in 0 .. Take - 1 loop
                     declare
                        Origin : constant B.Byte_Index :=
                          At_Byte + Width * B.Byte_Count (Block);
                        Slot   : constant Element_Count := Block * 32;
                     begin
                        Scales (Block) := Half_At (Origin);

                        if Format = G.Type_Q8_0 then
                           for J in 0 .. 31 loop
                              declare
                                 U : constant Interfaces.Unsigned_8 :=
                                   Data (Origin + 2 + B.Byte_Count (J));
                              begin
                                 Values (Slot + Element_Count (J)) :=
                                   Real (if U < 128
                                         then Integer (U)
                                         else Integer (U) - 256);
                              end;
                           end loop;
                        else
                           --  Q4_0: the two halves of the block interleave in
                           --  the packed bytes, both biased by eight.
                           for J in 0 .. 15 loop
                              declare
                                 Packed : constant Interfaces.Unsigned_8 :=
                                   Data (Origin + 2 + B.Byte_Count (J));
                              begin
                                 Values (Slot + Element_Count (J)) :=
                                   Real (Integer (Packed and 16#0F#) - 8);
                                 Values (Slot + Element_Count (J) + 16) :=
                                   Real (Integer (Interfaces.Shift_Right
                                                    (Packed, 4)) - 8);
                              end;
                           end loop;
                        end if;
                     end;
                  end loop;

                  for Which in 0 .. Count - 1 loop
                     declare
                        At_Vec : constant Element_Count :=
                          First + Which * Stride + Column;
                        Total  : N.Wide_Real := 0.0;
                     begin
                        for Block in 0 .. Take - 1 loop
                           declare
                              Slot  : constant Element_Count := Block * 32;
                              Sum_0 : N.Wide_Real := 0.0;
                              Sum_1 : N.Wide_Real := 0.0;
                              Sum_2 : N.Wide_Real := 0.0;
                              Sum_3 : N.Wide_Real := 0.0;
                           begin
                              for Group in 0 .. 7 loop
                                 declare
                                    At_Elt : constant Element_Count :=
                                      Slot + Element_Count (Group) * 4;
                                    At_In  : constant Element_Count :=
                                      At_Vec + At_Elt;
                                 begin
                                    Sum_0 := Sum_0
                                      + N.Wide_Real (Values (At_Elt))
                                        * N.Wide_Real (Vectors (At_In));
                                    Sum_1 := Sum_1
                                      + N.Wide_Real (Values (At_Elt + 1))
                                        * N.Wide_Real (Vectors (At_In + 1));
                                    Sum_2 := Sum_2
                                      + N.Wide_Real (Values (At_Elt + 2))
                                        * N.Wide_Real (Vectors (At_In + 2));
                                    Sum_3 := Sum_3
                                      + N.Wide_Real (Values (At_Elt + 3))
                                        * N.Wide_Real (Vectors (At_In + 3));
                                 end;
                              end loop;

                              Total := Total
                                + N.Wide_Real (Scales (Block))
                                  * (Sum_0 + Sum_1 + Sum_2 + Sum_3);
                           end;
                        end loop;

                        Sums (Sums'First + Which) :=
                          Sums (Sums'First + Which) + Total;
                     end;
                  end loop;

                  Done := Done + Take;
                  Column := Column + Take * 32;
                  At_Byte := At_Byte + Width * B.Byte_Count (Take);
               end;
            end loop;

            Ok := True;
            return;
         end;
      end if;

      --  Decode a span, then multiply it by each vector.
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

      case Format is
         when G.Type_F32 =>
            declare
               Present : Boolean;
            begin
               Target (Target'First + 0) := B.Get_F32 (Data, Offset, Present);
               Ok := Present;
            end;

         when G.Type_F16 =>
            Target (Target'First + 0) := Scale (Data, Offset);
            Ok := True;

         when G.Type_Q4_0 =>
            --  One scale, then sixteen bytes each holding two nibbles. The low
            --  nibble of byte j is element j and the high nibble is element
            --  j + 16; both are biased by eight.
            declare
               D : constant Real := Scale (Data, Offset);
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Raw (Data, Offset + 2 + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Integer (Packed and 16#0F#) - 8);
                     Target (Target'First + Element_Count (J + 16)) :=
                       D * Real (Integer (Interfaces.Shift_Right (Packed, 4)) - 8);
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q8_0 =>
            declare
               D : constant Real := Scale (Data, Offset);
            begin
               for J in 0 .. 31 loop
                  Target (Target'First + Element_Count (J)) :=
                    D * Real (Signed (Data, Offset + 2 + B.Byte_Count (J)));
               end loop;
               Ok := True;
            end;

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
                     for Sub in 0 .. 1 loop
                      declare
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
                       for L in Sub * 16 .. Sub * 16 + 15 loop
                        declare
                           Position : constant B.Byte_Count := B.Byte_Count (L);
                           Low_A    : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + Low_Half + Position);
                           Low_B    : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + Low_Half + Position + 32);
                           Bits     : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + High_Half + Position);
                           Q1 : constant Integer :=
                             Integer (Low_A and 16#0F#)
                             + 16 * Integer (Bits and 3) - 32;
                           Q2 : constant Integer :=
                             Integer (Low_B and 16#0F#)
                             + 16 * Integer
                                     (Interfaces.Shift_Right (Bits, 2) and 3)
                             - 32;
                           Q3 : constant Integer :=
                             Integer (Interfaces.Shift_Right (Low_A, 4))
                             + 16 * Integer
                                     (Interfaces.Shift_Right (Bits, 4) and 3)
                             - 32;
                           Q4 : constant Integer :=
                             Integer (Interfaces.Shift_Right (Low_B, 4))
                             + 16 * Integer
                                     (Interfaces.Shift_Right (Bits, 6) and 3)
                             - 32;
                        begin
                           Target
                             (Target'First + Out_Half + Element_Count (L)) :=
                             Scale_1 * Real (Q1);
                           Target
                             (Target'First + Out_Half + 32
                              + Element_Count (L)) := Scale_2 * Real (Q2);
                           Target
                             (Target'First + Out_Half + 64
                              + Element_Count (L)) := Scale_3 * Real (Q3);
                           Target
                             (Target'First + Out_Half + 96
                              + Element_Count (L)) := Scale_4 * Real (Q4);
                        end;
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
