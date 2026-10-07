separate (Model_Runner.Llama)
procedure Feed_Next
  (Item   : in out Session;
   Source : Model'Class;
   Tokens : Model_Runner.Tokenizer.Token_Array;
   States : N.Real_Array;
   First  : Natural;
   Status : out E.Error_Info)
is
   Settings : Configuration renames Source.Settings;
   Width    : constant Element_Count := Element_Count (Settings.Embedding);
   Count    : constant Element_Count := Element_Count (Tokens'Length);
   KV_Heads : constant Element_Count := Element_Count (Settings.KV_Heads);
   Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
   Value_Size : constant Element_Count :=
     Element_Count (Settings.Value_Size);
   KV_Width : constant Element_Count := KV_Heads * Head_Size;
   V_Width  : constant Element_Count := KV_Heads * Value_Size;
   Layer_Index : constant Natural := Settings.Layers;
begin
   Status := E.Success;

   if Count = 0 then
      return;
   end if;

   if not Drafts_Next (Item) then
      Status := E.Make (E.Lifecycle_Invalid_State);
      return;
   end if;

   if States'Length /= Count * Width
     or else First + Natural (Count) > Item.Context
   then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      E.Add_Integer (Status, "input", Long_Long_Integer (First));
      E.Add_Integer (Status, "expected", Long_Long_Integer (Item.Context));
      return;
   end if;

   --  What a position leaves behind is its keys and its values in the
   --  block's cache, and nothing else: the query, the blend, the
   --  projection back and the feed-forward make the block's answer at that
   --  position, which a position fed for its cache never reads. So this is
   --  Draft_Next's front only -- the input, its projection, the keys and
   --  values -- over every position at once.
   declare
      Current : Layer renames Source.Next.all (0);
      Own     : constant Boolean := Item.Next_Keys /= null;
      Keys    : constant Model_Runner.Tensors.Real_Array_Access :=
        (if Own then Item.Next_Keys else Item.Keys);
      Values  : constant Model_Runner.Tensors.Real_Array_Access :=
        (if Own then Item.Next_Values else Item.Values);
      Base    : constant Element_Count :=
        (if Own then 0 else Keys_At (Item, Layer_Index));
      V_Base  : constant Element_Count :=
        (if Own then 0 else Values_At (Item, Layer_Index));

      --  A batch of rows each, Count of them end to end.
      Inputs, Acts, Norms, Keyed, Valued : T.Real_Array_Access := null;

      procedure Release is
      begin
         T.Free (Inputs);
         T.Free (Acts);
         T.Free (Norms);
         T.Free (Keyed);
         T.Free (Valued);
      end Release;

      function Row
        (Of_Buffer : T.Real_Array_Access; I, Wide : Element_Count)
         return Element_Count
      is (Of_Buffer.all'First + I * Wide);
   begin
      T.Allocate (Count * 2 * Width, Inputs);
      T.Allocate (Count * Width, Acts);
      T.Allocate (Count * Width, Norms);
      T.Allocate (Count * KV_Width, Keyed);
      T.Allocate (Count * V_Width, Valued);

      if Inputs = null or else Acts = null or else Norms = null
        or else Keyed = null or else Valued = null
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      --  Each position's input: the next token's embedding and the state,
      --  each normalized by its own gain, side by side.
      for I in 0 .. Count - 1 loop
         T.Dequantize_Row
           (Source.Embeddings,
            Element_Count (Tokens (Tokens'First + Integer (I))),
            Item.Activation.all, Status);
         if E.Is_Error (Status) then
            Release;
            return;
         end if;

         if Embedding_Scale (Source) /= 1.0 then
            for Value of Item.Activation.all loop
               Value := Value * Embedding_Scale (Source);
            end loop;
         end if;

         declare
            At_In : constant Element_Count := Row (Inputs, I, 2 * Width);
         begin
            K.RMS_Norm
              (Item.Activation.all, Current.Next_ENorm.all, Settings.Epsilon,
               Inputs.all (At_In .. At_In + Width - 1));
            K.RMS_Norm
              (States (States'First + I * Width
                       .. States'First + I * Width + Width - 1),
               Current.Next_HNorm.all, Settings.Epsilon,
               Inputs.all (At_In + Width .. At_In + 2 * Width - 1));
         end;
      end loop;

      Product_Batch (Item, Current.Next_Proj, Inputs, Count, Acts, Status);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;

      for I in 0 .. Count - 1 loop
         Normalize
           (Source,
            Acts.all (Row (Acts, I, Width) .. Row (Acts, I, Width) + Width - 1),
            Current.Attention_Norm.all, Current.Attention_Norm_Bias,
            Norms.all (Row (Norms, I, Width)
                       .. Row (Norms, I, Width) + Width - 1));
      end loop;

      Product_Batch (Item, Current.Key, Norms, Count, Keyed, Status);
      if E.Is_Ok (Status) then
         Product_Batch (Item, Current.Value, Norms, Count, Valued, Status);
      end if;
      if E.Is_Error (Status) then
         Release;
         return;
      end if;

      --  A position's keys normalized by head and turned to it, and both
      --  written to the block's cache there, as Draft_Next writes them.
      for I in 0 .. Count - 1 loop
         declare
            Position : constant Natural := First + Natural (I);
            Cell     : constant Element_Count := Element_Count (Position);
            Slot     : constant Element_Count := Base + Cell * KV_Width;
            V_Slot   : constant Element_Count := V_Base + Cell * V_Width;
            K_At     : constant Element_Count := Row (Keyed, I, KV_Width);
            V_At     : constant Element_Count := Row (Valued, I, V_Width);
         begin
            Item.Key_Row.all := Keyed.all (K_At .. K_At + KV_Width - 1);

            Normalize_Heads
              (Item.Key_Row.all, KV_Heads, Head_Size, Current.Key_Norm.all,
               Settings.Epsilon, Item.Head_Row.all);

            K.Apply_Rotary
              (Item.Key_Row.all, KV_Heads, Head_Size,
               Element_Count (Settings.Rotary), Position,
               Turn_Base (Settings, Layer_Index),
               Turn_Scaling (Settings, Layer_Index),
               Turns (Source), Settings.Pairing,
               Sections => Settings.Sections,
               Place => K.Everywhere (Rope_Next (Item, Position)));

            for Offset in 0 .. KV_Width - 1 loop
               Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
            end loop;
            for Offset in 0 .. V_Width - 1 loop
               Values.all (V_Slot + Offset) := Valued.all (V_At + Offset);
            end loop;
         end;
      end loop;

      Release;
   end;
end Feed_Next;
