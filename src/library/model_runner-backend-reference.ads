with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  A backend that answers slowly and plainly.
--
--  The CPU backend partitions rows across workers, shares one reading of the
--  weights between the vectors of a batch, and decodes a span into a buffer
--  so the loops vectorize. Each of those is a reason the answer might be
--  wrong for a reason that is hard to see, and each was put there for speed.
--
--  This one has none of them. It takes a row, decodes it whole, multiplies it
--  by the vector one element at a time, and sums in the wide format. It runs
--  on the calling task. There is nothing to partition, nothing to share and
--  nothing to overlap, so there is nothing about it that can go wrong in a
--  way that depends on how the work was divided.
--
--  It exists to be a second opinion on a model the caller actually has.
--  `tests conformance` compares the engine against an independently written
--  forward pass, which is stronger -- but only on a fixture. Somebody with a
--  file that produces suspicious text can run it again with --backend
--  reference and find out whether the fast path was the reason.
--
--  It is much slower, and that is not a defect to be fixed. Making it faster
--  would mean giving it the things it exists to be without.
--
--  Task safety: every operation is pure with respect to this package and
--  runs entirely on the calling task.
package Model_Runner.Backend.Reference is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  What this backend implements.
   --
   --  It reads every format the engine decodes, needs no alignment beyond the
   --  four bytes a float wants, cannot batch -- several vectors cost several
   --  readings of the weights, which is exactly the saving it declines to
   --  make -- and has no workers to run in parallel.
   --
   --  @return The capability record.
   function Describe return Capabilities;

   --  Matrix product against one input vector.
   --
   --  @param Weight Weight view.
   --  @param Vector Input vector of length Columns, indexed from 0.
   --  @param Target Output vector of length Rows, indexed from 0.
   --  @param Status Success, or why the product could not be computed.
   procedure Product
     (Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info);

   --  Matrix product against several input vectors, one after another.
   --
   --  The weights are read once per vector, which is what Supports_Batched
   --  being False says. A caller that wants the saving wants another backend.
   --
   --  @param Weight Weight view.
   --  @param Vectors Count vectors laid end to end.
   --  @param Count Number of input vectors.
   --  @param Target Count output vectors laid end to end.
   --  @param Status Success, or why the product could not be computed.
   procedure Product_Batch
     (Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

end Model_Runner.Backend.Reference;
