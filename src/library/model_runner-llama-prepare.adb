separate (Model_Runner.Llama)
procedure Prepare
  (Item     : in out Model;
   Source   : Containers.Container;
   Bytes    : in out Model_Runner.Byte_Sources.Source'Class;
   Bounds   : Model_Runner.Limits.Model_Limits :=
     Model_Runner.Limits.Default_Model_Limits;
   Cancel   : Model_Runner.Cancellation.Token_Reference := null;
   Observer : Model_Runner.Progress.Observer_Reference := null;
   Backend  : Model_Runner.Backend.Backend_Kind :=
     Model_Runner.Backend.Backend_CPU;
   Repack   : Repack_Mode := No_Repack;
   Fit_Required : Boolean := True;
   Threads  : Positive := 1;
   Status   : out E.Error_Info;
   Stretch  : Rotary_Request := No_Rotary_Request;
   Panel_Cache : String := "";
   Context  : Natural := 0;
   Cache    : Cache_Precision := Exact)
is
   Ignored : E.Error_Info;

   --  When the weights' rewrite began, for what it cost.
   Repack_Clock   : Model_Runner.Clocks.System_Clock;
   Repack_Started : Model_Runner.Clocks.Nanoseconds := 0;

   --  Whether a dense model the device's room does not take whole is
   --  split: its top layers' feed-forward left to the processor.
   Dense_Split : Boolean := False;

   --  The bytes a view's storage takes, or none where there is no view.
   function Bytes_Of (View : T.View) return Interfaces.Unsigned_64
   is (if T.Is_Present (View)
       then Interfaces.Unsigned_64 (View.Rows) * Interfaces.Unsigned_64 (T.Row_Bytes (View))
       else 0);

   --  Whether a view is the gate, up or down of a layer whose
   --  feed-forward the processor runs.
   function Host_Fed (Where : View_Access) return Boolean is
   begin
      if Item.Layers /= null then
         for Index in Item.Layers.all'Range loop
            declare
               L : Layer renames Item.Layers.all (Index);
            begin
               if L.Host_Feed
                 and then (Where = L.Gate'Unchecked_Access
                           or else Where = L.Up'Unchecked_Access
                           or else Where = L.Down'Unchecked_Access)
               then
                  return True;
               end if;
            end;
         end loop;
      end if;
      return False;
   end Host_Fed;

   --  Abandon preparation, releasing every resource acquired so far.
   procedure Fail (Reason : E.Error_Info) is
   begin
      Close (Item, Ignored);
      Status := Reason;
   end Fail;

begin
   Close (Item, Ignored);
   Status := E.Success;

   if not Containers.Is_Valid (Source) then
      Fail (E.Make (E.Lifecycle_Model_Not_Ready));
      return;
   end if;

   --  A shard of a model rather than a model.
   --
   --  A file split off a larger one is a perfectly well-formed container
   --  holding a third of the tensors, so nothing before this point has
   --  any reason to object -- and what used to happen next was a refusal
   --  naming the first tensor the architecture wanted and did not find,
   --  which sends a reader after their model instead of after their
   --  command. The count of tensors the shards hold between them is
   --  written in every one of them, so the question can simply be asked.
   declare
      Across : constant Natural := Containers.Shard_Tensor_Count (Source);
   begin
      if Containers.Shard_Count (Source) > 1
        and then Across /= 0
        and then Containers.Tensor_Count (Source) /= Across
      then
         Fail (E.Make (E.GGUF_Shards_Missing));
         E.Add_Integer
           (Status, "index",
            Long_Long_Integer (Containers.Shard_Index (Source) + 1));
         E.Add_Integer
           (Status, "count",
            Long_Long_Integer (Containers.Shard_Count (Source)));
         return;
      end if;
   end;

   Mem.Initialize (Item.Accounting, Bounds, Bounds.Max_Model_Bytes);

   --  Room for what every matrix will be called. One entry a tensor the
   --  file holds, which is more than the matrices among them and is the
   --  bound rather than the count.
   Item.Named := new Named_View_List (1 .. Containers.Tensor_Count (Source));
   Item.Named_Up := 0;

   --  The backend's own account of what it can do, taken once and kept
   --  with the model. The case has no others: a backend added to the
   --  enumeration stops this compiling until it says what it can read,
   --  which is the point of asking rather than assuming.
   P.Publish (Observer, P.Load_Progress (P.Selecting_Backend));
   case Backend is
      when Model_Runner.Backend.Backend_CPU =>
         Item.Able := Workers_CPU.Describe;
      when Model_Runner.Backend.Backend_Reference =>
         Item.Able := Model_Runner.Backend.Reference.Describe;
      when Model_Runner.Backend.Backend_Device =>
         Item.Able := Model_Runner.Backend.Device.Describe;
   end case;

   --  Evaluation is matrix by vector and nothing else. A backend that
   --  cannot do that cannot run a model, and says so here rather than
   --  part way through the first token.
   if not Item.Able.Supports_Matrix_Vector then
      Fail (E.Make (E.Backend_Capability_Missing));
      E.Add_Text
        (Status, "capability", "matrix_vector", E.Param_Identifier);
      E.Add_Text
        (Status, "backend",
         Model_Runner.Backend.Backend_Name (Item.Able.Kind),
         E.Param_Identifier);
      return;
   end if;

   P.Publish (Observer, P.Load_Progress (P.Selecting_Architecture));
   Read_Configuration (Source, Bounds, Item.Settings, Status);
   if E.Is_Ok (Status) then
      Item.Settings.Trained_Context := Item.Settings.Context_Length;
      Apply_Stretch (Item.Settings, Stretch, Status);
   end if;
   if E.Is_Error (Status) then
      Fail (Status);
      return;
   end if;

   P.Publish (Observer, P.Load_Progress (P.Loading_Tokenizer));
   Model_Runner.Tokenizer.Load (Item.Words, Source, Bounds, Status);
   if E.Is_Error (Status) then
      Fail (Status);
      return;
   end if;

   Item.Settings.Vocabulary := Model_Runner.Tokenizer.Size (Item.Words);

   --  The vocabulary's own storage and the container's metadata pool.
   --  Both are megabytes on a real model and neither was counted, so the
   --  account said the program held the weights and nothing else.
   Mem.Record_Allocation
     (Item.Accounting, Mem.Tokenizer_Storage,
      Interfaces.Unsigned_64
        (Model_Runner.Tokenizer.Storage_Bytes (Item.Words)));
   Mem.Record_Allocation
     (Item.Accounting, Mem.Metadata_Storage,
      Containers.Metadata_Bytes (Source));

   --  Chat template. An embedded template is untrusted data: it is compiled
   --  and validated here, before anything can be generated with it. A
   --  template outside the supported subset leaves the model usable in raw
   --  mode and records why conversation mode is unavailable.
   P.Publish (Observer, P.Load_Progress (P.Compiling_Template));
   declare
      Source_Text : constant String :=
        Containers.String_Value (Source, "tokenizer.chat_template");
   begin
      Item.Chat_Present := Source_Text /= "";
      if Item.Chat_Present then
         Model_Runner.Templates.Compile
           (Item.Chat, Source_Text, Bounds, Item.Chat_Status);

         --  A template that compiles is asked to render the plainest
         --  conversation there is, one user turn and the generation
         --  prompt, here rather than at the first prompt. The engine
         --  refuses a construct it lacks where the construct is read
         --  and not where the template is compiled, so a template can
         --  compile and still render nothing: Qwen3-Coder's own does,
         --  its macro compiling now and its "is iterable" refusing at
         --  once. Such a template is as unusable as one that will not
         --  compile, and is stood in for the same way.
         if E.Is_Ok (Item.Chat_Status) then
            declare
               Probe  : Model_Runner.Conversation.History;
               Room   : String (1 .. 4096);
               Used   : Natural;
               Status : E.Error_Info;
            begin
               Model_Runner.Conversation.Open (Probe, Status => Status);
               Model_Runner.Conversation.Append
                 (Probe, Model_Runner.Conversation.User_Role, "x",
                  Status);
               Model_Runner.Templates.Render
                 (Item.Chat, Probe, "", "", True, Room, Used, Status);
               Model_Runner.Conversation.Close (Probe);
               if Status.Code in E.Template_Unsupported_Construct
                               | E.Template_Unknown_Filter
                               | E.Template_Unknown_Variable
               then
                  Item.Chat_Status := Status;
               end if;
            end;
         end if;

         --  A template outside the subset that is nonetheless written in
         --  a format this build carries -- its own text says which, by
         --  the turn markers and the call shape in it -- is rendered with
         --  that format instead. Only then: a template that compiles and
         --  renders is what the model was trained on and nothing
         --  replaces it, and a template no carried format is recognised
         --  in leaves the model in raw mode as before. The stand-in is
         --  compiled the same way and refused the same way, so a carried
         --  format that will not compile against these bounds changes
         --  nothing.
         if E.Is_Error (Item.Chat_Status) then
            declare
               Name  : constant String :=
                 Model_Runner.Templates.Recognise (Source_Text);
               Again : E.Error_Info;
            begin
               if Name /= "" then
                  Model_Runner.Templates.Close (Item.Chat);
                  Model_Runner.Templates.Compile
                    (Item.Chat, Model_Runner.Templates.Built_In (Name),
                     Bounds, Again);
                  if E.Is_Ok (Again) then
                     Item.Chat_Status := Again;
                     Set_Template_Format (Item, Name);
                     Item.Chat_Stood_In := True;
                  end if;
               end if;
            end;
         end if;
      else
         Item.Chat_Status := E.Make (E.Template_Missing);
      end if;
   end;

   P.Publish (Observer, P.Load_Progress (P.Planning_Memory));

   --  Load the whole tensor data section into one arena. Every tensor view
   --  then refers to a slice of it, so there is exactly one large
   --  allocation for model weights and no second unquantized copy.
   declare
      Length : constant B.Byte_Count :=
        B.Byte_Count (Containers.Tensor_Data_Bytes (Source));
   begin
      Item.Arena_Base := B.Byte_Count (Containers.Data_Offset (Source));

      --  Where the source says its bytes already are. A mapped file
      --  answers with its mapping, and then nothing is allocated and
      --  nothing is copied: the weights are the file's own pages, faulted
      --  in as they are read. A source that cannot say answers with
      --  nothing and is read into an arena, as every source was.
      --  Only a mapping is borrowed, and only when it holds the whole
      --  tensor section. A source that is already an array in this
      --  process could say where it is too, and is not asked: that array
      --  belongs to whoever passed it and may be freed while the model
      --  still refers to it, where a mapping belongs to the source and
      --  lives exactly as long as it does.
      if Bytes.Is_Mapped
        and then Bytes.Base /= System.Null_Address
        and then Bytes.Size >= Item.Arena_Base + Length

        --  Unless the device was opened to read the weights where they
        --  lie. Both ways avoid a copy and they are exclusive: the driver
        --  imports host memory it can pin and refuses a file's pages, so
        --  a caller who asked for the device to take the model's memory
        --  is given memory the device will take.
        and then not
          (Model_Runner.Backend."="
             (Backend, Model_Runner.Backend.Backend_Device)
           and then Model_Runner.Backend.Device.Shares_Host)
      then
         Item.Weights_Base :=
           System.Storage_Elements.To_Address
             (System.Storage_Elements.To_Integer (Bytes.Base)
              + System.Storage_Elements.Integer_Address (Item.Arena_Base));
         Item.Weights_Span := Length;
         Item.Weights_Held := False;

         --  Counted as what it is. A read-only mapping costs address
         --  space rather than resident pages, so it is not charged
         --  against the memory limit and does not appear as memory this
         --  program is holding -- which is the whole of the difference
         --  between mapping a model and reading one.
         Mem.Record_Mapping
           (Item.Accounting, Interfaces.Unsigned_64 (Length));
      else
         Mem.Check_Allocation
           (Item.Accounting, Mem.Model_Weights,
            Interfaces.Unsigned_64 (Length), Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         B.Allocate (Length, Item.Arena);
         if Item.Arena = null then
            Fail (E.Make (E.Memory_Allocation_Failed));
            return;
         end if;

         Mem.Record_Allocation
           (Item.Accounting, Mem.Model_Weights,
            Interfaces.Unsigned_64 (Length));

         Item.Weights_Base := Item.Arena.all'Address;
         Item.Weights_Span := B.Byte_Count (Item.Arena.all'Length);
         Item.Weights_Held := True;
      end if;

      --  The file is validated, and now it is read. Between those two
      --  moments it may have been replaced -- a download finishing over
      --  it, a build writing a new quantization to the same path -- and
      --  what would then be read is a different file wearing the shape of
      --  the one that was checked. Asked here because here is the last
      --  moment it is still true that nothing has been read.
      if Bytes.Changed then
         Fail (E.Make (E.GGUF_File_Changed));
         return;
      end if;

      P.Publish (Observer, P.Load_Progress (P.Preparing_Tensors));

      if Item.Weights_Held then
         Bytes.Read (Item.Arena_Base, Item.Arena.all, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end if;
   end;

   if C.Is_Cancelled (Cancel) then
      Fail (E.Make (E.Generation_Cancelled));
      return;
   end if;

   declare
      Width  : constant Element_Count :=
        Element_Count (Item.Settings.Embedding);
      Vocab  : constant Element_Count :=
        Element_Count (Item.Settings.Vocabulary);
      Feed   : constant Element_Count :=
        Element_Count (Item.Settings.Feed_Forward);
      --  What the attention tensors are shaped by. The queries are as
      --  many heads of key width; the keys are the key-value heads of the
      --  same; the values are those heads of value width; and what the
      --  output projection reads is the heads' worth of value width,
      --  which is the embedding width only when the two agree.
      Wide   : constant Element_Count :=
        Element_Count (Item.Settings.Heads * Item.Settings.Head_Size);
      KV     : constant Element_Count :=
        Element_Count (Item.Settings.KV_Heads * Item.Settings.Head_Size);
      KV_Out : constant Element_Count :=
        Element_Count (Item.Settings.KV_Heads * Item.Settings.Value_Size);
      Blend  : constant Element_Count :=
        Element_Count (Item.Settings.Heads * Item.Settings.Value_Size);
      --  One block resolved, of the stack or past it. A procedure
      --  rather than the loop's body so that the blocks past the stack
      --  are resolved by the same words: they are full attention layers
      --  with a projection in front and a normalization behind.
      procedure Resolve_Block
        (Index   : Natural;
         Beyond  : Boolean;
         Current : in out Layer)
      is
         --  Whether this is a linear attention layer, which keeps no
         --  keys and values and has projections of its own.
         Is_Linear : constant Boolean :=
           not Beyond and then Linear (Item.Settings, Index);
      begin
         --  The normalization a block is given on the way in. Every
         --  architecture here has one except Bert, which normalizes
         --  on the way out of each sublayer instead and carries no
         --  tensor for this at all.
         if not Normalizes_After (Item.Settings.Kind)
           and then Item.Settings.Kind /= Olmo2
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_norm.weight"),
               Width, Current.Attention_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Bert's two, which are the whole of its normalization: one
         --  over the residual after attention has been added to it,
         --  one over the residual after the feed-forward has. Both
         --  centre and both carry a shift, so both take a bias where
         --  Gemma2's post-normalizations take none.
         --
         --  They are read into the same two fields Gemma2 uses and
         --  applied in a different place, which is the whole
         --  difference between the two arrangements: Gemma2
         --  normalizes what the sublayer produced and adds that,
         --  and Bert adds what the sublayer produced and normalizes
         --  the sum.
         if Normalizes_After (Item.Settings.Kind) then
            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "attn_output_norm.weight"), Width,
               Current.Post_Attention_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "attn_output_norm.bias"), Width,
               Current.Post_Attention_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "layer_output_norm.weight"), Width,
               Current.Post_Feed_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "layer_output_norm.bias"), Width,
               Current.Post_Feed_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  What the code variant of this architecture carries and
         --  the text one does not: a centred normalization over the
         --  whole of the queries and another over the whole of the
         --  keys, and a third normalization of the attention sublayer.
         --  Six tensors with their biases, wanted all together where
         --  the file carries any one of them: a file with some would
         --  otherwise be read as a model with a normalization or two
         --  missing -- which is an embedding, and a plausible one.
         if Item.Settings.Kind = Jina_Bert_V2
           and then (for some Name of Jina_Code_Norms =>
                       Containers.Find_Tensor
                         (Source, Layer_Key (Index, Name.all)) /= 0)
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q_norm.weight"),
               Wide, Current.Query_Whole_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q_norm.bias"),
               Wide, Current.Query_Whole_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k_norm.weight"),
               KV, Current.Key_Whole_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k_norm.bias"),
               KV, Current.Key_Whole_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_norm_2.weight"),
               Width, Current.Second_Attention_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_norm_2.bias"),
               Width, Current.Second_Attention_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

         elsif Item.Settings.Kind = Olmo2 then
            --  OLMo2 normalizes the whole of the query projection and
            --  the whole of the key projection, root-mean-square and
            --  without a shift, in place of the per-head normalization
            --  qwen3 does under the same two tensor names. Required, not
            --  taken if present: every OLMo2 layer carries them.
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q_norm.weight"),
               Wide, Current.Query_Whole_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k_norm.weight"),
               KV, Current.Key_Whole_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Gemma2 normalizes what each sublayer produced as well as
         --  what it was given. Required rather than optional: a
         --  gemma2 file without them is not one this build can
         --  compute, and taking them if present would read such a
         --  file as a model with two normalizations missing.
         if Item.Settings.Kind in Gemma2 | Gemma3 | Olmo2 | Glm4 then
            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "post_attention_norm.weight"), Width,
               Current.Post_Attention_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "post_ffw_norm.weight"), Width,
               Current.Post_Feed_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Three projections out of one tensor where the
         --  architecture fuses them, and three tensors where it does
         --  not. The order inside the fused one is queries, then
         --  keys, then values, which is the order the rows are
         --  written in.
         if Item.Settings.Kind in Falcon | Phi2 | GPT2 | Starcoder2
                                | Stablelm | Gptneox | Rwkv6
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_norm.bias"),
               Width, Current.Attention_Norm_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         if Is_Linear
           and then (Pure_SSM (Item.Settings.Kind)
                     or else Is_Jamba (Item.Settings.Kind))
         then
            --  Mamba's block, all of it a linear layer: the input split
            --  into an inner activation and its gate, a causal
            --  convolution over the inner activation with a bias, the
            --  inner activation projected to the time step and to B and
            --  C, the time step projected up with a bias, the state
            --  transition a state a channel, the skip a channel, and the
            --  projection back. No queries, keys or values, no attention.
            declare
               Inner : constant Element_Count :=
                 Element_Count (Item.Settings.Inner_Size);
               State : constant Element_Count :=
                 Element_Count (Item.Settings.State_Size);
               Rank  : constant Element_Count :=
                 Element_Count (Item.Settings.Time_Rank);
               Taps  : constant Element_Count :=
                 Element_Count (Item.Settings.Conv_Kernel);
               Group : constant Element_Count :=
                 Element_Count (Item.Settings.Groups);
               Heads : constant Element_Count :=
                 Element_Count (Item.Settings.Ssm_Heads);

               --  The block the convolution runs over -- the inner width
               --  and B and C beside it -- and the whole of the in
               --  projection's output: the gate, that block, and a time
               --  step a head.
               DXBC   : constant Element_Count :=
                 Inner + 2 * Group * State;
               In_Out : constant Element_Count := Inner + DXBC + Heads;
            begin
               if Is_Mamba2 (Item.Settings.Kind) then
                  --  Mamba2's one projection in: the gate, the inner
                  --  activation, B and C, and the time step a head, all
                  --  from the model width. The convolution runs over the
                  --  inner activation with B and C; A, D and the step's
                  --  bias are a head; the gated normalization is the inner
                  --  width; and the projection out is the same as Mamba's.
                  --  No ssm_x or ssm_dt matrices: B, C and the step come
                  --  straight out of the split.
                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_in.weight"),
                     In_Out, Width, Current.Ssm_In, Status, Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Table
                    (Item, Source, Layer_Key (Index, "ssm_conv1d.weight"),
                     DXBC, Taps, Current.Conv, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_conv1d.bias"),
                     DXBC, Current.Conv_Bias, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  --  A number a head, which the file keeps as a head a
                  --  row of one -- llama.cpp's {1, n_head} -- rather than
                  --  as one row of heads; read as the table it is, the
                  --  same numbers in the same order.
                  Resolve_Table
                    (Item, Source, Layer_Key (Index, "ssm_a"),
                     Heads, 1, Current.Ssm_A, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Table
                    (Item, Source, Layer_Key (Index, "ssm_d"),
                     Heads, 1, Current.Ssm_D, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_dt.bias"),
                     Heads, Current.DT_Bias, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_norm.weight"),
                     Inner, Current.State_Norm, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_out.weight"),
                     Width, Inner, Current.Linear_Out, Status, Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               else
                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_in.weight"),
                     2 * Inner, Width, Current.Ssm_In, Status, Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Table
                    (Item, Source, Layer_Key (Index, "ssm_conv1d.weight"),
                     Inner, Taps, Current.Conv, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_conv1d.bias"),
                     Inner, Current.Conv_Bias, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_x.weight"),
                     Rank + 2 * State, Inner, Current.Ssm_X, Status,
                     Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  --  Jamba's three normalizations of the slices ssm_x
                  --  produced: the time step, and the B and C the scan
                  --  reads, each by root mean square with its own gain.
                  if Is_Jamba (Item.Settings.Kind) then
                     Resolve_Norm
                       (Item, Source,
                        Layer_Key (Index, "ssm_dt_norm.weight"),
                        Rank, Current.Ssm_Dt_Norm, Status);
                     if E.Is_Ok (Status) then
                        Resolve_Norm
                          (Item, Source,
                           Layer_Key (Index, "ssm_b_norm.weight"),
                           State, Current.Ssm_B_Norm, Status);
                     end if;
                     if E.Is_Ok (Status) then
                        Resolve_Norm
                          (Item, Source,
                           Layer_Key (Index, "ssm_c_norm.weight"),
                           State, Current.Ssm_C_Norm, Status);
                     end if;
                     if E.Is_Error (Status) then
                        return;
                     end if;
                  end if;

                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_dt.weight"),
                     Inner, Rank, Current.Ssm_Dt, Status, Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_dt.bias"),
                     Inner, Current.DT_Bias, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Table
                    (Item, Source, Layer_Key (Index, "ssm_a"),
                     Inner, State, Current.Ssm_A, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "ssm_d"),
                     Inner, Current.Ssm_D, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Resolve
                    (Item, Source, Layer_Key (Index, "ssm_out.weight"),
                     Width, Inner, Current.Linear_Out, Status, Repack);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end if;
            end;
         elsif Is_Linear and then Is_RWKV (Item.Settings.Kind) then
            --  RWKV6's block: its second normalization (ln2, the channel
            --  mix's input; ln1 was read above with the rest), the five
            --  matrices the time mix projects a token through and the
            --  channel mix's three -- all through the product, repacked
            --  like any other -- and the vectors the product does not
            --  touch: the shift's interpolation and its data-dependent
            --  two low projections, the decay's bias and its two, the
            --  first token's bonus, the per-head normalization's gain and
            --  shift, the five streams' interpolation, and the channel
            --  mix's two shifts. The low projections are read whole and
            --  multiplied by hand, being small; the eight wide matrices
            --  go through the product.
            declare
               RW    : constant Element_Count :=
                 Element_Count (Item.Settings.Embedding);
               Feed  : constant Element_Count :=
                 Element_Count (Item.Settings.Feed_Forward);
               D_TM  : constant Element_Count :=
                 Element_Count (Item.Settings.Mix_Extra);
               D_Dec : constant Element_Count :=
                 Element_Count (Item.Settings.Decay_Extra);

               procedure One
                 (Name : String; Rows, Cols : Element_Count;
                  Into : out T.Real_Array_Access) is
               begin
                  Resolve_Table (Item, Source, Layer_Key (Index, Name),
                                 Rows, Cols, Into, Status);
               end One;

               procedure Vec (Name : String; Into : out T.Real_Array_Access)
               is
               begin
                  Resolve_Norm (Item, Source, Layer_Key (Index, Name),
                                RW, Into, Status);
               end Vec;
            begin
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "attn_norm_2.weight"),
                  RW, Current.Second_Attention_Norm, Status);
               if E.Is_Ok (Status) then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_norm_2.bias"),
                     RW, Current.Second_Attention_Norm_Bias, Status);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;

               --  The eight wide matrices, through the product.
               Resolve (Item, Source,
                        Layer_Key (Index, "time_mix_receptance.weight"),
                        RW, RW, Current.Rwkv_R, Status, Repack);
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "time_mix_key.weight"),
                           RW, RW, Current.Rwkv_K, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "time_mix_value.weight"),
                           RW, RW, Current.Rwkv_V, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "time_mix_gate.weight"),
                           RW, RW, Current.Rwkv_G, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "time_mix_output.weight"),
                           RW, RW, Current.Rwkv_TM_Out, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "channel_mix_key.weight"),
                           Feed, RW, Current.Rwkv_CM_K, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve (Item, Source,
                           Layer_Key (Index, "channel_mix_value.weight"),
                           RW, Feed, Current.Rwkv_CM_V, Status, Repack);
               end if;
               if E.Is_Ok (Status) then
                  Resolve
                    (Item, Source,
                     Layer_Key (Index, "channel_mix_receptance.weight"),
                     RW, RW, Current.Rwkv_CM_R, Status, Repack);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;

               --  The two low projections of the shift, read whole:
               --  w1 maps the model width to five ranks, w2 each rank
               --  back to the model width, one map a stream.
               One ("time_mix_w1.weight", 5 * D_TM, RW, Current.Rwkv_TM_W1);
               if E.Is_Ok (Status) then
                  One ("time_mix_w2.weight", 5 * RW, D_TM, Current.Rwkv_TM_W2);
               end if;
               if E.Is_Ok (Status) then
                  One ("time_mix_decay_w1.weight", D_Dec, RW,
                       Current.Rwkv_Decay_W1);
               end if;
               if E.Is_Ok (Status) then
                  One ("time_mix_decay_w2.weight", RW, D_Dec,
                       Current.Rwkv_Decay_W2);
               end if;
               --  The five shifts' mixes as one table, w, k, v, r, g --
               --  or, in a file written before llama.cpp fused them,
               --  as five vectors read into the same table in that
               --  order: v6-Finch as published is one of those.
               if E.Is_Ok (Status) then
                  if Containers.Find_Tensor
                       (Source, Layer_Key (Index, "time_mix_lerp_fused.weight"))
                     /= 0
                  then
                     One ("time_mix_lerp_fused.weight", 5, RW,
                          Current.Rwkv_Lerp_Fused);
                  else
                     T.Allocate (5 * RW, Current.Rwkv_Lerp_Fused);
                     if Current.Rwkv_Lerp_Fused = null then
                        Status := E.Make (E.Memory_Allocation_Failed);
                     end if;
                     declare
                        Names : constant array (0 .. 4) of String (1 .. 1) :=
                          ["w", "k", "v", "r", "g"];
                     begin
                        for Part in Names'Range loop
                           exit when E.Is_Error (Status);
                           declare
                              One_Mix : T.Real_Array_Access;
                           begin
                              Vec ("time_mix_lerp_" & Names (Part)
                                   & ".weight", One_Mix);
                              if E.Is_Ok (Status) then
                                 Current.Rwkv_Lerp_Fused.all
                                   (Element_Count (Part) * RW
                                    .. Element_Count (Part) * RW + RW - 1) :=
                                   One_Mix.all;
                              end if;
                              T.Free (One_Mix);
                           end;
                        end loop;
                     end;
                  end if;
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;

               --  And the vectors.
               Vec ("time_mix_lerp_x.weight", Current.Rwkv_Lerp_X);
               --  The bonus a head gives the current position, which the
               --  file keeps a head a row: the same numbers in the same
               --  order as one vector of the model's width.
               if E.Is_Ok (Status) then
                  One ("time_mix_first.weight",
                       RW / Element_Count (Item.Settings.Head_Dim),
                       Element_Count (Item.Settings.Head_Dim),
                       Current.Rwkv_First);
               end if;
               if E.Is_Ok (Status) then
                  Vec ("time_mix_decay.weight", Current.Rwkv_Decay);
               end if;
               if E.Is_Ok (Status) then
                  Vec ("time_mix_ln.weight", Current.Rwkv_TM_LN);
               end if;
               if E.Is_Ok (Status) then
                  Vec ("time_mix_ln.bias", Current.Rwkv_TM_LN_Bias);
               end if;
               if E.Is_Ok (Status) then
                  Vec ("channel_mix_lerp_k.weight", Current.Rwkv_CM_Lerp_K);
               end if;
               if E.Is_Ok (Status) then
                  Vec ("channel_mix_lerp_r.weight", Current.Rwkv_CM_Lerp_R);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;
            end;
         elsif Is_Linear then
            --  The linear layer's projections: the queries, keys and
            --  values in one tensor, the gate, the decay and the
            --  rate a value head, the taps, the decay's shape, the
            --  blend's normalization and the way back. The decay's
            --  shape is the one tensor here without a suffix, which
            --  is how the file spells it.
            Resolve
              (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
               Element_Count (Mix_Width (Item.Settings)), Width,
               Current.Mix, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "attn_gate.weight"),
               Element_Count (Value_Width (Item.Settings)), Width,
               Current.Z_Gate, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ssm_alpha.weight"),
               Element_Count (Item.Settings.Value_Heads), Width,
               Current.Alpha, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ssm_beta.weight"),
               Element_Count (Item.Settings.Value_Heads), Width,
               Current.Beta, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "ssm_a"),
               Element_Count (Item.Settings.Value_Heads),
               Current.A_Log, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "ssm_dt.bias"),
               Element_Count (Item.Settings.Value_Heads),
               Current.DT_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Table
              (Item, Source, Layer_Key (Index, "ssm_conv1d.weight"),
               Element_Count (Mix_Width (Item.Settings)),
               Element_Count (Item.Settings.Conv_Kernel),
               Current.Conv, Status, Turned => True);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "ssm_norm.weight"),
               Element_Count (Item.Settings.State_Size),
               Current.State_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ssm_out.weight"),
               Width, Element_Count (Value_Width (Item.Settings)),
               Current.Linear_Out, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;
         elsif Item.Settings.Kind
            in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert | Gptneox | Mpt
             | Chatglm
         then
            Resolve_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
               Wide + KV + KV_Out, Width, 0, Wide,
               Current.Query, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
               Wide + KV + KV_Out, Width, Wide, KV,
               Current.Key, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.weight"),
               Wide + KV + KV_Out, Width, Wide + KV, KV_Out,
               Current.Value, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;
         elsif Is_MLA (Item.Settings.Kind) then
            --  DeepSeek's latent projections. The query goes straight
            --  where the file states no query latent and through a
            --  latent and a norm otherwise; the keys and values through
            --  a latent that carries the rotated slice beside it -- one
            --  shared across the heads -- and a norm over the latent
            --  alone, then out to a key that is not rotated and a value
            --  a head. The rotated slice is the head's Rotary elements;
            --  the rest of the head width (Head_Size - Rotary) is the
            --  nope key.
            if Item.Settings.Q_Lora_Rank > 0 then
               Resolve
                 (Item, Source, Layer_Key (Index, "attn_q_a.weight"),
                  Element_Count (Item.Settings.Q_Lora_Rank), Width,
                  Current.Q_A, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;

               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "attn_q_a_norm.weight"),
                  Element_Count (Item.Settings.Q_Lora_Rank),
                  Current.Q_A_Norm, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_q_b.weight"),
                  Wide, Element_Count (Item.Settings.Q_Lora_Rank),
                  Current.Q_B, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;
            else
               Resolve
                 (Item, Source, Layer_Key (Index, "attn_q.weight"),
                  Wide, Width, Current.Query, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "attn_kv_a_mqa.weight"),
               Element_Count
                 (Item.Settings.KV_Lora_Rank + Item.Settings.Rotary),
               Width, Current.KV_A_MQA, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            --  And its two row ranges as views of their own, the latent's
            --  and then the rotated slice's: the same bytes, a row range
            --  each, for the device's whole layer to project apart.
            declare
               Lat_Rows : constant Element_Count :=
                 Element_Count (Item.Settings.KV_Lora_Rank);
            begin
               Current.KV_A_Lat := Current.KV_A_MQA;
               Current.KV_A_Lat.Rows := Lat_Rows;
               Current.KV_A_Rope := Current.KV_A_MQA;
               Current.KV_A_Rope.Rows :=
                 Element_Count (Item.Settings.Rotary);
               Current.KV_A_Rope.Offset :=
                 Current.KV_A_MQA.Offset
                 + B.Byte_Count (Lat_Rows)
                   * T.Row_Bytes (Current.KV_A_MQA);
            end;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_kv_a_norm.weight"),
               Element_Count (Item.Settings.KV_Lora_Rank),
               Current.KV_A_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "attn_kv_b.weight"),
               Element_Count
                 (Item.Settings.Heads
                  * (Item.Settings.Head_Size - Item.Settings.Rotary
                     + Item.Settings.Value_Size)),
               Element_Count (Item.Settings.KV_Lora_Rank),
               Current.KV_B, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;
         else
            --  Twice as wide where the query projection carries a
            --  gate beside each head, as the hybrids' does.
            Resolve
              (Item, Source, Layer_Key (Index, "attn_q.weight"),
               (if Hybrid (Item.Settings.Kind) then 2 * Wide else Wide),
               Width, Current.Query, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "attn_k.weight"),
               KV, Width, Current.Key, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "attn_v.weight"),
               KV_Out, Width, Current.Value, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Qwen2 adds a bias to each projection; Llama and Qwen3
         --  have none. Required when the architecture says so rather
         --  than taken if present: a qwen2 file without them is a file
         --  this cannot evaluate, and reading it as though the biases
         --  were zero would produce plausible text that is not what
         --  the model says.
         --  Phi2 biases the same three projections, and writes the
         --  three biases in one vector as it writes the three matrices
         --  in one tensor. Each part is taken from the same offset its
         --  matrix is taken from, so a reader that splits the matrices
         --  correctly and the biases some other way would be wrong
         --  only in what it adds -- which reads as a model that has
         --  drifted rather than one that has broken.
         if Item.Settings.Kind in Phi2 | GPT2 | Gptneox then
            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, 0, Wide, Current.Query_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, Wide, KV, Current.Key_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, Wide + KV, KV_Out,
               Current.Value_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  ChatGLM fuses the three biases in one vector as Phi2 does,
         --  but the bias is the model's to carry or leave -- GLM-4-9B and
         --  ChatGLM3 have one, another might not -- so it is taken where
         --  the file holds it rather than required, the fused twin of the
         --  choice GLM4 makes over its three separate biases.
         if Item.Settings.Kind = Chatglm
           and then Containers.Find_Tensor
                      (Source, Layer_Key (Index, "attn_qkv.bias")) /= 0
         then
            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, 0, Wide, Current.Query_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, Wide, KV, Current.Key_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm_Part
              (Item, Source, Layer_Key (Index, "attn_qkv.bias"),
               Wide + KV + KV_Out, Wide + KV, KV_Out,
               Current.Value_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Bert biases the same three and writes them as Qwen2
         --  does, one vector a projection rather than three in one,
         --  and jina-bert-v2 does the same.
         if Item.Settings.Kind in Qwen2 | Bert | Jina_Bert_V2 | Starcoder2
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q.bias"),
               Wide, Current.Query_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k.bias"),
               KV, Current.Key_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_v.bias"),
               KV_Out, Current.Value_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  GLM4 biases the same three where qwen2 does, but the bias
         --  is the model's to carry or leave: GLM-4-9B has one, a
         --  smaller GLM4 may not, so it is taken where the file holds
         --  it rather than required. Read all three where the first is
         --  present, so a file with some is not read as one with a bias
         --  or two missing.
         if Item.Settings.Kind in Glm4 | Stablelm
           and then Containers.Find_Tensor
                      (Source, Layer_Key (Index, "attn_q.bias")) /= 0
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q.bias"),
               Wide, Current.Query_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k.bias"),
               KV, Current.Key_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_v.bias"),
               KV_Out, Current.Value_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  The keys' and values' biases again, one after the other, for
         --  the device step that adds both as it readies the heads.
         if Current.Key_Bias /= null and then Current.Value_Bias /= null
           and then Current.KV_Bias = null
         then
            declare
               Keys   : constant Element_Count :=
                 Current.Key_Bias.all'Length;
               Values : constant Element_Count :=
                 Current.Value_Bias.all'Length;
            begin
               T.Allocate (Keys + Values, Current.KV_Bias);
               if Current.KV_Bias /= null then
                  Current.KV_Bias.all (0 .. Keys - 1) :=
                    Current.Key_Bias.all;
                  Current.KV_Bias.all (Keys .. Keys + Values - 1) :=
                    Current.Value_Bias.all;
               end if;
            end;
         end if;

         --  StableLM's larger sizes normalize each query and key head
         --  with a centred normalization and a gain of its own a head,
         --  which is a third kind of head normalization this does not
         --  compute -- neither the shared-gain root-mean-square one qwen3
         --  has nor the whole-projection one olmo2 has. A file that
         --  carries it (the 12B does, the 1.6B does not) is refused by
         --  name rather than run with the normalization silently dropped.
         if Item.Settings.Kind = Stablelm
           and then Containers.Find_Tensor
                      (Source, Layer_Key (Index, "attn_q_norm.weight"))
                    /= 0
         then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text
              (Status, "feature",
               "stablelm per-head query and key normalization",
               E.Param_Identifier);
            return;
         end if;

         --  Qwen3 normalizes each query head and each key head before
         --  the rotation, with one gain per element of a head shared
         --  across the heads. Required for the architectures that have
         --  it, for the same reason the biases are.
         if Item.Settings.Kind in Qwen3 | Qwen3_MoE | Gemma3
           or else (Hybrid (Item.Settings.Kind) and then not Is_Linear)
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q_norm.weight"),
               Element_Count (Item.Settings.Head_Size),
               Current.Query_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k_norm.weight"),
               Element_Count (Item.Settings.Head_Size),
               Current.Key_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Command-R+ normalizes each query head and each key head under
         --  the same tensor names as Qwen3, but centred and with a gain
         --  for every head rather than one shared across them, so the
         --  tensors are as wide as the whole projection. Read where the
         --  file holds them and left null where it does not: Command-R
         --  itself carries none and takes Falcon's plain path, while
         --  Command-R+ carries them. Read together, so a file with one is
         --  not taken for one with the other missing.
         if Item.Settings.Kind = Command_R
           and then Containers.Find_Tensor
                      (Source, Layer_Key (Index, "attn_q_norm.weight"))
                    /= 0
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_q_norm.weight"),
               Element_Count (Item.Settings.Heads * Item.Settings.Head_Size),
               Current.Query_Head_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_k_norm.weight"),
               Element_Count
                 (Item.Settings.KV_Heads * Item.Settings.Head_Size),
               Current.Key_Head_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         if not Is_Linear then
            Resolve
              (Item, Source, Layer_Key (Index, "attn_output.weight"),
               Width, Blend, Current.Attention_Out, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  And the bias on the way out of attention, which Phi2,
         --  GPT2, Bert and jina-bert-v2 have and the rest have not.
         if Item.Settings.Kind in
              Phi2 | GPT2 | Bert | Jina_Bert_V2 | GPT_OSS | Starcoder2 | Gptneox
         then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_output.bias"),
               Width, Current.Out_Bias, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  One score a head that joins the softmax's denominator and
         --  has nothing behind it, which is what lets a head of this
         --  architecture attend to nothing at all. Named by head
         --  count rather than by width: there is one of these for
         --  each head, not one for each component.
         if Item.Settings.Kind = GPT_OSS then
            Resolve_Norm
              (Item, Source, Layer_Key (Index, "attn_sinks.weight"),
               Element_Count (Item.Settings.Heads), Current.Sinks,
               Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  Falcon has one normalization a block, not two: attention
         --  and the feed-forward read the same normalized input. The
         --  feed norm stays null and the block below reads that.
         --  Nor where no feed-forward follows the block: Mamba's and
         --  Mamba2's layers are the block and nothing after it, and
         --  RWKV6's channel mix is its own, normalized by attn_norm_2
         --  above. A published file of either carries no ffn_norm and
         --  no feed-forward, and requiring them refused it for tensors
         --  the evaluation never reads.
         if Item.Settings.Kind not in Falcon | Phi2 | Olmo2 | Command_R
           and then not Normalizes_After (Item.Settings.Kind)
           and then not Pure_SSM (Item.Settings.Kind)
           and then not Is_RWKV (Item.Settings.Kind)
         then
            --  The hybrids name the normalization before the
            --  feed-forward for what it follows rather than what it
            --  precedes; it is the same normalization in the same
            --  place.
            Resolve_Norm
              (Item, Source,
               Layer_Key (Index,
                          (if Hybrid (Item.Settings.Kind)
                           then "post_attention_norm.weight"
                           else "ffn_norm.weight")),
               Width, Current.Feed_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            --  The shift beside it, where the architecture centres.
            --  Falcon and phi2 never reach here -- they have one
            --  normalization a block -- so this is gpt2's, and it was
            --  missing: the file carries it, the engine read every
            --  other layer-norm shift, and the feed-forward ran off a
            --  normalization that was neither centred nor shifted.
            --  Optional, and deliberately so. Requiring it would
            --  refuse a file that does not carry one, which is the
            --  trap this architecture's output bias already fell
            --  into: the loader asked for a tensor because the
            --  fixture wrote it, and a published model was refused.
            if Item.Settings.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox
              and then Containers.Find_Tensor
                         (Source, Layer_Key (Index, "ffn_norm.bias"))
                       /= 0
            then
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "ffn_norm.bias"),
                  Width, Current.Feed_Norm_Bias, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end if;

         if Pure_SSM (Item.Settings.Kind) or else Is_RWKV (Item.Settings.Kind)
         then
            --  No feed-forward to read: see the normalization above.
            null;

         elsif Item.Settings.Kind in Falcon | Phi2 | GPT2 | Bert | Starcoder2 | Gptneox | Mpt
         then
            --  No gate: one projection up, a Gaussian unit, one down.
            --  The gate stays null, and the block below reads that
            --  rather than the architecture.
            Resolve
              (Item, Source, Layer_Key (Index, "ffn_up.weight"),
               Feed, Width, Current.Up, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ffn_down.weight"),
               Width, Feed, Current.Down, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            --  A bias on each side of the block, which Phi2 has and
            --  Falcon does not, so the arrangement they share is not
            --  what decides this.
            if Item.Settings.Kind in Phi2 | GPT2 | Bert | Starcoder2 | Gptneox then
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "ffn_up.bias"),
                  Feed, Current.Up_Bias, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "ffn_down.bias"),
                  Width, Current.Down_Bias, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;

         elsif Item.Settings.Experts = 0
           and then Item.Settings.Kind in Phi3 | Glm4 | Chatglm
         then
            --  The gate and the up projection in one tensor, gate
            --  first. Taking them the other way round is a model that
            --  gates on what it should be scaling, which reads as
            --  fluent nonsense rather than as a refusal.
            Resolve_Part
              (Item, Source, Layer_Key (Index, "ffn_up.weight"),
               Feed * 2, Width, 0, Feed,
               Current.Gate, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Part
              (Item, Source, Layer_Key (Index, "ffn_up.weight"),
               Feed * 2, Width, Feed, Feed,
               Current.Up, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ffn_down.weight"),
               Width, Feed, Current.Down, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

         elsif Item.Settings.Experts = 0
           or else ((Is_Jamba (Item.Settings.Kind)
                     or else Is_MLA (Item.Settings.Kind))
                    and then Containers.Find_Tensor
                               (Source,
                                Layer_Key (Index, "ffn_gate_inp.weight"))
                             = 0)
         then
            --  Jamba's dense layers and DeepSeek's leading ones -- the
            --  ones without a router -- go through the plain gated
            --  feed-forward; the mixture layers fall to Resolve_Experts
            --  below, a layer at a time.
            Resolve
              (Item, Source, Layer_Key (Index, "ffn_gate.weight"),
               Feed, Width, Current.Gate, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ffn_up.weight"),
               Feed, Width, Current.Up, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve
              (Item, Source, Layer_Key (Index, "ffn_down.weight"),
               Width, Feed, Current.Down, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            --  The one gated architecture here that shifts what it
            --  projects down. Every other one carries no bias
            --  anywhere in its feed-forward, which is why this is
            --  asked for by architecture and not taken if present.
            if Item.Settings.Kind = Jina_Bert_V2 then
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "ffn_down.bias"),
                  Width, Current.Down_Bias, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         else
            Resolve_Experts
              (Item, Source, Index, Current, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            --  And the expert every position goes through as well,
            --  where the mixture has one, with the row that gates
            --  it.
            if Item.Settings.Shared_Feed > 0 then
               Resolve
                 (Item, Source,
                  Layer_Key (Index, "ffn_gate_shexp.weight"),
                  Element_Count (Item.Settings.Shared_Feed), Width,
                  Current.Shared_Gate, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;

               Resolve
                 (Item, Source,
                  Layer_Key (Index, "ffn_up_shexp.weight"),
                  Element_Count (Item.Settings.Shared_Feed), Width,
                  Current.Shared_Up, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;

               Resolve
                 (Item, Source,
                  Layer_Key (Index, "ffn_down_shexp.weight"),
                  Width, Element_Count (Item.Settings.Shared_Feed),
                  Current.Shared_Down, Status, Repack);
               if E.Is_Error (Status) then
                  return;
               end if;

               --  The row that gates it, where there is one; a
               --  mixture without -- DeepSeek2's -- adds its shared
               --  experts as they are.
               if Containers.Find_Tensor
                    (Source,
                     Layer_Key (Index, "ffn_gate_inp_shexp.weight")) /= 0
               then
                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "ffn_gate_inp_shexp.weight"),
                     Width, Current.Shared_Router, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end if;
            end if;
         end if;

         --  What makes a block past the stack a draft of the next
         --  token: the projection from the stack's last state
         --  beside the next token's embedding, each normalized
         --  first, and the normalization ahead of the shared head.
         if Beyond then
            Resolve
              (Item, Source, Layer_Key (Index, "nextn.eh_proj.weight"),
               Width, 2 * Width, Current.Next_Proj, Status, Repack);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "nextn.enorm.weight"),
               Width, Current.Next_ENorm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source, Layer_Key (Index, "nextn.hnorm.weight"),
               Width, Current.Next_HNorm, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Resolve_Norm
              (Item, Source,
               Layer_Key (Index, "nextn.shared_head_norm.weight"),
               Width, Current.Next_Head_Norm, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
      end Resolve_Block;
   begin
      Resolve
        (Item, Source, "token_embd.weight", Vocab, Width,
         Item.Embeddings, Status, Repack);

      --  And the table of positions, for the architecture that learns
      --  where a token is rather than rotating for it. One row a
      --  position, as wide as the embedding, and read exactly once a
      --  token -- there is no rotation anywhere in such a model, so this
      --  is the whole of its position handling.
      if E.Is_Ok (Status) and then Item.Settings.Kind in GPT2 | Bert then
         Resolve
           (Item, Source, "position_embd.weight",
            Element_Count (Item.Settings.Context_Length), Width,
            Item.Positions, Status, Repack);
      end if;
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      --  Bert learns a third row beside those two: which segment of the
      --  input a token belongs to. Two rows, and this reads the first of
      --  them for every position, because a text embedded here is one
      --  segment -- the second is what a model trained on sentence pairs
      --  uses to tell the halves apart, and there is no way to ask for a
      --  pair through this program.
      --
      --  Required where the architecture states it. A file without it is
      --  not a bert with one embedding missing; it is a file describing a
      --  model this does not compute, and reading it as though the
      --  segment row were zero would answer with an embedding that is
      --  wrong by whatever that row holds.
      if E.Is_Ok (Status) and then Item.Settings.Segments > 0 then
         Resolve
           (Item, Source, "token_types.weight",
            Element_Count (Item.Settings.Segments), Width,
            Item.Segments, Status, Repack);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end if;

      --  And the normalization over the sum of the three, before the
      --  first layer sees it. Bert normalizes what it embedded; every
      --  other architecture here hands layer zero the embedding row as it
      --  stands, or scales it by a constant, and has no tensor for this.
      if E.Is_Ok (Status)
        and then (Normalizes_After (Item.Settings.Kind)
                  or else Is_RWKV (Item.Settings.Kind))
      then
         Resolve_Norm
           (Item, Source, "token_embd_norm.weight", Width,
            Item.Embedding_Norm, Status);
         if E.Is_Ok (Status) then
            Resolve_Norm
              (Item, Source, "token_embd_norm.bias", Width,
               Item.Embedding_Norm_Bias, Status);
         end if;
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end if;

      --  A model that carries a scoring head -- cls.output.weight, one row
      --  down to a relevance score -- is a reranker even where its file
      --  forgot to say so with a pooling type, as several published GGUF
      --  conversions do. Read as one, so it scores rather than handing back
      --  a vector nothing asked for.
      if E.Is_Ok (Status)
        and then Item.Settings.Pooling /= Pool_Rank
        and then Containers.Find_Tensor (Source, "cls.output.weight") /= 0
        and then Containers.Find_Tensor (Source, "cls.weight") /= 0
      then
         Item.Settings.Pooling := Pool_Rank;
      end if;

      --  The scoring head of a reranker, where the pooling type asks for
      --  one: a dense of the embedding width and its bias, then a single
      --  row down to the score and its bias. Read once a model, beside the
      --  embedding tensors, so the ranking pass has them in hand.
      if E.Is_Ok (Status) and then Item.Settings.Pooling = Pool_Rank then
         Resolve
           (Item, Source, "cls.weight", Width, Width,
            Item.Rank_Dense, Status, Repack);
         if E.Is_Ok (Status) then
            Resolve_Norm
              (Item, Source, "cls.bias", Width, Item.Rank_Dense_Bias,
               Status);
         end if;
         if E.Is_Ok (Status) then
            Resolve
              (Item, Source, "cls.output.weight", 1, Width,
               Item.Rank_Out, Status, Repack);
         end if;
         if E.Is_Ok (Status) then
            Resolve_Norm
              (Item, Source, "cls.output.bias", 1, Item.Rank_Out_Bias,
               Status);
         end if;
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end if;

      --  The normalization between the last layer and whatever reads it.
      --  Every architecture here has one except Bert, whose layers
      --  normalize on the way out rather than on the way in: the last
      --  thing its last layer did was normalize what it produced, and a
      --  file carrying a tensor for a second one would be describing a
      --  model this does not compute.
      if not Normalizes_After (Item.Settings.Kind) then
         Resolve_Norm
           (Item, Source, "output_norm.weight", Width, Item.Output_Norm,
            Status);

         --  RWKV6 among them: its last normalization is a layer norm
         --  with a shift, as its per-block ones are, and the file
         --  carries the shift. Without it the output normalization
         --  divided by the root mean square and did not centre.
         if E.Is_Ok (Status)
           and then Item.Settings.Kind in Falcon | Phi2 | GPT2 | Starcoder2 | Stablelm | Gptneox
                                        | Rwkv6
         then
            Resolve_Norm
              (Item, Source, "output_norm.bias", Width,
               Item.Output_Norm_Bias, Status);
         end if;
      end if;
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      --  A table of per-dimension divisors for the rotation, when the
      --  model carries one. This is how a file states a stretch that is
      --  not one number: the conversion works the schedule out and writes
      --  it as a tensor, and a model carrying one and not having it
      --  applied would rotate every long-range dimension wrongly while
      --  looking entirely healthy on a short prompt.
      if Containers.Find_Tensor (Source, "rope_freqs.weight") /= 0 then
         Resolve_Norm
           (Item, Source, "rope_freqs.weight",
            Element_Count (Item.Settings.Rotary / 2), Item.Rope_Factors,
            Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

      elsif Item.Settings.Rope_Llama3 then
         --  Llama 3's factors, one a rotation pair, where the file did
         --  not write them out: one for a frequency faster than its high
         --  band, the scale factor for one slower than its low band, and
         --  an eased mix between.
         declare
            Two_Pi : constant N.Wide_Real := 6.283185307179586;
            Rotary : constant Natural := Item.Settings.Rotary;
            Pairs  : constant Natural := Rotary / 2;
            Base   : constant N.Wide_Real := Item.Settings.Rope_Base;
            Scale  : constant N.Wide_Real :=
              N.Wide_Real (Item.Settings.Rope_Llama3_Factor);
            Low_F  : constant N.Wide_Real :=
              N.Wide_Real (Item.Settings.Rope_Llama3_Low);
            High_F : constant N.Wide_Real :=
              N.Wide_Real (Item.Settings.Rope_Llama3_High);
            Orig   : constant N.Wide_Real :=
              N.Wide_Real (Item.Settings.Rope_Original);
            Low_Wave  : constant N.Wide_Real :=
              (if Low_F > 0.0 then Orig / Low_F else 0.0);
            High_Wave : constant N.Wide_Real :=
              (if High_F > 0.0 then Orig / High_F else 0.0);
         begin
            if Pairs > 0 and then Orig > 0.0 and then Scale > 0.0
              and then High_F /= Low_F
            then
               Item.Rope_Factors :=
                 new Model_Runner.Tensors.Real_Array
                   (0 .. Element_Count (Pairs - 1));
               for I in 0 .. Pairs - 1 loop
                  declare
                     Inv  : constant N.Wide_Real :=
                       N.Power
                         (Base,
                          -2.0 * N.Wide_Real (I) / N.Wide_Real (Rotary));
                     Wave : constant N.Wide_Real := Two_Pi / Inv;
                     Fac  : N.Wide_Real;
                  begin
                     if Wave < High_Wave then
                        Fac := 1.0;
                     elsif Wave > Low_Wave then
                        Fac := Scale;
                     else
                        declare
                           Smooth : constant N.Wide_Real :=
                             (Orig / Wave - Low_F) / (High_F - Low_F);
                        begin
                           Fac := 1.0 / ((1.0 - Smooth) / Scale + Smooth);
                        end;
                     end if;
                     Item.Rope_Factors.all (Element_Count (I)) :=
                       Real (Fac);
                  end;
               end loop;
            end if;
         end;

      elsif Containers.Find_Tensor (Source, "rope_factors_long.weight") /= 0
        or else Containers.Find_Tensor
                  (Source, "rope_factors_short.weight") /= 0
      then
         --  LongRoPE: the long table where the model is opened past the
         --  context it was trained on, the short table otherwise, applied
         --  as any per-dimension factor table is.
         declare
            Long  : constant Boolean :=
              Item.Settings.Rope_Original > 0
              and then Item.Settings.Context_Length
                       > Item.Settings.Rope_Original
              and then Containers.Find_Tensor
                         (Source, "rope_factors_long.weight") /= 0;
            Named : constant String :=
              (if Long then "rope_factors_long.weight"
               elsif Containers.Find_Tensor
                       (Source, "rope_factors_short.weight") /= 0
               then "rope_factors_short.weight"
               else "rope_factors_long.weight");
         begin
            Resolve_Norm
              (Item, Source, Named,
               Element_Count (Item.Settings.Rotary / 2),
               Item.Rope_Factors, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end;
      end if;

      --  A model with no output projection ties the output to the embedding
      --  table. The alias is explicit and immutable; nothing is copied.
      --
      --  Except for a model that has no head to tie. Bert produces states
      --  and stops, and its embedding table read backwards is not the
      --  projection it never trained -- so the tie is not made, and what
      --  asks for a distribution is refused by name instead of given the
      --  numbers that arrangement would produce. Which architectures
      --  those are is settled where the profile is read, so that
      --  `inspect` can say it without resolving a tensor.
      if not Item.Settings.Has_Head then
         null;
      elsif Containers.Find_Tensor (Source, "output.weight") = 0 then
         Item.Settings.Tied_Output := True;
         Item.Output := Item.Embeddings;
      else
         Resolve
           (Item, Source, "output.weight", Vocab, Width,
            Item.Output, Status, Repack);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         --  And the bias on it, which Phi2 carries and GPT2 does not.
         --  It is added after the last projection, so it is the last
         --  thing between the model and the caller.
         --
         --  GPT2 was here until a published gpt2 file was read and had no
         --  such tensor. The fixture wrote one because this asked for
         --  one, so the sweep agreed with itself about a model nobody
         --  ships -- which is the failure mode a synthetic fixture has
         --  and a real file does not.
         if Item.Settings.Kind = Phi2 then
            Resolve_Norm
              (Item, Source, "output.bias", Vocab,
               Item.Output_Bias, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;
      end if;

      Item.Layers := new Layer_Array (0 .. Item.Settings.Layers - 1);

      --  And the blocks past the stack, which are resolved as the
      --  stack's full attention layers are, under the indices the file
      --  gives them, plus what makes them a draft of the next token.
      if Item.Settings.Next_Layers > 0 then
         Item.Next := new Layer_Array (0 .. Item.Settings.Next_Layers - 1);
      end if;

      for Index in 0 .. Item.Settings.Layers + Item.Settings.Next_Layers - 1
      loop
         if C.Is_Cancelled (Cancel) then
            Fail (E.Make (E.Generation_Cancelled));
            return;
         end if;

         if Index < Item.Settings.Layers then
            Resolve_Block (Index, False, Item.Layers.all (Index));
         else
            Resolve_Block
              (Index, True, Item.Next.all (Index - Item.Settings.Layers));
         end if;

         exit when E.Is_Error (Status);

         if Index < Item.Settings.Layers then
            Pair_Norms (Item, Item.Layers.all (Index));
         end if;
      end loop;

      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
   end;

   --  Or write them out again in panels, if that was what was asked.
   --
   --  A different kind of copy from the two below: nothing is decoded,
   --  the bytes are the file's own in another order, and the copy is the
   --  size of what it copies. Only the four-bit k-quant is written this
   --  way and only where the row count divides by the panel; everything
   --  else in the file is left where it lies, so the file's own bytes
   --  stay mapped and are never released here.
   --  A dense model the device's room does not take whole reads every
   --  weight every token, so a shortfall left to the device is uploaded
   --  every token: ThinkingCap-Qwen3.8-27B, 15.5 GB against 14.6, read
   --  0.24 tokens a second so. Split instead, as a mixture's experts
   --  are: the top layers' gate, up and down, enough of them for the rest
   --  to fit, stay on the host in panels and the processor runs them,
   --  while the device runs every layer's front half and every other
   --  layer whole.
   if Item.Settings.Experts = 0
     and then Item.Layers /= null
     and then Item.Able.Memory_Bytes > 0
     and then Model_Runner.Backend."=" (Item.Able.Kind, Model_Runner.Backend.Backend_Device)
   then
      declare
         Held  : constant View_List := Matrices (Item);
         Total : Interfaces.Unsigned_64 := 0;
         Freed : Interfaces.Unsigned_64 := 0;

         --  The device's room for the matrices is counted rather than
         --  assumed: both heaps, less the session's context at the length
         --  planned for it and the precision it keeps, less a ring of the
         --  hybrid's states five deep -- a drafted round's rewind -- and less
         --  Session_Margin for the batch's buffers, the driver and the
         --  desktop. The plan is the context the run named, or
         --  Planned_Context where it named none, and the session is held to
         --  it (Device_Context): a context left to grow to the model's own
         --  grew past the room the share left it, and a long conversation
         --  ended in the driver's refusal rather than at its length. The
         --  fixed share left a quarter for all of that whatever the
         --  context: ThinkingCap at 1,024 positions generates 64 tokens in
         --  15.7 s where the share took 16.8, and named nothing, 16.4 s and
         --  16,384 positions; a 12,478-token prompt, named nothing, runs
         --  with the part's mapped memory at most 14.9 GB of its 15.3 GiB,
         --  where a share of seven eighths ran out at 6,502. The margin is
         --  what that measured needs: the heaps say half a gigabyte more
         --  than the part maps, and a paged context a sixth more than its
         --  plan, so a gigabyte left 16,384 positions too close. A long
         --  context named is room the matrices give up: more of the model
         --  on the processor, and the run slower but whole.
         Session_Margin  : constant Interfaces.Unsigned_64 := 3 * 2 ** 29;
         Stream_Margin   : constant Interfaces.Unsigned_64 := 2 ** 29;
         State_Slots     : constant := 5;
         Planned_Context : constant := 16_384;

         function Counted_Room (Planned : Natural) return Interfaces.Unsigned_64
         is
            Plan    : Model_Runner.Memory.Session_Plan;
            Planning : E.Error_Info;
            --  The heaps, or what the host says the device may take of
            --  them where that is less.
            Budget  : constant Interfaces.Unsigned_64 :=
              Model_Runner.Backend.Device.Budget_Bytes;
            Heaps   : constant Interfaces.Unsigned_64 :=
              (if Budget > 0
               then Interfaces.Unsigned_64'Min
                      (Budget, Model_Runner.Backend.Device.Heap_Bytes)
               else Model_Runner.Backend.Device.Heap_Bytes);
            States  : constant Interfaces.Unsigned_64 :=
              (if Hybrid (Item.Settings.Kind)
               then Interfaces.Unsigned_64 (State_Slots)
                    * Interfaces.Unsigned_64
                        (State_Room (Item.Settings)
                         + Conv_Room (Item.Settings)) * 4
               else 0);
         begin
            if Planned = 0 or else Heaps = 0 then
               return 0;
            end if;
            Plan_Session (Item, Planned, Plan, Planning, Cache => Cache);
            if E.Is_Error (Planning)
              or else Heaps <= Session_Margin + States + Plan.KV_Cache_Bytes
            then
               return 0;
            end if;
            return Heaps - Session_Margin - States - Plan.KV_Cache_Bytes;
         end Counted_Room;

         Planned : Natural := Context;
         Room    : Interfaces.Unsigned_64 := 0;

         --  Whether the matrices' budget is the room counted here, rather
         --  than one the caller named.
         Counted_Here : Boolean := False;
      begin
         for Index in Held'Range loop
            declare
               Seen_Before : Boolean := False;
            begin
               for Earlier in Held'First .. Index - 1 loop
                  if Held (Earlier).all.Base = Held (Index).all.Base
                    and then Held (Earlier).all.Offset = Held (Index).all.Offset
                  then
                     Seen_Before := True;
                     exit;
                  end if;
               end loop;
               if not Seen_Before then
                  Total := Total + Bytes_Of (Held (Index).all);
               end if;
            end;
         end loop;

         --  Unnamed, the longest context halving down from the model's own
         --  at which every matrix still fits, and Planned_Context where none
         --  does: a model that fits whole keeps as long a context as it
         --  can, and one that does not keeps the matrices' room.
         if Planned = 0 then
            Planned := Item.Settings.Context_Length;
            while Planned > Planned_Context
              and then Counted_Room (Planned) < Total
            loop
               Planned := Natural'Max (Planned_Context, Planned / 2);
            end loop;
         end if;

         Room := Counted_Room (Planned);

         --  The file's pages of what goes to the device are kept where the
         --  matrices are no more than three fifths of the device's heaps,
         --  which on a part that shares its memory are half the host's:
         --  Qwen3 8B's 4.4 GB read its saved prompt back in 1.9 s with
         --  them and 6.1 without. A larger model gives them back, as
         --  ThinkingCap's must.
         Model_Runner.Backend.Device.Keep_File_Pages
           (Total <= Model_Runner.Backend.Device.Heap_Bytes / 5 * 3);

         --  A model the room does not take whole is split, and a long
         --  prompt's batch streams the feed-forward its processor keeps:
         --  that batch's answers and the streamed matrices are room of
         --  their own, which the margin above was measured without.
         --  ThinkingCap's prompt of 4,024 at --context-size 8192 went
         --  1.58 GB past what a short one needed, a third of it cache,
         --  and ran the part out of memory where nothing was left for it.
         --  Half a gigabyte, now that the room is the host's budget for
         --  the device rather than its heaps and a dense split's batch is
         --  Dense_Streamed_Batch: a prompt of 16,215, the whole context,
         --  peaked at 14.5 GB of the part's 16.4, and with none the 12,529
         --  of another peaked at 15.0.
         if Room > Stream_Margin and then Total > Room then
            Room := Room - Stream_Margin;
         end if;

         if Room > 0 then
            Model_Runner.Backend.Device.Fit_Budget (Room);
            Item.Able := Model_Runner.Backend.Device.Describe;
            if Item.Able.Memory_Bytes = Room then
               Item.Device_Context := Planned;
               Counted_Here := True;
            end if;
         end if;

         --  A budget the caller named is the weights', and is held to;
         --  what is left of the device beside it is the cache's. A context
         --  nobody named is the longest halving of the model's own whose
         --  cache fits there, where it was the model's own whatever the
         --  weights had taken: Steelman-14B's 32,768 beside a named 14 GB
         --  was more than the part has.
         if Item.Device_Context = 0
           and then Context = 0
           and then Item.Able.Memory_Bytes > 0
         then
            declare
               Weights : constant Interfaces.Unsigned_64 := Item.Able.Memory_Bytes;
               Asked   : Natural := Item.Settings.Context_Length;
            begin
               while Asked > Planned_Context
                 and then Counted_Room (Asked) < Weights
               loop
                  Asked := Natural'Max (Planned_Context, Asked / 2);
               end loop;
               Item.Device_Context := Asked;
            end;
         end if;

         if Total > Item.Able.Memory_Bytes then
            for Index in reverse Item.Layers.all'Range loop
               exit when Total - Freed <= Item.Able.Memory_Bytes;
               declare
                  L : Layer renames Item.Layers.all (Index);
               begin
                  if L.Feed_Norm /= null
                    and then T.Is_Present (L.Gate)
                    and then T.Is_Present (L.Up)
                    and then T.Is_Present (L.Down)
                    and then Model_Runner.Quantization.Interleave.Interleaves
                               (L.Gate.Format, L.Gate.Rows, L.Gate.Columns)
                    and then Model_Runner.Quantization.Interleave.Interleaves
                               (L.Up.Format, L.Up.Rows, L.Up.Columns)
                    and then Model_Runner.Quantization.Interleave.Interleaves
                               (L.Down.Format, L.Down.Rows, L.Down.Columns)
                  then
                     L.Host_Feed := True;
                     L.File_Gate := L.Gate;
                     L.File_Up := L.Up;
                     L.File_Down := L.Down;
                     Freed := Freed + Bytes_Of (L.Gate) + Bytes_Of (L.Up) + Bytes_Of (L.Down);
                  end if;
               end;
            end loop;
            Dense_Split := Total - Freed <= Item.Able.Memory_Bytes;
            if not Dense_Split then
               for L of Item.Layers.all loop
                  L.Host_Feed := False;
               end loop;
            end if;

            --  Split for a context's room the cache takes only as it
            --  fills: where every matrix fits the device beside the
            --  margins, the split layers stay on the device too, their
            --  panels built and kept aside, until a session's cache wants
            --  the room (Room_For_Cache). Steelman-14B named 32,768 positions
            --  and was split for them before its first token; a short
            --  conversation generated at 6.6 tokens a second where 4,096
            --  named read 7.8.
            declare
               Budget : constant Interfaces.Unsigned_64 :=
                 Model_Runner.Backend.Device.Budget_Bytes;
               Heaps  : constant Interfaces.Unsigned_64 :=
                 (if Budget > 0
                  then Interfaces.Unsigned_64'Min
                         (Budget, Model_Runner.Backend.Device.Heap_Bytes)
                  else Model_Runner.Backend.Device.Heap_Bytes);
               Margins : constant Interfaces.Unsigned_64 :=
                 Session_Margin + Stream_Margin
                 + (if Hybrid (Item.Settings.Kind)
                    then Interfaces.Unsigned_64 (State_Slots)
                         * Interfaces.Unsigned_64
                             (State_Room (Item.Settings)
                              + Conv_Room (Item.Settings)) * 4
                    else 0);
            begin
               --  Only where the room was counted here: a budget the caller
               --  named bounds the matrices itself, and is held to.
               if Dense_Split
                 and then Counted_Here
                 and then Item.Settings.Experts = 0
                 and then Heaps > Margins
                 and then Total < Heaps - Margins
               then
                  Item.Feed_Room := Heaps - Margins;
                  Item.Feed_Weights := Total;
               end if;
            end;
         end if;
      end;
   end if;

   if Repack /= No_Repack or else Dense_Split then
      Repack_Started := Model_Runner.Clocks.Now (Repack_Clock);
   end if;

   if Repack = To_Rows or else Dense_Split then
      P.Publish (Observer, P.Load_Progress (P.Repacking_Weights));

      --  The head as the file has it, before it may be written in panels.
      Item.Output_As_Stored := Item.Output;

      declare
         Needed : B.Byte_Count := 0;

         --  The cache file a split's panels are built in, whether they
         --  are, and where the panels are built either way.
         Built     : Model_Runner.Panel_Cache.Building;
         Into_File : Boolean := False;
         Target_At : System.Address := System.Null_Address;

         --  The lookup tables are left alone. A row of a panel is a
         --  gather, and these three are read a row at a time and
         --  multiplied by nothing: interleaving them would pay the
         --  gather on every token to buy a kernel none of them reaches.
         function Is_Lookup (Where : View_Access) return Boolean
         is (Where = Item.Embeddings'Unchecked_Access
             or else Where = Item.Positions'Unchecked_Access
             or else Where = Item.Segments'Unchecked_Access);

         function To_Panel return View_List is
            Whole : constant View_List := Matrices (Item);
            Room  : View_List (Whole'Range);
            Count : Natural := 0;
         begin
            for Where of Whole loop
               if not Is_Lookup (Where)
                 --  Split, only what the processor runs.
                 and then (Repack = To_Rows or else Host_Fed (Where))
                 and then Model_Runner.Quantization.Interleave.Interleaves
                            (Where.all.Format, Where.all.Rows,
                             Where.all.Columns)
               then
                  Count := Count + 1;
                  Room (Count) := Where;
               end if;
            end loop;

            return Room (1 .. Count);
         end To_Panel;

         --  Blocks in one row, which is not the same number for every
         --  format the panel layout accepts: a super-block for the three
         --  k-quants and thirty-two elements for the legacy four-bit one.
         --  It was written 256 at all three of the places below, which
         --  was right for as long as three formats were all there were.
         function Blocks_Of (Where : View_Access) return Element_Count
         is (Where.all.Columns
             / Element_Count
                 (Model_Runner.GGUF.Block_Elements (Where.all.Format)));

         Held : constant View_List := To_Panel;

         --  The panel cache's file for this load: the whole model's, or a
         --  split's own beside it; none where the caller keeps no cache.
         function Panel_File (Total : B.Byte_Count) return String
         is (if Panel_Cache = "" then ""
             elsif Repack = To_Rows then Panel_Cache
             elsif Dense_Split
             then Panel_Cache & ".split-"
                  & Model_Runner.Text.Trim (B.Byte_Count'Image (Total))
             else "");

         --  The panel cache's file: a header of Header_Bytes -- a mark,
         --  the layout's version, the panels' bytes and how many matrices
         --  -- and then every matrix's panels in Held's order, as the
         --  rewrite lays them out in memory.
         Header_Bytes : constant := 4096;
         Mark         : constant String := "MRPANELS";
         Version      : constant := 1;

         package Files renames Model_Runner.Byte_Sources.Files;
         package IL renames Model_Runner.Quantization.Interleave;

         --  Where matrix Which's panels begin past the header.
         function Base_Of (Which : Positive) return B.Byte_Count is
            Running : B.Byte_Count := 0;
         begin
            for Index in Held'First .. Which - 1 loop
               Running := Running
                 + IL.Panel_Bytes
                     (Held (Index).all.Format, Held (Index).all.Rows,
                      Blocks_Of (Held (Index)));
            end loop;
            return Running;
         end Base_Of;

         --  The header's four numbers, a word of eight bytes each after
         --  the mark, least significant byte first.
         function Header_Word (Value : Interfaces.Unsigned_64) return String
         is
            Result : String (1 .. 8);
            Rest   : Interfaces.Unsigned_64 := Value;
         begin
            for Index in Result'Range loop
               Result (Index) :=
                 Character'Val (Natural (Interfaces."and" (Rest, 255)));
               Rest := Interfaces.Shift_Right (Rest, 8);
            end loop;
            return Result;
         end Header_Word;

         function Header (Total : B.Byte_Count) return String
         is (Mark
             & Header_Word (Version)
             & Header_Word (Interfaces.Unsigned_64 (Total))
             & Header_Word (Interfaces.Unsigned_64 (Held'Length)));

         --  The cached panels mapped and read where they lie, where the
         --  file is there, is the size and says what these panels say,
         --  and the first panel of every matrix is the one the rewrite
         --  would write now: a file from a build that lays panels out
         --  otherwise, or of another file at the same path, fails that and
         --  is written afresh. False where anything is off; the views are
         --  then as they were.
         function Map_Panels
           (Total : B.Byte_Count; Verify : Boolean := True) return Boolean
         is
            Map : Panel_Map_Access;
            Ok  : E.Error_Info;

            procedure Release is new Ada.Unchecked_Deallocation
              (Files.File_Source, Panel_Map_Access);

            procedure Give_Up is
            begin
               Files.Close (Map.all);
               Release (Map);
            end Give_Up;
         begin
            if not Model_Runner.Panel_Cache.Is_There (Panel_File (Total)) then
               return False;
            end if;

            Map := new Files.File_Source;
            Files.Open (Map.all, Panel_File (Total), Files.Mapping_Required,
                        Status => Ok);
            if E.Is_Error (Ok)
              or else Files.Size (Map.all) /= Header_Bytes + Total
            then
               Give_Up;
               return False;
            end if;

            declare
               Expected : constant String := Header (Total);
               Held_Header : String (1 .. Expected'Length)
                 with Import, Address => Files.Base (Map.all);
            begin
               if Held_Header /= Expected then
                  Give_Up;
                  return False;
               end if;
            end;

            for Which in Held'Range loop
               exit when not Verify;
               declare
                  Where : constant View_Access := Held (Which);
                  Size  : constant B.Byte_Count :=
                    IL.Panel_Bytes
                      (Where.all.Format, IL.Panel_Rows, Blocks_Of (Where));
                  Source : B.Byte_Array (1 .. Where.all.Span)
                    with Import, Address => Where.all.Base;
                  Kept  : B.Byte_Array (1 .. Size)
                    with Import,
                         Address =>
                           System.Storage_Elements.To_Address
                             (System.Storage_Elements.To_Integer
                                (Files.Base (Map.all))
                              + System.Storage_Elements.Integer_Address
                                  (Header_Bytes + Base_Of (Which)));
                  Probe : B.Byte_Array_Access := new B.Byte_Array (1 .. Size);
                  Taken : Boolean;
                  Same  : Boolean;
               begin
                  Probe.all := [others => 0];
                  IL.Build
                    (Format => Where.all.Format,
                     Source => Source,
                     From   => Where.all.Offset,
                     Target => Probe.all,
                     Into   => 0,
                     Rows   => IL.Panel_Rows,
                     Blocks => Blocks_Of (Where),
                     Ok     => Taken);
                  Same := Taken and then B."=" (Probe.all, Kept);
                  B.Free (Probe);
                  if not Same then
                     Give_Up;
                     return False;
                  end if;
               end;
            end loop;

            for Which in Held'Range loop
               declare
                  Fresh : T.View;
               begin
                  T.Make_Panels_At
                    (Format  => Held (Which).all.Format,
                     Rows    => Held (Which).all.Rows,
                     Columns => Held (Which).all.Columns,
                     Base    => Files.Base (Map.all),
                     Span    => Files.Size (Map.all),
                     Offset  => Header_Bytes + Base_Of (Which),
                     Result  => Fresh,
                     Status  => Ok);
                  if E.Is_Error (Ok) then
                     --  Nothing has been moved yet but this one, which
                     --  failed: the views are still the file's.
                     Give_Up;
                     return False;
                  end if;
               end;
            end loop;

            for Which in Held'Range loop
               declare
                  Fresh : T.View;
               begin
                  T.Make_Panels_At
                    (Held (Which).all.Format, Held (Which).all.Rows,
                     Held (Which).all.Columns, Files.Base (Map.all),
                     Files.Size (Map.all), Header_Bytes + Base_Of (Which),
                     Fresh, Ok);
                  Held (Which).all := Fresh;
               end;
            end loop;

            Item.Panel_Map := Map;
            Mem.Record_Mapping
              (Item.Accounting, Interfaces.Unsigned_64 (Total));
            return True;
         exception
            when others =>
               if Map /= null then
                  Give_Up;
               end if;
               return False;
         end Map_Panels;

         --  The panels just written, kept for the next load: a file
         --  beside its final name and renamed into it whole, so a load
         --  never maps half of one. Anything that goes wrong -- no room,
         --  no directory -- leaves no file and costs nothing but the
         --  attempt.
         procedure Write_Panels (Total : B.Byte_Count) is
         begin
            Item.Panel_Writer := new Model_Runner.Panel_Cache.Writing;
            Item.Panel_Writer.Start
              (Panel_File (Total), Header (Total),
               Item.Repacked.all (Item.Repacked.all'First)'Address, Total);
         exception
            when others =>
               null;
         end Write_Panels;
      begin
         --  A model with nothing to interleave keeps every view it has
         --  and allocates nothing, which is the honest answer for a file
         --  in another format rather than a diagnostic: the flag says
         --  what to do with four-bit weights and this file has none.
         if Held'Length > 0 then
            for Where of Held loop
               Needed := Needed
                 + Model_Runner.Quantization.Interleave.Panel_Bytes
                     (Where.all.Format, Where.all.Rows,
                      Blocks_Of (Where));
            end loop;

            --  The cache is a whole model's panels, and a split's few are
            --  kept in a file of their own beside it: made afresh in the
            --  process's own memory, they were what a host short of memory
            --  sent to swap -- 3.5 GB of ThinkingCap's -- where pages of a
            --  file are let go and read again.
            if Panel_File (Needed) /= "" and then Map_Panels (Needed) then
               Model_Runner.Panel_Cache.Mark_Used (Panel_File (Needed));
               goto Panels_Done;
            end if;

            --  A split's panels are built in their cache file, where the
            --  host can write them back and let them go; a whole model's,
            --  and any the file cannot take, in the process's own memory
            --  and written out beside the run.
            if Panel_File (Needed) /= "" and then Repack /= To_Rows then
               --  A split's file for each split, the newest four kept: a
               --  context is a split, and three a user moves between were
               --  built afresh at each, the bound on the cache's whole size
               --  keeping what that costs.
               Model_Runner.Panel_Cache.Keep_Newest
                 (Panel_Cache & ".split", 3);
               Model_Runner.Panel_Cache.Begin_Build
                 (Built, Panel_File (Needed), Header (Needed), Needed,
                  Target_At, Into_File);
            end if;

            if not Into_File then
               Mem.Check_Allocation
                 (Item.Accounting, Mem.Converted_Weights,
                  Interfaces.Unsigned_64 (Needed), Status);
               if E.Is_Error (Status) then
                  Fail (Status);
                  return;
               end if;

               --  Not zeroed here: a zeroing pass on one task touched every
               --  page of the copy before the team began, a third of the
               --  rewrite's time. Each matrix's panels are cleared by the
               --  task that writes them, beside where they are written.
               begin
                  Item.Repacked := new B.Byte_Array (1 .. Needed);
               exception
                  when Storage_Error =>
                     Item.Repacked := null;
               end;
               if Item.Repacked = null then
                  Fail (E.Make (E.Memory_Allocation_Failed));
                  return;
               end if;

               Mem.Record_Allocation
                 (Item.Accounting, Mem.Converted_Weights,
                  Interfaces.Unsigned_64 (Needed));
               Target_At := Item.Repacked.all (1)'Address;
            end if;
            Mem.Record_Conversion
              (Item.Accounting, Interfaces.Unsigned_64 (Needed));

            declare
               Bases : array (Held'Range) of B.Byte_Count :=
                 [others => 0];

               --  Where the panels are built: the cache file's pages, or
               --  the copy in the process's memory.
               Whole : B.Byte_Array (1 .. Needed)
                 with Import, Address => Target_At;

               --  The same queue the decoding pass uses and for the same
               --  reason: the matrices differ by a factor of ten in size
               --  and a split by count is not a split of the work.
               protected Shared is
                  procedure Take (Index : out Natural);
                  procedure Note (Reason : E.Error_Info);
                  function Reason return E.Error_Info;
               private
                  Next : Natural := Held'First;
                  Bad  : E.Error_Info := E.Success;
               end Shared;

               protected body Shared is
                  procedure Take (Index : out Natural) is
                  begin
                     if Next > Held'Last or else E.Is_Error (Bad) then
                        Index := 0;
                     else
                        Index := Next;
                        Next := Next + 1;
                     end if;
                  end Take;

                  procedure Note (Reason : E.Error_Info) is
                  begin
                     if E.Is_Ok (Bad) then
                        Bad := Reason;
                     end if;
                  end Note;

                  function Reason return E.Error_Info is (Bad);
               end Shared;

               procedure Panel_One (Which : Positive) is
                  Where : constant View_Access := Held (Which);
                  Taken : Boolean;

                  Source : B.Byte_Array (1 .. Where.all.Span)
                    with Import, Address => Where.all.Base;
                  First : constant B.Byte_Index := Whole'First + Bases (Which);
                  Size  : constant B.Byte_Count :=
                    Model_Runner.Quantization.Interleave.Panel_Bytes
                      (Where.all.Format, Where.all.Rows, Blocks_Of (Where));
               begin
                  Whole (First .. First + Size - 1) := [others => 0];
                  Model_Runner.Quantization.Interleave.Build
                    (Format => Where.all.Format,
                     Source => Source,
                     From   => Where.all.Offset,
                     Target => Whole,
                     Into   => Bases (Which),
                     Rows   => Where.all.Rows,
                     Blocks => Blocks_Of (Where),
                     Ok     => Taken);

                  if not Taken then
                     Shared.Note (E.Make (E.Internal_Invariant_Violated));
                  end if;
               end Panel_One;

               task type Panelling;

               task body Panelling is
                  Which : Natural;
               begin
                  loop
                     Shared.Take (Which);
                     exit when Which = 0;
                     Panel_One (Which);

                     if C.Is_Cancelled (Cancel) then
                        Shared.Note (E.Make (E.Generation_Cancelled));
                     end if;
                  end loop;
               exception
                  when others =>
                     Shared.Note (E.Make (E.Internal_Invariant_Violated));
               end Panelling;
            begin
               declare
                  Running : B.Byte_Count := 0;
               begin
                  for Index in Held'Range loop
                     Bases (Index) := Running;
                     Running := Running
                       + Model_Runner.Quantization.Interleave.Panel_Bytes
                           (Held (Index).all.Format,
                            Held (Index).all.Rows,
                            Blocks_Of (Held (Index)));
                  end loop;
               end;

               declare
                  Team : array (1 .. Positive'Min (Threads, Held'Length))
                    of Panelling;
                  pragma Unreferenced (Team);
               begin
                  null;
               end;

               declare
                  Trouble : constant E.Error_Info := Shared.Reason;
               begin
                  if E.Is_Error (Trouble) then
                     if Into_File then
                        Model_Runner.Panel_Cache.Abandon (Built);
                     end if;
                     Fail (Trouble);
                     return;
                  end if;
               end;

               --  Built in the file: named, and mapped again for reading
               --  as a later load maps it, without the comparison a later
               --  load makes, since these are the bytes it would compare.
               --  Where that fails the panels are copied into the
               --  process's memory and go on from there, as before.
               if Into_File then
                  declare
                     Named : Boolean;
                  begin
                     Model_Runner.Panel_Cache.Finish (Built, Named);
                     if Named and then Map_Panels (Needed, Verify => False)
                     then
                        Model_Runner.Panel_Cache.Release (Built);
                        goto Panels_Done;
                     end if;

                     begin
                        Item.Repacked := new B.Byte_Array (1 .. Needed);
                     exception
                        when Storage_Error =>
                           Item.Repacked := null;
                     end;
                     if Item.Repacked = null then
                        Model_Runner.Panel_Cache.Abandon (Built);
                        Fail (E.Make (E.Memory_Allocation_Failed));
                        return;
                     end if;
                     Item.Repacked.all := Whole;
                     Mem.Record_Allocation
                       (Item.Accounting, Mem.Converted_Weights,
                        Interfaces.Unsigned_64 (Needed));
                     Model_Runner.Panel_Cache.Release (Built);
                     Into_File := Named;
                  end;
               end if;

               for Index in Held'Range loop
                  declare
                     Fresh : T.View;
                  begin
                     T.Make_Panels
                       (Format  => Held (Index).all.Format,
                        Rows    => Held (Index).all.Rows,
                        Columns => Held (Index).all.Columns,
                        Data    => Item.Repacked,
                        Offset  => Bases (Index),
                        Result  => Fresh,
                        Status  => Status);
                     if E.Is_Error (Status) then
                        Fail (Status);
                        return;
                     end if;

                     Held (Index).all := Fresh;
                  end;
               end loop;
            end;

            if Panel_File (Needed) /= "" and then not Into_File then
               Write_Panels (Needed);
            end if;

            <<Panels_Done>>
            null;
         end if;
      end;
   end if;

   --  The split layers the device holds until the cache wants their room
   --  (Feed_Room): their panels set aside, the file's matrices where the
   --  device reads them, and the matrices' budget the whole model.
   if Item.Feed_Room > 0 then
      for L of Item.Layers.all loop
         if L.Host_Feed and then T.Is_Present (L.File_Gate)
           and then T.Is_Present (L.File_Up) and then T.Is_Present (L.File_Down)
         then
            declare
               None : T.View;
            begin
               L.Panel_Gate := L.Gate;
               L.Panel_Up := L.Up;
               L.Panel_Down := L.Down;
               L.Gate := L.File_Gate;
               L.Up := L.File_Up;
               L.Down := L.File_Down;
               L.File_Gate := None;
               L.File_Up := None;
               L.File_Down := None;
               L.Host_Feed := False;
            end;
         end if;
      end loop;
      Model_Runner.Backend.Device.Fit_Budget (Item.Feed_Weights);
      Item.Able := Model_Runner.Backend.Device.Describe;
   end if;

   --  Decode the weight matrices once, if that was asked for.
   --
   --  Every matrix then refers into a second buffer holding binary32,
   --  and nothing else changes: the values written are the ones the
   --  decoder produces, in the order the kernels read them, so what
   --  follows is the same arithmetic on the same numbers. What it costs
   --  is four bytes a weight against about one, which is why it is asked
   --  for rather than done.
   if Repack = To_F32 or else Repack = To_BF16 then
      P.Publish (Observer, P.Load_Progress (P.Repacking_Weights));

      declare
         --  Bytes a weight, and the format the copy is written in.
         Width : constant B.Byte_Count :=
           (if Repack = To_BF16 then 2 else 4);
         Format : constant Model_Runner.GGUF.Tensor_Type :=
           (if Repack = To_BF16
            then Model_Runner.GGUF.Type_BF16
            else Model_Runner.GGUF.Type_F32);

         use type Interfaces.Unsigned_32;

         Needed : B.Byte_Count := 0;

         --  The ones that need decoding, out of the matrices this
         --  model holds. A matrix already in the target format is
         --  nothing to decode: copying it would double the memory to buy
         --  nothing, which is what the first version of this did to
         --  every binary32 tensor in a file.
         Skipped : Natural := 0;

         function To_Decode return View_List is
            Whole : constant View_List := Matrices (Item);
            Room  : View_List (Whole'Range);
            Count : Natural := 0;

            Target : constant Model_Runner.GGUF.Tensor_Type :=
              (if Repack = To_BF16
               then Model_Runner.GGUF.Type_BF16
               else Model_Runner.GGUF.Type_F32);
         begin
            for Where of Whole loop
               if Model_Runner.GGUF."=" (Where.all.Format, Target) then
                  Skipped := Skipped + 1;
               else
                  Count := Count + 1;
                  Room (Count) := Where;
               end if;
            end loop;

            return Room (1 .. Count);
         end To_Decode;

         Held : constant View_List := To_Decode;
      begin
         for Where of Held loop
            Needed := Needed
              + B.Byte_Count (Where.all.Rows)
                * B.Byte_Count (Where.all.Columns) * Width;
         end loop;

         --  Asked for before it is taken, like the weights themselves.
         --  Repacking is four bytes a weight where the file holds about
         --  one, so a memory limit that the model fits under is a limit
         --  the repacked copy may not, and a caller who set one meant it.
         Mem.Check_Allocation
           (Item.Accounting, Mem.Converted_Weights,
            Interfaces.Unsigned_64 (Needed), Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         B.Allocate (Needed, Item.Repacked);
         if Item.Repacked = null then
            Fail (E.Make (E.Memory_Allocation_Failed));
            return;
         end if;

         Mem.Record_Allocation
           (Item.Accounting, Mem.Converted_Weights,
            Interfaces.Unsigned_64 (Needed));
         Mem.Record_Conversion
           (Item.Accounting, Interfaces.Unsigned_64 (Needed));

         --  Where each matrix's copy begins, computed before anything
         --  is written so that the decoding can be handed out.
         declare
            Bases : array (Held'Range) of B.Byte_Count :=
              [others => 0];
            Trouble : E.Error_Info := E.Success;

            --  Which matrix to take next. A queue rather than a slice
            --  per task: the matrices differ by a factor of ten in size,
            --  and a fair-looking split by count is not a fair split of
            --  the work.
            protected Shared is
               procedure Take (Index : out Natural);
               procedure Note (Reason : E.Error_Info);
               function Reason return E.Error_Info;
            private
               Next : Natural := Held'First;
               Bad  : E.Error_Info := E.Success;
            end Shared;

            protected body Shared is
               procedure Take (Index : out Natural) is
               begin
                  if Next > Held'Last or else E.Is_Error (Bad) then
                     Index := 0;
                  else
                     Index := Next;
                     Next := Next + 1;
                  end if;
               end Take;

               procedure Note (Reason : E.Error_Info) is
               begin
                  if E.Is_Ok (Bad) then
                     Bad := Reason;
                  end if;
               end Note;

               function Reason return E.Error_Info is (Bad);
            end Shared;

            --  One matrix, decoded into its own region.
            procedure Decode_One (Which : Positive) is
               Where   : constant View_Access := Held (Which);
               Rows    : constant Element_Count := Where.all.Rows;
               Columns : constant Element_Count := Where.all.Columns;
               Base    : constant B.Byte_Count := Bases (Which);
               Row     : T.Real_Array (0 .. Columns - 1) := [others => 0.0];
               Local   : E.Error_Info;
            begin
               for Index in 0 .. Rows - 1 loop
                  T.Dequantize_Row (Where.all, Index, Row, Local);
                  if E.Is_Error (Local) then
                     Shared.Note (Local);
                     return;
                  end if;

                  for Column in Row'Range loop
                     declare
                        At_Byte : constant B.Byte_Count :=
                          Base
                          + (B.Byte_Count (Index) * B.Byte_Count (Columns)
                             + B.Byte_Count (Column)) * Width;
                     begin
                        if Repack = To_BF16 then
                           declare
                              Whole : constant Interfaces.Unsigned_32 :=
                                N.Bits (Row (Column));
                              Round : constant Interfaces.Unsigned_32 :=
                                16#7FFF#
                                + (Interfaces.Shift_Right (Whole, 16)
                                   and 1);
                           begin
                              Item.Repacked.all
                                (Item.Repacked.all'First + At_Byte
                                 .. Item.Repacked.all'First + At_Byte + 1)
                                := B.Put_U16
                                     (Interfaces.Unsigned_16
                                        (Interfaces.Shift_Right
                                           (Whole + Round, 16)
                                         and 16#FFFF#));
                           end;
                        else
                           Item.Repacked.all
                             (Item.Repacked.all'First + At_Byte
                              .. Item.Repacked.all'First + At_Byte + 3) :=
                             B.Put_F32 (Row (Column));
                        end if;
                     end;
                  end loop;

                  if C.Is_Cancelled (Cancel) then
                     Shared.Note (E.Make (E.Generation_Cancelled));
                     return;
                  end if;
               end loop;
            end Decode_One;

            task type Decoder;

            task body Decoder is
               Which : Natural;
            begin
               loop
                  Shared.Take (Which);
                  exit when Which = 0;
                  Decode_One (Which);
               end loop;
            exception
               when others =>
                  Shared.Note (E.Make (E.Internal_Invariant_Violated));
            end Decoder;
         begin
            declare
               Running : B.Byte_Count := 0;
            begin
               for Index in Held'Range loop
                  Bases (Index) := Running;
                  Running := Running
                    + B.Byte_Count (Held (Index).all.Rows)
                      * B.Byte_Count (Held (Index).all.Columns) * Width;
               end loop;
            end;

            declare
               Team : array (1 .. Positive'Min (Threads, Held'Length))
                 of Decoder;
               pragma Unreferenced (Team);
            begin
               null;
            end;

            Trouble := Shared.Reason;
            if E.Is_Error (Trouble) then
               Fail (Trouble);
               return;
            end if;

            for Index in Held'Range loop
               declare
                  Fresh : T.View;
               begin
                  T.Make
                    (Format  => Format,
                     Rows    => Held (Index).all.Rows,
                     Columns => Held (Index).all.Columns,
                     Data    => Item.Repacked,
                     Offset  => Bases (Index),
                     Result  => Fresh,
                     Status  => Status);
                  if E.Is_Error (Status) then
                     Fail (Status);
                     return;
                  end if;
                  Fresh.Role := Held (Index).all.Role;
                  Held (Index).all := Fresh;
               end;
            end loop;
         end;

         --  Only when nothing is left pointing at it. A matrix already
         --  in the target format is not copied, and its view still
         --  refers into the file's bytes -- freeing them under it read
         --  outside its storage on the first product, which is what an
         --  all-binary32 file did the moment the skip was added.
         if Skipped = 0 then
            declare
               Was : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64 (Item.Weights_Span);
            begin
               Release_Weights (Item);
               Mem.Record_Release
                 (Item.Accounting, Mem.Model_Weights, Was);
            end;
         end if;
      end;
   end if;

   --  What the rewrite cost, for the statistics: the copy's bytes and
   --  the time it took, file order to panels or to binary32.
   if Repack /= No_Repack and then Item.Repacked /= null then
      Item.Repack_Ns := Model_Runner.Clocks.Elapsed
        (Repack_Started, Model_Runner.Clocks.Now (Repack_Clock));
   end if;

   --  And whether the backend has room for what those matrices now are.
   --
   --  Asked after any repacking, because repacking is what changes the
   --  answer: a model that fits a device as it is stored may not fit it
   --  at four bytes a weight. Asked before the model is declared ready,
   --  because being told after a minute of loading is being told a minute
   --  late.
   --
   --  This is a warning in the shape of a refusal and it is a refusal on
   --  purpose. A model larger than the device's share still runs -- what
   --  does not fit is given back and uploaded again as it is wanted --
   --  but it runs slower than the processor would, and quietly. A caller
   --  who wants that can say --repack none, choose another backend, or
   --  raise nothing at all and be told what the numbers were.
   if Fit_Required and then Item.Able.Memory_Bytes > 0 then
      declare
         Held  : constant View_List := Matrices (Item);
         Total : Interfaces.Unsigned_64 := 0;

         --  Distinct storage, because a model with a tied output holds
         --  one matrix under two names and a device asked to keep it
         --  twice keeps it once: the address is the key.
         function Counted_Before (Upto : Natural) return Boolean is
         begin
            for Earlier in Held'First .. Upto - 1 loop
               if Held (Earlier).all.Base = Held (Upto).all.Base
                 and then Held (Earlier).all.Offset
                          = Held (Upto).all.Offset
               then
                  return True;
               end if;
            end loop;
            return False;
         end Counted_Before;
      begin
         for Index in Held'Range loop
            if not Counted_Before (Index) then
               Total := Total
                 + Interfaces.Unsigned_64 (Held (Index).all.Rows)
                   * Interfaces.Unsigned_64 (T.Row_Bytes (Held (Index).all));
            end if;
         end loop;

         --  What the processor runs of a split is not the device's.
         if Dense_Split then
            for Where of Held loop
               if Host_Fed (Where) and then Bytes_Of (Where.all) <= Total then
                  Total := Total - Bytes_Of (Where.all);
               end if;
            end loop;
         end if;

         --  What a TOKEN reads, which is what decides whether a model
         --  larger than the device's share runs well or badly.
         --
         --  A dense model reads every weight for every token, so a
         --  budget holding a fraction of it uploads the rest every
         --  token: TinyLlama-1.1B on this part reads 5.3 tokens a second
         --  that way against the processor's 39.4, which is the seven
         --  and a half times slower this refusal was written for and
         --  still is.
         --
         --  A MIXTURE READS EIGHT EXPERTS OF A HUNDRED AND TWENTY-EIGHT.
         --  Its token touches its dense half and a sixteenth of its
         --  experts, so a shortfall is uploaded a fraction as often, and
         --  Qwen3-30B-A3B -- 11.26 GB against the 8.47 this part offers
         --  -- reads 11.1 tokens a second on the device against 2.9 on
         --  the processor. Refusing that is refusing four times the
         --  speed, on the reasoning that applies to the other kind of
         --  model.
         declare
            Share : Interfaces.Unsigned_64 := Total;
         begin
            if Item.Settings.Experts > 0
              and then Item.Settings.Experts_Used > 0
              and then Item.Layers /= null
            then
               declare
                  Expert_Bytes : Interfaces.Unsigned_64 := 0;
               begin
                  for Index in Item.Layers.all'Range loop
                     if Item.Layers.all (Index).Experts /= null then
                        for Which of Item.Layers.all (Index).Experts.all
                        loop
                           Expert_Bytes := Expert_Bytes
                             + Interfaces.Unsigned_64 (Which.Gate.Rows)
                               * Interfaces.Unsigned_64
                                   (T.Row_Bytes (Which.Gate))
                             + Interfaces.Unsigned_64 (Which.Up.Rows)
                               * Interfaces.Unsigned_64
                                   (T.Row_Bytes (Which.Up))
                             + Interfaces.Unsigned_64 (Which.Down.Rows)
                               * Interfaces.Unsigned_64
                                   (T.Row_Bytes (Which.Down));
                        end loop;
                     end if;
                  end loop;

                  if Expert_Bytes <= Share then
                     Share := Share - Expert_Bytes
                       + Expert_Bytes
                         * Interfaces.Unsigned_64
                             (Item.Settings.Experts_Used)
                         / Interfaces.Unsigned_64 (Item.Settings.Experts);
                  end if;
               end;
            end if;

            if Share <= Item.Able.Memory_Bytes then
               Total := Share;
            end if;
         end;

         if Total > Item.Able.Memory_Bytes then
            Status := E.Make (E.Memory_Limit_Exceeded);

            --  Every parameter the message names, because a message
            --  missing one renders as its own key and says nothing at
            --  all. The category is the backend's memory rather than one
            --  of the accounting's, which is what this limit is about.
            E.Add_Text
              (Status, "category", "backend_memory", E.Param_Identifier);
            E.Add_Integer
              (Status, "requested", Long_Long_Integer (Total),
               E.Param_Bytes);
            E.Add_Integer
              (Status, "limit",
               Long_Long_Integer (Item.Able.Memory_Bytes), E.Param_Bytes);
            E.Add_Text
              (Status, "backend",
               Model_Runner.Backend.Backend_Name (Item.Able.Kind),
               E.Param_Identifier);
            Fail (Status);
            return;
         end if;
      end;
   end if;

   --  Whether a mixture's experts go to the device as stacks. Only
   --  where every weight fits the device's budget, distinct storage
   --  counted once as the fit check counts it: a stack is one matrix to
   --  the residency, and a model whose stacks do not all fit would give
   --  back and upload again a whole stack where it gave back a slice.
   Item.Stacked := False;
   Item.Split_Feed := Dense_Split;

   if Item.Settings.Experts > 0
     and then Item.Settings.Experts_Used > 0
     and then Item.Settings.Experts_Used
              <= Model_Runner.Backend.Device.Max_Members
     and then Item.Able.Memory_Bytes > 0
     and then Model_Runner.Backend."="
                (Item.Able.Kind, Model_Runner.Backend.Backend_Device)
   then
      declare
         Held  : constant View_List := Matrices (Item);
         Total : Interfaces.Unsigned_64 := 0;
      begin
         for Index in Held'Range loop
            declare
               Seen_Before : Boolean := False;
            begin
               for Earlier in Held'First .. Index - 1 loop
                  if Held (Earlier).all.Base = Held (Index).all.Base
                    and then Held (Earlier).all.Offset
                             = Held (Index).all.Offset
                  then
                     Seen_Before := True;
                     exit;
                  end if;
               end loop;

               if not Seen_Before then
                  Total := Total
                    + Interfaces.Unsigned_64 (Held (Index).all.Rows)
                      * Interfaces.Unsigned_64
                          (T.Row_Bytes (Held (Index).all));
               end if;
            end;
         end loop;

         Item.Stacked := Total <= Item.Able.Memory_Bytes;

         --  And the route kernel told whether this mixture's shares stay
         --  as the softmax gave them, so that one that does not
         --  renormalize -- DeepSeek-V2 -- routes on the device too.
         Model_Runner.Backend.Device.Keep_Route_Shares
           (not Item.Settings.Renormalize_Experts);

         --  Where the stacks do not fit, the device may still hold
         --  everything else: the feed-forward -- the stacks, the router
         --  and the shared expert, which the host's mixture reads -- goes
         --  to the processor's pool, and the device runs each layer's
         --  front half. A 21 GB mixture here holds 12.7: streamed, its
         --  experts read at 2.9 tokens a second on the device against
         --  13.9 on the processor alone.
         if not Item.Stacked and then Item.Layers /= null then
            declare
               Feed_Bytes : Interfaces.Unsigned_64 := 0;

               procedure Count (View : T.View) is
               begin
                  if T.Is_Present (View) then
                     Feed_Bytes := Feed_Bytes
                       + Interfaces.Unsigned_64 (View.Rows)
                         * Interfaces.Unsigned_64 (T.Row_Bytes (View));
                  end if;
               end Count;
            begin
               for Index in Item.Layers.all'Range loop
                  declare
                     L : Layer renames Item.Layers.all (Index);
                  begin
                     Count (L.Gate_Stack);
                     Count (L.Up_Stack);
                     Count (L.Down_Stack);
                     Count (L.Router);
                     Count (L.Shared_Gate);
                     Count (L.Shared_Up);
                     Count (L.Shared_Down);
                  end;
               end loop;

               Item.Split_Feed :=
                 Feed_Bytes > 0
                 and then Feed_Bytes < Total
                 and then Total - Feed_Bytes <= Item.Able.Memory_Bytes;
            end;
         end if;
      end;

      --  And the stacks put on the device now, where they fit, rather
      --  than as tokens route to them. A mixture touches an expert
      --  when a token chooses it, so a fresh process spent its first
      --  hundred tokens uploading five gigabytes a few matrices at a
      --  time and generated at half speed while it did; the same bytes
      --  cross here, once, while the caller is still loading. A stack
      --  the device will not hold is left for the tokens, as before.
      --
      --  Published as the finalizing it is part of: a stage of its own
      --  would be one a trace of every other load could not show.
      if Item.Stacked and then Item.Layers /= null then
         P.Publish (Observer, P.Load_Progress (P.Finalizing_Model));

         for Index in Item.Layers.all'Range loop
            declare
               Current : Layer renames Item.Layers.all (Index);
               Ignored : E.Error_Info;
            begin
               if T.Is_Present (Current.Gate_Stack) then
                  Model_Runner.Backend.Device.Hold
                    (Current.Gate_Stack, Ignored);
                  Model_Runner.Backend.Device.Hold
                    (Current.Up_Stack, Ignored);
                  Model_Runner.Backend.Device.Hold
                    (Current.Down_Stack, Ignored);
               end if;
            end;
         end loop;
      end if;
   end if;

   P.Publish (Observer, P.Load_Progress (P.Finalizing_Model));
   Item.Packing := Repack;
   Item.Ready := True;
   P.Publish (Observer, P.Load_Progress (P.Model_Ready));
   Status := E.Success;
exception
   when Occurrence : others =>
      Close (Item, Ignored);
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.prepare");
      E.Add_Frame
        (Status, Ada.Exceptions.Exception_Name (Occurrence));
end Prepare;
