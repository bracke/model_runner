with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with System.Storage_Elements;

with Model_Runner.Arithmetic;
with Model_Runner.Backend.Device;
with Model_Runner.Backend.Reference;
with Model_Runner.Text;

package body Model_Runner.Llama is

   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   --  The same reason the kernels give. Every activation and weight here
   --  came out of a model file, so a not-a-number or an infinity is possible
   --  input, and this package guards against it explicitly: a non-finite
   --  value found in a tensor is a diagnostic, and so is a non-finite logit.
   --  Validity checking raises when such a value is read, which is before
   --  any of those guards can run, so it would replace each diagnostic with
   --  an exception -- reported, since nothing may escape, as the engine
   --  finding a defect in itself. Bounds and range checking are untouched.
   pragma Suppress (Validity_Check);

   use type Model_Runner.Errors.Error_Code;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Arithmetic.Checked;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Tensors.Half_Array_Access;

   package A renames Model_Runner.Arithmetic;
   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.Cancellation;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package K renames Model_Runner.Kernels;
   package Mem renames Model_Runner.Memory;
   package N renames Model_Runner.Numerics;
   package P renames Model_Runner.Progress;
   package T renames Model_Runner.Tensors;
   package Workers_CPU renames Model_Runner.Backend.CPU;

   --  Bytes one cache element occupies, in each of the two storages a
   --  session may ask for. Exact is the correctness baseline every published
   --  figure is taken against; halved is what it says, and the conformance
   --  evidence this used to say it would need before being advertised is in
   --  the README.
   Cache_Element_Bytes :
     constant array (Cache_Precision) of Interfaces.Unsigned_64 :=
       [Exact => 4, Halved => 2, Eighth => 1];

   --  The per-layer tensors jina-bert-v2's code variant carries and its text
   --  variant does not. Named here so the refusal below spells each one
   --  exactly as the file does.
   type Tensor_Name is access constant String;
   Unread_Jina_Norms : constant array (1 .. 3) of Tensor_Name :=
     [new String'("attn_norm_2.weight"),
      new String'("attn_q_norm.weight"),
      new String'("attn_k_norm.weight")];

   --  Metadata keys are built once, here, so that no other package spells a
   --  tensor or metadata name.
   function Layer_Key (Index : Natural; Suffix : String) return String
   is ("blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
       & "." & Suffix);

   --  Metadata keys carry the architecture's own name, so the same reader
   --  finds llama.context_length in one file and qwen2.context_length in
   --  another without either name being written anywhere but here.
   function Model_Key
     (Kind : Architecture; Suffix : String) return String
   is (Architecture_Name (Kind) & "." & Suffix);

   procedure Deallocate_Layers is
     new Ada.Unchecked_Deallocation (Layer_Array, Layer_Array_Access);

   procedure Deallocate_Experts is
     new Ada.Unchecked_Deallocation (Expert_Array, Expert_Array_Access);

   procedure Deallocate_History is
     new Ada.Unchecked_Deallocation (Token_History, Token_History_Access);

   ---------------------------------------------------------------------------
   --  Configuration
   ---------------------------------------------------------------------------

   --  Read and validate the architecture metadata.
   procedure Read_Configuration
     (Source   : Containers.Container;
      Bounds   : Model_Runner.Limits.Model_Limits;
      Settings : out Configuration;
      Status   : out E.Error_Info)
   is
      Number : Long_Long_Integer;
      Value  : N.Wide_Real;
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
                    when Llama => K.Interleaved,
                    when Qwen2 | Qwen3 | Qwen3_MoE | Gemma | Gemma2 | Gemma3
                       | Phi3 | Falcon | Phi2 | GPT2 | Bert
                       | Nomic_Bert | Jina_Bert_V2 =>
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

      Required (Model_Key (Settings.Kind, "feed_forward_length"),
                Long_Long_Integer (Bounds.Max_Embedding) * 64,
                Settings.Feed_Forward);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "attention.head_count"),
                Long_Long_Integer (Bounds.Max_Heads), Settings.Heads);
      if E.Is_Error (Status) then
         return;
      end if;

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

      --  The floor under a normalization's divisor. An architecture that
      --  normalizes by root mean square states it under one key and Bert,
      --  which centres, states it under another -- the same quantity in the
      --  same units, named for the normalization it belongs to. Bert is
      --  asked for its own key and falls back to the other, so a file that
      --  states either is read and a file that states neither takes the
      --  default both would.
      if Normalizes_After (Settings.Kind) then
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

      --  What the file says its states should be pooled with. Read for the
      --  architecture that states it and left unstated for the rest, which
      --  is not the same as none: a model that says nothing about pooling
      --  has not asked for one, and a model that says none has.
      --
      --  Ranked pooling is a fourth value some files carry. It is not a way
      --  of reducing a text to a vector at all -- it names a scoring head
      --  this program does not have -- so it is refused by name rather than
      --  read as one of the three that are.
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
               when others =>
                  Reject_Feature ("rank pooling");
                  return;
            end case;
         end if;

         --  A row for each segment a token may belong to. The architecture
         --  states two and the shape is checked against that where the
         --  tensor is resolved; a text embedded here is all one segment, so
         --  only the first row is ever read, and the second is required
         --  because a file that has not got it is not the model this
         --  computes.
         if Containers.Find_Tensor (Source, "token_types.weight") /= 0 then
            Settings.Segments := 2;
         end if;
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
      --  divides the low frequencies and leaves the high ones alone. Any
      --  other name changes the position mapping in a way this does not
      --  compute, and running it as though it did would produce a model that
      --  reads its own context wrongly at long range and says nothing about
      --  it.
      declare
         Named : constant String :=
           Containers.String_Value
             (Source, Model_Key (Settings.Kind, "rope.scaling.type"));
      begin
         if Named /= "" and then Named /= "none" and then Named /= "linear"
           and then Named /= "yarn"
         then
            Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
            E.Add_Text (Status, "scaling", Named, E.Param_Identifier);
            return;
         end if;

         --  Two tables, chosen by how long the prompt turned out to be, is
         --  a different method again: it makes the rotation depend on the
         --  whole sequence rather than on the position, and nothing here
         --  does that. Refused by the tensors as well as by the name,
         --  because a file may carry them without naming the method.
         if Containers.Find_Tensor (Source, "rope_factors_long.weight") /= 0
           or else Containers.Find_Tensor
                     (Source, "rope_factors_short.weight") /= 0
         then
            Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
            E.Add_Text (Status, "scaling", "longrope", E.Param_Identifier);
            return;
         end if;

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

      if Settings.Experts > 0 then
         --  What is understood is a softmax over every expert, the highest
         --  few taken, and their weights renormalized over that few. A file
         --  naming a different gate or asking for the weights unnormalized
         --  describes a mixture this does not compute, and running it as
         --  though it did would produce a plausible wrong answer rather than
         --  a refusal.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_gating_func"),
            1, 1, Number, Local);
         if Present_And_Wrong (Local) then
            Reject_Feature ("expert_gating_function");
            return;
         end if;

         declare
            Normalized : Boolean;
         begin
            Containers.Get_Boolean
              (Source, Model_Key (Settings.Kind, "expert_weights_norm"),
               Normalized, Local);
            if Present_And_Wrong (Local)
              or else (E.Is_Ok (Local) and then not Normalized)
            then
               Reject_Feature ("unnormalized_expert_weights");
               return;
            end if;
         end;

         --  A shared expert runs for every position beside the chosen ones.
         --  Nothing here computes it, and a model that has one produces a
         --  different answer without it.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_shared_count"),
            0, 0, Number, Local);
         if Present_And_Wrong (Local) then
            Reject_Feature ("shared_expert");
            return;
         end if;

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

      --  How steeply a head's attention falls off with distance, for the
      --  one architecture here that is told where a token is by the scores
      --  rather than by a rotation or a learned row.
      --
      --  Written rather than read. The key exists in the format --
      --  `<arch>.attention.max_alibi_bias` -- and no published
      --  jina-bert-v2 states it; the other runtime carries eight for this
      --  architecture in its own source and reads nothing. A file that does
      --  state one is refused rather than cut to eight, because a slope
      --  ladder is what tells the model where a token is and a wrong one
      --  answers rather than refuses.
      if Settings.Kind = Jina_Bert_V2 then
         Settings.Max_Bias := 8.0;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "attention.max_alibi_bias"),
            0.0, 1.0E6, Value, Local);
         if E.Is_Ok (Local) and then N.Real (Value) /= Settings.Max_Bias then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text
              (Status, "feature", "attention.max_alibi_bias other than 8",
               E.Param_Identifier);
            return;
         elsif Present_And_Wrong (Local) then
            Status := Local;
            return;
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
        (if Settings.Kind in Bert | Jina_Bert_V2 then 0
         elsif E.Is_Ok (Local) then Natural (Number)
         else Settings.Head_Size);

      if Settings.Rotary > Settings.Head_Size
        or else Settings.Rotary mod 2 /= 0
      then
         Status := E.Make (E.Arch_Invalid_Rope);
         E.Add_Integer (Status, "rotary", Long_Long_Integer (Settings.Rotary));
         E.Add_Integer
           (Status, "head_size", Long_Long_Integer (Settings.Head_Size));
         return;
      end if;

      Status := E.Success;
   end Read_Configuration;

   ------------------
   -- Read_Config --
   ------------------

   procedure Read_Config
     (Source   : Containers.Container;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Settings : out Configuration;
      Status   : out E.Error_Info) is
   begin
      Read_Configuration (Source, Bounds, Settings, Status);
   end Read_Config;

   ---------------------------------------------------------------------------
   --  Tensor resolution
   ---------------------------------------------------------------------------

   --  Every matrix a model holds, as references to the views that name
   --  them. A norm is already a decoded vector and a bias is too, so neither
   --  is here.
   --
   --  One list, because there are two questions about the same set -- what
   --  to decode when repacking, and how many bytes a backend would have to
   --  hold -- and a second copy of the walk is a second place for a tensor
   --  to be forgotten. The mixture layers are where that would happen: three
   --  matrices an expert, and a list written twice would have them in one.
   type View_Access is access all T.View;
   type View_List is array (Positive range <>) of View_Access;

   function Matrices (Item : in out Model) return View_List is
      --  Seven a dense layer, and a mixture layer instead carries a router
      --  and three matrices an expert.
      Per_Layer : constant Positive :=
        (if Item.Settings.Experts = 0
         then 7
         else 4 + 1 + 3 * Item.Settings.Experts);

      --  Four beside the layers -- the embedding table, the output
      --  projection, the positions and the segments -- though no
      --  architecture carries all four: a model with segments has no output
      --  projection. Sized for four anyway, because "three is enough" is
      --  true by a coincidence between two architectures rather than by
      --  anything holding it, and the cost of the fourth is a pointer.
      Room  : View_List (1 .. 4 + Per_Layer * Item.Settings.Layers);
      Count : Natural := 0;

      procedure Add (Where : View_Access) is
      begin
         if T.Is_Present (Where.all) then
            Count := Count + 1;
            Room (Count) := Where;
         end if;
      end Add;
   begin
      Add (Item.Embeddings'Unchecked_Access);
      Add (Item.Output'Unchecked_Access);

      --  And the table of positions, which is a matrix like any other and
      --  has to be rewritten when the weights are: a view left pointing at
      --  the file's bytes while everything around it moved into the
      --  repacked buffer reads a row that is not there. Empty for every
      --  architecture that rotates, and Add ignores an empty view.
      Add (Item.Positions'Unchecked_Access);

      --  And the segment table beside it, for the same reason and with the
      --  same consequence. It was left out, and the sweep found it: with
      --  the weights repacked, everything around this moved into the new
      --  buffer and this went on reading the file's -- which is a row of
      --  something, so what came back was an embedding rather than a
      --  refusal. Empty for every architecture that has no segments.
      Add (Item.Segments'Unchecked_Access);

      for Index in Item.Layers'Range loop
         Add (Item.Layers (Index).Query'Unchecked_Access);
         Add (Item.Layers (Index).Key'Unchecked_Access);
         Add (Item.Layers (Index).Value'Unchecked_Access);
         Add (Item.Layers (Index).Attention_Out'Unchecked_Access);
         Add (Item.Layers (Index).Gate'Unchecked_Access);
         Add (Item.Layers (Index).Up'Unchecked_Access);
         Add (Item.Layers (Index).Down'Unchecked_Access);
         Add (Item.Layers (Index).Router'Unchecked_Access);

         if Item.Layers (Index).Experts /= null then
            for Which in Item.Layers (Index).Experts.all'Range loop
               Add (Item.Layers (Index).Experts.all (Which).Gate'Unchecked_Access);
               Add (Item.Layers (Index).Experts.all (Which).Up'Unchecked_Access);
               Add (Item.Layers (Index).Experts.all (Which).Down'Unchecked_Access);
            end loop;
         end if;
      end loop;

      return Room (1 .. Count);
   end Matrices;

   --  Resolve one tensor by name and check its shape against the role it
   --  plays. Every required tensor is resolved during preparation; no name
   --  lookup happens during evaluation.
   procedure Resolve
     (Item     : in out Model;
      Source   : Containers.Container;
      Name     : String;
      Rows     : Element_Count;
      Columns  : Element_Count;
      Result   : out T.View;
      Status   : out E.Error_Info;

      --  What the caller asked to have the weights decoded into, because
      --  that -- and not what the file holds -- is what a backend will read
      --  from this tensor.
      Repack   : Repack_Mode := No_Repack;

      --  False for a tensor decoded once at load and never handed over: a
      --  norm or a bias is a vector by the time anything computes with it,
      --  so the format the file wrote it in is nothing the backend sees.
      Reaches  : Boolean := True)
   is
      Index : constant Natural := Containers.Find_Tensor (Source, Name);
   begin
      Result := T.Empty_View;

      if Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      if not Containers.Tensor_Is_Supported (Source, Index) then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text
           (Status, "format",
            Model_Runner.GGUF.Type_Name
              (Containers.Tensor_Format (Source, Index)),
            E.Param_Identifier);
         return;
      end if;

      --  And what the backend can read, which is a different question from
      --  what the container can describe. Asked here, per tensor, while the
      --  model loads: a backend that cannot take a format should refuse the
      --  model that carries it, not meet it in the middle of a token.
      --
      --  Asked of the format the backend will read, which is the repacking
      --  target when there is one. Asking it of the file's format instead
      --  refuses `--repack f32` on a quantized model -- and a backend that
      --  reads binary32 only is exactly the backend repacking exists to make
      --  usable, so the check would have refused every model the flag was
      --  for. It did, once.
      declare
         Seen : constant Model_Runner.GGUF.Tensor_Type :=
           (case Repack is
              when No_Repack => Containers.Tensor_Format (Source, Index),
              when To_F32    => Model_Runner.GGUF.Type_F32,
              when To_BF16   => Model_Runner.GGUF.Type_BF16);
      begin
         if Reaches
           and then not Model_Runner.Backend.Supports (Item.Able, Seen)
         then
            Status := E.Make (E.Backend_Unsupported_Format);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Text
              (Status, "format", Model_Runner.GGUF.Type_Name (Seen),
               E.Param_Identifier);
            E.Add_Text
              (Status, "backend",
               Model_Runner.Backend.Backend_Name (Item.Able.Kind),
               E.Param_Identifier);
            return;
         end if;
      end;

      --  And where it sits. A backend states the alignment it needs from
      --  tensor storage; a file is free to place a tensor anywhere its own
      --  alignment allows, and the two are not the same number.
      if Containers.Tensor_Offset (Source, Index)
         mod Interfaces.Unsigned_64 (Item.Able.Alignment) /= 0
      then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text (Status, "capability", "alignment", E.Param_Identifier);
         E.Add_Integer
           (Status, "alignment", Long_Long_Integer (Item.Able.Alignment),
            E.Param_Bytes);
         return;
      end if;

      declare
         Rank      : constant Positive := Containers.Tensor_Rank (Source, Index);
         Contiguous : constant Element_Count :=
           Element_Count (Containers.Tensor_Dimension (Source, Index, 1));
         Remaining : Element_Count := 1;
      begin
         for Axis in 2 .. Rank loop
            Remaining := Remaining
              * Element_Count (Containers.Tensor_Dimension (Source, Index, Axis));
         end loop;

         if Contiguous /= Columns or else Remaining /= Rows then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Contiguous));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Remaining));
            E.Add_Integer
              (Status, "expected_columns", Long_Long_Integer (Columns));
            E.Add_Integer (Status, "expected_rows", Long_Long_Integer (Rows));
            return;
         end if;

         T.Make
           (Format  => Containers.Tensor_Format (Source, Index),
            Rows    => Rows,
            Columns => Columns,
            Base    => Item.Weights_Base,
            Span    => Item.Weights_Span,
            Offset  =>
              B.Byte_Count (Containers.Tensor_Offset (Source, Index))
              - Item.Arena_Base,
            Result  => Result,
            Status  => Status);

         if E.Is_Error (Status) then
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         end if;
      end;
   end Resolve;

   --  Resolve one projection out of a tensor that holds several.
   --
   --  Phi3 writes the queries, keys and values as one tensor and the gate
   --  and the up projection as another. A row is a whole number of blocks in
   --  every format this reads, so a part begins at a block boundary and is
   --  a view over the same bytes at an offset -- no copy, and the part is an
   --  ordinary matrix to everything downstream, including the repacking
   --  pass, which rewrites each part as its own tensor.
   --
   --  The whole shape is checked rather than the part's: a file whose fused
   --  tensor is the wrong size is a file this cannot read, and finding that
   --  out from the first part alone would take the first rows of something
   --  else and call them a projection.
   --
   --  @param Whole_Rows Rows the fused tensor holds altogether.
   --  @param First_Row Row this part starts at.
   --  @param Rows Rows this part holds.
   procedure Resolve_Part
     (Item       : in out Model;
      Source     : Containers.Container;
      Name       : String;
      Whole_Rows : Element_Count;
      Columns    : Element_Count;
      First_Row  : Element_Count;
      Rows       : Element_Count;
      Result     : out T.View;
      Status     : out E.Error_Info;
      Repack     : Repack_Mode := No_Repack)
   is
      Whole : T.View;
   begin
      Result := T.Empty_View;

      --  The whole tensor first, which is where the shape and the format
      --  are checked. Repack reaches it because that check asks what the
      --  backend will read rather than what the file holds.
      Resolve (Item, Source, Name, Whole_Rows, Columns, Whole, Status,
               Repack => Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Per_Block : constant Element_Count :=
           Element_Count (Model_Runner.GGUF.Block_Elements (Whole.Format));
         Row_Bytes : constant B.Byte_Count :=
           B.Byte_Count (Columns / Per_Block)
           * B.Byte_Count (Model_Runner.GGUF.Block_Bytes (Whole.Format));
      begin
         if Columns mod Per_Block /= 0 then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
            return;
         end if;

         T.Make
           (Format  => Whole.Format,
            Rows    => Rows,
            Columns => Columns,
            Base    => Item.Weights_Base,
            Span    => Item.Weights_Span,
            Offset  => Whole.Offset + B.Byte_Count (First_Row) * Row_Bytes,
            Result  => Result,
            Status  => Status);
      end;

      --  Nothing repacks here. The pass that rewrites weights runs later,
      --  over every view the model holds, and a part is one of those: it
      --  arrives there as an ordinary matrix and is rewritten as its own
      --  tensor, which is also what makes a repacked phi3 model stop being
      --  fused at all.
   end Resolve_Part;

   --  Resolve a one-dimensional normalization weight and decode it once into a
   --  plain vector. Norm weights are read on every layer of every token, and
   --  they are tiny, so keeping them decoded costs little and removes a
   --  dequantization from the inner loop.
   procedure Resolve_Norm
     (Item   : in out Model;
      Source : Containers.Container;
      Name   : String;
      Width  : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Weight : T.View;
   begin
      Result := null;
      Resolve (Item, Source, Name, 1, Width, Weight, Status,
               Reaches => False);
      if E.Is_Error (Status) then
         return;
      end if;

      T.Allocate (Width, Result);
      if Result = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      Mem.Record_Allocation
        (Item.Accounting, Mem.Converted_Weights,
         Interfaces.Unsigned_64 (Width) * 4);
      Mem.Record_Conversion
        (Item.Accounting, Interfaces.Unsigned_64 (Width) * 4);

      T.Dequantize_Row (Weight, 0, Result.all, Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
      end if;
   end Resolve_Norm;

   --  Resolve part of a one-dimensional tensor several projections share.
   --
   --  The same arrangement the matrices are in: an architecture that writes
   --  its queries, keys and values as one tensor writes their biases as one
   --  vector too, and each is a run of elements at an offset. Copied out
   --  rather than made a view, because a bias is a few hundred numbers that
   --  are added to a row and nothing gains from sharing them.
   --
   --  @param Whole Elements the whole vector holds.
   --  @param First Element the part starts at.
   --  @param Count Elements the part holds.
   procedure Resolve_Norm_Part
     (Item   : in out Model;
      Source : Containers.Container;
      Name   : String;
      Whole  : Element_Count;
      First  : Element_Count;
      Count  : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Entire : T.Real_Array_Access;
   begin
      Result := null;
      Resolve_Norm (Item, Source, Name, Whole, Entire, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      T.Allocate (Count, Result);
      if Result = null then
         T.Free (Entire);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      Result.all := Entire.all (First .. First + Count - 1);
      T.Free (Entire);
   end Resolve_Norm_Part;

   --  Resolve a layer's router and the stack of expert matrices behind it.
   --
   --  A file writes the experts of one layer as a single tensor with the
   --  expert axis outermost, so one expert's rows are contiguous and a view
   --  over them is arithmetic on an offset rather than a copy. That is the
   --  whole reason this is cheap: a mixture model holds no more bytes than
   --  the file does, and no expert is materialized until a position routes
   --  to it.
   procedure Resolve_Experts
     (Item    : in out Model;
      Source  : Containers.Container;
      Index   : Natural;
      Current : in out Layer;
      Status  : out E.Error_Info;
      Repack  : Repack_Mode := No_Repack)
   is
      Width : constant Element_Count :=
        Element_Count (Item.Settings.Embedding);
      Feed  : constant Element_Count :=
        Element_Count (Item.Settings.Expert_Feed);
      Count : constant Element_Count :=
        Element_Count (Item.Settings.Experts);

      --  One expert's rows out of the stack.
      procedure Slice
        (Whole  : T.View;
         Which  : Element_Count;
         Rows   : Element_Count;
         Result : out T.View;
         Status : out E.Error_Info) is
      begin
         T.Make
           (Format  => Whole.Format,
            Rows    => Rows,
            Columns => Whole.Columns,
            Base    => Whole.Base,
            Span    => Whole.Span,
            Offset  =>
              Whole.Offset
              + B.Byte_Count (Which) * B.Byte_Count (Rows)
                * T.Row_Bytes (Whole),
            Result  => Result,
            Status  => Status);
      end Slice;

      Gates, Ups, Downs : T.View;
   begin
      Resolve
        (Item, Source, Layer_Key (Index, "ffn_gate_inp.weight"),
         Count, Width, Current.Router, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_gate_exps.weight"),
         Feed * Count, Width, Gates, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_up_exps.weight"),
         Feed * Count, Width, Ups, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_down_exps.weight"),
         Width * Count, Feed, Downs, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Current.Experts := new Expert_Array (0 .. Item.Settings.Experts - 1);

      for Which in Current.Experts.all'Range loop
         Slice
           (Gates, Element_Count (Which), Feed,
            Current.Experts.all (Which).Gate, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Slice
           (Ups, Element_Count (Which), Feed,
            Current.Experts.all (Which).Up, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Slice
           (Downs, Element_Count (Which), Width,
            Current.Experts.all (Which).Down, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end loop;
   end Resolve_Experts;

   ---------------------
   -- Release_Weights --
   ---------------------

   procedure Release_Weights (Item : in out Model) is
   begin
      --  The device is told before the bytes go, never after.
      --
      --  It remembers a matrix by where its bytes lie, so an address it
      --  holds and this program has freed is an address the next matrix can
      --  be given -- and the device would answer for that one with these
      --  weights. This is the only place the weights are freed, so that it
      --  is the only place that has to remember to say so: there were two,
      --  and the second was found by listing what the first one's fix did
      --  not cover rather than by anything failing.
      --
      --  Said unconditionally. A model that never touched a device gives
      --  back nothing, which costs nothing, and a model cannot know whether
      --  the device holds its addresses.
      Model_Runner.Backend.Device.Forget_Matrices;
      --  Only what was allocated is released. A borrowed span belongs to the
      --  source that gave it and is unmapped when that source closes.
      B.Free (Item.Arena);
      Item.Arena_Base := 0;
      Item.Weights_Base := System.Null_Address;
      Item.Weights_Span := 0;
      Item.Weights_Held := False;
   end Release_Weights;

   --  The feed-forward gate this architecture was trained with.
   --
   --  Gemma's is a Gaussian error unit; everything else here is a logistic
   --  one. The two are close enough that reading a Gemma file with SiLU
   --  produces fluent wrong text rather than anything that looks broken,
   --  which is why this is decided from the architecture rather than left
   --  to a default.
   --  Which unit a gated block puts on its gate arm, as a number a device
   --  can be given. Beside Gate_Activation rather than anywhere else, so the
   --  two cannot come to disagree about which architecture takes which.
   --
   --  @param Item Model whose architecture decides.
   --  @return Zero for the sigmoid-weighted unit, one for the Gaussian one.
   function Gate_Unit (Item : Model'Class) return Natural
   is (if Item.Settings.Kind
          in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
             | Jina_Bert_V2
       then 1 else 0);

   procedure Gate_Activation (Item : Model'Class; Target : in out Real_Array)
   is
   begin
      if Item.Settings.Kind
         in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
            | Jina_Bert_V2
      then
         K.GELU (Target);
      else
         K.SiLU (Target);
      end if;
   end Gate_Activation;

   --  The base a layer turns its rotation on.
   --
   --  One base for the whole model everywhere but Gemma3, which turns the
   --  windowed layers on a base of their own -- a small one for a layer that
   --  looks a few positions back and the model's own for the layer that sees
   --  everything. Asked per layer rather than carried in the plan, because
   --  the alternative is a field that can disagree with the window it is
   --  supposed to follow.
   function Turn_Base
     (Settings : Configuration; Layer : Natural) return N.Wide_Real
   is (if Settings.Local_Base > 0.0
         and then Settings.Window_Every > 0
         and then Layer mod Settings.Window_Every /= Settings.Window_Every - 1
       then Settings.Local_Base
       else Settings.Rope_Base);

   --  A score held under a bound, as the architecture that states one puts
   --  it: cap times the hyperbolic tangent of the score over the cap. Small
   --  scores come back nearly unchanged and large ones stop just under the
   --  cap, which is what keeps one key from taking the whole of a softmax.
   --
   --  A cap of zero is no cap, which is every architecture here but Gemma2.
   function Capped (Score : Real; Cap : Real) return Real
   is (if Cap <= 0.0 then Score
       else Real (N.Wide_Real (Cap)
                  * N.Tanh (N.Wide_Real (Score) / N.Wide_Real (Cap))));

   --  The logits held under the bound the architecture states, if it states
   --  one. Applied to what the caller is about to be given rather than to
   --  the row the engine keeps, because it is part of the model's answer
   --  and not part of its bookkeeping.
   procedure Cap_Logits (Settings : Configuration; Values : in out Real_Array)
   is
   begin
      if Settings.Logit_Cap <= 0.0 then
         return;
      end if;

      for Value of Values loop
         Value := Capped (Value, Settings.Logit_Cap);
      end loop;
   end Cap_Logits;

   --  The last two things done to a row of logits: the bias the output
   --  projection carries, and the bound the architecture puts on what it
   --  produced. Written once and called from each of the three places that
   --  produce logits -- a token at a time, every position of a batch, and
   --  the last position of one -- because the alternative is three copies
   --  and a fourth place that forgets one of them. That is not a
   --  hypothetical either: an architecture whose feed-forward result was
   --  discarded, and a batched path normalized one way where the rest of the
   --  program normalized another, were both a step written beside a branch
   --  rather than after it.
   procedure Finish_Logits
     (Source : Model'Class;
      Values : in out Real_Array) is
   begin
      if Source.Output_Bias /= null
        and then Source.Output_Bias.all'Length = Values'Length
      then
         K.Add (Values, Source.Output_Bias.all);
      end if;

      Cap_Logits (Source.Settings, Values);
   end Finish_Logits;

   --  Whether this model's normalization weights are trained around zero.
   --
   --  Gemma's are, so its gain is one plus the stored weight; every other
   --  architecture here trains them around one and uses the weight as it
   --  stands. Asked of the model rather than carried in the plan, so that
   --  the nine places a normalization happens cannot disagree.
   function Lifted_Norms (Item : Model'Class) return Boolean
   is (Item.Settings.Kind in Gemma | Gemma2 | Gemma3);

   --  Normalize the way the architecture does, into Target.
   --
   --  Falcon, Phi2, GPT2 and Bert centre and carry a bias; everything else
   --  divides by the root mean square and does not. One procedure rather
   --  than a test at each of the nine places a normalization happens,
   --  because nine tests are nine chances to write one of them the other
   --  way round.
   procedure Normalize
     (Item   : Model'Class;
      Source : Real_Array;
      Gain   : Real_Array;
      Bias   : T.Real_Array_Access;
      Target : out Real_Array) is
   begin
      if Item.Settings.Kind
           in Falcon | Phi2 | GPT2 | Bert | Nomic_Bert | Jina_Bert_V2
        and then Bias /= null
      then
         K.Layer_Norm (Source, Gain, Bias.all, Item.Settings.Epsilon, Target);
      else
         K.RMS_Norm (Source, Gain, Item.Settings.Epsilon, Target,
                     Lifted => Lifted_Norms (Item));
      end if;
   end Normalize;

   --  The state a position is left with: what the last layer produced,
   --  through the model's final normalization where it has one.
   --
   --  Bert has not got one, and that is not an omission in the file. Its
   --  layers normalize on the way out of each sublayer rather than on the
   --  way in, so the last thing the last layer did was normalize what it
   --  produced, and a second normalization here would be one the model was
   --  never trained with. What "nothing" has to be is a copy, because every
   --  caller of this writes somewhere other than where it read.
   procedure Final_State
     (Item   : Model'Class;
      Source : Real_Array;
      Target : out Real_Array) is
   begin
      if Item.Output_Norm = null then
         Target := Source;
      else
         Normalize
           (Item, Source, Item.Output_Norm.all, Item.Output_Norm_Bias,
            Target);
      end if;
   end Final_State;

   --  Normalize what a sublayer produced, where the architecture says so.
   --
   --  Gemma2 normalizes on the way out of each sublayer as well as on the
   --  way in; every other architecture here does nothing between the
   --  sublayer and the residual add. Given the layer's gain, which is null
   --  for those, so this is a call that costs a test rather than four call
   --  sites that each have to remember.
   procedure Post_Norm
     (Item   : Model'Class;
      Gain   : T.Real_Array_Access;
      Target : in out Real_Array;

      --  The scratch as a reference rather than as an array, because it is
      --  allocated only for the architecture that needs it: passing
      --  Room.all at a call site would dereference a null buffer for every
      --  architecture that does not, before this procedure could decide it
      --  had nothing to do. It did, and every model in the sweep failed as
      --  an invariant violation.
      Room   : T.Real_Array_Access) is
   begin
      if Gain = null or else Room = null then
         return;
      end if;

      K.RMS_Norm (Target, Gain.all, Item.Settings.Epsilon, Room.all,
                  Lifted => Lifted_Norms (Item));
      Target := Room.all;
   end Post_Norm;

   --  Add what a sublayer produced to the residual, normalizing on whichever
   --  side of the add the architecture normalizes.
   --
   --  Two arrangements meet here. Gemma2 normalizes what the sublayer
   --  produced and adds that to the residual; Bert adds it and then
   --  normalizes the sum. The same two tensors, read in the same two places,
   --  computing different models -- and the only thing that distinguishes
   --  them is which side of the add falls under the normalization.
   --
   --  Written once for that reason. A sublayer joins a residual at four
   --  places in this file, and a difference this quiet, repeated four times,
   --  is a difference three of them would eventually stop having.
   procedure Join_Residual
     (Item     : Model'Class;
      Produced : in out Real_Array;
      Residual : in out Real_Array;
      Gain     : T.Real_Array_Access;
      Bias     : T.Real_Array_Access;
      Room     : T.Real_Array_Access) is
   begin
      if not Normalizes_After (Item.Settings.Kind) then
         Post_Norm (Item, Gain, Produced, Room);
         K.Add (Residual, Produced);
         return;
      end if;

      K.Add (Residual, Produced);

      if Gain /= null and then Room /= null then
         Normalize (Item, Residual, Gain.all, Bias, Room.all);
         Residual := Room.all;
      end if;
   end Join_Residual;

   --  What the embedding row is multiplied by before the first layer.
   --
   --  One everywhere but Gemma, which scales by the square root of the
   --  embedding width -- about forty on a model of a useful size, so a file
   --  read without it produces text rather than a refusal, and the text is
   --  wrong. Computed here rather than stored, because it is one square root
   --  per token and the alternative is a field that can disagree with the
   --  architecture that decides it.
   function Embedding_Scale (Item : Model'Class) return Real
   is (if Item.Settings.Kind in Gemma | Gemma2 | Gemma3
       then Real (N.Sqrt (N.Wide_Real (Item.Settings.Embedding)))
       else 1.0);

   -------------
   -- Prepare --
   -------------

   ------------------
   -- Use_Template --
   ------------------

   procedure Use_Template
     (Item   : in out Model;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Model_Runner.Templates.Close (Item.Chat);
      Model_Runner.Templates.Compile (Item.Chat, Source, Bounds, Status);
      Item.Chat_Present := E.Is_Ok (Status);
      Item.Chat_Status := Status;
   end Use_Template;

   procedure Prepare
     (Item     : in out Model;
      Source   : Containers.Container;
      Bytes    : in out Model_Runner.Byte_Sources.Source'Class;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Backend  : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Repack   : Repack_Mode := No_Repack;
      Fit_Required : Boolean := True;
      Threads  : Positive := 1;
      Status   : out E.Error_Info)
   is
      Ignored : E.Error_Info;

      --  Abandon preparation, releasing every resource acquired so far.
      procedure Fail (Reason : E.Error_Info) is
      begin
         Close (Item, Ignored);
         Status := Reason;
      end Fail;

   begin
      Close (Item, Ignored);
      Status := E.Success;

      if not Containers.Is_Valid (Source) then
         Fail (E.Make (E.Lifecycle_Model_Not_Ready));
         return;
      end if;

      Mem.Initialize (Item.Accounting, Bounds, Bounds.Max_Model_Bytes);

      --  The backend's own account of what it can do, taken once and kept
      --  with the model. The case has no others: a backend added to the
      --  enumeration stops this compiling until it says what it can read,
      --  which is the point of asking rather than assuming.
      P.Publish (Observer, P.Load_Progress (P.Selecting_Backend));
      case Backend is
         when Model_Runner.Backend.Backend_CPU =>
            Item.Able := Workers_CPU.Describe;
         when Model_Runner.Backend.Backend_Reference =>
            Item.Able := Model_Runner.Backend.Reference.Describe;
         when Model_Runner.Backend.Backend_Device =>
            Item.Able := Model_Runner.Backend.Device.Describe;
      end case;

      --  Evaluation is matrix by vector and nothing else. A backend that
      --  cannot do that cannot run a model, and says so here rather than
      --  part way through the first token.
      if not Item.Able.Supports_Matrix_Vector then
         Fail (E.Make (E.Backend_Capability_Missing));
         E.Add_Text
           (Status, "capability", "matrix_vector", E.Param_Identifier);
         E.Add_Text
           (Status, "backend",
            Model_Runner.Backend.Backend_Name (Item.Able.Kind),
            E.Param_Identifier);
         return;
      end if;

      P.Publish (Observer, P.Load_Progress (P.Selecting_Architecture));
      Read_Configuration (Source, Bounds, Item.Settings, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      P.Publish (Observer, P.Load_Progress (P.Loading_Tokenizer));
      Model_Runner.Tokenizer.Load (Item.Words, Source, Bounds, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      Item.Settings.Vocabulary := Model_Runner.Tokenizer.Size (Item.Words);

      --  The vocabulary's own storage and the container's metadata pool.
      --  Both are megabytes on a real model and neither was counted, so the
      --  account said the program held the weights and nothing else.
      Mem.Record_Allocation
        (Item.Accounting, Mem.Tokenizer_Storage,
         Interfaces.Unsigned_64
           (Model_Runner.Tokenizer.Storage_Bytes (Item.Words)));
      Mem.Record_Allocation
        (Item.Accounting, Mem.Metadata_Storage,
         Containers.Metadata_Bytes (Source));

      --  Chat template. An embedded template is untrusted data: it is compiled
      --  and validated here, before anything can be generated with it. A
      --  template outside the supported subset leaves the model usable in raw
      --  mode and records why conversation mode is unavailable.
      P.Publish (Observer, P.Load_Progress (P.Compiling_Template));
      declare
         Source_Text : constant String :=
           Containers.String_Value (Source, "tokenizer.chat_template");
      begin
         Item.Chat_Present := Source_Text /= "";
         if Item.Chat_Present then
            Model_Runner.Templates.Compile
              (Item.Chat, Source_Text, Bounds, Item.Chat_Status);
         else
            Item.Chat_Status := E.Make (E.Template_Missing);
         end if;
      end;

      P.Publish (Observer, P.Load_Progress (P.Planning_Memory));

      --  Load the whole tensor data section into one arena. Every tensor view
      --  then refers to a slice of it, so there is exactly one large
      --  allocation for model weights and no second unquantized copy.
      declare
         Length : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Data_Bytes (Source));
      begin
         Item.Arena_Base := B.Byte_Count (Containers.Data_Offset (Source));

         --  Where the source says its bytes already are. A mapped file
         --  answers with its mapping, and then nothing is allocated and
         --  nothing is copied: the weights are the file's own pages, faulted
         --  in as they are read. A source that cannot say answers with
         --  nothing and is read into an arena, as every source was.
         --  Only a mapping is borrowed, and only when it holds the whole
         --  tensor section. A source that is already an array in this
         --  process could say where it is too, and is not asked: that array
         --  belongs to whoever passed it and may be freed while the model
         --  still refers to it, where a mapping belongs to the source and
         --  lives exactly as long as it does.
         if Bytes.Is_Mapped
           and then Bytes.Base /= System.Null_Address
           and then Bytes.Size >= Item.Arena_Base + Length

           --  Unless the device was opened to read the weights where they
           --  lie. Both ways avoid a copy and they are exclusive: the driver
           --  imports host memory it can pin and refuses a file's pages, so
           --  a caller who asked for the device to take the model's memory
           --  is given memory the device will take.
           and then not
             (Model_Runner.Backend."="
                (Backend, Model_Runner.Backend.Backend_Device)
              and then Model_Runner.Backend.Device.Shares_Host)
         then
            Item.Weights_Base :=
              System.Storage_Elements.To_Address
                (System.Storage_Elements.To_Integer (Bytes.Base)
                 + System.Storage_Elements.Integer_Address (Item.Arena_Base));
            Item.Weights_Span := Length;
            Item.Weights_Held := False;

            --  Counted as what it is. A read-only mapping costs address
            --  space rather than resident pages, so it is not charged
            --  against the memory limit and does not appear as memory this
            --  program is holding -- which is the whole of the difference
            --  between mapping a model and reading one.
            Mem.Record_Mapping
              (Item.Accounting, Interfaces.Unsigned_64 (Length));
         else
            Mem.Check_Allocation
              (Item.Accounting, Mem.Model_Weights,
               Interfaces.Unsigned_64 (Length), Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;

            B.Allocate (Length, Item.Arena);
            if Item.Arena = null then
               Fail (E.Make (E.Memory_Allocation_Failed));
               return;
            end if;

            Mem.Record_Allocation
              (Item.Accounting, Mem.Model_Weights,
               Interfaces.Unsigned_64 (Length));

            Item.Weights_Base := Item.Arena.all'Address;
            Item.Weights_Span := B.Byte_Count (Item.Arena.all'Length);
            Item.Weights_Held := True;
         end if;

         --  The file is validated, and now it is read. Between those two
         --  moments it may have been replaced -- a download finishing over
         --  it, a build writing a new quantization to the same path -- and
         --  what would then be read is a different file wearing the shape of
         --  the one that was checked. Asked here because here is the last
         --  moment it is still true that nothing has been read.
         if Bytes.Changed then
            Fail (E.Make (E.GGUF_File_Changed));
            return;
         end if;

         P.Publish (Observer, P.Load_Progress (P.Preparing_Tensors));

         if Item.Weights_Held then
            Bytes.Read (Item.Arena_Base, Item.Arena.all, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;
      end;

      if C.Is_Cancelled (Cancel) then
         Fail (E.Make (E.Generation_Cancelled));
         return;
      end if;

      declare
         Width  : constant Element_Count :=
           Element_Count (Item.Settings.Embedding);
         Vocab  : constant Element_Count :=
           Element_Count (Item.Settings.Vocabulary);
         Feed   : constant Element_Count :=
           Element_Count (Item.Settings.Feed_Forward);
         --  What the attention tensors are shaped by. The queries are as
         --  many heads of key width; the keys are the key-value heads of the
         --  same; the values are those heads of value width; and what the
         --  output projection reads is the heads' worth of value width,
         --  which is the embedding width only when the two agree.
         Wide   : constant Element_Count :=
           Element_Count (Item.Settings.Heads * Item.Settings.Head_Size);
         KV     : constant Element_Count :=
           Element_Count (Item.Settings.KV_Heads * Item.Settings.Head_Size);
         KV_Out : constant Element_Count :=
           Element_Count (Item.Settings.KV_Heads * Item.Settings.Value_Size);
         Blend  : constant Element_Count :=
           Element_Count (Item.Settings.Heads * Item.Settings.Value_Size);
      begin
         Resolve
           (Item, Source, "token_embd.weight", Vocab, Width,
            Item.Embeddings, Status, Repack);

         --  And the table of positions, for the architecture that learns
         --  where a token is rather than rotating for it. One row a
         --  position, as wide as the embedding, and read exactly once a
         --  token -- there is no rotation anywhere in such a model, so this
         --  is the whole of its position handling.
         if E.Is_Ok (Status) and then Item.Settings.Kind in GPT2 | Bert then
            Resolve
              (Item, Source, "position_embd.weight",
               Element_Count (Item.Settings.Context_Length), Width,
               Item.Positions, Status, Repack);
         end if;
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         --  Bert learns a third row beside those two: which segment of the
         --  input a token belongs to. Two rows, and this reads the first of
         --  them for every position, because a text embedded here is one
         --  segment -- the second is what a model trained on sentence pairs
         --  uses to tell the halves apart, and there is no way to ask for a
         --  pair through this program.
         --
         --  Required where the architecture states it. A file without it is
         --  not a bert with one embedding missing; it is a file describing a
         --  model this does not compute, and reading it as though the
         --  segment row were zero would answer with an embedding that is
         --  wrong by whatever that row holds.
         if E.Is_Ok (Status) and then Item.Settings.Segments > 0 then
            Resolve
              (Item, Source, "token_types.weight",
               Element_Count (Item.Settings.Segments), Width,
               Item.Segments, Status, Repack);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;

         --  And the normalization over the sum of the three, before the
         --  first layer sees it. Bert normalizes what it embedded; every
         --  other architecture here hands layer zero the embedding row as it
         --  stands, or scales it by a constant, and has no tensor for this.
         if E.Is_Ok (Status)
           and then Normalizes_After (Item.Settings.Kind)
         then
            Resolve_Norm
              (Item, Source, "token_embd_norm.weight", Width,
               Item.Embedding_Norm, Status);
            if E.Is_Ok (Status) then
               Resolve_Norm
                 (Item, Source, "token_embd_norm.bias", Width,
                  Item.Embedding_Norm_Bias, Status);
            end if;
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;

         --  The normalization between the last layer and whatever reads it.
         --  Every architecture here has one except Bert, whose layers
         --  normalize on the way out rather than on the way in: the last
         --  thing its last layer did was normalize what it produced, and a
         --  file carrying a tensor for a second one would be describing a
         --  model this does not compute.
         if not Normalizes_After (Item.Settings.Kind) then
            Resolve_Norm
              (Item, Source, "output_norm.weight", Width, Item.Output_Norm,
               Status);

            if E.Is_Ok (Status)
              and then Item.Settings.Kind in Falcon | Phi2 | GPT2
            then
               Resolve_Norm
                 (Item, Source, "output_norm.bias", Width,
                  Item.Output_Norm_Bias, Status);
            end if;
         end if;
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         --  A table of per-dimension divisors for the rotation, when the
         --  model carries one. This is how a file states a stretch that is
         --  not one number: the conversion works the schedule out and writes
         --  it as a tensor, and a model carrying one and not having it
         --  applied would rotate every long-range dimension wrongly while
         --  looking entirely healthy on a short prompt.
         if Containers.Find_Tensor (Source, "rope_freqs.weight") /= 0 then
            Resolve_Norm
              (Item, Source, "rope_freqs.weight",
               Element_Count (Item.Settings.Rotary / 2), Item.Rope_Factors,
               Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;

         --  A model with no output projection ties the output to the embedding
         --  table. The alias is explicit and immutable; nothing is copied.
         --
         --  Except for a model that has no head to tie. Bert produces states
         --  and stops, and its embedding table read backwards is not the
         --  projection it never trained -- so the tie is not made, and what
         --  asks for a distribution is refused by name instead of given the
         --  numbers that arrangement would produce. Which architectures
         --  those are is settled where the profile is read, so that
         --  `inspect` can say it without resolving a tensor.
         if not Item.Settings.Has_Head then
            null;
         elsif Containers.Find_Tensor (Source, "output.weight") = 0 then
            Item.Settings.Tied_Output := True;
            Item.Output := Item.Embeddings;
         else
            Resolve
              (Item, Source, "output.weight", Vocab, Width,
               Item.Output, Status, Repack);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;

            --  And the bias on it, which Phi2 carries and GPT2 does not.
            --  It is added after the last projection, so it is the last
            --  thing between the model and the caller.
            --
            --  GPT2 was here until a published gpt2 file was read and had no
            --  such tensor. The fixture wrote one because this asked for
            --  one, so the sweep agreed with itself about a model nobody
            --  ships -- which is the failure mode a synthetic fixture has
            --  and a real file does not.
            if Item.Settings.Kind = Phi2 then
               Resolve_Norm
                 (Item, Source, "output.bias", Vocab,
                  Item.Output_Bias, Status);
               if E.Is_Error (Status) then
                  Fail (Status);
                  return;
               end if;
            end if;
         end if;

         Item.Layers := new Layer_Array (0 .. Item.Settings.Layers - 1);

         for Index in Item.Layers.all'Range loop
            if C.Is_Cancelled (Cancel) then
               Fail (E.Make (E.Generation_Cancelled));
               return;
            end if;

            declare
               Current : Layer renames Item.Layers.all (Index);
            begin
               --  The normalization a block is given on the way in. Every
               --  architecture here has one except Bert, which normalizes
               --  on the way out of each sublayer instead and carries no
               --  tensor for this at all.
               if not Normalizes_After (Item.Settings.Kind) then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_norm.weight"),
                     Width, Current.Attention_Norm, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  Bert's two, which are the whole of its normalization: one
               --  over the residual after attention has been added to it,
               --  one over the residual after the feed-forward has. Both
               --  centre and both carry a shift, so both take a bias where
               --  Gemma2's post-normalizations take none.
               --
               --  They are read into the same two fields Gemma2 uses and
               --  applied in a different place, which is the whole
               --  difference between the two arrangements: Gemma2
               --  normalizes what the sublayer produced and adds that,
               --  and Bert adds what the sublayer produced and normalizes
               --  the sum.
               if Normalizes_After (Item.Settings.Kind) then
                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "attn_output_norm.weight"), Width,
                     Current.Post_Attention_Norm, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "attn_output_norm.bias"), Width,
                     Current.Post_Attention_Norm_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "layer_output_norm.weight"), Width,
                     Current.Post_Feed_Norm, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "layer_output_norm.bias"), Width,
                     Current.Post_Feed_Norm_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  What the code variant of this architecture carries and
               --  the text one does not: a third normalization inside the
               --  attention sublayer, and one over the queries and one over
               --  the keys. None of the three is computed here, and a file
               --  carrying any of them is refused by name rather than read
               --  as a model with three normalizations missing -- which is
               --  an embedding, and a plausible one.
               if Item.Settings.Kind = Jina_Bert_V2 then
                  for Name of Unread_Jina_Norms loop
                     if Containers.Find_Tensor
                          (Source, Layer_Key (Index, Name.all)) /= 0
                     then
                        Status := E.Make (E.Arch_Unsupported_Feature);
                        E.Add_Text
                          (Status, "feature", Name.all, E.Param_Identifier);
                        exit;
                     end if;
                  end loop;
                  exit when E.Is_Error (Status);
               end if;

               --  Gemma2 normalizes what each sublayer produced as well as
               --  what it was given. Required rather than optional: a
               --  gemma2 file without them is not one this build can
               --  compute, and taking them if present would read such a
               --  file as a model with two normalizations missing.
               if Item.Settings.Kind in Gemma2 | Gemma3 then
                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "post_attention_norm.weight"), Width,
                     Current.Post_Attention_Norm, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "post_ffw_norm.weight"), Width,
                     Current.Post_Feed_Norm, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  Three projections out of one tensor where the
               --  architecture fuses them, and three tensors where it does
               --  not. The order inside the fused one is queries, then
               --  keys, then values, which is the order the rows are
               --  written in.
               if Item.Settings.Kind in Falcon | Phi2 | GPT2 then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_norm.bias"),
                     Width, Current.Attention_Norm_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               if Item.Settings.Kind
                  in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert
               then
                  Resolve_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
                     Wide + KV + KV_Out, Width, 0, Wide,
                     Current.Query, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
                     Wide + KV + KV_Out, Width, Wide, KV,
                     Current.Key, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
                     Wide + KV + KV_Out, Width, Wide + KV, KV_Out,
                     Current.Value, Status, Repack);
                  exit when E.Is_Error (Status);
               else
                  Resolve
                    (Item, Source, Layer_Key (Index, "attn_q.weight"),
                     Wide, Width, Current.Query, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "attn_k.weight"),
                     KV, Width, Current.Key, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "attn_v.weight"),
                     KV_Out, Width, Current.Value, Status, Repack);
                  exit when E.Is_Error (Status);
               end if;

               --  Qwen2 adds a bias to each projection; Llama and Qwen3
               --  have none. Required when the architecture says so rather
               --  than taken if present: a qwen2 file without them is a file
               --  this cannot evaluate, and reading it as though the biases
               --  were zero would produce plausible text that is not what
               --  the model says.
               --  Phi2 biases the same three projections, and writes the
               --  three biases in one vector as it writes the three matrices
               --  in one tensor. Each part is taken from the same offset its
               --  matrix is taken from, so a reader that splits the matrices
               --  correctly and the biases some other way would be wrong
               --  only in what it adds -- which reads as a model that has
               --  drifted rather than one that has broken.
               if Item.Settings.Kind in Phi2 | GPT2 then
                  Resolve_Norm_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
                     Wide + KV + KV_Out, 0, Wide, Current.Query_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
                     Wide + KV + KV_Out, Wide, KV, Current.Key_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm_Part
                    (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
                     Wide + KV + KV_Out, Wide + KV, KV_Out,
                     Current.Value_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  Bert biases the same three and writes them as Qwen2
               --  does, one vector a projection rather than three in one,
               --  and jina-bert-v2 does the same.
               if Item.Settings.Kind in Qwen2 | Bert | Jina_Bert_V2 then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_q.bias"),
                     Wide, Current.Query_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_k.bias"),
                     KV, Current.Key_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_v.bias"),
                     KV_Out, Current.Value_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  Qwen3 normalizes each query head and each key head before
               --  the rotation, with one gain per element of a head shared
               --  across the heads. Required for the architectures that have
               --  it, for the same reason the biases are.
               if Item.Settings.Kind in Qwen3 | Qwen3_MoE | Gemma3 then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_q_norm.weight"),
                     Element_Count (Item.Settings.Head_Size),
                     Current.Query_Norm, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_k_norm.weight"),
                     Element_Count (Item.Settings.Head_Size),
                     Current.Key_Norm, Status);
                  exit when E.Is_Error (Status);
               end if;

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_output.weight"),
                  Width, Blend, Current.Attention_Out, Status, Repack);
               exit when E.Is_Error (Status);

               --  And the bias on the way out of attention, which Phi2,
               --  GPT2, Bert and jina-bert-v2 have and the rest have not.
               if Item.Settings.Kind in Phi2 | GPT2 | Bert | Jina_Bert_V2
               then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_output.bias"),
                     Width, Current.Out_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               --  Falcon has one normalization a block, not two: attention
               --  and the feed-forward read the same normalized input. The
               --  feed norm stays null and the block below reads that.
               if Item.Settings.Kind not in Falcon | Phi2
                 and then not Normalizes_After (Item.Settings.Kind)
               then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ffn_norm.weight"),
                     Width, Current.Feed_Norm, Status);
                  exit when E.Is_Error (Status);

                  --  The shift beside it, where the architecture centres.
                  --  Falcon and phi2 never reach here -- they have one
                  --  normalization a block -- so this is gpt2's, and it was
                  --  missing: the file carries it, the engine read every
                  --  other layer-norm shift, and the feed-forward ran off a
                  --  normalization that was neither centred nor shifted.
                  --  Optional, and deliberately so. Requiring it would
                  --  refuse a file that does not carry one, which is the
                  --  trap this architecture's output bias already fell
                  --  into: the loader asked for a tensor because the
                  --  fixture wrote it, and a published model was refused.
                  if Item.Settings.Kind in Falcon | Phi2 | GPT2
                    and then Containers.Find_Tensor
                               (Source, Layer_Key (Index, "ffn_norm.bias"))
                             /= 0
                  then
                     Resolve_Norm
                       (Item, Source, Layer_Key (Index, "ffn_norm.bias"),
                        Width, Current.Feed_Norm_Bias, Status);
                     exit when E.Is_Error (Status);
                  end if;
               end if;

               if Item.Settings.Kind in Falcon | Phi2 | GPT2 | Bert then
                  --  No gate: one projection up, a Gaussian unit, one down.
                  --  The gate stays null, and the block below reads that
                  --  rather than the architecture.
                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_up.weight"),
                     Feed, Width, Current.Up, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_down.weight"),
                     Width, Feed, Current.Down, Status, Repack);
                  exit when E.Is_Error (Status);

                  --  A bias on each side of the block, which Phi2 has and
                  --  Falcon does not, so the arrangement they share is not
                  --  what decides this.
                  if Item.Settings.Kind in Phi2 | GPT2 | Bert then
                     Resolve_Norm
                       (Item, Source, Layer_Key (Index, "ffn_up.bias"),
                        Feed, Current.Up_Bias, Status);
                     exit when E.Is_Error (Status);

                     Resolve_Norm
                       (Item, Source, Layer_Key (Index, "ffn_down.bias"),
                        Width, Current.Down_Bias, Status);
                     exit when E.Is_Error (Status);
                  end if;

               elsif Item.Settings.Experts = 0
                 and then Item.Settings.Kind = Phi3
               then
                  --  The gate and the up projection in one tensor, gate
                  --  first. Taking them the other way round is a model that
                  --  gates on what it should be scaling, which reads as
                  --  fluent nonsense rather than as a refusal.
                  Resolve_Part
                    (Item, Source, Layer_Key (Index, "ffn_up.weight"),
                     Feed * 2, Width, 0, Feed,
                     Current.Gate, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve_Part
                    (Item, Source, Layer_Key (Index, "ffn_up.weight"),
                     Feed * 2, Width, Feed, Feed,
                     Current.Up, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_down.weight"),
                     Width, Feed, Current.Down, Status, Repack);
                  exit when E.Is_Error (Status);

               elsif Item.Settings.Experts = 0 then
                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_gate.weight"),
                     Feed, Width, Current.Gate, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_up.weight"),
                     Feed, Width, Current.Up, Status, Repack);
                  exit when E.Is_Error (Status);

                  Resolve
                    (Item, Source, Layer_Key (Index, "ffn_down.weight"),
                     Width, Feed, Current.Down, Status, Repack);
                  exit when E.Is_Error (Status);

                  --  The one gated architecture here that shifts what it
                  --  projects down. Every other one carries no bias
                  --  anywhere in its feed-forward, which is why this is
                  --  asked for by architecture and not taken if present.
                  if Item.Settings.Kind = Jina_Bert_V2 then
                     Resolve_Norm
                       (Item, Source, Layer_Key (Index, "ffn_down.bias"),
                        Width, Current.Down_Bias, Status);
                     exit when E.Is_Error (Status);
                  end if;
               else
                  Resolve_Experts
                    (Item, Source, Index, Current, Status, Repack);
                  exit when E.Is_Error (Status);
               end if;
            end;
         end loop;

         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end;

      --  Decode the weight matrices once, if that was asked for.
      --
      --  Every matrix then refers into a second buffer holding binary32,
      --  and nothing else changes: the values written are the ones the
      --  decoder produces, in the order the kernels read them, so what
      --  follows is the same arithmetic on the same numbers. What it costs
      --  is four bytes a weight against about one, which is why it is asked
      --  for rather than done.
      if Repack /= No_Repack then
         P.Publish (Observer, P.Load_Progress (P.Repacking_Weights));

         declare
            --  Bytes a weight, and the format the copy is written in.
            Width : constant B.Byte_Count :=
              (if Repack = To_BF16 then 2 else 4);
            Format : constant Model_Runner.GGUF.Tensor_Type :=
              (if Repack = To_BF16
               then Model_Runner.GGUF.Type_BF16
               else Model_Runner.GGUF.Type_F32);

            use type Interfaces.Unsigned_32;

            Needed : B.Byte_Count := 0;

            --  The ones that need decoding, out of the matrices this
            --  model holds. A matrix already in the target format is
            --  nothing to decode: copying it would double the memory to buy
            --  nothing, which is what the first version of this did to
            --  every binary32 tensor in a file.
            Skipped : Natural := 0;

            function To_Decode return View_List is
               Whole : constant View_List := Matrices (Item);
               Room  : View_List (Whole'Range);
               Count : Natural := 0;

               Target : constant Model_Runner.GGUF.Tensor_Type :=
                 (if Repack = To_BF16
                  then Model_Runner.GGUF.Type_BF16
                  else Model_Runner.GGUF.Type_F32);
            begin
               for Where of Whole loop
                  if Model_Runner.GGUF."=" (Where.all.Format, Target) then
                     Skipped := Skipped + 1;
                  else
                     Count := Count + 1;
                     Room (Count) := Where;
                  end if;
               end loop;

               return Room (1 .. Count);
            end To_Decode;

            Held : constant View_List := To_Decode;
         begin
            for Where of Held loop
               Needed := Needed
                 + B.Byte_Count (Where.all.Rows)
                   * B.Byte_Count (Where.all.Columns) * Width;
            end loop;

            --  Asked for before it is taken, like the weights themselves.
            --  Repacking is four bytes a weight where the file holds about
            --  one, so a memory limit that the model fits under is a limit
            --  the repacked copy may not, and a caller who set one meant it.
            Mem.Check_Allocation
              (Item.Accounting, Mem.Converted_Weights,
               Interfaces.Unsigned_64 (Needed), Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;

            B.Allocate (Needed, Item.Repacked);
            if Item.Repacked = null then
               Fail (E.Make (E.Memory_Allocation_Failed));
               return;
            end if;

            Mem.Record_Allocation
              (Item.Accounting, Mem.Converted_Weights,
               Interfaces.Unsigned_64 (Needed));
            Mem.Record_Conversion
              (Item.Accounting, Interfaces.Unsigned_64 (Needed));

            --  Where each matrix's copy begins, computed before anything
            --  is written so that the decoding can be handed out.
            declare
               Bases : array (Held'Range) of B.Byte_Count :=
                 [others => 0];
               Trouble : E.Error_Info := E.Success;

               --  Which matrix to take next. A queue rather than a slice
               --  per task: the matrices differ by a factor of ten in size,
               --  and a fair-looking split by count is not a fair split of
               --  the work.
               protected Shared is
                  procedure Take (Index : out Natural);
                  procedure Note (Reason : E.Error_Info);
                  function Reason return E.Error_Info;
               private
                  Next : Natural := Held'First;
                  Bad  : E.Error_Info := E.Success;
               end Shared;

               protected body Shared is
                  procedure Take (Index : out Natural) is
                  begin
                     if Next > Held'Last or else E.Is_Error (Bad) then
                        Index := 0;
                     else
                        Index := Next;
                        Next := Next + 1;
                     end if;
                  end Take;

                  procedure Note (Reason : E.Error_Info) is
                  begin
                     if E.Is_Ok (Bad) then
                        Bad := Reason;
                     end if;
                  end Note;

                  function Reason return E.Error_Info is (Bad);
               end Shared;

               --  One matrix, decoded into its own region.
               procedure Decode_One (Which : Positive) is
                  Where   : constant View_Access := Held (Which);
                  Rows    : constant Element_Count := Where.all.Rows;
                  Columns : constant Element_Count := Where.all.Columns;
                  Base    : constant B.Byte_Count := Bases (Which);
                  Row     : T.Real_Array (0 .. Columns - 1) := [others => 0.0];
                  Local   : E.Error_Info;
               begin
                  for Index in 0 .. Rows - 1 loop
                     T.Dequantize_Row (Where.all, Index, Row, Local);
                     if E.Is_Error (Local) then
                        Shared.Note (Local);
                        return;
                     end if;

                     for Column in Row'Range loop
                        declare
                           At_Byte : constant B.Byte_Count :=
                             Base
                             + (B.Byte_Count (Index) * B.Byte_Count (Columns)
                                + B.Byte_Count (Column)) * Width;
                        begin
                           if Repack = To_BF16 then
                              declare
                                 Whole : constant Interfaces.Unsigned_32 :=
                                   N.Bits (Row (Column));
                                 Round : constant Interfaces.Unsigned_32 :=
                                   16#7FFF#
                                   + (Interfaces.Shift_Right (Whole, 16)
                                      and 1);
                              begin
                                 Item.Repacked.all
                                   (Item.Repacked.all'First + At_Byte
                                    .. Item.Repacked.all'First + At_Byte + 1)
                                   := B.Put_U16
                                        (Interfaces.Unsigned_16
                                           (Interfaces.Shift_Right
                                              (Whole + Round, 16)
                                            and 16#FFFF#));
                              end;
                           else
                              Item.Repacked.all
                                (Item.Repacked.all'First + At_Byte
                                 .. Item.Repacked.all'First + At_Byte + 3) :=
                                B.Put_F32 (Row (Column));
                           end if;
                        end;
                     end loop;

                     if C.Is_Cancelled (Cancel) then
                        Shared.Note (E.Make (E.Generation_Cancelled));
                        return;
                     end if;
                  end loop;
               end Decode_One;

               task type Decoder;

               task body Decoder is
                  Which : Natural;
               begin
                  loop
                     Shared.Take (Which);
                     exit when Which = 0;
                     Decode_One (Which);
                  end loop;
               exception
                  when others =>
                     Shared.Note (E.Make (E.Internal_Invariant_Violated));
               end Decoder;
            begin
               declare
                  Running : B.Byte_Count := 0;
               begin
                  for Index in Held'Range loop
                     Bases (Index) := Running;
                     Running := Running
                       + B.Byte_Count (Held (Index).all.Rows)
                         * B.Byte_Count (Held (Index).all.Columns) * Width;
                  end loop;
               end;

               declare
                  Team : array (1 .. Positive'Min (Threads, Held'Length))
                    of Decoder;
                  pragma Unreferenced (Team);
               begin
                  null;
               end;

               Trouble := Shared.Reason;
               if E.Is_Error (Trouble) then
                  Fail (Trouble);
                  return;
               end if;

               for Index in Held'Range loop
                  declare
                     Fresh : T.View;
                  begin
                     T.Make
                       (Format  => Format,
                        Rows    => Held (Index).all.Rows,
                        Columns => Held (Index).all.Columns,
                        Data    => Item.Repacked,
                        Offset  => Bases (Index),
                        Result  => Fresh,
                        Status  => Status);
                     if E.Is_Error (Status) then
                        Fail (Status);
                        return;
                     end if;
                     Held (Index).all := Fresh;
                  end;
               end loop;
            end;

            --  Only when nothing is left pointing at it. A matrix already
            --  in the target format is not copied, and its view still
            --  refers into the file's bytes -- freeing them under it read
            --  outside its storage on the first product, which is what an
            --  all-binary32 file did the moment the skip was added.
            if Skipped = 0 then
               declare
                  Was : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Item.Weights_Span);
               begin
                  Release_Weights (Item);
                  Mem.Record_Release
                    (Item.Accounting, Mem.Model_Weights, Was);
               end;
            end if;
         end;
      end if;

      --  And whether the backend has room for what those matrices now are.
      --
      --  Asked after any repacking, because repacking is what changes the
      --  answer: a model that fits a device as it is stored may not fit it
      --  at four bytes a weight. Asked before the model is declared ready,
      --  because being told after a minute of loading is being told a minute
      --  late.
      --
      --  This is a warning in the shape of a refusal and it is a refusal on
      --  purpose. A model larger than the device's share still runs -- what
      --  does not fit is given back and uploaded again as it is wanted --
      --  but it runs slower than the processor would, and quietly. A caller
      --  who wants that can say --repack none, choose another backend, or
      --  raise nothing at all and be told what the numbers were.
      if Fit_Required and then Item.Able.Memory_Bytes > 0 then
         declare
            Held  : constant View_List := Matrices (Item);
            Total : Interfaces.Unsigned_64 := 0;

            --  Distinct storage, because a model with a tied output holds
            --  one matrix under two names and a device asked to keep it
            --  twice keeps it once: the address is the key.
            function Counted_Before (Upto : Natural) return Boolean is
            begin
               for Earlier in Held'First .. Upto - 1 loop
                  if Held (Earlier).all.Base = Held (Upto).all.Base
                    and then Held (Earlier).all.Offset
                             = Held (Upto).all.Offset
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end Counted_Before;
         begin
            for Index in Held'Range loop
               if not Counted_Before (Index) then
                  Total := Total
                    + Interfaces.Unsigned_64 (Held (Index).all.Rows)
                      * Interfaces.Unsigned_64 (T.Row_Bytes (Held (Index).all));
               end if;
            end loop;

            if Total > Item.Able.Memory_Bytes then
               Status := E.Make (E.Memory_Limit_Exceeded);

               --  Every parameter the message names, because a message
               --  missing one renders as its own key and says nothing at
               --  all. The category is the backend's memory rather than one
               --  of the accounting's, which is what this limit is about.
               E.Add_Text
                 (Status, "category", "backend_memory", E.Param_Identifier);
               E.Add_Integer
                 (Status, "requested", Long_Long_Integer (Total),
                  E.Param_Bytes);
               E.Add_Integer
                 (Status, "limit",
                  Long_Long_Integer (Item.Able.Memory_Bytes), E.Param_Bytes);
               E.Add_Text
                 (Status, "backend",
                  Model_Runner.Backend.Backend_Name (Item.Able.Kind),
                  E.Param_Identifier);
               Fail (Status);
               return;
            end if;
         end;
      end if;

      P.Publish (Observer, P.Load_Progress (P.Finalizing_Model));
      Item.Packing := Repack;
      Item.Ready := True;
      P.Publish (Observer, P.Load_Progress (P.Model_Ready));
      Status := E.Success;
   exception
      when Occurrence : others =>
         Close (Item, Ignored);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "llama.prepare");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Prepare;

   -----------
   -- Close --
   -----------

   ----------------
   -- Accounting --
   ----------------

   function Accounting (Item : Model) return Mem.Account
   is (Item.Accounting);

   ----------------
   -- Capability --
   ----------------

   function Capability
     (Item : Model) return Model_Runner.Backend.Capabilities
   is (Item.Able);

   function Accounting (Item : Session) return Mem.Account
   is (Item.Accounting);

   --  The product, through whichever backend this session was opened for.
   --
   --  Every matrix product in the engine goes through these two, so the
   --  choice is made once rather than at sixteen call sites. The CPU backend
   --  takes the pool; the reference backend has none and does not want one.
   procedure Product
     (Item   : Session;
      Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info) is
   begin
      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch (Item.Team, Weight, Vector, Target, Status);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product
              (Weight, Vector, Target, Status);
         when Model_Runner.Backend.Backend_Device =>
            Model_Runner.Backend.Device.Dispatch
              (Weight, Vector, Target, Status, Item.Stopping);
      end case;
   end Product;

   --  Several matrices against one activation, as one thing where that is
   --  worth something.
   --
   --  The places a block reads more than one matrix from the same input with
   --  nothing between them: its queries, keys and values, and the gate and up
   --  projection of a gated feed-forward. A device can be told, and then it
   --  costs one upload of that input, one command buffer, one submission and
   --  one wait instead of one of each per matrix. The processor and the
   --  reference gain nothing from being told -- their work is the arithmetic,
   --  not the errand -- so they do what they did, one product after another,
   --  and the difference stays inside here rather than becoming a shape every
   --  backend has to answer for.
   --
   --  @param Item Session the layer belongs to.
   --  @param Weights The matrices, in the order their results are wanted.
   --  @param Vector The activation all of them read.
   --  @param Into Receives each matrix's result, in the same order.
   --  @param Status Success, or the first refusal among them.
   procedure Product_Group
     (Item    : Session;
      Weights : T.View_Group;
      Vector  : T.Real_Array_Access;
      Into    : T.Target_Group;
      Status  : out E.Error_Info)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      if Item.Owner.Able.Kind = Model_Runner.Backend.Backend_Device then
         Model_Runner.Backend.Device.Dispatch_Group
           (Weights, Vector, Into, Status, Item.Stopping);
         return;
      end if;

      Status := E.Success;
      for Index in Weights'Range loop
         Product
           (Item, Weights (Index), Vector,
            Into (Into'First + (Index - Weights'First)), Status);
         exit when E.Is_Error (Status);
      end loop;
   end Product_Group;

   procedure Product_Batch
     (Item    : Session;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch_Batch
              (Item.Team, Weight, Vectors, Count, Target, Status);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product_Batch
              (Weight, Vectors, Count, Target, Status);

         when Model_Runner.Backend.Backend_Device =>
            Model_Runner.Backend.Device.Dispatch_Batch
              (Weight, Vectors, Count, Target, Status, Item.Stopping);
      end case;
   end Product_Batch;

   --  The model's per-dimension divisors, or none when it carries no table.
   function Turns (Item : Model'Class) return Real_Array
   is (if Item.Rope_Factors = null
       then K.No_Factors
       else Item.Rope_Factors.all);

   --  Attention for one position, over every head.
   --
   --  Each head scores the positions it may read against its query, turns
   --  those scores into a distribution, and sums the values in proportion.
   --  Both evaluation paths call this -- a token at a time and a token of a
   --  batch -- so the arithmetic that decides what a position attends to
   --  exists once rather than twice.
   --
   --  There are two of these because the cache has two storages and the
   --  difference is one conversion in the innermost loop. A single body with
   --  a test in that loop would put a branch between every multiply and the
   --  next on the exact path, which is the default and the one every
   --  published figure was measured on. Both are reached by the conformance
   --  sweep, so neither is a copy nothing runs.
   --  How steeply one head's attention falls off with distance.
   --
   --  The ladder the architecture's own runtime computes, and it is not a
   --  straight geometric one. The heads up to the largest power of two not
   --  above the head count take m0 to the power h + 1, where m0 is two to
   --  the minus max_bias over that power; the heads above it take m1 to the
   --  power 2 (h - that) + 1, where m1 is the same with half the bias.
   --  Twelve heads take eight of the first and four of the second, so a
   --  ladder written as the first alone is right for two thirds of them and
   --  wrong for the rest -- which is an embedding rather than a refusal, and
   --  is why the file this was checked against is the twelve-head one.
   --
   --  Zero bias gives zero slope, which is no bias at all, and every
   --  architecture that rotates or learns a row for the position takes that.
   function Head_Slope
     (Max_Bias : Real; Head : Element_Count; Heads : Element_Count)
      return Real
   is
      Power : Element_Count := 1;
   begin
      if Max_Bias <= 0.0 then
         return 0.0;
      end if;

      while Power * 2 <= Heads loop
         Power := Power * 2;
      end loop;

      declare
         Rungs : constant N.Wide_Real := N.Wide_Real (Power);
         Bias  : constant N.Wide_Real := N.Wide_Real (Max_Bias);
         M0    : constant N.Wide_Real := N.Power (2.0, -(Bias / Rungs));
         M1    : constant N.Wide_Real :=
           N.Power (2.0, -(Bias / 2.0 / Rungs));
      begin
         if Head < Power then
            return Real (N.Power (M0, N.Wide_Real (Head + 1)));
         else
            return Real
              (N.Power (M1, N.Wide_Real (2 * (Head - Power) + 1)));
         end if;
      end;
   end Head_Slope;

   procedure Blend_Exact
     (Query      : Real_Array;
      Keys       : Real_Array;
      Values     : Real_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;

      --  The bound the architecture states on a score, or zero for none.
      Cap        : Real;

      --  How steeply attention falls off with distance, or zero for an
      --  architecture that says where a token is some other way, and where
      --  the query itself is. The second is not Last: for a model that
      --  reads a whole text at once every slot of the batch sees the same
      --  last position, so the query's own position never reaches here
      --  unless it is passed. It has no default for that reason.
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is
   begin
      Ok := True;

      for Head in From_Head .. To_Head loop
         declare
            Group    : constant Element_Count := Head / Group_Size;
            At_Score : constant Element_Count :=
              Scores'First + Head * Score_Room;
            Q_Origin : constant Element_Count := Query'First + Head * Head_Size;
            Usable   : Boolean;
         begin
            for Step in First .. Last loop
               declare
                  Origin : constant Element_Count :=
                    Keys'First + K_Base + Step * KV_Width + Group * Head_Size;
                  Sum    : N.Wide_Real := 0.0;
               begin
                  for Component in 0 .. Head_Size - 1 loop
                     Sum := Sum
                       + N.Wide_Real (Query (Q_Origin + Component))
                         * N.Wide_Real (Keys (Origin + Component));
                  end loop;
                  Scores (At_Score + Step) := Real (Sum) * Scale;
               end;
            end loop;

            --  The bound afterwards, in a loop of its own, and only when
            --  there is one. Applied inside the loop above it cost every
            --  architecture a test per score -- twelve tokens went from
            --  1.83 s to 2.07 s and the processor time with it, for a
            --  feature one architecture of six uses.
            --  And the fall-off with distance, in a loop of its own for the
            --  same reason and under the same guard. Unsigned, because the
            --  one architecture that takes it reads a whole text and a
            --  position is as far from what follows it as from what came
            --  before.
            declare
               Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
            begin
               if Slope > 0.0 then
                  for Step in First .. Last loop
                     Scores (At_Score + Step) :=
                       Scores (At_Score + Step)
                       - Slope
                         * Real (abs (Integer (Step) - Integer (Query_At)));
                  end loop;
               end if;
            end;

            if Cap > 0.0 then
               for Step in First .. Last loop
                  Scores (At_Score + Step) :=
                    Capped (Scores (At_Score + Step), Cap);
               end loop;
            end if;

            K.Softmax
              (Scores (At_Score + First .. At_Score + Last), Usable);
            if not Usable then
               Ok := False;
               return;
            end if;

            --  A component at a time was one pass over the whole cache per
            --  component: the values of a position are contiguous, so
            --  holding the component still and walking the steps reads
            --  every V_Width'th element and touches a cache line for each
            --  one of them. Holding a run of components instead and walking
            --  the steps once reads them where they lie.
            --
            --  Bit for bit what it replaces. Each component still sums over
            --  the steps in ascending order and rounds once at the end;
            --  what moved is where the sum is kept, not what is added to
            --  it. A run at a time rather than all of them because the run
            --  is on the stack and a head's width is a model's to choose.
            declare
               Run : constant Element_Count := 64;
               At_Component : Element_Count := 0;
            begin
               while At_Component < Value_Size loop
                  declare
                     Here : constant Element_Count :=
                       Element_Count'Min (Run, Value_Size - At_Component);
                     Sums : N.Wide_Real_Array (0 .. Here - 1) :=
                       [others => 0.0];
                  begin
                     for Step in First .. Last loop
                        declare
                           Weight : constant N.Wide_Real :=
                             N.Wide_Real (Scores (At_Score + Step));
                           At_Value : constant Element_Count :=
                             Values'First + V_Base + Step * V_Width
                             + Group * Value_Size + At_Component;
                        begin
                           for Component in 0 .. Here - 1 loop
                              Sums (Component) := Sums (Component)
                                + Weight
                                  * N.Wide_Real
                                      (Values (At_Value + Component));
                           end loop;
                        end;
                     end loop;

                     for Component in 0 .. Here - 1 loop
                        Target (Target'First + Head * Value_Size
                                + At_Component + Component) :=
                          Real (Sums (Component));
                     end loop;

                     At_Component := At_Component + Here;
                  end;
               end loop;
            end;
         end;
      end loop;
   end Blend_Exact;

   --  Put one position's keys and values where a device can read them.
   --
   --  Said by both evaluators, because a model must attend the same way
   --  whichever reads it: one that computes attention one way while
   --  generating and another while a draft's proposals are checked says two
   --  different things, and the suite says so.
   --
   --  A device that has no room is not a failure. Resident comes back False
   --  and everything is done on the processor as before, which is a slower
   --  run rather than a refused one.
   --
   --  @param Item Session whose cache this is.
   --  @param At_Key Where this position's keys go among the keys.
   --  @param Key_Row The keys, rotated.
   --  @param At_Value Where its values go among the values.
   --  @param Value_Row The values.
   --  @param Resident True when both reached the device.
   procedure Put_Position
     (Item      : Session;
      At_Key    : Element_Count;
      Key_Row   : Real_Array;
      At_Value  : Element_Count;
      Value_Row : Real_Array;
      Resident  : out Boolean)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      Resident := False;

      if Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else Item.Held /= Exact
      then
         return;
      end if;

      --  Said every position and done once: the room is the whole cache,
      --  both halves, and asking again for what is there returns at once.
      Model_Runner.Backend.Device.Reserve_Cache
        (Item.Keys.all'Length + Item.Values.all'Length, Resident);

      if Resident then
         Model_Runner.Backend.Device.Put_Cache (At_Key, Key_Row, Resident);
      end if;

      if Resident then
         --  The values follow the keys in the device's copy, which is one
         --  buffer because attention wants four arrays and the pipeline
         --  layout carries three.
         Model_Runner.Backend.Device.Put_Cache
           (Item.Keys.all'Length + At_Value, Value_Row, Resident);
      end if;
   end Put_Position;

   --  One position attending, on the device, to the cache it already holds.
   --
   --  The arguments the processor's own attention takes, in the same order,
   --  so that the two call sites read alike and a reader can see that they
   --  are asking for the same thing.
   --
   --  @param Item Session the position belongs to.
   --  @param Source Model, for the bound its architecture states.
   --  @param Query This position's queries.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param First First cached position that may be looked at.
   --  @param Last Last cached position that may be looked at.
   --  @param K_Base Where this layer's keys begin.
   --  @param V_Base Where this layer's values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Target Receives the blend, one position after another.
   --  @param Usable False when the arithmetic went non-finite.
   --  @param Positions How many positions attend at once. One while
   --    generating; the whole batch while a prompt is evaluated.
   --  @param Window This layer's sliding window, or zero for none, which a
   --    batch needs because every position of it has its own first.
   procedure Attend_There
     (Item       : Session;
      Source     : Model'Class;
      Query      : Real_Array;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Scale      : Real;
      Target     : out Real_Array;
      Usable     : out Boolean;
      Positions  : Element_Count := 1;
      Window     : Natural := 0)
   is
      --  What this model's attention is, asked of the model rather than
      --  passed in: a window is a property of a layer and changes down the
      --  stack, but whether a position may see what follows it is a
      --  property of the model and cannot differ between two calls about
      --  the same one.
      Causal : constant Boolean := Source.Settings.Causal;

      --  A head's worth of queries and of blend, which is how far apart one
      --  position of a batch is from the next in either array.
      Query_Span : constant Element_Count := Heads * Head_Size;
      Blend_Span : constant Element_Count := Heads * Value_Size;

      Took : Boolean;
   begin
      Model_Runner.Backend.Device.Attend
        (Query, Natural (Heads), Natural (Head_Size), Natural (Value_Size),
         Source.Settings.Group_Size, Natural (First), Natural (Last),
         Natural (K_Base), Natural (Item.Keys.all'Length + V_Base),
         Natural (KV_Width), Natural (V_Width),
         Scale, Source.Settings.Attention_Cap, Target, Took,
         Positions => Natural (Positions), Window => Window,
         Causal => Causal, Max_Bias => Source.Settings.Max_Bias);

      if Took then
         Usable := True;
         return;
      end if;

      --  A device that will not take it is not a wrong answer, only an
      --  absent one, and the processor has the same cache to read: the
      --  positions were written to both. Saying so here rather than at
      --  either call site keeps the two evaluators alike, and keeps a
      --  refusal from being reported as a tensor gone non-finite.
      Usable := True;

      for Slot in 0 .. Positions - 1 loop
         declare
            --  Position Slot of the batch looks to Last + Slot, and back to
            --  the window's start where there is one. The device works this
            --  out from the same two numbers, which is what makes the two
            --  paths comparable rather than merely similar.
            --
            --  Attending both ways, every position looks to Last itself:
            --  the text ends where the text ends, whichever position is
            --  asking.
            Ends  : constant Element_Count :=
              (if Causal then Last + Slot else Last);

            --  And where this slot's own query sits, which Ends is not for
            --  a model that reads both ways: there every slot shares Ends
            --  and only this differs between them.
            Asking : constant Element_Count :=
              (if Causal then Ends else Last - (Positions - 1) + Slot);
            Since : constant Element_Count :=
              (if Window = 0 then First
               elsif Ends + 1 > Element_Count (Window)
               then Ends + 1 - Element_Count (Window)
               else 0);

            Q_At : constant Element_Count := Slot * Query_Span;
            B_At : constant Element_Count := Slot * Blend_Span;

            Fine : Boolean;
         begin
            Blend_Exact
              (Query (Query'First + Q_At .. Query'First + Q_At
                      + Query_Span - 1),
               Item.Keys.all, Item.Values.all,
               K_Base, V_Base, KV_Width, V_Width, Heads, Head_Size,
               Value_Size, Element_Count (Source.Settings.Group_Size),
               Since, Ends, Scale, Source.Settings.Attention_Cap,
               Source.Settings.Max_Bias, Asking,
               0, Heads - 1, Item.Score_Room, Item.Scores.all,
               Target (Target'First + B_At .. Target'First + B_At
                       + Blend_Span - 1), Fine);

            Usable := Usable and then Fine;
            exit when not Fine;
         end;
      end loop;
   end Attend_There;

   --  The same, over a cache held in half precision. Every element is
   --  widened where the exact one reads it; nothing else differs, and
   --  nothing here computes in half precision.
   --  One row of the cache, written as bytes with a scale of its own.
   --
   --  Symmetric around zero: the scale is the largest magnitude in the row
   --  divided by 127, so the largest element lands on the end of the range
   --  and zero stays zero. A row of zeros has no magnitude to scale by and
   --  keeps a scale of one, which reads back as the zeros it was.
   --
   --  The unit is a row rather than the whole cache because a row is what
   --  the evaluator writes at once and what it reads at once, and because
   --  one scale for a whole context would be set by whichever position had
   --  the largest key in it and would quantize every other position against
   --  that.
   procedure Pack_Row
     (Source : Real_Array;
      Into   : in out B.Byte_Array;
      Origin : B.Byte_Count;
      Scale  : out Real)
   is
      Largest : Real := 0.0;
   begin
      for Value of Source loop
         Largest := Real'Max (Largest, abs Value);
      end loop;

      Scale := (if Largest > 0.0 then Largest / 127.0 else 1.0);

      for Offset in 0 .. Element_Count (Source'Length) - 1 loop
         declare
            Step : constant Real :=
              Real'Rounding (Source (Source'First + Offset) / Scale);
            Held : constant Real := Real'Max (-127.0, Real'Min (127.0, Step));
         begin
            Into (Origin + B.Byte_Count (Offset)) :=
              B.Byte (Integer (Held) + 128);
         end;
      end loop;
   end Pack_Row;

   --  One element back out of it.
   function Unpack
     (From  : B.Byte_Array;
      At_By : B.Byte_Count;
      Scale : Real) return Real
   is (Real (Integer (From (At_By)) - 128) * Scale);

   --  Attention over a cache stored as bytes and row scales.
   --
   --  The same arithmetic as the other two, reading through Unpack. Written
   --  out rather than shared with them: what differs is the innermost read
   --  of the innermost loop, and a storage chosen per session would put a
   --  branch there rather than around it.
   procedure Blend_Eighth
     (Query      : Real_Array;
      Keys       : B.Byte_Array;
      Values     : B.Byte_Array;
      Key_Scales : Real_Array;
      Val_Scales : Real_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      Rows       : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is
   begin
      Ok := True;

      for Head in From_Head .. To_Head loop
         declare
            Group    : constant Element_Count := Head / Group_Size;
            At_Score : constant Element_Count :=
              Scores'First + Head * Score_Room;
            Q_Origin : constant Element_Count := Query'First + Head * Head_Size;
            Usable   : Boolean;
         begin
            for Step in First .. Last loop
               declare
                  Origin : constant B.Byte_Count :=
                    B.Byte_Count (Keys'First)
                    + B.Byte_Count (K_Base + Step * KV_Width
                                    + Group * Head_Size);
                  Row    : constant Real :=
                    Key_Scales (Key_Scales'First + Rows + Step);
                  Sum    : N.Wide_Real := 0.0;
               begin
                  for Component in 0 .. Head_Size - 1 loop
                     Sum := Sum
                       + N.Wide_Real (Query (Q_Origin + Component))
                         * N.Wide_Real
                             (Unpack (Keys,
                                      Origin + B.Byte_Count (Component), Row));
                  end loop;
                  Scores (At_Score + Step) := Real (Sum) * Scale;
               end;
            end loop;

            --  And the fall-off with distance, in a loop of its own for the
            --  same reason and under the same guard. Unsigned, because the
            --  one architecture that takes it reads a whole text and a
            --  position is as far from what follows it as from what came
            --  before.
            declare
               Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
            begin
               if Slope > 0.0 then
                  for Step in First .. Last loop
                     Scores (At_Score + Step) :=
                       Scores (At_Score + Step)
                       - Slope
                         * Real (abs (Integer (Step) - Integer (Query_At)));
                  end loop;
               end if;
            end;

            if Cap > 0.0 then
               for Step in First .. Last loop
                  Scores (At_Score + Step) :=
                    Capped (Scores (At_Score + Step), Cap);
               end loop;
            end if;

            K.Softmax
              (Scores (At_Score + First .. At_Score + Last), Usable);
            if not Usable then
               Ok := False;
               return;
            end if;

            --  A run of components at a time rather than one, for the
            --  reason written out in Blend_Exact: a position's values are
            --  contiguous and holding the component still walks them a line
            --  at a time. Bit for bit what it replaces -- each component
            --  still sums over the steps in ascending order.
            declare
               Run : constant Element_Count := 64;
               At_Component : Element_Count := 0;
            begin
               while At_Component < Value_Size loop
                  declare
                     Here : constant Element_Count :=
                       Element_Count'Min (Run, Value_Size - At_Component);
                     Sums : N.Wide_Real_Array (0 .. Here - 1) :=
                       [others => 0.0];
                  begin
                     for Step in First .. Last loop
                        declare
                           Weight : constant N.Wide_Real :=
                             N.Wide_Real (Scores (At_Score + Step));
                           At_Byte : constant B.Byte_Count :=
                             B.Byte_Count (Values'First)
                             + B.Byte_Count (V_Base + Step * V_Width
                                             + Group * Value_Size
                                             + At_Component);
                           Scaled : constant Real :=
                             Val_Scales (Val_Scales'First + Rows + Step);
                        begin
                           for Component in 0 .. Here - 1 loop
                              Sums (Component) := Sums (Component)
                                + Weight
                                  * N.Wide_Real
                                      (Unpack
                                         (Values,
                                          At_Byte + B.Byte_Count (Component),
                                          Scaled));
                           end loop;
                        end;
                     end loop;

                     for Component in 0 .. Here - 1 loop
                        Target (Target'First + Head * Value_Size
                                + At_Component + Component) :=
                          Real (Sums (Component));
                     end loop;

                     At_Component := At_Component + Here;
                  end;
               end loop;
            end;
         end;
      end loop;
   end Blend_Eighth;

   procedure Blend_Halved
     (Query      : Real_Array;
      Keys       : T.Half_Array;
      Values     : T.Half_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is
   begin
      Ok := True;

      for Head in From_Head .. To_Head loop
         declare
            Group    : constant Element_Count := Head / Group_Size;
            At_Score : constant Element_Count :=
              Scores'First + Head * Score_Room;
            Q_Origin : constant Element_Count := Query'First + Head * Head_Size;
            Usable   : Boolean;
         begin
            for Step in First .. Last loop
               declare
                  Origin : constant Element_Count :=
                    Keys'First + K_Base + Step * KV_Width + Group * Head_Size;
                  Sum    : N.Wide_Real := 0.0;
               begin
                  for Component in 0 .. Head_Size - 1 loop
                     Sum := Sum
                       + N.Wide_Real (Query (Q_Origin + Component))
                         * N.Wide_Real
                             (N.To_Real (Keys (Origin + Component)));
                  end loop;
                  Scores (At_Score + Step) := Real (Sum) * Scale;
               end;
            end loop;

            --  As above: the bound in a loop of its own, and only when
            --  there is one.
            --  And the fall-off with distance, in a loop of its own for the
            --  same reason and under the same guard. Unsigned, because the
            --  one architecture that takes it reads a whole text and a
            --  position is as far from what follows it as from what came
            --  before.
            declare
               Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
            begin
               if Slope > 0.0 then
                  for Step in First .. Last loop
                     Scores (At_Score + Step) :=
                       Scores (At_Score + Step)
                       - Slope
                         * Real (abs (Integer (Step) - Integer (Query_At)));
                  end loop;
               end if;
            end;

            if Cap > 0.0 then
               for Step in First .. Last loop
                  Scores (At_Score + Step) :=
                    Capped (Scores (At_Score + Step), Cap);
               end loop;
            end if;

            K.Softmax
              (Scores (At_Score + First .. At_Score + Last), Usable);
            if not Usable then
               Ok := False;
               return;
            end if;

            --  A run of components at a time rather than one, for the
            --  reason written out in Blend_Exact. Bit for bit what it
            --  replaces.
            declare
               Run : constant Element_Count := 64;
               At_Component : Element_Count := 0;
            begin
               while At_Component < Value_Size loop
                  declare
                     Here : constant Element_Count :=
                       Element_Count'Min (Run, Value_Size - At_Component);
                     Sums : N.Wide_Real_Array (0 .. Here - 1) :=
                       [others => 0.0];
                  begin
                     for Step in First .. Last loop
                        declare
                           Weight : constant N.Wide_Real :=
                             N.Wide_Real (Scores (At_Score + Step));
                           At_Value : constant Element_Count :=
                             Values'First + V_Base + Step * V_Width
                             + Group * Value_Size + At_Component;
                        begin
                           for Component in 0 .. Here - 1 loop
                              Sums (Component) := Sums (Component)
                                + Weight
                                  * N.Wide_Real
                                      (N.To_Real
                                         (Values (At_Value + Component)));
                           end loop;
                        end;
                     end loop;

                     for Component in 0 .. Here - 1 loop
                        Target (Target'First + Head * Value_Size
                                + At_Component + Component) :=
                          Real (Sums (Component));
                     end loop;

                     At_Component := At_Component + Here;
                  end;
               end loop;
            end;
         end;
      end loop;
   end Blend_Halved;

   --  Normalize each head of a projection in place.
   --
   --  The gain is one element per element of a head, shared across the
   --  heads: a head is normalized against itself and scaled by the same
   --  vector every other head is. Room for one head is passed in rather
   --  than taken, because this runs inside the evaluator and the evaluator
   --  does not allocate.
   procedure Normalize_Heads
     (Vector  : in out Real_Array;
      Heads   : Element_Count;
      Width   : Element_Count;
      Gain    : Real_Array;
      Epsilon : Real;
      Room    : in out Real_Array) is
   begin
      for Head in 0 .. Heads - 1 loop
         declare
            Origin : constant Element_Count := Vector'First + Head * Width;
         begin
            --  Plainly, and not the lifted convention: this normalizes a
            --  query or key head, which only Qwen3 does, and Qwen3 trains
            --  those weights around one like everything else here.
            K.RMS_Norm
              (Vector (Origin .. Origin + Width - 1), Gain, Epsilon, Room);
            Vector (Origin .. Origin + Width - 1) := Room;
         end;
      end loop;
   end Normalize_Heads;

   --  The feed-forward block of one position, through the experts its router
   --  chose for it.
   --
   --  The router scores every expert, the softmax turns the scores into a
   --  distribution, the highest few are taken and their shares renormalized
   --  over that few, and each of them runs the same gate-up-silu-down block
   --  a dense model has one of. The outputs are summed in proportion to
   --  those shares.
   --
   --  Ties go to the lower-numbered expert, which is what the strict
   --  comparison below buys: two experts scoring the same must not make the
   --  answer depend on which one the search happened to reach first.
   --
   --  Input and Result must not be the same buffer: every expert reads the
   --  input after the sum has started being written.
   procedure Mixture
     (Item    : in out Session;
      Current : Layer;
      Input   : T.Real_Array_Access;
      Result  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Settings : Configuration renames Item.Owner.Settings;
      Used     : constant Natural := Settings.Experts_Used;

      Chosen : array (0 .. Used - 1) of Natural := [others => 0];
      Share  : array (0 .. Used - 1) of Real := [others => 0.0];
      Taken  : array (0 .. Settings.Experts - 1) of Boolean :=
        [others => False];

      Total  : Real := 0.0;
      Usable : Boolean;
   begin
      Product (Item, Current.Router, Input, Item.Routing, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      K.Softmax (Item.Routing.all, Usable);
      if not Usable then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;

      for Slot in Chosen'Range loop
         declare
            Best : Integer := -1;
         begin
            for Which in Taken'Range loop
               if not Taken (Which)
                 and then
                   (Best < 0
                    or else Item.Routing (Element_Count (Which))
                            > Item.Routing (Element_Count (Best)))
               then
                  Best := Which;
               end if;
            end loop;

            Taken (Best) := True;
            Chosen (Slot) := Best;
            Share (Slot) := Item.Routing (Element_Count (Best));
            Total := Total + Share (Slot);
         end;
      end loop;

      --  The shares came out of a softmax, so they are positive and sum to
      --  one over every expert; over the chosen few they sum to less, and
      --  this is what puts them back on a scale where the sum below is a
      --  weighted average rather than an arbitrarily shrunken one.
      if not (Total > 0.0) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;

      for Slot in Share'Range loop
         Share (Slot) := Share (Slot) / Total;
      end loop;

      Result.all := [others => 0.0];

      for Slot in Chosen'Range loop
         declare
            Which : Expert renames Current.Experts.all (Chosen (Slot));
         begin
            Product (Item, Which.Gate, Input, Item.Gate, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Product (Item, Which.Up, Input, Item.Up, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            --  A mixture is Qwen3_MoE only, which is a logistic gate; asked
            --  of the model all the same, so that an architecture added with
            --  a router and a different gate cannot quietly get this one.
            Gate_Activation (Item.Owner.all, Item.Gate.all);
            K.Multiply (Item.Gate.all, Item.Up.all);

            Product (Item, Which.Down, Item.Gate, Item.Expert_Row, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            K.Scale (Item.Expert_Row.all, Share (Slot));
            K.Add (Result.all, Item.Expert_Row.all);
         end;
      end loop;
   end Mixture;

   -----------
   -- Enter --
   -----------

   --  Evaluating does not name a phase. It used to set Generating, whether
   --  the tokens being evaluated were a prompt being read or a reply being
   --  written, because the evaluator cannot tell the difference -- so a
   --  session reading a prompt said it was generating, and the state that
   --  meant "reading a prompt" was reachable by nobody.
   procedure Enter (Item : in out Session; Phase : Session_State) is
   begin
      --  A failed or closed session stays where it is. A phase recorded over
      --  a failure would lose the one fact worth keeping about it.
      if Item.Current in Ready | Evaluating_Prompt | Generating then
         Item.Current := Phase;
      end if;
   end Enter;

   procedure Close
     (Item   : in out Model;
      Status : out E.Error_Info) is
   begin
      if Item.Sessions > 0 then
         Status := E.Make (E.Lifecycle_Session_Active);
         E.Add_Integer (Status, "sessions", Long_Long_Integer (Item.Sessions));
         return;
      end if;

      Item.Ready := False;

      if Item.Layers /= null then
         for Index in Item.Layers.all'Range loop
            T.Free (Item.Layers.all (Index).Attention_Norm);
            T.Free (Item.Layers.all (Index).Post_Attention_Norm);
            T.Free (Item.Layers.all (Index).Attention_Norm_Bias);
            T.Free (Item.Layers.all (Index).Post_Feed_Norm);
            T.Free (Item.Layers.all (Index).Feed_Norm);
            T.Free (Item.Layers.all (Index).Feed_Norm_Bias);

            --  The attention biases, which nothing released: a qwen2 model
            --  held three vectors a layer past its own closing, and only
            --  that architecture has them, which is why closing a llama
            --  model looked clean.
            T.Free (Item.Layers.all (Index).Query_Norm);
            T.Free (Item.Layers.all (Index).Key_Norm);
            T.Free (Item.Layers.all (Index).Query_Bias);
            T.Free (Item.Layers.all (Index).Key_Bias);
            T.Free (Item.Layers.all (Index).Value_Bias);
            T.Free (Item.Layers.all (Index).Out_Bias);
            T.Free (Item.Layers.all (Index).Up_Bias);
            T.Free (Item.Layers.all (Index).Down_Bias);

            if Item.Layers.all (Index).Experts /= null then
               Deallocate_Experts (Item.Layers.all (Index).Experts);
            end if;
         end loop;
         Deallocate_Layers (Item.Layers);
      end if;

      T.Free (Item.Output_Norm);
      T.Free (Item.Output_Norm_Bias);
      T.Free (Item.Output_Bias);
      T.Free (Item.Rope_Factors);

      --  The repacked arena goes with it, and after it: by then the device
      --  has been told to give everything back, so there is no address left
      --  for it to be wrong about.
      Release_Weights (Item);
      B.Free (Item.Repacked);
      Item.Embeddings := T.Empty_View;
      Item.Output := T.Empty_View;
      Item.Settings := (others => <>);
      Model_Runner.Tokenizer.Close (Item.Words);
      Model_Runner.Templates.Close (Item.Chat);
      Item.Chat_Present := False;
      Item.Chat_Status := E.Success;
      Status := E.Success;
   exception
      when others =>
         Item.Ready := False;
         Status := E.Success;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Model) is
      Ignored : E.Error_Info;
   begin
      Item.Sessions := 0;
      Close (Item, Ignored);
   end Finalize;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Item : Model) return Boolean is (Item.Ready);

   ------------
   -- Config --
   ------------

   function Config (Item : Model) return Configuration is (Item.Settings);

   ----------------
   -- Vocabulary --
   ----------------

   function Vocabulary
     (Item : Model) return access constant Model_Runner.Tokenizer.Vocabulary
   is (Item.Words'Unchecked_Access);

   -------------------
   -- Has_Template --
   -------------------

   function Has_Template (Item : Model) return Boolean is (Item.Chat_Present);

   ---------------------
   -- Template_Ready --
   ---------------------

   function Weights_Mapped (Item : Model) return Boolean
   is (not Item.Weights_Held
       and then Item.Weights_Base /= System.Null_Address);

   function Template_Ready (Item : Model) return Boolean
   is (Item.Chat_Present and then Model_Runner.Templates.Is_Compiled (Item.Chat));

   -------------------------
   -- Template_Condition --
   -------------------------

   function Template_Condition (Item : Model) return E.Error_Info
   is (Item.Chat_Status);

   --------------
   -- Template --
   --------------

   function Template
     (Item : Model) return access constant Model_Runner.Templates.Compiled
   is (Item.Chat'Unchecked_Access);

   -------------
   -- Account --
   -------------

   function Account (Item : Model) return Mem.Account is (Item.Accounting);

   ---------------------------------------------------------------------------
   --  Sessions
   ---------------------------------------------------------------------------

   --------------------
   -- Merge_Adapter --
   --------------------

   procedure Merge_Adapter
     (Item   : in out Model;
      Source : Containers.Container;
      Bytes  : in out Model_Runner.Byte_Sources.Source'Class;
      Scale  : Real := 1.0;
      Status : out E.Error_Info)
   is
      use type Model_Runner.GGUF.Tensor_Type;
      use type Interfaces.Unsigned_32;

      Arena : B.Byte_Array_Access := null;
      Base  : B.Byte_Count := 0;

      --  How much the adapter's own metadata says to scale by. A rank-r
      --  adapter is trained with a factor of alpha over r, and the file
      --  carries alpha; leaving it out would scale every fine-tune by its
      --  rank.
      Alpha : N.Wide_Real := 0.0;

      --  The same, as bits, for the digest below.
      Alpha_Bits : Interfaces.Unsigned_32 := 0;

      procedure Release is
      begin
         B.Free (Arena);
      end Release;

      --  One of the pair, resolved against the adapter's own arena.
      procedure Adapter_View
        (Name   : String;
         Result : out T.View;
         Found  : out Boolean;
         Local  : out E.Error_Info)
      is
         Index : constant Natural := Containers.Find_Tensor (Source, Name);
      begin
         Result := T.Empty_View;
         Local := E.Success;
         Found := Index /= 0;

         if not Found then
            return;
         end if;

         declare
            Rank : constant Positive := Containers.Tensor_Rank (Source, Index);
            Columns : constant Element_Count :=
              Element_Count (Containers.Tensor_Dimension (Source, Index, 1));
            Rows : Element_Count := 1;
         begin
            for Axis in 2 .. Rank loop
               Rows := Rows
                 * Element_Count
                     (Containers.Tensor_Dimension (Source, Index, Axis));
            end loop;

            T.Make
              (Format  => Containers.Tensor_Format (Source, Index),
               Rows    => Rows,
               Columns => Columns,
               Data    => Arena,
               Offset  =>
                 B.Byte_Count (Containers.Tensor_Offset (Source, Index))
                 - Base,
               Result  => Result,
               Status  => Local);

            if E.Is_Error (Local) then
               E.Add_Text (Local, "tensor", Name, E.Param_Identifier);
            end if;
         end;
      end Adapter_View;

      --  Add the pair's product into one repacked matrix.
      --
      --  The difference is B times A, which is what a low-rank adapter is:
      --  a pair whose product has the shape of the weight and whose own
      --  storage is the rank times the two widths rather than their
      --  product.
      procedure Merge_One
        (Target : T.View;
         Down   : T.View;
         Up     : T.View;
         Local  : out E.Error_Info)
      is
         Rank : constant Element_Count := Down.Rows;

         Left  : Real_Array (0 .. Down.Columns - 1);
         Right : Real_Array (0 .. Up.Columns - 1);
      begin
         Local := E.Success;

         if Target.Format /= Model_Runner.GGUF.Type_F32
           or else Down.Columns /= Target.Columns
           or else Up.Rows /= Target.Rows
           or else Up.Columns /= Rank
         then
            Local := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Integer (Local, "rows", Long_Long_Integer (Target.Rows));
            E.Add_Integer
              (Local, "columns", Long_Long_Integer (Target.Columns));
            return;
         end if;

         --  One row of the weight at a time, so that the adapter's rows are
         --  decoded once each and the weight is touched once.
         for Row in 0 .. Target.Rows - 1 loop
            T.Dequantize_Row (Up, Row, Right, Local);
            if E.Is_Error (Local) then
               return;
            end if;

            for Which in 0 .. Rank - 1 loop
               if Right (Which) /= 0.0 then
                  T.Dequantize_Row (Down, Which, Left, Local);
                  if E.Is_Error (Local) then
                     return;
                  end if;

                  declare
                     Factor : constant N.Wide_Real :=
                       N.Wide_Real (Right (Which)) * N.Wide_Real (Scale)
                       * Alpha;

                     At_Row : constant B.Byte_Count :=
                       Target.Offset
                       + B.Byte_Count (Row) * T.Row_Bytes (Target);

                     --  The one place a view is written through rather than
                     --  read. It reaches here only for a model prepared as
                     --  binary32, whose weights are the copy the repacking
                     --  made and never a mapped file, which nothing may
                     --  write to.
                     Held : B.Byte_Array (1 .. Target.Span)
                       with Import, Address => Target.Base;
                  begin
                     for Column in 0 .. Target.Columns - 1 loop
                        declare
                           At_Byte : constant B.Byte_Count :=
                             At_Row + B.Byte_Count (Column) * 4;

                           Was : constant Real :=
                             N.From_Bits
                               (Interfaces.Unsigned_32
                                  (Held (Held'First + At_Byte))
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Held (Held'First + At_Byte + 1)),
                                      8)
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Held (Held'First + At_Byte + 2)),
                                      16)
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_32
                                        (Held (Held'First + At_Byte + 3)),
                                      24));

                           Now : constant Real :=
                             Real (N.Wide_Real (Was)
                                   + Factor * N.Wide_Real (Left (Column)));

                           Bits : constant Interfaces.Unsigned_32 :=
                             N.Bits (Now);
                        begin
                           Held (Held'First + At_Byte) :=
                             B.Byte (Bits and 16#FF#);
                           Held (Held'First + At_Byte + 1) :=
                             B.Byte
                               (Interfaces.Shift_Right (Bits, 8) and 16#FF#);
                           Held (Held'First + At_Byte + 2) :=
                             B.Byte
                               (Interfaces.Shift_Right (Bits, 16) and 16#FF#);
                           Held (Held'First + At_Byte + 3) :=
                             B.Byte
                               (Interfaces.Shift_Right (Bits, 24) and 16#FF#);
                        end;
                     end loop;
                  end;
               end if;
            end loop;
         end loop;
      end Merge_One;

      --  Every weight an adapter may touch, by the name it has in a file.
      type Target_Name is access constant String;

      Names : constant array (1 .. 7) of Target_Name :=
        [new String'("attn_q"), new String'("attn_k"), new String'("attn_v"),
         new String'("attn_output"), new String'("ffn_gate"),
         new String'("ffn_up"), new String'("ffn_down")];

      Merged : Natural := 0;
   begin
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      if Item.Sessions > 0 then
         Status := E.Make (E.Lifecycle_Session_Active);
         return;
      end if;

      if Item.Packing /= To_F32 or else Item.Repacked = null then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "adapter_without_f32_weights",
                     E.Param_Identifier);
         return;
      end if;

      --  What the adapter says about itself, before its bytes are read.
      declare
         Value : N.Wide_Real;
         Local : E.Error_Info;
      begin
         Containers.Get_Float
           (Source, "adapter.lora.alpha", 0.0, 1.0E6, Value, Local);
         Alpha := (if E.Is_Ok (Local) then Value else 1.0);
         Alpha_Bits := N.Bits (Real (Alpha));
      end;

      --  The adapter's tensors, in an arena of their own.
      declare
         Length : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Data_Bytes (Source));
      begin
         if Length = 0 then
            Status := E.Make (E.Arch_Missing_Tensor);
            E.Add_Text (Status, "tensor", "lora", E.Param_Identifier);
            return;
         end if;

         B.Allocate (Length, Arena);
         if Arena = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;

         Base := B.Byte_Count (Containers.Data_Offset (Source));
         Bytes.Read (Base, Arena.all, Status);
         if E.Is_Error (Status) then
            Release;
            return;
         end if;
      end;

      for Index in Item.Layers.all'Range loop
         for Which of Names loop
            declare
               Stem : constant String :=
                 Layer_Key (Index, Which.all & ".weight");

               Down, Up : T.View;
               Has_Down, Has_Up : Boolean;
               Local : E.Error_Info;
            begin
               Adapter_View (Stem & ".lora_a", Down, Has_Down, Local);
               if E.Is_Error (Local) then
                  Status := Local;
                  Release;
                  return;
               end if;

               Adapter_View (Stem & ".lora_b", Up, Has_Up, Local);
               if E.Is_Error (Local) then
                  Status := Local;
                  Release;
                  return;
               end if;

               --  Half a pair is not an adapter for anything. Refused by
               --  name rather than ignored, because the half that is there
               --  says a fine-tune expected both.
               if Has_Down /= Has_Up then
                  Status := E.Make (E.Arch_Missing_Tensor);
                  E.Add_Text
                    (Status, "tensor",
                     Stem & (if Has_Down then ".lora_b" else ".lora_a"),
                     E.Param_Identifier);
                  Release;
                  return;
               end if;

               if Has_Down then
                  declare
                     Target : T.View := T.Empty_View;
                  begin
                     if Which.all = "attn_q" then
                        Target := Item.Layers.all (Index).Query;
                     elsif Which.all = "attn_k" then
                        Target := Item.Layers.all (Index).Key;
                     elsif Which.all = "attn_v" then
                        Target := Item.Layers.all (Index).Value;
                     elsif Which.all = "attn_output" then
                        Target := Item.Layers.all (Index).Attention_Out;
                     elsif Which.all = "ffn_gate" then
                        Target := Item.Layers.all (Index).Gate;
                     elsif Which.all = "ffn_up" then
                        Target := Item.Layers.all (Index).Up;
                     else
                        Target := Item.Layers.all (Index).Down;
                     end if;

                     if not T.Is_Present (Target) then
                        Status := E.Make (E.Arch_Missing_Tensor);
                        E.Add_Text
                          (Status, "tensor", Stem, E.Param_Identifier);
                        Release;
                        return;
                     end if;

                     Merge_One (Target, Down, Up, Local);
                     if E.Is_Error (Local) then
                        Status := Local;
                        E.Add_Text
                          (Status, "tensor", Stem, E.Param_Identifier);
                        Release;
                        return;
                     end if;

                     Merged := Merged + 1;
                  end;
               end if;
            end;
         end loop;
      end loop;

      Release;

      --  An adapter that touched nothing is one whose tensors this profile
      --  does not know by name, which is worth saying rather than reporting
      --  a merge that changed no weight.
      if Merged = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", "lora_a", E.Param_Identifier);
         return;
      end if;

      --  And the model is no longer the model its file describes. What was
      --  merged goes into what identifies it, so that a context saved
      --  before this cannot be read after it: the weights that produced
      --  that context are gone.
      declare
         procedure Mix (Value : Interfaces.Unsigned_64) is
         begin
            Item.Adapted :=
              (Item.Adapted xor Value) * 16#0000_0100_0000_01B3#;
         end Mix;
      begin
         if Item.Adapted = 0 then
            Item.Adapted := 16#CBF2_9CE4_8422_2325#;
         end if;

         Mix (Interfaces.Unsigned_64 (Merged));
         Mix (Interfaces.Unsigned_64 (N.Bits (Scale)));
         Mix (Interfaces.Unsigned_64 (Containers.Tensor_Data_Bytes (Source)));
         Mix (Interfaces.Unsigned_64 (Alpha_Bits));
      end;
   end Merge_Adapter;

   ---------------------------------------------------------------------------
   --  Saved sessions
   ---------------------------------------------------------------------------

   --  What a saved session begins with, so that a file that is not one is
   --  refused before anything in it is believed.
   Session_Magic : constant := 16#4D52_5345_5353_0001#;

   --  The layout below. A file written by another version is refused rather
   --  than guessed at.
   Session_Version : constant := 1;

   ------------------
   -- Fingerprint --
   ------------------

   function Fingerprint (Item : Model) return Interfaces.Unsigned_64 is
      --  An ordinary multiply-and-mix. This identifies a model; it does not
      --  authenticate one, and a stronger function would only make it look
      --  as though it did.
      Digest : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;

      procedure Mix (Value : Interfaces.Unsigned_64) is
      begin
         Digest := (Digest xor Value) * 16#0000_0100_0000_01B3#;
      end Mix;

      procedure Mix_Count (Value : Natural) is
      begin
         Mix (Interfaces.Unsigned_64 (Value));
      end Mix_Count;
   begin
      if not Item.Ready then
         return 0;
      end if;

      Mix_Count (Architecture'Pos (Item.Settings.Kind));
      Mix_Count (Item.Settings.Context_Length);
      Mix_Count (Item.Settings.Embedding);
      Mix_Count (Item.Settings.Feed_Forward);
      Mix_Count (Item.Settings.Layers);
      Mix_Count (Item.Settings.Heads);
      Mix_Count (Item.Settings.KV_Heads);
      Mix_Count (Item.Settings.Head_Size);
      Mix_Count (Item.Settings.Value_Size);
      Mix_Count (Item.Settings.Rotary);
      Mix_Count (Item.Settings.Vocabulary);
      Mix_Count (Item.Settings.Window);
      Mix_Count (Item.Settings.Experts);
      Mix_Count (Item.Settings.Experts_Used);
      Mix_Count (Repack_Mode'Pos (Item.Packing));

      --  And whatever has been merged into the weights since, because a
      --  model with an adapter in it is not the model its file describes.
      Mix (Item.Adapted);

      --  And the weights themselves, by their size and a sample. Reading
      --  all of them would be a second pass over a model at every load for
      --  a number only a saved session uses.
      if Item.Weights_Base /= System.Null_Address then
         Mix (Interfaces.Unsigned_64 (Item.Weights_Span));

         declare
            --  Through the weights wherever they are: the copy when there
            --  is one, the file's own pages when there is not. Reading the
            --  arena directly was what this did, and the arena is null for
            --  a model that was never copied.
            Held : B.Byte_Array (1 .. Item.Weights_Span)
              with Import, Address => Item.Weights_Base;

            Step : constant B.Byte_Count :=
              B.Byte_Count'Max (1, Item.Weights_Span / 4096);
            At_Byte : B.Byte_Count := 0;
         begin
            while At_Byte < Item.Weights_Span loop
               Mix (Interfaces.Unsigned_64 (Held (Held'First + At_Byte)));
               At_Byte := At_Byte + Step;
            end loop;
         end;
      end if;

      return Digest;
   end Fingerprint;

   --------------
   -- Snapshot --
   --------------

   procedure Snapshot
     (Item   : Session;
      Source : Model'Class;
      Into   : out B.Byte_Array_Access;
      Status : out E.Error_Info)
   is
      Settings : constant Configuration := Source.Settings;

      Held     : constant B.Byte_Count := B.Byte_Count (Item.Committed);
      KV_Width : constant B.Byte_Count :=
        B.Byte_Count (Settings.KV_Heads * Settings.Head_Size);
      V_Width  : constant B.Byte_Count :=
        B.Byte_Count (Settings.KV_Heads * Settings.Value_Size);
      Layers   : constant B.Byte_Count := B.Byte_Count (Settings.Layers);

      --  Ten numbers of eight bytes, then a token each, then the two caches
      --  at four bytes an element whichever precision they are held in.
      Length : constant B.Byte_Count :=
        10 * 8 + Held * 8
        + Layers * Held * KV_Width * 4
        + Layers * Held * V_Width * 4;

      At_Byte : B.Byte_Count := 0;

      procedure Put (Value : Interfaces.Unsigned_64) is
      begin
         Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 7) :=
           B.Put_U64 (Value);
         At_Byte := At_Byte + 8;
      end Put;

      procedure Put_Count (Value : Natural) is
      begin
         Put (Interfaces.Unsigned_64 (Value));
      end Put_Count;

      procedure Put_Bits (Bits : Interfaces.Unsigned_32) is
      begin
         Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 3) :=
           B.Put_U32 (Bits);
         At_Byte := At_Byte + 4;
      end Put_Bits;
   begin
      Into := null;
      Status := E.Success;

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Owner = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      B.Allocate (Length, Into);
      if Into = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Put (Interfaces.Unsigned_64'(Session_Magic));
      Put_Count (Natural'(Session_Version));
      Put (Fingerprint (Source));
      Put_Count (Settings.Layers);
      Put_Count (Settings.KV_Heads);
      Put_Count (Settings.Head_Size);
      Put_Count (Settings.Value_Size);
      Put_Count (Item.Context);
      Put_Count (Item.Committed);
      Put_Count (Cache_Precision'Pos (Item.Held));

      for Index in 0 .. Item.Committed - 1 loop
         Put_Count (Natural (Item.History.all (Index)));
      end loop;

      --  The cache is laid out by capacity, so one layer's committed
      --  positions are a run and the layers are not adjacent.
      for Layer_Index in 0 .. Layers - 1 loop
         declare
            First : constant Element_Count :=
              Element_Count (Layer_Index)
              * Element_Count (Item.Context) * Element_Count (KV_Width);
         begin
            for Index in 0 .. Element_Count (Held * KV_Width) - 1 loop
               if Item.Held = Eighth then
                  --  Written as the numbers it stands for rather than as
                  --  its bytes and scales: a saved context is read back by
                  --  a session that may hold a different precision, and
                  --  four bytes an element is what the format says.
                  Put_Bits
                    (N.Bits
                       (Unpack
                          (Item.Byte_Keys.all,
                           B.Byte_Count (First + Index),
                           Item.Key_Scales.all
                             (First / Element_Count (KV_Width)
                              + Index / Element_Count (KV_Width)))));
               elsif Item.Held = Exact then
                  Put_Bits (N.Bits (Item.Keys.all (First + Index)));
               else
                  Put_Bits
                    (Interfaces.Unsigned_32
                       (Item.Half_Keys.all (First + Index)));
               end if;
            end loop;
         end;
      end loop;

      for Layer_Index in 0 .. Layers - 1 loop
         declare
            First : constant Element_Count :=
              Element_Count (Layer_Index)
              * Element_Count (Item.Context) * Element_Count (V_Width);
         begin
            for Index in 0 .. Element_Count (Held * V_Width) - 1 loop
               if Item.Held = Exact then
                  Put_Bits (N.Bits (Item.Values.all (First + Index)));
               else
                  Put_Bits
                    (Interfaces.Unsigned_32
                       (Item.Half_Values.all (First + Index)));
               end if;
            end loop;
         end;
      end loop;
   end Snapshot;

   -----------
   -- Adopt --
   -----------

   procedure Adopt
     (Item   : in out Session;
      Source : Model'Class;
      From   : B.Byte_Array;
      Status : out E.Error_Info)
   is
      use type Interfaces.Unsigned_32;

      Settings : constant Configuration := Source.Settings;

      KV_Width : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Head_Size);
      V_Width  : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Value_Size);

      At_Byte : B.Byte_Count := 0;
      Trouble : Boolean := False;

      procedure Refuse (Code : E.Error_Code; What : String) is
      begin
         if not Trouble then
            Trouble := True;
            Status := E.Make (Code);
            E.Add_Text (Status, "construct", What, E.Param_Text);
         end if;
      end Refuse;

      function Get return Interfaces.Unsigned_64 is
         Ok : Boolean;
         Value : Interfaces.Unsigned_64;
      begin
         if Trouble then
            return 0;
         end if;

         Value := B.Get_U64 (From, At_Byte, Ok);
         if not Ok then
            Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
            return 0;
         end if;

         At_Byte := At_Byte + 8;
         return Value;
      end Get;

      function Get_Bits return Interfaces.Unsigned_32 is
         Ok : Boolean;
         Value : Interfaces.Unsigned_32;
      begin
         if Trouble then
            return 0;
         end if;

         Value := B.Get_U32 (From, At_Byte, Ok);
         if not Ok then
            Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
            return 0;
         end if;

         At_Byte := At_Byte + 4;
         return Value;
      end Get_Bits;

      --  One run of the cache, into whichever storage the session holds.
      --  One run of the cache, into whichever storage the session holds. A
      --  byte cache is filled a row at a time rather than an element at a
      --  time, because the scale a row is written with is the largest
      --  magnitude in it and there is no such thing until the row is whole.
      procedure Get_Run
        (Keys : Boolean; First : Element_Count; Count : Element_Count)
      is
         Width : constant Element_Count :=
           (if Keys then KV_Width else V_Width);
      begin
         for Index in 0 .. Count - 1 loop
            declare
               Bits : constant Interfaces.Unsigned_32 := Get_Bits;
            begin
               exit when Trouble;

               if Item.Held = Exact then
                  declare
                     Value : constant Real := N.From_Bits (Bits);
                  begin
                     --  A cache of not-a-number would poison every later
                     --  position, and these bytes are untrusted.
                     if not N.Is_Finite (Value) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Keys.all (First + Index) := Value;
                     else
                        Item.Values.all (First + Index) := Value;
                     end if;
                  end;
               elsif Item.Held = Eighth then
                  declare
                     Value : constant Real := N.From_Bits (Bits);
                  begin
                     if not N.Is_Finite (Value) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Key_Row.all (Index mod Width) := Value;
                     else
                        Item.Value_Row.all (Index mod Width) := Value;
                     end if;

                     if Index mod Width = Width - 1 then
                        declare
                           Row : constant Element_Count :=
                             (First + Index) / Width;
                        begin
                           if Keys then
                              Pack_Row
                                (Item.Key_Row.all (0 .. Width - 1),
                                 Item.Byte_Keys.all,
                                 B.Byte_Count (First + Index - Width + 1),
                                 Item.Key_Scales.all (Row));
                           else
                              Pack_Row
                                (Item.Value_Row.all (0 .. Width - 1),
                                 Item.Byte_Values.all,
                                 B.Byte_Count (First + Index - Width + 1),
                                 Item.Value_Scales.all (Row));
                           end if;
                        end;
                     end if;
                  end;
               else
                  declare
                     Value : constant N.Half :=
                       N.Half (Bits and 16#FFFF#);
                  begin
                     if not N.Is_Finite (N.To_Real (Value)) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Half_Keys.all (First + Index) := Value;
                     else
                        Item.Half_Values.all (First + Index) := Value;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Get_Run;

      Held : Element_Count := 0;
   begin
      Status := E.Success;

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Owner = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      --  Nothing of what was there survives, whether or not this succeeds.
      Reset (Item);

      declare
         Magic   : constant Interfaces.Unsigned_64 := Get;
         Version : constant Interfaces.Unsigned_64 := Get;
         Mark    : constant Interfaces.Unsigned_64 := Get;
         Layers  : constant Interfaces.Unsigned_64 := Get;
         KV      : constant Interfaces.Unsigned_64 := Get;
         Wide    : constant Interfaces.Unsigned_64 := Get;
         Deep    : constant Interfaces.Unsigned_64 := Get;
         Room    : constant Interfaces.Unsigned_64 := Get;
         Filled  : constant Interfaces.Unsigned_64 := Get;
         Packed  : constant Interfaces.Unsigned_64 := Get;
      begin
         if not Trouble and then Magic /= Session_Magic then
            Refuse (E.Lifecycle_Cache_Unreadable, "not a saved session");
         end if;

         if not Trouble and then Version /= Session_Version then
            Refuse (E.Lifecycle_Cache_Unreadable, "another version");
         end if;

         if not Trouble and then Mark /= Fingerprint (Source) then
            Refuse (E.Lifecycle_Cache_Mismatched, "another model");
         end if;

         if not Trouble
           and then (Layers /= Interfaces.Unsigned_64 (Settings.Layers)
                     or else KV /= Interfaces.Unsigned_64 (Settings.KV_Heads)
                     or else Wide
                             /= Interfaces.Unsigned_64 (Settings.Head_Size)
                     or else Deep
                             /= Interfaces.Unsigned_64 (Settings.Value_Size))
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another shape");
         end if;

         if not Trouble
           and then Room /= Interfaces.Unsigned_64 (Item.Context)
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another context");
         end if;

         if not Trouble
           and then Packed
                    /= Interfaces.Unsigned_64
                         (Cache_Precision'Pos (Item.Held))
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another precision");
         end if;

         if not Trouble
           and then Filled > Interfaces.Unsigned_64 (Item.Context)
         then
            Refuse (E.Lifecycle_Cache_Unreadable, "more than the context");
         end if;

         if not Trouble then
            Held := Element_Count (Filled);
         end if;
      end;

      if not Trouble then
         for Index in 0 .. Natural (Held) - 1 loop
            declare
               Value : constant Interfaces.Unsigned_64 := Get;
            begin
               exit when Trouble;

               if Value >= Interfaces.Unsigned_64 (Settings.Vocabulary) then
                  Refuse (E.Lifecycle_Cache_Unreadable, "token out of range");
                  exit;
               end if;

               Item.History.all (Index) :=
                 Model_Runner.Tokenizer.Token_Id (Value);
            end;
         end loop;
      end if;

      if not Trouble then
         for Layer_Index in 0 .. Element_Count (Settings.Layers) - 1 loop
            Get_Run
              (True, Layer_Index * Element_Count (Item.Context) * KV_Width,
               Held * KV_Width);
            exit when Trouble;
         end loop;
      end if;

      if not Trouble then
         for Layer_Index in 0 .. Element_Count (Settings.Layers) - 1 loop
            Get_Run
              (False, Layer_Index * Element_Count (Item.Context) * V_Width,
               Held * V_Width);
            exit when Trouble;
         end loop;
      end if;

      if Trouble then
         --  Nothing half read is left where a conversation would be.
         Reset (Item);
         return;
      end if;

      Item.Committed := Natural (Held);
   end Adopt;

   ------------------
   -- Plan_Session --
   ------------------

   procedure Plan_Session
     (Item    : Model;
      Context : Natural;
      Plan    : out Mem.Session_Plan;
      Status  : out E.Error_Info;
      Cache   : Cache_Precision := Exact) is
   begin
      Plan_For (Item.Settings, Context, Plan, Status, Cache);
   end Plan_Session;

   ---------------
   -- Plan_For --
   ---------------

   procedure Plan_For
     (Settings : Configuration;
      Context  : Natural;
      Plan     : out Mem.Session_Plan;
      Status   : out E.Error_Info;
      Cache    : Cache_Precision := Exact)
   is
      Capacity : constant Natural :=
        (if Context = 0 then Settings.Context_Length else Context);

      --  layers * capacity * kv heads * head size * bytes * 2, entirely in
      --  checked arithmetic so that an implausible request is reported as an
      --  overflow rather than wrapping into a small allocation.
      Room : constant A.Checked :=
        A.To_Checked (Interfaces.Unsigned_64 (Settings.Layers))
        * A.To_Checked (Interfaces.Unsigned_64 (Capacity))
        * A.To_Checked (Interfaces.Unsigned_64 (Settings.KV_Heads))
        * A.To_Checked
            (Interfaces.Unsigned_64 (Settings.Head_Size + Settings.Value_Size))
        * A.To_Checked (Cache_Element_Bytes (Cache));
   begin
      Plan := (others => <>);

      if not A.Is_Valid (Room) then
         Status := E.Make (E.Memory_Plan_Overflow);
         return;
      end if;

      Plan.KV_Cache_Bytes := A.Value (Room);
      Plan.Activation_Bytes :=
        Interfaces.Unsigned_64 (Settings.Embedding) * 4 * 4;
      Plan.Batch_Bytes :=
        Interfaces.Unsigned_64 (Feed_Width (Settings)) * 4 * 2
        + Interfaces.Unsigned_64 (Settings.Experts) * 4
        + (if Settings.Experts > 0
           then Interfaces.Unsigned_64 (Settings.Embedding) * 4 * 2
           else 0);
      Plan.Logits_Bytes := Interfaces.Unsigned_64 (Settings.Vocabulary) * 4;
      Plan.Sampling_Bytes := Plan.Logits_Bytes;
      Plan.Token_History_Bytes := Interfaces.Unsigned_64 (Capacity) * 4;
      Plan.Decoder_Bytes := 64;
      Plan.Stop_Bytes := 4096;
      Plan.Rendering_Bytes := 0;

      Mem.Finalize_Session_Plan (Plan, Status);
   end Plan_For;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item           : in out Session;
      Source         : in out Model'Class;
      Context        : Natural := 0;
      Session_Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Workers        : Workers_CPU.Pool_Reference := null;
      Cache          : Cache_Precision := Exact;
      Status         : out E.Error_Info)
   is
      Settings : Configuration;
      Capacity : Natural;
   begin
      Close (Item);
      Status := E.Success;

      if not Source.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      Settings := Source.Settings;
      Capacity := (if Context = 0 then Settings.Context_Length else Context);

      if Capacity = 0
        or else Capacity > Settings.Context_Length
        or else Capacity > Session_Bounds.Max_Context
      then
         Status := E.Make (E.Arch_Context_Too_Large);
         E.Add_Integer (Status, "requested", Long_Long_Integer (Capacity));
         E.Add_Integer
           (Status, "maximum", Long_Long_Integer (Settings.Context_Length));
         return;
      end if;

      Plan_Session (Model (Source), Capacity, Item.Plan, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What the plan says, recorded where a report can find it. Every
      --  figure here was already computed and then thrown away, so the
      --  account read zero for the KV cache while the session held it.
      Mem.Initialize
        (Item.Accounting, Model_Runner.Limits.Default_Model_Limits,
         Session_Bounds.Max_Session_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.KV_Cache, Item.Plan.KV_Cache_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.Activations,
         Item.Plan.Activation_Bytes + Item.Plan.Batch_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.Logits, Item.Plan.Logits_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.Sampling_Workspace, Item.Plan.Sampling_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.Token_Buffers,
         Item.Plan.Token_History_Bytes + Item.Plan.Decoder_Bytes);
      Mem.Record_Allocation
        (Item.Accounting, Mem.Template_Buffers,
         Item.Plan.Rendering_Bytes + Item.Plan.Stop_Bytes);

      if Session_Bounds.Max_Session_Bytes /= 0
        and then Item.Plan.Total_Resident > Session_Bounds.Max_Session_Bytes
      then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", "kv_cache", E.Param_Identifier);
         E.Add_Integer
           (Status, "requested",
            Long_Long_Integer (Item.Plan.Total_Resident), E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Session_Bounds.Max_Session_Bytes),
            E.Param_Bytes);
         return;
      end if;

      declare
         Width : constant Element_Count :=
           Element_Count (Settings.Embedding);
         Feed  : constant Element_Count :=
           Element_Count (Feed_Width (Settings));
         Wide  : constant Element_Count :=
           Element_Count (Settings.Heads * Settings.Head_Size);
         Blend : constant Element_Count :=
           Element_Count (Settings.Heads * Settings.Value_Size);
         KV    : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Head_Size);
         KV_Out : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Value_Size);
         Deep  : constant Element_Count :=
           Element_Count (Settings.Layers) * Element_Count (Capacity);

         --  One scale a row, and a row is one position of one layer.
         Rows  : constant Element_Count := Deep;
      begin
         --  One storage or the other, never both.
         Item.Held := Cache;

         case Cache is
            when Exact =>
               T.Allocate (Deep * KV, Item.Keys);
               T.Allocate (Deep * KV_Out, Item.Values);

            when Halved =>
               T.Allocate (Deep * KV, Item.Half_Keys);
               T.Allocate (Deep * KV_Out, Item.Half_Values);

            when Eighth =>
               --  The bytes, and a scale for every row of them: one row a
               --  position a layer, for the keys and again for the values.
               Item.Byte_Keys := new B.Byte_Array (0 .. B.Byte_Count (Deep * KV) - 1);
               Item.Byte_Values :=
                 new B.Byte_Array (0 .. B.Byte_Count (Deep * KV_Out) - 1);
               T.Allocate (Rows, Item.Key_Scales);
               T.Allocate (Rows, Item.Value_Scales);
         end case;
         T.Allocate (Width, Item.Activation);
         T.Allocate (Width, Item.Normalized);

         --  Room for a normalization taken out of the way. Gemma2 and
         --  Gemma3 normalize what a sublayer produced; Falcon keeps what the
         --  block normalized on the way in, because both of its sublayers
         --  read it. Different uses, one buffer, and both want it as wide as
         --  the embedding.
         --  Asked partly of the arrangement rather than wholly of a list,
         --  because a list is what an architecture gets left off. Nomic_Bert
         --  was: Join_Residual normalizes only where it has room to do it
         --  in, so a missing buffer is not a refusal but a residual that is
         --  never normalized, and the values grew until layer five could
         --  not hold them.
         if Source.Settings.Kind in Gemma2 | Gemma3 | Falcon | Phi2
           or else Normalizes_After (Source.Settings.Kind)
         then
            T.Allocate (Width, Item.Post_Room);
         end if;

         T.Allocate (Wide, Item.Query);
         T.Allocate (KV, Item.Key_Row);
         T.Allocate (KV_Out, Item.Value_Row);
         T.Allocate (Blend, Item.Attention);
         Item.Score_Room := Element_Count (Capacity);
         T.Allocate
           (Element_Count (Natural'Max (1, Settings.Heads))
            * Item.Score_Room, Item.Scores);
         T.Allocate (Feed, Item.Gate);
         T.Allocate (Feed, Item.Up);
         T.Allocate (Element_Count (Settings.Vocabulary), Item.Logit_Row);
         Item.History := new Token_History (0 .. Capacity - 1);

         --  An architecture that normalizes its heads needs room for one.
         if Settings.Head_Size > 0
           and then Source.Layers /= null
           and then Source.Layers.all (Source.Layers.all'First).Query_Norm
                    /= null
         then
            T.Allocate (Element_Count (Settings.Head_Size), Item.Head_Row);
            if Item.Head_Row = null then
               Close (Item);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
         end if;

         --  A mixture of experts needs three more, and a dense model needs
         --  none of them: allocating them anyway would charge every model
         --  for a feature almost none of them have.
         if Settings.Experts > 0 then
            T.Allocate (Element_Count (Settings.Experts), Item.Routing);
            T.Allocate (Width, Item.Mixture);
            T.Allocate (Width, Item.Expert_Row);

            if Item.Routing = null or else Item.Mixture = null
              or else Item.Expert_Row = null
            then
               Close (Item);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
         end if;

         if (Cache = Exact
             and then (Item.Keys = null or else Item.Values = null))
           or else (Cache = Halved
                    and then (Item.Half_Keys = null
                              or else Item.Half_Values = null))
           or else (Cache = Eighth
                    and then (Item.Byte_Keys = null
                              or else Item.Byte_Values = null
                              or else Item.Key_Scales = null
                              or else Item.Value_Scales = null))
           or else Item.Activation = null or else Item.Normalized = null
           or else Item.Query = null or else Item.Key_Row = null
           or else Item.Value_Row = null or else Item.Attention = null
           or else Item.Scores = null or else Item.Gate = null
           or else Item.Up = null or else Item.Logit_Row = null
         then
            Close (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end;

      Item.Owner := Source'Unchecked_Access;
      Item.Team := Workers;
      Item.Context := Capacity;
      Item.Committed := 0;
      Item.Current := Ready;
      Source.Sessions := Source.Sessions + 1;
   exception
      when others =>
         Close (Item);
         Status := E.Make (E.Memory_Allocation_Failed);
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Session) is
   begin
      if Item.Owner /= null and then Item.Current /= Closed then
         if Item.Owner.Sessions > 0 then
            Item.Owner.Sessions := Item.Owner.Sessions - 1;
         end if;
      end if;

      T.Free (Item.Keys);
      T.Free (Item.Values);
      B.Free (Item.Byte_Keys);
      B.Free (Item.Byte_Values);
      T.Free (Item.Key_Scales);
      T.Free (Item.Value_Scales);
      T.Free (Item.Half_Keys);
      T.Free (Item.Half_Values);
      T.Free (Item.Activation);
      T.Free (Item.Normalized);
      T.Free (Item.Post_Room);
      T.Free (Item.Query);
      T.Free (Item.Key_Row);
      T.Free (Item.Value_Row);
      T.Free (Item.Attention);
      T.Free (Item.Scores);
      T.Free (Item.Gate);
      T.Free (Item.Up);
      T.Free (Item.Head_Row);
      T.Free (Item.Routing);
      T.Free (Item.Mixture);
      T.Free (Item.Expert_Row);
      T.Free (Item.Logit_Row);

      if Item.History /= null then
         Deallocate_History (Item.History);
      end if;

      Item.Owner := null;
      Item.Team := null;
      Item.Context := 0;
      Item.Committed := 0;
      Item.Current := Closed;
   exception
      when others =>
         Item.Current := Closed;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Session) is
   begin
      Close (Item);
   end Finalize;

   -----------
   -- State --
   -----------

   function State (Item : Session) return Session_State is (Item.Current);

   ----------------
   -- Precision --
   ----------------

   function Precision (Item : Session) return Cache_Precision is (Item.Held);

   -------------------
   -- Hidden_State --
   -------------------

   procedure Hidden_State
     (Item   : Session;
      Target : out Real_Array;
      Status : out E.Error_Info) is
   begin
      Target := [others => 0.0];

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Committed = 0
        or else Item.Normalized = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      if Target'Length /= Item.Normalized.all'Length then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "output", Long_Long_Integer (Target'Length));
         E.Add_Integer
           (Status, "expected",
            Long_Long_Integer (Item.Normalized.all'Length));
         return;
      end if;

      Target := Item.Normalized.all;
      Status := E.Success;
   end Hidden_State;

   --------------
   -- Position --
   --------------

   function Position (Item : Session) return Natural is (Item.Committed);

   --------------
   -- Capacity --
   --------------

   function Capacity (Item : Session) return Natural is (Item.Context);

   -------------
   -- Workers --
   -------------

   function Workers (Item : Session) return Workers_CPU.Pool_Reference
   is (Item.Team);

   ----------------------
   -- Committed_Token --
   ----------------------

   function Committed_Token (Item : Session; Index : Natural) return Token_Id is
   begin
      if Item.History = null or else Index >= Item.Committed then
         return Model_Runner.Tokenizer.No_Token;
      else
         return Item.History.all (Index);
      end if;
   end Committed_Token;

   -----------
   -- Reset --
   -----------

   -----------
   -- Shift --
   -----------

   procedure Shift
     (Item   : in out Session;
      Source : Model'Class;
      Keep   : Natural;
      Drop   : Positive;
      Status : out E.Error_Info)
   is
      Settings : constant Configuration := Source.Settings;

      Head_Size : constant Element_Count :=
        Element_Count (Settings.Head_Size);
      KV_Heads  : constant Element_Count :=
        Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;
      V_Width   : constant Element_Count :=
        KV_Heads * Element_Count (Settings.Value_Size);

      Moved : Natural;
   begin
      Status := E.Success;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if Keep + Drop > Item.Committed then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "input", Long_Long_Integer (Keep + Drop));
         E.Add_Integer
           (Status, "expected", Long_Long_Integer (Item.Committed));
         return;
      end if;

      Moved := Item.Committed - Keep - Drop;

      --  Every layer, every moved position: the key turned back by the angle
      --  Drop stands for and written where it now belongs, the value copied.
      for Index in Item.Owner.Layers'Range loop
         declare
            Base : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * KV_Width;
            V_Base : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * V_Width;
            Rows_Base : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context);
         begin
            for Step in 0 .. Moved - 1 loop
               declare
                  From : constant Element_Count :=
                    Base + Element_Count (Keep + Drop + Step) * KV_Width;
                  Into : constant Element_Count :=
                    Base + Element_Count (Keep + Step) * KV_Width;

                  V_From : constant Element_Count :=
                    V_Base + Element_Count (Keep + Drop + Step) * V_Width;
                  V_Into : constant Element_Count :=
                    V_Base + Element_Count (Keep + Step) * V_Width;
               begin
                  if Item.Held = Eighth then
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Key_Row.all (Offset) :=
                          Unpack (Item.Byte_Keys.all,
                                  B.Byte_Count (From + Offset),
                                  Item.Key_Scales.all
                                    (Rows_Base
                                     + Element_Count (Keep + Drop + Step)));
                     end loop;
                  elsif Item.Held = Exact then
                     Item.Key_Row.all (0 .. KV_Width - 1) :=
                       Item.Keys.all (From .. From + KV_Width - 1);
                  else
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Key_Row.all (Offset) :=
                          N.To_Real (Item.Half_Keys.all (From + Offset));
                     end loop;
                  end if;

                  K.Apply_Rotary
                    (Item.Key_Row.all, KV_Heads, Head_Size,
                     Element_Count (Settings.Rotary), Drop,
                     Turn_Base (Settings, Natural (Index)),
                     Settings.Scaling, Turns (Source),
                     Settings.Pairing, Backwards => True);

                  if Item.Held = Eighth then
                     --  Turned back and written again, which is a second
                     --  rounding of a row that was already rounded once.
                     --  A rolling context in this storage loses a little
                     --  more of what it keeps every time it rolls, and that
                     --  is the price of the storage rather than a fault in
                     --  the shift.
                     Pack_Row
                       (Item.Key_Row.all (0 .. KV_Width - 1),
                        Item.Byte_Keys.all, B.Byte_Count (Into),
                        Item.Key_Scales.all
                          (Rows_Base + Element_Count (Keep + Step)));

                     for Offset in 0 .. V_Width - 1 loop
                        Item.Byte_Values.all
                          (B.Byte_Count (V_Into + Offset)) :=
                          Item.Byte_Values.all
                            (B.Byte_Count (V_From + Offset));
                     end loop;
                     Item.Value_Scales.all
                       (Rows_Base + Element_Count (Keep + Step)) :=
                       Item.Value_Scales.all
                         (Rows_Base + Element_Count (Keep + Drop + Step));
                  elsif Item.Held = Exact then
                     Item.Keys.all (Into .. Into + KV_Width - 1) :=
                       Item.Key_Row.all (0 .. KV_Width - 1);
                     Item.Values.all (V_Into .. V_Into + V_Width - 1) :=
                       Item.Values.all (V_From .. V_From + V_Width - 1);
                  else
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Half_Keys.all (Into + Offset) :=
                          N.To_Half (Item.Key_Row.all (Offset));
                     end loop;
                     for Offset in 0 .. V_Width - 1 loop
                        Item.Half_Values.all (V_Into + Offset) :=
                          Item.Half_Values.all (V_From + Offset);
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  And the history, which is what a restored context is checked
      --  against and what a prefix comparison reads.
      for Step in 0 .. Moved - 1 loop
         Item.History.all (Keep + Step) :=
           Item.History.all (Keep + Drop + Step);
      end loop;

      Item.Committed := Keep + Moved;
   end Shift;

   ------------
   -- Rewind --
   ------------

   procedure Rewind
     (Item     : in out Session;
      Position : Natural;
      Status   : out E.Error_Info) is
   begin
      Status := E.Success;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if Position > Item.Committed then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "input", Long_Long_Integer (Position));
         E.Add_Integer (Status, "expected", Long_Long_Integer (Item.Committed));
         return;
      end if;

      --  Nothing is cleared. What is past the position is not read: every
      --  attention reads the committed length and every write past it is a
      --  write to a slot that will be written again before it is read.
      Item.Committed := Position;
   end Rewind;

   procedure Reset (Item : in out Session) is
   begin
      --  Only the logical contents are invalidated. The cache and scratch
      --  buffers stay allocated so that a reset costs nothing and the next
      --  turn does not have to plan memory again.
      --
      --  Their contents do not stay. A reset is a caller saying the previous
      --  conversation is over, and the tokens of it sat in the history until
      --  something happened to write over them. Bytes.Wipe was written for
      --  this and its documentation said it was used on session reset; it
      --  was called by nothing.
      if Item.History /= null then
         Item.History.all := [others => Model_Runner.Tokenizer.No_Token];
      end if;
      Item.Committed := 0;
      if Item.Current /= Closed then
         Item.Current := Ready;
      end if;
   end Reset;

   --  The earliest position a query at Position may attend to.
   --
   --  Without a window that is the beginning; with one it is the window's
   --  worth of positions ending at Position, so a query at position ten
   --  with a window of four sees seven, eight, nine and ten. Positions
   --  before that are in the cache and are not read: the window narrows
   --  what may be seen, not what is held.
   function Earliest
     (Settings : Configuration;
      Position : Element_Count;

      --  Which layer is asking, because an architecture may window some of
      --  them and not others. Gemma2 windows every other one, starting with
      --  layer zero; every other architecture here windows all or none, and
      --  passes whatever it likes.
      Layer    : Natural := 0) return Element_Count
   is
      Width : constant Element_Count := Element_Count (Settings.Window);
   begin
      --  Which layers slide a window. Gemma2 alternates, so every second
      --  layer sees everything; Gemma3 windows five in six, so every sixth
      --  does. Written as one rule with the period the architecture states,
      --  because two rules that mean the same thing are two rules to get
      --  wrong.
      if Settings.Alternating
        and then Settings.Window_Every > 0
        and then Layer mod Settings.Window_Every = Settings.Window_Every - 1
      then
         return 0;
      end if;

      if Settings.Window = 0 or else Position < Width then
         return 0;
      else
         return Position - Width + 1;
      end if;
   end Earliest;

   --------------
   -- Evaluate --
   --------------

   procedure Evaluate
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Logits : out Real_Array;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info)
   is
      Settings  : constant Configuration := Source.Settings;
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Value_Size : constant Element_Count :=
        Element_Count (Settings.Value_Size);
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;

      --  The values are their own width, so they are their own cache. The
      --  two were one number until a model stated them apart.
      V_Width   : constant Element_Count := KV_Heads * Value_Size;
      Reserved  : constant Element_Count := Element_Count (Item.Committed);
      Scale     : constant Real :=
        Real (1.0 / N.Sqrt (N.Wide_Real (Settings.Head_Size)));
   begin
      Logits := [others => 0.0];

      --  Where the products can reach it. Not cleared on the way out, and
      --  it does not need to be: every entry point that reaches a product
      --  sets it first, so what is read is always this call's token. A
      --  session between calls holds the last one it was given, which is
      --  the caller's own and which nothing reads.
      Item.Stopping := Cancel;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if not Source.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      --  A single token is evaluated in order to find out what comes after
      --  it, and a model with no head cannot say. Refused here rather than
      --  at the projection, so that a caller who asked the wrong thing of
      --  the wrong model is told before a forward pass is spent on it.
      if not Settings.Has_Head then
         Status := E.Make (E.Arch_No_Output_Head);
         E.Add_Text
           (Status, "architecture", Architecture_Name (Settings.Kind),
            E.Param_Identifier);
         return;
      end if;

      if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Token) then
         Status := E.Make (E.Tokenizer_Invalid_Token_Id);
         E.Add_Integer (Status, "token", Long_Long_Integer (Token));
         E.Add_Integer
           (Status, "vocabulary", Long_Long_Integer (Settings.Vocabulary));
         return;
      end if;

      if Item.Committed >= Item.Context then
         Status := E.Make (E.Generation_Context_Exhausted);
         E.Add_Integer
           (Status, "capacity", Long_Long_Integer (Item.Context),
            E.Param_Tokens);
         return;
      end if;

      if Logits'Length /= Element_Count (Settings.Vocabulary) then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "output", Long_Long_Integer (Logits'Length));
         return;
      end if;

      --  Embedding lookup.
      T.Dequantize_Row
        (Source.Embeddings, Element_Count (Token), Item.Activation.all, Status);
      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      if Embedding_Scale (Source) /= 1.0 then
         for Value of Item.Activation.all loop
            Value := Value * Embedding_Scale (Source);
         end loop;
      end if;

      --  Where the token is, added to what the token is. GPT2 learns this
      --  instead of rotating, so a model with a position table has no
      --  rotation and a model with rotation has no table; the two are never
      --  both read.
      if Source.Settings.Kind = GPT2 then
         T.Dequantize_Row
           (Source.Positions, Element_Count (Item.Committed),
            Item.Normalized.all, Status);
         if E.Is_Error (Status) then
            Item.Current := Failed;
            return;
         end if;

         K.Add (Item.Activation.all, Item.Normalized.all);
      end if;

      for Index in Source.Layers.all'Range loop
         if C.Is_Cancelled (Cancel) then
            --  The reserved position was never committed, so the cache still
            --  describes exactly the context that was valid before this call.
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;

         declare
            Current : Layer renames Source.Layers.all (Index);
            Base    : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * KV_Width;
            Slot    : constant Element_Count := Base + Reserved * KV_Width;

            --  Where this layer's row scales begin, which is one a position
            --  rather than one an element.
            Rows_Base : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context);
            V_Base  : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * V_Width;
            V_Slot  : constant Element_Count := V_Base + Reserved * V_Width;

            --  Whether this position reached the device's own cache, which
            --  is what says attention may be done there. False leaves
            --  everything as it was, so a device that refused the room is a
            --  slower run rather than a failed one.
            Resident : Boolean := False;

            --  Whether attention and the matrix that reads its blend went
            --  over as one submission. False means the projection still has
            --  to be done, which is what it means everywhere else.
            Projected : Boolean := False;

            --  Set when a device took the whole gated feed-forward, its
            --  projection down included, so that the common tail does not
            --  project it a second time.
            Whole_Block : Boolean := False;
         begin
            --  Attention block.
            Normalize
              (Source, Item.Activation.all, Current.Attention_Norm.all,
               Current.Attention_Norm_Bias, Item.Normalized.all);

            --  Falcon runs the feed-forward from this same normalized input
            --  rather than from what attention produced, so it is kept
            --  before attention overwrites the buffer it shares.
            if Current.Feed_Norm = null then
               Item.Post_Room.all := Item.Normalized.all;
            end if;

            Product_Group
              (Item,
               [Current.Query, Current.Key, Current.Value],
               Item.Normalized,
               [Item.Query, Item.Key_Row, Item.Value_Row],
               Status);
            exit when E.Is_Error (Status);

            --  The projection bias, before the rotary encoding, because the
            --  bias is part of the projection and the encoding acts on what
            --  the projection produced.
            if Current.Query_Bias /= null then
               K.Add (Item.Query.all, Current.Query_Bias.all);
               K.Add (Item.Key_Row.all, Current.Key_Bias.all);
               K.Add (Item.Value_Row.all, Current.Value_Bias.all);
            end if;

            --  And the per-head normalization, where the architecture has
            --  one. Before the rotation, as the projection's bias is: both
            --  act on what the projection produced.
            if Current.Query_Norm /= null then
               Normalize_Heads
                 (Item.Query.all, Heads, Head_Size,
                  Current.Query_Norm.all, Settings.Epsilon,
                  Item.Head_Row.all);
               Normalize_Heads
                 (Item.Key_Row.all, KV_Heads, Head_Size,
                  Current.Key_Norm.all, Settings.Epsilon, Item.Head_Row.all);
            end if;

            K.Apply_Rotary
              (Item.Query.all, Heads, Head_Size,
               Element_Count (Settings.Rotary), Item.Committed,
               Turn_Base (Settings, Natural (Index)),
               Settings.Scaling, Turns (Source),
               Settings.Pairing);
            K.Apply_Rotary
              (Item.Key_Row.all, KV_Heads, Head_Size,
               Element_Count (Settings.Rotary), Item.Committed,
               Turn_Base (Settings, Natural (Index)),
               Settings.Scaling, Turns (Source),
               Settings.Pairing);

            --  Write into the reserved slot. The slot is only readable as
            --  context once Committed is advanced, at the end of this call.
            if Item.Held = Eighth then
               Pack_Row
                 (Item.Key_Row.all (0 .. KV_Width - 1), Item.Byte_Keys.all,
                  B.Byte_Count (Slot),
                  Item.Key_Scales.all (Rows_Base + Reserved));
               Pack_Row
                 (Item.Value_Row.all (0 .. V_Width - 1), Item.Byte_Values.all,
                  B.Byte_Count (V_Slot),
                  Item.Value_Scales.all (Rows_Base + Reserved));
            elsif Item.Held = Exact then
               for Offset in 0 .. KV_Width - 1 loop
                  Item.Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
               end loop;
               for Offset in 0 .. V_Width - 1 loop
                  Item.Values.all (V_Slot + Offset) :=
                    Item.Value_Row.all (Offset);
               end loop;

               --  And into the device's own copy, where attention reads it.
               --  The host copy stays in step because everything else reads
               --  it: the snapshot, the eviction, the other two precisions.
               Put_Position
                 (Item, Slot, Item.Key_Row.all (0 .. KV_Width - 1),
                  V_Slot, Item.Value_Row.all (0 .. V_Width - 1), Resident);
            else
               for Offset in 0 .. KV_Width - 1 loop
                  Item.Half_Keys.all (Slot + Offset) :=
                    N.To_Half (Item.Key_Row.all (Offset));
               end loop;
               for Offset in 0 .. V_Width - 1 loop
                  Item.Half_Values.all (V_Slot + Offset) :=
                    N.To_Half (Item.Value_Row.all (Offset));
               end loop;
            end if;

            --  Causal attention over the committed positions and this one.
            --  Grouped-query attention maps each query head to its key-value
            --  head by division; no key or value head is ever duplicated.
            --
            --  A model with a sliding window sees the window's worth of
            --  positions ending at this one and no more. The positions
            --  before that are still in the cache -- narrowing what may be
            --  read is not the same as holding less, and this holds the
            --  same amount either way.
            declare
               First : constant Element_Count :=
                 Earliest (Settings, Reserved, Natural (Index));
               Usable : Boolean;

               --  A share of the heads, for the worker pool.
               --
               --  Attention ran on the calling task while every worker sat
               --  idle, and the budget under "Where a token's time goes"
               --  says it is about a third of a generated token now that
               --  the products have got two and a half times faster. A head
               --  is independent of every other head: it reads its own
               --  slice of the query, writes its own row of scores and its
               --  own slice of the blend, so the only thing that had to
               --  change before this was possible is that the scores are a
               --  row a head rather than one row shared.
               type Blend_Share is limited new Workers_CPU.Task_Item with
                  record
                     Ok : Boolean := True;
                  end record;

               overriding procedure Run
                 (Share : in out Blend_Share;
                  From  : Element_Count;
                  To    : Element_Count);

               overriding procedure Run
                 (Share : in out Blend_Share;
                  From  : Element_Count;
                  To    : Element_Count)
               is
                  Fine : Boolean := True;
               begin
                  if From > To then
                     return;
                  end if;

                  if Item.Held = Eighth then
                     Blend_Eighth
                       (Item.Query.all, Item.Byte_Keys.all,
                        Item.Byte_Values.all,
                        Item.Key_Scales.all, Item.Value_Scales.all,
                        Base, V_Base, Rows_Base, KV_Width, V_Width, Heads,
                        Head_Size, Value_Size,
                        Element_Count (Settings.Group_Size),
                        First, Reserved, Scale, Settings.Attention_Cap,
                        Settings.Max_Bias, Reserved,
                        From, To, Item.Score_Room,
                        Item.Scores.all, Item.Attention.all, Fine);
                  elsif Item.Held = Exact then
                     Blend_Exact
                       (Item.Query.all, Item.Keys.all, Item.Values.all,
                        Base, V_Base, KV_Width, V_Width, Heads, Head_Size,
                        Value_Size, Element_Count (Settings.Group_Size),
                        First, Reserved, Scale, Settings.Attention_Cap,
                        Settings.Max_Bias, Reserved,
                        From, To, Item.Score_Room,
                        Item.Scores.all, Item.Attention.all, Fine);
                  else
                     Blend_Halved
                       (Item.Query.all, Item.Half_Keys.all,
                        Item.Half_Values.all,
                        Base, V_Base, KV_Width, V_Width, Heads, Head_Size,
                        Value_Size, Element_Count (Settings.Group_Size),
                        First, Reserved, Scale, Settings.Attention_Cap,
                        Settings.Max_Bias, Reserved,
                        From, To, Item.Score_Room,
                        Item.Scores.all, Item.Attention.all, Fine);
                  end if;

                  --  Only ever set false, by any share that could not
                  --  finish, and read by nobody until the pool has
                  --  collected every worker -- which is a rendezvous
                  --  through a protected object and orders these writes
                  --  against that read.
                  if not Fine then
                     Share.Ok := False;
                  end if;
               end Run;

               Share  : aliased Blend_Share;
               Shared : E.Error_Info;
            begin
               if Item.Held /= Exact or else not Resident then
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Heads, Share'Unchecked_Access, Shared);
                  Usable := Share.Ok and then E.Is_Ok (Shared);
               elsif Item.Held = Exact and then Resident then
                  --  Attention and the matrix that reads its result, named
                  --  together so they go over as one command buffer and the
                  --  blend never comes back. Where the device will not take
                  --  the pair, Attend_There does the attention alone and the
                  --  projection follows as it always did.
                  Model_Runner.Backend.Device.Attend_And_Project
                    (Item.Query.all, Natural (Heads), Natural (Head_Size),
                     Natural (Value_Size), Settings.Group_Size,
                     Natural (First), Natural (Reserved), Natural (Base),
                     Natural (Item.Keys.all'Length + V_Base),
                     Natural (KV_Width), Natural (V_Width), Scale,
                     Settings.Attention_Cap, Current.Attention_Out,
                     Item.Normalized, Projected,
                     Max_Bias => Settings.Max_Bias);

                  if Projected then
                     Usable := True;
                  else
                     Attend_There
                       (Item, Source, Item.Query.all, Heads, Head_Size,
                        Value_Size, First, Reserved, Base, V_Base, KV_Width,
                        V_Width, Scale, Item.Attention.all, Usable);
                  end if;
               end if;

               if not Usable then
                  Item.Current := Failed;
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  E.Add_Integer (Status, "layer", Long_Long_Integer (Index));
                  return;
               end if;
            end;

            --  Done already where the pair went over together.
            if not Projected then
               Product
                 (Item, Current.Attention_Out, Item.Attention,
                  Item.Normalized, Status);
               exit when E.Is_Error (Status);
            end if;

            if Current.Out_Bias /= null then
               K.Add (Item.Normalized.all, Current.Out_Bias.all);
            end if;
            Join_Residual
              (Source, Item.Normalized.all, Item.Activation.all,
               Current.Post_Attention_Norm,
               Current.Post_Attention_Norm_Bias, Item.Post_Room);

            --  Feed-forward block. It reads what the layer normalized on
            --  the way in where the architecture runs the two in parallel,
            --  and what the residual holds now where it runs them one after
            --  the other -- which is the whole of the difference between
            --  the two arrangements.
            if Current.Feed_Norm = null then
               Item.Normalized.all := Item.Post_Room.all;
            else
               Normalize
                 (Source, Item.Activation.all, Current.Feed_Norm.all,
                  Current.Feed_Norm_Bias, Item.Normalized.all);
            end if;

            if Settings.Experts > 0 then
               Mixture
                 (Item, Current, Item.Normalized, Item.Mixture, Status);
               exit when E.Is_Error (Status);
               Join_Residual
                 (Source, Item.Mixture.all, Item.Activation.all,
                  Current.Post_Feed_Norm, Current.Post_Feed_Norm_Bias,
                  Item.Post_Room);
            else
               --  Gated or not, the two arrangements differ only in how the
               --  buffer handed to the projection down is filled: one fills
               --  it from two projections and a product, the other from one
               --  projection. What follows is common, and is written once so
               --  that it cannot be reached by one arrangement and skipped by
               --  the other -- which is what happened when the ungated arm
               --  was added beside a projection down that belonged to the
               --  gated one, and Falcon then ran with its feed-forward
               --  computed and discarded.
               if not T.Is_Present (Current.Gate) then
                  --  No gate: up, a Gaussian unit, down. The gate being
                  --  absent is what says so, rather than the architecture,
                  --  so an architecture added later with the same
                  --  arrangement needs nothing here.
                  Product
                    (Item, Current.Up, Item.Normalized, Item.Gate, Status);
                  exit when E.Is_Error (Status);

                  --  The bias belongs to the projection, so it is added
                  --  before the unit rather than after it.
                  if Current.Up_Bias /= null then
                     K.Add (Item.Gate.all, Current.Up_Bias.all);
                  end if;

                  Gate_Activation (Source, Item.Gate.all);
               else
                  --  A device takes the whole block: both arms, the unit
                  --  and the multiply, and the projection that reads the
                  --  result, without any of the middle coming back. Every
                  --  other backend does what it did.
                  if Model_Runner.Backend."=" (Item.Owner.Able.Kind,
                                               Model_Runner.Backend
                                                 .Backend_Device)
                  then
                     Model_Runner.Backend.Device.Dispatch_Gated
                       (Current.Gate, Current.Up, Current.Down,
                        Item.Normalized, 1, Gate_Unit (Source),
                        Item.Normalized, Status, Item.Stopping);
                     exit when E.Is_Error (Status);
                     Whole_Block := True;
                  else
                     Product_Group
                       (Item, [Current.Gate, Current.Up], Item.Normalized,
                        [Item.Gate, Item.Up], Status);
                     exit when E.Is_Error (Status);

                     Gate_Activation (Source, Item.Gate.all);
                     K.Multiply (Item.Gate.all, Item.Up.all);
                  end if;
               end if;

               if not Whole_Block then
                  Product
                    (Item, Current.Down, Item.Gate, Item.Normalized, Status);
                  exit when E.Is_Error (Status);
               end if;

               if Current.Down_Bias /= null then
                  K.Add (Item.Normalized.all, Current.Down_Bias.all);
               end if;

               Join_Residual
                 (Source, Item.Normalized.all, Item.Activation.all,
                  Current.Post_Feed_Norm, Current.Post_Feed_Norm_Bias,
                  Item.Post_Room);
            end if;
         end;
      end loop;

      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      Final_State (Source, Item.Activation.all, Item.Normalized.all);

      --  The output projection is the widest product of the token, so it is
      --  the one that most benefits from the pool. It writes into a
      --  session-owned row that is then copied into the caller's vector.
      Product
        (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      Logits := Item.Logit_Row.all;
      Finish_Logits (Source, Logits);

      --  Commit: the position becomes readable context only now, after every
      --  layer of this token has succeeded.
      Item.History.all (Item.Committed) := Token;
      Item.Committed := Item.Committed + 1;
      Status := E.Success;
   exception
      when others =>
         Item.Current := Failed;
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "llama.evaluate");
   end Evaluate;

   ---------------------
   -- Evaluate_Batch --
   ---------------------

   procedure Evaluate_Batch
     (Item   : in out Session;
      Source : Model'Class;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      Logits : out Real_Array;
      States : T.Real_Array_Access := null;
      Every  : T.Real_Array_Access := null;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info)
   is
      Settings  : constant Configuration := Source.Settings;
      Width     : constant Element_Count := Element_Count (Settings.Embedding);
      --  Zero for a mixture of experts: the batch never holds a
      --  feed-forward activation there, because that block runs a position
      --  at a time through the session's own buffers.
      Feed      : constant Element_Count :=
        (if Settings.Experts > 0
         then 0
         else Element_Count (Settings.Feed_Forward));
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Value_Size : constant Element_Count :=
        Element_Count (Settings.Value_Size);
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;
      V_Width   : constant Element_Count := KV_Heads * Value_Size;
      Wide      : constant Element_Count := Heads * Head_Size;
      Blend     : constant Element_Count := Heads * Value_Size;
      Reserved  : constant Element_Count := Element_Count (Item.Committed);
      Count     : constant Element_Count := Element_Count (Tokens'Length);
      Scale     : constant Real :=
        Real (1.0 / N.Sqrt (N.Wide_Real (Settings.Head_Size)));

      --  One batch's activations. Held for the call rather than the session
      --  so that a session that never batches pays nothing for the option.
      Acts   : T.Real_Array_Access := null;
      Norm   : T.Real_Array_Access := null;

      --  What the block normalized on the way in, kept for the architecture
      --  that runs both of its sublayers from it. Null for the rest, which
      --  is what the block below reads.
      Kept_Norm : T.Real_Array_Access := null;
      Query  : T.Real_Array_Access := null;
      Keys   : T.Real_Array_Access := null;
      Values : T.Real_Array_Access := null;
      Attend : T.Real_Array_Access := null;
      Gate   : T.Real_Array_Access := null;
      Up     : T.Real_Array_Access := null;

      procedure Release is
      begin
         T.Free (Acts);
         T.Free (Norm);
         T.Free (Kept_Norm);
         T.Free (Query);
         T.Free (Keys);
         T.Free (Values);
         T.Free (Attend);
         T.Free (Gate);
         T.Free (Up);
      end Release;

      --  Slice of a batch buffer belonging to one token of the batch.
      function Slot
        (Which : Element_Count; Stride : Element_Count) return Element_Count
      is (Which * Stride);
   begin
      Logits := [others => 0.0];

      --  As in Evaluate: where the products can reach it, set on the way in
      --  by every entry point that reaches one.
      Item.Stopping := Cancel;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if not Source.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      --  More than one token at a time is a thing the backend either does or
      --  does not. One at a time is the same call with Count of one, so only
      --  a real batch has to ask.
      if Count > 1 and then not Source.Able.Supports_Batched then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "batched", E.Param_Identifier);
         E.Add_Text
           (Status, "backend",
            Model_Runner.Backend.Backend_Name (Source.Able.Kind),
            E.Param_Identifier);
         return;
      end if;

      --  How many positions may come in one call. A causal model takes the
      --  batch this file bounds the working set at, because a longer prompt
      --  is the same answer in more calls. A model that attends both ways
      --  has no such freedom: position zero has to see the last position of
      --  the text in the same pass, so the whole text is the batch and the
      --  bound is the context.
      declare
         Limit : constant Element_Count :=
           (if Settings.Causal
            then Max_Batch
            else Element_Count (Settings.Context_Length));
      begin
         --  A causal model handed more than the batch bound is a caller
         --  asking for a shape this does not evaluate, and a shape mismatch
         --  is what that is. A model that attends both ways handed more
         --  than its context is something else: the text does not fit the
         --  model, which is an ordinary thing for a caller to do and not a
         --  shape they got wrong. Saying "mismatched shapes" to somebody
         --  who embedded a long document tells them nothing they can act
         --  on.
         if Count = 0 or else Count > Limit then
            if Count > Limit and then not Settings.Causal then
               Status := E.Make (E.Arch_Context_Too_Large);
               E.Add_Integer
                 (Status, "requested", Long_Long_Integer (Count),
                  E.Param_Tokens);
               E.Add_Integer
                 (Status, "maximum", Long_Long_Integer (Limit),
                  E.Param_Tokens);
            else
               Status := E.Make (E.Tensor_Shape_Mismatch);
               E.Add_Integer (Status, "input", Long_Long_Integer (Count));
               E.Add_Integer (Status, "limit", Long_Long_Integer (Limit));
            end if;
            return;
         end if;
      end;

      --  And it has to be the whole text. A second batch into a cache that
      --  already holds positions would attend to what is there and be
      --  invisible to it: the first half would have been computed without
      --  the second, which is exactly the answer a bidirectional model is
      --  not. Refused rather than split, because what comes back from a
      --  split is an embedding, plausible in every respect, of a text the
      --  model never read whole.
      if not Settings.Causal and then Item.Committed > 0 then
         Status := E.Make (E.Arch_Text_Not_Whole);
         E.Add_Text
           (Status, "architecture", Architecture_Name (Settings.Kind),
            E.Param_Identifier);
         E.Add_Integer
           (Status, "count", Long_Long_Integer (Item.Committed),
            E.Param_Tokens);
         return;
      end if;

      for Token of Tokens loop
         if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Token) then
            Status := E.Make (E.Tokenizer_Invalid_Token_Id);
            E.Add_Integer (Status, "token", Long_Long_Integer (Token));
            E.Add_Integer
              (Status, "vocabulary", Long_Long_Integer (Settings.Vocabulary));
            return;
         end if;
      end loop;

      if Reserved + Count > Element_Count (Item.Context) then
         Status := E.Make (E.Generation_Context_Exhausted);
         E.Add_Integer
           (Status, "capacity", Long_Long_Integer (Item.Context),
            E.Param_Tokens);
         return;
      end if;

      --  What a caller may ask a headless model for is states. A
      --  distribution is refused by name, and an empty Logits is how a
      --  caller says they are not asking for one -- the alternative is a row
      --  of zeros that looks like a distribution and is not.
      if not Settings.Has_Head then
         if Logits'Length /= 0 or else Every /= null then
            Status := E.Make (E.Arch_No_Output_Head);
            E.Add_Text
              (Status, "architecture", Architecture_Name (Settings.Kind),
               E.Param_Identifier);
            return;
         end if;

      elsif Logits'Length /= Element_Count (Settings.Vocabulary) then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "output", Long_Long_Integer (Logits'Length));
         return;
      end if;

      T.Allocate (Count * Width, Acts);
      T.Allocate (Count * Width, Norm);

      if Source.Settings.Kind in Falcon | Phi2 then
         T.Allocate (Count * Width, Kept_Norm);
      end if;
      T.Allocate (Count * Wide, Query);
      T.Allocate (Count * KV_Width, Keys);
      T.Allocate (Count * V_Width, Values);
      T.Allocate (Count * Blend, Attend);
      T.Allocate (Count * Feed, Gate);
      T.Allocate (Count * Feed, Up);

      if Acts = null or else Norm = null or else Query = null
        or else Keys = null or else Values = null or else Attend = null
        or else ((Gate = null or else Up = null) and then Feed > 0)
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "batch_activations", E.Param_Identifier);
         return;
      end if;

      --  Embedding lookup for every token of the batch.
      for Which in 0 .. Count - 1 loop
         declare
            Origin : constant Element_Count := Slot (Which, Width);
         begin
            T.Dequantize_Row
              (Source.Embeddings,
               Element_Count (Tokens (Tokens'First + Natural (Which))),
               Acts.all (Origin .. Origin + Width - 1), Status);

            if Embedding_Scale (Source) /= 1.0 then
               for Value of Acts.all (Origin .. Origin + Width - 1) loop
                  Value := Value * Embedding_Scale (Source);
               end loop;
            end if;

            --  As in the single-token path: where the token is, added to
            --  what it is. Its position is the committed count plus its
            --  place in this batch.
            if Source.Settings.Kind in GPT2 | Bert then
               T.Dequantize_Row
                 (Source.Positions,
                  Element_Count (Item.Committed) + Which,
                  Item.Normalized.all, Status);

               if E.Is_Ok (Status) then
                  K.Add (Acts.all (Origin .. Origin + Width - 1),
                         Item.Normalized.all);
               end if;
            end if;

            --  And which segment it belongs to, which is the first of them
            --  for every position of a text embedded here. The row is the
            --  same for all of them and is read once a position rather than
            --  once: a row is a decode of the file's own bytes, and hoisting
            --  it would mean a second buffer to hold it in.
            if E.Is_Ok (Status) and then Source.Settings.Segments > 0 then
               T.Dequantize_Row
                 (Source.Segments, 0, Item.Normalized.all, Status);

               if E.Is_Ok (Status) then
                  K.Add (Acts.all (Origin .. Origin + Width - 1),
                         Item.Normalized.all);
               end if;
            end if;

            --  Bert normalizes the sum of the three before layer zero sees
            --  it. Written here rather than as the first thing a layer does,
            --  because it happens once for the whole model and not once a
            --  layer, and because the tensor it uses belongs to the
            --  embedding rather than to any block.
            if E.Is_Ok (Status) and then Source.Embedding_Norm /= null then
               Normalize
                 (Source, Acts.all (Origin .. Origin + Width - 1),
                  Source.Embedding_Norm.all, Source.Embedding_Norm_Bias,
                  Item.Normalized.all);
               Acts.all (Origin .. Origin + Width - 1) :=
                 Item.Normalized.all;
            end if;

            if E.Is_Error (Status) then
               Release;
               Item.Current := Failed;
               return;
            end if;
         end;
      end loop;

      for Index in Source.Layers.all'Range loop
         if C.Is_Cancelled (Cancel) then
            --  Nothing was committed, so the cache still describes exactly
            --  the context that was valid before this call.
            Release;
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;

         declare
            Current : Layer renames Source.Layers.all (Index);
            Base    : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * KV_Width;
            Rows_Base : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context);
            V_Base  : constant Element_Count :=
              Element_Count (Index) * Element_Count (Item.Context) * V_Width;

            --  Whether this batch's positions reached the device's cache.
            --  Set as they are written and read where they are attended to,
            --  which is a loop later.
            Resident : Boolean := False;

            --  Set when a device took the whole gated feed-forward, its
            --  projection down included, so that the common tail does not
            --  project it a second time.
            Whole_Block : Boolean := False;
         begin
            --  What the block is given. Every architecture here normalizes
            --  on the way in except Bert, whose block reads the residual as
            --  it stands -- the normalization it has was applied on the way
            --  out of the block before this one.
            if Current.Attention_Norm = null then
               Norm.all (0 .. Count * Width - 1) :=
                 Acts.all (0 .. Count * Width - 1);
            else
               for Which in 0 .. Count - 1 loop
                  declare
                     Origin : constant Element_Count := Slot (Which, Width);
                  begin
                     Normalize
                       (Source, Acts.all (Origin .. Origin + Width - 1),
                        Current.Attention_Norm.all,
                        Current.Attention_Norm_Bias,
                        Norm.all (Origin .. Origin + Width - 1));
                  end;
               end loop;
            end if;

            --  Kept where the architecture runs its two sublayers from the
            --  same normalized input: attention is about to overwrite the
            --  buffer that holds it. A batch keeps all of it, which is why
            --  this is the batch's own buffer rather than the one position
            --  the single-token path keeps.
            --
            --  Asked of the architecture and not of the feed normalization
            --  being absent, because those are two different things and
            --  Bert is where they came apart: it has no feed normalization
            --  either, and it does not run its sublayers in parallel, so
            --  reading the absence as the arrangement copied a batch into a
            --  buffer that had never been allocated.
            if Source.Settings.Kind in Falcon | Phi2 then
               Kept_Norm.all (0 .. Count * Width - 1) :=
                 Norm.all (0 .. Count * Width - 1);
            end if;

            --  One pass over each weight for the whole batch.
            Product_Batch
              (Item, Current.Query, Norm, Count, Query, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Key, Norm, Count, Keys, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Value, Norm, Count, Values, Status);
            exit when E.Is_Error (Status);

            --  Rotate at each token's own position, then publish every key
            --  and value before any attention reads them: token K of the
            --  batch attends to the earlier tokens of the same batch.
            for Which in 0 .. Count - 1 loop
               declare
                  Q_At : constant Element_Count := Slot (Which, Wide);
                  KV_At : constant Element_Count := Slot (Which, KV_Width);
                  V_At  : constant Element_Count := Slot (Which, V_Width);
                  Place : constant Element_Count :=
                    Base + (Reserved + Which) * KV_Width;
                  V_Place : constant Element_Count :=
                    V_Base + (Reserved + Which) * V_Width;
               begin
                  --  The same bias as the single-token path adds, on each
                  --  token of the batch. A batch that skipped it would
                  --  answer a prompt differently from the way it answers
                  --  the same text one token at a time.
                  if Current.Query_Bias /= null then
                     K.Add (Query.all (Q_At .. Q_At + Wide - 1),
                            Current.Query_Bias.all);
                     K.Add (Keys.all (KV_At .. KV_At + KV_Width - 1),
                            Current.Key_Bias.all);
                     K.Add (Values.all (V_At .. V_At + V_Width - 1),
                            Current.Value_Bias.all);
                  end if;

                  if Current.Query_Norm /= null then
                     Normalize_Heads
                       (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                        Current.Query_Norm.all, Settings.Epsilon,
                        Item.Head_Row.all);
                     Normalize_Heads
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        KV_Heads, Head_Size, Current.Key_Norm.all,
                        Settings.Epsilon, Item.Head_Row.all);
                  end if;

                  K.Apply_Rotary
                    (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                     Element_Count (Settings.Rotary),
                     Item.Committed + Natural (Which),
                     Turn_Base (Settings, Natural (Index)),
                     Settings.Scaling, Turns (Source),
                     Settings.Pairing);
                  K.Apply_Rotary
                    (Keys.all (KV_At .. KV_At + KV_Width - 1),
                     KV_Heads, Head_Size, Element_Count (Settings.Rotary),
                     Item.Committed + Natural (Which),
                     Turn_Base (Settings, Natural (Index)),
                     Settings.Scaling, Turns (Source),
                     Settings.Pairing);

                  if Item.Held = Eighth then
                     Pack_Row
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        Item.Byte_Keys.all, B.Byte_Count (Place),
                        Item.Key_Scales.all (Rows_Base + Reserved + Which));
                     Pack_Row
                       (Values.all (V_At .. V_At + V_Width - 1),
                        Item.Byte_Values.all, B.Byte_Count (V_Place),
                        Item.Value_Scales.all (Rows_Base + Reserved + Which));
                  elsif Item.Held = Exact then
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Keys.all (Place + Offset) :=
                          Keys.all (KV_At + Offset);
                     end loop;
                     for Offset in 0 .. V_Width - 1 loop
                        Item.Values.all (V_Place + Offset) :=
                          Values.all (V_At + Offset);
                     end loop;

                     --  And the device's copy, as the single-token path
                     --  does. Both evaluators must attend the same way: a
                     --  model that computes attention one way when it
                     --  generates and another when a draft's proposals are
                     --  checked says two different things, and the suite
                     --  says so.
                     Put_Position
                       (Item, Place, Keys.all (KV_At .. KV_At + KV_Width - 1),
                        V_Place, Values.all (V_At .. V_At + V_Width - 1),
                        Resident);
                  else
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Half_Keys.all (Place + Offset) :=
                          N.To_Half (Keys.all (KV_At + Offset));
                     end loop;
                     for Offset in 0 .. V_Width - 1 loop
                        Item.Half_Values.all (V_Place + Offset) :=
                          N.To_Half (Values.all (V_At + Offset));
                     end loop;
                  end if;
               end;
            end loop;

            --  The whole batch in one call where a device holds the cache.
            --  Every position of a batch reads the same cache and writes its
            --  own blend, so nothing makes them wait for each other -- and a
            --  call costs 83 microseconds before it computes anything, which
            --  a position at a time pays 2420 times over a 110-token prompt.
            if Item.Held = Exact and then Resident then
               declare
                  --  What Earliest would return for the batch's first
                  --  position, and the width it would slide for the rest.
                  --  Taken from Earliest rather than restated, so a layer
                  --  that windows nothing says zero here as it does there.
                  Window_Here : constant Natural :=
                    (if Settings.Window > 0
                       and then Earliest (Settings,
                                          Element_Count (Settings.Window),
                                          Natural (Index)) > 0
                     then Settings.Window
                     else 0);

                  Usable : Boolean;
               begin
                  --  The last position the batch may look at. Causally
                  --  that is the batch's first, and each position after it
                  --  moves its own end along; attending both ways it is the
                  --  batch's last, and every position shares it.
                  Attend_There
                    (Item, Source, Query.all (0 .. Count * Wide - 1),
                     Heads, Head_Size, Value_Size,
                     Earliest (Settings, Reserved, Natural (Index)),
                     (if Settings.Causal
                      then Reserved
                      else Reserved + Count - 1),
                     Base, V_Base, KV_Width, V_Width, Scale,
                     Attend.all (0 .. Count * Blend - 1), Usable,
                     Positions => Count, Window => Window_Here);

                  if not Usable then
                     Item.Current := Failed;
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Integer (Status, "layer",
                                    Long_Long_Integer (Index));
                     return;
                  end if;
               end;
            end if;

            --  Every position of the batch, in shares of the heads.
            --
            --  A head at a time down the positions rather than a position at
            --  a time down the heads, which is the same work in the other
            --  order and is what makes it one hand-off a layer instead of
            --  one per position: a hundred and twenty-eight positions of
            --  twenty-two layers would otherwise be nearly three thousand
            --  rendezvous for a prompt. It also needs no score buffer beyond
            --  the row a head already has, where sharing the positions out
            --  would have needed a row per share per head.
            if not (Item.Held = Exact and then Resident) then
               declare
                  type Batch_Share is limited new Workers_CPU.Task_Item with
                     record
                        Ok : Boolean := True;
                     end record;

                  overriding procedure Run
                    (Share : in out Batch_Share;
                     From  : Element_Count;
                     To    : Element_Count);

                  overriding procedure Run
                    (Share : in out Batch_Share;
                     From  : Element_Count;
                     To    : Element_Count) is
                  begin
                     if From > To then
                        return;
                     end if;

                     for Which in 0 .. Count - 1 loop
                        declare
                           Last_Step : constant Element_Count :=
                             (if Settings.Causal
                              then Reserved + Which
                              else Reserved + Count - 1);
                           First_Step : constant Element_Count :=
                             Earliest (Settings, Last_Step, Natural (Index));
                           Q_At   : constant Element_Count :=
                             Slot (Which, Wide);
                           B_At   : constant Element_Count :=
                             Slot (Which, Blend);
                           Usable : Boolean := True;
                        begin
                           if Item.Held = Eighth then
                              Blend_Eighth
                                (Query.all (Q_At .. Q_At + Wide - 1),
                                 Item.Byte_Keys.all, Item.Byte_Values.all,
                                 Item.Key_Scales.all, Item.Value_Scales.all,
                                 Base, V_Base, Rows_Base, KV_Width, V_Width,
                                 Heads, Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Step, Last_Step, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Reserved + Which,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           elsif Item.Held = Exact then
                              Blend_Exact
                                (Query.all (Q_At .. Q_At + Wide - 1),
                                 Item.Keys.all, Item.Values.all,
                                 Base, V_Base, KV_Width, V_Width, Heads,
                                 Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Step, Last_Step, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Reserved + Which,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           else
                              Blend_Halved
                                (Query.all (Q_At .. Q_At + Wide - 1),
                                 Item.Half_Keys.all, Item.Half_Values.all,
                                 Base, V_Base, KV_Width, V_Width, Heads,
                                 Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Step, Last_Step, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Reserved + Which,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           end if;

                           if not Usable then
                              Share.Ok := False;
                           end if;
                        end;
                     end loop;
                  end Run;

                  Share  : aliased Batch_Share;
                  Shared : E.Error_Info;
               begin
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Heads, Share'Unchecked_Access, Shared);

                  if not Share.Ok or else E.Is_Error (Shared) then
                     Release;
                     Item.Current := Failed;
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Integer
                       (Status, "layer", Long_Long_Integer (Index));
                     return;
                  end if;
               end;
            end if;

            Product_Batch
              (Item, Current.Attention_Out, Attend, Count, Norm, Status);
            exit when E.Is_Error (Status);

            if Current.Out_Bias /= null then
               for Which in 0 .. Count - 1 loop
                  declare
                     Origin : constant Element_Count := Slot (Which, Width);
                  begin
                     K.Add (Norm.all (Origin .. Origin + Width - 1),
                            Current.Out_Bias.all);
                  end;
               end loop;
            end if;

            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  Join_Residual
                    (Source,
                     Norm.all (Origin .. Origin + Width - 1),
                     Acts.all (Origin .. Origin + Width - 1),
                     Current.Post_Attention_Norm,
                     Current.Post_Attention_Norm_Bias,
                     Item.Post_Room);

                  --  What the feed-forward reads: the block's own normalized
                  --  input where the two sublayers run in parallel, the
                  --  residual as it stands where the block normalized it on
                  --  the way out, and a fresh normalization of the residual
                  --  where they run one after the other.
                  if Normalizes_After (Source.Settings.Kind) then
                     Norm.all (Origin .. Origin + Width - 1) :=
                       Acts.all (Origin .. Origin + Width - 1);
                  elsif Current.Feed_Norm = null then
                     Norm.all (Origin .. Origin + Width - 1) :=
                       Kept_Norm.all (Origin .. Origin + Width - 1);
                  else
                     Normalize
                       (Source, Acts.all (Origin .. Origin + Width - 1),
                        Current.Feed_Norm.all, Current.Feed_Norm_Bias,
                        Norm.all (Origin .. Origin + Width - 1));
                  end if;
               end;
            end loop;

            --  Which experts run is decided per position, so a batch has no
            --  one matrix to multiply the whole of it by: this is the one
            --  block that runs a token at a time however many were handed
            --  in. Everything before it -- the projections, the attention,
            --  the output -- still goes through the batch.
            if Settings.Experts > 0 then
               for Which in 0 .. Count - 1 loop
                  declare
                     Origin : constant Element_Count := Slot (Which, Width);
                  begin
                     Item.Normalized.all :=
                       Norm.all (Origin .. Origin + Width - 1);
                     Mixture
                       (Item, Current, Item.Normalized, Item.Mixture, Status);
                     exit when E.Is_Error (Status);
                     Norm.all (Origin .. Origin + Width - 1) :=
                       Item.Mixture.all;
                  end;
               end loop;
               exit when E.Is_Error (Status);
            else
               --  As in the single-token path: the two arrangements differ
               --  only in how Gate is filled, and the projection down is
               --  written once so that neither can skip it.
               if not T.Is_Present (Current.Gate) then
                  --  No gate: up, a Gaussian unit, down. As in the
                  --  single-token path, the gate being absent is what says
                  --  so.
                  Product_Batch
                    (Item, Current.Up, Norm, Count, Gate, Status);
                  exit when E.Is_Error (Status);

                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count := Slot (Which, Feed);
                     begin
                        --  Before the unit, as in the single-token path.
                        if Current.Up_Bias /= null then
                           K.Add (Gate.all (Origin .. Origin + Feed - 1),
                                  Current.Up_Bias.all);
                        end if;

                        Gate_Activation
                          (Source, Gate.all (Origin .. Origin + Feed - 1));
                     end;
                  end loop;
               elsif Model_Runner.Backend."="
                       (Item.Owner.Able.Kind,
                        Model_Runner.Backend.Backend_Device)
               then
                  --  A device takes the whole gated block at once -- both
                  --  arms, the unit, the multiply, and the projection that
                  --  reads what they make -- with none of the middle coming
                  --  back. However many positions: the combining step works
                  --  elementwise over whatever the arms hold, and both arms
                  --  are laid out the same way by the same kernel, so what
                  --  that layout is does not matter to it.
                  Model_Runner.Backend.Device.Dispatch_Gated
                    (Current.Gate, Current.Up, Current.Down,
                     Norm, Count, Gate_Unit (Source), Norm, Status,
                     Item.Stopping);
                  exit when E.Is_Error (Status);
                  Whole_Block := True;
               else
                  Product_Batch
                    (Item, Current.Gate, Norm, Count, Gate, Status);
                  exit when E.Is_Error (Status);
                  Product_Batch
                    (Item, Current.Up, Norm, Count, Up, Status);
                  exit when E.Is_Error (Status);

                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count := Slot (Which, Feed);
                     begin
                        Gate_Activation
                          (Source, Gate.all (Origin .. Origin + Feed - 1));
                        K.Multiply
                          (Gate.all (Origin .. Origin + Feed - 1),
                           Up.all (Origin .. Origin + Feed - 1));
                     end;
                  end loop;
               end if;

               if not Whole_Block then
                  Product_Batch
                    (Item, Current.Down, Gate, Count, Norm, Status);
                  exit when E.Is_Error (Status);
               end if;

               if Current.Down_Bias /= null then
                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count := Slot (Which, Width);
                     begin
                        K.Add (Norm.all (Origin .. Origin + Width - 1),
                               Current.Down_Bias.all);
                     end;
                  end loop;
               end if;
            end if;

            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  Join_Residual
                    (Source,
                     Norm.all (Origin .. Origin + Width - 1),
                     Acts.all (Origin .. Origin + Width - 1),
                     Current.Post_Feed_Norm,
                     Current.Post_Feed_Norm_Bias,
                     Item.Post_Room);
               end;
            end loop;
         end;
      end loop;

      if E.Is_Error (Status) then
         Release;
         Item.Current := Failed;
         return;
      end if;

      --  Only the last token's distribution is produced: the earlier tokens
      --  of a prompt are consumed to build context, not to be sampled from.
      --  Every position's state, for a caller that pools over them. The
      --  same normalization the last position gets, applied to each: what
      --  makes an embedding of a text is what the model made of every
      --  position of it, and only this path has them all in hand.
      if States /= null
        and then States.all'Length >= Count * Width
      then
         for Which in 0 .. Count - 1 loop
            declare
               Origin : constant Element_Count := Slot (Which, Width);
            begin
               Final_State
                 (Source, Acts.all (Origin .. Origin + Width - 1),
                  States.all (States.all'First + Origin
                              .. States.all'First + Origin + Width - 1));
            end;
         end loop;
      end if;

      --  Every position's logits, for a caller checking what another model
      --  proposed. The output projection once per position, which is the
      --  largest matrix here: asked for and never given away.
      if Every /= null
        and then Every.all'Length
                 >= Count * Element_Count (Settings.Vocabulary)
      then
         for Which in 0 .. Count - 1 loop
            declare
               Origin : constant Element_Count := Slot (Which, Width);
               Into   : constant Element_Count :=
                 Which * Element_Count (Settings.Vocabulary);
            begin
               Final_State
                 (Source, Acts.all (Origin .. Origin + Width - 1),
                  Item.Normalized.all);

               Product
                 (Item, Source.Output, Item.Normalized, Item.Logit_Row,
                  Status);
               if E.Is_Error (Status) then
                  Release;
                  Item.Current := Failed;
                  return;
               end if;

               Finish_Logits (Source, Item.Logit_Row.all);
               Every.all (Every.all'First + Into
                          .. Every.all'First + Into
                             + Element_Count (Settings.Vocabulary) - 1) :=
                 Item.Logit_Row.all;
            end;
         end loop;
      end if;

      --  The last position's distribution, for the caller who is reading a
      --  prompt in order to continue it. A headless model has none and was
      --  refused the ask on the way in, so there is nothing to compute and
      --  nothing to hand back.
      if Settings.Has_Head then
         declare
            Origin : constant Element_Count := Slot (Count - 1, Width);
         begin
            --  Through the same normalization the single-token path uses,
            --  and not the root-mean-square form directly: an architecture
            --  that centres its normalization would otherwise be centred
            --  everywhere but here, which is a difference only the batched
            --  path shows and only in the logits it returns.
            Final_State
              (Source, Acts.all (Origin .. Origin + Width - 1),
               Item.Normalized.all);
         end;

         Product
           (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
         if E.Is_Error (Status) then
            Release;
            Item.Current := Failed;
            return;
         end if;

         Logits := Item.Logit_Row.all;
         Finish_Logits (Source, Logits);
      end if;

      --  Commit every position of the batch, or none of them.
      for Which in 0 .. Count - 1 loop
         Item.History.all (Item.Committed + Natural (Which)) :=
           Tokens (Tokens'First + Natural (Which));
      end loop;
      Item.Committed := Item.Committed + Natural (Count);
      Status := E.Success;
      Release;
   exception
      when Occurrence : others =>
         Release;
         Item.Current := Failed;
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "llama.evaluate_batch");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Evaluate_Batch;

end Model_Runner.Llama;
