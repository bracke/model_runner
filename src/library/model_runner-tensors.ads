with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  Read-only tensor views over model bytes.
--
--  Dimension convention. This crate uses one internal convention and converts
--  to it exactly once, when a descriptor is turned into a view. GGUF writes
--  dimension 1 first and that dimension is contiguous in memory. Here a
--  two-dimensional weight is therefore a matrix of Rows rows, each holding
--  Columns contiguous elements, where Columns is GGUF dimension 1 and Rows is
--  the product of the remaining dimensions.
--
--  For every weight in the supported architecture, Columns is the input width
--  and Rows is the output width, so a matrix-vector product reads each row
--  contiguously:
--
--     Y (r) = sum over c of W (r, c) * X (c)
--
--  Storage and lifetime. A view is a non-owning reference into a buffer that
--  the prepared model owns. A view must not outlive that buffer. Views are
--  read-only: model weights are immutable once preparation completes, and
--  there is no operation here that writes through one.
--
--  Quantized formats. A row of a quantized tensor is a whole number of blocks.
--  Row_Dot and Dequantize_Row decode one block at a time into a small fixed
--  buffer, so no operation ever materializes an unquantized copy of a whole
--  tensor, let alone of the model.
--
--  Task safety: views are immutable and may be read concurrently.
package Model_Runner.Tensors is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Wide_Real is Model_Runner.Numerics.Wide_Real;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   --  A read-only matrix view.
   --
   --  Data is the buffer the elements live in; Offset is the byte position of
   --  the first element within it. A default view is empty and every operation
   --  on it reports a shape mismatch.
   type View is record
      Format  : Model_Runner.GGUF.Tensor_Type := Model_Runner.GGUF.Type_F32;
      Rows    : Element_Count := 0;
      Columns : Element_Count := 0;
      Data    : Model_Runner.Bytes.Byte_Array_Access := null;
      Offset  : Model_Runner.Bytes.Byte_Count := 0;
      Length  : Model_Runner.Bytes.Byte_Count := 0;
   end record;

   Empty_View : constant View := (others => <>);

   --  Heap storage for activation and cache buffers.
   --
   --  Declared here rather than in Model_Runner.Numerics so that the numeric
   --  package stays free of allocation.
   type Real_Array_Access is access Real_Array;

   subtype Half_Array is Model_Runner.Numerics.Half_Array;
   type Half_Array_Access is access Half_Array;

   --  Allocate a zero-filled vector.
   --
   --  @param Length Number of elements.
   --  @param Result Allocated vector indexed from 0, or null on failure.
   procedure Allocate (Length : Element_Count; Result : out Real_Array_Access);

   --  Allocate a zero-filled half-precision vector.
   --
   --  Zero here is the bit pattern zero, which is what binary16 zero is, so
   --  the buffer reads as zeros before anything writes to it.
   --
   --  @param Length Number of elements.
   --  @param Result Allocated vector indexed from 0, or null on failure.
   procedure Allocate (Length : Element_Count; Result : out Half_Array_Access);

   --  Release a vector and clear the reference. Idempotent.
   --
   --  @param Item Reference to release.
   procedure Free (Item : in out Real_Array_Access);

   --  Release a half-precision vector and clear the reference. Idempotent.
   --
   --  @param Item Reference to release.
   procedure Free (Item : in out Half_Array_Access);

   --  Build a view and validate that it fits inside its buffer.
   --
   --  @param Format Element format.
   --  @param Rows Number of rows.
   --  @param Columns Contiguous elements per row.
   --  @param Data Buffer holding the elements.
   --  @param Offset Byte position of the first element.
   --  @param Result Constructed view; empty on failure.
   --  @param Status Success, Tensor_Invalid_Shape, Tensor_Block_Misaligned,
   --    Tensor_Format_Unsupported or Tensor_Out_Of_Bounds.
   procedure Make
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Data    : Model_Runner.Bytes.Byte_Array_Access;
      Offset  : Model_Runner.Bytes.Byte_Count;
      Result  : out View;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Report whether a view refers to storage.
   --
   --  @param Item View to inspect.
   --  @return True when the view has a buffer and a non-zero shape.
   function Is_Present (Item : View) return Boolean;

   --  Serialized size of one row.
   --
   --  @param Item View to inspect.
   --  @return Bytes per row.
   function Row_Bytes (Item : View) return Model_Runner.Bytes.Byte_Count;

   --  Total element count.
   --
   --  @param Item View to inspect.
   --  @return Rows multiplied by Columns.
   function Elements (Item : View) return Element_Count;

   --  Dot product of one row with a vector.
   --
   --  Quantized rows are decoded one block at a time into a fixed-size local
   --  buffer. Accumulation is in Wide_Real and the result is rounded to Real
   --  once, so the result does not depend on how the row was split into
   --  blocks.
   --
   --  @param Item Weight view.
   --  @param Row Row index, zero based.
   --  @param Vector Input vector of length Columns, indexed from 0.
   --  @return Dot product; 0.0 when the row or the length is out of range.
   function Row_Dot
     (Item   : View;
      Row    : Element_Count;
      Vector : Real_Array) return Real;

   --  Decode one row into a caller-owned buffer.
   --
   --  Used for embedding lookup, where the row is the token's embedding, and
   --  by the tests to compare a quantized row against its reference values.
   --
   --  @param Item Weight view.
   --  @param Row Row index, zero based.
   --  @param Target Buffer of length Columns, indexed from 0.
   --  @param Status Success or Tensor_Out_Of_Bounds.
   procedure Dequantize_Row
     (Item   : View;
      Row    : Element_Count;
      Target : out Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  Matrix-vector product over a range of rows.
   --
   --  Restricting the row range is how the worker pool partitions the work:
   --  each worker owns a disjoint range, so the result never depends on how
   --  many workers ran.
   --
   --  @param Item Weight view.
   --  @param Vector Input vector of length Columns, indexed from 0.
   --  @param Target Output vector of length Rows, indexed from 0.
   --  @param First First row to compute, zero based.
   --  @param Last Last row to compute, zero based.
   procedure Mat_Vec_Range
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      First  : Element_Count;
      Last   : Element_Count);

   --  Matrix-vector product over every row.
   --
   --  @param Item Weight view.
   --  @param Vector Input vector of length Columns, indexed from 0.
   --  @param Target Output vector of length Rows, indexed from 0.
   --  @param Status Success or Tensor_Shape_Mismatch.
   procedure Mat_Vec
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  Matrix product against several input vectors at once, over a range of
   --  rows.
   --
   --  This is what makes batched prefill worth doing. The cost of a row is
   --  dominated by decoding its weights, not by the arithmetic that consumes
   --  them, so a row decoded once and applied to Count inputs costs far less
   --  than the same row decoded Count times. Count of one is the same work as
   --  Mat_Vec_Range, arranged the same way.
   --
   --  Each input vector is computed independently and in the same order as it
   --  would be alone, so a batch produces exactly the values the same tokens
   --  produce one at a time -- not merely close ones.
   --
   --  @param Item Weight view.
   --  @param Vectors Count input vectors laid end to end, each of length
   --    Columns; vector K starts at Vectors'First + K * Columns.
   --  @param Count Number of input vectors.
   --  @param Target Count output vectors laid end to end, each of length
   --    Rows; vector K starts at Target'First + K * Rows.
   --  @param First First row to compute, zero based.
   --  @param Last Last row to compute, zero based.
   procedure Mat_Mul_Range
     (Item    : View;
      Vectors : Real_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count);

end Model_Runner.Tensors;
