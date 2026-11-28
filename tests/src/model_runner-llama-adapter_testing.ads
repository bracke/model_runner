with System;
--  Test-crate inspection only; no production API is added for mutable weights.
package Model_Runner.Llama.Adapter_Testing is

   --  Check that original device slices preserve each prepared CPU expert's
   --  role and reference-activation contract, without copying panel layout.
   --  @param Item Prepared model whose expert views are inspected.
   --  @return True only if at least one expert was checked and all agree.
   function Device_Expert_Contracts_Match (Item : Model) return Boolean;

   --  Test the exact stable router selection without preparing 128 experts.
   procedure Pick_Experts (Scores : Real_Array; Result : out Real_Array);

   function Mixture_Storage (Live : Session) return System.Address;
   function Has_Head_Rows (Live : Session) return Boolean;
   procedure Grouped_Draft_Dots (Queries, Key : Real_Array; Width, Many : Element_Count;
                                 Result : out Real_Array);
   procedure Grouped_Draft_Values (Value, Gains : Real_Array; Into : in out Real_Array;
                                   Stride, Many : Element_Count);

   --  Exact arithmetic probes, confined to the test crate.
   function Scalar_Exp (Value : Real) return Real;
   procedure Vector_Exp (Values : in out Real_Array; Subtract : Real);
   procedure Vector_Activate (Gate : in out Real_Array; Up : Real_Array);
   procedure Rotation (Values : in out Real_Array; Heads, Width : Element_Count;
                       Position : Natural; Base : Wide_Real; Reused : Boolean);
   function Plan_Slots (Live : Session) return Natural;
   function Residual_Runs (Live : Session) return Interfaces.Unsigned_64;
   procedure Residual_Project
     (Live : in out Session; Weight : Model_Runner.Tensors.View; Input : Real_Array; Count : Positive;
      Output : in out Real_Array; Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null);

   --  Test the unobserved proposal projection, including skipped-row guards.
   procedure Proposal_Project
     (Live : Session; Weight : Model_Runner.Tensors.View; Input : Real_Array; Count : Positive;
      Output : in out Real_Array; Status : out Model_Runner.Errors.Error_Info);

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

   --  Fill only allocated Inkling scratch, never weights or committed state.
   --  @param Live Session whose producer/consumer lifetimes are tested.
   --  @param Value Poison value written to the reusable evaluation arena.
   procedure Poison_Scratch (Live : in out Session; Value : Model_Runner.Numerics.Real);

end Model_Runner.Llama.Adapter_Testing;
