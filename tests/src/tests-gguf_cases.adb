with AUnit.Assertions;

with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Numerics;
with Model_Runner.Quantization;

with Fixtures;
with Fuzzing;

package body Tests.GGUF_Cases is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.GGUF.Value_Type;
   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;
   use type Model_Runner.Bytes.Byte_Array;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Quantization;

   use type N.Element_Count;
   use type B.Byte_Array_Access;
   package G renames Model_Runner.GGUF;
   package Containers renames Model_Runner.GGUF.Containers;

   --  Build a small, entirely well-formed container: a few scalar metadata
   --  types, one string array, one float array and two tensors.
   procedure Build_Valid (Result : out B.Byte_Array_Access) is
      Builder : Fixtures.Builder;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "general.name", "fixture");
      Fixtures.Add_U32 (Builder, "llama.block_count", 2);
      Fixtures.Add_U64 (Builder, "llama.context_length", 16);
      Fixtures.Add_I32 (Builder, "fixture.signed", -7);
      Fixtures.Add_F32 (Builder, "llama.attention.layer_norm_rms_epsilon", 1.0E-5);
      Fixtures.Add_Bool (Builder, "fixture.flag", True);

      Fixtures.Begin_Array (Builder, "tokenizer.ggml.tokens", G.Value_String, 3);
      Fixtures.String_Element (Builder, "<unk>");
      Fixtures.String_Element (Builder, "a");
      Fixtures.String_Element (Builder, "b");
      Fixtures.End_Array (Builder);

      Fixtures.Begin_Array (Builder, "tokenizer.ggml.scores", G.Value_Float32, 3);
      Fixtures.Float_Element (Builder, 0.0);
      Fixtures.Float_Element (Builder, -1.5);
      Fixtures.Float_Element (Builder, 2.25);
      Fixtures.End_Array (Builder);

      Fixtures.Add_Tensor
        (Builder, "token_embd.weight", [4, 3], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (12, 1)));
      Fixtures.Add_Tensor
        (Builder, "output_norm.weight", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 2)));

      Fixtures.Build (Builder, Result);
   end Build_Valid;

   --  Parse a byte image and report the resulting status code.
   procedure Parse_Image
     (Image  : B.Byte_Array;
      Item   : in out Containers.Container;
      Status : out E.Error_Info;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits)
   is
      Copy   : aliased constant B.Byte_Array := Image;
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Copy'Access);
   begin
      Containers.Reader.Parse (Item, Source, Bounds, null, null, Status);
   end Parse_Image;

   --  Parse an edited copy of the valid image and report the status code.
   function Status_After_Edit
     (Offset : B.Byte_Count;
      Value  : B.Byte_Array) return E.Error_Code
   is
      Image  : B.Byte_Array_Access;
      Result : E.Error_Code;
   begin
      Build_Valid (Image);
      Image.all (Image.all'First + Offset
                 .. Image.all'First + Offset + Value'Length - 1) := Value;

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Result := Status.Code;
         Containers.Close (Item);
      end;

      B.Free (Image);
      return Result;
   end Status_After_Edit;

   --  A well-formed file parses and every fact it stated is readable.
   procedure Valid_File_Parses (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Build_Valid (Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (E.Is_Ok (Status),
                 "valid container rejected: " & E.Error_Code'Image (Status.Code));
         Assert (Containers.Is_Valid (Item), "container not marked valid");
         Assert (Containers.Version (Item) = 3, "wrong version");
         Assert (Containers.Alignment (Item) = 32, "wrong default alignment");
         Assert (Containers.Metadata_Count (Item) = 9,
                 "wrong metadata count:"
                 & Natural'Image (Containers.Metadata_Count (Item)));
         Assert (Containers.Tensor_Count (Item) = 2, "wrong tensor count");
         Assert (Containers.String_Value (Item, "general.architecture") = "llama",
                 "architecture not readable");
         Assert (Containers.Find_Tensor (Item, "token_embd.weight") /= 0,
                 "tensor not found by name");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Valid_File_Parses;

   --  Typed accessors separate absent, wrongly typed and out-of-range keys.
   procedure Typed_Accessors (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Build_Valid (Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
         Number : Long_Long_Integer;
         Real   : Model_Runner.Numerics.Wide_Real;
         Flag   : Boolean;
         Length : Natural;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (E.Is_Ok (Status), "fixture did not parse");

         Containers.Get_Integer (Item, "llama.block_count", 1, 64, Number, Status);
         Assert (E.Is_Ok (Status) and then Number = 2, "block_count not read");

         Containers.Get_Integer (Item, "llama.missing", 0, 1, Number, Status);
         Assert (Status.Code = E.GGUF_Missing_Metadata_Key,
                 "absent key not reported as missing");

         Containers.Get_Integer
           (Item, "general.architecture", 0, 1, Number, Status);
         Assert (Status.Code = E.GGUF_Metadata_Type_Mismatch,
                 "wrong type not reported");

         Containers.Get_Integer (Item, "llama.block_count", 8, 64, Number, Status);
         Assert (Status.Code = E.GGUF_Metadata_Out_Of_Range,
                 "out-of-range value not reported");

         Containers.Get_Integer (Item, "fixture.signed", -10, 0, Number, Status);
         Assert (E.Is_Ok (Status) and then Number = -7, "signed value not read");

         Containers.Get_Float
           (Item, "llama.attention.layer_norm_rms_epsilon",
            0.0, 1.0, Real, Status);
         Assert (E.Is_Ok (Status) and then Real > 0.0, "epsilon not read");

         Containers.Get_Boolean (Item, "fixture.flag", Flag, Status);
         Assert (E.Is_Ok (Status) and then Flag, "bool not read");

         Containers.Get_Array_Length
           (Item, "tokenizer.ggml.tokens", G.Value_String, Length, Status);
         Assert (E.Is_Ok (Status) and then Length = 3, "array length wrong");

         declare
            Token : String (1 .. 16);
            Last  : Natural;
         begin
            Containers.Get_String_Element
              (Item, "tokenizer.ggml.tokens", 2, Token, Last, Status);
            Assert (E.Is_Ok (Status) and then Token (1 .. Last) = "a",
                    "string array element wrong");
         end;

         Containers.Get_Float_Element
           (Item, "tokenizer.ggml.scores", 3, Real, Status);
         Assert (E.Is_Ok (Status) and then Real = 2.25,
                 "float array element wrong");

         Containers.Close (Item);
      end;

      B.Free (Image);
   end Typed_Accessors;

   --  A wrong magic is rejected before anything else is read.
   procedure Invalid_Magic (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Status_After_Edit (0, [1 => 16#00#]) = E.GGUF_Invalid_Magic,
              "corrupt magic not rejected");
   end Invalid_Magic;

   --  Versions outside the supported window are rejected as unsupported, not
   --  as malformed.
   procedure Unsupported_Version (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Status_After_Edit (4, B.Put_U32 (1)) = E.GGUF_Unsupported_Version,
              "version 1 accepted");
      Assert (Status_After_Edit (4, B.Put_U32 (4)) = E.GGUF_Unsupported_Version,
              "future version accepted");
   end Unsupported_Version;

   --  An implausible tensor or metadata count is rejected against the limits
   --  before any loop is sized from it.
   procedure Excessive_Counts (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Status_After_Edit (8, B.Put_U64 (16#FFFF_FFFF#))
              = E.GGUF_Tensor_Count_Too_Large,
              "huge tensor count accepted");
      Assert (Status_After_Edit (16, B.Put_U64 (16#FFFF_FFFF#))
              = E.GGUF_Metadata_Count_Too_Large,
              "huge metadata count accepted");
   end Excessive_Counts;

   --  Truncation at any offset is a structured rejection, never an exception.
   procedure Truncation_Is_Structured
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Build_Valid (Image);

      for Length in B.Byte_Count range 0 .. Image.all'Length - 1 loop
         declare
            Item   : Containers.Container;
            Status : E.Error_Info;
            Prefix : constant B.Byte_Array :=
              Image.all (Image.all'First .. Image.all'First + Length - 1);
         begin
            Parse_Image (Prefix, Item, Status);
            Assert (E.Is_Error (Status),
                    "truncated file accepted at length"
                    & B.Byte_Count'Image (Length));
            Assert (not Containers.Is_Valid (Item),
                    "truncated file left a valid container");
            Containers.Close (Item);
         end;
      end loop;

      B.Free (Image);
   end Truncation_Is_Structured;

   --  A duplicate metadata key is rejected rather than silently shadowed.
   procedure Duplicate_Metadata_Key
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Build (Builder, Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (Status.Code = E.GGUF_Duplicate_Metadata_Key,
                 "duplicate key accepted");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Duplicate_Metadata_Key;

   --  A duplicate tensor name is rejected.
   procedure Duplicate_Tensor_Name
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_Tensor
        (Builder, "a.weight", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
      Fixtures.Add_Tensor
        (Builder, "a.weight", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 2)));
      Fixtures.Build (Builder, Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (Status.Code = E.GGUF_Duplicate_Tensor_Name,
                 "duplicate tensor name accepted");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Duplicate_Tensor_Name;

   --  Invalid UTF-8 in a metadata string is rejected.
   procedure Invalid_UTF8_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
   begin
      Fixtures.Reset (Builder);
      --  A lone continuation byte can never begin a well-formed sequence.
      Fixtures.Add_String
        (Builder, "general.name", [1 => Character'Val (16#80#)]);
      Fixtures.Build (Builder, Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (Status.Code = E.GGUF_Invalid_UTF8, "invalid UTF-8 accepted");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Invalid_UTF8_Rejected;

   --  A quantized tensor whose contiguous dimension is not a whole number of
   --  blocks is rejected.
   procedure Block_Misalignment (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
   begin
      Fixtures.Reset (Builder);
      --  Q8_0 stores 32 elements per block; 20 is not a multiple of 32.
      Fixtures.Add_Tensor
        (Builder, "a.weight", [20], G.Type_Q8_0, B.Byte_Array'(1 .. 34 => 0));
      Fixtures.Build (Builder, Image);

      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (Status.Code = E.GGUF_Block_Misalignment,
                 "misaligned quantized dimension accepted");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Block_Misalignment;

   --  A tensor whose declared range runs past the end of the file is rejected.
   procedure Tensor_Out_Of_Bounds (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
      Found : Boolean := False;
   begin
      Build_Valid (Image);

      --  Overwrite the last tensor's relative offset with a value far beyond
      --  the file. The descriptor table is the last thing before the data
      --  section, so the final eight bytes of it hold that offset.
      declare
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Parse_Image (Image.all, Item, Status);
         Assert (E.Is_Ok (Status), "fixture did not parse");
         Containers.Close (Item);
      end;

      for Probe in B.Byte_Count range 0 .. Image.all'Length - 8 loop
         declare
            Copy   : B.Byte_Array := Image.all;
            Item   : Containers.Container;
            Status : E.Error_Info;
         begin
            Copy (Copy'First + Probe .. Copy'First + Probe + 7) :=
              B.Put_U64 (16#0001_0000_0000#);
            Parse_Image (Copy, Item, Status);
            if Status.Code = E.GGUF_Tensor_Out_Of_Bounds then
               Found := True;
            end if;
            Containers.Close (Item);
         end;
         exit when Found;
      end loop;

      Assert (Found, "no edit produced an out-of-bounds tensor rejection");
      B.Free (Image);
   end Tensor_Out_Of_Bounds;

   --  Trailing bytes after the last tensor are rejected by default and
   --  accepted when the policy allows them.
   procedure Trailing_Data_Policy (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image    : B.Byte_Array_Access;
      Relaxed  : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
   begin
      Build_Valid (Image);

      declare
         Extended : constant B.Byte_Array :=
           Image.all & B.Byte_Array'(1 .. 16 => 16#AB#);
         Item     : Containers.Container;
         Status   : E.Error_Info;
      begin
         Parse_Image (Extended, Item, Status);
         Assert (Status.Code = E.GGUF_Trailing_Data,
                 "trailing data accepted by default");
         Containers.Close (Item);

         Relaxed.Allow_Trailing_Data := True;
         Parse_Image (Extended, Item, Status, Relaxed);
         Assert (E.Is_Ok (Status), "trailing data rejected under relaxed policy");
         Containers.Close (Item);
      end;

      B.Free (Image);
   end Trailing_Data_Policy;

   --  A mutation campaign over the synthetic model produces only controlled
   --  outcomes: nothing escapes as an exception and no invalid container is
   --  accepted into a usable state. The seeds are fixed, so this case is
   --  deterministic and reproducible; larger campaigns run through
   --  "tests fuzz".
   procedure Mutation_Corpus_Is_Controlled
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      for Seed in Interfaces.Unsigned_64 range 1 .. 3 loop
         declare
            Result : Fuzzing.Report;
         begin
            Fuzzing.Run (Seed, 150, Result);

            Assert (Result.Escaped = 0,
                    "seed" & Interfaces.Unsigned_64'Image (Seed)
                    & ": an exception escaped the parser at case"
                    & Natural'Image (Result.First_Bad));
            Assert (Result.Invalid = 0,
                    "seed" & Interfaces.Unsigned_64'Image (Seed)
                    & ": an invalid container was accepted at case"
                    & Natural'Image (Result.First_Bad));

            --  The campaign has to actually reach the parser's rejection
            --  paths, otherwise it would pass by doing nothing.
            Assert (Result.Rejected > 0,
                    "seed" & Interfaces.Unsigned_64'Image (Seed)
                    & ": no mutation was rejected, so nothing was exercised");
         end;
      end loop;
   end Mutation_Corpus_Is_Controlled;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("gguf container");
   end Name;

   --  Random bytes reinterpreted as floating point are frequently infinities
   --  or not-a-number, and a comparison against those says nothing. This
   --  forces every scale and every raw float in a buffer to a modest finite
   --  exponent, leaving the mantissas and the quantized payloads random.
   procedure Make_Finite
     (Data   : in out B.Byte_Array;
      Format : Model_Runner.GGUF.Tensor_Type;
      Blocks : N.Element_Count)
   is
      Width : constant B.Byte_Count :=
        B.Byte_Count (Model_Runner.GGUF.Block_Bytes (Format));

      --  Set the high byte of a half at a block-relative position.
      procedure Tame_Half (Block : N.Element_Count; At_Byte : B.Byte_Count) is
      begin
         Data (Data'First + B.Byte_Count (Block) * Width + At_Byte + 1) :=
           16#30#;
      end Tame_Half;
   begin
      for Block in 0 .. Blocks - 1 loop
         case Format is
            when Model_Runner.GGUF.Type_F32 =>
               Data (Data'First + B.Byte_Count (Block) * Width + 3) := 16#3E#;
            when Model_Runner.GGUF.Type_F16 =>
               Tame_Half (Block, 0);
            when Model_Runner.GGUF.Type_Q4_0 | Model_Runner.GGUF.Type_Q8_0 =>
               Tame_Half (Block, 0);
            when Model_Runner.GGUF.Type_Q4_K | Model_Runner.GGUF.Type_Q5_K =>
               --  Scale and minimum both lead the block.
               Tame_Half (Block, 0);
               Tame_Half (Block, 2);
            when Model_Runner.GGUF.Type_Q6_K =>
               Tame_Half (Block, 208);
            when others =>
               null;
         end case;
      end loop;
   end Make_Finite;

   --  The fused kernel and the reference decoder must agree, for every format.
   --
   --  Accumulate_Dot reads the block layouts a second time so that it can
   --  multiply without decoding into a buffer first. That is a real risk: a
   --  layout could be right in the decoder, whose golden vectors check it, and
   --  wrong in the kernel that every matrix product actually runs. This is
   --  what makes that impossible to miss.
   --
   --  The two are not required to be bit-identical. Folding the scale out of
   --  the block removes a rounding to single precision per element, so the
   --  fused result is the more accurate of the two; the check is that they
   --  agree to the precision the inputs carry.
   procedure Fused_Dot_Matches_Decoder
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Formats : constant array (1 .. 7) of Model_Runner.GGUF.Tensor_Type :=
        [Model_Runner.GGUF.Type_F32, Model_Runner.GGUF.Type_F16,
         Model_Runner.GGUF.Type_Q4_0, Model_Runner.GGUF.Type_Q8_0,
         Model_Runner.GGUF.Type_Q4_K, Model_Runner.GGUF.Type_Q5_K,
         Model_Runner.GGUF.Type_Q6_K];

      Fused_Seen   : Natural := 0;
      Checked_Rows : Natural := 0;
   begin
      for Format of Formats loop
         declare
            Per : constant N.Element_Count :=
              N.Element_Count (Model_Runner.GGUF.Block_Elements (Format));
            Width : constant B.Byte_Count :=
              B.Byte_Count (Model_Runner.GGUF.Block_Bytes (Format));

            --  Enough blocks that a span crosses more than one, and a width
            --  that is a whole number of blocks for every format here.
            Blocks  : constant N.Element_Count := 8;
            Columns : constant N.Element_Count := Per * Blocks;

            Data   : B.Byte_Array_Access;
            Vector : N.Real_Array (0 .. Columns - 1);
            Decoded : N.Real_Array (0 .. Columns - 1);
            Sums   : N.Wide_Real_Array (0 .. 0) := [others => 0.0];
            Ok     : Boolean;
            Seed   : Interfaces.Unsigned_32 := 16#1234_5678#;

            function Next return Interfaces.Unsigned_32 is
            begin
               --  A cheap generator; the point is a spread of bit patterns,
               --  not statistical quality.
               Seed := Seed * 1_664_525 + 1_013_904_223;
               return Seed;
            end Next;
         begin
            B.Allocate (Width * B.Byte_Count (Blocks), Data);
            Assert (Data /= null, "could not allocate block data");

            --  Bytes across the whole range, so no nibble, sign bit or
            --  sub-block scale is left unexercised.
            for Index in Data.all'Range loop
               Data.all (Index) :=
                 B.Byte (Interfaces.Shift_Right (Next, 24) and 16#FF#);
            end loop;

            Make_Finite (Data.all, Format, Blocks);

            for Index in Vector'Range loop
               Vector (Index) :=
                 N.Real (Integer (Interfaces.Shift_Right (Next, 26))) - 32.0;
            end loop;

            --  Reference: decode the row, then multiply.
            Q.Decode_Blocks (Format, Data.all, 0, Blocks, Decoded, Ok);
            Assert (Ok, "reference decode failed for "
                    & Model_Runner.GGUF.Type_Name (Format));

            declare
               Reference : N.Wide_Real := 0.0;
            begin
               for Index in 0 .. Columns - 1 loop
                  Reference := Reference
                    + N.Wide_Real (Decoded (Index))
                      * N.Wide_Real (Vector (Index));
               end loop;

               --  Under test: multiply without decoding.
               Q.Accumulate_Dot
                 (Format, Data.all, 0, Blocks, Vector, Vector'First,
                  Columns, 1, Sums, Ok);
               Assert (Ok, "fused dot failed for "
                       & Model_Runner.GGUF.Type_Name (Format));

               if Q.Fused_Formats (Format) then
                  Fused_Seen := Fused_Seen + 1;
               end if;
               Checked_Rows := Checked_Rows + 1;

               declare
                  Size : constant N.Wide_Real :=
                    N.Wide_Real'Max (abs Reference, 1.0);
                  Gap  : constant N.Wide_Real := abs (Reference - Sums (0));
               begin
                  Assert
                    (Gap / Size <= 1.0E-6,
                     "fused dot disagrees with the decoder for "
                     & Model_Runner.GGUF.Type_Name (Format)
                     & ": decoded" & N.Wide_Real'Image (Reference)
                     & " fused" & N.Wide_Real'Image (Sums (0)));
               end;
            end;

            B.Free (Data);
         end;
      end loop;

      Assert (Checked_Rows = 7, "not every format was checked");
      Assert (Fused_Seen = 1,
              "the set of fused formats changed without this test noticing");
   end Fused_Dot_Matches_Decoder;

   --  One vector or many must give the same bits, for every format.
   --
   --  The kernel takes a different route when several vectors share a span,
   --  and the fused formats factor a block's scale out of its sum. If those
   --  routes disagreed, --batch-size would quietly change what a model says.
   --  The tiny fixture is entirely F32, so the end-to-end batch test cannot
   --  see this; the check belongs here, where the format is a parameter.
   procedure Batch_Width_Does_Not_Change_Result
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Formats : constant array (1 .. 7) of Model_Runner.GGUF.Tensor_Type :=
        [Model_Runner.GGUF.Type_F32, Model_Runner.GGUF.Type_F16,
         Model_Runner.GGUF.Type_Q4_0, Model_Runner.GGUF.Type_Q8_0,
         Model_Runner.GGUF.Type_Q4_K, Model_Runner.GGUF.Type_Q5_K,
         Model_Runner.GGUF.Type_Q6_K];

      Vectors_Used : constant N.Element_Count := 5;
   begin
      for Format of Formats loop
         declare
            Per : constant N.Element_Count :=
              N.Element_Count (Model_Runner.GGUF.Block_Elements (Format));
            Width : constant B.Byte_Count :=
              B.Byte_Count (Model_Runner.GGUF.Block_Bytes (Format));

            --  More than one span's worth, so the span boundary is crossed.
            Blocks  : constant N.Element_Count :=
              N.Element_Count'Max (2, 2048 / Per + 1);
            Columns : constant N.Element_Count := Per * Blocks;

            Data    : B.Byte_Array_Access;
            Inputs  : N.Real_Array (0 .. Vectors_Used * Columns - 1);
            Together : N.Wide_Real_Array (0 .. Vectors_Used - 1) :=
              [others => 0.0];
            Alone   : N.Wide_Real_Array (0 .. 0);
            Ok      : Boolean;
            Seed    : Interfaces.Unsigned_32 := 16#0BAD_F00D#;

            function Next return Interfaces.Unsigned_32 is
            begin
               Seed := Seed * 1_664_525 + 1_013_904_223;
               return Seed;
            end Next;
         begin
            B.Allocate (Width * B.Byte_Count (Blocks), Data);
            Assert (Data /= null, "could not allocate block data");

            for Index in Data.all'Range loop
               Data.all (Index) :=
                 B.Byte (Interfaces.Shift_Right (Next, 24) and 16#FF#);
            end loop;

            Make_Finite (Data.all, Format, Blocks);

            for Index in Inputs'Range loop
               Inputs (Index) :=
                 N.Real (Integer (Interfaces.Shift_Right (Next, 26))) - 32.0;
            end loop;

            --  All five vectors in one call.
            Q.Accumulate_Dot
              (Format, Data.all, 0, Blocks, Inputs, Inputs'First,
               Columns, Vectors_Used, Together, Ok);
            Assert (Ok, "batched dot failed for "
                    & Model_Runner.GGUF.Type_Name (Format));

            --  The same five vectors, one call each.
            for Which in 0 .. Vectors_Used - 1 loop
               Alone := [others => 0.0];
               Q.Accumulate_Dot
                 (Format, Data.all, 0, Blocks, Inputs,
                  Inputs'First + Which * Columns, Columns, 1, Alone, Ok);
               Assert (Ok, "single dot failed for "
                       & Model_Runner.GGUF.Type_Name (Format));

               Assert
                 (Alone (0) = Together (Which),
                  "batch width changed the result for "
                  & Model_Runner.GGUF.Type_Name (Format)
                  & ": alone" & N.Wide_Real'Image (Alone (0))
                  & " batched" & N.Wide_Real'Image (Together (Which)));
            end loop;

            B.Free (Data);
         end;
      end loop;
   end Batch_Width_Does_Not_Change_Result;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Valid_File_Parses'Access,
         "a well-formed container parses and reports its facts");
      Register_Routine
        (T, Typed_Accessors'Access,
         "typed accessors separate missing, mistyped and out-of-range keys");
      Register_Routine
        (T, Invalid_Magic'Access, "a corrupt magic is rejected");
      Register_Routine
        (T, Unsupported_Version'Access,
         "versions outside the supported window are rejected");
      Register_Routine
        (T, Excessive_Counts'Access,
         "counts beyond the configured limits are rejected");
      Register_Routine
        (T, Truncation_Is_Structured'Access,
         "truncation at every offset is a structured rejection");
      Register_Routine
        (T, Duplicate_Metadata_Key'Access,
         "a duplicate metadata key is rejected");
      Register_Routine
        (T, Duplicate_Tensor_Name'Access,
         "a duplicate tensor name is rejected");
      Register_Routine
        (T, Invalid_UTF8_Rejected'Access,
         "invalid UTF-8 in metadata is rejected");
      Register_Routine
        (T, Block_Misalignment'Access,
         "a quantized dimension that is not whole blocks is rejected");
      Register_Routine
        (T, Tensor_Out_Of_Bounds'Access,
         "a tensor range past the end of the file is rejected");
      Register_Routine
        (T, Trailing_Data_Policy'Access,
         "trailing data follows the configured policy");
      Register_Routine
        (T, Mutation_Corpus_Is_Controlled'Access,
         "a mutation campaign produces only controlled outcomes");
      Register_Routine
        (T, Fused_Dot_Matches_Decoder'Access,
         "the fused dot product agrees with the reference decoder");
      Register_Routine
        (T, Batch_Width_Does_Not_Change_Result'Access,
         "the number of vectors in a call does not change any of them");
   end Register_Tests;

end Tests.GGUF_Cases;
