separate (Model_Runner.Llama)
procedure Open
  (Item           : in out Session;
   Source         : in out Model'Class;
   Context        : Natural := 0;
   Session_Bounds : Model_Runner.Limits.Session_Limits :=
     Model_Runner.Limits.Default_Session_Limits;
   Workers        : Workers_CPU.Pool_Reference := null;
   Cache          : Cache_Precision := Exact;
   Status         : out E.Error_Info;
   Values         : Value_Precision := Same_As_Keys;
   Paged          : Boolean := False)
is
   Settings : Configuration;
   Capacity : Natural;
begin
   Close (Item);
   Status := E.Success;

   if not Source.Ready then
      Status := E.Make (E.Lifecycle_Model_Not_Ready);
      return;
   end if;

   Settings := Source.Settings;
   Capacity := (if Context = 0 then Settings.Context_Length else Context);

   --  And no more than the device's room was counted for, where Prepare
   --  counted it: the context grows on the device beside the matrices, and
   --  one let grow past what was set aside for it ran the part out of
   --  memory in the middle of a conversation.
   if Context = 0 and then Source.Device_Context > 0 then
      Capacity := Natural'Min (Capacity, Source.Device_Context);
   end if;

   --  Past the context the model was trained on only where the rotation
   --  was stretched for it, and never past what this session may hold.
   --
   --  A stretched rotation turns by a smaller angle a position, so more
   --  positions fit in the span of angles the model was trained over.
   --  Whether the answers past the trained length are worth having is a
   --  measurement and not a rule -- `### Past the context it was trained
   --  on` has the curve -- so this refuses the case where there is no
   --  mechanism at all and permits the case where there is one.
   if Capacity = 0
     or else (Capacity > Settings.Context_Length
              and then not Settings.Stretched)
     or else Capacity > Session_Bounds.Max_Context
   then
      Status := E.Make (E.Arch_Context_Too_Large);
      E.Add_Integer (Status, "requested", Long_Long_Integer (Capacity));
      E.Add_Integer
        (Status, "maximum", Long_Long_Integer (Settings.Context_Length));
      return;
   end if;

   --  A context nobody named is the model's own where the session can
   --  hold it, and otherwise the largest halving of it that fits. A
   --  declared context is a training fact and not a sizing one: qwen3-8b
   --  declares 40,960 positions, eighteen gigabytes of cache on a device,
   --  and a run that named none was refused where it could have run.
   --  A context that was named is held to, and refused as it was.
   if Context = 0 and then Session_Bounds.Max_Session_Bytes /= 0 then
      loop
         Plan_Session (Model (Source), Capacity, Item.Plan, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         exit when Session_Needs (Source, Item.Plan)
                     <= Session_Bounds.Max_Session_Bytes
           or else Capacity <= Least_Context;

         Capacity := Natural'Max (Least_Context, Capacity / 2);
      end loop;
   end if;

   Plan_Session (Model (Source), Capacity, Item.Plan, Status);
   if E.Is_Error (Status) then
      return;
   end if;

   --  What the plan says, recorded where a report can find it. Every
   --  figure here was already computed and then thrown away, so the
   --  account read zero for the KV cache while the session held it.
   Mem.Initialize
     (Item.Accounting, Model_Runner.Limits.Default_Model_Limits,
      Session_Bounds.Max_Session_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.KV_Cache, Item.Plan.KV_Cache_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.Activations,
      Item.Plan.Activation_Bytes + Item.Plan.Batch_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.Logits, Item.Plan.Logits_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.Sampling_Workspace, Item.Plan.Sampling_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.Token_Buffers,
      Item.Plan.Token_History_Bytes + Item.Plan.Decoder_Bytes);
   Mem.Record_Allocation
     (Item.Accounting, Mem.Template_Buffers,
      Item.Plan.Rendering_Bytes + Item.Plan.Stop_Bytes);

   --  What the session holds, against what it may.
   declare
      Needed : constant Interfaces.Unsigned_64 :=
        Session_Needs (Source, Item.Plan);
   begin
      if Session_Bounds.Max_Session_Bytes /= 0
        and then Needed > Session_Bounds.Max_Session_Bytes
      then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", "kv_cache", E.Param_Identifier);
         E.Add_Integer
           (Status, "requested", Long_Long_Integer (Needed),
            E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Session_Bounds.Max_Session_Bytes),
            E.Param_Bytes);
         return;
      end if;
   end;

   --  How the cache is cut up, before anything is allocated.
   --
   --  A layer that slides a window can never read further back than the
   --  window, so it is given the window and a margin rather than the
   --  whole context: the margin is what lets a batch be written and a
   --  run of tokens generated before the layer has to slide, and sliding
   --  moves only what the window still needs. A layer that attends to
   --  everything is given everything, which is what every layer had.
   --
   --  THE DEVICE KEEPS ITS OWN COPY OF THE CACHE AND WRITES IT A
   --  POSITION AT A TIME, so a host that slid its rows underneath would
   --  leave that copy describing positions that have moved. A session
   --  opened on a device holds the whole context for every layer, as it
   --  did, and the saving is the processor's for now.
   declare
      Layers : constant Natural := Settings.Layers;
      Room   : Element_Count := 0;
      Keys   : Element_Count := 0;
      Vals   : Element_Count := 0;

      --  How far past the window a layer runs before it slides.
      --
      --  A batch, because a batch is written before anything reads it
      --  and the room has to hold one whole, and the slack a slide keeps
      --  past the window for a rewind (Rewind_Slack), which the room
      --  holds beside the batch. Not more: what a slide
      --  costs is a window of rows moved every margin positions, which
      --  is a window over a batch of rows for every position written --
      --  eight of them on gemma2, against the six hundred megabytes of
      --  weights that position reads. What a larger margin would buy is
      --  fewer slides and a bigger cache, which is the trade this
      --  section exists to refuse.
      Margin : constant Element_Count :=
        Element_Count (Max_Batch) + Rewind_Slack;

      Windowed : constant Boolean := Settings.Window > 0;
   begin
      --  One entry a layer of the stack, and one more for each block
      --  past it, which attends in full over the same context and
      --  keeps its keys and values here like a layer of the stack.
      Item.Cells := new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
      Item.At_Keys := new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
      Item.At_Values := new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
      Item.At_Rows := new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
      Item.Origin := new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);

      for Layer in 0 .. Layers + Settings.Next_Layers - 1 loop
         Item.Cells.all (Layer) :=
           (if Layer < Layers and then Linear (Settings, Layer)
            --  A linear layer keeps a state instead, below.
            then 0
            elsif Layer < Layers and then Windowed
              and then Slides (Settings, Layer)
            then Element_Count'Min
                   (Element_Count (Capacity),
                    Element_Count (Settings.Window) + Margin)
            else Element_Count (Capacity));

         Item.At_Rows.all (Layer) := Room;
         Item.At_Keys.all (Layer) := Keys;
         Item.At_Values.all (Layer) := Vals;
         Item.Origin.all (Layer) := 0;

         Room := Room + Item.Cells.all (Layer);
         Keys := Keys
           + Item.Cells.all (Layer)
             * Element_Count (Settings.KV_Heads * Settings.Head_Size);
         Vals := Vals
           + Item.Cells.all (Layer)
             * Element_Count (Settings.KV_Heads * Settings.Value_Size);
      end loop;

      --  A session dealt its cache in pages rather than one block: how
      --  many pages each layer will hold, which is its cells rounded up
      --  to the page, and where each layer's pages begin in the flat
      --  Pages array. The bases themselves are set when the pages are
      --  taken, one slot at a time; here is only the shape. Pages are
      --  the device's, so a session on any other backend is dealt none
      --  and Paged stays false. Halves are paged as exact is: on the
      --  device they are its copy of an exact cache, read through the
      --  same tables. Left out, a session asking for them reserved its
      --  whole context as one block, which past one storage buffer
      --  left the device -- qwen3-8b at 32,768 positions read 3.55
      --  tokens a second where paged it reads 13.3.
      if Paged
        and then Model_Runner.Backend."="
                   (Source.Able.Kind,
                    Model_Runner.Backend.Backend_Device)
        and then Cache in Exact | Halved | Eighth | Fourth
      then
         Item.Paged := True;
         Item.Page_First :=
           new Cell_Counts (0 .. Layers + Settings.Next_Layers);
         Item.Page_Count :=
           new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
         Item.Page_Count.all := [others => 0];
         Item.Page_Table_At :=
           new Cell_Counts (0 .. Layers + Settings.Next_Layers - 1);
         Item.Page_Table_At.all := [others => 0];

         declare
            Total : Element_Count := 0;
         begin
            for Layer in 0 .. Layers + Settings.Next_Layers - 1 loop
               Item.Page_First.all (Layer) := Total;
               Total := Total
                 + (Item.Cells.all (Layer)
                    + Element_Count (Page_Positions) - 1)
                   / Element_Count (Page_Positions);
            end loop;

            Item.Page_First.all (Layers + Settings.Next_Layers) := Total;
            Item.Pages := new Cell_Counts (0 .. Natural'Max (Natural (Total), 1) - 1);
            Item.Pages.all := [others => 0];
         end;
      end if;
   end;

   declare
      Width : constant Element_Count :=
        Element_Count (Settings.Embedding);
      Feed  : constant Element_Count :=
        Element_Count (Feed_Width (Settings));
      Wide  : constant Element_Count :=
        Element_Count (Settings.Heads * Settings.Head_Size);
      Blend : constant Element_Count :=
        Element_Count (Settings.Heads * Settings.Value_Size);
      KV    : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Head_Size);
      KV_Out : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Value_Size);
      --  What the geometry above added up to: the positions every layer
      --  holds between them, which is the whole context a layer only
      --  where no layer slides a window.
      Rows  : constant Element_Count :=
        Item.At_Rows.all (Item.At_Rows.all'Last)
        + Item.Cells.all (Item.Cells.all'Last);
   begin
      --  One storage or the other, never both.
      --
      --  On the device, half precision is the device's: it keeps every
      --  position in both precisions and a token's attention reads the
      --  copy when asked, which is what a session asking for halves
      --  gets there, while the host's copy of record stays exact --
      --  the host reads it back only to save or roll a context, and a
      --  session that later runs on the processor runs exact. The
      --  device is told for the process, so the last session opened
      --  says; every session of a run asks for the same.
      if Model_Runner.Backend."="
           (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
        and then Cache in Exact | Halved
      then
         Model_Runner.Backend.Device.Attend_In_Halves (Cache = Halved);
         Item.Held := Exact;
         Item.Device_Halves :=
           Cache = Halved
           and then Model_Runner.Backend.Device.Attends_In_Halves;
      else
         Item.Held := Cache;
      end if;
      Item.Held_Values := Values_Held (Item.Held, Values);
      if not Stores_Pair (Item.Held, Values) then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Text (Status, "detail", "values stored apart from keys "
                     & "that are not packed", E.Param_Identifier);
         return;
      end if;

      case Item.Held is
         when Exact =>
            T.Allocate (Rows * KV, Item.Keys);
            T.Allocate (Rows * KV_Out, Item.Values);

         when Halved =>
            T.Allocate (Rows * KV, Item.Half_Keys);
            T.Allocate (Rows * KV_Out, Item.Half_Values);

         when Eighth | Fourth =>
            --  The bytes, and the scales: one a row a position a layer
            --  for the byte cache, one a block of thirty-two for the
            --  nibble cache, for the keys and again for the values.
            Item.Byte_Keys :=
              new B.Byte_Array
                (0 .. B.Byte_Count (Rows) * Row_Bytes (Item.Held, KV) - 1);
            Item.Byte_Values :=
              new B.Byte_Array
                (0 .. B.Byte_Count (Rows)
                      * Row_Bytes (Item.Held_Values, KV_Out) - 1);
            T.Allocate (Rows * Blocks_Of (Item.Held, KV), Item.Key_Scales);
            T.Allocate
              (Rows * Blocks_Of (Item.Held_Values, KV_Out), Item.Value_Scales);
      end case;

      --  The block past the stack keeps its own in full where the stack's
      --  are not: it drafts from them with the exact kernel, at any cache.
      if Settings.Next_Layers > 0 and then Item.Held /= Exact then
         T.Allocate (Item.Cells.all (Settings.Layers) * KV, Item.Next_Keys);
         T.Allocate (Item.Cells.all (Settings.Layers) * KV_Out, Item.Next_Values);
      end if;

      --  The cache in large pages where the host gives them: it is
      --  written a position at a time, and in ordinary pages a generated
      --  token's rows faulted in a page or two a layer.
      declare
         use System.Storage_Elements;

         procedure Advise (Start : System.Address; Length : Storage_Count)
         is
         begin
            if Length > 0 then
               Model_Runner.Zeroed_Storage.Prefer_Large (Start, Length);
            end if;
         end Advise;
      begin
         if Item.Keys /= null and then Item.Keys.all'Length > 0 then
            Advise (Item.Keys.all (Item.Keys.all'First)'Address,
                    Storage_Count (Item.Keys.all'Length) * 4);
         end if;
         if Item.Values /= null and then Item.Values.all'Length > 0 then
            Advise (Item.Values.all (Item.Values.all'First)'Address,
                    Storage_Count (Item.Values.all'Length) * 4);
         end if;
         if Item.Half_Keys /= null and then Item.Half_Keys.all'Length > 0
         then
            Advise (Item.Half_Keys.all (Item.Half_Keys.all'First)'Address,
                    Storage_Count (Item.Half_Keys.all'Length) * 2);
         end if;
         if Item.Half_Values /= null
           and then Item.Half_Values.all'Length > 0
         then
            Advise
              (Item.Half_Values.all (Item.Half_Values.all'First)'Address,
               Storage_Count (Item.Half_Values.all'Length) * 2);
         end if;
      end;
      T.Allocate (Width, Item.Activation);
      T.Allocate (Width, Item.Normalized);

      --  Room for a normalization taken out of the way. Gemma2 and
      --  Gemma3 normalize what a sublayer produced; Falcon keeps what the
      --  block normalized on the way in, because both of its sublayers
      --  read it. Different uses, one buffer, and both want it as wide as
      --  the embedding.
      --  Asked partly of the arrangement rather than wholly of a list,
      --  because a list is what an architecture gets left off. Nomic_Bert
      --  was: Join_Residual normalizes only where it has room to do it
      --  in, so a missing buffer is not a refusal but a residual that is
      --  never normalized, and the values grew until layer five could
      --  not hold them.
      if Source.Settings.Kind
           in Gemma2 | Gemma3 | Falcon | Phi2 | Olmo2 | Glm4 | Command_R
        or else Normalizes_After (Source.Settings.Kind)
      then
         T.Allocate (Width, Item.Post_Room);
      end if;

      if Source.Settings.Parallel_Residual
        or else (for some L of Source.Layers.all =>
                   L.Second_Attention_Norm /= null)
      then
         T.Allocate (Width, Item.Kept_Input);
      end if;

      T.Allocate (Wide, Item.Query);
      T.Allocate (KV, Item.Key_Row);
      T.Allocate (KV_Out, Item.Value_Row);
      T.Allocate (Blend, Item.Attention);

      --  DeepSeek's latent scratch, where the model attends through one.
      if Is_MLA (Settings.Kind) then
         T.Allocate
           (Element_Count (Natural'Max (1, Settings.Q_Lora_Rank)),
            Item.MLA_Q_Lat);
         T.Allocate
           (Element_Count (Settings.KV_Lora_Rank + Settings.Rotary),
            Item.MLA_KV_Lat);
         T.Allocate
           (Element_Count (Settings.KV_Lora_Rank), Item.MLA_C_Norm);
         T.Allocate
           (Element_Count
              (Settings.Heads
               * (Settings.Head_Size - Settings.Rotary
                  + Settings.Value_Size)),
            Item.MLA_KV);
      end if;
      Item.Score_Room := Element_Count (Capacity);
      T.Allocate
        (Element_Count (Natural'Max (1, Settings.Heads))
         * Item.Score_Room, Item.Scores);
      T.Allocate (Feed, Item.Gate);
      T.Allocate (Feed, Item.Up);

      --  A mixture's chosen experts all read the same input, so their
      --  gate and up matrices go over as one group. A group's targets
      --  are separate arrays, and they are the same shape every layer,
      --  so they are taken once here rather than a layer.
      if Settings.Experts > 0 and then Settings.Experts_Used > 0 then
         Item.Expert_Arms :=
           new T.Group_Room (1 .. 2 * Settings.Experts_Used);

         for Index in Item.Expert_Arms.all'Range loop
            T.Allocate
              (Element_Count (Settings.Expert_Feed),
               Item.Expert_Arms.all (Index));
         end loop;

         --  And the down projections as one group, which only the
         --  device takes: a group laid end to end wants a backend that
         --  can give each matrix its own stretch of one activation, and
         --  what it saves is a submission, which the processor does not
         --  pay.
         if Model_Runner.Backend."="
              (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
         then
            T.Allocate
              (Element_Count (Settings.Experts_Used)
               * Element_Count (Settings.Expert_Feed),
               Item.Expert_Feeds);

            Item.Expert_Outs :=
              new T.Group_Room (1 .. Settings.Experts_Used);

            for Index in Item.Expert_Outs.all'Range loop
               T.Allocate (Width, Item.Expert_Outs.all (Index));
            end loop;
         end if;
      end if;
      T.Allocate (Element_Count (Settings.Vocabulary), Item.Logit_Row);
      Item.History := new Token_History (0 .. Capacity - 1);
      if Settings.Sections /= K.No_Sections then
         Item.Marks := new Rope_Marks (0 .. Capacity - 1);
         Item.Marked := 0;
      end if;

      --  What a hybrid's layers keep and pass through: the gate beside
      --  the heads, a linear layer's rows on the way through, its
      --  convolution's memory and its state, and a mixture's shared
      --  expert's arms.
      if Hybrid (Settings.Kind) then
         declare
            Linears : Natural := 0;
         begin
            for Layer in 0 .. Settings.Layers - 1 loop
               if Linear (Settings, Layer) then
                  Linears := Linears + 1;
               end if;
            end loop;

            --  The query projection's whole answer, twice as wide as
            --  the queries: each head's queries and then its gate,
            --  split out from here into the two rows the rest reads.
            T.Allocate (2 * Wide, Item.Query_Full);

            --  And what the block past the stack takes in and what
            --  it is given: the last position's final state, and the
            --  two normalized halves side by side.
            if Settings.Next_Layers > 0 then
               T.Allocate (Width, Item.Last_Final);
               T.Allocate (2 * Width, Item.Next_Input);
            end if;
            T.Allocate (Wide, Item.Head_Gate);
            T.Allocate (Element_Count (Mix_Width (Settings)), Item.Mix_Row);
            T.Allocate (Element_Count (Value_Width (Settings)), Item.Z_Row);
            T.Allocate (Element_Count (Settings.Value_Heads), Item.Alpha_Row);
            T.Allocate (Element_Count (Settings.Value_Heads), Item.Beta_Row);
            T.Allocate
              (Element_Count (Value_Width (Settings)), Item.Blend_Row);
            T.Allocate (Conv_Room (Settings), Item.Conv_State);
            T.Allocate (State_Room (Settings), Item.Delta_State);
            Item.Kept_States := 0;
            Item.Kept_Newest := 0;

            if Settings.Shared_Feed > 0 then
               T.Allocate
                 (Element_Count (Settings.Shared_Feed), Item.Shared_Row);
               T.Allocate
                 (Element_Count (Settings.Shared_Feed), Item.Shared_Up_Row);
               T.Allocate (Width, Item.Shared_Out_Row);
            end if;

            if Item.Head_Gate = null or else Item.Query_Full = null
              or else Item.Mix_Row = null
              or else Item.Z_Row = null or else Item.Alpha_Row = null
              or else Item.Beta_Row = null or else Item.Blend_Row = null
              or else Item.Conv_State = null or else Item.Delta_State = null
              or else (Settings.Shared_Feed > 0
                       and then (Item.Shared_Row = null
                                 or else Item.Shared_Up_Row = null
                                 or else Item.Shared_Out_Row = null))
            then
               Close (Item);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;

            Item.Conv_State.all := [others => 0.0];
            Item.Delta_State.all := [others => 0.0];
         end;
      end if;

      --  The shared expert's rows, for a mixture that has one and is not
      --  the hybrid, which makes them with the rest of its own above:
      --  DeepSeek2's two shared experts run on every mixture layer.
      if Settings.Shared_Feed > 0 and then Item.Shared_Row = null then
         T.Allocate
           (Element_Count (Settings.Shared_Feed), Item.Shared_Row);
         T.Allocate
           (Element_Count (Settings.Shared_Feed), Item.Shared_Up_Row);
         T.Allocate (Width, Item.Shared_Out_Row);
         if Item.Shared_Row = null or else Item.Shared_Up_Row = null
           or else Item.Shared_Out_Row = null
         then
            Close (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      --  Mamba keeps a state a session as a hybrid's linear layers do:
      --  the convolution's last positions and the scan's state, one slot,
      --  cleared. It does not draft or rewind, so the ring never grows
      --  past the one slot. Beside them the scratch one position needs.
      --  Jamba keeps the same, for its Mamba layers alone -- the rooms
      --  count only those, through Linear.
      if Pure_SSM (Settings.Kind) or else Is_Jamba (Settings.Kind) then
         declare
            Inner : constant Element_Count :=
              Element_Count (Settings.Inner_Size);
            State : constant Element_Count :=
              Element_Count (Settings.State_Size);
            DBC   : constant Element_Count :=
              Element_Count (Settings.Time_Rank) + 2 * State;

            --  Mamba2's convolution block and its one projection in: the
            --  gate, that block and a step a head laid end to end.
            DXBC   : constant Element_Count :=
              Inner + 2 * Element_Count (Settings.Groups) * State;
            In_Out : constant Element_Count :=
              Inner + DXBC + Element_Count (Settings.Ssm_Heads);
         begin
            T.Allocate (Conv_Room (Settings), Item.Conv_State);
            T.Allocate (State_Room (Settings), Item.Delta_State);
            Item.Kept_States := 0;
            Item.Kept_Newest := 0;
            if Item.Conv_State /= null then
               Item.Conv_State.all := [others => 0.0];
            end if;
            if Item.Delta_State /= null then
               Item.Delta_State.all := [others => 0.0];
            end if;

            if Is_Mamba2 (Settings.Kind) then
               --  XZ holds the whole projection in (z, x, B, C, dt); X
               --  the convolution block (x, B, C); DT a step a head; Y
               --  the scan's answer. DBC and DTR are Mamba's alone.
               T.Allocate (In_Out, Item.Mamba_XZ);
               T.Allocate (DXBC, Item.Mamba_X);
               T.Allocate (Element_Count (Settings.Ssm_Heads), Item.Mamba_DT);
               T.Allocate (Inner, Item.Mamba_Y);
            else
               T.Allocate (2 * Inner, Item.Mamba_XZ);
               T.Allocate (Inner, Item.Mamba_X);
               T.Allocate (DBC, Item.Mamba_DBC);
               T.Allocate
                 (Element_Count (Settings.Time_Rank), Item.Mamba_DTR);
               T.Allocate (Inner, Item.Mamba_DT);
               T.Allocate (Inner, Item.Mamba_Y);
               T.Allocate (Inner, Item.Mamba_Steps);
               T.Allocate (Inner * State, Item.Mamba_Decays);
            end if;
         end;
      end if;

      --  RWKV6 keeps a state a session as Mamba does: the two token-shift
      --  slots in the convolution memory and the linear-attention state
      --  in the delta state, one slot, cleared, no draft or rewind.
      --  Beside them the scratch one position through the block needs.
      if Is_RWKV (Settings.Kind) then
         declare
            RW   : constant Element_Count :=
              Element_Count (Settings.Embedding);
            Feed : constant Element_Count :=
              Element_Count (Settings.Feed_Forward);
         begin
            T.Allocate (Conv_Room (Settings), Item.Conv_State);
            T.Allocate (State_Room (Settings), Item.Delta_State);
            Item.Kept_States := 0;
            Item.Kept_Newest := 0;
            if Item.Conv_State /= null then
               Item.Conv_State.all := [others => 0.0];
            end if;
            if Item.Delta_State /= null then
               Item.Delta_State.all := [others => 0.0];
            end if;

            T.Allocate (RW, Item.Rwkv_N1);
            T.Allocate (RW, Item.Rwkv_Inp);
            T.Allocate (RW, Item.Rwkv_N2);
            T.Allocate (RW, Item.Rwkv_Mix);
            T.Allocate (5 * RW, Item.Rwkv_Lora);
            T.Allocate
              (5 * Element_Count (Settings.Mix_Extra), Item.Rwkv_WLora);
            T.Allocate (RW, Item.Rwkv_Rr);
            T.Allocate (RW, Item.Rwkv_Kk);
            T.Allocate (RW, Item.Rwkv_Vv);
            T.Allocate (RW, Item.Rwkv_Gg);
            T.Allocate (RW, Item.Rwkv_Ww);
            T.Allocate (RW, Item.Rwkv_Y);
            T.Allocate (Feed, Item.Rwkv_CK);
         end;
      end if;

      --  An architecture that normalizes its heads needs room for one,
      --  whether the plain way (Query_Norm) or Command-R+'s centred way
      --  (Query_Head_Norm).
      if Settings.Head_Size > 0
        and then Source.Layers /= null
        and then (for some L of Source.Layers.all =>
                    L.Query_Norm /= null or else L.Query_Head_Norm /= null)
      then
         T.Allocate (Element_Count (Settings.Head_Size), Item.Head_Row);
         if Item.Head_Row = null then
            Close (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      --  A mixture of experts needs three more, and a dense model needs
      --  none of them: allocating them anyway would charge every model
      --  for a feature almost none of them have.
      if Settings.Experts > 0 then
         T.Allocate (Element_Count (Settings.Experts), Item.Routing);
         T.Allocate (Width, Item.Mixture);
         T.Allocate (Width, Item.Expert_Row);

         if Item.Routing = null or else Item.Mixture = null
           or else Item.Expert_Row = null
         then
            Close (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      if (Item.Held = Exact
          and then (Item.Keys = null or else Item.Values = null))
        or else (Item.Held = Halved
                 and then (Item.Half_Keys = null
                           or else Item.Half_Values = null))
        or else (Item.Held in Eighth | Fourth
                 and then (Item.Byte_Keys = null
                           or else Item.Byte_Values = null
                           or else Item.Key_Scales = null
                           or else Item.Value_Scales = null))
        or else Item.Activation = null or else Item.Normalized = null
        or else Item.Query = null or else Item.Key_Row = null
        or else Item.Value_Row = null or else Item.Attention = null
        or else Item.Scores = null or else Item.Gate = null
        or else Item.Up = null or else Item.Logit_Row = null
      then
         Close (Item);
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
   end;

   Item.Owner := Source'Unchecked_Access;
   Item.Team := Workers;

   --  The arithmetic, fixed for the session's life: the backend's
   --  default as it stands now, read once here and never again while
   --  the session runs.
   Item.Arithmetic := Workers_CPU.Integer_Activation_Roles;
   Item.Context := Capacity;
   Item.Committed := 0;
   Item.Current := Ready;
   Source.Sessions := Source.Sessions + 1;
exception
   when others =>
      Close (Item);
      Status := E.Make (E.Memory_Allocation_Failed);
end Open;
