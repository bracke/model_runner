with Interfaces;

package body Model_Runner.Quantization.Decoders is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Numerics.Real;

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   --  Elements per k-quant super-block.
   Super : constant := 256;

   --  The sixteen levels a non-linear four-bit quant may take.
   --
   --  Unlike every other format here, a nibble is not a number: it is an
   --  index into this table, and the table is part of the format rather than
   --  of any file. The spacing is fine near zero and coarse away from it,
   --  which is what "non-linear" means and why four bits go further here
   --  than they do in Q4_0. Indexing it is the gather that decides which of
   --  the two compilations of this unit is faster for these two formats.
   Levels : constant array (0 .. 15) of Integer :=
     [-127, -104, -83, -65, -49, -35, -22, -10,
         1,   13,  25,  38,  53,  69,  89, 113];

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
         when G.Type_Q4_1 =>
            --  As Q4_0, with a minimum of its own instead of a fixed bias of
            --  eight: the block carries two half-precision numbers, and a
            --  nibble is scaled and then lifted rather than centred.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D      : constant Real := Scale (Data, Offset);
               Lowest : constant Real := Scale (Data, Offset + 2);
               Base   : constant B.Byte_Index := Data'First + Offset + 4;
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Integer (Packed and 16#0F#)) + Lowest;
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real (Integer (Interfaces.Shift_Right (Packed, 4)))
                       + Lowest;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ4_NL =>
            --  Thirty-two elements, a half-precision scale, then sixteen
            --  bytes of nibbles laid out as Q4_0 lays them: the low nibble
            --  of byte j is element j and the high nibble is element j + 16.
            --  What differs is what a nibble means -- an index into the
            --  level table rather than a number to centre on eight.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D    : constant Real := Scale (Data, Offset);
               Base : constant B.Byte_Index := Data'First + Offset + 2;
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Levels (Integer (Packed and 16#0F#)));
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real
                             (Levels
                                (Integer
                                   (Interfaces.Shift_Right (Packed, 4))));
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ4_XS =>
            --  The same levels over a super-block: two hundred and fifty-six
            --  elements in eight sub-blocks of thirty-two, one
            --  half-precision scale for the whole block and a six-bit scale
            --  for each sub-block. Those six bits are split -- four in a
            --  nibble of scales_l and two in a field of scales_h -- and the
            --  value they carry is signed by subtracting thirty-two.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D : constant Real := Scale (Data, Offset);

               High : constant Interfaces.Unsigned_16 :=
                 Interfaces.Unsigned_16 (Data (Data'First + Offset + 2))
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_16
                         (Data (Data'First + Offset + 3)), 8);

               Low  : constant B.Byte_Index := Data'First + Offset + 4;
               Base : constant B.Byte_Index := Data'First + Offset + 8;
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Nibble : constant Interfaces.Unsigned_8 :=
                       (if Sub mod 2 = 0
                        then Data (Low + B.Byte_Count (Sub / 2)) and 16#0F#
                        else Interfaces.Shift_Right
                               (Data (Low + B.Byte_Count (Sub / 2)), 4));

                     Upper : constant Interfaces.Unsigned_16 :=
                       Interfaces.Shift_Right (High, 2 * Sub) and 3;

                     Level : constant Integer :=
                       Integer (Nibble) + 16 * Integer (Upper);

                     Step : constant Real := D * Real (Level - 32);

                     At_Byte : constant B.Byte_Index :=
                       Base + B.Byte_Count (Sub) * 16;
                     Slot    : constant Element_Count :=
                       Target'First + Element_Count (Sub) * 32;
                  begin
                     for J in 0 .. 15 loop
                        declare
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + B.Byte_Count (J));
                        begin
                           Target (Slot + Element_Count (J)) :=
                             Step * Real (Levels (Integer (Packed and 16#0F#)));
                           Target (Slot + Element_Count (J) + 16) :=
                             Step * Real
                                      (Levels
                                         (Integer
                                            (Interfaces.Shift_Right
                                               (Packed, 4))));
                        end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q5_0 | G.Type_Q5_1 =>
            --  A fifth bit for each element, held apart from the nibbles in
            --  four bytes read as one number: bit j belongs to element j and
            --  bit j + 16 to element j + 16, which is the same rule the
            --  five-bit super-block uses kept in a different place.
            --
            --  These two cost about two and a half times what the four-bit
            --  formats do -- 1.05 nanoseconds an element against 0.43 -- and
            --  the fifth bit is the whole of it. Every other format finds its
            --  extra bits at a fixed place in a byte it is already reading;
            --  here the bit for element j is bit j of a thirty-two bit word,
            --  so the shift amount varies with the element and the loop
            --  cannot be vectorized by an instruction set without a per-lane
            --  shift. Baseline x86-64 has none, and compiling for a host that
            --  does measured slower everywhere else, which is in the README.
            --  Turning the two conditionals into shifts was tried and changed
            --  nothing, which is what said the branch was not the cost.
            --
            --  The two differ only in what happens once the fifth bit is
            --  restored. Q5_0 centres the result by subtracting sixteen, as
            --  Q4_0 subtracts eight; Q5_1 carries a minimum instead, as Q4_1
            --  does. Everything else is the same, which is why they share a
            --  branch rather than repeating one.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Centred : constant Boolean := Format = G.Type_Q5_0;

               --  Q5_0 keeps the fifth bits straight after its one scale;
               --  Q5_1 keeps them after its two.
               Fifths_At : constant B.Byte_Count := (if Centred then 2 else 4);
               Quants_At : constant B.Byte_Count := (if Centred then 6 else 8);

               D      : constant Real := Scale (Data, Offset);
               Lowest : constant Real :=
                 (if Centred then 0.0 else Scale (Data, Offset + 2));
               Bias   : constant Integer := (if Centred then 16 else 0);

               Head   : constant B.Byte_Index := Data'First + Offset;
               Base   : constant B.Byte_Index := Head + Quants_At;

               Fifths : constant Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Data (Head + Fifths_At))
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 1)), 8)
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 2)), 16)
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 3)), 24);
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                     Low_Fifth : constant Integer :=
                       (if (Interfaces.Shift_Right (Fifths, J) and 1) = 1
                        then 16 else 0);
                     High_Fifth : constant Integer :=
                       (if (Interfaces.Shift_Right (Fifths, J + 16) and 1) = 1
                        then 16 else 0);
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Integer (Packed and 16#0F#)
                                 + Low_Fifth - Bias)
                       + Lowest;
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real (Integer (Interfaces.Shift_Right (Packed, 4))
                                 + High_Fifth - Bias)
                       + Lowest;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q2_K =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               --  Sixteen bytes of packed scales, then sixty-four bytes of
               --  quants at two bits each, then the two half-precision
               --  factors. Every element is one of four levels, so the format
               --  leans harder on its scales than any other here: sixteen
               --  sub-blocks of sixteen elements, each with a four-bit scale
               --  and a four-bit minimum sharing one byte.
               Scales  : constant B.Byte_Count := Offset;
               Quants  : constant B.Byte_Count := Offset + 16;
               D       : constant Real := Scale (Data, Offset + 80);
               Minimum : constant Real := Scale (Data, Offset + 82);
            begin
               for Half in 0 .. 1 loop
                  for Group in 0 .. 3 loop
                     for Upper in 0 .. 1 loop
                        declare
                           --  The scales are consumed in the order the
                           --  sub-blocks are written, which is why this is a
                           --  running index rather than an offset computed
                           --  from the element number.
                           Which : constant B.Byte_Count :=
                             B.Byte_Count (Half * 8 + Group * 2 + Upper);
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + Scales + Which);

                           Factor : constant Real :=
                             D * Real (Integer (Packed and 16#0F#));
                           Lowest : constant Real :=
                             Minimum
                             * Real (Integer
                                       (Interfaces.Shift_Right (Packed, 4)));

                           --  Sixteen adjacent bytes to sixteen adjacent
                           --  elements, as everywhere else here.
                           From : constant B.Byte_Count :=
                             Quants + B.Byte_Count (Half * 32 + Upper * 16);
                           Into : constant Element_Count :=
                             Element_Count (Half * 128 + Group * 32
                                            + Upper * 16);
                           Shift : constant Natural := 2 * Group;
                        begin
                           for L in 0 .. 15 loop
                              Target
                                (Target'First + Into + Element_Count (L)) :=
                                Factor
                                * Real (Integer
                                          (Interfaces.Shift_Right
                                             (Data (Data'First + From
                                                    + B.Byte_Count (L)),
                                              Shift)
                                           and 3))
                                - Lowest;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end loop;
               Ok := True;
            end;

         when G.Type_Q3_K =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               --  Three bits an element, in two pieces. The low two are
               --  packed four to a byte as in the two-bit format; the third
               --  lives in a mask of thirty-two bytes shared by the whole
               --  block, one bit per element position per sub-block group,
               --  and it is the bit's absence that lowers the value: set
               --  leaves the two low bits alone, clear takes four away, which
               --  is what makes the range minus four to three rather than
               --  zero to seven.
               High    : constant B.Byte_Count := Offset;
               Quants  : constant B.Byte_Count := Offset + 32;
               Scales  : constant B.Byte_Count := Offset + 96;
               D       : constant Real := Scale (Data, Offset + 108);

               --  The sixteen sub-block scales are six bits each, packed
               --  across twelve bytes: four low bits in one of the first
               --  eight bytes, two high bits in one of the last four. Which
               --  of the four groups a sub-block falls in decides both where
               --  its nibble comes from and how far its two bits are shifted.
               function Sub_Scale (Which : Natural) return Integer is
                  Group : constant Natural := Which / 4;
                  Place : constant B.Byte_Count := B.Byte_Count (Which mod 4);

                  Low_Byte : constant Interfaces.Unsigned_8 :=
                    Data (Data'First + Scales
                          + (if Group mod 2 = 0 then Place else Place + 4));
                  Low : constant Interfaces.Unsigned_8 :=
                    (if Group < 2
                     then Low_Byte and 16#0F#
                     else Interfaces.Shift_Right (Low_Byte, 4));

                  Top : constant Interfaces.Unsigned_8 :=
                    Interfaces.Shift_Right
                      (Data (Data'First + Scales + Place + 8),
                       2 * Group)
                    and 3;
               begin
                  return Integer (Low) + 16 * Integer (Top) - 32;
               end Sub_Scale;
            begin
               for Half in 0 .. 1 loop
                  for Group in 0 .. 3 loop
                     for Upper in 0 .. 1 loop
                        declare
                           Which : constant Natural :=
                             Half * 8 + Group * 2 + Upper;
                           Factor : constant Real :=
                             D * Real (Sub_Scale (Which));

                           From : constant B.Byte_Count :=
                             Quants + B.Byte_Count (Half * 32 + Upper * 16);
                           Mask_At : constant B.Byte_Count :=
                             High + B.Byte_Count (Upper * 16);
                           Into : constant Element_Count :=
                             Element_Count (Half * 128 + Group * 32
                                            + Upper * 16);
                           Shift : constant Natural := 2 * Group;

                           --  One bit of the mask serves one sub-block
                           --  group, and the bit advances across the whole
                           --  block rather than restarting at its middle.
                           Bit : constant Interfaces.Unsigned_8 :=
                             Interfaces.Shift_Left (1, Half * 4 + Group);
                        begin
                           for L in 0 .. 15 loop
                              declare
                                 Low : constant Integer :=
                                   Integer
                                     (Interfaces.Shift_Right
                                        (Data (Data'First + From
                                               + B.Byte_Count (L)),
                                         Shift)
                                      and 3);
                                 Lifted : constant Boolean :=
                                   (Data (Data'First + Mask_At
                                          + B.Byte_Count (L)) and Bit) /= 0;
                              begin
                                 Target
                                   (Target'First + Into + Element_Count (L)) :=
                                   Factor
                                   * Real (if Lifted then Low else Low - 4);
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
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
   ------------------
   -- Decode_Span --
   ------------------

   procedure Decode_Span
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Count  : Element_Count;
      Width  : B.Byte_Count;
      Per    : Element_Count;
      Target : out Real_Array;
      Ok     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Slot : Element_Count := Target'First;
      Step : B.Byte_Count := Offset;
   begin
      Ok := False;

      for Block in 1 .. Count loop
         --  Straight into the destination. This used to decode into a
         --  scratch block and copy 256 elements out of it, which was the
         --  whole of the difference between this path and the formats
         --  unpacked inline.
         Decode_One (Format, Data, Step, Target (Slot .. Slot + Per - 1), Ok);
         exit when not Ok;
         Slot := Slot + Per;
         Step := Step + Width;
      end loop;
   end Decode_Span;

end Model_Runner.Quantization.Decoders;
