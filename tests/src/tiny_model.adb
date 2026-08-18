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

   Hex : constant String := "0123456789ABCDEF";

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
         Window => (if Shape = Windowed then 3 else 0),
         Experts => (if Shape = Mixed then 4 else 0),
         Experts_Used => (if Shape = Mixed then 2 else 0),
         Stretch => (if Shape = Stretched then Yarn else Plain),
         Rope_Table => Shape = Stretched,
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
      Apart_Widths : Boolean := False)
   is
      Quantized : constant Boolean :=
        Format in Q4_0 | Q4_1 | Q5_0 | Q5_1 | Q8_0
                | Q2_K | Q3_K | Q4_K | Q5_K | Q6_K
                | IQ4_NL | IQ4_XS;
      Deep      : constant Boolean :=
        Format in Q2_K | Q3_K | Q4_K | Q5_K | Q6_K | IQ4_XS;

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
      Key_Size : constant Natural :=
        (if Apart_Widths then 2 * Head_Size else Head_Size);
      Value_Size : constant Natural :=
        (if Apart_Widths then 3 * Head_Size else Head_Size);

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
      Blocks : constant Natural := (if Kind = Gemma3 then 6 else Layers);

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
         Total : constant N.Element_Count := Values'Length;
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

         --  Around zero where the architecture's gain is one plus the
         --  weight, as in Gain_Of and for the same reason.
         Middle : constant N.Real :=
           (if Kind in Gemma | Gemma2 | Gemma3 then 0.0 else 1.0);
      begin
         for Index in Values'Range loop
            Values (Index) := Middle + Drawn (Index) * 0.25;
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

         --  Around zero for Gemma and around one for everything else,
         --  because that is what the two conventions mean. Written this way
         --  on purpose: a Gemma fixture whose weights sat around one would
         --  answer nearly the same whether the reader lifted the gain or
         --  not, and a fixture that cannot tell two readings apart is a
         --  fixture that proves neither.
         Middle : constant N.Real :=
           (if Kind in Gemma | Gemma2 | Gemma3 then 0.0 else 1.0);
      begin
         for Index in Values'Range loop
            Values (Index) := Middle + Drawn (Index) * 0.25;
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
           when Gemma     => "gemma",
           when Gemma2    => "gemma2",
           when Gemma3    => "gemma3",
           when Phi3      => "phi3",
           when Falcon    => "falcon",
           when Phi2      => "phi2",
           when GPT2      => "gpt2");

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Digit : constant String := [1 => Hex (Index + 1)];
      begin
         return "blk." & Digit & "." & Suffix;
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
      Fixtures.Add_U32 (Builder, Prefix & ".attention.head_count_kv", KV_Heads);
      Fixtures.Add_F32
        (Builder, Prefix & ".attention.layer_norm_rms_epsilon", 1.0E-5);
      Fixtures.Add_U32
        (Builder, Prefix & ".rope.dimension_count",
         (if Kind = GPT2 then 0 else Interfaces.Unsigned_32 (Head_Size)));

      --  The head widths, when the file states them apart.
      if Apart_Widths then
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.key_length",
            Interfaces.Unsigned_32 (Key_Size));
         Fixtures.Add_U32
           (Builder, Prefix & ".attention.value_length",
            Interfaces.Unsigned_32 (Value_Size));
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

      --  A mixture of experts, when one is asked for. Absent otherwise,
      --  which is what a dense model looks like.
      if Experts > 0 then
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_count",
            Interfaces.Unsigned_32 (Experts));
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_used_count",
            Interfaces.Unsigned_32 (Experts_Used));
         Fixtures.Add_U32
           (Builder, Prefix & ".expert_feed_forward_length",
            Interfaces.Unsigned_32 (Expert_Feed));
      end if;

      --  A sliding window, when one is asked for. Absent otherwise, which
      --  is what a model that attends to everything looks like.
      if Window > 0 then
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

      --  Gemma3 turns its windowed layers on a base of their own. Far from
      --  the model's, so that a reader which used one base for every layer
      --  answers visibly differently rather than nearly the same.
      if Kind = Gemma3 then
         Fixtures.Add_F32 (Builder, Prefix & ".rope.local_freq_base", 500.0);
      end if;

      Fixtures.Add_String
        (Builder, "tokenizer.ggml.model",
         (if Byte_Pair then "gpt2" else "llama"));

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
      if Byte_Pair then
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
      Fixtures.Add_Bool
        (Builder, "tokenizer.ggml.add_bos_token", Adds_Beginning);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);

      --  The per-dimension divisors, when the file carries them. Written
      --  deliberately rather than drawn from the sequence: a divisor near
      --  zero is a huge angle, which says nothing about whether the table is
      --  read and everything about floating point.
      if Rope_Table then
         declare
            Values : N.Real_Array (0 .. N.Element_Count (Head_Size / 2) - 1);
         begin
            for Index in Values'Range loop
               Values (Index) := 1.0 + N.Real (Index) * 0.5;
            end loop;
            Fixtures.Add_Tensor
              (Builder, "rope_freqs.weight", [G.U64 (Head_Size / 2)],
               G.Type_F32, Fixtures.Encode_F32 (Values));
         end;
      end if;

      Weight ("token_embd.weight", [G.U64 (Embedding), Vocabulary]);

      for Index in 0 .. Blocks - 1 loop
         Norm (Layer_Name (Index, "attn_norm.weight"));

         --  Gemma2's two extra normalizations, one after each sublayer.
         if Kind in Gemma2 | Gemma3 then
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
         elsif Kind in Phi3 | Falcon | Phi2 | GPT2 then
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
         else
            Weight (Layer_Name (Index, "attn_q.weight"),
                    [G.U64 (Embedding), G.U64 (Heads * Key_Size)]);
         end if;

         --  Only where the three are not already in one tensor. A file that
         --  carried both would say two different things about the same
         --  projection, and a reader that preferred one would agree with a
         --  reader that preferred the other about nothing.
         if Kind not in Phi3 | Falcon | Phi2 | GPT2 then
            Weight (Layer_Name (Index, "attn_k.weight"),
                    [G.U64 (Embedding), G.U64 (KV_Heads * Key_Size)]);
            Weight (Layer_Name (Index, "attn_v.weight"),
                    [G.U64 (Embedding), G.U64 (KV_Heads * Value_Size)]);
         end if;
         --  Qwen2 carries a bias beside each projection; Llama has none.
         if Kind = Qwen2 and then not Omit_Biases then
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
         if Kind in Falcon | Phi2 | GPT2 then
            Norm_Of (Layer_Name (Index, "attn_norm.bias"), Embedding);
         end if;

         --  Phi2 biases the three projections as Qwen2 does and writes the
         --  three in one vector, as it writes the three matrices in one
         --  tensor. Drawn as three in the order the unfused architectures
         --  draw them, for the reason Weight_Of exists.
         if Kind in Phi2 | GPT2 then
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

         if Kind in Qwen3 | Qwen3_MoE | Gemma3
           and then not Omit_Biases
         then
            Gain_Of (Layer_Name (Index, "attn_q_norm.weight"), Key_Size);
            Gain_Of (Layer_Name (Index, "attn_k_norm.weight"), Key_Size);
         end if;

         Weight (Layer_Name (Index, "attn_output.weight"),
                 [G.U64 (Heads * Value_Size), G.U64 (Embedding)]);
         --  One normalization a block where the two sublayers run in
         --  parallel; two where they run one after the other.
         if Kind in Phi2 | GPT2 then
            Norm_Of (Layer_Name (Index, "attn_output.bias"), Embedding);
         end if;

         if Kind not in Falcon | Phi2 then
            Norm (Layer_Name (Index, "ffn_norm.weight"));
         end if;

         if Experts > 0 then
            --  The router, then the experts stacked on an outermost axis,
            --  which is how a file writes them: one tensor a matrix rather
            --  than one tensor an expert.
            Weight (Layer_Name (Index, "ffn_gate_inp.weight"),
                    [G.U64 (Embedding), G.U64 (Experts)]);
            Weight (Layer_Name (Index, "ffn_gate_exps.weight"),
                    [G.U64 (Embedding), G.U64 (Expert_Feed), G.U64 (Experts)]);
            Weight (Layer_Name (Index, "ffn_up_exps.weight"),
                    [G.U64 (Embedding), G.U64 (Expert_Feed), G.U64 (Experts)]);
            Weight (Layer_Name (Index, "ffn_down_exps.weight"),
                    [G.U64 (Expert_Feed), G.U64 (Embedding), G.U64 (Experts)]);
         elsif Kind in Falcon | Phi2 | GPT2 then
            --  No gate: one projection up and one down.
            Weight (Layer_Name (Index, "ffn_up.weight"),
                    [G.U64 (Embedding), G.U64 (Feed_Forward)]);
            Weight (Layer_Name (Index, "ffn_down.weight"),
                    [G.U64 (Feed_Forward), G.U64 (Embedding)]);

            --  And a bias on each side of it, which Phi2 has and Falcon
            --  does not: the arrangement they share does not decide this.
            if Kind in Phi2 | GPT2 then
               Norm_Of (Layer_Name (Index, "ffn_up.bias"), Feed_Forward);
               Norm_Of (Layer_Name (Index, "ffn_down.bias"), Embedding);
            end if;
         elsif Kind = Phi3 then
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
         end if;
      end loop;

      Norm ("output_norm.weight");
      if Kind in Falcon | Phi2 | GPT2 then
         Norm ("output_norm.bias");
      end if;
      --  One row a position, which is what GPT2 has instead of a rotation.
      if Kind = GPT2 then
         Weight ("position_embd.weight",
                 [G.U64 (Embedding), G.U64 (Room)]);
      end if;

      Weight ("output.weight", [G.U64 (Embedding), Vocabulary]);

      --  Phi2's output projection carries a bias, so the last thing this
      --  writes is the last thing the model adds.
      if Kind in Phi2 | GPT2 then
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
      Format : Weight_Format := F32) is
      use Ada.Streams;
      Image  : Model_Runner.Bytes.Byte_Array_Access;
      Handle : Stream_IO.File_Type;
   begin
      Build (Image, Format => Format,
             Adds_Beginning => Adds_Beginning, Room => Room);

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
