separate (Model_Runner.Llama)
procedure Inkling_Tensors
  (Item : in out Model; Source : Containers.Container;
   Settings : Configuration; Load : Boolean; Status : out E.Error_Info)
is
   H : constant Natural := Settings.Embedding;
   Q : constant Natural := Settings.Heads;
   K_Heads : constant Natural := Settings.KV_Heads;
   D : constant Natural := Settings.Head_Size;
   R : constant Natural := Settings.Inkling.Relative_Width;
   F : constant Natural := Settings.Expert_Feed;
   X : constant Natural := Settings.Inkling.Relative_Extent;
   C_Taps : constant Natural := Settings.Inkling.Convolution_Length;
   G_Rank : constant Natural := Settings.Inkling.Gate_Rank;
   Seen : array (1 .. Containers.Tensor_Count (Source)) of Boolean := [others => False];

   procedure Activation_Contract (Weight : in out T.View) is
   begin
      --  F32 matrices retain the reference lane reduction when their role
      --  is explicitly selected for integer-profile execution as well.
      Weight.Reference_Activations := Weight.Format in Model_Runner.GGUF.Type_F32
        | Model_Runner.GGUF.Type_Q8_0 | Model_Runner.GGUF.Type_Q5_0
        | Model_Runner.GGUF.Type_Q4_K | Model_Runner.GGUF.Type_Q5_K | Model_Runner.GGUF.Type_Q6_K
        | Model_Runner.GGUF.Type_IQ4_XS | Model_Runner.GGUF.Type_IQ4_NL | Model_Runner.GGUF.Type_Q2_0
        | Model_Runner.GGUF.Type_IQ3_S | Model_Runner.GGUF.Type_IQ3_XXS
        | Model_Runner.GGUF.Type_IQ2_XXS | Model_Runner.GGUF.Type_IQ2_XS | Model_Runner.GGUF.Type_IQ2_S
        | Model_Runner.GGUF.Type_IQ1_S | Model_Runner.GGUF.Type_IQ1_M;
   end Activation_Contract;

   function Suffix (Role : Inkling_Weight_Role) return String is
     (case Role is
         when Inkling_Attention_Norm => "attn_norm.weight",
         when Inkling_Query => "attn_q.weight",
         when Inkling_Key => "attn_k.weight",
         when Inkling_Value => "attn_v.weight",
         when Inkling_Attention_Out => "attn_output.weight",
         when Inkling_Attention_Gate => "attn_gate.weight",
         when Inkling_Query_Clip => "attn_q_clip.weight",
         when Inkling_Sink => "attn_sink_proj.weight",
         when Inkling_Relative => "attn_rel.weight",
         when Inkling_Relative_Bias => "attn_rel_bias.weight",
         when Inkling_Relative_Clip => "attn_rel_clip.weight",
         when Inkling_Key_Conv => "attn_k_conv.weight",
         when Inkling_Value_Conv => "attn_v_conv.weight",
         when Inkling_Attention_Conv => "attn_post_conv.weight",
         when Inkling_Feed_Conv => "ffn_post_conv.weight",
         when Inkling_Query_Norm => "attn_q_inp_norm.weight",
         when Inkling_Key_Norm => "attn_k_inp_norm.weight",
         when Inkling_Value_Norm => "attn_v_inp_norm.weight",
         when Inkling_Key_Dynamic => "attn_k_conv_proj.weight",
         when Inkling_Value_Dynamic => "attn_v_conv_proj.weight",
         when Inkling_Attention_Depth => "attn_res_query.weight",
         when Inkling_Feed_Depth => "ffn_res_query.weight",
         when Inkling_Feed_Norm => "ffn_norm.weight",
         when Inkling_Router => "ffn_gate_inp.weight",
         when Inkling_Selection_Bias => "exp_probs_b.bias",
         when Inkling_Fused_Experts => "ffn_gate_up_exps.weight",
         when Inkling_Down_Experts => "ffn_down_exps.weight",
         when Inkling_Message_Query => "loop_msg_query.weight",
         when Inkling_Q_Down => "loop_q_ctrl_down.weight",
         when Inkling_Q_Gain => "loop_q_ctrl_gain.weight",
         when Inkling_Q_Forget => "loop_q_ctrl_forget.weight",
         when Inkling_K_Down => "loop_k_ctrl_down.weight",
         when Inkling_K_Gain => "loop_k_ctrl_gain.weight",
         when Inkling_K_Forget => "loop_k_ctrl_forget.weight",
         when Inkling_V_Down => "loop_v_ctrl_down.weight",
         when Inkling_V_Gain => "loop_v_ctrl_gain.weight",
         when Inkling_V_Forget => "loop_v_ctrl_forget.weight",
         when Inkling_FFN_Down => "loop_ffn_ctrl_down.weight",
         when Inkling_FFN_Gain => "loop_ffn_ctrl_gain.weight",
         when Inkling_FFN_Forget => "loop_ffn_ctrl_forget.weight");

   procedure Check (Name : String; A : Natural; B_Dim : Natural := 1; C_Dim : Natural := 1) is
      Index : constant Natural := Containers.Find_Tensor (Source, Name);
      Dims : constant array (1 .. 4) of Natural := [A, B_Dim, C_Dim, 1];
   begin
      if E.Is_Error (Status) then
         return;
      end if;
      if Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;
      if Seen (Index) or else not Containers.Tensor_Is_Supported (Source, Index) then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text (Status, "format", Model_Runner.GGUF.Type_Name (Containers.Tensor_Format (Source, Index)));
         return;
      end if;
      for Axis in 1 .. 4 loop
         if (if Axis <= Containers.Tensor_Rank (Source, Index)
             then Containers.Tensor_Dimension (Source, Index, Axis) else 1)
           /= Interfaces.Unsigned_64 (Dims (Axis))
         then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Containers.Tensor_Dimension (Source, Index, 1)));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Containers.Tensor_Elements (Source, Index)));
            E.Add_Integer (Status, "expected_columns", Long_Long_Integer (A));
            E.Add_Integer (Status, "expected_rows", Long_Long_Integer (B_Dim) * Long_Long_Integer (C_Dim));
            return;
         end if;
      end loop;
      Seen (Index) := True;
   end Check;

   procedure Global (Name : String; Rows, Columns : Natural; Which : Positive) is
   begin
      Check (Name, Columns, Rows);
      if not Load or else E.Is_Error (Status) then
         return;
      end if;
      case Which is
         when 1 => Resolve (Item, Source, Name, Element_Count (Rows), Element_Count (Columns),
                            Item.Embeddings, Status);
         when 2 => Resolve_Norm (Item, Source, Name, Element_Count (Columns), Item.Embedding_Norm, Status);
         when 3 =>
            Resolve (Item, Source, Name, Element_Count (Rows), Element_Count (Columns), Item.Output, Status);
            if E.Is_Ok (Status) then
               Item.Output.Rows := Element_Count (Settings.Vocabulary);
               Activation_Contract (Item.Output);
            end if;
         when 4 => Resolve_Norm (Item, Source, Name, Element_Count (Columns), Item.Output_Norm, Status);
         when others => Resolve (Item, Source, Name, Element_Count (Rows), Element_Count (Columns),
                                 Item.Inkling_Output_Query, Status);
            if E.Is_Ok (Status) then Activation_Contract (Item.Inkling_Output_Query); end if;
      end case;
   end Global;
