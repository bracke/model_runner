separate (Model_Runner.Llama)
procedure Read_Configuration
  (Source   : Containers.Container;
   Bounds   : Model_Runner.Limits.Model_Limits;
   Settings : out Configuration;
   Status   : out E.Error_Info)
is
   Number : Long_Long_Integer;
   Value  : N.Wide_Real;

   --  How many shared experts the file states, which DeepSeek2 gives
   --  their width by.
   Shared_Count : Natural := 0;
   Local  : E.Error_Info;

   --  Read a required positive integer key.
   procedure Required
     (Key     : String;
      Maximum : Long_Long_Integer;
      Target  : out Natural) is
   begin
      Target := 0;
      Containers.Get_Integer (Source, Key, 1, Maximum, Number, Status);
      if E.Is_Ok (Status) then
         Target := Natural (Number);
      end if;
   end Required;

   --  Report whether a key was present and could not be used.
   --
   --  An optional key that is absent is not an error: the model does not
   --  say, and the profile falls back to its default. A key that is there
   --  and is the wrong type, or names a value outside the accepted range,
   --  is the file being wrong about the model it describes. Falling back
   --  then would build a model of a different shape than the file states
   --  and say nothing about it.
   function Present_And_Wrong (Item : E.Error_Info) return Boolean
   is (E.Is_Error (Item)
       and then Item.Code /= E.GGUF_Missing_Metadata_Key);

   --  Report an unsupported feature the file asked for.
   procedure Reject_Feature (Feature : String) is
   begin
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", Feature, E.Param_Identifier);
   end Reject_Feature;

