separate (Model_Runner.Llama)
procedure DSpark_Tensors
  (Item : in out Model; Source : Containers.Container;
   Settings : Configuration; Load : Boolean; Status : out E.Error_Info)
is
   use type Model_Runner.GGUF.Tensor_Type;
   H : constant Natural := Settings.Embedding;
   D : constant Natural := Settings.Head_Size;
   Q : constant Natural := Settings.Heads * D;
   KV : constant Natural := Settings.KV_Heads * D;
   F : constant Natural := Settings.Feed_Forward;
   V : constant Natural := Settings.Vocabulary;
   R : constant Natural := Settings.DSpark.Markov_Rank;
   Seen : array (1 .. Containers.Tensor_Count (Source)) of Boolean := [others => False];

   procedure Check (Name : String; Columns, Rows : Natural;
                    Format : Model_Runner.GGUF.Tensor_Type) is
      At_Tensor : constant Natural := Containers.Find_Tensor (Source, Name);
   begin
      if E.Is_Error (Status) then return; end if;
      if At_Tensor = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
      elsif Seen (At_Tensor) or else Containers.Tensor_Format (Source, At_Tensor) /= Format
        or else not Containers.Tensor_Is_Supported (Source, At_Tensor)
      then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
      elsif Containers.Tensor_Dimension (Source, At_Tensor, 1) /= Interfaces.Unsigned_64 (Columns)
        or else Containers.Tensor_Elements (Source, At_Tensor)
          /= Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Rows)
        or else Containers.Tensor_Rank (Source, At_Tensor) /= (if Rows = 1 then 1 else 2)
      then
         Status := E.Make (E.Arch_Invalid_Tensor_Shape);
      else
         Seen (At_Tensor) := True;
      end if;
      if E.Is_Error (Status) then E.Add_Text (Status, "tensor", Name, E.Param_Identifier); end if;
   end Check;

   procedure Matrix (Name : String; Columns, Rows : Natural; Into : in out T.View;
                     Format : Model_Runner.GGUF.Tensor_Type := Model_Runner.GGUF.Type_Q8_0) is
   begin
      Check (Name, Columns, Rows, Format);
      if Load and then E.Is_Ok (Status) then
         Resolve (Item, Source, Name, Element_Count (Rows), Element_Count (Columns), Into, Status);
         Into.Reference_Activations := True;
      end if;
   end Matrix;

   procedure Vector (Name : String; Width : Natural; Into : in out T.Real_Array_Access) is
   begin
      Check (Name, Width, 1, Model_Runner.GGUF.Type_F32);
      if Load and then E.Is_Ok (Status) then
         Resolve_Norm (Item, Source, Name, Element_Count (Width), Into, Status);
      end if;
   end Vector;

   --  Descriptor validation uses the same mapping with no allocation.
