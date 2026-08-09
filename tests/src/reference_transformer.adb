with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Errors;
with Model_Runner.Numerics;

package body Reference_Transformer is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package Functions is
     new Ada.Numerics.Generic_Elementary_Functions (Long_Float);

   procedure Free_Matrix is
     new Ada.Unchecked_Deallocation (Matrix, Matrix_Access);
   procedure Free_Vector is
     new Ada.Unchecked_Deallocation (Real_Vector, Vector_Access);
   procedure Free_Layers is
     new Ada.Unchecked_Deallocation (Layer_Array, Layer_Array_Access);

   -------------------
   -- Decode_Float --
   -------------------

   function Decode_Float
     (Image  : B.Byte_Array;
      Offset : Interfaces.Unsigned_64) return Long_Float
   is
      Base : constant B.Byte_Count := Image'First + B.Byte_Count (Offset);
      Raw  : Interfaces.Unsigned_32 := 0;
   begin
      --  Assemble the little-endian word by hand rather than reusing the
      --  engine's primitive decoding, so that a decoding mistake cannot be
      --  common to both implementations.
      for Index in reverse 0 .. 3 loop
         Raw := Interfaces.Shift_Left (Raw, 8)
           + Interfaces.Unsigned_32 (Image (Base + B.Byte_Count (Index)));
      end loop;

      declare
         Sign     : constant Long_Float :=
           (if (Raw and 16#8000_0000#) /= 0 then -1.0 else 1.0);
         Exponent : constant Integer :=
           Integer (Interfaces.Shift_Right (Raw, 23) and 16#FF#);
         Mantissa : constant Interfaces.Unsigned_32 := Raw and 16#7F_FFFF#;
      begin
         --  Reconstruct the value arithmetically from its fields. This is the
         --  definition of binary32 rather than a reinterpretation of the host
         --  representation, which is what makes it an independent decode.
         if Exponent = 0 then
            if Mantissa = 0 then
               return Sign * 0.0;
            end if;
            return Sign * Long_Float (Mantissa) * 2.0 ** (-149);
         elsif Exponent = 16#FF# then
            --  The synthetic models carry no non-finite weights; report a zero
            --  rather than inventing an infinity the comparison cannot use.
            return 0.0;
         else
            return Sign
              * (1.0 + Long_Float (Mantissa) / 8_388_608.0)
              * 2.0 ** (Exponent - 127);
         end if;
      end;
   end Decode_Float;

   --  Decode one Q8_0 element, independently of the engine.
   --
   --  The layout says: thirty-two elements to a block of thirty-four bytes,
   --  a half-precision scale first, then one signed byte each. This works the
   --  half out arithmetically from its sign, exponent and mantissa rather than
   --  reusing the engine's conversion, so a fault in that conversion cannot
   --  hide by being made twice.
   function Decode_Q8_0
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is

      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 32);
      Within : constant Natural := Index mod 32;
      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 34;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      Raw_Half : constant Natural :=
        Byte_At (At_Block) + 256 * Byte_At (At_Block + 1);

      Sign     : constant Long_Float :=
        (if Raw_Half >= 16#8000# then -1.0 else 1.0);
      Exponent : constant Integer := (Raw_Half / 1024) mod 32;
      Mantissa : constant Integer := Raw_Half mod 1024;

      Scale : Long_Float;

      Quant : constant Integer :=
        (if Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within)) < 128
         then Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within))
         else Byte_At (At_Block + 2 + Interfaces.Unsigned_64 (Within)) - 256);
   begin
      if Exponent = 0 then
         --  Subnormal, or zero when the mantissa is zero too.
         Scale := Sign * Long_Float (Mantissa) * (2.0 ** (-24));
      elsif Exponent = 31 then
         --  Infinity or not-a-number; a fixture never contains one, and
         --  answering zero keeps this from inventing a value.
         Scale := 0.0;
      else
         Scale :=
           Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
           * (2.0 ** (Exponent - 15));
      end if;

      return Scale * Long_Float (Quant);
   end Decode_Q8_0;

   --  Decode one Q4_K element, independently of the engine.
   --
   --  The layout says: two hundred and fifty-six elements to a superblock of
   --  one hundred and forty-four bytes. A half-precision scale, a
   --  half-precision minimum, twelve bytes carrying a six-bit factor and a
   --  six-bit offset for each of eight sub-blocks, then one hundred and
   --  twenty-eight bytes of four-bit quants, two to a byte, in which
   --  sub-blocks 2g and 2g+1 share thirty-two bytes -- low nibbles first.
   --  A value is factor * scale * quant - offset * minimum.
   --
   --  Worked out from the layout rather than by calling the engine, like the
   --  Q8_0 decoder above and for the same reason: a fault made twice is a
   --  fault that agrees with itself.
   function Decode_Q4_K
     (Image : Model_Runner.Bytes.Byte_Array;
      Base  : Interfaces.Unsigned_64;
      Index : Natural) return Long_Float
   is
      Block  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Index / 256);
      Within : constant Natural := Index mod 256;
      Sub    : constant Natural := Within / 32;
      In_Sub : constant Natural := Within mod 32;

      At_Block : constant Interfaces.Unsigned_64 := Base + Block * 144;

      function Byte_At (Offset : Interfaces.Unsigned_64) return Natural
      is (Natural
            (Image (Image'First + Model_Runner.Bytes.Byte_Count (Offset))));

      --  A half-precision value, from its fields.
      function Half_At (Offset : Interfaces.Unsigned_64) return Long_Float is
         Raw      : constant Natural :=
           Byte_At (Offset) + 256 * Byte_At (Offset + 1);
         Sign     : constant Long_Float :=
           (if Raw >= 16#8000# then -1.0 else 1.0);
         Exponent : constant Integer := (Raw / 1024) mod 32;
         Mantissa : constant Integer := Raw mod 1024;
      begin
         if Exponent = 0 then
            return Sign * Long_Float (Mantissa) * (2.0 ** (-24));
         elsif Exponent = 31 then
            return 0.0;
         else
            return Sign * (1.0 + Long_Float (Mantissa) / 1024.0)
              * (2.0 ** (Exponent - 15));
         end if;
      end Half_At;

      Scale   : constant Long_Float := Half_At (At_Block);
      Minimum : constant Long_Float := Half_At (At_Block + 2);
      Scales  : constant Interfaces.Unsigned_64 := At_Block + 4;

      Factor, Offset_Level : Natural;

      Quants : constant Interfaces.Unsigned_64 := At_Block + 16;
      Pair   : constant Interfaces.Unsigned_64 :=
        Quants + Interfaces.Unsigned_64 (Sub / 2) * 32
        + Interfaces.Unsigned_64 (In_Sub);
      Packed : constant Natural := Byte_At (Pair);
      Quant  : constant Natural :=
        (if Sub mod 2 = 0 then Packed mod 16 else Packed / 16);
   begin
      --  The first four sub-blocks keep six bits in a byte of their own; the
      --  last four take four bits from one byte and two from another.
      if Sub < 4 then
         Factor := Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) mod 64;
         Offset_Level :=
           Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 64;
      else
         Factor :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) mod 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) - 4) / 64);
         Offset_Level :=
           (Byte_At (Scales + Interfaces.Unsigned_64 (Sub) + 4) / 16)
           + 16 * (Byte_At (Scales + Interfaces.Unsigned_64 (Sub)) / 64);
      end if;

      return Scale * Long_Float (Factor) * Long_Float (Quant)
        - Minimum * Long_Float (Offset_Level);
   end Decode_Q4_K;

   --  Read a metadata integer, or a default.
   function Metadata
     (Source  : Containers.Container;
      Key     : String;
      Default : Natural) return Natural
   is
      Value  : Long_Long_Integer;
      Status : Model_Runner.Errors.Error_Info;
   begin
      Containers.Get_Integer (Source, Key, 0, 1_000_000, Value, Status);
      if Model_Runner.Errors.Is_Ok (Status) then
         return Natural (Value);
      else
         return Default;
      end if;
   end Metadata;

   ----------
   -- Load --
   ----------

   --  The prefix a model's metadata keys carry.
   function Prefix (Item : Model) return String
   is (case Item.Kind is when Llama => "llama.", when Qwen2 => "qwen2.");

   procedure Load
     (Item   : in out Model;
      Source : Containers.Container;
      Image  : B.Byte_Array;
      Ok     : out Boolean)
   is
      use type Model_Runner.GGUF.Tensor_Type;

      --  Read a two-dimensional tensor. GGUF dimension 1 is contiguous and is
      --  the input width; the remaining extent is the output width.
      function Read_Matrix (Name : String; Present : out Boolean)
        return Matrix_Access
      is
         Index : constant Natural := Containers.Find_Tensor (Source, Name);
      begin
         Present := False;

         if Index = 0
           or else Containers.Tensor_Format (Source, Index)
                   not in Model_Runner.GGUF.Type_F32
                        | Model_Runner.GGUF.Type_Q8_0
                        | Model_Runner.GGUF.Type_Q4_K
         then
            return null;
         end if;

         declare
            Columns : constant Natural :=
              Natural (Containers.Tensor_Dimension (Source, Index, 1));
            Rows    : Natural := 1;
            Offset  : constant Interfaces.Unsigned_64 :=
              Containers.Tensor_Offset (Source, Index);
            Result  : Matrix_Access;
         begin
            for Axis in 2 .. Containers.Tensor_Rank (Source, Index) loop
               Rows :=
                 Rows * Natural (Containers.Tensor_Dimension (Source, Index, Axis));
            end loop;

            Result := new Matrix (0 .. Rows - 1, 0 .. Columns - 1);

            for Row in 0 .. Rows - 1 loop
               for Column in 0 .. Columns - 1 loop
                  if Containers.Tensor_Format (Source, Index)
                       = Model_Runner.GGUF.Type_Q8_0
                  then
                     Result (Row, Column) :=
                       Decode_Q8_0
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 34
                            * Interfaces.Unsigned_64 (Columns / 32),
                          Column);
                  elsif Containers.Tensor_Format (Source, Index)
                          = Model_Runner.GGUF.Type_Q4_K
                  then
                     Result (Row, Column) :=
                       Decode_Q4_K
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row) * 144
                            * Interfaces.Unsigned_64 (Columns / 256),
                          Column);
                  else
                     Result (Row, Column) :=
                       Decode_Float
                         (Image,
                          Offset
                          + Interfaces.Unsigned_64 (Row * Columns + Column) * 4);
                  end if;
               end loop;
            end loop;

            Present := True;
            return Result;
         end;
      end Read_Matrix;

      --  Read a one-dimensional tensor.
      function Read_Vector (Name : String; Present : out Boolean)
        return Vector_Access
      is
         Index : constant Natural := Containers.Find_Tensor (Source, Name);
      begin
         Present := False;

         if Index = 0
           or else Containers.Tensor_Format (Source, Index)
                   /= Model_Runner.GGUF.Type_F32
         then
            return null;
         end if;

         declare
            Width  : constant Natural :=
              Natural (Containers.Tensor_Dimension (Source, Index, 1));
            Offset : constant Interfaces.Unsigned_64 :=
              Containers.Tensor_Offset (Source, Index);
            Result : constant Vector_Access := new Real_Vector (0 .. Width - 1);
         begin
            for Position in 0 .. Width - 1 loop
               Result (Position) :=
                 Decode_Float
                   (Image, Offset + Interfaces.Unsigned_64 (Position) * 4);
            end loop;
            Present := True;
            return Result;
         end;
      end Read_Vector;

      function Layer_Name (Index : Natural; Suffix : String) return String is
         Digits_Text : constant String := Natural'Image (Index);
      begin
         return "blk." & Digits_Text (Digits_Text'First + 1 .. Digits_Text'Last)
           & "." & Suffix;
      end Layer_Name;

      Present : Boolean;
   begin
      Close (Item);
      Ok := False;

      --  The architectures this reference knows, which must be the ones the
      --  engine knows: a conformance run compares two implementations of
      --  the same function, and a reference that computes a different one
      --  reports the engine as wrong. Qwen2 was added to the engine and not
      --  to here, so its arithmetic had nothing independent to be checked
      --  against at all.
      declare
         Named : constant String :=
           Containers.String_Value (Source, "general.architecture");
      begin
         if Named = "llama" then
            Item.Kind := Llama;
         elsif Named = "qwen2" then
            Item.Kind := Qwen2;
         else
            return;
         end if;
      end;

      Item.Embedding := Metadata (Source, Prefix (Item) & "embedding_length", 0);
      Item.Feed_Forward := Metadata (Source, Prefix (Item) & "feed_forward_length", 0);
      Item.Layers := Metadata (Source, Prefix (Item) & "block_count", 0);
      Item.Heads := Metadata (Source, Prefix (Item) & "attention.head_count", 0);
      Item.KV_Heads :=
        Metadata (Source, Prefix (Item) & "attention.head_count_kv", Item.Heads);
      Item.Context := Metadata (Source, Prefix (Item) & "context_length", 0);

      if Item.Embedding = 0 or else Item.Layers = 0 or else Item.Heads = 0
        or else Item.Embedding mod Item.Heads /= 0
        or else Item.KV_Heads = 0
        or else Item.Heads mod Item.KV_Heads /= 0
      then
         return;
      end if;

      Item.Head_Size := Item.Embedding / Item.Heads;
      Item.Rotary :=
        Metadata (Source, Prefix (Item) & "rope.dimension_count", Item.Head_Size);

      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Containers.Get_Float
           (Source, Prefix (Item) & "attention.layer_norm_rms_epsilon",
            0.0, 1.0, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Epsilon := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, Prefix (Item) & "rope.freq_base", 1.0, 1.0E12, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Rope_Base := Long_Float (Value);
         end if;
      end;

      Item.Embeddings := Read_Matrix ("token_embd.weight", Present);
      if not Present then
         return;
      end if;
      Item.Words := Item.Embeddings'Length (1);

      Item.Output_Norm := Read_Vector ("output_norm.weight", Present);
      if not Present then
         return;
      end if;

      Item.Output := Read_Matrix ("output.weight", Present);
      if not Present then
         --  A tied model reuses the embedding table as the output projection.
         Item.Output := Item.Embeddings;
      end if;

      Item.Blocks := new Layer_Array (0 .. Item.Layers - 1);

      for Index in Item.Blocks'Range loop
         declare
            Current : Layer renames Item.Blocks (Index);
         begin
            Current.Attention_Norm :=
              Read_Vector (Layer_Name (Index, "attn_norm.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Query :=
              Read_Matrix (Layer_Name (Index, "attn_q.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Key :=
              Read_Matrix (Layer_Name (Index, "attn_k.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Value :=
              Read_Matrix (Layer_Name (Index, "attn_v.weight"), Present);
            if not Present then
               return;
            end if;

            --  The projection biases, required for the architecture that
            --  has them and absent from the one that does not.
            if Item.Kind = Qwen2 then
               Current.Query_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_q.bias"), Present);
               if not Present then
                  return;
               end if;

               Current.Key_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_k.bias"), Present);
               if not Present then
                  return;
               end if;

               Current.Value_Bias :=
                 Read_Vector (Layer_Name (Index, "attn_v.bias"), Present);
               if not Present then
                  return;
               end if;
            end if;

            Current.Attention_Out :=
              Read_Matrix (Layer_Name (Index, "attn_output.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Feed_Norm :=
              Read_Vector (Layer_Name (Index, "ffn_norm.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Gate :=
              Read_Matrix (Layer_Name (Index, "ffn_gate.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Up :=
              Read_Matrix (Layer_Name (Index, "ffn_up.weight"), Present);
            if not Present then
               return;
            end if;

            Current.Down :=
              Read_Matrix (Layer_Name (Index, "ffn_down.weight"), Present);
            if not Present then
               return;
            end if;
         end;
      end loop;

      Item.Loaded := True;
      Ok := True;
   end Load;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Model) is
      Tied : constant Boolean := Item.Output = Item.Embeddings;
   begin
      if Item.Blocks /= null then
         for Index in Item.Blocks'Range loop
            Free_Vector (Item.Blocks (Index).Attention_Norm);
            Free_Matrix (Item.Blocks (Index).Query);
            Free_Matrix (Item.Blocks (Index).Key);
            Free_Matrix (Item.Blocks (Index).Value);
            Free_Matrix (Item.Blocks (Index).Attention_Out);
            Free_Vector (Item.Blocks (Index).Feed_Norm);
            Free_Matrix (Item.Blocks (Index).Gate);
            Free_Matrix (Item.Blocks (Index).Up);
            Free_Matrix (Item.Blocks (Index).Down);
         end loop;
         Free_Layers (Item.Blocks);
      end if;

      if not Tied then
         Free_Matrix (Item.Output);
      end if;
      Item.Output := null;

      Free_Matrix (Item.Embeddings);
      Free_Vector (Item.Output_Norm);
      Item.Loaded := False;
      Item.Words := 0;
   end Close;

   ----------------
   -- Vocabulary --
   ----------------

   function Vocabulary (Item : Model) return Natural is (Item.Words);

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : in out Model;
      Tokens : Token_Vector;
      Logits : out Real_Vector;
      Ok     : out Boolean)
   is
      Width    : constant Natural := Item.Embedding;
      KV_Width : constant Natural := Item.KV_Heads * Item.Head_Size;
      Steps    : constant Natural := Tokens'Length;

      --  The whole key and value history, rather than a cache with reserved
      --  and committed positions.
      type History is array (Natural range <>, Natural range <>) of Long_Float;
      type History_Access is access History;
      procedure Free_History is
        new Ada.Unchecked_Deallocation (History, History_Access);

      Keys   : History_Access := null;
      Values : History_Access := null;

      State  : Real_Vector (0 .. Width - 1) := [others => 0.0];
      Normed : Real_Vector (0 .. Width - 1) := [others => 0.0];

      --  Root-mean-square normalization with a per-element gain.
      procedure Normalize
        (Source : Real_Vector;
         Gain   : Real_Vector;
         Target : out Real_Vector)
      is
         Total : Long_Float := 0.0;
      begin
         for Index in Source'Range loop
            Total := Total + Source (Index) * Source (Index);
         end loop;

         declare
            Scale : constant Long_Float :=
              1.0 / Functions.Sqrt
                      (Total / Long_Float (Source'Length) + Item.Epsilon);
         begin
            for Index in Source'Range loop
               Target (Index) := Source (Index) * Scale * Gain (Index);
            end loop;
         end;
      end Normalize;

      --  Matrix-vector product, one row at a time.
      procedure Project
        (Weight : Matrix;
         Input  : Real_Vector;
         Target : out Real_Vector)
      is
      begin
         for Row in Weight'Range (1) loop
            declare
               Total : Long_Float := 0.0;
            begin
               for Column in Weight'Range (2) loop
                  Total := Total + Weight (Row, Column) * Input (Column);
               end loop;
               Target (Row) := Total;
            end;
         end loop;
      end Project;

      --  Rotary encoding over the leading Rotary elements of each head.
      procedure Rotate
        (Vector   : in out Real_Vector;
         Heads    : Natural;
         Position : Natural)
      is
      begin
         for Head in 0 .. Heads - 1 loop
            for Pair in 0 .. Item.Rotary / 2 - 1 loop
               declare
                  Frequency : constant Long_Float :=
                    1.0 / Functions."**"
                            (Item.Rope_Base,
                             2.0 * Long_Float (Pair)
                             / Long_Float (Item.Rotary));
                  Angle : constant Long_Float :=
                    Long_Float (Position) * Frequency;
                  --  Llama pairs an element with its neighbour; Qwen2
                  --  pairs it with the one half a rotation later. Written
                  --  out here rather than shared with the engine: the point
                  --  of this implementation is to be arrived at separately,
                  --  and a shared rotation would agree with itself.
                  Even  : constant Natural :=
                    (if Item.Kind = Llama
                     then Head * Item.Head_Size + 2 * Pair
                     else Head * Item.Head_Size + Pair);
                  Odd   : constant Natural :=
                    (if Item.Kind = Llama
                     then Even + 1
                     else Even + Item.Rotary / 2);
                  Left  : constant Long_Float := Vector (Even);
                  Right : constant Long_Float := Vector (Odd);
               begin
                  Vector (Even) :=
                    Left * Functions.Cos (Angle) - Right * Functions.Sin (Angle);
                  Vector (Odd) :=
                    Left * Functions.Sin (Angle) + Right * Functions.Cos (Angle);
               end;
            end loop;
         end loop;
      end Rotate;

   begin
      Ok := False;
      Logits := [others => 0.0];

      if not Item.Loaded or else Steps = 0
        or else Logits'Length /= Item.Words
      then
         return;
      end if;

      for Token of Tokens loop
         if Token >= Item.Words then
            return;
         end if;
      end loop;

      Keys := new History (0 .. Item.Layers * Steps - 1, 0 .. KV_Width - 1);
      Values := new History (0 .. Item.Layers * Steps - 1, 0 .. KV_Width - 1);

      for Step in 0 .. Steps - 1 loop
         --  Embedding lookup.
         for Index in 0 .. Width - 1 loop
            State (Index) :=
              Item.Embeddings (Tokens (Tokens'First + Step), Index);
         end loop;

         for Block in 0 .. Item.Layers - 1 loop
            declare
               Current : Layer renames Item.Blocks (Block);
               Query   : Real_Vector (0 .. Width - 1) := [others => 0.0];
               Key_Row : Real_Vector (0 .. KV_Width - 1) := [others => 0.0];
               Val_Row : Real_Vector (0 .. KV_Width - 1) := [others => 0.0];
               Blended : Real_Vector (0 .. Width - 1) := [others => 0.0];
               Slot    : constant Natural := Block * Steps + Step;
            begin
               Normalize (State, Current.Attention_Norm.all, Normed);
               Project (Current.Query.all, Normed, Query);
               Project (Current.Key.all, Normed, Key_Row);
               Project (Current.Value.all, Normed, Val_Row);

               --  The bias belongs to the projection, so it is added to
               --  what the projection produced and before the rotation acts
               --  on it. That ordering is the one thing the engine's own
               --  tests cannot check, because a fixture has nothing to be
               --  right against; this is the something.
               if Current.Query_Bias /= null then
                  for Index in Query'Range loop
                     Query (Index) :=
                       Query (Index) + Current.Query_Bias.all (Index);
                  end loop;
                  for Index in Key_Row'Range loop
                     Key_Row (Index) :=
                       Key_Row (Index) + Current.Key_Bias.all (Index);
                     Val_Row (Index) :=
                       Val_Row (Index) + Current.Value_Bias.all (Index);
                  end loop;
               end if;

               Rotate (Query, Item.Heads, Step);
               Rotate (Key_Row, Item.KV_Heads, Step);

               for Index in 0 .. KV_Width - 1 loop
                  Keys (Slot, Index) := Key_Row (Index);
                  Values (Slot, Index) := Val_Row (Index);
               end loop;

               --  Attention. The key and value heads are expanded to one per
               --  query head rather than mapped, so a grouping mistake in the
               --  engine cannot be reproduced here.
               declare
                  Group : constant Natural := Item.Heads / Item.KV_Heads;
                  Scale : constant Long_Float :=
                    1.0 / Functions.Sqrt (Long_Float (Item.Head_Size));
               begin
                  for Head in 0 .. Item.Heads - 1 loop
                     declare
                        Source_Head : constant Natural := Head / Group;
                        Scores : Real_Vector (0 .. Step) := [others => 0.0];
                        Largest : Long_Float;
                        Total   : Long_Float := 0.0;
                     begin
                        for Past in 0 .. Step loop
                           declare
                              Where : constant Natural := Block * Steps + Past;
                              Total_Score : Long_Float := 0.0;
                           begin
                              for Component in 0 .. Item.Head_Size - 1 loop
                                 Total_Score := Total_Score
                                   + Query (Head * Item.Head_Size + Component)
                                     * Keys (Where,
                                             Source_Head * Item.Head_Size
                                             + Component);
                              end loop;
                              Scores (Past) := Total_Score * Scale;
                           end;
                        end loop;

                        Largest := Scores (0);
                        for Past in Scores'Range loop
                           if Scores (Past) > Largest then
                              Largest := Scores (Past);
                           end if;
                        end loop;

                        for Past in Scores'Range loop
                           Scores (Past) := Functions.Exp (Scores (Past) - Largest);
                           Total := Total + Scores (Past);
                        end loop;

                        for Component in 0 .. Item.Head_Size - 1 loop
                           declare
                              Sum : Long_Float := 0.0;
                           begin
                              for Past in 0 .. Step loop
                                 Sum := Sum + Scores (Past)
                                   * Values (Block * Steps + Past,
                                             Source_Head * Item.Head_Size
                                             + Component);
                              end loop;
                              Blended (Head * Item.Head_Size + Component) :=
                                Sum / Total;
                           end;
                        end loop;
                     end;
                  end loop;
               end;

               Project (Current.Attention_Out.all, Blended, Normed);
               for Index in 0 .. Width - 1 loop
                  State (Index) := State (Index) + Normed (Index);
               end loop;

               --  Feed-forward block.
               Normalize (State, Current.Feed_Norm.all, Normed);

               declare
                  Gate : Real_Vector (0 .. Item.Feed_Forward - 1) :=
                    [others => 0.0];
                  Up   : Real_Vector (0 .. Item.Feed_Forward - 1) :=
                    [others => 0.0];
               begin
                  Project (Current.Gate.all, Normed, Gate);
                  Project (Current.Up.all, Normed, Up);

                  for Index in Gate'Range loop
                     Gate (Index) :=
                       Gate (Index) / (1.0 + Functions.Exp (-Gate (Index)))
                       * Up (Index);
                  end loop;

                  Project (Current.Down.all, Gate, Normed);
               end;

               for Index in 0 .. Width - 1 loop
                  State (Index) := State (Index) + Normed (Index);
               end loop;
            end;
         end loop;
      end loop;

      Normalize (State, Item.Output_Norm.all, Normed);
      Project (Item.Output.all, Normed, Logits);

      Free_History (Keys);
      Free_History (Values);
      Ok := True;
   exception
      when others =>
         Free_History (Keys);
         Free_History (Values);
         Ok := False;
   end Run;

end Reference_Transformer;
