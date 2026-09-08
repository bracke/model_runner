with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  Quantized weights, eight rows interleaved.
--
--  What this is for. A row product reads one row's blocks and reduces the
--  eight partial sums the byte dot product leaves; every row pays that
--  reduction, and a strip of vectors pays a pass over the weights for every
--  four of them. Interleaving eight rows turns both around: a lane of the
--  accumulator becomes a row rather than a quarter of one, so nothing is
--  reduced horizontally at all, and the eight accumulators a strip can hold
--  cover eight vectors instead of four -- half the passes over the weights
--  for the same answer.
--
--  It buys that with a copy. The quants are the file's own quants in another
--  order and the scales are the file's own scales taken out of the six-bit
--  fields they were packed into, so the values a kernel forms are the values
--  the file describes and nothing here is lossy. What it costs is a second
--  copy of every matrix it is applied to, a fiftieth larger than the first,
--  which is why it is asked for rather than done -- Model_Runner.Llama's
--  To_Rows is the request.
--
--  This is what llama.cpp calls `block_q4_Kx8` and `block_q4_0x8` and builds
--  at load with `ggml_repack_q4_K_to_q4_K_8_bl` and its legacy counterpart;
--  the layouts below are not its layouts, because the instruction this
--  engine's kernel uses is not the instruction its kernel uses. What the two
--  share is the idea and the eight.
--
--  Twelve formats are written here: the three k-quants a "_M" file is made
--  of, the four legacy ones, the two- and three-bit k-quants, the two
--  non-linear formats, and the block-exponent one. That is every quantized
--  format the engine multiplies except Q8_0, which is left out on purpose
--  -- it is already level with llama.cpp and has no correction to carry. The
--  legacy layouts are described before the last two because they are the
--  four-bit k-quant's with everything it packs taken away -- and, for the
--  two that carry a fifth bit, with one thing added that no k-quant has.
--
--  The four-bit layout. A panel is eight consecutive rows. For each
--  super-block of the panel, 1184 bytes -- the eight rows' 144 each,
--  rearranged, and thirty-two more:
--
--     0 ..  15   the eight rows' block scales, half precision, in order
--    16 ..  31   the eight rows' block minima, likewise
--    32 ..  95   the sub-block scales, a byte each, sub-block major
--    96 .. 159   the sub-block minima, the same way
--   160 .. 1183  the eight rows' quants, interleaved
--
--  The quants are interleaved so that a thirty-two byte load holds four
--  consecutive elements of each of the eight rows: byte 4*L + M of the group
--  is row L's element M of the four. Masking the low nibbles gives one
--  sub-block's four, shifting and masking gives the paired sub-block's, and
--  a byte dot product against the four activations broadcast as one word
--  puts row L's contribution in lane L. That is the whole of why the order
--  is this order.
--
--  And the sub-block scales are unpacked here rather than in the kernel,
--  which is the thirty-two bytes. A file keeps eight six-bit scales and
--  eight six-bit minima in twelve bytes; taking them out is about
--  twenty-five instructions a row, and a panel wants them a lane a row,
--  which is a transpose on top. Done in the kernel that cost two and a half
--  times what the kernel itself cost for a generated token, where there is
--  one vector to amortize it over. Done here it is paid once at load. A
--  byte apiece is sixty-four for each of the two against the ninety-six they
--  were packed into, and the panel block grows by the difference.
--
--  The six-bit layout, which a "_M" file needs because it is a mixture: its
--  output projection and about half its feed-forward are Q6_K, and with the
--  four-bit path in panels a profile put that format at a quarter of a
--  prompt. For each super-block of a panel, 1680 bytes -- the eight rows'
--  210 each and not one more, because this format's sub-block scales are
--  already whole bytes:
--
--     0 ..   15   the eight rows' block scales, half precision
--    16 ..  143   the sixteen sub-block scales, signed bytes, sub-block major
--   144 .. 1167   the low four bits of every quant, interleaved
--  1168 .. 1679   the high two bits, interleaved
--
--  The low bits are paired as the four-bit format pairs its two sub-blocks:
--  group P of four consecutive elements in the low nibbles and group P + 32
--  in the high ones. The high two bits cannot be paired the same way -- a
--  byte holds four elements' worth of them rather than two -- so one
--  thirty-two byte load of them serves four groups at four different shifts:
--  bits 0-1 for group C, 2-3 for C + 16, 4-5 for C + 32 and 6-7 for C + 48.
--  Which is why the kernel reads the same high-bit group twice, once with a
--  shift of nought and four and once with two and six.
--
--  Task safety: pure functions on caller-supplied buffers, no state.
package Model_Runner.Quantization.Interleave is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  Rows one panel holds.
   --
   --  Eight, because the byte dot product leaves eight lanes and a lane is
   --  what a row becomes. It is not a tunable: four would waste half of
   --  every accumulator and sixteen has no register to be.
   Panel_Rows : constant := 8;

   --  Bytes one panel's block occupies, in each of the four layouts.
   Panel_Block_Bytes : constant := 1184;
   Five_Block_Bytes  : constant := 1440;
   Six_Block_Bytes   : constant := 1680;
   Legacy_Block_Bytes : constant := 144;
   Least_Block_Bytes  : constant := 160;
   Fifth_Block_Bytes  : constant := 176;
   Fifth_Least_Block_Bytes : constant := 192;
   Two_Block_Bytes   : constant := 800;
   Three_Block_Bytes : constant := 912;
   Level_Block_Bytes : constant := 1104;
   Micro_Block_Bytes : constant := 160;

   --  Where the five parts of a four-bit panel block begin.
   Panel_Scale_At   : constant := 0;
   Panel_Least_At   : constant := 16;
   Panel_Factor_At  : constant := 32;
   Panel_Minimum_At : constant := 96;
   Panel_Quants_At  : constant := 160;

   --  The five-bit layout is the four-bit one with a run of fifth bits
   --  after the quants, and its first five parts are at the same places:
   --
   --  1184 .. 1439  the fifth bit of every quant, interleaved
   --
   --  The fifth bits are a bit an element where the low four are a nibble,
   --  so one thirty-two byte load of them serves all four pairs at four
   --  shifts -- bit 2*J for a pair's low sub-block and 2*J + 1 for its
   --  high one -- which is why the kernel reads the same group of them four
   --  times over.
   Five_High_At : constant := 1184;

   --  And the four parts of a six-bit one.
   Six_Scale_At  : constant := 0;
   Six_Factor_At : constant := 16;
   Six_Low_At    : constant := 144;
   Six_High_At   : constant := 1168;

   --  The legacy four-bit layout, which is the smallest of the four and the
   --  only one whose block is not a super-block: thirty-two elements behind
   --  one half-precision scale, no minimum and no sub-blocks. A panel block
   --  is 144 bytes, the eight rows' eighteen each and not one more, because
   --  there is nothing packed here to take out:
   --
   --     0 ..  15   the eight rows' block scales, half precision, in order
   --    16 .. 143   the eight rows' quants, interleaved
   --
   --  The quants are grouped as the k-quant's are -- byte 4L + M of a
   --  thirty-two byte group is row L's element M of the four -- with the
   --  pairing this format's own nibble gives: group C holds elements 4C to
   --  4C + 3 in its low nibbles and 4C + 16 to 4C + 19 in its high ones,
   --  four groups to a block. So the kernel's inner loop is the k-quant's
   --  with a quarter of the trips.
   Legacy_Scale_At  : constant := 0;
   Legacy_Quants_At : constant := 16;

   --  And the legacy four-bit format that keeps a minimum instead of a
   --  centring, which is the same block with a second half-precision number
   --  in it and sixteen more bytes to a panel:
   --
   --     0 ..  15   the eight rows' block scales, half precision
   --    16 ..  31   the eight rows' block minima, likewise
   --    32 .. 159   the eight rows' quants, interleaved
   --
   --  The quants are grouped exactly as the format above groups them,
   --  because the two pack their nibbles the same way. What differs is what
   --  a nibble means: there it is itself less eight, here it is itself, and
   --  the minimum is added to the row's whole block rather than taken off
   --  every quant.
   Least_Scale_At  : constant := 0;
   Least_Least_At  : constant := 16;
   Least_Quants_At : constant := 32;

   --  And the two that carry a fifth bit. These are the two formats the
   --  row product has always been slowest at, and the reason is where the
   --  file keeps that bit: bit J of a thirty-two bit word, so the shift
   --  that extracts it varies with the element and the loop will not
   --  vectorize. A panel puts an end to that, because the shift can be
   --  decided when the panel is written rather than when it is read.
   --
   --  The five-bit centred format, 176 bytes -- the eight rows'
   --  twenty-two each, and not one more:
   --
   --     0 ..  15   the eight rows' block scales, half precision
   --    16 .. 143   the eight rows' low four bits, interleaved
   --   144 .. 175   the eight rows' fifth bits, interleaved
   --
   --  The fifth bits are packed so that ONE thirty-two byte load serves the
   --  whole block at four pairs of shifts. Byte 4L + M of the run holds row
   --  L's fifth bits for the eight elements that share position M: bit 2C
   --  belongs to element 4C + M and bit 2C + 1 to element 4C + M + 16,
   --  which are exactly the two elements group C's byte 4L + M carries the
   --  low nibbles of. So a group's turn is a shift that brings its bit to
   --  position four and one three-input logical operation that folds it
   --  into the nibble -- and the shift is an immediate, because the group
   --  is unrolled.
   Fifth_Scale_At  : constant := 0;
   Fifth_Quants_At : constant := 16;
   Fifth_Fifths_At : constant := 144;

   --  And the five-bit format that keeps a minimum, 192 bytes, which is
   --  the one above with sixteen more:
   --
   --     0 ..  15   the eight rows' block scales, half precision
   --    16 ..  31   the eight rows' block minima, likewise
   --    32 .. 159   the eight rows' low four bits, interleaved
   --   160 .. 191   the eight rows' fifth bits, interleaved
   Fifth_Least_Scale_At   : constant := 0;
   Fifth_Least_Minimum_At : constant := 16;
   Fifth_Least_Quants_At  : constant := 32;
   Fifth_Least_Fifths_At  : constant := 160;

   --  The two-bit k-quant, which is what a "Q2_K" file is made of. A
   --  super-block of 256 keeps sixteen sub-blocks of sixteen, and every one
   --  of them carries both a scale and a minimum in four bits -- so this
   --  format has twice the sub-blocks of the four-bit k-quant and half the
   --  bits in a quant, and the panel is arranged for the first of those
   --  rather than the second.
   --
   --  800 bytes, which is the first layout here that grows: the eight rows'
   --  84 each is 672, and the difference is the sixteen scales and sixteen
   --  minima taken out of their nibbles and written a byte apiece.
   --
   --     0 ..  15   the eight rows' block scales, half precision
   --    16 ..  31   the eight rows' block minima, likewise
   --    32 .. 159   the sixteen sub-block scales, a byte each, sub-block
   --                major
   --   160 .. 287   the sixteen sub-block minima, the same way
   --   288 .. 799   the quants, interleaved
   --
   --  A quant is two bits, so a byte holds four of them and one thirty-two
   --  byte group covers SIXTEEN elements a row rather than eight. Byte
   --  4L + M of group G holds row L's elements 16G + M, 16G + 4 + M,
   --  16G + 8 + M and 16G + 12 + M, at bits 0-1, 2-3, 4-5 and 6-7 --
   --  so one load and four shifts give the group's four runs of four
   --  consecutive elements, which is what the byte dot product wants. And a
   --  group is exactly a sub-block, which is why the scales above are
   --  sub-block major: the kernel widens eight rows' scale for one group
   --  out of eight consecutive bytes.
   Two_Scale_At   : constant := 0;
   Two_Least_At   : constant := 16;
   Two_Factor_At  : constant := 32;
   Two_Minimum_At : constant := 160;
   Two_Quants_At  : constant := 288;

   --  And the three-bit k-quant. Sixteen sub-blocks again, a six-bit signed
   --  scale each and no minimum, with the quant's third bit in a run of its
   --  own exactly as the five-bit legacy formats keep their fifth.
   --
   --  912 bytes against the eight rows' 110, which is 880: the difference
   --  is the sixteen packed six-bit scales written a byte apiece.
   --
   --     0 ..  15   the eight rows' block scales, half precision
   --    16 .. 143   the sixteen sub-block scales, a signed byte each,
   --                sub-block major
   --   144 .. 655   the low two bits, interleaved, as the two-bit format
   --                interleaves its whole quant
   --   656 .. 911   the high bits, interleaved
   --
   --  The high bits are packed two groups to a run, because a group needs
   --  only four of them a byte: byte 4L + M of run R holds row L's high bit
   --  for element 32R + 4S + M at bit S and for element 32R + 16 + 4S + M
   --  at bit 4 + S, S running nought to three. So one load of a run serves
   --  two groups at four shifts each, and the shift is an immediate.
   Three_Scale_At  : constant := 0;
   Three_Factor_At : constant := 16;
   Three_Low_At    : constant := 144;
   Three_High_At   : constant := 656;

   --  The two non-linear formats, whose nibble is not a number but an index
   --  into a table of sixteen levels that belongs to the format. NOTHING
   --  ABOUT THAT REACHES THE LAYOUT: the panel keeps the nibbles, and the
   --  kernel turns an index into a level with one `vpshufb` against a
   --  register holding the table twice. A byte table lookup is a single
   --  instruction on this part, which is why storing the levels themselves
   --  -- a byte an element, twice the room -- would be the wrong trade.
   --
   --  IQ4_NL's block is Q4_0's in every respect the layout cares about,
   --  thirty-two elements behind one half-precision scale with element J in
   --  the low nibble of byte J and element J + 16 in the high one, so it
   --  takes the same 144-byte panel and the same permutation. Only the
   --  kernel differs.
   --
   --  IQ4_XS is that block eight times over with a six-bit scale apiece,
   --  1104 bytes against the eight rows' 136 each:
   --
   --     0 ..   15   the eight rows' block scales, half precision
   --    16 ..   79   the eight sub-block scales, a signed byte each,
   --                 sub-block major
   --    80 .. 1103   the quants, interleaved -- four groups to a sub-block,
   --                 paired as Q4_0 pairs its two halves
   Level_Scale_At  : constant := 0;
   Level_Factor_At : constant := 16;
   Level_Quants_At : constant := 80;

   --  And the block-exponent format, whose nibbles are IQ4_NL's and whose
   --  scale is not a half at all. It is an E8M0 exponent -- one byte, two
   --  to that byte less a hundred and twenty-eight -- and the range of that
   --  runs from two to the minus hundred and twenty-eight to two to the
   --  hundred and twenty-seventh, which a half cannot hold at either end.
   --  So this is the one panel here whose scales are binary32:
   --
   --     0 ..  31   the eight rows' block scales, binary32
   --    32 .. 159   the eight rows' quants, interleaved
   --
   --  160 bytes against the eight rows' seventeen each, which is the only
   --  thing this format's panel costs that IQ4_NL's does not -- and the
   --  kernel is one instruction shorter for it, loading eight floats where
   --  the others widen eight halves.
   Micro_Scale_At  : constant := 0;
   Micro_Quants_At : constant := 32;

   --  Bytes a panel block occupies in the layout this format takes.
   --
   --  @param Format Weight format; one Interleaves accepts.
   --  @return Bytes one panel's super-block occupies, or zero.
   function Block_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type)
      return Model_Runner.Bytes.Byte_Count;

   --  What one row's super-block occupies in it, which is a panel block
   --  divided by the eight rows it holds.
   --
   --  @param Format Weight format; one Interleaves accepts.
   --  @return Bytes a row's super-block occupies, or zero.
   function Panel_Row_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type)
      return Model_Runner.Bytes.Byte_Count;

   --  What a matrix in this layout occupies.
   --
   --  @param Format Weight format; one Interleaves accepts.
   --  @param Rows Rows the matrix holds; a multiple of Panel_Rows.
   --  @param Blocks Super-blocks in one row.
   --  @return Bytes the panels take altogether.
   function Panel_Bytes
     (Format : Model_Runner.GGUF.Tensor_Type;
      Rows   : Element_Count;
      Blocks : Element_Count)
      return Model_Runner.Bytes.Byte_Count;

   --  Whether a matrix in this format and shape can be interleaved.
   --
   --  Every format the panel kernels read: the three k-quants a "_M" file
   --  is made of, the four legacy ones, the two- and three-bit k-quants,
   --  the two non-linear formats and the block-exponent one. A row count that is not a whole
   --  number of panels is refused rather than padded, because a padded panel
   --  is rows that do not exist and a kernel that has to know which they
   --  are.
   --
   --  @param Format Weight format as the file holds it.
   --  @param Rows Rows the matrix holds.
   --  @param Columns Elements in one row.
   --  @return True when Build below will write this matrix.
   function Interleaves
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count) return Boolean;

   --  Rewrite one matrix into the panel layout.
   --
   --  Source and Target may not overlap. Interleaves has already said the
   --  shape divides, and Panel_Bytes says how much room Target needs.
   --
   --  @param Format Weight format; one Interleaves accepts.
   --  @param Source Buffer holding the matrix as the file stores it.
   --  @param From Byte position of the matrix's first row within Source.
   --  @param Target Buffer to write the panels into.
   --  @param Into Byte position to write the first panel at.
   --  @param Rows Rows the matrix holds; a multiple of Panel_Rows.
   --  @param Blocks Super-blocks in one row.
   --  @param Ok True when every byte read and written lay inside its buffer.
   procedure Build
     (Format : Model_Runner.GGUF.Tensor_Type;
      Source : Model_Runner.Bytes.Byte_Array;
      From   : Model_Runner.Bytes.Byte_Count;
      Target : in out Model_Runner.Bytes.Byte_Array;
      Into   : Model_Runner.Bytes.Byte_Count;
      Rows   : Element_Count;
      Blocks : Element_Count;
      Ok     : out Boolean);

   --  Put one row back the way the file had it.
   --
   --  For the readers that want a row rather than a product -- decoding a
   --  row for a test, or the floating-point path a kernel refusal falls back
   --  to. It is the inverse of Build for that row and nothing faster: a row
   --  taken out of a panel is a gather, which is what interleaving moved the
   --  cost of the product away from.
   --
   --  @param Format Weight format; one Interleaves accepts.
   --  @param Source Buffer holding the panels.
   --  @param From Byte position of the matrix's first panel.
   --  @param Row Row wanted, counted from the matrix's first.
   --  @param Blocks Super-blocks in one row.
   --  @param Target Buffer to write the row's blocks into, indexed from its
   --    own first; it holds one block of the format for each of Blocks.
   --  @param Ok True when every byte read and written lay inside its buffer.
   procedure Extract_Row
     (Format : Model_Runner.GGUF.Tensor_Type;
      Source : Model_Runner.Bytes.Byte_Array;
      From   : Model_Runner.Bytes.Byte_Count;
      Row    : Element_Count;
      Blocks : Element_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean);

end Model_Runner.Quantization.Interleave;
