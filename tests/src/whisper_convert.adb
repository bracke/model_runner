with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces;

with CryptoLib.Hashes;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Heap_Buffers;
with Model_Runner.Numerics;
with Model_Runner.Safetensors;
with Model_Runner.Tensors;

with Fixtures;
with Quantizer;

package body Whisper_Convert is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package J renames Jsonlib.Documents;
   package N renames Model_Runner.Numerics;
   package ST renames Model_Runner.Safetensors;
   package T renames Model_Runner.Tensors;

   use Ada.Strings.Unbounded;
   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type J.Value_Kind;
   use type G.U64;
   use type G.Tensor_Type;
   use type N.Element_Count;
   use type N.Half;
   use type Interfaces.Unsigned_32;
   use type T.Real_Array_Access;

   --  This tool's version, written into the manifest: a change to what it
   --  writes changes it.
   Tool_Version : constant String := "whisper-convert 1";

   --  The profile written; Model_Runner.Whisper reads this one.
   Profile : constant := 1;

   Refused : exception;

   function Bits_Of is new Ada.Unchecked_Conversion (Interfaces.IEEE_Float_32, Interfaces.Unsigned_32);

   procedure Say (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("whisper-convert: " & Text);
      Ada.Text_IO.Flush;
   end Say;

   function Whole_File (Path : String) return String is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Open (File, In_File, Path, Form => "shared=no");
      declare
         Text : String (1 .. Natural (Size (File)));
      begin
         String'Read (Stream (File), Text);
         Close (File);
         return Text;
      end;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Say ("cannot read " & Path);
         raise Refused;
   end Whole_File;

   procedure Parse (Path : String; Into : in out J.Document) is
      Error : Jsonlib.Errors.Error_Info;
   begin
      Jsonlib.Parsers.Parse (Whole_File (Path), Into, Error);
      if Jsonlib.Errors.Failed (Error) then
         Say (Path & " is not JSON");
         raise Refused;
      end if;
   end Parse;

   function Integer_Of (Doc : J.Document; Named : String) return Long_Long_Integer is
      Item : constant J.Node := J.Member (Doc, J.Root (Doc), Named);
   begin
      if not J.Is_Present (Item) or else J.Kind (Doc, Item) /= J.Integer_Value then
         Say ("config.json has no number " & Named);
         raise Refused;
      end if;
      return J.As_Integer (Doc, Item);
   end Integer_Of;

   --  The SHA-256 of a file, in lower-case hexadecimal.
   function Digest_Of (Path : String) return String is
      use Ada.Streams;
      package IO renames Ada.Streams.Stream_IO;
      Context : CryptoLib.Hashes.SHA256_Context;
      File    : IO.File_Type;
      Room    : Model_Runner.Heap_Buffers.Bytes (4 * 1024 * 1024);
      Buffer  : Stream_Element_Array renames Room.Data.all;
      Last    : Stream_Element_Offset;
      Digest  : CryptoLib.Hashes.SHA256_Digest;
      Hex     : constant String := "0123456789abcdef";
      Seen    : String (1 .. 64);
   begin
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      IO.Open (File, IO.In_File, Path, Form => "shared=no");
      while not IO.End_Of_File (File) loop
         IO.Read (File, Buffer, Last);
         CryptoLib.Hashes.Update (Context, Buffer (1 .. Last));
      end loop;
      IO.Close (File);
      Digest := CryptoLib.Hashes.Finalize (Context);
      for I in Digest'Range loop
         Seen (2 * I - 1) := Hex (Natural (Digest (I)) / 16 + 1);
         Seen (2 * I) := Hex (Natural (Digest (I)) mod 16 + 1);
      end loop;
      return Seen;
   end Digest_Of;

   --  One tensor the profile names: the checkpoint's name, the file's, its
   --  shape as the checkpoint writes it (outermost first), and whether it
   --  is a matrix, which binary16 may take.
   type Shape is array (1 .. 3) of N.Element_Count;

   type Planned is record
      From, To : Unbounded_String;
      Dims     : Shape := [others => 1];
      Rank     : Positive := 1;
      Matrix   : Boolean := False;
   end record;

   package Plan_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, Planned);

   --  Bytes Count elements take in a format the converter writes.
   function Bytes_Of (Format : G.Tensor_Type; Count : N.Element_Count) return B.Byte_Count is
     (case Format is
         when G.Type_F16  => 2 * B.Byte_Count (Count),
         when G.Type_Q8_0 => 34 * B.Byte_Count (Count / 32),
         when others      => 4 * B.Byte_Count (Count));

   function Image (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   ---------
   -- Run --
   ---------

   function Run (From, Into : String; Matrices : Model_Runner.GGUF.Tensor_Type) return Natural is
      Config, Generation, Vocab, Added : J.Document;
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Table  : ST.Table;
      Status : E.Error_Info;
      Build  : Fixtures.Builder;
      Plan   : Plan_Vectors.Vector;
   begin
      Parse (From & "/config.json", Config);
      Parse (From & "/generation_config.json", Generation);
      Parse (From & "/vocab.json", Vocab);
      Parse (From & "/added_tokens.json", Added);

      declare
         Width     : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "d_model"));
         Mels      : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "num_mel_bins"));
         Vocab_Size : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "vocab_size"));
         Audio_Ctx : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "max_source_positions"));
         Text_Ctx  : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "max_target_positions"));
         Enc_Layers : constant Natural := Natural (Integer_Of (Config, "encoder_layers"));
         Dec_Layers : constant Natural := Natural (Integer_Of (Config, "decoder_layers"));
         Enc_Heads : constant Natural := Natural (Integer_Of (Config, "encoder_attention_heads"));
         Dec_Heads : constant Natural := Natural (Integer_Of (Config, "decoder_attention_heads"));
         Enc_Feed  : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "encoder_ffn_dim"));
         Dec_Feed  : constant N.Element_Count := N.Element_Count (Integer_Of (Config, "decoder_ffn_dim"));
         Tokens    : array (0 .. Vocab_Size - 1) of Unbounded_String;
         Special   : array (0 .. Vocab_Size - 1) of Boolean := [others => False];
         --  Whether an identifier is named; a token's text may be empty --
         --  vocab.json names 50256 so -- so its text cannot say.
         Named     : array (0 .. Vocab_Size - 1) of Boolean := [others => False];

         function Id_Of (Text : String) return Long_Long_Integer is
         begin
            for I in Tokens'Range loop
               if Tokens (I) = Text then
                  return Long_Long_Integer (I);
               end if;
            end loop;
            Say ("the vocabulary has no " & Text);
            raise Refused;
         end Id_Of;

         procedure Add (From_Name, To_Name : String; Dims : Shape; Rank : Positive; Matrix : Boolean := False) is
         begin
            Plan.Append (Planned'(To_Unbounded_String (From_Name), To_Unbounded_String (To_Name), Dims, Rank, Matrix));
         end Add;

         procedure Add_Vector (From_Name, To_Name : String; Length : N.Element_Count) is
         begin
            Add (From_Name, To_Name, [Length, 1, 1], 1);
         end Add_Vector;

         procedure Add_Norm (From_Name, To_Name : String) is
         begin
            Add_Vector (From_Name & ".weight", To_Name & ".weight", Width);
            Add_Vector (From_Name & ".bias", To_Name & ".bias", Width);
         end Add_Norm;

         procedure Add_Attention (From_Name, To_Name : String) is
         begin
            Add (From_Name & ".q_proj.weight", To_Name & "_q.weight", [Width, Width, 1], 2, True);
            Add_Vector (From_Name & ".q_proj.bias", To_Name & "_q.bias", Width);
            Add (From_Name & ".k_proj.weight", To_Name & "_k.weight", [Width, Width, 1], 2, True);
            Add (From_Name & ".v_proj.weight", To_Name & "_v.weight", [Width, Width, 1], 2, True);
            Add_Vector (From_Name & ".v_proj.bias", To_Name & "_v.bias", Width);
            Add (From_Name & ".out_proj.weight", To_Name & "_out.weight", [Width, Width, 1], 2, True);
            Add_Vector (From_Name & ".out_proj.bias", To_Name & "_out.bias", Width);
         end Add_Attention;

         procedure Add_Feed (From_Name, To_Name : String; Feed : N.Element_Count) is
         begin
            Add (From_Name & ".fc1.weight", To_Name & ".ffn_up.weight", [Feed, Width, 1], 2, True);
            Add_Vector (From_Name & ".fc1.bias", To_Name & ".ffn_up.bias", Feed);
            Add (From_Name & ".fc2.weight", To_Name & ".ffn_down.weight", [Width, Feed, 1], 2, True);
            Add_Vector (From_Name & ".fc2.bias", To_Name & ".ffn_down.bias", Width);
         end Add_Feed;

         procedure Take_Tokens (Doc : J.Document; Is_Added : Boolean) is
            Root : constant J.Node := J.Root (Doc);
         begin
            for I in 1 .. J.Length (Doc, Root) loop
               declare
                  Id : constant Long_Long_Integer := J.As_Integer (Doc, J.Element (Doc, Root, I));
               begin
                  if Id < 0 or else Id >= Long_Long_Integer (Vocab_Size) then
                     Say ("token " & J.Name (Doc, Root, I) & " has identifier " & Image (Id)
                          & ", past the vocabulary of " & Image (Long_Long_Integer (Vocab_Size)));
                     raise Refused;
                  end if;
                  if Named (N.Element_Count (Id))
                    and then Tokens (N.Element_Count (Id)) /= J.Name (Doc, Root, I)
                  then
                     Say ("identifier " & Image (Id) & " is two tokens");
                     raise Refused;
                  end if;
                  Tokens (N.Element_Count (Id)) := To_Unbounded_String (J.Name (Doc, Root, I));
                  Special (N.Element_Count (Id)) := Is_Added;
                  Named (N.Element_Count (Id)) := True;
               end;
            end loop;
         end Take_Tokens;
      begin
         if Width < 1 or else Mels < 1 or else Vocab_Size < 1 or else Audio_Ctx < 1 or else Text_Ctx < 1
           or else Enc_Layers < 1 or else Dec_Layers < 1 or else Enc_Heads < 1 or else Dec_Heads < 1
           or else Width mod N.Element_Count (Enc_Heads) /= 0 or else Width mod N.Element_Count (Dec_Heads) /= 0
         then
            Say ("config.json states a shape that is no model's");
            raise Refused;
         end if;

         --  The vocabulary: vocab.json and added_tokens.json together are
         --  every identifier, once.
         Take_Tokens (Vocab, Is_Added => False);
         Take_Tokens (Added, Is_Added => True);
         for I in Tokens'Range loop
            if not Named (I) then
               Say ("identifier " & Image (Long_Long_Integer (I)) & " is no token");
               raise Refused;
            end if;
         end loop;

         Fixtures.Reset (Build);
         Fixtures.Add_String (Build, "general.architecture", "whisper");
         Fixtures.Add_String (Build, "general.name", Ada.Directories.Simple_Name (From));
         Fixtures.Add_U32 (Build, "whisper.profile.version", Profile);
         Fixtures.Add_U32 (Build, "whisper.encoder.context_length", Interfaces.Unsigned_32 (Audio_Ctx));
         Fixtures.Add_U32 (Build, "whisper.encoder.embedding_length", Interfaces.Unsigned_32 (Width));
         Fixtures.Add_U32 (Build, "whisper.encoder.feed_forward_length", Interfaces.Unsigned_32 (Enc_Feed));
         Fixtures.Add_U32 (Build, "whisper.encoder.attention.head_count", Interfaces.Unsigned_32 (Enc_Heads));
         Fixtures.Add_U32 (Build, "whisper.encoder.block_count", Interfaces.Unsigned_32 (Enc_Layers));
         Fixtures.Add_U32 (Build, "whisper.decoder.context_length", Interfaces.Unsigned_32 (Text_Ctx));
         Fixtures.Add_U32 (Build, "whisper.decoder.embedding_length", Interfaces.Unsigned_32 (Width));
         Fixtures.Add_U32 (Build, "whisper.decoder.feed_forward_length", Interfaces.Unsigned_32 (Dec_Feed));
         Fixtures.Add_U32 (Build, "whisper.decoder.attention.head_count", Interfaces.Unsigned_32 (Dec_Heads));
         Fixtures.Add_U32 (Build, "whisper.decoder.block_count", Interfaces.Unsigned_32 (Dec_Layers));
         Fixtures.Add_F32 (Build, "whisper.attention.layer_norm_epsilon", 1.0E-5);
         Fixtures.Add_U32 (Build, "whisper.audio.mel_bins", Interfaces.Unsigned_32 (Mels));
         Fixtures.Add_U32 (Build, "whisper.audio.sample_rate", 16_000);
         Fixtures.Add_U32 (Build, "whisper.audio.window_length", 400);
         Fixtures.Add_U32 (Build, "whisper.audio.hop_length", 160);
         Fixtures.Add_U32 (Build, "whisper.audio.chunk_length", 30);
         Fixtures.Add_U32 (Build, "whisper.vocabulary.size", Interfaces.Unsigned_32 (Vocab_Size));

         declare
            Multilingual : constant Boolean := J.Has_Member (Generation, J.Root (Generation), "lang_to_id");
            Root : constant J.Node := J.Root (Generation);
         begin
            Fixtures.Add_Bool (Build, "whisper.multilingual", Multilingual);
            Fixtures.Add_I32 (Build, "whisper.token.end_of_text", Interfaces.Integer_32 (Id_Of ("<|endoftext|>")));
            Fixtures.Add_I32 (Build, "whisper.token.start_of_transcript",
                              Interfaces.Integer_32 (Id_Of ("<|startoftranscript|>")));
            Fixtures.Add_I32 (Build, "whisper.token.transcribe", Interfaces.Integer_32 (Id_Of ("<|transcribe|>")));
            Fixtures.Add_I32 (Build, "whisper.token.translate", Interfaces.Integer_32 (Id_Of ("<|translate|>")));
            Fixtures.Add_I32 (Build, "whisper.token.start_of_previous",
                              Interfaces.Integer_32 (Id_Of ("<|startofprev|>")));
            Fixtures.Add_I32 (Build, "whisper.token.start_of_lm", Interfaces.Integer_32 (Id_Of ("<|startoflm|>")));
            Fixtures.Add_I32 (Build, "whisper.token.no_timestamps",
                              Interfaces.Integer_32 (Id_Of ("<|notimestamps|>")));
            --  "<|nospeech|>" in later vocabularies, "<|nocaptions|>" in
            --  the first.
            declare
               No_Speech : Long_Long_Integer := -1;
            begin
               for I in Tokens'Range loop
                  if Tokens (I) = "<|nospeech|>" or else Tokens (I) = "<|nocaptions|>" then
                     No_Speech := Long_Long_Integer (I);
                  end if;
               end loop;
               if No_Speech < 0 then
                  Say ("the vocabulary has no <|nospeech|>");
                  raise Refused;
               end if;
               Fixtures.Add_I32 (Build, "whisper.token.no_speech", Interfaces.Integer_32 (No_Speech));
            end;
            Fixtures.Add_I32 (Build, "whisper.token.timestamp_begin", Interfaces.Integer_32 (Id_Of ("<|0.00|>")));

            --  The languages, in the order of their tokens: the first's
            --  token and the codes.
            if Multilingual then
               declare
                  Langs : constant J.Node := J.Member (Generation, Root, "lang_to_id");
                  Count : constant Natural := J.Length (Generation, Langs);
                  First : Long_Long_Integer := Long_Long_Integer'Last;
               begin
                  for I in 1 .. Count loop
                     First := Long_Long_Integer'Min
                       (First, J.As_Integer (Generation, J.Element (Generation, Langs, I)));
                  end loop;
                  Fixtures.Add_I32 (Build, "whisper.token.first_language", Interfaces.Integer_32 (First));
                  Fixtures.Begin_Array (Build, "whisper.languages", G.Value_String, Count);
                  for Id in First .. First + Long_Long_Integer (Count) - 1 loop
                     declare
                        Text : constant String := To_String (Tokens (N.Element_Count (Id)));
                     begin
                        if Text'Length < 5 or else Text (Text'First .. Text'First + 1) /= "<|"
                          or else Text (Text'Last - 1 .. Text'Last) /= "|>"
                        then
                           Say ("token " & Image (Id) & " is no language: " & Text);
                           raise Refused;
                        end if;
                        Fixtures.String_Element (Build, Text (Text'First + 2 .. Text'Last - 2));
                     end;
                  end loop;
                  Fixtures.End_Array (Build);
               end;
            end if;

            declare
               procedure Take_List (Key : String) is
                  List : constant J.Node := J.Member (Generation, Root, Key);
               begin
                  if not J.Is_Present (List) then
                     Say ("generation_config.json has no " & Key);
                     raise Refused;
                  end if;
                  Fixtures.Begin_Array (Build, "whisper." & Key, G.Value_Int32, J.Length (Generation, List));
                  for I in 1 .. J.Length (Generation, List) loop
                     Fixtures.Int32_Element
                       (Build, Interfaces.Integer_32 (J.As_Integer (Generation, J.Element (Generation, List, I))));
                  end loop;
                  Fixtures.End_Array (Build);
               end Take_List;
            begin
               Take_List ("suppress_tokens");
               Take_List ("begin_suppress_tokens");
               --  The heads word timing reads, [block, head] pairs written
               --  flat, where the checkpoint names them.
               declare
                  Pairs : constant J.Node := J.Member (Generation, Root, "alignment_heads");
               begin
                  if J.Is_Present (Pairs) then
                     Fixtures.Begin_Array
                       (Build, "whisper.alignment_heads", G.Value_Int32, 2 * J.Length (Generation, Pairs));
                     for I in 1 .. J.Length (Generation, Pairs) loop
                        for K in 1 .. 2 loop
                           Fixtures.Int32_Element
                             (Build, Interfaces.Integer_32
                                (J.As_Integer (Generation, J.Element (Generation, J.Element (Generation, Pairs, I), K))));
                        end loop;
                     end loop;
                     Fixtures.End_Array (Build);
                  end if;
               end;
            end;
         end;

         Fixtures.Add_String (Build, "tokenizer.ggml.model", "gpt2");
         Fixtures.Add_String (Build, "tokenizer.ggml.pre", "gpt-2");
         Fixtures.Begin_Array (Build, "tokenizer.ggml.tokens", G.Value_String, Natural (Vocab_Size));
         for Token of Tokens loop
            Fixtures.String_Element (Build, To_String (Token));
         end loop;
         Fixtures.End_Array (Build);
         Fixtures.Begin_Array (Build, "tokenizer.ggml.token_type", G.Value_Int32, Natural (Vocab_Size));
         for Is_Special of Special loop
            Fixtures.Int32_Element (Build, (if Is_Special then 3 else 1));
         end loop;
         Fixtures.End_Array (Build);
         declare
            Text  : constant String := Whole_File (From & "/merges.txt");
            Lines : Plan_Vectors.Vector;
            Start : Positive := Text'First;
            pragma Unreferenced (Lines);
            package String_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, String);
            Merges : String_Vectors.Vector;
         begin
            for I in Text'Range loop
               if Text (I) = ASCII.LF or else I = Text'Last then
                  declare
                     Line : constant String := Text (Start .. (if Text (I) = ASCII.LF then I - 1 else I));
                  begin
                     if Line'Length > 0 and then Line (Line'First) /= '#' then
                        Merges.Append (Line);
                     end if;
                  end;
                  Start := I + 1;
               end if;
            end loop;
            Fixtures.Begin_Array (Build, "tokenizer.ggml.merges", G.Value_String, Natural (Merges.Length));
            for Merge of Merges loop
               Fixtures.String_Element (Build, Merge);
            end loop;
            Fixtures.End_Array (Build);
         end;
         Fixtures.Add_U32 (Build, "tokenizer.ggml.bos_token_id", Interfaces.Unsigned_32 (Id_Of ("<|endoftext|>")));
         Fixtures.Add_U32 (Build, "tokenizer.ggml.eos_token_id", Interfaces.Unsigned_32 (Id_Of ("<|endoftext|>")));
         Fixtures.Add_Bool (Build, "tokenizer.ggml.add_bos_token", False);

         --  The tensors, in the profile's order.
         Add ("model.encoder.conv1.weight", "enc.conv1.weight", [Width, Mels, 3], 3);
         Add_Vector ("model.encoder.conv1.bias", "enc.conv1.bias", Width);
         Add ("model.encoder.conv2.weight", "enc.conv2.weight", [Width, Width, 3], 3);
         Add_Vector ("model.encoder.conv2.bias", "enc.conv2.bias", Width);
         Add ("model.encoder.embed_positions.weight", "enc.position_embd.weight", [Audio_Ctx, Width, 1], 2);
         for L in 0 .. Enc_Layers - 1 loop
            declare
               F  : constant String := "model.encoder.layers." & Image (Long_Long_Integer (L));
               To : constant String := "enc.blk." & Image (Long_Long_Integer (L));
            begin
               Add_Norm (F & ".self_attn_layer_norm", To & ".attn_norm");
               Add_Attention (F & ".self_attn", To & ".attn");
               Add_Norm (F & ".final_layer_norm", To & ".ffn_norm");
               Add_Feed (F, To, Enc_Feed);
            end;
         end loop;
         Add_Norm ("model.encoder.layer_norm", "enc.output_norm");
         Add ("model.decoder.embed_tokens.weight", "dec.token_embd.weight", [Vocab_Size, Width, 1], 2, True);
         Add ("model.decoder.embed_positions.weight", "dec.position_embd.weight", [Text_Ctx, Width, 1], 2);
         for L in 0 .. Dec_Layers - 1 loop
            declare
               F  : constant String := "model.decoder.layers." & Image (Long_Long_Integer (L));
               To : constant String := "dec.blk." & Image (Long_Long_Integer (L));
            begin
               Add_Norm (F & ".self_attn_layer_norm", To & ".attn_norm");
               Add_Attention (F & ".self_attn", To & ".attn");
               Add_Norm (F & ".encoder_attn_layer_norm", To & ".cross_attn_norm");
               Add_Attention (F & ".encoder_attn", To & ".cross_attn");
               Add_Norm (F & ".final_layer_norm", To & ".ffn_norm");
               Add_Feed (F, To, Dec_Feed);
            end;
         end loop;
         Add_Norm ("model.decoder.layer_norm", "dec.output_norm");
      end;

      Model_Runner.Byte_Sources.Files.Open (Source, From & "/model.safetensors", Status => Status);
      if E.Is_Error (Status) then
         Say ("cannot open " & From & "/model.safetensors");
         raise Refused;
      end if;
      ST.Read (Table, Source, Status);
      if E.Is_Error (Status) then
         Say ("model.safetensors has no table this reads: " & Status.Code'Image);
         raise Refused;
      end if;

      --  Every tensor there, of its shape, before anything is written.
      for P of Plan loop
         declare
            Index : constant Natural := ST.Find (Table, To_String (P.From));
         begin
            if Index = 0 then
               Say ("model.safetensors has no " & To_String (P.From));
               raise Refused;
            end if;
            declare
               Info : constant ST.Tensor_Info := ST.Info (Table, Index);
               Same : Boolean := Info.Rank = P.Rank;
            begin
               for D in 1 .. P.Rank loop
                  Same := Same and then Info.Shape (D) = G.U64 (P.Dims (D));
               end loop;
               if not Same then
                  Say (To_String (P.From) & " is not of the shape config.json gives it");
                  raise Refused;
               end if;
            end;
         end;
      end loop;
      for I in 1 .. ST.Count (Table) loop
         if ST.Name (Table, I) /= "proj_out.weight"
           and then not (for some P of Plan => To_String (P.From) = ST.Name (Table, I))
         then
            Say ("model.safetensors holds " & ST.Name (Table, I) & ", which the profile does not name");
            raise Refused;
         end if;
      end loop;

      --  The head, then each tensor converted and padded, in order.
      for P of Plan loop
         declare
            Elements : N.Element_Count := 1;
            Dims     : Fixtures.Dimension_List (1 .. P.Rank);
            Format   : constant G.Tensor_Type := (if P.Matrix then Matrices else G.Type_F32);
         begin
            for D in 1 .. P.Rank loop
               Elements := Elements * P.Dims (D);
               Dims (D) := G.U64 (P.Dims (P.Rank + 1 - D));
            end loop;
            if Format = G.Type_Q8_0 and then P.Dims (P.Rank) mod 32 /= 0 then
               Say (To_String (P.From) & "'s rows are not whole blocks of 32");
               raise Refused;
            end if;
            Fixtures.Plan_Tensor (Build, To_String (P.To), Dims, Format, Bytes_Of (Format, Elements));
         end;
      end loop;

      declare
         use Ada.Streams.Stream_IO;
         Output : File_Type;
         Head   : B.Byte_Array_Access;

         procedure Put (Data : B.Byte_Array) is
            Buffer : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Data'Length))
              with Import, Address => Data'Address;
         begin
            Write (Output, Buffer);
         end Put;
      begin
         Fixtures.Build_Head (Build, Head);
         Create (Output, Out_File, Into, Form => "shared=no");
         Put (Head.all);
         B.Free (Head);
         for P of Plan loop
            declare
               Info   : constant ST.Tensor_Info := ST.Info (Table, ST.Find (Table, To_String (P.From)));
               Last_D : constant N.Element_Count := N.Element_Count (Info.Shape (Info.Rank));
               Rows   : constant N.Element_Count := N.Element_Count (Info.Elements) / Last_D;
               Raw    : B.Byte_Array_Access;
               View   : T.View;
               Values : T.Real_Array_Access;
            begin
               B.Allocate (Info.Data_Length, Raw);
               T.Allocate (N.Element_Count (Info.Elements), Values);
               if Raw = null or else Values = null then
                  Say ("no memory for " & To_String (P.From));
                  raise Refused;
               end if;
               Source.Read (Info.Data_Offset, Raw.all, Status);
               if E.Is_Ok (Status) then
                  T.Make (Info.Element, Rows, Last_D, Raw, 0, View, Status);
               end if;
               for R in 0 .. Rows - 1 loop
                  exit when E.Is_Error (Status);
                  T.Dequantize_Row (View, R, Values (R * Last_D .. (R + 1) * Last_D - 1), Status);
               end loop;
               if E.Is_Error (Status) then
                  Say ("cannot read " & To_String (P.From) & ": " & Status.Code'Image);
                  raise Refused;
               end if;
               --  Written from the heap, a row at a time: the token table
               --  is a hundred and fifty megabytes.
               declare
                  Format  : constant G.Tensor_Type := (if P.Matrix then Matrices else G.Type_F32);
                  Width   : constant B.Byte_Count := (if Format = G.Type_F16 then 2 else 4);
                  Length  : constant B.Byte_Count := Bytes_Of (Format, N.Element_Count (Info.Elements));
                  Encoded : B.Byte_Array_Access;
                  Zeros   : constant B.Byte_Array (1 .. Fixtures.Padding_After (Build, Length)) :=
                    [others => 0];
               begin
                  B.Allocate (Length, Encoded);
                  if Encoded = null then
                     Say ("no memory for " & To_String (P.From));
                     raise Refused;
                  end if;
                  if Format = G.Type_Q8_0 then
                     --  A row at a time, as ggml's quantize_row_q8_0 does it.
                     declare
                        Row_Bytes : constant B.Byte_Count := Bytes_Of (Format, Last_D);
                     begin
                        for R in 0 .. Rows - 1 loop
                           Encoded (Encoded'First + B.Byte_Count (R) * Row_Bytes
                                    .. Encoded'First + B.Byte_Count (R + 1) * Row_Bytes - 1) :=
                             Quantizer.Encode (Values (R * Last_D .. (R + 1) * Last_D - 1), Quantizer.Q8_0);
                        end loop;
                     end;
                  end if;
                  for I in (if Format = G.Type_Q8_0 then 1 else 0) .. (if Format = G.Type_Q8_0 then 0
                                                                       else Values.all'Last) loop
                     declare
                        At_Byte : constant B.Byte_Count := Encoded'First + B.Byte_Count (I) * Width;
                     begin
                        if Width = 2 then
                           declare
                              Bits : constant N.Half := N.To_Half (Values (I));
                           begin
                              Encoded (At_Byte) := B.Byte (Bits mod 256);
                              Encoded (At_Byte + 1) := B.Byte (Bits / 256);
                           end;
                        else
                           declare
                              Bits : constant Interfaces.Unsigned_32 := Bits_Of (Interfaces.IEEE_Float_32 (Values (I)));
                           begin
                              for K in 0 .. 3 loop
                                 Encoded (At_Byte + B.Byte_Count (K)) :=
                                   B.Byte (Interfaces.Shift_Right (Bits, 8 * K) and 255);
                              end loop;
                           end;
                        end if;
                     end;
                  end loop;
                  Put (Encoded.all);
                  Put (Zeros);
                  B.Free (Encoded);
               end;
               B.Free (Raw);
               T.Free (Values);
            end;
         end loop;
         Close (Output);
      end;
      Model_Runner.Byte_Sources.Files.Close (Source);

      --  Read back as a container, every tensor where it was planned.
      declare
         Check : Model_Runner.Byte_Sources.Files.File_Source;
         Made  : Model_Runner.GGUF.Containers.Container;
      begin
         Model_Runner.Byte_Sources.Files.Open (Check, Into, Status => Status);
         if E.Is_Ok (Status) then
            Model_Runner.GGUF.Containers.Reader.Parse (Made, Check, Status => Status);
         end if;
         if E.Is_Error (Status) then
            Say (Into & " does not read back as a container: " & Status.Code'Image);
            raise Refused;
         end if;
         if Model_Runner.GGUF.Containers.Tensor_Count (Made) /= Natural (Plan.Length) then
            Say (Into & " reads back with another tensor count");
            raise Refused;
         end if;
         Model_Runner.Byte_Sources.Files.Close (Check);
      end;

      declare
         Manifest : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (Manifest, Ada.Text_IO.Out_File, Into & ".manifest");
         Ada.Text_IO.Put_Line (Manifest, "profile " & Image (Profile));
         Ada.Text_IO.Put_Line (Manifest, "tool " & Tool_Version);
         Ada.Text_IO.Put_Line (Manifest, "matrices " & G.Type_Name (Matrices));
         Ada.Text_IO.Put_Line (Manifest, "source " & Digest_Of (From & "/model.safetensors") & " model.safetensors");
         Ada.Text_IO.Put_Line (Manifest, "output " & Digest_Of (Into) & " "
                               & Ada.Directories.Simple_Name (Into));
         Ada.Text_IO.Close (Manifest);
      end;
      Say ("wrote " & Into & ", " & Image (Long_Long_Integer (Plan.Length)) & " tensors");
      return 0;
   exception
      when Refused =>
         if Model_Runner.Byte_Sources.Files.Is_Open (Source) then
            Model_Runner.Byte_Sources.Files.Close (Source);
         end if;
         return 1;
   end Run;

end Whisper_Convert;
