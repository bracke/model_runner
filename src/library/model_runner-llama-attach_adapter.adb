with GNAT.SHA256;

separate (Model_Runner.Llama)
procedure Attach_Adapter
  (Item : in out Model; Source : Containers.Container;
   Bytes : in out Model_Runner.Byte_Sources.Source'Class;
   Scale : Real := 1.0; Status : out E.Error_Info;
   Bounds : Adapter_Limits := Default_Adapter_Limits;
   Cancel : Model_Runner.Cancellation.Token_Reference := null)
is
   pragma Suppress (Validity_Check);
   use type Model_Runner.Backend.Backend_Kind;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Interfaces.Unsigned_32;

   Names : constant array (1 .. 7) of Model_Runner.Text.Bounded :=
     [Model_Runner.Text.To_Bounded ("attn_q"), Model_Runner.Text.To_Bounded ("attn_k"),
      Model_Runner.Text.To_Bounded ("attn_v"), Model_Runner.Text.To_Bounded ("attn_output"),
      Model_Runner.Text.To_Bounded ("ffn_gate"), Model_Runner.Text.To_Bounded ("ffn_up"),
      Model_Runner.Text.To_Bounded ("ffn_down")];
   Old_Count : constant Natural := (if Item.Runtime_Pairs = null then 0 else Item.Runtime_Pairs'Length);
   Old_Descriptors : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64 (Old_Count) * (Runtime_Pair'Object_Size / System.Storage_Unit);
   Fresh : Runtime_Pair_Access := null;
   Used : Natural := Old_Count;
   Data_Bytes : Interfaces.Unsigned_64 := 0;
   Descriptor_Bytes : Interfaces.Unsigned_64 := 0;
   Staged : Mem.Account := Item.Accounting;
   Alpha : Wide_Real := 0.0;
   Most_Rank, Most_Rows : Element_Count := 0;
   Context : GNAT.SHA256.Context;
   Raw : B.Byte_Array (1 .. 65_536);
   Hashed : String (1 .. 65_536);
   Hash_Used : Natural := 0;

   procedure Cleanup is
   begin
      if Fresh /= null and then Fresh /= Item.Runtime_Pairs then
         for Index in Old_Count + 1 .. Fresh'Last loop
            T.Free (Fresh (Index).Down);
            T.Free (Fresh (Index).Up);
         end loop;
         Free_Runtime_Pairs (Fresh);
      end if;
   end Cleanup;

   procedure Unsupported (Feature : String) is
   begin
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", Feature, E.Param_Identifier);
   end Unsupported;

   procedure Limit (Requested, Maximum : Interfaces.Unsigned_64) is
   begin
      Status := E.Make (E.Memory_Limit_Exceeded);
      E.Add_Text (Status, "category", "adapter_weights", E.Param_Identifier);
      E.Add_Integer (Status, "requested", Long_Long_Integer (Requested), E.Param_Bytes);
      E.Add_Integer (Status, "limit", Long_Long_Integer (Maximum), E.Param_Bytes);
   end Limit;

   procedure Hash_Word (Value : Interfaces.Unsigned_64; Length : Positive := 8) is
      Word : String (1 .. Length);
      Rest : Interfaces.Unsigned_64 := Value;
   begin
      for Ch of Word loop
         Ch := Character'Val (Rest and 16#FF#);
         Rest := Interfaces.Shift_Right (Rest, 8);
      end loop;
      GNAT.SHA256.Update (Context, Word);
   end Hash_Word;

   procedure Hash_Value (Value : Real) is
      Rest : Interfaces.Unsigned_32 := N.Bits (Value);
   begin
      for Index in 1 .. 4 loop
         Hash_Used := Hash_Used + 1;
         Hashed (Hash_Used) := Character'Val (Rest and 16#FF#);
         Rest := Interfaces.Shift_Right (Rest, 8);
      end loop;
      if Hash_Used = Hashed'Length then
         GNAT.SHA256.Update (Context, Hashed);
         Hash_Used := 0;
      end if;
   end Hash_Value;

   procedure Load_Matrix (Index : Positive; Into : T.Real_Array_Access) is
      Format : constant Model_Runner.GGUF.Tensor_Type := Containers.Tensor_Format (Source, Index);
      Each : constant B.Byte_Count := (if Format = Model_Runner.GGUF.Type_F32 then 4 else 2);
      Offset : B.Byte_Count := B.Byte_Count (Containers.Tensor_Offset (Source, Index));
      Done : Element_Count := 0;
   begin
      while Done < Into'Length loop
         if C.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;
         declare
            Take : constant Element_Count := Element_Count'Min (Into'Length - Done, Element_Count (65_536 / Each));
            Count : constant B.Byte_Count := B.Byte_Count (Take) * Each;
         begin
            Bytes.Read (Offset, Raw (1 .. Count), Status);
            if E.Is_Error (Status) then
               return;
            end if;
            for Position in 0 .. Take - 1 loop
               declare
                  At_Byte : constant B.Byte_Count := 1 + B.Byte_Count (Position) * Each;
                  Bits : Interfaces.Unsigned_32 := Interfaces.Unsigned_32 (Raw (At_Byte))
                    or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 1)), 8);
                  Value : Real;
               begin
                  if Each = 4 then
                     Bits := Bits or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 2)), 16)
                       or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 3)), 24);
                     Value := N.From_Bits (Bits);
                  else
                     Value := N.To_Real (N.Half (Bits));
                  end if;
                  if not N.Is_Finite (Value) then
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Text (Status, "tensor", Containers.Tensor_Name (Source, Index), E.Param_Identifier);
                     return;
                  end if;
                  Into (Done + Position) := Value;
                  Hash_Value (Value);
               end;
            end loop;
            Done := Done + Take;
            Offset := Offset + Count;
         end;
      end loop;
   end Load_Matrix;

   function Shape_OK (Index : Positive; Columns, Rows : Element_Count) return Boolean is
      Offset : constant Interfaces.Unsigned_64 := Containers.Tensor_Offset (Source, Index);
      Format : constant Model_Runner.GGUF.Tensor_Type := Containers.Tensor_Format (Source, Index);
      Length : Interfaces.Unsigned_64;
   begin
      if Containers.Tensor_Rank (Source, Index) /= 2
        or else Containers.Tensor_Dimension (Source, Index, 1) /= Interfaces.Unsigned_64 (Columns)
        or else Containers.Tensor_Dimension (Source, Index, 2) /= Interfaces.Unsigned_64 (Rows)
      then
         Status := E.Make (E.Arch_Invalid_Tensor_Shape);
      elsif Format not in Model_Runner.GGUF.Type_F32 | Model_Runner.GGUF.Type_F16 then
         Status := E.Make (E.Tensor_Format_Unsupported);
      else
         Length := Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Rows)
           * (if Format = Model_Runner.GGUF.Type_F32 then 4 else 2);
         if Offset <= Interfaces.Unsigned_64 (Bytes.Size)
           and then Length <= Interfaces.Unsigned_64 (Bytes.Size) - Offset
         then
            return True;
         end if;
         Status := E.Make (E.GGUF_Tensor_Out_Of_Bounds);
      end if;
      E.Add_Text (Status, "tensor", Containers.Tensor_Name (Source, Index), E.Param_Identifier);
      return False;
   end Shape_OK;