begin
   Status := E.Success;
   if Load then
      Item.DSpark_Views := new DSpark_Weights;
      Item.Layers := new Layer_Array (0 .. 2);
   end if;
   if Load then
      Matrix ("mask_embd.weight", H, 7, Item.DSpark_Views.Mask, Model_Runner.GGUF.Type_F32);
   else
      Check ("mask_embd.weight", H, 7, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Matrix ("markov_w1.weight", R, V, Item.DSpark_Views.Markov_W1, Model_Runner.GGUF.Type_BF16);
   else
      Check ("markov_w1.weight", R, V, Model_Runner.GGUF.Type_BF16);
   end if;
   if Load then
      Matrix ("markov_w2.weight", R, V, Item.DSpark_Views.Markov_W2, Model_Runner.GGUF.Type_BF16);
   else
      Check ("markov_w2.weight", R, V, Model_Runner.GGUF.Type_BF16);
   end if;
   if Load then
      Matrix ("joint_proj.weight", 2 * H + 2 * R, 3 * R, Item.DSpark_Views.Joint, Model_Runner.GGUF.Type_BF16);
   else
      Check ("joint_proj.weight", 2 * H + 2 * R, 3 * R, Model_Runner.GGUF.Type_BF16);
   end if;
   if Load then
      Vector ("token_embd_norm.weight", H, Item.Embedding_Norm);
   else
      Check ("token_embd_norm.weight", H, 1, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Vector ("output_norm.weight", H, Item.Output_Norm);
   else
      Check ("output_norm.weight", H, 1, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Vector ("markov_ctx_mix.weight", 4, Item.DSpark_Views.Context_Mix);
   else
      Check ("markov_ctx_mix.weight", 4, 1, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Vector ("markov_ctx_norm.weight", H, Item.DSpark_Views.Context_Norm);
   else
      Check ("markov_ctx_norm.weight", H, 1, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Vector ("markov_w2.bias", V, Item.DSpark_Views.Markov_Bias);
   else
      Check ("markov_w2.bias", V, 1, Model_Runner.GGUF.Type_F32);
   end if;
   if Load then
      Vector ("joint_proj.bias", 3 * R, Item.DSpark_Views.Joint_Bias);
   else
      Check ("joint_proj.bias", 3 * R, 1, Model_Runner.GGUF.Type_F32);
   end if;
   for Index in 0 .. 2 loop
      if Load then
         Matrix (Layer_Key (Index, "attn_q.weight"), H, Q, Item.Layers (Index).Query);
      else
         Check (Layer_Key (Index, "attn_q.weight"), H, Q, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "attn_k.weight"), H, KV, Item.Layers (Index).Key);
      else
         Check (Layer_Key (Index, "attn_k.weight"), H, KV, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "attn_v.weight"), H, KV, Item.Layers (Index).Value);
      else
         Check (Layer_Key (Index, "attn_v.weight"), H, KV, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "attn_output.weight"), Q, H, Item.Layers (Index).Attention_Out);
      else
         Check (Layer_Key (Index, "attn_output.weight"), Q, H, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "ffn_gate.weight"), H, F, Item.Layers (Index).Gate);
      else
         Check (Layer_Key (Index, "ffn_gate.weight"), H, F, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "ffn_up.weight"), H, F, Item.Layers (Index).Up);
      else
         Check (Layer_Key (Index, "ffn_up.weight"), H, F, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "ffn_down.weight"), F, H, Item.Layers (Index).Down);
      else
         Check (Layer_Key (Index, "ffn_down.weight"), F, H, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "attn_k_ctx.weight"), H, KV, Item.DSpark_Views.Contexts (Index).Key);
      else
         Check (Layer_Key (Index, "attn_k_ctx.weight"), H, KV, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Matrix (Layer_Key (Index, "attn_v_ctx.weight"), H, KV, Item.DSpark_Views.Contexts (Index).Value);
      else
         Check (Layer_Key (Index, "attn_v_ctx.weight"), H, KV, Model_Runner.GGUF.Type_Q8_0);
      end if;
      if Load then
         Vector (Layer_Key (Index, "attn_norm.weight"), H, Item.Layers (Index).Attention_Norm);
      else
         Check (Layer_Key (Index, "attn_norm.weight"), H, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "ffn_norm.weight"), H, Item.Layers (Index).Feed_Norm);
      else
         Check (Layer_Key (Index, "ffn_norm.weight"), H, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "attn_q_norm.weight"), D, Item.Layers (Index).Query_Head_Norm);
      else
         Check (Layer_Key (Index, "attn_q_norm.weight"), D, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "attn_k_norm.weight"), D, Item.Layers (Index).Key_Head_Norm);
      else
         Check (Layer_Key (Index, "attn_k_norm.weight"), D, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "ctx_mix.weight"), 4, Item.DSpark_Views.Contexts (Index).Mix);
      else
         Check (Layer_Key (Index, "ctx_mix.weight"), 4, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "ctx_norm.weight"), H, Item.DSpark_Views.Contexts (Index).Norm);
      else
         Check (Layer_Key (Index, "ctx_norm.weight"), H, 1, Model_Runner.GGUF.Type_F32);
      end if;
      if Load then
         Vector (Layer_Key (Index, "attn_k_ctx_norm.weight"), D, Item.DSpark_Views.Contexts (Index).Key_Norm);
      else
         Check (Layer_Key (Index, "attn_k_ctx_norm.weight"), D, 1, Model_Runner.GGUF.Type_F32);
      end if;
   end loop;
   for Index in Seen'Range loop
      if not Seen (Index) and then E.Is_Ok (Status) then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "dflash.unmapped_tensor", E.Param_Identifier);
         E.Add_Text (Status, "tensor", Containers.Tensor_Name (Source, Index), E.Param_Identifier);
         return;
      end if;
   end loop;
end DSpark_Tensors;
