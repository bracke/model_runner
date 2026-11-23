--  Test-crate inspection only; no production API is added for mutable weights.
package Model_Runner.Llama.Adapter_Testing is

   type Projection is (Attention_Query, Attention_Key, Attention_Value, Attention_Output,
                       Feed_Gate, Feed_Up, Feed_Down);

   --  @param Which One of the seven promised adapter targets.
   --  @return GGUF projection stem, without layer or weight suffix.
   function Stem (Which : Projection) return String;

   --  The non-owning result is valid only while Item stays prepared.
   --  @param Item Prepared model under test.
   --  @param Layer_Index Zero-based layer index.
   --  @param Which Projection to inspect.
   --  @param Result Read-only view, empty on failure.
   --  @param Status Success, lifecycle, bounds or missing-tensor refusal.
   procedure Read_Projection
     (Item : Model; Layer_Index : Natural; Which : Projection;
      Result : out Model_Runner.Tensors.View; Status : out Model_Runner.Errors.Error_Info);

   --  @param Live Open session with its own admitted adapter scratch.
   --  @param Weight Resolved prepared-model projection.
   --  @param Input Packed input rows.
   --  @param Count Number of rows; one uses the token route, more use the batch route.
   --  @param Output Receives packed output rows.
   --  @param Status Native projection result.
   procedure Project
     (Live : Session; Weight : Model_Runner.Tensors.View; Input : Model_Runner.Numerics.Real_Array;
      Count : Positive; Output : out Model_Runner.Numerics.Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  @param Live Session whose private admitted scratch is exercised without a base product.
   --  @param Weight Exact target view.
   --  @param Input Packed active rows, possibly followed by unused guard rows.
   --  @param Count Number of active rows.
   --  @param Output Base activations plus deltas on success; unused rows must remain untouched.
   --  @param Status Adapter execution result.
   --  @param Cancel Optional token restored after the call, including on failure.
   procedure Accumulate
     (Live : in out Session; Weight : Model_Runner.Tensors.View;
      Input : Model_Runner.Numerics.Real_Array; Count : Model_Runner.Numerics.Element_Count;
      Output : in out Model_Runner.Numerics.Real_Array; Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null);

end Model_Runner.Llama.Adapter_Testing;
