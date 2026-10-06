separate (Model_Runner.Llama)
procedure Merge_Adapter
  (Item   : in out Model;
   Source : Containers.Container;
   Bytes  : in out Model_Runner.Byte_Sources.Source'Class;
   Scale  : Real := 1.0;
   Status : out E.Error_Info)
is
   use type Model_Runner.GGUF.Tensor_Type;
   use type Interfaces.Unsigned_32;

   Arena : B.Byte_Array_Access := null;
   Base  : B.Byte_Count := 0;

   --  How much the adapter's own metadata says to scale by. A rank-r
   --  adapter is trained with a factor of alpha over r, and the file
   --  carries alpha; leaving it out would scale every fine-tune by its
   --  rank.
   Alpha : N.Wide_Real := 0.0;

   --  The same, as bits, for the digest below.
   Alpha_Bits : Interfaces.Unsigned_32 := 0;

   procedure Release is
   begin
      B.Free (Arena);
   end Release;

   --  One of the pair, resolved against the adapter's own arena.
   procedure Adapter_View
     (Name   : String;
      Result : out T.View;
      Found  : out Boolean;
      Local  : out E.Error_Info)
   is
      Index : constant Natural := Containers.Find_Tensor (Source, Name);
   begin
      Result := T.Empty_View;
      Local := E.Success;
      Found := Index /= 0;

      if not Found then
         return;
      end if;

      declare
         Rank : constant Positive := Containers.Tensor_Rank (Source, Index);
         Columns : constant Element_Count :=
           Element_Count (Containers.Tensor_Dimension (Source, Index, 1));
         Rows : Element_Count := 1;
      begin
         for Axis in 2 .. Rank loop
            Rows := Rows
              * Element_Count
                  (Containers.Tensor_Dimension (Source, Index, Axis));
         end loop;

         T.Make
           (Format  => Containers.Tensor_Format (Source, Index),
            Rows    => Rows,
            Columns => Columns,
            Data    => Arena,
            Offset  =>
              B.Byte_Count (Containers.Tensor_Offset (Source, Index))
              - Base,
            Result  => Result,
            Status  => Local);

         if E.Is_Error (Local) then
            E.Add_Text (Local, "tensor", Name, E.Param_Identifier);
         end if;
      end;
   end Adapter_View;

   --  Add the pair's product into one repacked matrix.
   --
   --  The difference is B times A, which is what a low-rank adapter is:
   --  a pair whose product has the shape of the weight and whose own
   --  storage is the rank times the two widths rather than their
   --  product.
   procedure Merge_One
     (Target : T.View;
      Down   : T.View;
      Up     : T.View;
      Local  : out E.Error_Info)
   is
      Rank : constant Element_Count := Down.Rows;

      Left  : Real_Array (0 .. Down.Columns - 1);
      Right : Real_Array (0 .. Up.Columns - 1);
   begin
      Local := E.Success;

      if Target.Format /= Model_Runner.GGUF.Type_F32
        or else Down.Columns /= Target.Columns
        or else Up.Rows /= Target.Rows
        or else Up.Columns /= Rank
      then
         Local := E.Make (E.Arch_Invalid_Tensor_Shape);
         E.Add_Integer (Local, "rows", Long_Long_Integer (Target.Rows));
         E.Add_Integer
           (Local, "columns", Long_Long_Integer (Target.Columns));
         return;
      end if;

      --  One row of the weight at a time, so that the adapter's rows are
      --  decoded once each and the weight is touched once.
      for Row in 0 .. Target.Rows - 1 loop
         T.Dequantize_Row (Up, Row, Right, Local);
         if E.Is_Error (Local) then
            return;
         end if;

         for Which in 0 .. Rank - 1 loop
            if Right (Which) /= 0.0 then
               T.Dequantize_Row (Down, Which, Left, Local);
               if E.Is_Error (Local) then
                  return;
               end if;

               declare
                  Factor : constant N.Wide_Real :=
                    N.Wide_Real (Right (Which)) * N.Wide_Real (Scale)
                    * Alpha;

                  At_Row : constant B.Byte_Count :=
                    Target.Offset
                    + B.Byte_Count (Row) * T.Row_Bytes (Target);

                  --  The one place a view is written through rather than
                  --  read. It reaches here only for a model prepared as
                  --  binary32, whose weights are the copy the repacking
                  --  made and never a mapped file, which nothing may
                  --  write to.
                  Held : B.Byte_Array (1 .. Target.Span)
                    with Import, Address => Target.Base;
               begin
                  for Column in 0 .. Target.Columns - 1 loop
                     declare
                        At_Byte : constant B.Byte_Count :=
                          At_Row + B.Byte_Count (Column) * 4;

                        Was : constant Real :=
                          N.From_Bits
                            (Interfaces.Unsigned_32
                               (Held (Held'First + At_Byte))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_32
                                     (Held (Held'First + At_Byte + 1)),
                                   8)
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_32
                                     (Held (Held'First + At_Byte + 2)),
                                   16)
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_32
                                     (Held (Held'First + At_Byte + 3)),
                                   24));

                        Now : constant Real :=
                          Real (N.Wide_Real (Was)
                                + Factor * N.Wide_Real (Left (Column)));

                        Bits : constant Interfaces.Unsigned_32 :=
                          N.Bits (Now);
                     begin
                        Held (Held'First + At_Byte) :=
                          B.Byte (Bits and 16#FF#);
                        Held (Held'First + At_Byte + 1) :=
                          B.Byte
                            (Interfaces.Shift_Right (Bits, 8) and 16#FF#);
                        Held (Held'First + At_Byte + 2) :=
                          B.Byte
                            (Interfaces.Shift_Right (Bits, 16) and 16#FF#);
                        Held (Held'First + At_Byte + 3) :=
                          B.Byte
                            (Interfaces.Shift_Right (Bits, 24) and 16#FF#);
                     end;
                  end loop;
               end;
            end if;
         end loop;
      end loop;
   end Merge_One;

   --  Every weight an adapter may touch, by the name it has in a file.
   type Target_Name is access constant String;

   Names : constant array (1 .. 7) of Target_Name :=
     [new String'("attn_q"), new String'("attn_k"), new String'("attn_v"),
      new String'("attn_output"), new String'("ffn_gate"),
      new String'("ffn_up"), new String'("ffn_down")];

   Merged : Natural := 0;
begin
   Status := E.Success;

   if not Item.Ready then
      Status := E.Make (E.Lifecycle_Model_Not_Ready);
      return;
   end if;

   if Item.Sessions > 0 then
      Status := E.Make (E.Lifecycle_Session_Active);
      return;
   end if;

   if Item.Packing /= To_F32 or else Item.Repacked = null then
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", "adapter_without_f32_weights",
                  E.Param_Identifier);
      return;
   end if;

   --  What the adapter says about itself, before its bytes are read.
   declare
      Value : N.Wide_Real;
      Local : E.Error_Info;
   begin
      Containers.Get_Float
        (Source, "adapter.lora.alpha", 0.0, 1.0E6, Value, Local);
      Alpha := (if E.Is_Ok (Local) then Value else 1.0);
      Alpha_Bits := N.Bits (Real (Alpha));
   end;

   --  The adapter's tensors, in an arena of their own.
   declare
      Length : constant B.Byte_Count :=
        B.Byte_Count (Containers.Tensor_Data_Bytes (Source));
   begin
      if Length = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", "lora", E.Param_Identifier);
         return;
      end if;

      B.Allocate (Length, Arena);
      if Arena = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Base := B.Byte_Count (Containers.Data_Offset (Source));
      Bytes.Read (Base, Arena.all, Status);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
   end;

   for Index in Item.Layers.all'Range loop
      for Which of Names loop
         declare
            Stem : constant String :=
              Layer_Key (Index, Which.all & ".weight");

            Down, Up : T.View;
            Has_Down, Has_Up : Boolean;
            Local : E.Error_Info;
         begin
            Adapter_View (Stem & ".lora_a", Down, Has_Down, Local);
            if E.Is_Error (Local) then
               Status := Local;
               Release;
               return;
            end if;

            Adapter_View (Stem & ".lora_b", Up, Has_Up, Local);
            if E.Is_Error (Local) then
               Status := Local;
               Release;
               return;
            end if;

            --  Half a pair is not an adapter for anything. Refused by
            --  name rather than ignored, because the half that is there
            --  says a fine-tune expected both.
            if Has_Down /= Has_Up then
               Status := E.Make (E.Arch_Missing_Tensor);
               E.Add_Text
                 (Status, "tensor",
                  Stem & (if Has_Down then ".lora_b" else ".lora_a"),
                  E.Param_Identifier);
               Release;
               return;
            end if;

            if Has_Down then
               declare
                  Target : T.View := T.Empty_View;
               begin
                  if Which.all = "attn_q" then
                     Target := Item.Layers.all (Index).Query;
                  elsif Which.all = "attn_k" then
                     Target := Item.Layers.all (Index).Key;
                  elsif Which.all = "attn_v" then
                     Target := Item.Layers.all (Index).Value;
                  elsif Which.all = "attn_output" then
                     Target := Item.Layers.all (Index).Attention_Out;
                  elsif Which.all = "ffn_gate" then
                     Target := Item.Layers.all (Index).Gate;
                  elsif Which.all = "ffn_up" then
                     Target := Item.Layers.all (Index).Up;
                  else
                     Target := Item.Layers.all (Index).Down;
                  end if;

                  if not T.Is_Present (Target) then
                     Status := E.Make (E.Arch_Missing_Tensor);
                     E.Add_Text
                       (Status, "tensor", Stem, E.Param_Identifier);
                     Release;
                     return;
                  end if;

                  Merge_One (Target, Down, Up, Local);
                  if E.Is_Error (Local) then
                     Status := Local;
                     E.Add_Text
                       (Status, "tensor", Stem, E.Param_Identifier);
                     Release;
                     return;
                  end if;

                  Merged := Merged + 1;
               end;
            end if;
         end;
      end loop;
   end loop;

   Release;

   --  An adapter that touched nothing is one whose tensors this profile
   --  does not know by name, which is worth saying rather than reporting
   --  a merge that changed no weight.
   if Merged = 0 then
      Status := E.Make (E.Arch_Missing_Tensor);
      E.Add_Text (Status, "tensor", "lora_a", E.Param_Identifier);
      return;
   end if;

   --  And the model is no longer the model its file describes. What was
   --  merged goes into what identifies it, so that a context saved
   --  before this cannot be read after it: the weights that produced
   --  that context are gone.
   declare
      procedure Mix (Value : Interfaces.Unsigned_64) is
      begin
         Item.Adapted :=
           (Item.Adapted xor Value) * 16#0000_0100_0000_01B3#;
      end Mix;
   begin
      if Item.Adapted = 0 then
         Item.Adapted := 16#CBF2_9CE4_8422_2325#;
      end if;

      Mix (Interfaces.Unsigned_64 (Merged));
      Mix (Interfaces.Unsigned_64 (N.Bits (Scale)));
      Mix (Interfaces.Unsigned_64 (Containers.Tensor_Data_Bytes (Source)));
      Mix (Interfaces.Unsigned_64 (Alpha_Bits));
   end;
end Merge_Adapter;