begin
   Status := E.Success;
   Global ("token_embd.weight", Settings.Inkling.Padded_Vocabulary, H, 1);
   Global ("token_embd_norm.weight", 1, H, 2);
   Global ("output.weight", Settings.Inkling.Padded_Vocabulary, H, 3);
   Global ("output_norm.weight", 1, H, 4);
   Global ("output_res_query.weight", 1, H, 5);
   if Load and then E.Is_Ok (Status) then
      Item.Layers := new Layer_Array (0 .. Settings.Layers - 1);
   end if;
   for Index in 0 .. Settings.Layers - 1 loop
      for Role in Inkling_Weight_Role loop
         declare
            Local : constant Boolean := Settings.Window_Layers (Index);
            A, B_Dim, C_Dim : Natural := 1;
            Present : Boolean := True;
            Name : constant String := Layer_Key (Index, Suffix (Role));
         begin
            case Role is
               when Inkling_Attention_Norm => A := H; Present := Local;
               when Inkling_Query | Inkling_Attention_Gate => A := H; B_Dim := D * Q;
               when Inkling_Key | Inkling_Value => A := H; B_Dim := D * K_Heads;
               when Inkling_Attention_Out => A := D * Q; B_Dim := H;
               when Inkling_Query_Clip => A := D; B_Dim := Q;
               when Inkling_Sink => A := H; B_Dim := Q;
               when Inkling_Relative => A := H; B_Dim := R * Q;
               when Inkling_Relative_Bias => A := R; B_Dim := (if Local then Settings.Window else X);
               when Inkling_Relative_Clip => A := R; B_Dim := Q;
               when Inkling_Key_Conv | Inkling_Value_Conv => A := C_Taps; B_Dim := D * K_Heads;
               when Inkling_Attention_Conv | Inkling_Feed_Conv => A := C_Taps; B_Dim := H;
               when Inkling_Query_Norm | Inkling_Key_Norm | Inkling_Value_Norm => A := H; Present := not Local;
               when Inkling_Key_Dynamic | Inkling_Value_Dynamic =>
                  A := H; B_Dim := C_Taps * K_Heads; Present := not Local;
               when Inkling_Attention_Depth => A := H; B_Dim := (if Local then 1 else 3); Present := Index > 0;
               when Inkling_Feed_Depth | Inkling_Feed_Norm => A := H;
               when Inkling_Router => A := H; B_Dim := Settings.Experts;
               when Inkling_Selection_Bias =>
                  A := Settings.Experts; Present := Containers.Find_Tensor (Source, Name) > 0;
               when Inkling_Fused_Experts => A := H; B_Dim := 2 * F; C_Dim := Settings.Experts;
               when Inkling_Down_Experts => A := F; B_Dim := H; C_Dim := Settings.Experts;
               when Inkling_Message_Query => A := H; B_Dim := 4;
               when Inkling_Q_Down | Inkling_K_Down | Inkling_V_Down | Inkling_FFN_Down =>
                  A := 2 * H; B_Dim := G_Rank;
               when others => A := G_Rank; B_Dim := H;
            end case;
            if Role in Inkling_Message_Query .. Inkling_FFN_Forget then
               Present := Index in Settings.Inkling.First_Layer .. Settings.Inkling.End_Layer - 1;
            end if;
            if Present then
               Check (Name, A, B_Dim, C_Dim);
               if E.Is_Error (Status) then
                  return;
               end if;
               if Load then
                  if Role = Inkling_Selection_Bias then
                     Resolve_Norm (Item, Source, Name, Element_Count (A), Item.Layers (Index).Select_Bias, Status);
                  elsif Role not in Inkling_Router | Inkling_Fused_Experts | Inkling_Down_Experts then
                     Resolve (Item, Source, Name, Element_Count (B_Dim) * Element_Count (C_Dim), Element_Count (A),
                              Item.Layers (Index).Inkling_Weights (Role), Status,
                              Reaches => Inkling_Matrix_Role (Role));
                     Activation_Contract (Item.Layers (Index).Inkling_Weights (Role));
                  end if;
               end if;
            end if;
         end;
         if E.Is_Error (Status) then
            return;
         end if;
      end loop;
      if Load then
         Resolve_Experts (Item, Source, Index, Item.Layers (Index), Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Activation_Contract (Item.Layers (Index).Router);
         for Expert of Item.Layers (Index).Experts.all loop
            Activation_Contract (Expert.Gate);
            Activation_Contract (Expert.Up);
            Activation_Contract (Expert.Down);
         end loop;
      end if;
   end loop;
   for Index in Seen'Range loop
      if not Seen (Index) then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "inkling2_loop.tensor." & Containers.Tensor_Name (Source, Index));
         return;
      end if;
   end loop;
end Inkling_Tensors;
