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

   Hex : constant String := "0123456789ABCDEF";

   -----------
   -- Build --
   -----------

   procedure Build
     (Result    : out Model_Runner.Bytes.Byte_Array_Access;
      Format    : Weight_Format := Float32;
      End_Token : Natural := 2;
      Adds_Beginning : Boolean := True;
      Room      : Positive := Context;
      Qwen      : Boolean := False;
      Omit_Biases : Boolean := False)
   is
      Quantized : constant Boolean := Format = Q8_0;

      --  The quantized fixture is wider because a Q8_0 row must be a whole
      --  number of thirty-two element blocks. Everything else matches.
      Embedding : constant Natural :=
        (if Quantized then Wide_Embedding else Tiny_Model.Embedding);
      Feed_Forward : constant Natural :=
        (if Quantized then Wide_Feed_Forward else Tiny_Model.Feed_Forward);
      Head_Size : constant Natural :=
        (if Quantized then Wide_Head_Size else Tiny_Model.Head_Size);
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
         declare
            Values : constant N.Real_Array := Next (Total);
         begin
            --  A quantized model keeps its matrices quantized and its norms
            --  in binary32; the fixture follows that, so the quantized path
            --  is exercised the way a real file exercises it.
            if Format = Q8_0 and then Total mod 32 = 0 then
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_Q8_0,
                  Fixtures.Encode_Q8_0 (Values));
            else
               Fixtures.Add_Tensor
                 (Builder, Name, Dimensions, G.Type_F32,
                  Fixtures.Encode_F32 (Values));
            end if;
         end;
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

      --  A one-dimensional tensor of a given width, for the biases.
      procedure Norm_Of (Name : String; Width : Positive) is
         Values : N.Real_Array (0 .. N.Element_Count (Width) - 1);
         Drawn  : constant N.Real_Array := Next (N.Element_Count (Width));
      begin
         for Index in Values'Range loop
            Values (Index) := Drawn (Index) * 0.125;
         end loop;
         Fixtures.Add_Tensor
           (Builder, Name, [G.U64 (Width)], G.Type_F32,
            Fixtures.Encode_F32 (Values));
      end Norm_Of;

      Prefix : constant String := (if Qwen then "qwen2" else "llama");

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Digit : constant String := [1 => Hex (Index + 1)];
      begin
         return "blk." & Digit & "." & Suffix;
      end Layer_Name;

   begin
      Fixtures.Reset (Builder);

      Fixtures.Add_String
        (Builder, "general.architecture", (if Qwen then "qwen2" else "llama"));
      Fixtures.Add_String (Builder, "general.name", "tiny");
      Fixtures.Add_U32
        (Builder, Prefix & ".context_length", Interfaces.Unsigned_32 (Room));
      Fixtures.Add_U32
        (Builder, Prefix & ".embedding_length", Interfaces.Unsigned_32 (Embedding));
      Fixtures.Add_U32 (Builder, Prefix & ".block_count", Layers);
      Fixtures.Add_U32
        (Builder, Prefix & ".feed_forward_length", Interfaces.Unsigned_32 (Feed_Forward));
      Fixtures.Add_U32 (Builder, Prefix & ".attention.head_count", Heads);
      Fixtures.Add_U32 (Builder, Prefix & ".attention.head_count_kv", KV_Heads);
      Fixtures.Add_F32
        (Builder, Prefix & ".attention.layer_norm_rms_epsilon", 1.0E-5);
      Fixtures.Add_U32
        (Builder, Prefix & ".rope.dimension_count", Interfaces.Unsigned_32 (Head_Size));
      Fixtures.Add_F32 (Builder, Prefix & ".rope.freq_base", 10_000.0);

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
      Fixtures.Add_U32
        (Builder, "tokenizer.ggml.eos_token_id",
         Interfaces.Unsigned_32 (End_Token));
      Fixtures.Add_Bool
        (Builder, "tokenizer.ggml.add_bos_token", Adds_Beginning);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);

      Weight ("token_embd.weight", [G.U64 (Embedding), Vocabulary]);

      for Index in 0 .. Layers - 1 loop
         Norm (Layer_Name (Index, "attn_norm.weight"));
         Weight (Layer_Name (Index, "attn_q.weight"), [G.U64 (Embedding), G.U64 (Embedding)]);
         Weight (Layer_Name (Index, "attn_k.weight"),
                 [G.U64 (Embedding), G.U64 (KV_Heads * Head_Size)]);
         Weight (Layer_Name (Index, "attn_v.weight"),
                 [G.U64 (Embedding), G.U64 (KV_Heads * Head_Size)]);
         --  Qwen2 carries a bias beside each projection; Llama has none.
         if Qwen and then not Omit_Biases then
            Norm_Of (Layer_Name (Index, "attn_q.bias"), Embedding);
            Norm_Of (Layer_Name (Index, "attn_k.bias"), KV_Heads * Head_Size);
            Norm_Of (Layer_Name (Index, "attn_v.bias"), KV_Heads * Head_Size);
         end if;

         Weight (Layer_Name (Index, "attn_output.weight"),
                 [G.U64 (Embedding), G.U64 (Embedding)]);
         Norm (Layer_Name (Index, "ffn_norm.weight"));
         Weight (Layer_Name (Index, "ffn_gate.weight"),
                 [G.U64 (Embedding), G.U64 (Feed_Forward)]);
         Weight (Layer_Name (Index, "ffn_up.weight"), [G.U64 (Embedding), G.U64 (Feed_Forward)]);
         Weight (Layer_Name (Index, "ffn_down.weight"),
                 [G.U64 (Feed_Forward), G.U64 (Embedding)]);
      end loop;

      Norm ("output_norm.weight");
      Weight ("output.weight", [G.U64 (Embedding), Vocabulary]);

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

   procedure Write
     (Path : String;
      Adds_Beginning : Boolean := True;
      Room : Positive := Context) is
      use Ada.Streams;
      Image  : Model_Runner.Bytes.Byte_Array_Access;
      Handle : Stream_IO.File_Type;
   begin
      Build (Image, Adds_Beginning => Adds_Beginning, Room => Room);

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
