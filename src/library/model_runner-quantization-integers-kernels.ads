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
--  Wider says which instruction set this compilation may name, which here
--  decides which of two machine code insertions the block product goes
--  through. It is a static constant in each instantiation, so the branch on
--  it is folded and neither build carries the other's instructions.
--
--  What the insertions buy is not the multiply-add, which the compiler
--  already finds on its own: it is the horizontal reduction around it. A
--  block product reduced to a scalar at every block is about seven
--  instructions of shuffling and adding for three of arithmetic, and an
--  ablation puts the whole multiply-add step at 39 per cent of a prompt
--  while it issues at about a fifth of the rate this part can. Keeping the
--  eight partial sums the instruction leaves and reducing once a row
--  instead is what they are for.
--
--  Both leave the same four sums, and that is a requirement rather than a
--  coincidence. The wide one takes sixteen elements at a time and folds the
--  block's two halves and then the register's; the baseline one takes eight
--  and adds all four quarters. Either way a sum holds the same four of the
--  block's sixteen pairs, and the floating-point work after that is
--  elementwise, so the two produce identical bits -- which is what lets the
--  answer stay a property of the model rather than of the host that ran it.
--  A test asserts the equality.
--  Deep says this compilation may reach the byte dot product, which is an
--  AVX-512 instruction and so a strictly narrower promise than Wider: every
--  host that has it has the wide lanes too, and the instantiation carrying
--  it is built for x86-64-v4.
--
--  It is a separate arithmetic rather than a faster spelling of the same
--  one. The byte instruction is unsigned against signed, so the weight byte
--  is biased into range and the bias taken back out with the activation
--  block's own sum -- which the Totals table already carries. What comes out
--  agrees with the other two to the bound the conformance sweep states and
--  not bit for bit, which is a change from what those two promise each
--  other and is written up beside the tolerance.
private generic
   Wider : Boolean := False;
   Deep  : Boolean := False;
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
   --  @param Halves Activation sums, one for every sixteen elements of
   --    Values, which the six-bit k-quant's kernels want.
   --  @param First Index in Values of the first element of vector zero.
   --  @param Stride Distance in Values from one vector to the next.
   --  @param Count Number of vectors.
   --  @param Sums Rows * Count accumulators, row major, added to.
   --  @param Ok True when every range the call reads lay inside what it was
   --    given, which is proved once before the loops suppress their checks.
   --  @param Interleaved Whether Data holds the weights a panel of rows at
   --    a time. Only the four-bit k-quant is ever written that way, and
   --    only by the pass that was asked to; every other format and every
   --    model read as its file stores it leaves this False and reaches the
   --    same kernels it always did.
   --  @param Reference_Arithmetic Retain reference binary32 lanes in the deep compilation.
   --  @param Metadata Optional immutable native header scales.
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
      Halves    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean;
      Interleaved : Boolean := False;
      Reference_Arithmetic : Boolean := False;
      Metadata : Model_Runner.Numerics.Real_Array := []);

   --  A block of an activation, packed: its own scale, its thirty-two
   --  bytes and the two sums a k-quant's minimum term wants.
   --
   --  Multiply by the inverse of that scale, round to nearest with ties
   --  away from zero, clamp to the byte the dot product can negate, store
   --  thirty-two of them, and give back the sum of the first sixteen and
   --  the sum of all of them.
   --
   --  These two are here rather than beside their caller because only this
   --  unit is built for the instruction set they want, and because a static
   --  formal is the only thing that lets one source carry both the
   --  insertion and the loop without the baseline compilation naming a
   --  register it has not got.
   --
   --  @param Vectors Activations to read.
   --  @param At_It First element of the block, from Vectors'First.
   --  @param Values Receives thirty-two bytes from At_Out.
   --  @param At_Out First byte of the block, from Values'First.
   --  @param Scale The block's largest magnitude over a hundred and
   --    twenty-seven, or zero where nothing was finite.
   --  @param Earlier Sum of the first sixteen.
   --  @param Total Sum of all thirty-two.
   --  @param Finite False where the block holds an infinity or a NaN, in
   --    which case nothing else it reports means anything.
   procedure Block_Pack
     (Vectors : Model_Runner.Numerics.Real_Array;
      At_It   : Element_Count;
      Values  : in out Signed_Array;
      At_Out  : Element_Count;
      Scale   : out Model_Runner.Numerics.Real;
      Earlier : out Interfaces.Integer_32;
      Total   : out Interfaces.Integer_32;
      Finite  : out Boolean);

   --  The same block against a scale somebody else found.
   --
   --  What a k-quant's activation wants: its scale spans eight blocks, so
   --  the extent is taken over all of them and each block is only rounded.
   --  Nothing else differs, and the two share the whole of their
   --  arithmetic.
   --
   --  @param Vectors Activations to read.
   --  @param At_It First element of the block, from Vectors'First.
   --  @param Inverse One over the scale, or zero for a block of zeros.
   --  @param Values Receives thirty-two bytes from At_Out.
   --  @param At_Out First byte of the block, from Values'First.
   --  @param Earlier Sum of the first sixteen.
   --  @param Total Sum of all thirty-two.
   procedure Block_Round
     (Vectors : Model_Runner.Numerics.Real_Array;
      At_It   : Element_Count;
      Inverse : Model_Runner.Numerics.Real;
      Values  : in out Signed_Array;
      At_Out  : Element_Count;
      Earlier : out Interfaces.Integer_32;
      Total   : out Interfaces.Integer_32);

   --  Sums of a super-block's eight blocks: block B's first sixteen at 2B,
   --  all thirty-two at 2B + 1.
   type Block_Sums is array (0 .. 15) of Interfaces.Integer_32;

   --  The largest magnitude in a super-block of 256, and whether all of it
   --  is finite: the eight blocks' Block_Extent in one pass.
   --
   --  @param Vectors Activations to read.
   --  @param At_It First element of the super-block, from Vectors'First.
   --  @param Largest Receives the largest magnitude.
   --  @param Finite Receives whether every element is finite.
   procedure Super_Extent
     (Vectors : Model_Runner.Numerics.Real_Array;
      At_It   : Element_Count;
      Largest : out Model_Runner.Numerics.Real;
      Finite  : out Boolean);

   --  Reference products written directly in vector-major output order.
   --  An optional same-shape native partner shares each activation read.
   --  Unsupported profiles or malformed ranges return before output writes.
   --  @param Format Shared quantization format.
   --  @param Data Native or interleaved weight bytes.
   --  @param Offset First weight byte.
   --  @param Row_Bytes Native row stride.
   --  @param Rows Number of output rows.
   --  @param Blocks Quantization blocks per row.
   --  @param Values Packed activation bytes.
   --  @param Scales Activation scales.
   --  @param Totals Activation block totals.
   --  @param Halves Activation half-block totals.
   --  @param First First activation coordinate.
   --  @param Stride Activation vector stride.
   --  @param Count Number of vectors.
   --  @param Target Receives completed binary32 products.
   --  @param Result_First First output row within each vector.
   --  @param Result_Stride Output vector stride.
   --  @param Ok True after all products are written.
   --  @param Interleaved Whether Data uses eight-row panels.
   --  @param Metadata Optional compact physical weight coefficients.
   --  @param Partner Optional second native weight matrix.
   --  @param Partner_Offset First partner byte.
   --  @param Partner_Metadata Optional partner coefficients.
   --  @param Partner_Target Receives partner products; must not alias Target.
   --  @param Result_Members Optional destination vector index for each input; distinct and in range.
   --  @param Input_Members Optional source vector indices; repeated indices are permitted.
   procedure Reference_Products
     (Format : Model_Runner.GGUF.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count; Rows, Blocks : Element_Count;
      Values : Signed_Array; Scales : Model_Runner.Numerics.Real_Array; Totals, Halves : Sum_Array;
      First, Stride, Count : Element_Count; Target : access Model_Runner.Numerics.Real_Array;
      Result_First, Result_Stride : Element_Count; Ok : out Boolean;
      Interleaved : Boolean := False; Metadata : Model_Runner.Numerics.Real_Array := [];
      Partner : Model_Runner.Bytes.Byte_Array := []; Partner_Offset : Model_Runner.Bytes.Byte_Count := 0;
      Partner_Metadata : Model_Runner.Numerics.Real_Array := [];
      Partner_Target : access Model_Runner.Numerics.Real_Array := null;
      Result_Members : Model_Runner.Shares.Member_Rows := [];
      Input_Members : Model_Runner.Shares.Member_Rows := []);

   --  Decode only the sixteen compact group coefficients of a K block.
   --  @param Format Q4_K, Q5_K or Q6_K.
   --  @param Data Native block storage.
   --  @param Offset Byte position of the block.
   --  @param Into Sixteen scale/minimum or signed-scale bytes.
   --  @param Ok True when the native block and output fit.
   procedure Reference_Coefficients
     (Format : Model_Runner.GGUF.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count; Into : out Model_Runner.Bytes.Byte_Array;
      Ok : out Boolean);

   --  Reference nearest-even packing with the original scale divisions.
   --  @param Vectors Valid finite-input candidate rows.
   --  @param First First 32-value block.
   --  @param Last Last 32-value block.
   --  @param Values Receives reference bytes at their source offsets.
   --  @param Scales Receives one scale per 32 values.
   --  @param Totals Receives block sums.
   --  @param Halves Receives sixteen-value sums.
   --  @param Ok False for nonfinite inputs.
   --  @param Super Use signed first-maximum Q8_K scaling.
   --  @param Half_Scales Round stored scales to binary16.
   --  @param Known_Peak Optional measured finite peak of a single 32-value block.
   procedure Reference_Pack
     (Vectors : Model_Runner.Numerics.Real_Array; First, Last : Element_Count;
      Values : in out Signed_Array; Scales : in out Model_Runner.Numerics.Real_Array;
      Totals, Halves : in out Sum_Array; Ok : out Boolean;
      Super, Half_Scales : Boolean; Known_Peak : Model_Runner.Numerics.Real := -1.0);

   --  A super-block's eight blocks rounded against one scale: Block_Round
   --  eight times over, its constants made once.
   --
   --  @param Vectors Activations to read.
   --  @param At_It First element of the super-block, from Vectors'First.
   --  @param Inverse One over the scale, or zero for a block of zeros.
   --  @param Values Receives 256 bytes from At_Out.
   --  @param At_Out First byte of the super-block, from Values'First.
   --  @param Sums Receives each block's two sums.
   procedure Super_Round
     (Vectors : Model_Runner.Numerics.Real_Array;
      At_It   : Element_Count;
      Inverse : Model_Runner.Numerics.Real;
      Values  : in out Signed_Array;
      At_Out  : Element_Count;
      Sums    : out Block_Sums);

end Model_Runner.Quantization.Integers.Kernels;
