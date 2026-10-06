separate (Model_Runner.Llama)
procedure Draft_Next
  (Item       : in out Session;
   Source     : Model'Class;
   Token      : Model_Runner.Tokenizer.Token_Id;
   State      : N.Real_Array;
   Position   : Natural;
   Logits     : out N.Real_Array;
   Next_State : out N.Real_Array;
   Status     : out E.Error_Info)
is
   Settings : Configuration renames Source.Settings;
   Width    : constant Element_Count := Element_Count (Settings.Embedding);
   Heads    : constant Element_Count := Element_Count (Settings.Heads);
   KV_Heads : constant Element_Count := Element_Count (Settings.KV_Heads);
   Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
   Value_Size : constant Element_Count :=
     Element_Count (Settings.Value_Size);
   KV_Width : constant Element_Count := KV_Heads * Head_Size;
   V_Width  : constant Element_Count := KV_Heads * Value_Size;
   Layer_Index : constant Natural := Settings.Layers;
   Scale : constant Real := Score_Scale (Settings);
begin
   Status := E.Success;
   Logits := [others => 0.0];
   Next_State := [others => 0.0];

   if not Drafts_Next (Item) then
      Status := E.Make (E.Lifecycle_Invalid_State);
      return;
   end if;

   --  The position may run past what the stack has committed: the block
   --  chains from its own answers, one position further each time, and
   --  its cache is its own. What bounds it is the room in that cache.
   if State'Length /= Width or else Next_State'Length /= Width
     or else (Logits'Length /= Element_Count (Settings.Vocabulary)
              and then Logits'Length /= 0)
     or else Position >= Item.Context
     or else Natural (Token) >= Settings.Vocabulary
   then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      E.Add_Integer (Status, "input", Long_Long_Integer (Position));
      E.Add_Integer (Status, "expected", Long_Long_Integer (Item.Context));
      return;
   end if;

   declare
      Current : Layer renames Source.Next.all (0);
      Base    : constant Element_Count := Keys_At (Item, Layer_Index);
      V_Base  : constant Element_Count := Values_At (Item, Layer_Index);
      Cell    : constant Element_Count := Element_Count (Position);
      Slot    : constant Element_Count := Base + Cell * KV_Width;
      V_Slot  : constant Element_Count := V_Base + Cell * V_Width;
      Usable  : Boolean := True;
   begin
      --  The block's input: the next token's embedding and the state,
      --  each normalized by its own gain, side by side, projected.
      T.Dequantize_Row
        (Source.Embeddings, Element_Count (Token), Item.Activation.all,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Embedding_Scale (Source) /= 1.0 then
         for Value of Item.Activation.all loop
            Value := Value * Embedding_Scale (Source);
         end loop;
      end if;

      K.RMS_Norm
        (Item.Activation.all, Current.Next_ENorm.all, Settings.Epsilon,
         Item.Next_Input.all (0 .. Width - 1));
      K.RMS_Norm
        (State, Current.Next_HNorm.all, Settings.Epsilon,
         Item.Next_Input.all (Width .. 2 * Width - 1));

      Product (Item, Current.Next_Proj, Item.Next_Input, Item.Activation,
               Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The attention half: normalized, projected, the gates taken
      --  out, the heads normalized and turned, the keys and values
      --  written to the block's own cache at this position, and the
      --  blend over every position up to it, gated, projected back and
      --  joined.
      Normalize
        (Source, Item.Activation.all, Current.Attention_Norm.all,
         Current.Attention_Norm_Bias, Item.Normalized.all);

      Product_Group
        (Item, [Current.Query, Current.Key, Current.Value],
         Item.Normalized,
         [Item.Query_Full, Item.Key_Row, Item.Value_Row], Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Split_Head_Gates (Item, Settings);

      Normalize_Heads
        (Item.Query.all, Heads, Head_Size, Current.Query_Norm.all,
         Settings.Epsilon, Item.Head_Row.all);
      Normalize_Heads
        (Item.Key_Row.all, KV_Heads, Head_Size, Current.Key_Norm.all,
         Settings.Epsilon, Item.Head_Row.all);

      K.Apply_Rotary_Pair
        (Item.Query.all, Heads, Item.Key_Row.all, KV_Heads, Head_Size,
         Element_Count (Settings.Rotary), Position,
         Turn_Base (Settings, Layer_Index), Turn_Scaling (Settings, Layer_Index),
         Turns (Source), Settings.Pairing,
         Sections => Settings.Sections,
         Place => K.Everywhere (Rope_Next (Item, Position)));

      for Offset in 0 .. KV_Width - 1 loop
         Item.Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
      end loop;
      for Offset in 0 .. V_Width - 1 loop
         Item.Values.all (V_Slot + Offset) := Item.Value_Row.all (Offset);
      end loop;

      Blend_Exact
        (Item.Query.all, Item.Keys.all, Item.Values.all,
         Base, V_Base, KV_Width, V_Width, Heads, Head_Size, Value_Size,
         Element_Count (Settings.Group_Size),
         First => 0, Last => Cell, Scale => Scale,
         Cap => Settings.Attention_Cap, Max_Bias => Settings.Max_Bias,
         Query_At => Cell, Sinks => null,
         From_Head => 0, To_Head => Heads - 1,
         Score_Room => Item.Score_Room, Scores => Item.Scores.all,
         Target => Item.Attention.all, Ok => Usable);

      if not Usable then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         E.Add_Integer (Status, "layer", Long_Long_Integer (Layer_Index));
         return;
      end if;

      Gate_Heads (Item);

      Product
        (Item, Current.Attention_Out, Item.Attention, Item.Normalized,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      K.Add (Item.Activation.all, Item.Normalized.all);

      --  The feed-forward half: the mixture with its shared expert
      --  where the block is one, the gated block where it is not.
      Normalize
        (Source, Item.Activation.all, Current.Feed_Norm.all,
         Current.Feed_Norm_Bias, Item.Normalized.all);

      if Settings.Experts > 0 then
         Mixture (Item, Current, Item.Normalized, Item.Mixture, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         K.Add (Item.Activation.all, Item.Mixture.all);
      else
         Product_Group
           (Item, [Current.Gate, Current.Up], Item.Normalized,
            [Item.Gate, Item.Up], Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Gate_Activation (Source, Item.Gate.all);
         K.Multiply (Item.Gate.all, Item.Up.all);

         Product (Item, Current.Down, Item.Gate, Item.Normalized, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         K.Add (Item.Activation.all, Item.Normalized.all);
      end if;

      --  Its answer: normalized ahead of the shared head, kept for
      --  the next draft, and read by the head.
      K.RMS_Norm
        (Item.Activation.all, Current.Next_Head_Norm.all,
         Settings.Epsilon, Item.Normalized.all);
      Next_State := Item.Normalized.all;

      --  The head only where a distribution was asked for: a position
      --  run through again to put the cache right wants the cache and
      --  the state, and the head is most of what the block costs.
      if Logits'Length = 0 then
         return;
      end if;

      --  Over the first rows of the head only: a proposal is a token a
      --  draft thinks likely, and a vocabulary's first tokens are its
      --  commonest -- a byte-pair vocabulary is numbered in the order
      --  its merges were learned. The check is against the model's own
      --  distribution over every token, so what the draft cannot
      --  propose costs a refusal and never a wrong answer. On Qwen3.5-4B
      --  the head is 675 MB of the block's 800; its first 65,536 rows
      --  read 23.1 -> 25.3 tokens a second greedy against the whole, with
      --  86 of 129 proposals kept against 88 of 123, and 17.5 -> 20.1
      --  sampled. Fewer rows lose proposals faster than they save bytes:
      --  32,768 read 23.1 and 8,192 20.5.
      declare
         Rows : constant Element_Count :=
           Element_Count'Min (Source.Output.Rows, Draft_Vocabulary);
         Head : T.View := Source.Output;
      begin
         Head.Rows := Rows;
         Head.Length :=
           Model_Runner.Bytes.Byte_Count (Rows) * T.Row_Bytes (Source.Output);

         --  Or those rows at four bits, where the run asked for them:
         --  the block only proposes, so a coarser head changes how many
         --  proposals are kept and never what is written.
         if Source.Draft_Head.Rows = Rows then
            Head := Source.Draft_Head;
         end if;

         Product (Item, Head, Item.Normalized, Item.Logit_Row, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         --  What the draft cannot say, it gives no chance at all.
         Logits := [others => -1.0e30];
         Logits (Logits'First .. Logits'First + Rows - 1) :=
           Item.Logit_Row.all
             (Item.Logit_Row.all'First
              .. Item.Logit_Row.all'First + Rows - 1);
         Finish_Logits (Source, Logits);
      end;
   end;
end Draft_Next;
