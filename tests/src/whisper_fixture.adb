with Ada.Streams.Stream_IO;
with Interfaces;

with Model_Runner.GGUF;
with Model_Runner.Numerics;

with Fixtures;

package body Whisper_Fixture is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type N.Element_Count;
   use type N.Real;
   use type Interfaces.Unsigned_64;

   Width  : constant := 8;
   Feed   : constant := 16;
   Mels   : constant := 80;
   Audio  : constant := 1_500;
   Text   : constant := 16;
   Heads  : constant := 2;

   --  The vocabulary: bytes, then the special tokens, then the times.
   End_Of_Text   : constant := 256;
   Start         : constant := 257;
   First_Language : constant := 258;
   Translate     : constant := 260;
   Transcribe    : constant := 261;
   Start_Of_LM   : constant := 262;
   Start_Of_Prev : constant := 263;
   No_Speech     : constant := 264;
   No_Times      : constant := 265;
   First_Time    : constant := 266;
   --  One merge, of a space and a t, and its token.
   Merged        : constant := First_Time + 1_501;
   Vocabulary    : constant := Merged + 1;

   --  A byte's character in the byte-level alphabet, as UTF-8: printable
   --  bytes stand for themselves, the rest for 256 and on, in order.
   function Byte_Token (Value : Natural) return String is
      function Printable (V : Natural) return Boolean is
        (V in 33 .. 126 | 161 .. 172 | 174 .. 255);
      Code : Natural := Value;
   begin
      if not Printable (Value) then
         Code := 256;
         for V in 0 .. Value - 1 loop
            if not Printable (V) then
               Code := Code + 1;
            end if;
         end loop;
      end if;
      if Code < 128 then
         return [1 => Character'Val (Code)];
      elsif Code < 2_048 then
         return [Character'Val (16#C0# + Code / 64), Character'Val (16#80# + Code mod 64)];
      else
         return [Character'Val (16#E0# + Code / 4_096), Character'Val (16#80# + Code / 64 mod 64),
                 Character'Val (16#80# + Code mod 64)];
      end if;
   end Byte_Token;

   function Time_Token (Step : Natural) return String is
      Hundredths : constant Natural := Step * 2;
      Whole : constant String := Natural'Image (Hundredths / 100);
      Part  : constant String := Natural'Image (100 + Hundredths mod 100);
   begin
      return "<|" & Whole (Whole'First + 1 .. Whole'Last) & "." & Part (Part'First + 2 .. Part'Last) & "|>";
   end Time_Token;

   function Token (Id : Natural) return String is
     (case Id is
         when 0 .. 255       => Byte_Token (Id),
         when End_Of_Text    => "<|endoftext|>",
         when Start          => "<|startoftranscript|>",
         when First_Language => "<|en|>",
         when First_Language + 1 => "<|da|>",
         when Translate      => "<|translate|>",
         when Transcribe     => "<|transcribe|>",
         when Start_Of_LM    => "<|startoflm|>",
         when Start_Of_Prev  => "<|startofprev|>",
         when No_Speech      => "<|nospeech|>",
         when No_Times       => "<|notimestamps|>",
         when Merged         => Byte_Token (32) & "t",
         when others         => Time_Token (Id - First_Time));

   --  A fixed sequence of small values, different for every tensor.
   function Values (Count : N.Element_Count; Seed : Natural; Around : N.Real := 0.0) return N.Real_Array is
      Result : N.Real_Array (0 .. Count - 1);
   begin
      for I in Result'Range loop
         Result (I) := Around + N.Real (Long_Float ((Natural (I mod 9_973) * 37 + Seed * 101) mod 211) / 211.0 - 0.5)
           * 0.2;
      end loop;
      return Result;
   end Values;

   procedure Build (Result : out B.Byte_Array_Access; Defect : Flaw := None) is
      Item : Fixtures.Builder;
      Seed : Natural := 0;

      procedure Tensor (Name : String; Dims : Fixtures.Dimension_List; Around : N.Real := 0.0) is
         Count : N.Element_Count := 1;
      begin
         if Defect = Missing_Tensor and then Name = "dec.blk.0.cross_attn_k.weight" then
            return;
         end if;
         for D of Dims loop
            Count := Count * N.Element_Count (D);
         end loop;
         Seed := Seed + 1;
         if Defect = Misshapen_Tensor and then Name = "enc.blk.0.ffn_up.weight" then
            Fixtures.Add_Tensor (Item, Name, [Width, Feed + 1], G.Type_F32,
                                 Fixtures.Encode_F32 (Values (Width * (Feed + 1), Seed)));
            return;
         end if;
         Fixtures.Add_Tensor (Item, Name, Dims, G.Type_F32, Fixtures.Encode_F32 (Values (Count, Seed, Around)));
      end Tensor;

      procedure Norm (Name : String) is
      begin
         Tensor (Name & ".weight", [Width], Around => 1.0);
         Tensor (Name & ".bias", [Width]);
      end Norm;

      procedure Attention (Name : String) is
      begin
         Tensor (Name & "_q.weight", [Width, Width]);
         Tensor (Name & "_q.bias", [Width]);
         Tensor (Name & "_k.weight", [Width, Width]);
         Tensor (Name & "_v.weight", [Width, Width]);
         Tensor (Name & "_v.bias", [Width]);
         Tensor (Name & "_out.weight", [Width, Width]);
         Tensor (Name & "_out.bias", [Width]);
      end Attention;

      procedure Feed_Forward (Name : String) is
      begin
         Tensor (Name & ".ffn_up.weight", [Width, Feed]);
         Tensor (Name & ".ffn_up.bias", [Feed]);
         Tensor (Name & ".ffn_down.weight", [Feed, Width]);
         Tensor (Name & ".ffn_down.bias", [Width]);
      end Feed_Forward;

      procedure Count_Key (Key : String; Value : Natural) is
      begin
         Fixtures.Add_U32 (Item, Key, Interfaces.Unsigned_32 (Value));
      end Count_Key;

      procedure Token_Key (Key : String; Value : Natural) is
      begin
         Fixtures.Add_I32 (Item, Key, Interfaces.Integer_32 (Value));
      end Token_Key;
   begin
      Fixtures.Reset (Item);
      Fixtures.Add_String (Item, "general.architecture", (if Defect = Other_Architecture then "llama" else "whisper"));
      Fixtures.Add_String (Item, "general.name", "fixture");
      Count_Key ("whisper.profile.version", (if Defect = Other_Profile then 2 else 1));
      Count_Key ("whisper.encoder.context_length", Audio);
      Count_Key ("whisper.encoder.embedding_length", Width);
      Count_Key ("whisper.encoder.feed_forward_length", Feed);
      Count_Key ("whisper.encoder.attention.head_count", Heads);
      Count_Key ("whisper.encoder.block_count", (if Defect = Too_Many_Blocks then 65 else 1));
      Count_Key ("whisper.decoder.context_length", Text);
      Count_Key ("whisper.decoder.embedding_length", Width);
      Count_Key ("whisper.decoder.feed_forward_length", Feed);
      Count_Key ("whisper.decoder.attention.head_count", Heads);
      Count_Key ("whisper.decoder.block_count", 1);
      Fixtures.Add_F32 (Item, "whisper.attention.layer_norm_epsilon", 1.0E-5);
      Count_Key ("whisper.audio.mel_bins", Mels);
      Count_Key ("whisper.audio.sample_rate", 16_000);
      Count_Key ("whisper.audio.window_length", 400);
      Count_Key ("whisper.audio.hop_length", 160);
      Count_Key ("whisper.audio.chunk_length", 30);
      Count_Key ("whisper.vocabulary.size", Vocabulary);
      Fixtures.Add_Bool (Item, "whisper.multilingual", True);
      Token_Key ("whisper.token.end_of_text", End_Of_Text);
      Token_Key ("whisper.token.start_of_transcript", Start);
      Token_Key ("whisper.token.transcribe", Transcribe);
      Token_Key ("whisper.token.translate", Translate);
      Token_Key ("whisper.token.start_of_previous", Start_Of_Prev);
      Token_Key ("whisper.token.start_of_lm", Start_Of_LM);
      Token_Key ("whisper.token.no_timestamps", No_Times);
      Token_Key ("whisper.token.no_speech", (if Defect = Token_Past_Vocabulary then Vocabulary else No_Speech));
      Token_Key ("whisper.token.timestamp_begin", First_Time);
      Token_Key ("whisper.token.first_language", First_Language);
      Fixtures.Begin_Array (Item, "whisper.languages", G.Value_String, 2);
      Fixtures.String_Element (Item, "en");
      Fixtures.String_Element (Item, "da");
      Fixtures.End_Array (Item);
      Fixtures.Begin_Array (Item, "whisper.suppress_tokens", G.Value_Int32, 3);
      Fixtures.Int32_Element (Item, Start);
      Fixtures.Int32_Element (Item, Translate);
      Fixtures.Int32_Element (Item, Transcribe);
      Fixtures.End_Array (Item);
      Fixtures.Begin_Array (Item, "whisper.begin_suppress_tokens", G.Value_Int32, 2);
      Fixtures.Int32_Element (Item, 220);
      Fixtures.Int32_Element (Item, End_Of_Text);
      Fixtures.End_Array (Item);

      Fixtures.Add_String (Item, "tokenizer.ggml.model", "gpt2");
      Fixtures.Add_String (Item, "tokenizer.ggml.pre", "gpt-2");
      Fixtures.Begin_Array (Item, "tokenizer.ggml.tokens", G.Value_String, Vocabulary);
      for Id in 0 .. Vocabulary - 1 loop
         Fixtures.String_Element (Item, Token (Id));
      end loop;
      Fixtures.End_Array (Item);
      Fixtures.Begin_Array (Item, "tokenizer.ggml.token_type", G.Value_Int32, Vocabulary);
      for Id in 0 .. Vocabulary - 1 loop
         Fixtures.Int32_Element (Item, (if Id in 0 .. 255 | Merged then 1 else 3));
      end loop;
      Fixtures.End_Array (Item);
      Fixtures.Begin_Array (Item, "tokenizer.ggml.merges", G.Value_String, 1);
      Fixtures.String_Element (Item, Byte_Token (32) & " t");
      Fixtures.End_Array (Item);
      Count_Key ("tokenizer.ggml.bos_token_id", End_Of_Text);
      Count_Key ("tokenizer.ggml.eos_token_id", End_Of_Text);
      Fixtures.Add_Bool (Item, "tokenizer.ggml.add_bos_token", False);

      Tensor ("enc.conv1.weight", [3, Mels, Width]);
      Tensor ("enc.conv1.bias", [Width]);
      Tensor ("enc.conv2.weight", [3, Width, Width]);
      Tensor ("enc.conv2.bias", [Width]);
      Tensor ("enc.position_embd.weight", [Width, Audio]);
      Norm ("enc.blk.0.attn_norm");
      Attention ("enc.blk.0.attn");
      Norm ("enc.blk.0.ffn_norm");
      Feed_Forward ("enc.blk.0");
      Norm ("enc.output_norm");
      Tensor ("dec.token_embd.weight", [Width, Vocabulary]);
      Tensor ("dec.position_embd.weight", [Width, Text]);
      Norm ("dec.blk.0.attn_norm");
      Attention ("dec.blk.0.attn");
      Norm ("dec.blk.0.cross_attn_norm");
      Attention ("dec.blk.0.cross_attn");
      Norm ("dec.blk.0.ffn_norm");
      Feed_Forward ("dec.blk.0");
      Norm ("dec.output_norm");
      Fixtures.Build (Item, Result);
   end Build;

   procedure Write (Path : String; Defect : Flaw := None) is
      use Ada.Streams.Stream_IO;
      File : File_Type;
      Data : B.Byte_Array_Access;
   begin
      Build (Data, Defect);
      Create (File, Out_File, Path, Form => "shared=no");
      B.Byte_Array'Write (Stream (File), Data.all);
      Close (File);
      B.Free (Data);
   end Write;

end Whisper_Fixture;
