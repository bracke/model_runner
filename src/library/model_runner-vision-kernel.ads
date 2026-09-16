--  The product a picture's encoder spends its time in, in binary32.
--
--  A token of text multiplies one vector by a matrix, and reading the
--  matrix is the cost; a picture multiplies four thousand vectors by
--  each matrix, and the arithmetic is. The engine's products decode a row
--  of weights once and walk every vector with it, accumulating in
--  binary64, which is right for the first job and slow for the second.
--  This is the second job's kernel: both matrices in binary32, two rows
--  of one against four of the other at a time, eight lanes of partial
--  sums apiece, so that the compiler's vectorizer has eight independent
--  accumulators to keep in registers and nothing to reassociate.
--
--  Instantiated twice, once compiled for the wide vector unit and once
--  without, and the wide one chosen where the host has it; the two agree
--  to the bit, lane for lane, since neither contracts a multiply into an
--  add and both sum the lanes in the same order.
private generic
   Wider : Boolean := False;
package Model_Runner.Vision.Kernel is

   --  Rows of the right-hand matrix one tile holds.
   Tile : constant := 4;

   --  C (i, n) := sum over k of A (i, k) * W (n, k), for every row i of A
   --  and the rows n of W in tiles First .. Last, added to nothing: the
   --  target rows are written, not accumulated into. A is Rows rows of
   --  Width, W is Wanted rows of Width, C is Rows rows of Wanted, all
   --  row-major and indexed from their arrays' first elements.
   --
   --  @param A The left matrix.
   --  @param Rows Rows A has.
   --  @param W The right matrix, whose rows are the answer's columns.
   --  @param Wanted Rows W has.
   --  @param Width Columns both have.
   --  @param C Receives Rows rows of Wanted.
   --  @param First First tile of W's rows to compute.
   --  @param Last Last tile; a tile past the end is the tail of W.
   procedure Multiply
     (A      : Model_Runner.Numerics.Real_Array;
      Rows   : Model_Runner.Numerics.Element_Count;
      W      : Model_Runner.Numerics.Real_Array;
      Wanted : Model_Runner.Numerics.Element_Count;
      Width  : Model_Runner.Numerics.Element_Count;
      C      : in out Model_Runner.Numerics.Real_Array;
      First  : Model_Runner.Numerics.Element_Count;
      Last   : Model_Runner.Numerics.Element_Count);

end Model_Runner.Vision.Kernel;
