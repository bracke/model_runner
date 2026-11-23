with Ada.Text_IO;
with Ada.Strings.Unbounded;
with System;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Platform;
with Project_Tools.Files;

package body Adapter_Inspection is

   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package F renames Model_Runner.Byte_Sources.Files;
   package G renames Model_Runner.GGUF;
   package J renames Jsonlib.Documents;
   package L renames Model_Runner.Llama;
   use type Interfaces.Unsigned_64;
   use type B.Byte_Count;
   use type G.Value_Type;
   use type G.Tensor_Type;
   use type L.Configuration;
   use Ada.Strings.Unbounded;
   use type Model_Runner.Numerics.Wide_Real;

   --  Size is the manifest's advertised size; Read still refuses any byte absent from the prefix.
   --  This source is used only for descriptor inspection, never model preparation or inference.
   type Header_Source is limited new Model_Runner.Byte_Sources.Source with record
      File : F.File_Source;
      Advertised : B.Byte_Count := 0;
   end record;
   overriding function Size (Self : Header_Source) return B.Byte_Count is (Self.Advertised);
   overriding procedure Read
     (Self : in out Header_Source; Offset : B.Byte_Count; Target : out B.Byte_Array; Status : out E.Error_Info);
   overriding function Is_Mapped (Self : Header_Source) return Boolean is (False);
   overriding function Base (Self : Header_Source) return System.Address is (System.Null_Address);
   overriding function Name (Self : Header_Source) return String is (F.Name (Self.File));
   overriding function Changed (Self : Header_Source) return Boolean is (F.Changed (Self.File));

   overriding procedure Read
     (Self : in out Header_Source; Offset : B.Byte_Count; Target : out B.Byte_Array; Status : out E.Error_Info)
   is
   begin
      F.Read (Self.File, Offset, Target, Status);
   end Read;

   function Same_Metadata
     (Left, Right : C.Container; Prefix : String; Reason : out Unbounded_String) return Boolean is
      Count_Left, Count_Right : Natural := 0;
      function Starts (Text : String) return Boolean
      is (Text'Length >= Prefix'Length and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);
   begin
      Reason := Null_Unbounded_String;
      for Index in 1 .. C.Metadata_Count (Right) loop
         if Starts (C.Metadata_Key (Right, Index)) then
            Count_Right := Count_Right + 1;
         end if;
      end loop;
      for Index in 1 .. C.Metadata_Count (Left) loop
         declare
            Key : constant String := C.Metadata_Key (Left, Index);
            Other : constant Natural := C.Find (Right, Key);
         begin
            if Starts (Key) then
               Reason := To_Unbounded_String (Key);
               Count_Left := Count_Left + 1;
               if Other = 0 or else C.Metadata_Kind (Left, Index) /= C.Metadata_Kind (Right, Other)
                 or else C.Metadata_Length (Left, Index) /= C.Metadata_Length (Right, Other)
               then
                  return False;
               elsif C.Metadata_Kind (Left, Index) /= G.Value_Array then
                  if C.Value_Image (Left, Index, 1_048_576) /= C.Value_Image (Right, Other, 1_048_576) then
                     return False;
                  end if;
               else
                  if C.Metadata_Element_Kind (Left, Index) /= C.Metadata_Element_Kind (Right, Other) then
                     return False;
                  end if;
                  for Position in 1 .. C.Metadata_Length (Left, Index) loop
                     declare
                        Kind : constant G.Value_Type := C.Metadata_Element_Kind (Left, Index);
                        A, Z : String (1 .. 32_768);
                        A_Last, Z_Last : Natural;
                        A_Int, Z_Int : Long_Long_Integer;
                        A_Float, Z_Float : Model_Runner.Numerics.Wide_Real;
                        A_Bool, Z_Bool : Boolean;
                        A_Status, Z_Status : E.Error_Info;
                     begin
                        if Kind = G.Value_String then
                           C.Get_String_Element (Left, Key, Position, A, A_Last, A_Status, Index);
                           C.Get_String_Element (Right, Key, Position, Z, Z_Last, Z_Status, Other);
                           if E.Is_Error (A_Status) or else E.Is_Error (Z_Status)
                             or else A (1 .. A_Last) /= Z (1 .. Z_Last)
                           then
                              return False;
                           end if;
                        elsif Kind in G.Value_Float32 | G.Value_Float64 then
                           C.Get_Float_Element (Left, Key, Position, A_Float, A_Status, Index);
                           C.Get_Float_Element (Right, Key, Position, Z_Float, Z_Status, Other);
                           if E.Is_Error (A_Status) or else E.Is_Error (Z_Status) or else A_Float /= Z_Float then
                              return False;
                           end if;
                        elsif Kind = G.Value_Bool then
                           C.Get_Boolean_Element (Left, Key, Position, A_Bool, A_Status);
                           C.Get_Boolean_Element (Right, Key, Position, Z_Bool, Z_Status);
                           if E.Is_Error (A_Status) or else E.Is_Error (Z_Status) or else A_Bool /= Z_Bool then
                              return False;
                           end if;
                        else
                           C.Get_Integer_Element (Left, Key, Position, A_Int, A_Status, Index);
                           C.Get_Integer_Element (Right, Key, Position, Z_Int, Z_Status, Other);
                           if E.Is_Error (A_Status) or else E.Is_Error (Z_Status) or else A_Int /= Z_Int then
                              return False;
                           end if;
                        end if;
                     end;
                  end loop;
               end if;
            end if;
         end;
      end loop;
      Reason := (if Count_Left = Count_Right then Null_Unbounded_String else To_Unbounded_String (Prefix));
      return Count_Left = Count_Right;
   end Same_Metadata;

   procedure Run
     (Base, Adapted, Adapter, Output_Path : String;
      Base_Bytes, Adapted_Bytes, Adapter_Bytes : Interfaces.Unsigned_64;
      Clean : out Boolean)
   is
      First, Second, Third : Header_Source;
      Original, Modified, Adapter_Container : C.Container;
      Settings : L.Configuration;
      Other_Settings : L.Configuration;
      Plan : Model_Runner.Memory.Session_Plan;
      Status : E.Error_Info;
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Failures : constant J.Node := J.New_Array (Doc);
      Pairs : Natural := 0;
      Parameters, Delta_Parameters : Interfaces.Unsigned_64 := 0;
      Bad : Natural := 0;
      Reason : Unbounded_String;

      procedure Problem (Text : String) is
      begin
         Bad := Bad + 1;
         J.Append (Doc, Failures, J.New_String (Doc, Text));
      end Problem;

      procedure Count (Key : String; Value : Interfaces.Unsigned_64) is
      begin
         J.Insert (Doc, Root, Key, J.New_Integer (Doc, Long_Long_Integer (Value)));
      end Count;

      procedure Open (Source : in out Header_Source; Container : in out C.Container;
                      Path : String; Advertised : Interfaces.Unsigned_64) is
      begin
         F.Open (Source.File, Path, Policy => F.Mapping_Disabled, Status => Status);
         if E.Is_Error (Status) then
            Problem ("cannot open " & Path);
            return;
         end if;
         Source.Advertised := (if Advertised = 0 then F.Size (Source.File) else B.Byte_Count (Advertised));
         if Source.Advertised < F.Size (Source.File) then
            Problem ("advertised size is smaller than the prefix: " & Path);
            return;
         end if;
         C.Reader.Parse (Container, Source, Status => Status);
         if E.Is_Error (Status) then
            Problem ("invalid or incomplete header " & Path & ": " & E.Error_Code'Image (Status.Code));
         end if;
      end Open;

      procedure Close is
      begin
         C.Close (Original);
         C.Close (Modified);
         C.Close (Adapter_Container);
         F.Close (First.File);
         F.Close (Second.File);
         F.Close (Third.File);
      end Close;
   begin
      Clean := False;
      J.Set_Root (Doc, Root);
      J.Insert (Doc, Root, "schema_version", J.New_Integer (Doc, 1));
      J.Insert (Doc, Root, "scope", J.New_String (Doc, "header inspection only; no tensor payload verified"));
      J.Insert (Doc, Root, "payload_verified", J.New_Boolean (Doc, False));
      J.Insert (Doc, Root, "failures", Failures);
      Open (First, Original, Base, Base_Bytes);
      Open (Second, Modified, Adapted, Adapted_Bytes);
      Open (Third, Adapter_Container, Adapter, Adapter_Bytes);
      if Bad = 0 then
         J.Insert (Doc, Root, "architecture",
                   J.New_String (Doc, C.String_Value (Original, "general.architecture")));
         L.Read_Config (Original, Settings => Settings, Status => Status);
         if E.Is_Error (Status) then
            Problem ("architecture configuration: " & E.Error_Code'Image (Status.Code));
         else
            L.Read_Config (Modified, Settings => Other_Settings, Status => Status);
            if E.Is_Error (Status) or else Settings /= Other_Settings then
               Problem ("resolved architecture configurations differ");
            end if;
            L.Plan_For (Settings, 8_192, Plan, Status, Cache => L.Transformed_Fourth);
            if E.Is_Ok (Status) then
               Count ("session_estimate_8192_q4t_bytes", Plan.Total_Resident);
            end if;
         end if;
         if C.String_Value (Original, "general.architecture") /= C.String_Value (Modified, "general.architecture")
           or else C.String_Value (Original, "general.architecture")
             /= C.String_Value (Adapter_Container, "general.architecture")
         then
            Problem ("architecture mismatch");
         end if;
         if not Same_Metadata (Original, Modified, "tokenizer.", Reason) then
            Problem ("tokenizer or chat template differs: " & To_String (Reason));
         end if;
         if not Same_Metadata
           (Original, Modified, C.String_Value (Original, "general.architecture") & ".", Reason)
         then
            Problem ("architecture metadata differs: " & To_String (Reason));
         end if;
         if C.Tensor_Count (Original) /= C.Tensor_Count (Modified) then
            Problem ("tensor counts differ");
         end if;
         for Index in 1 .. C.Tensor_Count (Original) loop
            declare
               Other : constant Natural := C.Find_Tensor (Modified, C.Tensor_Name (Original, Index));
            begin
               Parameters := Parameters + C.Tensor_Elements (Original, Index);
               if Other = 0 or else C.Tensor_Rank (Original, Index) /= C.Tensor_Rank (Modified, Other)
                 or else C.Tensor_Format (Original, Index) /= C.Tensor_Format (Modified, Other)
               then
                  Problem ("tensor descriptor mismatch: " & C.Tensor_Name (Original, Index));
               else
                  for Axis in 1 .. C.Tensor_Rank (Original, Index) loop
                     if C.Tensor_Dimension (Original, Index, Axis) /= C.Tensor_Dimension (Modified, Other, Axis) then
                        Problem ("tensor dimension mismatch: " & C.Tensor_Name (Original, Index));
                     end if;
                  end loop;
               end if;
            end;
         end loop;
         if C.String_Value (Adapter_Container, "general.type") /= "adapter"
           or else C.String_Value (Adapter_Container, "adapter.type") /= "lora"
           or else C.Has (Adapter_Container, "adapter.alora.invocation_tokens")
         then
            Problem ("unsupported adapter metadata");
         end if;
         for Index in 1 .. C.Tensor_Count (Adapter_Container) loop
            declare
               Name : constant String := C.Tensor_Name (Adapter_Container, Index);
               Is_A : constant Boolean := Name'Length > 7 and then Name (Name'Last - 6 .. Name'Last) = ".lora_a";
               Is_B : constant Boolean := Name'Length > 7 and then Name (Name'Last - 6 .. Name'Last) = ".lora_b";
               Stem : constant String := (if Is_A or else Is_B then Name (Name'First .. Name'Last - 7) else "");
               Target : constant Natural := C.Find_Tensor (Original, Stem);
               Other : constant Natural := C.Find_Tensor
                 (Adapter_Container, Stem & (if Is_A then ".lora_b" else ".lora_a"));
            begin
               Delta_Parameters := Delta_Parameters + C.Tensor_Elements (Adapter_Container, Index);
               if not (Is_A or Is_B) or else Target = 0 or else Other = 0
                 or else C.Tensor_Rank (Adapter_Container, Index) /= 2
                 or else C.Tensor_Rank (Adapter_Container, Other) /= 2
                 or else C.Tensor_Rank (Original, Target) /= 2
               then
                  Problem ("unresolved adapter tensor: " & Name);
               elsif Is_A then
                  Pairs := Pairs + 1;
                  if C.Tensor_Dimension (Adapter_Container, Index, 1) /= C.Tensor_Dimension (Original, Target, 1)
                    or else C.Tensor_Dimension (Adapter_Container, Other, 2) /= C.Tensor_Dimension (Original, Target, 2)
                    or else C.Tensor_Dimension (Adapter_Container, Index, 2)
                      /= C.Tensor_Dimension (Adapter_Container, Other, 1)
                  then
                     Problem ("adapter pair shape mismatch: " & Stem);
                  end if;
               end if;
            end;
         end loop;
         Count ("base_parameters", Parameters);
         Count ("adapter_parameters", Delta_Parameters);
         Count ("adapter_pairs", Interfaces.Unsigned_64 (Pairs));
         Count ("base_file_bytes", Interfaces.Unsigned_64 (First.Advertised));
         Count ("f32_weight_estimate_bytes", Parameters * 4);
         Count ("physical_memory_bytes", Model_Runner.Platform.Physical_Memory);
         Count ("available_memory_bytes", Model_Runner.Platform.Available_Memory);
         J.Insert (Doc, Root, "q8_weights_fit_available_memory", J.New_Boolean
                   (Doc, Interfaces.Unsigned_64 (First.Advertised) < Model_Runner.Platform.Available_Memory));
         if Pairs = 0 then
            Problem ("no adapter pairs");
         end if;
      end if;
      Clean := Bad = 0;
      J.Insert (Doc, Root, "headers_compatible", J.New_Boolean (Doc, Clean));
      Project_Tools.Files.Write_Raw_File
        (Output_Path, Jsonlib.Serializers.To_String (Doc, (Jsonlib.Serializers.Default_Options with delta
                                                         Form => Jsonlib.Serializers.Pretty)));
      Close;
   exception
      when others =>
         Close;
         Ada.Text_IO.Put_Line ("adapter inspection failed");
         Clean := False;
   end Run;

end Adapter_Inspection;
