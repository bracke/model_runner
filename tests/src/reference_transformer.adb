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
                   /= Model_Runner.GGUF.Type_F32
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
                  Result (Row, Column) :=
                    Decode_Float
                      (Image,
                       Offset
                       + Interfaces.Unsigned_64 (Row * Columns + Column) * 4);
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

      if Containers.String_Value (Source, "general.architecture") /= "llama" then
         return;
      end if;

      Item.Embedding := Metadata (Source, "llama.embedding_length", 0);
      Item.Feed_Forward := Metadata (Source, "llama.feed_forward_length", 0);
      Item.Layers := Metadata (Source, "llama.block_count", 0);
      Item.Heads := Metadata (Source, "llama.attention.head_count", 0);
      Item.KV_Heads :=
        Metadata (Source, "llama.attention.head_count_kv", Item.Heads);
      Item.Context := Metadata (Source, "llama.context_length", 0);

      if Item.Embedding = 0 or else Item.Layers = 0 or else Item.Heads = 0
        or else Item.Embedding mod Item.Heads /= 0
        or else Item.KV_Heads = 0
        or else Item.Heads mod Item.KV_Heads /= 0
      then
         return;
      end if;

      Item.Head_Size := Item.Embedding / Item.Heads;
      Item.Rotary :=
        Metadata (Source, "llama.rope.dimension_count", Item.Head_Size);

      declare
         Value  : Model_Runner.Numerics.Wide_Real;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Containers.Get_Float
           (Source, "llama.attention.layer_norm_rms_epsilon",
            0.0, 1.0, Value, Status);
         if Model_Runner.Errors.Is_Ok (Status) then
            Item.Epsilon := Long_Float (Value);
         end if;

         Containers.Get_Float
           (Source, "llama.rope.freq_base", 1.0, 1.0E12, Value, Status);
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
                  Even  : constant Natural := Head * Item.Head_Size + 2 * Pair;
                  Odd   : constant Natural := Even + 1;
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
