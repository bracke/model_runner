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

   Hex : constant String := "0123456789ABCDEF";

   -----------
   -- Build --
   -----------

   procedure Build (Result : out Model_Runner.Bytes.Byte_Array_Access) is
      Builder : Fixtures.Builder;
      Seed    : Interfaces.Unsigned_64 := 12_345;

      --  Draw the next weight block from the fixed sequence.
      function Next (Count : N.Element_Count) return N.Real_Array is
      begin
         Seed := Seed + 7919;
         return Fixtures.Sequence (Count, Seed, 0.5);
      end Next;

      --  Append a float32 tensor whose contents come from the sequence.
      procedure Weight
        (Name       : String;
         Dimensions : Fixtures.Dimension_List)
      is
         Total : N.Element_Count := 1;
      begin
         for Extent of Dimensions loop
            Total := Total * N.Element_Count (Extent);
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, Dimensions, G.Type_F32,
            Fixtures.Encode_F32 (Next (Total)));
      end Weight;

      --  Append a normalization weight, which is kept near one so that the
      --  normalized activations stay in a comfortable range.
      procedure Norm (Name : String) is
         Values : N.Real_Array (0 .. Embedding - 1);
         Drawn  : constant N.Real_Array := Next (Embedding);
      begin
         for Index in Values'Range loop
            Values (Index) := 1.0 + Drawn (Index) * 0.25;
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, [G.U64 (Embedding)], G.Type_F32,
            Fixtures.Encode_F32 (Values));
      end Norm;

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Digit : constant String := [1 => Hex (Index + 1)];
      begin
         return "blk." & Digit & "." & Suffix;
      end Layer_Name;

   begin
      Fixtures.Reset (Builder);

      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "general.name", "tiny");
      Fixtures.Add_U32 (Builder, "llama.context_length", Context);
      Fixtures.Add_U32 (Builder, "llama.embedding_length", Embedding);
      Fixtures.Add_U32 (Builder, "llama.block_count", Layers);
      Fixtures.Add_U32 (Builder, "llama.feed_forward_length", Feed_Forward);
      Fixtures.Add_U32 (Builder, "llama.attention.head_count", Heads);
      Fixtures.Add_U32 (Builder, "llama.attention.head_count_kv", KV_Heads);
      Fixtures.Add_F32
        (Builder, "llama.attention.layer_norm_rms_epsilon", 1.0E-5);
      Fixtures.Add_U32 (Builder, "llama.rope.dimension_count", Head_Size);
      Fixtures.Add_F32 (Builder, "llama.rope.freq_base", 10_000.0);

      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");

      --  A minimal template inside the supported subset, so that the
      --  conversation path can be exercised end to end without a real model.
      Fixtures.Add_String
        (Builder, "tokenizer.chat_template",
         "{% for message in messages %}"
         & "{{ message['role'] + ': ' + message['content'] + '\n' }}"
         & "{% endfor %}"
         & "{% if add_generation_prompt %}{{ 'assistant: ' }}{% endif %}");

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

      Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 1);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 2);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_bos_token", True);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);

      Weight ("token_embd.weight", [Embedding, Vocabulary]);

      for Index in 0 .. Layers - 1 loop
         Norm (Layer_Name (Index, "attn_norm.weight"));
         Weight (Layer_Name (Index, "attn_q.weight"), [Embedding, Embedding]);
         Weight (Layer_Name (Index, "attn_k.weight"),
                 [Embedding, KV_Heads * Head_Size]);
         Weight (Layer_Name (Index, "attn_v.weight"),
                 [Embedding, KV_Heads * Head_Size]);
         Weight (Layer_Name (Index, "attn_output.weight"),
                 [Embedding, Embedding]);
         Norm (Layer_Name (Index, "ffn_norm.weight"));
         Weight (Layer_Name (Index, "ffn_gate.weight"),
                 [Embedding, Feed_Forward]);
         Weight (Layer_Name (Index, "ffn_up.weight"), [Embedding, Feed_Forward]);
         Weight (Layer_Name (Index, "ffn_down.weight"),
                 [Feed_Forward, Embedding]);
      end loop;

      Norm ("output_norm.weight");
      Weight ("output.weight", [Embedding, Vocabulary]);

      Fixtures.Build (Builder, Result);
   end Build;

   -----------
   -- Write --
   -----------

   procedure Write (Path : String) is
      use Ada.Streams;
      Image  : Model_Runner.Bytes.Byte_Array_Access;
      Handle : Stream_IO.File_Type;
   begin
      Build (Image);

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
