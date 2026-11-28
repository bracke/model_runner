separate (Tiny_Model)
procedure Build_Inkling
  (Result : out Model_Runner.Bytes.Byte_Array_Access;
   Fault : Inkling_Fault := Inkling_Valid;
   Quantized : Boolean := False;
   Room : Positive := 32;
   Uniform_Router : Boolean := False;
   Down_Format : Model_Runner.GGUF.Tensor_Type := Model_Runner.GGUF.Type_Q8_0)
is
   use type Model_Runner.Bytes.Byte_Count;
   Builder : Fixtures.Builder;
   Prefix : constant String := "inkling2_loop.";
   Seed : Interfaces.Unsigned_64 := 123;
   H : constant Natural := (if Quantized or else Fault = Inkling_Aligned_Heads then 32 else 8);
   D : constant Natural := (if Fault = Inkling_Aligned_Heads then 32 else 4);
   Q : constant Natural := (if Uniform_Router then 4 elsif Fault = Inkling_Aligned_Heads then 3 else 2);
   F : constant Natural :=
     (if Down_Format in G.Type_IQ3_S | G.Type_IQ3_XXS then 256 elsif Quantized then 64 else 12);
   E : constant := 4;

   procedure Whole (Key : String; Value : Natural) is
   begin
      Fixtures.Add_U32 (Builder, Prefix & Key, Interfaces.Unsigned_32 (Value));
   end Whole;

   procedure Scalar (Key : String; Value : N.Real) is
   begin
      Fixtures.Add_F32 (Builder, Prefix & Key, Value);
   end Scalar;

   procedure Weight (Name : String; A : Natural; B_Dim : Natural := 1; C_Dim : Natural := 1) is
      Dims : constant Fixtures.Dimension_List :=
        (if C_Dim > 1 then [G.U64 (A), G.U64 (B_Dim), G.U64 (C_Dim)]
         elsif B_Dim > 1 then [G.U64 (A), G.U64 (B_Dim)] else [G.U64 (A)]);
      Count : constant N.Element_Count := N.Element_Count (A) * N.Element_Count (B_Dim) * N.Element_Count (C_Dim);
      Values : N.Real_Array (0 .. Count - 1);
   begin
      if Fault = Inkling_Missing_Tensor and then Name = "blk.6.loop_q_ctrl_forget.weight" then
         return;
      end if;
      Seed := Seed + 7919;
      Values := Fixtures.Sequence (Count, Seed, 0.2);
      if Ada.Strings.Fixed.Index (Name, "norm.weight") > 0
        or else Ada.Strings.Fixed.Index (Name, "clip.weight") > 0
      then
         for Value of Values loop
            Value := 1.0 + Value;
         end loop;
      end if;
      if Fault = Inkling_Zero_Controls
        and then (Ada.Strings.Fixed.Index (Name, "ctrl_gain") > 0
                  or else Ada.Strings.Fixed.Index (Name, "ctrl_forget") > 0)
      then
         Values := [others => 0.0];
      end if;
      if Uniform_Router and then Ada.Strings.Fixed.Index (Name, "ffn_gate_inp") > 0 then
         Values := [others => 0.0];
      end if;
      if Quantized and then A mod 32 = 0 and then B_Dim > 1
        and then Ada.Strings.Fixed.Index (Name, "ffn_gate_inp") = 0
        and then Ada.Strings.Fixed.Index (Name, "res_query") = 0
        and then Ada.Strings.Fixed.Index (Name, "loop_msg_query") = 0
      then
         if Ada.Strings.Fixed.Index (Name, "ffn_down_exps") > 0 then
            case Down_Format is
               when G.Type_IQ4_NL =>
                  Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_IQ4_NL, Fixtures.Encode_IQ4_NL (Values));
               when G.Type_Q2_0 =>
                  Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_Q2_0, Fixtures.Encode_Q2_0 (Values));
               when G.Type_IQ3_S =>
                  Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_IQ3_S, Fixtures.Encode_IQ3_S (Values));
               when G.Type_IQ3_XXS =>
                  Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_IQ3_XXS, Fixtures.Encode_IQ3_XXS (Values));
               when G.Type_Q8_0 =>
                  Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_Q8_0, Fixtures.Encode_Q8_0 (Values));
               when others => raise Constraint_Error with "unsupported synthetic expert down format";
            end case;
         else
            Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_Q8_0, Fixtures.Encode_Q8_0 (Values));
         end if;
      else
         declare
            Payload : Model_Runner.Bytes.Byte_Array := Fixtures.Encode_F32 (Values);
         begin
            if Fault = Inkling_Nonfinite_Weight and then Name = "blk.10.attn_q.weight" then
               --  Inject the IEEE encoding after serialization: Ada validity
               --  checks correctly refuse to assign a NaN to a Real object.
               Payload (Payload'First .. Payload'First + 3) := [0, 0, 16#C0#, 16#7F#];
            end if;
            Fixtures.Add_Tensor (Builder, Name, Dims, G.Type_F32, Payload);
         end;
      end if;
   end Weight;
begin
   Fixtures.Reset (Builder);
   Fixtures.Add_String (Builder, "general.architecture", "inkling2_loop");
   --  Kept second so a non-finite scalar can be injected without doing
   --  arithmetic on an invalid floating-point value in the generator.
   Scalar ("attention.layer_norm_rms_epsilon", 1.0E-6);
   Whole ("block_count", 24);
   Whole ("context_length", Room);
   Whole ("embedding_length", H);
   Whole ("feed_forward_length", F);
   Whole ("expert_feed_forward_length", F);
   Whole ("expert_count", E);
   Whole ("expert_used_count", 2);
   Whole ("attention.key_length", D);
   Whole ("attention.value_length", D);
   Whole ("vocab_size", 20);
   Whole ("vocab_size_unpadded", (if Fault = Inkling_Bad_Vocabulary then 17 else 16));
   Whole ("attention.sliding_window", 4);
   Whole ("attn_res.block_size", 6);
   Whole ("loop.start", 6);
   Whole ("loop.end", 18);
   Whole ("loop.count", (if Fault = Inkling_Wrong_Loops then 4 else 3));
   Whole ("loop.gate_rank", 2);
   Whole ("attention.relative_length", 2);
   Whole ("attention.relative_extent", 4);
   Whole ("shortconv.l_cache", 4);
   Whole ("attention.log_scale_floor", 8);
   Whole ("rope.dimension_count", 0);
   if Fault = Inkling_Wrong_Parameter_Type then
      Fixtures.Add_String (Builder, Prefix & "attention.qk_clip", "4");
   elsif Fault /= Inkling_Missing_Parameter then
      Scalar ("attention.qk_clip", 4.0);
   end if;
   Scalar ("attention.relative_clip", 2.0);
   Scalar ("attention.log_scale_alpha", 0.1);
   Scalar ("activation.situ_beta", (if Fault = Inkling_Alternate_Softcap then 8.0 else 4.0));
   Scalar ("activation.situ_linear_beta", 25.0);
   if Fault /= Inkling_Omitted_Optionals then
      Scalar ("expert_weights_scale", 2.0);
      Scalar ("final_logit_softcapping", 30.0);
      Fixtures.Add_Bool (Builder, Prefix & "loop.varying", Fault = Inkling_Variable_Loops);
   end if;
   for Which in 1 .. 2 loop
      Fixtures.Begin_Array
        (Builder, Prefix & (if Which = 1 then "attention.head_count" else "attention.head_count_kv"),
         G.Value_Int32, 24);
      for Index in 1 .. 24 loop
         Fixtures.Int32_Element
           (Builder, (if Which = 2 then 1
                      elsif Fault = Inkling_Heterogeneous_Heads and then Index = 24 then 3
                      else Interfaces.Integer_32 (Q)));
      end loop;
      Fixtures.End_Array (Builder);
   end loop;
   declare
      Length : constant Natural := (if Fault = Inkling_Bad_Pattern then 23 else 24);
   begin
      Fixtures.Begin_Array (Builder, Prefix & "attention.sliding_window_pattern", G.Value_Bool, Length);
      for Index in 0 .. Length - 1 loop
         Fixtures.Bool_Element (Builder, Index mod 6 /= 5);
      end loop;
      Fixtures.End_Array (Builder);
   end;
   Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 1);
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 2);
   Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
   Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_bos_token", False);
   Fixtures.Begin_Array (Builder, "tokenizer.ggml.tokens", G.Value_String, 16);
   Fixtures.String_Element (Builder, "<unk>");
   Fixtures.String_Element (Builder, "<s>");
   Fixtures.String_Element (Builder, "</s>");
   for Index in 3 .. 15 loop
      Fixtures.String_Element (Builder, String'(1 => Character'Val (Character'Pos ('a') + Index - 3)));
   end loop;
   Fixtures.End_Array (Builder);
   Fixtures.Begin_Array (Builder, "tokenizer.ggml.scores", G.Value_Float32, 16);
   for Index in 0 .. 15 loop
      Fixtures.Float_Element (Builder, 0.0);
   end loop;
   Fixtures.End_Array (Builder);
   Fixtures.Begin_Array (Builder, "tokenizer.ggml.token_type", G.Value_Int32, 16);
   for Index in 0 .. 15 loop
      Fixtures.Int32_Element (Builder, (if Index = 0 then 2 elsif Index < 3 then 3 else 1));
   end loop;
   Fixtures.End_Array (Builder);
   Weight ("token_embd.weight", H, 20);
   Weight ("token_embd_norm.weight", H);
   Weight ("output.weight", H, 20);
   Weight ("output_norm.weight", H);
   Weight ("output_res_query.weight", H);
   for Index in 0 .. 23 loop
      declare
         Num : constant String := Ada.Strings.Fixed.Trim (Index'Image, Ada.Strings.Both);
         Stem : constant String := "blk." & Num & ".";
         procedure W (Name : String; A : Natural; B : Natural := 1; C : Natural := 1) is
         begin
            Weight (Stem & Name & ".weight", A, B, C);
         end W;
      begin
         W ("attn_q", H, Q * D); W ("attn_k", H, D); W ("attn_v", H, D);
         W ("attn_output", Q * D, H); W ("attn_gate", H, Q * D);
         W ("attn_q_clip", D, Q); W ("attn_sink_proj", H, Q);
         W ("attn_rel", H, 2 * Q); W ("attn_rel_bias", 2, 4); W ("attn_rel_clip", 2, Q);
         W ("attn_k_conv", 4, D); W ("attn_v_conv", 4, D);
         W ("attn_post_conv", 4, H); W ("ffn_post_conv", 4, H);
         if Index mod 6 = 5 then
            W ("attn_q_inp_norm", H); W ("attn_k_inp_norm", H); W ("attn_v_inp_norm", H);
            W ("attn_k_conv_proj", H, 4); W ("attn_v_conv_proj", H, 4);
         else
            W ("attn_norm", H);
         end if;
         if Index > 0 then
            W ("attn_res_query", H, (if Index mod 6 = 5 then 3 else 1));
         end if;
         W ("ffn_res_query", H); W ("ffn_norm", H); W ("ffn_gate_inp", H, E);
         Weight (Stem & "exp_probs_b.bias", E);
         W ("ffn_gate_up_exps", H, 2 * F, E);
         W ("ffn_down_exps", F, H,
            (if Fault = Inkling_Wrong_Expert_Shape and then Index = 0 then E + 1 else E));
         if Index in 6 .. 17 then
            W ("loop_msg_query", H, 4);
            for Channel in 1 .. 4 loop
               declare
                  Name : constant String :=
                    (case Channel is when 1 => "q", when 2 => "k", when 3 => "v", when others => "ffn");
               begin
                  W ("loop_" & Name & "_ctrl_down", 2 * H, 2);
                  W ("loop_" & Name & "_ctrl_gain", 2, H);
                  W ("loop_" & Name & "_ctrl_forget", 2, H);
               end;
            end loop;
         end if;
      end;
   end loop;
   if Fault = Inkling_Extra_Tensor then
      Weight ("vision.unimplemented.weight", 1);
   end if;
   Fixtures.Build (Builder, Result);
   if Fault = Inkling_Nonfinite_Parameter then
      Fixtures.Poke_U32
        (Result.all, Fixtures.Field_Position (Builder, Fixtures.Metadata_Value_Type, 2) + 4, 16#7FC0_0000#);
   end if;
end Build_Inkling;
