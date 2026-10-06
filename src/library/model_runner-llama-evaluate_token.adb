separate (Model_Runner.Llama)
procedure Evaluate_Token
  (Item   : in out Session;
   Source : Model'Class;
   Token  : Token_Id;
   Row    : T.Real_Array_Access;
   Asked  : Element_Count;
   Cancel : Model_Runner.Cancellation.Token_Reference := null;
   Status : out E.Error_Info)
is
   Settings  : constant Configuration := Source.Settings;
   Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
   Value_Size : constant Element_Count :=
     Element_Count (Settings.Value_Size);
   Heads     : constant Element_Count := Element_Count (Settings.Heads);
   KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
   KV_Width  : constant Element_Count := KV_Heads * Head_Size;

   --  The values are their own width, so they are their own cache. The
   --  two were one number until a model stated them apart.
   V_Width   : constant Element_Count := KV_Heads * Value_Size;
   Reserved  : constant Element_Count := Element_Count (Item.Committed);
   Scale     : constant Real := Score_Scale (Settings);

   --  Whether the layer before this one left its answer on the device,
   --  and which layers left their keys and values in the device's own
   --  cache without also sending them back. A token is twenty-two
   --  layers and each of them waited on its own fence; carried and
   --  deferred, only the last one does.
   Chaining : constant Boolean := True;
   Carried  : Boolean := False;
   Deferred : array (Source.Layers.all'Range) of Boolean :=
     [others => False];

   --  Whether the session's ring is on the device and the runs'
   --  table says where this position goes in it, which every linear
   --  layer of this token then reads: sent and written once here,
   --  not once a layer, since the writing waits for the device.
   Linear_Ready : Boolean := False;

   --  Whether a layer is one the device takes whole. Asked of the next
   --  layer as well as of this one: a layer that falls back reads the
   --  host's copy of the activation, and the host's copy is what
   --  carrying does not write.
   --  A mixture layer goes whole where the device holds its expert
   --  stacks and the architecture puts nothing between the router and
   --  the experts that the device does not do: no expert biases. The
   --  clamped gate is a unit of the combining kernel now. The routing
   --  then happens where the router ran.
   --  A dense layer in a mixture's stack -- DeepSeek's first -- whose
   --  feed-forward is the plain one and goes whole as a dense model's.
   function Dense_Among_Experts (L : Layer) return Boolean
   is (L.Experts = null
       and then not T.Is_Present (L.Router)
       and then T.Is_Present (L.Up));

   function Mixture_Whole (L : Layer) return Boolean
   is (Source.Stacked
       and then L.Experts /= null
       and then T.Is_Present (L.Router)
       and then T.Is_Present (L.Gate_Stack)
       and then T.Is_Present (L.Up_Stack)
       and then T.Is_Present (L.Down_Stack)
       --  The expert biases go as steps of the sequence, the two
       --  arms' together: one arm biased and the other not is a
       --  shape no file has and the sequence does not take.
       and then (L.Expert_Gate_Bias = null) = (L.Expert_Up_Bias = null)
       and then Settings.Experts_Used
                <= Model_Runner.Backend.Device.Max_Members
         and then not Settings.Sigmoid_Gate);

   --  A hybrid's linear layer goes whole where the device has the
   --  rule and the convolution, the session a ring that is over, and
   --  the feed-forward behind it is a shape the sequence takes.
   function Linear_Front_Fits (L : Layer) return Boolean
   is (Linear_Ready
       and then Item.Delta_State /= null
       and then Item.Conv_State /= null
       and then Model_Runner.Backend.Device.Runs_Linear
       and then T.Is_Present (L.Mix)
       and then T.Is_Present (L.Z_Gate)
       and then T.Is_Present (L.Alpha)
       and then T.Is_Present (L.Beta)
       and then T.Is_Present (L.Linear_Out)
       and then L.Conv /= null
       and then L.Linear_Numbers /= null
       and then L.Attention_Norm /= null
       and then L.Feed_Norm /= null
       and then Norms_Agree (L)
       and then True);

   function Linear_Layer_Fits (L : Layer) return Boolean
   is (Linear_Front_Fits (L)
       and then not L.Host_Feed
       and then (if Settings.Experts > 0 then Mixture_Whole (L)
                 else T.Is_Present (L.Up)));

   --  A dense layer goes whole gated or not -- the one projection up
   --  with a unit alone on it is a shape the sequence takes -- and a
   --  mixture where the device holds its stacks.
   function Front_Fits (L : Layer; Index : Natural) return Boolean
   is (True

       --  A hybrid's linear layers keep a state on the host and are
       --  not attention; its attention layers go whole, the gate
       --  beside each head and the shared expert as steps of the
       --  sequence, where the value heads are as wide as the query
       --  heads -- the gate is elementwise over the blend -- and the
       --  projections carry no bias, which the picking apart of the
       --  queries and the gates does not take.
       and then not Linear (Settings, Index)
       and then (not Hybrid (Settings.Kind)
                 or else (Settings.Value_Size = Settings.Head_Size
                          and then L.Query_Bias = null))

       --  A layer's sinks go on the device where the cache holds a slot
       --  for them at this layer's place: the sink joins the softmax's
       --  denominator in the shader as the architecture wants. It read
       --  as answering to nothing for a day because every chained layer
       --  put its sinks in the one slot -- Put_Cache writes the mapping
       --  as the buffer is built, before the device runs any of it, so
       --  by the time a layer's attention read the slot it held the last
       --  layer's sink. Sinks_Ready gives a slot a layer now, and the
       --  layers past what the room holds are the ones this sends to the
       --  host.
       and then Sinks_Fit (L.Sinks, Index)

       --  The normalization on the way in, which every architecture
       --  has but the one that normalizes on the way out and has the
       --  two after the joins instead. The one before the
       --  feed-forward may be absent: the two halves then run side by
       --  side, both from the one on the way in.
       and then (L.Attention_Norm /= null)
                = not Normalizes_After (Settings.Kind)
       and then (not Normalizes_After (Settings.Kind)
                 or else (L.Post_Attention_Norm /= null
                          and then L.Post_Feed_Norm /= null))

       --  Centred all or none, as Norms_Agree says.
       and then Norms_Agree (L)

       --  The attention projections' biases go as steps of the
       --  sequence, all three or none: an architecture states them
       --  as one.
       and then (L.Query_Bias = null) = (L.Key_Bias = null)
       and then (L.Query_Bias = null) = (L.Value_Bias = null)

       --  A head normalization goes to the device, both or neither:
       --  the sequence normalizes the queries and the keys as a pair
       --  and an architecture states them as one.
       and then (L.Query_Norm = null) = (L.Key_Norm = null)

       --  A dense feed-forward's two biases are steps of the
       --  sequence; a mixture's are its experts', named apart.

       --  The code variant's three normalizations more -- over the
       --  whole of the queries and the keys, and the attention
       --  sublayer's residual joined again -- are not in the sequence.
       --  The device sequence has no step that scales a sublayer's
       --  output before it joins the residual, which Granite does; such
       --  a layer runs on the host under the device backend, the way a
       --  hybrid's linear layers do.
       and then not (Settings.Kind in Granite | Granite_MoE
                     and then Settings.Residual_Mul /= 0.0)

       --  GLM4 would fit the sequence, but its combination of a
       --  sandwich post-normalization with an interleaved partial
       --  rotation and a query-key-value bias is one no device layer
       --  has run: the kernels are there for each piece and untried
       --  together. Held to the host under the device backend until
       --  they are, as Granite is for a different reason.
       and then Settings.Kind not in Glm4 | Starcoder2 | Stablelm | Gptneox | Mpt
                          | Chatglm | Command_R
       and then Settings.Max_Bias = 0.0
       and then L.Second_Attention_Norm = null
       and then L.Query_Whole_Norm = null

       --  DeepSeek's latent attention goes whole where its queries are
       --  one projection (V2-Lite's); a query through a latent of its
       --  own is not a shape the device's layer builds yet.
       and then (not Is_MLA (Settings.Kind)
                 or else (Settings.Q_Lora_Rank = 0
                          and then T.Is_Present (L.KV_A_Lat)
                          and then T.Is_Present (L.KV_A_Rope)
                          and then L.KV_A_Norm /= null)));

   --  A layer goes whole where its front half does and the device takes
   --  its feed-forward too: a mixture whose stacks it holds, or a dense
   --  feed-forward, whose biases -- and a mixture's post-norm -- are
   --  steps of the sequence.
   function Whole_Layer_Fits (L : Layer; Index : Natural) return Boolean
   is ((if Settings.Experts > 0 and then not Dense_Among_Experts (L)
        then Mixture_Whole (L)
        else T.Is_Present (L.Up))
       and then Front_Fits (L, Index)
       and then not L.Host_Feed
       and then (Settings.Experts = 0
                 or else (L.Up_Bias = null and then L.Down_Bias = null))
       and then (L.Post_Feed_Norm = null
                 or else Settings.Experts = 0
                 or else Normalizes_After (Settings.Kind)));

   --  Whichever of the two a layer is: what the carry from the layer
   --  before asks of the layer after.
   function Layer_Fits (L : Layer; Index : Natural) return Boolean
   is (if Pure_SSM (Settings.Kind)
         or else (Is_Jamba (Settings.Kind) and then Linear (Settings, Index))
       then Mamba2_Fits (Item, L)
       elsif Linear (Settings, Index) then Linear_Layer_Fits (L)
       else Whole_Layer_Fits (L, Index));

   --  Whether the final normalization and the output head follow the
   --  last layer on the device, reading what it left there: one
   --  submission waited for at the end of a token rather than two, and
   --  the last layer's answer never comes home. Not for a centred
   --  normalization, which the device's takes with a shift this does
   --  not pass, nor where the final state is kept for the block past
   --  the stack.
   Head_Follows : constant Boolean :=
     Model_Runner.Backend."="
       (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then Source.Output_Norm /= null
     and then not Centres (Source, Source.Output_Norm_Bias)
     and then Item.Last_Final = null;

   --  Whether a layer leaves its answer on the device: for the next
   --  layer where that one goes to the device too, and after the last
   --  for the head.
   function Carries_On (Index : Natural) return Boolean
   is (if Index < Source.Layers.all'Last
       then Layer_Fits (Source.Layers.all (Index + 1), Index + 1)
       else Head_Follows);

   --  Room for the shared expert's answer where the device makes it
   --  after a front half, and none where the layer has no shared one.
   --  The shared expert of a layer whose front half the device ran,
   --  sent over while the host's pool runs the chosen experts; the
   --  mixture fetches it when it sums, or makes it itself.
   procedure Start_Shared (L : Layer; Front : Boolean) is
   begin
      Item.Shared_Ready := False;

      if not Front
        or else not T.Is_Present (L.Shared_Gate)
        or else L.Feed_Norm = null
        or else L.Feed_Norm_Pair /= null
        or else Centres (Source, L.Feed_Norm_Bias)
        or else Settings.Parallel_Residual
      then
         return;
      end if;

      if Item.Shared_Given = null
        or else Item.Shared_Given.all'Length
                /= Element_Count (Settings.Embedding)
      then
         T.Free (Item.Shared_Given);
         T.Allocate (Element_Count (Settings.Embedding), Item.Shared_Given);
         if Item.Shared_Given = null then
            return;
         end if;
      end if;

      Model_Runner.Backend.Device.Start_Shared
        (Item.Activation, L.Feed_Norm, Settings.Epsilon,
         L.Shared_Gate, L.Shared_Up, L.Shared_Down, L.Shared_Router,
         Item.Shared_Ready);
   end Start_Shared;

   --  A layer whose front half goes to the device and whose feed-forward
   --  the processor runs: a mixture the device does not hold, in a model
   --  whose everything else it does (Split_Feed), arranged the plain way
   --  -- a normalization before the feed-forward, joined after it.
   function Split_Here (L : Layer) return Boolean
   is (Source.Split_Feed
       and then ((L.Experts /= null and then not Mixture_Whole (L))
                 or else L.Host_Feed)
       and then L.Feed_Norm /= null
       and then not Normalizes_After (Settings.Kind)
       and then not Settings.Parallel_Residual
       and then L.Second_Attention_Norm = null);

   --  A slice of a token's work, for the pool.
   --
   --  A generated token's products run on five tasks and what lies
   --  between them ran on one -- six per cent of the token, with four
   --  workers watching, which `### The element-wise work of a layer, on
   --  the pool` measures. The batched path has shared these out since it
   --  was written -- Norm_Share, Join_Share and Feed_Share below -- and
   --  cuts them by position, which is what a batch has more than one of.
   --  A token has one position, so these cut by element instead.
   --
   --  CUTTING BY ELEMENT IS EXACT WHERE THE WORK IS ELEMENT-WISE AND
   --  WRONG WHERE IT IS NOT, which is the whole of what decides what is
   --  here. The gated middle and the residual add are element-wise: the
   --  answer at an index reads that index and nothing else, so a share
   --  computes what the whole computed, element for element, and no
   --  digest moves. A normalization is not -- it reads the sum of the
   --  whole vector before it writes any of it -- and it stays on the
   --  submitting task rather than becoming two dispatches around a
   --  barrier for two microseconds of arithmetic.
   --
   --  These are declared here rather than where they are used, which is
   --  inside the loop over the layers. A tagged type declared in a loop
   --  is elaborated every time round it, and that measured 2.3
   --  microseconds a layer -- three more empty ones in the same block
   --  cost one per cent of the token. What changes per layer travels in
   --  the record instead.

   --  What an element of the gated middle costs, against an element of
   --  the blend the inline bound was chosen on. It is an exponential
   --  and a multiply where that is a multiply and an add, and
   --  `tests benchmark` reads 2.13 ns an element for the activation
   --  against 0.26 for a quantized row product. Named rather than folded
   --  into the bound so that the bound stays one number for every
   --  caller and each caller says what its own elements cost.
   Gate_Weight : constant Element_Count := 8;

   --  A share of the heads.
   --
   --  A head is independent of every other head: it reads its own slice
   --  of the query, writes its own row of scores and its own slice of
   --  the blend, so the only thing that had to change before this was
   --  possible is that the scores are a row a head rather than one row
   --  shared.
   type Blend_Share is limited new Workers_CPU.Task_Item with
      record
         Base      : Element_Count := 0;
         V_Base    : Element_Count := 0;
         Rows_Base : Element_Count := 0;
         --  The first and the last position this layer may read, said
         --  as cells rather than positions: a layer that slides a
         --  window holds them somewhere else, and the blend walks its
         --  own memory. Every distance the blend takes is a difference
         --  between two of these, so subtracting the same origin from
         --  both leaves the arithmetic where it was.
         Earliest  : Element_Count := 0;
         Upto      : Element_Count := 0;
         Sinks     : T.Real_Array_Access := null;
         Ok        : Boolean := True;
      end record;

   overriding procedure Run
     (Share : in out Blend_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Blend_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      Fine : Boolean := True;
   begin
      if From > To then
         return;
      end if;

      if Item.Held in Eighth | Fourth then
         Blend_Eighth
           (Item.Held, Item.Held_Values, Item.Query.all, Item.Byte_Keys.all,
            Item.Byte_Values.all,
            Item.Key_Scales.all, Item.Value_Scales.all,
            Share.Base, Share.V_Base, Share.Rows_Base, KV_Width,
            V_Width, Heads, Head_Size, Value_Size,
            Element_Count (Settings.Group_Size),
            Share.Earliest, Share.Upto, Scale, Settings.Attention_Cap,
            Settings.Max_Bias, Share.Upto, Share.Sinks,
            From, To, Item.Score_Room,
            Item.Scores.all, Item.Attention.all, Fine);
      elsif Item.Held = Exact then
         Blend_Exact
           (Item.Query.all, Item.Keys.all, Item.Values.all,
            Share.Base, Share.V_Base, KV_Width, V_Width, Heads, Head_Size,
            Value_Size, Element_Count (Settings.Group_Size),
            Share.Earliest, Share.Upto, Scale, Settings.Attention_Cap,
            Settings.Max_Bias, Share.Upto, Share.Sinks,
            From, To, Item.Score_Room,
            Item.Scores.all, Item.Attention.all, Fine);
      else
         Blend_Halved
           (Item.Query.all, Item.Half_Keys.all,
            Item.Half_Values.all,
            Share.Base, Share.V_Base, KV_Width, V_Width, Heads, Head_Size,
            Value_Size, Element_Count (Settings.Group_Size),
            Share.Earliest, Share.Upto, Scale, Settings.Attention_Cap,
            Settings.Max_Bias, Share.Upto, Share.Sinks,
            From, To, Item.Score_Room,
            Item.Scores.all, Item.Attention.all, Fine);
      end if;

      --  Only ever set false, by any share that could not finish, and
      --  read by nobody until the pool has collected every worker --
      --  which is a rendezvous through a protected object and orders
      --  these writes against that read.
      if not Fine then
         Share.Ok := False;
      end if;
   end Run;

   type Gated_Share is limited new Workers_CPU.Task_Item with record
      Gate : T.Real_Array_Access;
      Up   : T.Real_Array_Access;
   end record;

   overriding procedure Run
     (Share : in out Gated_Share; First : Element_Count;
      Last  : Element_Count);

   overriding procedure Run
     (Share : in out Gated_Share; First : Element_Count;
      Last  : Element_Count) is
   begin
      if First > Last then
         return;
      end if;

      Gate_Activation
        (Source, Share.Gate.all (Share.Gate.all'First + First
                                 .. Share.Gate.all'First + Last));

      if Share.Up /= null then
         K.Multiply
           (Share.Gate.all (Share.Gate.all'First + First
                            .. Share.Gate.all'First + Last),
            Share.Up.all (Share.Up.all'First + First
                          .. Share.Up.all'First + Last));
      end if;
   end Run;

   type Added_Share is limited new Workers_CPU.Task_Item with record
      Into : T.Real_Array_Access;
      Adds : T.Real_Array_Access;
   end record;

   overriding procedure Run
     (Share : in out Added_Share; First : Element_Count;
      Last  : Element_Count);

   overriding procedure Run
     (Share : in out Added_Share; First : Element_Count;
      Last  : Element_Count) is
   begin
      if First > Last then
         return;
      end if;

      K.Add
        (Share.Into.all (Share.Into.all'First + First
                         .. Share.Into.all'First + Last),
         Share.Adds.all (Share.Adds.all'First + First
                         .. Share.Adds.all'First + Last));
   end Run;

   --  The residual join, shared out where it is only an addition.
   --
   --  Which is where the layer has no normalization on the way out of
   --  the sublayer: an architecture that has one reads the sum of the
   --  whole vector, so the join stops being element-wise and the whole
   --  of it stays here. Every llama, qwen, phi and mistral takes the
   --  first arm; gemma2 and gemma3 take the second.
   procedure Joined
     (Produced : T.Real_Array_Access;
      Gain     : T.Real_Array_Access;
      Bias     : T.Real_Array_Access;
      Sent     : out E.Error_Info);

   procedure Joined
     (Produced : T.Real_Array_Access;
      Gain     : T.Real_Array_Access;
      Bias     : T.Real_Array_Access;
      Sent     : out E.Error_Info) is
   begin
      Sent := E.Success;

      --  And where the two are not the same length, which nothing here
      --  produces and which a share cut by index could not answer: the
      --  whole of it goes through the procedure that checks its own
      --  shapes, exactly as it did before there were shares.
      --  Granite damps each sublayer's output before it joins the
      --  residual, which Join_Residual does; take that arm rather than
      --  the parallel add that would skip it.
      if Gain /= null
        or else Produced.all'Length /= Item.Activation.all'Length
        or else (Source.Settings.Kind in Granite | Granite_MoE
                 and then Source.Settings.Residual_Mul /= 0.0)
      then
         Join_Residual
           (Source, Produced.all, Item.Activation.all, Gain, Bias,
            Item.Post_Room);
         return;
      end if;

      declare
         Share : aliased Added_Share :=
           (Into => Item.Activation, Adds => Produced);
      begin
         Workers_CPU.Dispatch_Shares
           (Item.Team, Item.Activation.all'Length,
            Share'Unchecked_Access, Sent,
            Cost => Item.Activation.all'Length);
      end;
   end Joined;

   --  Where the last phase boundary was, for a caller that asked for a
   --  budget. The batched path keeps one of these too, and the phases
   --  mean the same thing in both -- which is the point: a token and a
   --  prompt divide their time very differently and the only way to see
   --  that is to measure them the same way.
   Mark : Ada.Real_Time.Time := Ada.Real_Time.Clock;
begin
   --  Where the products can reach it. Not cleared on the way out, and
   --  it does not need to be: every entry point that reaches a product
   --  sets it first, so what is read is always this call's token. A
   --  session between calls holds the last one it was given, which is
   --  the caller's own and which nothing reads.
   Item.Stopping := Cancel;

   if Item.Current = Closed or else Item.Current = Failed then
      Status := E.Make (E.Lifecycle_Invalid_State);
      E.Add_Text
        (Status, "state",
         Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
         E.Param_Identifier);
      return;
   end if;

   if not Source.Ready then
      Status := E.Make (E.Lifecycle_Model_Not_Ready);
      return;
   end if;

   --  A single token is evaluated in order to find out what comes after
   --  it, and a model with no head cannot say. Refused here rather than
   --  at the projection, so that a caller who asked the wrong thing of
   --  the wrong model is told before a forward pass is spent on it.
   if not Settings.Has_Head then
      Status := E.Make (E.Arch_No_Output_Head);
      E.Add_Text
        (Status, "architecture", Architecture_Name (Settings.Kind),
         E.Param_Identifier);
      return;
   end if;

   if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Token) then
      Status := E.Make (E.Tokenizer_Invalid_Token_Id);
      E.Add_Integer (Status, "token", Long_Long_Integer (Token));
      E.Add_Integer
        (Status, "vocabulary", Long_Long_Integer (Settings.Vocabulary));
      return;
   end if;

   if Item.Committed >= Item.Context then
      Status := E.Make (E.Generation_Context_Exhausted);
      E.Add_Integer
        (Status, "capacity", Long_Long_Integer (Item.Context),
         E.Param_Tokens);
      return;
   end if;

   if Asked /= Element_Count (Settings.Vocabulary) then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      E.Add_Integer (Status, "output", Long_Long_Integer (Asked));
      return;
   end if;

   --  Embedding lookup.
   T.Dequantize_Row
     (Source.Embeddings, Element_Count (Token), Item.Activation.all, Status);
   if E.Is_Error (Status) then
      Item.Current := Failed;
      return;
   end if;

   if Embedding_Scale (Source) /= 1.0 then
      for Value of Item.Activation.all loop
         Value := Value * Embedding_Scale (Source);
      end loop;
   end if;

   --  RWKV6 normalizes the embedding once before the first block sees it,
   --  the way Bert does -- the batch path does this too, and a generated
   --  token is the first place the single-token path meets an
   --  architecture that carries the tensor.
   if Source.Embedding_Norm /= null then
      Normalize
        (Source, Item.Activation.all, Source.Embedding_Norm.all,
         Source.Embedding_Norm_Bias, Item.Normalized.all);
      Item.Activation.all := Item.Normalized.all;
   end if;

   --  A text token, where the rotation's position has three parts:
   --  what it turns by is one past the token before it.
   Set_Mark (Item, Item.Committed);

   --  Where the token is, added to what the token is. GPT2 learns this
   --  instead of rotating, so a model with a position table has no
   --  rotation and a model with rotation has no table; the two are never
   --  both read.
   if Source.Settings.Kind = GPT2 then
      T.Dequantize_Row
        (Source.Positions, Element_Count (Item.Committed),
         Item.Normalized.all, Status);
      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      K.Add (Item.Activation.all, Item.Normalized.all);
   end if;

   --  Room for this position in the layers that slide a window.
   Make_Room (Item, Settings, Reserved);

   --  The ring over, and the one run this position is.
   if Hybrid (Settings.Kind)
     and then Item.Delta_State /= null
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind,
                 Model_Runner.Backend.Backend_Device)
     and then Model_Runner.Backend.Device.Runs_Linear
   then
      Send_States (Item'Unchecked_Access, Linear_Ready);
      if Linear_Ready then
         Write_Runs
           ([1 => (Whose => Item'Unchecked_Access,
                   First => Natural (Reserved), Count => 1, Row => 0)],
            Linear_Ready);
      end if;
   end if;

   for Index in Source.Layers.all'Range loop
      --  A dense layer whose feed-forward the processor runs reads its
      --  products there; every other runs where it always has.
      if Source.Split_Feed and then Settings.Experts = 0 then
         Item.Host_Feed := Source.Layers.all (Index).Host_Feed;
      end if;

      if C.Is_Cancelled (Cancel) then
         --  The reserved position was never committed, so the cache still
         --  describes exactly the context that was valid before this call.
         Status := E.Make (E.Generation_Cancelled);
         return;
      end if;

      declare
         Current : Layer renames Source.Layers.all (Index);
         Base    : constant Element_Count :=
           Keys_At (Item, Natural (Index));
         Cell    : constant Element_Count :=
           Cell_Of (Item, Natural (Index), Reserved);
         Slot    : constant Element_Count := Base + Cell * KV_Width;

         --  Where this layer's page table was written, for a paged
         --  session: set with the pages, so that a write that could not
         --  finish turns the whole layer to the host rather than reading
         --  a table that is not there.
         Paged_Table_At : Element_Count := 0;

         --  Where this layer's row scales begin, which is one a position
         --  rather than one an element.
         Rows_Base : constant Element_Count :=
           Rows_At (Item, Natural (Index));
         V_Base  : constant Element_Count :=
           Values_At (Item, Natural (Index));
         V_Slot  : constant Element_Count := V_Base + Cell * V_Width;

         --  Whether this position reached the device's own cache, which
         --  is what says attention may be done there. False leaves
         --  everything as it was, so a device that refused the room is a
         --  slower run rather than a failed one.
         Resident : Boolean := False;

         --  Whether attention and the matrix that reads its blend went
         --  over as one submission. False means the projection still has
         --  to be done, which is what it means everywhere else.
         Projected : Boolean := False;
         --  And whether the whole of the layer's second half went over
         --  as one sequence: attention, its projection, the join, the
         --  normalization, the feed-forward and the join after it. Every
         --  step below is then already done.
         Fused     : Boolean := False;

         --  Whether the device was asked for this layer at all, so
         --  that a layer the engine kept back is told apart from a
         --  layer the device refused; and whether the whole of it went
         --  over when it was asked -- which is not what Fused says,
         --  since a refused layer falls to the road that fuses its
         --  second half and sets that. Noted at the layer's end.
         Asked      : Boolean := False;
         Went_Whole : Boolean := False;

         --  And the one reason the engine knows and the device cannot,
         --  the sequence never having been built: that this session has
         --  no block of the device's cache.
         No_Block   : Boolean := False;

         --  Set when a device took the whole gated feed-forward, its
         --  projection down included, so that the common tail does not
         --  project it a second time.
         Whole_Block : Boolean := False;

         --  Whether this layer goes to the device as its front half
         --  alone, the feed-forward the processor's (Split_Here), and
         --  whether the device took it.
         Half      : Boolean := False;
         Half_Done : Boolean := False;
         --  The angles this position turns by, where the whole layer
         --  goes over as one: the table is what the device is handed
         --  instead of the architecture. Two numbers a pair.
         Pairs : constant Element_Count :=
           Element_Count (Settings.Rotary) / 2;

         Angles : N.Wide_Real_Array (0 .. Pairs * 2 - 1) :=
           [others => 0.0];

         Cosines : N.Wide_Real_Array (0 .. Pairs - 1);
         Sines   : N.Wide_Real_Array (0 .. Pairs - 1);

         --  Whether this layer is one of a hybrid's linear ones, which
         --  keeps a state instead of keys and values and takes the
         --  path of its own below; its feed-forward is every layer's.
         Is_Linear : constant Boolean :=
           Linear (Settings, Natural (Index));
      begin
         --  A Mamba2 layer whole on the device, normalization, mixer and
         --  residual, carried on to the next where that one goes too:
         --  the memory and the state seated in the device's room.
         if Mamba2_Fits (Item, Current) then
            declare
               Out_Too : constant Boolean :=
                 Chaining and then Carries_On (Index);
               Seated  : Boolean;
               Ran     : Boolean := False;
               Back    : Boolean;
            begin
               Send_States (Item'Unchecked_Access, Seated);
               if Seated then
                  Asked := True;
                  Model_Runner.Backend.Device.Mamba2_Layer
                    (Mamba2_Block_Of (Item, Current, Natural (Index), True),
                     Item.Activation.all, 1, Item.Normalized.all, Ran,
                     Item.Stopping, Carry_In => Carried,
                     Carry_Out => Out_Too);
               end if;

               if Ran then
                  if not Out_Too then
                     Item.Activation.all := Item.Normalized.all;
                  end if;
                  Went_Whole := True;
                  Carried := Out_Too;
                  Charge (Item, Fusing, Mark);
                  goto Layer_Done;
               end if;

               --  Refused: the host goes on from the activation the
               --  layer before left on the device.
               if Carried then
                  Model_Runner.Backend.Device.Fetch_Carried
                    (Item.Activation.all, Back);
                  Carried := False;
                  if not Back then
                     Item.Current := Failed;
                     Status := E.Make (E.Backend_Device_Refused);
                     return;
                  end if;
               end if;
            end;
         end if;

         if Is_Linear then
            --  The whole of it on the device, the ring included: the
            --  four projections, the convolution over the memory the
            --  ring keeps, the rule over the state it keeps, the
            --  projection out and the feed-forward, as one sequence.
            --  The ring goes over once, the first time, and comes
            --  home when the host is about to read it.
            if Model_Runner.Backend."="
                 (Item.Owner.Able.Kind,
                  Model_Runner.Backend.Backend_Device)
              and then (Linear_Layer_Fits (Current)
                        or else (Split_Here (Current)
                                 and then Linear_Front_Fits (Current)))
            then
               Half := not Linear_Layer_Fits (Current);

               declare
                  Sent : constant Boolean := Linear_Ready;
                  Back : Boolean;
               begin
                  --  No ring on the device is no layer on it; the
                  --  activation the layer before carried out comes
                  --  home for the host to go on from.
                  if not Sent and then Carried then
                     Model_Runner.Backend.Device.Fetch_Carried
                       (Item.Activation.all, Back);
                     Carried := False;
                     if not Back then
                        Item.Current := Failed;
                        Status := E.Make (E.Backend_Device_Refused);
                        return;
                     end if;
                  end if;

                  if Sent then
                     Asked := True;
                     if Half and then Source.Split_Feed
                       and then Workers_CPU."/=" (Item.Team, null)
                     then
                        Workers_CPU.Rouse (Item.Team.all);
                     end if;
                     Model_Runner.Backend.Device.Whole_Layer
                       (Item.Activation.all,
                        Device_Norm (Current.Attention_Norm,
                                     Current.Attention_Norm_Pair),
                        Device_Norm (Current.Feed_Norm,
                                     Current.Feed_Norm_Pair),
                        Settings.Epsilon,
                        T.Empty_View, T.Empty_View, T.Empty_View,
                        No_Turns, Natural (Head_Size), 0,
                        K."=" (Settings.Pairing, K.Split),
                        0, 0, Natural (Heads), Natural (Value_Size),
                        Settings.Group_Size, 0, 0, 0, 0,
                        Natural (KV_Width), Natural (V_Width),
                        Scale, Settings.Attention_Cap,
                        Current.Linear_Out,
                        Current.Gate, Current.Up, Current.Down,
                        Gate_Unit (Source),
                        Item.Key_Row, Item.Value_Row, Item.Activation,
                        Fused,
                        Carry_In  => Carried,
                        Carry_Out =>
                          not Half
                          and then Chaining
                          and then Carries_On (Index),
                        Mirror    => False,
                        Cancel    => Item.Stopping,
                        Router     =>
                          (if Settings.Experts > 0 then Current.Router
                           else T.Empty_View),
                        Router_Bias => Current.Router_Bias,
                        Gate_Stack  => Current.Gate_Stack,
                        Up_Stack    => Current.Up_Stack,
                        Down_Stack  => Current.Down_Stack,
                        Feed        => Settings.Expert_Feed,
                        Used        => Settings.Experts_Used,
                        Experts     => Settings.Experts,
                        Alpha => Settings.Gate_Alpha,
                        Limit => Settings.Gate_Limit,
                        Gate_Bias   => Current.Expert_Gate_Bias,
                        Up_Bias     =>
                          (if Settings.Experts > 0
                           then Current.Expert_Up_Bias
                           else Current.Up_Bias),
                        Down_Bias   =>
                          (if Settings.Experts > 0
                           then Current.Expert_Down_Bias
                           else Current.Down_Bias),
                        Post_Attention_Norm =>
                          Device_Norm (Current.Post_Attention_Norm,
                                       Current.Post_Attention_Norm_Pair),
                        Post_Feed_Norm      =>
                          Device_Norm (Current.Post_Feed_Norm,
                                       Current.Post_Feed_Norm_Pair),
                        Shifted => Norms_Shifted (Current),
                        Shared_Gate   => Current.Shared_Gate,
                        Shared_Up     => Current.Shared_Up,
                        Shared_Down   => Current.Shared_Down,
                        Shared_Router => Current.Shared_Router,
                        Linear_Mix    => Current.Mix,
                        Linear_Z      => Current.Z_Gate,
                        Linear_Alpha  => Current.Alpha,
                        Linear_Beta   => Current.Beta,
                        Conv          => Current.Conv,
                        Numbers       => Current.Linear_Numbers,
                        Linear        =>
                          Linear_Shape_Of (Item, Natural (Index), 1),
                        Linear_State_At =>
                          Linear_State_At (Item, Natural (Index)),
                        No_Feed   => Half);
                     Start_Shared (Current, Half and then Fused);
                     Half_Done := Half and then Fused;
                     Went_Whole := Fused and then not Half;
                  end if;
               end;

               if Half_Done then
                  --  The front half only: the ring moved on the device
                  --  as a whole layer's does, and the feed-forward is
                  --  the host's, after the host's own linear block.
                  Item.Kept_Newest :=
                    Natural'Max (Item.Kept_Newest, Natural (Reserved) + 1);
                  Carried := False;
                  if Chaining then
                     Deferred (Index) := True;
                  end if;
                  Fused := False;
                  Charge (Item, Attending, Mark);
                  goto Front_Done;
               end if;

               if Fused then
                  Item.Kept_Newest :=
                    Natural'Max (Item.Kept_Newest, Natural (Reserved) + 1);
                  Carried :=
                    Chaining
                    and then Carries_On (Index);
                  if Chaining then
                     Deferred (Index) := True;
                  end if;
                  Charge (Item, Fusing, Mark);
                  goto Layer_Done;
               end if;

               --  Refused: the host computes this layer, so what the
               --  device holds at its front is no longer the activation.
               --  The attention path clears this after every layer; the
               --  linear one only set it, and a layer refused here left
               --  the next one to carry in the stale front.
               Carried := False;
            end if;

            Normalize
              (Source, Item.Activation.all, Current.Attention_Norm.all,
               Current.Attention_Norm_Bias, Item.Normalized.all);
            Charge (Item, Normalizing, Mark);

            --  RWKV6 owns both its residuals and writes the block's
            --  output straight into the activation, so it joins nothing
            --  below and the layer is done once the step returns.
            if Is_RWKV (Settings.Kind) then
               RWKV6_Step
                 (Item, Source, Current, Natural (Index), Went_Whole,
                  Status);
               Asked := Went_Whole;
               exit when E.Is_Error (Status);
               Charge (Item, Attending, Mark);
               goto Layer_Done;
            end if;

            --  Jamba's linear layers are Mamba layers -- its stateful
            --  mixer is Mamba's scan, not the gated delta rule -- so they
            --  take Mamba's step and then, unlike a pure state-space
            --  model, go on to a feed-forward below.
            if Pure_SSM (Settings.Kind) or else Is_Jamba (Settings.Kind) then
               if Is_Mamba2 (Settings.Kind) then
                  Mamba2_Step
                    (Item, Source, Current, Natural (Index), Went_Whole,
                     Status);
                  Asked := Went_Whole;
               else
                  Mamba_Step
                    (Item, Source, Current, Natural (Index), Status);
               end if;
            else
               Linear_Position
                 (Item, Source, Current, Natural (Index),
                  Natural (Reserved), Status);
            end if;
            exit when E.Is_Error (Status);
            Charge (Item, Attending, Mark);

            Joined
              (Item.Normalized, Current.Post_Attention_Norm,
               Current.Post_Attention_Norm_Bias, Status);
            exit when E.Is_Error (Status);
            Charge (Item, Joining, Mark);

            --  Mamba's layer is the block and nothing after it: no
            --  feed-forward follows, where a hybrid's linear layer has
            --  every layer's. So the layer is done once the block has
            --  joined the residual.
            if Pure_SSM (Settings.Kind) then
               goto Layer_Done;
            end if;
         else

            --  The whole layer as one submission. A generated token made
            --  two of them a layer and makes one. A packed session's
            --  keys and values are packed as they are placed, by a step
            --  of the same sequence.
            --  An architecture that turns nothing -- GPT-2 learned a
            --  row a position -- hands over an empty table and the
            --  sequence has no turning step.
            if Item.Held in Exact | Eighth | Fourth
              and then Element_Count (Settings.Rotary) <= Head_Size
              and then (((Settings.Experts = 0
                          or else Dense_Among_Experts (Current)
                          or else Mixture_Whole (Current))
                         and then Whole_Layer_Fits (Current, Natural (Index)))
                        or else (Split_Here (Current)
                                 and then Front_Fits
                                            (Current, Natural (Index))))
              and then Model_Runner.Backend."="
                         (Item.Owner.Able.Kind,
                          Model_Runner.Backend.Backend_Device)
            then
               Half := not ((Settings.Experts = 0
                             or else Dense_Among_Experts (Current)
                             or else Mixture_Whole (Current))
                            and then Whole_Layer_Fits
                                       (Current, Natural (Index)));

               if Item.Paged then
                  --  Up to the one position this token writes: it needs
                  --  the pages its own cell reaches and no more, and its
                  --  page tables written where the sequence reads them,
                  --  which Take_Pages does for every layer at once.
                  Take_Pages (Item'Unchecked_Access, Reserved, Resident);
                  if Resident then
                     Paged_Table_At :=
                       Item.Page_Table_At.all (Natural (Index));
                  end if;
               else
                  Take_Block (Item'Unchecked_Access, Resident);
               end if;
               No_Block := not Resident;

               if Resident then
                  if Settings.Rotary > 0 then
                     K.Rotary_Table
                       (Element_Count (Settings.Rotary), Item.Committed,
                        Turn_Base (Settings, Natural (Index)),
                        Turn_Scaling (Settings, Natural (Index)),
                        Turns (Source),
                        Cosines => Cosines, Sines => Sines,
                        Sections => Settings.Sections,
                        Place => Place_At (Item, Item.Committed));

                     for Pair in 0 .. Pairs - 1 loop
                        Angles (Pair * 2) := Cosines (Pair);
                        Angles (Pair * 2 + 1) := Sines (Pair);
                     end loop;
                  end if;

                  Asked := True;
                  if Half and then Source.Split_Feed
                    and then Workers_CPU."/=" (Item.Team, null)
                  then
                     Workers_CPU.Rouse (Item.Team.all);
                  end if;
                  Model_Runner.Backend.Device.Whole_Layer
                    (Item.Activation.all,
                     Device_Norm (Current.Attention_Norm,
                                  Current.Attention_Norm_Pair),
                     Device_Norm (Current.Feed_Norm,
                                  Current.Feed_Norm_Pair),
                     Settings.Epsilon,
                     Current.Query,
                     (if Is_MLA (Settings.Kind)
                      then MLA_Rows (Current.KV_A_MQA, Heads * Head_Size)
                      else Current.Key),
                     (if Is_MLA (Settings.Kind)
                      then MLA_Rows (Current.KV_A_MQA, Heads * Value_Size)
                      else Current.Value),
                     Angles, Natural (Head_Size), Settings.Rotary,
                     K."=" (Settings.Pairing, K.Split),
                     (if Item.Paged then 0
                      else Block_Base (Item) + Slot),
                     (if Item.Paged then Page_Value_Base (Item)
                      else Block_Base (Item)
                           + Exact_Keys (Item) + V_Slot),
                     Natural (Heads), Natural (Value_Size),
                     Settings.Group_Size,
                     Natural (Cell_Of (Item, Natural (Index),
                                       Earliest (Settings, Reserved,
                                                 Natural (Index)))),
                     Natural (Cell),
                     (if Item.Paged then 0
                      else Block_Base (Item) + Base),
                     (if Item.Paged then Page_Value_Base (Item)
                      else Block_Base (Item)
                           + Exact_Keys (Item) + V_Base),
                     Natural (KV_Width), Natural (V_Width),
                     Scale, Settings.Attention_Cap,
                     Current.Attention_Out,
                     Current.Gate, Current.Up, Current.Down,
                     Gate_Unit (Source),
                     Item.Key_Row, Item.Value_Row, Item.Activation, Fused,

                     --  As a batch does: the first layer reads what the
                     --  host has and the last writes what it reads, and
                     --  the ones between hand the activation on where it
                     --  lies and leave their keys and values in the
                     --  device's own cache. A token is twenty-two layers
                     --  and each of them waited on its own fence.
                     Carry_In  => Carried,
                     Carry_Out =>
                       not Half
                       and then Chaining
                       and then Carries_On (Index),
                     --  A paged session places its keys and values by
                     --  the chained head step as a block session does: the
                     --  head step reads the page table out of the cache it
                     --  writes, at a binding of its own, and places into
                     --  the page the position names. A round, whose rows
                     --  carry their own per-row table, still mirrors.
                     Mirror    => not Chaining,
                     Window   =>
                       (if Settings.Window > 0
                          and then Earliest (Settings,
                                             Element_Count (Settings.Window),
                                             Natural (Index)) > 0
                        then Settings.Window
                        else 0),
                     Max_Bias => Settings.Max_Bias,
                     Cancel   => Item.Stopping,

                     --  A cache in pages: the layer's page table, where
                     --  the step that places and the attention both read
                     --  a position's page out of, and the page's width
                     --  as a shift. The bases above are then offsets
                     --  inside a page, and this position's cell says
                     --  which page it lands in.
                     Pages_At   => Natural (Paged_Table_At),
                     Page_Shift =>
                       (if Item.Paged then Page_Shift_Bits else 0),
                     First_Position => Natural (Cell),

                     --  The head normalizations, where the layer has
                     --  them, and the mixture where the layer is one.
                     Query_Norm => Current.Query_Norm,
                     Key_Norm   => Current.Key_Norm,
                     Router     =>
                       (if Settings.Experts > 0 then Current.Router
                        else T.Empty_View),
                     Router_Bias => Current.Router_Bias,
                     Gate_Stack  => Current.Gate_Stack,
                     Up_Stack    => Current.Up_Stack,
                     Down_Stack  => Current.Down_Stack,
                     Feed        => Settings.Expert_Feed,
                     Used        => Settings.Experts_Used,
                     Experts     => Settings.Experts,

                     --  A packed session's block -- or, where it is
                     --  paged, its page: the bytes and scales are then a
                     --  region's offset in a page, and the page fields
                     --  above place the row.
                     Packed      => Packed_Shape (Item, Base, V_Base,
                                                  KV_Width, V_Width,
                                                  Paged => Item.Paged),
                     Pack_Keys   =>
                       Packing_Of (Item, Slot, KV_Width, True,
                                   Paged => Item.Paged),
                     Pack_Values =>
                       Packing_Of (Item, V_Slot, V_Width, False,
                                   Paged => Item.Paged),

                     --  The layer's sinks, put where the attention
                     --  reads them.
                     Sinks_At    => Sinks_Ready (Current.Sinks, Natural (Index)),
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit,

                     --  And its experts' biases, where the layer
                     --  carries them, as steps of the sequence -- or
                     --  a dense feed-forward's own two.
                     Gate_Bias   => Current.Expert_Gate_Bias,
                     Up_Bias     =>
                       (if Settings.Experts > 0 then Current.Expert_Up_Bias
                        else Current.Up_Bias),
                     Down_Bias   =>
                       (if Settings.Experts > 0
                        then Current.Expert_Down_Bias
                        else Current.Down_Bias),
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

                     --  A hybrid's gate beside each head, and its
                     --  mixture's shared expert.
                     Head_Gates    => Hybrid (Settings.Kind),
                     Shared_Gate   => Current.Shared_Gate,
                     Shared_Up     => Current.Shared_Up,
                     Shared_Down   => Current.Shared_Down,
                     Shared_Router => Current.Shared_Router,
                     No_Feed       => Half,
                     MLA_Latent    =>
                       (if Is_MLA (Settings.Kind) then Current.KV_A_Lat
                        else T.Empty_View),
                     MLA_Rope      =>
                       (if Is_MLA (Settings.Kind) then Current.KV_A_Rope
                        else T.Empty_View),
                     MLA_Norm      => Current.KV_A_Norm,
                     MLA_Up        =>
                       (if Is_MLA (Settings.Kind) then Current.KV_B
                        else T.Empty_View));
                  Start_Shared (Current, Half and then Fused);
                  Half_Done := Half and then Fused;
                  Went_Whole := Fused and then not Half;
               end if;
            end if;

            Carried :=
              Chaining
              and then Fused
              and then not Half_Done
              and then Carries_On (Index);

            if Fused then
               --  The host keeps its own copy of the cache -- the
               --  snapshot, the eviction and the other two precisions all
               --  read it -- and reads it out of the device's own once the
               --  token is done rather than a layer at a time, which is
               --  what lets a layer be handed over without waiting.
               --  A packed session's copy is the rows packed as the
               --  device packed them, the same bytes.
               if Chaining then
                  Deferred (Index) := True;
               elsif Item.Held in Eighth | Fourth then
                  Pack_Row
                    (Item.Key_Row.all (0 .. KV_Width - 1),
                     Item.Byte_Keys.all, Slot, KV_Width,
                     Item.Key_Scales.all, Item.Held);
                  Pack_Row
                    (Item.Value_Row.all (0 .. V_Width - 1),
                     Item.Byte_Values.all, V_Slot, V_Width,
                     Item.Value_Scales.all, Item.Held_Values);
               else
                  for Offset in 0 .. KV_Width - 1 loop
                     Item.Keys.all (Slot + Offset) :=
                       Item.Key_Row.all (Offset);
                  end loop;
                  for Offset in 0 .. V_Width - 1 loop
                     Item.Values.all (V_Slot + Offset) :=
                       Item.Value_Row.all (Offset);
                  end loop;
               end if;

               --  The whole layer, not the attending in it: nothing
               --  between the normalization at its front and the join at
               --  its back came back to the host, so this one reading is
               --  all there is and it is charged where it belongs.
               --  The front half only: the cache is the device's as a
               --  whole layer's is, and the feed-forward the host's.
               if Half_Done then
                  Fused := False;
                  Charge (Item, Attending, Mark);
                  goto Front_Done;
               end if;

               Charge (Item, Fusing, Mark);
               goto Layer_Done;
            end if;

            --  Attention block. OLMo2 has no normalization on the way in
            --  and hands attention the residual as it stands; every other
            --  architecture here normalizes it first.
            if Current.Attention_Norm = null then
               Item.Normalized.all := Item.Activation.all;
            else
               Normalize
                 (Source, Item.Activation.all, Current.Attention_Norm.all,
                  Current.Attention_Norm_Bias, Item.Normalized.all);
            end if;

            --  Falcon runs the feed-forward from this same normalized input
            --  rather than from what attention produced, so it is kept
            --  before attention overwrites the buffer it shares. OLMo2 has
            --  a null feed norm too but reads the post-attention residual,
            --  so this is asked of the pre-norm being present -- Falcon --
            --  and not merely of the feed norm being absent.
            if Current.Feed_Norm = null
              and then Current.Attention_Norm /= null
            then
               Item.Post_Room.all := Item.Normalized.all;
            end if;

            Charge (Item, Normalizing, Mark);

            --  The query projection's whole answer goes to its own room
            --  where it carries a gate beside each head, and the queries
            --  and the gates are taken out of it before anything reads
            --  them.
            if Is_MLA (Settings.Kind) then
               MLA_Project (Item, Current, Status);
            else
               Product_Group
                 (Item,
                  [Current.Query, Current.Key, Current.Value],
                  Item.Normalized,
                  [(if Hybrid (Settings.Kind)
                    then Item.Query_Full else Item.Query),
                   Item.Key_Row, Item.Value_Row],
                  Status);
            end if;
            exit when E.Is_Error (Status);

            Charge (Item, Projecting, Mark);

            if Hybrid (Settings.Kind) then
               Split_Head_Gates (Item, Settings);
            end if;

            --  The projection bias, before the rotary encoding, because the
            --  bias is part of the projection and the encoding acts on what
            --  the projection produced.
            if Current.Query_Bias /= null then
               K.Add (Item.Query.all, Current.Query_Bias.all);
               K.Add (Item.Key_Row.all, Current.Key_Bias.all);
               K.Add (Item.Value_Row.all, Current.Value_Bias.all);
            end if;

            --  MPT's clamp, where it states one, on what the projection
            --  produced and before anything reads it.
            Clip_QKV
              (Settings.Clip_QKV, Item.Query.all, Item.Key_Row.all,
               Item.Value_Row.all);

            --  And the per-head normalization, where the architecture has
            --  one. Before the rotation, as the projection's bias is: both
            --  act on what the projection produced.
            if Current.Query_Norm /= null then
               Normalize_Heads
                 (Item.Query.all, Heads, Head_Size,
                  Current.Query_Norm.all, Settings.Epsilon,
                  Item.Head_Row.all);
               Normalize_Heads
                 (Item.Key_Row.all, KV_Heads, Head_Size,
                  Current.Key_Norm.all, Settings.Epsilon, Item.Head_Row.all);
            elsif Current.Query_Head_Norm /= null then
               Normalize_Heads_Centred
                 (Item.Query.all, Heads, Head_Size,
                  Current.Query_Head_Norm.all, Settings.Epsilon,
                  Item.Head_Row.all);
               Normalize_Heads_Centred
                 (Item.Key_Row.all, KV_Heads, Head_Size,
                  Current.Key_Head_Norm.all, Settings.Epsilon,
                  Item.Head_Row.all);
            end if;

            --  And the code variant's, over the whole of each
            --  projection rather than a head of it.
            if Current.Query_Whole_Norm /= null then
               Normalize_Whole
                 (Source, Item.Query.all, Current.Query_Whole_Norm,
                  Current.Query_Whole_Norm_Bias);
               Normalize_Whole
                 (Source, Item.Key_Row.all, Current.Key_Whole_Norm,
                  Current.Key_Whole_Norm_Bias);
            end if;

            declare
               use type K.Rotary_Scaling;

               Base    : constant N.Wide_Real :=
                 Turn_Base (Settings, Natural (Index));
               Stretch : constant K.Rotary_Scaling :=
                 Turn_Scaling (Settings, Natural (Index));
               Pairs   : constant Element_Count :=
                 Element_Count (Settings.Rotary) / 2;
               --  Every head turns from its first element: DeepSeek's
               --  heads are laid out rotated slice first (MLA_Project).
               Shift   : constant Element_Count := 0;
            begin
               --  A rotation by the position alone turns every layer of
               --  this token by the same angles where the base and the
               --  stretch agree, so the table is made once and kept.
               --  One dealt among the parts of a place is made each time.
               if Settings.Sections = K.No_Sections
                 and then Pairs in 1 .. Item.Turned_Cos'Length
               then
                  if not Item.Turned
                    or else Item.Turned_At /= Item.Committed
                    or else Item.Turned_Base /= Base
                    or else Item.Turned_Scale /= Stretch
                    or else Item.Turned_Pairs /= Pairs
                  then
                     K.Rotary_Table
                       (Element_Count (Settings.Rotary), Item.Committed,
                        Base, Stretch, Turns (Source),
                        Cosines => Item.Turned_Cos (0 .. Pairs - 1),
                        Sines => Item.Turned_Sin (0 .. Pairs - 1));
                     Item.Turned := True;
                     Item.Turned_At := Item.Committed;
                     Item.Turned_Base := Base;
                     Item.Turned_Scale := Stretch;
                     Item.Turned_Pairs := Pairs;
                  end if;

                  K.Apply_Rotary_Table
                    (Item.Query.all, Heads, Head_Size,
                     Element_Count (Settings.Rotary),
                     Item.Turned_Cos (0 .. Pairs - 1),
                     Item.Turned_Sin (0 .. Pairs - 1),
                     Settings.Pairing, Shift);
                  K.Apply_Rotary_Table
                    (Item.Key_Row.all, KV_Heads, Head_Size,
                     Element_Count (Settings.Rotary),
                     Item.Turned_Cos (0 .. Pairs - 1),
                     Item.Turned_Sin (0 .. Pairs - 1),
                     Settings.Pairing, Shift);
               else
                  K.Apply_Rotary
                    (Item.Query.all, Heads, Head_Size,
                     Element_Count (Settings.Rotary), Item.Committed,
                     Base, Stretch, Turns (Source), Settings.Pairing,
                     Sections => Settings.Sections,
                     Place => Place_At (Item, Item.Committed),
                     Offset => Shift);
                  K.Apply_Rotary
                    (Item.Key_Row.all, KV_Heads, Head_Size,
                     Element_Count (Settings.Rotary), Item.Committed,
                     Base, Stretch, Turns (Source), Settings.Pairing,
                     Sections => Settings.Sections,
                     Place => Place_At (Item, Item.Committed),
                     Offset => Shift);
               end if;
            end;

            --  Write into the reserved slot. The slot is only readable as
            --  context once Committed is advanced, at the end of this call.
            if Item.Held in Eighth | Fourth then
               Pack_Row
                 (Item.Key_Row.all (0 .. KV_Width - 1), Item.Byte_Keys.all,
                  Slot, KV_Width, Item.Key_Scales.all, Item.Held);
               Pack_Row
                 (Item.Value_Row.all (0 .. V_Width - 1), Item.Byte_Values.all,
                  V_Slot, V_Width, Item.Value_Scales.all, Item.Held_Values);

               --  And into the device's own copy of the packed block,
               --  where its attention reads the bytes the host rounded.
               Put_Packed_Position
                 (Item'Unchecked_Access, Slot, V_Slot, KV_Width, V_Width,
                  Resident);
            elsif Item.Held = Exact then
               for Offset in 0 .. KV_Width - 1 loop
                  Item.Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
               end loop;
               for Offset in 0 .. V_Width - 1 loop
                  Item.Values.all (V_Slot + Offset) :=
                    Item.Value_Row.all (Offset);
               end loop;

               --  And into the device's own copy, where attention reads it.
               --  The host copy stays in step because everything else reads
               --  it: the snapshot, the eviction, the other two precisions.
               Put_Position
                 (Item'Unchecked_Access,
                  Slot, Item.Key_Row.all (0 .. KV_Width - 1),
                  V_Slot, Item.Value_Row.all (0 .. V_Width - 1), Resident);
            else
               Model_Runner.Kernels.To_Halves
                 (Item.Key_Row.all (0 .. KV_Width - 1),
                  Item.Half_Keys.all (Slot .. Slot + KV_Width - 1));
               Model_Runner.Kernels.To_Halves
                 (Item.Value_Row.all (0 .. V_Width - 1),
                  Item.Half_Values.all (V_Slot .. V_Slot + V_Width - 1));
            end if;

            --  Rotating covers the cache write, as it does in the batched
            --  path and for the same reason.
            Charge (Item, Rotating, Mark);

            --  Causal attention over the committed positions and this one.
            --  Grouped-query attention maps each query head to its key-value
            --  head by division; no key or value head is ever duplicated.
            --
            --  A model with a sliding window sees the window's worth of
            --  positions ending at this one and no more, and the positions
            --  before that are no longer in the cache: a layer that slides
            --  holds the window and a batch rather than the whole context.
            --  What that changes here is nothing -- Cell_Of says where a
            --  position sits and the blend is given cells rather than
            --  positions -- and what it changes elsewhere is a gemma3
            --  session at its own context, from 1.83 GB to 0.33.
            declare
               First : constant Element_Count :=
                 Earliest (Settings, Reserved, Natural (Index));
               Usable : Boolean;

               Share  : aliased Blend_Share :=
                 (Base     => Base,
                  V_Base   => V_Base,
                  Rows_Base => Rows_Base,
                  Earliest => Cell_Of (Item, Natural (Index), First),
                  Upto     => Cell,
                  Sinks    => Current.Sinks,
                  Ok       => True);
               Shared : E.Error_Info;
            begin

               --  A layer with sinks the device has no room for attends
               --  on the host; the pair below is given the others'.
               if Item.Held = Halved or else not Resident
                 or else not Sinks_Fit (Current.Sinks, Natural (Index))
                 or else Hybrid (Settings.Kind)
               then
                  --  How much arithmetic the heads are between them: every
                  --  head reads the positions the cache holds, a head's
                  --  worth of each. A generated token early in a
                  --  conversation is a few hundred thousand elements and
                  --  the pool is not woken for it.
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Heads, Share'Unchecked_Access, Shared,
                     Cost => Heads * Reserved * Head_Size);
                  Usable := Share.Ok and then E.Is_Ok (Shared);
               elsif Resident
                 and then Settings.Experts = 0
                 and then T.Is_Present (Current.Gate)
                 and then Current.Feed_Norm /= null
                 and then Current.Out_Bias = null
                 and then Current.Up_Bias = null
                 and then Current.Down_Bias = null
                 and then Current.Feed_Norm_Bias = null
                 and then Current.Post_Attention_Norm = null
                 and then Current.Post_Feed_Norm = null
                 and then not (Settings.Kind in Granite | Granite_MoE
                               and then Settings.Residual_Mul /= 0.0)
                 and then Settings.Kind not in Starcoder2 | Stablelm | Gptneox | Mpt
                       | Command_R
                 and then Settings.Max_Bias = 0.0
               then
                  --  The whole of the layer's second half as one sequence.
                  --  Everything the host used to do between its two
                  --  submissions -- the residual join and the
                  --  normalization -- is a step of it, so the two become
                  --  one and the fence between them is not paid. A packed
                  --  session's step reads its block with the packed
                  --  kernel; the rest of the sequence is the same.
                  Model_Runner.Backend.Device.Attend_And_Feed
                    (Item.Query.all, Item.Activation.all,
                     Natural (Heads), Natural (Head_Size),
                     Natural (Value_Size), Settings.Group_Size,
                     Natural (Cell_Of (Item, Natural (Index), First)),
                     Natural (Cell),
                     Block_Base (Item) + Base,
                     --  A packed session has no exact rows for the
                     --  values to follow; its step reads neither base.
                     Block_Base (Item) + Exact_Keys (Item) + V_Base,
                     Natural (KV_Width), Natural (V_Width), Scale,
                     Settings.Attention_Cap, Current.Attention_Out,
                     Current.Feed_Norm.all, Settings.Epsilon,
                     Current.Gate, Current.Up, Current.Down,
                     Gate_Unit (Source), Item.Activation, Fused,
                     Max_Bias => Settings.Max_Bias,
                     Packed => Packed_Shape (Item, Base, V_Base,
                                             KV_Width, V_Width),
                     Sinks_At => Sinks_Ready (Current.Sinks, Natural (Index)),
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit);

                  if Fused then
                     Usable := True;
                     Projected := True;
                  else
                     Attend_There
                       (Item, Source, Item.Query.all, Heads, Head_Size,
                        Value_Size,
                        Cell_Of (Item, Natural (Index), First), Cell,
                        Base, V_Base, KV_Width,
                        V_Width, Scale, Item.Attention.all, Usable,
                        Sinks => Current.Sinks);
                  end if;
               elsif Resident then
                  --  Attention and the matrix that reads its result, named
                  --  together so they go over as one command buffer and the
                  --  blend never comes back. Where the device will not take
                  --  the pair, Attend_There does the attention alone and the
                  --  projection follows as it always did.
                  Model_Runner.Backend.Device.Attend_And_Project
                    (Item.Query.all, Natural (Heads), Natural (Head_Size),
                     Natural (Value_Size), Settings.Group_Size,
                     Natural (Cell_Of (Item, Natural (Index), First)),
                     Natural (Cell), Base,
                     Exact_Keys (Item) + V_Base,
                     Natural (KV_Width), Natural (V_Width), Scale,
                     Settings.Attention_Cap, Current.Attention_Out,
                     Item.Normalized, Projected,
                     Max_Bias => Settings.Max_Bias,
                     Packed => Packed_Shape (Item, Base, V_Base,
                                             KV_Width, V_Width),
                     Sinks_At => Sinks_Ready (Current.Sinks, Natural (Index)));

                  if Projected then
                     Usable := True;
                  else
                     Attend_There
                       (Item, Source, Item.Query.all, Heads, Head_Size,
                        Value_Size,
                        Cell_Of (Item, Natural (Index), First), Cell,
                        Base, V_Base, KV_Width,
                        V_Width, Scale, Item.Attention.all, Usable,
                        Sinks => Current.Sinks);
                  end if;
               end if;

               if not Usable then
                  Item.Current := Failed;
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  E.Add_Integer (Status, "layer", Long_Long_Integer (Index));
                  return;
               end if;
            end;

            Charge (Item, Attending, Mark);
         end if;

         --  Every step of this is a step of the sequence where the
         --  layer's second half went over as one, so there is nothing
         --  left here to do.
      <<Front_Done>>
         if not Fused then
            --  Done already where the pair went over together, and
            --  where the layer is linear and joined its answer above
            --  -- or where the device ran the front half and joined it.
            if not Is_Linear and then not Half_Done then
               if not Projected then
                           --  Each head's blend through the sigmoid of its gate
                  --  first, where the query projection carried one.
                  if Hybrid (Settings.Kind) then
                     Gate_Heads (Item);
                  end if;

                  Product
                    (Item, Current.Attention_Out, Item.Attention,
                     Item.Normalized, Status);
                  exit when E.Is_Error (Status);

               end if;

               Charge (Item, Projecting, Mark);

               if Current.Out_Bias /= null then
                  K.Add (Item.Normalized.all, Current.Out_Bias.all);
               end if;

               --  The code variant reads the layer's input once more
               --  after the join, so it is kept across it -- and so does a
               --  parallel-residual block, whose feed-forward reads the
               --  layer's input rather than the residual the attention has
               --  been added to. Kept here, before the join below writes
               --  the residual over it.
               if Current.Second_Attention_Norm /= null
                 or else Settings.Parallel_Residual
               then
                  Item.Kept_Input.all := Item.Activation.all;
               end if;
               Joined
                 (Item.Normalized, Current.Post_Attention_Norm,
                  Current.Post_Attention_Norm_Bias, Status);
               exit when E.Is_Error (Status);
               if Current.Second_Attention_Norm /= null then
                  Join_Again
                    (Source, Item.Activation.all, Item.Kept_Input.all,
                     Current, Item.Post_Room);
               end if;

               Charge (Item, Joining, Mark);
            end if;

            --  Feed-forward block. It reads what the layer normalized on
            --  the way in where the architecture runs the two in parallel
            --  (Falcon), the residual as it stands where the architecture
            --  has no normalization before the feed-forward at all (OLMo2,
            --  which normalizes what the feed-forward produced instead),
            --  and a fresh normalization of the residual where it runs the
            --  two one after the other.
            if Current.Feed_Norm /= null then
               --  A parallel-residual block normalizes the layer's input,
               --  kept above, rather than the residual the attention was
               --  added to; every sequential block normalizes the residual
               --  as it now stands.
               Normalize
                 (Source,
                  (if Settings.Parallel_Residual
                   then Item.Kept_Input.all else Item.Activation.all),
                  Current.Feed_Norm.all,
                  Current.Feed_Norm_Bias, Item.Normalized.all);
            elsif Current.Attention_Norm /= null then
               Item.Normalized.all := Item.Post_Room.all;
            else
               Item.Normalized.all := Item.Activation.all;
            end if;

            Charge (Item, Normalizing, Mark);

            --  A mixture layer runs its router and experts; a dense one
            --  the plain feed-forward. Which a layer is is the layer's
            --  own, not the model's -- Jamba has both -- so the per-layer
            --  presence of experts decides, which is the model's answer
            --  for every architecture whose layers are all of one kind.
            if Current.Experts /= null then
               Mixture
                 (Item, Current, Item.Normalized, Item.Mixture, Status);

               --  The pool roused for this layer's experts may sleep
               --  again; the next layer's front half rouses it anew.
               if Workers_CPU."/=" (Item.Team, null) then
                  Workers_CPU.Rest (Item.Team.all);
               end if;
               exit when E.Is_Error (Status);
               Joined
                 (Item.Mixture, Current.Post_Feed_Norm,
                  Current.Post_Feed_Norm_Bias, Status);
               exit when E.Is_Error (Status);
            else
               --  Gated or not, the two arrangements differ only in how the
               --  buffer handed to the projection down is filled: one fills
               --  it from two projections and a product, the other from one
               --  projection. What follows is common, and is written once so
               --  that it cannot be reached by one arrangement and skipped by
               --  the other -- which is what happened when the ungated arm
               --  was added beside a projection down that belonged to the
               --  gated one, and Falcon then ran with its feed-forward
               --  computed and discarded.
               if not T.Is_Present (Current.Gate) then
                  --  No gate: up, a Gaussian unit, down. The gate being
                  --  absent is what says so, rather than the architecture,
                  --  so an architecture added later with the same
                  --  arrangement needs nothing here.
                  Product
                    (Item, Current.Up, Item.Normalized, Item.Gate, Status);
                  exit when E.Is_Error (Status);

                  --  The bias belongs to the projection, so it is added
                  --  before the unit rather than after it.
                  if Current.Up_Bias /= null then
                     K.Add (Item.Gate.all, Current.Up_Bias.all);
                  end if;

                  Gate_Activation (Source, Item.Gate.all);
               else
                  --  A device takes the whole block: both arms, the unit
                  --  and the multiply, and the projection that reads the
                  --  result, without any of the middle coming back. Every
                  --  other backend does what it did.
                  --  Not a layer whose feed-forward the processor runs:
                  --  its weights are the host's panels.
                  if Model_Runner.Backend."=" (Item.Owner.Able.Kind,
                                               Model_Runner.Backend
                                                 .Backend_Device)
                    and then not Item.Host_Feed
                  then
                     Model_Runner.Backend.Device.Dispatch_Gated
                       (Current.Gate, Current.Up, Current.Down,
                        Item.Normalized, 1, Gate_Unit (Source),
                        Item.Normalized, Status, Item.Stopping,
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit);
                     exit when E.Is_Error (Status);
                     Whole_Block := True;
                  else
                     Product_Group
                       (Item, [Current.Gate, Current.Up], Item.Normalized,
                        [Item.Gate, Item.Up], Status);
                     exit when E.Is_Error (Status);

                     if Item.Gate.all'Length /= Item.Up.all'Length then
                        --  Not a shape anything here produces, and one
                        --  a share cut by index could not answer. The
                        --  kernels check their own shapes.
                        Gate_Activation (Source, Item.Gate.all);
                        K.Multiply (Item.Gate.all, Item.Up.all);
                     else
                        declare
                           Share  : aliased Gated_Share :=
                             (Gate => Item.Gate, Up => Item.Up);
                           Shared : E.Error_Info;
                        begin
                           Workers_CPU.Dispatch_Shares
                             (Item.Team, Item.Gate.all'Length,
                              Share'Unchecked_Access, Shared,
                              Cost => Item.Gate.all'Length * Gate_Weight);

                           if E.Is_Error (Shared) then
                              Status := Shared;
                              return;
                           end if;
                        end;
                     end if;
                  end if;
               end if;

               if not Whole_Block then
                  Product
                    (Item, Current.Down, Item.Gate, Item.Normalized, Status);
                  exit when E.Is_Error (Status);
               end if;

               if Current.Down_Bias /= null then
                  K.Add (Item.Normalized.all, Current.Down_Bias.all);
               end if;

               Charge (Item, Feeding, Mark);

               Joined
                 (Item.Normalized, Current.Post_Feed_Norm,
                  Current.Post_Feed_Norm_Bias, Status);
               exit when E.Is_Error (Status);
            end if;

         end if;

         Charge (Item, Joining, Mark);

         <<Layer_Done>>

         --  What became of this layer, for the run's report: the whole
         --  of it over as one sequence, or not -- and, where the device
         --  was asked and said no, what it said no to.
         if Model_Runner.Backend."="
              (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
         then
            Model_Runner.Backend.Device.Note_Layer
              (Went_Whole, Asked, Cache => No_Block,
               Held => No_Block and then Blocks_Were_Held,
               Split => Half_Done);
         end if;
      end;
   end loop;

   --  Every layer's products where they always ran, past the stack.
   if Source.Split_Feed and then Settings.Experts = 0 then
      Item.Host_Feed := False;
   end if;

   --  The host's own copy of the cache, brought up to date out of the
   --  device's for the layers that did not send it back one at a time.
   --  One position apiece, which is what a token writes.
   --  The host's copy of what the device wrote, owed rather than read:
   --  where every layer went whole, the position is recorded as owed
   --  and fetched when something is about to read it, as a batch's
   --  are. Reading it here was two reads a layer through a mapping the
   --  device's memory answers a word at a time -- five milliseconds of
   --  a twenty-nine millisecond token, the device's own clock said, for
   --  bytes nothing read in a run that neither saves its context nor
   --  rolls it. A layer that did not go whole wrote the host's copy
   --  itself, so a mix of the two is read as it was.
   declare
      Owing : constant Boolean :=
        (for all Index in Source.Layers.all'Range => Deferred (Index));
   begin
      if Owing then
         if Item.Owed_Count = 0 then
            Item.Owed_At := Natural (Reserved);
            Item.Owed_Count := 1;
         else
            Item.Owed_Count :=
              Natural'Max (Item.Owed_At + Item.Owed_Count,
                           Natural (Reserved) + 1)
              - Item.Owed_At;
         end if;
      end if;

      for Index in Source.Layers.all'Range loop
         if Deferred (Index) and then not Owing
           and then not Linear (Settings, Natural (Index))
         then
            declare
               At_Key : constant Element_Count :=
                 Keys_At (Item, Natural (Index))
                 + Cell_Of (Item, Natural (Index), Reserved) * KV_Width;

               At_Val : constant Element_Count :=
                 Values_At (Item, Natural (Index))
                 + Cell_Of (Item, Natural (Index), Reserved) * V_Width;

               Read : Boolean;
            begin
               --  Paged, the position is in the layer's pages, found
               --  through the page table as the settling reads them.
               if Item.Paged and then Item.Held = Exact then
                  Read_Pages_Layer
                    (Item, Natural (Index), KV_Width, V_Width,
                     Cell_Of (Item, Natural (Index), Reserved), 1, Read);
               elsif Item.Paged then
                  Read_Packed_Pages_Layer
                    (Item, Natural (Index), KV_Width, V_Width,
                     Cell_Of (Item, Natural (Index), Reserved), 1, Read);
               elsif Item.Held in Eighth | Fourth then
                  Read_Back_Packed
                    (Item, At_Key, At_Val, 1, KV_Width, V_Width, Read);
               else
                  Model_Runner.Backend.Device.Get_Cache
                    (Block_Base (Item) + At_Key,
                     Item.Keys.all (At_Key .. At_Key + KV_Width - 1), Read);

                  if Read then
                     Model_Runner.Backend.Device.Get_Cache
                       (Block_Base (Item) + Item.Keys.all'Length + At_Val,
                        Item.Values.all (At_Val .. At_Val + V_Width - 1),
                        Read);
                  end if;
               end if;

               if not Read then
                  Item.Current := Failed;
                  Status := E.Make (E.Backend_Closed);
                  return;
               end if;
            end;
         end if;
      end loop;
   end;

   if E.Is_Error (Status) then
      Item.Current := Failed;
      return;
   end if;

   --  The last layer's answer still on the device, for the head to
   --  read there. Where the device will not take the head after all,
   --  the answer comes home and the host goes on as it always did.
   if Carried then
      declare
         Done : Boolean;
         Back : Boolean;

         --  Where the bound is the only thing finishing the logits, the
         --  device takes it after the head rather than the host over
         --  every logit while the device waits.
         Cap_There : constant Boolean :=
           Settings.Logit_Cap > 0.0
           and then Source.Output_Bias = null
           and then Settings.Kind not in Granite | Granite_MoE | Command_R;
      begin
         Model_Runner.Backend.Device.Normalize_And_Project
           ([Source.Output], Item.Activation, Source.Output_Norm.all,
            Settings.Epsilon, [Row], Done,
            Cancel => Item.Stopping, Carry_In => True,
            Cap => (if Cap_There then Settings.Logit_Cap else 0.0));

         if Done then
            Charge (Item, Reading_Out, Mark);
            if Cap_There then
               goto Logits_Finished;
            end if;
            goto Logits_Made;
         end if;

         Model_Runner.Backend.Device.Fetch_Carried
           (Item.Activation.all, Back);
         if not Back then
            Item.Current := Failed;
            Status := E.Make (E.Backend_Device_Refused);
            return;
         end if;
      end;
   end if;

   Final_State (Source, Item.Activation.all, Item.Normalized.all);

   --  Kept for the block past the stack, where there is one.
   if Item.Last_Final /= null then
      Item.Last_Final.all := Item.Normalized.all;
      Item.Has_Final := True;
   end if;

   --  The output projection is the widest product of the token, so it is
   --  the one that most benefits from the pool. It writes into a
   --  session-owned row that is then copied into the caller's vector.
   Product
     (Item, Source.Output, Item.Normalized, Row, Status);
   if E.Is_Error (Status) then
      Item.Current := Failed;
      return;
   end if;

   Charge (Item, Reading_Out, Mark);

   <<Logits_Made>>

   Finish_Logits (Source, Row.all);

   <<Logits_Finished>>

   --  Commit: the position becomes readable context only now, after every
   --  layer of this token has succeeded.
   Item.History.all (Item.Committed) := Token;
   Item.Committed := Item.Committed + 1;
   Status := E.Success;
exception
   when others =>
      Item.Current := Failed;
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.evaluate");
end Evaluate_Token;
