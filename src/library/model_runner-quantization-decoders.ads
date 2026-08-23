--  One block of one format, decoded into floats.
--
--  This is the arithmetic of every quantized format the program reads, and
--  it is a generic for one reason: so that the same source can be compiled
--  twice, once for the instruction set every x86-64 has and once for a wider
--  one, and the faster of the two chosen per format at load.
--
--  Four formats want the wider instruction set and the other eleven are
--  slower for it. Q5_0 and Q5_1 keep the fifth bit of each element at a
--  varying place in a thirty-two bit word, so the shift amount varies with
--  the element; IQ4_NL and IQ4_XS index a table of sixteen levels, which is
--  a gather. Neither vectorizes on baseline x86-64 and both do where there
--  are per-lane shifts and gathers. Measured on this repository's own
--  benchmark, alternating the two builds on a quiet machine, medians of
--  three: IQ4_NL 1.36 ns an element against 0.75, Q5_0 1.02 against 0.64,
--  Q5_1 1.06 against 0.68, IQ4_XS 0.90 against 0.68. Every other format
--  loses between seven and forty-two per cent, which is why this is a
--  per-format choice and not a build switch -- and why the accumulation
--  that follows the decode is not in here: it is shared by every format and
--  is the part the wider build makes worse.
--
--  A generic rather than a second copy of the four decoders, because a
--  format with two implementations has one nobody tests. This repository
--  learnt that once already, from an error injected into the unused copy of
--  a decoder that went unnoticed.
--
--  Task safety: a call holds no state.
private generic
package Model_Runner.Quantization.Decoders is

   --  Decode one block.
   --
   --  @param Format Block format.
   --  @param Data Bytes holding the block.
   --  @param Offset Where the block begins, checked by the caller.
   --  @param Target Receives this format's block elements.
   --  @param Ok True when the format is one this decodes and the block fits.
   procedure Decode_One
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Numerics.Real_Array;
      Ok     : out Boolean);

   --  Decode a run of blocks, straight into the destination.
   --
   --  The loop lives in here rather than in the caller so that a span costs
   --  one call across the unit boundary instead of one per block. Which
   --  matters only for the formats whose blocks are narrow: a k-quant spreads
   --  a call over 256 elements, and Q4_1 -- which has 32 and gains nothing
   --  from the wider instructions -- was eleven per cent slower when the
   --  loop was outside and the call was per block. Measured, not supposed.
   --
   --  @param Format Block format.
   --  @param Data Bytes holding the blocks.
   --  @param Offset Where the first block begins, checked by the caller.
   --  @param Count Blocks to decode.
   --  @param Width Bytes a block takes.
   --  @param Per Elements a block holds.
   --  @param Target Receives Count * Per elements from its first index.
   --  @param Ok True when every block decoded.
   procedure Decode_Span
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Count  : Element_Count;
      Width  : Model_Runner.Bytes.Byte_Count;
      Per    : Element_Count;
      Target : out Model_Runner.Numerics.Real_Array;
      Ok     : out Boolean);

end Model_Runner.Quantization.Decoders;