begin
   Settings := (others => <>);

   declare
      Name  : constant String :=
        Containers.String_Value (Source, "general.architecture");
      Found : Boolean := False;
   begin
      if Name = "" then
         Status := E.Make (E.Arch_Missing_Identifier);
         return;
      end if;

      --  Matched against the architectures this profile reads. Nothing is
      --  inferred: a file says what it is, and one that says something
      --  else is refused by name rather than read as though it were the
      --  shape this happens to implement.
      for Kind in Architecture loop
         if Architecture_Name (Kind) = Name then
            Settings.Kind := Kind;

            --  How the weights of this architecture were laid out for
            --  rotation. Llama interleaves the pairs; Qwen2 splits the
            --  head in half. Same rotation, different elements, and the
            --  wrong one reads as a model that has lost the thread.
            Settings.Pairing :=
              (case Kind is
                 --  DeepSeek2 is llama.cpp's "normal" rotation as Llama
                 --  is: read split, DeepSeek-Coder-V2-Lite answered in
                 --  scraps of four languages.
                 when Llama | Granite | Granite_MoE | Glm4 | Internlm2
                    | Baichuan | Chatglm | Command_R | Deepseek2 =>
                   K.Interleaved,
                 when Qwen2 | Qwen3 | Qwen3_MoE | GPT_OSS | Gemma | Gemma2
                    | Gemma3 | Phi3 | Falcon | Phi2 | GPT2 | Bert
                    | Nomic_Bert | Jina_Bert_V2 | Qwen35 | Qwen35_MoE
                    | Olmo2 | Starcoder2 | Stablelm | Gptneox | Mpt | Mamba
                    | Mamba2 | Rwkv6 | Jamba =>
                   K.Split);

            --  What a position may see. Every architecture here
            --  generates, and a generated token cannot depend on one
            --  that does not exist yet -- except Bert, which does not
            --  generate at all: it reads a text that is already whole
            --  and every position of it may see every other.
            Settings.Causal := not Normalizes_After (Kind);

            --  And whether it can turn a state into a distribution at
            --  all. Decided here rather than where the output projection
            --  is resolved, because it is a fact about the architecture
            --  and `inspect` reports what a file says without resolving
            --  a tensor: read from the resolution, it said every model
            --  had a head, including the one that has none.
            Settings.Has_Head := not Normalizes_After (Kind);
            Found := True;
         end if;
      end loop;

      if not Found then
         --  What this build does read, listed from the enumeration rather
         --  than written out. It named one architecture while reading
         --  four, which is the kind of message that sends somebody
         --  looking for a build that does not exist.
         declare
            Known : String (1 .. 128) := [others => ' '];
            Last  : Natural := 0;

            procedure Append (Text : String) is
            begin
               if Last + Text'Length <= Known'Last then
                  Known (Last + 1 .. Last + Text'Length) := Text;
                  Last := Last + Text'Length;
               end if;
            end Append;
         begin
            for Kind in Architecture loop
               if Last > 0 then
                  Append (" ");
               end if;
               Append (Architecture_Name (Kind));
            end loop;

            Status := E.Make (E.Arch_Unsupported);
            E.Add_Text (Status, "architecture", Name, E.Param_Identifier);
            E.Add_Text
              (Status, "supported", Known (1 .. Last), E.Param_Text);
         end;
         return;
      end if;
   end;

   Required (Model_Key (Settings.Kind, "context_length"),
             Long_Long_Integer (Bounds.Max_Context_Length),
             Settings.Context_Length);
   if E.Is_Error (Status) then
      return;
   end if;

   Required (Model_Key (Settings.Kind, "embedding_length"),
             Long_Long_Integer (Bounds.Max_Embedding), Settings.Embedding);
   if E.Is_Error (Status) then
      return;
   end if;

   Required (Model_Key (Settings.Kind, "block_count"),
             Long_Long_Integer (Bounds.Max_Layers), Settings.Layers);
   if E.Is_Error (Status) then
      return;
   end if;

   --  A hybrid mixture states no dense width at all -- its experts'
   --  and its shared expert's widths are stated under their own keys
   --  below -- so the key is required of every architecture but that.
   if Settings.Kind = Qwen35_MoE
     and then not Containers.Has
                    (Source, Model_Key (Settings.Kind, "feed_forward_length"))
   then
      Settings.Feed_Forward := 0;
   elsif Pure_SSM (Settings.Kind) then
      --  A pure state-space model has no feed-forward and no attention,
      --  and the files llama.cpp's converter writes say so with a
      --  nought for each: Mamba-2.8B and Mamba2-130M state
      --  feed_forward_length 0 and attention.head_count 0. Both are taken
      --  as they are -- the width is nought -- and the head count, which
      --  only the attention's bookkeeping reads, is held at one.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "feed_forward_length"),
         0, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Settings.Feed_Forward := Natural (Number);
   else
      Required (Model_Key (Settings.Kind, "feed_forward_length"),
                Long_Long_Integer (Bounds.Max_Embedding) * 64,
                Settings.Feed_Forward);
      if E.Is_Error (Status) then
         return;
      end if;
   end if;

   --  RWKV6 states nought heads as well: its heads are its wkv.head_size,
   --  read below, and the attention's count is bookkeeping alone.
   if Pure_SSM (Settings.Kind) or else Is_RWKV (Settings.Kind) then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.head_count"),
         0, Long_Long_Integer (Bounds.Max_Heads), Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Settings.Heads := Natural'Max (1, Natural (Number));
   else
      Required (Model_Key (Settings.Kind, "attention.head_count"),
                Long_Long_Integer (Bounds.Max_Heads), Settings.Heads);
      if E.Is_Error (Status) then
         return;
      end if;
   end if;

   --  Jamba states its key-value head count a layer, nought where the
   --  layer keeps a Mamba state and the attention count where it attends,
   --  which is how the file says which layers are which. Read as the
   --  array it is: a nought marks a Mamba layer, and any non-nought is
   --  the count the attention layers share. Every other architecture
   --  states one number for the whole model.
   if Is_Jamba (Settings.Kind) then
      if Settings.Layers > Max_Block_Count then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "block_count", Long_Long_Integer (Settings.Layers));
         return;
      end if;

      Settings.KV_Heads := Settings.Heads;
      declare
         Length : Natural := 0;
         Probe  : E.Error_Info;
      begin
         Containers.Get_Array_Length
           (Source, Model_Key (Settings.Kind, "attention.head_count_kv"),
            Model_Runner.GGUF.Value_Int32, Length, Probe);

         if E.Is_Ok (Probe) and then Length >= Settings.Layers then
            --  The per-layer array a real file states: nought heads a
            --  Mamba layer, the attention count where it attends.
            for Layer in 0 .. Settings.Layers - 1 loop
               Containers.Get_Integer_Element
                 (Source,
                  Model_Key (Settings.Kind, "attention.head_count_kv"),
                  Layer + 1, Number, Local);
               if E.Is_Error (Local) then
                  Status := E.Make (E.GGUF_Missing_Metadata_Key);
                  E.Add_Text
                    (Status, "key",
                     Model_Key (Settings.Kind, "attention.head_count_kv"),
                     E.Param_Identifier);
                  return;
               end if;
               Settings.Mamba_Layer (Layer) := Number = 0;
               if Number /= 0 then
                  Settings.KV_Heads := Natural (Number);
               end if;
            end loop;

         else
            --  A file stating one number, or none, has no Mamba layers
            --  by that account: every layer attends. A minimal fixture
            --  that only checks the keys load takes this road.
            Containers.Get_Integer
              (Source,
               Model_Key (Settings.Kind, "attention.head_count_kv"), 1,
               Long_Long_Integer (Settings.Heads), Number, Local);
            if E.Is_Ok (Local) then
               Settings.KV_Heads := Natural (Number);
            end if;
            Settings.Mamba_Layer := [others => False];
         end if;
      end;

   else
      --  Key-value head count is optional; a model that omits it is
      --  multi-head rather than grouped-query.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.head_count_kv"), 1,
         Long_Long_Integer (Settings.Heads), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.KV_Heads :=
        (if E.Is_Ok (Local) then Natural (Number) else Settings.Heads);
   end if;

   --  The floor under a normalization's divisor. An architecture that
   --  normalizes by root mean square states it under one key and Bert,
   --  which centres, states it under another -- the same quantity in the
   --  same units, named for the normalization it belongs to. Bert is
   --  asked for its own key and falls back to the other, so a file that
   --  states either is read and a file that states neither takes the
   --  default both would.
   if Normalizes_After (Settings.Kind)
     or else Settings.Kind
               in Starcoder2 | Stablelm | Gptneox | Mpt | Command_R | Rwkv6
   then
      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attention.layer_norm_epsilon"),
         0.0, 1.0, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
   end if;

   if not Normalizes_After (Settings.Kind) or else E.Is_Error (Local) then
      Containers.Get_Float
        (Source,
         Model_Key (Settings.Kind, "attention.layer_norm_rms_epsilon"),
         0.0, 1.0, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
   end if;
   Settings.Epsilon :=
     (if E.Is_Ok (Local) then N.Real (Value) else 1.0E-5);

   --  Whether the two halves of the block run side by side. GPT-NeoX
   --  states it and defaults to on where the key is absent, which is
   --  what its published files leave to the reader; every other
   --  architecture runs them one after the other.
   if Settings.Kind = Gptneox then
      declare
         Parallel : Boolean;
      begin
         Containers.Get_Boolean
           (Source, Model_Key (Settings.Kind, "use_parallel_residual"),
            Parallel, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Parallel_Residual :=
           (if E.Is_Ok (Local) then Parallel else True);
      end;
   end if;

   --  What the file says its states should be pooled with. Read for the
   --  architecture that states it and left unstated for the rest, which
   --  is not the same as none: a model that says nothing about pooling
   --  has not asked for one, and a model that says none has.
   --
   --  Ranked pooling is a fourth value some files carry. It does not
   --  reduce a text to a vector -- it scores one, through a head the
   --  model carries beside its blocks: the first position's state through
   --  a dense layer and a logistic, then a row down to a single number.
   if Normalizes_After (Settings.Kind) then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "pooling_type"), 0, 4, Number,
         Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;

      if E.Is_Ok (Local) then
         case Number is
            when 0 => Settings.Pooling := Pool_None;
            when 1 => Settings.Pooling := Pool_Mean;
            when 2 => Settings.Pooling := Pool_Cls;
            when 3 => Settings.Pooling := Pool_Last;
            when others => Settings.Pooling := Pool_Rank;
         end case;
      end if;

      --  A row for each segment a token may belong to. The architecture
      --  states two and the shape is checked against that where the
      --  tensor is resolved; a text embedded here is all one segment, so
      --  only the first row is ever read, and the second is required
      --  because a file that has not got it is not the model this
      --  computes.
      declare
         Idx : constant Natural :=
           Containers.Find_Tensor (Source, "token_types.weight");
      begin
         if Idx /= 0 then
            --  As many segment rows as the file carries: two for BERT,
            --  one for the RoBERTa family, which drops the segment
            --  embedding. Only the first row is ever read -- a text
            --  embedded here is all one segment -- so the count is read
            --  from the file rather than assumed, and a reranker built on
            --  RoBERTa (bge-reranker among them) is no longer refused for
            --  carrying one row where a BERT carries two.
            Settings.Segments :=
              (if Containers.Tensor_Rank (Source, Idx) >= 2
               then Natural (Containers.Tensor_Dimension (Source, Idx, 2))
               else 1);
         end if;
      end;
   end if;

   Containers.Get_Float
     (Source, Model_Key (Settings.Kind, "rope.freq_base"), 1.0, 1.0E12, Value, Local);
   if Present_And_Wrong (Local) then
      Status := Local;
      return;
   end if;
   Settings.Rope_Base := (if E.Is_Ok (Local) then Value else 10_000.0);

   --  Rotary scaling. A model that says nothing rotates as it was
   --  trained; "linear" divides every position by the factor; "yarn"
   --  divides the low frequencies and leaves the high ones alone;
   --  "llama3" eases across three bands. "longrope" (Phi-3's, sometimes
   --  named "su") carries the stretch in two per-dimension factor tables,
   --  read below and applied as any factor table is, so the name only has
   --  to be let through here. Any other name -- "dynamic" among them --
   --  changes the position mapping in a way this does not compute, and
   --  running it as though it did would produce a model that reads its own
   --  context wrongly at long range and says nothing about it.
   declare
      Named : constant String :=
        Containers.String_Value
          (Source, Model_Key (Settings.Kind, "rope.scaling.type"));
   begin
      if Named /= "" and then Named /= "none" and then Named /= "linear"
        and then Named /= "yarn" and then Named /= "llama3"
        and then Named /= "longrope" and then Named /= "su"
      then
         Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
         E.Add_Text (Status, "scaling", Named, E.Param_Identifier);
         return;

      --  LongRoPE is its two factor tables and nothing else, so a file
      --  that names it without carrying them has no stretch to apply and
      --  would read as unscaled: refused rather than run wrongly at range.
      elsif (Named = "longrope" or else Named = "su")
        and then Containers.Find_Tensor
                   (Source, "rope_factors_long.weight") = 0
        and then Containers.Find_Tensor
                   (Source, "rope_factors_short.weight") = 0
      then
         Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
         E.Add_Text (Status, "scaling", Named, E.Param_Identifier);
         return;
      end if;

      --  LongRoPE -- two tables of per-dimension factors, the long one
      --  or the short chosen by the context the model is opened at --
      --  is read below, where the rotation's factors are, and applied
      --  as any other per-dimension factor table is.

      Settings.Scaling.Kind :=
        (if Named = "yarn" then K.Yarn
         elsif Named = "linear" then K.Linear
         else K.Unscaled);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.factor"), 0.0,
         1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) and then Value > 0.0 then
         Settings.Scaling.Frequency := 1.0 / Value;

         --  A factor with no name is the linear stretch, which is what
         --  the key meant before there was more than one kind of it.
         if Named = "" and then Value /= 1.0 then
            Settings.Scaling.Kind := K.Linear;
         end if;
      end if;
   end;

   --  Llama 3 and LongRoPE both stretch from the context the model was
   --  trained on, read here for whichever uses it.
   Containers.Get_Integer
     (Source,
      Model_Key (Settings.Kind, "rope.scaling.original_context_length"),
      1, Long_Long_Integer (Bounds.Max_Context_Length), Number, Local);
   if Present_And_Wrong (Local) then
      Status := Local;
      return;
   end if;
   if E.Is_Ok (Local) then
      Settings.Rope_Original := Natural (Number);
   end if;

   --  Llama 3's rotary scaling: the scale factor and the band it eases
   --  across, worked into per-dimension divisors where the factors are
   --  read. The scalar stretch is set aside; the divisors carry it.
   if Containers.String_Value
        (Source, Model_Key (Settings.Kind, "rope.scaling.type")) = "llama3"
   then
      Settings.Rope_Llama3 := True;
      if Settings.Scaling.Frequency > 0.0 then
         Settings.Rope_Llama3_Factor :=
           Real (1.0 / Settings.Scaling.Frequency);
      end if;
      Settings.Scaling.Frequency := 1.0;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.low_freq_factor"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) and then Value > 0.0 then
         Settings.Rope_Llama3_Low := Real (Value);
      end if;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.high_freq_factor"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) and then Value > 0.0 then
         Settings.Rope_Llama3_High := Real (Value);
      end if;
   end if;

   --  A model carrying LongRoPE's factor tables lets the tables do the
   --  whole stretch, so no scalar factor is applied beside them.
   if Containers.Find_Tensor (Source, "rope_factors_long.weight") /= 0
     or else Containers.Find_Tensor
               (Source, "rope_factors_short.weight") /= 0
   then
      Settings.Scaling.Frequency := 1.0;
      Settings.Scaling.Kind := K.Unscaled;
   end if;

   --  What the ramp is derived from, which only Yarn reads. The context
   --  the model was trained on is the default for the context it was
   --  trained on, so a file that omits it is saying the two are the same.
   if K."=" (Settings.Scaling.Kind, K.Yarn) then
      Containers.Get_Integer
        (Source,
         Model_Key (Settings.Kind, "rope.scaling.original_context_length"),
         1, Long_Long_Integer (Bounds.Max_Context_Length), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Scaling.Original :=
        (if E.Is_Ok (Local)
         then Natural (Number)
         else Settings.Context_Length);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.attn_factor"),
         0.0, 1.0E3, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) then
         Settings.Scaling.Attenuation := Value;
      end if;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.beta_fast"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) and then Value > 0.0 then
         Settings.Scaling.Beta_Fast := Value;
      end if;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.scaling.beta_slow"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      if E.Is_Ok (Local) and then Value > 0.0 then
         Settings.Scaling.Beta_Slow := Value;
      end if;
   end if;

   --  DeepSeek2 under YaRN, as llama.cpp reads it: the rotation keeps the
   --  magnitude the file states (one where it states none) rather than
   --  YaRN's own one-plus-a-tenth-of-the-log, and the scores take the
   --  square of mscale instead, mscale being one plus the file's
   --  yarn_log_multiplier times the log of the stretch. Applied to the
   --  rotated part alone, YaRN's magnitude weighted the sixty-four
   --  rotated dimensions of each key 1.87 times against its 128 plain
   --  ones, and DeepSeek-Coder-V2-Lite answered with nothing a reader
   --  could follow.
   if Settings.Kind = Deepseek2
     and then K."=" (Settings.Scaling.Kind, K.Yarn)
     and then Settings.Scaling.Frequency > 0.0
     and then Settings.Scaling.Frequency < 1.0
   then
      declare
         Stretch : constant N.Wide_Real :=
           N.Log (1.0 / Settings.Scaling.Frequency);
         Log_Mul : N.Wide_Real := 0.0;
      begin
         Containers.Get_Float
           (Source,
            Model_Key (Settings.Kind, "rope.scaling.yarn_log_multiplier"),
            0.0, 1.0E3, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) then
            Log_Mul := Value;
         end if;

         Settings.Scaling.Attenuation :=
           Settings.Scaling.Attenuation / (1.0 + 0.1 * Stretch);
         Settings.Score_Gain :=
           Real ((1.0 + Log_Mul * Stretch) * (1.0 + Log_Mul * Stretch));
      end;
   end if;

   --  A mixture of experts, when the model names one. The count is what
   --  each layer holds and the used count is how many of them run for one
   --  position; a file naming either names both, because one without the
   --  other describes no model.
   if Containers.Has (Source, Model_Key (Settings.Kind, "expert_count"))
     or else Containers.Has
               (Source, Model_Key (Settings.Kind, "expert_used_count"))
   then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "expert_count"),
         0, Long_Long_Integer (Bounds.Max_Experts), Number, Local);
      if E.Is_Error (Local) then
         Status := Local;
         return;
      end if;
      Settings.Experts := Natural (Number);

      --  A count of zero is a dense model that said so. The used count
      --  then has to say the same thing, since a model cannot run experts
      --  it does not have.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "expert_used_count"),
         (if Settings.Experts = 0 then 0 else 1),
         Long_Long_Integer (Natural'Max (Settings.Experts, 1)),
         Number, Local);
      if E.Is_Error (Local) then
         Status := Local;
         return;
      end if;
      Settings.Experts_Used := Natural (Number);

      if Settings.Experts = 0 then
         Settings.Experts_Used := 0;
      end if;
   end if;

   --  The hybrid architectures' shape: how often a layer attends in
   --  full, and the linear layers' heads, state and convolution, all
   --  required, since a file without them describes no model of this
   --  kind. And how many blocks past the stack the file carries, which
   --  the stack does not run and the count of layers does not include.
   if Hybrid (Settings.Kind) then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "full_attention_interval"),
         1, Long_Long_Integer (Bounds.Max_Layers), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Linear_Every :=
        (if E.Is_Ok (Local) then Natural (Number) else 4);

      Required (Model_Key (Settings.Kind, "ssm.state_size"),
                Long_Long_Integer (Bounds.Max_Embedding),
                Settings.State_Size);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "ssm.group_count"),
                Long_Long_Integer (Bounds.Max_Heads), Settings.Key_Heads);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "ssm.time_step_rank"),
                Long_Long_Integer (Bounds.Max_Heads), Settings.Value_Heads);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "ssm.conv_kernel"),
                16, Settings.Conv_Kernel);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The inner size is the value heads times the state, and a file
      --  saying otherwise describes a shape this does not compute.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "ssm.inner_size"),
         1, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
      if Present_And_Wrong (Local)
        or else (E.Is_Ok (Local)
                 and then Natural (Number) /= Value_Width (Settings))
        or else Settings.Value_Heads mod Settings.Key_Heads /= 0
      then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "value_heads", Long_Long_Integer (Settings.Value_Heads));
         E.Add_Integer
           (Status, "key_heads", Long_Long_Integer (Settings.Key_Heads));
         return;
      end if;

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "nextn_predict_layers"),
         0, 4, Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Next_Layers := (if E.Is_Ok (Local) then Natural (Number) else 0);

      if Settings.Next_Layers >= Settings.Layers then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "next_layers", Long_Long_Integer (Settings.Next_Layers));
         return;
      end if;
      Settings.Layers := Settings.Layers - Settings.Next_Layers;

      --  The shared expert's width, where the mixture has one.
      if Settings.Experts > 0 then
         Containers.Get_Integer
           (Source,
            Model_Key (Settings.Kind, "expert_shared_feed_forward_length"),
            0, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Shared_Feed :=
           (if E.Is_Ok (Local) then Natural (Number) else 0);
      end if;
   end if;

   --  Mamba's widths, each with the default the other runtime carries
   --  where the file leaves it out: sixteen states, four convolution
   --  taps, an inner width twice the model's, and a time step of the
   --  model width over sixteen rounded up. Read under the same ssm keys
   --  the hybrid uses, but their meaning is Mamba's -- the time step is a
   --  projection rank, not a count of heads. Jamba's Mamba layers read
   --  the same widths under the same keys.
   if Pure_SSM (Settings.Kind) or else Is_Jamba (Settings.Kind) then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "ssm.state_size"),
         1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.State_Size :=
        (if E.Is_Ok (Local) then Natural (Number) else 16);

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "ssm.conv_kernel"),
         1, 16, Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Conv_Kernel :=
        (if E.Is_Ok (Local) then Natural (Number) else 4);

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "ssm.inner_size"),
         1, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Inner_Size :=
        (if E.Is_Ok (Local) then Natural (Number)
         else 2 * Settings.Embedding);

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "ssm.time_step_rank"),
         1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Time_Rank :=
        (if E.Is_Ok (Local) then Natural (Number)
         else (Settings.Embedding + 15) / 16);

      --  Mamba2's structure, past the widths Mamba shares. The groups
      --  its B and C are shared across default to one -- the whole inner
      --  width one group -- and the head count is the time-step rank the
      --  file states, because Mamba2's step is a head and no longer a
      --  low-rank projection, so head_dim is the inner width over it.
      --  A file whose heads do not divide the inner width, or whose
      --  groups do not divide the heads, describes a shape this does not
      --  compute and is refused rather than mis-read.
      if Is_Mamba2 (Settings.Kind) then
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "ssm.group_count"),
            1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Groups :=
           (if E.Is_Ok (Local) then Natural (Number) else 1);

         Settings.Ssm_Heads := Settings.Time_Rank;
         if Settings.Ssm_Heads = 0
           or else Settings.Inner_Size mod Settings.Ssm_Heads /= 0
           or else Settings.Ssm_Heads mod Settings.Groups /= 0
         then
            Status := E.Make (E.Arch_Invalid_Dimensions);
            E.Add_Integer
              (Status, "heads", Long_Long_Integer (Settings.Ssm_Heads));
            E.Add_Integer
              (Status, "inner_size",
               Long_Long_Integer (Settings.Inner_Size));
            E.Add_Integer
              (Status, "groups", Long_Long_Integer (Settings.Groups));
            return;
         end if;
         Settings.Head_Dim := Settings.Inner_Size / Settings.Ssm_Heads;
      end if;
   end if;

   --  RWKV6's shape: the head width the linear-attention state is a
   --  matrix of, from which the head count follows -- the model width
   --  over it, which must divide -- and the two low ranks the token
   --  shift and the decay are projected through a position at a time.
   --  The block's output is halved every so many layers to keep the
   --  residual bounded over the depth; a file stating none never halves.
   --  Two token-shift slots is the only arrangement understood, and the
   --  convolution memory is set to hold them.
   if Is_RWKV (Settings.Kind) then
      Required (Model_Key (Settings.Kind, "wkv.head_size"),
                Long_Long_Integer (Bounds.Max_Embedding),
                Settings.Head_Dim);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "time_mix_extra_dim"),
                Long_Long_Integer (Bounds.Max_Embedding),
                Settings.Mix_Extra);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "time_decay_extra_dim"),
                Long_Long_Integer (Bounds.Max_Embedding),
                Settings.Decay_Extra);
      if E.Is_Error (Status) then
         return;
      end if;

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "rescale_every_n_layers"),
         0, Long_Long_Integer (Bounds.Max_Layers), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Rescale_Every :=
        (if E.Is_Ok (Local) then Natural (Number) else 0);

      --  Two shift slots is what the block is written for: the last
      --  position's two normalized inputs. A file stating another number
      --  describes a shift this does not keep.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "token_shift_count"),
         1, 8, Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      elsif E.Is_Ok (Local) and then Natural (Number) /= 2 then
         Reject_Feature ("a token shift that is not two slots");
         return;
      end if;

      if Settings.Head_Dim = 0
        or else Settings.Embedding mod Settings.Head_Dim /= 0
      then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "embedding", Long_Long_Integer (Settings.Embedding));
         E.Add_Integer
           (Status, "head_size", Long_Long_Integer (Settings.Head_Dim));
         return;
      end if;
      Settings.Ssm_Heads := Settings.Embedding / Settings.Head_Dim;
      Settings.Conv_Kernel := 2;
   end if;

   if Settings.Experts > 0 then
      --  What is understood is a softmax over every expert, the highest
      --  few taken, and their weights renormalized over that few. A file
      --  naming a different gate or asking for the weights unnormalized
      --  describes a mixture this does not compute, and running it as
      --  though it did would produce a plausible wrong answer rather than
      --  a refusal.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "expert_gating_func"),
         1, 2, Number, Local);
      if Present_And_Wrong (Local) then
         Reject_Feature ("expert_gating_function");
         return;
      end if;
      Settings.Sigmoid_Gate := E.Is_Ok (Local) and then Number = 2;

      declare
         Normalized : Boolean;
      begin
         Containers.Get_Boolean
           (Source, Model_Key (Settings.Kind, "expert_weights_norm"),
            Normalized, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         --  DeepSeek2 states it where it renormalizes and is silent
         --  where it does not: V2 and V2-Lite train with the few taken
         --  as the softmax left them, which is llama.cpp's default too.
         --  Renormalized, DeepSeek-Coder-V2-Lite's six experts summed
         --  to one where they sum to a fraction, every mixture layer's
         --  answer several times too large.
         Settings.Renormalize_Experts :=
           (if E.Is_Ok (Local) then Normalized
            else Settings.Kind /= Deepseek2);

         --  Jamba softmaxes its experts and takes the highest few as
         --  they are, without renormalizing the few over themselves,
         --  whatever the file says -- the other runtime does the same.
         if Is_Jamba (Settings.Kind) then
            Settings.Renormalize_Experts := False;
         end if;
      end;

      --  The scalar the renormalized weights are multiplied by, which
      --  GraniteMoE carries and every other mixture here leaves at one.
      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "expert_weights_scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Expert_Scale :=
        (if E.Is_Ok (Local) then N.Real (Value) else 1.0);

      --  A shared expert runs for every position beside the chosen ones,
      --  which Shared_Expert does where the layer carries its gate. The
      --  count a file states is folded into that one block's width -- the
      --  shared experts are merged into a single gate-up-down of the
      --  stated feed length -- so the number is read and let pass, and the
      --  tensors it comes with are what the shared block runs.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "expert_shared_count"),
         0, Long_Long_Integer (Bounds.Max_Experts), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Shared_Count := (if E.Is_Ok (Local) then Natural (Number) else 0);

      --  One expert's width, when the file states it separately. A
      --  mixture-of-experts file often carries both numbers, and they are
      --  not the same: feed_forward_length describes the dense block the
      --  model does not have.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "expert_feed_forward_length"),
         1, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Expert_Feed :=
        (if E.Is_Ok (Local)
         then Natural (Number)
         else Settings.Feed_Forward);

      --  DeepSeek2 states how many shared experts it has and not their
      --  width, which is that many experts' worth side by side -- as
      --  llama.cpp derives it. Without it the shared experts were never
      --  read, and every mixture layer of DeepSeek-Coder-V2-Lite ran
      --  without the two experts every position goes through.
      if Settings.Kind = Deepseek2
        and then Settings.Shared_Feed = 0
        and then Shared_Count > 0
      then
         Settings.Shared_Feed := Settings.Expert_Feed * Shared_Count;
      end if;
   end if;

   --  A sliding window, when the model names one. Read rather than
   --  refused: each position attends to the window's worth of positions
   --  ending at itself, and the layers all use the same window.
   --
   --  The value is bounded by the context length. A window at least as
   --  wide as the context can see everything the context holds, which is
   --  what no window means, so it is stored as none -- the attention loops
   --  then have no bound to test and a model that names a wide window
   --  costs nothing to run.
   if Containers.Has
        (Source, Model_Key (Settings.Kind, "attention.sliding_window"))
   then
      declare
         Value : Long_Long_Integer;
         Local : E.Error_Info;
      begin
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "attention.sliding_window"),
            1, Long_Long_Integer (Bounds.Max_Context_Length), Value, Local);

         if E.Is_Error (Local) then
            Status := Local;
            return;
         end if;

         if Natural (Value) < Settings.Context_Length then
            Settings.Window := Natural (Value);
         end if;
      end;
   end if;

   --  Whether a position may see what follows it, where the file says so.
   --
   --  The architecture's name is a good default and not an answer: a
   --  published all-MiniLM states `bert.attention.causal` as false
   --  rather than leaving it to be assumed, and a file that states the
   --  other thing means it. Read here so that what decides the
   --  arithmetic is the file, which is the rule everywhere else in this
   --  profile and was an assumption only here.
   declare
      Named : Boolean;
      Local : E.Error_Info;
   begin
      Containers.Get_Boolean
        (Source, Model_Key (Settings.Kind, "attention.causal"), Named,
         Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;

      if E.Is_Ok (Local) then
         Settings.Causal := Named;
      end if;
   end;

   --  A window is a bound on how far back a position may look, and a
   --  model that looks both ways has not got such a thing: there is no
   --  "back" to bound. A file stating one under a bidirectional
   --  architecture is describing something this cannot compute, and
   --  reading the window as though it bounded the whole span would give
   --  every position the same few positions to see -- an answer, and not
   --  the model's.
   if not Settings.Causal and then Settings.Window > 0 then
      Reject_Feature ("a sliding window on a model that attends both ways");
      return;
   end if;

   --  The two bounds Gemma2 states, and the window it alternates. Read
   --  where the architecture says so rather than taken if present: a
   --  gemma2 file without them is a file this build cannot compute, and
   --  a file that states them under another architecture's prefix is a
   --  file that means something else by them.
   if Settings.Kind = Gemma3 then
      --  Five layers in six slide a window; the sixth sees everything.
      Settings.Alternating := True;
      Settings.Window_Every := 6;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.local_freq_base"),
         1.0, 1.0E12, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Local_Base :=
        (if E.Is_Ok (Local) then Value else 10_000.0);
   end if;

   --  GPT_OSS alternates a window the same way Gemma2 does and turns
   --  the windowed layers on a base of their own, the way Gemma3 does.
   --  It is the first architecture here to want both, which is why
   --  neither of those two blocks could be reused for it.
   if Settings.Kind = GPT_OSS then
      Settings.Alternating := True;
      Settings.Window_Every := 2;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.freq_base_swa"),
         1.0, 1.0E12, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Local_Base :=
        (if E.Is_Ok (Local) then Value else Settings.Rope_Base);

      --  The gate's two bounds, which this architecture states nowhere:
      --  they are constants of the model rather than of the file, and
      --  llama.cpp writes them out in its graph for the same reason.
      --  1.702 is the slope that makes the logistic agree with the
      --  Gaussian error function this model was trained against.
      Settings.Gate_Alpha := 1.702;
      Settings.Gate_Limit := 7.0;
   end if;

   if Settings.Kind = Gemma2 then
      Settings.Alternating := True;
      Settings.Window_Every := 2;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attn_logit_softcapping"),
         1.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Attention_Cap :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "final_logit_softcapping"),
         1.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Logit_Cap :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);
   end if;

   if Settings.Kind in Granite | Granite_MoE then
      --  The four multipliers the architecture applies. Each is optional
      --  in the file and defaults to the identity -- a Granite that
      --  states none is a plain llama -- so a missing key is not an
      --  error, only a wrong one is.
      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "embedding_scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Embedding_Mul :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "residual_scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Residual_Mul :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attention.scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Attention_Mul :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "logit_scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Logit_Mul :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);
   end if;

   --  Command-R carries the same key under the opposite meaning: it
   --  multiplies its logits by the scale where Granite divides by it, so
   --  it is read into its own field and applied its own way.
   if Settings.Kind = Command_R then
      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "logit_scale"),
         1.0E-6, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Logit_Scale :=
        (if E.Is_Ok (Local) then N.Real (Value) else 0.0);
   end if;

   --  How steeply a head's attention falls off with distance, for the
   --  one architecture here that is told where a token is by the scores
   --  rather than by a rotation or a learned row.
   --
   --  The key exists in the format -- `<arch>.attention.max_alibi_bias`
   --  -- and no published jina-bert-v2 states it; the other runtime
   --  carries eight for this architecture in its own source. So eight is
   --  the default, taken when the file says nothing, and the stated bias
   --  is read and used where the file carries one -- the slope ladder is
   --  what tells the model where a token is, and Head_Slope builds it
   --  from whatever this holds, so a file that states its own is run at
   --  its own rather than refused.
   if Settings.Kind in Jina_Bert_V2 | Mpt
     or else (Settings.Kind = Baichuan and then Settings.Layers = 40)
   then
      Settings.Max_Bias := 8.0;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attention.max_alibi_bias"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      elsif E.Is_Ok (Local) then
         Settings.Max_Bias := N.Real (Value);
      end if;
   end if;

   --  MPT may clamp its fused queries, keys and values to a magnitude
   --  the file states, before it splits them apart and attends. Taken
   --  where the file carries it and left at zero -- no clamp -- where it
   --  does not, which is the ordinary case.
   if Settings.Kind = Mpt then
      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attention.clamp_kqv"),
         0.0, 1.0E6, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      elsif E.Is_Ok (Local) then
         Settings.Clip_QKV := N.Real (Value);
      end if;
   end if;

   if Settings.Heads mod Settings.KV_Heads /= 0 then
      Status := E.Make (E.Arch_Invalid_Head_Counts);
      E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
      E.Add_Integer
        (Status, "kv_heads", Long_Long_Integer (Settings.KV_Heads));
      return;
   end if;

   Settings.Group_Size := Settings.Heads / Settings.KV_Heads;

   --  How wide a head is. A file may state the key width and the value
   --  width, and they need not be each other nor the embedding divided by
   --  the head count: a model is free to give its heads more room than
   --  its embedding would imply, or to read values narrower than the keys
   --  it selects them with.
   --
   --  A file that states neither has both derived from the embedding
   --  width, which then has to divide exactly -- a remainder would mean
   --  the file describes a model this arithmetic cannot express.
   Containers.Get_Integer
     (Source, Model_Key (Settings.Kind, "attention.key_length"),
      1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
   if Present_And_Wrong (Local) then
      Status := Local;
      return;
   end if;

   if E.Is_Ok (Local) then
      Settings.Head_Size := Natural (Number);
   else
      if Settings.Embedding mod Settings.Heads /= 0 then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "embedding", Long_Long_Integer (Settings.Embedding));
         E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
         return;
      end if;
      Settings.Head_Size := Settings.Embedding / Settings.Heads;
   end if;

   Containers.Get_Integer
     (Source, Model_Key (Settings.Kind, "attention.value_length"),
      1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
   if Present_And_Wrong (Local) then
      Status := Local;
      return;
   end if;
   Settings.Value_Size :=
     (if E.Is_Ok (Local) then Natural (Number) else Settings.Head_Size);

   --  A hybrid's full attention carries a gate beside each head, of the
   --  head's own width, and scales the head's blend by it -- so its
   --  value width is its head size, and a file stating another is a
   --  model the reference implementation does not define either.
   --  Refused by name: read anyway, the gate ran off the end of the
   --  blend, and the fixture sweep's shape with the widths apart said
   --  INTERNAL_INVARIANT_VIOLATED on every backend for as long as the
   --  architecture had been read.
   if Hybrid (Settings.Kind)
     and then Settings.Value_Size /= Settings.Head_Size
   then
      Status := E.Make (E.Arch_Invalid_Dimensions);
      E.Add_Integer
        (Status, "head_size", Long_Long_Integer (Settings.Head_Size));
      E.Add_Integer
        (Status, "value_size", Long_Long_Integer (Settings.Value_Size));
      return;
   end if;

   Containers.Get_Integer
     --  From zero, not from one. Zero is what an architecture that
     --  learns where a token is rather than rotating for it states, and
     --  it is a fact about the model rather than a missing key: GPT2
     --  carries a table of positions and no rotation, and a reader that
     --  refused the zero would refuse the model.
     (Source, Model_Key (Settings.Kind, "rope.dimension_count"), 0,
      Long_Long_Integer (Settings.Head_Size), Number, Local);
   if Present_And_Wrong (Local) then
      Status := Local;
      return;
   end if;
   --  Bert does not rotate at all, so the width is zero however the file
   --  reads: it learns where a token is instead, and a published file
   --  states no rotary width because there is nothing to state. Left to
   --  the default below, an absent key would have taken the head size
   --  and turned every query and key of a model that never rotates --
   --  which the sweep could not have caught, because the fixture wrote
   --  the key as zero and so agreed with itself about a model nobody
   --  ships. That is the same trap gpt2's output bias fell into, found
   --  the same way: by reading a file somebody else published.
   Settings.Rotary :=
     (if Settings.Kind in Bert | Jina_Bert_V2 | Mpt | Jamba
         or else (Settings.Kind = Baichuan and then Settings.Layers = 40)
       then 0
      elsif E.Is_Ok (Local) then Natural (Number)
      else Settings.Head_Size);

   --  DeepSeek's latent ranks. The keys are projected through a latent
   --  of KV_Lora_Rank, required; the queries through one of Q_Lora_Rank
   --  where the file states it and straight otherwise, so nought is a
   --  fact about the model rather than a missing key. Leading_Dense is
   --  how many layers run a dense feed-forward before the mixture ones,
   --  counting from the first; nought where every layer is a mixture.
   --  The head width (Head_Size, from key_length) is the rotated slice
   --  (Rotary) and the rest that is not; the value width (Value_Size)
   --  its own -- both already read above.
   if Is_MLA (Settings.Kind) then
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.q_lora_rank"),
         0, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Q_Lora_Rank :=
        (if E.Is_Ok (Local) then Natural (Number) else 0);

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.kv_lora_rank"),
         1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if E.Is_Error (Local) then
         Status := E.Make (E.GGUF_Missing_Metadata_Key);
         E.Add_Text
           (Status, "key",
            Model_Key (Settings.Kind, "attention.kv_lora_rank"),
            E.Param_Identifier);
         return;
      end if;
      Settings.KV_Lora_Rank := Natural (Number);

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "leading_dense_block_count"),
         0, Long_Long_Integer (Settings.Layers), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Leading_Dense :=
        (if E.Is_Ok (Local) then Natural (Number) else 0);
   end if;

   --  The three parts a Qwen3.5 position has, and how many pairs each
   --  turns: stated as four counts, the fourth unused, and dealt
   --  interleaved. A text token has the three parts equal, so a model
   --  read without them rotates the same; they matter to a picture's
   --  rows, which have a row and a column of their own.
   if Settings.Kind in Qwen35 | Qwen35_MoE then
      declare
         Key    : constant String :=
           Model_Key (Settings.Kind, "rope.dimension_sections");
         Length : Natural := 0;
         Count  : Long_Long_Integer;
         Found  : E.Error_Info;
      begin
         Containers.Get_Array_Length
           (Source, Key, Model_Runner.GGUF.Value_Int32, Length, Found);
         if E.Is_Ok (Found) and then Length >= 3 then
            for Part in 1 .. Natural'Min (4, Length) loop
               Containers.Get_Integer_Element (Source, Key, Part, Count, Found);
               exit when E.Is_Error (Found) or else Count < 0 or else Count > 4096;
               case Part is
                  when 1 => Settings.Sections.T := Natural (Count);
                  when 2 => Settings.Sections.H := Natural (Count);
                  when 3 => Settings.Sections.W := Natural (Count);
                  when others => Settings.Sections.E := Natural (Count);
               end case;
            end loop;
            Settings.Sections.Interleaved := True;
            if E.Is_Error (Found) then
               Settings.Sections := K.No_Sections;
            end if;
         end if;
      end;
   end if;

   if Settings.Rotary > Settings.Head_Size
     or else Settings.Rotary mod 2 /= 0
   then
      Status := E.Make (E.Arch_Invalid_Rope);
      E.Add_Integer (Status, "rotary", Long_Long_Integer (Settings.Rotary));
      E.Add_Integer
        (Status, "head_size", Long_Long_Integer (Settings.Head_Size));
      return;
   end if;

   --  What a file states that its architecture has no use for, refused
   --  by name rather than read and ignored. A model built on a state
   --  that runs position by position -- Mamba, Mamba2, RWKV6 -- has no
   --  attention to widen or to window, no rotation to stretch and no
   --  experts to route to; StableLM has no mixture; Jamba and DeepSeek2
   --  attend to everything, and Jamba's attention reads values as wide
   --  as its keys. A file stating one of these describes a model this
   --  does not compute, and loading it anyway ran some other model under
   --  the file's name and said nothing.
   declare
      function States (Key : String) return Boolean
      is (Containers.Has (Source, Model_Key (Settings.Kind, Key)));

      --  The first key of those a stateful model has no use for that
      --  the file states, or nothing.
      function Unused_By_State return String
      is (if States ("attention.key_length")
          then "attention.key_length"
          elsif States ("attention.value_length")
          then "attention.value_length"
          elsif States ("attention.sliding_window")
          then "attention.sliding_window"
          elsif States ("rope.scaling.type") then "rope.scaling.type"
          elsif States ("rope.scaling.factor") then "rope.scaling.factor"
          elsif States ("expert_count") then "expert_count"
          elsif States ("expert_used_count") then "expert_used_count"
          else "");
   begin
      if Pure_SSM (Settings.Kind) or else Is_RWKV (Settings.Kind) then
         if Unused_By_State /= "" then
            Reject_Feature (Unused_By_State);
            return;
         end if;

         if Containers.Find_Tensor (Source, "rope_freqs.weight") /= 0 then
            Reject_Feature ("rope_freqs");
            return;
         end if;
      end if;

      if Settings.Kind = Stablelm and then States ("expert_count") then
         Reject_Feature ("expert_count");
         return;
      end if;

      if Settings.Kind in Jamba | Deepseek2
        and then States ("attention.sliding_window")
      then
         Reject_Feature ("attention.sliding_window");
         return;
      end if;

      if Settings.Kind = Jamba
        and then Settings.Head_Size /= Settings.Value_Size
      then
         Reject_Feature ("attention.value_length");
         return;
      end if;
   end;

   Status := E.Success;
end Read_Configuration;
