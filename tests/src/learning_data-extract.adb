with Ada.Streams.Stream_IO;
with Interfaces;
with Model_Runner.Backend;
with Model_Runner.Bytes;
with Fixtures;
with Learning_Sources;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

separate (Learning_Data)
procedure Extract
  (Model, Dataset, Output : String; Status : out E.Error_Info;
   Backend : Model_Runner.Backend.Backend_Kind := Model_Runner.Backend.Backend_Device;
   Expected_Base : String := "ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755") is
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package C renames Model_Runner.GGUF.Containers;
   package F renames Model_Runner.Byte_Sources.Files;
   package IO renames Ada.Streams.Stream_IO;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type Interfaces.Unsigned_32;
   use type Model_Runner.Backend.Backend_Kind;
   On_Device : constant Boolean := Backend = Model_Runner.Backend.Backend_Device;
   Owner : Learning_Sources.Guard;
   Source : F.File_Source renames Owner.Bytes;
   Parsed : C.Container;
   Engine : L.Model;
   Ready : Boolean;
   States, Every : T.Real_Array_Access := null;
   Width, Vocabulary : N.Element_Count;
   Batch : Positive;
   Base_SHA : constant String := Learning_Lora_Files.Digest (Model);
   procedure Put_U32 (File : IO.File_Type; Value : Interfaces.Unsigned_32) is
      Bytes : Ada.Streams.Stream_Element_Array (1 .. 4);
      Rest : Interfaces.Unsigned_32 := Value;
   begin
      for Byte of Bytes loop
         Byte := Ada.Streams.Stream_Element (Rest and 255);
         Rest := Interfaces.Shift_Right (Rest, 8);
      end loop;
      IO.Write (File, Bytes);
   end Put_U32;
   procedure Put_Row (File : IO.File_Type; Values : N.Real_Array) is
      Bytes : constant Model_Runner.Bytes.Byte_Array := Fixtures.Encode_F32 (Values);
      Raw : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Bytes'Length))
        with Import, Address => Bytes'Address;
   begin
      IO.Write (File, Raw);
   end Put_Row;
   procedure Split (Name : String; Maximum : Positive) is
      Lines : Ada.Text_IO.File_Type;
      File : IO.File_Type;
      Rows : Natural := 0;
      Header : constant Ada.Streams.Stream_Element_Array :=
        [77, 82, 72, 76, 79, 82, 65, 49]; -- MRHLORA1
   begin
      Ada.Text_IO.Open (Lines, Ada.Text_IO.In_File, Dataset & "/" & Name & ".jsonl");
      IO.Create (File, IO.Out_File, Output & "/" & Name & ".features");
      IO.Write (File, Header);
      Put_U32 (File, Interfaces.Unsigned_32 (Width));
      Put_U32 (File, Interfaces.Unsigned_32 (Vocabulary));
      Put_U32 (File, 0);
      while not Ada.Text_IO.End_Of_File (Lines) loop
         declare
            Doc : J.Document;
            Parse_Error : Jsonlib.Errors.Error_Info;
            Line : constant String := Ada.Text_IO.Get_Line (Lines);
         begin
            Jsonlib.Parsers.Parse (Line, Doc, Parse_Error);
            if Jsonlib.Errors.Failed (Parse_Error) then
               Status := E.Make (E.IO_Read_Failed);
               exit;
            end if;
            declare
               Root : constant J.Node := J.Root (Doc);
               P : constant J.Node := J.Member (Doc, Root, "input_tokens");
               R : constant J.Node := J.Member (Doc, Root, "response_tokens");
               Mask : constant J.Node := J.Member (Doc, Root, "loss_positions");
               Prefix : constant Natural := J.Length (Doc, P);
               Suffix : constant Natural := J.Length (Doc, R);
               Live : L.Session;
               Tokens : Model_Runner.Tokenizer.Token_Array (1 .. 16_384);
               Targets : array (1 .. 16_384) of Integer := [others => -1];
               Last_Row : N.Real_Array (0 .. Vocabulary - 1);
               Lo : Positive := 1;
               function Token (Node : J.Node; Index : Positive) return Model_Runner.Tokenizer.Token_Id is
                  Value : constant Long_Long_Integer := J.As_Integer (Doc, J.Element (Doc, Node, Index));
               begin
                  if Value not in 0 .. Long_Long_Integer (Vocabulary) - 1 then
                     Status := E.Make (E.Tokenizer_Invalid_Token_Id);
                     return 0;
                  end if;
                  return Model_Runner.Tokenizer.Token_Id (Value);
               end Token;
            begin
               if Prefix = 0 or else Suffix = 0 or else Prefix + Suffix > Tokens'Length
                 or else J.Length (Doc, Mask) > 32 or else Rows + J.Length (Doc, Mask) > Maximum
               then
                  Status := E.Make (E.Tensor_Shape_Mismatch);
                  exit;
               end if;
               for I in 1 .. Prefix loop
                  Tokens (I) := Token (P, I);
               end loop;
               for I in 1 .. Suffix - 1 loop
                  Tokens (Prefix + I) := Token (R, I);
               end loop;
               for I in 1 .. J.Length (Doc, Mask) loop
                  declare
                     Position : constant Long_Long_Integer := J.As_Integer (Doc, J.Element (Doc, Mask, I));
                  begin
                     if Position not in 1 .. Long_Long_Integer (Suffix) then
                        Status := E.Make (E.Tensor_Shape_Mismatch);
                        exit;
                     end if;
                     Targets (Prefix + Natural (Position) - 1) := Integer (Token (R, Positive (Position)));
                  end;
               end loop;
               exit when E.Is_Error (Status);
               L.Open (Live, Engine, Context => Prefix + Suffix, Cache => L.Transformed_Fourth,
                       Values => L.Value_Fourth, Paged => On_Device, Status => Status);
               if E.Is_Error (Status) then
                  exit;
               end if;
               while Lo <= Prefix + Suffix - 1 loop
                  declare
                     Hi : constant Positive := Positive'Min (Lo + Batch - 1, Prefix + Suffix - 1);
                     Need : constant Boolean := (for some I in Lo .. Hi => Targets (I) >= 0);
                  begin
                     L.Evaluate_Batch
                       (Live, Engine, Tokens (Lo .. Hi), Last_Row,
                        States => (if Need then States else null), Every => (if Need then Every else null),
                        Status => Status);
                     exit when E.Is_Error (Status);
                     for I in Lo .. Hi loop
                        if Targets (I) >= 0 then
                           declare
                              At_State : constant N.Element_Count := N.Element_Count (I - Lo) * Width;
                              At_Logit : constant N.Element_Count := N.Element_Count (I - Lo) * Vocabulary;
                           begin
                              Put_U32 (File, Interfaces.Unsigned_32 (Targets (I)));
                              Put_Row (File, States.all (At_State .. At_State + Width - 1));
                              Put_Row (File, Every.all (At_Logit .. At_Logit + Vocabulary - 1));
                              Rows := Rows + 1;
                           end;
                        end if;
                     end loop;
                     Lo := Hi + 1;
                  end;
               end loop;
               L.Close (Live);
            end;
            exit when E.Is_Error (Status);
         end;
      end loop;
      Ada.Text_IO.Close (Lines);
      IO.Set_Index (File, 17);
      Put_U32 (File, Interfaces.Unsigned_32 (Rows));
      IO.Close (File);
      Ada.Text_IO.Put_Line ("extracted " & Name & ": " & Image (Rows) & " supervised positions");
      if Rows = 0 then
         Status := E.Make (E.IO_Read_Failed);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Lines) then
            Ada.Text_IO.Close (Lines);
         end if;
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         Status := E.Make (E.IO_Write_Failed);
   end Split;
