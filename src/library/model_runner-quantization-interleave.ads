with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  The four-bit k-quant's weights, eight rows interleaved.
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
--  This is what llama.cpp calls `block_q4_Kx8` and builds at load with
--  `ggml_repack_q4_K_to_q4_K_8_bl`; the layout below is not its layout,
--  because the instruction this engine's kernel uses is not the instruction
--  its kernel uses. What the two share is the idea and the eight.
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

   --  Bytes one panel's super-block occupies, in each of the three layouts.
   Panel_Block_Bytes : constant := 1184;
   Five_Block_Bytes  : constant := 1440;
   Six_Block_Bytes   : constant := 1680;

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
   --  The three k-quants a "_M" file is made of. A row count that is not a
   --  whole number of panels is refused rather than padded, because a padded
   --  panel is rows that do not exist and a kernel that has to know which
   --  they are.
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
