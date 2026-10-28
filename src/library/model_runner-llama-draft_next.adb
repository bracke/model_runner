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

   --  The block's attention a share of heads a worker: it reads every
   --  position the block holds, which sixteen thousand in was 39 ms a
   --  proposal on one core.
   type Next_Share is limited new Workers_CPU.Task_Item with record
      Keys   : Model_Runner.Tensors.Real_Array_Access := null;
      Values : Model_Runner.Tensors.Real_Array_Access := null;
      Base, V_Base, First, Cell : Element_Count := 0;
      --  From one position's values to the next's; see Value_Stride.
      V_Stride : Element_Count := 0;
      Ok     : Boolean := True;
   end record;

   overriding procedure Run
     (Share : in out Next_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Next_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      Fine : Boolean;
   begin
      Blend_Exact
        (Item.Query.all, Share.Keys.all, Share.Values.all,
         Share.Base, Share.V_Base, KV_Width, Share.V_Stride, Heads, Head_Size,
         Value_Size, Element_Count (Settings.Group_Size),
         First => Share.First, Last => Share.Cell, Scale => Scale,
         Cap => Settings.Attention_Cap, Max_Bias => Settings.Max_Bias,
         Query_At => Share.Cell, Sinks => null,
         From_Head => From, To_Head => To,
         Score_Room => Item.Score_Room, Scores => Item.Scores.all,
         Target => Item.Attention.all, Ok => Fine);
      if not Fine then
         Share.Ok := False;
      end if;
   end Run;
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
      --  How far back a proposal looks. It is a guess the stack checks,
      --  so what it attends to is the draft's choice and not the answer's,
      --  and it attends on the processor: over every position, Qwen3.6's
      --  three proposals took 118 ms of a round sixteen thousand positions
      --  in, where at the start of a context they took six.
      Next_Reach : constant Element_Count := 2_048;

      Current : Layer renames Source.Next.all (0);
      --  In the stack's cache where it is exact, in the block's own where
      --  it is not.
      Own     : constant Boolean := Item.Next_Keys /= null;
      Keys    : constant Model_Runner.Tensors.Real_Array_Access :=
        (if Own then Item.Next_Keys else Item.Keys);
      Values  : constant Model_Runner.Tensors.Real_Array_Access :=
        (if Own then Item.Next_Values else Item.Values);
      Base    : constant Element_Count := (if Own then 0 else Keys_At (Item, Layer_Index));
      V_Base  : constant Element_Count := (if Own then 0 else Values_At (Item, Layer_Index));
      Cell    : constant Element_Count := Element_Count (Position);
      Slot    : constant Element_Count := Base + Cell * KV_Width;
      --  The block's own values are a value apart; the stack's, where it
      --  keeps them, as the session keeps them.
      V_Stride : constant Element_Count :=
        (if Own then V_Width else Value_Stride (Item));
      V_Slot  : constant Element_Count := V_Base + Cell * V_Stride;
      Usable  : Boolean := True;

      --  Whether the block's queries carry a gate a head, as a hybrid's
      --  full attention layers do: twice the queries' rows.
      Gated   : constant Boolean :=
        Natural (Current.Query.Rows) = 2 * Natural (Heads * Head_Size);

      --  The first position the block attends.
      Earliest_Cell : constant Element_Count :=
        (if Cell >= Next_Reach then Cell - Next_Reach + 1 else 0);

      --  Whether the block went whole on the device, as Whole_Layer runs
      --  a layer of the stack: a paged session the device holds, the
      --  block's own rows, and a block whose feed-forward the device
      --  takes whole -- the dense one, or a mixture of stacks routed as
      --  the stack's are. False where any of it is refused, and the
      --  processor's way below runs instead.
      function On_Device return Boolean;

      function On_Device return Boolean is
         use type Model_Runner.Backend.Backend_Kind;

         Shape_Fits : constant Boolean :=
           Own
           and then Item.Paged
           and then Item.Seen = null
           and then not Item.On_Host
           and then Item.Owner /= null
           and then Item.Owner.Able.Kind = Model_Runner.Backend.Backend_Device
           and then Item.Held in Exact | Halved
           and then not Item.Values_In_Keys
           and then not Is_MLA (Settings.Kind)
           and then Element_Count (Settings.Rotary) <= Head_Size
           and then not Current.Host_Feed
           and then Current.Attention_Norm /= null
           and then Current.Feed_Norm /= null
           and then (if Settings.Experts > 0
                     then Source.Stacked
                          and then Current.Experts /= null
                          and then T.Is_Present (Current.Router)
                          and then T.Is_Present (Current.Gate_Stack)
                          and then T.Is_Present (Current.Up_Stack)
                          and then T.Is_Present (Current.Down_Stack)
                          and then Current.Expert_Gate_Bias = null
                          and then Current.Expert_Up_Bias = null
                          and then Current.Up_Bias = null
                          and then Current.Down_Bias = null
                          and then Current.Select_Bias = null
                          and then not Settings.Sigmoid_Gate
                          and then not Grouped (Settings)
                          and then Settings.Experts_Used
                                   <= Model_Runner.Backend.Device.Max_Members
                     else T.Is_Present (Current.Up));
         Resident : Boolean;
         Pairs    : constant Element_Count := Element_Count (Settings.Rotary) / 2;
         Angles   : N.Wide_Real_Array (0 .. Pairs * 2 - 1);
         Cosines  : N.Wide_Real_Array (0 .. Pairs - 1);
         Sines    : N.Wide_Real_Array (0 .. Pairs - 1);
         Before   : constant N.Real_Array := Item.Activation.all;
         Fused    : Boolean;
         Layer_Page_First : Element_Count;
         P        : constant Element_Count := Element_Count (Page_Positions);
      begin
         if not Shape_Fits then
            return False;
         end if;

         Take_Pages (Item'Unchecked_Access, Cell, Resident);
         if not Resident then
            return False;
         end if;
         Layer_Page_First := Item.Page_First.all (Layer_Index);

         --  The rows the device lacks, from the first the block reads.
         for Row in Element_Count'Max
                      (Element_Count (Item.Next_Device_Upto), Earliest_Cell)
                    .. Cell - 1
         loop
            declare
               Page_Base : constant Element_Count :=
                 Item.Pages.all (Natural (Layer_Page_First + Row / P));
               Put_Keys, Put_Values : Boolean;
            begin
               Model_Runner.Backend.Device.Put_Cache
                 (Page_Base + (Row mod P) * KV_Width,
                  Keys.all (Row * KV_Width .. Row * KV_Width + KV_Width - 1),
                  Put_Keys);
               Model_Runner.Backend.Device.Put_Cache
                 (Page_Base + P * KV_Width + (Row mod P) * V_Width,
                  Values.all (Row * V_Width .. Row * V_Width + V_Width - 1),
                  Put_Values);
               if not (Put_Keys and then Put_Values) then
                  Item.Next_Device_Upto := Natural (Row);
                  return False;
               end if;
            end;
         end loop;
         Item.Next_Device_Upto := Natural'Max (Item.Next_Device_Upto, Position);

         if Settings.Rotary > 0 then
            K.Rotary_Table
              (Element_Count (Settings.Rotary), Position,
               Turn_Base (Settings, Layer_Index),
               Turn_Scaling (Settings, Layer_Index),
               Turns (Source, Item),
               Cosines => Cosines, Sines => Sines,
               Sections => Settings.Sections,
               Place => K.Everywhere (Rope_Next (Item, Position)));
            for Pair in 0 .. Pairs - 1 loop
               Angles (Pair * 2) := Cosines (Pair);
               Angles (Pair * 2 + 1) := Sines (Pair);
            end loop;
         end if;

         Model_Runner.Backend.Device.Whole_Layer
           (Item.Activation.all,
            Device_Norm (Current.Attention_Norm, Current.Attention_Norm_Pair),
            Device_Norm (Current.Feed_Norm, Current.Feed_Norm_Pair),
            Settings.Epsilon,
            Current.Query, Current.Key, Current.Value,
            Angles, Natural (Head_Size), Settings.Rotary,
            K."=" (Settings.Pairing, K.Split),
            0, Page_Value_Base (Item),
            Natural (Heads), Natural (Value_Size), Settings.Group_Size,
            Natural (Earliest_Cell), Natural (Cell),
            0, Page_Value_Base (Item),
            Natural (KV_Width), Natural (V_Width),
            Scale, Settings.Attention_Cap,
            Current.Attention_Out,
            Current.Gate, Current.Up, Current.Down,
            Gate_Unit (Source),
            Item.Key_Row, Item.Value_Row, Item.Activation, Fused,
            Mirror => True,
            Max_Bias => Settings.Max_Bias,
            Cancel => Item.Stopping,
            Pages_At => Natural (Item.Page_Table_At.all (Layer_Index)),
            Page_Shift => Page_Shift_Bits,
            First_Position => Position,
            Query_Norm => Current.Query_Norm,
            Key_Norm   => Current.Key_Norm,
            Router     =>
              (if Settings.Experts > 0 then Current.Router else T.Empty_View),
            Router_Bias => Current.Router_Bias,
            Gate_Stack  => Current.Gate_Stack,
            Up_Stack    => Current.Up_Stack,
            Down_Stack  => Current.Down_Stack,
            Feed        => Settings.Expert_Feed,
            Used        => Settings.Experts_Used,
            Experts     => Settings.Experts,
            Alpha => Settings.Gate_Alpha,
            Limit => Settings.Gate_Limit,
            Query_Bias  => Current.Query_Bias,
            Key_Bias    => Current.Key_Bias,
            Value_Bias  => Current.Value_Bias,
            KV_Bias     => Current.KV_Bias,
            Out_Bias    => Current.Out_Bias,
            Post_Attention_Norm =>
              Device_Norm (Current.Post_Attention_Norm,
                           Current.Post_Attention_Norm_Pair),
            Post_Feed_Norm      =>
              Device_Norm (Current.Post_Feed_Norm,
                           Current.Post_Feed_Norm_Pair),
            Shifted => Norms_Shifted (Current),
            After   => Normalizes_After (Settings.Kind),
            Head_Gates    => Gated,
            Shared_Gate   => Current.Shared_Gate,
            Shared_Up     => Current.Shared_Up,
            Shared_Down   => Current.Shared_Down,
            Shared_Router => Current.Shared_Router);

         if not Fused then
            Item.Activation.all := Before;
            return False;
         end if;

         --  The row it placed, for the host's own copy of the block's
         --  cache.
         Keys.all (Slot .. Slot + KV_Width - 1) :=
           Item.Key_Row.all (0 .. KV_Width - 1);
         Values.all (V_Slot .. V_Slot + V_Width - 1) :=
           Item.Value_Row.all (0 .. V_Width - 1);
         Item.Next_Device_Upto := Natural'Max (Item.Next_Device_Upto, Position + 1);
         return True;
      end On_Device;
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

      --  The whole block as one submission where the device holds the
      --  session's pages and the block's shape: its keys and values put
      --  into its own pages there, the rows the host wrote since put
      --  there first, and the attention, the mixture and the joins all
      --  the device's. Each piece a submission of its own, waited for,
      --  and the attention on the processor, a proposal of Qwen3.6
      --  took 5.2 ms of wall where its device work is 1.9.
      if On_Device then
         goto Answered;
      end if;

      --  A draft on the processor writes its row on the host alone.
      Item.Next_Device_Upto := Natural'Min (Item.Next_Device_Upto, Position);

      --  The attention half: normalized, projected, the gates taken
      --  out, the heads normalized and turned, the keys and values
      --  written to the block's own cache at this position, and the
      --  blend over every position up to it, gated, projected back and
      --  joined.
      Normalize
        (Source, Item.Activation.all, Current.Attention_Norm.all,
         Current.Attention_Norm_Bias, Item.Normalized.all);

      --  A hybrid's queries carry a gate a head beside them, split out
      --  here and laid over the blend; a plain layer's are the queries.
      if Gated then
         Product_Group
           (Item, [Current.Query, Current.Key, Current.Value],
            Item.Normalized,
            [Item.Query_Full, Item.Key_Row, Item.Value_Row], Status);
      else
         Product_Group
           (Item, [Current.Query, Current.Key, Current.Value],
            Item.Normalized,
            [Item.Query, Item.Key_Row, Item.Value_Row], Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      if Gated then
         Split_Head_Gates (Item, Settings);
      end if;

      if Current.Query_Norm /= null then
         Normalize_Heads
           (Item.Query.all, Heads, Head_Size, Current.Query_Norm.all,
            Settings.Epsilon, Item.Head_Row.all);
      end if;
      if Current.Key_Norm /= null then
         Normalize_Heads
           (Item.Key_Row.all, KV_Heads, Head_Size, Current.Key_Norm.all,
            Settings.Epsilon, Item.Head_Row.all);
      end if;

      K.Apply_Rotary_Pair
        (Item.Query.all, Heads, Item.Key_Row.all, KV_Heads, Head_Size,
         Element_Count (Settings.Rotary), Position,
         Turn_Base (Settings, Layer_Index), Turn_Scaling (Settings, Layer_Index),
         Turns (Source, Item), Settings.Pairing,
         Sections => Settings.Sections,
         Place => K.Everywhere (Rope_Next (Item, Position)));

      for Offset in 0 .. KV_Width - 1 loop
         Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
      end loop;
      for Offset in 0 .. V_Width - 1 loop
         Values.all (V_Slot + Offset) := Item.Value_Row.all (Offset);
      end loop;

      declare
         Share  : aliased Next_Share;
         Shared : E.Error_Info;
      begin
         Share.Keys := Keys;
         Share.Values := Values;
         Share.Base := Base;
         Share.V_Base := V_Base;
         Share.V_Stride := V_Stride;
         Share.First := Earliest_Cell;
         Share.Cell := Cell;
         Workers_CPU.Dispatch_Shares
           (Item.Team, Heads, Share'Unchecked_Access, Shared,
            Cost => Heads * (Cell - Share.First + 1) * Head_Size);
         Usable := Share.Ok and then E.Is_Ok (Shared);
      end;

      if not Usable then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         E.Add_Integer (Status, "layer", Long_Long_Integer (Layer_Index));
         return;
      end if;

      if Gated then
         Gate_Heads (Item);
      end if;

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

      <<Answered>>

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
