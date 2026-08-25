with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  Products of quantized weights with activations quantized to a byte.
--
--  What this is for. A weight in this file's formats is already a small
--  integer and a scale; the vector it is multiplied by is binary32. Widening
--  the weight to binary32 to meet it is what the floating-point path does,
--  and it costs two conversions and a binary64 multiply-add an element. If
--  the vector is rounded to a byte first, with a scale of its own for every
--  thirty-two of them, a block product becomes an integer sum of thirty-two
--  small products -- exact, since it cannot exceed 32 * 127 * 127 -- and one
--  multiply by the product of the two scales. That is the arithmetic every
--  fast runtime does, and it is the reason this one was an order of
--  magnitude behind on a prompt.
--
--  What it costs. The vector is rounded, once, before the product rather than
--  inside it. Nothing else is: the weights are read as the file holds them
--  and the block sums are exact, so this path is more accurate than the
--  floating-point one within a block and less accurate across the vector. The
--  bound it answers to is stated in the conformance suite beside the bounds
--  for the other lossy modes, and it is measured rather than assumed.
--
--  Quantizing is a pure function of the vector, which is what lets the task
--  submitting a matrix product do it once for every worker: a batch, a worker
--  count and a single token all see the same bytes, so a result does not
--  depend on how the work was cut up.
--
--  Task safety: pure functions on caller-supplied buffers, no state.
package Model_Runner.Quantization.Integers is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Element_Index is Model_Runner.Numerics.Element_Index;

   --  Elements one activation block holds.
   --
   --  Thirty-two, because that is what the eight-bit and four-bit block
   --  formats hold and what a 256-element super-block divides into: a weight
   --  block and a whole number of activation blocks line up, so a block
   --  product is one integer sum times one product of two scales. A width
   --  that did not divide every weight block would leave a partial sum at a
   --  block boundary, which is what made folding the multiply into the
   --  four-bit decode 1.79 times slower and is written out above
   --  Accumulate_Dot.
   Activation_Block : constant := 32;

   --  One quantized activation.
   type Byte_Signed is range -128 .. 127 with Size => 8;

   --  A run of quantized activations, indexed from zero as Real_Array is.
   type Signed_Array is array (Element_Index range <>) of Byte_Signed
     with Component_Size => 8;

   --  A run of exact block sums.
   type Sum_Array is array (Element_Index range <>) of Interfaces.Integer_32;

   --  Whether a run of vectors of this width can be quantized at all.
   --
   --  It cannot when the width is not a whole number of blocks. There is no
   --  partial-block arithmetic here on purpose: a tensor whose width is not a
   --  multiple of the block takes the floating-point path, decided once when
   --  a model is prepared rather than once per product.
   --
   --  @param Columns Width of one vector.
   --  @return True when the width is a positive multiple of the block.
   function Is_Packable (Columns : Element_Count) return Boolean
   is (Columns > 0 and then Columns mod Activation_Block = 0);

   --  Whether this package multiplies a weight format without decoding it
   --  into binary32 first.
   --
   --  A pure function of the format, so it can be asked rather than told:
   --  nothing about it depends on the host, and a format this answers False
   --  for is one the caller computes the other way.
   --
   --  @param Format Weight format.
   --  @return True when Accumulate_Rows implements it.
   function Has_Integer_Kernel
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean;

   --  Allow the product built for the wider instruction set.
   --
   --  Told rather than asked, and told once before any product is
   --  dispatched: this package interprets what a model file holds and may
   --  not reach a host, so the question is asked where a host may be
   --  reached and the answer pushed here.
   --
   --  @param Allowed True where the host has the wider instructions.
   procedure Use_Wide_Rows (Allowed : Boolean);

   --  Quantize a run of vectors to one byte an element.
   --
   --  Symmetric and per block: the scale is the block's largest magnitude
   --  over 127, and an element is its value over that scale rounded to
   --  nearest with ties away from zero. A block of zeros gets a scale of zero
   --  and bytes of zero, which multiplies out to zero as it should, and a
   --  block holding anything that is not finite is refused rather than
   --  rounded -- a not-a-number has no nearest byte, and a caller reading Ok
   --  takes the floating-point path where the value will be reported by the
   --  finiteness checks that already exist.
   --
   --  Totals carries the sum of each block's bytes. Nothing reads it for a
   --  format whose block is a scale and no offset; every format that carries
   --  a minimum as well needs it, because the product of a weight d*q + m
   --  with an activation da*qa is d*da*sum(q*qa) + m*da*sum(qa), and the
   --  second term is this table. It costs four bytes a block to keep and a
   --  redesign to add later.
   --
   --  @param Vectors Count vectors laid end to end, each Columns wide.
   --  @param Count Number of vectors.
   --  @param Columns Width of one vector.
   --  @param Values Quantized elements, Count * Columns of them from
   --    Values'First.
   --  @param Scales One scale for every Activation_Block elements of Values,
   --    from Scales'First.
   --  @param Totals One sum for every Activation_Block elements of Values,
   --    from Totals'First.
   --  @param Ok True when the shape is packable, every buffer had room, and
   --    every element read was finite. False leaves the three outputs as they
   --    were rather than half filled.
   procedure Quantize_Vectors
     (Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Columns : Element_Count;
      Values  : out Signed_Array;
      Scales  : out Model_Runner.Numerics.Real_Array;
      Totals  : out Sum_Array;
      Ok      : out Boolean);

   --  How many rows one call of Accumulate_Rows computes at once.
   --
   --  Four, and measured rather than reasoned: a 110-token prompt takes
   --  2.120 s at two rows, 1.948 s at four and 2.122 s at eight. Four sets
   --  of accumulators and one activation block are what fit in registers
   --  together, and four is enough chains to interleave against a
   --  multiply-add latency. A caller with fewer rows left than this passes
   --  fewer; the kernel is written for the general count and this is only
   --  the largest tile it will take.
   --
   --  Eight rather than the four it was, and what changed is not this
   --  kernel but how many vectors reach it. A tile reads the activation
   --  once and the activation is re-read once per tile, so the traffic it
   --  saves grows with the batch: at the thirty-two vectors a pass that was
   --  the default when four was chosen, eight measured worse -- 2.122 s
   --  against 1.948 -- and at the hundred and twenty-eight that a prompt is
   --  read in now it measures better, 1.281 s against 1.379.
   --
   --  Which is why Wanted_Tile exists rather than this deciding alone: a
   --  generated token is one vector, where the activation is two kilobytes
   --  and in the nearest cache whatever the tile, and there eight is
   --  slightly worse than four -- 2.593 s against 2.545. The tile that
   --  suits a prompt is not the tile that suits a token.
   Row_Tile : constant := 8;

   --  How many rows to ask for, given how many vectors are being multiplied.
   --
   --  @param Count Vectors in the pass.
   --  @return The tile to ask Accumulate_Rows for.
   function Wanted_Tile (Count : Element_Index) return Element_Index
   is (if Count > 1 then Row_Tile else 4);

   --  The same product over several consecutive rows at once.
   --
   --  A row at a time reads the activation once per row: for a matrix of two
   --  thousand rows that is two thousand passes over the same bytes, which
   --  sit in the nearest cache and are still loaded two thousand times.
   --  Reading it once for four rows is the whole of what this adds, and the
   --  four rows also give the processor four independent chains where one
   --  gave it one.
   --
   --  A row's blocks are accumulated first to last whatever the tile, so a
   --  row's value does not depend on how many rows were computed beside it
   --  -- which is what lets a share of a matrix be cut anywhere.
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
   --  @param Sums Rows * Count accumulators from Sums'First, row major:
   --    row R vector K is at R * Count + K. Added to, and left as they were
   --    when Ok is False.
   --  @param Ok True when the format has an integer kernel, every row lay
   --    wholly inside Data, and every element the call would read lay inside
   --    Values and its two tables.
   procedure Accumulate_Rows
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

end Model_Runner.Quantization.Integers;
