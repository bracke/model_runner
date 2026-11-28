separate (Tiny_Model)
procedure Build_DSpark (Result : out Model_Runner.Bytes.Byte_Array_Access) is
   package B renames Model_Runner.Bytes;
   use type B.Byte_Count;
   Builder : Fixtures.Builder;
   Raw : constant String := Project_Tools.Files.Read_Raw_File
     ("fixtures/inkling2/dspark-tiny/weights.bin");
   Payload : B.Byte_Array (0 .. B.Byte_Count (Raw'Length) - 1);

   procedure Weight
     (Name : String; Columns, Rows : Positive; Format : G.Tensor_Type;
      Offset, Count : B.Byte_Count) is
   begin
      Fixtures.Add_Tensor
        (Builder, Name, (if Rows = 1 then [G.U64 (Columns)] else [G.U64 (Columns), G.U64 (Rows)]),
         Format, Payload (Offset .. Offset + Count - 1));
   end Weight;
begin
   --  Only independently generated tensor payloads are retained in fixtures.
   --  Framing is built here, so clean checkouts need no ignored GGUF file.
   for I in Raw'Range loop
      Payload (B.Byte_Count (I - Raw'First)) := B.Byte (Character'Pos (Raw (I)));
   end loop;
   Fixtures.Reset (Builder);
   Fixtures.Add_String (Builder, "general.architecture", "dflash");
   Fixtures.Add_U32 (Builder, "dflash.block_count", 3);
   Fixtures.Add_U32 (Builder, "dflash.context_length", 2048);
   Fixtures.Add_U32 (Builder, "dflash.embedding_length", 32);
   Fixtures.Add_U32 (Builder, "dflash.feed_forward_length", 64);
   Fixtures.Add_U32 (Builder, "dflash.attention.head_count", 2);
   Fixtures.Add_U32 (Builder, "dflash.attention.head_count_kv", 1);
   Fixtures.Add_U32 (Builder, "dflash.attention.key_length", 16);
   Fixtures.Add_U32 (Builder, "dflash.attention.value_length", 16);
   Fixtures.Add_U32 (Builder, "dflash.rope.dimension_count", 16);
   Fixtures.Add_F32 (Builder, "dflash.rope.freq_base", 1000000.0);
   Fixtures.Add_F32 (Builder, "dflash.attention.layer_norm_rms_epsilon", 1.0E-6);
   Fixtures.Add_U32 (Builder, "dflash.attention.sliding_window", 1025);
   Fixtures.Begin_Array
     (Builder, "dflash.attention.sliding_window_pattern", G.Value_Bool, 3);
   Fixtures.Bool_Element (Builder, True);
   Fixtures.Bool_Element (Builder, False);
   Fixtures.Bool_Element (Builder, True);
   Fixtures.End_Array (Builder);
   Fixtures.Add_F32 (Builder, "dflash.final_logit_softcapping", 30.0);
   Fixtures.Add_U32 (Builder, "dflash.block_size", 8);
   Fixtures.Begin_Array
     (Builder, "dflash.target_layers", G.Value_Int32, 4);
   Fixtures.Int32_Element (Builder, 5);
   Fixtures.Int32_Element (Builder, 23);
   Fixtures.Int32_Element (Builder, 41);
   Fixtures.Int32_Element (Builder, 48);
   Fixtures.End_Array (Builder);
   Fixtures.Add_Bool (Builder, "dflash.sample_from_anchor", False);
   Fixtures.Add_Bool (Builder, "dflash.has_confidence_head", False);
   Fixtures.Add_Bool (Builder, "dflash.has_markov_context", True);
   Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 1);
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 2);
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
   Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_bos_token", False);
   Fixtures.Begin_Array
     (Builder, "tokenizer.ggml.tokens", G.Value_String, 16);
   Fixtures.String_Element (Builder, "<unk>");
   Fixtures.String_Element (Builder, "<s>");
   Fixtures.String_Element (Builder, "</s>");
   Fixtures.String_Element (Builder, "a");
   Fixtures.String_Element (Builder, "b");
   Fixtures.String_Element (Builder, "c");
   Fixtures.String_Element (Builder, "d");
   Fixtures.String_Element (Builder, "e");
   Fixtures.String_Element (Builder, "f");
   Fixtures.String_Element (Builder, "g");
   Fixtures.String_Element (Builder, "h");
   Fixtures.String_Element (Builder, "i");
   Fixtures.String_Element (Builder, "j");
   Fixtures.String_Element (Builder, "k");
   Fixtures.String_Element (Builder, "l");
   Fixtures.String_Element (Builder, "m");
   Fixtures.End_Array (Builder);
   Fixtures.Begin_Array
     (Builder, "tokenizer.ggml.scores", G.Value_Float32, 16);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.Float_Element (Builder, 0.0);
   Fixtures.End_Array (Builder);
   Fixtures.Begin_Array
     (Builder, "tokenizer.ggml.token_type", G.Value_Int32, 16);
   Fixtures.Int32_Element (Builder, 2);
   Fixtures.Int32_Element (Builder, 3);
   Fixtures.Int32_Element (Builder, 3);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.Int32_Element (Builder, 1);
   Fixtures.End_Array (Builder);
   Weight ("mask_embd.weight", 32, 7, G.Type_F32, 0, 896);
   Weight ("token_embd_norm.weight", 32, 1, G.Type_F32, 896, 128);
   Weight ("output_norm.weight", 32, 1, G.Type_F32, 1024, 128);
   Weight ("markov_w1.weight", 4, 16, G.Type_BF16, 1152, 128);
   Weight ("markov_w2.weight", 4, 16, G.Type_BF16, 1280, 128);
   Weight ("markov_w2.bias", 16, 1, G.Type_F32, 1408, 64);
   Weight ("joint_proj.weight", 72, 12, G.Type_BF16, 1472, 1728);
   Weight ("joint_proj.bias", 12, 1, G.Type_F32, 3200, 48);
   Weight ("markov_ctx_mix.weight", 4, 1, G.Type_F32, 3248, 16);
   Weight ("markov_ctx_norm.weight", 32, 1, G.Type_F32, 3264, 128);
   Weight ("blk.0.attn_norm.weight", 32, 1, G.Type_F32, 3392, 128);
   Weight ("blk.0.ffn_norm.weight", 32, 1, G.Type_F32, 3520, 128);
   Weight ("blk.0.attn_q_norm.weight", 16, 1, G.Type_F32, 3648, 64);
   Weight ("blk.0.attn_k_norm.weight", 16, 1, G.Type_F32, 3712, 64);
   Weight ("blk.0.attn_q.weight", 32, 32, G.Type_Q8_0, 3776, 1088);
   Weight ("blk.0.attn_k.weight", 32, 16, G.Type_Q8_0, 4864, 544);
   Weight ("blk.0.attn_v.weight", 32, 16, G.Type_Q8_0, 5408, 544);
   Weight ("blk.0.attn_output.weight", 32, 32, G.Type_Q8_0, 5952, 1088);
   Weight ("blk.0.ffn_gate.weight", 32, 64, G.Type_Q8_0, 7040, 2176);
   Weight ("blk.0.ffn_up.weight", 32, 64, G.Type_Q8_0, 9216, 2176);
   Weight ("blk.0.ffn_down.weight", 64, 32, G.Type_Q8_0, 11392, 2176);
   Weight ("blk.0.ctx_mix.weight", 4, 1, G.Type_F32, 13568, 16);
   Weight ("blk.0.ctx_norm.weight", 32, 1, G.Type_F32, 13584, 128);
   Weight ("blk.0.attn_k_ctx.weight", 32, 16, G.Type_Q8_0, 13712, 544);
   Weight ("blk.0.attn_v_ctx.weight", 32, 16, G.Type_Q8_0, 14256, 544);
   Weight ("blk.0.attn_k_ctx_norm.weight", 16, 1, G.Type_F32, 14800, 64);
   Weight ("blk.1.attn_norm.weight", 32, 1, G.Type_F32, 14864, 128);
   Weight ("blk.1.ffn_norm.weight", 32, 1, G.Type_F32, 14992, 128);
   Weight ("blk.1.attn_q_norm.weight", 16, 1, G.Type_F32, 15120, 64);
   Weight ("blk.1.attn_k_norm.weight", 16, 1, G.Type_F32, 15184, 64);
   Weight ("blk.1.attn_q.weight", 32, 32, G.Type_Q8_0, 15248, 1088);
   Weight ("blk.1.attn_k.weight", 32, 16, G.Type_Q8_0, 16336, 544);
   Weight ("blk.1.attn_v.weight", 32, 16, G.Type_Q8_0, 16880, 544);
   Weight ("blk.1.attn_output.weight", 32, 32, G.Type_Q8_0, 17424, 1088);
   Weight ("blk.1.ffn_gate.weight", 32, 64, G.Type_Q8_0, 18512, 2176);
   Weight ("blk.1.ffn_up.weight", 32, 64, G.Type_Q8_0, 20688, 2176);
   Weight ("blk.1.ffn_down.weight", 64, 32, G.Type_Q8_0, 22864, 2176);
   Weight ("blk.1.ctx_mix.weight", 4, 1, G.Type_F32, 25040, 16);
   Weight ("blk.1.ctx_norm.weight", 32, 1, G.Type_F32, 25056, 128);
   Weight ("blk.1.attn_k_ctx.weight", 32, 16, G.Type_Q8_0, 25184, 544);
   Weight ("blk.1.attn_v_ctx.weight", 32, 16, G.Type_Q8_0, 25728, 544);
   Weight ("blk.1.attn_k_ctx_norm.weight", 16, 1, G.Type_F32, 26272, 64);
   Weight ("blk.2.attn_norm.weight", 32, 1, G.Type_F32, 26336, 128);
   Weight ("blk.2.ffn_norm.weight", 32, 1, G.Type_F32, 26464, 128);
   Weight ("blk.2.attn_q_norm.weight", 16, 1, G.Type_F32, 26592, 64);
   Weight ("blk.2.attn_k_norm.weight", 16, 1, G.Type_F32, 26656, 64);
   Weight ("blk.2.attn_q.weight", 32, 32, G.Type_Q8_0, 26720, 1088);
   Weight ("blk.2.attn_k.weight", 32, 16, G.Type_Q8_0, 27808, 544);
   Weight ("blk.2.attn_v.weight", 32, 16, G.Type_Q8_0, 28352, 544);
   Weight ("blk.2.attn_output.weight", 32, 32, G.Type_Q8_0, 28896, 1088);
   Weight ("blk.2.ffn_gate.weight", 32, 64, G.Type_Q8_0, 29984, 2176);
   Weight ("blk.2.ffn_up.weight", 32, 64, G.Type_Q8_0, 32160, 2176);
   Weight ("blk.2.ffn_down.weight", 64, 32, G.Type_Q8_0, 34336, 2176);
   Weight ("blk.2.ctx_mix.weight", 4, 1, G.Type_F32, 36512, 16);
   Weight ("blk.2.ctx_norm.weight", 32, 1, G.Type_F32, 36528, 128);
   Weight ("blk.2.attn_k_ctx.weight", 32, 16, G.Type_Q8_0, 36656, 544);
   Weight ("blk.2.attn_v_ctx.weight", 32, 16, G.Type_Q8_0, 37200, 544);
   Weight ("blk.2.attn_k_ctx_norm.weight", 16, 1, G.Type_F32, 37744, 64);
   Fixtures.Build (Builder, Result);
end Build_DSpark;
