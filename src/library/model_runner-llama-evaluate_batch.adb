separate (Model_Runner.Llama)
procedure Evaluate_Batch
  (Item   : in out Session;
   Source : Model'Class;
   Tokens : Model_Runner.Tokenizer.Token_Array;
   Logits : out Real_Array;
   States : T.Real_Array_Access := null;
   Every  : T.Real_Array_Access := null;
   Cancel : Model_Runner.Cancellation.Token_Reference := null;
   Given  : Given_Rows := No_Given_Rows;
   Status : out E.Error_Info)
is
   Settings  : constant Configuration := Source.Settings;
   Width     : constant Element_Count := Element_Count (Settings.Embedding);

   --  How many of the given rows each member has taken so far: one
   --  count for a batch, one a member for a round.
   Taken_By  : array (Element_Count range 0 .. 0) of Element_Count :=
     [others => 0];

   --  Where each position's run of given rows ends: a picture's rows
   --  attend to each other both ways, as the reference lets them, so a
   --  position inside one looks as far as the run's last position rather
   --  than to itself. A position outside any run looks to itself.
   Sees_To   : array (0 .. Element_Count (Tokens'Length) - 1)
                 of Element_Count;
   Has_Runs  : Boolean := False;
   --  Zero for a mixture of experts: the batch never holds a
   --  feed-forward activation there, because that block runs a position
   --  at a time through the session's own buffers. Jamba is the exception
   --  -- a mixture on some layers, a dense feed-forward on others -- and
   --  its dense layers run the batch through this buffer, so it is cut to
   --  the dense width rather than to nothing.
   Feed      : constant Element_Count :=
     (if Settings.Experts > 0
         and then not Is_Jamba (Settings.Kind)
         and then not Is_MLA (Settings.Kind)
      then 0
      else Element_Count (Settings.Feed_Forward));
   Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
   Value_Size : constant Element_Count :=
     Element_Count (Settings.Value_Size);
   Heads     : constant Element_Count := Element_Count (Settings.Heads);
   KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
   KV_Width  : constant Element_Count := KV_Heads * Head_Size;
   V_Width   : constant Element_Count := KV_Heads * Value_Size;
   Wide      : constant Element_Count := Heads * Head_Size;
   Blend     : constant Element_Count := Heads * Value_Size;
   Reserved  : constant Element_Count := Element_Count (Item.Committed);
   Count     : constant Element_Count := Element_Count (Tokens'Length);

   --  Which member each row belongs to, and how far into that member's
   --  own share it sits.
   --
   --  A round's rows are pairs of a member and a position, and nothing
   --  else about them follows from the row number: one member may
   --  contribute a single token while another reads a prompt. The pairs
   --  are written down rather than derived, which is what lets one
   --  procedure answer for a batch, for a decode round and for a round
   --  with a prompt in it.
   Row_Owner : constant array (0 .. Element_Count'Max (Count, 1) - 1)
     of Element_Count := [others => 0];

   --  Whether a token is one the given rows stand behind: the set's
   --  token, or its second where it has one.
   function Stands_Behind
     (Token : Token_Id; Mine : Given_Rows) return Boolean
   is (Token = Mine.Token
       or else (Mine.Second /= Model_Runner.Tokenizer.No_Token
                and then Token = Mine.Second));

   --  Where row Which sits in that session's cache.
   function Sits_At (Which : Element_Count) return Element_Count
   is (Reserved + Which);

   --  The lowest and the highest cell this call reads of a layer,
   --  over every row: one session's own for a batch, and for a round
   --  the widest of its rows -- each row has its own last in the
   --  table, the kernel takes its span from there, and what these are
   --  for is the engine's count of slices.
   function Lowest_Cell (Layer : Natural) return Element_Count;
   function Highest_Cell (Layer : Natural) return Element_Count;

   function Lowest_Cell (Layer : Natural) return Element_Count is
      Least : constant Element_Count :=
        Cell_Of (Item, Layer, Earliest (Settings, Reserved, Layer));
   begin
      return Least;
   end Lowest_Cell;

   function Highest_Cell (Layer : Natural) return Element_Count is
      Most : constant Element_Count :=
        Cell_Of (Item, Layer,
                 (if Settings.Causal then Reserved
                  else Reserved + Count - 1));
   begin
      return Most;
   end Highest_Cell;

   Scale     : constant Real := Score_Scale (Settings);

   --  Where the last phase boundary was, for a caller that asked for a
   --  budget. Read once at each boundary and moved there; see Charge.
   Mark : Ada.Real_Time.Time := Ada.Real_Time.Clock;

   --  One batch's activations. Held for the call rather than the session
   --  so that a session that never batches pays nothing for the option.
   Acts   : T.Real_Array_Access := null;
   Norm   : T.Real_Array_Access := null;

   --  What the block normalized on the way in, kept for the architecture
   --  that runs both of its sublayers from it. Null for the rest, which
   --  is what the block below reads.
   Kept_Norm : T.Real_Array_Access := null;
   Query  : T.Real_Array_Access := null;
   Keys   : T.Real_Array_Access := null;
   Values : T.Real_Array_Access := null;
   Attend : T.Real_Array_Access := null;
   Query_Full : T.Real_Array_Access := null;
   Gates  : T.Real_Array_Access := null;
   Gate   : T.Real_Array_Access := null;
   Up     : T.Real_Array_Access := null;

   --  Whether the last position's distribution was taken from the
   --  product over every row, so that the head is not read again.
   Took_Last : Boolean := False;

   --  A linear layer's projections over the batch, where the
   --  architecture has such layers: what its rule reads and what it
   --  leaves for the projection out.
   Mix_Rows   : T.Real_Array_Access := null;
   Z_Rows     : T.Real_Array_Access := null;
   Alpha_Rows : T.Real_Array_Access := null;
   Beta_Rows  : T.Real_Array_Access := null;
   Blend_Rows : T.Real_Array_Access := null;
   Mix_Wide    : constant Element_Count :=
     Element_Count (Mix_Width (Source.Settings));
   Value_Wide  : constant Element_Count :=
     Element_Count (Value_Width (Source.Settings));
   Value_Heads : constant Element_Count :=
     Element_Count (Source.Settings.Value_Heads);

   --  The angles this batch turns by, where a device does the turning: a
   --  cosine and the sine after it for each pair of each position, in
   --  the wide format the rotation keeps them in. Allocated only for the
   --  path that uses it.
   type Wide_Access is access N.Wide_Real_Array;

   procedure Forget is
     new Ada.Unchecked_Deallocation (N.Wide_Real_Array, Wide_Access);

   Angles : Wide_Access := null;

   --  The base the table in Angles was tabulated for, and a value no
   --  base takes so that the first layer of a batch always tabulates.
   --
   --  Everything the table depends on but the base is fixed for the
   --  whole of one call: the rotary width, the positions -- which start
   --  at Item.Committed and run to Count -- the scaling and the turns.
   --  So a batch tabulates once a base and not once a layer, and an
   --  architecture that states no local base states one base.
   Angles_Base : N.Wide_Real := -1.0;

   --  Whether the layer before this one left its answer on the device.
   --  False at the start of every batch: the first layer reads the
   --  embedding, which the host has.
   Carrying : constant Boolean := True;
   Deferring : constant Boolean := True;

   --  Whether any layer was kept off the whole road because the
   --  session has no block of the device's cache -- a context past
   --  what one storage buffer holds there is the usual reason, and it
   --  reads nothing like a shape the sequence will not take. Set by
   --  Has_Block below and read where the layer's outcome is noted.
   Blockless : Boolean := False;
   Carried : Boolean := False;

   --  Which layers left their keys and values in the device's cache
   --  without also sending them back through the result buffer. The
   --  host keeps its own copy of the cache for a session that later
   --  runs on the processor, and those layers' share of it is read out
   --  of the device once, after the batch, rather than a layer at a
   --  time while the batch is waiting on each of them.
   Deferred : array (Source.Layers.all'Range) of Boolean :=
     [others => False];

   --  Whether the session's ring is on the device and the runs'
   --  table says where this position goes in it, which every linear
   --  layer of this token then reads: sent and written once here,
   --  not once a layer, since the writing waits for the device.
   Linear_Ready : Boolean := False;
   Linear_Runs  : Natural := 1;

   --  Whether a layer is one the device takes whole. Asked of the next
   --  layer as well as of this one, because a layer that hands its
   --  answer on must know that the layer it hands to will be there to
   --  take it: one that falls back reads the host's copy, and the host's
   --  copy is what carrying does not write.
   --  A mixture layer goes whole where the device holds its expert
   --  stacks and nothing stands between the router and the experts
   --  that the device does not do -- as a token's does, and for a batch
   --  through the routing inverted and every expert run over the
   --  positions that chose it as one dispatch a matrix.
   --  A dense layer in a mixture's stack -- DeepSeek's first -- whose
   --  feed-forward is the plain one and goes whole as a dense model's.
   function Dense_Among_Experts (L : Layer) return Boolean
   is (L.Experts = null
       and then not T.Is_Present (L.Router)
       and then T.Is_Present (L.Up));

   function Mixture_Whole (L : Layer) return Boolean
   is ((Source.Stacked
        or else (Source.Split_Feed
                 and then Count >= Element_Count (Stream_Least)))
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
                <= Model_Runner.Backend.Device.Max_Route
         and then not Settings.Sigmoid_Gate);

   --  The next layer's expert stacks, copied to the device in the
   --  background while this layer runs, where the device streams them.
   procedure Prefetch_Next (Index : Natural) is
   begin
      if Source.Split_Feed
        and then not Source.Stacked
        and then Count >= Element_Count (Stream_Least)
        and then Index < Source.Layers.all'Last
        and then Mixture_Whole (Source.Layers.all (Index + 1))
      then
         Model_Runner.Backend.Device.Prefetch_Stacks
           (Source.Layers.all (Index + 1).Gate_Stack,
            Source.Layers.all (Index + 1).Up_Stack,
            Source.Layers.all (Index + 1).Down_Stack);
      end if;
   end Prefetch_Next;

   --  As the token's.
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

   --  A split dense model's layer whose feed-forward the processor holds,
   --  run whole on the device instead for a batch long enough that the
   --  upload is the lesser cost: its gate, up and down as the file holds
   --  them, uploaded for the batch and not kept (Stream_Feed). On the
   --  processor the panels take ThinkingCap's feed-forward at about half a
   --  millisecond a position a layer; uploaded, the device takes it at
   --  half that and the upload is a few hundredths of a second a batch.
   function Streams_Feed (L : Layer) return Boolean
   is (Source.Split_Feed
       and then Settings.Experts = 0
       and then L.Host_Feed
       and then Count
                >= Element_Count (Natural'Min (Stream_Least, Feed_Stream_Least))
       and then T.Is_Present (L.File_Gate)
       and then T.Is_Present (L.File_Up)
       and then T.Is_Present (L.File_Down));

   --  Whether the processor runs this layer's feed-forward for this batch.
   function Hosted (L : Layer) return Boolean
   is (L.Host_Feed and then not Streams_Feed (L));

   function Feed_Gate (L : Layer) return T.View
   is (if Streams_Feed (L) then L.File_Gate else L.Gate);

   function Feed_Up (L : Layer) return T.View
   is (if Streams_Feed (L) then L.File_Up else L.Up);

   function Feed_Down (L : Layer) return T.View
   is (if Streams_Feed (L) then L.File_Down else L.Down);

   function Linear_Layer_Fits (L : Layer) return Boolean
   is (Linear_Front_Fits (L)
       and then not Hosted (L)
       and then (if Settings.Experts > 0 then Mixture_Whole (L)
                 else T.Is_Present (L.Up)));

   --  As the token's: a dense layer gated or not, a mixture where the
   --  device holds its stacks, the normalizations as the architecture
   --  arranges them and centred all or none, and a hybrid's attention
   --  layers but not its linear ones.
   function Front_Fits (L : Layer; Index : Natural) return Boolean
   is (True
       and then not Linear (Settings, Index)
       and then (not Hybrid (Settings.Kind)
                 or else (Settings.Value_Size = Settings.Head_Size
                          and then L.Query_Bias = null))
       --  A layer with sinks goes on the device where the cache holds a
       --  slot for it at this layer's place, a slot a layer so a batch
       --  that chains does not land every layer's sinks on the last's;
       --  the ones past the room go to the host, as a single token's do.
       and then Sinks_Fit (L.Sinks, Index)
       and then (L.Attention_Norm /= null)
                = not Normalizes_After (Settings.Kind)
       and then (not Normalizes_After (Settings.Kind)
                 or else (L.Post_Attention_Norm /= null
                          and then L.Post_Feed_Norm /= null))
       and then Norms_Agree (L)
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

       --  The attention projections' biases go as steps of the
       --  sequence, all three or none, as the token's whole layer
       --  takes them.
       and then (L.Query_Bias = null) = (L.Key_Bias = null)
       and then (L.Query_Bias = null) = (L.Value_Bias = null)

       --  A head normalization goes to the device, both or neither,
       --  as the token's whole layer takes them.
       and then (L.Query_Norm = null) = (L.Key_Norm = null));

   --  A layer goes whole where its front half does and the device takes
   --  its feed-forward too: a mixture whose stacks it holds, or a dense
   --  feed-forward, whose biases -- and a mixture's post-norm -- are
   --  steps of the sequence.
   function Whole_Layer_Fits (L : Layer; Index : Natural) return Boolean
   is ((if Settings.Experts > 0 and then not Dense_Among_Experts (L)
        then Mixture_Whole (L)
        else T.Is_Present (L.Up))
       and then Front_Fits (L, Index)
       and then not Hosted (L)
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

   --  A layer whose front half goes to the device and whose feed-forward
   --  the processor runs: a mixture the device does not hold, in a model
   --  whose everything else it does (Split_Feed), arranged the plain way
   --  -- a normalization before the feed-forward, joined after it.
   function Split_Here (L : Layer) return Boolean
   is (Source.Split_Feed
       and then ((L.Experts /= null and then not Mixture_Whole (L))
                 or else Hosted (L))
       and then L.Feed_Norm /= null
       and then not Normalizes_After (Settings.Kind)
       and then not Settings.Parallel_Residual
       and then L.Second_Attention_Norm = null);

   --  Whether the session holds a block of the device's cache, taking
   --  one where it may: what the whole layer writes its keys and
   --  values into, asked before the layer is committed to it.
   function Has_Block (Of_Item : Session_Access) return Boolean is
      Held : Boolean;
   begin
      Take_Block (Of_Item, Held);

      Blockless := Blockless or else not Held;
      return Held;
   end Has_Block;

   procedure Release is
   begin
      T.Free (Acts);
      T.Free (Norm);
      T.Free (Kept_Norm);
      T.Free (Query);
      T.Free (Keys);
      T.Free (Values);
      T.Free (Attend);
      T.Free (Query_Full);
      T.Free (Gates);
      T.Free (Gate);
      T.Free (Up);
      T.Free (Mix_Rows);
      T.Free (Z_Rows);
      T.Free (Alpha_Rows);
      T.Free (Beta_Rows);
      T.Free (Blend_Rows);
      Forget (Angles);
   end Release;

   --  Slice of a batch buffer belonging to one token of the batch.
   function Slot
     (Which : Element_Count; Stride : Element_Count) return Element_Count
   is (Which * Stride);
begin
   Logits := [others => 0.0];

   --  As in Evaluate: where the products can reach it, set on the way in
   --  by every entry point that reaches one.
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

   --  A prompt on the device: the part has likely been idle and at its
   --  lowest clock, which a short prompt is over before it climbs out
   --  of. A round's few positions are not a prompt, and a keeper beside
   --  a token's work costs it.
   if Count >= Prompt_Clock_Least
     and then Model_Runner.Backend."="
                (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
   then
      Model_Runner.Backend.Device.Hold_Clock;
   end if;

   --  More than one token at a time is a thing the backend either does or
   --  does not. One at a time is the same call with Count of one, so only
   --  a real batch has to ask.
   if Count > 1 and then not Source.Able.Supports_Batched then
      Status := E.Make (E.Backend_Capability_Missing);
      E.Add_Text (Status, "capability", "batched", E.Param_Identifier);
      E.Add_Text
        (Status, "backend",
         Model_Runner.Backend.Backend_Name (Source.Able.Kind),
         E.Param_Identifier);
      return;
   end if;

   --  How many positions may come in one call. A causal model takes the
   --  batch this file bounds the working set at, because a longer prompt
   --  is the same answer in more calls. A model that attends both ways
   --  has no such freedom: position zero has to see the last position of
   --  the text in the same pass, so the whole text is the batch and the
   --  bound is the context.
   declare
      Limit : constant Element_Count :=
        (if Settings.Causal
         then Element_Count (Batch_Limit (Source))
         else Element_Count (Settings.Context_Length));
   begin
      --  A causal model handed more than the batch bound is a caller
      --  asking for a shape this does not evaluate, and a shape mismatch
      --  is what that is. A model that attends both ways handed more
      --  than its context is something else: the text does not fit the
      --  model, which is an ordinary thing for a caller to do and not a
      --  shape they got wrong. Saying "mismatched shapes" to somebody
      --  who embedded a long document tells them nothing they can act
      --  on.
      if Count = 0 or else Count > Limit then
         if Count > Limit and then not Settings.Causal then
            Status := E.Make (E.Arch_Context_Too_Large);
            E.Add_Integer
              (Status, "requested", Long_Long_Integer (Count),
               E.Param_Tokens);
            E.Add_Integer
              (Status, "maximum", Long_Long_Integer (Limit),
               E.Param_Tokens);
         else
            Status := E.Make (E.Tensor_Shape_Mismatch);
            E.Add_Integer (Status, "input", Long_Long_Integer (Count));
            E.Add_Integer (Status, "limit", Long_Long_Integer (Limit));
         end if;
         return;
      end if;
   end;

   --  And it has to be the whole text. A second batch into a cache that
   --  already holds positions would attend to what is there and be
   --  invisible to it: the first half would have been computed without
   --  the second, which is exactly the answer a bidirectional model is
   --  not. Refused rather than split, because what comes back from a
   --  split is an embedding, plausible in every respect, of a text the
   --  model never read whole.
   if not Settings.Causal and then Item.Committed > 0 then
      Status := E.Make (E.Arch_Text_Not_Whole);
      E.Add_Text
        (Status, "architecture", Architecture_Name (Settings.Kind),
         E.Param_Identifier);
      E.Add_Integer
        (Status, "count", Long_Long_Integer (Item.Committed),
         E.Param_Tokens);
      return;
   end if;

   for Token of Tokens loop
      if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Token) then
         Status := E.Make (E.Tokenizer_Invalid_Token_Id);
         E.Add_Integer (Status, "token", Long_Long_Integer (Token));
         E.Add_Integer
           (Status, "vocabulary", Long_Long_Integer (Settings.Vocabulary));
         return;
      end if;
   end loop;

   --  Room for what this pass will add. A batch adds its whole length to
   --  one session; a round adds one position to each of its members, and
   --  a member with no room left is the round refused rather than that
   --  member quietly writing past its cache.
   for Which in 0 .. Count - 1 loop
      if Sits_At (Which) + (Count - Which)
           > Element_Count (Item'Unchecked_Access.Context)
      then
         Status := E.Make (E.Generation_Context_Exhausted);
         E.Add_Integer
           (Status, "capacity",
            Long_Long_Integer (Item'Unchecked_Access.Context), E.Param_Tokens);
         return;
      end if;
   end loop;

   --  What a caller may ask a headless model for is states. A
   --  distribution is refused by name, and an empty Logits is how a
   --  caller says they are not asking for one -- the alternative is a row
   --  of zeros that looks like a distribution and is not.
   if not Settings.Has_Head then
      if Logits'Length /= 0 or else Every /= null then
         Status := E.Make (E.Arch_No_Output_Head);
         E.Add_Text
           (Status, "architecture", Architecture_Name (Settings.Kind),
            E.Param_Identifier);
         return;
      end if;

   elsif Logits'Length /= Element_Count (Settings.Vocabulary) then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      E.Add_Integer (Status, "output", Long_Long_Integer (Logits'Length));
      return;
   end if;

   T.Allocate (Count * Width, Acts);
   T.Allocate (Count * Width, Norm);

   if Source.Settings.Kind in Falcon | Phi2 | Command_R then
      T.Allocate (Count * Width, Kept_Norm);
   end if;
   T.Allocate (Count * Wide, Query);
   if Hybrid (Settings.Kind) then
      T.Allocate (Count * 2 * Wide, Query_Full);
      T.Allocate (Count * Wide, Gates);
      T.Allocate (Count * Mix_Wide, Mix_Rows);
      T.Allocate (Count * Value_Wide, Z_Rows);
      T.Allocate (Count * Value_Heads, Alpha_Rows);
      T.Allocate (Count * Value_Heads, Beta_Rows);
      T.Allocate (Count * Value_Wide, Blend_Rows);
   end if;
   T.Allocate (Count * KV_Width, Keys);
   T.Allocate (Count * V_Width, Values);
   T.Allocate (Count * Blend, Attend);
   T.Allocate (Count * Feed, Gate);
   T.Allocate (Count * Feed, Up);

   if Acts = null or else Norm = null or else Query = null
     or else Keys = null or else Values = null or else Attend = null
     or else ((Gate = null or else Up = null) and then Feed > 0)
   then
      Release;
      Status := E.Make (E.Memory_Allocation_Failed);
      E.Add_Text (Status, "category", "batch_activations", E.Param_Identifier);
      return;
   end if;

   --  The runs of given rows, each looking to its own end.
   for Which in 0 .. Count - 1 loop
      Sees_To (Which) := Which;
   end loop;
   declare
      Which : Element_Count := 0;
   begin
      while Which < Count loop
         declare
            Mine : constant Given_Rows := Given;
         begin
            if Mine.Rows /= null
              and then not Mine.Causal
              and then Mine.Token /= Model_Runner.Tokenizer.No_Token
              and then Stands_Behind
                         (Tokens (Tokens'First + Natural (Which)), Mine)
            then
               declare
                  Ends : Element_Count := Which;
               begin
                  --  A run ends with its member's rows: two members'
                  --  pictures side by side in a round are two runs.
                  while Ends + 1 < Count
                    and then Row_Owner (Ends + 1) = Row_Owner (Which)
                    and then Stands_Behind
                               (Tokens (Tokens'First + Natural (Ends + 1)),
                                Mine)
                  loop
                     Ends := Ends + 1;
                  end loop;
                  for Inside in Which .. Ends loop
                     Sees_To (Inside) := Ends;
                  end loop;
                  Has_Runs := Has_Runs or else Ends > Which;
                  Which := Ends + 1;
               end;
            else
               Which := Which + 1;
            end if;
         end;
      end loop;
   end;

   --  Embedding lookup for every token of the batch -- or the row given
   --  for it, which stands as it is: the scale a model applies to its
   --  own embedding is not applied to a row that was never one.
   for Which in 0 .. Count - 1 loop
      declare
         Origin : constant Element_Count := Slot (Which, Width);
         Token  : constant Token_Id :=
           Tokens (Tokens'First + Natural (Which));
      begin
         if Given.Rows /= null
           and then Stands_Behind (Token, Given)
         then
            declare
               Mine   : constant Given_Rows := Given;
               Taken  : Element_Count renames Taken_By (Row_Owner (Which));
               Row_At : constant Element_Count :=
                 (Mine.First + Taken) * Width;
            begin
               if Row_At + Width > Mine.Rows.all'Length then
                  Status := E.Make (E.Tensor_Out_Of_Bounds);
                  E.Add_Integer
                    (Status, "index", Long_Long_Integer (Mine.First + Taken));
               else
                  Acts.all (Origin .. Origin + Width - 1) :=
                    Mine.Rows.all (Row_At .. Row_At + Width - 1);

                  --  Where the row stands in its picture, for a
                  --  rotation whose positions have three parts; a row
                  --  with no place given stands where a text token
                  --  would.
                  if Mine.Places /= null
                    and then Mine.First + Taken in Mine.Places.all'Range
                  then
                     Set_Mark
                       (Item'Unchecked_Access.all, Natural (Sits_At (Which)),
                        Mine.Places.all (Mine.First + Taken), True);
                  else
                     Set_Mark (Item'Unchecked_Access.all, Natural (Sits_At (Which)));
                  end if;
                  Taken := Taken + 1;
               end if;
            end;
         else
            Set_Mark (Item'Unchecked_Access.all, Natural (Sits_At (Which)));
            T.Dequantize_Row
              (Source.Embeddings, Element_Count (Token),
               Acts.all (Origin .. Origin + Width - 1), Status);

            if Embedding_Scale (Source) /= 1.0 then
               for Value of Acts.all (Origin .. Origin + Width - 1) loop
                  Value := Value * Embedding_Scale (Source);
               end loop;
            end if;
         end if;

         --  As in the single-token path: where the token is, added to
         --  what it is. Its position is the committed count plus its
         --  place in this batch.
         if Source.Settings.Kind in GPT2 | Bert then
            T.Dequantize_Row
              (Source.Positions,
               Element_Count (Item.Committed) + Which,
               Item.Normalized.all, Status);

            if E.Is_Ok (Status) then
               K.Add (Acts.all (Origin .. Origin + Width - 1),
                      Item.Normalized.all);
            end if;
         end if;

         --  And which segment it belongs to, which is the first of them
         --  for every position of a text embedded here. The row is the
         --  same for all of them and is read once a position rather than
         --  once: a row is a decode of the file's own bytes, and hoisting
         --  it would mean a second buffer to hold it in.
         if E.Is_Ok (Status) and then Source.Settings.Segments > 0 then
            T.Dequantize_Row
              (Source.Segments, 0, Item.Normalized.all, Status);

            if E.Is_Ok (Status) then
               K.Add (Acts.all (Origin .. Origin + Width - 1),
                      Item.Normalized.all);
            end if;
         end if;

         --  Bert normalizes the sum of the three before layer zero sees
         --  it. Written here rather than as the first thing a layer does,
         --  because it happens once for the whole model and not once a
         --  layer, and because the tensor it uses belongs to the
         --  embedding rather than to any block.
         if E.Is_Ok (Status) and then Source.Embedding_Norm /= null then
            Normalize
              (Source, Acts.all (Origin .. Origin + Width - 1),
               Source.Embedding_Norm.all, Source.Embedding_Norm_Bias,
               Item.Normalized.all);
            Acts.all (Origin .. Origin + Width - 1) :=
              Item.Normalized.all;
         end if;

         if E.Is_Error (Status) then
            Release;
            Item.Current := Failed;
            return;
         end if;
      end;
   end loop;

   --  Room for what this pass will add, in the layers that slide a
   --  window. A round's rows are different sessions at different
   --  positions, so each is asked for its own.
   for Which in 0 .. Count - 1 loop
      Make_Room (Item'Unchecked_Access.all, Settings, Sits_At (Which));
   end loop;

   --  Every member's ring over, and the runs' table: one run a
   --  member, its rows one after another, where a batch is one run.
   --  Not for a batch with a picture's rows in it, which attends on
   --  the host.
   if Hybrid (Settings.Kind)
     and then Item.Delta_State /= null
     and then Count > 0
     and then not Has_Runs
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind,
                 Model_Runner.Backend.Backend_Device)
     and then Model_Runner.Backend.Device.Runs_Linear
   then
      declare
         Runs  : State_Runs (1 .. Natural (Count));
         Many  : Natural := 0;
         Start : Element_Count := 0;
      begin
         Linear_Ready := True;

         while Start < Count loop
            declare
               Owner  : constant Element_Count := Row_Owner (Start);
               Finish : Element_Count := Start;
               Sent   : Boolean;
            begin
               while Finish + 1 < Count
                 and then Row_Owner (Finish + 1) = Owner
               loop
                  Finish := Finish + 1;
               end loop;

               Send_States (Item'Unchecked_Access, Sent);
               Linear_Ready := Linear_Ready and then Sent;

               Many := Many + 1;
               Runs (Many) :=
                 (Whose => Item'Unchecked_Access,
                  First => Natural (Sits_At (Start)),
                  Count => Natural (Finish - Start + 1),
                  Row   => Natural (Start));
               Start := Finish + 1;
            end;
         end loop;

         if Linear_Ready then
            Write_Runs (Runs (1 .. Many), Linear_Ready);
         end if;
         Linear_Runs := Many;
      end;
   end if;

   for Index in Source.Layers.all'Range loop
      --  A dense layer whose feed-forward the processor runs reads its
      --  products there; every other runs where it always has.
      if Source.Split_Feed and then Settings.Experts = 0 then
         Item.Host_Feed := Hosted (Source.Layers.all (Index));
      end if;

      if C.Is_Cancelled (Cancel) then
         --  Nothing was committed, so the cache still describes exactly
         --  the context that was valid before this call.
         Release;
         Status := E.Make (E.Generation_Cancelled);
         return;
      end if;

      declare
         Current : Layer renames Source.Layers.all (Index);
         Base    : constant Element_Count :=
           Keys_At (Item, Natural (Index));
         Rows_Base : constant Element_Count :=
           Rows_At (Item, Natural (Index));
         V_Base  : constant Element_Count :=
           Values_At (Item, Natural (Index));

         --  Where a paged batch's page table for the layer was written,
         --  and whether it reached the device: a round reads its per-row
         --  table instead, so this is for a single session's batch.
         Paged_Table_At : Element_Count := 0;

         --  Whether this batch's positions reached the device's cache,
         --  set as they are written and read where they are attended to,
         --  which is a loop later.
         Resident : Boolean := False;

         --  Whether a device took the normalization and the three
         --  matrices that read it as one sequence, and whether it turned
         --  the queries and the keys while it had them.
         Grouped   : Boolean := False;
         Projected : Boolean := False;
         Rotated   : Boolean := False;

         --  And whether the whole layer went over as one sequence, which
         --  is the two halves and everything the host did between them.
         Whole_Layer_Done : Boolean := False;

         --  Whether the device takes this layer's front half alone, the
         --  feed-forward the processor's (Split_Here), and whether it did.
         Half      : Boolean := False;
         Half_Done : Boolean := False;
         Cached           : Boolean := False;

         --  And whether the whole of the layer's second half went over
         --  as one sequence, as it does when a single position is
         --  generated: attention, its projection, the join, the
         --  normalization, the feed-forward and the join after it.
         --  Every step below is then already done.
         Fused : Boolean := False;

         --  Whether the device was asked for this layer at all, so
         --  that a layer the engine kept back is told apart from a
         --  layer the device refused; and whether the whole of it went
         --  over when it was asked. Noted at the layer's end.
         Asked      : Boolean := False;
         Went_Whole : Boolean := False;

         --  And the one reason the engine knows and the device cannot:
         --  that this session has no block of the device's cache,
         --  which Has_Block finds while the layer's road is chosen and
         --  so is read where the outcome is noted rather than here.
         No_Block   : Boolean := False;

         --  Set when a device took the whole gated feed-forward, its
         --  projection down included, so that the common tail does not
         --  project it a second time.
         Whole_Block : Boolean := False;

         --  Whether this layer is one of a hybrid's linear ones, which
         --  attends through its state a position at a time below and
         --  takes the batch's feed-forward as every layer does.
         Is_Linear : constant Boolean :=
           Linear (Settings, Natural (Index));

         --  Five of this block's loops over the batch go to the worker
         --  pool. They are elementwise: a position's normalization and
         --  its residual join read and write that position's own slice
         --  and no other's, so a share of the batch is the same
         --  arithmetic in the same order and the answer is bit for bit
         --  what one task produced. Twenty-two per cent of a device
         --  prompt was here, on one core, while the pool that computes
         --  its attention a few lines below sat idle.
         --
         --  Not the rotation, which is the sixth such loop: it writes
         --  the key and value cache, and on a device that is a call
         --  through an engine that is one task's to use.
         --
         --  Below a batch of sixteen the pool is not asked. A share is a
         --  protected round trip a worker, and a token at a time would
         --  pay for that and have nothing to divide.
         Team : constant Workers_CPU.Pool_Reference :=
           (if Count >= 16 then Item.Team else null);

         type Norm_Share is limited new Workers_CPU.Task_Item with
            null record;

         overriding procedure Run
           (Share : in out Norm_Share;
            From  : Element_Count;
            To    : Element_Count);

         overriding procedure Run
           (Share : in out Norm_Share;
            From  : Element_Count;
            To    : Element_Count)
         is
            pragma Unreferenced (Share);
         begin
            if From > To then
               return;
            end if;

            for Which in From .. To loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  Normalize
                    (Source, Acts.all (Origin .. Origin + Width - 1),
                     Current.Attention_Norm.all,
                     Current.Attention_Norm_Bias,
                     Norm.all (Origin .. Origin + Width - 1));
               end;
            end loop;
         end Run;

         --  The residual joins need scratch where the architecture
         --  normalizes on the way out of a sublayer, and the session's
         --  single row of it is what stopped this being shared out:
         --  every position wrote through the same one. A share takes its
         --  own for as long as it runs, and only where there is a
         --  normalization to do -- Post_Norm returns at once when the
         --  layer has none, which is every llama, so the common case
         --  allocates nothing.
         type Join_Share is limited new Workers_CPU.Task_Item with
            record
               After : Boolean := False;
               Ok    : Boolean := True;
            end record;

         overriding procedure Run
           (Share : in out Join_Share;
            From  : Element_Count;
            To    : Element_Count);

         overriding procedure Run
           (Share : in out Join_Share;
            From  : Element_Count;
            To    : Element_Count)
         is
            Room : T.Real_Array_Access := null;

            --  The layer's input, kept across the attention join for
            --  the code variant of jina-bert-v2 and allocated for it
            --  alone.
            Kept : T.Real_Array_Access := null;
         begin
            if From > To then
               return;
            end if;

            if Item.Post_Room /= null then
               T.Allocate (Width, Room);
               if Room = null then
                  Share.Ok := False;
                  return;
               end if;
            end if;

            if Current.Second_Attention_Norm /= null
              or else Source.Settings.Parallel_Residual
            then
               T.Allocate (Width, Kept);
               if Kept = null then
                  T.Free (Room);
                  Share.Ok := False;
                  return;
               end if;
            end if;

            for Which in From .. To loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  if Share.After then
                     Join_Residual
                       (Source,
                        Norm.all (Origin .. Origin + Width - 1),
                        Acts.all (Origin .. Origin + Width - 1),
                        Current.Post_Feed_Norm,
                        Current.Post_Feed_Norm_Bias,
                        Room);
                  else
                     --  The code variant reads the layer's input once
                     --  more after the join, and a parallel-residual block
                     --  feeds its feed-forward from it, so it is kept here
                     --  before the join writes the residual over it.
                     if Current.Second_Attention_Norm /= null
                       or else Source.Settings.Parallel_Residual
                     then
                        Kept.all := Acts.all (Origin .. Origin + Width - 1);
                     end if;
                     Join_Residual
                       (Source,
                        Norm.all (Origin .. Origin + Width - 1),
                        Acts.all (Origin .. Origin + Width - 1),
                        Current.Post_Attention_Norm,
                        Current.Post_Attention_Norm_Bias,
                        Room);
                     if Current.Second_Attention_Norm /= null then
                        Join_Again
                          (Source, Acts.all (Origin .. Origin + Width - 1),
                           Kept.all, Current, Room);
                     end if;

                     --  What the feed-forward reads: the block's own
                     --  normalized input where the two sublayers run in
                     --  parallel, the residual as it stands where the
                     --  block normalized it on the way out, and a fresh
                     --  normalization of the residual where they run one
                     --  after the other.
                     --  Nothing where no feed-forward follows: Mamba's
                     --  block and RWKV6's two mixes are the whole layer.
                     if Pure_SSM (Source.Settings.Kind)
                       or else Is_RWKV (Source.Settings.Kind)
                     then
                        null;
                     elsif Normalizes_After (Source.Settings.Kind) then
                        Norm.all (Origin .. Origin + Width - 1) :=
                          Acts.all (Origin .. Origin + Width - 1);
                     elsif Current.Feed_Norm /= null then
                        --  A parallel-residual block feeds from the
                        --  layer's input, kept above; a sequential one
                        --  from the residual the attention was added to.
                        Normalize
                          (Source,
                           (if Source.Settings.Parallel_Residual
                            then Kept.all
                            else Acts.all (Origin .. Origin + Width - 1)),
                           Current.Feed_Norm.all, Current.Feed_Norm_Bias,
                           Norm.all (Origin .. Origin + Width - 1));
                     elsif Current.Attention_Norm /= null then
                        Norm.all (Origin .. Origin + Width - 1) :=
                          Kept_Norm.all (Origin .. Origin + Width - 1);
                     else
                        --  OLMo2: no normalization before the
                        --  feed-forward, which reads the post-attention
                        --  residual as it stands.
                        Norm.all (Origin .. Origin + Width - 1) :=
                          Acts.all (Origin .. Origin + Width - 1);
                     end if;
                  end if;
               end;
            end loop;

            T.Free (Room);
            T.Free (Kept);
         end Run;

         --  And the fifth, which was the largest of them and the last to
         --  be noticed. The feed-forward's activation and the multiply
         --  that follows it walk a position's whole inner width -- five
         --  thousand six hundred and thirty-two numbers for this model --
         --  and a batch of five hundred and twelve of them ran on one
         --  core while seven waited. Sorted by thread, a profile of a
         --  1419-token prompt put `silu` and `multiply` on the main task
         --  and on no worker at all: 1.18 and 0.59 per cent of the
         --  samples collected, which at 35.66 seconds of processor time
         --  is about 0.63 seconds of a 5.93-second prompt spent on a
         --  machine that has eight cores and was using one.
         --
         --  Elementwise like the three above it, and shared out the same
         --  way: a position's slice is read and written by that position
         --  and no other, so a share is the same arithmetic in the same
         --  order and the answer is bit for bit what one task produced.
         type Feed_Share is limited new Workers_CPU.Task_Item with
            record
               --  Whether there is an up projection to multiply in, or
               --  only the unit and the bias before it.
               Both : Boolean := True;
            end record;

         overriding procedure Run
           (Share : in out Feed_Share;
            From  : Element_Count;
            To    : Element_Count);

         overriding procedure Run
           (Share : in out Feed_Share;
            From  : Element_Count;
            To    : Element_Count) is
         begin
            if From > To then
               return;
            end if;

            for Which in From .. To loop
               declare
                  Origin : constant Element_Count := Slot (Which, Feed);
               begin
                  if Share.Both then
                     Gate_Activation
                       (Source, Gate.all (Origin .. Origin + Feed - 1));
                     K.Multiply
                       (Gate.all (Origin .. Origin + Feed - 1),
                        Up.all (Origin .. Origin + Feed - 1));
                  else
                     --  Before the unit, as in the single-token path.
                     if Current.Up_Bias /= null then
                        K.Add (Gate.all (Origin .. Origin + Feed - 1),
                               Current.Up_Bias.all);
                     end if;

                     Gate_Activation
                       (Source, Gate.all (Origin .. Origin + Feed - 1));
                  end if;
               end;
            end loop;
         end Run;
      begin
         --  What the block is given. Every architecture here normalizes
         --  on the way in except Bert, whose block reads the residual as
         --  it stands -- the normalization it has was applied on the way
         --  out of the block before this one.
         --  Where a device takes the normalization together with the
         --  three matrices that read it, none of this happens here: the
         --  layer's input goes over as it stands and what comes back is
         --  the queries, the keys and the values.
         Projected := False;

         --  A Mamba2 layer whole on the device, as the token's: one
         --  session's rows, carried on to the next layer where that one
         --  goes too.
         if Mamba2_Fits (Item, Current)
           and then not Has_Runs
           and then Row_Owner (0) = Row_Owner (Count - 1)
         then
            declare
               Out_Too : constant Boolean :=
                 Carrying
                 and then Index < Source.Layers.all'Last
                 and then Layer_Fits (Source.Layers.all (Index + 1),
                                      Natural (Index) + 1);
               Seated  : Boolean;
               Ran     : Boolean := False;
               Back    : Boolean;
            begin
               Send_States (Item'Unchecked_Access, Seated);
               if Seated then
                  Asked := True;
                  Model_Runner.Backend.Device.Mamba2_Layer
                    (Mamba2_Block_Of (Item, Current, Natural (Index), True),
                     Acts.all (0 .. Count * Width - 1), Count,
                     Acts.all (0 .. Count * Width - 1), Ran,
                     Item.Stopping, Carry_In => Carried,
                     Carry_Out => Out_Too);
               end if;

               if Ran then
                  Went_Whole := True;
                  Carried := Out_Too;
                  goto Mamba_Done_Batch;
               end if;

               if Carried then
                  Model_Runner.Backend.Device.Fetch_Carried
                    (Acts.all (0 .. Count * Width - 1), Back);
                  Carried := False;
                  if not Back then
                     Release;
                     Item.Current := Failed;
                     Status := E.Make (E.Backend_Device_Refused);
                     return;
                  end if;
               end if;
            end;
         end if;

         --  The normalization and the three matrices that read it, as
         --  one sequence. A round takes this: it names no cache and no
         --  run of positions -- it reads the layer's input, normalizes
         --  each row, multiplies the batch by three matrices and turns
         --  the queries and keys by angles the caller tabulates a row at
         --  a time. Every one of those is already a row at a time.
         --
         --  What a round does not take is Whole_Layer below, which does
         --  name a cache and a run of positions, and is refused a round
         --  where it is chosen rather than here.
         --  The front half alone -- the normalization and the three
         --  projections -- is a shape the device takes only where the
         --  normalization is by root mean square, the feed-forward has
         --  its own and the two halves run one after the other. A head
         --  normalization, or a projection's bias, a centred
         --  normalization, a parallel or a post-normalizing layer, is
         --  a step of the whole layer and of nothing else here: such
         --  a layer goes whole or goes to the host, which is what the
         --  fallback below keeps to.
         --  A hybrid's linear layer whole on the device, as the
         --  token's: the ring goes over once and comes home when the
         --  host is about to read it. Not for a round, whose rows
         --  are different sessions' and would take turns with the
         --  one ring the device holds, and not for a batch with a
         --  picture's rows in it.
         if Model_Runner.Backend."="
              (Item.Owner.Able.Kind,
               Model_Runner.Backend.Backend_Device)
           and then Is_Linear
           and then (Linear_Layer_Fits (Current)
                     or else (Split_Here (Current)
                              and then Linear_Front_Fits (Current)))
         then
            Half := not Linear_Layer_Fits (Current);

            declare
               Sent : constant Boolean := Linear_Ready;
               Back : Boolean;
            begin
               if not Sent and then Carried then
                  Model_Runner.Backend.Device.Fetch_Carried
                    (Acts.all (0 .. Count * Width - 1), Back);
                  Carried := False;
                  if not Back then
                     Release;
                     Item.Current := Failed;
                     Status := E.Make (E.Backend_Device_Refused);
                     return;
                  end if;
               end if;

               if Sent then
                  Asked := True;
                  Prefetch_Next (Natural (Index));
                  if Half and then Source.Split_Feed
                    and then Workers_CPU."/=" (Item.Team, null)
                  then
                     Workers_CPU.Rouse (Item.Team.all);
                  end if;
                  Model_Runner.Backend.Device.Whole_Layer
                    (Acts.all (0 .. Count * Width - 1),
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
                     Feed_Gate (Current), Feed_Up (Current),
                     Feed_Down (Current),
                     Gate_Unit (Source),
                     Keys, Values, Acts, Whole_Layer_Done,
                     Positions => Natural (Count),
                     Stream_Feed => Streams_Feed (Current),
                     Cancel    => Item.Stopping,
                     Carry_In  => Carried,
                     Mirror    => False,
                     Carry_Out =>
                       not Half
                       and then Carrying
                       and then Index < Source.Layers.all'Last
                       and then Layer_Fits
                                  (Source.Layers.all (Index + 1),
                                   Natural (Index) + 1),
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
                       (if Settings.Experts > 0 then Current.Expert_Up_Bias
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
                       Linear_Shape_Of (Item, Natural (Index),
                                        Linear_Runs),
                     Linear_State_At =>
                       Linear_State_At (Item, Natural (Index)),
                     No_Feed   => Half);
                  Half_Done := Half and then Whole_Layer_Done;
                  if Half_Done then
                     Whole_Layer_Done := False;
                  end if;
                  Went_Whole := Whole_Layer_Done;

                  --  A streamed feed-forward the device would not take:
                  --  the layer's own views are the processor's panels, so
                  --  the rest of it is the processor's too.
                  if not Whole_Layer_Done and then Streams_Feed (Current)
                  then
                     Item.Host_Feed := True;
                  end if;
               end if;
            end;

            Deferred (Index) :=
              Deferring and then (Whole_Layer_Done or else Half_Done);

            if Half_Done then
               --  The front half only: each member's ring reached the
               --  end of its rows on the device, and the host runs the
               --  feed-forward.
               for Which in 0 .. Count - 1 loop
                  Item'Unchecked_Access.Kept_Newest :=
                    Natural'Max (Item'Unchecked_Access.Kept_Newest,
                                 Natural (Sits_At (Which)) + 1);
               end loop;
               Carried := False;
               goto Front_Done_Batch;
            end if;

            Carried :=
              Carrying
              and then Whole_Layer_Done
              and then Index < Source.Layers.all'Last
              and then Layer_Fits
                         (Source.Layers.all (Index + 1),
                          Natural (Index) + 1);

            if Whole_Layer_Done then
               --  Each member's ring reaches to the end of its rows.
               for Which in 0 .. Count - 1 loop
                  Item'Unchecked_Access.Kept_Newest :=
                    Natural'Max (Item'Unchecked_Access.Kept_Newest,
                                 Natural (Sits_At (Which)) + 1);
               end loop;
               Projected := True;
               Rotated := True;
               Fused := True;
               Cached := True;
            end if;
         end if;

         if Model_Runner.Backend."="
              (Item.Owner.Able.Kind,
               Model_Runner.Backend.Backend_Device)
           and then not Is_Linear
           and then ((Current.Attention_Norm /= null
                      and then Current.Attention_Norm_Bias = null
                      and then Current.Feed_Norm /= null
                      and then Current.Query_Norm = null
                      and then Current.Query_Bias = null
                      and then Source.Settings.Kind not in Falcon | Phi2 | Mpt | Command_R
                      and then Source.Settings.Max_Bias = 0.0)
                     or else (Item.Held in Exact | Eighth | Fourth
                              and then (Whole_Layer_Fits
                                          (Current, Natural (Index))
                                        or else (Split_Here (Current)
                                                 and then Front_Fits
                                                   (Current,
                                                    Natural (Index))))
                              --  A batch with its block, or a paged
                              --  batch whose pages the road takes
                              --  itself below.
                              and then (if Item.Paged then True
                                        else Has_Block
                                               (Item'Unchecked_Access))))
         then
            Charge (Item, Normalizing, Mark);

            --  The angles this batch turns by, tabulated here and turned
            --  by on the device. Everything an architecture varies about
            --  a rotation is in these two numbers a pair, so the kernel
            --  that applies them knows nothing about any architecture --
            --  see Kernels.Rotary_Table.
            declare
               Pairs : constant Element_Count :=
                 Element_Count (Settings.Rotary) / 2;

               Turnable : constant Boolean :=
                 Settings.Rotary > 0
                 and then Element_Count (Settings.Rotary) <= Head_Size
                 and then Element_Count (Settings.Rotary) mod 2 = 0;
            begin
               if Turnable then
                  if Angles = null
                    or else Angles.all'Length < Count * Pairs * 2
                  then
                     Forget (Angles);
                     Angles :=
                       new N.Wide_Real_Array (0 .. Count * Pairs * 2 - 1);

                     --  Room that holds nothing yet.
                     Angles_Base := -1.0;
                  end if;

                  if Angles_Base
                     /= Turn_Base (Settings, Natural (Index))
                  then
                     Angles_Base := Turn_Base (Settings, Natural (Index));

                     for Which in 0 .. Count - 1 loop
                        declare
                           Cosines : N.Wide_Real_Array (0 .. Pairs - 1);
                           Sines   : N.Wide_Real_Array (0 .. Pairs - 1);
                        begin
                           K.Rotary_Table
                             (Element_Count (Settings.Rotary),
                              Natural (Sits_At (Which)),
                              Turn_Base (Settings, Natural (Index)),
                              Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                              Cosines => Cosines, Sines => Sines,
                              Sections => Settings.Sections,
                              Place =>
                                Place_At (Item'Unchecked_Access.all,
                                          Natural (Sits_At (Which))));

                           for Pair in 0 .. Pairs - 1 loop
                              Angles.all (Which * Pairs * 2 + Pair * 2) :=
                                Cosines (Pair);
                              Angles.all
                                (Which * Pairs * 2 + Pair * 2 + 1) :=
                                Sines (Pair);
                           end loop;
                        end;
                     end loop;
                  end if;
               end if;

               --  Does the device hold the cache? Asked here rather
               --  than read off Resident, which is set by the loop that
               --  writes the positions and so says nothing yet: the
               --  whole layer writes them itself and has to know before
               --  it starts. Asking for room already taken returns at
               --  once.
               if Item.Paged then
                  --  Up to the last position of the batch, which is the
                  --  furthest cell any row of it reaches. A round wrote
                  --  its tables when it seated its members, past the
                  --  per-row table, so this does not write them again --
                  --  the member here is only the round's first.
                  Take_Pages
                    (Item'Unchecked_Access, Reserved + Count - 1, Resident,
                     Write_Tables => True);

                  --  A batch reads its own page table, which Take_Pages
                  --  wrote for every layer.
                  if Resident then
                     Paged_Table_At :=
                       Item.Page_Table_At.all (Natural (Index));
                  end if;

                  No_Block := not Resident;
               elsif Item.Held in Exact | Eighth | Fourth
                 and then Model_Runner.Backend."="
                            (Item.Owner.Able.Kind,
                             Model_Runner.Backend.Backend_Device)
               then
                  Take_Block (Item'Unchecked_Access, Resident);
                  No_Block := not Resident;
               end if;

               --  The whole layer as one submission, where the device
               --  holds the cache: with the turning a step and the cache
               --  write a step, there is nothing left for the host to do
               --  between the two halves.
               --  A round takes this too, through the same table its
               --  attention reads: the step that writes the cache looks
               --  a row's block and a row's position up there rather
               --  than counting from the first row's, so the bases
               --  below are the layer's offset alone.
               --
               --  The block a batch adds is read here and not hoisted
               --  into the declarations above, because Take_Block --
               --  which is what gives a session its block -- runs a
               --  dozen lines up from here, inside this same block. A
               --  constant declared before it holds the seat the
               --  session had before it had one, which is a batch
               --  writing its cache over somebody else's.
               --  And not for a batch with a picture's rows in it: the
               --  whole layer attends every position to itself and
               --  before, and those rows attend to each other, which
               --  the host's attention knows and the device's does not.
               --  A packed session's keys and values are packed as
               --  they are placed, by a step of the same sequence; a
               --  round's each into its own member's block, out of the
               --  table, as an exact round's are.
               if (Turnable or else Settings.Rotary = 0)
                 and then Resident
                 and then Item.Held in Exact | Eighth | Fourth
                 and then (((Settings.Experts = 0
                             or else Dense_Among_Experts (Current)
                             or else Mixture_Whole (Current))
                            and then Whole_Layer_Fits
                                       (Current, Natural (Index)))
                           or else (Split_Here (Current)
                                    and then Front_Fits
                                               (Current, Natural (Index))))
                 and then not Has_Runs
               then
                  Half := not ((Settings.Experts = 0
                                or else Dense_Among_Experts (Current)
                                or else Mixture_Whole (Current))
                               and then Whole_Layer_Fits
                                          (Current, Natural (Index)));
                  Asked := True;
                  Prefetch_Next (Natural (Index));
                  if Half and then Source.Split_Feed
                    and then Workers_CPU."/=" (Item.Team, null)
                  then
                     Workers_CPU.Rouse (Item.Team.all);
                  end if;
                  Model_Runner.Backend.Device.Whole_Layer
                    (Acts.all (0 .. Count * Width - 1),
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
                     (if Turnable
                      then Angles.all (0 .. Count * Pairs * 2 - 1)
                      else No_Turns),
                     Natural (Head_Size), Settings.Rotary,
                     K."=" (Settings.Pairing, K.Split),
                     (if Item.Paged then 0
                      else Block_Base (Item)
                           + Cell_Of (Item, Natural (Index),
                                      Reserved) * KV_Width
                           + Base),
                     (if Item.Paged then Page_Value_Base (Item)
                      else Block_Base (Item)
                           + Cell_Of (Item, Natural (Index),
                                      Reserved) * V_Width
                           + Exact_Keys (Item) + V_Base),
                     Natural (Heads), Natural (Value_Size),
                     Settings.Group_Size,
                     --  The lowest and highest cached positions this
                     --  call reads. A round's rows each have their own
                     --  in the table and the kernel takes its span
                     --  from there; what these are for then is the
                     --  engine's count of slices, so they must be the
                     --  widest row's and not the first member's --
                     --  which they were, and a round whose first
                     --  member was the shortest was cut into the
                     --  slices that row wanted, four times too few
                     --  for the longest. A round of sixteen packed
                     --  sessions from 88 to 1,419 positions read 2.15
                     --  s against 1.23 for sixteen at 1,419.
                     Natural (Lowest_Cell (Natural (Index))),
                     Natural (Highest_Cell (Natural (Index))),
                     (if Item.Paged then 0
                      else Block_Base (Item) + Base),
                     (if Item.Paged then Page_Value_Base (Item)
                      else Block_Base (Item)
                           + Exact_Keys (Item) + V_Base),
                     Natural (KV_Width), Natural (V_Width),
                     Scale, Settings.Attention_Cap,
                     Current.Attention_Out,
                     Feed_Gate (Current), Feed_Up (Current),
                     Feed_Down (Current),
                     Gate_Unit (Source),
                     Keys, Values, Acts, Whole_Layer_Done,
                     Positions => Natural (Count),
                     Stream_Feed => Streams_Feed (Current),
                     Window    =>
                       (if Settings.Window > 0
                          and then Earliest
                                     (Settings,
                                      Element_Count (Settings.Window),
                                      Natural (Index)) > 0
                        then Settings.Window
                        else 0),
                     Causal    => Settings.Causal,
                     Max_Bias  => Settings.Max_Bias,

                     --  A paged batch reads its own page table for the
                     --  layer, and where each new position lands follows
                     --  from the first. A paged round reads the per-row
                     --  table above instead, a member's table a row, so
                     --  it needs neither -- only the shift that tells the
                     --  kernel the base words there are page tables.
                     Pages_At   => Natural (Paged_Table_At),
                     Page_Shift =>
                       (if Item.Paged then Page_Shift_Bits else 0),
                     First_Position =>
                       (if Item.Paged
                        then Natural (Cell_Of (Item, Natural (Index),
                                               Reserved))
                        else 0),
                     Cancel    => Item.Stopping,

                     --  The first layer reads what the host sent and
                     --  the last writes what the host reads; the ones
                     --  between hand the activation on where it lies.
                     --  Carried only where the whole layer went to the
                     --  device on the layer before as well, which
                     --  Carried says.
                     Carry_In  => Carried,
                     --  A paged batch places by the chained head step
                     --  as a block session does; a round still mirrors.
                     Mirror    => not Deferring,
                     Carry_Out =>
                       not Half
                       and then Carrying
                       and then Index < Source.Layers.all'Last
                       and then Layer_Fits
                                  (Source.Layers.all (Index + 1),
                                   Natural (Index) + 1),

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

                     --  A packed session's block, and how its keys and
                     --  values are packed into it as they are placed:
                     --  from this batch's first cell on.
                     --  A round's rows each add their own block and
                     --  cell out of the table, so a round is given
                     --  the layer's offsets alone.
                     Packed      => Packed_Shape (Item, Base, V_Base,
                                                  KV_Width, V_Width,
                                                  Seated => False,
                                                  Paged => Item.Paged),
                     Pack_Keys   =>
                       Packing_Of
                         (Item,
                          Base + Cell_Of (Item, Natural (Index),
                                          Reserved) * KV_Width,
                          KV_Width, True, Seated => False,
                          Paged => Item.Paged),
                     Pack_Values =>
                       Packing_Of
                         (Item,
                          V_Base + Cell_Of (Item, Natural (Index),
                                            Reserved) * V_Width,
                          V_Width, False, Seated => False,
                          Paged => Item.Paged),

                     --  And the layer unpacked into the copy for the
                     --  matrix instruction, where the batch is long
                     --  enough for it: every cell up to the batch's last.
                     --  A round's rows read different blocks and none is
                     --  unpacked. A paged session gathers its scattered
                     --  pages into the copy, which the packed pages leave
                     --  free, and the matrix reads them there.
                     Unpacked    =>
                       (Unpacking_Of
                               (Item, Base, V_Base, KV_Width, V_Width,
                                Cell_Of (Item, Natural (Index), Reserved)
                                + Count,
                                Paged => Item.Paged)),
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
                  Half_Done := Half and then Whole_Layer_Done;
                  if Half_Done then
                     Whole_Layer_Done := False;
                  end if;
                  Went_Whole := Whole_Layer_Done;

                  --  A streamed feed-forward the device would not take:
                  --  the layer's own views are the processor's panels, so
                  --  the rest of it is the processor's too.
                  if not Whole_Layer_Done and then Streams_Feed (Current)
                  then
                     Item.Host_Feed := True;
                  end if;
               end if;

               Deferred (Index) :=
                 Deferring and then (Whole_Layer_Done or else Half_Done);

               --  The front half only: the keys and values are the
               --  device's as a whole layer's are, and the feed-forward
               --  the host's.
               if Half_Done then
                  Carried := False;
                  goto Front_Done_Batch;
               end if;

               Carried :=
                 Carrying
                 and then Whole_Layer_Done
                 and then Index < Source.Layers.all'Last
                 and then Layer_Fits
                            (Source.Layers.all (Index + 1),
                             Natural (Index) + 1);

               if Whole_Layer_Done then
                  Projected := True;
                  Rotated := True;
                  Fused := True;
                  Cached := True;
               elsif Current.Query_Norm = null
                 and then Current.Query_Bias = null
                 and then Current.Attention_Norm /= null
                 and then Current.Attention_Norm_Bias = null
                 and then Current.Feed_Norm /= null
                 and then Source.Settings.Kind not in Falcon | Phi2 | Mpt | Command_R
                 and then Source.Settings.Max_Bias = 0.0
               then
                  --  Not for a layer whose projections carry a bias:
                  --  the host adds it before the turning, and this
                  --  turns as it projects.
                  Model_Runner.Backend.Device.Normalize_And_Project
                    ([Current.Query, Current.Key, Current.Value],
                     Acts, Current.Attention_Norm.all, Settings.Epsilon,
                     [Query, Keys, Values], Projected,
                     Spread => Count,
                     Turns  =>
                       (if Turnable
                        then Angles.all (0 .. Count * Pairs * 2 - 1)
                        else Model_Runner.Backend.Device.No_Turns),
                     Turned    => (if Turnable then 2 else 0),
                     Head_Size => Natural (Head_Size),
                     Rotary    => Settings.Rotary,
                     Split     => K."=" (Settings.Pairing, K.Split),
                     Cancel    => Item.Stopping);

                  Rotated := Projected and then Turnable;
               end if;
            end;
         end if;

         if not Projected then
            if Current.Attention_Norm = null then
               Norm.all (0 .. Count * Width - 1) :=
                 Acts.all (0 .. Count * Width - 1);
            else
               declare
                  Share  : aliased Norm_Share;
                  Shared : E.Error_Info;
               begin
                  Workers_CPU.Dispatch_Shares
                    (Team, Count, Share'Unchecked_Access, Shared);
               end;
            end if;
         end if;

         --  Kept where the architecture runs its two sublayers from the
         --  same normalized input: attention is about to overwrite the
         --  buffer that holds it. A batch keeps all of it, which is why
         --  this is the batch's own buffer rather than the one position
         --  the single-token path keeps.
         --
         --  Asked of the architecture and not of the feed normalization
         --  being absent, because those are two different things and
         --  Bert is where they came apart: it has no feed normalization
         --  either, and it does not run its sublayers in parallel, so
         --  reading the absence as the arrangement copied a batch into a
         --  buffer that had never been allocated.
         if Source.Settings.Kind in Falcon | Phi2 | Command_R then
            Kept_Norm.all (0 .. Count * Width - 1) :=
              Norm.all (0 .. Count * Width - 1);
         end if;

         if Is_Linear and then Fused then
            --  Gone over whole above, feed-forward and all.
            null;
         elsif Is_Linear
           and then (Pure_SSM (Settings.Kind)
                     or else Is_Jamba (Settings.Kind))
         then
            --  Mamba's batch is its positions one after another, each
            --  the single-token step over its own row of the normalized
            --  batch and each carrying the state the one before it left,
            --  because the selective scan is a recurrence with nothing to
            --  parallelize over the batch. Each row's answer is written
            --  back in its place for the join below to take, exactly as
            --  the single-token path leaves it in Normalized. Jamba's
            --  Mamba layers go the same way, and then on to a
            --  feed-forward where a pure state-space model stops.
            Charge (Item, Normalizing, Mark);
            --  The projections over the whole batch and the scan the
            --  team's; see Mamba_Batch and Mamba2_Batch.
            if Is_Mamba2 (Settings.Kind) then
               Mamba2_Batch
                 (Item, Source, Current, Natural (Index), Norm, Count,
                  Went_Whole, Status);
               Asked := Went_Whole;
            else
               Mamba_Batch
                 (Item, Source, Current, Natural (Index), Norm, Count,
                  Status);
            end if;
            exit when E.Is_Error (Status);
            Charge (Item, Attending, Mark);
         elsif Is_Linear and then Is_RWKV (Settings.Kind) then
            --  RWKV6's batch goes through the block whole (RWKV6_Batch),
            --  which owns both residuals and writes the block's output;
            --  what the join below adds to the residual is that output
            --  less the row it started from, so the sum is the output
            --  whatever the rescale did to it, and the feed is skipped
            --  as Mamba's is.
            Charge (Item, Normalizing, Mark);
            declare
               Block_Out : T.Real_Array_Access;
            begin
               T.Allocate (Count * Width, Block_Out);
               if Block_Out = null then
                  Status := E.Make (E.Memory_Allocation_Failed);
               else
                  RWKV6_Batch
                    (Item, Source, Current, Natural (Index), Norm, Acts,
                     Count, Block_Out, Went_Whole, Status);
                  Asked := Went_Whole;
                  if E.Is_Ok (Status) then
                     for I in 0 .. Count * Width - 1 loop
                        Norm.all (Norm.all'First + I) :=
                          Block_Out.all (I) - Acts.all (Acts.all'First + I);
                     end loop;
                  end if;
                  T.Free (Block_Out);
               end if;
            end;
            exit when E.Is_Error (Status);
            Charge (Item, Attending, Mark);
         elsif Is_Linear then
            --  The linear layer's projections once over the whole batch,
            --  then its positions one after another, since each reads
            --  the state the one before it left; then the projection
            --  out, once again over the batch, into the normalized rows
            --  in their place, and the join below takes it from there.
            Charge (Item, Normalizing, Mark);

            Product_Batch
              (Item, Current.Mix, Norm, Count, Mix_Rows, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Z_Gate, Norm, Count, Z_Rows, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Alpha, Norm, Count, Alpha_Rows, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Beta, Norm, Count, Beta_Rows, Status);
            exit when E.Is_Error (Status);

            Charge (Item, Attending, Mark);

            --  The rule over each member's own run of rows and its
            --  own ring: a round's rows are different sessions', and
            --  a chunk over all of them as one session's read the
            --  first member's state for every row -- which is what
            --  the second member of a hybrid round got until the
            --  round was tested for it.
            declare
               Start : Element_Count := 0;
            begin
               while Start < Count loop
                  declare
                     Owner  : constant Element_Count := Row_Owner (Start);
                     Finish : Element_Count := Start;
                  begin
                     while Finish + 1 < Count
                       and then Row_Owner (Finish + 1) = Owner
                     loop
                        Finish := Finish + 1;
                     end loop;

                     Linear_Chunk
                       (Item'Unchecked_Access.all, Source, Current,
                        Natural (Index), Natural (Sits_At (Start)),
                        (First => (Mixed => Mix_Rows, Z_Gate => Z_Rows,
                                   Alpha => Alpha_Rows, Beta => Beta_Rows,
                                   Blend => Blend_Rows,
                                   M0 => Start * Mix_Wide,
                                   Z0 => Start * Value_Wide,
                                   A0 => Start * Value_Heads,
                                   B0 => Start * Value_Heads,
                                   O0 => Start * Value_Wide),
                         Count => Finish - Start + 1,
                         Mix_Stride => Mix_Wide,
                         Z_Stride => Value_Wide,
                         Head_Stride => Value_Heads,
                         Blend_Stride => Value_Wide),
                        Status);
                     exit when E.Is_Error (Status);

                     Start := Finish + 1;
                  end;
               end loop;
            end;
            exit when E.Is_Error (Status);

            Charge (Item, Projecting, Mark);

            Product_Batch
              (Item, Current.Linear_Out, Blend_Rows, Count, Norm, Status);
            exit when E.Is_Error (Status);
         else

            --  One pass over each weight for the whole batch.
            if not Projected then
               Charge (Item, Normalizing, Mark);

               --  The query projection's whole answer goes to its own
               --  room where it carries a gate beside each head, and
               --  each row's queries and gates are taken out of it.
               if Is_MLA (Settings.Kind) then
                  --  DeepSeek's latent projection, every projection once
                  --  over the batch; see MLA_Project_Batch.
                  MLA_Project_Batch
                    (Item, Current, Norm, Count, Query, Keys, Values,
                     Status);
                  exit when E.Is_Error (Status);
               elsif Hybrid (Settings.Kind) then
                  Product_Batch
                    (Item, Current.Query, Norm, Count, Query_Full, Status);
                  exit when E.Is_Error (Status);

                  for Which in 0 .. Count - 1 loop
                     declare
                        From : constant Element_Count := Which * 2 * Wide;
                        Q_At : constant Element_Count := Which * Wide;
                     begin
                        for H in 0 .. Heads - 1 loop
                           for C in 0 .. Head_Size - 1 loop
                              Query.all (Q_At + H * Head_Size + C) :=
                                Query_Full.all (From + H * 2 * Head_Size + C);
                              Gates.all (Q_At + H * Head_Size + C) :=
                                Query_Full.all
                                  (From + H * 2 * Head_Size + Head_Size + C);
                           end loop;
                        end loop;
                     end;
                  end loop;
               else
                  Product_Batch
                    (Item, Current.Query, Norm, Count, Query, Status);
                  exit when E.Is_Error (Status);
               end if;
               --  DeepSeek made its keys and values above, a head at a
               --  time from the latent, so there is no separate
               --  projection for them.
               if not Is_MLA (Settings.Kind) then
                  Product_Batch
                    (Item, Current.Key, Norm, Count, Keys, Status);
                  exit when E.Is_Error (Status);
                  Product_Batch
                    (Item, Current.Value, Norm, Count, Values, Status);
                  exit when E.Is_Error (Status);
               end if;
            end if;

            Charge (Item, Projecting, Mark);

            --  Rotate at each token's own position, then publish every key
            --  and value before any attention reads them: token K of the
            --  batch attends to the earlier tokens of the same batch.
            --
            --  Not for a layer the device took whole and whose rows are
            --  owed: the device turned them and holds them, nothing came
            --  back to copy, and a copy of what did not come back is a
            --  copy of nothing -- eleven microseconds a position a layer,
            --  which was a seventh of a long prompt.
            for Which in 0 .. (if Deferred (Index) then -1 else Count - 1)
            loop
               declare
                  Q_At : constant Element_Count := Slot (Which, Wide);
                  KV_At : constant Element_Count := Slot (Which, KV_Width);
                  V_At  : constant Element_Count := Slot (Which, V_Width);
                  Place : constant Element_Count :=
                    Base
                    + Cell_Of (Item, Natural (Index), Sits_At (Which))
                      * KV_Width;
                  V_Place : constant Element_Count :=
                    V_Base
                    + Cell_Of (Item, Natural (Index), Sits_At (Which))
                      * V_Width;
               begin
                  --  The same bias as the single-token path adds, on each
                  --  token of the batch. A batch that skipped it would
                  --  answer a prompt differently from the way it answers
                  --  the same text one token at a time.
                  if Current.Query_Bias /= null then
                     K.Add (Query.all (Q_At .. Q_At + Wide - 1),
                            Current.Query_Bias.all);
                     K.Add (Keys.all (KV_At .. KV_At + KV_Width - 1),
                            Current.Key_Bias.all);
                     K.Add (Values.all (V_At .. V_At + V_Width - 1),
                            Current.Value_Bias.all);
                  end if;

                  --  MPT's clamp on each token of the batch, the same the
                  --  single-token path applies, before anything reads them.
                  Clip_QKV
                    (Settings.Clip_QKV,
                     Query.all (Q_At .. Q_At + Wide - 1),
                     Keys.all (KV_At .. KV_At + KV_Width - 1),
                     Values.all (V_At .. V_At + V_Width - 1));

                  if Current.Query_Norm /= null then
                     Normalize_Heads
                       (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                        Current.Query_Norm.all, Settings.Epsilon,
                        Item.Head_Row.all);
                     Normalize_Heads
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        KV_Heads, Head_Size, Current.Key_Norm.all,
                        Settings.Epsilon, Item.Head_Row.all);
                  elsif Current.Query_Head_Norm /= null then
                     Normalize_Heads_Centred
                       (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                        Current.Query_Head_Norm.all, Settings.Epsilon,
                        Item.Head_Row.all);
                     Normalize_Heads_Centred
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        KV_Heads, Head_Size, Current.Key_Head_Norm.all,
                        Settings.Epsilon, Item.Head_Row.all);
                  end if;

                  --  And the code variant's, over the whole of each
                  --  projection rather than a head of it.
                  if Current.Query_Whole_Norm /= null then
                     Normalize_Whole
                       (Source, Query.all (Q_At .. Q_At + Wide - 1),
                        Current.Query_Whole_Norm,
                        Current.Query_Whole_Norm_Bias);
                     Normalize_Whole
                       (Source, Keys.all (KV_At .. KV_At + KV_Width - 1),
                        Current.Key_Whole_Norm,
                        Current.Key_Whole_Norm_Bias);
                  end if;

                  --  The queries and the keys of this position turn by
                  --  the same angles, so the table is computed once for
                  --  both. Two calls computed it twice, and the table is
                  --  a power, a cosine and a sine a pair.
                  --
                  --  Done already where the device turned them as it
                  --  projected: the table it was given is this one.
                  if not Rotated then
                     K.Apply_Rotary_Pair
                       (Query.all (Q_At .. Q_At + Wide - 1), Heads,
                        Keys.all (KV_At .. KV_At + KV_Width - 1), KV_Heads,
                        Head_Size, Element_Count (Settings.Rotary),
                        Natural (Sits_At (Which)),
                        Turn_Base (Settings, Natural (Index)),
                        Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                        Settings.Pairing,
                        Sections => Settings.Sections,
                        Place =>
                          Place_At (Item'Unchecked_Access.all,
                                    Natural (Sits_At (Which))),
                        Offset => 0);
                  end if;

                  if Item.Held in Eighth | Fourth then
                     Pack_Row
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        Item'Unchecked_Access.Byte_Keys.all, Place, KV_Width,
                        Item'Unchecked_Access.Key_Scales.all, Item.Held);
                     Pack_Row
                       (Values.all (V_At .. V_At + V_Width - 1),
                        Item'Unchecked_Access.Byte_Values.all, V_Place, V_Width,
                        Item'Unchecked_Access.Value_Scales.all, Item.Held_Values);

                     --  And the device's copy of the packed block --
                     --  a round's into each row's own member's block.
                     --  Written already where the layer went over
                     --  whole: the sequence packed them there.
                     if not Cached then
                        declare
                           Placed : Boolean;
                        begin
                           Put_Packed_Position
                             (Item'Unchecked_Access, Place, V_Place, KV_Width,
                              V_Width, Placed);
                           Resident := Placed;
                        end;
                     end if;
                  elsif Item.Held = Exact then
                     for Offset in 0 .. KV_Width - 1 loop
                        Item'Unchecked_Access.Keys.all (Place + Offset) :=
                          Keys.all (KV_At + Offset);
                     end loop;
                     for Offset in 0 .. V_Width - 1 loop
                        Item'Unchecked_Access.Values.all (V_Place + Offset) :=
                          Values.all (V_At + Offset);
                     end loop;

                     --  And the device's copy, as the single-token path
                     --  does. Both evaluators must attend the same way: a
                     --  model that computes attention one way when it
                     --  generates and another when a draft's proposals are
                     --  checked says two different things, and the suite
                     --  says so.
                     --
                     --  Written already where the layer went over whole:
                     --  the sequence put them there before it attended.
                     --
                     --  A round writes each row into the row's own block of
                     --  that cache, which is what the kernel below reads
                     --  and is why a member's position does not land on
                     --  another member's.
                     if not Cached then
                        declare
                           Placed : Boolean;
                        begin
                           Put_Position
                             (Item'Unchecked_Access,
                              Place,
                              Keys.all (KV_At .. KV_At + KV_Width - 1),
                              V_Place,
                              Values.all (V_At .. V_At + V_Width - 1),
                              Placed);

                           Resident := Placed;
                        end;
                     end if;
                  else
                     Model_Runner.Kernels.To_Halves
                       (Keys.all (KV_At .. KV_At + KV_Width - 1),
                        Item'Unchecked_Access.Half_Keys.all
                          (Place .. Place + KV_Width - 1));
                     Model_Runner.Kernels.To_Halves
                       (Values.all (V_At .. V_At + V_Width - 1),
                        Item'Unchecked_Access.Half_Values.all
                          (V_Place .. V_Place + V_Width - 1));
                  end if;
               end;
            end loop;

            --  Rotating covers the cache writes too: they are the same loop
            --  over the batch, and separating them would read the clock
            --  twice a position rather than once a layer -- which is the
            --  instrument measuring itself rather than the work.
            Charge (Item, Rotating, Mark);

            --  The whole batch in one call where a device holds the cache.
            --  Every position of a batch reads the same cache and writes its
            --  own blend, so nothing makes them wait for each other -- and a
            --  call costs 83 microseconds before it computes anything, which
            --  a position at a time pays 2420 times over a 110-token prompt.
            --
            --  Done already where the whole layer went over as one: this is
            --  a step of it.
            --  A hybrid's heads are gated after they attend, which the
            --  device's second half does not do: its full attention
            --  layers attend on the host.
            --  And not where a picture's rows look forward: the device's
            --  attention moves every position's end along by one, and
            --  a batch with a run in it is attended on the host, which
            --  knows where each run ends.
            --  Not a paged session: this fallback attends over block
            --  offsets a paged cache does not hold -- Seat_At is the
            --  block's base and the round's table is the block round's,
            --  neither of which a paged batch or round has. A paged
            --  session whose layer did not go over whole attends on the
            --  host below, out of its host copy, which mirroring keeps
            --  current.
            if Item.Held in Exact | Eighth | Fourth and then Resident
              and then not Item.Paged
              and then not Fused
              and then not Hybrid (Settings.Kind)
              and then not Has_Runs
            then
               declare
                  --  What Earliest would return for the batch's first
                  --  position, and the width it would slide for the rest.
                  --  Taken from Earliest rather than restated, so a layer
                  --  that windows nothing says zero here as it does there.
                  Window_Here : constant Natural :=
                    (if Settings.Window > 0
                       and then Earliest (Settings,
                                          Element_Count (Settings.Window),
                                          Natural (Index)) > 0
                     then Settings.Window
                     else 0);

                  --  The last position the batch may look at. Causally
                  --  that is the batch's first, and each position after it
                  --  moves its own end along; attending both ways it is the
                  --  batch's last, and every position shares it.
                  First_Step : constant Element_Count :=
                    Cell_Of (Item, Natural (Index),
                             Earliest (Settings, Reserved, Natural (Index)));
                  Last_Step  : constant Element_Count :=
                    Cell_Of (Item, Natural (Index),
                             (if Settings.Causal
                              then Reserved
                              else Reserved + Count - 1));

                  --  Where this session's own block begins, for a batch. A
                  --  round says nothing here: the kernel adds each row's
                  --  own block out of the table, and a base added twice
                  --  would read past the cache.
                  Seat_At : constant Element_Count := Block_Base (Item);

                  Usable : Boolean;
               begin
                  --  The whole of the layer's second half as one sequence,
                  --  for a batch as for a single position.
                  --
                  --  A batch already paid three submissions a layer and had
                  --  the host joining and normalizing between them, which
                  --  for a hundred and twenty-eight positions is a quarter
                  --  of a million elements a layer crossing the bus twice
                  --  to be added up. The steps are the same nine; only the
                  --  position count differs, and every kernel in them was
                  --  written to take one.
                  --  A packed block's step reads it with the packed
                  --  kernel, a round's rows each out of their own
                  --  block through the table.
                  if Item.Held in Exact | Eighth | Fourth
                    and then Settings.Experts = 0
                    and then not Current.Host_Feed
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
                     Model_Runner.Backend.Device.Attend_And_Feed
                       (Query.all (0 .. Count * Wide - 1),
                        Acts.all (0 .. Count * Width - 1),
                        Natural (Heads), Natural (Head_Size),
                        Natural (Value_Size), Settings.Group_Size,
                        Natural (First_Step), Natural (Last_Step),
                        Seat_At + Base,
                        Seat_At + Exact_Keys (Item) + V_Base,
                        Natural (KV_Width), Natural (V_Width), Scale,
                        Settings.Attention_Cap, Current.Attention_Out,
                        Current.Feed_Norm.all, Settings.Epsilon,
                        Current.Gate, Current.Up, Current.Down,
                        Gate_Unit (Source), Acts, Fused,
                        Positions => Natural (Count),
                        Window    => Window_Here,
                        Causal    => Settings.Causal,
                        Max_Bias  => Settings.Max_Bias,
                        Packed    => Packed_Shape (Item, Base, V_Base,
                                                   KV_Width, V_Width,
                                                   Seated => False),
                        Sinks_At  => Sinks_Ready (Current.Sinks, Natural (Index)),
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit);
                  end if;

                  --  A packed round the device would not take as one
                  --  sequence is attended on the host below: the
                  --  single call reads one block, and a round's rows
                  --  are in several.
                  if Fused then
                     Usable := True;
                  else
                     Attend_There
                       (Item, Source, Query.all (0 .. Count * Wide - 1),
                        Heads, Head_Size, Value_Size,
                        First_Step, Last_Step,
                        Base, V_Base, KV_Width, V_Width, Scale,
                        Attend.all (0 .. Count * Blend - 1), Usable,
                        Positions => Count, Window => Window_Here,
                        Sinks => Current.Sinks);
                  end if;

                  if not Usable then
                     Item.Current := Failed;
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Integer (Status, "layer",
                                    Long_Long_Integer (Index));
                     return;
                  end if;
               end;
            end if;

            --  Every position of the batch, in shares of the heads.
            --
            --  A head at a time down the positions rather than a position at
            --  a time down the heads, which is the same work in the other
            --  order and is what makes it one hand-off a layer instead of
            --  one per position: a hundred and twenty-eight positions of
            --  twenty-two layers would otherwise be nearly three thousand
            --  rendezvous for a prompt. It also needs no score buffer beyond
            --  the row a head already has, where sharing the positions out
            --  would have needed a row per share per head.
            if not Fused
              and then (Hybrid (Settings.Kind)
                        or else Has_Runs
                        or else Item.Paged
                        or else not (Item.Held = Exact and then Resident))
            then
               declare
                  type Batch_Share is limited new Workers_CPU.Task_Item with
                     record
                        Ok : Boolean := True;
                     end record;

                  overriding procedure Run
                    (Share : in out Batch_Share;
                     From  : Element_Count;
                     To    : Element_Count);

                  overriding procedure Run
                    (Share : in out Batch_Share;
                     From  : Element_Count;
                     To    : Element_Count) is
                  begin
                     if From > To then
                        return;
                     end if;

                     declare
                        --  Four positions at a time where the cache is
                        --  kept in halves: a key read and converted once
                        --  for the four (Blend_Halved_Four). In binary32
                        --  too (Blend_Exact_Four), but not sixty-four
                        --  wide: Blend_Exact scores that width eight keys
                        --  to a fold, which the block's kernels do not
                        --  sum to the bit. The rest of a batch, and the
                        --  byte caches, a position at a time as before.
                        Four : constant Boolean :=
                          (Item.Held = Halved
                           or else (Item.Held = Exact
                                    and then Head_Size /= 64))
                          and then Value_Size mod 16 = 0
                          and then Count >= 4;
                        Size : Positive := 4;
                        Rows : T.Real_Array_Access := null;
                        Next : Element_Count := 0;

                        function First_Of (Which : Element_Count)
                          return Element_Count
                        is (Cell_Of (Item'Unchecked_Access.all,
                                     Natural (Index),
                                     Earliest (Settings, Sits_At (Which),
                                               Natural (Index))));

                        function Last_Of (Which : Element_Count)
                          return Element_Count
                        is (Cell_Of (Item'Unchecked_Access.all,
                                     Natural (Index),
                                     (if Settings.Causal
                                      then Sits_At (Sees_To (Which))
                                      else Reserved + Count - 1)));

                        function Query_Of (Which : Element_Count)
                          return Element_Count
                        is (Cell_Of (Item'Unchecked_Access.all,
                                     Natural (Index), Sits_At (Which)));

                        procedure One (Which : Element_Count) is
                           --  A causal position looks to itself -- or to
                           --  the end of the run of given rows it is in.
                           --  The window is measured from the position
                           --  itself either way.
                           Last_Step : constant Element_Count :=
                             (if Settings.Causal
                              then Sits_At (Sees_To (Which))
                              else Reserved + Count - 1);
                           First_Step : constant Element_Count :=
                             Earliest (Settings, Sits_At (Which),
                                       Natural (Index));

                           --  Said as cells of the row's own session,
                           --  because a round's rows are different sessions
                           --  and each holds its window somewhere of its
                           --  own. Every distance the blend takes is a
                           --  difference between two of these.
                           First_Cell : constant Element_Count :=
                             Cell_Of (Item'Unchecked_Access.all, Natural (Index),
                                      First_Step);
                           Last_Cell  : constant Element_Count :=
                             Cell_Of (Item'Unchecked_Access.all, Natural (Index),
                                      Last_Step);

                           --  The query's own position, which is not the
                           --  last one: a model that reads a whole text at
                           --  once gives every slot of the batch the same
                           --  last position, and the fall-off with distance
                           --  is measured from where the query is.
                           Query_Cell : constant Element_Count :=
                             Cell_Of (Item'Unchecked_Access.all, Natural (Index),
                                      Sits_At (Which));

                           Q_At   : constant Element_Count :=
                             Slot (Which, Wide);
                           B_At   : constant Element_Count :=
                             Slot (Which, Blend);
                           Usable : Boolean := True;
                        begin
                           if Item.Held in Eighth | Fourth then
                              Blend_Eighth
                                (Item.Held, Item.Held_Values,
                                 Query.all (Q_At .. Q_At + Wide - 1),
                                 Item'Unchecked_Access.Byte_Keys.all,
                                 Item'Unchecked_Access.Byte_Values.all,
                                 Item'Unchecked_Access.Key_Scales.all,
                                 Item'Unchecked_Access.Value_Scales.all,
                                 Base, V_Base, Rows_Base, KV_Width, V_Width,
                                 Heads, Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Cell, Last_Cell, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Query_Cell, Current.Sinks,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           elsif Item.Held = Exact then
                              Blend_Exact
                                (Query.all (Q_At .. Q_At + Wide - 1),
                                 Item'Unchecked_Access.Keys.all,
                                 Item'Unchecked_Access.Values.all,
                                 Base, V_Base, KV_Width, V_Width, Heads,
                                 Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Cell, Last_Cell, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Query_Cell, Current.Sinks,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           else
                              Blend_Halved
                                (Query.all (Q_At .. Q_At + Wide - 1),
                                 Item'Unchecked_Access.Half_Keys.all,
                                 Item'Unchecked_Access.Half_Values.all,
                                 Base, V_Base, KV_Width, V_Width, Heads,
                                 Head_Size, Value_Size,
                                 Element_Count (Settings.Group_Size),
                                 First_Cell, Last_Cell, Scale,
                                 Settings.Attention_Cap, Settings.Max_Bias,
                                 Query_Cell, Current.Sinks,
                                 From, To, Item.Score_Room, Item.Scores.all,
                                 Attend.all (B_At .. B_At + Blend - 1),
                                 Usable);
                           end if;

                           if not Usable then
                              Share.Ok := False;
                           end if;
                        end One;
                     begin
                        if Four then
                           T.Allocate (8 * Item.Score_Room, Rows);
                        end if;

                        while Next < Count loop
                           Size :=
                             (if Next + 7 < Count then 8 else 4);
                           if Rows /= null and then Next + 3 < Count then
                              declare
                                 Firsts, Lasts, Queries : Cell_Quad;
                                 Usable : Boolean;
                              begin
                                 Firsts := [others => 0];
                                 Lasts := [others => 0];
                                 Queries := [others => 0];
                                 for R in 0 .. Size - 1 loop
                                    Firsts (R) :=
                                      First_Of (Next + Element_Count (R));
                                    Lasts (R) :=
                                      Last_Of (Next + Element_Count (R));
                                    Queries (R) :=
                                      Query_Of (Next + Element_Count (R));
                                 end loop;

                                 if Item.Held = Exact then
                                    Blend_Exact_Four
                                      (Size,
                                       Query.all, Slot (Next, Wide), Wide,
                                       Item'Unchecked_Access.Keys.all,
                                       Item'Unchecked_Access.Values.all,
                                       Base, V_Base, KV_Width, V_Width,
                                       Head_Size, Value_Size,
                                       Element_Count (Settings.Group_Size),
                                       Heads, Firsts, Lasts, Queries, Scale,
                                       Settings.Attention_Cap,
                                       Settings.Max_Bias, Current.Sinks,
                                       From, To, Item.Score_Room, Rows.all,
                                       Attend.all, Slot (Next, Blend), Blend,
                                       Usable);
                                 else
                                    Blend_Halved_Four
                                      (Size,
                                       Query.all, Slot (Next, Wide), Wide,
                                       Item'Unchecked_Access.Half_Keys.all,
                                       Item'Unchecked_Access.Half_Values.all,
                                       Base, V_Base, KV_Width, V_Width,
                                       Head_Size, Value_Size,
                                       Element_Count (Settings.Group_Size),
                                       Heads, Firsts, Lasts, Queries, Scale,
                                       Settings.Attention_Cap,
                                       Settings.Max_Bias, Current.Sinks,
                                       From, To, Item.Score_Room, Rows.all,
                                       Attend.all, Slot (Next, Blend), Blend,
                                       Usable);
                                 end if;

                                 if not Usable then
                                    Share.Ok := False;
                                 end if;
                              end;
                              Next := Next + Element_Count (Size);
                           else
                              One (Next);
                              Next := Next + 1;
                           end if;
                        end loop;

                        T.Free (Rows);
                     end;
                  end Run;

                  Share  : aliased Batch_Share;
                  Shared : E.Error_Info;
               begin
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Heads, Share'Unchecked_Access, Shared);

                  if not Share.Ok or else E.Is_Error (Shared) then
                     Release;
                     Item.Current := Failed;
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Integer
                       (Status, "layer", Long_Long_Integer (Index));
                     return;
                  end if;
               end;
            end if;

            Charge (Item, Attending, Mark);
         end if;

         --  Every step of the rest is a step of the sequence where the
         --  layer's second half went over as one, so there is nothing
         --  left here to do.
      <<Front_Done_Batch>>
         if not Fused then

            if Half_Done then
               --  The device ran the front half and joined it into the
               --  rows; what the feed-forward reads is their normalization.
               for Which in 0 .. Count - 1 loop
                  declare
                     Origin : constant Element_Count := Slot (Which, Width);
                  begin
                     Normalize
                       (Source, Acts.all (Origin .. Origin + Width - 1),
                        Current.Feed_Norm.all, Current.Feed_Norm_Bias,
                        Norm.all (Origin .. Origin + Width - 1));
                  end;
               end loop;
               Charge (Item, Normalizing, Mark);
            else
               --  A linear layer's answer is in Norm already.
               if not Is_Linear then
                  --  Each head's blend through the sigmoid of its gate,
                  --  where the projection carried one.
                  if Hybrid (Settings.Kind) then
                     for C in 0 .. Count * Blend - 1 loop
                        Attend.all (C) :=
                          Attend.all (C) * Sigmoid (Gates.all (C));
                     end loop;
                  end if;

                  Product_Batch
                    (Item, Current.Attention_Out, Attend, Count, Norm, Status);
                  exit when E.Is_Error (Status);
               end if;
               Charge (Item, Projecting, Mark);

               if Current.Out_Bias /= null then
                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count := Slot (Which, Width);
                     begin
                        K.Add (Norm.all (Origin .. Origin + Width - 1),
                               Current.Out_Bias.all);
                     end;
                  end loop;
               end if;

               declare
                  Share  : aliased Join_Share;
                  Shared : E.Error_Info;
               begin
                  Workers_CPU.Dispatch_Shares
                    (Team, Count, Share'Unchecked_Access, Shared);

                  if not Share.Ok or else E.Is_Error (Shared) then
                     Release;
                     Item.Current := Failed;
                     Status := E.Make (E.Memory_Allocation_Failed);
                     return;
                  end if;
               end;

               Charge (Item, Joining, Mark);
            end if;

            --  Mamba's layer is its block and no feed-forward, so once
            --  the block has joined the residual the layer is done; and
            --  RWKV6's is its two mixes, both joined above, with no feed
            --  after either.
            if Pure_SSM (Settings.Kind) or else Is_RWKV (Settings.Kind) then
               goto After_Feed_Batch;
            end if;

            --  Which experts run is decided per position, so a batch has no
            --  one matrix to multiply the whole of it by: this is the one
            --  block that runs a token at a time however many were handed
            --  in. Everything before it -- the projections, the attention,
            --  the output -- still goes through the batch.
            if Current.Experts /= null then
               --  Gathered by expert, which is what makes an expert's
               --  matrices cross once a layer instead of once for every
               --  position that chose them. This used to be the device's
               --  alone, on the reading that the processor reads the
               --  same memory either way; it does not, because a
               --  position at a time is one vector against every matrix
               --  and the gathered run is a strip -- Qwen3-30B-A3B's
               --  110-token prompt on the pool reads 36 tokens a second
               --  a position at a time and 71 gathered, the same text.
               --  The reference keeps the loop: it has no batched
               --  product to gather into.
               Grouped := False;

               if Model_Runner.Backend."/="
                    (Item.Owner.Able.Kind,
                     Model_Runner.Backend.Backend_Reference)
                 and then Count > 1
               then
                  Mixture_Batch
                    (Item, Current, Norm, Count, Grouped, Status);

                  --  The pool roused for these experts may sleep again.
                  if Workers_CPU."/=" (Item.Team, null) then
                     Workers_CPU.Rest (Item.Team.all);
                  end if;
                  exit when E.Is_Error (Status);
               end if;

               if not Grouped then
                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count :=
                          Slot (Which, Width);
                     begin
                        Item.Normalized.all :=
                          Norm.all (Origin .. Origin + Width - 1);
                        Mixture
                          (Item, Current, Item.Normalized, Item.Mixture,
                           Status);
                        exit when E.Is_Error (Status);
                        Norm.all (Origin .. Origin + Width - 1) :=
                          Item.Mixture.all;
                     end;
                  end loop;
               end if;
               exit when E.Is_Error (Status);
            else
               --  As in the single-token path: the two arrangements differ
               --  only in how Gate is filled, and the projection down is
               --  written once so that neither can skip it.
               if not T.Is_Present (Current.Gate) then
                  --  No gate: up, a Gaussian unit, down. As in the
                  --  single-token path, the gate being absent is what says
                  --  so.
                  Product_Batch
                    (Item, Current.Up, Norm, Count, Gate, Status);
                  exit when E.Is_Error (Status);

                  declare
                     Share  : aliased Feed_Share := (Both => False);
                     Shared : E.Error_Info;
                  begin
                     Workers_CPU.Dispatch_Shares
                       (Team, Count, Share'Unchecked_Access, Shared);

                     if E.Is_Error (Shared) then
                        Release;
                        Item.Current := Failed;
                        Status := Shared;
                        return;
                     end if;
                  end;
               elsif Model_Runner.Backend."="
                       (Item.Owner.Able.Kind,
                        Model_Runner.Backend.Backend_Device)
                 --  Not a layer whose feed-forward the processor runs.
                 and then not Item.Host_Feed
               then
                  --  A device takes the whole gated block at once -- both
                  --  arms, the unit, the multiply, and the projection that
                  --  reads what they make -- with none of the middle coming
                  --  back. However many positions: the combining step works
                  --  elementwise over whatever the arms hold, and both arms
                  --  are laid out the same way by the same kernel, so what
                  --  that layout is does not matter to it.
                  Model_Runner.Backend.Device.Dispatch_Gated
                    (Current.Gate, Current.Up, Current.Down,
                     Norm, Count, Gate_Unit (Source), Norm, Status,
                     Item.Stopping,
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit);
                  exit when E.Is_Error (Status);
                  Whole_Block := True;
               else
                  Product_Batch
                    (Item, Current.Gate, Norm, Count, Gate, Status);
                  exit when E.Is_Error (Status);
                  Product_Batch
                    (Item, Current.Up, Norm, Count, Up, Status);
                  exit when E.Is_Error (Status);

                  declare
                     Share  : aliased Feed_Share;
                     Shared : E.Error_Info;
                  begin
                     Workers_CPU.Dispatch_Shares
                       (Team, Count, Share'Unchecked_Access, Shared);

                     if E.Is_Error (Shared) then
                        Release;
                        Item.Current := Failed;
                        Status := Shared;
                        return;
                     end if;
                  end;
               end if;

               if not Whole_Block then
                  Product_Batch
                    (Item, Current.Down, Gate, Count, Norm, Status);
                  exit when E.Is_Error (Status);
               end if;

               if Current.Down_Bias /= null then
                  for Which in 0 .. Count - 1 loop
                     declare
                        Origin : constant Element_Count := Slot (Which, Width);
                     begin
                        K.Add (Norm.all (Origin .. Origin + Width - 1),
                               Current.Down_Bias.all);
                     end;
                  end loop;
               end if;
            end if;

            Charge (Item, Feeding, Mark);

            declare
               Share  : aliased Join_Share := (After => True, Ok => True);
               Shared : E.Error_Info;
            begin
               Workers_CPU.Dispatch_Shares
                 (Team, Count, Share'Unchecked_Access, Shared);

               if not Share.Ok or else E.Is_Error (Shared) then
                  Release;
                  Item.Current := Failed;
                  Status := E.Make (E.Memory_Allocation_Failed);
                  return;
               end if;
            end;

            Charge (Item, Joining, Mark);

            <<After_Feed_Batch>>
            null;
         end if;

         <<Mamba_Done_Batch>>

         --  What became of this layer, for the run's report.
         if Model_Runner.Backend."="
              (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
         then
            Model_Runner.Backend.Device.Note_Layer
              (Went_Whole, Asked, Cache => No_Block or else Blockless,
               Held =>
                 (No_Block or else Blockless)
                 and then Blocks_Were_Held,
               Split => Half_Done);
         end if;
      end;
   end loop;

   --  Every layer's products where they always ran, past the stack.
   if Source.Split_Feed and then Settings.Experts = 0 then
      Item.Host_Feed := False;

      --  The buffers a streamed feed-forward left for the next of its
      --  size: the tokens after a prompt stream nothing, and holding them
      --  slowed the generation after a 6,502-token prompt from 3.59 tokens
      --  a second to 2.81.
      if Count
         >= Element_Count (Natural'Min (Stream_Least, Feed_Stream_Least))
      then
         Model_Runner.Backend.Device.Drop_Spares;
      end if;
   end if;

   --  The host's own copy of the cache, brought up to date out of the
   --  device's, for the layers that did not send it back a step at a
   --  time. The same bytes; the difference is that the batch did not
   --  wait on any of them.
   --  Whether the host's copy can simply be owed rather than fetched.
   --
   --  Every layer of this call has to have deferred: a layer that did
   --  not wrote the host's copy itself and may not have written the
   --  device's, so fetching that layer's range back would overwrite a
   --  good copy with whatever the block happens to hold.
   --
   --  A round's rows belong to different sessions, which is a range
   --  each rather than one -- so a round read every row of every layer
   --  back where a batch of one session deferred the lot. Each member
   --  has a window of its own to defer into, and each is fetched when
   --  something is about to read that member's copy.
   declare
      All_Deferred : constant Boolean :=
        Deferring
        and then (for all Index in Source.Layers.all'Range =>
                    Deferred (Index));

      Owing : constant Boolean := All_Deferred;

   begin
      if Owing then
         if Item.Owed_Count = 0 then
            Item.Owed_At := Item.Committed;
            Item.Owed_Count := Natural (Count);
         else
            --  Two calls' ranges are consecutive, so the union is the
            --  first of the earlier and the last of the later.
            Item.Owed_Count :=
              Natural'Max (Item.Owed_At + Item.Owed_Count,
                           Item.Committed + Natural (Count))
              - Item.Owed_At;
         end if;

      end if;

      for Index in Source.Layers.all'Range loop
         if Deferred (Index) and then not Owing
           and then not Linear (Settings, Natural (Index))
         then
            declare
               Layer_Keys : constant Element_Count :=
                 Keys_At (Item, Natural (Index));

               Layer_Vals : constant Element_Count :=
                 Values_At (Item, Natural (Index));

               Read : Boolean := True;
            begin
               --  A batch is one session's own run of positions and comes
               --  back in two reads. A round's rows are different sessions
               --  in different blocks, so each row is fetched into the
               --  member whose cache it belongs to -- which is the same
               --  bytes and the same one wait, said a row at a time.
               declare
                  Cell : constant Element_Count :=
                    Cell_Of (Item, Natural (Index),
                             Element_Count (Item.Committed));

                  Base : constant Element_Count :=
                    Layer_Keys + Cell * KV_Width;

                  V_At : constant Element_Count :=
                    Layer_Vals + Cell * V_Width;
               begin
                  if Item.Paged and then Item.Held = Exact then
                     Read_Pages_Layer
                       (Item, Natural (Index), KV_Width, V_Width,
                        Cell, Count, Read);
                  elsif Item.Paged then
                     Read_Packed_Pages_Layer
                       (Item, Natural (Index), KV_Width, V_Width,
                        Cell, Count, Read);
                  elsif Item.Held in Eighth | Fourth then
                     Read_Back_Packed
                       (Item, Base, V_At, Count, KV_Width, V_Width,
                        Read);
                  else
                     Model_Runner.Backend.Device.Get_Cache
                       (Block_Base (Item) + Base,
                        Item.Keys.all
                          (Base .. Base + Count * KV_Width - 1),
                        Read);

                     if Read then
                        Model_Runner.Backend.Device.Get_Cache
                          (Block_Base (Item) + Item.Keys.all'Length
                           + V_At,
                           Item.Values.all
                             (V_At .. V_At + Count * V_Width - 1),
                           Read);
                     end if;
                  end if;
               end;

               if not Read then
                  Release;
                  Item.Current := Failed;
                  Status := E.Make (E.Backend_Closed);
                  return;
               end if;
            end;
         end if;
      end loop;
   end;

   if E.Is_Error (Status) then
      Release;
      Item.Current := Failed;
      return;
   end if;

   --  A paged session's batch with a picture's rows in it attended on
   --  the host, and wrote its keys and values into the host's copy
   --  only: Put_Position writes a block, which a paged session has not
   --  got, so the device's pages kept whatever they held before. The
   --  next token read them there -- Gemma 3 named a red picture "Red"
   --  and then said nothing but noise. Its pages given back, the next
   --  pass takes them again and writes the committed cache into them
   --  from the host's copy, as it does for a session turned out and
   --  come back.
   if Item.Paged and then Has_Runs then
      Release_Session_Pages (Item'Unchecked_Access);
   end if;

   --  Only the last token's distribution is produced: the earlier tokens
   --  of a prompt are consumed to build context, not to be sampled from.
   --  Every position's state, for a caller that pools over them. The
   --  same normalization the last position gets, applied to each: what
   --  makes an embedding of a text is what the model made of every
   --  position of it, and only this path has them all in hand.
   if States /= null
     and then States.all'Length >= Count * Width
   then
      for Which in 0 .. Count - 1 loop
         declare
            Origin : constant Element_Count := Slot (Which, Width);
         begin
            Final_State
              (Source, Acts.all (Origin .. Origin + Width - 1),
               States.all (States.all'First + Origin
                           .. States.all'First + Origin + Width - 1));
         end;
      end loop;
   end if;

   --  Every position's logits, for a caller checking what another model
   --  proposed. The output projection once per position, which is the
   --  largest matrix here: asked for and never given away.
   if Every /= null
     and then Every.all'Length
              >= Count * Element_Count (Settings.Vocabulary)
   then
      --  ONE PROJECTION OVER EVERY ROW, not a projection a row. This
      --  read the output matrix once for each position asked about --
      --  sixty-five megabytes of it a position on a small model -- where
      --  the round path a few lines above had always batched the same
      --  work. A caller asking for every position's distribution is
      --  asking for the largest matrix in the model to be multiplied by
      --  a matrix and not by a hundred vectors in turn.
      --
      --  What it was costing: 0.45 seconds a position, against 2.6
      --  milliseconds for a position of an ordinary prompt.
      declare
         Vocabulary  : constant Element_Count :=
           Element_Count (Settings.Vocabulary);
         Wide_Logits : T.Real_Array_Access := null;
      begin
         T.Allocate (Count * Vocabulary, Wide_Logits);

         if Wide_Logits = null then
            Release;
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text
              (Status, "category", "every_logits", E.Param_Identifier);
            return;
         end if;

         for Which in 0 .. Count - 1 loop
            declare
               Origin : constant Element_Count := Slot (Which, Width);
               Into   : constant Element_Count := Which * Width;
            begin
               Final_State
                 (Source, Acts.all (Origin .. Origin + Width - 1),
                  Norm.all (Into .. Into + Width - 1));
            end;
         end loop;

         Product_Batch
           (Item, Source.Output, Norm, Count, Wide_Logits, Status);

         if E.Is_Error (Status) then
            T.Free (Wide_Logits);
            Release;
            Item.Current := Failed;
            return;
         end if;

         for Which in 0 .. Count - 1 loop
            declare
               Into : constant Element_Count := Which * Vocabulary;
            begin
               Finish_Logits
                 (Source,
                  Wide_Logits.all (Into .. Into + Vocabulary - 1));

               Every.all (Every.all'First + Into
                          .. Every.all'First + Into + Vocabulary - 1) :=
                 Wide_Logits.all (Into .. Into + Vocabulary - 1);
            end;
         end loop;

         --  The last row is the last position's distribution, and the
         --  head is not read a second time for it: on a small model
         --  the head is a third of the file, and a draft's every round
         --  asks for every row.
         if Settings.Has_Head then
            declare
               Into : constant Element_Count := (Count - 1) * Vocabulary;
               Origin : constant Element_Count := Slot (Count - 1, Width);
            begin
               Logits := Wide_Logits.all (Into .. Into + Vocabulary - 1);
               Final_State
                 (Source, Acts.all (Origin .. Origin + Width - 1),
                  Item.Normalized.all);
               if Item.Last_Final /= null then
                  Item.Last_Final.all := Item.Normalized.all;
                  Item.Has_Final := True;
               end if;
               Took_Last := True;
            end;
         end if;

         T.Free (Wide_Logits);
      end;
   end if;

   --  The last position's distribution, for the caller who is reading a
   --  prompt in order to continue it. A headless model has none and was
   --  refused the ask on the way in, so there is nothing to compute and
   --  nothing to hand back.
   if Settings.Has_Head and then not Took_Last then
      declare
         Origin : constant Element_Count := Slot (Count - 1, Width);
      begin
         --  Through the same normalization the single-token path uses,
         --  and not the root-mean-square form directly: an architecture
         --  that centres its normalization would otherwise be centred
         --  everywhere but here, which is a difference only the batched
         --  path shows and only in the logits it returns.
         Final_State
           (Source, Acts.all (Origin .. Origin + Width - 1),
            Item.Normalized.all);

         --  Kept for the block past the stack, where there is one.
         if Item.Last_Final /= null then
            Item.Last_Final.all := Item.Normalized.all;
            Item.Has_Final := True;
         end if;
      end;

      Product
        (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
      if E.Is_Error (Status) then
         Release;
         Item.Current := Failed;
         return;
      end if;

      Logits := Item.Logit_Row.all;
      Finish_Logits (Source, Logits);
   end if;

   --  Commit every position of the batch, or none of them -- and for a
   --  round, one position in each member, which is the same rule said
   --  once a row.
   for Which in 0 .. Count - 1 loop
      Item'Unchecked_Access.History.all (Natural (Sits_At (Which))) :=
        Tokens (Tokens'First + Natural (Which));
   end loop;

   Item.Committed := Item.Committed + Natural (Count);
   Status := E.Success;
   Charge (Item, Reading_Out, Mark);
   Release;
exception
   when Occurrence : others =>
      Release;
      Item.Current := Failed;
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.evaluate_batch");
      E.Add_Frame
        (Status, Ada.Exceptions.Exception_Name (Occurrence));
end Evaluate_Batch;