begin
   Status := E.Success;
   if not Item.Ready then
      Status := E.Make (E.Lifecycle_Model_Not_Ready);
      return;
   elsif Item.Sessions > 0 then
      Status := E.Make (E.Lifecycle_Session_Active);
      return;
   elsif Item.Able.Kind not in Model_Runner.Backend.Backend_CPU | Model_Runner.Backend.Backend_Reference
     or else Item.Settings.Kind not in Llama | Qwen2 | Qwen3 | Qwen35 | Granite
     or else Item.Settings.Experts /= 0
     or else Item.Layers_Light /= null or else Item.Light_Head /= null
     or else (Old_Count = 0 and then Item.Adapted /= 0)
   then
      Unsupported ("runtime_adapter_combination");
      return;
   elsif Bounds.Max_Adapters > 8 or else Bounds.Max_Pairs > 4_096 or else Bounds.Max_Rank > 64
     or else Bounds.Max_Bytes = 0 or else Bounds.Max_Bytes > 2 ** 30
     or else Item.Runtime_Rank > Element_Count (Bounds.Max_Rank)
   then
      Unsupported ("adapter_limits");
      return;
   elsif not N.Is_Finite (Scale) then
      Status := E.Make (E.Tensor_Non_Finite_Value);
      E.Add_Text (Status, "tensor", "adapter.scale", E.Param_Identifier);
      return;
   elsif Runtime_Adapter_Count (Item) >= Bounds.Max_Adapters then
      Limit (Interfaces.Unsigned_64 (Item.Runtime_Files + 1), Interfaces.Unsigned_64 (Bounds.Max_Adapters));
      return;
   end if;
   if C.Is_Cancelled (Cancel) then
      Status := E.Make (E.Generation_Cancelled);
      return;
   end if;
   if Containers.String_Value (Source, "general.type") /= "adapter"
     or else Containers.String_Value (Source, "adapter.type") /= "lora"
     or else Containers.String_Value (Source, "general.architecture") /= Architecture_Name (Item.Settings.Kind)
     or else Containers.Has (Source, "adapter.alora.invocation_tokens")
   then
      Unsupported ("adapter_metadata");
      return;
   end if;
   if Containers.Has (Source, "adapter.lora.alpha") then
      Containers.Get_Float (Source, "adapter.lora.alpha", 0.0, 1.0E6, Alpha, Status);
      if E.Is_Error (Status) then
         return;
      end if;
   end if;
   if Containers.Tensor_Count (Source) = 0 or else Containers.Tensor_Count (Source) mod 2 /= 0 then
      Status := E.Make (E.Arch_Missing_Tensor);
      E.Add_Text (Status, "tensor", "adapter_pair", E.Param_Identifier);
      return;
   end if;
   if Containers.Tensor_Count (Source) / 2 > Bounds.Max_Pairs - Natural'Min (Old_Count, Bounds.Max_Pairs) then
      Limit (Interfaces.Unsigned_64 (Old_Count) + Interfaces.Unsigned_64 (Containers.Tensor_Count (Source) / 2),
             Interfaces.Unsigned_64 (Bounds.Max_Pairs));
      return;
   end if;
   declare
      New_Count : constant Positive := Containers.Tensor_Count (Source) / 2;
      Seen : array (1 .. New_Count * 2) of Boolean := [others => False];
   begin
      Descriptor_Bytes := Interfaces.Unsigned_64 (Old_Count + New_Count)
        * (Runtime_Pair'Object_Size / System.Storage_Unit);
      if Runtime_Adapter_Bytes (Item) - Old_Descriptors + Descriptor_Bytes > Bounds.Max_Bytes then
         Limit (Runtime_Adapter_Bytes (Item) - Old_Descriptors + Descriptor_Bytes, Bounds.Max_Bytes);
         return;
      end if;
      Mem.Check_Allocation (Staged, Mem.Converted_Weights, Descriptor_Bytes, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  Descriptor storage is bounded before any payload allocation. Old pointers are borrowed only until commit.
      Fresh := new Runtime_Pair_List (1 .. Old_Count + New_Count);
      if Old_Count > 0 then
         Fresh (1 .. Old_Count) := Item.Runtime_Pairs.all;
      end if;
      for Layer_Index in Item.Layers'Range loop
         if C.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            Cleanup;
            return;
         end if;
         for Which in Names'Range loop
            declare
               Stem : constant String :=
                 Layer_Key (Layer_Index, Model_Runner.Text.To_String (Names (Which)) & ".weight");
               A_Index : constant Natural := Containers.Find_Tensor (Source, Stem & ".lora_a");
               B_Index : constant Natural := Containers.Find_Tensor (Source, Stem & ".lora_b");
               Target : T.View;
               Rank : Element_Count;
               Needed : Interfaces.Unsigned_64;
            begin
               if (A_Index = 0) /= (B_Index = 0) then
                  Status := E.Make (E.Arch_Missing_Tensor);
                  E.Add_Text (Status, "tensor", Stem & (if A_Index = 0 then ".lora_a" else ".lora_b"),
                              E.Param_Identifier);
                  Cleanup;
                  return;
               end if;
               if A_Index /= 0 then
                  Target := (case Which is
                               when 1 => Item.Layers (Layer_Index).Query,
                               when 2 => Item.Layers (Layer_Index).Key,
                               when 3 => Item.Layers (Layer_Index).Value,
                               when 4 => Item.Layers (Layer_Index).Attention_Out,
                               when 5 => Item.Layers (Layer_Index).Gate,
                               when 6 => Item.Layers (Layer_Index).Up,
                               when others => Item.Layers (Layer_Index).Down);
                  if not T.Is_Present (Target) then
                     Status := E.Make (E.Arch_Missing_Tensor);
                     E.Add_Text (Status, "tensor", Stem, E.Param_Identifier);
                     Cleanup;
                     return;
                  end if;
                  if Containers.Tensor_Rank (Source, A_Index) /= 2
                    or else Containers.Tensor_Dimension (Source, A_Index, 2) = 0
                    or else Containers.Tensor_Dimension (Source, A_Index, 2) > Interfaces.Unsigned_64 (Bounds.Max_Rank)
                  then
                     Status := E.Make (E.Arch_Invalid_Tensor_Shape);
                     E.Add_Text (Status, "tensor", Stem & ".lora_a", E.Param_Identifier);
                     Cleanup;
                     return;
                  end if;
                  Rank := Element_Count (Containers.Tensor_Dimension (Source, A_Index, 2));
                  Needed := 4 * Interfaces.Unsigned_64 (Rank)
                    * (Interfaces.Unsigned_64 (Target.Columns) + Interfaces.Unsigned_64 (Target.Rows));
                  if Runtime_Adapter_Bytes (Item) - Old_Descriptors + Descriptor_Bytes + Data_Bytes + Needed
                    > Bounds.Max_Bytes
                  then
                     Limit (Runtime_Adapter_Bytes (Item) - Old_Descriptors + Descriptor_Bytes + Data_Bytes + Needed,
                            Bounds.Max_Bytes);
                     Cleanup;
                     return;
                  end if;
                  if not Shape_OK (A_Index, Target.Columns, Rank) or else not Shape_OK (B_Index, Rank, Target.Rows) then
                     Cleanup;
                     return;
                  end if;
                  Used := Used + 1;
                  Fresh (Used).Target := Target;
                  Fresh (Used).Rank := Rank;
                  Fresh (Used).Factor := Wide_Real (Scale) * (if Alpha = 0.0 then 1.0 else Alpha / Wide_Real (Rank));
                  Fresh (Used).Down_Index := A_Index;
                  Fresh (Used).Up_Index := B_Index;
                  Data_Bytes := Data_Bytes + Needed;
                  Most_Rank := Element_Count'Max (Most_Rank, Rank);
                  Most_Rows := Element_Count'Max (Most_Rows, Target.Rows);
                  Seen (A_Index) := True;
                  Seen (B_Index) := True;
               end if;
            end;
         end loop;
      end loop;
      if Used /= Fresh'Last or else (for some Value of Seen => not Value) then
         Unsupported ("adapter_target");
         Cleanup;
         return;
      end if;
   end;
   Mem.Check_Allocation (Staged, Mem.Converted_Weights, Data_Bytes + Descriptor_Bytes, Status);
   if E.Is_Error (Status) then
      Cleanup;
      return;
   end if;
   Mem.Record_Allocation (Staged, Mem.Converted_Weights, Data_Bytes + Descriptor_Bytes);
   GNAT.SHA256.Update (Context, "model_runner.cpu_lora.v2.tiled8.wide");
   Hash_Word (Interfaces.Unsigned_64 (N.Bits (Scale)), 4);
   Hash_Word (N.Wide_Bits (Alpha));
   Hash_Word (Boolean'Pos (Containers.Has (Source, "adapter.lora.alpha")), 1);
   for Index in Old_Count + 1 .. Fresh'Last loop
      declare
         Pair : Runtime_Pair renames Fresh (Index);
         Name : constant String := Containers.Tensor_Name (Source, Pair.Down_Index);
      begin
         if C.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            Cleanup;
            return;
         end if;
         Hash_Word (Name'Length);
         GNAT.SHA256.Update (Context, Name);
         Hash_Word (Interfaces.Unsigned_64 (Pair.Target.Columns));
         Hash_Word (Interfaces.Unsigned_64 (Pair.Target.Rows));
         Hash_Word (Interfaces.Unsigned_64 (Pair.Rank));
         T.Allocate (Pair.Rank * Pair.Target.Columns, Pair.Down);
         T.Allocate (Pair.Rank * Pair.Target.Rows, Pair.Up);
         if Pair.Down = null or else Pair.Up = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            Cleanup;
            return;
         end if;
         Load_Matrix (Pair.Down_Index, Pair.Down);
         if E.Is_Ok (Status) then
            Load_Matrix (Pair.Up_Index, Pair.Up);
         end if;
         if E.Is_Error (Status) then
            Cleanup;
            return;
         end if;
         if Hash_Used > 0 then
            GNAT.SHA256.Update (Context, Hashed (1 .. Hash_Used));
            Hash_Used := 0;
         end if;
      end;
   end loop;
   if C.Is_Cancelled (Cancel) then
      Status := E.Make (E.Generation_Cancelled);
      Cleanup;
      return;
   elsif Bytes.Changed then
      Status := E.Make (E.GGUF_File_Changed);
      Cleanup;
      return;
   end if;
   declare
      Digest : constant GNAT.SHA256.Message_Digest := GNAT.SHA256.Digest (Context);
      Identity : Interfaces.Unsigned_64 := (if Item.Adapted = 0 then 16#CBF2_9CE4_8422_2325# else Item.Adapted);
   begin
      for Ch of Digest loop
         Identity := (Identity xor Character'Pos (Ch)) * 16#0000_0100_0000_01B3#;
      end loop;
      Free_Runtime_Pairs (Item.Runtime_Pairs); --  Only the old descriptor array; its matrices moved with Fresh.
      Item.Runtime_Pairs := Fresh;
      Item.Adapted := Identity;
   end;
   Mem.Record_Release (Staged, Mem.Converted_Weights, Old_Descriptors);
   Mem.Record_Conversion (Staged, Data_Bytes);
   Item.Accounting := Staged;
   Item.Runtime_Bytes := Item.Runtime_Bytes - Old_Descriptors + Data_Bytes + Descriptor_Bytes;
   Item.Runtime_Rank := Element_Count'Max (Item.Runtime_Rank, Most_Rank);
   Item.Runtime_Rows := Element_Count'Max (Item.Runtime_Rows, Most_Rows);
   Item.Runtime_Files := Item.Runtime_Files + 1;
exception
   when Storage_Error =>
      Cleanup;
      Status := E.Make (E.Memory_Allocation_Failed);
end Attach_Adapter;
