with Interfaces;

package body Model_Runner.Quantization.Interleave is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;

   use type B.Byte_Count;
   use type G.Tensor_Type;
   use type Interfaces.Unsigned_8;

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
         or else Format = G.Type_Q4_0)
        and then Rows > 0
        and then Rows mod Panel_Rows = 0
        and then Columns > 0)
       and then

       --  A whole number of the format's own blocks, which is a super-block
       --  for the three k-quants and thirty-two elements for the legacy one.
       (if Format = G.Type_Q4_0
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
            else
               Take_Four (Source, In_At, Target, Out_At, Lane,
                          Fifth => Format = G.Type_Q5_K);
            end if;
         end;
      end loop;

      Ok := True;
   end Extract_Row;

end Model_Runner.Quantization.Interleave;
