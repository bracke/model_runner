with Ada.Directories;
with Ada.Streams.Stream_IO;

with Interfaces;

with Model_Runner.GGUF;
with Model_Runner.Numerics;

with Fixtures;

package body Tiny_Model is

   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Unsigned_64;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;

   -----------
   -- Build --
   -----------

   --  The rank-one pair the adapter fixture carries, as the two vectors
   --  whose outer product is the difference. Written out here so that the
   --  adapter file and the merged model are built from the same numbers.
   function Adapter_Row (Index : Natural) return N.Real
   is (0.05 * N.Real (Index mod 5) - 0.1);

   function Adapter_Column (Index : Natural) return N.Real
   is (0.02 * N.Real (Index mod 7) - 0.05);

   ------------------
   -- Build_Shaped --
   ------------------

   procedure Build_Shaped
     (Result : out Model_Runner.Bytes.Byte_Array_Access;
      Format : Weight_Format := F32;
      Kind   : Fixture_Architecture := Llama;
      Shape  : Fixture_Shape := Plain) is
   begin
      Build
        (Result, Format, Kind => Kind,
         Window => (if Shape in Windowed | Reaching then 3 else 0),
         Experts => (if Shape = Mixed then 4 else 0),
         Experts_Used => (if Shape = Mixed then 2 else 0),
         Stretch => (if Shape in Stretched | Reaching then Yarn else Plain),
         Rope_Table => Shape in Stretched | Reaching,
         Apart_Widths => Shape = Apart);
   end Build_Shaped;

   procedure Build
     (Result    : out Model_Runner.Bytes.Byte_Array_Access;
      Format    : Weight_Format := F32;
      End_Token : Natural := 2;
      Adds_Beginning : Boolean := True;
      Room      : Positive := Context;
      Kind      : Fixture_Architecture := Llama;
      Omit_Biases : Boolean := False;
      Byte_Pair : Boolean := False;
      Window    : Natural := 0;
      Experts      : Natural := 0;
      Experts_Used : Natural := 0;
      Merged       : Boolean := False;
      Stretch      : Rope_Stretch := Plain;
      Rope_Table   : Boolean := False;
      Apart_Widths : Boolean := False;
      Head_Factor : Positive := 1;
      Sections     : Boolean := False;
      Depth        : Natural := 0;
      Code_Norms   : Boolean := True;
      Ranking      : Boolean := False)
   is
      Quantized : constant Boolean :=
        Format in Q4_0 | Q4_1 | Q5_0 | Q5_1 | Q8_0
                | Q2_K | Q3_K | Q4_K | Q5_K | Q6_K
                | IQ4_NL | IQ4_XS | IQ3_S | IQ2_XXS | MXFP4;
      Deep      : constant Boolean :=
        Format in Q2_K | Q3_K | Q4_K | Q5_K | Q6_K | IQ4_XS | IQ3_S
                | IQ2_XXS;

      --  The quantized fixture is wider because a Q8_0 row must be a whole
      --  number of thirty-two element blocks. Everything else matches.
      Embedding : constant Natural :=
        (if Deep then Deep_Embedding
         elsif Quantized then Wide_Embedding
         else Tiny_Model.Embedding);
      Feed_Forward : constant Natural :=
        (if Deep then Deep_Feed_Forward
         elsif Quantized then Wide_Feed_Forward
         else Tiny_Model.Feed_Forward);
      Head_Size : constant Natural :=
        (if Deep then Deep_Head_Size
         elsif Quantized then Wide_Head_Size
         else Tiny_Model.Head_Size);

      --  One expert is narrower than the dense block, which is the whole
      --  point of having several of them, and the file states that width
      --  separately. A quantized row is still a whole number of blocks, so
      --  the narrowest each fixture can be is what it is.
      Expert_Feed : constant Natural :=
        (if Deep then Deep_Feed_Forward
         elsif Quantized then 32
         else 8);
      --  A key head twice the width the embedding implies and a value head
      --  three times it. Both are stated in the file, and each is a
      --  different number from the other and from the embedding divided by
      --  the head count -- which is three separate assumptions this fixture
      --  breaks at once.
      --  DeepSeek's key head is its whole key_length -- the part that is
      --  rotated and the part that is not -- and its value head is the part
      --  that is not, as the model defines them.
      Key_Size : constant Natural :=
        (if Kind = Deepseek2 then Head_Size
         elsif Apart_Widths then 2 * Head_Size else Head_Factor * Head_Size);
      Value_Size : constant Natural :=
        (if Kind = Deepseek2 then Head_Size - Head_Size / 2
         elsif Apart_Widths then 3 * Head_Size else Head_Factor * Head_Size);

      --  DeepSeek's latent ranks and its one leading dense layer, small.
      DS_Q_Lora    : constant Natural := 4;
      DS_KV_Lora   : constant Natural := 4;
      DS_Leading   : constant Natural := 1;
      DS_Rotary    : constant Natural := Head_Size / 2;
      DS_Nope      : constant Natural := Head_Size - Head_Size / 2;

      Builder : Fixtures.Builder;
      Seed    : Interfaces.Unsigned_64 := 12_345;

      --  Draw the next weight block from the fixed sequence.
      --  How large the two projections that make an attention score are
      --  drawn, which is not a free choice once the fixture is wide.
      --
      --  A projection sums over the embedding, so an element of a query or a
      --  key grows as the square root of the width and their product grows as
      --  the width itself. At eight elements a score is a small number and
      --  the softmax over three positions is a distribution. At two hundred
      --  and fifty-six it was not: the deep fixture's scores read 32.3
      --  against 20.2, which is a softmax that has already decided, and one
      --  position carried the whole of every head.
      --
      --  A model like that cannot feel a small mistake. Moving a key bias by
      --  sixteen left every logit bit for bit the same, because the winner of
      --  a one-hot softmax does not change and nothing else is read -- so the
      --  comparisons that fixture ran said less than their count suggested,
      --  and the check that moves tensors is what said so.
      --
      --  Only the queries and the keys are drawn smaller. Scaling every
      --  weight this way was the first attempt and it moved the problem: the
      --  scores came back to size, and the whole of what a layer contributes
      --  went under what an architecture that multiplies its embedding by the
      --  square root of the width carries in the residual, so gemma3's second
      --  layer stopped answering at all. What a score is made of is what has
      --  to shrink.
      --  How many blocks this fixture holds.
      --
      --  Two for every architecture but gemma3, which is enough to show that
      --  a layer reads what the layer before it wrote. Gemma3 needs six: its
      --  window falls on five layers in six and the sixth sees everything,
      --  and with two blocks that sixth layer is never built -- so the layer
      --  that attends to the whole context, and the rotation base it turns
      --  on, were described in the engine, described again in the
      --  independent implementation, and compared by nothing.
      --  And the hybrid needs three: two of the stack, and past it the
      --  block that drafts the next token, which the file counts among
      --  its blocks and names apart with nextn_predict_layers.
      --  Or as many as the caller asked for.
      Blocks : constant Natural :=
        (if Depth > 0 then Depth
         elsif Kind = Gemma3 then 6 elsif Kind = Qwen35 then Layers + 1
         elsif Kind = Jamba then 4
         elsif Kind = Deepseek2 then 3
         else Layers);

      --  Jamba's four layers, one of each of its two mixers crossed with its
      --  two feed-forwards: a Mamba layer where the index is even and an
      --  attention layer where it is odd, a mixture where it is below two and
      --  a dense feed-forward where it is not -- so a Mamba layer with a
      --  mixture (0), an attention layer with a mixture (1), a Mamba layer
      --  with a dense feed-forward (2) and an attention layer with a dense
      --  one (3), which crosses everything the reader must tell apart.
      function Jamba_Mamba (At_Layer : Natural) return Boolean
      is (At_Layer mod 2 = 0);
      function Jamba_MoE (At_Layer : Natural) return Boolean
      is (At_Layer < 2);

      --  Jamba is a mixture on some layers whatever the sweep asked for, so
      --  it carries a count of its own where the caller named none.
      Eff_Experts : constant Natural :=
        (if Kind in Jamba | Deepseek2 and then Experts = 0 then 4
         else Experts);
      Eff_Used    : constant Natural :=
        (if Kind in Jamba | Deepseek2 and then Experts_Used = 0 then 2
         else Experts_Used);

      --  DeepSeek's mixture layers: every layer past the leading dense ones
      --  carries a router and experts; the leading ones a dense block.
      function DS_MoE (At_Layer : Natural) return Boolean
      is (Kind = Deepseek2 and then At_Layer >= DS_Leading);

      Score_Amplitude : constant N.Real :=
        0.5 * N.Real
                (N.Sqrt
                   (N.Wide_Real (Tiny_Model.Embedding)
                    / N.Wide_Real (Embedding)));

      function Next (Count : N.Element_Count) return N.Real_Array is
      begin
         Seed := Seed + 7919;
         return Fixtures.Sequence (Count, Seed, 0.5);
      end Next;

      --  The same draw at the amplitude a query or a key is drawn at.
      function Next_Score (Count : N.Element_Count) return N.Real_Array is
      begin
         Seed := Seed + 7919;
         return Fixtures.Sequence (Count, Seed, Score_Amplitude);
      end Next_Score;

      --  Append a tensor whose contents are given rather than drawn, which
      --  is what an architecture writing several projections into one tensor
      --  needs: the parts are drawn separately, in the order the unfused
      --  architectures draw them, and written as one. A phi3 fixture is then
      --  the same model as a llama one with its weights in fewer places --
      --  so a reader that splits them correctly gets llama's answer, and the
      --  sweep compares like with like instead of comparing two different
      --  random models and calling the difference a tolerance.
      procedure Weight_Of
        (Name       : String;
         Dimensions : Fixtures.Dimension_List;
         Values     : N.Real_Array)
      is
         --  A block is a run of one row, so it is the row's width that
         --  has to be a whole number of blocks and not the tensor's
         --  count. Asked of the count, a matrix eight wide by an
         --  embedding long was quantized and could not be read back --
         --  the hybrid's projection out of its linear layers, which the
         --  sweep counted as fifteen refusals for as long as the fixture
         --  existed. A tensor with rows too narrow to block stays in
         --  binary32, as a converter keeps one.
         Total : constant N.Element_Count :=
           N.Element_Count (Dimensions (Dimensions'First));
      begin
         --  A quantized model keeps its matrices quantized and its norms
         --  in binary32; the fixture follows that, so the quantized path
         --  is exercised the way a real file exercises it.
            if Format = F16 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_F16,
                  Fixtures.Encode_F16 (Values));
            elsif Format = BF16 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_BF16,
                  Fixtures.Encode_BF16 (Values));
            elsif Format = Q5_0 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q5_0,
                  Fixtures.Encode_Q5_0 (Values));
            elsif Format = Q5_1 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q5_1,
                  Fixtures.Encode_Q5_1 (Values));
            elsif Format = Q3_K and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q3_K,
                  Fixtures.Encode_Q3_K (Values));
            elsif Format = Q5_K and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q5_K,
                  Fixtures.Encode_Q5_K (Values));
            elsif Format = Q6_K and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q6_K,
                  Fixtures.Encode_Q6_K (Values));
            elsif Format = Q4_0 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q4_0,
                  Fixtures.Encode_Q4_0 (Values));
            elsif Format = Q4_1 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q4_1,
                  Fixtures.Encode_Q4_1 (Values));
            elsif Format = Q2_K and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q2_K,
                  Fixtures.Encode_Q2_K (Values));
            elsif Format = Q4_K and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q4_K,
                  Fixtures.Encode_Q4_K (Values));
            elsif Format = IQ4_NL and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_IQ4_NL,
                  Fixtures.Encode_IQ4_NL (Values));
            elsif Format = IQ4_XS and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_IQ4_XS,
                  Fixtures.Encode_IQ4_XS (Values));
            elsif Format = IQ3_S and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_IQ3_S,
                  Fixtures.Encode_IQ3_S (Values));
            elsif Format = IQ2_XXS and then Total mod 256 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_IQ2_XXS,
                  Fixtures.Encode_IQ2_XXS (Values));
            elsif Format = MXFP4 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_MXFP4,
                  Fixtures.Encode_MXFP4 (Values));
            elsif Format = Q8_0 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q8_0,
                  Fixtures.Encode_Q8_0 (Values));
            else
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_F32,
                  Fixtures.Encode_F32 (Values));
            end if;
      end Weight_Of;

      --  The ordinary case: one tensor, drawn as it is written.
      --  Whether a tensor of this name is one of the two a score is made
      --  of. Asked by name so that every architecture's queries and keys are
      --  drawn the same way, whatever else it writes beside them.
      function Makes_A_Score (Name : String) return Boolean
      is (Name'Length >= 13
          and then (Name (Name'Last - 12 .. Name'Last) = "attn_q.weight"
                    or else Name (Name'Last - 12 .. Name'Last)
                            = "attn_k.weight"));

      function Biases_A_Score (Name : String) return Boolean
      is (Name'Length >= 11
          and then (Name (Name'Last - 10 .. Name'Last) = "attn_q.bias"
                    or else Name (Name'Last - 10 .. Name'Last)
                            = "attn_k.bias"));

      procedure Weight
        (Name       : String;
         Dimensions : Fixtures.Dimension_List)
      is
         Total : N.Element_Count := 1;
      begin
         for Extent of Dimensions loop
            Total := Total * N.Element_Count (Extent);
         end loop;

         if Makes_A_Score (Name) then
            Weight_Of (Name, Dimensions, Next_Score (Total));
         else
            Weight_Of (Name, Dimensions, Next (Total));
         end if;
      end Weight;

      --  Append a normalization weight, which is kept near one so that the
      --  normalized activations stay in a comfortable range.
      procedure Norm (Name : String) is
         Values : N.Real_Array (0 .. N.Element_Count (Embedding) - 1);
         Drawn  : constant N.Real_Array :=
           Next (N.Element_Count (Embedding));
      begin
         for Index in Values'Range loop
            Values (Index) := 1.0 + Drawn (Index) * 0.25;
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, [G.U64 (Embedding)], G.Type_F32,
            Fixtures.Encode_F32 (Values));
      end Norm;

      --  A normalization gain of a given width, kept near one for the same
      --  reason the embedding-wide one is: a gain near zero would make what
      --  it scales vanish, and a comparison against nearly nothing says
      --  nearly nothing.
      procedure Gain_Of (Name : String; Width : Positive) is
         Values : N.Real_Array (0 .. N.Element_Count (Width) - 1);
         Drawn  : constant N.Real_Array := Next (N.Element_Count (Width));
      begin
         --  Around one for Gemma as for everything else. It was around
         --  zero for Gemma, so that a fixture could tell a reader that
         --  lifted the gain from one that did not -- and both the engine
         --  and the reference lifted it, so the fixture told nothing, and
         --  a Gemma file holds its gains around one in any case, the
         --  converter having added the one as it wrote.
         for Index in Values'Range loop
            Values (Index) := 1.0 + Drawn (Index) * 0.25;
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, [G.U64 (Width)], G.Type_F32,
            Fixtures.Encode_F32 (Values));
      end Gain_Of;

      --  A one-dimensional tensor of a given width, for the biases.
      procedure Norm_Of (Name : String; Width : Positive) is
         Values : N.Real_Array (0 .. N.Element_Count (Width) - 1);
         Drawn  : constant N.Real_Array :=
           (if Biases_A_Score (Name) then Next_Score (N.Element_Count (Width))
            else Next (N.Element_Count (Width)));
      begin
         for Index in Values'Range loop
            Values (Index) := Drawn (Index) * 0.125;
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, [G.U64 (Width)], G.Type_F32,
            Fixtures.Encode_F32 (Values));
      end Norm_Of;

      Prefix : constant String :=
        (case Kind is
           when Llama     => "llama",
           when Qwen2     => "qwen2",
           when Qwen3     => "qwen3",
           when Qwen3_MoE => "qwen3moe",
           when GPT_OSS   => "gpt-oss",
           when Gemma     => "gemma",
           when Gemma2    => "gemma2",
           when Gemma3    => "gemma3",
           when Phi3      => "phi3",
           when Falcon    => "falcon",
           when Phi2      => "phi2",
           when GPT2      => "gpt2",
           when Bert      => "bert",
           when Nomic_Bert => "nomic-bert",
           when Jina_Bert_V2 => "jina-bert-v2",
           when Qwen35    =>
             (if Experts > 0 then "qwen35moe" else "qwen35"),
           when Granite   =>
             (if Experts > 0 then "granitemoe" else "granite"),
           when Olmo2     => "olmo2",
           when Glm4      => "glm4",
           when Starcoder2 => "starcoder2",
           when Stablelm  => "stablelm",
           when Gptneox   => "gptneox",
           when Internlm2 => "internlm2",
           when Baichuan  => "baichuan",
           when Mpt       => "mpt",
           when Chatglm   => "chatglm",
           when Command_R => "command-r",
           when Mamba     => "mamba",
           when Mamba2    => "mamba2",
           when Rwkv6     => "rwkv6",
           when Jamba     => "jamba",
           when Deepseek2 => "deepseek2");

      --  Whether a block of the hybrid is a linear one: every second block
      --  attends in full, counting from one, as the file counts.
      --  The block past the stack attends in full, whatever its number.
      function Linear_Block (Index : Natural) return Boolean
      is (Kind in Mamba | Mamba2 | Rwkv6
          or else (Kind = Jamba and then Jamba_Mamba (Index))
          or else (Kind = Qwen35 and then Index < Layers
                   and then (Index + 1) mod 2 /= 0));

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Number : constant String := Natural'Image (Index);
      begin
         return "blk." & Number (Number'First + 1 .. Number'Last) & "."
           & Suffix;
      end Layer_Name;

   begin
      Fixtures.Reset (Builder);

      Fixtures.Add_String
        (Builder, "general.architecture", Prefix);
      Fixtures.Add_String (Builder, "general.name", "tiny");
      Fixtures.Add_U32
        (Builder, Prefix & ".context_length", Interfaces.Unsigned_32 (Room));
      Fixtures.Add_U32
        (Builder, Prefix & ".embedding_length", Interfaces.Unsigned_32 (Embedding));
      Fixtures.Add_U32
        (Builder, Prefix & ".block_count",
         Interfaces.Unsigned_32 (Blocks));
      Fixtures.Add_U32
        (Builder, Prefix & ".feed_forward_length", Interfaces.Unsigned_32 (Feed_Forward));
      Fixtures.Add_U32 (Builder, Prefix & ".attention.head_count", Heads);

      --  Jamba states its key-value head count a layer, nought where a layer
      --  keeps a Mamba state and the attention count where it attends, which
      --  is how the file says which layers are which; every other
      --  architecture states one number for the whole model.
      if Kind = Jamba then
         Fixtures.Begin_Array
           (Builder, Prefix & ".attention.head_count_kv",
            Model_Runner.GGUF.Value_Int32, Blocks);
         for Index in 0 .. Blocks - 1 loop
            Fixtures.Int32_Element
              (Builder,
               (if Jamba_Mamba (Index) then 0
                else Interfaces.Integer_32 (KV_Heads)));
         end loop;
         Fixtures.End_Array (Builder);
      else
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.head_count_kv",
            --  DeepSeek's latent attention reconstructs a key and a value
            --  a head, so it is multi-head rather than grouped-query: every
            --  head has its own, the count of them the head count.
            (if Kind = Deepseek2 then Heads else KV_Heads));
      end if;
      --  Bert states the same quantity under the key that names the
      --  normalization it belongs to, which is not the root-mean-square
      --  one. A fixture that wrote the other key would be a file the
      --  engine reads by falling back rather than by reading what bert
      --  files actually say.
      if Kind in Bert | Nomic_Bert | Jina_Bert_V2 | Starcoder2 | Stablelm | Gptneox | Mpt
        | Command_R
      then
         Fixtures.Add_F32
           (Builder, Prefix & ".attention.layer_norm_epsilon", 1.0E-5);
      else
         Fixtures.Add_F32
           (Builder, Prefix & ".attention.layer_norm_rms_epsilon", 1.0E-5);
      end if;

      --  GPT-NeoX's parallel residual, stated and built on: the fixture
      --  exercises the side-by-side path, which is the one that is new code
      --  and the one Pythia and GPT-NeoX-20B run.
      if Kind = Gptneox then
         Fixtures.Add_Bool (Builder, Prefix & ".use_parallel_residual", True);
      end if;

      --  Jina_Bert_V2 states no rotation key at all, as its published files
      --  do not: it is told where a token is by a fall-off in the scores.
      --  Writing a zero here would be this fixture answering a question the
      --  file leaves open, which is what let bert's absent key be read as a
      --  head-wide rotation.
      if Kind not in Jina_Bert_V2 | Mpt then
         Fixtures.Add_U32
           (Builder, Prefix & ".rope.dimension_count",
            (if Kind in GPT2 | Bert
             then 0
             --  StableLM rotates only part of each head -- the leading half
             --  here -- where every other rotating architecture turns the
             --  whole of it. The one fixture that exercises the partial path,
             --  which the split pairing and the tail left alone are crossed
             --  against the independent implementation through.
             elsif Kind in Stablelm | Gptneox | Chatglm | Deepseek2
             then Interfaces.Unsigned_32 (Head_Size / 2)
             else Interfaces.Unsigned_32 (Head_Size)));
      end if;

      --  A jina-bert-v2 that states its own alibi bias rather than leaving
      --  the eight the architecture defaults to: six, so the slope ladder
      --  the engine builds is not the one it would build from the default,
      --  and a reader that ignored the key would answer differently.
      if Kind in Jina_Bert_V2 | Mpt then
         Fixtures.Add_F32 (Builder, Prefix & ".attention.max_alibi_bias", 6.0);
      end if;

      --  MPT clamps its queries, keys and values. Stated here so the clamp
      --  is exercised end to end -- a bound low enough to catch some of the
      --  projected values and leave the rest, so a run that skipped it and a
      --  run that applied it are two different answers, not the same one.
      if Kind = Mpt then
         Fixtures.Add_F32 (Builder, Prefix & ".attention.clamp_kqv", 1.5);
      end if;

      --  A position in three parts, dealt one pair to time and one to
      --  the row: the two pairs a head of four has.
      if Sections and then Kind = Qwen35 then
         Fixtures.Begin_Array
           (Builder, Prefix & ".rope.dimension_sections", G.Value_Int32, 4);
         Fixtures.Int32_Element (Builder, 1);
         Fixtures.Int32_Element (Builder, 1);
         Fixtures.Int32_Element (Builder, 0);
         Fixtures.Int32_Element (Builder, 0);
         Fixtures.End_Array (Builder);
      end if;

      --  The hybrid's linear layers: every second block attends in full;
      --  the rest keep a state of Linear_State by Linear_State a value
      --  head over Linear_Heads key heads and as many value heads, after
      --  a convolution Linear_Taps long. The inner size is the value
      --  heads times the state, which the reader checks.
      if Kind = Qwen35 then
         Fixtures.Add_U32 (Builder, Prefix & ".full_attention_interval", 2);
         Fixtures.Add_U32 (Builder, Prefix & ".ssm.state_size", Linear_State);
         Fixtures.Add_U32 (Builder, Prefix & ".ssm.group_count", Linear_Heads);
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.time_step_rank", Linear_Heads);
         Fixtures.Add_U32 (Builder, Prefix & ".ssm.conv_kernel", Linear_Taps);
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.inner_size",
            Interfaces.Unsigned_32 (Linear_Heads * Linear_State));
         Fixtures.Add_U32 (Builder, Prefix & ".nextn_predict_layers", 1);
      end if;

      --  Mamba's widths: a small state, a short convolution, an inner width
      --  twice the model's and a time step of a couple of ranks. Every layer
      --  is a selective scan and there is no attention anywhere.
      if Kind = Mamba then
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.state_size",
            Interfaces.Unsigned_32 (Linear_State));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.conv_kernel",
            Interfaces.Unsigned_32 (Linear_Taps));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.inner_size",
            Interfaces.Unsigned_32 (2 * Embedding));
         Fixtures.Add_U32 (Builder, Prefix & ".ssm.time_step_rank", 2);
      end if;

      --  Mamba2's widths: the same small state and short convolution, an
      --  inner width twice the model's split into four heads, and B and C
      --  shared across two groups -- two heads a group, so the group
      --  sharing and the two-group normalization are both exercised. The
      --  time-step rank carries the head count, as Mamba2 states it.
      if Kind = Mamba2 then
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.state_size",
            Interfaces.Unsigned_32 (Linear_State));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.conv_kernel",
            Interfaces.Unsigned_32 (Linear_Taps));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.inner_size",
            Interfaces.Unsigned_32 (2 * Embedding));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.time_step_rank",
            Interfaces.Unsigned_32 (2 * Linear_Heads));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.group_count",
            Interfaces.Unsigned_32 (Linear_Heads));
      end if;

      --  RWKV6's shape: a head width that divides the model width, the two
      --  low ranks its shift and its decay project through, and two token
      --  shift slots. No rescaling in the fixture -- its residual is short
      --  enough not to need it -- and a plain layer-norm epsilon.
      if Kind = Rwkv6 then
         Fixtures.Add_U32
           (Builder, Prefix & ".wkv.head_size",
            Interfaces.Unsigned_32 (Embedding / Linear_Heads));
         Fixtures.Add_U32
           (Builder, Prefix & ".time_mix_extra_dim", 2);
         Fixtures.Add_U32
           (Builder, Prefix & ".time_decay_extra_dim", 2);
         Fixtures.Add_U32 (Builder, Prefix & ".rescale_every_n_layers", 2);
         Fixtures.Add_U32 (Builder, Prefix & ".token_shift_count", 2);
         Fixtures.Add_F32
           (Builder, Prefix & ".attention.layer_norm_epsilon", 1.0e-5);
      end if;

      --  Jamba's Mamba layers read the same widths under the same keys plain
      --  Mamba does: a small state, a short convolution, an inner width
      --  twice the model's and a low time step.
      if Kind = Jamba then
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.state_size",
            Interfaces.Unsigned_32 (Linear_State));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.conv_kernel",
            Interfaces.Unsigned_32 (Linear_Taps));
         Fixtures.Add_U32
           (Builder, Prefix & ".ssm.inner_size",
            Interfaces.Unsigned_32 (2 * Embedding));
         Fixtures.Add_U32 (Builder, Prefix & ".ssm.time_step_rank", 2);
      end if;

      --  Which pooling the model was trained for, which is a thing a bert
      --  file states and a decoder does not. Written as the first position,
      --  because that is what these vocabularies put a marker at.
      if Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
         --  The first position for the two that a published file pools that
         --  way, and the mean for the one whose published file states the
         --  mean. Two answers rather than one, because a reader that pooled
         --  every such model the same way would agree with this fixture
         --  about all of them.
         Fixtures.Add_U32
           (Builder, Prefix & ".pooling_type",
            (if Ranking then 4 elsif Kind = Jina_Bert_V2 then 1 else 2));

         --  Stated rather than left to the architecture's name, because a
         --  published file states it and a fixture that did not would let a
         --  reader which ignores the key pass.
         Fixtures.Add_Bool
           (Builder, Prefix & ".attention.causal", False);
      end if;

      --  The head widths, when the file states them apart. DeepSeek always
      --  states them: its key head is the whole key_length and its value
      --  head the part that is not rotated, neither the embedding over the
      --  head count.
      if Apart_Widths or else Head_Factor > 1 or else Kind = Deepseek2 then
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.key_length",
            Interfaces.Unsigned_32 (Key_Size));
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.value_length",
            Interfaces.Unsigned_32 (Value_Size));
      end if;

      --  DeepSeek's latent ranks and its leading dense layers.
      if Kind = Deepseek2 then
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.q_lora_rank",
            Interfaces.Unsigned_32 (DS_Q_Lora));
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.kv_lora_rank",
            Interfaces.Unsigned_32 (DS_KV_Lora));
         Fixtures.Add_U32
           (Builder, Prefix & ".leading_dense_block_count",
            Interfaces.Unsigned_32 (DS_Leading));
      end if;
      Fixtures.Add_F32 (Builder, Prefix & ".rope.freq_base", 10_000.0);

      --  How the rotation is stretched, when it is. A factor of four with
      --  a trained context of half what the model declares is a model asked
      --  to reach well past what it saw, which is the case the method
      --  exists for.
      if Stretch /= Plain then
         Fixtures.Add_String
           (Builder, Prefix & ".rope.scaling.type",
            (if Stretch = Yarn then "yarn" else "linear"));
         Fixtures.Add_F32 (Builder, Prefix & ".rope.scaling.factor", 4.0);

         if Stretch = Yarn then
            Fixtures.Add_U32
              (Builder, Prefix & ".rope.scaling.original_context_length",
               Interfaces.Unsigned_32 (Positive'Max (1, Room / 2)));
            Fixtures.Add_F32
              (Builder, Prefix & ".rope.scaling.attn_factor", 1.0);
            Fixtures.Add_F32
              (Builder, Prefix & ".rope.scaling.beta_fast", 32.0);
            Fixtures.Add_F32
              (Builder, Prefix & ".rope.scaling.beta_slow", 1.0);
         end if;
      end if;

      --  What GPT_OSS states and no other architecture here does: a window
      --  every other layer, and a base of its own for the layers that slide
      --  one. The engine refuses to guess at either.
      --
      --  The window is the shape's where the shape names one, and GPT_OSS's
      --  own four otherwise: written twice, the file carried the key twice
      --  and the reader refused it, which the sweep counted as fifteen
      --  refusals of the windowed shape for as long as both were written.
      if Kind = GPT_OSS then
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.sliding_window",
            Interfaces.Unsigned_32 (if Window > 0 then Window else 4));
         Fixtures.Add_F32
           (Builder, Prefix & ".rope.freq_base_swa", 8_000.0);
      end if;

      --  A mixture of experts, when one is asked for. Absent otherwise,
      --  which is what a dense model looks like. Jamba carries a count of
      --  its own, being a mixture on some of its layers whatever was asked.
      if Eff_Experts > 0 then
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_count",
            Interfaces.Unsigned_32 (Eff_Experts));
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_used_count",
            Interfaces.Unsigned_32 (Eff_Used));
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_feed_forward_length",
            Interfaces.Unsigned_32 (Expert_Feed));

         --  GraniteMoE scales its renormalized weights by a number it
         --  carries; written off one so a reader that ignored it answers
         --  differently. Only granitemoe states it, so every other mixture's
         --  fixture is left as it was.
         if Kind = Granite then
            Fixtures.Add_F32 (Builder, Prefix & ".expert_weights_scale", 1.3);
         end if;

         --  The shared expert every position of a hybrid mixture goes
         --  through beside the chosen ones. Its width is stated apart, as
         --  the file states it; the same width as an expert here, which is
         --  enough to run the path.
         if Kind = Qwen35 then
            Fixtures.Add_U32
              (Builder, Prefix & ".expert_shared_feed_forward_length",
               Interfaces.Unsigned_32 (Expert_Feed));
         end if;
      end if;

      --  A sliding window, when one is asked for. Absent otherwise, which
      --  is what a model that attends to everything looks like.
      if Window > 0 and then Kind /= GPT_OSS then
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.sliding_window",
            Interfaces.Unsigned_32 (Window));
      end if;

      --  Gemma2's two bounds. Small numbers rather than the fifty and
      --  thirty a real one carries, so that the fixture's own scores and
      --  logits actually reach them: a bound nothing reaches is a bound
      --  neither implementation can be shown to apply.
      if Kind = Gemma2 then
         Fixtures.Add_F32
           (Builder, Prefix & ".attn_logit_softcapping", 4.0);
         Fixtures.Add_F32
           (Builder, Prefix & ".final_logit_softcapping", 2.0);
      end if;

      --  Granite's four multipliers, each far enough from one that a reader
      --  which dropped it answers differently rather than nearly the same,
      --  and none so large it drives the fixture's own arithmetic out of
      --  range: the embedding is lifted, each sublayer's output is damped
      --  before it joins the residual, the attention scale is stated in
      --  place of one over the root of the head width, and the logits are
      --  divided down.
      if Kind = Granite then
         Fixtures.Add_F32 (Builder, Prefix & ".embedding_scale", 1.5);
         Fixtures.Add_F32 (Builder, Prefix & ".residual_scale", 0.7);
         Fixtures.Add_F32 (Builder, Prefix & ".attention.scale", 0.2);
         Fixtures.Add_F32 (Builder, Prefix & ".logit_scale", 2.0);
      end if;

      --  Command-R carries the same key but multiplies by it. A value below
      --  one, so a run that applied it and one that did not are two answers.
      if Kind = Command_R then
         Fixtures.Add_F32 (Builder, Prefix & ".logit_scale", 0.5);
      end if;

      --  Gemma3 turns its windowed layers on a base of their own. Far from
      --  the model's, so that a reader which used one base for every layer
      --  answers visibly differently rather than nearly the same.
      if Kind = Gemma3 then
         Fixtures.Add_F32 (Builder, Prefix & ".rope.local_freq_base", 500.0);
      end if;

      --  A bert file carries a WordPiece vocabulary, and the architecture
      --  decides it rather than the caller: a bert written with a
      --  SentencePiece vocabulary is not a file anyone ships, and building
      --  the sweep out of one would check the engine against a model that
      --  does not exist.
      Fixtures.Add_String
        (Builder, "tokenizer.ggml.model",
         (if Kind in Bert | Nomic_Bert | Jina_Bert_V2 then "bert"
          elsif Byte_Pair then "gpt2"
          else "llama"));

      --  A minimal template inside the supported subset, so that the
      --  conversation path can be exercised end to end without a real model.
      Fixtures.Add_String
        (Builder, "tokenizer.chat_template",
         "{% for message in messages %}"
         & "{{ message['role'] + ': ' + message['content'] + '\n' }}"
         & "{% endfor %}"
         & "{% if add_generation_prompt %}{{ 'assistant: ' }}{% endif %}");

      --  The byte-pair vocabulary. Sixteen pieces again, so the embedding
      --  matrix fits either, and the same three control tokens at the same
      --  identifiers, so a test varying the end token means the same thing
      --  on both roads. The pieces are written in the stand-in alphabet
      --  those vocabularies use, where a space is U+0120.
      --  The WordPiece vocabulary. Sixteen pieces again, at the same three
      --  control identifiers, so a test that varies the end token means the
      --  same thing on all three roads. What is its own is the shape of the
      --  pieces: a piece that starts a word carries a leading U+2581 and one
      --  that continues a word is written bare, so "abc" is reachable both
      --  as one marked piece and as marked "ab" with bare "c" -- and which
      --  of those a reader takes is the whole of what this road decides.
      --
      --  Written with two leading hashes at first, because that is the
      --  convention the architecture's papers describe. No converted
      --  vocabulary uses it: of the thirty thousand pieces in a published
      --  all-MiniLM not one begins with the hashes and twenty-four thousand
      --  begin with this marker. A fixture written from the paper made both
      --  the engine and the reader written against it agree about a model
      --  nobody ships, and a real file then embedded text nobody wrote.
      if Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
         declare
            Mark : constant String :=
              [Character'Val (16#E2#), Character'Val (16#96#),
               Character'Val (16#81#)];

            type Text_Access is access constant String;
            Pieces : constant array (1 .. Vocabulary) of Text_Access :=
              [new String'("[UNK]"),
               new String'("[CLS]"),
               new String'("[SEP]"),
               new String'("[PAD]"),
               new String'(Mark & "a"),
               new String'(Mark & "b"),
               new String'(Mark & "c"),
               new String'(Mark & "ab"),
               new String'("b"),
               new String'("c"),
               new String'("bc"),
               new String'(Mark & "abc"),
               new String'(Mark & "x"),
               new String'("a"),
               new String'(Mark & "1"),
               new String'(Mark & "2")];
         begin
            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.tokens", G.Value_String, Vocabulary);
            for Index in Pieces'Range loop
               Fixtures.String_Element (Builder, Pieces (Index).all);
            end loop;
            Fixtures.End_Array (Builder);

            --  Scores mean nothing on this road -- there is no merge to
            --  order -- and the array is written because the reader asks
            --  every vocabulary for one.
            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.scores", G.Value_Float32, Vocabulary);
            for Index in 0 .. Vocabulary - 1 loop
               Fixtures.Float_Element (Builder, 0.0);
            end loop;
            Fixtures.End_Array (Builder);

            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.token_type", G.Value_Int32,
               Vocabulary);
            Fixtures.Int32_Element (Builder, 2);   --  [UNK]
            Fixtures.Int32_Element (Builder, 3);   --  [CLS]
            Fixtures.Int32_Element (Builder, 3);   --  [SEP]
            Fixtures.Int32_Element (Builder, 3);   --  [PAD]
            for Index in 5 .. Vocabulary loop
               Fixtures.Int32_Element (Builder, 1);
            end loop;
            Fixtures.End_Array (Builder);
         end;

      elsif Byte_Pair then
         declare
            Space : constant String :=
              [Character'Val (16#C4#), Character'Val (16#A0#)];

            type Text_Access is access constant String;
            Pieces : constant array (1 .. Vocabulary) of Text_Access :=
              [new String'("<unk>"),
               new String'("<s>"),
               new String'("</s>"),
               new String'(Space),
               new String'("a"),
               new String'("b"),
               new String'("c"),
               new String'("ab"),
               new String'("bc"),
               new String'(Space & "a"),
               new String'(Space & "ab"),
               new String'("abc"),
               new String'("x"),
               new String'(Space & "b"),
               new String'("1"),
               new String'("2")];

            --  Rank order, and not the order the pieces are written: what
            --  decides a merge here is the rank and not the score.
            Merges : constant array (1 .. 6) of Text_Access :=
              [new String'(Space & " a"),
               new String'(Space & "a b"),
               new String'(Space & " b"),
               new String'("b c"),
               new String'("a b"),
               new String'("ab c")];
         begin
            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.tokens", G.Value_String, Vocabulary);
            for Index in Pieces'Range loop
               Fixtures.String_Element (Builder, Pieces (Index).all);
            end loop;
            Fixtures.End_Array (Builder);

            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.merges", G.Value_String,
               Merges'Length);
            for Index in Merges'Range loop
               Fixtures.String_Element (Builder, Merges (Index).all);
            end loop;
            Fixtures.End_Array (Builder);

            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.scores", G.Value_Float32, Vocabulary);
            for Index in 0 .. Vocabulary - 1 loop
               Fixtures.Float_Element (Builder, 0.0);
            end loop;
            Fixtures.End_Array (Builder);

            Fixtures.Begin_Array
              (Builder, "tokenizer.ggml.token_type", G.Value_Int32,
               Vocabulary);
            Fixtures.Int32_Element (Builder, 2);   --  <unk>
            Fixtures.Int32_Element (Builder, 3);   --  <s>
            Fixtures.Int32_Element (Builder, 3);   --  </s>
            for Index in 4 .. Vocabulary loop
               Fixtures.Int32_Element (Builder, 1);
            end loop;
            Fixtures.End_Array (Builder);
         end;
      else

         --  A vocabulary with three control tokens, a handful of ordinary
         --  pieces and byte-fallback tokens, which is the smallest shape that
         --  still exercises every decoding path.
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, Vocabulary);
         Fixtures.String_Element (Builder, "<unk>");
         Fixtures.String_Element (Builder, "<s>");
         Fixtures.String_Element (Builder, "</s>");
         Fixtures.String_Element
           (Builder,
            [1 => Character'Val (16#E2#), 2 => Character'Val (16#96#),
             3 => Character'Val (16#81#)]);
         Fixtures.String_Element (Builder, "a");
         Fixtures.String_Element (Builder, "b");
         Fixtures.String_Element (Builder, "c");
         Fixtures.String_Element (Builder, "ab");
         Fixtures.String_Element (Builder, "bc");
         Fixtures.String_Element
           (Builder,
            [1 => Character'Val (16#E2#), 2 => Character'Val (16#96#),
             3 => Character'Val (16#81#)] & "a");
         Fixtures.String_Element (Builder, "<0x61>");
         Fixtures.String_Element (Builder, "<0x62>");
         Fixtures.String_Element (Builder, "<0x63>");
         Fixtures.String_Element (Builder, "<0x64>");
         Fixtures.String_Element (Builder, "<0x20>");
         Fixtures.String_Element (Builder, "<0x0A>");
         Fixtures.End_Array (Builder);

         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.scores", G.Value_Float32, Vocabulary);
         for Index in 0 .. Vocabulary - 1 loop
            --  Longer pieces score higher so that the merge order is
            --  deterministic and easy to predict.
            Fixtures.Float_Element (Builder, N.Real (Index) * 0.5);
         end loop;
         Fixtures.End_Array (Builder);

         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.token_type", G.Value_Int32, Vocabulary);
         Fixtures.Int32_Element (Builder, 2);   --  <unk>
         Fixtures.Int32_Element (Builder, 3);   --  <s>
         Fixtures.Int32_Element (Builder, 3);   --  </s>
         for Index in 3 .. 9 loop
            Fixtures.Int32_Element (Builder, 1);
         end loop;
         for Index in 10 .. Vocabulary - 1 loop
            Fixtures.Int32_Element (Builder, 6);
         end loop;
         Fixtures.End_Array (Builder);
      end if;

      Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 1);
      Fixtures.Add_U32
        (Builder, "tokenizer.ggml.eos_token_id",
         Interfaces.Unsigned_32 (End_Token));
      --  The two flags, except on the road where a published file states
      --  neither. A WordPiece text is wrapped in its markers by
      --  construction, and an all-MiniLM says so by saying nothing: it
      --  states the two identifiers and no flag at all.
      --
      --  Written here for every road at first, which meant this fixture
      --  answered a question real files leave to the road -- so the engine
      --  reading absent as "the model does not say" could not be caught by
      --  anything here. It was caught by a second runtime instead, at a
      --  cosine of 0.994. A fixture that states what no file states is a
      --  fixture that cannot fail the way a file makes you fail.
      if Kind not in Bert | Nomic_Bert | Jina_Bert_V2 then
         Fixtures.Add_Bool
           (Builder, "tokenizer.ggml.add_bos_token", Adds_Beginning);
         Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);
      end if;

      --  The per-dimension divisors, when the file carries them. Written
      --  deliberately rather than drawn from the sequence: a divisor near
      --  zero is a huge angle, which says nothing about whether the table is
      --  read and everything about floating point.
      if Rope_Table then
         declare
            --  Half the rotated width, which is the whole head for every
            --  architecture that turns all of it and the leading half for
            --  the one that turns part -- the table has a divisor a rotated
            --  pair, so a partial rotation carries a shorter table.
            Rotated : constant Natural :=
              (if Kind in Stablelm | Gptneox | Chatglm then Head_Size / 2 else Head_Size);
            Values : N.Real_Array (0 .. N.Element_Count (Rotated / 2) - 1);
         begin
            for Index in Values'Range loop
               Values (Index) := 1.0 + N.Real (Index) * 0.5;
            end loop;
            Fixtures.Add_Tensor
              (Builder, "rope_freqs.weight", [G.U64 (Rotated / 2)],
               G.Type_F32, Fixtures.Encode_F32 (Values));
         end;
      end if;

      Weight ("token_embd.weight", [G.U64 (Embedding), Vocabulary]);

      --  Bert's other two embeddings and the normalization over their sum.
      --  Two segment rows, of which a text uses the first: the second is
      --  written because the architecture states it, and a fixture that
      --  wrote one row would let a reader that ignores the segment
      --  entirely agree with one that reads it.
      if Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
         Weight ("token_types.weight", [G.U64 (Embedding), G.U64 (2)]);
         Norm ("token_embd_norm.weight");
         Norm_Of ("token_embd_norm.bias", Embedding);
      end if;

      --  RWKV6 normalizes the embedding once before the first block (ln0),
      --  by centring with a shift as Bert does.
      if Kind = Rwkv6 then
         Norm ("token_embd_norm.weight");
         Norm_Of ("token_embd_norm.bias", Embedding);
      end if;

      for Index in 0 .. Blocks - 1 loop
         --  Every architecture but Bert normalizes on the way into the
         --  block. Bert's two normalizations are on the way out of its two
         --  sublayers and are written below.
         if Kind not in Bert | Nomic_Bert | Jina_Bert_V2 | Olmo2 then
            Norm (Layer_Name (Index, "attn_norm.weight"));
         end if;

         --  Gemma2's two extra normalizations, one after each sublayer,
         --  which OLMo2 carries under the same names and is the whole of
         --  its normalization, having none on the way in.
         if Kind in Gemma2 | Gemma3 | Olmo2 | Glm4 then
            Norm (Layer_Name (Index, "post_attention_norm.weight"));
            Norm (Layer_Name (Index, "post_ffw_norm.weight"));
         end if;
         if Merged and then Index = 0 then
            --  The same weights, plus the difference the adapter fixture
            --  describes: alpha times the outer product of its two
            --  vectors, which is what merging that adapter has to produce.
            declare
               Rows  : constant N.Element_Count :=
                 N.Element_Count (Heads * Key_Size);
               Cols  : constant N.Element_Count :=
                 N.Element_Count (Embedding);
               Values : N.Real_Array := Next (Rows * Cols);
            begin
               for Row in 0 .. Rows - 1 loop
                  for Column in 0 .. Cols - 1 loop
                     Values (Row * Cols + Column) :=
                       Values (Row * Cols + Column)
                       + N.Real (Adapter_Alpha)
                         * Adapter_Column (Natural (Row))
                         * Adapter_Row (Natural (Column));
                  end loop;
               end loop;

               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "attn_q.weight"),
                  [G.U64 (Embedding), G.U64 (Heads * Key_Size)],
                  G.Type_F32, Fixtures.Encode_F32 (Values));
            end;
         elsif Linear_Block (Index) and then Kind = Rwkv6 then
            --  RWKV6's own: its second normalization, the eight wide
            --  matrices of its two mixes, the four low projections of its
            --  shift and its decay, the five streams' interpolation, and the
            --  vectors the products do not touch.
            declare
               D_TM  : constant Natural := 2;
               D_Dec : constant Natural := 2;
               Feed  : constant Natural := Feed_Forward;
            begin
               Norm (Layer_Name (Index, "attn_norm_2.weight"));
               Norm_Of (Layer_Name (Index, "attn_norm_2.bias"), Embedding);

               Weight (Layer_Name (Index, "time_mix_receptance.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "time_mix_key.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "time_mix_value.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "time_mix_gate.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "time_mix_output.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "channel_mix_key.weight"),
                       [G.U64 (Embedding), G.U64 (Feed)]);
               Weight (Layer_Name (Index, "channel_mix_value.weight"),
                       [G.U64 (Feed), G.U64 (Embedding)]);
               Weight (Layer_Name (Index, "channel_mix_receptance.weight"),
                       [G.U64 (Embedding), G.U64 (Embedding)]);

               Weight (Layer_Name (Index, "time_mix_w1.weight"),
                       [G.U64 (Embedding), G.U64 (5 * D_TM)]);
               Weight (Layer_Name (Index, "time_mix_w2.weight"),
                       [G.U64 (D_TM), G.U64 (5 * Embedding)]);
               Weight (Layer_Name (Index, "time_mix_decay_w1.weight"),
                       [G.U64 (Embedding), G.U64 (D_Dec)]);
               Weight (Layer_Name (Index, "time_mix_decay_w2.weight"),
                       [G.U64 (D_Dec), G.U64 (Embedding)]);

               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "time_mix_lerp_fused.weight"),
                  [G.U64 (Embedding), G.U64 (5)], G.Type_F32,
                  Fixtures.Encode_F32 (Next (N.Element_Count (5 * Embedding))));

               Norm_Of (Layer_Name (Index, "time_mix_lerp_x.weight"), Embedding);
               Norm_Of (Layer_Name (Index, "time_mix_first.weight"), Embedding);
               Norm_Of (Layer_Name (Index, "time_mix_decay.weight"), Embedding);
               Norm_Of (Layer_Name (Index, "time_mix_ln.weight"), Embedding);
               Norm_Of (Layer_Name (Index, "time_mix_ln.bias"), Embedding);
               Norm_Of
                 (Layer_Name (Index, "channel_mix_lerp_k.weight"), Embedding);
               Norm_Of
                 (Layer_Name (Index, "channel_mix_lerp_r.weight"), Embedding);
            end;
         elsif Linear_Block (Index) and then Kind = Mamba2 then
            --  Mamba2's own: one projection in (the gate, the activation, B
            --  and C, and a step a head), the convolution over the
            --  activation and B and C with its bias, the per-head transition
            --  -- negative, so the state decays -- the per-head skip and
            --  step bias, the gated normalization's gain, and the way back.
            declare
               Inner  : constant Natural := 2 * Embedding;
               State  : constant Natural := Linear_State;
               Heads  : constant Natural := 2 * Linear_Heads;
               Grps   : constant Natural := Linear_Heads;
               DXBC   : constant Natural := Inner + 2 * Grps * State;
               In_Out : constant Natural := Inner + DXBC + Heads;
               A_Vals : N.Real_Array (0 .. N.Element_Count (Heads) - 1);
            begin
               Weight (Layer_Name (Index, "ssm_in.weight"),
                       [G.U64 (Embedding), G.U64 (In_Out)]);

               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_conv1d.weight"),
                  [G.U64 (Linear_Taps), G.U64 (DXBC)], G.Type_F32,
                  Fixtures.Encode_F32
                    (Next (N.Element_Count (Linear_Taps * DXBC))));
               Norm_Of (Layer_Name (Index, "ssm_conv1d.bias"), DXBC);

               --  The transition a head, already the negative exponential
               --  the file stores: a decay between nought and one.
               for H in A_Vals'Range loop
                  A_Vals (H) := -(0.5 + 0.25 * N.Real (Natural (H)));
               end loop;
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_a"),
                  [G.U64 (Heads)], G.Type_F32,
                  Fixtures.Encode_F32 (A_Vals));

               Norm_Of (Layer_Name (Index, "ssm_d"), Heads);
               Norm_Of (Layer_Name (Index, "ssm_dt.bias"), Heads);
               Norm_Of (Layer_Name (Index, "ssm_norm.weight"), Inner);
               Weight (Layer_Name (Index, "ssm_out.weight"),
                       [G.U64 (Inner), G.U64 (Embedding)]);
            end;
         elsif Linear_Block (Index) and then Kind in Mamba | Jamba then
            --  Mamba's own: the input projection to the inner activation and
            --  its gate, the convolution with its bias, the projection to
            --  the time step and B and C, the time step's projection up with
            --  its bias, the transition -- negative, so the state decays --
            --  the skip and the projection back. Jamba's Mamba layers add a
            --  normalization of the time step and of the B and C.
            declare
               Inner : constant Natural := 2 * Embedding;
               State : constant Natural := Linear_State;
               Rank  : constant Natural := 2;
               A_Vals : N.Real_Array (0 .. N.Element_Count (Inner * State) - 1);
               Drawn  : constant N.Real_Array :=
                 Next (N.Element_Count (Inner * State));
            begin
               Weight (Layer_Name (Index, "ssm_in.weight"),
                       [G.U64 (Embedding), G.U64 (2 * Inner)]);

               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_conv1d.weight"),
                  [G.U64 (Linear_Taps), G.U64 (Inner)], G.Type_F32,
                  Fixtures.Encode_F32
                    (Next (N.Element_Count (Linear_Taps * Inner))));
               Norm_Of (Layer_Name (Index, "ssm_conv1d.bias"), Inner);

               Weight (Layer_Name (Index, "ssm_x.weight"),
                       [G.U64 (Inner), G.U64 (Rank + 2 * State)]);

               if Kind = Jamba then
                  Norm_Of (Layer_Name (Index, "ssm_dt_norm.weight"), Rank);
                  Norm_Of (Layer_Name (Index, "ssm_b_norm.weight"), State);
                  Norm_Of (Layer_Name (Index, "ssm_c_norm.weight"), State);
               end if;

               Weight (Layer_Name (Index, "ssm_dt.weight"),
                       [G.U64 (Rank), G.U64 (Inner)]);
               Norm_Of (Layer_Name (Index, "ssm_dt.bias"), Inner);

               --  The transition a state a channel, already the negative
               --  exponential the file stores rather than the log-of-minus
               --  it trains: a decay between nought and one, never a growth.
               for I in A_Vals'Range loop
                  A_Vals (I) := -(0.5 + 0.5 * abs (Drawn (I)));
               end loop;
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_a"),
                  [G.U64 (State), G.U64 (Inner)], G.Type_F32,
                  Fixtures.Encode_F32 (A_Vals));

               Norm_Of (Layer_Name (Index, "ssm_d"), Inner);
               Weight (Layer_Name (Index, "ssm_out.weight"),
                       [G.U64 (Inner), G.U64 (Embedding)]);
            end;
         elsif Linear_Block (Index) then
            --  The linear layer's own: the three projections in one, the
            --  gate, the decay and the rate a value head, the decay's
            --  shape -- negative, as a file stores minus the exponential
            --  of what was trained -- the rate's bias, the taps, the
            --  blend's gain and the way back.
            declare
               Mix : constant Natural :=
                 (2 * Linear_Heads + Linear_Heads) * Linear_State;
               Val : constant Natural := Linear_Heads * Linear_State;
               Shape_Of_Decay : N.Real_Array (0 .. Linear_Heads - 1);
            begin
               Weight (Layer_Name (Index, "attn_qkv.weight"),
                       [G.U64 (Embedding), G.U64 (Mix)]);
               Weight (Layer_Name (Index, "attn_gate.weight"),
                       [G.U64 (Embedding), G.U64 (Val)]);
               Weight (Layer_Name (Index, "ssm_alpha.weight"),
                       [G.U64 (Embedding), G.U64 (Linear_Heads)]);
               Weight (Layer_Name (Index, "ssm_beta.weight"),
                       [G.U64 (Embedding), G.U64 (Linear_Heads)]);

               for H in Shape_Of_Decay'Range loop
                  Shape_Of_Decay (H) := -0.5 - 0.25 * N.Real (H);
               end loop;
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_a"),
                  [G.U64 (Linear_Heads)], G.Type_F32,
                  Fixtures.Encode_F32 (Shape_Of_Decay));

               Norm_Of (Layer_Name (Index, "ssm_dt.bias"), Linear_Heads);
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ssm_conv1d.weight"),
                  [G.U64 (Linear_Taps), G.U64 (Mix)], G.Type_F32,
                  Fixtures.Encode_F32
                    (Next_Score (N.Element_Count (Linear_Taps * Mix))));
               Gain_Of (Layer_Name (Index, "ssm_norm.weight"), Linear_State);
               Weight (Layer_Name (Index, "ssm_out.weight"),
                       [G.U64 (Val), G.U64 (Embedding)]);
            end;
         elsif Kind = Qwen35 then
            --  Twice as wide: each head's queries and then its gate.
            Weight (Layer_Name (Index, "attn_q.weight"),
                    [G.U64 (Embedding), G.U64 (2 * Heads * Key_Size)]);
         elsif Kind in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Mpt
                     | Chatglm
         then
            --  One tensor holding all three, in the order a reader has to
            --  take them out: queries, then keys, then values -- and drawn
            --  as three, in the order every other architecture draws them,
            --  so this fixture is that fixture with its weights in fewer
            --  places rather than a different model.
            declare
               use type N.Real_Array;

               Q : constant N.Real_Array :=
                 Next_Score (N.Element_Count (Embedding * Heads * Key_Size));
               K : constant N.Real_Array :=
                 Next_Score (N.Element_Count (Embedding * KV_Heads * Key_Size));
               V : constant N.Real_Array :=
                 Next (N.Element_Count (Embedding * KV_Heads * Value_Size));
            begin
               Weight_Of
                 (Layer_Name (Index, "attn_qkv.weight"),
                  [G.U64 (Embedding),
                   G.U64 (Heads * Key_Size + KV_Heads * Key_Size
                          + KV_Heads * Value_Size)],
                  Q & K & V);
            end;
         elsif Kind = Deepseek2 then
            --  DeepSeek's latent projections: the query through a latent
            --  and a norm, the keys and values through a latent that
            --  carries the rotated slice beside it, its norm over the
            --  latent alone, and the up projection out to a nope key and a
            --  value a head.
            Weight (Layer_Name (Index, "attn_q_a.weight"),
                    [G.U64 (Embedding), G.U64 (DS_Q_Lora)]);
            Gain_Of (Layer_Name (Index, "attn_q_a_norm.weight"), DS_Q_Lora);
            Weight (Layer_Name (Index, "attn_q_b.weight"),
                    [G.U64 (DS_Q_Lora), G.U64 (Heads * Key_Size)]);
            Weight (Layer_Name (Index, "attn_kv_a_mqa.weight"),
                    [G.U64 (Embedding), G.U64 (DS_KV_Lora + DS_Rotary)]);
            Gain_Of (Layer_Name (Index, "attn_kv_a_norm.weight"), DS_KV_Lora);
            Weight (Layer_Name (Index, "attn_kv_b.weight"),
                    [G.U64 (DS_KV_Lora),
                     G.U64 (Heads * (DS_Nope + Value_Size))]);
         else
            Weight (Layer_Name (Index, "attn_q.weight"),
                    [G.U64 (Embedding), G.U64 (Heads * Key_Size)]);
         end if;

         --  Only where the three are not already in one tensor. A file that
         --  carried both would say two different things about the same
         --  projection, and a reader that preferred one would agree with a
         --  reader that preferred the other about nothing.
         if Kind not in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Chatglm
                      | Deepseek2
           and then not Linear_Block (Index)
         then
            Weight (Layer_Name (Index, "attn_k.weight"),
                    [G.U64 (Embedding), G.U64 (KV_Heads * Key_Size)]);
            Weight (Layer_Name (Index, "attn_v.weight"),
                    [G.U64 (Embedding), G.U64 (KV_Heads * Value_Size)]);
         end if;
         --  Qwen2 carries a bias beside each projection; Llama has none.
         --  Bert carries the same three, written the same way.
         if Kind in Qwen2 | Bert | Jina_Bert_V2 | Glm4 | Starcoder2 | Stablelm
           and then not Omit_Biases
         then
            Norm_Of (Layer_Name (Index, "attn_q.bias"), Heads * Key_Size);
            Norm_Of (Layer_Name (Index, "attn_k.bias"), KV_Heads * Key_Size);
            Norm_Of (Layer_Name (Index, "attn_v.bias"), KV_Heads * Value_Size);
         end if;

         --  Qwen3 normalizes each query head and each key head instead of
         --  biasing the projections. One gain per element of a head, shared
         --  across the heads.
         --  Falcon's normalization carries a bias, which is a different
         --  thing from the projection biases Qwen2 has: it belongs to the
         --  normalization and every falcon file has one.
         if Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox
           | Rwkv6
         then
            Norm_Of (Layer_Name (Index, "attn_norm.bias"), Embedding);
         end if;

         --  Phi2 biases the three projections as Qwen2 does and writes the
         --  three in one vector, as it writes the three matrices in one
         --  tensor. Drawn as three in the order the unfused architectures
         --  draw them, for the reason Weight_Of exists.
         if Kind in Phi2 | GPT2 | Gptneox | Chatglm then
            declare
               use type N.Real_Array;

               Q : constant N.Real_Array :=
                 Next_Score (N.Element_Count (Heads * Key_Size));
               K : constant N.Real_Array :=
                 Next_Score (N.Element_Count (KV_Heads * Key_Size));
               V : constant N.Real_Array :=
                 Next (N.Element_Count (KV_Heads * Value_Size));
               Whole : constant N.Real_Array := Q & K & V;
               Eased : N.Real_Array (Whole'Range);
            begin
               for Index in Whole'Range loop
                  Eased (Index) := Whole (Index) * 0.125;
               end loop;

               --  In binary32 whatever the matrices are in, as a real
               --  file writes a bias: quantizing it made every reader that
               --  asks for a plain vector refuse the model, which is a
               --  refusal the sweep counted as an architecture it had
               --  nothing to say about.
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "attn_qkv.bias"),
                  [G.U64 (Heads * Key_Size + KV_Heads * Key_Size
                          + KV_Heads * Value_Size)],
                  G.Type_F32, Fixtures.Encode_F32 (Eased));
            end;
         end if;

         if (Kind in Qwen3 | Qwen3_MoE | Gemma3
             or else (Kind = Qwen35 and then not Linear_Block (Index)))
           and then not Omit_Biases
         then
            Gain_Of (Layer_Name (Index, "attn_q_norm.weight"), Key_Size);
            Gain_Of (Layer_Name (Index, "attn_k_norm.weight"), Key_Size);
         end if;

         --  Command-R+ carries a head norm under the same names, but a gain
         --  a head rather than one shared across them, so each is as wide as
         --  the whole projection. Written here to cross the centred per-head
         --  normalization; a Command-R without them is Falcon's plain path.
         if Kind = Command_R then
            Gain_Of
              (Layer_Name (Index, "attn_q_norm.weight"), Heads * Key_Size);
            Gain_Of
              (Layer_Name (Index, "attn_k_norm.weight"), KV_Heads * Key_Size);
         end if;

         if not Linear_Block (Index) then
            Weight (Layer_Name (Index, "attn_output.weight"),
                    [G.U64 (Heads * Value_Size), G.U64 (Embedding)]);
         end if;

         --  What makes the block past the stack a draft: the projection
         --  from the next token's embedding beside the stack's state,
         --  the normalization of each, and the one ahead of the head.
         if Kind = Qwen35 and then Index >= Layers then
            Weight (Layer_Name (Index, "nextn.eh_proj.weight"),
                    [G.U64 (2 * Embedding), G.U64 (Embedding)]);
            Norm (Layer_Name (Index, "nextn.enorm.weight"));
            Norm (Layer_Name (Index, "nextn.hnorm.weight"));
            Norm (Layer_Name (Index, "nextn.shared_head_norm.weight"));
         end if;
         --  One normalization a block where the two sublayers run in
         --  parallel; two where they run one after the other.
         if Kind in Phi2 | GPT2 | Bert | Jina_Bert_V2 | GPT_OSS | Starcoder2 | Gptneox
         then
            Norm_Of (Layer_Name (Index, "attn_output.bias"), Embedding);
         end if;

         --  One score a head that joins the softmax's denominator, which is
         --  this architecture's own and nothing else here has.
         if Kind = GPT_OSS then
            Norm_Of (Layer_Name (Index, "attn_sinks.weight"), Heads);
         end if;

         --  Bert's normalization over the residual once attention has been
         --  added to it, and the one over the residual once the
         --  feed-forward has. Both centre and both carry a shift.
         --  Both of the arrangement's normalizations, written together
         --  because both belong to it rather than to the shape of the
         --  feed-forward below: the second was written inside the gateless
         --  block, which the gated one of these two architectures never
         --  reaches.
         if Kind in Bert | Nomic_Bert | Jina_Bert_V2 then
            Norm (Layer_Name (Index, "attn_output_norm.weight"));
            Norm_Of (Layer_Name (Index, "attn_output_norm.bias"), Embedding);
            Norm (Layer_Name (Index, "layer_output_norm.weight"));
            Norm_Of
              (Layer_Name (Index, "layer_output_norm.bias"), Embedding);
         end if;

         --  The code variant's six: over the whole of the queries and of
         --  the keys, each the width of its projection, and the attention
         --  sublayer's second, the width of the embedding.
         if Kind = Jina_Bert_V2 and then Code_Norms then
            Gain_Of (Layer_Name (Index, "attn_q_norm.weight"),
                     Heads * Key_Size);
            Norm_Of (Layer_Name (Index, "attn_q_norm.bias"),
                     Heads * Key_Size);
            Gain_Of (Layer_Name (Index, "attn_k_norm.weight"),
                     KV_Heads * Key_Size);
            Norm_Of (Layer_Name (Index, "attn_k_norm.bias"),
                     KV_Heads * Key_Size);
            Norm (Layer_Name (Index, "attn_norm_2.weight"));
            Norm_Of (Layer_Name (Index, "attn_norm_2.bias"), Embedding);
         end if;

         --  OLMo2 normalizes the whole of the query and key projections,
         --  root-mean-square and without a shift -- the same tensor names
         --  qwen3 uses per head, here over the whole projection.
         if Kind = Olmo2 then
            Gain_Of (Layer_Name (Index, "attn_q_norm.weight"),
                     Heads * Key_Size);
            Gain_Of (Layer_Name (Index, "attn_k_norm.weight"),
                     KV_Heads * Key_Size);
         end if;

         if Kind not in Falcon | Phi2 | Bert | Nomic_Bert | Jina_Bert_V2
                       | Olmo2 | Command_R
         then
            --  Named for what it follows by the hybrid, for what it
            --  precedes by the rest; the same normalization.
            Norm (Layer_Name (Index,
                              (if Kind = Qwen35
                               then "post_attention_norm.weight"
                               else "ffn_norm.weight")));

            --  The shift beside it, which a centring architecture carries
            --  and this fixture did not write. Every published gpt2 has
            --  one, the engine did not read it, and nothing here could see
            --  that because the fixture the engine was checked against had
            --  no such tensor either. Falcon and phi2 never reach this:
            --  they have one normalization a block.
            if Kind in GPT2 | Starcoder2 | Stablelm | Gptneox then
               Norm_Of (Layer_Name (Index, "ffn_norm.bias"), Embedding);
            end if;
         end if;

         if (if Kind = Jamba then Jamba_MoE (Index)
             elsif Kind = Deepseek2 then DS_MoE (Index)
             else Experts > 0)
         then
            --  The router, then the experts stacked on an outermost axis,
            --  which is how a file writes them: one tensor a matrix rather
            --  than one tensor an expert. Jamba carries this on its mixture
            --  layers and the plain feed-forward below on its dense ones.
            Weight (Layer_Name (Index, "ffn_gate_inp.weight"),
                    [G.U64 (Embedding), G.U64 (Eff_Experts)]);
            Weight (Layer_Name (Index, "ffn_gate_exps.weight"),
                    [G.U64 (Embedding), G.U64 (Expert_Feed), G.U64 (Eff_Experts)]);
            Weight (Layer_Name (Index, "ffn_up_exps.weight"),
                    [G.U64 (Embedding), G.U64 (Expert_Feed), G.U64 (Eff_Experts)]);
            Weight (Layer_Name (Index, "ffn_down_exps.weight"),
                    [G.U64 (Expert_Feed), G.U64 (Embedding), G.U64 (Eff_Experts)]);

            --  And the biases GPT_OSS carries on all of them, laid out the
            --  way the weights are: every expert's in one tensor.
            if Kind = GPT_OSS then
               Norm_Of (Layer_Name (Index, "ffn_gate_inp.bias"), Experts);
               Norm_Of (Layer_Name (Index, "ffn_gate_exps.bias"),
                        Expert_Feed * Experts);
               Norm_Of (Layer_Name (Index, "ffn_up_exps.bias"),
                        Expert_Feed * Experts);
               Norm_Of (Layer_Name (Index, "ffn_down_exps.bias"),
                        Embedding * Experts);
            end if;
            --  The shared expert: the same gate-up-down block an expert
            --  is, and a row that gates its answer against the input. Every
            --  layer of a hybrid mixture carries one, the block past the
            --  stack included.
            if Kind = Qwen35 then
               Weight (Layer_Name (Index, "ffn_gate_shexp.weight"),
                       [G.U64 (Embedding), G.U64 (Expert_Feed)]);
               Weight (Layer_Name (Index, "ffn_up_shexp.weight"),
                       [G.U64 (Embedding), G.U64 (Expert_Feed)]);
               Weight (Layer_Name (Index, "ffn_down_shexp.weight"),
                       [G.U64 (Expert_Feed), G.U64 (Embedding)]);
               --  The shared expert's gating row, drawn small and centred
               --  rather than around one: it is a projection to one number
               --  through a sigmoid, and a row of ones saturates the gate,
               --  so moving it leaves the answer where a quantized run's
               --  noise hides it. Centred, the gate sits where it responds.
               Fixtures.Add_Tensor
                 (Builder, Layer_Name (Index, "ffn_gate_inp_shexp.weight"),
                  [G.U64 (Embedding)], G.Type_F32,
                  Fixtures.Encode_F32 (Next (N.Element_Count (Embedding))));
            end if;
         elsif Kind in Falcon | Phi2 | GPT2 | Bert | Starcoder2 | Gptneox | Mpt then
            --  No gate: one projection up and one down.
            Weight (Layer_Name (Index, "ffn_up.weight"),
                    [G.U64 (Embedding), G.U64 (Feed_Forward)]);
            Weight (Layer_Name (Index, "ffn_down.weight"),
                    [G.U64 (Feed_Forward), G.U64 (Embedding)]);

            --  And a bias on each side of it, which Phi2 has and Falcon
            --  does not: the arrangement they share does not decide this.
            if Kind in Phi2 | GPT2 | Bert | Starcoder2 | Gptneox then
               Norm_Of (Layer_Name (Index, "ffn_up.bias"), Feed_Forward);
               Norm_Of (Layer_Name (Index, "ffn_down.bias"), Embedding);
            end if;

            --  And the second of Bert's two normalizations, over the
            --  residual the feed-forward has just been added to.

         elsif Kind in Phi3 | Glm4 | Chatglm then
            --  The gate and the up projection in one tensor, gate first,
            --  and drawn as two for the same reason.
            declare
               use type N.Real_Array;

               Gate : constant N.Real_Array :=
                 Next (N.Element_Count (Embedding * Feed_Forward));
               Up   : constant N.Real_Array :=
                 Next (N.Element_Count (Embedding * Feed_Forward));
            begin
               Weight_Of
                 (Layer_Name (Index, "ffn_up.weight"),
                  [G.U64 (Embedding), G.U64 (2 * Feed_Forward)],
                  Gate & Up);
            end;
            Weight (Layer_Name (Index, "ffn_down.weight"),
                    [G.U64 (Feed_Forward), G.U64 (Embedding)]);
         else
            Weight (Layer_Name (Index, "ffn_gate.weight"),
                    [G.U64 (Embedding), G.U64 (Feed_Forward)]);
            Weight (Layer_Name (Index, "ffn_up.weight"),
                    [G.U64 (Embedding), G.U64 (Feed_Forward)]);
            Weight (Layer_Name (Index, "ffn_down.weight"),
                    [G.U64 (Feed_Forward), G.U64 (Embedding)]);

            --  The one gated architecture here that shifts what it projects
            --  down, and it shifts nothing else: no bias on the gate, none
            --  on the way up. A fixture that wrote all three would let a
            --  reader taking every bias it finds agree with one asking for
            --  the one the architecture states.
            if Kind = Jina_Bert_V2 then
               Norm_Of (Layer_Name (Index, "ffn_down.bias"), Embedding);
            end if;
         end if;
      end loop;

      --  Bert has no normalization between its last layer and whatever
      --  reads it: its last layer already normalized what it produced.
      if Kind not in Bert | Nomic_Bert | Jina_Bert_V2 then
         Norm ("output_norm.weight");
         if Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox
                  | Rwkv6
         then
            Norm ("output_norm.bias");
         end if;
      end if;

      --  One row a position, which is what GPT2 and Bert have instead of a
      --  rotation.
      if Kind in GPT2 | Bert then
         Weight ("position_embd.weight",
                 [G.U64 (Embedding), G.U64 (Room)]);
      end if;

      --  And no projection to a distribution. A bert file carries none and
      --  ties none: writing one here would let a reader that invents a head
      --  for such a model pass, which is exactly the reading the engine
      --  refuses.
      if Kind not in Bert | Nomic_Bert | Jina_Bert_V2 then
         Weight ("output.weight", [G.U64 (Embedding), Vocabulary]);
      end if;

      --  A reranker's scoring head, where this fixture builds one: a dense
      --  of the embedding width and its bias, then a single row down to the
      --  score and its bias.
      if Ranking then
         Weight ("cls.weight", [G.U64 (Embedding), G.U64 (Embedding)]);
         Norm ("cls.bias");
         Weight ("cls.output.weight", [G.U64 (Embedding), G.U64 (1)]);
         Norm_Of ("cls.output.bias", 1);
      end if;

      --  Phi2's output projection carries a bias, so the last thing this
      --  writes is the last thing the model adds. GPT2's does not, which a
      --  published gpt2 file said and this fixture had been contradicting.
      if Kind = Phi2 then
         Norm_Of ("output.bias", Natural (Vocabulary));
      end if;

      Fixtures.Build (Builder, Result);
   end Build;

   -----------
   -- Write --
   -----------

   ---------------------------
   -- Write_Suite_Fixture --
   ---------------------------

   procedure Write_Suite_Fixture is
   begin
      --  The directory is in the repository -- it carries the prompts and
      --  the expectation files -- but a checkout that somehow lacks it
      --  should get a fixture rather than an exception from deep inside a
      --  test that is about something else.
      if not Ada.Directories.Exists ("fixtures") then
         Ada.Directories.Create_Path ("fixtures");
      end if;

      Write (Suite_Fixture);
   end Write_Suite_Fixture;

   --------------------
   -- Write_Adapter --
   --------------------

   procedure Write_Adapter
     (Path    : String;
      Half    : Boolean := False;
      Foreign : Boolean := False;
      Deep    : Boolean := False;
      Rank    : Positive := 1;
      Apart   : Boolean := False)
   is
      Wide_Of : constant Natural :=
        (if Deep then Deep_Embedding else Embedding);
      Tall_Of : constant Natural :=
        (if Deep then Heads * Deep_Head_Size
         elsif Apart then Heads * 2 * Head_Size
         else Heads * Head_Size);

      use Ada.Streams;

      Builder : Fixtures.Builder;
      Image   : Model_Runner.Bytes.Byte_Array_Access;
      Handle  : Stream_IO.File_Type;

      Stem : constant String :=
        (if Foreign
         then "blk.0.attn_norm.weight"
         else "blk.0.attn_q.weight");
   begin
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "general.type", "adapter");
      Fixtures.Add_String (Builder, "adapter.type", "lora");
      Fixtures.Add_F32 (Builder, "adapter.lora.alpha", Adapter_Alpha);

      --  The first of the pair is the rank by the input width; the second
      --  is the output width by the rank. GGUF writes the contiguous
      --  dimension first, so each is written the way it is read.
      declare
         --  Rank rows of the first and rank columns of the second. Only the
         --  first row and column carry the difference the merge test checks;
         --  the rest are zero, so a higher rank costs the merge what a real
         --  one costs without changing what it produces.
         Down : N.Real_Array
           (0 .. N.Element_Count (Wide_Of) * N.Element_Count (Rank) - 1) :=
             [others => 0.0];
         Up   : N.Real_Array
           (0 .. N.Element_Count (Tall_Of) * N.Element_Count (Rank) - 1) :=
             [others => 0.0];
      begin
         for Index in 0 .. N.Element_Count (Wide_Of) - 1 loop
            Down (Index) := Adapter_Row (Natural (Index));
         end loop;
         for Index in 0 .. N.Element_Count (Tall_Of) - 1 loop
            Up (Index * N.Element_Count (Rank)) :=
              Adapter_Column (Natural (Index));
         end loop;

         Fixtures.Add_Tensor
           (Builder, Stem & ".lora_a", [G.U64 (Wide_Of), G.U64 (Rank)],
            G.Type_F32, Fixtures.Encode_F32 (Down));

         if not Half then
            Fixtures.Add_Tensor
              (Builder, Stem & ".lora_b", [G.U64 (Rank), G.U64 (Tall_Of)],
               G.Type_F32, Fixtures.Encode_F32 (Up));
         end if;
      end;

      Fixtures.Build (Builder, Image);

      Stream_IO.Create (Handle, Stream_IO.Out_File, Path);
      declare
         Block : Stream_Element_Array
           (1 .. Stream_Element_Offset (Image.all'Length));
         Target : Stream_Element_Offset := 0;
      begin
         for Value of Image.all loop
            Target := Target + 1;
            Block (Target) := Stream_Element (Value);
         end loop;
         Stream_IO.Write (Handle, Block);
      end;
      Stream_IO.Close (Handle);

      Model_Runner.Bytes.Free (Image);
   end Write_Adapter;

   procedure Write
     (Path : String;
      Adds_Beginning : Boolean := True;
      Room : Positive := Context;
      Format : Weight_Format := F32;
      Kind : Fixture_Architecture := Llama;
      Shape : Fixture_Shape := Plain) is
      use Ada.Streams;
      Image  : Model_Runner.Bytes.Byte_Array_Access;
      Handle : Stream_IO.File_Type;
   begin
      --  The shape decides the window, the experts and the stretch, and it
      --  decided them only for a fixture built in memory: a file written to
      --  disk was always the plain one, whatever architecture it declared.
      --  A mixture-of-experts file with no expert keys in it is a dense
      --  model under another name, which is not what a caller asking for
      --  one wants to inspect.
      Build (Image, Format => Format,
             Adds_Beginning => Adds_Beginning, Room => Room, Kind => Kind,
             Window => (if Shape in Windowed | Reaching then 3 else 0),
             Experts => (if Shape = Mixed then 4 else 0),
             Experts_Used => (if Shape = Mixed then 2 else 0),
             Stretch => (if Shape in Stretched | Reaching then Yarn else Plain),
             Rope_Table => Shape in Stretched | Reaching,
             Apart_Widths => Shape = Apart);

      Stream_IO.Create (Handle, Stream_IO.Out_File, Path);

      declare
         Block : Stream_Element_Array
           (1 .. Stream_Element_Offset (Image.all'Length));
         Target : Stream_Element_Offset := 0;
      begin
         for Value of Image.all loop
            Target := Target + 1;
            Block (Target) := Stream_Element (Value);
         end loop;
         Stream_IO.Write (Handle, Block);
      end;

      Stream_IO.Close (Handle);
      Model_Runner.Bytes.Free (Image);
   end Write;

end Tiny_Model;
