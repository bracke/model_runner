with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  Reference decoders for the supported quantized block formats.
--
--  Every format has one decoder here, written from the block layout and
--  nothing else. Decode_Blocks unpacks the four simple layouts inline and
--  delegates the k-quants to a per-block routine; Decode_Block is that same
--  code with a count of one. It has not always been so: four formats had a
--  second copy that nothing called, so nothing tested it, and an error
--  planted in one went unnoticed.
--
--  Golden vectors check what the decoders produce, against expectations
--  derived by hand from the layouts above rather than from the code.
--
--  Accumulate_Dot reads two of those layouts a second time, to multiply
--  without decoding first. That is a deliberate exception to one-reader-per
--  -format and it costs something: a layout could be right in the decoder and
--  wrong in the kernel. It is paid for by a test that checks the two against
--  each other for every format on values chosen to exercise the whole range,
--  so a divergence fails the suite rather than quietly changing a model's
--  output.
--
--  Advertised formats. F32, F16, Q4_0, Q8_0, Q4_K, Q5_K and Q6_K are decoded
--  here. Model_Runner.GGUF.Is_Supported names the same set; a format that is
--  merely recognized by the parser is rejected before preparation.
--
--  Block layouts, in serialized byte order:
--
--     Q4_0  32 elements, 18 bytes: half d, then 16 packed nibbles. Element j
--           uses the low nibble of byte j and element j+16 the high nibble.
--     Q8_0  32 elements, 34 bytes: half d, then 32 signed bytes.
--     Q4_K 256 elements, 144 bytes: half d, half dmin, 12 packed six-bit
--           scale/min pairs, then 128 packed nibbles in eight sub-blocks.
--     Q5_K 256 elements, 176 bytes: as Q4_K plus 32 bytes carrying the fifth
--           bit of each quant.
--     Q6_K 256 elements, 210 bytes: 128 low-nibble bytes, 64 bytes of the two
--           high bits, 16 signed sub-block scales, then half d.
--
--  Task safety: all operations are pure functions of their arguments.
package Model_Runner.Quantization is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   use type Model_Runner.Numerics.Element_Count;

   --  Largest number of elements any supported block holds. A decoded block
   --  fits in a buffer of this size, which is what lets the row operations
   --  work without allocating.
   Max_Block_Elements : constant := 256;

   subtype Block_Buffer is Real_Array (0 .. Max_Block_Elements - 1);

   --  Decode one block.
   --
   --  @param Format Block format.
   --  @param Data Buffer holding the block.
   --  @param Offset Byte position of the block's first byte.
   --  @param Target Decoded values; only the first Block_Elements are written.
   --  @param Ok True when the block lay wholly inside Data and the format is
   --    one this package decodes.
   procedure Decode_Block
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Block_Buffer;
      Ok     : out Boolean);

   --  Decode a run of consecutive blocks.
   --
   --  This is the form the kernels use. Deciding the format once for a whole
   --  span rather than once per block is what makes the difference: a Q8_0
   --  block is only thirty-two elements, so a per-block decision and call cost
   --  more than the arithmetic they guard. A format that packs more elements
   --  into a block was measurably faster per element for exactly that reason.
   --
   --  The layout knowledge still lives in one place per format. Decode_Block
   --  is this operation with a count of one, so the golden vectors that check
   --  a single block check the same code the kernels run.
   --
   --  @param Format Block format.
   --  @param Data Buffer holding the blocks.
   --  @param Offset Byte position of the first block's first byte.
   --  @param Count Number of consecutive blocks to decode.
   --  @param Target Decoded values, Count * Block_Elements of them, written
   --    from Target'First. Zeroed when Ok is False, so that a caller which
   --    ignores Ok reads zeros rather than whatever it left there.
   --  @param Ok True when Count is not zero, every block lay wholly inside
   --    Data, the format is one this package decodes, and Target had room.
   procedure Decode_Blocks
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Count  : Element_Count;
      Target : out Real_Array;
      Ok     : out Boolean);

   --  Accumulate the dot product of a span of blocks with one or more
   --  vectors, reading the packed bytes directly.
   --
   --  Nothing is written out: the multiply is folded into the decode, so no
   --  dequantized copy of the weights exists even briefly. For the formats
   --  whose block carries a single scale this also removes work rather than
   --  just a buffer. A Q8_0 value is its scale times a small integer, so the
   --  sum over a block is the scale times the sum of integer times input --
   --  one multiply by the scale for each block instead of one for each of its
   --  thirty-two elements, and one rounding fewer per element.
   --
   --  No format is decoded that way any more. Q4_0 was the last, and folding
   --  the multiply into its decode measured 1.79 times slower than decoding a
   --  span and multiplying it: 1746 against 3128 million elements a second,
   --  alternating. Fusing breaks the sum at every block so the scale can be
   --  applied there, and that costs the flat inner loop more than the saved
   --  multiply is worth. Every format now takes one path, and the rounding
   --  every other format already had is what Q4_0 has too.
   --
   --  Each vector is accumulated independently, so a span shared between
   --  several vectors gives each one the value it would have had alone. The
   --  packed bytes are read once for all of them, which is what lets a batch
   --  share the work without changing the answer.
   --
   --  @param Format Block format.
   --  @param Data Buffer holding the blocks.
   --  @param Offset Byte position of the first block.
   --  @param Blocks Number of consecutive blocks in the span.
   --  @param Vectors Buffer holding the input vectors.
   --  @param First Index in Vectors of the first element of vector zero that
   --    lines up with the first element of this span.
   --  @param Stride Distance in Vectors from one vector to the next.
   --  @param Count Number of vectors.
   --  @param Sums Accumulators, Count of them from Sums'First, added to.
   --    Left as they were when Ok is False: a refused call adds nothing
   --    rather than part of a span.
   --  @param Ok True when Blocks and Count are not zero, the span lay wholly
   --    inside Data, every element the call would read lay inside Vectors,
   --    Sums held Count accumulators, and the format is one this package
   --    decodes. The bounds are established here because the loops below run
   --    with the runtime checks suppressed.
   procedure Accumulate_Dot
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Data    : Model_Runner.Bytes.Byte_Array;
      Offset  : Model_Runner.Bytes.Byte_Count;
      Blocks  : Element_Count;
      Vectors : Real_Array;
      First   : Element_Count;
      Stride  : Element_Count;
      Count   : Element_Count;
      Sums    : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok      : out Boolean);


   --  Report whether this package decodes a format.
   --
   --  @param Format Format to test.
   --  @return True when Decode_Block implements it.
   function Is_Decodable
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean;

end Model_Runner.Quantization;
