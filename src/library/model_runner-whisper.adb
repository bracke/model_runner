with Ada.Calendar;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

with Model_Runner.Audio.Spectrograms;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Kernels;
with Model_Runner.Shares;
with Model_Runner.Whisper.Decoding;

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
         Dec_Scores => Element_Count (Positive'Max (Item.Decoder_Heads, Item.Encoder_Heads)) * P,
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
        + 6 * S.Row + S.Feed_Row + S.Dec_Scores + Item.Width + S.Logits;
   begin
      return (if Item.Ready then 4 * B.Byte_Count (Floats) else 0);
   end Session_Bytes;

   --------------
   -- Sessions --
   --------------

   procedure Close (Item : in out Session) is
   begin
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
      FP.Free (Item.Weight_Panels);
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
      Item.Has_Encoded := False;
      Item.Held := 0;
   end Close;

   function Is_Open (Item : Session) return Boolean is (Item.Source /= null);

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
      CPU.Dispatch_Shares (Item.Team, Rows, Work'Unchecked_Access, Status, Cost => Rows * Width);
      if E.Is_Ok (Status) and then Work.Failed then
         Status := E.Make (E.Sampling_Non_Finite_Logit);
      end if;
   end Rows_Through;

   --------------
   -- Products --
   --------------

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
      Status : in out E.Error_Info)
   is
      Team : constant Model_Runner.Shares.Team_Access := CPU.Sharing (Item.Team);
      Rows : constant Element_Count := Weight.Rows;
      Cols : constant Element_Count := Weight.Columns;
   begin
      if E.Is_Error (Status) then
         return;
      end if;
      for R in 0 .. Rows - 1 loop
         T.Dequantize_Row (Weight, R, Item.Decoded (R * Cols .. (R + 1) * Cols - 1), Status);
         exit when E.Is_Error (Status);
      end loop;
      if E.Is_Ok (Status) then
         FP.Pack (Team, Item.Decoded.all, 0, Rows, Cols, Cols, 1, Item.Weight_Panels, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      FP.Multiply (Team, Item.Weight_Panels, Source.all, 0, Cols, Count, Target.all, 0, Rows);
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
      CPU.Dispatch_Batch (Item.Team, Weight, Source, Count, Target, Status);
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
                  for J in 0 .. Seen - 1 loop
                     declare
                        P : constant Real := Real (Elementary.Exp (Wide_Real (Item.Scores (Scores + J) - Top)));
                     begin
                        Item.Scores (Scores + J) := P;
                        Sum := Sum + Wide_Real (P);
                     end;
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

   --  The encoder's attention: every position to every position, a head at
   --  a time, both products by panels -- the keys laid out as a weight the
   --  queries multiply, the scores softened row by row, then the values,
   --  turned, as a weight the scores multiply.
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

   procedure Encode
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
      Multiply_Many (Item, Item.Work_A, P2, Source.Conv1.Weight, Item.Work_B, Source.Conv1.Bias, Status);
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
      Multiply_Many (Item, Item.Work_C, P, Source.Conv2.Weight, Item.Encoded, Source.Conv2.Bias, Status);
      Rows_Through (Item, Gaussian, Item.Encoded, P, W, Status);
      Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Source.Audio_Positions);

      for L in 1 .. Source.Encoder_Blocks loop
         exit when E.Is_Error (Status);
         declare
            Each : Block renames Source.Encoder (L);
         begin
            Rows_Through (Item, Normalize, Item.Work_A, P, W, Status, Source => Item.Encoded,
                          Weight => Each.Attention_Norm.Weight, Bias => Each.Attention_Norm.Bias);
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.Q.Weight, Item.Work_B, Each.Attention.Q.Bias, Status);
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.K.Weight, Item.Work_C, null, Status);
            Multiply_Many (Item, Item.Work_A, P, Each.Attention.V.Weight, Item.Work_D, Each.Attention.V.Bias, Status);
            Attend_Both_Ways (Item, Item.Work_B, Item.Work_C, Item.Work_D, Item.Work_E, Status);
            Multiply_Many (Item, Item.Work_E, P, Each.Attention.Output.Weight, Item.Work_A,
                           Each.Attention.Output.Bias, Status);
            Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Item.Work_A);

            Rows_Through (Item, Normalize, Item.Work_B, P, W, Status, Source => Item.Encoded,
                          Weight => Each.Feed_Norm.Weight, Bias => Each.Feed_Norm.Bias);
            Multiply_Many (Item, Item.Work_B, P, Each.Up.Weight, Item.Work_C, Each.Up.Bias, Status);
            Rows_Through (Item, Gaussian, Item.Work_C, P, F, Status);
            Multiply_Many (Item, Item.Work_C, P, Each.Down.Weight, Item.Work_A, Each.Down.Bias, Status);
            Rows_Through (Item, Accumulate, Item.Encoded, P, W, Status, Source => Item.Work_A);
         end;
      end loop;
      Rows_Through (Item, Normalize, Item.Work_A, P, W, Status, Source => Item.Encoded,
                    Weight => Source.Encoder_Norm.Weight, Bias => Source.Encoder_Norm.Bias);
      if E.Is_Error (Status) then
         return;
      end if;
      Item.Encoded (0 .. P * W - 1) := Item.Work_A (0 .. P * W - 1);

      --  Each decoder block's keys and values of what was heard, once.
      for L in 1 .. Source.Decoder_Blocks loop
         Multiply_Many (Item, Item.Encoded, P, Source.Decoder (L).Cross.K.Weight, Item.Cross_K (L), null, Status);
         Multiply_Many (Item, Item.Encoded, P, Source.Decoder (L).Cross.V.Weight, Item.Cross_V (L),
                        Source.Decoder (L).Cross.V.Bias, Status);
      end loop;
      Item.Has_Encoded := E.Is_Ok (Status);
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
   procedure Feed
     (Item   : in out Session;
      Tokens : Tk.Token_Array;
      Status : out E.Error_Info)
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
      if Count = 0 or else Item.Held + Count > Source.Text_Context then
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
         K.Add (Item.Dec_X (I * W .. (I + 1) * W - 1),
                Source.Text_Positions ((Item.Held + I) * W .. (Item.Held + I + 1) * W - 1));
      end loop;

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
            Item.Self_K (L) (Item.Held * W .. (Item.Held + Count) * W - 1) := Item.Dec_K (0 .. Count * W - 1);
            Item.Self_V (L) (Item.Held * W .. (Item.Held + Count) * W - 1) := Item.Dec_V (0 .. Count * W - 1);
            Work.Keys := Item.Self_K (L);
            Work.Values := Item.Self_V (L);
            Work.Before := Item.Held;
            Work.Causal := True;
            CPU.Dispatch_Shares (Item.Team, Heads, Work'Unchecked_Access, Status,
                                 Cost => Count * (Item.Held + Count) * W);
            Multiply_Few (Item, Item.Dec_A, Count, Each.Attention.Output.Weight, Item.Dec_H,
                          Each.Attention.Output.Bias, Status);
            Rows_Through (Item, Accumulate, Item.Dec_X, Count, W, Status, Source => Item.Dec_H);

            Rows_Through (Item, Normalize, Item.Dec_H, Count, W, Status, Source => Item.Dec_X,
                          Weight => Each.Cross_Norm.Weight, Bias => Each.Cross_Norm.Bias);
            Multiply_Few (Item, Item.Dec_H, Count, Each.Cross.Q.Weight, Item.Dec_Q, Each.Cross.Q.Bias, Status);
            exit when E.Is_Error (Status);
            Work.Keys := Item.Cross_K (L);
            Work.Values := Item.Cross_V (L);
            Work.Key_Count := Source.Audio_Context;
            Work.Causal := False;
            CPU.Dispatch_Shares (Item.Team, Heads, Work'Unchecked_Access, Status,
                                 Cost => Count * Source.Audio_Context * W);
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
      Item.Held := Item.Held + Count;

      K.Layer_Norm (Item.Dec_X ((Count - 1) * W .. Count * W - 1), Source.Decoder_Norm.Weight.all,
                    Source.Decoder_Norm.Bias.all, Source.Epsilon, Item.Last_Row.all);
      CPU.Dispatch (Item.Team, Source.Token_Table, Item.Last_Row, Item.Logits, Status);
   end Feed;

   ------------
   -- Decode --
   ------------

   procedure Decode
     (Item   : in out Session;
      Tokens : Tk.Token_Array;
      Logits : out Real_Array;
      Status : out E.Error_Info) is
   begin
      Item.Held := 0;
      Feed (Item, Tokens, Status);
      if E.Is_Ok (Status) then
         Logits := Item.Logits (0 .. Logits'Length - 1);
      end if;
   end Decode;

   ----------------
   -- Transcribe --
   ----------------

   --  Tokens a window may be prompted with, after <|startofprev|>: the
   --  reference's n_text_ctx / 2 - 1.
   function Prompt_Room (Item : Model) return Natural is (Natural (Item.Text_Context) / 2 - 1);

   package Token_Vectors is new Ada.Containers.Vectors (Positive, Token_Id);

   procedure Transcribe
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
      Language : Token_Id := 0;
      --  Every token the windows decoded, the initial prompt's first.
      All_Tokens : Token_Vectors.Vector;
      Reset_Since : Natural := 0;
      Rules : Model_Runner.Whisper.Decoding.Rules;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Mels : constant Element_Count := Element_Count (Source.Mels);

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
            return Tk.Decode (Source.Vocabulary, Text_Tokens);
         end;
      end Text_Of;
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
      if Source.Multilingual and then Language = 0 then
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
      Result.Language :=
        (if Source.Multilingual
         then To_Unbounded_String (Language_Code (Source.all, Natural (Language - Source.First_Language) + 1))
         else To_Unbounded_String ("en"));

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
         begin
            Take_Window (Seek, Size);
            Encode (Item, Window.all, Status);
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

            --  The decoder up to the start of the transcript: what it says
            --  there is how likely the window holds no speech.
            Item.Held := 0;
            declare
               Head : Tk.Token_Array (1 .. Natural (Prompt.Length));
            begin
               for I in Head'Range loop
                  Head (I) := Prompt (I);
               end loop;
               Feed (Item, Head, Status);
            end;
            if E.Is_Ok (Status) then
               No_Speech := Decoding.Probability (Item.Logits (0 .. Source.Vocabulary_Size - 1), Source.No_Speech);
               if Source.Multilingual then
                  Feed (Item, [Language, Source.Transcribe_Token], Status);
               end if;
            end if;

            --  Greedy, a token at a time, until the end of text, the window's
            --  tokens, or the context.
            for Step in 1 .. Settings.Max_Tokens loop
               exit when E.Is_Error (Status);
               if Cancelled then
                  Status := E.Make (E.Generation_Cancelled);
                  exit;
               end if;
               declare
                  Said : Tk.Token_Array (1 .. Natural (Sampled.Length));
                  Next : Token_Id;
                  Logits : Real_Array renames Item.Logits (0 .. Source.Vocabulary_Size - 1);
               begin
                  for I in Said'Range loop
                     Said (I) := Sampled (I);
                  end loop;
                  Decoding.Apply (Rules, Said, Logits);
                  Next := Decoding.Pick (Logits);
                  if Next /= Source.End_Of_Text then
                     Sum_Log := Sum_Log + Decoding.Log_Probability (Logits, Next);
                  end if;
                  Sampled.Append (Next);
                  Result.Figures.Tokens := Result.Figures.Tokens + 1;
                  if Next = Source.End_Of_Text then
                     Ended := True;
                     exit;
                  end if;
                  exit when Item.Held + 1 > Source.Text_Context;
                  Feed (Item, [1 => Next], Status);
               end;
            end loop;
            Result.Figures.Decoder_Seconds := Result.Figures.Decoder_Seconds + (Ada.Calendar.Clock - Started_Window);
            if E.Is_Error (Status) then
               Release;
               return;
            end if;
            if Ended then
               Sampled.Delete_Last;
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
                  Piece.Cut_Short := not Ended;
                  declare
                     Text : constant String := (if To >= From then Text_Of (Sampled, From, To) else "");
                  begin
                     --  A segment of no length, or of no text, keeps no
                     --  text, and gives the next window none to be
                     --  prompted with.
                     if Start_At = End_At or else Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both) = "" then
                        Piece.Text := Null_Unbounded_String;
                     else
                        Piece.Text := To_Unbounded_String (Text);
                        for I in From .. To loop
                           All_Tokens.Append (Sampled (I));
                        end loop;
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
                  end;
               end if;
            end;
         end;
         if not Settings.Condition_On_Previous then
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
   end Transcribe;

end Model_Runner.Whisper;
