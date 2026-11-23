with Ada.Text_IO;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Fixtures;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Numerics;
with Model_Runner.Llama;
with Model_Runner.Text;
with Model_Runner.Tensors;

package body Adapter_Fixture is
   procedure Run
     (Model_Path, Output_Path, Tensor_Name : String; Clean : out Boolean;
      Rank : Positive := 2; All_Targets : Boolean := False) is
      package C renames Model_Runner.GGUF.Containers;
      package B renames Model_Runner.Bytes;
      package N renames Model_Runner.Numerics;
      package E renames Model_Runner.Errors;
      package L renames Model_Runner.Llama;
      package T renames Model_Runner.Tensors;
      use type Model_Runner.GGUF.U64;
      use type N.Element_Count;
      use type N.Real;
      use type B.Byte_Count;
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Parsed : C.Container;
      Status : E.Error_Info;
      Builder : Fixtures.Builder;
      Image : B.Byte_Array_Access := null;
      Output : Ada.Streams.Stream_IO.File_Type;
      Created : Boolean := False;
      Down, Up : T.Real_Array_Access := null;
      Settings : L.Configuration;
      Pairs : Natural := 0;
      Encoded_Bytes : Model_Runner.GGUF.U64 := 0;
      Valid : Boolean := True;
      Names : constant array (1 .. 7) of Model_Runner.Text.Bounded :=
        [Model_Runner.Text.To_Bounded ("attn_q"), Model_Runner.Text.To_Bounded ("attn_k"),
         Model_Runner.Text.To_Bounded ("attn_v"), Model_Runner.Text.To_Bounded ("attn_output"),
         Model_Runner.Text.To_Bounded ("ffn_gate"), Model_Runner.Text.To_Bounded ("ffn_up"),
         Model_Runner.Text.To_Bounded ("ffn_down")];

      procedure Add (Name : String) is
         Index : constant Natural := C.Find_Tensor (Parsed, Name);
         Width, Height : N.Element_Count;
         Needed : Model_Runner.GGUF.U64;
      begin
         if Index = 0 then
            return;
         elsif C.Tensor_Rank (Parsed, Index) /= 2
           or else C.Tensor_Dimension (Parsed, Index, 1) not in 1 .. 65_536
           or else C.Tensor_Dimension (Parsed, Index, 2) not in 1 .. 65_536
         then
            Valid := False;
            return;
         end if;
         Width := N.Element_Count (C.Tensor_Dimension (Parsed, Index, 1));
         Height := N.Element_Count (C.Tensor_Dimension (Parsed, Index, 2));
         Needed := 2 * Model_Runner.GGUF.U64 (Rank) * Model_Runner.GGUF.U64 (Width + Height);
         if Pairs = 4_096 or else Needed > 134_217_728 - Encoded_Bytes then
            Valid := False;
            return;
         end if;
         T.Allocate (Width * N.Element_Count (Rank), Down);
         T.Allocate (Height * N.Element_Count (Rank), Up);
         for Cell in Down'Range loop
            Down (Cell) := N.Real (Integer (Cell mod 17) - 8) / 1_024.0;
         end loop;
         for Cell in Up'Range loop
            Up (Cell) := N.Real (Integer (Cell mod 19) - 9) / 1_024.0;
         end loop;
         Fixtures.Add_Tensor (Builder, Name & ".lora_a", [Model_Runner.GGUF.U64 (Width), Model_Runner.GGUF.U64 (Rank)],
                              Model_Runner.GGUF.Type_F16, Fixtures.Encode_F16 (Down.all));
         Fixtures.Add_Tensor (Builder, Name & ".lora_b", [Model_Runner.GGUF.U64 (Rank), Model_Runner.GGUF.U64 (Height)],
                              Model_Runner.GGUF.Type_F16, Fixtures.Encode_F16 (Up.all));
         T.Free (Down);
         T.Free (Up);
         Pairs := Pairs + 1;
         Encoded_Bytes := Encoded_Bytes + Needed;
      end Add;
   begin
      Clean := False;
      if Output_Path = "" or else Ada.Directories.Exists (Output_Path) then
         Ada.Text_IO.Put_Line ("adapter fixture requires a new output path");
         return;
      end if;
      if Rank > 64 then
         Ada.Text_IO.Put_Line ("adapter fixture rank must be in 1 .. 64");
         return;
      end if;
      Model_Runner.Byte_Sources.Files.Open (Source, Model_Path, Status => Status);
      if E.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if E.Is_Ok (Status) then
         L.Read_Config (Parsed, Settings => Settings, Status => Status);
         if All_Targets and then
           (Settings.Kind not in L.Llama | L.Qwen2 | L.Qwen3 | L.Qwen35 or else Settings.Experts /= 0)
         then
            Valid := False;
         end if;
         if E.Is_Ok (Status) and then Valid then
            Fixtures.Add_String (Builder, "general.architecture", C.String_Value (Parsed, "general.architecture"));
            Fixtures.Add_String (Builder, "general.type", "adapter");
            Fixtures.Add_String (Builder, "adapter.type", "lora");
            Fixtures.Add_F32 (Builder, "adapter.lora.alpha", N.Real (Rank));
            if All_Targets then
               for Layer in 0 .. Settings.Layers - 1 loop
                  for Stem of Names loop
                     Add ("blk." & Model_Runner.Text.Image (Long_Long_Integer (Layer)) & "."
                          & Model_Runner.Text.To_String (Stem) & ".weight");
                     exit when not Valid;
                  end loop;
                  exit when not Valid;
               end loop;
            else
               Add (Tensor_Name);
            end if;
            if Valid and then Pairs > 0 then
               Fixtures.Build (Builder, Image);
               declare
                  Raw : Ada.Streams.Stream_Element_Array (1 .. 65_536);
                  Done : B.Byte_Count := 0;
               begin
                  Ada.Streams.Stream_IO.Create (Output, Ada.Streams.Stream_IO.Out_File, Output_Path);
                  Created := True;
                  while Done < Image'Length loop
                     declare
                        Count : constant B.Byte_Count := B.Byte_Count'Min (Image'Length - Done, 65_536);
                     begin
                        for Cell in 1 .. Count loop
                           Raw (Ada.Streams.Stream_Element_Offset (Cell)) :=
                             Ada.Streams.Stream_Element (Image (Image'First + Done + Cell - 1));
                        end loop;
                        Ada.Streams.Stream_IO.Write (Output, Raw (1 .. Ada.Streams.Stream_Element_Offset (Count)));
                        Done := Done + Count;
                     end;
                  end loop;
                  Ada.Streams.Stream_IO.Close (Output);
               end;
               B.Free (Image);
               Clean := True;
            end if;
         end if;
      end if;
      C.Close (Parsed);
      Model_Runner.Byte_Sources.Files.Close (Source);
      Ada.Text_IO.Put_Line (if Clean then "wrote synthetic adapter (not trained)" else "adapter fixture refused");
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (Output) then
            Ada.Streams.Stream_IO.Close (Output);
         end if;
         if Created then
            Ada.Directories.Delete_File (Output_Path);
         end if;
         B.Free (Image);
         T.Free (Down);
         T.Free (Up);
         C.Close (Parsed);
         Model_Runner.Byte_Sources.Files.Close (Source);
         Clean := False;
         Ada.Text_IO.Put_Line ("adapter fixture could not be written");
   end Run;
end Adapter_Fixture;
