--  Exact Q4_K products compiled for x86-64-v4, entered only after CPU and
--  operating-system feature validation. These kernels preserve four
--  binary64 accumulation lanes per row and never round activations.
private package Model_Runner.Tensors.Wide_Products is
   --  Accumulate one Q4_K block for eight independent stored rows.
   --  @param Weight Quant bytes of row zero, past its block header.
   --  @param Vector 256 binary32 activations.
   --  @param Row_Stride Bytes between stored rows.
   --  @param Parameters Decoded scale/minimum pairs in sub-block order.
   --  @param Lanes Eight rows of four binary64 accumulators.
   procedure Rows
     (Weight, Vector : System.Address; Row_Stride : Model_Runner.Bytes.Byte_Count;
      Parameters : Real_Array; Lanes : in out Model_Runner.Numerics.Wide_Real_Array);

   --  Accumulate the same block directly from the existing eight-row panel.
   --  @param Weight Interleaved quant bytes, past the 128-byte panel header.
   --  @param Vector 256 binary32 activations.
   --  @param Row_Stride Reserved; zero for a panel.
   --  @param Parameters Decoded scale/minimum pairs in sub-block order.
   --  @param Lanes Eight rows of four binary64 accumulators.
   procedure Panels
     (Weight, Vector : System.Address; Row_Stride : Model_Runner.Bytes.Byte_Count;
      Parameters : Real_Array; Lanes : in out Model_Runner.Numerics.Wide_Real_Array);
end Model_Runner.Tensors.Wide_Products;
