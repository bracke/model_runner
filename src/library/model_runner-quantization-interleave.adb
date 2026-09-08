with Interfaces;

package body Model_Runner.Quantization.Interleave is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;

   use type B.Byte_Count;
   use type G.Tensor_Type;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_16;

   --  What one row's super-block occupies, and where its parts are. Written
   --  out rather than asked of Model_Runner.GGUF, because the arithmetic
   --  below is about these formats' own layouts and not about block sizes in
   --  general: a reader checking the permutation wants the numbers where the
   --  permutation is.
   Row_Block_Bytes : constant := 144;
   Scales_At       : constant := 4;
   Quants_At       : constant := 16;

   --  And the six-bit format's own, which is a different shape: the low four
   --  bits of every quant, then the high two, then sixteen signed scale
   --  bytes, then the block's scale.
   --  And the five-bit one's, which is the four-bit block with a run of
   --  fifth bits between the packed scales and the quants.
   Five_Row_Bytes : constant := 176;
   Five_High      : constant := 16;
   Five_Quants    : constant := 48;

   --  And the legacy four-bit block, which is a scale and sixteen bytes of
   --  nibbles. Element J is the low nibble of byte J and element J + 16 the
   --  high one, which is the pairing the panel keeps.
   Legacy_Row_Bytes : constant := 18;
   Legacy_Quants    : constant := 2;

   --  And the one that keeps a minimum where the other keeps a centring:
   --  a scale, a minimum and the same sixteen bytes of nibbles.
   Least_Row_Bytes : constant := 20;
   Least_Quants    : constant := 4;

   --  And the two that carry a fifth bit, where the file keeps that bit as
   --  bit J of a thirty-two bit word beside the nibbles.
   Fifth_Row_Bytes : constant := 22;
   Fifth_High      : constant := 2;
   Fifth_Quants    : constant := 6;

   Fifth_Least_Row_Bytes : constant := 24;
   Fifth_Least_High      : constant := 4;
   Fifth_Least_Quants    : constant := 8;

   --  The two-bit k-quant's block as the file holds it: sixteen bytes of
   --  paired four-bit scale and minimum, sixty-four of quants, then the two
   --  half-precision numbers those nibbles are multiplied by.
   Two_Row_Bytes : constant := 84;
   Two_Scales    : constant := 0;
   Two_Quants    : constant := 16;
   Two_D         : constant := 80;
   Two_Dmin      : constant := 82;

   --  And the three-bit one's: the high bit of every quant first, then the
   --  low two bits, then twelve bytes holding sixteen six-bit scales, then
   --  the block's own scale.
   --  And the two non-linear ones. IQ4_NL's block is Q4_0's shape exactly;
   --  IQ4_XS keeps eight of them behind one scale, with the eight six-bit
   --  sub-block scales split between a nibble each and a pair of bits each.
   --  And the block-exponent format: one E8M0 byte and sixteen of nibbles.
   Micro_Row_Bytes : constant := 17;
   Micro_Quants    : constant := 1;

   Level_Row_Bytes : constant := 136;
   Level_High      : constant := 2;
   Level_Low       : constant := 4;
   Level_Quants    : constant := 8;

   Three_Row_Bytes : constant := 110;
   Three_Hmask     : constant := 0;
   Three_Quants    : constant := 32;
   Three_Scales    : constant := 96;
   Three_D         : constant := 108;

   Six_Row_Bytes : constant := 210;
   Six_Low       : constant := 0;
   Six_High      : constant := 128;
   Six_Scales    : constant := 192;
   Six_Scale     : constant := 208;

   --  The eight scales and eight minima a four-bit super-block's twelve
   --  bytes hold.
   type Six_Bits is array (0 .. 7) of Interfaces.Unsigned_8;

   --  Take them out, which is llama.cpp's get_scale_min_k4 for all eight at
   --  once. The first four of each are a whole six-bit field; the last four
   --  are four bits in one byte and their top two in the spare bits of
   --  another, which is why the loop below is two loops.
   procedure Unpack
     (Packed : B.Byte_Array;
      At_It  : B.Byte_Index;
      Scale  : out Six_Bits;
      Least  : out Six_Bits)
   is
      function Q (Index : Natural) return Interfaces.Unsigned_8
      is (Packed (At_It + B.Byte_Count (Index)));
   begin
      for J in 0 .. 3 loop
         Scale (J) := Q (J) and 63;
         Least (J) := Q (J + 4) and 63;
      end loop;

      for J in 0 .. 3 loop
         Scale (J + 4) :=
           (Q (J + 8) and 16#0F#)
           or Interfaces.Shift_Left (Interfaces.Shift_Right (Q (J), 6), 4);
         Least (J + 4) :=
           Interfaces.Shift_Right (Q (J + 8), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Q (J + 4), 6), 4);
      end loop;
   end Unpack;

   --  And put them back, which is the inverse and is what a row taken out of
   --  a panel needs. Six bits of each of the first four go in whole; the top
   --  two bits of each of the last four ride in the spare bits above them.
   procedure Pack
     (Scale  : Six_Bits;
      Least  : Six_Bits;
      Target : out B.Byte_Array;
      At_It  : B.Byte_Index)
   is
   begin
      for J in 0 .. 3 loop
         Target (At_It + B.Byte_Count (J)) :=
           Scale (J)
           or Interfaces.Shift_Left (Interfaces.Shift_Right (Scale (J + 4), 4),
                                     6);
         Target (At_It + B.Byte_Count (J) + 4) :=
           Least (J)
           or Interfaces.Shift_Left (Interfaces.Shift_Right (Least (J + 4), 4),
                                     6);
         Target (At_It + B.Byte_Count (J) + 8) :=
           (Scale (J + 4) and 16#0F#)
           or Interfaces.Shift_Left (Least (J + 4) and 16#0F#, 4);
      end loop;
   end Pack;

   --  Where a six-bit element's bits are, in the block the file wrote.
   --
   --  A super-block is two halves of a hundred and twenty-eight, and each
   --  half is four runs of thirty-two: two runs share a byte of low bits and
   --  all four share a byte of high bits. This says which byte and which
   --  shift, once, so that Build and Extract_Row cannot disagree about it.
   procedure Six_Places
     (Element : Natural;
      Low_At  : out B.Byte_Count;
      Low_Up  : out Natural;
      High_At : out B.Byte_Count;
      High_Up : out Natural)
   is
      Half   : constant Natural := Element / 128;
      Inside : constant Natural := Element mod 128;
      Run    : constant Natural := Inside / 32;
      Within : constant Natural := Inside mod 32;
   begin
      High_At := B.Byte_Count (Six_High + 32 * Half + Within);
      High_Up := 2 * Run;

      Low_At :=
        B.Byte_Count
          (Six_Low + 64 * Half + Within
           + (if Run mod 2 = 1 then 32 else 0));
      Low_Up := (if Run < 2 then 0 else 4);
   end Six_Places;

   -------------------
   -- Block_Bytes --
   -------------------

   function Block_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type)
      return Model_Runner.Bytes.Byte_Count
   is (if Format = G.Type_Q4_K then Panel_Block_Bytes
       elsif Format = G.Type_Q5_K then Five_Block_Bytes
       elsif Format = G.Type_Q6_K then Six_Block_Bytes
       elsif Format = G.Type_Q4_0 then Legacy_Block_Bytes
       elsif Format = G.Type_Q4_1 then Least_Block_Bytes
       elsif Format = G.Type_Q5_0 then Fifth_Block_Bytes
       elsif Format = G.Type_Q5_1 then Fifth_Least_Block_Bytes
       elsif Format = G.Type_Q2_K then Two_Block_Bytes
       elsif Format = G.Type_Q3_K then Three_Block_Bytes
       elsif Format = G.Type_IQ4_NL then Legacy_Block_Bytes
       elsif Format = G.Type_IQ4_XS then Level_Block_Bytes
       elsif Format = G.Type_MXFP4 then Micro_Block_Bytes
       else 0);

   -----------------------
   -- Panel_Row_Bytes --
   -----------------------

   function Panel_Row_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type)
      return Model_Runner.Bytes.Byte_Count
   is (Block_Bytes (Format) / Panel_Rows);

   -------------------
   -- Panel_Bytes --
   -------------------

   function Panel_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type;
      Rows   : Element_Count;
      Blocks : Element_Count)
      return Model_Runner.Bytes.Byte_Count
   is (B.Byte_Count (Rows / Panel_Rows)
       * B.Byte_Count (Blocks) * Block_Bytes (Format));

   --  Bytes one row's super-block occupies as the file stores it.
   function Native_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type)
      return Model_Runner.Bytes.Byte_Count
   is (if Format = G.Type_Q4_K then Row_Block_Bytes
       elsif Format = G.Type_Q5_K then Five_Row_Bytes
       elsif Format = G.Type_Q6_K then Six_Row_Bytes
       elsif Format = G.Type_Q4_0 then Legacy_Row_Bytes
       elsif Format = G.Type_Q4_1 then Least_Row_Bytes
       elsif Format = G.Type_Q5_0 then Fifth_Row_Bytes
       elsif Format = G.Type_Q5_1 then Fifth_Least_Row_Bytes
       elsif Format = G.Type_Q2_K then Two_Row_Bytes
       elsif Format = G.Type_Q3_K then Three_Row_Bytes
       elsif Format = G.Type_IQ4_NL then Legacy_Row_Bytes
       elsif Format = G.Type_IQ4_XS then Level_Row_Bytes
       elsif Format = G.Type_MXFP4 then Micro_Row_Bytes
       else 0);

   ------------------
   -- Interleaves --
   ------------------

   function Interleaves
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count) return Boolean
   is (((Format = G.Type_Q4_K
         or else Format = G.Type_Q5_K
         or else Format = G.Type_Q6_K
         or else Format = G.Type_Q4_0
         or else Format = G.Type_Q4_1
         or else Format = G.Type_Q5_0
         or else Format = G.Type_Q5_1
         or else Format = G.Type_Q2_K
         or else Format = G.Type_Q3_K
         or else Format = G.Type_IQ4_NL
         or else Format = G.Type_IQ4_XS
         or else Format = G.Type_MXFP4)
        and then Rows > 0
        and then Rows mod Panel_Rows = 0
        and then Columns > 0)
       and then

       --  A whole number of the format's own blocks, which is a super-block
       --  for the three k-quants and thirty-two elements for the legacy one.
       (if Format = G.Type_Q4_0 or else Format = G.Type_Q4_1
          or else Format = G.Type_Q5_0 or else Format = G.Type_Q5_1
          or else Format = G.Type_IQ4_NL
          or else Format = G.Type_MXFP4
        then Columns mod 32 = 0
        else Columns mod 256 = 0));

   --  One row's four-bit or five-bit super-block, written into its panel.
   --
   --  The two are the same block with a run of fifth bits inserted: the same
   --  scale, the same minimum, the same twelve packed six-bit fields and the
   --  same hundred and twenty-eight bytes of nibbles, pairing element E with
   --  element E + 32 exactly as the other does. So the permutation is one
   --  procedure and the fifth bits are a run it copies afterwards, a group
   --  of four rows at a time, into a place the four-bit panel does not have.
   procedure Build_Four
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count;
      Fifth  : Boolean := False)
   is
      Quants : constant B.Byte_Count :=
        (if Fifth then Five_Quants else Quants_At);
      Scale : Six_Bits;
      Least : Six_Bits;
   begin
      --  The block's scale and its minimum, the eight rows' side by side so
      --  that a kernel converts all eight in one instruction.
      Target (Out_At + Panel_Scale_At + Lane * 2)     := Source (In_At);
      Target (Out_At + Panel_Scale_At + Lane * 2 + 1) := Source (In_At + 1);
      Target (Out_At + Panel_Least_At + Lane * 2)     := Source (In_At + 2);
      Target (Out_At + Panel_Least_At + Lane * 2 + 1) := Source (In_At + 3);

      --  The eight sub-block scales and minima, taken out of their six-bit
      --  fields and written a byte each, sub-block major -- so that the
      --  kernel widens eight rows' scale for one sub-block out of eight
      --  consecutive bytes.
      Unpack (Source, In_At + Scales_At, Scale, Least);

      for Sub in 0 .. 7 loop
         Target
           (Out_At + Panel_Factor_At
            + B.Byte_Count (Sub) * Panel_Rows + Lane) := Scale (Sub);
         Target
           (Out_At + Panel_Minimum_At
            + B.Byte_Count (Sub) * Panel_Rows + Lane) := Least (Sub);
      end loop;

      --  And the quants, which is the permutation this layout exists for.
      --  Group G of pair J takes four bytes from each row, and row L's four
      --  land at 4 * L: masking the group's low nibbles leaves lane L
      --  holding row L's four elements of sub-block 2J, and shifting leaves
      --  it holding sub-block 2J + 1's.
      for Pair in B.Byte_Count range 0 .. 3 loop
         for Group in B.Byte_Count range 0 .. 7 loop
            declare
               Wrote : constant B.Byte_Index :=
                 Out_At + Panel_Quants_At
                 + Pair * 256 + Group * 32 + Lane * 4;
               Read  : constant B.Byte_Index :=
                 In_At + Quants + Pair * 32 + Group * 4;
            begin
               Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
            end;
         end loop;
      end loop;

      --  And the fifth bits, a bit an element and a group of four to four
      --  bytes, so that one load of them serves every pair.
      if Fifth then
         for Group in B.Byte_Count range 0 .. 7 loop
            declare
               Wrote : constant B.Byte_Index :=
                 Out_At + Five_High_At + Group * 32 + Lane * 4;
               Read  : constant B.Byte_Index :=
                 In_At + Five_High + Group * 4;
            begin
               Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
            end;
         end loop;
      end if;
   end Build_Four;

   --  The three-bit format's sixteen six-bit scales, which are packed in
   --  twelve bytes by a scheme of their own: four bytes of low nibbles,
   --  four more, then four bytes carrying every scale's top two bits, two
   --  bits to a scale. What comes out is llama.cpp's `aux` shuffle, and the
   --  value a kernel wants is this less thirty-two.
   type Scale_Sixteen is array (0 .. 15) of Interfaces.Unsigned_8;

   procedure Three_Places
     (Packed : B.Byte_Array;
      At_It  : B.Byte_Index;
      Scale  : out Scale_Sixteen)
   is
      function Q (Index : Natural) return Interfaces.Unsigned_8
      is (Packed (At_It + B.Byte_Count (Index)));
   begin
      for Index in 0 .. 3 loop
         Scale (Index) :=
           (Q (Index) and 16#0F#)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Q (8 + Index), 0) and 16#03#, 4);
         Scale (Index + 4) :=
           (Q (Index + 4) and 16#0F#)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Q (8 + Index), 2) and 16#03#, 4);
         Scale (Index + 8) :=
           Interfaces.Shift_Right (Q (Index), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Q (8 + Index), 4) and 16#03#, 4);
         Scale (Index + 12) :=
           Interfaces.Shift_Right (Q (Index + 4), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Q (8 + Index), 6) and 16#03#, 4);
      end loop;
   end Three_Places;

   --  And its inverse, for putting a row back the way the file had it.
   procedure Three_Pack
     (Scale  : Scale_Sixteen;
      Target : in out B.Byte_Array;
      At_It  : B.Byte_Index)
   is
   begin
      for Index in 0 .. 3 loop
         Target (At_It + B.Byte_Count (Index)) :=
           (Scale (Index) and 16#0F#)
           or Interfaces.Shift_Left (Scale (Index + 8) and 16#0F#, 4);
         Target (At_It + B.Byte_Count (Index) + 4) :=
           (Scale (Index + 4) and 16#0F#)
           or Interfaces.Shift_Left (Scale (Index + 12) and 16#0F#, 4);
         Target (At_It + B.Byte_Count (Index) + 8) :=
           Interfaces.Shift_Right (Scale (Index), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Scale (Index + 4), 4), 2)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Scale (Index + 8), 4), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Scale (Index + 12), 4), 6);
      end loop;
   end Three_Pack;

   --  Where element E of a two- or three-bit super-block has its low bits:
   --  the byte, and how far to shift it. Both formats pack them the same
   --  way, in two halves of a hundred and twenty-eight with a shift that
   --  steps every thirty-two.
   procedure Low_Places
     (Element : Element_Count;
      At_Byte : out B.Byte_Count;
      Shift   : out Natural)
   is
      Half : constant Element_Count := Element / 128;
      Rest : constant Element_Count := Element mod 128;
   begin
      At_Byte := B.Byte_Count (Half * 32 + Rest mod 32);
      Shift   := Natural (Rest / 32) * 2;
   end Low_Places;

   --  And one row's legacy four-bit block, which is the shortest of the
   --  four permutations because this format packs nothing.
   --
   --  Its scale goes where the k-quant's goes and its sixteen bytes of
   --  nibbles go four at a time into four groups, exactly as the k-quant's
   --  hundred and twenty-eight go into thirty-two. The pairing comes with
   --  them: this format's byte holds element J and element J + 16 where the
   --  k-quant's holds E and E + 32, so a group masked low is four elements
   --  of the block's first half and the same group shifted is four of its
   --  second.
   procedure Build_Legacy
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Legacy_Scale_At + Lane * 2)     := Source (In_At);
      Target (Out_At + Legacy_Scale_At + Lane * 2 + 1) := Source (In_At + 1);

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Legacy_Quants_At + Group * 32 + Lane * 4;
            Read  : constant B.Byte_Index :=
              In_At + Legacy_Quants + Group * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Build_Legacy;

   --  And one row's legacy four-bit block that keeps a minimum.
   --
   --  The same permutation as the one above with a second number beside the
   --  scale. The nibbles are not touched differently at all: what the
   --  minimum changes is the kernel's arithmetic, not the layout's.
   procedure Build_Least
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Least_Scale_At + Lane * 2)     := Source (In_At);
      Target (Out_At + Least_Scale_At + Lane * 2 + 1) := Source (In_At + 1);
      Target (Out_At + Least_Least_At + Lane * 2)     := Source (In_At + 2);
      Target (Out_At + Least_Least_At + Lane * 2 + 1) := Source (In_At + 3);

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Least_Quants_At + Group * 32 + Lane * 4;
            Read  : constant B.Byte_Index :=
              In_At + Least_Quants + Group * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Build_Least;

   --  And one row's block of either five-bit legacy format.
   --
   --  The nibbles go exactly where the four-bit formats' go. What is new is
   --  the run of fifth bits, and it is the whole reason these two are worth
   --  a panel: the file keeps them as bit J of a thirty-two bit word, so a
   --  row product's shift varies with the element and the loop will not
   --  vectorize. Written here, the shift is decided once and the kernel's
   --  is an immediate.
   --
   --  Byte 4L + M of the run carries row L's fifth bits for the eight
   --  elements that share position M: bit 2C for element 4C + M and bit
   --  2C + 1 for element 4C + M + 16. Those are exactly the two elements
   --  whose low nibbles sit in byte 4L + M of group C, so one load of the
   --  run serves every group of the block at a shift apiece.
   procedure Build_Fifth
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count;
      Least  : Boolean)
   is
      Scale_At  : constant B.Byte_Count :=
        (if Least then Fifth_Least_Scale_At else Fifth_Scale_At);
      Quants_At : constant B.Byte_Count :=
        (if Least then Fifth_Least_Quants_At else Fifth_Quants_At);
      Fifths_At : constant B.Byte_Count :=
        (if Least then Fifth_Least_Fifths_At else Fifth_Fifths_At);

      High   : constant B.Byte_Count :=
        (if Least then Fifth_Least_High else Fifth_High);
      Quants : constant B.Byte_Count :=
        (if Least then Fifth_Least_Quants else Fifth_Quants);

      --  The four bytes the file keeps the fifth bits in, read as the one
      --  little-endian word the format defines them to be.
      Bits : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Source (In_At + High))
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (Source (In_At + High + 1)), 8)
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (Source (In_At + High + 2)), 16)
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (Source (In_At + High + 3)), 24);

      function Bit (Index : Natural) return Interfaces.Unsigned_8
      is (Interfaces.Unsigned_8
            (Interfaces.Shift_Right (Bits, Index) and 1));
   begin
      Target (Out_At + Scale_At + Lane * 2)     := Source (In_At);
      Target (Out_At + Scale_At + Lane * 2 + 1) := Source (In_At + 1);

      if Least then
         Target (Out_At + Fifth_Least_Minimum_At + Lane * 2) :=
           Source (In_At + 2);
         Target (Out_At + Fifth_Least_Minimum_At + Lane * 2 + 1) :=
           Source (In_At + 3);
      end if;

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Quants_At + Group * 32 + Lane * 4;
            Read  : constant B.Byte_Index :=
              In_At + Quants + Group * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;

      for Place in B.Byte_Count range 0 .. 3 loop
         declare
            Packed : Interfaces.Unsigned_8 := 0;
         begin
            for Group in 0 .. 3 loop
               Packed := Packed
                 or Interfaces.Shift_Left
                      (Bit (Group * 4 + Natural (Place)), Group * 2)
                 or Interfaces.Shift_Left
                      (Bit (Group * 4 + Natural (Place) + 16),
                       Group * 2 + 1);
            end loop;

            Target (Out_At + Fifths_At + Lane * 4 + Place) := Packed;
         end;
      end loop;
   end Build_Fifth;

   --  One row's two-bit super-block, written into its panel.
   --
   --  The sixteen scales and sixteen minima come out of their nibbles here
   --  and go a byte apiece, sub-block major, for the reason the four-bit
   --  k-quant's do: a kernel wants eight rows' scale for one sub-block as
   --  eight consecutive bytes, and unpacking that in the kernel is work
   --  paid once a product instead of once a load.
   --
   --  And a quant is two bits, so a group of thirty-two bytes carries
   --  sixteen elements a row rather than eight: byte 4L + M of group G
   --  holds row L's elements 16G + M, 16G + 4 + M, 16G + 8 + M and
   --  16G + 12 + M at the four pairs of bits, which is one load and four
   --  shifts for four runs of four consecutive elements.
   procedure Build_Two
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Two_Scale_At + Lane * 2)     :=
        Source (In_At + Two_D);
      Target (Out_At + Two_Scale_At + Lane * 2 + 1) :=
        Source (In_At + Two_D + 1);
      Target (Out_At + Two_Least_At + Lane * 2)     :=
        Source (In_At + Two_Dmin);
      Target (Out_At + Two_Least_At + Lane * 2 + 1) :=
        Source (In_At + Two_Dmin + 1);

      for Sub in B.Byte_Count range 0 .. 15 loop
         declare
            Packed : constant Interfaces.Unsigned_8 :=
              Source (In_At + Two_Scales + Sub);
         begin
            Target (Out_At + Two_Factor_At + Sub * Panel_Rows + Lane) :=
              Packed and 16#0F#;
            Target (Out_At + Two_Minimum_At + Sub * Panel_Rows + Lane) :=
              Interfaces.Shift_Right (Packed, 4);
         end;
      end loop;

      for Group in Element_Count range 0 .. 15 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : Interfaces.Unsigned_8 := 0;
            begin
               for Step in Element_Count range 0 .. 3 loop
                  declare
                     At_Byte : B.Byte_Count;
                     Shift   : Natural;
                  begin
                     Low_Places
                       (Group * 16 + Step * 4 + Place, At_Byte, Shift);
                     Packed := Packed
                       or Interfaces.Shift_Left
                            (Interfaces.Shift_Right
                               (Source (In_At + Two_Quants + At_Byte), Shift)
                             and 16#03#,
                             Natural (Step) * 2);
                  end;
               end loop;

               Target
                 (Out_At + Two_Quants_At + B.Byte_Count (Group) * 32
                  + Lane * 4 + B.Byte_Count (Place)) := Packed;
            end;
         end loop;
      end loop;
   end Build_Two;

   --  And one row's three-bit super-block.
   --
   --  Its sixteen scales are six bits packed by a scheme of their own and
   --  come out here as signed bytes; its low two bits go where the two-bit
   --  format's whole quant goes; and its high bit goes into a run of its
   --  own, two groups to a byte, so that one load serves two groups at four
   --  shifts each and every shift is an immediate.
   procedure Build_Three
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      Scale : Scale_Sixteen;
   begin
      Target (Out_At + Three_Scale_At + Lane * 2)     :=
        Source (In_At + Three_D);
      Target (Out_At + Three_Scale_At + Lane * 2 + 1) :=
        Source (In_At + Three_D + 1);

      Three_Places (Source, In_At + Three_Scales, Scale);

      for Sub in B.Byte_Count range 0 .. 15 loop
         Target (Out_At + Three_Factor_At + Sub * Panel_Rows + Lane) :=
           Scale (Natural (Sub)) - 32;
      end loop;

      for Group in Element_Count range 0 .. 15 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : Interfaces.Unsigned_8 := 0;
            begin
               for Step in Element_Count range 0 .. 3 loop
                  declare
                     At_Byte : B.Byte_Count;
                     Shift   : Natural;
                  begin
                     Low_Places
                       (Group * 16 + Step * 4 + Place, At_Byte, Shift);
                     Packed := Packed
                       or Interfaces.Shift_Left
                            (Interfaces.Shift_Right
                               (Source (In_At + Three_Quants + At_Byte),
                                Shift)
                             and 16#03#,
                             Natural (Step) * 2);
                  end;
               end loop;

               Target
                 (Out_At + Three_Low_At + B.Byte_Count (Group) * 32
                  + Lane * 4 + B.Byte_Count (Place)) := Packed;
            end;
         end loop;
      end loop;

      for Run in Element_Count range 0 .. 7 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : Interfaces.Unsigned_8 := 0;
            begin
               for Pair in Element_Count range 0 .. 1 loop
                  for Step in Element_Count range 0 .. 3 loop
                     declare
                        Element : constant Element_Count :=
                          Run * 32 + Pair * 16 + Step * 4 + Place;

                        Half : constant Element_Count := Element / 128;
                        Rest : constant Element_Count := Element mod 128;

                        Bit : constant Natural :=
                          Natural (Half) * 4 + Natural (Rest / 32);

                        Mask : constant Interfaces.Unsigned_8 :=
                          Interfaces.Shift_Right
                            (Source (In_At + Three_Hmask
                                     + B.Byte_Count (Rest mod 32)),
                             Bit)
                          and 1;
                     begin
                        Packed := Packed
                          or Interfaces.Shift_Left
                               (Mask, Natural (Pair) * 4 + Natural (Step));
                     end;
                  end loop;
               end loop;

               Target
                 (Out_At + Three_High_At + B.Byte_Count (Run) * 32
                  + Lane * 4 + B.Byte_Count (Place)) := Packed;
            end;
         end loop;
      end loop;
   end Build_Three;

   --  One row's non-linear super-block, written into its panel.
   --
   --  The eight six-bit sub-block scales come out of their nibble-and-pair
   --  here and go a signed byte apiece, sub-block major -- the same
   --  arrangement every other panel with sub-blocks uses, and for the same
   --  reason. The nibbles are not touched at all: an index into the level
   --  table is still an index, and turning it into a level is one
   --  instruction in the kernel rather than a byte an element here.
   procedure Build_Level
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      High : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Source (In_At + Level_High))
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_16 (Source (In_At + Level_High + 1)), 8);
   begin
      Target (Out_At + Level_Scale_At + Lane * 2)     := Source (In_At);
      Target (Out_At + Level_Scale_At + Lane * 2 + 1) := Source (In_At + 1);

      for Sub in B.Byte_Count range 0 .. 7 loop
         declare
            Nibble : constant Interfaces.Unsigned_8 :=
              (if Sub mod 2 = 0
               then Source (In_At + Level_Low + Sub / 2) and 16#0F#
               else Interfaces.Shift_Right
                      (Source (In_At + Level_Low + Sub / 2), 4));

            Upper : constant Interfaces.Unsigned_8 :=
              Interfaces.Unsigned_8
                (Interfaces.Shift_Right (High, 2 * Natural (Sub)) and 3);
         begin
            Target (Out_At + Level_Factor_At + Sub * Panel_Rows + Lane) :=
              (Nibble or Interfaces.Shift_Left (Upper, 4)) - 32;
         end;
      end loop;

      for Group in B.Byte_Count range 0 .. 31 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Level_Quants_At + Group * 32 + Lane * 4;
            Read  : constant B.Byte_Index :=
              In_At + Level_Quants + Group * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Build_Level;

   --  One row's block-exponent block, written into its panel.
   --
   --  The nibbles go exactly where IQ4_NL's go. What is done here and
   --  nowhere else is the scale: the file keeps an E8M0 exponent byte and
   --  the panel keeps the binary32 number it stands for, because two to the
   --  byte less a hundred and twenty-eight does not fit in a half at either
   --  end of its range. The conversion is the one the decoder does, a bit
   --  pattern rather than a power taken at run time, so it is exact.
   procedure Build_Micro
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      Held : constant Interfaces.Unsigned_8 := Source (In_At);

      --  Two to the byte less a hundred and twenty-eight has a biased
      --  exponent of the byte less one and no mantissa; the two bytes below
      --  that are subnormal, where what shifts is the leading bit.
      Bits : constant Interfaces.Unsigned_32 :=
        (if Held < 2
         then Interfaces.Shift_Left (16#0020_0000#, Natural (Held))
         else Interfaces.Shift_Left
                (Interfaces.Unsigned_32 (Held) - 1, 23));
   begin
      for Index in B.Byte_Count range 0 .. 3 loop
         Target (Out_At + Micro_Scale_At + Lane * 4 + Index) :=
           Interfaces.Unsigned_8
             (Interfaces.Shift_Right (Bits, Natural (Index) * 8)
              and 16#FF#);
      end loop;

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Micro_Quants_At + Group * 32 + Lane * 4;
            Read  : constant B.Byte_Index :=
              In_At + Micro_Quants + Group * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Build_Micro;

   --  And one row's six-bit super-block.
   --
   --  Its block scale and its sixteen sub-block scales are already whole
   --  bytes, so the only thing rearranged about them is where they sit. The
   --  quants are taken apart into the two runs the kernel unpacks them from:
   --  group P of four elements in the low nibbles and group P + 32 in the
   --  high ones, as the four-bit format pairs its sub-blocks, and the high
   --  two bits four groups to a byte, the shift saying which of the four.
   procedure Build_Six
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Six_Scale_At + Lane * 2)     :=
        Source (In_At + Six_Scale);
      Target (Out_At + Six_Scale_At + Lane * 2 + 1) :=
        Source (In_At + Six_Scale + 1);

      for Sub in 0 .. 15 loop
         Target
           (Out_At + Six_Factor_At
            + B.Byte_Count (Sub) * Panel_Rows + Lane) :=
           Source (In_At + Six_Scales + B.Byte_Count (Sub));
      end loop;

      --  Four elements at a time, because a group's four are consecutive on
      --  both sides: their source bytes are four in a row, their
      --  destination bytes are four in a row, and the shift each is read at
      --  is the same. Asked one element at a time this loop was the whole
      --  of what a panelled load cost -- nine per cent of a profile, with
      --  the rest of the pass a slice copy.
      for Group in 0 .. 63 loop
         declare
            Low_At  : B.Byte_Count;
            Low_Up  : Natural;
            High_At : B.Byte_Count;
            High_Up : Natural;

            Spot : constant B.Byte_Index :=
              Out_At + Six_Low_At
              + B.Byte_Count (Group mod 32) * 32 + Lane * 4;
            Over : constant B.Byte_Index :=
              Out_At + Six_High_At
              + B.Byte_Count (Group mod 16) * 32 + Lane * 4;

            Up : constant Natural := 2 * (Group / 16);
         begin
            Six_Places (Group * 4, Low_At, Low_Up, High_At, High_Up);

            for Which in B.Byte_Count range 0 .. 3 loop
               declare
                  Nibble : constant Interfaces.Unsigned_8 :=
                    Interfaces.Shift_Right
                      (Source (In_At + Low_At + Which), Low_Up) and 16#0F#;
                  Topmost : constant Interfaces.Unsigned_8 :=
                    Interfaces.Shift_Right
                      (Source (In_At + High_At + Which), High_Up) and 3;
               begin
                  if Group < 32 then
                     Target (Spot + Which) := Nibble;
                  else
                     Target (Spot + Which) :=
                       Target (Spot + Which)
                       or Interfaces.Shift_Left (Nibble, 4);
                  end if;

                  if Group < 16 then
                     Target (Over + Which) := Topmost;
                  else
                     Target (Over + Which) :=
                       Target (Over + Which)
                       or Interfaces.Shift_Left (Topmost, Up);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Build_Six;

   -------------
   -- Build --
   -------------

   procedure Build
     (Format : Model_Runner.GGUF.Tensor_Type;
      Source : Model_Runner.Bytes.Byte_Array;
      From   : Model_Runner.Bytes.Byte_Count;
      Target : in out Model_Runner.Bytes.Byte_Array;
      Into   : Model_Runner.Bytes.Byte_Count;
      Rows   : Element_Count;
      Blocks : Element_Count;
      Ok     : out Boolean)
   is
      Native   : constant B.Byte_Count := Native_Bytes (Format);
      Panelled : constant B.Byte_Count := Block_Bytes (Format);

      Row_Span : constant B.Byte_Count := B.Byte_Count (Blocks) * Native;
      Whole    : constant B.Byte_Count := Row_Span * B.Byte_Count (Rows);
   begin
      Ok := False;

      if Rows = 0 or else Blocks = 0
        or else Rows mod Panel_Rows /= 0
        or else Native = 0
      then
         return;
      end if;

      if not B.Has_Room (Source, From, Whole)
        or else not B.Has_Room
                      (Target, Into, Panel_Bytes (Format, Rows, Blocks))
      then
         return;
      end if;

      for Panel in Element_Count range 0 .. Rows / Panel_Rows - 1 loop
         declare
            Panel_In  : constant B.Byte_Index :=
              Source'First + From
              + Row_Span * B.Byte_Count (Panel * Panel_Rows);
            Panel_Out : constant B.Byte_Index :=
              Target'First + Into
              + B.Byte_Count (Panel) * B.Byte_Count (Blocks) * Panelled;
         begin
            for Block in Element_Count range 0 .. Blocks - 1 loop
               declare
                  Out_At : constant B.Byte_Index :=
                    Panel_Out + B.Byte_Count (Block) * Panelled;
               begin
                  for Row in 0 .. Panel_Rows - 1 loop
                     declare
                        In_At : constant B.Byte_Index :=
                          Panel_In
                          + Row_Span * B.Byte_Count (Row)
                          + B.Byte_Count (Block) * Native;
                     begin
                        if Format = G.Type_Q6_K then
                           Build_Six
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_Q4_0 then
                           Build_Legacy
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_Q4_1 then
                           Build_Least
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_Q5_0
                          or else Format = G.Type_Q5_1
                        then
                           Build_Fifth
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row),
                              Least => Format = G.Type_Q5_1);
                        elsif Format = G.Type_Q2_K then
                           Build_Two
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_Q3_K then
                           Build_Three
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_IQ4_NL then

                           --  This format's block is Q4_0's shape, so its
                           --  panel is Q4_0's panel. Only the kernel knows
                           --  the difference.
                           Build_Legacy
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_IQ4_XS then
                           Build_Level
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        elsif Format = G.Type_MXFP4 then
                           Build_Micro
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row));
                        else
                           Build_Four
                             (Source, In_At, Target, Out_At,
                              B.Byte_Count (Row),
                              Fifth => Format = G.Type_Q5_K);
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;

      Ok := True;
   end Build;

   --  One row of a four-bit or five-bit panel, put back the way the file
   --  had it.
   procedure Take_Four
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count;
      Fifth  : Boolean := False)
   is
      Quants : constant B.Byte_Count :=
        (if Fifth then Five_Quants else Quants_At);
      Scale : Six_Bits;
      Least : Six_Bits;
   begin
      Target (Out_At)     := Source (In_At + Panel_Scale_At + Lane * 2);
      Target (Out_At + 1) := Source (In_At + Panel_Scale_At + Lane * 2 + 1);
      Target (Out_At + 2) := Source (In_At + Panel_Least_At + Lane * 2);
      Target (Out_At + 3) := Source (In_At + Panel_Least_At + Lane * 2 + 1);

      for Sub in 0 .. 7 loop
         Scale (Sub) :=
           Source (In_At + Panel_Factor_At
                   + B.Byte_Count (Sub) * Panel_Rows + Lane);
         Least (Sub) :=
           Source (In_At + Panel_Minimum_At
                   + B.Byte_Count (Sub) * Panel_Rows + Lane);
      end loop;

      Pack (Scale, Least, Target, Out_At + Scales_At);

      for Pair in B.Byte_Count range 0 .. 3 loop
         for Group in B.Byte_Count range 0 .. 7 loop
            declare
               Wrote : constant B.Byte_Index :=
                 Out_At + Quants + Pair * 32 + Group * 4;
               Read  : constant B.Byte_Index :=
                 In_At + Panel_Quants_At
                 + Pair * 256 + Group * 32 + Lane * 4;
            begin
               Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
            end;
         end loop;
      end loop;

      if Fifth then
         for Group in B.Byte_Count range 0 .. 7 loop
            declare
               Wrote : constant B.Byte_Index :=
                 Out_At + Five_High + Group * 4;
               Read  : constant B.Byte_Index :=
                 In_At + Five_High_At + Group * 32 + Lane * 4;
            begin
               Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
            end;
         end loop;
      end if;
   end Take_Four;

   --  And one row of a legacy four-bit panel.
   procedure Take_Legacy
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At)     := Source (In_At + Legacy_Scale_At + Lane * 2);
      Target (Out_At + 1) := Source (In_At + Legacy_Scale_At + Lane * 2 + 1);

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Legacy_Quants + Group * 4;
            Read  : constant B.Byte_Index :=
              In_At + Legacy_Quants_At + Group * 32 + Lane * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Take_Legacy;

   --  And one row of a panel in that layout.
   procedure Take_Least
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At)     := Source (In_At + Least_Scale_At + Lane * 2);
      Target (Out_At + 1) := Source (In_At + Least_Scale_At + Lane * 2 + 1);
      Target (Out_At + 2) := Source (In_At + Least_Least_At + Lane * 2);
      Target (Out_At + 3) := Source (In_At + Least_Least_At + Lane * 2 + 1);

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Least_Quants + Group * 4;
            Read  : constant B.Byte_Index :=
              In_At + Least_Quants_At + Group * 32 + Lane * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Take_Least;

   --  And one row of a five-bit legacy panel, put back the way the file
   --  had it -- the fifth bits gathered out of the four bytes they were
   --  spread across and written as the word the format defines.
   procedure Take_Fifth
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count;
      Least  : Boolean)
   is
      Scale_At  : constant B.Byte_Count :=
        (if Least then Fifth_Least_Scale_At else Fifth_Scale_At);
      Quants_At : constant B.Byte_Count :=
        (if Least then Fifth_Least_Quants_At else Fifth_Quants_At);
      Fifths_At : constant B.Byte_Count :=
        (if Least then Fifth_Least_Fifths_At else Fifth_Fifths_At);

      High   : constant B.Byte_Count :=
        (if Least then Fifth_Least_High else Fifth_High);
      Quants : constant B.Byte_Count :=
        (if Least then Fifth_Least_Quants else Fifth_Quants);

      Bits : Interfaces.Unsigned_32 := 0;
   begin
      Target (Out_At)     := Source (In_At + Scale_At + Lane * 2);
      Target (Out_At + 1) := Source (In_At + Scale_At + Lane * 2 + 1);

      if Least then
         Target (Out_At + 2) :=
           Source (In_At + Fifth_Least_Minimum_At + Lane * 2);
         Target (Out_At + 3) :=
           Source (In_At + Fifth_Least_Minimum_At + Lane * 2 + 1);
      end if;

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Quants + Group * 4;
            Read  : constant B.Byte_Index :=
              In_At + Quants_At + Group * 32 + Lane * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;

      for Place in B.Byte_Count range 0 .. 3 loop
         declare
            Packed : constant Interfaces.Unsigned_8 :=
              Source (In_At + Fifths_At + Lane * 4 + Place);
         begin
            for Group in 0 .. 3 loop
               Bits := Bits
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Interfaces.Shift_Right (Packed, Group * 2) and 1),
                       Group * 4 + Natural (Place))
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Interfaces.Shift_Right (Packed, Group * 2 + 1)
                          and 1),
                       Group * 4 + Natural (Place) + 16);
            end loop;
         end;
      end loop;

      for Index in B.Byte_Count range 0 .. 3 loop
         Target (Out_At + High + Index) :=
           Interfaces.Unsigned_8
             (Interfaces.Shift_Right (Bits, Natural (Index) * 8) and 16#FF#);
      end loop;
   end Take_Fifth;

   --  One row of a two-bit panel, put back the way the file had it.
   procedure Take_Two
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Two_D)     :=
        Source (In_At + Two_Scale_At + Lane * 2);
      Target (Out_At + Two_D + 1) :=
        Source (In_At + Two_Scale_At + Lane * 2 + 1);
      Target (Out_At + Two_Dmin)     :=
        Source (In_At + Two_Least_At + Lane * 2);
      Target (Out_At + Two_Dmin + 1) :=
        Source (In_At + Two_Least_At + Lane * 2 + 1);

      for Sub in B.Byte_Count range 0 .. 15 loop
         Target (Out_At + Two_Scales + Sub) :=
           Source (In_At + Two_Factor_At + Sub * Panel_Rows + Lane)
           or Interfaces.Shift_Left
                (Source (In_At + Two_Minimum_At + Sub * Panel_Rows + Lane),
                 4);
      end loop;

      for Index in B.Byte_Count range 0 .. 63 loop
         Target (Out_At + Two_Quants + Index) := 0;
      end loop;

      for Group in Element_Count range 0 .. 15 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : constant Interfaces.Unsigned_8 :=
                 Source (In_At + Two_Quants_At + B.Byte_Count (Group) * 32
                         + Lane * 4 + B.Byte_Count (Place));
            begin
               for Step in Element_Count range 0 .. 3 loop
                  declare
                     At_Byte : B.Byte_Count;
                     Shift   : Natural;
                  begin
                     Low_Places
                       (Group * 16 + Step * 4 + Place, At_Byte, Shift);
                     Target (Out_At + Two_Quants + At_Byte) :=
                       Target (Out_At + Two_Quants + At_Byte)
                       or Interfaces.Shift_Left
                            (Interfaces.Shift_Right
                               (Packed, Natural (Step) * 2) and 16#03#,
                             Shift);
                  end;
               end loop;
            end;
         end loop;
      end loop;
   end Take_Two;

   --  And one row of a three-bit panel.
   procedure Take_Three
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      Scale : Scale_Sixteen;
   begin
      Target (Out_At + Three_D)     :=
        Source (In_At + Three_Scale_At + Lane * 2);
      Target (Out_At + Three_D + 1) :=
        Source (In_At + Three_Scale_At + Lane * 2 + 1);

      for Sub in B.Byte_Count range 0 .. 15 loop
         Scale (Natural (Sub)) :=
           Source (In_At + Three_Factor_At + Sub * Panel_Rows + Lane) + 32;
      end loop;

      Three_Pack (Scale, Target, Out_At + Three_Scales);

      for Index in B.Byte_Count range 0 .. 95 loop
         Target (Out_At + Three_Hmask + Index) := 0;
      end loop;

      for Group in Element_Count range 0 .. 15 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : constant Interfaces.Unsigned_8 :=
                 Source (In_At + Three_Low_At + B.Byte_Count (Group) * 32
                         + Lane * 4 + B.Byte_Count (Place));
            begin
               for Step in Element_Count range 0 .. 3 loop
                  declare
                     At_Byte : B.Byte_Count;
                     Shift   : Natural;
                  begin
                     Low_Places
                       (Group * 16 + Step * 4 + Place, At_Byte, Shift);
                     Target (Out_At + Three_Quants + At_Byte) :=
                       Target (Out_At + Three_Quants + At_Byte)
                       or Interfaces.Shift_Left
                            (Interfaces.Shift_Right
                               (Packed, Natural (Step) * 2) and 16#03#,
                             Shift);
                  end;
               end loop;
            end;
         end loop;
      end loop;

      for Run in Element_Count range 0 .. 7 loop
         for Place in Element_Count range 0 .. 3 loop
            declare
               Packed : constant Interfaces.Unsigned_8 :=
                 Source (In_At + Three_High_At + B.Byte_Count (Run) * 32
                         + Lane * 4 + B.Byte_Count (Place));
            begin
               for Pair in Element_Count range 0 .. 1 loop
                  for Step in Element_Count range 0 .. 3 loop
                     declare
                        Element : constant Element_Count :=
                          Run * 32 + Pair * 16 + Step * 4 + Place;

                        Half : constant Element_Count := Element / 128;
                        Rest : constant Element_Count := Element mod 128;

                        Bit : constant Natural :=
                          Natural (Half) * 4 + Natural (Rest / 32);

                        Held : constant Interfaces.Unsigned_8 :=
                          Interfaces.Shift_Right
                            (Packed, Natural (Pair) * 4 + Natural (Step))
                          and 1;
                     begin
                        Target
                          (Out_At + Three_Hmask
                           + B.Byte_Count (Rest mod 32)) :=
                          Target (Out_At + Three_Hmask
                                  + B.Byte_Count (Rest mod 32))
                          or Interfaces.Shift_Left (Held, Bit);
                     end;
                  end loop;
               end loop;
            end;
         end loop;
      end loop;
   end Take_Three;

   --  And one row of a non-linear panel.
   procedure Take_Level
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      High : Interfaces.Unsigned_16 := 0;
   begin
      Target (Out_At)     := Source (In_At + Level_Scale_At + Lane * 2);
      Target (Out_At + 1) := Source (In_At + Level_Scale_At + Lane * 2 + 1);

      Target (Out_At + Level_Low .. Out_At + Level_Low + 3) := [others => 0];

      for Sub in B.Byte_Count range 0 .. 7 loop
         declare
            Level : constant Interfaces.Unsigned_8 :=
              Source (In_At + Level_Factor_At + Sub * Panel_Rows + Lane)
              + 32;
         begin
            if Sub mod 2 = 0 then
               Target (Out_At + Level_Low + Sub / 2) :=
                 Target (Out_At + Level_Low + Sub / 2)
                 or (Level and 16#0F#);
            else
               Target (Out_At + Level_Low + Sub / 2) :=
                 Target (Out_At + Level_Low + Sub / 2)
                 or Interfaces.Shift_Left (Level and 16#0F#, 4);
            end if;

            High := High
              or Interfaces.Shift_Left
                   (Interfaces.Unsigned_16
                      (Interfaces.Shift_Right (Level, 4) and 3),
                    2 * Natural (Sub));
         end;
      end loop;

      Target (Out_At + Level_High) :=
        Interfaces.Unsigned_8 (High and 16#FF#);
      Target (Out_At + Level_High + 1) :=
        Interfaces.Unsigned_8 (Interfaces.Shift_Right (High, 8));

      for Group in B.Byte_Count range 0 .. 31 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Level_Quants + Group * 4;
            Read  : constant B.Byte_Index :=
              In_At + Level_Quants_At + Group * 32 + Lane * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Take_Level;

   --  And one row of a block-exponent panel, the scale taken back to the
   --  exponent byte it came from.
   procedure Take_Micro
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
      Bits : Interfaces.Unsigned_32 := 0;
   begin
      for Index in B.Byte_Count range 0 .. 3 loop
         Bits := Bits
           or Interfaces.Shift_Left
                (Interfaces.Unsigned_32
                   (Source (In_At + Micro_Scale_At + Lane * 4 + Index)),
                 Natural (Index) * 8);
      end loop;

      --  The two subnormal patterns stand for exponents nought and one;
      --  every other is the biased exponent plus one.
      Target (Out_At) :=
        (if Bits = 16#0020_0000# then 0
         elsif Bits = 16#0040_0000# then 1
         else Interfaces.Unsigned_8
                (Interfaces.Shift_Right (Bits, 23) + 1));

      for Group in B.Byte_Count range 0 .. 3 loop
         declare
            Wrote : constant B.Byte_Index :=
              Out_At + Micro_Quants + Group * 4;
            Read  : constant B.Byte_Index :=
              In_At + Micro_Quants_At + Group * 32 + Lane * 4;
         begin
            Target (Wrote .. Wrote + 3) := Source (Read .. Read + 3);
         end;
      end loop;
   end Take_Micro;

   --  And one row of a six-bit one.
   procedure Take_Six
     (Source : B.Byte_Array;
      In_At  : B.Byte_Index;
      Target : in out B.Byte_Array;
      Out_At : B.Byte_Index;
      Lane   : B.Byte_Count)
   is
   begin
      Target (Out_At + Six_Scale)     :=
        Source (In_At + Six_Scale_At + Lane * 2);
      Target (Out_At + Six_Scale + 1) :=
        Source (In_At + Six_Scale_At + Lane * 2 + 1);

      for Sub in 0 .. 15 loop
         Target (Out_At + Six_Scales + B.Byte_Count (Sub)) :=
           Source (In_At + Six_Factor_At
                   + B.Byte_Count (Sub) * Panel_Rows + Lane);
      end loop;

      for Group in 0 .. 63 loop
         declare
            Low_At  : B.Byte_Count;
            Low_Up  : Natural;
            High_At : B.Byte_Count;
            High_Up : Natural;

            Spot : constant B.Byte_Index :=
              In_At + Six_Low_At
              + B.Byte_Count (Group mod 32) * 32 + Lane * 4;
            Over : constant B.Byte_Index :=
              In_At + Six_High_At
              + B.Byte_Count (Group mod 16) * 32 + Lane * 4;

            Up : constant Natural := 2 * (Group / 16);
         begin
            Six_Places (Group * 4, Low_At, Low_Up, High_At, High_Up);

            for Which in B.Byte_Count range 0 .. 3 loop
               declare
                  Nibble : constant Interfaces.Unsigned_8 :=
                    (if Group < 32
                     then Source (Spot + Which) and 16#0F#
                     else Interfaces.Shift_Right (Source (Spot + Which), 4));
                  Topmost : constant Interfaces.Unsigned_8 :=
                    Interfaces.Shift_Right (Source (Over + Which), Up) and 3;
               begin
                  Target (Out_At + Low_At + Which) :=
                    Target (Out_At + Low_At + Which)
                    or Interfaces.Shift_Left (Nibble, Low_Up);
                  Target (Out_At + High_At + Which) :=
                    Target (Out_At + High_At + Which)
                    or Interfaces.Shift_Left (Topmost, High_Up);
               end;
            end loop;
         end;
      end loop;
   end Take_Six;

   -------------------
   -- Extract_Row --
   -------------------

   procedure Extract_Row
     (Format : Model_Runner.GGUF.Tensor_Type;
      Source : Model_Runner.Bytes.Byte_Array;
      From   : Model_Runner.Bytes.Byte_Count;
      Row    : Element_Count;
      Blocks : Element_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean)
   is
      Native   : constant B.Byte_Count := Native_Bytes (Format);
      Panelled : constant B.Byte_Count := Block_Bytes (Format);

      Row_Span : constant B.Byte_Count := B.Byte_Count (Blocks) * Native;

      Panel : constant Element_Count := Row / Panel_Rows;
      Lane  : constant B.Byte_Count := B.Byte_Count (Row mod Panel_Rows);

      Panel_In : constant B.Byte_Count :=
        From + B.Byte_Count (Panel) * B.Byte_Count (Blocks) * Panelled;
   begin
      Ok := False;
      Target := [others => 0];

      if Blocks = 0
        or else Native = 0
        or else Target'Length < Row_Span
        or else not B.Has_Room
                      (Source, Panel_In, B.Byte_Count (Blocks) * Panelled)
      then
         return;
      end if;

      for Block in Element_Count range 0 .. Blocks - 1 loop
         declare
            In_At : constant B.Byte_Index :=
              Source'First + Panel_In + B.Byte_Count (Block) * Panelled;
            Out_At : constant B.Byte_Index :=
              Target'First + B.Byte_Count (Block) * Native;
         begin
            if Format = G.Type_Q6_K then
               Take_Six (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_Q4_0 then
               Take_Legacy (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_Q4_1 then
               Take_Least (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_Q5_0 or else Format = G.Type_Q5_1 then
               Take_Fifth (Source, In_At, Target, Out_At, Lane,
                           Least => Format = G.Type_Q5_1);
            elsif Format = G.Type_Q2_K then
               Take_Two (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_Q3_K then
               Take_Three (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_IQ4_NL then
               Take_Legacy (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_IQ4_XS then
               Take_Level (Source, In_At, Target, Out_At, Lane);
            elsif Format = G.Type_MXFP4 then
               Take_Micro (Source, In_At, Target, Out_At, Lane);
            else
               Take_Four (Source, In_At, Target, Out_At, Lane,
                          Fifth => Format = G.Type_Q5_K);
            end if;
         end;
      end loop;

      Ok := True;
   end Extract_Row;

end Model_Runner.Quantization.Interleave;
