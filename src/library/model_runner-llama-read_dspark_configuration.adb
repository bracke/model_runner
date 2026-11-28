separate (Model_Runner.Llama)
procedure Read_DSpark_Configuration
  (Source : Containers.Container; Bounds : Model_Runner.Limits.Model_Limits;
   Settings : out Configuration; Status : out E.Error_Info)
is
   Prefix : constant String := "dflash.";
   Number : Long_Long_Integer;
   Value : Wide_Real;
   Count : Natural;

   procedure Invalid (Key : String) is
   begin
      Status := E.Make (E.Arch_Invalid_Metadata);
      E.Add_Text (Status, "key", Prefix & Key, E.Param_Identifier);
   end Invalid;

   procedure Whole (Key : String; Maximum : Natural; Into : out Natural) is
   begin
      Into := 0;
      if E.Is_Error (Status) then return; end if;
      Containers.Get_Integer (Source, Prefix & Key, 1, Long_Long_Integer (Maximum), Number, Status);
      if E.Is_Ok (Status) then Into := Natural (Number); end if;
   end Whole;

   procedure Float_Key (Key : String; Into : out Real) is
   begin
      Into := 0.0;
      if E.Is_Error (Status) then return; end if;
      Containers.Get_Float (Source, Prefix & Key, 1.0E-20, 1.0E7, Value, Status);
      if E.Is_Ok (Status) then Into := Real (Value); end if;
   end Float_Key;

   procedure Flag (Key : String; Expected : Boolean) is
      Actual : Boolean;
   begin
      if E.Is_Error (Status) then return; end if;
      Containers.Get_Boolean (Source, Prefix & Key, Actual, Status);
      if E.Is_Ok (Status) and then Actual /= Expected then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", Prefix & Key, E.Param_Identifier);
      end if;
   end Flag;
begin
   Settings := (Kind => DFlash, others => <>);
   Status := E.Success;
   Whole ("block_count", Natural'Min (Bounds.Max_Layers, 3), Settings.Layers);
   Whole ("context_length", Bounds.Max_Context_Length, Settings.Context_Length);
   Whole ("embedding_length", Bounds.Max_Embedding, Settings.Embedding);
   Whole ("feed_forward_length", Natural'Min (Bounds.Max_Embedding, Natural'Last / 16) * 16,
          Settings.Feed_Forward);
   Whole ("attention.head_count", Bounds.Max_Heads, Settings.Heads);
   Whole ("attention.head_count_kv", Bounds.Max_Heads, Settings.KV_Heads);
   Whole ("attention.key_length", Bounds.Max_Embedding, Settings.Head_Size);
   Whole ("attention.value_length", Bounds.Max_Embedding, Settings.Value_Size);
   Whole ("rope.dimension_count", Bounds.Max_Embedding, Settings.Rotary);
   Whole ("attention.sliding_window", Bounds.Max_Context_Length, Settings.Window);
   Whole ("block_size", 8, Settings.DSpark.Block_Size);
   Float_Key ("attention.layer_norm_rms_epsilon", Settings.Epsilon);
   Float_Key ("final_logit_softcapping", Settings.Logit_Cap);
   if E.Is_Error (Status) then return; end if;
   Containers.Get_Float (Source, Prefix & "rope.freq_base", 1.0, 1.0E12, Value, Status);
   if E.Is_Error (Status) then return; end if;
   Settings.Rope_Base := Value;
   Flag ("sample_from_anchor", False);
   Flag ("has_confidence_head", False);
   Flag ("has_markov_context", True);
   if E.Is_Error (Status) then return; end if;
   if Settings.Layers /= 3 or else Settings.DSpark.Block_Size /= 8
     or else Settings.Heads mod Settings.KV_Heads /= 0
     or else Settings.Head_Size /= Settings.Value_Size
     or else Settings.Rotary /= Settings.Head_Size or else Settings.Rotary mod 2 /= 0
     or else Settings.Embedding > Natural'Last / 4
     or else Settings.Heads > Natural'Last / Settings.Head_Size
     or else Settings.Window /= 1025 or else Settings.Logit_Cap /= 30.0
   then
      Invalid ("configuration"); return;
   end if;
   if Containers.Has (Source, Prefix & "rope.scaling.type")
     or else Containers.Has (Source, Prefix & "rope.dimension_sections")
     or else Containers.Has (Source, Prefix & "attention.q_lora_rank")
     or else Containers.Has (Source, Prefix & "attention.kv_lora_rank")
   then
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", "dflash.backbone_variant", E.Param_Identifier);
      return;
   end if;
   Settings.Pairing := K.Split;
   Settings.Group_Size := Settings.Heads / Settings.KV_Heads;
   Settings.Causal := False;
   Settings.Alternating := True;
   declare
      At_Key : constant Natural := Containers.Find (Source, Prefix & "target_layers");
   begin
      if At_Key = 0 then Invalid ("target_layers"); return; end if;
      if not Model_Runner.GGUF.Is_Integer (Containers.Metadata_Element_Kind (Source, At_Key)) then
         Invalid ("target_layers"); return;
      end if;
      Count := Containers.Metadata_Length (Source, At_Key);
   end;
   if Count /= 4 then Invalid ("target_layers"); return; end if;
   for Index in Settings.DSpark.Target_Layers'Range loop
      Containers.Get_Integer_Element (Source, Prefix & "target_layers", Index, Number, Status);
      if E.Is_Error (Status) then return; end if;
      if Number /= Long_Long_Integer (Settings.DSpark.Target_Layers (Index)) then
         Invalid ("target_layers"); return;
      end if;
   end loop;
   Containers.Get_Array_Length
     (Source, Prefix & "attention.sliding_window_pattern", Model_Runner.GGUF.Value_Bool, Count, Status);
   if E.Is_Error (Status) then return; end if;
   if Count /= 3 then Invalid ("attention.sliding_window_pattern"); return; end if;
   for Index in 0 .. 2 loop
      Containers.Get_Boolean_Element
        (Source, Prefix & "attention.sliding_window_pattern", Index + 1, Settings.Window_Layers (Index), Status);
      if E.Is_Error (Status) then return; end if;
      if Settings.Window_Layers (Index) /= (Index /= 1) then
         Invalid ("attention.sliding_window_pattern"); return;
      end if;
   end loop;
   Containers.Get_Array_Length
     (Source, "tokenizer.ggml.tokens", Model_Runner.GGUF.Value_String, Settings.Vocabulary, Status);
   if E.Is_Error (Status) then return; end if;
   if Settings.Vocabulary = 0 or else Settings.Vocabulary > Bounds.Max_Vocabulary then
      Invalid ("vocabulary"); return;
   end if;
   declare
      At_W1 : constant Natural := Containers.Find_Tensor (Source, "markov_w1.weight");
      Rank : Interfaces.Unsigned_64;
      Descriptor : Model;
   begin
      if At_W1 = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", "markov_w1.weight", E.Param_Identifier);
         return;
      end if;
      Rank := Containers.Tensor_Dimension (Source, At_W1, 1);
      if Rank = 0 or else Rank > Interfaces.Unsigned_64 (Bounds.Max_Embedding)
        or else Rank > Interfaces.Unsigned_64 (Natural'Last / 6)
      then Invalid ("markov_rank"); return; end if;
      Settings.DSpark.Markov_Rank := Natural (Rank);
      DSpark_Tensors (Descriptor, Source, Settings, Load => False, Status => Status);
   end;
end Read_DSpark_Configuration;
