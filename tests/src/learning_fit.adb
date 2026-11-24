with Ada.Directories;
with Ada.Text_IO;
with Ada.Calendar;
with Ada.Unchecked_Deallocation;
with Interfaces;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Jsonlib.Parsers;
with Jsonlib.Errors;
with Learning_Lora;
with Learning_Lora_Files;
with Learning_Sources;
with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Project_Tools.Files;

package body Learning_Fit is
   pragma Suppress (Validity_Check);
   package N renames Model_Runner.Numerics;
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Tensors;
   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.GGUF.Containers;
   package F renames Model_Runner.Byte_Sources.Files;
   package J renames Jsonlib.Documents;
   use type N.Element_Count;
   use type N.Wide_Real;
   use type B.Byte_Count;
   use type B.Byte;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type T.Real_Array_Access;
   use type Ada.Calendar.Time;
   use type Ada.Directories.File_Size;
   use type J.Value_Kind;
   type Id_List is array (Natural range <>) of Natural;
   type Id_Access is access Id_List;
   procedure Free is new Ada.Unchecked_Deallocation (Id_List, Id_Access);
   type Feature_Set is record
      Rows, Width, Vocabulary : Natural := 0;
      Hidden, Logits : T.Real_Array_Access := null;
      Targets : Id_Access := null;
   end record;
   procedure Release (Item : in out Feature_Set) is
   begin
      T.Free (Item.Hidden);
      T.Free (Item.Logits);
      Free (Item.Targets);
      Item.Rows := 0;
   end Release;
   procedure Read_Features (Path : String; Limit : Positive; Item : in out Feature_Set; Status : out E.Error_Info) is
      Owner : Learning_Sources.Guard;
      Source : F.File_Source renames Owner.Bytes;
      Header : B.Byte_Array (1 .. 20);
      Raw : B.Byte_Array_Access := null;
      function U32 (Data : B.Byte_Array; Index : B.Byte_Count) return Interfaces.Unsigned_32 is
        (Interfaces.Unsigned_32 (Data (Index))
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Data (Index + 1)), 8)
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Data (Index + 2)), 16)
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Data (Index + 3)), 24));
      Row_Bytes : B.Byte_Count;
      Magic : constant String := "MRHLORA1";
   begin
      F.Open (Source, Path, Max_Bytes => 2 ** 30, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Source.Read (0, Header, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for I in 1 .. 8 loop
         if Header (B.Byte_Count (I)) /= Character'Pos (Magic (I)) then
            Status := E.Make (E.IO_Read_Failed);
            return;
         end if;
      end loop;
      if U32 (Header, 9) not in 1 .. 8_192 or else U32 (Header, 13) not in 2 .. 262_144
        or else U32 (Header, 17) not in 1 .. Interfaces.Unsigned_32 (Limit)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Frame (Status, "learning.features.header");
         return;
      end if;
      Item.Width := Natural (U32 (Header, 9));
      Item.Vocabulary := Natural (U32 (Header, 13));
      Item.Rows := Natural (U32 (Header, 17));
      Row_Bytes := B.Byte_Count (4 * (Item.Width + Item.Vocabulary + 1));
      if Source.Size /= 20 + B.Byte_Count (Item.Rows) * Row_Bytes then
         Status := E.Make (E.IO_Read_Failed);
         return;
      end if;
      T.Allocate (N.Element_Count (Item.Rows * Item.Width), Item.Hidden);
      T.Allocate (N.Element_Count (Item.Rows * Item.Vocabulary), Item.Logits);
      Item.Targets := new Id_List (0 .. Item.Rows - 1);
      Raw := new B.Byte_Array (1 .. Row_Bytes);
      if Item.Hidden = null or else Item.Logits = null then
         Status := E.Make (E.Memory_Allocation_Failed);
      else
         for Row in 0 .. Item.Rows - 1 loop
            Source.Read (20 + B.Byte_Count (Row) * Row_Bytes, Raw.all, Status);
            exit when E.Is_Error (Status);
            if U32 (Raw.all, 1) >= Interfaces.Unsigned_32 (Item.Vocabulary) then
               Status := E.Make (E.Tokenizer_Invalid_Token_Id);
               exit;
            end if;
            Item.Targets (Row) := Natural (U32 (Raw.all, 1));
            for I in 0 .. Item.Width + Item.Vocabulary - 1 loop
               declare
                  Value : constant N.Real := N.From_Bits (U32 (Raw.all, B.Byte_Count (5 + I * 4)));
               begin
                  if not N.Is_Finite (Value) then
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     exit;
                  elsif I < Item.Width then
                     Item.Hidden (N.Element_Count (Row * Item.Width + I)) := Value;
                  else
                     Item.Logits (N.Element_Count (Row * Item.Vocabulary + I - Item.Width)) := Value;
                  end if;
               end;
            end loop;
            exit when E.Is_Error (Status);
         end loop;
      end if;
      B.Free (Raw);
   exception
      when others =>
         B.Free (Raw);
         Status := E.Make (E.IO_Read_Failed);
   end Read_Features;
   procedure Run (Model, Features, Output : String; Status : out E.Error_Info) is
      Owner : Learning_Sources.Guard;
      Source : F.File_Source renames Owner.Bytes;
      Parsed : C.Container;
      Settings : Model_Runner.Llama.Configuration;
      Train, Validation : Feature_Set;
      Item : Learning_Lora.Adapter;
      Base_SHA : constant String := Learning_Lora_Files.Digest (Model);
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Curve : Ada.Text_IO.File_Type;
      Best : N.Wide_Real := N.Wide_Real'Last;
      Best_Epoch : Natural := 0;
      Zero_Train, Zero_Validation : N.Wide_Real := 0.0;
      State : Interfaces.Unsigned_64 := 42;
      function Image (Value : Natural) return String is (Model_Runner.Text.Image (Long_Long_Integer (Value)));
      function Mean_Loss (Data : Feature_Set) return N.Wide_Real is
         Sum, Loss : N.Wide_Real := 0.0;
      begin
         for Row in 0 .. Data.Rows - 1 loop
            declare
               H : constant N.Element_Count := N.Element_Count (Row * Data.Width);
               V : constant N.Element_Count := N.Element_Count (Row * Data.Vocabulary);
            begin
               Learning_Lora.Observe
                 (Item, Data.Hidden.all (H .. H + N.Element_Count (Data.Width) - 1),
                  Data.Logits.all (V .. V + N.Element_Count (Data.Vocabulary) - 1),
                  Data.Targets (Row), False, Loss, Status);
               if E.Is_Error (Status) then
                  return 0.0;
               end if;
               Sum := Sum + Loss;
            end;
         end loop;
         return Sum / N.Wide_Real (Data.Rows);
      end Mean_Loss;
      procedure Epoch_Record (Epoch : Natural; Train_Loss, Validation_Loss : N.Wide_Real) is
         Doc : J.Document;
         Root : constant J.Node := J.New_Object (Doc);
      begin
         J.Set_Root (Doc, Root);
         J.Insert (Doc, Root, "epoch", J.New_Integer (Doc, Long_Long_Integer (Epoch)));
         J.Insert (Doc, Root, "train_cross_entropy", J.New_Float (Doc, Long_Float (Train_Loss)));
         J.Insert (Doc, Root, "validation_cross_entropy", J.New_Float (Doc, Long_Float (Validation_Loss)));
         J.Insert (Doc, Root, "elapsed_seconds", J.New_Float
           (Doc, Long_Float (Ada.Calendar.Clock - Started)));
         J.Insert (Doc, Root, "checkpoint_sha256", J.New_String
           (Doc, Learning_Lora_Files.Digest
              (Output & (if Epoch = 0 then "/zero.gguf" else "/epoch-" & Image (Epoch) & ".gguf"))));
         Ada.Text_IO.Put_Line (Curve, Jsonlib.Serializers.To_String (Doc));
         Ada.Text_IO.Flush (Curve);
         Ada.Text_IO.Put_Line ("epoch " & Image (Epoch) & ": train=" & N.Wide_Real'Image (Train_Loss)
                               & " validation=" & N.Wide_Real'Image (Validation_Loss));
         Ada.Text_IO.Flush;
      end Epoch_Record;
      procedure Finish_Fitting is
         Order : Id_List (0 .. Train.Rows - 1);
         Last_Train, Last_Validation, Loss : N.Wide_Real := 0.0;
         Down, Up : T.Real_Array_Access := null;
         Up_Norm : N.Wide_Real := 0.0;
      begin
         for Epoch in 1 .. 8 loop
            for I in Order'Range loop
               Order (I) := I;
            end loop;
            for I in reverse 1 .. Order'Last loop
               State := State xor Interfaces.Shift_Left (State, 13);
               State := State xor Interfaces.Shift_Right (State, 7);
               State := State xor Interfaces.Shift_Left (State, 17);
               declare
                  Pick : constant Natural := Natural (State mod Interfaces.Unsigned_64 (I + 1));
                  Swap : constant Natural := Order (I);
               begin
                  Order (I) := Order (Pick);
                  Order (Pick) := Swap;
               end;
            end loop;
            for I in Order'Range loop
               declare
                  Row : constant Natural := Order (I);
                  H : constant N.Element_Count := N.Element_Count (Row * Train.Width);
                  V : constant N.Element_Count := N.Element_Count (Row * Train.Vocabulary);
               begin
                  Learning_Lora.Observe
                    (Item, Train.Hidden.all (H .. H + N.Element_Count (Train.Width) - 1),
                     Train.Logits.all (V .. V + N.Element_Count (Train.Vocabulary) - 1),
                     Train.Targets (Row), True, Loss, Status);
                  exit when E.Is_Error (Status);
                  if (I + 1) mod 8 = 0 or else I = Order'Last then
                     Learning_Lora.Step (Item, 0.001, 1.0, Status);
                  end if;
                  exit when E.Is_Error (Status);
               end;
            end loop;
            exit when E.Is_Error (Status);
            Last_Train := Mean_Loss (Train);
            Last_Validation := Mean_Loss (Validation);
            exit when E.Is_Error (Status);
            Learning_Lora_Files.Save
              (Item, Output & "/epoch-" & Image (Epoch) & ".gguf", Base_SHA,
               C.String_Value (Parsed, "general.architecture"), Status);
            exit when E.Is_Error (Status);
            Epoch_Record (Epoch, Last_Train, Last_Validation);
            if Last_Validation < Best then
               Best := Last_Validation;
               Best_Epoch := Epoch;
            end if;
         end loop;
         if E.Is_Ok (Status) then
            T.Allocate (N.Element_Count (Train.Width * 8), Down);
            T.Allocate (N.Element_Count (Train.Vocabulary * 8), Up);
            Learning_Lora.Get_Factors (Item, Down.all, Up.all, Status);
            for Value of Up.all loop
               Up_Norm := Up_Norm + N.Wide_Real (Value) ** 2;
            end loop;
            T.Free (Down);
            T.Free (Up);
            if Up_Norm = 0.0 or else Best_Epoch = 0 then
               Status := E.Make (E.Internal_Invariant_Violated);
            else
               Ada.Directories.Copy_File
                 (Output & "/epoch-" & Image (Best_Epoch) & ".gguf", Output & "/selected.gguf");
               Ada.Directories.Copy_File (Output & "/epoch-8.gguf", Output & "/final.gguf");
               declare
                  Doc : J.Document;
                  Root : constant J.Node := J.New_Object (Doc);
                  procedure Put (Key, Value : String) is
                  begin
                     J.Insert (Doc, Root, Key, J.New_String (Doc, Value));
                  end Put;
               begin
                  J.Set_Root (Doc, Root);
                  Put ("schema", "model_runner.output_lora_fit.v1");
                  Put ("base_sha256", Base_SHA);
                  Put ("train_features_sha256", Learning_Lora_Files.Digest (Features & "/train.features"));
                  Put ("validation_features_sha256", Learning_Lora_Files.Digest (Features & "/validation.features"));
                  Put ("selected_sha256", Learning_Lora_Files.Digest (Output & "/selected.gguf"));
                  Put ("final_sha256", Learning_Lora_Files.Digest (Output & "/final.gguf"));
                  J.Insert (Doc, Root, "selected_epoch", J.New_Integer (Doc, Long_Long_Integer (Best_Epoch)));
                  J.Insert (Doc, Root, "epochs", J.New_Integer (Doc, 8));
                  J.Insert (Doc, Root, "rank", J.New_Integer (Doc, 8));
                  J.Insert (Doc, Root, "train_positions", J.New_Integer (Doc, Long_Long_Integer (Train.Rows)));
                  J.Insert (Doc, Root, "validation_positions", J.New_Integer
                    (Doc, Long_Long_Integer (Validation.Rows)));
                  J.Insert (Doc, Root, "zero_train_cross_entropy", J.New_Float (Doc, Long_Float (Zero_Train)));
                  J.Insert (Doc, Root, "zero_validation_cross_entropy", J.New_Float
                    (Doc, Long_Float (Zero_Validation)));
                  J.Insert (Doc, Root, "selected_validation_cross_entropy", J.New_Float (Doc, Long_Float (Best)));
                  J.Insert (Doc, Root, "final_train_cross_entropy", J.New_Float (Doc, Long_Float (Last_Train)));
                  J.Insert (Doc, Root, "final_up_squared_norm", J.New_Float (Doc, Long_Float (Up_Norm)));
                  J.Insert (Doc, Root, "validation_improved", J.New_Boolean (Doc, Best < Zero_Validation));
                  Project_Tools.Files.Write_Raw_File
                    (Output & "/fit.json", Jsonlib.Serializers.To_String (Doc) & ASCII.LF);
               end;
            end if;
         end if;
         Ada.Text_IO.Close (Curve);
         Learning_Lora.Clear (Item);
         Release (Train);
         Release (Validation);
      end Finish_Fitting;
   begin
      Status := E.Success;
      if Ada.Directories.Exists (Output) or else Base_SHA'Length /= 64 then
         Status := E.Make (E.IO_Open_Failed);
         return;
      end if;
      if not Ada.Directories.Exists (Features & "/manifest.json")
        or else Ada.Directories.Size (Features & "/manifest.json") > 65_536
      then
         Status := E.Make (E.IO_Read_Failed);
         return;
      end if;
      declare
         Doc : J.Document;
         Parse_Error : Jsonlib.Errors.Error_Info;
         function Value (Key : String) return String is
           (if J.Kind (Doc, J.Root (Doc)) = J.Object_Value and then J.Has_Member (Doc, J.Root (Doc), Key)
             and then J.Kind (Doc, J.Member (Doc, J.Root (Doc), Key)) = J.String_Value
            then J.As_String (Doc, J.Member (Doc, J.Root (Doc), Key)) else "");
      begin
         Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Features & "/manifest.json"), Doc, Parse_Error);
         if Jsonlib.Errors.Failed (Parse_Error) or else Value ("model_sha256") /= Base_SHA
           or else Value ("train_features_sha256") /= Learning_Lora_Files.Digest (Features & "/train.features")
           or else Value ("validation_features_sha256") /=
             Learning_Lora_Files.Digest (Features & "/validation.features")
         then
            Status := E.Make (E.IO_Read_Failed);
            return;
         end if;
      end;
      F.Open (Source, Model, Status => Status);
      if E.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if E.Is_Ok (Status) then
         Model_Runner.Llama.Read_Config (Parsed, Settings => Settings, Status => Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Head : constant Natural := C.Find_Tensor (Parsed, "output.weight");
      begin
         if Head = 0 or else C.Tensor_Rank (Parsed, Head) /= 2
           or else C.Tensor_Dimension (Parsed, Head, 2) not in 2 .. 262_144
         then
            Status := E.Make (E.Tensor_Shape_Mismatch);
            return;
         end if;
         Settings.Vocabulary := Natural (C.Tensor_Dimension (Parsed, Head, 2));
      end;
      Read_Features (Features & "/train.features", 1_024, Train, Status);
      if E.Is_Ok (Status) then
         Read_Features (Features & "/validation.features", 256, Validation, Status);
      end if;
      if E.Is_Ok (Status) and then
        (Train.Width /= Settings.Embedding or else Train.Vocabulary /= Settings.Vocabulary
         or else Validation.Width /= Train.Width or else Validation.Vocabulary /= Train.Vocabulary)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Frame (Status, "learning.fit.geometry");
         E.Add_Integer (Status, "train_width", Long_Long_Integer (Train.Width));
         E.Add_Integer (Status, "train_vocabulary", Long_Long_Integer (Train.Vocabulary));
         E.Add_Integer (Status, "validation_width", Long_Long_Integer (Validation.Width));
         E.Add_Integer (Status, "validation_vocabulary", Long_Long_Integer (Validation.Vocabulary));
         E.Add_Integer (Status, "model_width", Long_Long_Integer (Settings.Embedding));
         E.Add_Integer (Status, "model_vocabulary", Long_Long_Integer (Settings.Vocabulary));
      end if;
      if E.Is_Error (Status) then
         Release (Train);
         Release (Validation);
         return;
      end if;
      Learning_Lora.Initialize (Item, (Train.Width, Train.Vocabulary, 8), 42, Status);
      if E.Is_Error (Status) then
         E.Add_Frame (Status, "learning.fit.initialize");
         Release (Train);
         Release (Validation);
         return;
      end if;
      Ada.Directories.Create_Path (Output);
      Ada.Text_IO.Create (Curve, Ada.Text_IO.Out_File, Output & "/curve.jsonl");
      Zero_Train := Mean_Loss (Train);
      Zero_Validation := Mean_Loss (Validation);
      Learning_Lora_Files.Save
        (Item, Output & "/zero.gguf", Base_SHA, C.String_Value (Parsed, "general.architecture"), Status);
      if E.Is_Ok (Status) then
         Epoch_Record (0, Zero_Train, Zero_Validation);
         Finish_Fitting;
      end if;
      if Ada.Text_IO.Is_Open (Curve) then
         Ada.Text_IO.Close (Curve);
      end if;
      Release (Train);
      Release (Validation);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Curve) then
            Ada.Text_IO.Close (Curve);
         end if;
         Learning_Lora.Clear (Item);
         Release (Train);
         Release (Validation);
         Status := E.Make (E.IO_Write_Failed);
   end Run;
end Learning_Fit;
