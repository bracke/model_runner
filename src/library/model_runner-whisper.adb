with Ada.Calendar;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

with Model_Runner.Audio.Spectrograms;
with Model_Runner.Backend.Device;
with Model_Runner.Platform.Device.Products;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Kernels;
with Model_Runner.Shares;
with Model_Runner.Whisper.Decoding;
with Model_Runner.Whisper.Timing;
with Model_Runner.UTF8;

package body Model_Runner.Whisper is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package K renames Model_Runner.Kernels;
   package N renames Model_Runner.Numerics;
   package CPU renames Model_Runner.Backend.CPU;
   package FP renames Model_Runner.Float_Panels;
   package Tk renames Model_Runner.Tokenizer;
   package Containers renames Model_Runner.GGUF.Containers;
   package Spectrograms renames Model_Runner.Audio.Spectrograms;

   subtype Wide_Real is N.Wide_Real;
   subtype Token_Id is Tk.Token_Id;

   package Elementary is new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   use Ada.Strings.Unbounded;
   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type Wide_Real;
   use type Token_Id;
   use type T.Real_Array_Access;
   use type T.Group_Room_Access;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;
   use type Model_Runner.Cancellation.Token_Reference;

   procedure Free is new Ada.Unchecked_Deallocation (Block_Array, Block_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Panel_Array, Panel_Array_Access);

   Architecture : constant String := "whisper";

   --  The decoder's attention reads at most this many keys: the encoder's
   --  positions, which are more than the text context.
   Audio_Positions_Count : constant Element_Count := Window_Frames / 2;

   --  Seconds a time token steps, and frames an encoder position spans.
   Time_Precision : constant Real := 0.02;
   Input_Stride   : constant Element_Count := 2;

   function Image (Value : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Value), Ada.Strings.Both));

   -------------
   -- Binding --
   -------------

   --  A view over a named tensor of the given rows and columns, where it
   --  lies: the leading axes that multiply to Columns are a row.
   procedure Bind
     (Item    : in out Model;
      Name    : String;
      Rows    : Element_Count;
      Columns : Element_Count;
      Result  : out T.View;
      Status  : out E.Error_Info)
   is
      Index : constant Natural := Containers.Find_Tensor (Item.Container, Name);
   begin
      Result := T.Empty_View;
      Status := E.Success;
      if Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;
      if not Containers.Tensor_Is_Supported (Item.Container, Index) then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text (Status, "format",
                     Model_Runner.GGUF.Type_Name (Containers.Tensor_Format (Item.Container, Index)),
                     E.Param_Identifier);
         return;
      end if;
      declare
         Rank : constant Positive := Containers.Tensor_Rank (Item.Container, Index);
         Contiguous : Element_Count := 1;
         Remaining  : Element_Count := 1;
         Axis : Positive := 1;
      begin
         while Axis <= Rank and then Contiguous < Columns loop
            Contiguous := Contiguous * Element_Count (Containers.Tensor_Dimension (Item.Container, Index, Axis));
            Axis := Axis + 1;
         end loop;
         while Axis <= Rank loop
            Remaining := Remaining * Element_Count (Containers.Tensor_Dimension (Item.Container, Index, Axis));
            Axis := Axis + 1;
         end loop;
         if Contiguous /= Columns or else Remaining /= Rows then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Contiguous));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Remaining));
            E.Add_Integer (Status, "expected_columns", Long_Long_Integer (Columns));
            E.Add_Integer (Status, "expected_rows", Long_Long_Integer (Rows));
            return;
         end if;
      end;
      T.Make
        (Format  => Containers.Tensor_Format (Item.Container, Index),
         Rows    => Rows,
         Columns => Columns,
         Base    => Item.Base,
         Span    => Item.Span,
         Offset  => B.Byte_Count (Containers.Tensor_Offset (Item.Container, Index))
                    - B.Byte_Count (Containers.Data_Offset (Item.Container)),
         Result  => Result,
         Status  => Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
      end if;
   end Bind;

   --  A table of the given length, decoded once to binary32.
   procedure Bind_Values
     (Item   : in out Model;
      Name   : String;
      Rows   : Element_Count;
      Width  : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      View : T.View;
   begin
      Result := null;
      Bind (Item, Name, Rows, Width, View, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      T.Allocate (Rows * Width, Result);
      if Result = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      for R in 0 .. Rows - 1 loop
         T.Dequantize_Row (View, R, Result (R * Width .. (R + 1) * Width - 1), Status);
         exit when E.Is_Error (Status);
      end loop;
   end Bind_Values;

   procedure Bind_Norm (Item : in out Model; Name : String; Result : out Norm; Status : out E.Error_Info) is
   begin
      Bind_Values (Item, Name & ".weight", 1, Item.Width, Result.Weight, Status);
      if E.Is_Ok (Status) then
         Bind_Values (Item, Name & ".bias", 1, Item.Width, Result.Bias, Status);
      end if;
   end Bind_Norm;

   procedure Bind_Projection
     (Item      : in out Model;
      Name      : String;
      Rows      : Element_Count;
      Columns   : Element_Count;
      With_Bias : Boolean;
      Result    : out Projection;
      Status    : out E.Error_Info) is
   begin
      Result.Bias := null;
      Bind (Item, Name & ".weight", Rows, Columns, Result.Weight, Status);
      if E.Is_Ok (Status) and then With_Bias then
         Bind_Values (Item, Name & ".bias", 1, Rows, Result.Bias, Status);
      end if;
   end Bind_Projection;

   procedure Bind_Attention
     (Item : in out Model; Name : String; Result : out Attention_Weights; Status : out E.Error_Info)
   is
      W : constant Element_Count := Item.Width;
   begin
      Bind_Projection (Item, Name & "_q", W, W, True, Result.Q, Status);
      if E.Is_Ok (Status) then
         Bind_Projection (Item, Name & "_k", W, W, False, Result.K, Status);
      end if;
      if E.Is_Ok (Status) then
         Bind_Projection (Item, Name & "_v", W, W, True, Result.V, Status);
      end if;
      if E.Is_Ok (Status) then
         Bind_Projection (Item, Name & "_out", W, W, True, Result.Output, Status);
      end if;
   end Bind_Attention;

   procedure Free_Norm (Item : in out Norm) is
   begin
      T.Free (Item.Weight);
      T.Free (Item.Bias);
   end Free_Norm;

   procedure Free_Projection (Item : in out Projection) is
   begin
      Item.Weight := T.Empty_View;
      T.Free (Item.Bias);
   end Free_Projection;

   procedure Free_Attention (Item : in out Attention_Weights) is
   begin
      Free_Projection (Item.Q);
      Free_Projection (Item.K);
      Free_Projection (Item.V);
      Free_Projection (Item.Output);
   end Free_Attention;

   procedure Free_Blocks (Item : in out Block_Array_Access) is
   begin
      if Item = null then
         return;
      end if;
      for Each of Item.all loop
         Free_Norm (Each.Attention_Norm);
         Free_Attention (Each.Attention);
         Free_Norm (Each.Cross_Norm);
         Free_Attention (Each.Cross);
         Free_Norm (Each.Feed_Norm);
         Free_Projection (Each.Up);
         Free_Projection (Each.Down);
      end loop;
      Free (Item);
   end Free_Blocks;

   --  Everything a model holds, given back.
   procedure Release (Item : in out Model) is
   begin
      Item.Ready := False;
      Free_Blocks (Item.Encoder);
      Free_Blocks (Item.Decoder);
      Free_Projection (Item.Conv1);
      Free_Projection (Item.Conv2);
      T.Free (Item.Audio_Positions);
      T.Free (Item.Text_Positions);
      Free_Norm (Item.Encoder_Norm);
      Free_Norm (Item.Decoder_Norm);
      Item.Token_Table := T.Empty_View;
      Item.Language_Total := 0;
      Item.Suppressed_Count := 0;
      Item.Begin_Suppressed_Count := 0;
      Item.Alignment_Count := 0;
      Item.Title := Null_Unbounded_String;
      Tk.Close (Item.Vocabulary);
      B.Free (Item.Arena);
      Item.Base := System.Null_Address;
      Item.Span := 0;
      Containers.Close (Item.Container);
      Model_Runner.Byte_Sources.Files.Close (Item.File);
   end Release;

   -------------
   -- Prepare --
   -------------

   procedure Prepare
     (Item   : in out Model;
      Path   : String;
      Status : out E.Error_Info)
   is
      procedure Fail (Condition : E.Error_Info) is
      begin
         Status := Condition;
         Release (Item);
      end Fail;

      --  An integer the profile requires, within bounds.
      procedure Need
        (Key : String; Minimum, Maximum : Long_Long_Integer; Value : out Long_Long_Integer; Ok : out Boolean) is
      begin
         Containers.Get_Integer (Item.Container, Key, Minimum, Maximum, Value, Status);
         Ok := E.Is_Ok (Status);
         if not Ok then
            E.Add_Text (Status, "key", Key, E.Param_Identifier);
            Fail (Status);
         end if;
      end Need;

      --  A token the profile names, within the vocabulary.
      procedure Need_Token (Key : String; Into : out Token_Id; Ok : out Boolean) is
         Value : Long_Long_Integer;
      begin
         Need (Key, 0, Long_Long_Integer (Item.Vocabulary_Size) - 1, Value, Ok);
         Into := (if Ok then Token_Id (Value) else 0);
      end Need_Token;

      --  A list of tokens the profile names.
      procedure Need_List (Key : String; Into : out Token_List; Count : out Natural; Ok : out Boolean) is
         Length : Natural;
         Value  : Long_Long_Integer;
         At_Entry : constant Natural := Containers.Find (Item.Container, Key);
      begin
         Into := [others => 0];
         Count := 0;
         Containers.Get_Array_Length (Item.Container, Key, Model_Runner.GGUF.Value_Int32, Length, Status);
         Ok := E.Is_Ok (Status);
         if Ok and then Length > Max_Suppressed then
            Status := E.Make (E.Arch_Invalid_Metadata);
            Ok := False;
         end if;
         for I in 1 .. (if Ok then Length else 0) loop
            Containers.Get_Integer_Element (Item.Container, Key, I, Value, Status, At_Entry);
            if E.Is_Error (Status) or else Value < 0 or else Value >= Long_Long_Integer (Item.Vocabulary_Size) then
               Status := E.Make (E.Arch_Invalid_Metadata);
               Ok := False;
               exit;
            end if;
            Into (I) := Token_Id (Value);
            Count := I;
         end loop;
         if not Ok then
            E.Add_Text (Status, "key", Key, E.Param_Identifier);
            Fail (Status);
         end if;
      end Need_List;

      Value : Long_Long_Integer;
      Ok    : Boolean;
   begin
      Status := E.Success;
      if Item.Open_Sessions > 0 then
         Status := E.Make (E.Lifecycle_Session_Active);
         return;
      end if;
      Release (Item);

      Model_Runner.Byte_Sources.Files.Open (Item.File, Path, Status => Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;
      Containers.Reader.Parse (Item.Container, Item.File, Status => Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      declare
         Kind : constant String := Containers.String_Value (Item.Container, "general.architecture");
      begin
         if Kind /= Architecture then
            Status := E.Make (E.Arch_Unsupported);
            E.Add_Text (Status, "architecture", (if Kind = "" then "none" else Kind), E.Param_Identifier);
            Fail (Status);
            return;
         end if;
      end;
      Need ("whisper.profile.version", Profile_Version, Profile_Version, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Title := To_Unbounded_String (Containers.String_Value (Item.Container, "general.name"));

      Need ("whisper.encoder.embedding_length", 1, 8_192, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Width := Element_Count (Value);
      Need ("whisper.decoder.embedding_length", Value, Value, Value, Ok);
      if not Ok then
         return;
      end if;
      Need ("whisper.audio.mel_bins", 1, Long_Long_Integer (Spectrograms.Mel_Count'Last), Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Mels := Positive (Value);
      --  The window the encoder hears is fixed: thirty seconds, 3,000
      --  frames, 1,500 positions after the second convolution's stride.
      Need ("whisper.encoder.context_length", Long_Long_Integer (Audio_Positions_Count),
            Long_Long_Integer (Audio_Positions_Count), Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Audio_Context := Element_Count (Value);
      Need ("whisper.audio.sample_rate", Model_Runner.Audio.Canonical_Rate, Model_Runner.Audio.Canonical_Rate,
            Value, Ok);
      if not Ok then
         return;
      end if;
      Need ("whisper.audio.hop_length", Spectrograms.Hop_Length, Spectrograms.Hop_Length, Value, Ok);
      if not Ok then
         return;
      end if;
      Need ("whisper.audio.window_length", Spectrograms.Window_Length, Spectrograms.Window_Length, Value, Ok);
      if not Ok then
         return;
      end if;
      Need ("whisper.decoder.context_length", 8, 4_096, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Text_Context := Element_Count (Value);
      Need ("whisper.encoder.block_count", 1, Max_Blocks, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Encoder_Blocks := Natural (Value);
      Need ("whisper.decoder.block_count", 1, Max_Blocks, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Decoder_Blocks := Natural (Value);
      Need ("whisper.encoder.attention.head_count", 1, 256, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Encoder_Heads := Positive (Value);
      Need ("whisper.decoder.attention.head_count", 1, 256, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Decoder_Heads := Positive (Value);
      Need ("whisper.encoder.feed_forward_length", 1, 65_536, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Encoder_Feed := Element_Count (Value);
      Need ("whisper.decoder.feed_forward_length", 1, 65_536, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Decoder_Feed := Element_Count (Value);
      Need ("whisper.vocabulary.size", 16, 1_000_000, Value, Ok);
      if not Ok then
         return;
      end if;
      Item.Vocabulary_Size := Element_Count (Value);
      declare
         Epsilon : Wide_Real;
      begin
         Containers.Get_Float
           (Item.Container, "whisper.attention.layer_norm_epsilon", 1.0E-12, 1.0E-2, Epsilon, Status);
         if E.Is_Error (Status) then
            E.Add_Text (Status, "key", "whisper.attention.layer_norm_epsilon", E.Param_Identifier);
            Fail (Status);
            return;
         end if;
         Item.Epsilon := Real (Epsilon);
      end;

      if Item.Width mod Element_Count (Item.Encoder_Heads) /= 0
        or else Item.Width mod Element_Count (Item.Decoder_Heads) /= 0
      then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer (Status, "embedding", Long_Long_Integer (Item.Width));
         E.Add_Integer (Status, "heads", Long_Long_Integer (Item.Encoder_Heads));
         Fail (Status);
         return;
      end if;

      Need_Token ("whisper.token.end_of_text", Item.End_Of_Text, Ok);
      if Ok then
         Need_Token ("whisper.token.start_of_transcript", Item.Start_Of_Transcript, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.transcribe", Item.Transcribe_Token, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.translate", Item.Translate_Token, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.start_of_previous", Item.Start_Of_Previous, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.start_of_lm", Item.Start_Of_LM, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.no_timestamps", Item.No_Timestamps, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.no_speech", Item.No_Speech, Ok);
      end if;
      if Ok then
         Need_Token ("whisper.token.timestamp_begin", Item.Timestamp_Begin, Ok);
      end if;
      if Ok then
         Need_List ("whisper.suppress_tokens", Item.Suppressed, Item.Suppressed_Count, Ok);
      end if;
      if Ok then
         Need_List ("whisper.begin_suppress_tokens", Item.Begin_Suppressed, Item.Begin_Suppressed_Count, Ok);
      end if;
      if not Ok then
         return;
      end if;
      --  The heads word timing reads.
      if Containers.Has (Item.Container, "whisper.alignment_heads") then
         declare
            Length   : Natural;
            Value    : Long_Long_Integer;
            Block    : Long_Long_Integer := 0;
            At_Entry : constant Natural := Containers.Find (Item.Container, "whisper.alignment_heads");
         begin
            Containers.Get_Array_Length
              (Item.Container, "whisper.alignment_heads", Model_Runner.GGUF.Value_Int32, Length, Status);
            if E.Is_Ok (Status) and then (Length mod 2 /= 0 or else Length / 2 > Max_Alignment_Heads) then
               Status := E.Make (E.Arch_Invalid_Metadata);
            end if;
            for I in 1 .. (if E.Is_Ok (Status) then Length else 0) loop
               Containers.Get_Integer_Element (Item.Container, "whisper.alignment_heads", I, Value, Status, At_Entry);
               exit when E.Is_Error (Status);
               if I mod 2 = 1 then
                  Block := Value;
               elsif Block < 0 or else Block >= Long_Long_Integer (Item.Decoder_Blocks)
                 or else Value < 0 or else Value >= Long_Long_Integer (Item.Decoder_Heads)
               then
                  Status := E.Make (E.Arch_Invalid_Metadata);
                  exit;
               else
                  Item.Alignment_Count := Item.Alignment_Count + 1;
                  Item.Alignment (Item.Alignment_Count) := (Positive (Block + 1), Natural (Value));
               end if;
            end loop;
            if E.Is_Error (Status) then
               E.Add_Text (Status, "key", "whisper.alignment_heads", E.Param_Identifier);
               Fail (Status);
               return;
            end if;
         end;
      else
         for B in Item.Decoder_Blocks / 2 + 1 .. Item.Decoder_Blocks loop
            for H in 0 .. Item.Decoder_Heads - 1 loop
               exit when Item.Alignment_Count = Max_Alignment_Heads;
               Item.Alignment_Count := Item.Alignment_Count + 1;
               Item.Alignment (Item.Alignment_Count) := (B, H);
            end loop;
         end loop;
      end if;

      --  A transcript's times run to thirty seconds: 1,501 of them.
      if Element_Count (Item.Timestamp_Begin) + 1_501 > Item.Vocabulary_Size then
         Status := E.Make (E.Arch_Invalid_Metadata);
         E.Add_Text (Status, "key", "whisper.token.timestamp_begin", E.Param_Identifier);
         Fail (Status);
         return;
      end if;

      Containers.Get_Boolean (Item.Container, "whisper.multilingual", Item.Multilingual, Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "key", "whisper.multilingual", E.Param_Identifier);
         Fail (Status);
         return;
      end if;
      if Item.Multilingual then
         declare
            Count    : Natural;
            At_Entry : constant Natural := Containers.Find (Item.Container, "whisper.languages");
         begin
            Need_Token ("whisper.token.first_language", Item.First_Language, Ok);
            if not Ok then
               return;
            end if;
            Containers.Get_Array_Length
              (Item.Container, "whisper.languages", Model_Runner.GGUF.Value_String, Count, Status);
            if E.Is_Ok (Status)
              and then (Count < 1 or else Count > Max_Languages
                        or else Element_Count (Item.First_Language) + Element_Count (Count) > Item.Vocabulary_Size)
            then
               Status := E.Make (E.Arch_Invalid_Metadata);
            end if;
            for I in 1 .. (if E.Is_Ok (Status) then Count else 0) loop
               Containers.Get_String_Element
                 (Item.Container, "whisper.languages", I, Item.Languages (I).Text, Item.Languages (I).Length,
                  Status, At_Entry);
               exit when E.Is_Error (Status);
            end loop;
            if E.Is_Error (Status) then
               E.Add_Text (Status, "key", "whisper.languages", E.Param_Identifier);
               Fail (Status);
               return;
            end if;
            Item.Language_Total := Count;
         end;
      end if;

      --  The tensor section: the file's own pages where it is mapped,
      --  read into an arena where it is not.
      declare
         Data_At : constant B.Byte_Count := B.Byte_Count (Containers.Data_Offset (Item.Container));
         Length  : constant B.Byte_Count := B.Byte_Count (Containers.Tensor_Data_Bytes (Item.Container));
      begin
         if Item.File.Is_Mapped
           and then Item.File.Base /= System.Null_Address
           and then Item.File.Size >= Data_At + Length
         then
            Item.Base := System.Storage_Elements.To_Address
              (System.Storage_Elements.To_Integer (Item.File.Base)
               + System.Storage_Elements.Integer_Address (Data_At));
            Item.Span := Length;
         else
            B.Allocate (Length, Item.Arena);
            if Item.Arena = null then
               Fail (E.Make (E.Memory_Allocation_Failed));
               return;
            end if;
            Item.File.Read (Data_At, Item.Arena.all, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
            Item.Base := Item.Arena.all'Address;
            Item.Span := Length;
         end if;
      end;

      Tk.Load (Item.Vocabulary, Item.Container, Status => Status);
      if E.Is_Ok (Status) and then Element_Count (Tk.Size (Item.Vocabulary)) /= Item.Vocabulary_Size then
         Status := E.Make (E.Arch_Vocabulary_Mismatch);
      end if;
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      declare
         W  : constant Element_Count := Item.Width;
         M  : constant Element_Count := Element_Count (Item.Mels);
      begin
         Bind_Projection (Item, "enc.conv1", W, 3 * M, True, Item.Conv1, Status);
         if E.Is_Ok (Status) then
            Bind_Projection (Item, "enc.conv2", W, 3 * W, True, Item.Conv2, Status);
         end if;
         if E.Is_Ok (Status) then
            Bind_Values (Item, "enc.position_embd.weight", Item.Audio_Context, W, Item.Audio_Positions, Status);
         end if;
         if E.Is_Ok (Status) then
            Item.Encoder := new Block_Array (1 .. Item.Encoder_Blocks);
            Item.Decoder := new Block_Array (1 .. Item.Decoder_Blocks);
         end if;
         for L in 1 .. (if E.Is_Ok (Status) then Item.Encoder_Blocks else 0) loop
            declare
               Name : constant String := "enc.blk." & Image (Long_Long_Integer (L - 1));
               Each : Block renames Item.Encoder (L);
            begin
               Bind_Norm (Item, Name & ".attn_norm", Each.Attention_Norm, Status);
               if E.Is_Ok (Status) then
                  Bind_Attention (Item, Name & ".attn", Each.Attention, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Norm (Item, Name & ".ffn_norm", Each.Feed_Norm, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Projection (Item, Name & ".ffn_up", Item.Encoder_Feed, W, True, Each.Up, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Projection (Item, Name & ".ffn_down", W, Item.Encoder_Feed, True, Each.Down, Status);
               end if;
            end;
            exit when E.Is_Error (Status);
         end loop;
         if E.Is_Ok (Status) then
            Bind_Norm (Item, "enc.output_norm", Item.Encoder_Norm, Status);
         end if;
         if E.Is_Ok (Status) then
            Bind (Item, "dec.token_embd.weight", Item.Vocabulary_Size, W, Item.Token_Table, Status);
         end if;
         if E.Is_Ok (Status) then
            Bind_Values (Item, "dec.position_embd.weight", Item.Text_Context, W, Item.Text_Positions, Status);
         end if;
         for L in 1 .. (if E.Is_Ok (Status) then Item.Decoder_Blocks else 0) loop
            declare
               Name : constant String := "dec.blk." & Image (Long_Long_Integer (L - 1));
               Each : Block renames Item.Decoder (L);
            begin
               Bind_Norm (Item, Name & ".attn_norm", Each.Attention_Norm, Status);
               if E.Is_Ok (Status) then
                  Bind_Attention (Item, Name & ".attn", Each.Attention, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Norm (Item, Name & ".cross_attn_norm", Each.Cross_Norm, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Attention (Item, Name & ".cross_attn", Each.Cross, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Norm (Item, Name & ".ffn_norm", Each.Feed_Norm, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Projection (Item, Name & ".ffn_up", Item.Decoder_Feed, W, True, Each.Up, Status);
               end if;
               if E.Is_Ok (Status) then
                  Bind_Projection (Item, Name & ".ffn_down", W, Item.Decoder_Feed, True, Each.Down, Status);
               end if;
            end;
            exit when E.Is_Error (Status);
         end loop;
         if E.Is_Ok (Status) then
            Bind_Norm (Item, "dec.output_norm", Item.Decoder_Norm, Status);
         end if;
      end;
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Ready := True;
   exception
      when Storage_Error =>
         Fail (E.Make (E.Memory_Allocation_Failed));
   end Prepare;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Model; Status : out E.Error_Info) is
   begin
      if Item.Open_Sessions > 0 then
         Status := E.Make (E.Lifecycle_Session_Active);
         return;
      end if;
      Status := E.Success;
      Release (Item);
   end Close;

   --------------
   -- Queries --
   --------------

   function Is_Ready (Item : Model) return Boolean is (Item.Ready);

   function Name (Item : Model) return String is (To_String (Item.Title));

   function Is_Multilingual (Item : Model) return Boolean is (Item.Multilingual);

   function Language_Count (Item : Model) return Natural is (Item.Language_Total);

   function Language_Code (Item : Model; Index : Positive) return String is
     (Item.Languages (Index).Text (1 .. Item.Languages (Index).Length));

   function Language_Index (Item : Model; Code : String) return Natural is
   begin
      for I in 1 .. Item.Language_Total loop
         if Language_Code (Item, I) = Code then
            return I;
         end if;
      end loop;
      return 0;
   end Language_Index;

   function Knows_Language (Item : Model; Code : String) return Boolean is
     (Language_Index (Item, Code) > 0);

   function Weight_Bytes (Item : Model) return B.Byte_Count is
     (if Item.Ready then B.Byte_Count (Containers.Tensor_Data_Bytes (Item.Container)) else 0);

   function Sessions_Open (Item : Model) return Natural is (Item.Open_Sessions);

   --  The elements each of a session's buffers is allocated with.
   type Sizes is record
      Encoded, Cross, Self, A, B, C, D, E, Scores, Decoded : Element_Count := 0;
      Row, Feed_Row, Dec_Scores, Logits : Element_Count := 0;
   end record;

   function Sizes_Of (Item : Model) return Sizes is
      P  : constant Element_Count := Item.Audio_Context;
      P2 : constant Element_Count := Window_Frames;
      W  : constant Element_Count := Item.Width;
      M  : constant Element_Count := Element_Count (Item.Mels);
      F  : constant Element_Count := Element_Count'Max (Item.Encoder_Feed, Item.Decoder_Feed);
      Ctx : constant Element_Count := Item.Text_Context;
   begin
      return
        (Encoded    => P * W,
         Cross      => P * W,
         Self       => Ctx * W,
         A          => Element_Count'Max (P2 * 3 * M, P * W),
         B          => P2 * W,
         C          => Element_Count'Max (P * 3 * W, P * F),
         D          => P * W,
         E          => P * W,
         Scores     => P * P,
         Decoded    => Element_Count'Max (W * F, Element_Count'Max (W * 3 * W, W * 3 * M)),
         Row        => Ctx * W,
         Feed_Row   => Ctx * F,
         Dec_Scores => Element_Count (Positive'Max (Item.Decoder_Heads, Item.Encoder_Heads)) * P * Ctx,
         Logits     => Item.Vocabulary_Size);
   end Sizes_Of;

   function Session_Bytes (Item : Model) return B.Byte_Count is
      S : constant Sizes := Sizes_Of (Item);
      Blocks : constant Element_Count := Element_Count (Item.Decoder_Blocks);
      Floats : constant Element_Count :=
        S.Encoded + 2 * Blocks * (S.Cross + S.Self) + S.A + S.B + S.C + S.D + S.E + S.Scores
        --  The decoded weight, and the three panel sets about as large as
        --  what they lay out.
        + 2 * S.Decoded + 2 * Item.Audio_Context * Item.Width
        + 6 * S.Row + S.Feed_Row + S.Dec_Scores + Item.Width + S.Logits
        --  The encoder's matrices kept in panels, and the decoder's keys'
        --  and values' of what was heard.
        + Element_Count (Item.Encoder_Blocks) * (4 * Item.Width * Item.Width + 2 * Item.Width * Item.Encoder_Feed)
        + 3 * Item.Width * (Element_Count (Item.Mels) + Item.Width)
        + 2 * Element_Count (Item.Decoder_Blocks) * Item.Width * Item.Width;
   begin
      return (if Item.Ready then 4 * B.Byte_Count (Floats) else 0);
   end Session_Bytes;

   --------------
   -- Sessions --
   --------------

   procedure Free_Panels (Set : in out Panel_Array_Access) is
   begin
      if Set /= null then
         for Each of Set.all loop
            FP.Free (Each);
         end loop;
         Free (Set);
      end if;
   end Free_Panels;

   --  The device's copies of the session's matrices and norms forgotten.
   procedure Forget_Matrices (Item : in out Session);

   procedure Close (Item : in out Session) is
   begin
      --  Kept, the device holds the session's norms too, by the address of
      --  a buffer freed here that the next allocation may be given.
      if Item.Source /= null and then Item.Keep_On_Device then
         Forget_Matrices (Item);
      end if;
      if Item.Source /= null then
         Item.Source.Open_Sessions := Item.Source.Open_Sessions - 1;
         Item.Source := null;
      end if;
      Item.Team := null;
      T.Free (Item.Encoded);
      T.Free (Item.Cross_K);
      T.Free (Item.Cross_V);
      T.Free (Item.Self_K);
      T.Free (Item.Self_V);
      T.Free (Item.Work_A);
      T.Free (Item.Work_B);
      T.Free (Item.Work_C);
      T.Free (Item.Work_D);
      T.Free (Item.Work_E);
      T.Free (Item.Scores);
      T.Free (Item.Decoded);
      T.Free (Item.Norm_Pairs);
      T.Free (Item.Cross_Pairs);
      for Pairs of Item.Encoder_Pairs loop
         T.Free (Pairs (1));
         T.Free (Pairs (2));
      end loop;
      T.Free (Item.Candidate_K);
      T.Free (Item.Candidate_V);
      T.Free (Item.Candidate_Logits);
      T.Free (Item.Candidate_Query);
      T.Free (Item.Candidate_Blend);
      FP.Free (Item.Weight_Panels);
      Free_Panels (Item.Packed);
      Free_Panels (Item.Cross_Keys);
      Free_Panels (Item.Cross_Values);
      FP.Free (Item.Key_Panels);
      FP.Free (Item.Value_Panels);
      T.Free (Item.Dec_X);
      T.Free (Item.Dec_H);
      T.Free (Item.Dec_Q);
      T.Free (Item.Dec_K);
      T.Free (Item.Dec_V);
      T.Free (Item.Dec_A);
      T.Free (Item.Dec_F);
      T.Free (Item.Dec_Scores);
      T.Free (Item.Last_Row);
      T.Free (Item.Logits);
      T.Free (Item.Captured);
      Item.Capturing := False;
      Item.Has_Encoded := False;
      Item.Held := 0;
   end Close;

   function Is_Open (Item : Session) return Boolean is (Item.Source /= null);

   procedure Use_Device (Item : in out Session; On : Boolean; Keep : Boolean := False) is
      use type Interfaces.Unsigned_64;
   begin
      Item.On_Device := On;
      Item.Keep_On_Device := Keep;
      --  The file's pages kept where the model is small beside the device,
      --  as a language model's are (Prepare): read past the cache, Whisper
      --  small's 490 MB came from the drive at every run's first window --
      --  JFK's eleven seconds 1.46 s from the command line, where
      --  whisper.cpp, its file held from the run before, took 0.69. A
      --  language model already open that gave its pages back keeps them
      --  given back (Keep_File_Pages).
      if On and then Model_Runner.Backend.Device.Is_Ready then
         Model_Runner.Backend.Device.Keep_File_Pages
           (Interfaces.Unsigned_64 (Weight_Bytes (Item.Source.all))
            <= Model_Runner.Backend.Device.Heap_Bytes / 5 * 2);
      end if;
   end Use_Device;

   procedure Open
     (Item   : in out Session;
      Source : not null access Model;
      Team   : CPU.Pool_Reference;
      Status : out E.Error_Info)
   is
      S : Sizes;
      Ok : Boolean := True;

      procedure Room (Length : Element_Count; Into : out T.Real_Array_Access) is
      begin
         T.Allocate (Length, Into);
         Ok := Ok and then Into /= null;
      end Room;

      procedure Rooms (Count : Natural; Length : Element_Count; Into : out T.Group_Room_Access) is
      begin
         Into := new T.Group_Room (1 .. Count);
         for Each of Into.all loop
            Room (Length, Each);
         end loop;
      end Rooms;
   begin
      Close (Item);
      if not Source.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;
      S := Sizes_Of (Source.all);
      Room (S.Encoded, Item.Encoded);
      Rooms (Source.Decoder_Blocks, S.Cross, Item.Cross_K);
      Rooms (Source.Decoder_Blocks, S.Cross, Item.Cross_V);
      Rooms (Source.Decoder_Blocks, S.Self, Item.Self_K);
      Rooms (Source.Decoder_Blocks, S.Self, Item.Self_V);
      Room (S.A, Item.Work_A);
      Room (S.B, Item.Work_B);
      Room (S.C, Item.Work_C);
      Room (S.D, Item.Work_D);
      Room (S.E, Item.Work_E);
      Room (S.Scores, Item.Scores);
      Room (S.Decoded, Item.Decoded);
      Room (S.Row, Item.Dec_X);
      Room (S.Row, Item.Dec_H);
      Room (S.Row, Item.Dec_Q);
      Room (S.Row, Item.Dec_K);
      Room (S.Row, Item.Dec_V);
      Room (S.Row, Item.Dec_A);
      Room (S.Feed_Row, Item.Dec_F);
      Room (S.Dec_Scores, Item.Dec_Scores);
      Room (Source.Width, Item.Last_Row);
      Room (S.Logits, Item.Logits);
      Item.Packed := new Panel_Array (1 .. 2 + 6 * Source.Encoder_Blocks + 2 * Source.Decoder_Blocks);
      Item.Cross_Keys := new Panel_Array (1 .. Source.Decoder_Blocks * Source.Decoder_Heads);
      Item.Cross_Values := new Panel_Array (1 .. Source.Decoder_Blocks * Source.Decoder_Heads);
      --  The session is closed before the model may be: the model refuses
      --  to close while it counts one open.
      Item.Source := Source.all'Unchecked_Access;
      Item.Team := Team;
      Source.Open_Sessions := Source.Open_Sessions + 1;
      if not Ok then
         Close (Item);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "speech", E.Param_Identifier);
         return;
      end if;
      Status := E.Success;
   exception
      when Storage_Error =>
         Close (Item);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "speech", E.Param_Identifier);
   end Open;

   ---------------
   -- Row tasks --
   ---------------

   --  Work over rows, each on its own: a layer normalization, the exact
   --  GELU, a bias added, a row added in, or a softmax of scaled scores.
   type Row_Task is (Normalize, Gaussian, Add_Bias, Accumulate, Scaled_Softmax);

   type Row_Work is new Model_Runner.Shares.Work with record
      Kind           : Row_Task := Add_Bias;
      Source, Target : T.Real_Array_Access;
      Width          : Element_Count := 0;
      Weight, Bias   : T.Real_Array_Access;
      Epsilon, Scale : Real := 0.0;
      Failed         : Boolean := False with Atomic;
   end record;

   overriding procedure Run (Item : in out Row_Work; First : Element_Count; Last : Element_Count) is
      Ok : Boolean;
   begin
      for Row in First .. Last loop
         declare
            From : constant Element_Count := Row * Item.Width;
            To   : constant Element_Count := From + Item.Width - 1;
         begin
            case Item.Kind is
               when Normalize =>
                  K.Layer_Norm (Item.Source (From .. To), Item.Weight.all, Item.Bias.all, Item.Epsilon,
                                Item.Target (From .. To));
               when Gaussian =>
                  K.Exact_GELU (Item.Target (From .. To));
               when Add_Bias =>
                  K.Add (Item.Target (From .. To), Item.Bias.all);
               when Accumulate =>
                  K.Add (Item.Target (From .. To), Item.Source (From .. To));
               when Scaled_Softmax =>
                  K.Scale (Item.Target (From .. To), Item.Scale);
                  K.Softmax (Item.Target (From .. To), Ok);
                  if not Ok then
                     Item.Failed := True;
                  end if;
            end case;
         end;
      end loop;
   end Run;

   --  Elements of row work below which the pool is not woken.
   Small_Rows : constant Element_Count := 32_768;

   procedure Rows_Through
     (Item   : in out Session;
      Kind   : Row_Task;
      Target : T.Real_Array_Access;
      Rows   : Element_Count;
      Width  : Element_Count;
      Status : in out E.Error_Info;
      Source : T.Real_Array_Access := null;
      Weight : T.Real_Array_Access := null;
      Bias   : T.Real_Array_Access := null;
      Scale  : Real := 1.0)
   is
      Work : aliased Row_Work;
   begin
      if E.Is_Error (Status) or else Rows = 0 then
         return;
      end if;
      Work.Kind := Kind;
      Work.Source := Source;
      Work.Target := Target;
      Work.Width := Width;
      Work.Weight := Weight;
      Work.Bias := Bias;
      Work.Epsilon := Item.Source.Epsilon;
      Work.Scale := Scale;
      --  A few rows -- the decoder's one a token -- are done here: waking
      --  the pool for microseconds of work cost more than the work, some
      --  two hundred and fifty times a token.
      CPU.Dispatch_Shares ((if Rows * Width < Small_Rows then null else Item.Team), Rows, Work'Unchecked_Access,
                           Status, Cost => Rows * Width);
      if E.Is_Ok (Status) and then Work.Failed then
         Status := E.Make (E.Sampling_Non_Finite_Logit);
      end if;
   end Rows_Through;

   --------------
   -- Products --
   --------------

   --  A weight's rows decoded to binary32, shared over the pool: a whole
   --  window's weights pass through here, ninety million elements on small,
   --  and on the calling task alone that was a tenth of the encoder.
   type Decode_Work is new Model_Runner.Shares.Work with record
      Weight : T.View;
      Into   : T.Real_Array_Access;
      Failed : Boolean := False with Atomic;
   end record;

   overriding procedure Run (Item : in out Decode_Work; First : Element_Count; Last : Element_Count) is
      Cols   : constant Element_Count := Item.Weight.Columns;
      Status : E.Error_Info;
   begin
      for R in First .. Last loop
         T.Dequantize_Row (Item.Weight, R, Item.Into (R * Cols .. (R + 1) * Cols - 1), Status);
         if E.Is_Error (Status) then
            Item.Failed := True;
         end if;
      end loop;
   end Run;

   --  Target := Count rows of Source times Weight, plus Bias: the weight
   --  decoded to binary32 and laid out in panels, then multiplied over the
   --  team. For the encoder's thousands of rows, where the arithmetic and
   --  not the reading is the cost.
   procedure Multiply_Many
     (Item   : in out Session;
      Source : T.Real_Array_Access;
      Count  : Element_Count;
      Weight : T.View;
      Target : T.Real_Array_Access;
      Bias   : T.Real_Array_Access;
      Status : in out E.Error_Info;
      Slot   : Positive)
   is
      Team : constant Model_Runner.Shares.Team_Access := CPU.Sharing (Item.Team);
      Rows : constant Element_Count := Weight.Rows;
      Cols : constant Element_Count := Weight.Columns;
   begin
      if E.Is_Error (Status) then
         return;
      end if;
      --  On the device the weights as the file holds them, where its tile
      --  takes their shape whole; anything it declines, on the pool.
      if Item.Borrowed
        and then Cols mod 128 = 0 and then Rows mod 32 = 0
      then
         declare
            Answer : E.Error_Info;
         begin
            Model_Runner.Backend.Device.Dispatch_Batch (Weight, Source, Count, Target, Answer);
            if E.Is_Ok (Answer) then
               if Bias /= null then
                  Rows_Through (Item, Add_Bias, Target, Count, Rows, Status, Bias => Bias);
               end if;
               return;
            end if;
         end;
      end if;
      if FP.Is_Packed (Item.Packed (Slot)) then
         FP.Multiply (Team, Item.Packed (Slot), Source.all, 0, Cols, Count, Target.all, 0, Rows);
         if Bias /= null then
            Rows_Through (Item, Add_Bias, Target, Count, Rows, Status, Bias => Bias);
         end if;
         return;
      end if;
      declare
         Work : aliased Decode_Work;
      begin
         Work.Weight := Weight;
         Work.Into := Item.Decoded;
         CPU.Dispatch_Shares (Item.Team, Rows, Work'Unchecked_Access, Status, Cost => Rows * Cols);
         if E.Is_Ok (Status) and then Work.Failed then
            Status := E.Make (E.Tensor_Format_Unsupported);
         end if;
      end;
      if E.Is_Ok (Status) then
         FP.Pack (Team, Item.Decoded.all, 0, Rows, Cols, Cols, 1, Item.Packed (Slot), Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      FP.Multiply (Team, Item.Packed (Slot), Source.all, 0, Cols, Count, Target.all, 0, Rows);
      if Bias /= null then
         Rows_Through (Item, Add_Bias, Target, Count, Rows, Status, Bias => Bias);
      end if;
   end Multiply_Many;

   --  The same for the decoder's few rows: the weight read where it lies,
   --  in its own format, by the backend's products.
   procedure Multiply_Few
     (Item   : in out Session;
      Source : T.Real_Array_Access;
      Count  : Element_Count;
      Weight : T.View;
      Target : T.Real_Array_Access;
      Bias   : T.Real_Array_Access;
      Status : in out E.Error_Info) is
   begin
      if E.Is_Error (Status) then
         return;
      end if;
      CPU.Dispatch_Batch (Item.Team, Weight, Source, Count, Target, Status, Roles => CPU.Every_Role);
      if Bias /= null then
         Rows_Through (Item, Add_Bias, Target, Count, Weight.Rows, Status, Bias => Bias);
      end if;
   end Multiply_Few;

   ---------------
   -- Attention --
   ---------------

   --  The decoder's attention, a head a share: each query's scores over
   --  its keys, softened, and the values blended by them. Queries attend
   --  causally -- query i to keys 0 .. Before + i -- or to every key.
   type Head_Work is new Model_Runner.Shares.Work with record
      Queries, Keys, Values, Output, Scores : T.Real_Array_Access;
      Width, Head    : Element_Count := 0;
      Count          : Element_Count := 0;
      Key_Count      : Element_Count := 0;
      Before         : Element_Count := 0;
      Causal         : Boolean := False;
      Scale          : Real := 1.0;
      Score_Stride   : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Head_Work; First : Element_Count; Last : Element_Count) is
   begin
      for H in First .. Last loop
         declare
            Scores : constant Element_Count := H * Item.Score_Stride;
            Offset : constant Element_Count := H * Item.Head;
         begin
            for I in 0 .. Item.Count - 1 loop
               declare
                  Seen : constant Element_Count :=
                    (if Item.Causal then Item.Before + I + 1 else Item.Key_Count);
                  Top  : Real := Real'First;
                  Sum  : Wide_Real := 0.0;
                  Q_At : constant Element_Count := I * Item.Width + Offset;
               begin
                  for J in 0 .. Seen - 1 loop
                     declare
                        K_At : constant Element_Count := J * Item.Width + Offset;
                        Dot  : constant Real :=
                          K.Dot (Item.Queries (Q_At .. Q_At + Item.Head - 1),
                                 Item.Keys (K_At .. K_At + Item.Head - 1)) * Item.Scale;
                     begin
                        Item.Scores (Scores + J) := Dot;
                        Top := Real'Max (Top, Dot);
                     end;
                  end loop;
                  K.Exponentiate (Item.Scores (Scores .. Scores + Seen - 1), Top);
                  for J in 0 .. Seen - 1 loop
                     Sum := Sum + Wide_Real (Item.Scores (Scores + J));
                  end loop;
                  declare
                     Out_At : constant Element_Count := I * Item.Width + Offset;
                     Blend  : N.Wide_Real_Array (0 .. Item.Head - 1) := [others => 0.0];
                  begin
                     for J in 0 .. Seen - 1 loop
                        declare
                           V_At : constant Element_Count := J * Item.Width + Offset;
                           P    : constant Wide_Real := Wide_Real (Item.Scores (Scores + J));
                        begin
                           for D in 0 .. Item.Head - 1 loop
                              Blend (D) := Blend (D) + P * Wide_Real (Item.Values (V_At + D));
                           end loop;
                        end;
                     end loop;
                     for D in 0 .. Item.Head - 1 loop
                        Item.Output (Out_At + D) := Real (Blend (D) / Sum);
                     end loop;
                  end;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  A token's attention to what was heard, a head a share: its queries
   --  against the head's keys laid out in panels, the rows of scores
   --  softened, the head's values -- turned, in panels -- blended by them.
   --  Each head's products on its own worker, alone: the pool is shared
   --  over the heads, not inside one.
   type Cross_Work is new Model_Runner.Shares.Work with record
      Owner   : access Session;
      Block   : Positive := 1;
      Count   : Element_Count := 0;
      Scale   : Real := 1.0;
      Failed  : Boolean := False with Atomic;
   end record;

   overriding procedure Run (Item : in out Cross_Work; First : Element_Count; Last : Element_Count) is
      S     : Session renames Item.Owner.all;
      P     : constant Element_Count := S.Source.Audio_Context;
      W     : constant Element_Count := S.Source.Width;
      Heads : constant Positive := S.Source.Decoder_Heads;
      Head  : constant Element_Count := W / Element_Count (Heads);
      Ok    : Boolean;
   begin
      for H in First .. Last loop
         declare
            Slot   : constant Positive := (Item.Block - 1) * Heads + Positive (H + 1);
            Scores : constant Element_Count := H * P * S.Source.Text_Context;
         begin
            FP.Multiply (null, S.Cross_Keys (Slot), S.Dec_Q.all, H * Head, W, Item.Count,
                         S.Dec_Scores.all, Scores, P);
            for I in 0 .. Item.Count - 1 loop
               K.Scale (S.Dec_Scores (Scores + I * P .. Scores + (I + 1) * P - 1), Item.Scale);
            end loop;
            --  An alignment head's scores, kept before they are softened.
            if S.Capturing then
               for A in 1 .. S.Source.Alignment_Count loop
                  if S.Source.Alignment (A).Block = Item.Block and then S.Source.Alignment (A).Head = Natural (H) then
                     declare
                        Into : constant Element_Count := Element_Count (A - 1) * Item.Count * P;
                     begin
                        S.Captured (Into .. Into + Item.Count * P - 1) :=
                          S.Dec_Scores (Scores .. Scores + Item.Count * P - 1);
                     end;
                  end if;
               end loop;
            end if;
            for I in 0 .. Item.Count - 1 loop
               K.Softmax (S.Dec_Scores (Scores + I * P .. Scores + (I + 1) * P - 1), Ok);
               if not Ok then
                  Item.Failed := True;
               end if;
            end loop;
            FP.Multiply (null, S.Cross_Values (Slot), S.Dec_Scores.all, Scores, P, Item.Count,
                         S.Dec_A.all, H * Head, W);
         end;
      end loop;
   end Run;

   --  The encoder's attention: every position to every position, a head at
   --  a time, both products by panels -- the keys laid out as a weight the
   --  queries multiply, the scores softened row by row, then the values,
   --  turned, as a weight the scores multiply.
   --  Queries the device's attention takes at once, as the vision
   --  encoder's do.
   Device_Queries : constant Element_Count := 512;

   --  Whisper's part of the device's cache, from Cache_Base: each decoder
   --  block's keys and values of what was heard, then of its own
   --  positions, then the encoder's attention's keys and values.
   function Heard_Keys_At (Item : Session; Block : Positive) return Element_Count is
     (Item.Cache_Base + Element_Count (Block - 1) * 2 * Item.Source.Audio_Context * Item.Source.Width);

   function Heard_Values_At (Item : Session; Block : Positive) return Element_Count is
     (Heard_Keys_At (Item, Block) + Item.Source.Audio_Context * Item.Source.Width);

   function Own_Keys_At (Item : Session; Block : Positive) return Element_Count is
     (Item.Cache_Base
      + Element_Count (Item.Source.Decoder_Blocks) * 2 * Item.Source.Audio_Context * Item.Source.Width
      + Element_Count (Block - 1) * 2 * Item.Source.Text_Context * Item.Source.Width);

   function Own_Values_At (Item : Session; Block : Positive) return Element_Count is
     (Own_Keys_At (Item, Block) + Item.Source.Text_Context * Item.Source.Width);

   function Scratch_At (Item : Session) return Element_Count is
     (Own_Keys_At (Item, Item.Source.Decoder_Blocks + 1));

   --  Each decoder block's candidates' keys and values, past the
   --  encoder's scratch: a row of Wide widths a position, candidate c's in
   --  its c-th.
   function Wide_Keys_At (Item : Session; Block : Positive) return Element_Count is
     (Scratch_At (Item) + 2 * Item.Source.Audio_Context * Item.Source.Width
      + Element_Count (Block - 1) * 2 * Item.Source.Text_Context * Element_Count (Item.Wide) * Item.Source.Width);

   function Wide_Values_At (Item : Session; Block : Positive) return Element_Count is
     (Wide_Keys_At (Item, Block) + Item.Source.Text_Context * Element_Count (Item.Wide) * Item.Source.Width);

   function Cache_End (Item : Session) return Element_Count is
     (Wide_Keys_At (Item, Item.Source.Decoder_Blocks + 1));

   procedure Attend_Both_Ways
     (Item   : in out Session;
      Q, Kv, V, Into : T.Real_Array_Access;
      Status : in out E.Error_Info)
   is
      Source : constant Model_Access := Item.Source;
      Team   : constant Model_Runner.Shares.Team_Access := CPU.Sharing (Item.Team);
      P      : constant Element_Count := Source.Audio_Context;
      W      : constant Element_Count := Source.Width;
      Head   : constant Element_Count := W / Element_Count (Source.Encoder_Heads);
      Scale  : constant Real := Real (1.0 / Elementary.Sqrt (Wide_Real (Head)));
   begin
      --  On the device, as the vision encoder attends: the keys and values
      --  put in its cache past the conversation's, every position asking
      --  of every other, a batch of queries at a time.
      if Item.Borrowed and then Head mod 16 = 0 then
         declare
            Keys_At   : constant Element_Count := Scratch_At (Item);
            Values_At : constant Element_Count := Keys_At + P * W;
            Was_Exact : constant Boolean := Model_Runner.Backend.Device.Attends_Exactly;
            Ok        : Boolean;
            From      : Element_Count := 0;
         begin
            Ok := True;
            Model_Runner.Backend.Device.Put_Cache (Keys_At, Kv (0 .. P * W - 1), Ok);
            if Ok then
               Model_Runner.Backend.Device.Put_Cache (Values_At, V (0 .. P * W - 1), Ok);
            end if;
            Model_Runner.Backend.Device.Attend_Exactly (False);
            while Ok and then From < P loop
               declare
                  Take : constant Element_Count := Element_Count'Min (Device_Queries, P - From);
               begin
                  Model_Runner.Backend.Device.Attend
                    (Q (From * W .. (From + Take) * W - 1), Source.Encoder_Heads, Natural (Head), Natural (Head), 1,
                     0, Natural (P - 1), Keys_At, Values_At, Natural (W), Natural (W), Scale, 0.0,
                     Into (From * W .. (From + Take) * W - 1), Ok, Positions => Natural (Take), Causal => False);
                  From := From + Take;
               end;
            end loop;
            Model_Runner.Backend.Device.Attend_Exactly (Was_Exact);
            if Ok then
               return;
            end if;
         end;
      end if;
      for H in 0 .. Element_Count (Source.Encoder_Heads) - 1 loop
         exit when E.Is_Error (Status);
         FP.Pack (Team, Kv.all, H * Head, P, Head, W, 1, Item.Key_Panels, Status);
         exit when E.Is_Error (Status);
         FP.Multiply (Team, Item.Key_Panels, Q.all, H * Head, W, P, Item.Scores.all, 0, P);
         Rows_Through (Item, Scaled_Softmax, Item.Scores, P, P, Status, Scale => Scale);
         exit when E.Is_Error (Status);
         FP.Pack (Team, V.all, H * Head, Head, P, 1, W, Item.Value_Panels, Status);
         exit when E.Is_Error (Status);
         FP.Multiply (Team, Item.Value_Panels, Item.Scores.all, 0, P, P, Into.all, H * Head, W);
      end loop;
   end Attend_Both_Ways;

   ------------
   -- Encode --
   ------------

   --  The encoder's blocks on the device, each one sequence -- its two
   --  normalizations, its attention both ways over the window's positions,
   --  its feed-forward -- the activation carried from one to the next and
   --  home after the last, as a picture's encoder's are (Vision): every
   --  product a dispatch of its own with the normalizations, the units and
   --  the joins on the host between them sent the window's 1,500 positions
   --  to and fro some ten times a block, and Whisper small heard eleven
   --  seconds in 0.82 s where whisper.cpp hears them in 0.63. First_Host is
   --  the first block left for the host: one past the last, or where the
   --  device turned one down.
   procedure Encoder_On_Device
     (Item       : in out Session;
      First_Host : out Positive;
      Status     : in out E.Error_Info)
   is
      package D renames Model_Runner.Backend.Device;
      Source : constant Model_Access := Item.Source;
      P      : constant Element_Count := Source.Audio_Context;
      W      : constant Element_Count := Source.Width;
      Heads  : constant Element_Count := Element_Count (Source.Encoder_Heads);
      Head   : constant Element_Count := W / Heads;
      Scale  : constant Real := Real (1.0 / Elementary.Sqrt (Wide_Real (Head)));
      K_Base : constant Element_Count := Cache_End (Item);
      V_Base : constant Element_Count := K_Base + P * W;
      None   : T.View;
      Ok     : Boolean := True;
      Carried : Boolean := False;
      Was_Exact : Boolean;
   begin
      First_Host := 1;
      if not Item.Borrowed or else not D.Is_Ready
        or else Source.Encoder_Blocks > Item.Encoder_Pairs'Length
        or else Head mod 16 /= 0
        or else E.Is_Error (Status)
      then
         return;
      end if;

      D.Reserve_Cache (V_Base + P * W, V_Base + P * W, Ok, Scratch => True);
      if not Ok then
         return;
      end if;

      for L in 1 .. Source.Encoder_Blocks loop
         declare
            Each : Block renames Source.Encoder (L);

            procedure Pair (Which : Positive; Of_Norm : Norm) is
            begin
               if Item.Encoder_Pairs (L) (Which) = null then
                  T.Allocate (2 * W, Item.Encoder_Pairs (L) (Which));
                  if Item.Encoder_Pairs (L) (Which) /= null then
                     Item.Encoder_Pairs (L) (Which) (0 .. W - 1) := Of_Norm.Weight.all;
                     Item.Encoder_Pairs (L) (Which) (W .. 2 * W - 1) := Of_Norm.Bias.all;
                  end if;
               end if;
            end Pair;
         begin
            Pair (1, Each.Attention_Norm);
            Pair (2, Each.Feed_Norm);
            if Item.Encoder_Pairs (L) (1) = null or else Item.Encoder_Pairs (L) (2) = null then
               return;
            end if;
         end;
      end loop;

      Was_Exact := D.Attends_Exactly;
      D.Attend_Exactly (False);
      for L in 1 .. Source.Encoder_Blocks loop
         declare
            Each : Block renames Source.Encoder (L);
            Last : constant Boolean := L = Source.Encoder_Blocks;
         begin
            D.Whole_Layer
              (Item.Encoded.all (0 .. P * W - 1),
               Item.Encoder_Pairs (L) (1), Item.Encoder_Pairs (L) (2),
               Source.Epsilon,
               Each.Attention.Q.Weight, Each.Attention.K.Weight, Each.Attention.V.Weight,
               D.No_Turns, Natural (Head), 0, False,
               K_Base, V_Base,
               Natural (Heads), Natural (Head), 1,
               0, Natural (P - 1),
               K_Base, V_Base,
               Natural (W), Natural (W),
               Scale, 0.0,
               Each.Attention.Output.Weight, None, Each.Up.Weight, Each.Down.Weight,
               6,
               Item.Work_C, Item.Work_D, Item.Encoded, Ok,
               Positions  => Natural (P),
               Causal     => False,
               Carry_In   => Carried,
               Carry_Out  => not Last,
               Mirror     => False,
               Up_Bias    => Each.Up.Bias,
               Down_Bias  => Each.Down.Bias,
               Query_Bias => Each.Attention.Q.Bias,
               Value_Bias => Each.Attention.V.Bias,
               Out_Bias   => Each.Attention.Output.Bias,
               Shifted    => True);
            exit when not Ok;
            Carried := not Last;
            First_Host := L + 1;
         end;
      end loop;

      if Carried then
         declare
            Back : Boolean;
         begin
            D.Fetch_Carried (Item.Encoded.all (0 .. P * W - 1), Back);
            if not Back then
               Status := E.Make (E.Backend_Device_Refused);
            end if;
         end;
      end if;
      D.Attend_Exactly (Was_Exact);
   end Encoder_On_Device;

   --  What was heard, each decoder block's keys and values of it, made on
   --  the host and laid out a head at a time for a token decoded there;
   --  once a window, and only where one is (Cross_Host).
   procedure Ensure_Cross_Host (Item : in out Session; Status : in out E.Error_Info) is
      Source : constant Model_Access := Item.Source;
      P      : constant Element_Count := Source.Audio_Context;
      W      : constant Element_Count := Source.Width;
      Team   : constant Model_Runner.Shares.Team_Access := CPU.Sharing (Item.Team);
      Heads  : constant Positive := Source.Decoder_Heads;
      Head   : constant Element_Count := W / Element_Count (Heads);
      function Cross_Slot (Block, Which : Positive) return Positive is
        (2 + 6 * Source.Encoder_Blocks + 2 * (Block - 1) + Which);
   begin
      if Item.Cross_Host or else E.Is_Error (Status) then
         return;
      end if;
      for L in 1 .. Source.Decoder_Blocks loop
         Multiply_Many (Item, Item.Encoded, P, Source.Decoder (L).Cross.K.Weight, Item.Cross_K (L), null, Status,
                        Cross_Slot (L, 1));
         Multiply_Many (Item, Item.Encoded, P, Source.Decoder (L).Cross.V.Weight, Item.Cross_V (L),
                        Source.Decoder (L).Cross.V.Bias, Status, Cross_Slot (L, 2));
      end loop;
      for L in 1 .. Source.Decoder_Blocks loop
         for H in 1 .. Heads loop
            exit when E.Is_Error (Status);
            FP.Pack (Team, Item.Cross_K (L).all, Element_Count (H - 1) * Head, P, Head, W, 1,
                     Item.Cross_Keys ((L - 1) * Heads + H), Status);
            exit when E.Is_Error (Status);
            FP.Pack (Team, Item.Cross_V (L).all, Element_Count (H - 1) * Head, Head, P, 1, W,
                     Item.Cross_Values ((L - 1) * Heads + H), Status);
         end loop;
      end loop;
      Item.Cross_Host := E.Is_Ok (Status);
   end Ensure_Cross_Host;

   --  Each decoder block's keys and values of what was heard, made on the
   --  device from the encoder's answer and placed in the cache where its
   --  tokens attend to them, blocks at a time a sequence: a product of the
   --  keys, one of the values and the place step that biases the values as
   --  it puts both there, as a token puts its own (Feed_On_Device).
   procedure Cross_On_The_Device (Item : in out Session; Ok : out Boolean) is
      package D renames Model_Runner.Backend.Device;
      package P renames Model_Runner.Platform.Device.Products;
      Source : constant Model_Access := Item.Source;
      Count  : constant Element_Count := Source.Audio_Context;
      W      : constant Element_Count := Source.Width;
      Heads  : constant Positive := Source.Decoder_Heads;
      Head   : constant Element_Count := W / Element_Count (Heads);
      Pair   : constant Model_Runner.Bytes.Byte_Count := Model_Runner.Bytes.Byte_Count (2 * W * 4);
      --  Three steps a block, as many blocks as one sequence holds.
      Each_Run : constant Positive := Natural'Max (1, P.Sequence_Limit / 3);
      First  : Positive := 1;
      Status : E.Error_Info;
   begin
      Ok := False;
      if Item.Cross_Pairs = null then
         T.Allocate (Element_Count (Source.Decoder_Blocks) * 2 * W, Item.Cross_Pairs);
         if Item.Cross_Pairs = null then
            return;
         end if;
         for L in 1 .. Source.Decoder_Blocks loop
            declare
               At_Pair : constant Element_Count := Element_Count (L - 1) * 2 * W;
               Bias    : constant T.Real_Array_Access := Source.Decoder (L).Cross.V.Bias;
            begin
               Item.Cross_Pairs (At_Pair .. At_Pair + W - 1) := [others => 0.0];
               if Bias /= null then
                  Item.Cross_Pairs (At_Pair + W .. At_Pair + 2 * W - 1) := Bias.all;
               else
                  Item.Cross_Pairs (At_Pair + W .. At_Pair + 2 * W - 1) := [others => 0.0];
               end if;
            end;
         end loop;
      end if;

      while First <= Source.Decoder_Blocks loop
         declare
            Last  : constant Positive := Positive'Min (Source.Decoder_Blocks, First + Each_Run - 1);
            Steps : P.Sequence;
            Added : Boolean := True;
            Key, Value : Natural := 0;
         begin
            for L in First .. Last loop
               exit when not Added;
               D.Add_View_Product_At (Steps, Source.Decoder (L).Cross.K.Weight, 0, Added);
               Key := P.Length (Steps);
               if Added then
                  D.Add_View_Product_At (Steps, Source.Decoder (L).Cross.V.Weight, 0, Added);
                  Value := P.Length (Steps);
               end if;
               if Added then
                  P.Add_Heads (Steps, Key, Heads, Positive (Head), 0, P.Interleaved, System.Null_Address, 0, 0.0,
                               Added,
                               Weight => Item.Cross_Pairs (Element_Count (L - 1) * 2 * W)'Address,
                               Weight_Span => Pair,
                               Key => Item.Cross_Pairs (Element_Count (L - 1) * 2 * W)'Address,
                               Into_Cache => True,
                               At_First => Heard_Keys_At (Item, L), Stride => Natural (W),
                               V_Step => Value, V_At_First => Heard_Values_At (Item, L),
                               V_Stride => Natural (W), Kept => False, Bias_Width => Natural (2 * W),
                               V_Bias_At => Natural (W));
               end if;
            end loop;
            if not Added then
               return;
            end if;
            D.Run_Steps (Steps, Item.Encoded (0 .. Count * W - 1), Positive (Count), System.Null_Address, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            First := Last + 1;
         end;
      end loop;
      Ok := True;
   end Cross_On_The_Device;

   procedure Encode_Here
     (Item   : in out Session;
      Mel    : Real_Array;
      Status : out E.Error_Info)
   is
      Source : constant Model_Access := Item.Source;
      P2 : constant Element_Count := Window_Frames;
      P  : constant Element_Count := Source.Audio_Context;
      W  : constant Element_Count := Source.Width;
      M  : constant Element_Count := Element_Count (Source.Mels);
      F  : constant Element_Count := Source.Encoder_Feed;

      --  Where each matrix's panels are kept: the two convolutions, six a
      --  block, then two a decoder block.
      function Slot_Of (Block, Which : Positive) return Positive is (2 + 6 * (Block - 1) + Which);
      First_Host : Positive := 1;
   begin
      Status := E.Success;
      Item.Has_Encoded := False;
      Item.Held := 0;
      if Mel'Length /= M * P2 then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      --  The first convolution, width three, padding one: frame t reads
      --  frames t - 1 .. t + 1 of every filter, laid out as a row of
      --  filter-major triples, as the kernel's [out, in, 3] is.
      for Frame in 0 .. P2 - 1 loop
         for C in 0 .. M - 1 loop
            for Tap in Element_Count'(0) .. 2 loop
               Item.Work_A (Frame * 3 * M + C * 3 + Tap) :=
                 (if Frame + Tap >= 1 and then Frame + Tap - 1 < P2
                  then Mel (Mel'First + C * P2 + Frame + Tap - 1) else 0.0);
            end loop;
         end loop;
      end loop;
      Multiply_Many (Item, Item.Work_A, P2, Source.Conv1.Weight, Item.Work_B, Source.Conv1.Bias, Status, 1);
      Rows_Through (Item, Gaussian, Item.Work_B, P2, W, Status);

      --  The second, stride two: position t reads frames 2t - 1 .. 2t + 1.
      for Position in 0 .. P - 1 loop
         for C in 0 .. W - 1 loop
            for Tap in Element_Count'(0) .. 2 loop
               Item.Work_C (Position * 3 * W + C * 3 + Tap) :=
                 (if 2 * Position + Tap >= 1 and then 2 * Position + Tap - 1 < P2
                  then Item.Work_B ((2 * Position + Tap - 1) * W + C) else 0.0);
            end loop;
         end loop;
      end loop;
      Multiply_Many (Item, Item.Work_C, P, Source.Conv2.Weight, Item.Encoded, Source.Conv2.Bias, Status, 2);
      Rows_Through (Item, Gaussian, Item.Encoded, P, W, Status);
      Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Source.Audio_Positions);

      Encoder_On_Device (Item, First_Host, Status);

      for L in First_Host .. Source.Encoder_Blocks loop
         exit when E.Is_Error (Status);
         declare
            Each : Block renames Source.Encoder (L);
         begin
            Rows_Through (Item, Normalize, Item.Work_A, P, W, Status, Source => Item.Encoded,
                          Weight => Each.Attention_Norm.Weight, Bias => Each.Attention_Norm.Bias);
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.Q.Weight, Item.Work_B, Each.Attention.Q.Bias, Status,
                           Slot_Of (L, 1));
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.K.Weight, Item.Work_C, null, Status, Slot_Of (L, 2));
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.V.Weight, Item.Work_D, Each.Attention.V.Bias, Status,
                           Slot_Of (L, 3));
            Attend_Both_Ways (Item, Item.Work_B, Item.Work_C, Item.Work_D, Item.Work_E, Status);
            Multiply_Many (Item, Item.Work_E, P, Each.Attention.Output.Weight, Item.Work_A,
                           Each.Attention.Output.Bias, Status, Slot_Of (L, 4));
            Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Item.Work_A);

            Rows_Through (Item, Normalize, Item.Work_B, P, W, Status, Source => Item.Encoded,
                          Weight => Each.Feed_Norm.Weight, Bias => Each.Feed_Norm.Bias);
            Multiply_Many (Item, Item.Work_B, P, Each.Up.Weight, Item.Work_C, Each.Up.Bias, Status, Slot_Of (L, 5));
            Rows_Through (Item, Gaussian, Item.Work_C, P, F, Status);
            Multiply_Many (Item, Item.Work_C, P, Each.Down.Weight, Item.Work_A, Each.Down.Bias, Status, Slot_Of (L, 6));
            Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Item.Work_A);
         end;
      end loop;
      Rows_Through (Item, Normalize, Item.Work_A, P, W, Status, Source => Item.Encoded,
                    Weight => Source.Encoder_Norm.Weight, Bias => Source.Encoder_Norm.Bias);
      if E.Is_Error (Status) then
         return;
      end if;
      Item.Encoded (0 .. P * W - 1) := Item.Work_A (0 .. P * W - 1);

      --  Each decoder block's keys and values of what was heard, once: on the
      --  device straight into the cache where the turn is held, a token's
      --  blocks attending to them there. Made on the host and put there,
      --  they went to and fro -- 295 MB each way for Whisper medium's 24
      --  blocks, and their host layout beside -- 0.31 s of an 0.79 s window.
      Item.Cross_On_Device := False;
      Item.Self_On_Device := False;
      Item.Cross_Host := False;
      if Item.Borrowed and then E.Is_Ok (Status) then
         Cross_On_The_Device (Item, Item.Cross_On_Device);
      end if;
      if not Item.Cross_On_Device and then E.Is_Ok (Status) then
         Ensure_Cross_Host (Item, Status);
         if Item.Borrowed and then E.Is_Ok (Status) then
            declare
               Ok : Boolean := True;
            begin
               for L in 1 .. Source.Decoder_Blocks loop
                  exit when not Ok;
                  Model_Runner.Backend.Device.Put_Cache (Heard_Keys_At (Item, L), Item.Cross_K (L) (0 .. P * W - 1), Ok);
                  if Ok then
                     Model_Runner.Backend.Device.Put_Cache (Heard_Values_At (Item, L),
                                                            Item.Cross_V (L) (0 .. P * W - 1), Ok);
                  end if;
               end loop;
               Item.Cross_On_Device := Ok;
            end;
         end if;
      end if;
      Item.Has_Encoded := E.Is_Ok (Status);
   end Encode_Here;

   --  Every matrix, bias and norm the session may have put on the device,
   --  given back: the device knows each by where its bytes lie.
   procedure Forget_Matrices (Item : in out Session) is
      Source : constant Model_Access := Item.Source;

      procedure Drop (Weight : T.View) is
      begin
         if Weight.Rows > 0 then
            Model_Runner.Backend.Device.Forget (Weight);
         end if;
      end Drop;

      procedure Drop (Values : T.Real_Array_Access) is
      begin
         if Values /= null then
            Model_Runner.Backend.Device.Forget
              ((T.Empty_View with delta Base => Values.all (Values.all'First)'Address, Offset => 0));
         end if;
      end Drop;

      procedure Drop (Layer : Projection) is
      begin
         Drop (Layer.Weight);
         Drop (Layer.Bias);
      end Drop;
   begin
      Drop (Source.Conv1.Weight);
      Drop (Source.Conv2.Weight);
      --  Biases too: a block run whole (Encoder_On_Device) keeps them.
      for Each of Source.Encoder.all loop
         Drop (Each.Attention.Q);
         Drop (Each.Attention.K);
         Drop (Each.Attention.V);
         Drop (Each.Attention.Output);
         Drop (Each.Up);
         Drop (Each.Down);
      end loop;
      for Pairs of Item.Encoder_Pairs loop
         Drop (Pairs (1));
         Drop (Pairs (2));
      end loop;
      for Each of Source.Decoder.all loop
         Drop (Each.Attention.Q);
         Drop (Each.Attention.K);
         Drop (Each.Attention.V);
         Drop (Each.Attention.Output);
         Drop (Each.Cross.Q);
         Drop (Each.Cross.K);
         Drop (Each.Cross.V);
         Drop (Each.Cross.Output);
         Drop (Each.Up);
         Drop (Each.Down);
      end loop;
      Drop (Source.Token_Table);
      if Item.Cross_Pairs /= null then
         for L in 1 .. Source.Decoder_Blocks loop
            Model_Runner.Backend.Device.Forget
              ((T.Empty_View with delta
                  Base => Item.Cross_Pairs (Element_Count (L - 1) * 2 * Source.Width)'Address, Offset => 0));
         end loop;
      end if;
      if Item.Norm_Pairs /= null then
         for N_I in 0 .. 4 * Element_Count (Source.Decoder_Blocks) loop
            Model_Runner.Backend.Device.Forget
              ((T.Empty_View with delta
                  Base => Item.Norm_Pairs (N_I * 2 * Source.Width)'Address, Offset => 0));
         end loop;
      end if;
   end Forget_Matrices;

   --  The device's turn taken for what follows, where the session asks for
   --  the device, it is open and lent, and it has room beside the
   --  conversation's model; Took says whether this call took it, and
   --  Let_Go gives it back then. A call inside one that took it takes
   --  nothing.
   procedure Hold (Item : in out Session; Took : out Boolean) is
      use type Interfaces.Unsigned_64;
      Ok : Boolean;
   begin
      Took := False;
      if Item.Borrowed or else not Item.On_Device or else not Model_Runner.Backend.Device.Is_Ready
        or else Model_Runner.Backend.Device.Room_Beside < Interfaces.Unsigned_64 (Weight_Bytes (Item.Source.all))
      then
         return;
      end if;
      Model_Runner.Backend.Device.Borrow_Turn (Took);
      if not Took then
         return;
      end if;
      Item.Borrowed := True;
      Item.Halves_Were := Model_Runner.Backend.Device.Attends_In_Halves;
      --  Taken, it is given back on the way out of a fault here: the caller
      --  hears nothing of the taking then, a Boolean out not being copied
      --  back past an exception, and the conversation would wait for it.
      begin
         --  Past what the conversation may hold rows to. Each turn's part was
         --  once put past what the cache held -- its own part from the turn
         --  before among it -- so every transcription grew the cache by a part;
         --  then where it was, where the cache had not grown since, which the
         --  conversation's pages could have grown into meanwhile.
         Item.Cache_Base := Model_Runner.Backend.Device.Cache_Claimed;
         --  A token reads the half-precision copy of what was heard: its
         --  attention is the bytes it reads, and the copy is half of them.
         --  The conversation's choice is put back with the turn.
         Model_Runner.Backend.Device.Attend_In_Halves (True);
         Model_Runner.Backend.Device.Reserve_Cache (Cache_End (Item), Cache_End (Item), Ok, Scratch => True);
         --  Without the candidates' rows where there is no room for them: a
         --  window drawn again draws on the pool then.
         if not Ok and then Item.Wide > 0 then
            Item.Wide := 0;
            Model_Runner.Backend.Device.Reserve_Cache (Cache_End (Item), Cache_End (Item), Ok, Scratch => True);
         end if;
         if not Ok then
            Model_Runner.Backend.Device.Attend_In_Halves (Item.Halves_Were);
            Model_Runner.Backend.Device.Return_Turn;
            Item.Borrowed := False;
            Took := False;
         end if;
      exception
         when others =>
            Model_Runner.Backend.Device.Attend_In_Halves (Item.Halves_Were);
            Model_Runner.Backend.Device.Return_Turn;
            Item.Borrowed := False;
            raise;
      end;
   end Hold;

   procedure Let_Go (Item : in out Session; Took : Boolean) is
   begin
      if not Took then
         return;
      end if;
      if not Item.Keep_On_Device then
         Forget_Matrices (Item);
      end if;
      --  What the cache holds is the conversation's to overwrite now.
      Item.Cross_On_Device := False;
      Item.Self_On_Device := False;
      Model_Runner.Backend.Device.Attend_In_Halves (Item.Halves_Were);
      Model_Runner.Backend.Device.Return_Turn;
      Item.Borrowed := False;
   end Let_Go;

   --  On the device where the session asks for it and the turn is lent,
   --  and the device has room for the model beside the conversation's;
   --  else on the pool.
   procedure Encode
     (Item   : in out Session;
      Mel    : Real_Array;
      Status : out E.Error_Info)
   is
      Took : Boolean := False;
   begin
      Hold (Item, Took);
      Encode_Here (Item, Mel, Status);
      Let_Go (Item, Took);
   exception
      when others =>
         Let_Go (Item, Took);
         raise;
   end Encode;

   ------------------
   -- Copy_Encoded --
   ------------------

   procedure Copy_Encoded (Item : Session; Into : out Real_Array) is
   begin
      Into := Item.Encoded (0 .. Into'Length - 1);
   end Copy_Encoded;

   ----------
   -- Feed --
   ----------

   --  The decoder over Tokens, after the positions its cache holds; the
   --  logits at the last of them left in Item.Logits.
   ---------------------
   -- Feed_On_Device --
   ---------------------

   --  Count tokens through the decoder on the device, their embedded rows
   --  in Dec_X: a sequence a block, the activation carried from one to the
   --  next and never home, the keys and values of each position put in the
   --  block's part of the cache and attended to there, and what was heard
   --  attended to where Encode put it. Then the last norm and, for one
   --  token, the logits; for more, the rows come home and the last one's
   --  logits are the pool's, as Feed makes them.
   procedure Feed_On_Device
     (Item   : in out Session;
      Count  : Element_Count;
      Status : out E.Error_Info;
      Fold   : Boolean;
      Drawn  : Boolean := False;
      At_Position : Element_Count := 0)
   is
      package D renames Model_Runner.Backend.Device;
      package P renames Model_Runner.Platform.Device.Products;
      Source : constant Model_Access := Item.Source;
      W      : constant Element_Count := Source.Width;
      Heads  : constant Natural := Source.Decoder_Heads;
      Head   : constant Element_Count := W / Element_Count (Heads);
      Scale  : constant Real := Real (1.0 / Elementary.Sqrt (Wide_Real (Head)));
      Pair   : constant Model_Runner.Bytes.Byte_Count := Model_Runner.Bytes.Byte_Count (2 * W * 4);
      Steps  : P.Sequence;
      Added  : Boolean := True;

      function Pair_At (Index : Element_Count) return System.Address is
        (Item.Norm_Pairs (Index * 2 * W)'Address);

      --  Where a block's keys' and values' biases lie, past the norms.
      function Biases_At (Block : Positive) return Element_Count is
        ((3 * Element_Count (Source.Decoder_Blocks) + 1 + Element_Count (Block - 1)) * 2 * W);

      --  The session's own positions, a row a width; or, Drawn, the
      --  candidates' rows, Count widths, row r of the batch candidate r's.
      Place     : constant Element_Count := (if Drawn then At_Position else Item.Held);
      Row_Width : constant Element_Count := (if Drawn then Count * W else W);

      function Keys_At (Block : Positive) return Element_Count is
        (if Drawn then Wide_Keys_At (Item, Block) else Own_Keys_At (Item, Block));

      function Values_At (Block : Positive) return Element_Count is
        (if Drawn then Wide_Values_At (Item, Block) else Own_Values_At (Item, Block));

      --  The step reading Step biased, where the projection has a bias:
      --  added in the product's own store where it may be (Fold).
      procedure Biased (Bias : T.Real_Array_Access; Step : in out Natural; Into_Product : Boolean := False) is
      begin
         if Added and then Bias /= null then
            P.Add_Bias (Steps, Bias.all (Bias.all'First)'Address, Model_Runner.Bytes.Byte_Count (Bias.all'Length) * 4,
                        0, 1, Bias.all'Length, Step, 0, Added, Key => Bias.all (Bias.all'First)'Address,
                        Kept => False, Fold => Into_Product and then Fold);
            Step := P.Length (Steps);
         end if;
      end Biased;

      --  A projection of step From, biased; its step.
      function Projected (Layer : Projection; From : Natural) return Natural is
         Step : Natural := 0;
      begin
         if Added then
            D.Add_View_Product (Steps, Layer.Weight, From, Added);
            Step := P.Length (Steps);
            Biased (Layer.Bias, Step, Into_Product => True);
         end if;
         return Step;
      end Projected;

      function Normed (Index : Element_Count; From : Natural; Kept : Boolean := False) return Natural is
      begin
         if Added then
            P.Add_Norm (Steps, Pair_At (Index), Pair, 0, Natural (W), Source.Epsilon, Added, From_Step => From,
                        Key => Pair_At (Index), Kept => Kept, Shift => True);
         end if;
         return P.Length (Steps);
      end Normed;
   begin
      Status := E.Success;
      if Item.Norm_Pairs = null then
         T.Allocate ((4 * Element_Count (Source.Decoder_Blocks) + 1) * 2 * W, Item.Norm_Pairs);
         if Item.Norm_Pairs = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         declare
            procedure Put (Index : Element_Count; Of_Norm : Norm) is
            begin
               Item.Norm_Pairs (Index * 2 * W .. Index * 2 * W + W - 1) := Of_Norm.Weight.all;
               Item.Norm_Pairs (Index * 2 * W + W .. (Index + 1) * 2 * W - 1) := Of_Norm.Bias.all;
            end Put;
         begin
            for L in 1 .. Source.Decoder_Blocks loop
               Put (3 * Element_Count (L - 1), Source.Decoder (L).Attention_Norm);
               Put (3 * Element_Count (L - 1) + 1, Source.Decoder (L).Cross_Norm);
               Put (3 * Element_Count (L - 1) + 2, Source.Decoder (L).Feed_Norm);
            end loop;
            Put (3 * Element_Count (Source.Decoder_Blocks), Source.Decoder_Norm);
            for L in 1 .. Source.Decoder_Blocks loop
               declare
                  At_Pair : constant Element_Count := Biases_At (L);
                  Values  : constant T.Real_Array_Access := Source.Decoder (L).Attention.V.Bias;
               begin
                  Item.Norm_Pairs (At_Pair .. At_Pair + W - 1) := [others => 0.0];
                  if Values = null then
                     Item.Norm_Pairs (At_Pair + W .. At_Pair + 2 * W - 1) := [others => 0.0];
                  else
                     Item.Norm_Pairs (At_Pair + W .. At_Pair + 2 * W - 1) := Values.all;
                  end if;
               end;
            end loop;
         end;
      end if;

      for L in 1 .. Source.Decoder_Blocks loop
         declare
            Each : Block renames Source.Decoder (L);
            First : constant Element_Count := 3 * Element_Count (L - 1);
            Norm_1, Query, Key, Value, Mixed, Out_1, Join_1 : Natural := 0;
            Norm_2, Asked, Heard, Out_2, Join_2 : Natural := 0;
            Norm_3, Up, Gelu, Down : Natural := 0;
            Before_2, Before_3 : Natural := 0;
         begin
            P.Open_Sequence (Steps);
            Added := True;
            Norm_1 := Normed (First, 0);
            Query := Projected (Each.Attention.Q, Norm_1);
            --  The keys and values, biased and put in the cache in one
            --  step, neither turned nor normalized.
            if Added then
               D.Add_View_Product (Steps, Each.Attention.K.Weight, Norm_1, Added);
               Key := P.Length (Steps);
            end if;
            if Added then
               D.Add_View_Product (Steps, Each.Attention.V.Weight, Norm_1, Added);
               Value := P.Length (Steps);
            end if;
            if Added then
               P.Add_Heads (Steps, Key, Heads, Positive (Head), 0, P.Interleaved, System.Null_Address, 0, 0.0, Added,
                            Weight => Item.Norm_Pairs (Biases_At (L))'Address, Weight_Span => Pair,
                            Key => Item.Norm_Pairs (Biases_At (L))'Address, Into_Cache => True,
                            At_First => Keys_At (L) + Place * Row_Width, Stride => Natural (W),
                            V_Step => Value, V_At_First => Values_At (L) + Place * Row_Width,
                            V_Stride => Natural (W), Kept => False, Bias_Width => Natural (2 * W),
                            V_Bias_At => Natural (W));
            end if;
            if Added then
               P.Add_Attention (Steps, Heads, Natural (Head), Natural (Head), 1, 0, Natural (Place),
                                Keys_At (L), Values_At (L), Natural (Row_Width), Natural (Row_Width), Scale, 0.0,
                                Added, Chained => True, Causal => True, Kept => False, From_Step => Query,
                                Rows_As_Heads => Drawn);
               Mixed := P.Length (Steps);
            end if;
            Out_1 := Projected (Each.Attention.Output, Mixed);
            if Added then
               P.Add_Join (Steps, Added, From_Step => Out_1, From_Vector => 0, Kept => False);
               Join_1 := P.Length (Steps);
            end if;

            Norm_2 := Normed (First + 1, Join_1);
            Asked := Projected (Each.Cross.Q, Norm_2);
            if Added then
               P.Add_Attention (Steps, Heads, Natural (Head), Natural (Head), 1, 0,
                                Natural (Source.Audio_Context - 1), Heard_Keys_At (Item, L), Heard_Values_At (Item, L),
                                Natural (W), Natural (W), Scale, 0.0, Added, Chained => True, Causal => False,
                                Kept => False, From_Step => Asked);
               Heard := P.Length (Steps);
            end if;
            --  The bias added to the residual rather than to the
            --  product, so that the join folds into the product's store:
            --  one dispatch where there were two.
            Before_2 := Join_1;
            Biased (Each.Cross.Output.Bias, Before_2);
            if Added then
               D.Add_View_Product (Steps, Each.Cross.Output.Weight, Heard, Added);
               Out_2 := P.Length (Steps);
            end if;
            if Added then
               P.Add_Join (Steps, Added, From_Step => Out_2, Residual_Step => Before_2, Kept => False);
               Join_2 := P.Length (Steps);
            end if;

            --  And the projection down's bias added to its residual.
            Before_3 := Join_2;
            Biased (Each.Down.Bias, Before_3);
            Norm_3 := Normed (First + 2, Join_2);
            Up := Projected (Each.Up, Norm_3);
            if Added then
               --  The Gaussian unit in its error function form, as the
               --  processor's and the reference's are; alone, both its arms
               --  named as the one step.
               P.Add_Combination (Steps, 10, Added, Kept => False, From_Step => Up, Other_Step => Up);
               Gelu := P.Length (Steps);
            end if;
            if Added then
               D.Add_View_Product (Steps, Each.Down.Weight, Gelu, Added);
               Down := P.Length (Steps);
            end if;
            if Added then
               P.Add_Join (Steps, Added, From_Step => Down, Residual_Step => Before_3, Kept => False);
            end if;
            if not Added then
               Status := E.Make (E.Backend_Capability_Missing);
               E.Add_Text (Status, "capability", "whisper decoder block", E.Param_Identifier);
               E.Add_Text (Status, "backend", "device", E.Param_Identifier);
               return;
            end if;
            D.Run_Steps (Steps, Item.Dec_X (0 .. Count * W - 1), Positive (Count), System.Null_Address, Status,
                         Carry_In => L > 1, Carry_Out => True);
            if E.Is_Error (Status) then
               return;
            end if;
         end;
      end loop;

      P.Open_Sequence (Steps);
      Added := True;
      if Count = 1 or else Drawn then
         --  Every row's logits, one token's or each candidate's.
         declare
            Last : constant Natural := Normed (3 * Element_Count (Source.Decoder_Blocks), 0);
            Into : constant System.Address :=
              (if Drawn then Item.Candidate_Logits (0)'Address else Item.Logits (0)'Address);
         begin
            if Added then
               D.Add_View_Product (Steps, Source.Token_Table, Last, Added, Kept => True);
            end if;
            if Added then
               D.Run_Steps (Steps, Item.Dec_X (0 .. Count * W - 1), Positive (Count), Into, Status,
                            Carry_In => True);
            end if;
         end;
      else
         declare
            Last : constant Natural := Normed (3 * Element_Count (Source.Decoder_Blocks), 0, Kept => True);
            pragma Unreferenced (Last);
         begin
            if Added then
               D.Run_Steps (Steps, Item.Dec_X (0 .. Count * W - 1), Positive (Count), Item.Dec_H (0)'Address, Status,
                            Carry_In => True);
            end if;
            if Added and then E.Is_Ok (Status) then
               Item.Last_Row.all := Item.Dec_H ((Count - 1) * W .. Count * W - 1);
               CPU.Dispatch (Item.Team, Source.Token_Table, Item.Last_Row, Item.Logits, Status,
                             Roles => CPU.Every_Role);
            end if;
         end;
      end if;
      if not Added then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "whisper decoder head", E.Param_Identifier);
         E.Add_Text (Status, "backend", "device", E.Param_Identifier);
      end if;
   end Feed_On_Device;

   --  The decoder's own keys and values brought home from the device, for
   --  the pool to go on from.
   procedure Bring_Home (Item : in out Session; Status : in out E.Error_Info) is
      W  : constant Element_Count := Item.Source.Width;
      Ok : Boolean := True;
   begin
      for L in 1 .. Item.Source.Decoder_Blocks loop
         exit when not Ok;
         Model_Runner.Backend.Device.Get_Cache (Own_Keys_At (Item, L), Item.Self_K (L) (0 .. Item.Held * W - 1), Ok);
         if Ok then
            Model_Runner.Backend.Device.Get_Cache
              (Own_Values_At (Item, L), Item.Self_V (L) (0 .. Item.Held * W - 1), Ok);
         end if;
      end loop;
      if not Ok then
         Status := E.Make (E.Backend_Closed);
      end if;
      Item.Self_On_Device := False;
   end Bring_Home;

   --  Which candidate each row of a batch of candidates is.
   type Slot_List is array (Positive range <>) of Positive;
   No_Slots : constant Slot_List (1 .. 0) := [others => 1];

   --  Tokens through the decoder: the session's next positions, or, with
   --  Slots, one token a candidate, every one at position At_Position,
   --  each attending to its own keys and values (Candidate_K, _V), and
   --  every row's logits made (Candidate_Logits), the session's own
   --  positions left as they were.
   procedure Feed
     (Item        : in out Session;
      Tokens      : Tk.Token_Array;
      Status      : out E.Error_Info;
      Slots       : Slot_List := No_Slots;
      At_Position : Element_Count := 0)
   is
      Source : constant Model_Access := Item.Source;
      W      : constant Element_Count := Source.Width;
      Count  : constant Element_Count := Tokens'Length;
      Heads  : constant Element_Count := Element_Count (Source.Decoder_Heads);
      Head   : constant Element_Count := W / Heads;
      Scale  : constant Real := Real (1.0 / Elementary.Sqrt (Wide_Real (Head)));
      Work   : aliased Head_Work;
   begin
      Status := E.Success;
      if not Item.Has_Encoded then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;
      if Count = 0 or else (if Slots'Length > 0 then At_Position + 1 else Item.Held + Count) > Source.Text_Context
        or else (Slots'Length > 0 and then Slots'Length /= Tokens'Length)
      then
         Status := E.Make (E.Generation_Prompt_Too_Long);
         E.Add_Integer (Status, "count", Long_Long_Integer (Item.Held + Count));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Source.Text_Context));
         return;
      end if;
      for T_I in Tokens'Range loop
         if Tokens (T_I) < 0 or else Element_Count (Tokens (T_I)) >= Source.Vocabulary_Size then
            Status := E.Make (E.Tokenizer_Invalid_Token_Id);
            return;
         end if;
      end loop;

      for I in 0 .. Count - 1 loop
         T.Dequantize_Row (Source.Token_Table, Element_Count (Tokens (Tokens'First + Natural (I))),
                           Item.Dec_X (I * W .. (I + 1) * W - 1), Status);
         exit when E.Is_Error (Status);
         declare
            Place : constant Element_Count := (if Slots'Length > 0 then At_Position else Item.Held + I);
         begin
            K.Add (Item.Dec_X (I * W .. (I + 1) * W - 1), Source.Text_Positions (Place * W .. (Place + 1) * W - 1));
         end;
      end loop;

      --  On the device where what was heard is there and the positions
      --  before are too; where it declines, the pool goes on from the same
      --  place.
      if Slots'Length = 0 and then Item.Borrowed and then Item.Cross_On_Device and then not Item.Capturing
        and then (Item.Held = 0 or else Item.Self_On_Device)
      then
         --  A token's biases in its products' stores; where the device
         --  refuses that, the token again with them named apart.
         Feed_On_Device (Item, Count, Status, Fold => Count = 1 and then not Item.Folds_Refused);
         if E.Is_Error (Status) and then Count = 1 and then not Item.Folds_Refused then
            --  Refused for the folds only where it runs without them: a
            --  device that refuses both has not said the folds were why.
            Feed_On_Device (Item, Count, Status, Fold => False);
            Item.Folds_Refused := E.Is_Ok (Status);
         end if;
         if E.Is_Ok (Status) then
            Item.Device_Fed := Item.Device_Fed + Natural (Count);
            Item.Held := Item.Held + Count;
            Item.Self_On_Device := True;
            return;
         end if;
         Status := E.Success;
         Item.Cross_On_Device := False;
      end if;
      if Item.Self_On_Device then
         Bring_Home (Item, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;
      --  What was heard laid out for the host, where it was put straight
      --  into the device's cache.
      Ensure_Cross_Host (Item, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Work.Width := W;
      Work.Head := Head;
      Work.Count := Count;
      Work.Scale := Scale;
      Work.Scores := Item.Dec_Scores;
      Work.Score_Stride := Source.Audio_Context;
      Work.Output := Item.Dec_A;
      Work.Queries := Item.Dec_Q;

      for L in 1 .. Source.Decoder_Blocks loop
         exit when E.Is_Error (Status);
         declare
            Each : Block renames Source.Decoder (L);
         begin
            Rows_Through (Item, Normalize, Item.Dec_H, Count, W, Status, Source => Item.Dec_X,
                          Weight => Each.Attention_Norm.Weight, Bias => Each.Attention_Norm.Bias);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Attention.Q.Weight, Item.Dec_Q, Each.Attention.Q.Bias, Status);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Attention.K.Weight, Item.Dec_K, null, Status);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Attention.V.Weight, Item.Dec_V, Each.Attention.V.Bias, Status);
            exit when E.Is_Error (Status);
            if Slots'Length = 0 then
               Item.Self_K (L) (Item.Held * W .. (Item.Held + Count) * W - 1) := Item.Dec_K (0 .. Count * W - 1);
               Item.Self_V (L) (Item.Held * W .. (Item.Held + Count) * W - 1) := Item.Dec_V (0 .. Count * W - 1);
               Work.Keys := Item.Self_K (L);
               Work.Values := Item.Self_V (L);
               Work.Before := Item.Held;
               Work.Causal := True;
               CPU.Dispatch_Shares (Item.Team, Heads, Work'Unchecked_Access, Status,
                                    Cost => Count * (Item.Held + Count) * W);
            else
               --  A row a candidate, each to its own positions.
               for R in 0 .. Count - 1 loop
                  exit when E.Is_Error (Status);
                  declare
                     Room : constant Positive :=
                       (Slots (Slots'First + Natural (R)) - 1) * Source.Decoder_Blocks + L;
                     Row  : constant Element_Count := R * W;
                  begin
                     Item.Candidate_K (Room) (At_Position * W .. (At_Position + 1) * W - 1) :=
                       Item.Dec_K (Row .. Row + W - 1);
                     Item.Candidate_V (Room) (At_Position * W .. (At_Position + 1) * W - 1) :=
                       Item.Dec_V (Row .. Row + W - 1);
                     Item.Candidate_Query.all := Item.Dec_Q (Row .. Row + W - 1);
                     Work.Queries := Item.Candidate_Query;
                     Work.Output := Item.Candidate_Blend;
                     Work.Count := 1;
                     Work.Keys := Item.Candidate_K (Room);
                     Work.Values := Item.Candidate_V (Room);
                     Work.Before := At_Position;
                     Work.Causal := True;
                     CPU.Dispatch_Shares (Item.Team, Heads, Work'Unchecked_Access, Status,
                                          Cost => (At_Position + 1) * W);
                     Item.Dec_A (Row .. Row + W - 1) := Item.Candidate_Blend.all;
                  end;
               end loop;
               Work.Queries := Item.Dec_Q;
               Work.Output := Item.Dec_A;
               Work.Count := Count;
            end if;
            Multiply_Few (Item, Item.Dec_A, Count, Each.Attention.Output.Weight, Item.Dec_H,
                          Each.Attention.Output.Bias, Status);
            Rows_Through (Item, Accumulate, Item.Dec_X, Count, W, Status, Source => Item.Dec_H);

            Rows_Through (Item, Normalize, Item.Dec_H, Count, W, Status, Source => Item.Dec_X,
                          Weight => Each.Cross_Norm.Weight, Bias => Each.Cross_Norm.Bias);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Cross.Q.Weight, Item.Dec_Q, Each.Cross.Q.Bias, Status);
            exit when E.Is_Error (Status);
            declare
               Across : aliased Cross_Work;
            begin
               Across.Owner := Item'Unchecked_Access;
               Across.Block := L;
               Across.Count := Count;
               Across.Scale := Scale;
               CPU.Dispatch_Shares (Item.Team, Heads, Across'Unchecked_Access, Status,
                                    Cost => Count * Source.Audio_Context * W);
               if E.Is_Ok (Status) and then Across.Failed then
                  Status := E.Make (E.Sampling_Non_Finite_Logit);
               end if;
            end;
            Multiply_Few (Item, Item.Dec_A, Count, Each.Cross.Output.Weight, Item.Dec_H, Each.Cross.Output.Bias,
                          Status);
            Rows_Through (Item, Accumulate, Item.Dec_X, Count, W, Status, Source => Item.Dec_H);

            Rows_Through (Item, Normalize, Item.Dec_H, Count, W, Status, Source => Item.Dec_X,
                          Weight => Each.Feed_Norm.Weight, Bias => Each.Feed_Norm.Bias);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Up.Weight, Item.Dec_F, Each.Up.Bias, Status);
            Rows_Through (Item, Gaussian, Item.Dec_F, Count, Source.Decoder_Feed, Status);
            Multiply_Few (Item, Item.Dec_F, Count, Each.Down.Weight, Item.Dec_H, Each.Down.Bias, Status);
            Rows_Through (Item, Accumulate, Item.Dec_X, Count, W, Status, Source => Item.Dec_H);
         end;
      end loop;
      if E.Is_Error (Status) then
         return;
      end if;
      if Slots'Length > 0 then
         --  Every candidate's logits, the table read once for them all.
         for R in 0 .. Count - 1 loop
            K.Layer_Norm (Item.Dec_X (R * W .. (R + 1) * W - 1), Source.Decoder_Norm.Weight.all,
                          Source.Decoder_Norm.Bias.all, Source.Epsilon, Item.Dec_H (R * W .. (R + 1) * W - 1));
         end loop;
         CPU.Dispatch_Batch (Item.Team, Source.Token_Table, Item.Dec_H, Count, Item.Candidate_Logits, Status,
                             Roles => CPU.Every_Role);
         return;
      end if;
      Item.Held := Item.Held + Count;

      K.Layer_Norm (Item.Dec_X ((Count - 1) * W .. Count * W - 1), Source.Decoder_Norm.Weight.all,
                    Source.Decoder_Norm.Bias.all, Source.Epsilon, Item.Last_Row.all);
      CPU.Dispatch (Item.Team, Source.Token_Table, Item.Last_Row, Item.Logits, Status, Roles => CPU.Every_Role);
   end Feed;

   ------------
   -- Decode --
   ------------

   procedure Decode
     (Item   : in out Session;
      Tokens : Tk.Token_Array;
      Logits : out Real_Array;
      Status : out E.Error_Info)
   is
      Took : Boolean := False;
   begin
      Hold (Item, Took);
      Item.Held := 0;
      Item.Self_On_Device := False;
      Feed (Item, Tokens, Status);
      if E.Is_Ok (Status) then
         Logits := Item.Logits (0 .. Logits'Length - 1);
      end if;
      Let_Go (Item, Took);
   exception
      when others =>
         Let_Go (Item, Took);
         raise;
   end Decode;

   ----------------
   -- Transcribe --
   ----------------

   --  Tokens a window may be prompted with, after <|startofprev|>: the
   --  reference's n_text_ctx / 2 - 1.
   function Prompt_Room (Item : Model) return Natural is (Natural (Item.Text_Context) / 2 - 1);

   package Token_Vectors is new Ada.Containers.Vectors (Positive, Token_Id);
   package Count_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   type Cost_Access is access Timing.Cost_Matrix;
   procedure Free is new Ada.Unchecked_Deallocation (Timing.Cost_Matrix, Cost_Access);

   --  Python's round (X, 2): to the nearest hundredth, a half to even.
   function Hundredths (X : Real) return Real is
     (Real (Wide_Real'Unbiased_Rounding (Wide_Real (X) * 100.0) / 100.0));

   --  Python's `Part in Whole` for strings: Part is somewhere in Whole, the
   --  empty string being everywhere.
   function Within (Part, Whole : String) return Boolean is
     (Part = "" or else Ada.Strings.Fixed.Index (Whole, Part) > 0);

   --  string.punctuation, and the reference's marks that join the word
   --  before or after them.
   Punctuation : constant String := "!""#$%&'()*+,-./:;<=>?@[\]^_`{|}~";
   Prepended   : constant String :=
     """'" & Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#9C#)
     & Character'Val (16#C2#) & Character'Val (16#BF#) & "([{-";
   Appended    : constant String :=
     """'." & Character'Val (16#E3#) & Character'Val (16#80#) & Character'Val (16#82#)
     & "," & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#8C#)
     & "!" & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#81#)
     & "?" & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#9F#)
     & ":" & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#9A#)
     & Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#9D#)
     & ")]}" & Character'Val (16#E3#) & Character'Val (16#80#) & Character'Val (16#81#);
   Sentence_Ends : constant String :=
     "." & Character'Val (16#E3#) & Character'Val (16#80#) & Character'Val (16#82#)
     & "!" & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#81#)
     & "?" & Character'Val (16#EF#) & Character'Val (16#BC#) & Character'Val (16#9F#);

   procedure Transcribe_Here
     (Item     : in out Session;
      Samples  : Real_Array;
      Settings : Options;
      Result   : out Transcript;
      Status   : out E.Error_Info;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null)
   is
      use type Ada.Calendar.Time;

      Source  : constant Model_Access := Item.Source;
      Mel     : T.Real_Array_Access;
      Window  : T.Real_Array_Access;
      Frames  : Element_Count;
      Content : Element_Count;
      Seek    : Element_Count := 0;
      --  Whether the language's encode was of the first window as it is
      --  transcribed, and stands for it.
      First_Heard : Boolean := False;
      Language : Token_Id := 0;
      --  Every token the windows decoded, the initial prompt's first.
      All_Tokens : Token_Vectors.Vector;
      Reset_Since : Natural := 0;
      --  The temperature the last window was decoded at: past a half, the
      --  reference prompts the next with nothing before it.
      Last_Temperature : Real := 0.0;
      Draws : Decoding.Stream := Decoding.Seeded (Settings.Seed);
      Rules : Model_Runner.Whisper.Decoding.Rules;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Mels : constant Element_Count := (if Source = null then 0 else Element_Count (Source.Mels));

      function I_Of (Token : Token_Id) return Positive is (Natural (Token - Source.First_Language) + 1);

      function Cancelled return Boolean is
        (Cancel /= null and then Model_Runner.Cancellation.Is_Cancelled (Cancel));

      procedure Release is
      begin
         T.Free (Mel);
         T.Free (Window);
      end Release;

      --  Window of Size frames from Seek, zeros after it to 3,000.
      procedure Take_Window (From, Size : Element_Count) is
      begin
         for C in 0 .. Mels - 1 loop
            for F in Element_Count'(0) .. Window_Frames - 1 loop
               Window (C * Window_Frames + F) := (if F < Size then Mel (C * Frames + From + F) else 0.0);
            end loop;
         end loop;
      end Take_Window;

      function Text_Of (Tokens : Token_Vectors.Vector; From, To : Natural) return String is
         Count : Natural := 0;
      begin
         for I in From .. To loop
            if Tokens (I) < Source.End_Of_Text then
               Count := Count + 1;
            end if;
         end loop;
         declare
            Text_Tokens : Tk.Token_Array (1 .. Count);
            Index : Natural := 0;
         begin
            for I in From .. To loop
               if Tokens (I) < Source.End_Of_Text then
                  Index := Index + 1;
                  Text_Tokens (Index) := Tokens (I);
               end if;
            end loop;
            --  As the reference decodes, errors replaced: a byte that is
            --  no part of a character becomes U+FFFD.
            return Model_Runner.UTF8.Repaired (Tk.Decode (Source.Vocabulary, Text_Tokens));
         end;
      end Text_Of;

      --  Where the last word before this window ended, as the reference
      --  keeps it across windows.
      Last_Speech : Real := 0.0;

      --  The reference's word timing for one window's segments
      --  (timing.find_alignment and add_word_timestamps): the decoder over
      --  the start of the transcript, <|notimestamps|>, the window's text
      --  tokens and the end, the alignment heads' scores kept; the cost
      --  warped; the tokens cut into words; long words held to twice the
      --  median; punctuation joined to its word; and the words dealt to the
      --  segments, whose ends move to their words'.
      procedure Time_Words
        (Text_Tokens : Token_Vectors.Vector;
         Lengths     : Count_Vectors.Vector;
         First       : Positive;
         Frames      : Element_Count;
         Offset      : Real)
      is
         Sot_Length : constant Natural := (if Source.Multilingual then 3 else 1);
         Texts      : constant Natural := Natural (Text_Tokens.Length);
         Count      : constant Natural := Sot_Length + 1 + Texts + 1;
         Tokens     : Tk.Token_Array (1 .. Count);
         P          : constant Element_Count := Source.Audio_Context;
         W          : constant Element_Count := Source.Width;
         Heard      : constant Positive := Positive'Max (1, Natural (Frames / 2));
         Probability : array (1 .. Texts) of Wide_Real := [others => 0.0];
         --  When each text token was first looked at, in seconds; the
         --  end's as the last.
         Jump : array (0 .. Texts) of Real := [others => 0.0];

         type Timed is record
            Text          : Unbounded_String;
            Tokens        : Natural := 0;
            Start, Finish : Real := 0.0;
            Likely        : Wide_Real := 0.0;
         end record;
         package Timed_Vectors is new Ada.Containers.Vectors (Positive, Timed);
         Words : Timed_Vectors.Vector;
      begin
         if Texts = 0 then
            return;
         end if;
         Tokens (1) := Source.Start_Of_Transcript;
         if Source.Multilingual then
            Tokens (2) := Language;
            Tokens (3) := (if Settings.Translate then Source.Translate_Token else Source.Transcribe_Token);
         end if;
         Tokens (Sot_Length + 1) := Source.No_Timestamps;
         for I in 1 .. Texts loop
            Tokens (Sot_Length + 1 + I) := Text_Tokens (I);
         end loop;
         Tokens (Count) := Source.End_Of_Text;

         if Item.Captured = null then
            T.Allocate (Element_Count (Source.Alignment_Count) * Source.Text_Context * P, Item.Captured);
            if Item.Captured = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
         end if;
         Item.Held := 0;
         Item.Capturing := True;
         Feed (Item, Tokens, Status);
         Item.Capturing := False;
         if E.Is_Error (Status) then
            return;
         end if;

         --  Each text token's probability where it was said.
         for Index in 0 .. Texts - 1 loop
            exit when E.Is_Error (Status);
            declare
               Row : constant Element_Count := Element_Count (Sot_Length + Index);
            begin
               K.Layer_Norm (Item.Dec_X (Row * W .. (Row + 1) * W - 1), Source.Decoder_Norm.Weight.all,
                             Source.Decoder_Norm.Bias.all, Source.Epsilon, Item.Last_Row.all);
               CPU.Dispatch (Item.Team, Source.Token_Table, Item.Last_Row, Item.Logits, Status,
                             Roles => CPU.Every_Role);
               Probability (Index + 1) :=
                 Decoding.Probability (Item.Logits (0 .. Source.Vocabulary_Size - 1), Text_Tokens (Index + 1));
            end;
         end loop;
         if E.Is_Error (Status) then
            return;
         end if;

         --  The cost, warped.
         declare
            All_Rows : Cost_Access := new Timing.Cost_Matrix (0 .. Count - 1, 0 .. Heard - 1);
            Cost     : Cost_Access := new Timing.Cost_Matrix (0 .. Texts, 0 .. Heard - 1);
            Rows_Of, Columns_Of : Timing.Index_List (1 .. Texts + 1 + Heard);
            Steps : Natural;
            Next  : Natural := 0;
         begin
            Timing.Weights (Item.Captured (0 .. Element_Count (Source.Alignment_Count * Count) * P - 1),
                            Source.Alignment_Count, Count, Heard, Positive (P), All_Rows.all);
            for R in 0 .. Texts loop
               for F in 0 .. Heard - 1 loop
                  Cost (R, F) := -All_Rows (Sot_Length + R, F);
               end loop;
            end loop;
            Timing.Warp (Cost.all, Rows_Of, Columns_Of, Steps);
            for K in 1 .. Steps loop
               if K = 1 or else Rows_Of (K) /= Rows_Of (K - 1) then
                  if Next <= Texts then
                     Jump (Next) := Real (Columns_Of (K)) / 50.0;
                  end if;
                  Next := Next + 1;
               end if;
            end loop;
            Free (All_Rows);
            Free (Cost);
         end;

         --  Cut into words: tokens joined until they are whole characters,
         --  and pieces joined unless one begins with a space or is
         --  punctuation; the end of text is a word of its own, and dropped.
         declare
            Piece  : Unbounded_String;
            Pieces : Natural := 0;
            Bound  : Natural := 0;
            Likely : Wide_Real := 0.0;
         begin
            for I in 1 .. Texts loop
               Append (Piece, Tk.Decode (Source.Vocabulary, [1 => Text_Tokens (I)]));
               Pieces := Pieces + 1;
               Likely := Likely + Probability (I);
               if Model_Runner.UTF8.Is_Valid (To_String (Piece)) then
                  declare
                     Said  : constant String := To_String (Piece);
                     Start : constant Boolean :=
                       Words.Is_Empty or else (Said'Length > 0 and then Said (Said'First) = ' ')
                       or else Within (Ada.Strings.Fixed.Trim (Said, Ada.Strings.Both), Punctuation);
                  begin
                     if Start then
                        Words.Append (Timed'(To_Unbounded_String (Said), Pieces, 0.0, 0.0, Likely));
                     else
                        declare
                           Last : Timed := Words.Last_Element;
                        begin
                           Append (Last.Text, Said);
                           Last.Tokens := Last.Tokens + Pieces;
                           Last.Likely := Last.Likely + Likely;
                           Words.Replace_Element (Words.Last_Index, Last);
                        end;
                     end if;
                  end;
                  Piece := Null_Unbounded_String;
                  Pieces := 0;
                  Likely := 0.0;
               end if;
            end loop;
            for I in Words.First_Index .. Words.Last_Index loop
               declare
                  Each : Timed := Words (I);
               begin
                  Each.Start := Jump (Bound);
                  Bound := Bound + Each.Tokens;
                  Each.Finish := Jump (Natural'Min (Bound, Texts));
                  Each.Likely := Each.Likely / Wide_Real (Natural'Max (1, Each.Tokens));
                  Words.Replace_Element (I, Each);
               end;
            end loop;
         end;

         --  Long words held to twice the median, at a sentence's edge.
         declare
            Durations : array (1 .. Natural (Words.Length)) of Real;
            Kept      : Natural := 0;
            Median    : Real := 0.0;
         begin
            for Each of Words loop
               if Each.Finish - Each.Start /= 0.0 then
                  Kept := Kept + 1;
                  Durations (Kept) := Each.Finish - Each.Start;
               end if;
            end loop;
            if Kept > 0 then
               for I in 2 .. Kept loop
                  declare
                     V : constant Real := Durations (I);
                     J : Natural := I - 1;
                  begin
                     while J >= 1 and then Durations (J) > V loop
                        Durations (J + 1) := Durations (J);
                        J := J - 1;
                     end loop;
                     Durations (J + 1) := V;
                  end;
               end loop;
               Median := (if Kept mod 2 = 1 then Durations (Kept / 2 + 1)
                          else (Durations (Kept / 2) + Durations (Kept / 2 + 1)) / 2.0);
            end if;
            Median := Real'Min (0.7, Median);
            declare
               Longest : constant Real := Median * 2.0;
            begin
               if Kept > 0 then
                  for I in Words.First_Index + 1 .. Words.Last_Index loop
                     declare
                        Each : Timed := Words (I);
                     begin
                        if Each.Finish - Each.Start > Longest then
                           if Within (To_String (Each.Text), Sentence_Ends) then
                              Each.Finish := Each.Start + Longest;
                           elsif Within (To_String (Words (I - 1).Text), Sentence_Ends) then
                              Each.Start := Each.Finish - Longest;
                           end if;
                           Words.Replace_Element (I, Each);
                        end if;
                     end;
                  end loop;
               end if;

               --  Punctuation joined: what opens a word to the word after,
               --  what closes one to the word before.
               if Natural (Words.Length) >= 2 then
                  declare
                     I : Integer := Words.Last_Index - 1;
                     J : Integer := Words.Last_Index;
                  begin
                     while I >= Words.First_Index loop
                        declare
                           Before : Timed := Words (I);
                           After  : Timed := Words (J);
                           Said   : constant String := To_String (Before.Text);
                        begin
                           if Said'Length > 0 and then Said (Said'First) = ' '
                             and then Within (Ada.Strings.Fixed.Trim (Said, Ada.Strings.Both), Prepended)
                           then
                              After.Text := Before.Text & After.Text;
                              After.Tokens := Before.Tokens + After.Tokens;
                              Before.Text := Null_Unbounded_String;
                              Before.Tokens := 0;
                              Words.Replace_Element (I, Before);
                              Words.Replace_Element (J, After);
                           else
                              J := I;
                           end if;
                        end;
                        I := I - 1;
                     end loop;
                  end;
                  declare
                     I : Positive := Words.First_Index;
                     J : Positive := Words.First_Index + 1;
                  begin
                     while J <= Words.Last_Index loop
                        declare
                           Before : Timed := Words (I);
                           After  : Timed := Words (J);
                           Said   : constant String := To_String (Before.Text);
                        begin
                           if not (Said'Length > 0 and then Said (Said'Last) = ' ')
                             and then Within (To_String (After.Text), Appended)
                           then
                              Before.Text := Before.Text & After.Text;
                              Before.Tokens := Before.Tokens + After.Tokens;
                              After.Text := Null_Unbounded_String;
                              After.Tokens := 0;
                              Words.Replace_Element (I, Before);
                              Words.Replace_Element (J, After);
                           else
                              I := J;
                           end if;
                        end;
                        J := J + 1;
                     end loop;
                  end;
               end if;

               --  Dealt to the segments, a segment's tokens' worth each.
               declare
                  Word_Index : Positive := Words.First_Index;
               begin
                  for S in 0 .. Natural (Lengths.Length) - 1 loop
                     declare
                        Piece : Segment := Result.Segments (First + S);
                        Saved : Natural := 0;
                     begin
                        while Word_Index <= Words.Last_Index and then Saved < Lengths (S + 1) loop
                           declare
                              Each : constant Timed := Words (Word_Index);
                           begin
                              if Each.Text /= Null_Unbounded_String then
                                 Piece.Words.Append
                                   (Word_Timing'(Text          => Each.Text,
                                                 Start_Seconds => Hundredths (Offset + Each.Start),
                                                 End_Seconds   => Hundredths (Offset + Each.Finish),
                                                 Probability   => Real (Each.Likely)));
                              end if;
                              Saved := Saved + Each.Tokens;
                              Word_Index := Word_Index + 1;
                           end;
                        end loop;
                        if not Piece.Words.Is_Empty then
                           declare
                              W1 : Word_Timing := Piece.Words.First_Element;
                           begin
                              --  The first and second word after a pause no
                              --  longer than twice the median.
                              if W1.End_Seconds - Last_Speech > Median * 4.0
                                and then (W1.End_Seconds - W1.Start_Seconds > Longest
                                          or else (Natural (Piece.Words.Length) > 1
                                                   and then Piece.Words (2).End_Seconds - W1.Start_Seconds
                                                            > Longest * 2.0))
                              then
                                 if Natural (Piece.Words.Length) > 1
                                   and then Piece.Words (2).End_Seconds - Piece.Words (2).Start_Seconds > Longest
                                 then
                                    declare
                                       W2 : Word_Timing := Piece.Words (2);
                                       Boundary : constant Real :=
                                         Real'Max (W2.End_Seconds / 2.0, W2.End_Seconds - Longest);
                                    begin
                                       W1.End_Seconds := Boundary;
                                       W2.Start_Seconds := Boundary;
                                       Piece.Words.Replace_Element (2, W2);
                                    end;
                                 end if;
                                 W1.Start_Seconds := Real'Max (0.0, W1.End_Seconds - Longest);
                              end if;
                              --  The segment's own start where the first
                              --  word is too long; else the word's.
                              if Piece.Start_Seconds < W1.End_Seconds
                                and then Piece.Start_Seconds - 0.5 > W1.Start_Seconds
                              then
                                 W1.Start_Seconds :=
                                   Real'Max (0.0, Real'Min (W1.End_Seconds - Median, Piece.Start_Seconds));
                              else
                                 Piece.Start_Seconds := W1.Start_Seconds;
                              end if;
                              Piece.Words.Replace_Element (1, W1);
                           end;
                           declare
                              Last : Word_Timing := Piece.Words.Last_Element;
                           begin
                              if Piece.End_Seconds > Last.Start_Seconds
                                and then Piece.End_Seconds + 0.5 < Last.End_Seconds
                              then
                                 Last.End_Seconds := Real'Max (Last.Start_Seconds + Median, Piece.End_Seconds);
                              else
                                 Piece.End_Seconds := Last.End_Seconds;
                              end if;
                              Piece.Words.Replace_Element (Piece.Words.Last_Index, Last);
                           end;
                           Last_Speech := Piece.End_Seconds;
                        end if;
                        Result.Segments.Replace_Element (First + S, Piece);
                     end;
                  end loop;
               end;
            end;
         end;
      end Time_Words;
   begin
      Result := (others => <>);
      Status := E.Success;
      if Item.Source = null then
         Status := E.Make (E.Lifecycle_Session_Closed);
         return;
      end if;

      Rules :=
        (End_Of_Text     => Source.End_Of_Text,
         No_Timestamps   => Source.No_Timestamps,
         Timestamp_Begin => Source.Timestamp_Begin,
         Vocabulary      => Natural (Source.Vocabulary_Size),
         Timestamps      => True,
         Max_Initial_Timestamp => 50,
         others          => <>);
      Rules.Suppressed_Count := Source.Suppressed_Count;
      Rules.Suppressed (1 .. Source.Suppressed_Count) := Decoding.Token_List (Source.Suppressed)
        (1 .. Source.Suppressed_Count);
      Rules.Begin_Suppressed_Count := Source.Begin_Suppressed_Count;
      Rules.Begin_Suppressed (1 .. Source.Begin_Suppressed_Count) := Decoding.Token_List (Source.Begin_Suppressed)
        (1 .. Source.Begin_Suppressed_Count);

      if Length (Settings.Language) > 0 then
         if not Source.Multilingual then
            if To_String (Settings.Language) /= "en" then
               Status := E.Make (E.Generation_Invalid_Request);
               E.Add_Text (Status, "detail", "this model hears English only", E.Param_Identifier);
               return;
            end if;
         elsif not Knows_Language (Source.all, To_String (Settings.Language)) then
            Status := E.Make (E.Generation_Invalid_Request);
            E.Add_Text (Status, "detail", "no language " & To_String (Settings.Language), E.Param_Identifier);
            return;
         else
            Language := Source.First_Language
              + Token_Id (Language_Index (Source.all, To_String (Settings.Language)) - 1);
         end if;
      end if;

      Result.Figures.Audio_Seconds := Real (Samples'Length) / Real (Model_Runner.Audio.Canonical_Rate);
      Spectrograms.Log_Mel (Samples, Spectrograms.Mel_Count (Source.Mels), Window_Samples, Mel, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      T.Allocate (Mels * Window_Frames, Window);
      if Window = null then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      Frames := Spectrograms.Frames_Of (Samples'Length, Window_Samples);
      Content := Frames - Window_Frames;
      Result.Figures.Spectrogram_Seconds := Ada.Calendar.Clock - Started;

      --  The initial prompt, as the reference encodes it: a space, then
      --  the text trimmed.
      if Length (Settings.Initial_Prompt) > 0 then
         declare
            Text   : constant String :=
              " " & Ada.Strings.Fixed.Trim (To_String (Settings.Initial_Prompt), Ada.Strings.Both);
            Target : Tk.Token_Array (1 .. Prompt_Room (Source.all));
            Last   : Natural;
         begin
            Tk.Encode (Source.Vocabulary, Text, False, False, Target, Last, Status);
            if E.Is_Error (Status) then
               Release;
               return;
            end if;
            for I in 1 .. Last loop
               All_Tokens.Append (Target (I));
            end loop;
         end;
      end if;

      --  The language, where not given: the first thirty seconds of the
      --  spectrogram as they are -- the padding's own frames after a short
      --  recording, as the reference reads them -- and the likeliest
      --  language token after <|startoftranscript|>.
      if Source.Multilingual and then Language = 0 and then not Settings.Detect_From_Window then
         declare
            Started_Encoder : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Best : Real := Real'First;
         begin
            for C in 0 .. Mels - 1 loop
               for F in Element_Count'(0) .. Window_Frames - 1 loop
                  Window (C * Window_Frames + F) := Mel (C * Frames + F);
               end loop;
            end loop;
            Encode (Item, Window.all, Status);
            Result.Figures.Encoder_Seconds := Result.Figures.Encoder_Seconds + (Ada.Calendar.Clock - Started_Encoder);
            --  Thirty seconds or more, and that window is the first one
            --  transcribed, to the frame: what was heard is kept for it.
            First_Heard := E.Is_Ok (Status) and then Content >= Window_Frames;
            if E.Is_Ok (Status) then
               Item.Held := 0;
               Feed (Item, [1 => Source.Start_Of_Transcript], Status);
            end if;
            if E.Is_Error (Status) then
               Release;
               return;
            end if;
            for I in 1 .. Source.Language_Total loop
               declare
                  Value : constant Real := Item.Logits (Element_Count (Source.First_Language) + Element_Count (I - 1));
               begin
                  if Value > Best then
                     Best := Value;
                     Language := Source.First_Language + Token_Id (I - 1);
                  end if;
               end;
            end loop;
         end;
      end if;
      if not Source.Multilingual then
         Result.Language := To_Unbounded_String ("en");
      elsif Language /= 0 then
         Result.Language :=
           To_Unbounded_String (Language_Code (Source.all, Natural (Language - Source.First_Language) + 1));
      end if;

      while Seek < Content loop
         if Cancelled then
            Release;
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;
         declare
            Size     : constant Element_Count := Element_Count'Min (Window_Frames, Content - Seek);
            Offset   : constant Real := Real (Seek) * Real (Spectrograms.Hop_Length)
              / Real (Model_Runner.Audio.Canonical_Rate);
            Started_Window : Ada.Calendar.Time := Ada.Calendar.Clock;
            Prompt   : Token_Vectors.Vector;
            Sampled  : Token_Vectors.Vector;
            Sum_Log  : Wide_Real := 0.0;
            No_Speech : Wide_Real := 0.0;
            Ended    : Boolean := False;
            Temperature : Real := 0.0;
         begin
            if Seek = 0 and then First_Heard then
               Item.Held := 0;
            else
               Take_Window (Seek, Size);
               Encode (Item, Window.all, Status);
            end if;
            Result.Figures.Encoder_Seconds := Result.Figures.Encoder_Seconds + (Ada.Calendar.Clock - Started_Window);
            Started_Window := Ada.Calendar.Clock;
            if E.Is_Error (Status) then
               Release;
               return;
            end if;
            Result.Figures.Windows := Result.Figures.Windows + 1;

            --  The prompt: the text before, bounded, then the start of the
            --  transcript, its language and task.
            declare
               Available : constant Natural := Natural (All_Tokens.Length) - Reset_Since;
               Take      : constant Natural := Natural'Min (Available, Prompt_Room (Source.all));
            begin
               if Take > 0 then
                  Prompt.Append (Source.Start_Of_Previous);
                  for I in Natural (All_Tokens.Length) - Take + 1 .. Natural (All_Tokens.Length) loop
                     Prompt.Append (All_Tokens (I));
                  end loop;
               end if;
            end;
            Prompt.Append (Source.Start_Of_Transcript);

            --  The window decoded once, at a temperature: the decoder up to
            --  the start of the transcript -- what it says there is how
            --  likely the window holds no speech, and, where asked, which
            --  language it is in -- then the language and the task, then a
            --  token at a time until the end of text, the window's tokens,
            --  or the context: the likeliest where the temperature is
            --  nought, else drawn.
            declare
               --  The prompt fed, how likely the window holds no speech
               --  read off it, the language where asked, then the language
               --  and the task: the logits are the first token's.
               procedure Start is
                  Head : Tk.Token_Array (1 .. Natural (Prompt.Length));
               begin
                  for I in Head'Range loop
                     Head (I) := Prompt (I);
                  end loop;
                  Item.Held := 0;
                  Feed (Item, Head, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  No_Speech := Decoding.Probability (Item.Logits (0 .. Source.Vocabulary_Size - 1), Source.No_Speech);
                  if Source.Multilingual and then Language = 0 then
                     declare
                        Best : Real := Real'First;
                     begin
                        for I in 1 .. Source.Language_Total loop
                           declare
                              Value : constant Real :=
                                Item.Logits (Element_Count (Source.First_Language) + Element_Count (I - 1));
                           begin
                              if Value > Best then
                                 Best := Value;
                                 Language := Source.First_Language + Token_Id (I - 1);
                              end if;
                           end;
                        end loop;
                        Result.Language := To_Unbounded_String (Language_Code (Source.all, I_Of (Language)));
                     end;
                  end if;
                  if Source.Multilingual then
                     Feed (Item, [Language, (if Settings.Translate then Source.Translate_Token
                                             else Source.Transcribe_Token)], Status);
                  end if;
               end Start;

               --  The next token of one draw from its logits, as the rules
               --  allow it, and its log probability where it is not the end.
               procedure Choose
                 (Temperature : Real;
                  Said_So_Far : Token_Vectors.Vector;
                  Logits      : in out Real_Array;
                  Next        : out Token_Id;
                  Log_Sum     : in out Wide_Real)
               is
                  Said : Tk.Token_Array (1 .. Natural (Said_So_Far.Length));
               begin
                  for I in Said'Range loop
                     Said (I) := Said_So_Far (I);
                  end loop;
                  Decoding.Apply (Rules, Said, Logits);
                  if Temperature = 0.0 then
                     Next := Decoding.Pick (Logits);
                  else
                     declare
                        Draw : Wide_Real;
                     begin
                        Decoding.Next (Draws, Draw);
                        Next := Decoding.Sample (Logits, Temperature, Draw);
                     end;
                  end if;
                  if Next /= Source.End_Of_Text then
                     Log_Sum := Log_Sum + Decoding.Log_Probability (Logits, Next);
                  end if;
                  Result.Figures.Tokens := Result.Figures.Tokens + 1;
               end Choose;

               procedure Decode_Once
                 (Temperature : Real;
                  Into        : in out Token_Vectors.Vector;
                  Log_Sum     : out Wide_Real;
                  Finished    : out Boolean) is
               begin
                  Into.Clear;
                  Log_Sum := 0.0;
                  Finished := False;
                  Start;
                  for Step in 1 .. Settings.Max_Tokens loop
                     exit when E.Is_Error (Status);
                     if Cancelled then
                        Status := E.Make (E.Generation_Cancelled);
                        exit;
                     end if;
                     declare
                        Next : Token_Id;
                     begin
                        Choose (Temperature, Into, Item.Logits (0 .. Source.Vocabulary_Size - 1), Next, Log_Sum);
                        Into.Append (Next);
                        if Next = Source.End_Of_Text then
                           Finished := True;
                           exit;
                        end if;
                        exit when Item.Held + 1 > Source.Text_Context;
                        Feed (Item, [1 => Next], Status);
                     end;
                  end loop;
                  if Finished then
                     Into.Delete_Last;
                  end if;
               end Decode_Once;

               --  Best_Of drawn together, as the reference draws them, a
               --  batch: the prompt fed once and its keys and values given
               --  to each, then a step at a time every unfinished draw's
               --  token fed in one pass over the weights, each attending to
               --  its own. The likeliest over its length kept: the
               --  reference's MaximumLikelihoodRanker.
               procedure Decode_Candidates
                 (Temperature : Real;
                  Into        : in out Token_Vectors.Vector;
                  Log_Sum     : out Wide_Real;
                  Finished    : out Boolean)
               is
                  Draws_Wanted : constant Positive := Settings.Best_Of;
                  Blocks : constant Positive := Source.Decoder_Blocks;
                  V      : constant Element_Count := Source.Vocabulary_Size;
                  W      : constant Element_Count := Source.Width;
                  type Token_Vector_Array is array (1 .. Draws_Wanted) of Token_Vectors.Vector;
                  type Log_Array is array (1 .. Draws_Wanted) of Wide_Real;
                  type Flag_Array is array (1 .. Draws_Wanted) of Boolean;
                  type Row_Array is array (1 .. Draws_Wanted) of Element_Count;
                  Said  : Token_Vector_Array;
                  Logs  : Log_Array := [others => 0.0];
                  Ended_Draw : Flag_Array := [others => False];
                  Row   : Row_Array := [others => 0];
                  Position : Element_Count;
                  Best  : Wide_Real := Wide_Real'First;
                  On_Device : Boolean;
               begin
                  Into.Clear;
                  Log_Sum := 0.0;
                  Finished := False;
                  if Item.Candidate_K = null or else Item.Candidate_K'Length < Draws_Wanted * Blocks then
                     T.Free (Item.Candidate_K);
                     T.Free (Item.Candidate_V);
                     Item.Candidate_K := new T.Group_Room (1 .. Draws_Wanted * Blocks);
                     Item.Candidate_V := new T.Group_Room (1 .. Draws_Wanted * Blocks);
                     for Room in 1 .. Draws_Wanted * Blocks loop
                        T.Allocate (Source.Text_Context * W, Item.Candidate_K (Room));
                        T.Allocate (Source.Text_Context * W, Item.Candidate_V (Room));
                     end loop;
                     T.Free (Item.Candidate_Logits);
                     T.Allocate (Element_Count (Draws_Wanted) * V, Item.Candidate_Logits);
                  end if;
                  if Item.Candidate_Query = null then
                     T.Allocate (W, Item.Candidate_Query);
                     T.Allocate (W, Item.Candidate_Blend);
                  end if;
                  if Item.Candidate_Logits = null or else Item.Candidate_Query = null
                    or else Item.Candidate_Blend = null
                  then
                     Status := E.Make (E.Memory_Allocation_Failed);
                     return;
                  end if;
                  for Room in 1 .. Draws_Wanted * Blocks loop
                     if Item.Candidate_K (Room) = null or else Item.Candidate_V (Room) = null then
                        Status := E.Make (E.Memory_Allocation_Failed);
                        return;
                     end if;
                  end loop;

                  Start;
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  Position := Item.Held;
                  for C in 1 .. Draws_Wanted loop
                     Item.Candidate_Logits (Element_Count (C - 1) * V .. Element_Count (C) * V - 1) :=
                       Item.Logits (0 .. V - 1);
                     Row (C) := Element_Count (C - 1);
                  end loop;

                  --  On the device where the turn is held, what was heard
                  --  is there and its cache has the candidates' rows: the
                  --  prompt's keys and values put in every candidate's
                  --  columns, then every candidate fed each step, one
                  --  that ended a dummy token whose answer goes unread, so
                  --  that row c stays candidate c.
                  On_Device := Item.Borrowed and then Item.Cross_On_Device and then Item.Wide >= Draws_Wanted;
                  if On_Device then
                     declare
                        Own  : T.Real_Array_Access;
                        Wide : T.Real_Array_Access;
                        Ok   : Boolean := True;
                        Row_Width : constant Element_Count := Element_Count (Draws_Wanted) * W;
                     begin
                        T.Allocate (Position * W, Own);
                        T.Allocate (Position * Row_Width, Wide);
                        if Own = null or else Wide = null then
                           Ok := False;
                        end if;
                        for L in 1 .. Blocks loop
                           exit when not Ok;
                           for Values in Boolean loop
                              exit when not Ok;
                              if Item.Self_On_Device then
                                 Model_Runner.Backend.Device.Get_Cache
                                   ((if Values then Own_Values_At (Item, L) else Own_Keys_At (Item, L)), Own.all, Ok);
                              else
                                 if Values then
                                    Own.all := Item.Self_V (L) (0 .. Position * W - 1);
                                 else
                                    Own.all := Item.Self_K (L) (0 .. Position * W - 1);
                                 end if;
                              end if;
                              if Ok then
                                 for P_I in 0 .. Position - 1 loop
                                    for C in 0 .. Element_Count (Draws_Wanted) - 1 loop
                                       Wide (P_I * Row_Width + C * W .. P_I * Row_Width + (C + 1) * W - 1) :=
                                         Own (P_I * W .. (P_I + 1) * W - 1);
                                    end loop;
                                 end loop;
                                 Model_Runner.Backend.Device.Put_Cache
                                   ((if Values then Wide_Values_At (Item, L) else Wide_Keys_At (Item, L)),
                                    Wide.all, Ok);
                              end if;
                           end loop;
                        end loop;
                        T.Free (Own);
                        T.Free (Wide);
                        On_Device := Ok;
                     end;
                  end if;

                  for Step in 1 .. Settings.Max_Tokens loop
                     exit when E.Is_Error (Status);
                     if Cancelled then
                        Status := E.Make (E.Generation_Cancelled);
                        exit;
                     end if;
                     declare
                        Fed   : Tk.Token_Array (1 .. Draws_Wanted);
                        Slots : Slot_List (1 .. Draws_Wanted);
                        Count : Natural := 0;
                        Every : Tk.Token_Array (1 .. Draws_Wanted) := [others => Source.End_Of_Text];
                     begin
                        for C in 1 .. Draws_Wanted loop
                           if not Ended_Draw (C) then
                              declare
                                 Next : Token_Id;
                              begin
                                 Choose (Temperature, Said (C),
                                         Item.Candidate_Logits (Row (C) * V .. (Row (C) + 1) * V - 1), Next, Logs (C));
                                 Said (C).Append (Next);
                                 if Next = Source.End_Of_Text then
                                    Ended_Draw (C) := True;
                                 else
                                    Count := Count + 1;
                                    Fed (Count) := Next;
                                    Slots (Count) := C;
                                    Every (C) := Next;
                                 end if;
                              end;
                           end if;
                        end loop;
                        exit when Count = 0 or else Position + 1 > Source.Text_Context;
                        if On_Device then
                           for C in 1 .. Draws_Wanted loop
                              declare
                                 At_Row : constant Element_Count := Element_Count (C - 1) * W;
                              begin
                                 T.Dequantize_Row (Source.Token_Table, Element_Count (Every (C)),
                                                   Item.Dec_X (At_Row .. At_Row + W - 1), Status);
                                 K.Add (Item.Dec_X (At_Row .. At_Row + W - 1),
                                        Source.Text_Positions (Position * W .. (Position + 1) * W - 1));
                              end;
                           end loop;
                           if E.Is_Ok (Status) then
                              Feed_On_Device (Item, Element_Count (Draws_Wanted), Status, Fold => False, Drawn => True,
                                              At_Position => Position);
                           end if;
                           if E.Is_Ok (Status) then
                              Item.Device_Fed := Item.Device_Fed + Draws_Wanted;
                           elsif Step = 1 then
                              --  Refused before anything was fed: the pool
                              --  takes the draws from the prompt, as below.
                              Status := E.Success;
                              On_Device := False;
                           end if;
                        end if;
                        if not On_Device then
                           if Step = 1 then
                              if Item.Self_On_Device then
                                 Bring_Home (Item, Status);
                                 exit when E.Is_Error (Status);
                              end if;
                              for C in 1 .. Draws_Wanted loop
                                 for L in 1 .. Blocks loop
                                    Item.Candidate_K ((C - 1) * Blocks + L) (0 .. Position * W - 1) :=
                                      Item.Self_K (L) (0 .. Position * W - 1);
                                    Item.Candidate_V ((C - 1) * Blocks + L) (0 .. Position * W - 1) :=
                                      Item.Self_V (L) (0 .. Position * W - 1);
                                 end loop;
                              end loop;
                           end if;
                           Feed (Item, Fed (1 .. Count), Status, Slots => Slots (1 .. Count), At_Position => Position);
                           for R in 1 .. Count loop
                              Row (Slots (R)) := Element_Count (R - 1);
                           end loop;
                        end if;
                        Position := Position + 1;
                     end;
                  end loop;

                  for C in 1 .. Draws_Wanted loop
                     if Ended_Draw (C) then
                        Said (C).Delete_Last;
                     end if;
                     declare
                        Score : constant Wide_Real :=
                          Logs (C) / Wide_Real (Natural'Max (1, Natural (Said (C).Length)));
                     begin
                        if Score > Best then
                           Best := Score;
                           Into := Said (C);
                           Log_Sum := Logs (C);
                           Finished := Ended_Draw (C);
                        end if;
                     end;
                  end loop;
               end Decode_Candidates;

            begin
               for Round in 1 .. Settings.Temperature_Count loop
                  Temperature := Settings.Temperatures (Round);
                  if Temperature = 0.0 or else Settings.Best_Of = 1 then
                     Decode_Once (Temperature, Sampled, Sum_Log, Ended);
                  else
                     Decode_Candidates (Temperature, Sampled, Sum_Log, Ended);
                     --  The device failing past the first draw leaves the
                     --  candidates' rows there alone: the window drawn again
                     --  on the pool, from its prompt.
                     if E.Is_Error (Status) and then Item.Borrowed and then Item.Wide > 0
                       and then not E."=" (Status.Code, E.Generation_Cancelled)
                     then
                        Item.Wide := 0;
                        Status := E.Success;
                        Decode_Candidates (Temperature, Sampled, Sum_Log, Ended);
                     end if;
                  end if;
                  exit when E.Is_Error (Status);
                  --  Refused, as the reference refuses a window: repeating
                  --  itself, or unlikely on average -- unless it is silent.
                  declare
                     Count   : constant Natural := Natural (Sampled.Length);
                     Average : constant Wide_Real := Sum_Log / Wide_Real (Count + 1);
                     Ratio   : constant Wide_Real :=
                       Decoding.Compression_Ratio ((if Count = 0 then "" else Text_Of (Sampled, 1, Count)));
                     Refused : Boolean :=
                       Ratio > Wide_Real (Settings.Compression_Threshold)
                       or else Average < Wide_Real (Settings.Log_Prob_Threshold);
                  begin
                     if No_Speech > Wide_Real (Settings.No_Speech_Threshold)
                       and then Average < Wide_Real (Settings.Log_Prob_Threshold)
                     then
                        Refused := False;
                     end if;
                     exit when not Refused;
                  end;
               end loop;
            end;
            Last_Temperature := Temperature;
            Result.Figures.Decoder_Seconds := Result.Figures.Decoder_Seconds + (Ada.Calendar.Clock - Started_Window);
            if E.Is_Error (Status) then
               Release;
               return;
            end if;

            declare
               Count    : constant Natural := Natural (Sampled.Length);
               Average  : constant Wide_Real := Sum_Log / Wide_Real (Count + 1);
               Whole    : constant String := (if Count = 0 then "" else Text_Of (Sampled, 1, Count));
               Ratio    : constant Wide_Real := Decoding.Compression_Ratio (Whole);
               Silent   : constant Boolean :=
                 No_Speech > Wide_Real (Settings.No_Speech_Threshold)
                 and then not (Average > Wide_Real (Settings.Log_Prob_Threshold));
               Doubtful : constant Boolean :=
                 Ratio > Wide_Real (Settings.Compression_Threshold)
                 or else Average < Wide_Real (Settings.Log_Prob_Threshold);
               Duration_Seconds : constant Real :=
                 Real (Size) * Real (Spectrograms.Hop_Length) / Real (Model_Runner.Audio.Canonical_Rate);

               function Is_Time (I : Positive) return Boolean is (Sampled (I) >= Source.Timestamp_Begin);

               --  This window's segments, where their words are timed: the
               --  first's place, each one's text tokens, all of them.
               First_New     : constant Positive := Natural (Result.Segments.Length) + 1;
               Window_Text   : Token_Vectors.Vector;
               Window_Counts : Count_Vectors.Vector;

               function Time_Of (Token : Token_Id) return Real is
                 (Real (Token - Source.Timestamp_Begin) * Time_Precision);

               procedure Add_Segment (From, To : Natural; Start_At, End_At : Real) is
                  Piece : Segment;
               begin
                  Piece.Start_Seconds := Start_At;
                  Piece.End_Seconds := End_At;
                  Piece.Average_Log_Probability := Real (Average);
                  Piece.No_Speech_Probability := Real (No_Speech);
                  Piece.Compression_Ratio := Real (Ratio);
                  Piece.Uncertain := Doubtful;
                  Piece.Temperature := Temperature;
                  Piece.Cut_Short := not Ended;
                  declare
                     Text : constant String := (if To >= From then Text_Of (Sampled, From, To) else "");
                  begin
                     --  A segment of no length, or of no text, keeps no
                     --  text, and gives the next window none to be
                     --  prompted with.
                     if Start_At = End_At or else Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both) = "" then
                        Piece.Text := Null_Unbounded_String;
                        Window_Counts.Append (0);
                     else
                        Piece.Text := To_Unbounded_String (Text);
                        declare
                           Texts : Natural := 0;
                        begin
                           for I in From .. To loop
                              All_Tokens.Append (Sampled (I));
                              if Sampled (I) < Source.End_Of_Text then
                                 Window_Text.Append (Sampled (I));
                                 Texts := Texts + 1;
                              end if;
                           end loop;
                           Window_Counts.Append (Texts);
                        end;
                     end if;
                  end;
                  Result.Segments.Append (Piece);
                  Append (Result.Text, Piece.Text);
               end Add_Segment;
            begin
               if Silent then
                  declare
                     Piece : Segment;
                  begin
                     Piece.Start_Seconds := Offset;
                     Piece.End_Seconds := Offset + Duration_Seconds;
                     Piece.No_Speech_Probability := Real (No_Speech);
                     Piece.Average_Log_Probability := Real (Average);
                     Piece.Silent := True;
                     Result.Segments.Append (Piece);
                  end;
                  Seek := Seek + Size;
               else
                  --  Segments between consecutive times; the window's last
                  --  time says where the next one starts.
                  declare
                     Single_Ending : constant Boolean :=
                       Count >= 2 and then not Is_Time (Count - 1) and then Is_Time (Count);
                     Last_Slice : Natural := 1;
                     Any_Pair   : Boolean := False;
                  begin
                     for I in 2 .. Count loop
                        if Is_Time (I - 1) and then Is_Time (I) then
                           Any_Pair := True;
                           Add_Segment (Last_Slice, I - 1, Offset + Time_Of (Sampled (Last_Slice)),
                                        Offset + Time_Of (Sampled (I - 1)));
                           Last_Slice := I;
                        end if;
                     end loop;
                     if Any_Pair then
                        if Single_Ending then
                           Add_Segment (Last_Slice, Count, Offset + Time_Of (Sampled (Last_Slice)),
                                        Offset + Time_Of (Sampled (Count)));
                           Seek := Seek + Size;
                        else
                           Seek := Seek
                             + Element_Count (Sampled (Last_Slice - 1) - Source.Timestamp_Begin) * Input_Stride;
                        end if;
                     else
                        declare
                           Span : Real := Duration_Seconds;
                        begin
                           for I in reverse 1 .. Count loop
                              if Is_Time (I) then
                                 if Sampled (I) /= Source.Timestamp_Begin then
                                    Span := Time_Of (Sampled (I));
                                 end if;
                                 exit;
                              end if;
                           end loop;
                           Add_Segment (1, Count, Offset, Offset + Span);
                        end;
                        Seek := Seek + Size;
                     end if;

                     --  Each word's time; and the next window from where the
                     --  last word ended, unless the window ended on a time
                     --  alone.
                     if Settings.Word_Timestamps then
                        Time_Words (Window_Text, Window_Counts, First_New, Size, Offset);
                        if E.Is_Error (Status) then
                           Release;
                           return;
                        end if;
                        if not Single_Ending and then Natural (Result.Segments.Length) >= First_New then
                           declare
                              Last_End : Real := Result.Segments.Last_Element.End_Seconds;
                           begin
                              for I in reverse First_New .. Result.Segments.Last_Index loop
                                 if not Result.Segments (I).Words.Is_Empty then
                                    Last_End := Result.Segments (I).Words.Last_Element.End_Seconds;
                                    exit;
                                 end if;
                              end loop;
                              if Last_End > Offset then
                                 Seek := Element_Count (Wide_Real'Unbiased_Rounding (Wide_Real (Last_End) * 100.0));
                              end if;
                           end;
                        end if;
                     end if;
                  end;
               end if;
            end;
         end;
         if not Settings.Condition_On_Previous or else Last_Temperature > 0.5 then
            Reset_Since := Natural (All_Tokens.Length);
         end if;
      end loop;
      Release;
   exception
      when Storage_Error =>
         Release;
         Result := (others => <>);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "speech", E.Param_Identifier);
   end Transcribe_Here;

   --  With the device's turn held throughout where it is to be had: the
   --  encoder and every token on it.
   procedure Transcribe
     (Item     : in out Session;
      Samples  : Real_Array;
      Settings : Options;
      Result   : out Transcript;
      Status   : out E.Error_Info;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null)
   is
      Took : Boolean := False;
      Fed  : constant Natural := Item.Device_Fed;
   begin
      if Item.Source /= null then
         Item.Wide := (if Settings.Best_Of > 1 then Settings.Best_Of else 0);
         Hold (Item, Took);
      end if;
      Transcribe_Here (Item, Samples, Settings, Result, Status, Cancel);
      Result.Figures.Device_Positions := Item.Device_Fed - Fed;
      Let_Go (Item, Took);
   exception
      when others =>
         Let_Go (Item, Took);
         raise;
   end Transcribe;

end Model_Runner.Whisper;