begin
   Status := E.Success;
   if Ada.Directories.Exists (Output) or else Expected_Base'Length /= 64 or else Base_SHA /= Expected_Base
     or else Backend not in Model_Runner.Backend.Backend_Device | Model_Runner.Backend.Backend_CPU
   then
      Status := E.Make (E.IO_Read_Failed);
      return;
   end if;
   F.Open (Source, Model, Status => Status);
   if E.Is_Ok (Status) then
      C.Reader.Parse (Parsed, Source, Status => Status);
   end if;
   if E.Is_Error (Status) then
      return;
   end if;
   if On_Device then
      Model_Runner.Backend.Device.Open (Ready);
      if not Ready then
         Status := E.Make (E.Backend_Device_Refused);
         return;
      end if;
      Model_Runner.Backend.Device.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_Every);
      Model_Runner.Backend.CPU.Use_Integer_Activations (L.Quantized_Roles (L.Integer_Activations));
   end if;
   L.Prepare (Engine, Parsed, Source, Backend => Backend,
              Threads => 7, Context => 16_384, Cache => L.Transformed_Fourth, Paged => On_Device, Status => Status);
   if E.Is_Error (Status) then
      return;
   end if;
   Width := N.Element_Count (L.Config (Engine).Embedding);
   Vocabulary := N.Element_Count (L.Config (Engine).Vocabulary);
   Batch := Positive'Min (64, L.Batch_Limit (Engine));
   T.Allocate (Width * N.Element_Count (Batch), States);
   T.Allocate (Vocabulary * N.Element_Count (Batch), Every);
   if States = null or else Every = null then
      Status := E.Make (E.Memory_Allocation_Failed);
   else
      Ada.Directories.Create_Path (Output);
      Split ("train", 1_024);
      if E.Is_Ok (Status) then
         Split ("validation", 256);
      end if;
      if E.Is_Ok (Status) then
         declare
            Doc : J.Document;
            Root : constant J.Node := J.New_Object (Doc);
            procedure Put (Key, Value : String) is
            begin
               J.Insert (Doc, Root, Key, J.New_String (Doc, Value));
            end Put;
         begin
            J.Set_Root (Doc, Root);
            Put ("schema", "model_runner.frozen_output_features.v1");
            Put ("model_sha256", Base_SHA);
            Put ("train_dataset_sha256", Learning_Lora_Files.Digest (Dataset & "/train.jsonl"));
            Put ("validation_dataset_sha256", Learning_Lora_Files.Digest (Dataset & "/validation.jsonl"));
            Put ("train_features_sha256", Learning_Lora_Files.Digest (Output & "/train.features"));
            Put ("validation_features_sha256", Learning_Lora_Files.Digest (Output & "/validation.features"));
            Put ("dtype", "little-endian-f32; u32 token targets");
            Put ("backend", (if On_Device then "device" else "cpu"));
            Put ("cache_keys", "q4t");
            Put ("cache_values", "q4");
            J.Insert (Doc, Root, "context_limit", J.New_Integer (Doc, 16_384));
            J.Insert (Doc, Root, "batch_limit", J.New_Integer (Doc, Long_Long_Integer (Batch)));
            J.Insert (Doc, Root, "width", J.New_Integer (Doc, Long_Long_Integer (Width)));
            J.Insert (Doc, Root, "vocabulary", J.New_Integer (Doc, Long_Long_Integer (Vocabulary)));
            Project_Tools.Files.Write_Raw_File
              (Output & "/manifest.json", Jsonlib.Serializers.To_String (Doc) & ASCII.LF);
         end;
      end if;
   end if;
   T.Free (States);
   T.Free (Every);
   declare
      Closed : E.Error_Info;
   begin
      L.Close (Engine, Closed);
      if E.Is_Ok (Status) then
         Status := Closed;
      end if;
   end;
end Extract;
