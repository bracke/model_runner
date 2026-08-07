with AUnit.Assertions;

with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Numerics;
with Model_Runner.Quantization;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.UTF8;
with Model_Runner.Tokenizer;
with Model_Runner.Llama;

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

   --  Decoded values, against expectations worked out from the layout.
   --
   --  Every other check on these decoders compares them with themselves: the
   --  fused kernel against the decoder it is meant to match, one batch width
   --  against another. For the k-quant formats the fused path *is* the
   --  decoder, so that check says nothing at all about them, and conformance
   --  runs on an F32 model. Three of these decoders were rewritten with no
   --  independent test of what they produce.
   --
   --  These blocks are built byte by byte and the expected values derived by
   --  hand from the documented layouts, choosing scales of one and offsets of
   --  zero so the arithmetic stays checkable by eye. A sign, a bias or a
   --  scale in the wrong place fails here.
   procedure Decoders_Produce_The_Documented_Values
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Half precision 1.0 is 16#3C00#, little-endian.
      One_Low  : constant B.Byte := 16#00#;
      One_High : constant B.Byte := 16#3C#;

      Decoded : N.Real_Array (0 .. 255);
      Ok      : Boolean;

      procedure Check
        (Format   : Model_Runner.GGUF.Tensor_Type;
         Bytes    : B.Byte_Array;
         At_Index : N.Element_Count;
         Expected : N.Real)
      is
         Data : B.Byte_Array_Access;
      begin
         B.Allocate (Bytes'Length, Data);
         Data.all := Bytes;

         Q.Decode_Blocks (Format, Data.all, 0, 1, Decoded, Ok);
         Assert (Ok, "decode failed for "
                 & Model_Runner.GGUF.Type_Name (Format));
         Assert
           (Decoded (At_Index) = Expected,
            Model_Runner.GGUF.Type_Name (Format) & " element"
            & N.Element_Count'Image (At_Index) & " decoded as"
            & N.Real'Image (Decoded (At_Index)) & ", expected"
            & N.Real'Image (Expected));

         B.Free (Data);
      end Check;
   begin
      --  Q8_0: one scale, then thirty-two signed bytes. Value is scale times
      --  the byte, so with a scale of one the value is the byte itself.
      declare
         Block : B.Byte_Array (0 .. 33) := [others => 0];
      begin
         Block (0) := One_Low;
         Block (1) := One_High;
         Block (2) := 7;        --  element 0
         Block (3) := 16#FF#;   --  element 1, minus one
         Block (33) := 100;     --  element 31
         Check (Model_Runner.GGUF.Type_Q8_0, Block, 0, 7.0);
         Check (Model_Runner.GGUF.Type_Q8_0, Block, 1, -1.0);
         Check (Model_Runner.GGUF.Type_Q8_0, Block, 31, 100.0);
      end;

      --  Q4_0: sixteen bytes of two nibbles, both biased by eight. The low
      --  nibble of byte j is element j and the high nibble element j + 16.
      declare
         Block : B.Byte_Array (0 .. 17) := [others => 0];
      begin
         Block (0) := One_Low;
         Block (1) := One_High;
         Block (2) := 16#F1#;   --  low 1, high 15
         Check (Model_Runner.GGUF.Type_Q4_0, Block, 0, 1.0 - 8.0);
         Check (Model_Runner.GGUF.Type_Q4_0, Block, 16, 15.0 - 8.0);
      end;

      --  Q4_K: value is d times the sub-block scale times the nibble, less
      --  dmin times the sub-block minimum. With d one, dmin zero, and the
      --  first four sub-block scales one, the value is the nibble.
      declare
         Block : B.Byte_Array (0 .. 143) := [others => 0];
      begin
         Block (0) := One_Low;
         Block (1) := One_High;      --  d = 1
         Block (2) := 0;
         Block (3) := 0;             --  dmin = 0
         Block (4) := 1;             --  sub-block 0 scale
         Block (5) := 1;             --  sub-block 1 scale
         Block (16) := 16#32#;       --  low nibble 2, high nibble 3
         Check (Model_Runner.GGUF.Type_Q4_K, Block, 0, 2.0);
         Check (Model_Runner.GGUF.Type_Q4_K, Block, 32, 3.0);
      end;

      --  Q5_K: as Q4_K, with a fifth bit held apart. With that bit clear the
      --  value is the nibble again; with it set the nibble gains sixteen.
      declare
         Block : B.Byte_Array (0 .. 175) := [others => 0];
      begin
         Block (0) := One_Low;
         Block (1) := One_High;
         Block (4) := 1;             --  sub-block 0 scale
         Block (5) := 1;             --  sub-block 1 scale
         Block (16) := 16#01#;       --  the fifth bits: element 0 set
         Block (48) := 16#32#;       --  quants: low 2, high 3
         Check (Model_Runner.GGUF.Type_Q5_K, Block, 0, 2.0 + 16.0);
         Check (Model_Runner.GGUF.Type_Q5_K, Block, 1, 0.0);
      end;

      --  Q6_K: six bits per element, biased by thirty-two, scaled by a
      --  signed sub-block scale. With every scale one and every quant zero,
      --  each value is the bias alone.
      declare
         Block : B.Byte_Array (0 .. 209) := [others => 0];
      begin
         for Index in 192 .. 207 loop
            Block (B.Byte_Count (Index)) := 1;
         end loop;
         Block (208) := One_Low;
         Block (209) := One_High;
         Check (Model_Runner.GGUF.Type_Q6_K, Block, 0, -32.0);

         --  Two high bits of one lift the first element by sixteen.
         Block (128) := 16#01#;
         Check (Model_Runner.GGUF.Type_Q6_K, Block, 0, -16.0);
      end;
   end Decoders_Produce_The_Documented_Values;

   --  Metadata is shown with its type and value, and an array is described
   --  rather than dumped.
   --
   --  The dumping matters most: a tokenizer vocabulary is a metadata array of
   --  tens of thousands of strings, and a reader asking what is in a file did
   --  not ask for all of them on the terminal.
   procedure Metadata_Values_Are_Typed_And_Bounded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      function Contains (Item : String; Part : String) return Boolean is
      begin
         if Part'Length = 0 or else Part'Length > Item'Length then
            return Part'Length = 0;
         end if;
         for Start in Item'First .. Item'Last - Part'Length + 1 loop
            if Item (Start .. Start + Part'Length - 1) = Part then
               return True;
            end if;
         end loop;
         return False;
      end Contains;

      Image  : B.Byte_Array_Access;
      Parsed : Containers.Container;
      Status : E.Error_Info;

      Saw_String  : Boolean := False;
      Saw_Integer : Boolean := False;
      Saw_Array   : Boolean := False;
   begin
      Build_Valid (Image);
      Parse_Image (Image.all, Parsed, Status);
      Assert (E.Is_Ok (Status), "the fixture did not parse");

      for Index in 1 .. Containers.Metadata_Count (Parsed) loop
         declare
            Key   : constant String := Containers.Metadata_Key (Parsed, Index);
            Shown : constant String := Containers.Value_Image (Parsed, Index);
         begin
            --  Every entry says what it is.
            Assert (Shown'Length > 0, "no value image for " & Key);

            if Containers.Metadata_Kind (Parsed, Index)
                 = Model_Runner.GGUF.Value_String
            then
               Saw_String := True;
               Assert (Contains (Shown, "string"),
                       "a string was not named as one: " & Shown);

            elsif Containers.Metadata_Kind (Parsed, Index)
                    = Model_Runner.GGUF.Value_Array
            then
               Saw_Array := True;
               --  Described, not dumped: the count is there, the elements
               --  are not.
               Assert (Contains (Shown, "array"),
                       "an array was not named as one: " & Shown);
               Assert (Contains (Shown, "items"),
                       "an array did not report its length: " & Shown);

               --  The point of the check: no element content. The fixture's
               --  string array begins with "<unk>", so its presence would
               --  mean the elements had been written out. A length bound
               --  alone was too loose to catch that.
               Assert (not Contains (Shown, "<unk>"),
                       "an array was dumped rather than described: " & Shown);
               Assert (Shown'Length < 48,
                       "an array image grew beyond a description: " & Shown);

            elsif Containers.Metadata_Kind (Parsed, Index)
                    in Model_Runner.GGUF.Value_UInt32
                     | Model_Runner.GGUF.Value_Int32
                     | Model_Runner.GGUF.Value_UInt64
            then
               Saw_Integer := True;
               Assert (Contains (Shown, "int"),
                       "an integer was not named as one: " & Shown);
            end if;
         end;
      end loop;

      Assert (Saw_String and then Saw_Integer and then Saw_Array,
              "the fixture no longer covers a string, an integer and an array");

      Containers.Close (Parsed);
      B.Free (Image);
   end Metadata_Values_Are_Typed_And_Bounded;

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

   --  Nothing a model file says can steer the terminal.
   --
   --  Metadata values, metadata keys and tensor names are all attacker
   --  supplied. Written raw to a terminal, an escape sequence in any of them
   --  can clear the screen, retitle the window or hide what follows -- so a
   --  file could make `inspect` misreport itself. The escaping is the only
   --  thing standing between the file and the terminal, and it had no test.
   procedure Hostile_Text_Cannot_Reach_The_Terminal
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Text renames Model_Runner.Text;

      ESC : constant Character := Character'Val (16#1B#);
      BEL : constant Character := Character'Val (16#07#);
      DEL : constant Character := Character'Val (16#7F#);

      --  A screen clear, a bell, a delete, and a character outside ASCII that
      --  must survive: escaping must not break legitimate UTF-8 text.
      Hostile : constant String :=
        "safe" & ESC & "[2J" & BEL & DEL & "end"
        & Character'Val (16#C3#) & Character'Val (16#B8#);

      --  True when Item carries a byte that a terminal would act on.
      function Is_Clean (Item : String) return Boolean is
      begin
         for Char of Item loop
            if Character'Pos (Char) < 16#20#
              or else Character'Pos (Char) = 16#7F#
            then
               return False;
            end if;
         end loop;
         return True;
      end Is_Clean;

      --  Report whether Needle occurs in Haystack.
      function Contains (Haystack, Needle : String) return Boolean is
      begin
         if Needle'Length > Haystack'Length then
            return False;
         end if;
         for Start in Haystack'First .. Haystack'Last - Needle'Length + 1 loop
            if Haystack (Start .. Start + Needle'Length - 1) = Needle then
               return True;
            end if;
         end loop;
         return False;
      end Contains;

      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
      Item    : Containers.Container;
      Status  : E.Error_Info;
      Seen    : Boolean := False;
   begin
      --  The escaper itself, on the boundaries that matter.
      Assert (Is_Clean (Text.Escape_Controls (Hostile)),
              "escaping left a control character behind");
      Assert (Contains (Text.Escape_Controls (Hostile), "\x1B"),
              "the escape character was not rendered as an escape");
      Assert (Contains (Text.Escape_Controls (Hostile), "\x7F"),
              "delete was not rendered as an escape");
      Assert
        (Contains
           (Text.Escape_Controls (Hostile),
            Character'Val (16#C3#) & Character'Val (16#B8#)),
         "escaping altered bytes outside ASCII and would break UTF-8");
      Assert (Text.Has_Controls (Hostile), "a control character was not seen");
      Assert (not Text.Has_Controls ("plain text"),
              "clean text was reported as carrying controls");
      Assert (not Text.Has_Controls (""),
              "empty text was said to carry controls");

      --  And now through a file, which is where a defect would actually live:
      --  the escaping is applied at the call sites, not by the reader.
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "general.name", Hostile);
      Fixtures.Add_String (Builder, "general." & ESC & "[2Jkey", "value");
      Fixtures.Add_U32 (Builder, "llama.block_count", 1);
      Fixtures.Add_Tensor
        (Builder, "out" & ESC & "[2J.weight", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
      Fixtures.Build (Builder, Image);

      Parse_Image (Image.all, Item, Status);

      --  A reader is free to reject this outright. What it must not do is
      --  accept it and then render it raw.
      if not E.Is_Error (Status) then
         for Index in 1 .. Containers.Metadata_Count (Item) loop
            Assert
              (Is_Clean (Containers.Value_Image (Item, Index)),
               "a metadata value reached the terminal unescaped");
            Assert
              (Is_Clean
                 (Text.Escape_Controls
                    (Containers.Metadata_Key (Item, Index))),
               "a metadata key reached the terminal unescaped");

            if Containers.Metadata_Key (Item, Index) = "general.name" then
               Seen := True;
               Assert
                 (Contains (Containers.Value_Image (Item, Index), "\x1B"),
                  "the hostile value was dropped rather than escaped");
            end if;
         end loop;

         Assert (Seen, "the hostile value was not among the metadata");

         for Index in 1 .. Containers.Tensor_Count (Item) loop
            Assert
              (Is_Clean
                 (Text.Escape_Controls
                    (Containers.Tensor_Name (Item, Index))),
               "a tensor name reached the terminal unescaped");
         end loop;
      end if;

      Containers.Close (Item);
      B.Free (Image);
   end Hostile_Text_Cannot_Reach_The_Terminal;

   --  A hostile vocabulary is refused, and a sound one stays inside itself.
   --
   --  The vocabulary comes out of the model file: the token strings, the
   --  scores, the token types and the special-token identifiers. The
   --  identifiers are the dangerous ones because they are used as indices into
   --  the vocabulary, and a file naming token 999999 in a vocabulary of five
   --  must not be believed.
   procedure Hostile_Vocabulary_Stays_Inside_Itself
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Vocab renames Model_Runner.Tokenizer;
      use type Vocab.Token_Id;
      use type Vocab.Model_Kind;

      ESC : constant Character := Character'Val (16#1B#);

      --  Build a five-token vocabulary. One token is empty, one carries a
      --  terminal escape and one is shaped like a byte-fallback token that
      --  names no byte.
      procedure Write_Tokens (Builder : in out Fixtures.Builder) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, 5);
         Fixtures.String_Element (Builder, "<unk>");
         Fixtures.String_Element (Builder, "");
         Fixtures.String_Element (Builder, "a" & ESC & "[2J");
         Fixtures.String_Element (Builder, "<0xZZ>");
         Fixtures.String_Element (Builder, "b");
         Fixtures.End_Array (Builder);
      end Write_Tokens;

      --  Load a built container and report what the tokenizer made of it.
      procedure Load_Built
        (Builder : in out Fixtures.Builder;
         Words   : in out Vocab.Vocabulary;
         Outcome : out E.Error_Info)
      is
         Image : B.Byte_Array_Access;
         Item  : Containers.Container;
         Parse : E.Error_Info;
      begin
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Parse);
         Assert (E.Is_Ok (Parse),
                 "the fixture container did not parse: "
                 & E.Error_Code'Image (Parse.Code));

         Vocab.Load (Words, Item, Status => Outcome);

         Containers.Close (Item);
         B.Free (Image);
      end Load_Built;

      Builder : Fixtures.Builder;
      Words   : Vocab.Vocabulary;
      Status  : E.Error_Info;

      --  A key naming a token that does not exist stops the load.
      procedure Refuses_Absent_Token (Key : String) is
      begin
         Write_Tokens (Builder);
         Fixtures.Add_U32 (Builder, Key, 999_999);
         Load_Built (Builder, Words, Status);

         Assert (E.Is_Error (Status),
                 "an identifier naming no token was accepted for " & Key);
         Assert (Status.Code = E.GGUF_Metadata_Out_Of_Range,
                 "the wrong diagnostic for " & Key & ": "
                 & E.Error_Code'Image (Status.Code));
         Vocab.Close (Words);
      end Refuses_Absent_Token;
   begin
      --  A declared identifier that names no token is refused. Ignoring it
      --  would tokenize as though the file had declared nothing, which changes
      --  the prompt the model sees without saying so.
      Refuses_Absent_Token ("tokenizer.ggml.bos_token_id");
      Refuses_Absent_Token ("tokenizer.ggml.eos_token_id");
      Refuses_Absent_Token ("tokenizer.ggml.unknown_token_id");

      --  A score or token-type table that is there but does not match the
      --  vocabulary is refused. Scores decide which merge wins, so dropping a
      --  short table quietly tokenizes the same text differently.
      Write_Tokens (Builder);
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.scores", G.Value_Float32, 3);
      for Index in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.0);
      end loop;
      Fixtures.End_Array (Builder);
      Load_Built (Builder, Words, Status);
      Assert (Status.Code = E.Tokenizer_Invalid_Scores,
              "a score table of the wrong length was accepted: "
              & E.Error_Code'Image (Status.Code));
      Vocab.Close (Words);

      Write_Tokens (Builder);
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.token_type", G.Value_Int32, 2);
      for Index in 1 .. 2 loop
         Fixtures.Int32_Element (Builder, 1);
      end loop;
      Fixtures.End_Array (Builder);
      Load_Built (Builder, Words, Status);
      Assert (Status.Code = E.Tokenizer_Invalid_Token_Type,
              "a token-type table of the wrong length was accepted: "
              & E.Error_Code'Image (Status.Code));
      Vocab.Close (Words);

      --  Tables of the right length are still accepted, so the check cannot
      --  be satisfied by refusing every table.
      Write_Tokens (Builder);
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.scores", G.Value_Float32, 5);
      for Index in 1 .. 5 loop
         Fixtures.Float_Element (Builder, 0.0);
      end loop;
      Fixtures.End_Array (Builder);
      Load_Built (Builder, Words, Status);
      Assert (E.Is_Ok (Status),
              "a score table matching the vocabulary was refused: "
              & E.Error_Code'Image (Status.Code));
      Vocab.Close (Words);

      --  A flag that is present but not a boolean is refused for the same
      --  reason: the file is wrong about itself.
      Write_Tokens (Builder);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.add_bos_token", 7);
      Load_Built (Builder, Words, Status);
      Assert (E.Is_Error (Status),
              "a mistyped add_bos_token was accepted");
      Vocab.Close (Words);

      --  Minus one means the model has no such token, and is not an error.
      Write_Tokens (Builder);
      Fixtures.Add_I32 (Builder, "tokenizer.ggml.bos_token_id", -1);
      Load_Built (Builder, Words, Status);
      Assert (E.Is_Ok (Status),
              "an explicit absence was refused: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vocab.Beginning_Token (Words) = Vocab.No_Token,
              "minus one did not read as no token");
      Vocab.Close (Words);

      --  A sound vocabulary loads, and everything asked of it stays inside it.
      Write_Tokens (Builder);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 0);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 4);
      Load_Built (Builder, Words, Status);

      Assert (E.Is_Ok (Status),
              "a sound vocabulary was refused: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vocab.Kind (Words) = Vocab.Kind_SentencePiece,
              "the vocabulary loaded as the wrong model");
      Assert (Vocab.Size (Words) = 5,
              "the vocabulary is not the size the file declared:"
              & Natural'Image (Vocab.Size (Words)));
      Assert (Vocab.Is_Valid (Words, Vocab.Beginning_Token (Words))
              and then Vocab.Is_Valid (Words, Vocab.End_Token (Words)),
              "an identifier inside the vocabulary was not usable");

      --  Reading outside the vocabulary is answered, not attempted.
      for Token of Vocab.Token_Array'
        [Vocab.No_Token, 5, 999_999, Vocab.Token_Id'Last]
      loop
         Assert (not Vocab.Is_Valid (Words, Token),
                 "a token outside the vocabulary was called valid:"
                 & Vocab.Token_Id'Image (Token));
         Assert (Vocab.Token_Text (Words, Token) = "",
                 "a token outside the vocabulary produced text");
      end loop;

      --  Encoding never produces an identifier the rest of the engine would
      --  then use as an index.
      declare
         Tokens  : Vocab.Token_Array (1 .. 64);
         Last    : Natural;
         Outcome : E.Error_Info;
      begin
         Vocab.Encode
           (Words, "ab" & ESC & " zz", True, True, Tokens, Last, Outcome);
         if E.Is_Ok (Outcome) then
            for Index in 1 .. Last loop
               Assert (Vocab.Is_Valid (Words, Tokens (Index)),
                       "encoding produced a token outside the vocabulary:"
                       & Vocab.Token_Id'Image (Tokens (Index)));
            end loop;
         end if;
      end;

      Vocab.Close (Words);
   end Hostile_Vocabulary_Stays_Inside_Itself;

   --  Architecture metadata that is present and wrong stops preparation.
   --
   --  Every one of these keys is optional, so an absent one falls back to a
   --  default and that is right: not every model states its rotary width or
   --  its epsilon. A key that is there and names a value the profile cannot
   --  use is a different thing. Falling back then builds a model of a
   --  different shape than the file describes and says nothing about it,
   --  which is the same trade the tokenizer used to make.
   procedure Wrong_Architecture_Metadata_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  A container carrying a valid llama configuration and nothing else.
      --  Preparation gets past the configuration and then fails for want of
      --  tensors, which is what makes this a usable probe: the interesting
      --  question is only ever which diagnostic comes back.
      procedure Write_Configuration (Builder : in out Fixtures.Builder) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Add_U32 (Builder, "llama.context_length", 16);
         Fixtures.Add_U32 (Builder, "llama.embedding_length", 8);
         Fixtures.Add_U32 (Builder, "llama.block_count", 2);
         Fixtures.Add_U32 (Builder, "llama.feed_forward_length", 12);
         Fixtures.Add_U32 (Builder, "llama.attention.head_count", 2);
      end Write_Configuration;

      --  Prepare a built container and report the diagnostic.
      function Outcome_Of (Builder : in out Fixtures.Builder) return E.Error_Code
      is
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Parse  : E.Error_Info;
         Status : E.Error_Info;
         Result : E.Error_Code;
         Prepared : Model_Runner.Llama.Model;
      begin
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Parse);
         Assert (E.Is_Ok (Parse),
                 "the fixture container did not parse: "
                 & E.Error_Code'Image (Parse.Code));

         declare
            Copy   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Copy'Access);
         begin
            Model_Runner.Llama.Prepare
              (Prepared, Item, Source, Status => Status);
            Result := Status.Code;
         end;

         Model_Runner.Llama.Close (Prepared, Status);
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Outcome_Of;

      Builder : Fixtures.Builder;

      --  The diagnostic for a sound configuration, whatever it is. Anything
      --  that stops preparation earlier must differ from it, or the test would
      --  pass on a file that was never looked at.
      Sound : E.Error_Code;
   begin
      Write_Configuration (Builder);
      Sound := Outcome_Of (Builder);
      Assert (Sound /= E.No_Error,
              "a container with no tensors prepared successfully");

      --  Out of range: more key-value heads than heads, a rotary width wider
      --  than the head size, an epsilon outside the accepted interval, and a
      --  rotary base below it.
      Write_Configuration (Builder);
      Fixtures.Add_U32 (Builder, "llama.attention.head_count_kv", 99);
      Assert (Outcome_Of (Builder) = E.GGUF_Metadata_Out_Of_Range,
              "an impossible key-value head count was accepted");

      Write_Configuration (Builder);
      Fixtures.Add_U32 (Builder, "llama.rope.dimension_count", 4096);
      Assert (Outcome_Of (Builder) = E.GGUF_Metadata_Out_Of_Range,
              "a rotary width wider than the head size was accepted");

      Write_Configuration (Builder);
      Fixtures.Add_F32
        (Builder, "llama.attention.layer_norm_rms_epsilon", 7.0);
      Assert (Outcome_Of (Builder) = E.GGUF_Metadata_Out_Of_Range,
              "an epsilon outside the accepted interval was accepted");

      Write_Configuration (Builder);
      Fixtures.Add_F32 (Builder, "llama.rope.freq_base", 0.0);
      Assert (Outcome_Of (Builder) = E.GGUF_Metadata_Out_Of_Range,
              "a rotary base below the accepted interval was accepted");

      --  Wrong type: the profile reads this as a number and the file wrote a
      --  string, so the file is wrong about itself.
      Write_Configuration (Builder);
      Fixtures.Add_String (Builder, "llama.rope.dimension_count", "many");
      Assert (Outcome_Of (Builder) = E.GGUF_Metadata_Type_Mismatch,
              "a rotary width written as a string was accepted");

      --  Absent stays absent: a configuration that states none of these
      --  optional keys still gets as far as one that states them soundly.
      Write_Configuration (Builder);
      Fixtures.Add_U32 (Builder, "llama.attention.head_count_kv", 1);
      Fixtures.Add_U32 (Builder, "llama.rope.dimension_count", 4);
      Assert (Outcome_Of (Builder) = Sound,
              "a sound optional key changed the outcome");
   end Wrong_Architecture_Metadata_Is_Refused;

   --  Structural refusals a mutation campaign reaches only by chance.
   --
   --  A sweep that disabled each refusal in the reader one at a time found
   --  these producing no test failure, and none of their codes appeared in any
   --  test. The container fuzzer does reach some of them, but it asserts only
   --  that the outcome was controlled, never which refusal fired, so a
   --  refusal that started reporting the wrong thing would still look fine.
   procedure Structural_Refusals_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Build a container from a builder already primed with the fault and
      --  report the code the reader gives it.
      function Outcome (Builder : in out Fixtures.Builder) return E.Error_Code is
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Status : E.Error_Info;
         Result : E.Error_Code;
      begin
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Status);
         Result := Status.Code;
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Outcome;

      --  A container that is sound apart from what the caller adds.
      procedure Sound (Builder : in out Fixtures.Builder) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
      end Sound;

      Builder : Fixtures.Builder;
   begin
      --  A key with no name. Nothing can ever ask for it, and a file carrying
      --  one is malformed rather than merely odd.
      Sound (Builder);
      Fixtures.Add_String (Builder, "", "value");
      Assert (Outcome (Builder) = E.GGUF_Empty_Metadata_Key,
              "a metadata key with no name was accepted");

      --  A tensor with no name, which the architecture profile could never
      --  resolve.
      Sound (Builder);
      Fixtures.Add_Tensor
        (Builder, "", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
      Assert (Outcome (Builder) = E.GGUF_Empty_Tensor_Name,
              "a tensor with no name was accepted");

      --  An alignment that is not a power of two. The data section is placed
      --  by it, so a bad one puts every tensor somewhere else.
      Sound (Builder);
      Fixtures.Add_U32 (Builder, "general.alignment", 3);
      Assert (Outcome (Builder) = E.GGUF_Invalid_Alignment,
              "an alignment that is not a power of two was accepted");

      Sound (Builder);
      Fixtures.Add_U32 (Builder, "general.alignment", 0);
      Assert (Outcome (Builder) = E.GGUF_Invalid_Alignment,
              "an alignment of zero was accepted");

      Sound (Builder);
      Fixtures.Add_U32 (Builder, "general.alignment", 131_072);
      Assert (Outcome (Builder) = E.GGUF_Invalid_Alignment,
              "an alignment past the accepted maximum was accepted");

      --  A power of two inside the range is still accepted, so the check
      --  cannot be satisfied by refusing every alignment.
      Sound (Builder);
      Fixtures.Add_U32 (Builder, "general.alignment", 64);
      Assert (Outcome (Builder) = E.No_Error,
              "a sound alignment was refused");

      --  A string past the limit. The reader reads a length from the file
      --  before it has the bytes to back it, so this is the bound that stands
      --  between a declared length and an allocation.
      --  A string past the limit. Reached by tightening the limit rather
      --  than by building a sixteen-megabyte fixture: the reader takes a
      --  length from the file before it has the bytes to back it, and what
      --  matters is that the bound is applied, not how large it is.
      declare
         Tight : Model_Runner.Limits.Model_Limits :=
           Model_Runner.Limits.Default_Model_Limits;
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Tight.Max_String_Bytes := 32;

         Sound (Builder);
         Fixtures.Add_String
           (Builder, "general.name", [1 .. 40 => 'x']);
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Status, Tight);

         Assert (Status.Code = E.GGUF_Invalid_String_Length,
                 "a string past the length limit was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Containers.Close (Item);
         B.Free (Image);
      end;

   end Structural_Refusals_Report_Themselves;

   --  Every refusal the tokenizer can give, reported by name.
   --
   --  The vocabulary is the largest attacker-controlled structure in a model
   --  file, and eight of its refusals were named by no test. Asserting only
   --  that loading failed would pass on a loader that refused everything for
   --  the wrong reason, which is what these codes exist to distinguish.
   procedure Tokenizer_Refusals_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Vocab renames Model_Runner.Tokenizer;

      --  Load a built container and report the code.
      function Loading (Builder : in out Fixtures.Builder) return E.Error_Code is
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Words  : Vocab.Vocabulary;
         Parse  : E.Error_Info;
         Status : E.Error_Info;
         Result : E.Error_Code;
      begin
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Parse);
         Assert (E.Is_Ok (Parse),
                 "the fixture container did not parse: "
                 & E.Error_Code'Image (Parse.Code));

         Vocab.Load (Words, Item, Status => Status);
         Result := Status.Code;

         Vocab.Close (Words);
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Loading;

      --  A container with an architecture and nothing else.
      procedure Bare (Builder : in out Fixtures.Builder) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
      end Bare;

      --  Three usable tokens.
      procedure With_Tokens (Builder : in out Fixtures.Builder) is
      begin
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, 3);
         Fixtures.String_Element (Builder, "<unk>");
         Fixtures.String_Element (Builder, "a");
         Fixtures.String_Element (Builder, "b");
         Fixtures.End_Array (Builder);
      end With_Tokens;

      Builder : Fixtures.Builder;
   begin
      --  A vocabulary that was never loaded. Encoding through it is a
      --  mistake in the caller rather than in any file, and the answer says
      --  so instead of returning no tokens as though the text were empty.
      declare
         Empty  : Vocab.Vocabulary;
         Tokens : Vocab.Token_Array (1 .. 8);
         Last   : Natural;
         Status : E.Error_Info;
      begin
         Vocab.Encode (Empty, "ab", False, False, Tokens, Last, Status);
         Assert (Status.Code = E.Tokenizer_Invalid_Vocabulary,
                 "encoding through an unloaded vocabulary was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Vocab.Close (Empty);
      end;

      --  A token longer than the reader will hold. A vocabulary entry is
      --  bounded because every one of them is copied into a pool, and a file
      --  declaring a longer one is describing something this engine cannot
      --  represent.
      Bare (Builder);
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.tokens", G.Value_String, 2);
      Fixtures.String_Element (Builder, "<unk>");
      Fixtures.String_Element (Builder, [1 .. 2_048 => 'x']);
      Fixtures.End_Array (Builder);
      Assert (Loading (Builder) = E.Tokenizer_Invalid_Token_Text,
              "a token past the length limit was accepted");

      --  No tokenizer at all. A file may legitimately carry no tokenizer, but
      --  this engine cannot generate without one and says which is missing.
      Bare (Builder);
      With_Tokens (Builder);
      Assert (Loading (Builder) = E.Tokenizer_Missing_Model,
              "a file with no tokenizer model was accepted");

      --  A tokenizer this engine does not implement. Named rather than
      --  treated as absent: the difference is whether the reader looks for a
      --  missing key or a different program.
      Bare (Builder);
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "bpe");
      With_Tokens (Builder);
      Assert (Loading (Builder) = E.Tokenizer_Unsupported_Model,
              "an unsupported tokenizer model was accepted");

      --  A model that declares a tokenizer and no tokens.
      Bare (Builder);
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
      Assert (Loading (Builder) = E.Tokenizer_Missing_Tokens,
              "a tokenizer with no token list was accepted");

      --  Everything sound, so the refusals above cannot come from a loader
      --  that refuses whatever it is given.
      Bare (Builder);
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
      With_Tokens (Builder);
      Assert (Loading (Builder) = E.No_Error,
              "a sound vocabulary was refused");

      --  Encoding, against that same sound vocabulary.
      declare
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Words  : Vocab.Vocabulary;
         Parse  : E.Error_Info;
         Status : E.Error_Info;
         Tokens : Vocab.Token_Array (1 .. 32);
         Last   : Natural;
      begin
         Bare (Builder);
         Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
         With_Tokens (Builder);
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Parse);
         Vocab.Load (Words, Item, Status => Status);
         Assert (E.Is_Ok (Status), "the sound vocabulary did not load");

         --  Text that is not UTF-8 is refused before it is tokenized, so no
         --  byte of it reaches the merge loop.
         Vocab.Encode
           (Words, "ab" & Character'Val (16#FF#) & Character'Val (16#FE#),
            False, False, Tokens, Last, Status);
         Assert (Status.Code = E.Tokenizer_Invalid_UTF8,
                 "input that is not UTF-8 was encoded: "
                 & E.Error_Code'Image (Status.Code));

         --  A buffer too small for the result is reported rather than
         --  overrun or quietly truncated.
         declare
            Cramped : Vocab.Token_Array (1 .. 1);
         begin
            Vocab.Encode
              (Words, "abababab", False, False, Cramped, Last, Status);
            Assert (Status.Code = E.Tokenizer_Buffer_Too_Small,
                    "a buffer too small for the tokens was accepted: "
                    & E.Error_Code'Image (Status.Code));
         end;

         --  Text with more symbols than the merge loop will hold. The bound
         --  is on code points rather than bytes, so this is the count the
         --  loop works with rather than the size of the string.
         --
         --  Two guards give this answer -- one counting the code points
         --  before the loop, one stopping the loop when it fills -- and this
         --  holds the pair rather than either. Measured: disabling either
         --  alone changes nothing, and disabling both does not merely lose
         --  the diagnostic, it reaches an internal invariant violation. They
         --  are load-bearing for more than the message.
         declare
            Long : constant String (1 .. 65_537) := [others => 'a'];
         begin
            Vocab.Encode (Words, Long, False, False, Tokens, Last, Status);
            Assert (Status.Code = E.Tokenizer_Input_Too_Long,
                    "text past the symbol limit was encoded: "
                    & E.Error_Code'Image (Status.Code));
         end;

         --  And a sound encode still works.
         Vocab.Encode (Words, "ab", False, False, Tokens, Last, Status);
         Assert (E.Is_Ok (Status),
                 "a sound encode failed: " & E.Error_Code'Image (Status.Code));
         Assert (Last > 0, "a sound encode produced no tokens");

         Vocab.Close (Words);
         Containers.Close (Item);
         B.Free (Image);
      end;
   end Tokenizer_Refusals_Report_Themselves;

   --  Every architecture refusal, reported by name.
   --
   --  A model file describes a shape, and this profile runs one shape. Eleven
   --  refusals say which way a file falls outside it, and none of them was
   --  named by a test. Distinguishing them is the point: "unsupported
   --  architecture" sends the reader to find another program, "invalid
   --  dimensions" says this file is inconsistent with itself.
   procedure Architecture_Refusals_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Prepare a built container and report the diagnostic. A container
      --  with no tensors gets past the configuration and stops for want of
      --  them, so anything reported before that came from the configuration.
      function Outcome (Builder : in out Fixtures.Builder) return E.Error_Code
      is
         Image    : B.Byte_Array_Access;
         Item     : Containers.Container;
         Parse    : E.Error_Info;
         Status   : E.Error_Info;
         Result   : E.Error_Code;
         Prepared : Model_Runner.Llama.Model;
      begin
         Fixtures.Build (Builder, Image);
         Parse_Image (Image.all, Item, Parse);
         Assert (E.Is_Ok (Parse),
                 "the fixture container did not parse: "
                 & E.Error_Code'Image (Parse.Code));

         declare
            Copy   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Copy'Access);
         begin
            Model_Runner.Llama.Prepare
              (Prepared, Item, Source, Status => Status);
            Result := Status.Code;
         end;

         Model_Runner.Llama.Close (Prepared, Status);
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Outcome;

      --  A configuration this profile accepts, apart from what is added.
      --
      --  The widths are parameters rather than keys to be written over: a key
      --  written twice makes the container itself invalid, and the reader
      --  refuses it before the profile ever sees the shape.
      procedure Sound
        (Builder   : in out Fixtures.Builder;
         Embedding : Interfaces.Unsigned_32 := 8;
         Heads     : Interfaces.Unsigned_32 := 2) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Add_U32 (Builder, "llama.context_length", 16);
         Fixtures.Add_U32 (Builder, "llama.embedding_length", Embedding);
         Fixtures.Add_U32 (Builder, "llama.block_count", 2);
         Fixtures.Add_U32 (Builder, "llama.feed_forward_length", 12);
         Fixtures.Add_U32 (Builder, "llama.attention.head_count", Heads);

         --  A tokenizer too, because preparation loads one before it looks
         --  for tensors: without it every case here would stop at the
         --  tokenizer and none would reach the shape being tested.
         Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, 3);
         Fixtures.String_Element (Builder, "<unk>");
         Fixtures.String_Element (Builder, "a");
         Fixtures.String_Element (Builder, "b");
         Fixtures.End_Array (Builder);
      end Sound;

      Builder : Fixtures.Builder;
   begin
      --  Nothing says what the file is.
      Fixtures.Reset (Builder);
      Fixtures.Add_U32 (Builder, "llama.block_count", 2);
      Assert (Outcome (Builder) = E.Arch_Missing_Identifier,
              "a file naming no architecture was accepted");

      --  It says what it is, and it is not this.
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "mamba");
      Assert (Outcome (Builder) = E.Arch_Unsupported,
              "an architecture this profile does not run was accepted");

      --  A width that does not divide into heads. The head size is derived
      --  from it, so a remainder means the file describes a model this
      --  arithmetic cannot express.
      Sound (Builder, Embedding => 9);
      Assert (Outcome (Builder) = E.Arch_Invalid_Dimensions,
              "an embedding width that does not divide into heads was accepted");

      --  Heads that do not divide into key-value heads.
      Sound (Builder, Embedding => 12, Heads => 3);
      Fixtures.Add_U32 (Builder, "llama.attention.head_count_kv", 2);
      Assert (Outcome (Builder) = E.Arch_Invalid_Head_Counts,
              "head counts that do not divide were accepted");

      --  A rotary width that is not even. Rotary encoding works on pairs.
      Sound (Builder);
      Fixtures.Add_U32 (Builder, "llama.rope.dimension_count", 3);
      Assert (Outcome (Builder) = E.Arch_Invalid_Rope,
              "an odd rotary width was accepted");

      --  A rotary scaling that changes the position mapping.
      Sound (Builder);
      Fixtures.Add_String (Builder, "llama.rope.scaling.type", "yarn");
      Assert (Outcome (Builder) = E.Arch_Unsupported_Rope_Scaling,
              "an unsupported rotary scaling was accepted");

      --  Features that make it a different model. The key being there is
      --  enough: its value would only say how different.
      Sound (Builder);
      Fixtures.Add_U32 (Builder, "llama.expert_count", 8);
      Assert (Outcome (Builder) = E.Arch_Unsupported_Feature,
              "a mixture-of-experts model was accepted");

      Sound (Builder);
      Fixtures.Add_U32 (Builder, "llama.attention.sliding_window", 4096);
      Assert (Outcome (Builder) = E.Arch_Unsupported_Feature,
              "a sliding-window model was accepted");

      --  A sound configuration reaches the tensors and stops for want of
      --  them, which is what makes every refusal above a configuration one.
      Sound (Builder);
      Assert (Outcome (Builder) = E.Arch_Missing_Tensor,
              "a sound configuration did not reach the tensors");

      --  A tensor that is there and the wrong shape.
      Sound (Builder);
      Fixtures.Add_Tensor
        (Builder, "token_embd.weight", [4], G.Type_F32,
         Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
      Assert (Outcome (Builder) = E.Arch_Invalid_Tensor_Shape,
              "an embedding tensor of the wrong shape was accepted");
   end Architecture_Refusals_Report_Themselves;

   --  A container that stops short, and tensors whose shape is not a shape.
   --
   --  Truncation is checked elsewhere at every byte offset, but only for
   --  producing some diagnostic. These check which one: a file that ends
   --  inside a field is truncated, a rank of zero or past the limit is an
   --  invalid rank, and an extent of zero is an invalid dimension. A reader
   --  that answered "truncated" to all three would pass the other test.
   procedure Shape_Refusals_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Parse a prefix of a sound container.
      function Cut_At (Length : B.Byte_Count) return E.Error_Code is
         Image  : B.Byte_Array_Access;
         Item   : Containers.Container;
         Status : E.Error_Info;
         Result : E.Error_Code;
      begin
         Build_Valid (Image);
         Parse_Image
           (Image.all (Image.all'First .. Image.all'First + Length - 1),
            Item, Status);
         Result := Status.Code;
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Cut_At;

      --  Build a container carrying one tensor of the given shape.
      function Shaped (Dimensions : Fixtures.Dimension_List) return E.Error_Code
      is
         Builder : Fixtures.Builder;
         Image   : B.Byte_Array_Access;
         Item    : Containers.Container;
         Status  : E.Error_Info;
         Result  : E.Error_Code;
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Add_Tensor
           (Builder, "weight", Dimensions, G.Type_F32,
            Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
         Fixtures.Build (Builder, Image);

         Parse_Image (Image.all, Item, Status);
         Result := Status.Code;
         Containers.Close (Item);
         B.Free (Image);
         return Result;
      end Shaped;
   begin
      --  Inside the magic, inside the header, and part way through the body.
      --  Every one of them ends in a field the reader was reading.
      Assert (Cut_At (2) = E.GGUF_Truncated,
              "a file ending inside the magic was not reported as truncated: "
              & E.Error_Code'Image (Cut_At (2)));
      Assert (Cut_At (12) = E.GGUF_Truncated,
              "a file ending inside the header was not reported as truncated: "
              & E.Error_Code'Image (Cut_At (12)));
      Assert (Cut_At (40) = E.GGUF_Truncated,
              "a file ending inside the metadata was not reported as"
              & " truncated: " & E.Error_Code'Image (Cut_At (40)));

      --  A rank past what the reader accepts. Four is the limit, so five is
      --  one too many rather than an arbitrary large number.
      Assert (Shaped ([2, 1, 1, 1, 1]) = E.GGUF_Invalid_Tensor_Rank,
              "a tensor of rank five was accepted: "
              & E.Error_Code'Image (Shaped ([2, 1, 1, 1, 1])));

      --  An extent of zero. The tensor would hold nothing and every stride
      --  computed from it would be meaningless.
      Assert (Shaped ([4, 0]) = E.GGUF_Invalid_Tensor_Dimension,
              "a tensor with an extent of zero was accepted: "
              & E.Error_Code'Image (Shaped ([4, 0])));

      --  A shape the reader accepts, so none of the above can come from a
      --  reader that refuses every tensor.
      Assert (Shaped ([4]) = E.No_Error,
              "a sound tensor shape was refused: "
              & E.Error_Code'Image (Shaped ([4])));
   end Shape_Refusals_Report_Themselves;

   --  Refusals that can only be reached by writing a sound file and then
   --  making one field wrong.
   --
   --  The builder writes correct containers by construction, so a type code
   --  the format does not define, a tensor placed off its alignment, and two
   --  tensors sharing bytes cannot be built -- only edited in afterwards. The
   --  builder records where it put each field and the test asks for the
   --  position by name, so this does not become a table of byte offsets that
   --  rots the moment the layout moves.
   procedure Edited_Fields_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Build a container with two tensors and one array, then hand the
      --  caller the image and the builder that knows where things are.
      procedure Written
        (Builder : in out Fixtures.Builder;
         Image   : out B.Byte_Array_Access) is
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Begin_Array
           (Builder, "fixture.list", G.Value_Int32, 2);
         Fixtures.Int32_Element (Builder, 1);
         Fixtures.Int32_Element (Builder, 2);
         Fixtures.End_Array (Builder);
         Fixtures.Add_Tensor
           (Builder, "first.weight", [4], G.Type_F32,
            Fixtures.Encode_F32 (Fixtures.Sequence (4, 1)));
         Fixtures.Add_Tensor
           (Builder, "second.weight", [4], G.Type_F32,
            Fixtures.Encode_F32 (Fixtures.Sequence (4, 2)));
         Fixtures.Build (Builder, Image);
      end Written;

      --  Parse an edited image and report the code.
      function Reading (Image : B.Byte_Array) return E.Error_Code is
         Item   : Containers.Container;
         Status : E.Error_Info;
         Result : E.Error_Code;
      begin
         Parse_Image (Image, Item, Status);
         Result := Status.Code;
         Containers.Close (Item);
         return Result;
      end Reading;

      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
      Where   : B.Byte_Count;
   begin
      --  Unedited, the container is sound. Everything below is one field
      --  away from this.
      Written (Builder, Image);
      Assert (Reading (Image.all) = E.No_Error,
              "the unedited fixture was refused: "
              & E.Error_Code'Image (Reading (Image.all)));
      B.Free (Image);

      --  A metadata value type the format does not define.
      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Metadata_Value_Type, Owner => 1);
      Assert (Where > 0, "the builder recorded no metadata value type");
      Fixtures.Poke_U32 (Image.all, Where, 4_000);
      Assert (Reading (Image.all) = E.GGUF_Unknown_Value_Type,
              "an undefined value type was accepted");
      B.Free (Image);

      --  An array element type that names nothing is an unknown value type,
      --  the same answer as for a value. The separate array diagnostic is for
      --  an element type the format defines and an array may not hold: an
      --  array of arrays, which has no length the reader could trust.
      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Array_Element_Type, Owner => 2);
      Assert (Where > 0, "the builder recorded no array element type");
      Fixtures.Poke_U32 (Image.all, Where, 4_000);
      Assert (Reading (Image.all) = E.GGUF_Unknown_Value_Type,
              "an undefined array element type was accepted");
      B.Free (Image);

      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Array_Element_Type, Owner => 2);
      Fixtures.Poke_U32 (Image.all, Where, G.Value_Code (G.Value_Array));
      Assert (Reading (Image.all) = E.GGUF_Invalid_Array_Element_Type,
              "an array of arrays was accepted");
      B.Free (Image);

      --  A tensor type the format does not define.
      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Tensor_Format, Owner => 1);
      Assert (Where > 0, "the builder recorded no tensor format");
      Fixtures.Poke_U32 (Image.all, Where, 4_000);
      Assert (Reading (Image.all) = E.GGUF_Unknown_Tensor_Type,
              "an undefined tensor type was accepted");
      B.Free (Image);

      --  A tensor that does not start on the alignment. Every offset in the
      --  data section is relative to it, so one tensor off the grid means the
      --  reader and the writer disagree about where the data begins.
      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Tensor_Offset, Owner => 2);
      Assert (Where > 0, "the builder recorded no tensor offset");
      Fixtures.Poke_U64 (Image.all, Where, 1);
      Assert (Reading (Image.all) = E.GGUF_Tensor_Offset_Misaligned,
              "a tensor off the alignment was accepted");
      B.Free (Image);

      --  Two tensors over the same bytes. Each is inside the file and the
      --  pair is still impossible.
      Written (Builder, Image);
      Where := Fixtures.Field_Position
        (Builder, Fixtures.Tensor_Offset, Owner => 2);
      Fixtures.Poke_U64 (Image.all, Where, 0);
      Assert (Reading (Image.all) = E.GGUF_Tensor_Overlap,
              "two tensors sharing bytes were accepted");
      B.Free (Image);
   end Edited_Fields_Report_Themselves;

   --  What a tensor view refuses about a shape it is asked to take.
   --
   --  A view is the only thing standing between a shape a file declared and
   --  an index into a buffer, so each way a shape can be impossible has its
   --  own answer: no shape at all, a quantized row that is not whole blocks,
   --  a format this build cannot decode, a buffer too small for the shape,
   --  and a multiply whose operand does not match.
   procedure View_Refusals_Report_Themselves
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tensors renames Model_Runner.Tensors;

      Room   : B.Byte_Array_Access := new B.Byte_Array (1 .. 4_096);
      Made   : Tensors.View;
      Status : E.Error_Info;

      --  Build a view and report the code.
      function Shaped
        (Format  : G.Tensor_Type;
         Rows    : N.Element_Count;
         Columns : N.Element_Count;
         Offset  : B.Byte_Count := 0) return E.Error_Code
      is
         Outcome : E.Error_Info;
         Ignored : Tensors.View;
      begin
         Tensors.Make (Format, Rows, Columns, Room, Offset, Ignored, Outcome);
         return Outcome.Code;
      end Shaped;
   begin
      Room.all := [others => 0];

      --  A shape with nothing in it.
      Assert (Shaped (G.Type_F32, 0, 4) = E.Tensor_Invalid_Shape,
              "a view with no rows was made: "
              & E.Error_Code'Image (Shaped (G.Type_F32, 0, 4)));
      Assert (Shaped (G.Type_F32, 4, 0) = E.Tensor_Invalid_Shape,
              "a view with no columns was made");

      --  A quantized row that is not a whole number of blocks. Q8_0 works
      --  thirty-two elements at a time, so twenty is half a block short.
      Assert (Shaped (G.Type_Q8_0, 1, 20) = E.Tensor_Block_Misaligned,
              "a quantized row that is not whole blocks was made: "
              & E.Error_Code'Image (Shaped (G.Type_Q8_0, 1, 20)));

      --  A format this build does not decode. The container may carry it and
      --  the engine still cannot run it, and the two are different refusals.
      Assert (Shaped (G.Type_Q4_1, 1, 32) = E.Tensor_Format_Unsupported,
              "a view over an undecodable format was made: "
              & E.Error_Code'Image (Shaped (G.Type_Q4_1, 1, 32)));

      --  A shape that does not fit the buffer it is placed in.
      Assert (Shaped (G.Type_F32, 1_000, 1_000) = E.Tensor_Out_Of_Bounds,
              "a view past the end of its buffer was made: "
              & E.Error_Code'Image (Shaped (G.Type_F32, 1_000, 1_000)));

      --  A shape that fits is made, so none of the above can come from a
      --  constructor that refuses everything.
      Tensors.Make (G.Type_F32, 4, 8, Room, 0, Made, Status);
      Assert (E.Is_Ok (Status),
              "a sound shape was refused: " & E.Error_Code'Image (Status.Code));
      Assert (Tensors.Is_Present (Made), "a made view says it is not present");

      --  And a multiply whose operand does not match the shape.
      declare
         Vector : constant N.Real_Array (1 .. 3) := [others => 0.0];
         Target : N.Real_Array (1 .. 4) := [others => 0.0];
         Outcome : E.Error_Info;
      begin
         Tensors.Mat_Vec (Made, Vector, Target, Outcome);
         Assert (Outcome.Code = E.Tensor_Shape_Mismatch,
                 "a vector of the wrong length was multiplied: "
                 & E.Error_Code'Image (Outcome.Code));

         declare
            Right : constant N.Real_Array (1 .. 8) := [others => 1.0];
         begin
            Tensors.Mat_Vec (Made, Right, Target, Outcome);
            Assert (E.Is_Ok (Outcome),
                    "a matching multiply was refused: "
                    & E.Error_Code'Image (Outcome.Code));
         end;
      end;

      B.Free (Room);
   end View_Refusals_Report_Themselves;

   --  What the UTF-8 validator must refuse, and what it must not.
   --
   --  Everything the program says about text safety rests on this: a metadata
   --  string, a token, a prompt file and a chat template are each accepted
   --  only if this says they are valid. Nothing exercised it directly.
   --
   --  The refusals that matter are the ones a length check alone would let
   --  through. An overlong encoding spells a character the short way round --
   --  C0 80 is a NUL wearing two bytes -- and a validator that accepts one
   --  lets a byte past every check that looked for it in its ordinary form.
   procedure UTF8_Refuses_What_It_Must
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package UTF8 renames Model_Runner.UTF8;

      --  A string from byte values, so the test says what it means.
      function Bytes (Values : B.Byte_Array) return String is
         Result : String (1 .. Values'Length);
         At_Index : Natural := 0;
      begin
         for Value of Values loop
            At_Index := At_Index + 1;
            Result (At_Index) := Character'Val (Value);
         end loop;
         return Result;
      end Bytes;
   begin
      --  Accepted: the four lengths, at their boundaries.
      Assert (UTF8.Is_Valid (""), "the empty string was refused");
      Assert (UTF8.Is_Valid ("hello"), "ASCII was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#C2#, 16#80#])),
              "the shortest two-byte sequence was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#DF#, 16#BF#])),
              "the longest two-byte sequence was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#E0#, 16#A0#, 16#80#])),
              "the shortest three-byte sequence was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#EF#, 16#BF#, 16#BF#])),
              "the longest three-byte sequence was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#F0#, 16#90#, 16#80#, 16#80#])),
              "the shortest four-byte sequence was refused");
      Assert (UTF8.Is_Valid (Bytes ([16#F4#, 16#8F#, 16#BF#, 16#BF#])),
              "U+10FFFF was refused");

      --  Overlong forms, one for each length that has them.
      Assert (not UTF8.Is_Valid (Bytes ([16#C0#, 16#80#])),
              "an overlong NUL was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#C1#, 16#BF#])),
              "an overlong two-byte form was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#E0#, 16#9F#, 16#BF#])),
              "an overlong three-byte form was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#F0#, 16#8F#, 16#BF#, 16#BF#])),
              "an overlong four-byte form was accepted");

      --  Surrogates, which UTF-8 may not carry however they are spelled.
      Assert (not UTF8.Is_Valid (Bytes ([16#ED#, 16#A0#, 16#80#])),
              "a high surrogate was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#ED#, 16#BF#, 16#BF#])),
              "a low surrogate was accepted");

      --  Past the last code point.
      Assert (not UTF8.Is_Valid (Bytes ([16#F4#, 16#90#, 16#80#, 16#80#])),
              "a code point above U+10FFFF was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#F5#, 16#80#, 16#80#, 16#80#])),
              "a lead byte above F4 was accepted");

      --  Structure: a continuation on its own, a lead with none, and a
      --  sequence interrupted by something that is not a continuation.
      Assert (not UTF8.Is_Valid (Bytes ([16#80#])),
              "a continuation byte alone was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#E2#, 16#82#])),
              "a truncated three-byte sequence was accepted");
      Assert (not UTF8.Is_Valid (Bytes ([16#E2#, 16#41#, 16#AC#])),
              "a sequence interrupted by ASCII was accepted");

      --  A prefix is safe up to a sequence that more bytes could complete,
      --  and no further. This is what keeps a partial character out of the
      --  output when a token boundary falls inside one.
      declare
         Whole : constant String := Bytes ([16#E2#, 16#82#, 16#AC#]);
      begin
         Assert (UTF8.Safe_Prefix_Length (Whole) = 3,
                 "a complete sequence was withheld");
         Assert (UTF8.Safe_Prefix_Length (Whole (1 .. 2)) = 0,
                 "a sequence cut short was released");
         Assert (UTF8.Safe_Prefix_Length ("ab" & Whole (1 .. 1)) = 2,
                 "the text before a cut sequence was withheld with it");
         Assert (UTF8.Safe_Prefix_Length ("abc") = 3,
                 "plain text was withheld");
      end;

      --  Counting is by code point, not by byte.
      Assert (UTF8.Code_Point_Count ("abc") = 3, "ASCII counted wrongly");
      Assert (UTF8.Code_Point_Count (Bytes ([16#E2#, 16#82#, 16#AC#])) = 1,
              "a three-byte character counted as more than one");
   end UTF8_Refuses_What_It_Must;

   --  Every piece the streaming decoder hands out is itself valid UTF-8.
   --
   --  Generated text reaches the reader one token at a time and each piece is
   --  written as it arrives. A model emits a character outside ASCII one byte
   --  per token, through byte-fallback tokens, so a piece that ended half way
   --  through one would put a broken byte on the terminal before the rest of
   --  the character existed. Checking the finished text says nothing about
   --  this: the whole is valid either way.
   --
   --  The vocabulary here is built for the question. The fixture model's
   --  tokens are all ASCII, so no character can span two of them and the
   --  holding-back logic never runs -- a test over that vocabulary passes
   --  whatever the decoder does.
   procedure Streamed_Pieces_Are_Whole_Characters
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Vocab renames Model_Runner.Tokenizer;

      State : Interfaces.Unsigned_64 := 6_364_136_223_846_793_005;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      Builder : Fixtures.Builder;
      Image   : B.Byte_Array_Access;
      Item    : Containers.Container;
      Words   : Vocab.Vocabulary;
      Parse   : E.Error_Info;
      Status  : E.Error_Info;

      --  The three bytes of U+20AC, one per token, and two ordinary ones.
      Byte_Tokens : constant := 3;
      Total       : constant := 5;

      Pieces   : Natural := 0;
      Nonempty : Natural := 0;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "llama");

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.tokens", G.Value_String, Total);
      Fixtures.String_Element (Builder, "<0xE2>");
      Fixtures.String_Element (Builder, "<0x82>");
      Fixtures.String_Element (Builder, "<0xAC>");
      Fixtures.String_Element (Builder, "a");
      Fixtures.String_Element (Builder, "b");
      Fixtures.End_Array (Builder);

      --  Six is the byte class. Without it these are ordinary tokens whose
      --  text happens to look like <0xE2>, and nothing is ever split.
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.token_type", G.Value_Int32, Total);
      for Index in 1 .. Byte_Tokens loop
         Fixtures.Int32_Element (Builder, 6);
      end loop;
      Fixtures.Int32_Element (Builder, 1);
      Fixtures.Int32_Element (Builder, 1);
      Fixtures.End_Array (Builder);

      Fixtures.Build (Builder, Image);
      Parse_Image (Image.all, Item, Parse);
      Assert (E.Is_Ok (Parse),
              "the byte-token fixture did not parse: "
              & E.Error_Code'Image (Parse.Code));

      Vocab.Load (Words, Item, Status => Status);
      Assert (E.Is_Ok (Status),
              "the byte-token vocabulary did not load: "
              & E.Error_Code'Image (Status.Code));

      --  A whole character, decoded one byte at a time, arrives in one piece
      --  rather than three. This is the case the property is about, so it is
      --  checked directly before generating anything.
      declare
         Stream : Vocab.Decoder;
         First  : constant String := Vocab.Push (Stream, Words, 0);
         Second : constant String := Vocab.Push (Stream, Words, 1);
         Third  : constant String := Vocab.Push (Stream, Words, 2);
      begin
         Vocab.Reset (Stream);
         Assert (First = "" and then Second = "",
                 "a character was handed out before it was complete");
         Assert (Third = Character'Val (16#E2#) & Character'Val (16#82#)
                 & Character'Val (16#AC#),
                 "the completed character was not handed out whole");
      end;

      --  Sequences a working model produces: ordinary tokens and whole
      --  characters, never a stray continuation byte. That restriction is the
      --  point rather than a convenience. A byte that cannot begin a valid
      --  character is released as it stands, deliberately -- withholding it
      --  would wait for a completion that can never come -- so the property
      --  being checked here is about text that is valid once assembled, which
      --  is what a model that works produces.
      for Case_Number in 1 .. 2_000 loop
         declare
            Units  : constant Natural := 1 + Draw (6);
            Stream : Vocab.Decoder;

            --  Hand one token to the decoder and hold it to the property.
            procedure Give (Token : Natural) is
               Part : constant String :=
                 Vocab.Push (Stream, Words, Vocab.Token_Id (Token));
            begin
               Pieces := Pieces + 1;
               if Part'Length > 0 then
                  Nonempty := Nonempty + 1;
               end if;

               Assert (Model_Runner.UTF8.Is_Valid (Part),
                       "case" & Natural'Image (Case_Number)
                       & " handed out a piece that is not whole UTF-8");
            end Give;
         begin
            Vocab.Reset (Stream);

            for Ignored in 1 .. Units loop
               if Draw (2) = 0 then
                  --  An ordinary token, whole in itself.
                  Give (3 + Draw (2));
               else
                  --  One character across three tokens, which is how a model
                  --  emits anything outside ASCII.
                  Give (0);
                  Give (1);
                  Give (2);
               end if;
            end loop;

            declare
               Tail : constant String := Vocab.Flush (Stream);
            begin
               Assert (Tail'Length = 0,
                       "case" & Natural'Image (Case_Number)
                       & " left bytes buffered after a whole sequence: """
                       & Tail & """");
            end;
         end;
      end loop;

      Assert (Nonempty > 500,
              "too few pieces carried text to be checking them:"
              & Natural'Image (Nonempty) & " of" & Natural'Image (Pieces));

      Vocab.Close (Words);
      Containers.Close (Item);
      B.Free (Image);
   end Streamed_Pieces_Are_Whole_Characters;

   --  What the writer put in is what the reader takes out.
   --
   --  Two independent pieces of code meet at the container format: the
   --  fixture builder writes it and the library reads it. Everything else in
   --  this suite tests them together, so a disagreement about how a field is
   --  laid out would look like agreement -- both sides would be wrong in the
   --  same direction and every test would pass.
   --
   --  This writes values chosen by number, reads them back through the
   --  accessors the engine uses, and compares. It covers the types a real
   --  model file carries: strings, unsigned and signed integers of two
   --  widths, floats, booleans, arrays, and the tensor descriptors.
   procedure Written_Values_Read_Back_Unchanged
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      State : Interfaces.Unsigned_64 := 4_294_967_291;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      Checked : Natural := 0;
   begin
      for Case_Number in 1 .. 500 loop
         declare
            Builder : Fixtures.Builder;
            Image   : B.Byte_Array_Access;
            Item    : Containers.Container;
            Parse   : E.Error_Info;
            Status  : E.Error_Info;

            Word    : constant Interfaces.Unsigned_32 :=
              Interfaces.Unsigned_32 (Draw (1_000_000));
            Signed  : constant Interfaces.Integer_32 :=
              Interfaces.Integer_32 (Draw (2_000_000)) - 1_000_000;
            Wide    : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Draw (1_000_000)) * 4_000_000_000;
            Flag    : constant Boolean := Draw (2) = 0;
            Extent  : constant Natural := 1 + Draw (4);

            Number  : Long_Long_Integer;
            Text    : String (1 .. 64);
            Last    : Natural;
            Read_Flag : Boolean;
         begin
            Fixtures.Reset (Builder);
            Fixtures.Add_String (Builder, "general.architecture", "llama");
            Fixtures.Add_U32 (Builder, "fixture.word", Word);
            Fixtures.Add_I32 (Builder, "fixture.signed", Signed);
            Fixtures.Add_U64 (Builder, "fixture.wide", Wide);
            Fixtures.Add_Bool (Builder, "fixture.flag", Flag);

            Fixtures.Begin_Array
              (Builder, "fixture.list", G.Value_Int32, Extent);
            for Index in 1 .. Extent loop
               Fixtures.Int32_Element (Builder, Interfaces.Integer_32 (Index));
            end loop;
            Fixtures.End_Array (Builder);

            Fixtures.Add_Tensor
              (Builder, "only.weight", [G.U64 (4), G.U64 (2)], G.Type_F32,
               Fixtures.Encode_F32 (Fixtures.Sequence (8, 1)));

            Fixtures.Build (Builder, Image);
            Parse_Image (Image.all, Item, Parse);
            Assert (E.Is_Ok (Parse),
                    "case" & Natural'Image (Case_Number)
                    & " did not parse: " & E.Error_Code'Image (Parse.Code));

            --  Each value, through the accessor the engine uses for it.
            Containers.Get_Integer
              (Item, "fixture.word", 0, Long_Long_Integer'Last, Number, Status);
            Assert (E.Is_Ok (Status)
                    and then Number = Long_Long_Integer (Word),
                    "case" & Natural'Image (Case_Number)
                    & " read an unsigned word back as"
                    & Long_Long_Integer'Image (Number));

            Containers.Get_Integer
              (Item, "fixture.signed", Long_Long_Integer'First,
               Long_Long_Integer'Last, Number, Status);
            Assert (E.Is_Ok (Status)
                    and then Number = Long_Long_Integer (Signed),
                    "case" & Natural'Image (Case_Number)
                    & " read a signed word back as"
                    & Long_Long_Integer'Image (Number));

            Containers.Get_Integer
              (Item, "fixture.wide", 0, Long_Long_Integer'Last, Number, Status);
            Assert (E.Is_Ok (Status)
                    and then Number = Long_Long_Integer (Wide),
                    "case" & Natural'Image (Case_Number)
                    & " read a wide value back as"
                    & Long_Long_Integer'Image (Number));

            Containers.Get_Boolean (Item, "fixture.flag", Read_Flag, Status);
            Assert (E.Is_Ok (Status) and then Read_Flag = Flag,
                    "case" & Natural'Image (Case_Number)
                    & " read a flag back inverted");

            Containers.Get_String
              (Item, "general.architecture", Text'Length, Text, Last, Status);
            Assert (E.Is_Ok (Status) and then Text (1 .. Last) = "llama",
                    "case" & Natural'Image (Case_Number)
                    & " read a string back as """ & Text (1 .. Last) & """");

            --  The array, by length and by element.
            declare
               Length : Natural;
            begin
               Containers.Get_Array_Length
                 (Item, "fixture.list", G.Value_Int32, Length, Status);
               Assert (E.Is_Ok (Status) and then Length = Extent,
                       "case" & Natural'Image (Case_Number)
                       & " read an array of" & Natural'Image (Length)
                       & " where" & Natural'Image (Extent) & " was written");

               for Index in 1 .. Extent loop
                  Containers.Get_Integer_Element
                    (Item, "fixture.list", Index, Number, Status);
                  Assert (E.Is_Ok (Status)
                          and then Number = Long_Long_Integer (Index),
                          "case" & Natural'Image (Case_Number)
                          & " read element" & Natural'Image (Index)
                          & " back as" & Long_Long_Integer'Image (Number));
               end loop;
            end;

            --  And the tensor descriptor.
            Assert (Containers.Tensor_Count (Item) = 1,
                    "case" & Natural'Image (Case_Number)
                    & " read a different number of tensors");
            Assert (Containers.Tensor_Name (Item, 1) = "only.weight",
                    "case" & Natural'Image (Case_Number)
                    & " read the tensor name back as "
                    & Containers.Tensor_Name (Item, 1));
            Assert (Containers.Tensor_Rank (Item, 1) = 2,
                    "case" & Natural'Image (Case_Number)
                    & " read a different rank");
            Assert (Containers.Tensor_Dimension (Item, 1, 1) = 4
                    and then Containers.Tensor_Dimension (Item, 1, 2) = 2,
                    "case" & Natural'Image (Case_Number)
                    & " read different extents");
            Assert (Containers.Tensor_Format (Item, 1) = G.Type_F32,
                    "case" & Natural'Image (Case_Number)
                    & " read a different format");

            Checked := Checked + 1;
            Containers.Close (Item);
            B.Free (Image);
         end;
      end loop;

      Assert (Checked = 500, "not every container was read back");
   end Written_Values_Read_Back_Unchanged;

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
        (T, Metadata_Values_Are_Typed_And_Bounded'Access,
         "metadata is shown with its type and value, arrays described not dumped");
      Register_Routine
        (T, Decoders_Produce_The_Documented_Values'Access,
         "each decoder produces the values its layout documents");
      Register_Routine
        (T, Fused_Dot_Matches_Decoder'Access,
         "the fused dot product agrees with the reference decoder");
      Register_Routine
        (T, UTF8_Refuses_What_It_Must'Access,
         "the UTF-8 validator refuses overlongs, surrogates and stray bytes");
      Register_Routine
        (T, View_Refusals_Report_Themselves'Access,
         "a tensor view refuses each impossible shape by name");
      Register_Routine
        (T, Edited_Fields_Report_Themselves'Access,
         "a field edited into a sound container reports the code that names it");
      Register_Routine
        (T, Shape_Refusals_Report_Themselves'Access,
         "truncation and impossible tensor shapes report the codes that name them");
      Register_Routine
        (T, Architecture_Refusals_Report_Themselves'Access,
         "every architecture refusal reports the code that names it");
      Register_Routine
        (T, Written_Values_Read_Back_Unchanged'Access,
         "what the writer put in is what the reader takes out");
      Register_Routine
        (T, Streamed_Pieces_Are_Whole_Characters'Access,
         "every piece the streaming decoder hands out is whole UTF-8");
      Register_Routine
        (T, Tokenizer_Refusals_Report_Themselves'Access,
         "every tokenizer refusal reports the code that names it");
      Register_Routine
        (T, Structural_Refusals_Report_Themselves'Access,
         "structural refusals report the code that names them");
      Register_Routine
        (T, Wrong_Architecture_Metadata_Is_Refused'Access,
         "architecture metadata that is present and wrong stops preparation");
      Register_Routine
        (T, Hostile_Vocabulary_Stays_Inside_Itself'Access,
         "a hostile vocabulary cannot make the tokenizer reach outside itself");
      Register_Routine
        (T, Hostile_Text_Cannot_Reach_The_Terminal'Access,
         "nothing a model file says can steer the terminal");
      Register_Routine
        (T, Batch_Width_Does_Not_Change_Result'Access,
         "the number of vectors in a call does not change any of them");
   end Register_Tests;

end Tests.GGUF_Cases;
