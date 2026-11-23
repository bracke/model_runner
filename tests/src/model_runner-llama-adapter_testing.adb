package body Model_Runner.Llama.Adapter_Testing is

   use type Model_Runner.Tensors.Real_Array_Access;

   procedure Accumulate
     (Live : in out Session; Weight : Model_Runner.Tensors.View;
      Input : Model_Runner.Numerics.Real_Array; Count : Model_Runner.Numerics.Element_Count;
      Output : in out Model_Runner.Numerics.Real_Array; Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null)
   is
      Saved : constant Model_Runner.Cancellation.Token_Reference := Live.Stopping;
   begin
      Live.Stopping := Cancel;
      Apply_Adapters_Batch (Live, Weight, Input, Count, Output, Status);
      Live.Stopping := Saved;
   exception
      when others => Live.Stopping := Saved; raise;
   end Accumulate;

   procedure Project
     (Live : Session; Weight : Model_Runner.Tensors.View; Input : Model_Runner.Numerics.Real_Array;
      Count : Positive; Output : out Model_Runner.Numerics.Real_Array;
      Status : out Model_Runner.Errors.Error_Info)
   is
      package T renames Model_Runner.Tensors;
      Data, Result : T.Real_Array_Access := null;
   begin
      Output := [others => 0.0];
      T.Allocate (Input'Length, Data);
      T.Allocate (Output'Length, Result);
      if Data = null or else Result = null then
         Status := Model_Runner.Errors.Make (Model_Runner.Errors.Memory_Allocation_Failed);
      else
         Data.all := Input;
         if Count = 1 then
            Product (Live, Weight, Data, Result, Status);
         else
            Product_Batch (Live, Weight, Data, Model_Runner.Numerics.Element_Count (Count), Result, Status);
         end if;
         Output := Result.all;
      end if;
      T.Free (Data);
      T.Free (Result);
   exception
      when others => T.Free (Data); T.Free (Result); raise;
   end Project;

   function Stem (Which : Projection) return String is
     (case Which is
        when Attention_Query => "attn_q", when Attention_Key => "attn_k",
        when Attention_Value => "attn_v", when Attention_Output => "attn_output",
        when Feed_Gate => "ffn_gate", when Feed_Up => "ffn_up", when Feed_Down => "ffn_down");

   procedure Read_Projection
     (Item : Model; Layer_Index : Natural; Which : Projection;
      Result : out Model_Runner.Tensors.View; Status : out Model_Runner.Errors.Error_Info)
   is
      package T renames Model_Runner.Tensors;
      package E renames Model_Runner.Errors;
   begin
      Result := T.Empty_View;
      Status := E.Success;
      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
      elsif Item.Layers = null or else Layer_Index not in Item.Layers'Range then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
      else
         Result := (case Which is
                      when Attention_Query => Item.Layers (Layer_Index).Query,
                      when Attention_Key => Item.Layers (Layer_Index).Key,
                      when Attention_Value => Item.Layers (Layer_Index).Value,
                      when Attention_Output => Item.Layers (Layer_Index).Attention_Out,
                      when Feed_Gate => Item.Layers (Layer_Index).Gate,
                      when Feed_Up => Item.Layers (Layer_Index).Up,
                      when Feed_Down => Item.Layers (Layer_Index).Down);
         if not T.Is_Present (Result) then
            Status := E.Make (E.Arch_Missing_Tensor);
         end if;
      end if;
   end Read_Projection;

end Model_Runner.Llama.Adapter_Testing;
