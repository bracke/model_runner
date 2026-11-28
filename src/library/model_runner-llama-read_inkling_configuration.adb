separate (Model_Runner.Llama)
procedure Read_Inkling_Configuration
  (Source   : Containers.Container;
   Bounds   : Model_Runner.Limits.Model_Limits;
   Settings : out Configuration;
   Status   : out E.Error_Info)
is
   use type Model_Runner.GGUF.Value_Type;
   Prefix : constant String := "inkling2_loop.";
   Number : Long_Long_Integer;
   Float  : Wide_Real;
   Count  : Natural;
   Varying : Boolean := False;

   procedure Invalid (Key : String) is
   begin
      Status := E.Make (E.Arch_Invalid_Metadata);
      E.Add_Text (Status, "key", Prefix & Key, E.Param_Identifier);
   end Invalid;

   procedure Whole
     (Key : String; Maximum : Natural; Into : out Natural; Minimum : Natural := 1)
   is
   begin
      Into := 0;
      if E.Is_Error (Status) then
         return;
      end if;
      Containers.Get_Integer
        (Source, Prefix & Key, Long_Long_Integer (Minimum), Long_Long_Integer (Maximum), Number, Status);
      if E.Is_Ok (Status) then
         Into := Natural (Number);
      end if;
   end Whole;

   procedure Real_Key
     (Key : String; Into : out Real; Minimum : Wide_Real := 1.0E-20;
      Maximum : Wide_Real := 1.0E6; Default : Real := -1.0)
   is
   begin
      Into := 0.0;
      if E.Is_Error (Status) then
         return;
      end if;
      if Default >= 0.0 and then not Containers.Has (Source, Prefix & Key) then
         Into := Default;
         return;
      end if;
      Containers.Get_Float (Source, Prefix & Key, Minimum, Maximum, Float, Status);
      if E.Is_Ok (Status) then
         Into := Real (Float);
      end if;
   end Real_Key;

   --  Upstream permits a scalar or a per-layer integer array. This adapter
   --  currently requires uniform widths/heads; heterogeneous arrays fail.
   procedure Uniform (Key : String; Maximum : Natural; Into : out Natural) is
      At_Key : constant Natural := Containers.Find (Source, Prefix & Key);
   begin
      Into := 0;
      if E.Is_Error (Status) then
         return;
      end if;
      if At_Key = 0 or else Containers.Metadata_Kind (Source, At_Key) /= Model_Runner.GGUF.Value_Array then
         Whole (Key, Maximum, Into);
         return;
      end if;
      if not Model_Runner.GGUF.Is_Integer (Containers.Metadata_Element_Kind (Source, At_Key))
        or else Containers.Metadata_Length (Source, At_Key) /= Settings.Layers
      then
         Invalid (Key);
         return;
      end if;
      for Index in 1 .. Settings.Layers loop
         Containers.Get_Integer_Element (Source, Prefix & Key, Index, Number, Status, At_Entry => At_Key);
         if E.Is_Error (Status) then
            return;
         end if;
         if Number < 1 or else Number > Long_Long_Integer (Maximum)
           or else (Index > 1 and then Number /= Long_Long_Integer (Into))
         then
            Invalid (Key);
            return;
         end if;
         Into := Natural (Number);
      end loop;
   end Uniform;
