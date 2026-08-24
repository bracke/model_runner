--  One integer product, compiled more than once.
--
--  The body here is the whole of what a quantized weight and a quantized
--  activation cost, and it is a generic for one reason: so that the same
--  source can be built twice, once for the instruction set every x86-64 has
--  and once for a wider one, and the host asked at run time which of them it
--  may enter. That is the shape Model_Runner.Quantization.Decoders already
--  has and for the same reason -- a format with two implementations has one
--  nobody tests, so there is one source and two compilations of it.
--
--  What the wider set buys here is measured rather than assumed: the
--  110-token prompt reads 1.476 s at the baseline and 1.297 s at
--  x86-64-v3, and sixty-four generated tokens 2.672 s against 2.402 s.
--  Building for x86-64-v4 as well reads 1.308 s and 2.366 s, which is level
--  with v3 and excludes far more hardware, so v3 is what is built.
--
--  The instantiations are compiled with floating-point contraction turned
--  off, so a fused multiply-add cannot round once where the other rounds
--  twice, and the two answer bit for bit. A test asserts exactly that.
--
--  Task safety: pure functions on caller-supplied buffers, no state.
private generic
package Model_Runner.Quantization.Integers.Kernels is

   --  The product of a span of weight blocks with quantized activations,
   --  over several consecutive rows at once.
   --
   --  This is Model_Runner.Quantization.Integers.Accumulate_Rows and
   --  nothing else; what each parameter means is written out there once,
   --  and repeated here only as far as the tags require.
   --
   --  @param Format Weight format; one Has_Integer_Kernel answers True for.
   --  @param Data Buffer holding the weight blocks.
   --  @param Offset Byte position of the first row's first block.
   --  @param Row_Bytes Distance in bytes from one row to the next.
   --  @param Rows Rows to compute, at most Row_Tile.
   --  @param Blocks Blocks in one row.
   --  @param Values Quantized activations, as Quantize_Vectors wrote them.
   --  @param Scales Activation scales, one per block of Values.
   --  @param Totals Activation block sums, one per block of Values.
   --  @param First Index in Values of the first element of vector zero.
   --  @param Stride Distance in Values from one vector to the next.
   --  @param Count Number of vectors.
   --  @param Sums Rows * Count accumulators, row major, added to.
   --  @param Ok True when every range the call reads lay inside what it was
   --    given, which is proved once before the loops suppress their checks.
   procedure Rows
     (Format    : Model_Runner.GGUF.Tensor_Type;
      Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean);

end Model_Runner.Quantization.Integers.Kernels;
