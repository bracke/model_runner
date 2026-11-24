with Ada.Directories;
with Ada.Streams.Stream_IO;
with GNAT.SHA256;
with Fixtures;
with Quantizer;
with Learning_Sources;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Project_Tools.Files;
with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

package body Learning_Lora_Files is
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package C renames G.Containers;
   package F renames Model_Runner.Byte_Sources.Files;
   package IO renames Ada.Streams.Stream_IO;
   use type N.Wide_Real;
   use type N.Element_Count;
   use type B.Byte_Count;
   use type G.Tensor_Type;
   use type G.U64;
   use type T.Real_Array_Access;
   function Digest (Path : String) return String is
      File : IO.File_Type;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_536);
      Last : Ada.Streams.Stream_Element_Offset;
      Context : GNAT.SHA256.Context;
   begin
      IO.Open (File, IO.In_File, Path);
      while not IO.End_Of_File (File) loop
         IO.Read (File, Buffer, Last);
         declare
            Text : String (1 .. Natural (Last)) with Import, Address => Buffer'Address;
         begin
            GNAT.SHA256.Update (Context, Text);
         end;
      end loop;
      IO.Close (File);
      return GNAT.SHA256.Digest (Context);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         return "";
   end Digest;
   procedure Write (File : IO.File_Type; Bytes : B.Byte_Array) is
      Raw : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Bytes'Length))
        with Import, Address => Bytes'Address;
   begin
      IO.Write (File, Raw);
   end Write;
   function Is_Hash (Text : String) return Boolean is
     (Text'Length = 64 and then (for all Ch of Text => Ch in '0' .. '9' | 'a' .. 'f'));
   procedure Save
     (Item : Learning_Lora.Adapter; Path, Base_SHA256, Architecture : String; Status : out E.Error_Info)
   is
      Shape : constant Learning_Lora.Dimensions := Learning_Lora.Shape (Item);
      Maker : Fixtures.Builder;
      Down, Up : T.Real_Array_Access := null;
      Image : B.Byte_Array_Access := null;
      File : IO.File_Type;
   begin
      Status := E.Success;
      if Path = "" or else Ada.Directories.Exists (Path) or else not Is_Hash (Base_SHA256)
        or else Architecture'Length not in 1 .. 64 or else Shape.Rank = 0
      then
         Status := E.Make (E.IO_Open_Failed);
         return;
      end if;
      T.Allocate (N.Element_Count (Shape.Width * Shape.Rank), Down);
      T.Allocate (N.Element_Count (Shape.Vocabulary * Shape.Rank), Up);
      if Down = null or else Up = null then
         T.Free (Down);
         T.Free (Up);
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      Learning_Lora.Get_Factors (Item, Down.all, Up.all, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Fixtures.Add_String (Maker, "general.architecture", Architecture);
      Fixtures.Add_String (Maker, "general.type", "adapter");
      Fixtures.Add_String (Maker, "adapter.type", "lora");
      Fixtures.Add_String (Maker, "learning.base_sha256", Base_SHA256);
      Fixtures.Add_String (Maker, "learning.method", "frozen-transformer-output-lora-cross-entropy-v1");
      Fixtures.Add_F32 (Maker, "adapter.lora.alpha", N.Real (Shape.Rank));
      Fixtures.Add_Tensor (Maker, "output.weight.lora_a", [G.U64 (Shape.Width), G.U64 (Shape.Rank)],
                           G.Type_F32, Fixtures.Encode_F32 (Down.all));
      Fixtures.Add_Tensor (Maker, "output.weight.lora_b", [G.U64 (Shape.Rank), G.U64 (Shape.Vocabulary)],
                           G.Type_F32, Fixtures.Encode_F32 (Up.all));
      Fixtures.Build (Maker, Image);
      IO.Create (File, IO.Out_File, Path);
      Write (File, Image.all);
      IO.Close (File);
      B.Free (Image);
      T.Free (Down);
      T.Free (Up);
   exception
      when others =>
         B.Free (Image);
         T.Free (Down);
         T.Free (Up);
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         Status := E.Make (E.IO_Write_Failed);
   end Save;
   procedure Load
     (Item : in out Learning_Lora.Adapter; Path, Expected_Base : String; Status : out E.Error_Info)
   is
      Owner : Learning_Sources.Guard;
      Source : F.File_Source renames Owner.Bytes;
      Parsed : C.Container;
      A, D : Natural;
      Shape : Learning_Lora.Dimensions;
      Alpha : N.Wide_Real;
      Down, Up : T.Real_Array_Access := null;
      function Read (Index : Positive; Rows, Columns : N.Element_Count; Into : out N.Real_Array) return Boolean is
         Raw : B.Byte_Array_Access := null;
         View : T.View;
      begin
         if C.Tensor_Rank (Parsed, Index) /= 2 or else C.Tensor_Format (Parsed, Index) /= G.Type_F32
           or else C.Tensor_Dimension (Parsed, Index, 1) /= G.U64 (Columns)
           or else C.Tensor_Dimension (Parsed, Index, 2) /= G.U64 (Rows)
         then
            return False;
         end if;
         Raw := new B.Byte_Array (1 .. B.Byte_Count (Into'Length) * 4);
         Source.Read (B.Byte_Count (C.Tensor_Offset (Parsed, Index)), Raw.all, Status);
         if E.Is_Ok (Status) then
            T.Make (G.Type_F32, Rows, Columns, Raw, 0, View, Status);
         end if;
         if E.Is_Error (Status) then
            B.Free (Raw);
            return False;
         end if;
         for R in 0 .. Rows - 1 loop
            T.Dequantize_Row (View, R, Into (Into'First + R * Columns .. Into'First + (R + 1) * Columns - 1), Status);
            if E.Is_Error (Status) then
               B.Free (Raw);
               return False;
            end if;
         end loop;
         B.Free (Raw);
         return True;
      exception
         when others =>
            B.Free (Raw);
            Status := E.Make (E.IO_Read_Failed);
            return False;
      end Read;
   begin
      Status := E.Success;
      if not Is_Hash (Expected_Base) then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      F.Open (Source, Path, Max_Bytes => 64 * 1_024 * 1_024, Status => Status);
      if E.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      A := C.Find_Tensor (Parsed, "output.weight.lora_a");
      D := C.Find_Tensor (Parsed, "output.weight.lora_b");
      if C.Tensor_Count (Parsed) /= 2 or else A = 0 or else D = 0
        or else C.String_Value (Parsed, "learning.base_sha256") /= Expected_Base
        or else C.Tensor_Dimension (Parsed, A, 1) not in 1 .. 8_192
        or else C.Tensor_Dimension (Parsed, A, 2) not in 1 .. 64
        or else C.Tensor_Dimension (Parsed, D, 2) not in 2 .. 262_144
        or else C.Tensor_Dimension (Parsed, A, 2)
          * (C.Tensor_Dimension (Parsed, A, 1) + C.Tensor_Dimension (Parsed, D, 2)) > 8_388_608
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Frame (Status, "learning.adapter.identity_or_shape");
         return;
      end if;
      Shape := (Width => Natural (C.Tensor_Dimension (Parsed, A, 1)),
                Rank => Natural (C.Tensor_Dimension (Parsed, A, 2)),
                Vocabulary => Natural (C.Tensor_Dimension (Parsed, D, 2)));
      C.Get_Float (Parsed, "adapter.lora.alpha", 0.0, 64.0, Alpha, Status);
      if E.Is_Error (Status) or else Alpha /= N.Wide_Real (Shape.Rank)
        or else C.String_Value (Parsed, "general.type") /= "adapter"
        or else C.String_Value (Parsed, "adapter.type") /= "lora"
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      T.Allocate (N.Element_Count (Shape.Width * Shape.Rank), Down);
      T.Allocate (N.Element_Count (Shape.Vocabulary * Shape.Rank), Up);
      if Down = null or else Up = null then
         Status := E.Make (E.Memory_Allocation_Failed);
      else
         if not Read (A, N.Element_Count (Shape.Rank), N.Element_Count (Shape.Width), Down.all) then
            if E.Is_Ok (Status) then
               Status := E.Make (E.Tensor_Shape_Mismatch);
            end if;
            E.Add_Frame (Status, "learning.adapter.down");
         elsif not Read (D, N.Element_Count (Shape.Vocabulary), N.Element_Count (Shape.Rank), Up.all) then
            if E.Is_Ok (Status) then
               Status := E.Make (E.Tensor_Shape_Mismatch);
            end if;
            E.Add_Frame (Status, "learning.adapter.up");
         else
            Learning_Lora.Initialize (Item, Shape, 1, Status);
            if E.Is_Ok (Status) then
               Learning_Lora.Set_Factors (Item, Down.all, Up.all, Status);
            end if;
         end if;
      end if;
      T.Free (Down);
      T.Free (Up);
   exception
      when others =>
         T.Free (Down);
         T.Free (Up);
         Status := E.Make (E.IO_Read_Failed);
   end Load;
   procedure Merge (Base_Path, Adapter_Path, Output_Path : String; Status : out E.Error_Info) is
      Base_SHA : constant String := Digest (Base_Path);
      Item : Learning_Lora.Adapter;
      Owner : Learning_Sources.Guard;
      Source : F.File_Source renames Owner.Bytes;
      Parsed : C.Container;
      Target : Natural;
      File : IO.File_Type;
      At_Byte : B.Byte_Count := 0;
      Buffer : B.Byte_Array (1 .. 65_536);
      Down, Up : T.Real_Array_Access := null;
      Error_Squares, Signal_Squares, Maximum_Error : N.Wide_Real := 0.0;
      Cells : N.Element_Count := 0;
      function Target_Format return Quantizer.Target is
      begin
         for Format in Quantizer.Target loop
            if Quantizer.Type_Of (Format) = C.Tensor_Format (Parsed, Target) then
               return Format;
            end if;
         end loop;
         return Quantizer.Q8_0;
      end Target_Format;
   begin
      Status := E.Success;
      if Output_Path = "" or else Ada.Directories.Exists (Output_Path) then
         Status := E.Make (E.IO_Open_Failed);
         return;
      end if;
      F.Open (Source, Base_Path, Policy => F.Mapping_Required, Status => Status);
      if E.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if E.Is_Ok (Status) then
         Load (Item, Adapter_Path, Base_SHA, Status);
      end if;
      if E.Is_Error (Status) then
         E.Add_Frame (Status, "learning.merge.input");
         return;
      end if;
      Target := C.Find_Tensor (Parsed, "output.weight");
      declare
         Shape : constant Learning_Lora.Dimensions := Learning_Lora.Shape (Item);
         Width : constant N.Element_Count := N.Element_Count (Shape.Width);
         Rank : constant N.Element_Count := N.Element_Count (Shape.Rank);
         Row : N.Real_Array (0 .. Width - 1);
         View : T.View;
         Head_At : B.Byte_Count;
         Format : G.Tensor_Type;
      begin
         if Target = 0 or else C.Tensor_Rank (Parsed, Target) /= 2
           or else C.Tensor_Dimension (Parsed, Target, 1) /= G.U64 (Shape.Width)
           or else C.Tensor_Dimension (Parsed, Target, 2) /= G.U64 (Shape.Vocabulary)
         then
            Status := E.Make (E.Tensor_Shape_Mismatch);
            E.Add_Frame (Status, "learning.merge.head_shape");
            E.Add_Integer (Status, "width", Long_Long_Integer (Shape.Width));
            E.Add_Integer (Status, "vocabulary", Long_Long_Integer (Shape.Vocabulary));
            E.Add_Integer (Status, "target", Long_Long_Integer (Target));
            return;
         end if;
         Format := C.Tensor_Format (Parsed, Target);
         if Format not in G.Type_F32 | G.Type_F16
           and then not (for some Kind in Quantizer.Target => Quantizer.Type_Of (Kind) = Format)
         then
            Status := E.Make (E.Tensor_Format_Unsupported);
            return;
         end if;
         T.Allocate (Width * Rank, Down);
         T.Allocate (N.Element_Count (Shape.Vocabulary) * Rank, Up);
         if Down = null or else Up = null then
            T.Free (Down);
            T.Free (Up);
            Learning_Lora.Clear (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         Learning_Lora.Get_Factors (Item, Down.all, Up.all, Status);
         Head_At := B.Byte_Count (C.Tensor_Offset (Parsed, Target));
         T.Make (Format, N.Element_Count (Shape.Vocabulary), Width,
                 Source.Base, Source.Size, Head_At, View, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         IO.Create (File, IO.Out_File, Output_Path);
         while At_Byte < Source.Size loop
            if At_Byte = Head_At then
               for V in 0 .. N.Element_Count (Shape.Vocabulary) - 1 loop
                  T.Dequantize_Row (View, V, Row, Status);
                  if E.Is_Error (Status) then
                     exit;
                  end if;
                  declare
                     Nonzero : Boolean := False;
                  begin
                     for C in 0 .. Width - 1 loop
                        declare
                           Change : N.Wide_Real := 0.0;
                        begin
                           for R in 0 .. Rank - 1 loop
                              Change := Change + N.Wide_Real (Up (V * Rank + R)) * N.Wide_Real (Down (R * Width + C));
                           end loop;
                           Nonzero := Nonzero or else Change /= 0.0;
                           Signal_Squares := Signal_Squares + Change * Change;
                           Row (C) := N.Real (N.Wide_Real (Row (C)) + Change);
                        end;
                     end loop;
                     if not Nonzero then
                        declare
                           Raw : B.Byte_Array (1 .. T.Row_Bytes (View));
                        begin
                           Source.Read (At_Byte, Raw, Status);
                           Write (File, Raw);
                        end;
                     elsif Format = G.Type_F32 then
                        Write (File, Fixtures.Encode_F32 (Row));
                     elsif Format = G.Type_F16 then
                        declare
                           Encoded : constant B.Byte_Array := Fixtures.Encode_F16 (Row);
                           View : T.View;
                           Made : N.Real_Array (0 .. Width - 1);
                        begin
                           T.Make (Format, 1, Width, Encoded'Address, Encoded'Length, 0, View, Status);
                           T.Dequantize_Row (View, 0, Made, Status);
                           for C in Row'Range loop
                              Error_Squares := Error_Squares + (N.Wide_Real (Made (C)) - N.Wide_Real (Row (C))) ** 2;
                              Maximum_Error := N.Wide_Real'Max
                                (Maximum_Error, abs (N.Wide_Real (Made (C)) - N.Wide_Real (Row (C))));
                           end loop;
                           Write (File, Encoded);
                        end;
                     else
                        declare
                           Encoded : constant B.Byte_Array := Quantizer.Encode (Row, Target_Format);
                           View : T.View;
                           Made : N.Real_Array (0 .. Width - 1);
                        begin
                           T.Make (Format, 1, Width, Encoded'Address, Encoded'Length, 0, View, Status);
                           T.Dequantize_Row (View, 0, Made, Status);
                           for C in Row'Range loop
                              Error_Squares := Error_Squares + (N.Wide_Real (Made (C)) - N.Wide_Real (Row (C))) ** 2;
                              Maximum_Error := N.Wide_Real'Max
                                (Maximum_Error, abs (N.Wide_Real (Made (C)) - N.Wide_Real (Row (C))));
                           end loop;
                           Write (File, Encoded);
                        end;
                     end if;
                  end;
                  Cells := Cells + Width;
                  At_Byte := At_Byte + T.Row_Bytes (View);
               end loop;
            else
               declare
                  Count : constant B.Byte_Count := B.Byte_Count'Min
                    (Buffer'Length, (if At_Byte < Head_At then Head_At else Source.Size) - At_Byte);
               begin
                  Source.Read (At_Byte, Buffer (1 .. Count), Status);
                  if E.Is_Error (Status) then
                     exit;
                  end if;
                  Write (File, Buffer (1 .. Count));
                  At_Byte := At_Byte + Count;
               end;
            end if;
            exit when E.Is_Error (Status);
         end loop;
         IO.Close (File);
         if E.Is_Ok (Status) then
            declare
               package J renames Jsonlib.Documents;
               Doc : J.Document;
               Root : constant J.Node := J.New_Object (Doc);
            begin
               J.Set_Root (Doc, Root);
               J.Insert (Doc, Root, "base_sha256", J.New_String (Doc, Base_SHA));
               J.Insert (Doc, Root, "adapter_sha256", J.New_String (Doc, Digest (Adapter_Path)));
               J.Insert (Doc, Root, "output_sha256", J.New_String (Doc, Digest (Output_Path)));
               J.Insert (Doc, Root, "tensor", J.New_String (Doc, "output.weight"));
               J.Insert (Doc, Root, "elements", J.New_Integer (Doc, Long_Long_Integer (Cells)));
               J.Insert (Doc, Root, "quantization_squared_error", J.New_Float (Doc, Long_Float (Error_Squares)));
               J.Insert (Doc, Root, "update_squared_norm", J.New_Float (Doc, Long_Float (Signal_Squares)));
               J.Insert (Doc, Root, "maximum_quantization_error", J.New_Float (Doc, Long_Float (Maximum_Error)));
               Project_Tools.Files.Write_Raw_File
                 (Output_Path & ".merge.json", Jsonlib.Serializers.To_String (Doc) & ASCII.LF);
            end;
         end if;
      end;
      Learning_Lora.Clear (Item);
      T.Free (Down);
      T.Free (Up);
   exception
      when others =>
         Learning_Lora.Clear (Item);
         T.Free (Down);
         T.Free (Up);
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         Status := E.Make (E.IO_Write_Failed);
   end Merge;
end Learning_Lora_Files;