begin
   Settings := (Kind => Inkling2_Loop, others => <>);
   Status := E.Success;
   Whole ("block_count", Natural'Min (Bounds.Max_Layers, Max_Block_Count), Settings.Layers);
   Whole ("context_length", Bounds.Max_Context_Length, Settings.Context_Length);
   Whole ("embedding_length", Bounds.Max_Embedding, Settings.Embedding);
   Uniform ("attention.head_count", Bounds.Max_Heads, Settings.Heads);
   Uniform ("attention.head_count_kv", Bounds.Max_Heads, Settings.KV_Heads);
   Whole ("attention.key_length", Bounds.Max_Embedding, Settings.Head_Size);
   Whole ("attention.value_length", Bounds.Max_Embedding, Settings.Value_Size);
   Whole ("expert_count", Bounds.Max_Experts, Settings.Experts);
   Whole ("expert_used_count", Bounds.Max_Experts, Settings.Experts_Used);
   Uniform ("expert_feed_forward_length", Natural'Min (Bounds.Max_Embedding, Natural'Last / 16) * 16,
            Settings.Expert_Feed);
   Whole ("feed_forward_length", Natural'Min (Bounds.Max_Embedding, Natural'Last / 16) * 16,
          Settings.Feed_Forward);
   Whole ("vocab_size", Bounds.Max_Vocabulary, Settings.Inkling.Padded_Vocabulary);
   Whole ("vocab_size_unpadded", Bounds.Max_Vocabulary, Settings.Vocabulary);
   Whole ("attention.sliding_window", Bounds.Max_Context_Length, Settings.Window);
   Whole ("attn_res.block_size", Max_Block_Count, Settings.Inkling.Block_Size);
   Whole ("loop.start", Max_Block_Count, Settings.Inkling.First_Layer);
   Whole ("loop.end", Max_Block_Count, Settings.Inkling.End_Layer);
   Whole ("loop.count", Max_Block_Count, Settings.Inkling.Iterations);
   Whole ("loop.gate_rank", Bounds.Max_Embedding, Settings.Inkling.Gate_Rank);
   Whole ("attention.relative_length", Bounds.Max_Embedding, Settings.Inkling.Relative_Width);
   Whole ("attention.relative_extent", Bounds.Max_Context_Length, Settings.Inkling.Relative_Extent);
   Whole ("shortconv.l_cache", 64, Settings.Inkling.Convolution_Length, 2);
   Whole ("attention.log_scale_floor", Bounds.Max_Context_Length, Settings.Inkling.Log_Scale_Floor);
   Real_Key ("attention.layer_norm_rms_epsilon", Settings.Epsilon, Maximum => 1.0);
   Real_Key ("attention.qk_clip", Settings.Inkling.QK_Clip);
   Real_Key ("attention.relative_clip", Settings.Inkling.Relative_Clip);
   Real_Key ("attention.log_scale_alpha", Settings.Inkling.Log_Scale_Alpha, Minimum => 0.0);
   Real_Key ("activation.situ_beta", Settings.Inkling.Gate_Softcap);
   Real_Key ("activation.situ_linear_beta", Settings.Inkling.Up_Softcap);
   Real_Key ("expert_weights_scale", Settings.Expert_Scale, Minimum => 0.0, Default => 1.0);
   Real_Key ("final_logit_softcapping", Settings.Logit_Cap, Minimum => 0.0, Default => 0.0);
   if E.Is_Error (Status) then
      return;
   end if;
   if Containers.Has (Source, Prefix & "loop.varying") then
      Containers.Get_Boolean (Source, Prefix & "loop.varying", Varying, Status);
      if E.Is_Error (Status) then
         return;
      end if;
   end if;
   if Varying then
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", "inkling2_loop.variable_loops", E.Param_Identifier);
      return;
   end if;
   if Settings.Layers /= 24 or else Settings.Inkling.Block_Size /= 6
     or else Settings.Inkling.First_Layer /= 6 or else Settings.Inkling.End_Layer /= 18
     or else Settings.Inkling.Iterations /= 3
   then
      Invalid ("loop.configuration");
      return;
   end if;
   Settings.Inkling.Runtime_Layers := 48;
   if Bounds.Max_Layers < Settings.Inkling.Runtime_Layers then
      Invalid ("loop.state_count");
      return;
   end if;
   if Settings.Heads mod Settings.KV_Heads /= 0 or else Settings.Head_Size /= Settings.Value_Size
     or else Settings.Experts_Used > Settings.Experts
     or else Settings.Vocabulary > Settings.Inkling.Padded_Vocabulary
     or else Settings.Feed_Forward /= Settings.Expert_Feed
   then
      Invalid ("dimensions");
      return;
   end if;
   --  These optional keys, when present, must agree with the decoder's
   --  non-rotary, equal local/global head geometry.
   for Index in 1 .. 3 loop
      declare
         Key : constant String :=
           (case Index is
              when 1 => "rope.dimension_count",
              when 2 => "attention.key_length_swa",
              when others => "attention.value_length_swa");
         Expected : constant Natural := (if Index = 1 then 0 else Settings.Head_Size);
      begin
         if Containers.Has (Source, Prefix & Key) then
            Whole (Key, Bounds.Max_Embedding, Count, 0);
            if E.Is_Error (Status) then
               return;
            end if;
            if Count /= Expected then
               Invalid (Key);
               return;
            end if;
         end if;
      end;
   end loop;
   Containers.Get_Array_Length
     (Source, Prefix & "attention.sliding_window_pattern", Model_Runner.GGUF.Value_Bool, Count, Status);
   if E.Is_Error (Status) then
      return;
   end if;
   if Count /= Settings.Layers then
      Invalid ("attention.sliding_window_pattern");
      return;
   end if;
   for Index in 0 .. Settings.Layers - 1 loop
      Containers.Get_Boolean_Element
        (Source, Prefix & "attention.sliding_window_pattern", Index + 1, Settings.Window_Layers (Index), Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Settings.Window_Layers (Index) /= (Index mod 6 /= 5) then
         Invalid ("attention.sliding_window_pattern");
         return;
      end if;
   end loop;
   Settings.Alternating := True;
   for Index in Settings.Layers .. Settings.Inkling.Runtime_Layers - 1 loop
      Settings.Window_Layers (Index) := Settings.Window_Layers
        (Settings.Inkling.First_Layer + (Index - Settings.Layers)
         mod (Settings.Inkling.End_Layer - Settings.Inkling.First_Layer));
   end loop;
   Containers.Get_Array_Length
     (Source, "tokenizer.ggml.tokens", Model_Runner.GGUF.Value_String, Count, Status);
   if E.Is_Error (Status) then
      return;
   end if;
   if Count /= Settings.Vocabulary then
      Invalid ("vocab_size_unpadded");
      return;
   end if;
   if Settings.Expert_Scale = 0.0 then
      Settings.Expert_Scale := 1.0;
   end if;
   Settings.Group_Size := Settings.Heads / Settings.KV_Heads;
   Settings.Sigmoid_Gate := True;
   Settings.Renormalize_Experts := True;
   Settings.Rotary := 0;
   declare
      Descriptor_Only : Model;
   begin
      Inkling_Tensors (Descriptor_Only, Source, Settings, Load => False, Status => Status);
   end;
end Read_Inkling_Configuration;
