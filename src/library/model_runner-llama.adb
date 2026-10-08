with System.Atomic_Operations.Integer_Arithmetic;
with Ada.Strings.Fixed;
with Ada.Real_Time;
with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with System.Storage_Elements;

with Model_Runner.Arithmetic;
with Model_Runner.Conversation;
with Model_Runner.Delta_Rule;
with Model_Runner.Backend.Device;
with Model_Runner.Backend.Reference;
with Model_Runner.Quantization.Integers;
with Model_Runner.GGUF;
with Model_Runner.Quantization.Interleave;
with Model_Runner.Zeroed_Storage;

package body Model_Runner.Llama is

   --  A counter the workers of a pool job take items from.
   type Take_Counter is new Integer with Atomic;
   package Takes is new System.Atomic_Operations.Integer_Arithmetic
     (Take_Counter);

   --  See Set_Stream_Least.
   Stream_Least : Positive := Stream_Least_Default;

   function Batch_Limit (Item : Model'Class) return Positive
   is (if Item.Split_Feed and then Item.Settings.Experts = 0
       then Dense_Streamed_Batch
       elsif Item.Split_Feed then Streamed_Batch
       else Max_Batch);

   function Batch_Limit (Item : Model'Class; Depth : Natural) return Positive
   is
      --  Depth at which the submission's fixed part and its attention take
      --  alike, and the depth the limit holds whole to (see the spec).
      Even_At : constant := 12_672;
      Held_To : constant := 16_384;
   begin
      if not (Item.Split_Feed and then Item.Settings.Experts = 0)
        or else Depth <= Held_To
      then
         return Batch_Limit (Item);
      end if;
      return Positive'Max
        (64,
         Dense_Streamed_Batch * (Even_At + Held_To) / (Even_At + Depth)
           / 64 * 64);
   end Batch_Limit;

   procedure Set_Stream_Least (Positions : Positive) is
   begin
      Stream_Least := Positions;
   end Set_Stream_Least;

   use type Model_Runner.Tokenizer.Token_Id;
   use type Model_Runner.Numerics.Element_Count;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   procedure Free_Cells is
     new Ada.Unchecked_Deallocation (Cell_Counts, Cell_Counts_Access);

   --  Whether a layer slides a window.
   --
   --  The same rule Earliest applies, written once so that the two cannot
   --  disagree: a window at all, and not one of the layers the alternating
   --  architectures leave attending to everything.
   function Slides (Settings : Configuration; Layer : Natural) return Boolean
   is (Settings.Window > 0
       and then not (Settings.Alternating
                     and then Settings.Window_Every > 0
                     and then Layer mod Settings.Window_Every
                              = Settings.Window_Every - 1));

   --  Where a layer's keys, values and row scales begin.
   --
   --  A layer used to begin at its index times the whole context, because
   --  every layer held the whole context. They are different sizes now, so
   --  the beginnings are a running sum computed when the session opens and
   --  read from here rather than multiplied out at every use.
   function Keys_At (Item : Session; Layer : Natural) return Element_Count
   is (if Item.At_Keys = null then 0 else Item.At_Keys.all (Layer));

   function Values_At (Item : Session; Layer : Natural) return Element_Count
   is (if Item.At_Values = null then 0 else Item.At_Values.all (Layer));

   function Rows_At (Item : Session; Layer : Natural) return Element_Count
   is (if Item.At_Rows = null then 0 else Item.At_Rows.all (Layer));

   --  Where a position sits inside its layer.
   --
   --  Its distance from the lowest position that layer still holds. For a
   --  layer that holds everything that is the position itself, which is
   --  what this was before there was anything else.
   function Cell_Of
     (Item : Session; Layer : Natural; Position : Element_Count)
      return Element_Count
   is (if Item.Origin = null then Position
       else Position - Item.Origin.all (Layer));

   --  The same reason the kernels give. Every activation and weight here
   --  came out of a model file, so a not-a-number or an infinity is possible
   --  input, and this package guards against it explicitly: a non-finite
   --  value found in a tensor is a diagnostic, and so is a non-finite logit.
   --  Validity checking raises when such a value is read, which is before
   --  any of those guards can run, so it would replace each diagnostic with
   --  an exception -- reported, since nothing may escape, as the engine
   --  finding a defect in itself. Bounds and range checking are untouched.
   pragma Suppress (Validity_Check);

   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Kernels.Rotary_Sections;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Arithmetic.Checked;

   --  Record which carried chat format Chat holds; the empty string for the
   --  model's own template. Truncated to the room the record keeps, which
   --  every format name fits.
   procedure Set_Template_Format (Item : in out Model; Name : String);
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;
   use type Model_Runner.Bytes.Byte;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Tensors.Half_Array_Access;

   function Score_Scale (Settings : Configuration) return Real
   is (if Settings.Kind in Granite | Granite_MoE and then Settings.Attention_Mul /= 0.0
       then Settings.Attention_Mul
       else Real
         (1.0
          / Model_Runner.Numerics.Sqrt
              (Model_Runner.Numerics.Wide_Real
                 (if Settings.Kind = Gemma3
                     and then Settings.Layers = 62
                     and then Settings.Heads > 0
                  then Settings.Embedding / Settings.Heads
                  else Settings.Head_Size)))
         * Settings.Score_Gain);

   --  A view that says only how many rows DeepSeek's keys or values are:
   --  the device's whole layer reads their count off the views it is given
   --  for them, and makes them from the latent itself.
   function MLA_Rows
     (Up : Model_Runner.Tensors.View; Rows : Model_Runner.Numerics.Element_Count)
      return Model_Runner.Tensors.View
   is
      Result : Model_Runner.Tensors.View := Up;
   begin
      Result.Rows := Rows;
      return Result;
   end MLA_Rows;

   package A renames Model_Runner.Arithmetic;
   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.Cancellation;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package K renames Model_Runner.Kernels;
   package Mem renames Model_Runner.Memory;
   package N renames Model_Runner.Numerics;
   package P renames Model_Runner.Progress;
   package T renames Model_Runner.Tensors;
   package Workers_CPU renames Model_Runner.Backend.CPU;

   --  Which linear layer of the stack a layer is: how many linear layers
   --  come before it, which is where its state and its convolution's
   --  memory lie among the session's.
   function Linear_Ordinal
     (Settings : Configuration; Layer : Natural) return Natural
   is
      Count : Natural := 0;
   begin
      for Which in 0 .. Layer - 1 loop
         if Linear (Settings, Which) then
            Count := Count + 1;
         end if;
      end loop;

      return Count;
   end Linear_Ordinal;

   --  Where a linear layer's convolution memory begins: Conv_Kernel - 1
   --  positions' mixed projections, oldest first, Mix_Width apiece.
   --  Mamba's convolution runs over its inner width, the delta rule's over
   --  its mixed projection.
   --  Mamba convolves its inner width; Mamba2 convolves the inner width
   --  and its B and C beside it -- the block the in_projection lays out as
   --  one; the delta rule convolves its mixed projection.
   --  RWKV6 keeps two token-shift slots a layer -- the last position's ln1
   --  output for the time mix, its ln2 output for the channel mix -- as one
   --  memory of a single position (Conv_Kernel is two) that is twice the
   --  model width.
   function Conv_Width (Settings : Configuration) return Element_Count
   is (if Is_RWKV (Settings.Kind)
       then 2 * Element_Count (Settings.Embedding)
       elsif Is_Mamba2 (Settings.Kind)
       then Element_Count (Settings.Inner_Size)
            + 2 * Element_Count (Settings.Groups)
                * Element_Count (Settings.State_Size)
       elsif Pure_SSM (Settings.Kind) or else Is_Jamba (Settings.Kind)
       then Element_Count (Settings.Inner_Size)
       else Element_Count (Mix_Width (Settings)));

   --  Mamba's state is a channel by a state, the delta rule's a value head
   --  by a state by a state.
   --  RWKV6's state is a matrix a head, the head's width by the head's
   --  width -- the linear attention it keeps instead of a cache.
   function State_Cells (Settings : Configuration) return Element_Count
   is (if Is_RWKV (Settings.Kind)
       then Element_Count (Settings.Ssm_Heads)
            * Element_Count (Settings.Head_Dim)
            * Element_Count (Settings.Head_Dim)
       elsif Pure_SSM (Settings.Kind) or else Is_Jamba (Settings.Kind)
       then Element_Count (Settings.Inner_Size)
            * Element_Count (Settings.State_Size)
       else Element_Count (Settings.Value_Heads)
            * Element_Count (Settings.State_Size)
            * Element_Count (Settings.State_Size));

   function Conv_At
     (Settings : Configuration; Layer : Natural) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Layer))
       * Element_Count (Settings.Conv_Kernel - 1)
       * Conv_Width (Settings));

   --  Where a linear layer's state begins within a slot: State_Size by
   --  State_Size a value head, the heads one after another, and within
   --  a head the state key-major -- row i holds S (i, j) for every j,
   --  contiguously -- so that every step of the rule is a row scaled
   --  into a running row.
   function State_At
     (Settings : Configuration; Layer : Natural) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Layer)) * State_Cells (Settings));

   --  How many numbers all of a session's linear states take, and all of
   --  its convolution memories.
   function State_Room (Settings : Configuration) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Settings.Layers))
       * State_Cells (Settings));

   function Conv_Room (Settings : Configuration) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Settings.Layers))
       * Element_Count (Settings.Conv_Kernel - 1)
       * Conv_Width (Settings));

   --  Which slot of the ring holds the state a position reads: the one
   --  the position before it wrote. Kept_States + 1 slots, the one slot
   --  where nothing is kept.
   function State_Slot
     (Item : Session; Position : Natural) return Element_Count
   is (Element_Count (Position mod (Item.Kept_States + 1)));

   --  The three that shape a linear layer's numbers, in binary32 as the
   --  other runtime computes them.
   function Sigmoid (Value : Real) return Real
   is (Real (1.0 / (1.0 + N.Exp (N.Wide_Real (-Value)))));

   --  The weight a shared expert's answer is added with: the sigmoid of
   --  the layer's own router row against the input, or one where the
   --  mixture keeps no such row.
   function Shared_Weight
     (Router : T.Real_Array_Access;
      Input  : Real_Array;
      At_Row : Element_Count) return Real
   is
      Gate : N.Wide_Real := 0.0;
   begin
      if Router = null then
         return 1.0;
      end if;
      for C in Router.all'Range loop
         Gate := Gate
           + N.Wide_Real (Input (At_Row + (C - Router.all'First)))
             * N.Wide_Real (Router.all (C));
      end loop;
      return Sigmoid (Real (Gate));
   end Shared_Weight;

   function Softplus (Value : Real) return Real
   is (if Value > 20.0 then Value
       else Real (N.Log (1.0 + N.Exp (N.Wide_Real (Value)))));

   --  Which matrix a view is, for a watcher. Declared here because the
   --  product wrappers below are above its body.
   function Named_As (Item : Model'Class; Which : T.View) return String;

   --  Bytes one cache element occupies, in each of the two storages a
   --  session may ask for. Exact is the correctness baseline every published
   --  figure is taken against; halved is what it says, and the conformance
   --  evidence this used to say it would need before being advertised is in
   --  the README.
   --  In sixteenths of a byte, since the four-bit cache is not a whole
   --  number of bytes an element: half a byte, and a scale of four bytes
   --  for every thirty-two -- ten sixteenths.
   Cache_Element_Sixteenths :
     constant array (Cache_Precision) of Interfaces.Unsigned_64 :=
       [Exact => 64, Halved => 32, Eighth => 16, Fourth => 10];

   --  The per-layer tensors jina-bert-v2's code variant carries and its text
   --  variant does not. Named here so that the loading below asks for
   --  all six by one list: a file with any of them has to carry every one.
   type Tensor_Name is access constant String;
   Jina_Code_Norms : constant array (1 .. 6) of Tensor_Name :=
     [new String'("attn_q_norm.weight"),
      new String'("attn_q_norm.bias"),
      new String'("attn_k_norm.weight"),
      new String'("attn_k_norm.bias"),
      new String'("attn_norm_2.weight"),
      new String'("attn_norm_2.bias")];

   --  Metadata keys are built once, here, so that no other package spells a
   --  tensor or metadata name.
   function Layer_Key (Index : Natural; Suffix : String) return String
   is ("blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
       & "." & Suffix);

   --  Metadata keys carry the architecture's own name, so the same reader
   --  finds llama.context_length in one file and qwen2.context_length in
   --  another without either name being written anywhere but here.
   function Model_Key
     (Kind : Architecture; Suffix : String) return String
   is (Architecture_Name (Kind) & "." & Suffix);

   procedure Deallocate_Layers is
     new Ada.Unchecked_Deallocation (Layer_Array, Layer_Array_Access);

   procedure Deallocate_Experts is
     new Ada.Unchecked_Deallocation (Expert_Array, Expert_Array_Access);

   procedure Deallocate_History is
     new Ada.Unchecked_Deallocation (Token_History, Token_History_Access);
   procedure Deallocate_Marks is
     new Ada.Unchecked_Deallocation (Rope_Marks, Rope_Marks_Access);

   --  The position a text token at Index turns by: what the mark before
   --  it says comes next, or the index itself where the model marks
   --  nothing. Past the last mark written, one more a position.
   function Rope_Next (Item : Session; Index : Natural) return Natural
   is (if Item.Marks = null or else Index = 0 then Index
       elsif Index <= Item.Marked then Item.Marks.all (Index - 1).Next
       elsif Item.Marked = 0 then Index
       else Item.Marks.all (Item.Marked - 1).Next + (Index - Item.Marked));

   --  What the position at Index turns by.
   function Place_At (Item : Session; Index : Natural) return K.Rotary_Place;

   function Turned_By
     (Item : Session; Index : Natural) return Model_Runner.Kernels.Rotary_Place
   is (Place_At (Item, Index));

   function Place_At (Item : Session; Index : Natural) return K.Rotary_Place
   is (if Item.Marks = null or else Index >= Item.Marked
         or else Index > Item.Marks.all'Last
       then K.Everywhere (Rope_Next (Item, Index))
       else Item.Marks.all (Index).Place);

   --  Write the mark for the position at Index: a text token's, or a
   --  given row's from where it stands in its picture. Nothing for a
   --  model that marks nothing.
   procedure Set_Mark
     (Item   : in out Session;
      Index  : Natural;
      Row    : Row_Place := (others => <>);
      Is_Row : Boolean := False)
   is
   begin
      if Item.Marks = null or else Index > Item.Marks.all'Last then
         return;
      end if;

      declare
         Text_At : constant Natural := Rope_Next (Item, Index);
         Start   : constant Natural :=
           (if not Is_Row or else Row.First or else Index = 0
            then Text_At
            else Item.Marks.all (Index - 1).Place.T);
      begin
         if Is_Row then
            Item.Marks.all (Index) :=
              (Place => (T => Start, H => Start + Row.Row, W => Start + Row.Column),
               Next  => Start + Row.Advance);
         else
            Item.Marks.all (Index) :=
              (Place => K.Everywhere (Text_At), Next => Text_At + 1);
         end if;
      end;

      if Index >= Item.Marked then
         Item.Marked := Index + 1;
      end if;
   end Set_Mark;

   ---------------------------------------------------------------------------
   --  Configuration
   ---------------------------------------------------------------------------

   --  Read and validate the architecture metadata.
   -------------------
   -- Apply_Stretch --
   -------------------

   --  Put what the caller asked of the rotation over what the file said.
   --
   --  Everything here was already read out of files and already runs. A
   --  model whose author wrote `rope.scaling.type` is stretched; a model
   --  whose author did not could not be stretched by anyone, which is a
   --  decision the file was making on the reader's behalf and had no
   --  business making. This is the same set of numbers, asked for.
   --
   --  EACH IS APPLIED ONLY WHERE IT WAS NAMED. Asking for a factor and
   --  nothing else takes the file's own band and attenuation with it, so a
   --  caller who wants twice the context of a Yarn model says so in one
   --  number and keeps everything the author tuned.
   procedure Apply_Stretch
     (Settings : in out Configuration;
      Ask      : Rotary_Request;
      Status   : out E.Error_Info)
   is
      --  Whether anything at all was asked for. A record of zeros is what
      --  every caller before this passed and means the file decides.
      Asked : constant Boolean :=
        Ask.Kind /= Unasked
        or else Ask.Factor /= 0.0
        or else Ask.Base /= 0.0
        or else Ask.Original /= 0
        or else Ask.Beta_Fast /= 0.0
        or else Ask.Beta_Slow /= 0.0
        or else Ask.Attenuation /= 0.0;
   begin
      Status := E.Success;

      if not Asked then
         return;
      end if;

      --  A model that turns nothing cannot be stretched, and the refusal
      --  says which model rather than which key. GPT2 and Bert learn a row
      --  a position and hold as many rows as they were trained with: there
      --  is no angle to turn by a different amount, and a caller asking for
      --  one has misunderstood the model rather than mistyped a number.
      if Settings.Rotary = 0 then
         Status := E.Make (E.Arch_Rotation_Not_Stretchable);
         E.Add_Text
           (Status, "architecture", Architecture_Name (Settings.Kind),
            E.Param_Identifier);
         return;
      end if;

      --  The kind. A factor named with no kind is the linear stretch, which
      --  is what a bare factor has always meant -- the key predates there
      --  being more than one kind of stretch, and so does the habit.
      case Ask.Kind is
         when Unasked =>
            if Ask.Factor /= 0.0 then
               Settings.Scaling.Kind := K.Linear;
            end if;

         when As_Trained =>
            Settings.Scaling.Kind := K.Unscaled;

         when Linear_Stretch =>
            Settings.Scaling.Kind := K.Linear;

         when Yarn_Stretch =>
            Settings.Scaling.Kind := K.Yarn;
      end case;

      --  The factor, as a person states it: two is twice the context. What
      --  the kernels hold is its reciprocal, because that is what a file
      --  states and what the arithmetic multiplies by.
      if Ask.Factor /= 0.0 then
         Settings.Scaling.Frequency := 1.0 / Ask.Factor;
      end if;

      if Ask.Base /= 0.0 then
         Settings.Rope_Base := Ask.Base;
      end if;

      if Ask.Beta_Fast /= 0.0 then
         Settings.Scaling.Beta_Fast := Ask.Beta_Fast;
      end if;

      if Ask.Beta_Slow /= 0.0 then
         Settings.Scaling.Beta_Slow := Ask.Beta_Slow;
      end if;

      if Ask.Attenuation /= 0.0 then
         Settings.Scaling.Attenuation := Ask.Attenuation;
      end if;

      --  What Yarn derives its ramp from. A caller who asked for Yarn and
      --  did not say what it was trained on means the context the file
      --  states, which is the same rule the file path takes.
      if Ask.Original /= 0 then
         Settings.Scaling.Original := Ask.Original;
      elsif K."=" (Settings.Scaling.Kind, K.Yarn)
        and then Settings.Scaling.Original = 0
      then
         Settings.Scaling.Original := Settings.Context_Length;
      end if;

      --  And the one consequence: a model stretched by request may be
      --  opened at a context longer than the one it was trained on. A model
      --  that was not may not, which is the rule as it was, and a request
      --  for the rotation as trained is a request to keep that rule.
      Settings.Stretched := not K."=" (Settings.Scaling.Kind, K.Unscaled);
   end Apply_Stretch;

   procedure Read_Configuration
     (Source   : Containers.Container;
      Bounds   : Model_Runner.Limits.Model_Limits;
      Settings : out Configuration;
      Status   : out E.Error_Info)
   is separate;

   ------------------
   -- Read_Config --
   ------------------

   procedure Read_Config
     (Source   : Containers.Container;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Settings : out Configuration;
      Status   : out E.Error_Info) is
   begin
      Read_Configuration (Source, Bounds, Settings, Status);
   end Read_Config;

   ---------------------------------------------------------------------------
   --  Tensor resolution
   ---------------------------------------------------------------------------

   --  Every matrix a model holds, as references to the views that name
   --  them. A norm is already a decoded vector and a bias is too, so neither
   --  is here.
   --
   --  One list, because there are two questions about the same set -- what
   --  to decode when repacking, and how many bytes a backend would have to
   --  hold -- and a second copy of the walk is a second place for a tensor
   --  to be forgotten. The mixture layers are where that would happen: three
   --  matrices an expert, and a list written twice would have them in one.
   type View_Access is access all T.View;
   type View_List is array (Positive range <>) of View_Access;

   function Matrices (Item : in out Model) return View_List is
      --  Seven a dense layer, and a mixture layer instead carries a router
      --  and three matrices an expert.
      --  Nine more for a hybrid: a linear layer's five and a shared
      --  expert's three and the next block's projection, counted for every
      --  layer and left empty where a layer has none, since Add skips an
      --  empty view.
      Per_Layer : constant Positive :=
        (if Item.Settings.Experts = 0
         then 7
         else 4 + 1 + 3 * Item.Settings.Experts)
        + (if Hybrid (Item.Settings.Kind) then 9 else 0)
        + (if Is_RWKV (Item.Settings.Kind) then 8 else 0)
        --  DeepSeek's latent attention carries two query and two key-value
        --  matrices in place of the three a plain attention has, and a
        --  shared expert's three beside the routed ones. Counted for every
        --  layer and left empty where a layer has none, since Add skips an
        --  empty view.
        + (if Is_MLA (Item.Settings.Kind) then 6 else 0);

      --  Four beside the layers -- the embedding table, the output
      --  projection, the positions and the segments -- though no
      --  architecture carries all four: a model with segments has no output
      --  projection. Sized for four anyway, because "three is enough" is
      --  true by a coincidence between two architectures rather than by
      --  anything holding it, and the cost of the fourth is a pointer.
      Room  : View_List
        (1 .. 4 + Per_Layer * (Item.Settings.Layers + Item.Settings.Next_Layers));
      Count : Natural := 0;

      procedure Add (Where : View_Access) is
      begin
         if T.Is_Present (Where.all) then
            Count := Count + 1;
            Room (Count) := Where;
         end if;
      end Add;

      --  A layer's matrices, of the stack or past it.
      procedure Add_Layer (Which : in out Layer) is
      begin
         Add (Which.Query'Unchecked_Access);

         --  DeepSeek's latent projections, read through the product like
         --  any matrix and so repacked like any; its two latent norms are
         --  read whole and are not here.
         Add (Which.Q_A'Unchecked_Access);
         Add (Which.Q_B'Unchecked_Access);
         Add (Which.KV_A_MQA'Unchecked_Access);
         Add (Which.KV_B'Unchecked_Access);
         Add (Which.Key'Unchecked_Access);
         Add (Which.Value'Unchecked_Access);
         Add (Which.Attention_Out'Unchecked_Access);
         Add (Which.Gate'Unchecked_Access);
         Add (Which.Up'Unchecked_Access);
         Add (Which.Down'Unchecked_Access);
         Add (Which.Router'Unchecked_Access);

         Add (Which.Mix'Unchecked_Access);
         Add (Which.Z_Gate'Unchecked_Access);
         Add (Which.Alpha'Unchecked_Access);
         Add (Which.Beta'Unchecked_Access);

         --  Mamba's three projected matrices, read through Product like any
         --  other and so repacked like any other; the scan's own vectors
         --  (Ssm_A, the convolution, Ssm_D) are read whole at load and are
         --  not here. Left out once, and a repacked model read Ssm_In out
         --  of storage the repacking had freed -- finite in, non-finite
         --  out, and the selective scan carried the NaN down the stack.
         Add (Which.Ssm_In'Unchecked_Access);
         Add (Which.Ssm_X'Unchecked_Access);
         Add (Which.Ssm_Dt'Unchecked_Access);
         Add (Which.Linear_Out'Unchecked_Access);

         --  RWKV6's eight wide matrices, read through the product like any
         --  other and so repacked like any other; its low projections and
         --  its vectors are read whole and are not here.
         Add (Which.Rwkv_R'Unchecked_Access);
         Add (Which.Rwkv_K'Unchecked_Access);
         Add (Which.Rwkv_V'Unchecked_Access);
         Add (Which.Rwkv_G'Unchecked_Access);
         Add (Which.Rwkv_TM_Out'Unchecked_Access);
         Add (Which.Rwkv_CM_K'Unchecked_Access);
         Add (Which.Rwkv_CM_V'Unchecked_Access);
         Add (Which.Rwkv_CM_R'Unchecked_Access);
         Add (Which.Shared_Gate'Unchecked_Access);
         Add (Which.Shared_Up'Unchecked_Access);
         Add (Which.Shared_Down'Unchecked_Access);
         Add (Which.Next_Proj'Unchecked_Access);

         if Which.Experts /= null then
            for Expert in Which.Experts.all'Range loop
               Add (Which.Experts.all (Expert).Gate'Unchecked_Access);
               Add (Which.Experts.all (Expert).Up'Unchecked_Access);
               Add (Which.Experts.all (Expert).Down'Unchecked_Access);
            end loop;
         end if;
      end Add_Layer;
   begin
      Add (Item.Embeddings'Unchecked_Access);
      Add (Item.Output'Unchecked_Access);
      Add (Item.Positions'Unchecked_Access);
      Add (Item.Segments'Unchecked_Access);

      for Index in Item.Layers'Range loop
         Add_Layer (Item.Layers (Index));
      end loop;

      if Item.Next /= null then
         for Index in Item.Next'Range loop
            Add_Layer (Item.Next (Index));
         end loop;
      end if;

      return Room (1 .. Count);
   end Matrices;

   --  Resolve one tensor by name and check its shape against the role it
   --  plays. Every required tensor is resolved during preparation; no name
   --  lookup happens during evaluation.
   --  The role a weight plays, read from its name: what a file calls
   --  "attn_" is an attention projection, "ffn_" a feed-forward one, and
   --  the output head is the output weight or, tied, the token table.
   --  Everything else -- a hybrid's linear layers, the block past the
   --  stack -- is other.
   function Role_Of (Name : String) return T.Weight_Role is
      function Has (Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Name, Part) > 0);
   begin
      if Name = "output.weight" or else Name = "token_embd.weight" then
         return T.Role_Output;
      elsif Has (".attn_") then
         return T.Role_Attention;
      elsif Has (".ffn_") then
         return T.Role_Feed_Forward;
      else
         return T.Role_Other;
      end if;
   end Role_Of;

   procedure Resolve
     (Item     : in out Model;
      Source   : Containers.Container;
      Name     : String;
      Rows     : Element_Count;
      Columns  : Element_Count;
      Result   : out T.View;
      Status   : out E.Error_Info;

      --  What the caller asked to have the weights decoded into, because
      --  that -- and not what the file holds -- is what a backend will read
      --  from this tensor.
      Repack   : Repack_Mode := No_Repack;

      --  False for a tensor decoded once at load and never handed over: a
      --  norm or a bias is a vector by the time anything computes with it,
      --  so the format the file wrote it in is nothing the backend sees.
      Reaches  : Boolean := True)
   is
      Index : constant Natural := Containers.Find_Tensor (Source, Name);
   begin
      Result := T.Empty_View;

      if Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      if not Containers.Tensor_Is_Supported (Source, Index) then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text
           (Status, "format",
            Model_Runner.GGUF.Type_Name
              (Containers.Tensor_Format (Source, Index)),
            E.Param_Identifier);
         return;
      end if;

      --  And what the backend can read, which is a different question from
      --  what the container can describe. Asked here, per tensor, while the
      --  model loads: a backend that cannot take a format should refuse the
      --  model that carries it, not meet it in the middle of a token.
      --
      --  Asked of the format the backend will read, which is the repacking
      --  target when there is one. Asking it of the file's format instead
      --  refuses `--repack f32` on a quantized model -- and a backend that
      --  reads binary32 only is exactly the backend repacking exists to make
      --  usable, so the check would have refused every model the flag was
      --  for. It did, once.
      declare
         Seen : constant Model_Runner.GGUF.Tensor_Type :=
           (case Repack is
              when No_Repack | To_Rows =>
                Containers.Tensor_Format (Source, Index),
              when To_F32    => Model_Runner.GGUF.Type_F32,
              when To_BF16   => Model_Runner.GGUF.Type_BF16);
      begin
         if Reaches
           and then not Model_Runner.Backend.Supports (Item.Able, Seen)
         then
            Status := E.Make (E.Backend_Unsupported_Format);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Text
              (Status, "format", Model_Runner.GGUF.Type_Name (Seen),
               E.Param_Identifier);
            E.Add_Text
              (Status, "backend",
               Model_Runner.Backend.Backend_Name (Item.Able.Kind),
               E.Param_Identifier);
            return;
         end if;
      end;

      --  And where it sits. A backend states the alignment it needs from
      --  tensor storage; a file is free to place a tensor anywhere its own
      --  alignment allows, and the two are not the same number.
      if Containers.Tensor_Offset (Source, Index)
         mod Interfaces.Unsigned_64 (Item.Able.Alignment) /= 0
      then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text (Status, "capability", "alignment", E.Param_Identifier);
         E.Add_Integer
           (Status, "alignment", Long_Long_Integer (Item.Able.Alignment),
            E.Param_Bytes);
         return;
      end if;

      declare
         Rank      : constant Positive := Containers.Tensor_Rank (Source, Index);
         Contiguous : constant Element_Count :=
           Element_Count (Containers.Tensor_Dimension (Source, Index, 1));
         Remaining : Element_Count := 1;
      begin
         for Axis in 2 .. Rank loop
            Remaining := Remaining
              * Element_Count (Containers.Tensor_Dimension (Source, Index, Axis));
         end loop;

         if Contiguous /= Columns or else Remaining /= Rows then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Contiguous));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Remaining));
            E.Add_Integer
              (Status, "expected_columns", Long_Long_Integer (Columns));
            E.Add_Integer (Status, "expected_rows", Long_Long_Integer (Rows));
            return;
         end if;

         T.Make
           (Format  => Containers.Tensor_Format (Source, Index),
            Rows    => Rows,
            Columns => Columns,
            Base    => Item.Weights_Base,
            Span    => Item.Weights_Span,
            Offset  =>
              B.Byte_Count (Containers.Tensor_Offset (Source, Index))
              - Item.Arena_Base,
            Result  => Result,
            Status  => Status);

         if E.Is_Error (Status) then
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         end if;
         Result.Role := Role_Of (Name);

         --  Where this matrix is, against what it is called. This is the
         --  one moment the two are in the same place: a view has an address
         --  and no name, and a name is what a watcher asks about.
         if E.Is_Ok (Status) and then Item.Named /= null then
            if Item.Named_Up < Item.Named.all'Length then
               Item.Named_Up := Item.Named_Up + 1;
               Item.Named.all (Item.Named_Up) :=
                 (Base   => Result.Base,
                  Offset => Result.Offset,
                  Name   => Model_Runner.Text.To_Bounded (Name));
            end if;
         end if;
      end;
   end Resolve;

   --  Resolve one projection out of a tensor that holds several.
   --
   --  Phi3 writes the queries, keys and values as one tensor and the gate
   --  and the up projection as another. A row is a whole number of blocks in
   --  every format this reads, so a part begins at a block boundary and is
   --  a view over the same bytes at an offset -- no copy, and the part is an
   --  ordinary matrix to everything downstream, including the repacking
   --  pass, which rewrites each part as its own tensor.
   --
   --  The whole shape is checked rather than the part's: a file whose fused
   --  tensor is the wrong size is a file this cannot read, and finding that
   --  out from the first part alone would take the first rows of something
   --  else and call them a projection.
   --
   --  @param Whole_Rows Rows the fused tensor holds altogether.
   --  @param First_Row Row this part starts at.
   --  @param Rows Rows this part holds.
   procedure Resolve_Part
     (Item       : in out Model;
      Source     : Containers.Container;
      Name       : String;
      Whole_Rows : Element_Count;
      Columns    : Element_Count;
      First_Row  : Element_Count;
      Rows       : Element_Count;
      Result     : out T.View;
      Status     : out E.Error_Info;
      Repack     : Repack_Mode := No_Repack)
   is
      Whole : T.View;
   begin
      Result := T.Empty_View;

      --  The whole tensor first, which is where the shape and the format
      --  are checked. Repack reaches it because that check asks what the
      --  backend will read rather than what the file holds.
      Resolve (Item, Source, Name, Whole_Rows, Columns, Whole, Status,
               Repack => Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Per_Block : constant Element_Count :=
           Element_Count (Model_Runner.GGUF.Block_Elements (Whole.Format));
         Row_Bytes : constant B.Byte_Count :=
           B.Byte_Count (Columns / Per_Block)
           * B.Byte_Count (Model_Runner.GGUF.Block_Bytes (Whole.Format));
      begin
         if Columns mod Per_Block /= 0 then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
            return;
         end if;

         T.Make
           (Format  => Whole.Format,
            Rows    => Rows,
            Columns => Columns,
            Base    => Item.Weights_Base,
            Span    => Item.Weights_Span,
            Offset  => Whole.Offset + B.Byte_Count (First_Row) * Row_Bytes,
            Result  => Result,
            Status  => Status);
         Result.Role := Whole.Role;
      end;

      --  Nothing repacks here. The pass that rewrites weights runs later,
      --  over every view the model holds, and a part is one of those: it
      --  arrives there as an ordinary matrix and is rewritten as its own
      --  tensor, which is also what makes a repacked phi3 model stop being
      --  fused at all.
   end Resolve_Part;

   --  Resolve a one-dimensional normalization weight and decode it once into a
   --  plain vector. Norm weights are read on every layer of every token, and
   --  they are tiny, so keeping them decoded costs little and removes a
   --  dequantization from the inner loop.
   procedure Resolve_Norm
     (Item   : in out Model;
      Source : Containers.Container;
      Name   : String;
      Width  : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Weight : T.View;
   begin
      Result := null;
      Resolve (Item, Source, Name, 1, Width, Weight, Status,
               Reaches => False);
      if E.Is_Error (Status) then
         return;
      end if;

      T.Allocate (Width, Result);
      if Result = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      Mem.Record_Allocation
        (Item.Accounting, Mem.Converted_Weights,
         Interfaces.Unsigned_64 (Width) * 4);
      Mem.Record_Conversion
        (Item.Accounting, Interfaces.Unsigned_64 (Width) * 4);

      T.Dequantize_Row (Weight, 0, Result.all, Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
      end if;
   end Resolve_Norm;

   --  Resolve part of a one-dimensional tensor several projections share.
   --
   --  The same arrangement the matrices are in: an architecture that writes
   --  its queries, keys and values as one tensor writes their biases as one
   --  vector too, and each is a run of elements at an offset. Copied out
   --  rather than made a view, because a bias is a few hundred numbers that
   --  are added to a row and nothing gains from sharing them.
   --
   --  @param Whole Elements the whole vector holds.
   --  @param First Element the part starts at.
   --  @param Count Elements the part holds.
   --  A small table of numbers -- Rows of Columns -- read whole into one
   --  array, row after row; or column after column, where the reader
   --  wants it the other way. The convolution's taps are one: the file
   --  keeps a row a component of the mixed projection with the taps along
   --  it, and the convolution wants a tap over every component, so that
   --  a tap is a run of the row it multiplies.
   procedure Resolve_Table
     (Item    : in out Model;
      Source  : Containers.Container;
      Name    : String;
      Rows    : Element_Count;
      Columns : Element_Count;
      Result  : out T.Real_Array_Access;
      Status  : out E.Error_Info;
      Turned  : Boolean := False)
   is
      Weight : T.View;
   begin
      Result := null;
      Resolve (Item, Source, Name, Rows, Columns, Weight, Status,
               Reaches => False);
      if E.Is_Error (Status) then
         return;
      end if;

      T.Allocate (Rows * Columns, Result);
      if Result = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      Mem.Record_Allocation
        (Item.Accounting, Mem.Converted_Weights,
         Interfaces.Unsigned_64 (Rows * Columns) * 4);
      Mem.Record_Conversion
        (Item.Accounting, Interfaces.Unsigned_64 (Rows * Columns) * 4);

      declare
         Line : Real_Array (0 .. Columns - 1);
      begin
         for Row in 0 .. Rows - 1 loop
            T.Dequantize_Row (Weight, Row, Line, Status);
            if E.Is_Error (Status) then
               E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
               return;
            end if;

            if Turned then
               for Column in 0 .. Columns - 1 loop
                  Result.all (Column * Rows + Row) := Line (Column);
               end loop;
            else
               Result.all (Row * Columns .. (Row + 1) * Columns - 1) := Line;
            end if;
         end loop;
      end;
   end Resolve_Table;

   procedure Resolve_Norm_Part
     (Item   : in out Model;
      Source : Containers.Container;
      Name   : String;
      Whole  : Element_Count;
      First  : Element_Count;
      Count  : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Entire : T.Real_Array_Access;
   begin
      Result := null;
      Resolve_Norm (Item, Source, Name, Whole, Entire, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      T.Allocate (Count, Result);
      if Result = null then
         T.Free (Entire);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      Result.all := Entire.all (First .. First + Count - 1);
      T.Free (Entire);
   end Resolve_Norm_Part;

   --  Resolve a layer's router and the stack of expert matrices behind it.
   --
   --  A file writes the experts of one layer as a single tensor with the
   --  expert axis outermost, so one expert's rows are contiguous and a view
   --  over them is arithmetic on an offset rather than a copy. That is the
   --  whole reason this is cheap: a mixture model holds no more bytes than
   --  the file does, and no expert is materialized until a position routes
   --  to it.
   procedure Resolve_Experts
     (Item    : in out Model;
      Source  : Containers.Container;
      Index   : Natural;
      Current : in out Layer;
      Status  : out E.Error_Info;
      Repack  : Repack_Mode := No_Repack)
   is
      Width : constant Element_Count :=
        Element_Count (Item.Settings.Embedding);
      Feed  : constant Element_Count :=
        Element_Count (Item.Settings.Expert_Feed);
      Count : constant Element_Count :=
        Element_Count (Item.Settings.Experts);

      --  One expert's rows out of the stack.
      procedure Slice
        (Whole  : T.View;
         Which  : Element_Count;
         Rows   : Element_Count;
         Result : out T.View;
         Status : out E.Error_Info) is
      begin
         T.Make
           (Format  => Whole.Format,
            Rows    => Rows,
            Columns => Whole.Columns,
            Base    => Whole.Base,
            Span    => Whole.Span,
            Offset  =>
              Whole.Offset
              + B.Byte_Count (Which) * B.Byte_Count (Rows)
                * T.Row_Bytes (Whole),
            Result  => Result,
            Status  => Status);
      end Slice;

      Gates, Ups, Downs : T.View;

   begin
      Resolve
        (Item, Source, Layer_Key (Index, "ffn_gate_inp.weight"),
         Count, Width, Current.Router, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_gate_exps.weight"),
         Feed * Count, Width, Gates, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_up_exps.weight"),
         Feed * Count, Width, Ups, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      Resolve
        (Item, Source, Layer_Key (Index, "ffn_down_exps.weight"),
         Width * Count, Feed, Downs, Status, Repack);
      if E.Is_Error (Status) then
         return;
      end if;

      --  And the biases, which this architecture is the first mixture here
      --  to carry: one a router and one for each of an expert's three
      --  projections, laid out as the weights are -- every expert's in one
      --  tensor, taken apart below.
      if Item.Settings.Kind = GPT_OSS then
         Resolve_Norm
           (Item, Source, Layer_Key (Index, "ffn_gate_inp.bias"),
            Element_Count (Item.Settings.Experts), Current.Router_Bias,
            Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Resolve_Norm
           (Item, Source, Layer_Key (Index, "ffn_gate_exps.bias"),
            Feed * Count, Current.Expert_Gate_Bias, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Resolve_Norm
           (Item, Source, Layer_Key (Index, "ffn_up_exps.bias"),
            Feed * Count, Current.Expert_Up_Bias, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Resolve_Norm
           (Item, Source, Layer_Key (Index, "ffn_down_exps.bias"),
            Width * Count, Current.Expert_Down_Bias, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      Current.Experts := new Expert_Array (0 .. Item.Settings.Experts - 1);
      Current.Gate_Stack := Gates;
      Current.Up_Stack := Ups;
      Current.Down_Stack := Downs;

      for Which in Current.Experts.all'Range loop
         Slice
           (Gates, Element_Count (Which), Feed,
            Current.Experts.all (Which).Gate, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Slice
           (Ups, Element_Count (Which), Feed,
            Current.Experts.all (Which).Up, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Slice
           (Downs, Element_Count (Which), Width,
            Current.Experts.all (Which).Down, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end loop;
   end Resolve_Experts;

   ---------------------
   -- Release_Weights --
   ---------------------

   procedure Release_Weights (Item : in out Model) is
   begin
      --  The device is told before the bytes go, never after.
      --
      --  It remembers a matrix by where its bytes lie, so an address it
      --  holds and this program has freed is an address the next matrix can
      --  be given -- and the device would answer for that one with these
      --  weights. This is the only place the weights are freed, so that it
      --  is the only place that has to remember to say so: there were two,
      --  and the second was found by listing what the first one's fix did
      --  not cover rather than by anything failing.
      --
      --  Said whenever this model holds weights, since a model cannot know
      --  whether the device holds its addresses. But not by one that holds
      --  none: the device forgets every matrix, not only this model's, and
      --  preparing a draft begins by closing it -- which emptied the
      --  device of the model it drafts for, eleven gigabytes that then
      --  came back one matrix a product (34.8 tokens a second to 2.9).
      if Item.Weights_Held
        or else Item.Weights_Span /= 0
        or else Item.Arena /= null
      then
         Model_Runner.Backend.Device.Forget_Matrices;
      end if;
      --  Only what was allocated is released. A borrowed span belongs to the
      --  source that gave it and is unmapped when that source closes.
      B.Free (Item.Arena);
      Item.Arena_Base := 0;
      Item.Weights_Base := System.Null_Address;
      Item.Weights_Span := 0;
      Item.Weights_Held := False;
   end Release_Weights;

   --  The feed-forward gate this architecture was trained with.
   --
   --  Gemma's is a Gaussian error unit; everything else here is a logistic
   --  one. The two are close enough that reading a Gemma file with SiLU
   --  produces fluent wrong text rather than anything that looks broken,
   --  which is why this is decided from the architecture rather than left
   --  to a default.
   --  Which unit a gated block puts on its gate arm, as a number a device
   --  can be given. Beside Gate_Activation rather than anywhere else, so the
   --  two cannot come to disagree about which architecture takes which.
   --
   --  @param Item Model whose architecture decides.
   --  @return Zero for the sigmoid-weighted unit, one for the Gaussian one.
   function Gate_Unit (Item : Model'Class) return Natural
   is (if Item.Settings.Gate_Alpha > 0.0 then 3
       elsif Item.Settings.Kind
             in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
                | Jina_Bert_V2 | Starcoder2 | Gptneox | Mpt
       then 1 else 0);

   procedure Gate_Activation (Item : Model'Class; Target : in out Real_Array)
   is
   begin
      if Item.Settings.Kind
         in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
            | Jina_Bert_V2 | Starcoder2 | Gptneox | Mpt
      then
         K.GELU (Target);
      else
         K.SiLU (Target);
      end if;
   end Gate_Activation;

   --  The base a layer turns its rotation on.
   --
   --  One base for the whole model everywhere but Gemma3, which turns the
   --  windowed layers on a base of their own -- a small one for a layer that
   --  looks a few positions back and the model's own for the layer that sees
   --  everything. Asked per layer rather than carried in the plan, because
   --  the alternative is a field that can disagree with the window it is
   --  supposed to follow.
   function Turn_Base
     (Settings : Configuration; Layer : Natural) return N.Wide_Real
   is (if Settings.Local_Base > 0.0
         and then Settings.Window_Every > 0
         and then Layer mod Settings.Window_Every /= Settings.Window_Every - 1
       then Settings.Local_Base
       else Settings.Rope_Base);

   --  The stretch a layer turns its rotation with.
   --
   --  The model's own everywhere but on Gemma3's windowed layers, which
   --  turn unstretched: the factor a Gemma 3 file states -- eight, on the
   --  4B and up -- is for the layers that see the whole context, and a
   --  layer that looks a thousand positions back was trained on positions
   --  as they are. The reference runtime keeps a separate scale for the
   --  windowed layers and sets it to one for this family. Applied to every
   --  layer, the factor put the 4B's windowed layers at an eighth of their
   --  positions: a six-token prompt answered, a four-hundred-token one
   --  came apart into a word repeated. GPT-OSS, the other family here that
   --  windows on a base of its own, stretches its windowed layers as the
   --  rest, which the reference does too.
   function Turn_Scaling
     (Settings : Configuration; Layer : Natural) return K.Rotary_Scaling
   is (if Settings.Kind = Gemma3
         and then Settings.Window_Every > 0
         and then Layer mod Settings.Window_Every /= Settings.Window_Every - 1
       then K.Rotary_Scaling'(others => <>)
       else Settings.Scaling);

   --  A score held under a bound, as the architecture that states one puts
   --  it: cap times the hyperbolic tangent of the score over the cap. Small
   --  scores come back nearly unchanged and large ones stop just under the
   --  cap, which is what keeps one key from taking the whole of a softmax.
   --
   --  A cap of zero is no cap, which is every architecture here but Gemma2.
   function Capped (Score : Real; Cap : Real) return Real
   is (if Cap <= 0.0 then Score
       else Real (N.Wide_Real (Cap)
                  * N.Tanh (N.Wide_Real (Score) / N.Wide_Real (Cap))));

   --  The logits held under the bound the architecture states, if it states
   --  one. Applied to what the caller is about to be given rather than to
   --  the row the engine keeps, because it is part of the model's answer
   --  and not part of its bookkeeping.
   procedure Cap_Logits (Settings : Configuration; Values : in out Real_Array)
   is
   begin
      if Settings.Logit_Cap <= 0.0 then
         return;
      end if;

      K.Soft_Cap (Values, Settings.Logit_Cap);
   end Cap_Logits;

   --  The last two things done to a row of logits: the bias the output
   --  projection carries, and the bound the architecture puts on what it
   --  produced. Written once and called from each of the three places that
   --  produce logits -- a token at a time, every position of a batch, and
   --  the last position of one -- because the alternative is three copies
   --  and a fourth place that forgets one of them. That is not a
   --  hypothetical either: an architecture whose feed-forward result was
   --  discarded, and a batched path normalized one way where the rest of the
   --  program normalized another, were both a step written beside a branch
   --  rather than after it.
   procedure Finish_Logits
     (Source : Model'Class;
      Values : in out Real_Array) is
   begin
      if Source.Output_Bias /= null
        and then Source.Output_Bias.all'Length = Values'Length
      then
         K.Add (Values, Source.Output_Bias.all);
      end if;

      --  Granite divides its logits by a scalar the file carries, before
      --  any bound the architecture states. It states none, so the order is
      --  moot here, but the division is the last thing the model does.
      if Source.Settings.Kind in Granite | Granite_MoE
        and then Source.Settings.Logit_Mul /= 0.0
      then
         K.Scale (Values, 1.0 / Source.Settings.Logit_Mul);
      end if;

      --  Command-R multiplies by its scale where Granite divides by its.
      if Source.Settings.Kind = Command_R
        and then Source.Settings.Logit_Scale /= 0.0
      then
         K.Scale (Values, Source.Settings.Logit_Scale);
      end if;

      Cap_Logits (Source.Settings, Values);
   end Finish_Logits;

   --  Every normalization here multiplies by the gain as the file stores
   --  it. Gemma trains its gains around zero and adds one at the point of
   --  use -- but the converter that writes a Gemma file adds that one to
   --  every norm weight as it writes, so a GGUF gain is already one plus
   --  the trained weight, and a runtime that lifts it again normalizes to
   --  two plus the weight. This engine did, for the whole family: every
   --  Gemma answered in fluent nonsense, and the fixtures and the reference
   --  agreed with it because they shared the belief. The kernels had an
   --  option to lift, and it is gone: nothing in a GGUF asks for it.

   -------------
   -- Account --
   -------------

   procedure Account (Item : in out Session; Wanted : Boolean) is
   begin
      Item.Spent := [others => 0.0];
      Item.Budgeting := Wanted;
   end Account;

   ----------------
   -- Time_Spent --
   ----------------

   function Time_Spent (Item : Session) return Phase_Times is (Item.Spent);

   -------------
   -- Sharing --
   -------------

   function Sharing (Item : Session) return Model_Runner.Shares.Team_Access
   is (Workers_CPU.Sharing (Item.Team));

   --  Charge what has passed since Mark to a phase, and move Mark to now.
   --
   --  Reading the clock is the whole cost of a budget, so it is read once
   --  here and serves as both the end of one phase and the start of the
   --  next: a pair of reads at every boundary would double what the
   --  instrument costs and would also leave the gap between them charged to
   --  nobody.
   procedure Charge
     (Item : in out Session;
      To   : Phase;
      Mark : in out Ada.Real_Time.Time);

   procedure Charge
     (Item : in out Session;
      To   : Phase;
      Mark : in out Ada.Real_Time.Time)
   is
      use type Ada.Real_Time.Time;
      Now : Ada.Real_Time.Time;
   begin
      if not Item.Budgeting then
         return;
      end if;

      Now := Ada.Real_Time.Clock;
      Item.Spent (To) := Item.Spent (To) + Ada.Real_Time.To_Duration (Now - Mark);
      Mark := Now;
   end Charge;

   --  A turning table for an architecture that turns nothing, for the
   --  device's whole layer.
   No_Turns : constant N.Wide_Real_Array (1 .. 0) := [others => 0.0];

   --  Whether a normalization with this shift is the centred one: the
   --  architectures whose normalization centres, and a shift the file
   --  carries. Asked by Normalize and by the pairing for the device, so
   --  that the two cannot disagree.
   --  MPT centres too, but carries no shift: it is a centred normalization
   --  without a bias, the one architecture here that separates the two. So
   --  the test is the kind and the bias together for every other centred
   --  one, and the kind alone for MPT, whose bias is null by design rather
   --  than by absence.
   function Centres
     (Item : Model'Class; Bias : T.Real_Array_Access) return Boolean
   is (Item.Settings.Kind in Mpt | Command_R
       or else (Item.Settings.Kind
                  in Falcon | Phi2 | GPT2 | Bert | Nomic_Bert | Jina_Bert_V2
                     | Starcoder2 | Stablelm | Gptneox | Rwkv6
                and then Bias /= null));

   --  Normalize the way the architecture does, into Target.
   --
   --  Falcon, Phi2, GPT2 and Bert centre and carry a bias; MPT centres and
   --  carries none, so where it centres the shift is zero; everything else
   --  divides by the root mean square and does not. One procedure rather
   --  than a test at each of the nine places a normalization happens,
   --  because nine tests are nine chances to write one of them the other
   --  way round.
   procedure Normalize
     (Item   : Model'Class;
      Source : Real_Array;
      Gain   : Real_Array;
      Bias   : T.Real_Array_Access;
      Target : out Real_Array) is
   begin
      if Centres (Item, Bias) then
         if Bias /= null then
            K.Layer_Norm
              (Source, Gain, Bias.all, Item.Settings.Epsilon, Target);
         else
            declare
               No_Shift : constant Real_Array (Gain'Range) := [others => 0.0];
            begin
               K.Layer_Norm
                 (Source, Gain, No_Shift, Item.Settings.Epsilon, Target);
            end;
         end if;
      else
         K.RMS_Norm (Source, Gain, Item.Settings.Epsilon, Target);
      end if;
   end Normalize;

   --  MPT clamps its queries, keys and values to a magnitude the file
   --  states, before it attends. Applied to the three rows once the
   --  projection has produced them, which is the same as clamping the fused
   --  projection before it is split, because the clamp is elementwise and
   --  MPT carries no bias between the two. A limit of zero -- every other
   --  architecture, and an MPT file that states none -- is no clamp.
   procedure Clip_QKV
     (Limit : N.Real; Query, Key, Value : in out Real_Array)
   is
      procedure Clip (Row : in out Real_Array) is
      begin
         for Value of Row loop
            if Value > Limit then
               Value := Limit;
            elsif Value < -Limit then
               Value := -Limit;
            end if;
         end loop;
      end Clip;
   begin
      if Limit > 0.0 then
         Clip (Query);
         Clip (Key);
         Clip (Value);
      end if;
   end Clip_QKV;

   --  Where each of an RWKV6 block's small tables lies in its pack, in
   --  elements, the model's width W and the two low ranks given: the two
   --  normalizations' gains and shifts, the plain shift's mix, the five
   --  streams' mixes and their map up, the decay's bias and map up, the
   --  bonus, the answer's normalization, and the channel mix's two mixes.
   type Rwkv_Places is record
      First_Norm, Second_Norm, Plain_Mix, Stream_Mix, Stream_Map,
      Decay_Bias, Decay_Map, Bonus, Out_Norm, Channel_Mix, Total :
        Element_Count := 0;
   end record;

   function Rwkv_Places_Of (Settings : Configuration) return Rwkv_Places is
      W     : constant Element_Count := Element_Count (Settings.Embedding);
      D_TM  : constant Element_Count := Element_Count (Settings.Mix_Extra);
      D_Dec : constant Element_Count := Element_Count (Settings.Decay_Extra);
      R     : Rwkv_Places;
   begin
      R.First_Norm  := 0;
      R.Second_Norm := 2 * W;
      R.Plain_Mix   := 4 * W;
      R.Stream_Mix  := 5 * W;
      R.Stream_Map  := 10 * W;
      R.Decay_Bias  := R.Stream_Map + 5 * W * D_TM;
      R.Decay_Map   := R.Decay_Bias + W;
      R.Bonus       := R.Decay_Map + W * D_Dec;
      R.Out_Norm    := R.Bonus + W;
      R.Channel_Mix := R.Out_Norm + 2 * W;
      R.Total       := R.Channel_Mix + 2 * W;
      return R;
   end Rwkv_Places_Of;

   --  Where each of a Mamba2 mixer's small tables lies in its pack, in
   --  elements: the taps a channel, their biases, dt's bias, A, D, and the
   --  normalization's gain.
   type Mamba2_Places is record
      Conv, Bias, Dt, A, D, Gain, Total : Element_Count := 0;
   end record;

   function Mamba2_Places_Of (Settings : Configuration) return Mamba2_Places
   is
      Inner : constant Element_Count := Element_Count (Settings.Inner_Size);
      Heads : constant Element_Count := Element_Count (Settings.Ssm_Heads);
      State : constant Element_Count := Element_Count (Settings.State_Size);
      DXBC  : constant Element_Count :=
        Inner + 2 * Element_Count (Settings.Groups) * State;
      R     : Mamba2_Places;
   begin
      --  Mamba's: the taps over x alone, and dt's bias, A and D a channel
      --  -- A a channel and a state -- with no gain; Jamba's then the gains
      --  of its x-projection's three normalizations, dt's rank, B and C.
      if not Is_Mamba2 (Settings.Kind) then
         R.Conv  := 0;
         R.Bias  := Inner * Element_Count (Settings.Conv_Kernel);
         R.Dt    := R.Bias + Inner;
         R.A     := R.Dt + Inner;
         R.D     := R.A + Inner * State;
         R.Gain  := R.D + Inner;
         R.Total := R.Gain
           + (if Is_Jamba (Settings.Kind)
              then Element_Count (Settings.Time_Rank) + 2 * State
              else 0);
         return R;
      end if;

      R.Conv  := 0;
      R.Bias  := DXBC * Element_Count (Settings.Conv_Kernel);
      R.Dt    := R.Bias + DXBC;
      R.A     := R.Dt + Heads;
      R.D     := R.A + Heads;
      R.Gain  := R.D + Heads;
      R.Total := R.Gain + Inner;
      return R;
   end Mamba2_Places_Of;

   --  The gain and the shift of each of a layer's centred normalizations
   --  laid end to end, for the device, which takes the two as one
   --  resident weight of twice the width. Built once, here, because the
   --  device keeps a weight by its address and the address has to stay:
   --  a pair made at the call would be resident once a call.
   procedure Pair_Norms (Item : Model'Class; Current : in out Layer) is
      procedure Pair
        (Gain, Bias : T.Real_Array_Access;
         Into       : in out T.Real_Array_Access) is
      begin
         if Gain = null
           or else Bias = null
           or else not Centres (Item, Bias)
           or else Gain.all'Length /= Bias.all'Length
         then
            return;
         end if;

         T.Allocate (2 * Gain.all'Length, Into);
         if Into = null then
            return;
         end if;

         Into.all (Into.all'First .. Into.all'First + Gain.all'Length - 1) :=
           Gain.all;
         Into.all (Into.all'First + Gain.all'Length .. Into.all'Last) :=
           Bias.all;
      end Pair;
   begin
      Pair (Current.Attention_Norm, Current.Attention_Norm_Bias,
            Current.Attention_Norm_Pair);
      Pair (Current.Feed_Norm, Current.Feed_Norm_Bias,
            Current.Feed_Norm_Pair);
      Pair (Current.Post_Attention_Norm, Current.Post_Attention_Norm_Bias,
            Current.Post_Attention_Norm_Pair);
      Pair (Current.Post_Feed_Norm, Current.Post_Feed_Norm_Bias,
            Current.Post_Feed_Norm_Pair);

      --  And a linear layer's three rows of numbers as one, for the
      --  device's rule step.
      if Current.A_Log /= null and then Current.DT_Bias /= null
        and then Current.State_Norm /= null
        and then Current.A_Log.all'Length = Current.DT_Bias.all'Length
      then
         declare
            Heads : constant Element_Count := Current.A_Log.all'Length;
            Wide  : constant Element_Count := Current.State_Norm.all'Length;
         begin
            T.Allocate (2 * Heads + Wide, Current.Linear_Numbers);
            if Current.Linear_Numbers /= null then
               Current.Linear_Numbers.all (0 .. Heads - 1) :=
                 Current.A_Log.all;
               Current.Linear_Numbers.all (Heads .. 2 * Heads - 1) :=
                 Current.DT_Bias.all;
               Current.Linear_Numbers.all (2 * Heads .. 2 * Heads + Wide - 1) :=
                 Current.State_Norm.all;
            end if;
         end;
      end if;

      --  And an RWKV6 block's small tables as one, for the device's
      --  sequence: every one of them present and of the length its place
      --  says, or no pack and the block goes a step at a time.
      if Is_RWKV (Item.Settings.Kind)
        and then Current.Attention_Norm /= null
        and then Current.Attention_Norm_Bias /= null
        and then Current.Second_Attention_Norm /= null
        and then Current.Second_Attention_Norm_Bias /= null
        and then Current.Rwkv_Lerp_X /= null
        and then Current.Rwkv_Lerp_Fused /= null
        and then Current.Rwkv_TM_W2 /= null
        and then Current.Rwkv_Decay /= null
        and then Current.Rwkv_Decay_W2 /= null
        and then Current.Rwkv_First /= null
        and then Current.Rwkv_TM_LN /= null
        and then Current.Rwkv_TM_LN_Bias /= null
        and then Current.Rwkv_CM_Lerp_K /= null
        and then Current.Rwkv_CM_Lerp_R /= null
      then
         declare
            P : constant Rwkv_Places := Rwkv_Places_Of (Item.Settings);
            W : constant Element_Count :=
              Element_Count (Item.Settings.Embedding);

            procedure Put (At_Element : Element_Count; From : T.Real_Array_Access)
            is
            begin
               Current.Rwkv_Pack.all
                 (At_Element .. At_Element + From.all'Length - 1) := From.all;
            end Put;
         begin
            if Current.Rwkv_Lerp_Fused.all'Length = 5 * W
              and then Current.Rwkv_TM_W2.all'Length
                       = P.Decay_Bias - P.Stream_Map
              and then Current.Rwkv_Decay_W2.all'Length
                       = P.Bonus - P.Decay_Map
              and then Current.Rwkv_First.all'Length = W
            then
               T.Allocate (P.Total, Current.Rwkv_Pack);
               if Current.Rwkv_Pack /= null then
                  Put (P.First_Norm, Current.Attention_Norm);
                  Put (P.First_Norm + W, Current.Attention_Norm_Bias);
                  Put (P.Second_Norm, Current.Second_Attention_Norm);
                  Put (P.Second_Norm + W, Current.Second_Attention_Norm_Bias);
                  Put (P.Plain_Mix, Current.Rwkv_Lerp_X);
                  Put (P.Stream_Mix, Current.Rwkv_Lerp_Fused);
                  Put (P.Stream_Map, Current.Rwkv_TM_W2);
                  Put (P.Decay_Bias, Current.Rwkv_Decay);
                  Put (P.Decay_Map, Current.Rwkv_Decay_W2);
                  Put (P.Bonus, Current.Rwkv_First);
                  Put (P.Out_Norm, Current.Rwkv_TM_LN);
                  Put (P.Out_Norm + W, Current.Rwkv_TM_LN_Bias);
                  Put (P.Channel_Mix, Current.Rwkv_CM_Lerp_K);
                  Put (P.Channel_Mix + W, Current.Rwkv_CM_Lerp_R);
               end if;
            end if;
         end;
      end if;

      --  And a Mamba or Mamba2 mixer's, every table present at the length
      --  its place says, or no pack and the mixer goes a step at a time.
      if (Pure_SSM (Item.Settings.Kind)
          or else (Is_Jamba (Item.Settings.Kind)
                   and then Current.Ssm_Dt_Norm /= null
                   and then Current.Ssm_B_Norm /= null
                   and then Current.Ssm_C_Norm /= null))
        and then Current.Conv /= null and then Current.Conv_Bias /= null
        and then Current.DT_Bias /= null and then Current.Ssm_A /= null
        and then Current.Ssm_D /= null
        and then (Current.State_Norm /= null
                  or else not Is_Mamba2 (Item.Settings.Kind))
      then
         declare
            P : constant Mamba2_Places := Mamba2_Places_Of (Item.Settings);

            procedure Put (At_Element : Element_Count;
                           From : T.Real_Array_Access) is
            begin
               Current.Ssm_Pack.all
                 (At_Element .. At_Element + From.all'Length - 1) := From.all;
            end Put;
         begin
            if Current.Conv.all'Length = P.Bias - P.Conv
              and then Current.Conv_Bias.all'Length = P.Dt - P.Bias
              and then Current.DT_Bias.all'Length = P.A - P.Dt
              and then Current.Ssm_A.all'Length = P.D - P.A
              and then Current.Ssm_D.all'Length = P.Gain - P.D
              and then (if Is_Mamba2 (Item.Settings.Kind)
                        then Current.State_Norm.all'Length = P.Total - P.Gain
                        elsif Is_Jamba (Item.Settings.Kind)
                        then Current.Ssm_Dt_Norm.all'Length
                             + Current.Ssm_B_Norm.all'Length
                             + Current.Ssm_C_Norm.all'Length
                             = P.Total - P.Gain
                        else P.Total = P.Gain)
            then
               T.Allocate (P.Total, Current.Ssm_Pack);
               if Current.Ssm_Pack /= null then
                  Put (P.Conv, Current.Conv);
                  Put (P.Bias, Current.Conv_Bias);
                  Put (P.Dt, Current.DT_Bias);
                  Put (P.A, Current.Ssm_A);
                  Put (P.D, Current.Ssm_D);
                  if Is_Mamba2 (Item.Settings.Kind) then
                     Put (P.Gain, Current.State_Norm);
                  elsif Is_Jamba (Item.Settings.Kind) then
                     Put (P.Gain, Current.Ssm_Dt_Norm);
                     Put (P.Gain + Current.Ssm_Dt_Norm.all'Length,
                          Current.Ssm_B_Norm);
                     Put (P.Gain + Current.Ssm_Dt_Norm.all'Length
                          + Current.Ssm_B_Norm.all'Length,
                          Current.Ssm_C_Norm);
                  end if;
               end if;
            end if;
         end;
      end if;
   end Pair_Norms;

   --  Whether a layer's normalizations go to the device centred: every
   --  one the layer has is paired above. All or none: the device's
   --  sequence centres a layer's normalizations together, and a layer
   --  with one centred and one not -- a GPT-2 file without its
   --  feed-forward shift is the one that would be -- goes a step at a
   --  time.
   function Norms_Shifted (L : Layer) return Boolean
   is (L.Attention_Norm_Pair /= null
       or else L.Post_Attention_Norm_Pair /= null);

   function Norms_Agree (L : Layer) return Boolean
   is ((L.Attention_Norm = null
        or else (L.Attention_Norm_Pair /= null) = Norms_Shifted (L))
       and then (L.Feed_Norm = null
                 or else (L.Feed_Norm_Pair /= null) = Norms_Shifted (L))
       and then (L.Post_Attention_Norm = null
                 or else (L.Post_Attention_Norm_Pair /= null)
                         = Norms_Shifted (L))
       and then (L.Post_Feed_Norm = null
                 or else (L.Post_Feed_Norm_Pair /= null)
                         = Norms_Shifted (L)));

   --  A normalization's weight as the device takes it: the pair where
   --  the layer's are centred, the gain where not, and null where the
   --  layer has not got one. By reference, because the device keeps a
   --  weight by its address.
   function Device_Norm
     (Gain, Pair : T.Real_Array_Access) return T.Real_Array_Access
   is (if Pair /= null then Pair else Gain);

   --  The state a position is left with: what the last layer produced,
   --  through the model's final normalization where it has one.
   --
   --  Bert has not got one, and that is not an omission in the file. Its
   --  layers normalize on the way out of each sublayer rather than on the
   --  way in, so the last thing the last layer did was normalize what it
   --  produced, and a second normalization here would be one the model was
   --  never trained with. What "nothing" has to be is a copy, because every
   --  caller of this writes somewhere other than where it read.
   procedure Final_State
     (Item   : Model'Class;
      Source : Real_Array;
      Target : out Real_Array) is
   begin
      if Item.Output_Norm = null then
         Target := Source;
      else
         Normalize
           (Item, Source, Item.Output_Norm.all, Item.Output_Norm_Bias,
            Target);
      end if;
   end Final_State;

   --  Normalize what a sublayer produced, where the architecture says so.
   --
   --  Gemma2 normalizes on the way out of each sublayer as well as on the
   --  way in; every other architecture here does nothing between the
   --  sublayer and the residual add. Given the layer's gain, which is null
   --  for those, so this is a call that costs a test rather than four call
   --  sites that each have to remember.
   procedure Post_Norm
     (Item   : Model'Class;
      Gain   : T.Real_Array_Access;
      Target : in out Real_Array;

      --  The scratch as a reference rather than as an array, because it is
      --  allocated only for the architecture that needs it: passing
      --  Room.all at a call site would dereference a null buffer for every
      --  architecture that does not, before this procedure could decide it
      --  had nothing to do. It did, and every model in the sweep failed as
      --  an invariant violation.
      Room   : T.Real_Array_Access) is
   begin
      if Gain = null or else Room = null then
         return;
      end if;

      K.RMS_Norm (Target, Gain.all, Item.Settings.Epsilon, Room.all);
      Target := Room.all;
   end Post_Norm;

   --  Add what a sublayer produced to the residual, normalizing on whichever
   --  side of the add the architecture normalizes.
   --
   --  Two arrangements meet here. Gemma2 normalizes what the sublayer
   --  produced and adds that to the residual; Bert adds it and then
   --  normalizes the sum. The same two tensors, read in the same two places,
   --  computing different models -- and the only thing that distinguishes
   --  them is which side of the add falls under the normalization.
   --
   --  Written once for that reason. A sublayer joins a residual at four
   --  places in this file, and a difference this quiet, repeated four times,
   --  is a difference three of them would eventually stop having.
   procedure Join_Residual
     (Item     : Model'Class;
      Produced : in out Real_Array;
      Residual : in out Real_Array;
      Gain     : T.Real_Array_Access;
      Bias     : T.Real_Array_Access;
      Room     : T.Real_Array_Access) is
   begin
      if not Normalizes_After (Item.Settings.Kind) then
         Post_Norm (Item, Gain, Produced, Room);
         if Item.Settings.Kind in Granite | Granite_MoE
           and then Item.Settings.Residual_Mul /= 0.0
         then
            K.Scale (Produced, Item.Settings.Residual_Mul);
         end if;
         K.Add (Residual, Produced);
         return;
      end if;

      K.Add (Residual, Produced);

      if Gain /= null and then Room /= null then
         Normalize (Item, Residual, Gain.all, Bias, Room.all);
         Residual := Room.all;
      end if;
   end Join_Residual;

   --  Normalize a projection over the whole of its width, in place, as the
   --  code variant of jina-bert-v2 does its queries and its keys: a centred
   --  normalization with a gain and a shift, over the projection rather
   --  than a head of it. The room is the projection's own width, taken
   --  here: the keys' is not the layer's where the key heads are fewer,
   --  and a scratch of the layer width would be the wrong length for them.
   --  Nothing is done where the gain is null.
   procedure Normalize_Whole
     (Item   : Model'Class;
      Vector : in out Real_Array;
      Gain   : T.Real_Array_Access;
      Bias   : T.Real_Array_Access)
   is
      Room : Real_Array (Vector'Range);
   begin
      if Gain = null then
         return;
      end if;

      Normalize (Item, Vector, Gain.all, Bias, Room);
      Vector := Room;
   end Normalize_Whole;

   --  The code variant's third normalization of the attention sublayer:
   --  the layer's input is added once more to the residual as the first
   --  join normalized it, and the sum is normalized again by a gain and a
   --  shift of its own. Input is the layer's input as it stood before the
   --  first join, which the caller kept.
   procedure Join_Again
     (Item     : Model'Class;
      Residual : in out Real_Array;
      Input    : Real_Array;
      Current  : Layer;
      Room     : T.Real_Array_Access) is
   begin
      if Current.Second_Attention_Norm = null or else Room = null then
         return;
      end if;

      K.Add (Residual, Input);
      Normalize
        (Item, Residual, Current.Second_Attention_Norm.all,
         Current.Second_Attention_Norm_Bias, Room.all);
      Residual := Room.all;
   end Join_Again;

   --  What the embedding row is multiplied by before the first layer.
   --
   --  One everywhere but Gemma, which scales by the square root of the
   --  embedding width -- about forty on a model of a useful size, so a file
   --  read without it produces text rather than a refusal, and the text is
   --  wrong. Computed here rather than stored, because it is one square root
   --  per token and the alternative is a field that can disagree with the
   --  architecture that decides it.
   function Embedding_Scale (Item : Model'Class) return Real
   is (if Item.Settings.Kind in Gemma | Gemma2 | Gemma3
       then Real (N.Sqrt (N.Wide_Real (Item.Settings.Embedding)))
       elsif Item.Settings.Kind in Granite | Granite_MoE
             and then Item.Settings.Embedding_Mul /= 0.0
       then Item.Settings.Embedding_Mul
       else 1.0);

   --  Rows of the output head a draft from the block past the stack reads.
   --  See Draft_Next.
   Draft_Vocabulary : constant := 65_536;

   --  The first Rows rows of Head written again as the legacy four-bit
   --  kind, into Room: decoded a row at a time and encoded a block at a
   --  time the way the reference encoder writes one -- the scale is the
   --  value of largest magnitude over minus eight, with its sign, and each
   --  weight the nearest of sixteen steps of it, the first sixteen in the
   --  low nibbles and the last in the high. Room is null where Head's
   --  width is not whole blocks or its format is already four bits or
   --  fewer, and on any failure.
   procedure Encode_Four_Bits
     (Accounting : in out Model_Runner.Memory.Account;
      Head       : T.View;
      Rows       : Element_Count;
      Threads    : Positive;
      Room       : out B.Byte_Array_Access;
      Status     : out E.Error_Info)
   is
      use type Model_Runner.GGUF.Tensor_Type;
      use type Interfaces.Unsigned_16;

      --  The legacy four-bit block: a binary16 scale and thirty-two
      --  nibbles, eighteen bytes.
      Block_Width : constant := 32;
      Block_Bytes : constant := 18;

      Blocks : constant Element_Count := Head.Columns / Block_Width;
      Row_Bytes : constant B.Byte_Count := B.Byte_Count (Blocks) * Block_Bytes;
      Needed : constant B.Byte_Count := Row_Bytes * B.Byte_Count (Rows);
   begin
      Status := E.Success;
      Room := null;

      if Rows = 0
        or else Rows > Head.Rows
        or else Head.Columns mod Block_Width /= 0
        or else Head.Format not in Model_Runner.GGUF.Type_F32
                                 | Model_Runner.GGUF.Type_F16
                                 | Model_Runner.GGUF.Type_BF16
                                 | Model_Runner.GGUF.Type_Q8_0
                                 | Model_Runner.GGUF.Type_Q6_K
                                 | Model_Runner.GGUF.Type_Q5_K
                                 | Model_Runner.GGUF.Type_Q5_0
                                 | Model_Runner.GGUF.Type_Q5_1
      then
         return;
      end if;

      Mem.Check_Allocation
        (Accounting, Mem.Converted_Weights,
         Interfaces.Unsigned_64 (Needed), Status);
      if E.Is_Error (Status) then
         return;
      end if;

      B.Allocate (Needed, Room);
      if Room = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Mem.Record_Allocation
        (Accounting, Mem.Converted_Weights, Interfaces.Unsigned_64 (Needed));

      declare
         Target : B.Byte_Array renames Room.all;

         protected Trouble is
            procedure Note (Reason : E.Error_Info);
            function Reason return E.Error_Info;
         private
            Bad : E.Error_Info := E.Success;
         end Trouble;

         protected body Trouble is
            procedure Note (Reason : E.Error_Info) is
            begin
               if E.Is_Ok (Bad) then
                  Bad := Reason;
               end if;
            end Note;

            function Reason return E.Error_Info is (Bad);
         end Trouble;

         procedure Encode (First, Last : Element_Count) is
            Row    : N.Real_Array (0 .. Head.Columns - 1);
            Status : E.Error_Info;
         begin
            for Which in First .. Last loop
               T.Dequantize_Row (Head, Which, Row, Status);
               if E.Is_Error (Status) then
                  Trouble.Note (Status);
                  return;
               end if;

               for Block in 0 .. Blocks - 1 loop
                  declare
                     At_Byte : constant B.Byte_Count :=
                       Target'First + B.Byte_Count (Which) * Row_Bytes
                       + B.Byte_Count (Block) * Block_Bytes;
                     From    : constant Element_Count := Block * Block_Width;
                     Largest : Real := 0.0;
                     Signed  : Real := 0.0;
                  begin
                     for J in 0 .. Block_Width - 1 loop
                        if abs Row (From + Element_Count (J)) > Largest then
                           Largest := abs Row (From + Element_Count (J));
                           Signed := Row (From + Element_Count (J));
                        end if;
                     end loop;

                     declare
                        Scale   : constant Real := Signed / (-8.0);
                        Inverse : constant Real :=
                          (if Scale /= 0.0 then 1.0 / Scale else 0.0);
                        Bits    : constant Interfaces.Unsigned_16 :=
                          Interfaces.Unsigned_16 (N.To_Half (Scale));

                        function Step (Value : Real) return B.Byte is
                          (B.Byte
                             (Integer'Min
                                (15,
                                 Integer'Max
                                   (0,
                                    Integer
                                      (Real'Truncation
                                         (Value * Inverse + 8.5))))));
                     begin
                        Target (At_Byte) :=
                          B.Byte (Bits and 16#FF#);
                        Target (At_Byte + 1) :=
                          B.Byte (Interfaces.Shift_Right (Bits, 8));

                        for J in 0 .. 15 loop
                           Target (At_Byte + 2 + B.Byte_Count (J)) :=
                             Step (Row (From + Element_Count (J)))
                             or Interfaces.Shift_Left
                                  (Step (Row (From + Element_Count (J) + 16)),
                                   4);
                        end loop;
                     end;
                  end;
               end loop;
            end loop;
         end Encode;

         Workers : constant Positive :=
           Positive'Min (Threads, Positive'Max (1, Natural (Rows / 4096)));
         Share   : constant Element_Count :=
           (Rows + Element_Count (Workers) - 1) / Element_Count (Workers);

         task type Encoder is
            entry Start (First, Last : Element_Count);
         end Encoder;

         task body Encoder is
            From, To : Element_Count;
         begin
            accept Start (First, Last : Element_Count) do
               From := First;
               To := Last;
            end Start;
            Encode (From, To);
         exception
            when others =>
               Trouble.Note (E.Make (E.Internal_Invariant_Violated));
         end Encoder;
      begin
         declare
            Team : array (1 .. Workers) of Encoder;
         begin
            for Index in Team'Range loop
               declare
                  First : constant Element_Count :=
                    Element_Count (Index - 1) * Share;
               begin
                  Team (Index).Start
                    (First, Element_Count'Min (Rows - 1, First + Share - 1));
               end;
            end loop;
         end;

         Status := Trouble.Reason;
      end;

      if E.Is_Error (Status) then
         Mem.Record_Release
           (Accounting, Mem.Converted_Weights,
            Interfaces.Unsigned_64 (Needed));
         B.Free (Room);
      end if;
   end Encode_Four_Bits;

   --  A view over Room as the four-bit rows Encode_Four_Bits wrote, or
   --  the empty view where it wrote none.
   function Four_Bit_View
     (Room : B.Byte_Array_Access; Rows, Columns : Element_Count;
      Role : T.Weight_Role) return T.View
   is
      Fresh  : T.View;
      Status : E.Error_Info;
   begin
      if Room = null then
         return T.Empty_View;
      end if;

      T.Make
        (Format  => Model_Runner.GGUF.Type_Q4_0,
         Rows    => Rows,
         Columns => Columns,
         Data    => Room,
         Offset  => 0,
         Result  => Fresh,
         Status  => Status);
      if E.Is_Error (Status) then
         return T.Empty_View;
      end if;

      Fresh.Role := Role;
      return Fresh;
   end Four_Bit_View;

   ------------------
   -- Lighten_Head --
   ------------------

   procedure Lighten_Head
     (Item    : in out Model;
      Threads : Positive := 1;
      Status  : out E.Error_Info)
   is
      Head : constant T.View :=
        (if T.Is_Present (Item.Output_As_Stored) then Item.Output_As_Stored
         else Item.Output);
   begin
      Status := E.Success;
      if Item.Light_Head /= null then
         return;
      end if;

      Encode_Four_Bits
        (Item.Accounting, Head, Head.Rows, Threads, Item.Light_Head, Status);
      if Item.Light_Head /= null then
         Item.Output :=
           Four_Bit_View (Item.Light_Head, Head.Rows, Head.Columns, Head.Role);
      end if;
   end Lighten_Head;

   ------------------------
   -- Lighten_Draft_Head --
   ------------------------

   procedure Lighten_Draft_Head
     (Item    : in out Model;
      Threads : Positive := 1;
      Status  : out E.Error_Info)
   is
      Head : constant T.View :=
        (if T.Is_Present (Item.Output_As_Stored) then Item.Output_As_Stored
         else Item.Output);
      Rows : constant Element_Count :=
        Element_Count'Min (Head.Rows, Draft_Vocabulary);
   begin
      Status := E.Success;
      if Item.Draft_Head_Bytes /= null then
         return;
      end if;

      Encode_Four_Bits
        (Item.Accounting, Head, Rows, Threads, Item.Draft_Head_Bytes, Status);
      Item.Draft_Head :=
        Four_Bit_View (Item.Draft_Head_Bytes, Rows, Head.Columns, Head.Role);
   end Lighten_Draft_Head;

   -----------------
   -- Head_Format --
   -----------------

   function Head_Format
     (Item : Model) return Model_Runner.GGUF.Tensor_Type
   is (Item.Output.Format);

   -------------
   -- Prepare --
   -------------

   ------------------
   -- Use_Template --
   ------------------

   procedure Use_Template
     (Item   : in out Model;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits;
      Status : out Model_Runner.Errors.Error_Info;
      Name   : String := "") is
   begin
      Model_Runner.Templates.Close (Item.Chat);
      Model_Runner.Templates.Compile (Item.Chat, Source, Bounds, Status);
      Item.Chat_Present := E.Is_Ok (Status);
      Item.Chat_Status := Status;
      Set_Template_Format (Item, (if E.Is_Ok (Status) then Name else ""));
      Item.Chat_Stood_In := False;
   end Use_Template;

   -------------------------
   -- Set_Template_Format --
   -------------------------

   procedure Set_Template_Format (Item : in out Model; Name : String) is
      Used : constant Natural :=
        Natural'Min (Name'Length, Item.Chat_Format_Name'Length);
   begin
      Item.Chat_Format_Name (1 .. Used) :=
        Name (Name'First .. Name'First + Used - 1);
      Item.Chat_Format_Used := Used;
   end Set_Template_Format;

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
   is separate;

   -----------
   -- Close --
   -----------

   ----------------
   -- Accounting --
   ----------------

   function Accounting (Item : Model) return Mem.Account
   is (Item.Accounting);

   ----------------
   -- Capability --
   ----------------

   function Capability
     (Item : Model) return Model_Runner.Backend.Capabilities
   is (Item.Able);

   function Accounting (Item : Session) return Mem.Account
   is (Item.Accounting);

   --  The product, through whichever backend this session was opened for.
   --
   --  Every matrix product in the engine goes through these two, so the
   --  choice is made once rather than at sixteen call sites. The CPU backend
   --  takes the pool; the reference backend has none and does not want one.
   procedure Product
     (Item   : Session;
      Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info) is
   begin
      --  What this product was given, where anything asked to be told.
      if Item.Seen /= null then
         declare
            Which : constant String := Named_As (Item.Owner.all, Weight);
         begin
            if Which /= "" then
               Item.Seen.Note (Which, Vector.all, 1);
            end if;
         end;
      end if;

      case (if Item.Host_Feed then Model_Runner.Backend.Backend_CPU
            else Item.Owner.Able.Kind)
      is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch (Item.Team, Weight, Vector, Target, Status, Roles => Item.Arithmetic);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product
              (Weight, Vector, Target, Status);
         when Model_Runner.Backend.Backend_Device =>
            Model_Runner.Backend.Device.Dispatch
              (Weight, Vector, Target, Status, Item.Stopping);
      end case;
   end Product;

   --  Several matrices against one activation, as one thing where that is
   --  worth something.
   --
   --  The places a block reads more than one matrix from the same input with
   --  nothing between them: its queries, keys and values, and the gate and up
   --  projection of a gated feed-forward. A device can be told, and then it
   --  costs one upload of that input, one command buffer, one submission and
   --  one wait instead of one of each per matrix. The processor and the
   --  reference gain nothing from being told -- their work is the arithmetic,
   --  not the errand -- so they do what they did, one product after another,
   --  and the difference stays inside here rather than becoming a shape every
   --  backend has to answer for.
   --
   --  @param Item Session the layer belongs to.
   --  @param Weights The matrices, in the order their results are wanted.
   --  @param Vector The activation all of them read.
   --  @param Into Receives each matrix's result, in the same order.
   --  @param Status Success, or the first refusal among them.
   procedure Product_Group
     (Item    : Session;
      Weights : T.View_Group;
      Vector  : T.Real_Array_Access;
      Into    : T.Target_Group;
      Status  : out E.Error_Info;
      Apart   : Element_Count := 0)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      --  Every matrix of the group, because a group is what a generated
      --  token's three projections are: hooking only the single product
      --  below would miss them, and did -- a watched run named the
      --  feed-forward's matrices and none of attention's.
      if Item.Seen /= null then
         for Index in Weights'Range loop
            declare
               Which : constant String :=
                 Named_As (Item.Owner.all, Weights (Index));
            begin
               if Which /= "" then
                  Item.Seen.Note (Which, Vector.all, 1);
               end if;
            end;
         end loop;
      end if;

      if not Item.Host_Feed
        and then Item.Owner.Able.Kind = Model_Runner.Backend.Backend_Device
      then
         Model_Runner.Backend.Device.Dispatch_Group
           (Weights, Vector, Into, Status, Item.Stopping, Apart);
         return;
      end if;

      --  And the pool has a group of its own: the wake and the settle of
      --  each product after the first are what it saves, which a generated
      --  token was paying five times a layer. It takes one activation, so
      --  a group laid end to end goes the long way below -- which costs the
      --  processor nothing, because what a group saves there is a wake and
      --  the pool is already awake.
      if (Item.Host_Feed
          or else Item.Owner.Able.Kind = Model_Runner.Backend.Backend_CPU)
        and then Apart = 0
      then
         Workers_CPU.Dispatch_Group (Item.Team, Weights, Vector, Into, Status, Roles => Item.Arithmetic);
         return;
      end if;

      --  One at a time, which every backend can do. A group laid end to
      --  end cannot come here, because a product takes a whole vector and
      --  there is no handing it a stretch of one; the caller asks for that
      --  only where a backend takes it.
      if Apart /= 0 then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "grouped_apart", E.Param_Identifier);
         return;
      end if;

      Status := E.Success;
      for Index in Weights'Range loop
         Product
           (Item, Weights (Index), Vector,
            Into (Into'First + (Index - Weights'First)), Status);
         exit when E.Is_Error (Status);
      end loop;
   end Product_Group;

   --  DeepSeek's queries as the projection makes them, each head its nope
   --  part then its rotated slice, reordered in place to the rotated slice
   --  then the nope part, for Count positions from At.
   procedure Rope_First
     (Item  : Session;
      Rows  : in out Real_Array;
      At_Row : Element_Count;
      Count : Element_Count)
   is
      Settings  : Configuration renames Item.Owner.Settings;
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Rope      : constant Element_Count := Element_Count (Settings.Rotary);
      Nope      : constant Element_Count := Head_Size - Rope;
      Held      : Real_Array (0 .. Head_Size - 1);
   begin
      for P in 0 .. Count - 1 loop
         for Head in 0 .. Heads - 1 loop
            declare
               At_Head : constant Element_Count :=
                 At_Row + (P * Heads + Head) * Head_Size;
            begin
               Held := Rows (At_Head .. At_Head + Head_Size - 1);
               Rows (At_Head .. At_Head + Rope - 1) :=
                 Held (Nope .. Head_Size - 1);
               Rows (At_Head + Rope .. At_Head + Head_Size - 1) :=
                 Held (0 .. Nope - 1);
            end;
         end loop;
      end loop;
   end Rope_First;

   --  DeepSeek's latent attention projection for one position: the query,
   --  keys and values reconstructed a head at a time from their latents,
   --  into the same rows a plain attention writes -- a key of the nope part
   --  and the shared rotated slice, a value of the rest -- so the rotation,
   --  the cache and the blend that follow run unchanged, the rotation told
   --  where the rotated slice sits by an offset a head. The rope part is
   --  written unrotated here; the caller rotates it with everything else.
   procedure MLA_Project
     (Item    : Session;
      Current : Layer;
      Status  : out E.Error_Info)
   is
      Settings  : Configuration renames Item.Owner.Settings;
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Rope      : constant Element_Count := Element_Count (Settings.Rotary);
      Nope      : constant Element_Count := Head_Size - Rope;
      V_Size    : constant Element_Count := Element_Count (Settings.Value_Size);
      KV_Lora   : constant Element_Count :=
        Element_Count (Settings.KV_Lora_Rank);
      KV_Stride : constant Element_Count := Nope + V_Size;
      K_At : constant Element_Count := Item.Key_Row.all'First;
      V_At : constant Element_Count := Item.Value_Row.all'First;
      L_At : constant Element_Count := Item.MLA_KV.all'First;
      R_At : constant Element_Count := Item.MLA_KV_Lat.all'First;
   begin
      --  The query, through a latent and a norm or straight where the file
      --  states no query latent.
      if Settings.Q_Lora_Rank > 0 then
         Product (Item, Current.Q_A, Item.Normalized, Item.MLA_Q_Lat, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         declare
            Normed : T.Real_Array (Item.MLA_Q_Lat.all'Range);
         begin
            K.RMS_Norm
              (Item.MLA_Q_Lat.all, Current.Q_A_Norm.all, Settings.Epsilon,
               Normed);
            Item.MLA_Q_Lat.all := Normed;
         end;
         Product (Item, Current.Q_B, Item.MLA_Q_Lat, Item.Query, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Product
           (Item, Current.KV_A_MQA, Item.Normalized, Item.MLA_KV_Lat, Status);
      else
         --  The query and the key-value latent read the same row: one job
         --  rather than two, the row quantized once.
         Product_Group
           (Item, [Current.Query, Current.KV_A_MQA], Item.Normalized,
            [Item.Query, Item.MLA_KV_Lat], Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  The key-value latent and the rotated slice it shares across the
      --  heads; the latent normalized by itself and projected out a head.
      K.RMS_Norm
        (Item.MLA_KV_Lat.all (R_At .. R_At + KV_Lora - 1),
         Current.KV_A_Norm.all, Settings.Epsilon, Item.MLA_C_Norm.all);
      Product (Item, Current.KV_B, Item.MLA_C_Norm, Item.MLA_KV, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  A head's key -- the shared rotated slice first, then the nope
      --  part from the up projection -- and its value, the rest of the up
      --  projection. Rotated first, and the query reordered to match: a
      --  score is the same sum whichever order its terms are in, and a head
      --  that turns from its first element is the shape the device's
      --  kernels take.
      Rope_First (Item, Item.Query.all, Item.Query.all'First, 1);
      for Head in 0 .. Heads - 1 loop
         for I in 0 .. Rope - 1 loop
            Item.Key_Row.all (K_At + Head * Head_Size + I) :=
              Item.MLA_KV_Lat.all (R_At + KV_Lora + I);
         end loop;
         for I in 0 .. Nope - 1 loop
            Item.Key_Row.all (K_At + Head * Head_Size + Rope + I) :=
              Item.MLA_KV.all (L_At + Head * KV_Stride + I);
         end loop;
         for I in 0 .. V_Size - 1 loop
            Item.Value_Row.all (V_At + Head * V_Size + I) :=
              Item.MLA_KV.all (L_At + Head * KV_Stride + Nope + I);
         end loop;
      end loop;

      Status := E.Success;
   end MLA_Project;

   procedure Product_Batch
     (Item    : Session;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info);

   --  DeepSeek's latent projection for a batch: what MLA_Project does a
   --  position, each projection taken once over every position -- the
   --  query (through its latent and norm where the file has one), the
   --  key-value latent with the shared rotated slice, its norm a row, and
   --  the up projection -- then the rows laid out as MLA_Project lays them.
   --  A position at a time it was a product a projection a position, which
   --  on the device is a round trip each: a prompt of a hundred went at
   --  five tokens a second.
   procedure MLA_Project_Batch
     (Item    : Session;
      Current : Layer;
      Rows    : T.Real_Array_Access;
      Count   : Element_Count;
      Query   : T.Real_Array_Access;
      Keys    : T.Real_Array_Access;
      Values  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Settings  : Configuration renames Item.Owner.Settings;
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Rope      : constant Element_Count := Element_Count (Settings.Rotary);
      Nope      : constant Element_Count := Head_Size - Rope;
      V_Size    : constant Element_Count := Element_Count (Settings.Value_Size);
      KV_Lora   : constant Element_Count :=
        Element_Count (Settings.KV_Lora_Rank);
      Q_Lora    : constant Element_Count :=
        Element_Count (Settings.Q_Lora_Rank);
      KV_Stride : constant Element_Count := Nope + V_Size;
      Lat_Width : constant Element_Count := KV_Lora + Rope;

      Q_Lat, KV_Lat, C_Norm, KV : T.Real_Array_Access;

      procedure Release is
      begin
         T.Free (Q_Lat); T.Free (KV_Lat); T.Free (C_Norm); T.Free (KV);
      end Release;
   begin
      Status := E.Success;
      T.Allocate (Count * Lat_Width, KV_Lat);
      T.Allocate (Count * KV_Lora, C_Norm);
      T.Allocate (Count * Heads * KV_Stride, KV);
      if Q_Lora > 0 then
         T.Allocate (Count * Q_Lora, Q_Lat);
      end if;
      if KV_Lat = null or else C_Norm = null or else KV = null
        or else (Q_Lora > 0 and then Q_Lat = null)
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      --  The queries.
      if Q_Lora > 0 then
         Product_Batch (Item, Current.Q_A, Rows, Count, Q_Lat, Status);
         if E.Is_Ok (Status) then
            for P in 0 .. Count - 1 loop
               declare
                  Normed : Real_Array (0 .. Q_Lora - 1);
               begin
                  K.RMS_Norm
                    (Q_Lat.all (P * Q_Lora .. P * Q_Lora + Q_Lora - 1),
                     Current.Q_A_Norm.all, Settings.Epsilon, Normed);
                  Q_Lat.all (P * Q_Lora .. P * Q_Lora + Q_Lora - 1) := Normed;
               end;
            end loop;
            Product_Batch (Item, Current.Q_B, Q_Lat, Count, Query, Status);
         end if;
      else
         Product_Batch (Item, Current.Query, Rows, Count, Query, Status);
      end if;
      if E.Is_Error (Status) then
         Release;
         return;
      end if;

      --  The key-value latents with their rotated slices, each latent
      --  normalized by itself, and the up projection of all of them.
      Product_Batch (Item, Current.KV_A_MQA, Rows, Count, KV_Lat, Status);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
      for P in 0 .. Count - 1 loop
         K.RMS_Norm
           (KV_Lat.all (P * Lat_Width .. P * Lat_Width + KV_Lora - 1),
            Current.KV_A_Norm.all, Settings.Epsilon,
            C_Norm.all (P * KV_Lora .. P * KV_Lora + KV_Lora - 1));
      end loop;
      Product_Batch (Item, Current.KV_B, C_Norm, Count, KV, Status);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;

      --  Each position's queries reordered rotated slice first, and its
      --  keys -- the shared rotated slice, then a head's nope part from the
      --  up projection -- and values, the rest of it; see MLA_Project.
      Rope_First (Item, Query.all, Query.all'First, Count);
      for P in 0 .. Count - 1 loop
         declare
            K_Row : constant Element_Count := P * Heads * Head_Size;
            V_Row : constant Element_Count := P * Heads * V_Size;
            L_Row : constant Element_Count := P * Heads * KV_Stride;
            R_Row : constant Element_Count := P * Lat_Width + KV_Lora;
         begin
            for Head in 0 .. Heads - 1 loop
               Keys.all (K_Row + Head * Head_Size
                         .. K_Row + Head * Head_Size + Rope - 1) :=
                 KV_Lat.all (R_Row .. R_Row + Rope - 1);
               Keys.all (K_Row + Head * Head_Size + Rope
                         .. K_Row + Head * Head_Size + Head_Size - 1) :=
                 KV.all (L_Row + Head * KV_Stride
                         .. L_Row + Head * KV_Stride + Nope - 1);
               Values.all (V_Row + Head * V_Size
                           .. V_Row + Head * V_Size + V_Size - 1) :=
                 KV.all (L_Row + Head * KV_Stride + Nope
                         .. L_Row + Head * KV_Stride + Nope + V_Size - 1);
            end loop;
         end;
      end loop;

      Release;
   end MLA_Project_Batch;

   procedure Product_Batch
     (Item    : Session;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      if Item.Seen /= null then
         declare
            Which : constant String := Named_As (Item.Owner.all, Weight);

            --  Exactly the rows this product will read, and not whatever
            --  the buffer happens to be: a round hands a buffer sized for
            --  the whole batch and multiplies a few of its rows, so a
            --  watcher dividing the buffer by the count would take a
            --  column width several times too wide.
            Room : constant Element_Count := Count * Weight.Columns;
         begin
            if Which /= "" and then Vectors.all'Length >= Room then
               Item.Seen.Note
                 (Which,
                  Vectors.all (Vectors.all'First
                               .. Vectors.all'First + Room - 1),
                  Count);
            end if;
         end;
      end if;

      case (if Item.Host_Feed then Model_Runner.Backend.Backend_CPU
            else Item.Owner.Able.Kind)
      is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch_Batch
              (Item.Team, Weight, Vectors, Count, Target, Status, Roles => Item.Arithmetic);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product_Batch
              (Weight, Vectors, Count, Target, Status);

         when Model_Runner.Backend.Backend_Device =>
            Model_Runner.Backend.Device.Dispatch_Batch
              (Weight, Vectors, Count, Target, Status, Item.Stopping);
      end case;
   end Product_Batch;

   --  One expert's product over a batch, out of the stack it is a slice
   --  of, where the device holds the stacks; Product_Batch on the slice's
   --  own view everywhere else. The same answer either way; what differs
   --  is what the device keeps -- the stack once, rather than the slice
   --  beside it.
   --
   --  @param Item Session the layer belongs to.
   --  @param Slice The expert's own view, which is what a watcher names.
   --  @param Stack The stack the expert is a slice of.
   --  @param Each Rows one expert's slice holds.
   --  @param Member Which expert.
   --  @param Vectors Count vectors of the stack's column count.
   --  @param Count How many.
   --  @param Target Receives Count results of Each rows.
   --  @param Status Success, or the first refusal.
   procedure Product_Slice
     (Item    : Session;
      Slice   : T.View;
      Stack   : T.View;
      Each    : Element_Count;
      Member  : Natural;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      if not Item.Owner.all.Stacked
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else not T.Is_Present (Stack)
      then
         Product_Batch (Item, Slice, Vectors, Count, Target, Status);
         return;
      end if;

      if Item.Seen /= null then
         declare
            Which : constant String := Named_As (Item.Owner.all, Slice);
            Room  : constant Element_Count := Count * Slice.Columns;
         begin
            if Which /= "" and then Vectors.all'Length >= Room then
               Item.Seen.Note
                 (Which,
                  Vectors.all (Vectors.all'First
                               .. Vectors.all'First + Room - 1),
                  Count);
            end if;
         end;
      end if;

      Model_Runner.Backend.Device.Dispatch_Slice
        (Stack, Each, Member, Vectors, Count, Target, Status,
         Item.Stopping);
   end Product_Slice;

   --  Whether a matrix's format wants its activation's sums over a
   --  super-block, which decides which packing of a batch it can read.
   function Supers (Weight : T.View) return Boolean
   is (Model_Runner.Quantization.Integers.Supers_Vectors (Weight.Format));

   --  Whether a matrix splits into two halves of whole panels, its bytes a
   --  whole number a row: what Row_Slice needs of it.
   function Halves_Whole (Weight : T.View) return Boolean
   is (Weight.Rows > 0
       and then Weight.Rows mod 16 = 0
       and then Weight.Length mod B.Byte_Count (Weight.Rows) = 0);

   --  Rows First .. First + Count - 1 of a matrix, as a matrix. A file's
   --  rows lie one after another and a panelled copy's panels do, eight
   --  rows each, so either way a run of rows starting on a panel is a run
   --  of bytes at the same rate a row.
   function Row_Slice
     (Weight : T.View;
      First  : Element_Count;
      Count  : Element_Count) return T.View
   is (Weight with delta
         Rows   => Count,
         Offset => Weight.Offset
                   + Weight.Length / B.Byte_Count (Weight.Rows)
                     * B.Byte_Count (First),
         Length => Weight.Length / B.Byte_Count (Weight.Rows)
                   * B.Byte_Count (Count));

   --  The model's per-dimension divisors, or none when it carries no table.
   function Turns (Item : Model'Class) return Real_Array
   is (if Item.Rope_Factors = null
       then K.No_Factors
       else Item.Rope_Factors.all);

   --  Attention for one position, over every head.
   --
   --  Each head scores the positions it may read against its query, turns
   --  those scores into a distribution, and sums the values in proportion.
   --  Both evaluation paths call this -- a token at a time and a token of a
   --  batch -- so the arithmetic that decides what a position attends to
   --  exists once rather than twice.
   --
   --  There are two of these because the cache has two storages and the
   --  difference is one conversion in the innermost loop. A single body with
   --  a test in that loop would put a branch between every multiply and the
   --  next on the exact path, which is the default and the one every
   --  published figure was measured on. Both are reached by the conformance
   --  sweep, so neither is a copy nothing runs.
   --  How steeply one head's attention falls off with distance.
   --
   --  The ladder the architecture's own runtime computes, and it is not a
   --  straight geometric one. The heads up to the largest power of two not
   --  above the head count take m0 to the power h + 1, where m0 is two to
   --  the minus max_bias over that power; the heads above it take m1 to the
   --  power 2 (h - that) + 1, where m1 is the same with half the bias.
   --  Twelve heads take eight of the first and four of the second, so a
   --  ladder written as the first alone is right for two thirds of them and
   --  wrong for the rest -- which is an embedding rather than a refusal, and
   --  is why the file this was checked against is the twelve-head one.
   --
   --  Zero bias gives zero slope, which is no bias at all, and every
   --  architecture that rotates or learns a row for the position takes that.
   function Head_Slope
     (Max_Bias : Real; Head : Element_Count; Heads : Element_Count)
      return Real
   is
      Power : Element_Count := 1;
   begin
      if Max_Bias <= 0.0 then
         return 0.0;
      end if;

      while Power * 2 <= Heads loop
         Power := Power * 2;
      end loop;

      declare
         Rungs : constant N.Wide_Real := N.Wide_Real (Power);
         Bias  : constant N.Wide_Real := N.Wide_Real (Max_Bias);
         M0    : constant N.Wide_Real := N.Power (2.0, -(Bias / Rungs));
         M1    : constant N.Wide_Real :=
           N.Power (2.0, -(Bias / 2.0 / Rungs));
      begin
         if Head < Power then
            return Real (N.Power (M0, N.Wide_Real (Head + 1)));
         else
            return Real
              (N.Power (M1, N.Wide_Real (2 * (Head - Power) + 1)));
         end if;
      end;
   end Head_Slope;

   procedure Blend_Exact
     (Query      : Real_Array;
      Keys       : Real_Array;
      Values     : Real_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;

      --  The bound the architecture states on a score, or zero for none.
      Cap        : Real;

      --  How steeply attention falls off with distance, or zero for an
      --  architecture that says where a token is some other way, and where
      --  the query itself is. The second is not Last: for a model that
      --  reads a whole text at once every slot of the batch sees the same
      --  last position, so the query's own position never reaches here
      --  unless it is passed. It has no default for that reason.
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  One score a head that joins the softmax's denominator and takes
      --  none of the weight, or null for an architecture that states none.
      Sinks      : Model_Runner.Tensors.Real_Array_Access;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is separate;

   --  The device's cache, dealt out in blocks.
   --
   --  A device holds one cache buffer, and until a round there was one
   --  session reading it: it wrote from the start and read from the start.
   --  A round's rows are different sessions attending side by side, so the
   --  buffer is dealt out in blocks of one session's worth and row i of a
   --  round reads block i -- which is the whole of what the kernel needs to
   --  be told, since it multiplies the row number by the block width.
   --
   --  A block is remembered between calls, so the same members round after
   --  round pay for this once. Taking a block another session holds turns
   --  that session out; what the host holds is the copy of record, always,
   --  so the one turned out loses a copy and nothing else, and takes a
   --  block again by writing its cache into it when it next runs.
   --
   --  One device, one engine, one buffer: this state is the buffer's and is
   --  as concurrent as the engine, which is to say that two tasks
   --  evaluating on the same device at once was never a thing this program
   --  did.
   --  How far into the buffer blocks have been dealt, in elements: the
   --  table a round reads and a layer's sinks sit past it. It only grows
   --  while anything holds a block, so the table does not move under a
   --  round that is already formed.
   Block_Taken  : Element_Count := 0;

   --  What a block must begin on, in elements: a cache line of this part,
   --  sixteen binary32 words. Nothing in the kernels asks for it -- they
   --  index elements -- but a block that began at an odd element would
   --  have every row of keys in it straddling a line it need not, which
   --  is what the room of rings measured at a third of the rule's time
   --  when a ring began forty floats in. A kilobyte, as the rings use,
   --  would round a short session's whole block up to one.
   Block_Alignment : constant Element_Count := 16;
   Block_Holder : array (0 .. Model_Runner.Backend.Device.Block_Limit - 1)
     of Session_Access := [others => null];

   --  The room a model's attention sinks take in the device cache: a slot a
   --  head a layer, where the architecture learned them, and none where it
   --  did not. Sized to the model rather than to a fixed cap, so a sink
   --  model of any depth or width keeps every layer's sinks on the device
   --  rather than spilling the layers whose slot would fall past a constant
   --  to the host. The next block is counted with the stack: it attends
   --  like the rest, so it too reads a sink where the model has one.
   function Sink_Footprint (Settings : Configuration) return Element_Count
   is (if Settings.Kind = GPT_OSS
       then Element_Count
              ((Settings.Layers + Settings.Next_Layers) * Settings.Heads)
       else 0);

   --  What the sink region the held blocks were sized for holds: the model
   --  their session belongs to, since the device carries one model's cache
   --  at a time, and none where no block is held.
   function Held_Sink_Room return Element_Count is
   begin
      for Which in Block_Holder'Range loop
         if Block_Holder (Which) /= null then
            return Sink_Footprint (Block_Holder (Which).Owner.Settings);
         end if;
      end loop;
      return 0;
   end Held_Sink_Room;

   --  And when each block was last asked for. A session stamps its block
   --  every time it asks for it -- which is every layer that goes over
   --  whole, so the stamp is how recently the block was read rather than
   --  how recently it was granted -- and a session that finds every block
   --  held takes the one stamped longest ago. The clock counts asks and
   --  nothing else: it is compared and never read as a time.

   --  The cache dealt in pages rather than blocks. A page holds this many
   --  positions of one layer, its keys and then its values -- a power of
   --  two so a position's page and its place inside it are a shift and a
   --  mask, which is what the kernels read the cache by, and a multiple of
   --  the matrix instruction's sixteen so a tile of keys never straddles a
   --  page.
   --
   --  Sixteen, the smallest the tile allows, because that is what a
   --  measurement found optimal: the cache a page holds is a session's fill
   --  rounded up to the page, so a smaller page wastes less, and the
   --  throughput is the same at every size -- the wider table more pages
   --  carry costs nothing in time. A larger page only ever ties, where the
   --  fill rounds to its boundary. Set_Page_Size moves it, kept in step
   --  with the shift; a server holding very many long fills may take a
   --  larger page to spend fewer pages against the pool's cap. The two are
   --  one geometry, changed only while no page is held.
   Page_Positions  : Natural := 16;
   Page_Shift_Bits : Natural := 4;

   --  Extra entries a layer's page table carries past its own pages, each
   --  the base of a valid page. A kernel reads its keys and values in
   --  chunks -- eight positions at a time, or a tile of the matrix
   --  instruction's sixteen, or a whole sixty-four-position tile -- and
   --  the last chunk of a run reads a few positions past the last one that
   --  attends. Their weight in the softmax is zero, so what they read does
   --  not reach the answer; but their position, shifted to a page, indexes
   --  the table, and past a table with no slack that is a wild read of the
   --  cache. In a block the same over-read lands on the next block's
   --  cells, which are memory; here the padding entries point a masked
   --  over-read at a real page instead. Two pages cover a sixty-four
   --  position tile at this page size, with one to spare.
   Page_Table_Pad : constant := 2;

   --  How large a page is, in elements: the positions times a row of keys
   --  and a row of values together. It is the model's, set when a paged
   --  session is laid out and the same for every page of the run.
   Page_Elements : Element_Count := 0;

   --  Who holds each page slot of the cache, and how far into the buffer
   --  pages have been dealt -- what Block_Taken is for a cache in blocks.
   --  Slot I is the elements [I * Page_Elements, (I + 1) * Page_Elements).
   Page_Cap : constant := 65_536;
   Page_Owner : array (0 .. Page_Cap - 1) of Session_Access :=
     [others => null];
   Pages_Taken : Element_Count := 0;

   --  The front of the cache's numbering, before the first page, that a
   --  paged session's tables are kept in: a word a page a layer and the
   --  padding, which the pool's slots and a pad a layer bound. Tables past
   --  the pages moved as the pages grew and had to be held in the binary32
   --  buffer with every row under them; at the front they stay where they
   --  are, and a cache whose rows are read only as halves keeps this front
   --  and the copy and nothing else.
   Page_Front : constant Element_Count := Element_Count (Page_Cap) + 4_096;

   --  Whose page tables are at the front of the pool, and where the front
   --  was when they were written. Every paged session writes its tables
   --  to the same place -- the front, Pages_Taken -- so a session may skip
   --  writing them again only while they are still its own and the front
   --  has not moved: a draft model's session between two of the target's
   --  tokens wrote its own there, and the target, its pages reaching far
   --  enough, read the draft's tables for its keys and values.
   Tables_Of    : Session_Access := null;
   Tables_Front : Element_Count := 0;

   --  How many slots are held, and the most that may be. The pool is
   --  bounded by the device's memory, which the reserve enforces; a server
   --  may bound it tighter, to hold more sessions in less by turning the
   --  coldest out rather than growing without end. The default is the
   --  pool's own size, which is no bound but the memory's.
   Pages_In_Use : Natural := 0;

   --  Paged sessions turned out since the device was opened: the count a
   --  server reads to know a tighter pool is churning the cache.

   --  Whether the last session to ask for a block and be refused was
   --  refused because every one of them was another session's, rather
   --  than for anything about its own shape or size. Read where the
   --  layer's outcome is noted, so that a run says which of the two it
   --  was: one is a context this device will not hold, the other is
   --  sixteen sessions that got there first.
   Blocks_Were_Held : Boolean := False;

   --  Who asked last, which is how a session's run of asks -- one a layer,
   --  through a token -- is told from the token before it.

   --  Which sessions hold a seat in the device's state room: a ring
   --  each, Kept_States + 1 slots of every linear layer's memories and
   --  states, laid one after another past the runs' table at the front.
   --  A seat is taken the first time a session's linear layer goes over
   --  and given back when the session closes or its ring changes size;
   --  a new one takes the first gap that fits, or the end.
   State_Seats : array (0 .. Model_Runner.Backend.Device.Block_Limit - 1)
     of Session_Access := [others => null];

   --  The runs' table at the front of the room: five words a run, one
   --  run a session of a round at most, in a stretch rounded up to the
   --  alignment below.
   --
   --  Every ring begins on a kilobyte. A ring that began forty floats
   --  in -- right after the table -- had every row of its states
   --  straddling a cache line more than it needs, and the rule read a
   --  third slower for it.
   State_Alignment : constant Element_Count := 256;
   State_Table_Room : constant Element_Count := State_Alignment;

   --  How many elements one slot of the ring takes on the device: the
   --  memories of every linear layer, then the states.
   function Device_Slot_Span (Item : Session) return Element_Count
   is (Conv_Room (Item.Owner.Settings) + State_Room (Item.Owner.Settings));

   --  How many elements a session's whole ring takes.
   function Device_Ring_Span (Item : Session) return Element_Count
   is ((Element_Count (Item.Kept_States) + 1
        + (if Item.Check_Slot then 1 else 0))
       * Device_Slot_Span (Item));

   --  Where a session's checkpoint slot lies on the device: past its ring.
   function Device_Check_At (Item : Session) return Element_Count
   is (Item.State_Base
       + (Element_Count (Item.Kept_States) + 1) * Device_Slot_Span (Item));

   --  Bring a session's ring home from the device, where the device's
   --  copy is the newer. A no-op otherwise, so it is asked wherever the
   --  host is about to read the ring.
   procedure Fetch_States (Item : Session_Access) is
      Read : Boolean := True;
   begin
      if Item = null or else not Item.State_On_Device
        or else not Item.State_Seated
        or else Item.Delta_State = null or else Item.Conv_State = null
      then
         return;
      end if;

      declare
         Settings   : Configuration renames Item.Owner.Settings;
         Every      : constant Element_Count := Device_Slot_Span (Item.all);
         Every_Conv : constant Element_Count := Conv_Room (Settings);
         Every_State : constant Element_Count := State_Room (Settings);
         Slots      : constant Element_Count :=
           Element_Count (Item.Kept_States) + 1;
      begin
         for Slot in 0 .. Slots - 1 loop
            Model_Runner.Backend.Device.Get_State
              (Item.State_Base + Slot * Every,
               Item.Conv_State.all
                 (Slot * Every_Conv .. (Slot + 1) * Every_Conv - 1),
               Read);
            exit when not Read;
            Model_Runner.Backend.Device.Get_State
              (Item.State_Base + Slot * Every + Every_Conv,
               Item.Delta_State.all
                 (Slot * Every_State .. (Slot + 1) * Every_State - 1),
               Read);
            exit when not Read;
         end loop;
      end;

      --  Read or not, the device's copy is not the one to read again: a
      --  read that failed leaves the host's as it was, and the next
      --  layer on the device starts from that.
      Item.State_On_Device := False;
   end Fetch_States;

   --  Give a session's seat back: at its close, and when its ring
   --  changes size. What the device held is not brought home here: a
   --  closing session's ring is nobody's, and a ring about to change
   --  size is fetched by the caller that will read it. Reading fifty
   --  megabytes back through the mapping at every close left the device
   --  idle long enough to drop its clock, and the next session's prompt
   --  ran a third slower for it.
   procedure Release_State_Room (Item : Session_Access) is
   begin
      if Item = null then
         return;
      end if;

      for Seat in State_Seats'Range loop
         if State_Seats (Seat) = Item then
            State_Seats (Seat) := null;
         end if;
      end loop;

      Item.State_Seated := False;
      Item.State_On_Device := False;

      --  A checkpoint the seat held goes with it.
      if Item.Check_On_Device then
         Item.Check_On_Device := False;
         Item.Check_At := 0;
      end if;

      --  And the room itself where nobody is seated in it: it grew to
      --  hold every seated ring and never shrank, so a hybrid session
      --  with states kept left tens of megabytes of the machine's own
      --  memory on the device until the engine closed. The next session
      --  to seat takes a room again and writes its ring into it, which
      --  is what seating is.
      if (for all Seated of State_Seats => Seated = null) then
         Model_Runner.Backend.Device.Release_State_Room;
      end if;
   end Release_State_Room;

   --  Give a session a seat: the first gap past the table that its ring
   --  fits, or the end of what is taken, with the room grown to reach
   --  it.
   --  Write a session's ring into the seat it holds, where its host copy
   --  says. Said by Send_States, which decides whether it is wanted, and
   --  by the compaction below, which has just moved the seat and must put
   --  the ring where it now is before anything reads it there.
   --
   --  Every slot of it, though only the slots a position has written say
   --  anything and a seat freshly taken is zeros. Sending the written
   --  ones alone was written and measured: a ring is as many slots as a
   --  draft is long and one more, so a session is past the last of them
   --  within six positions and every slot is live from there on. Nothing
   --  that can be run here showed the difference.
   procedure Write_Ring (Item : Session_Access; Ok : out Boolean) is
      Settings    : Configuration renames Item.Owner.Settings;
      Every       : constant Element_Count := Device_Slot_Span (Item.all);
      Every_Conv  : constant Element_Count := Conv_Room (Settings);
      Every_State : constant Element_Count := State_Room (Settings);
      Slots       : constant Element_Count :=
        Element_Count (Item.Kept_States) + 1;
      Written     : Boolean;
   begin
      Ok := True;

      for Slot in 0 .. Slots - 1 loop
         Model_Runner.Backend.Device.Put_State
           (Item.State_Base + Slot * Every,
            Item.Conv_State.all
              (Slot * Every_Conv .. (Slot + 1) * Every_Conv - 1),
            Written);
         if not Written then
            Ok := False;
            return;
         end if;
         Model_Runner.Backend.Device.Put_State
           (Item.State_Base + Slot * Every + Every_Conv,
            Item.Delta_State.all
              (Slot * Every_State .. (Slot + 1) * Every_State - 1),
            Written);
         if not Written then
            Ok := False;
            return;
         end if;
      end loop;
   end Write_Ring;

   --  The first place in the room a ring of Span elements fits: from the
   --  table's end, moved past every seated ring that overlaps, until
   --  nothing does, and rounded up to what a seat begins on.
   function First_Gap (Span : Element_Count) return Element_Count is
      Place : Element_Count := State_Table_Room;
   begin
      loop
         declare
            Moved : Boolean := False;
         begin
            for Seat in State_Seats'Range loop
               declare
                  Other : constant Session_Access := State_Seats (Seat);
               begin
                  if Other /= null
                    and then Place < Other.State_Base
                                  + Device_Ring_Span (Other.all)
                    and then Other.State_Base < Place + Span
                  then
                     Place :=
                       (Other.State_Base + Device_Ring_Span (Other.all)
                        + State_Alignment - 1)
                       / State_Alignment * State_Alignment;
                     Moved := True;
                  end if;
               end;
            end loop;
            exit when not Moved;
         end;
      end loop;

      return Place;
   end First_Gap;

   --  How much of the room below Upto no seated ring is using: what
   --  moving the seats to the front would recover.
   function Room_Below (Upto : Element_Count) return Element_Count is
      Taken : Element_Count := State_Table_Room;
   begin
      for Seat in State_Seats'Range loop
         if State_Seats (Seat) /= null
           and then State_Seats (Seat).State_Base < Upto
         then
            Taken :=
              Taken
              + (Device_Ring_Span (State_Seats (Seat).all)
                 + State_Alignment - 1)
                / State_Alignment * State_Alignment;
         end if;
      end loop;

      return (if Upto > Taken then Upto - Taken else 0);
   end Room_Below;

   --  Move seated rings to the front of the room until one of Span fits
   --  below what the room has already been reserved for, or until nothing
   --  is left to move.
   --
   --  The room is dealt a seat at a time, each placed at the first gap that
   --  holds it, and seats are given up in whatever order the sessions
   --  holding them close. Rings differ in size -- a session is asked how
   --  many states to keep -- so a seat given back in the middle leaves a
   --  gap that a larger ring cannot use, and the room grew at the end for
   --  every one of those while the gaps below it stayed empty. Nothing
   --  shrank it but the last seat going.
   --
   --  What a move costs is the ring read home and written again, which is
   --  what a session pays anyway when it is turned out of a seat; a ring
   --  whose place does not change pays nothing. So the rings are moved in
   --  the order they sit in and the walk stops at the first one that makes
   --  the room, rather than packing all sixteen to seat one session.
   --
   --  In that order and no other: a ring moves to where a ring below it
   --  used to be, so moving from the front means writing only over room
   --  already given up. Out of order -- seat by seat, as this did at
   --  first -- a ring could be written over one whose host copy was still
   --  the older, and what was read back for that one afterwards was the
   --  ring that had just been written over it.
   --
   --  @param Span What the asking session's ring needs room for.
   --  @param Ok False where a ring could not be read back or written, in
   --    which case nothing was moved that is not where the host says.
   procedure Compact_State_Room (Span : Element_Count; Ok : out Boolean) is
      Place : Element_Count := State_Table_Room;
   begin
      Ok := True;

      loop
         declare
            Next  : Session_Access := null;
            Where : Element_Count := 0;
         begin
            --  The lowest seat not yet packed.
            for Seat in State_Seats'Range loop
               declare
                  Other : constant Session_Access := State_Seats (Seat);
               begin
                  if Other /= null and then Other.State_Base >= Place
                    and then (Next = null or else Other.State_Base < Where)
                  then
                     Next  := Other;
                     Where := Other.State_Base;
                  end if;
               end;
            end loop;

            exit when Next = null;

            if Where > Place then
               --  Moved where it lies, as a block of the cache is: the
               --  ring came home to the host and went back again for
               --  this, which is tens of megabytes across the bus twice
               --  to shift a seat that the device can shift itself.
               declare
                  Went : Boolean;
               begin
                  Model_Runner.Backend.Device.Move_State
                    (From     => Where,
                     Into     => Place,
                     Elements => Device_Ring_Span (Next.all),
                     Ok       => Went);

                  if not Went then
                     Ok := False;
                     return;
                  end if;
               end;

               Next.State_Base := Place;

               Model_Runner.Backend.Device.Note_Moved (Ring => True);
            end if;

            Place :=
              (Place + Device_Ring_Span (Next.all) + State_Alignment - 1)
              / State_Alignment * State_Alignment;

            exit when Interfaces.Unsigned_64 (First_Gap (Span) + Span) * 4
                      <= Model_Runner.Backend.Device.State_Room_Bytes;
         end;
      end loop;
   end Compact_State_Room;

   procedure Seat_State
     (Item : Session_Access; Ok : out Boolean; Cleared : out Boolean)
   is
      Span : constant Element_Count := Device_Ring_Span (Item.all);
      Free : Integer := -1;
      Place : Element_Count := State_Table_Room;
   begin
      Cleared := False;

      Ok := Item.State_Seated;
      if Ok then
         return;
      end if;

      for Seat in State_Seats'Range loop
         if State_Seats (Seat) = null then
            Free := Seat;
            exit;
         end if;
      end loop;

      --  None free: the device's ring seats are all held, so this
      --  session runs its linear layers on the processor until a seat
      --  comes back. A seat is given up when its session closes, and a
      --  personal tool holds one or two.
      if Free < 0 then
         return;
      end if;

      --  The first gap: from the table's end, moved past every seated
      --  ring that overlaps, until nothing does.
      Place := First_Gap (Span);

      --  And where that gap is past the room already reserved while there
      --  is any gap below it, the seats are moved to the front instead of
      --  the room growing: rings differ in size, seats are given back in
      --  whatever order sessions close, and a gap a larger ring cannot use
      --  is room the room keeps for nobody. Only where the room would
      --  otherwise grow, because a move is a ring read home and written
      --  again.
      if Interfaces.Unsigned_64 (Place + Span) * 4
         > Model_Runner.Backend.Device.State_Room_Bytes
        and then Room_Below (Place) >= Span
      then
         declare
            Moved : Boolean;
         begin
            Compact_State_Room (Span, Moved);

            if Moved then
               Place := First_Gap (Span);
            end if;
         end;
      end if;

      Model_Runner.Backend.Device.Reserve_State (Place + Span, Ok);
      if not Ok then
         return;
      end if;

      State_Seats (Free) := Item;
      Item.State_Base := Place;
      Item.State_Seated := True;
      Item.State_On_Device := False;

      --  The seat zeroed on the device, which the session that had it
      --  before did not leave it: a ring is what it was written with,
      --  and a seat taken again holds the last session's. Zeroed here,
      --  a session with nothing committed has nothing to send -- twenty
      --  megabytes of nothing across the bus, six milliseconds a
      --  session, for a room the device can zero itself.
      Model_Runner.Backend.Device.Clear_State (Place, Span, Cleared);
   end Seat_State;

   --  Put a session's ring on the device, where the host's copy is the
   --  newer, in the seat it holds or takes.
   procedure Send_States (Item : Session_Access; Ok : out Boolean) is
   begin
      Ok := False;

      if Item = null or else Item.Owner = null
        or else Item.Delta_State = null or else Item.Conv_State = null
      then
         return;
      end if;

      declare
         Cleared : Boolean;
      begin
         Seat_State (Item, Ok, Cleared);
         if not Ok then
            return;
         end if;

         if Item.State_On_Device then
            return;
         end if;

         --  A ring of nothing into a seat the device has just zeroed:
         --  nothing to send. A session that has committed something has
         --  a ring that says so, and a seat it was already in holds
         --  whatever it left there, so both are sent as before.
         if Cleared and then Item.Committed = 0
           and then not Item.Ring_Written
         then
            Item.State_On_Device := True;
            return;
         end if;
      end;

      Write_Ring (Item, Ok);

      if Ok then
         Item.State_On_Device := True;
         Item.Ring_Written := False;
      end if;
   end Send_States;

   --  One run of a batch: a session's rows, one after another.
   type State_Run is record
      Whose : Session_Access := null;
      First : Natural := 0;
      Count : Natural := 0;
      Row   : Natural := 0;
   end record;
   type State_Runs is array (Positive range <>) of State_Run;

   --  Write the runs' table at the front of the room, as the kernels
   --  read it: five words a run, each a number as the bits of a float.
   procedure Write_Runs (Runs : State_Runs; Ok : out Boolean) is
      Words : Real_Array (0 .. Element_Count (Runs'Length) * 5 - 1);
      Place : Element_Count := 0;
   begin
      for Run of Runs loop
         Words (Place) :=
           N.From_Bits (Interfaces.Unsigned_32 (Run.Whose.State_Base));
         Words (Place + 1) := N.From_Bits (Interfaces.Unsigned_32 (Run.First));
         Words (Place + 2) := N.From_Bits (Interfaces.Unsigned_32 (Run.Count));
         Words (Place + 3) := N.From_Bits (Interfaces.Unsigned_32 (Run.Row));
         Words (Place + 4) :=
           N.From_Bits (Interfaces.Unsigned_32 (Run.Whose.Kept_States + 1));
         Place := Place + 5;
      end loop;

      Model_Runner.Backend.Device.Put_State (0, Words, Ok);
   end Write_Runs;

   --  A linear layer's geometry and its place in the ring, as the
   --  device's steps take them; the row steps are filled in there.
   function Linear_Shape_Of
     (Item : Session; Index : Natural; Runs : Positive)
      return Model_Runner.Backend.Device.Linear_Shape
   is
      Settings : Configuration renames Item.Owner.Settings;
   begin
      return
        (Mix         => Mix_Width (Settings),
         Head        => Settings.State_Size,
         Taps        => Settings.Conv_Kernel,
         Unit_Blocks => 2 * Settings.Key_Heads,
         Key_Heads   => Settings.Key_Heads,
         Value_Heads => Settings.Value_Heads,
         Key_Width   => Key_Width (Settings),
         Region_At   => Natural (Conv_At (Settings, Index)),
         Every       => Natural (Device_Slot_Span (Item)),
         Table_At    => 0,
         Runs        => Runs,
         Z_Step      => 0,
         Alpha_Step  => 0,
         Beta_Step   => 0,
         Scale       =>
           Real (1.0 / N.Sqrt (N.Wide_Real (Settings.State_Size))),
         Epsilon     => Settings.Epsilon);
   end Linear_Shape_Of;

   --  Where a linear layer's state lies within a slot on the device:
   --  after every layer's memories.
   function Linear_State_At (Item : Session; Index : Natural) return Natural
   is (Natural (Conv_Room (Item.Owner.Settings)
                + State_At (Item.Owner.Settings, Index)));

   --  A Mamba2 mixer as the device takes it, the session's seat in the
   --  state room included -- with the layer's normalization on the way in
   --  where the whole layer goes, residual and all.
   function Mamba2_Block_Of
     (Item      : Session;
      Current   : Layer;
      Index     : Natural;
      With_Norm : Boolean) return Model_Runner.Backend.Device.Mamba2_Block
   is
      Settings : Configuration renames Item.Owner.Settings;
      P : constant Mamba2_Places := Mamba2_Places_Of (Settings);

      --  z, x, B and C: the in-projection's rows before dt's.
      Main : constant Element_Count :=
        2 * Element_Count (Settings.Inner_Size)
        + 2 * Element_Count (Settings.Groups)
            * Element_Count (Settings.State_Size);

      --  Count rows of a matrix from row First on, as a view of their own.
      function Rows_Of (Whole : T.View; First, Count : Element_Count)
        return T.View
      is
         Result : T.View := Whole;
      begin
         Result.Rows := Count;
         Result.Offset :=
           Whole.Offset + B.Byte_Count (First) * T.Row_Bytes (Whole);
         return Result;
      end Rows_Of;
   begin
      return
        (Width     => Settings.Embedding,
         Inner     => Settings.Inner_Size,
         Heads     => Settings.Ssm_Heads,
         Head      => Settings.Head_Dim,
         State     => Settings.State_Size,
         Groups    => Settings.Groups,
         Taps      => Settings.Conv_Kernel,
         Pack      => Current.Ssm_Pack,
         Conv_At   => Natural (P.Conv),
         Bias_At   => Natural (P.Bias),
         Dt_At     => Natural (P.Dt),
         A_At      => Natural (P.A),
         D_At      => Natural (P.D),
         Gain_At   => Natural (P.Gain),
         In_Proj   =>
           (if Is_Mamba2 (Settings.Kind) then Rows_Of (Current.Ssm_In, 0, Main)
            else Current.Ssm_In),
         Dt_Proj   =>
           (if Is_Mamba2 (Settings.Kind)
            then Rows_Of (Current.Ssm_In, Main,
                          Element_Count (Settings.Ssm_Heads))
            else T.Empty_View),
         Out_Proj  => Current.Linear_Out,
         Memory_At => Natural (Item.State_Base + Conv_At (Settings, Index)),
         State_At  => Natural (Item.State_Base) + Linear_State_At (Item, Index),
         Epsilon   => Settings.Epsilon,
         Norm      => (if With_Norm then Current.Attention_Norm else null),
         Norm_Floor => Settings.Epsilon,
         Version   => (if Is_Mamba2 (Settings.Kind) then 2 else 1),
         Rank      => Settings.Time_Rank,
         X_Proj    => Current.Ssm_X,
         Dt_Up     => Current.Ssm_Dt,
         Dbc_Norm  => Current.Ssm_Dt_Norm /= null,
         Feed_Norm =>
           (if With_Norm and then Is_Jamba (Settings.Kind)
            then Current.Feed_Norm else null),
         Gate      => Current.Gate,
         Up        => Current.Up,
         Down      => Current.Down);
   end Mamba2_Block_Of;

   --  Whether a Mamba2 layer can go to the device whole: the device runs
   --  the mixer, the layer has its pack and a plain normalization, the
   --  shapes are the scan's, and the session keeps one state.
   function Mamba2_Fits (Item : Session; Current : Layer) return Boolean
   is ((Pure_SSM (Item.Owner.Settings.Kind)
        or else
          (Is_Jamba (Item.Owner.Settings.Kind)
           and then Current.Experts = null
           and then Current.Feed_Norm /= null
           and then Current.Feed_Norm_Bias = null
           and then T.Is_Present (Current.Gate)
           and then T.Is_Present (Current.Up)
           and then T.Is_Present (Current.Down)))
       and then Model_Runner.Backend."="
                  (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
       and then Current.Ssm_Pack /= null
       and then Current.Attention_Norm /= null
       and then Current.Attention_Norm_Bias = null
       and then Item.Kept_States = 0
       and then Item.Delta_State /= null
       and then Item.Conv_State /= null
       and then
         (if Is_Mamba2 (Item.Owner.Settings.Kind)
          then Item.Owner.Settings.Head_Dim
                 = Model_Runner.Backend.Device.Mamba2_Head
               and then Item.Owner.Settings.State_Size
                        = Model_Runner.Backend.Device.Mamba2_State
               and then Item.Owner.Settings.Ssm_Heads
                        * Item.Owner.Settings.Head_Dim
                        = Item.Owner.Settings.Inner_Size
               and then Model_Runner.Backend.Device.Runs_Mamba2
          else Item.Owner.Settings.State_Size
                 <= Model_Runner.Backend.Device.Mamba_Most_State
               and then Item.Owner.Settings.Time_Rank > 0
               and then (Is_Jamba (Item.Owner.Settings.Kind)
                         or else Current.Ssm_Dt_Norm = null)
               and then T.Is_Present (Current.Ssm_X)
               and then T.Is_Present (Current.Ssm_Dt)
               and then Model_Runner.Backend.Device.Runs_Mamba));

   --  Give a session a block of the device's cache, and keep it there.
   --
   --  A session takes the lowest free block the first time it writes to the
   --  device's cache and holds it while anything else can be given one.
   --  Nothing moves while a round forms -- not when its members change --
   --  which is what makes a round free to form: its rows read the blocks
   --  their sessions were already in.
   --
   --  Where every block is held, none is given: the session attends on the
   --  processor until a session holding one closes. Taking the block from
   --  the session gone longest unasked went out with the several-sequences
   --  server; one user does not open seventeen sessions.
   --
   --  @param Item The session.
   --  @param Ok True when the block is the session's and holds its cache.
   procedure Take_Block (Item : Session_Access; Ok : out Boolean);

   --  Read back whatever the device wrote that the host's copy has not
   --  got. Declared here because a session giving its block back must
   --  settle before the block goes; said where it is written, below.
   procedure Settle_Cache (Item : in out Session; Settled : out Boolean);

   --  The packed caches' layout, for the two precisions that pack: a row
   --  of Width elements takes Row_Bytes of the bytes and Blocks_Of scales,
   --  and an element -- numbered over the whole cache, a row after a row
   --  -- sits at Byte_Of, in the low half of its byte for an even offset
   --  in the row and the high half for an odd one where the cache is
   --  nibbles, with its scale at Scale_Of.
   Block : constant Element_Count := K.Nibble_Block;

   function Row_Bytes
     (Held : Cache_Precision; Width : Element_Count) return B.Byte_Count
   is (if Held = Fourth then B.Byte_Count ((Width + 1) / 2)
       else B.Byte_Count (Width));

   function Blocks_Of
     (Held : Cache_Precision; Width : Element_Count) return Element_Count
   is (if Held = Fourth then (Width + Block - 1) / Block else 1);

   function Byte_Of
     (Held : Cache_Precision; Element, Width : Element_Count) return B.Byte_Count
   is (if Held = Fourth
       then B.Byte_Count (Element / Width) * Row_Bytes (Held, Width)
            + B.Byte_Count ((Element mod Width) / 2)
       else B.Byte_Count (Element));

   function Scale_Of
     (Held : Cache_Precision; Element, Width : Element_Count) return Element_Count
   is (if Held = Fourth
       then (Element / Width) * Blocks_Of (Held, Width)
            + (Element mod Width) / Block
       else Element / Width);

   --  How a packed session's block is laid out in the device's cache, in
   --  words of four bytes from the block's base: the keys' bytes, the
   --  values' bytes, the key scales and the value scales, each a whole
   --  number of words along.
   type Packed_Block is record
      Key_Words       : Element_Count := 0;
      Value_Words     : Element_Count := 0;

      --  Where each region begins, in words from the block's base: the
      --  keys at nought, the values after the keys' words -- which are
      --  not the values' where the two sides are stored differently --
      --  and the scales after both.
      Values_At       : Element_Count := 0;
      Key_Scales_At   : Element_Count := 0;
      Value_Scales_At : Element_Count := 0;
      Span            : Element_Count := 0;
   end record;

   --  The most positions any layer holds.
   function Widest_Cells (Cells : Cell_Counts) return Element_Count is
      Most : Element_Count := 0;
   begin
      for Held of Cells loop
         Most := Element_Count'Max (Most, Held);
      end loop;
      return Most;
   end Widest_Cells;

   function Packed_Layout (Item : Session) return Packed_Block is
      Key_Words : constant Element_Count :=
        (if Item.Byte_Keys = null then 0
         else (Element_Count (Item.Byte_Keys.all'Length) + 3) / 4);
      Value_Words : constant Element_Count :=
        (if Item.Byte_Values = null then 0
         else (Element_Count (Item.Byte_Values.all'Length) + 3) / 4);
      Key_Scales : constant Element_Count :=
        (if Item.Key_Scales = null then 0 else Item.Key_Scales.all'Length);
      Value_Scales : constant Element_Count :=
        (if Item.Value_Scales = null then 0 else Item.Value_Scales.all'Length);

      --  And room enough that one layer's rows unpack into the block's
      --  own half-precision copy for the matrix attention. The copy is
      --  as many halves as the block is words; a layer's rows in halves
      --  are a fraction of a block that holds every layer's in bytes or
      --  nibbles, so they fit where the model has four layers or more in
      --  bytes and eight in nibbles, and a shallower model's block is
      --  padded out to the deepest layer's rows -- a fraction of a layer
      --  the model has not got, on a model small enough not to mind. The
      --  unpacking counts against this span before it asks.
      Halves : constant Element_Count :=
        (if Item.Owner = null or else Item.Cells = null then 0
         else Element_Count
                (Item.Owner.Settings.KV_Heads
                 * (Item.Owner.Settings.Head_Size
                    + Item.Owner.Settings.Value_Size))
              * Widest_Cells (Item.Cells.all));
   begin
      return (Key_Words       => Key_Words,
              Value_Words     => Value_Words,
              Values_At       => Key_Words,
              Key_Scales_At   => Key_Words + Value_Words,
              Value_Scales_At => Key_Words + Value_Words + Key_Scales,
              Span            =>
                Element_Count'Max
                  (Key_Words + Value_Words + Key_Scales + Value_Scales,
                   Halves));
   end Packed_Layout;

   --  How a packed session's page is laid out, in words of four bytes from
   --  the page's base -- the region-major page the paged packed kernels
   --  read. It is Packed_Layout at one page's worth of positions rather
   --  than the whole block, and it holds no half-precision copy: the copy
   --  a packed session unpacks into is the block's front, nobody's while
   --  the block is packed, and a page keeps only its four regions -- the
   --  keys' bytes, the values' bytes, the key scales and the value scales,
   --  each a whole number of words along, a position's row at its place
   --  inside the region. The keys and the values may hold different
   --  storages, so each region is sized by its own.
   function Packed_Page_Layout (Item : Session) return Packed_Block is
      KV_Width : constant Element_Count :=
        Element_Count (Item.Owner.Settings.KV_Heads
                       * Item.Owner.Settings.Head_Size);
      V_Width  : constant Element_Count :=
        Element_Count (Item.Owner.Settings.KV_Heads
                       * Item.Owner.Settings.Value_Size);
      Rows : constant Element_Count := Element_Count (Page_Positions);

      Key_Words : constant Element_Count :=
        (Rows * Element_Count (Row_Bytes (Item.Held, KV_Width)) + 3) / 4;
      Value_Words : constant Element_Count :=
        (Rows * Element_Count (Row_Bytes (Item.Held_Values, V_Width)) + 3) / 4;
      Key_Scales : constant Element_Count :=
        Rows * Blocks_Of (Item.Held, KV_Width);
      Value_Scales : constant Element_Count :=
        Rows * Blocks_Of (Item.Held_Values, V_Width);
   begin
      return (Key_Words       => Key_Words,
              Value_Words     => Value_Words,
              Values_At       => Key_Words,
              Key_Scales_At   => Key_Words + Value_Words,
              Value_Scales_At => Key_Words + Value_Words + Key_Scales,
              Span            =>
                Key_Words + Value_Words + Key_Scales + Value_Scales);
   end Packed_Page_Layout;

   --  How wide a session's block is, in elements: the exact cache's keys
   --  and values, or the packed cache's words.
   function Block_Span_Of (Item : Session) return Element_Count
   is (if Item.Held = Exact
       then (if Item.Keys = null or else Item.Values = null then 0
             else Item.Keys.all'Length + Item.Values.all'Length)
       elsif Item.Held in Eighth | Fourth then Packed_Layout (Item).Span
       else 0);

   --  How far into a session's block a half of an element is read, in
   --  elements from the block's base.
   --
   --  An exact session's block has a half of every element of it: the
   --  step that places a position writes both, and the matrix attention
   --  reads the halves. A packed session's block has no copy of itself --
   --  its keys and values are bytes or nibbles already -- and what it
   --  uses the copy for is the room a layer's rows unpack into for that
   --  same instruction, which is at the block's front and a fraction of
   --  it. A cache dealt to packed sessions used to keep two bytes for
   --  every element of every block, for elements no kernel would read a
   --  half of.
   function Copy_Span_Of (Item : Session) return Element_Count
   is (if Item.Held = Exact then Block_Span_Of (Item)
       elsif Item.Held in Eighth | Fourth
       then Element_Count
              (Item.Owner.Settings.KV_Heads
               * (Item.Owner.Settings.Head_Size
                  + Item.Owner.Settings.Value_Size))
            * (if Item.Cells = null then 0 else Widest_Cells (Item.Cells.all))
       else 0);

   ------------------
   -- Context_Room --
   ------------------

   -----------------
   -- Device_Room --
   -----------------

   procedure Device_Room
     (Item  : Session;
      Why   : out Device_Limit;
      Asked : out Interfaces.Unsigned_64;
      Kept  : out Interfaces.Unsigned_64)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      Why := Device_Takes_All;
      Asked := 0;
      Kept := 0;

      if Item.Owner = null
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
      then
         return;
      end if;

      --  A model without an attention layer -- Mamba, Mamba2, RWKV6 -- has
      --  no heads for the device to keep room for; its head width is its
      --  model width, which said it attended on the processor when it
      --  attends nowhere.
      if (for all Index in 0 .. Item.Owner.Settings.Layers - 1 =>
            Linear (Item.Owner.Settings, Index))
      then
         return;
      end if;

      declare
         Settings : Configuration renames Item.Owner.Settings;

         Head_Size  : constant Natural := Settings.Head_Size;
         Value_Size : constant Natural := Settings.Value_Size;

         Room : constant Natural :=
           Model_Runner.Backend.Device.Attention_Head_Room;

         --  Where the model learned no sinks the device keeps only the
         --  half-precision copy -- two bytes an element, not the cache
         --  proper's four -- and past what one buffer holds it keeps the
         --  copy in two, so what a buffer must hold is a half, not the
         --  whole. The cache proper is on the host and bounded there.
         --  Counting the copy, and a half of it where it splits, is what
         --  lets a sinkless model attend on the device at a context the
         --  cache proper would not fit; the reserve is the real guard on
         --  each buffer.
         Sinkless : constant Boolean :=
           Sink_Footprint (Item.Owner.Settings) = 0;

         Bound : constant Interfaces.Unsigned_64 :=
           Model_Runner.Backend.Device.Cache_Bound;

         Copy_Bytes : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64
             (Block_Span_Of (Item)
              + Element_Count (Model_Runner.Backend.Device.Table_Room)) * 2;

         Wanted : constant Interfaces.Unsigned_64 :=
           (if not Sinkless
            then Model_Runner.Backend.Device.Cache_Bytes_For
                   (Block_Span_Of (Item)
                    + Element_Count (Model_Runner.Backend.Device.Table_Room)
                    + Sink_Footprint (Item.Owner.Settings))
            elsif Bound > 0 and then Copy_Bytes > Bound
            then (Copy_Bytes + 1) / 2
            else Copy_Bytes);
      begin
         --  A head wider than the room a kernel keeps is attended on the
         --  processor whatever the cache holds, so it is asked first and
         --  the rest is not asked at all.
         if Room > 0
           and then (Head_Size > Room or else Value_Size > Room)
         then
            Why := Heads_Past_Room;
            Asked := Interfaces.Unsigned_64 (Natural'Max (Head_Size, Value_Size));
            Kept := Interfaces.Unsigned_64 (Room);
            return;
         end if;

         --  Then the packed kernel's own rule, for a session that packs.
         if Item.Held in Eighth | Fourth
           and then not Model_Runner.Backend.Device.Attends_Packed_Heads
                          (Head_Size, Value_Size)
         then
            Why := Packed_Heads_Unread;
            Asked := Interfaces.Unsigned_64 (Head_Size);
            Kept := Interfaces.Unsigned_64 (Value_Size);
            return;
         end if;

         --  Then the size rather than the shape.
         if Bound > 0 and then Wanted > Bound then
            Why := Context_Past_Bound;
            Asked := Wanted;
            Kept := Bound;
            return;
         end if;

         --  And last, the one that is neither: every block held by
         --  another session.
         --  Said only of a session that holds none itself, and true only
         --  of this moment -- a block given back is a block this session
         --  may have.
         if Item.Seat < 0
           and then Blocks_Held = Model_Runner.Backend.Device.Block_Limit
         then
            Why := Blocks_All_Held;
            Asked := Interfaces.Unsigned_64 (Blocks_Held);
            Kept := Interfaces.Unsigned_64
                      (Model_Runner.Backend.Device.Block_Limit);
         end if;
      end;
   end Device_Room;

   --  Write what the host holds of a session's cache into the block at
   --  Base, and only where it has committed something: a session with
   --  nothing committed has nothing to preserve, and a block it is taking
   --  for the first time was zeroed when the buffer was made.
   --
   --  A layer at a time, and only the cells it has written. The whole
   --  array in two writes was the shape of the cache rather than the shape
   --  of what is in it: a session of a 2,048-token context that has said
   --  twelve tokens holds twelve cells of every layer and forty-six
   --  megabytes of room for them, and the rest of it is the zeros the
   --  block already has. A layer holds its cells from the lowest position
   --  it still has, which a window slides forward, so what is written is
   --  that run.
   --
   --  Said where a session takes a block and where one it holds is moved,
   --  which is the same writing to the same end.
   --
   --  @param Item The session.
   --  @param Base Where its block begins, in elements.
   --  @param Written True when everything went.
   procedure Write_Block
     (Item : Session_Access; Base : Element_Count; Written : out Boolean) is
   begin
      Written := True;

      if Item.Committed = 0 then
         return;
      end if;

      if Item.Held = Exact then
         declare
            Settings : Configuration renames Item.Owner.Settings;

            KV_Width : constant Element_Count :=
              Element_Count (Settings.KV_Heads * Settings.Head_Size);
            V_Width  : constant Element_Count :=
              Element_Count (Settings.KV_Heads * Settings.Value_Size);

            Layers : constant Natural :=
              (if Item.Cells = null then 0 else Item.Cells.all'Length);
         begin
            for Layer in 0 .. Layers - 1 loop
               declare
                  Held : constant Element_Count :=
                    Element_Count'Min
                      (Item.Cells.all (Layer),
                       Cell_Of (Item.all, Layer,
                                Element_Count (Item.Committed)));
               begin
                  if Written and then Held > 0 then
                     Model_Runner.Backend.Device.Put_Cache
                       (Base + Keys_At (Item.all, Layer),
                        Item.Keys.all
                          (Keys_At (Item.all, Layer)
                           .. Keys_At (Item.all, Layer)
                              + Held * KV_Width - 1),
                        Written);
                  end if;

                  if Written and then Held > 0 then
                     Model_Runner.Backend.Device.Put_Cache
                       (Base + Item.Keys.all'Length
                        + Values_At (Item.all, Layer),
                        Item.Values.all
                          (Values_At (Item.all, Layer)
                           .. Values_At (Item.all, Layer)
                              + Held * V_Width - 1),
                        Written);
                  end if;
               end;
            end loop;
         end;
      else
         --  A packed session's block: its bytes as they are, and its
         --  scales as floats, each where Packed_Block says.
         declare
            Laid : constant Packed_Block := Packed_Layout (Item.all);
         begin
            Model_Runner.Backend.Device.Put_Cache_Bytes
              (Interfaces.Unsigned_64 (Base) * 4, Item.Byte_Keys.all,
               Written);
            if Written then
               Model_Runner.Backend.Device.Put_Cache_Bytes
                 (Interfaces.Unsigned_64 (Base + Laid.Values_At) * 4,
                  Item.Byte_Values.all, Written);
            end if;
            if Written then
               Model_Runner.Backend.Device.Put_Cache
                 (Base + Laid.Key_Scales_At, Item.Key_Scales.all, Written);
            end if;
            if Written then
               Model_Runner.Backend.Device.Put_Cache
                 (Base + Laid.Value_Scales_At, Item.Value_Scales.all,
                  Written);
            end if;
         end;
      end if;
   end Write_Block;

   --  The first place in the buffer a block of Span elements fits: from
   --  the front, past every block held that overlaps, until nothing does.
   function First_Block_Gap (Span : Element_Count) return Element_Count is
      Base : Element_Count := 0;
   begin
      loop
         declare
            Moved : Boolean := False;
         begin
            for Which in Block_Holder'Range loop
               declare
                  Other : constant Session_Access := Block_Holder (Which);
               begin
                  if Other /= null
                    and then Base < Other.Cache_Base
                                    + Block_Span_Of (Other.all)
                    and then Other.Cache_Base < Base + Span
                  then
                     Base :=
                       (Other.Cache_Base + Block_Span_Of (Other.all)
                        + Block_Alignment - 1)
                       / Block_Alignment * Block_Alignment;
                     Moved := True;
                  end if;
               end;
            end loop;
            exit when not Moved;
         end;
      end loop;

      return Base;
   end First_Block_Gap;

   --  How many layers hold cells of a session's cache, which is how many
   --  runs of keys and values a move of its block has at most.
   function Block_Layers (Item : Session) return Natural
   is (if Item.Cells = null then 0 else Item.Cells.all'Length);

   --  Which stretches of a session's block hold anything, counted from
   --  the block's base: the cells each layer has written, keys and values
   --  apart, for an exact session; the whole of a packed one, whose bytes
   --  and scales are laid out as the host lays its own and whose unused
   --  room is a fraction of what an exact block's is.
   --
   --  @param Item The session.
   --  @param Runs Receives them.
   --  @param Last How many were written.
   procedure Held_Runs
     (Item : Session_Access;
      Runs : out Model_Runner.Backend.Device.Block_Runs;
      Last : out Natural) is
   begin
      Last := 0;

      if Item.Held /= Exact or else Item.Committed = 0 then
         Last := 1;
         Runs (1) := (At_Value => 0, Count => Block_Span_Of (Item.all));
         return;
      end if;

      declare
         Settings : Configuration renames Item.Owner.Settings;

         KV_Width : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Head_Size);
         V_Width  : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Value_Size);
      begin
         for Layer in 0 .. Block_Layers (Item.all) - 1 loop
            declare
               Held : constant Element_Count :=
                 Element_Count'Min
                   (Item.Cells.all (Layer),
                    Cell_Of (Item.all, Layer,
                             Element_Count (Item.Committed)));
            begin
               if Held > 0 then
                  Last := Last + 1;
                  Runs (Last) :=
                    (At_Value => Keys_At (Item.all, Layer),
                     Count    => Held * KV_Width);

                  Last := Last + 1;
                  Runs (Last) :=
                    (At_Value =>
                       Item.Keys.all'Length + Values_At (Item.all, Layer),
                     Count    => Held * V_Width);
               end if;
            end;
         end loop;
      end;

      --  A session that has committed something but holds no cell of any
      --  layer -- a window that has slid past everything -- moves nothing.
      if Last = 0 then
         Last := 1;
         Runs (1) := (At_Value => 0, Count => 0);
      end if;
   end Held_Runs;

   --  Move blocks to the front until one of Span fits below where the
   --  buffer has already been dealt to, or until nothing is left to move.
   --
   --  Blocks are the size of the sessions in them and are given back in
   --  whatever order those sessions close, so a block given up between two
   --  others leaves a gap a larger block cannot use. Without this the
   --  buffer grew at the end for every one of those and shrank only when
   --  the last block went.
   --
   --  A block moved is the session's cache written again where it now is --
   --  what a session turned out of a block pays anyway -- so the blocks are
   --  moved in order from the front and the walk stops at the first one
   --  that makes the room. Moving every block would settle and rewrite
   --  sixteen caches to seat one session.
   --
   --  @param Span What the asking session needs room for.
   --  @param Ok False where a block could not be settled or written, in
   --    which case it is still where the host's copy says it is.
   procedure Compact_Blocks (Span : Element_Count; Ok : out Boolean) is
      Place : Element_Count := 0;
   begin
      Ok := True;

      --  In order of where they sit, which is the order that packs them.
      loop
         declare
            Next  : Session_Access := null;
            Where : Element_Count := 0;
         begin
            --  The lowest block not yet packed.
            for Which in Block_Holder'Range loop
               declare
                  Other : constant Session_Access := Block_Holder (Which);
               begin
                  if Other /= null and then Other.Cache_Base >= Place
                    and then (Next = null or else Other.Cache_Base < Where)
                  then
                     Next  := Other;
                     Where := Other.Cache_Base;
                  end if;
               end;
            end loop;

            exit when Next = null;

            if Where > Place then
               --  Moved where it lies. The host's copy is not read and
               --  not written: what the device holds of that session --
               --  including the positions it owes the host's copy, which
               --  had to be read back before the block could be written
               --  from the host -- goes down with the block.
               --
               --  And only the cells the session has written, a layer at
               --  a time, as the write from the host was: the rest of a
               --  block is the zeros it was made with, and at a long
               --  context that is most of it.
               declare
                  Went : Boolean;
                  Runs : Model_Runner.Backend.Device.Block_Runs
                           (1 .. 2 * Block_Layers (Next.all) + 1);
                  Last : Natural := 0;
               begin
                  Held_Runs (Next, Runs, Last);

                  Model_Runner.Backend.Device.Move_Cache
                    (From   => Where,
                     Into   => Place,
                     Runs   => Runs (1 .. Last),
                     Halves => Next.Held = Exact,
                     Ok     => Went);

                  if not Went then
                     Ok := False;
                     return;
                  end if;
               end;

               Next.Cache_Base := Place;

               Model_Runner.Backend.Device.Note_Moved;
            end if;

            Place :=
              (Place + Block_Span_Of (Next.all) + Block_Alignment - 1)
              / Block_Alignment * Block_Alignment;

            --  Enough moved: the asking session fits in what the packing
            --  has opened up, and the rest may stay where they are.
            exit when First_Block_Gap (Span) + Span <= Block_Taken;
         end;
      end loop;

      --  What the table sits past, which packing may have brought down.
      Block_Taken := 0;

      for Which in Block_Holder'Range loop
         if Block_Holder (Which) /= null then
            Block_Taken :=
              Element_Count'Max
                (Block_Taken,
                 Block_Holder (Which).Cache_Base
                 + Block_Span_Of (Block_Holder (Which).all));
         end if;
      end loop;
   end Compact_Blocks;

   procedure Take_Block (Item : Session_Access; Ok : out Boolean)
   is separate;

   ----------------
   -- Take_Pages --
   ----------------

   --  Write a layer's committed keys and values into the pages it holds,
   --  a page at a time: the host copy carried into a session's pages when
   --  it is given them, as Write_Block does for a block. Position P of the
   --  layer sits at cell P - Origin, in page (cell / Page_Positions) at
   --  (cell mod Page_Positions) inside it, the keys at the page's front
   --  and the values a run of keys in.
   procedure Write_Pages_Layer
     (Item     : Session;
      Layer    : Natural;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Upto     : Element_Count;
      Written  : out Boolean)
   is
      Cells : constant Element_Count := Cell_Of (Item, Layer, Upto);
      First : constant Element_Count := Item.Page_First.all (Layer);

      Keys_Base : constant Element_Count := Keys_At (Item, Layer);
      Vals_Base : constant Element_Count := Values_At (Item, Layer);
   begin
      Written := True;

      --  A layer that holds no cell of the committed range -- a window
      --  layer whose origin has caught up with the position it is asked
      --  about -- writes nothing rather than counting from cell minus one.
      if Cells = 0 then
         return;
      end if;

      for Page in 0 .. Natural (Cells - 1) / Page_Positions loop
         declare
            Low  : constant Element_Count :=
              Element_Count (Page) * Element_Count (Page_Positions);
            Span : constant Element_Count :=
              Element_Count'Min (Element_Count (Page_Positions), Cells - Low);
            Base : constant Element_Count :=
              Item.Pages.all (Natural (First) + Page);
         begin
            Model_Runner.Backend.Device.Put_Cache
              (Base,
               Item.Keys.all
                 (Keys_Base + Low * KV_Width
                  .. Keys_Base + (Low + Span) * KV_Width - 1),
               Written);

            if Written then
               Model_Runner.Backend.Device.Put_Cache
                 (Base + Element_Count (Page_Positions) * KV_Width,
                  Item.Values.all
                    (Vals_Base + Low * V_Width
                     .. Vals_Base + (Low + Span) * V_Width - 1),
                  Written);
            end if;

            exit when not Written;
         end;
      end loop;
   end Write_Pages_Layer;

   --  Read a layer's cells [From, From + Span) back out of the pages they
   --  are scattered through, into the host's contiguous copy: what
   --  Settle_Cache does for a block by reading from its base, done a page
   --  at a time because a paged layer's positions are not one run on the
   --  device. A cell's page is From / Page_Positions and its place inside
   --  it the remainder; a run of cells that crosses a page boundary is
   --  read as the two pages it lies in.
   procedure Read_Pages_Layer
     (Item     : in out Session;
      Layer    : Natural;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      From     : Element_Count;
      Span     : Element_Count;
      Read     : out Boolean)
   is
      First : constant Element_Count := Item.Page_First.all (Layer);

      Keys_Base : constant Element_Count := Keys_At (Item, Layer);
      Vals_Base : constant Element_Count := Values_At (Item, Layer);

      P : constant Element_Count := Element_Count (Page_Positions);
   begin
      Read := True;

      --  Nothing owed is nothing to read, and counting to From plus span
      --  less one would go below zero.
      if Span = 0 then
         return;
      end if;

      for Page in Natural (From / P) .. Natural ((From + Span - 1) / P) loop
         declare
            Low   : constant Element_Count := Element_Count (Page) * P;
            Lo    : constant Element_Count := Element_Count'Max (Low, From);
            Hi    : constant Element_Count :=
              Element_Count'Min (Low + P, From + Span);
            Count : constant Element_Count := Hi - Lo;
            Base  : constant Element_Count :=
              Item.Pages.all (Natural (First) + Page);
         begin
            Model_Runner.Backend.Device.Get_Cache
              (Base + (Lo - Low) * KV_Width,
               Item.Keys.all
                 (Keys_Base + Lo * KV_Width
                  .. Keys_Base + (Lo + Count) * KV_Width - 1),
               Read);

            if Read then
               Model_Runner.Backend.Device.Get_Cache
                 (Base + P * KV_Width + (Lo - Low) * V_Width,
                  Item.Values.all
                    (Vals_Base + Lo * V_Width
                     .. Vals_Base + (Lo + Count) * V_Width - 1),
                  Read);
            end if;

            exit when not Read;
         end;
      end loop;
   end Read_Pages_Layer;

   --  Write a packed layer's committed rows into the pages it holds, the
   --  packed analog of Write_Pages_Layer: a page holds Page_Positions rows
   --  of packed keys and values and their scales, region by region, and the
   --  host keeps the same bytes and scales -- the block's read back, or
   --  packed on the host -- laid contiguously a layer at a time. A page's
   --  rows are a contiguous run of the host's, since the page begins on a
   --  page boundary; the byte and scale offsets are Byte_Of and Scale_Of,
   --  as Read_Back_Packed has them for a block.
   procedure Write_Packed_Pages_Layer
     (Item     : Session;
      Layer    : Natural;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Upto     : Element_Count;
      Written  : out Boolean)
   is
      Cells  : constant Element_Count := Cell_Of (Item, Layer, Upto);
      First  : constant Element_Count := Item.Page_First.all (Layer);
      Held   : constant Cache_Precision := Item.Held;
      V_Held : constant Cache_Precision := Item.Held_Values;
      PL     : constant Packed_Block := Packed_Page_Layout (Item);
      K_El   : constant Element_Count := Keys_At (Item, Layer);
      V_El   : constant Element_Count := Values_At (Item, Layer);
      K_Row  : constant B.Byte_Count := Row_Bytes (Held, KV_Width);
      V_Row  : constant B.Byte_Count := Row_Bytes (V_Held, V_Width);
      K_Blk  : constant Element_Count := Blocks_Of (Held, KV_Width);
      V_Blk  : constant Element_Count := Blocks_Of (V_Held, V_Width);
   begin
      Written := True;
      if Cells = 0 then
         return;
      end if;

      for Page in 0 .. Natural (Cells - 1) / Page_Positions loop
         declare
            Low  : constant Element_Count :=
              Element_Count (Page) * Element_Count (Page_Positions);
            Span : constant Element_Count :=
              Element_Count'Min (Element_Count (Page_Positions), Cells - Low);
            Base : constant Element_Count :=
              Item.Pages.all (Natural (First) + Page);
            K_By : constant B.Byte_Count :=
              Byte_Of (Held, K_El + Low * KV_Width, KV_Width);
            V_By : constant B.Byte_Count :=
              Byte_Of (V_Held, V_El + Low * V_Width, V_Width);
            K_Sc : constant Element_Count :=
              Scale_Of (Held, K_El + Low * KV_Width, KV_Width);
            V_Sc : constant Element_Count :=
              Scale_Of (V_Held, V_El + Low * V_Width, V_Width);
         begin
            Model_Runner.Backend.Device.Put_Cache_Bytes
              (Interfaces.Unsigned_64 (Base) * 4,
               Item.Byte_Keys.all
                 (K_By .. K_By + B.Byte_Count (Span) * K_Row - 1),
               Written);
            if Written then
               Model_Runner.Backend.Device.Put_Cache_Bytes
                 (Interfaces.Unsigned_64 (Base + PL.Values_At) * 4,
                  Item.Byte_Values.all
                    (V_By .. V_By + B.Byte_Count (Span) * V_Row - 1),
                  Written);
            end if;
            if Written then
               Model_Runner.Backend.Device.Put_Cache
                 (Base + PL.Key_Scales_At,
                  Item.Key_Scales.all (K_Sc .. K_Sc + Span * K_Blk - 1),
                  Written);
            end if;
            if Written then
               Model_Runner.Backend.Device.Put_Cache
                 (Base + PL.Value_Scales_At,
                  Item.Value_Scales.all (V_Sc .. V_Sc + Span * V_Blk - 1),
                  Written);
            end if;

            exit when not Written;
         end;
      end loop;
   end Write_Packed_Pages_Layer;

   --  Read a packed layer's cells [From, From + Span) back out of their
   --  pages into the host's packed copy, the packed analog of
   --  Read_Pages_Layer: a run that crosses a page boundary is read as the
   --  pages it lies in, and a page's own run at the offset inside it.
   procedure Read_Packed_Pages_Layer
     (Item     : in out Session;
      Layer    : Natural;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      From     : Element_Count;
      Span     : Element_Count;
      Read     : out Boolean)
   is
      First  : constant Element_Count := Item.Page_First.all (Layer);
      Held   : constant Cache_Precision := Item.Held;
      V_Held : constant Cache_Precision := Item.Held_Values;
      PL     : constant Packed_Block := Packed_Page_Layout (Item);
      K_El   : constant Element_Count := Keys_At (Item, Layer);
      V_El   : constant Element_Count := Values_At (Item, Layer);
      K_Row  : constant B.Byte_Count := Row_Bytes (Held, KV_Width);
      V_Row  : constant B.Byte_Count := Row_Bytes (V_Held, V_Width);
      K_Blk  : constant Element_Count := Blocks_Of (Held, KV_Width);
      V_Blk  : constant Element_Count := Blocks_Of (V_Held, V_Width);
      P      : constant Element_Count := Element_Count (Page_Positions);
   begin
      Read := True;
      if Span = 0 then
         return;
      end if;

      for Page in Natural (From / P) .. Natural ((From + Span - 1) / P) loop
         declare
            Low   : constant Element_Count := Element_Count (Page) * P;
            Lo    : constant Element_Count := Element_Count'Max (Low, From);
            Hi    : constant Element_Count :=
              Element_Count'Min (Low + P, From + Span);
            Count : constant Element_Count := Hi - Lo;
            Base  : constant Element_Count :=
              Item.Pages.all (Natural (First) + Page);
            In_K  : constant B.Byte_Count := B.Byte_Count (Lo - Low) * K_Row;
            In_V  : constant B.Byte_Count := B.Byte_Count (Lo - Low) * V_Row;
            K_By  : constant B.Byte_Count :=
              Byte_Of (Held, K_El + Lo * KV_Width, KV_Width);
            V_By  : constant B.Byte_Count :=
              Byte_Of (V_Held, V_El + Lo * V_Width, V_Width);
            K_Sc  : constant Element_Count :=
              Scale_Of (Held, K_El + Lo * KV_Width, KV_Width);
            V_Sc  : constant Element_Count :=
              Scale_Of (V_Held, V_El + Lo * V_Width, V_Width);
         begin
            Model_Runner.Backend.Device.Get_Cache_Bytes
              (Interfaces.Unsigned_64 (Base) * 4 + Interfaces.Unsigned_64 (In_K),
               Item.Byte_Keys.all
                 (K_By .. K_By + B.Byte_Count (Count) * K_Row - 1),
               Read);
            if Read then
               Model_Runner.Backend.Device.Get_Cache_Bytes
                 (Interfaces.Unsigned_64 (Base + PL.Values_At) * 4
                  + Interfaces.Unsigned_64 (In_V),
                  Item.Byte_Values.all
                    (V_By .. V_By + B.Byte_Count (Count) * V_Row - 1),
                  Read);
            end if;
            if Read then
               Model_Runner.Backend.Device.Get_Cache
                 (Base + PL.Key_Scales_At + (Lo - Low) * K_Blk,
                  Item.Key_Scales.all (K_Sc .. K_Sc + Count * K_Blk - 1),
                  Read);
            end if;
            if Read then
               Model_Runner.Backend.Device.Get_Cache
                 (Base + PL.Value_Scales_At + (Lo - Low) * V_Blk,
                  Item.Value_Scales.all (V_Sc .. V_Sc + Count * V_Blk - 1),
                  Read);
            end if;

            exit when not Read;
         end;
      end loop;
   end Read_Packed_Pages_Layer;

   --  A page of one layer, in elements: the positions it holds times a
   --  row of keys and a row of values.
   function Page_Row (Item : Session) return Element_Count
   is (Element_Count
         (Item.Owner.Settings.KV_Heads
          * (Item.Owner.Settings.Head_Size
             + Item.Owner.Settings.Value_Size)));

   --  Give every page a session holds back to the pool: its slots freed,
   --  the count of pages in use brought down, and where the buffer has been
   --  dealt recomputed to the pages that are left. Not cleared: a slot
   --  taken again is written over. What a session closing and a session
   --  turned out both do, so that the pool's count -- Page_Owner,
   --  Pages_In_Use, Pages_Taken kept in step -- is dealt with in one place
   --  and cannot drift between the two.
   procedure Release_Session_Pages (Item : Session_Access) is
   begin
      if Item.Page_Count = null or else Page_Elements = 0 then
         return;
      end if;

      --  Only the pages the session was dealt, which its Page_Count says a
      --  layer at a time -- not every entry of Pages, most of which a
      --  session that filled a fraction of its context never took.
      for Layer in Item.Page_Count.all'Range loop
         for Page in 0 .. Natural (Item.Page_Count.all (Layer)) - 1 loop
            declare
               Slot : constant Natural :=
                 Natural
                   ((Item.Pages.all
                       (Natural (Item.Page_First.all (Layer)) + Page)
                     - Page_Front)
                    / Page_Elements);
            begin
               if Slot in Page_Owner'Range
                 and then Page_Owner (Slot) = Item
               then
                  Page_Owner (Slot) := null;
                  if Pages_In_Use > 0 then
                     Pages_In_Use := Pages_In_Use - 1;
                  end if;
               end if;
            end;
         end loop;
      end loop;

      Item.Page_Count.all := [others => 0];
      Item.Paged_In := False;
      Item.Paged_Upto := 0;

      Pages_Taken := 0;
      for Slot in Page_Owner'Range loop
         if Page_Owner (Slot) /= null then
            Pages_Taken :=
              Element_Count'Max
                (Pages_Taken,
                 Page_Front + Element_Count (Slot + 1) * Page_Elements);
         end if;
      end loop;
   end Release_Session_Pages;

   --  Turn a paged session out: its host copy settled, then its pages
   --  given back.
   --
   --  What turning a paged session out costs: its scattered pages read into
   --  the host's copy -- which, the session mirroring, is already there --
   --  and then let go, so the slots are free for the session that asked.
   --  The session come back re-takes pages and writes its committed cache
   --  into them, a layer at a time, as it did the first time. A settle that
   --  cannot finish leaves the pages where they are, so nothing is lost.
   --  How many pages a layer holds once its cells reach Upto: the cells a
   --  position at index Upto sits at, rounded up to the page, and never
   --  more than the layer's whole context. A window layer holds fewer
   --  than a layer that keeps everything.
   function Pages_Wanted
     (Item : Session; Layer : Natural; Upto : Element_Count)
      return Element_Count
   is
      Cells : constant Element_Count :=
        Element_Count'Min
          (Cell_Of (Item, Layer, Upto) + 1,
           (if Item.Cells = null then 0 else Item.Cells.all (Layer)));
   begin
      return
        (Cells + Element_Count (Page_Positions) - 1)
        / Element_Count (Page_Positions);
   end Pages_Wanted;

   --  Give a paged session the pages it needs to hold positions up to Upto,
   --  taking each at the first free slot -- and no more, so a session holds
   --  as many pages as it has filled rather than as many as its context
   --  could hold. A block is taken once and is a session's whole context; a
   --  page is taken here the first time a position reaches it.
   --
   --  Called every layer with the highest position this pass will write.
   --  The pages a layer already holds are left where they are; only the
   --  ones a new position has just reached are dealt, at the front, past
   --  every slot held. What was committed before -- a session evicted and
   --  come back -- is written into the pages it is given again.
   procedure Take_Pages
     (Item         : Session_Access;
      Upto         : Element_Count;
      Ok           : out Boolean;
      Write_Tables : Boolean := True)
   is separate;

   -------------------
   -- Reserve_Ahead --
   -------------------

   procedure Reserve_Ahead (Item : in out Session; Upto : Natural) is
      Dealt : Boolean;
   begin
      if Upto = 0 or else Upto >= Capacity (Item) then
         return;
      end if;
      Take_Pages (Item'Unchecked_Access, Element_Count (Upto), Dealt);
      pragma Unreferenced (Dealt);
   end Reserve_Ahead;

   --  Where a page's values begin inside it: after its positions' keys.
   function Page_Value_Base (Item : Session) return Element_Count
   is (Element_Count (Page_Positions)
       * Element_Count (Item.Owner.Settings.KV_Heads
                        * Item.Owner.Settings.Head_Size));

   ------------------
   -- Holds_Block --
   ------------------

   --  A session's seat is set to minus one wherever its block is taken
   --  away -- at its close, and where another session turns it out -- so
   --  holding one is holding a number.
   function Holds_Block (Item : Session) return Boolean
   is (Item.Seat >= 0);

   function Holds_Pages (Item : Session) return Boolean
   is (Item.Paged_In);

   function Holds_Seat (Item : Session) return Boolean
   is (Item.State_Seated);

   -----------------
   -- Blocks_Held --
   -----------------

   function Blocks_Held return Natural is
      Held : Natural := 0;
   begin
      for Which in Block_Holder'Range loop
         if Block_Holder (Which) /= null then
            Held := Held + 1;
         end if;
      end loop;

      return Held;
   end Blocks_Held;

   function Pages_Held return Natural is
      Held : Natural := 0;
   begin
      for Slot in Page_Owner'Range loop
         if Page_Owner (Slot) /= null then
            Held := Held + 1;
         end if;
      end loop;

      return Held;
   end Pages_Held;

   procedure Set_Page_Size (Positions : Positive) is
      Bits : Natural := 0;
      N    : Positive := Positions;
   begin
      --  Refused while any page is held: the pool serves one page size at
      --  a time, since a slot the owner array counts is that size and a
      --  base divides back to a slot by it. And refused for a size that is
      --  not a power of two of at least sixteen: the kernels read a page
      --  and a place inside it by a shift and a mask, and a tile of the
      --  matrix instruction, sixteen wide, must not straddle a page.
      if Pages_In_Use > 0 or else Positions < 16 then
         return;
      end if;

      while N > 1 and then N mod 2 = 0 loop
         N := N / 2;
         Bits := Bits + 1;
      end loop;

      if N /= 1 then
         return;
      end if;

      Page_Positions  := Positions;
      Page_Shift_Bits := Bits;

      --  The page's element count is worked out afresh from the new size
      --  when the next session takes its first page.
      Page_Elements := 0;
   end Set_Page_Size;

   function Seats_Held return Natural is
      Held : Natural := 0;
   begin
      for Seat in State_Seats'Range loop
         if State_Seats (Seat) /= null then
            Held := Held + 1;
         end if;
      end loop;

      return Held;
   end Seats_Held;

   --  Where a layer's sinks sit, in elements: after the table. Zero where
   --  the cache holds no block yet.
   function Sinks_Room_At return Element_Count
   is (if Block_Taken > 0
       then Block_Taken + Element_Count (Model_Runner.Backend.Device.Table_Room)
       else 0);

   --  Whether a layer's sinks can go to the device: the layer has them and
   --  the cache holds a slot for them at this layer's place, which is the
   --  room past the table divided into one span of heads a layer.
   --
   --  @param Sinks The layer's sinks, or null.
   --  @param Layer Which layer, so its slot falls after the earlier ones'.
   --  @return True where Sinks_Ready would put them.
   function Sinks_Fit
     (Sinks : Model_Runner.Tensors.Real_Array_Access;
      Layer : Natural := 0) return Boolean
   is (Sinks = null
       or else (Element_Count (Layer) + 1) * Sinks.all'Length
               <= Held_Sink_Room);

   --  A layer's sinks put where the device's attention reads them, a head
   --  each after the round's table and a slot on from the layer before, and
   --  where they went: what the attention step is told as Sinks_At. Zero for
   --  a layer without them, which is every layer of every architecture but
   --  one; and zero where they could not be put, which sends the layer to
   --  the host. Put every time rather than once, because every session of
   --  the model puts the same numbers and a copy of a few hundred bytes into
   --  a standing mapping is nothing beside the layer.
   --
   --  @param Sinks The layer's sinks, or null.
   --  @param Layer Which layer, so its slot falls after the earlier ones'.
   --  @return Where they begin, in elements, or zero.
   function Sinks_Ready
     (Sinks : Model_Runner.Tensors.Real_Array_Access;
      Layer : Natural := 0) return Natural
   is
      --  A slot a layer, so a token that chains its layers into one
      --  submission does not have every layer's sinks land on the last
      --  layer's: Put_Cache writes the mapping as the command buffer is
      --  built, before the device runs any of it, so a shared slot would
      --  hold whichever layer was written last by the time any attention
      --  read it. The layers past what the room holds go to the host.
      Span  : constant Element_Count :=
        (if Sinks = null then 0 else Sinks.all'Length);
      Where : constant Element_Count :=
        Sinks_Room_At + Element_Count (Layer) * Span;
      Ok    : Boolean;
   begin
      if Sinks = null or else Sinks_Room_At = 0
        or else not Sinks_Fit (Sinks, Layer)
      then
         return 0;
      end if;

      Model_Runner.Backend.Device.Put_Cache (Where, Sinks.all, Ok);
      return (if Ok then Natural (Where) else 0);
   end Sinks_Ready;

   --  Where a session's cache begins in the device's buffer.
   --  Where a session's block begins, in elements: where it was placed
   --  when it took one.
   function Block_Base (Item : Session) return Element_Count
   is (if Item.Seat < 0 then 0 else Item.Cache_Base);

   --  A layer's rows of a packed session, read back out of the device's
   --  block into the host's copy: the bytes the device packed and their
   --  scales, which are the same bytes the host would have packed. What
   --  Settle_Cache and the end of a token or a batch do for an exact
   --  session by reading floats.
   --
   --  @param Item Session whose block it is.
   --  @param Slot Where the first row begins, in elements of the host's
   --    flat keys.
   --  @param V_Slot The same for the values.
   --  @param Span How many rows, one after the other.
   --  @param KV_Width How wide a row of keys is.
   --  @param V_Width How wide a row of values is.
   --  @param Read True when every read succeeded.
   procedure Read_Back_Packed
     (Item     : in out Session;
      Slot     : Element_Count;
      V_Slot   : Element_Count;
      Span     : Element_Count;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Read     : out Boolean)
   is
      Base : constant Element_Count := Block_Base (Item);
      Laid : constant Packed_Block := Packed_Layout (Item);
      Held : constant Cache_Precision := Item.Held;
      V_Held : constant Cache_Precision := Item.Held_Values;
      K_At : constant B.Byte_Count := Byte_Of (Held, Slot, KV_Width);
      V_At : constant B.Byte_Count := Byte_Of (V_Held, V_Slot, V_Width);
      K_Scale : constant Element_Count := Scale_Of (Held, Slot, KV_Width);
      V_Scale : constant Element_Count := Scale_Of (V_Held, V_Slot, V_Width);
   begin
      Model_Runner.Backend.Device.Get_Cache_Bytes
        (Interfaces.Unsigned_64 (Base) * 4 + Interfaces.Unsigned_64 (K_At),
         Item.Byte_Keys.all
           (K_At .. K_At + B.Byte_Count (Span) * Row_Bytes (Held, KV_Width) - 1),
         Read);
      if Read then
         Model_Runner.Backend.Device.Get_Cache_Bytes
           (Interfaces.Unsigned_64 (Base + Laid.Values_At) * 4
            + Interfaces.Unsigned_64 (V_At),
            Item.Byte_Values.all
              (V_At .. V_At + B.Byte_Count (Span) * Row_Bytes (V_Held, V_Width) - 1),
            Read);
      end if;
      if Read then
         Model_Runner.Backend.Device.Get_Cache
           (Base + Laid.Key_Scales_At + K_Scale,
            Item.Key_Scales.all
              (K_Scale .. K_Scale + Span * Blocks_Of (Held, KV_Width) - 1),
            Read);
      end if;
      if Read then
         Model_Runner.Backend.Device.Get_Cache
           (Base + Laid.Value_Scales_At + V_Scale,
            Item.Value_Scales.all
              (V_Scale .. V_Scale + Span * Blocks_Of (V_Held, V_Width) - 1),
            Read);
      end if;
   end Read_Back_Packed;

   --  Give the host's copy of the cache the positions the device wrote.
   --
   --  A device that computed a layer wrote its keys and values into its own
   --  block and nothing else. The host keeps a copy because three things
   --  read it -- attention on the processor, saving a context, and rolling
   --  one -- and none of those is what a run ordinarily does, so the copy is
   --  brought up to date when one of them is about to happen rather than at
   --  the end of every call.
   --
   --  What that is worth is the whole of the difference between reading a
   --  1419-token prompt on the device in 1.000 seconds and in 0.705: two
   --  reads a layer, twenty-two layers, sixty-four megabytes and a wait on
   --  each, for bytes nothing was going to look at.
   --
   --  @param Item Session whose copy may be behind.
   --  @param Settled True where the copy is up to date after this, whether
   --    because nothing was owed or because every owed position was read
   --    back; false where a read failed and the copy is still behind, which
   --    is what tells a caller about to give the block or the pages up not
   --    to -- the device still holds what the host did not get.
   procedure Settle_Cache (Item : in out Session; Settled : out Boolean) is
   begin
      Settled := True;

      if Item.Owed_Count = 0 then
         return;
      end if;

      --  Cleared first. A read that fails leaves the copy as wrong as it
      --  was and asking again would fail the same way; what a caller sees
      --  is the refusal the reader itself reports.
      declare
         Source : constant access Model'Class := Item.Owner;

         Settings : constant Configuration := Source.Settings;

         KV_Width : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Head_Size);
         V_Width  : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Value_Size);

         Span  : constant Element_Count := Element_Count (Item.Owed_Count);
         First : constant Element_Count := Element_Count (Item.Owed_At);

         Read : Boolean := True;
      begin
         Item.Owed_Count := 0;

         for Index in Source.Layers.all'Range loop
            --  A linear layer keeps a state rather than keys and values,
            --  and its ring comes home by its own road.
            if Linear (Settings, Natural (Index)) then
               goto Next_Layer;
            end if;

            declare
               Layer_Keys : constant Element_Count :=
                 Keys_At (Item, Natural (Index));

               Layer_Vals : constant Element_Count :=
                 Values_At (Item, Natural (Index));

               --  Where the positions sit in this layer: at their cells,
               --  which on a layer that has slid are not their numbers.
               --  Every owed position was written since the layer last
               --  slid -- a slide settles first -- so each is still held.
               Cell : constant Element_Count :=
                 Cell_Of (Item, Natural (Index), First);

               Base : constant Element_Count := Layer_Keys + Cell * KV_Width;
               V_At : constant Element_Count := Layer_Vals + Cell * V_Width;
            begin
               if Item.Paged and then Item.Held = Exact then
                  --  Out of the pages the layer's positions are scattered
                  --  through, a page at a time, into the host's contiguous
                  --  copy: the same positions the block reads back, found
                  --  through the page table rather than at a block's base.
                  Read_Pages_Layer
                    (Item, Natural (Index), KV_Width, V_Width,
                     Cell, Span, Read);
               elsif Item.Paged then
                  --  The packed pages read back into the host's bytes and
                  --  scales, the packed analog.
                  Read_Packed_Pages_Layer
                    (Item, Natural (Index), KV_Width, V_Width,
                     Cell, Span, Read);
               elsif Item.Held in Eighth | Fourth then
                  Read_Back_Packed
                    (Item, Base, V_At, Span, KV_Width, V_Width, Read);
               else
                  Model_Runner.Backend.Device.Get_Cache
                    (Block_Base (Item) + Base,
                     Item.Keys.all (Base .. Base + Span * KV_Width - 1), Read);

                  if Read then
                     Model_Runner.Backend.Device.Get_Cache
                       (Block_Base (Item) + Item.Keys.all'Length + V_At,
                        Item.Values.all (V_At .. V_At + Span * V_Width - 1),
                        Read);
                  end if;
               end if;

               exit when not Read;
            end;

            <<Next_Layer>>
         end loop;

         Settled := Read;
      end;
   end Settle_Cache;

   --  Put one position's keys and values where a device can read them.
   --
   --  Said by both evaluators, because a model must attend the same way
   --  whichever reads it: one that computes attention one way while
   --  generating and another while a draft's proposals are checked says two
   --  different things, and the suite says so.
   --
   --  A device that has no room is not a failure. Resident comes back False
   --  and everything is done on the processor as before, which is a slower
   --  run rather than a refused one.
   --
   --  @param Item Session whose cache this is.
   --  @param At_Key Where this position's keys go among the keys.
   --  @param Key_Row The keys, rotated.
   --  @param At_Value Where its values go among the values.
   --  @param Value_Row The values.
   --  @param Resident True when both reached the device.
   procedure Put_Position
     (Item      : Session_Access;
      At_Key    : Element_Count;
      Key_Row   : Real_Array;
      At_Value  : Element_Count;
      Value_Row : Real_Array;
      Resident  : out Boolean)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      Resident := False;

      if Item = null
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else Item.Held /= Exact
      then
         return;
      end if;

      --  Said every position and done once: the block is asked for and,
      --  where it is already this session's, granted without a copy.
      Take_Block (Item, Resident);

      if not Resident then
         return;
      end if;

      declare
         Base : constant Element_Count := Block_Base (Item.all);
      begin
         Model_Runner.Backend.Device.Put_Cache
           (Base + At_Key, Key_Row, Resident);

         if Resident then
            --  The values follow the keys in the device's copy, which is one
            --  buffer because attention wants four arrays and the pipeline
            --  layout carries three.
            Model_Runner.Backend.Device.Put_Cache
              (Base + Item.Keys.all'Length + At_Value, Value_Row, Resident);
         end if;
      end;
   end Put_Position;

   --  A packed position's rows into the device's copy: the row's bytes and
   --  its scales, for the keys at Slot and the values at V_Slot, where the
   --  host has just packed them. What Put_Position is for the exact cache.
   --
   --  @param Item Session whose cache this is.
   --  @param Slot The keys' first element, numbered over the cache.
   --  @param V_Slot The values' first element.
   --  @param KV_Width Elements a row of keys.
   --  @param V_Width Elements a row of values.
   --  @param Resident True when the rows reached the device.
   procedure Put_Packed_Position
     (Item     : Session_Access;
      Slot     : Element_Count;
      V_Slot   : Element_Count;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Resident : out Boolean)
   is
      use type Model_Runner.Backend.Backend_Kind;
   begin
      Resident := False;

      if Item = null
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else Item.Held not in Eighth | Fourth
      then
         return;
      end if;

      Take_Block (Item, Resident);
      if not Resident then
         return;
      end if;

      declare
         Base : constant Element_Count := Block_Base (Item.all);
         Laid : constant Packed_Block := Packed_Layout (Item.all);
         Held : constant Cache_Precision := Item.Held;
         V_Held : constant Cache_Precision := Item.Held_Values;
         K_At : constant B.Byte_Count := Byte_Of (Held, Slot, KV_Width);
         V_At : constant B.Byte_Count := Byte_Of (V_Held, V_Slot, V_Width);
         K_Scale : constant Element_Count := Scale_Of (Held, Slot, KV_Width);
         V_Scale : constant Element_Count := Scale_Of (V_Held, V_Slot, V_Width);
      begin
         Model_Runner.Backend.Device.Put_Cache_Bytes
           (Interfaces.Unsigned_64 (Base) * 4 + Interfaces.Unsigned_64 (K_At),
            Item.Byte_Keys.all (K_At .. K_At + Row_Bytes (Held, KV_Width) - 1),
            Resident);
         if Resident then
            Model_Runner.Backend.Device.Put_Cache_Bytes
              (Interfaces.Unsigned_64 (Base + Laid.Values_At) * 4
               + Interfaces.Unsigned_64 (V_At),
               Item.Byte_Values.all (V_At .. V_At + Row_Bytes (V_Held, V_Width) - 1),
               Resident);
         end if;
         if Resident then
            Model_Runner.Backend.Device.Put_Cache
              (Base + Laid.Key_Scales_At + K_Scale,
               Item.Key_Scales.all
                 (K_Scale .. K_Scale + Blocks_Of (Held, KV_Width) - 1),
               Resident);
         end if;
         if Resident then
            Model_Runner.Backend.Device.Put_Cache
              (Base + Laid.Value_Scales_At + V_Scale,
               Item.Value_Scales.all
                 (V_Scale .. V_Scale + Blocks_Of (V_Held, V_Width) - 1),
               Resident);
         end if;
      end;
   end Put_Packed_Position;

   --  How many elements a session's exact keys are, which is where its
   --  exact values begin on the device -- and nought for a packed session,
   --  which holds no exact rows and whose values the packed kernel finds
   --  through Packed_Shape.
   --
   --  @param Item Session to ask.
   --  @return The keys' element count, or zero.
   function Exact_Keys (Item : Session) return Element_Count
   is (if Item.Keys = null then 0 else Item.Keys.all'Length);

   --  A packed session's block on the device, for this layer's rows: the
   --  rows' bases in bytes and the scales' in floats, each from where the
   --  layer's rows begin, and how many bits an element each side holds.
   --  What the packed kernel is told, whether it is called alone or as a
   --  step of a layer's sequence. Not_Packed for a session that is not.
   --
   --  @param Item Session whose block it is.
   --  @param K_Base Where this layer's keys begin, in elements of a row.
   --  @param V_Base Where this layer's values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Seated True for a round, whose rows each add their own
   --    block out of the table: the bases are then the layer's offsets
   --    alone, and this session's block is not in them.
   --  @return The block as the kernel reads it.
   function Packed_Shape
     (Item     : Session;
      K_Base   : Element_Count;
      V_Base   : Element_Count;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Seated   : Boolean := False;
      Paged    : Boolean := False)
      return Model_Runner.Backend.Device.Packed_Cache
   is
      Base : constant Element_Count := (if Seated then 0 else Block_Base (Item));
      Laid : constant Packed_Block :=
        (if Paged then Packed_Page_Layout (Item) else Packed_Layout (Item));
   begin
      if Item.Held not in Eighth | Fourth then
         return Model_Runner.Backend.Device.Not_Packed;
      end if;

      --  A cache in pages: the bytes and scales are a region's offset
      --  inside a page, and the attention adds the position's page and its
      --  place inside it. No block base, and no per-position offset -- the
      --  positions the batch attends are numbered from nought, and each
      --  reads its own page.
      if Paged then
         return
           (K_Bits   => (if Item.Held = Fourth then 4 else 8),
            V_Bits   => (if Item.Held_Values = Fourth then 4 else 8),
            K_Bytes  => 0,
            V_Bytes  => Interfaces.Unsigned_64 (Laid.Values_At) * 4,
            KS_At    => Natural (Laid.Key_Scales_At),
            VS_At    => Natural (Laid.Value_Scales_At),
            K_Blocks => Natural (Blocks_Of (Item.Held, KV_Width)),
            V_Blocks => Natural (Blocks_Of (Item.Held_Values, V_Width)));
      end if;

      return
        (K_Bits   => (if Item.Held = Fourth then 4 else 8),
         V_Bits   => (if Item.Held_Values = Fourth then 4 else 8),
         K_Bytes  => Interfaces.Unsigned_64 (Base) * 4
                     + Interfaces.Unsigned_64
                         (Byte_Of (Item.Held, K_Base, KV_Width)),
         V_Bytes  => Interfaces.Unsigned_64 (Base + Laid.Values_At) * 4
                     + Interfaces.Unsigned_64
                         (Byte_Of (Item.Held_Values, V_Base, V_Width)),
         KS_At    => Natural (Base + Laid.Key_Scales_At
                              + Scale_Of (Item.Held, K_Base, KV_Width)),
         VS_At    => Natural (Base + Laid.Value_Scales_At
                              + Scale_Of (Item.Held_Values, V_Base, V_Width)),
         K_Blocks => Natural (Blocks_Of (Item.Held, KV_Width)),
         V_Blocks => Natural (Blocks_Of (Item.Held_Values, V_Width)));
   end Packed_Shape;

   --  How a whole layer packs its keys, or its values, into a packed
   --  session's block on the device: the storage's bits, the bytes a row
   --  takes, where the first written row's bytes and scales go, and the
   --  scales a row has. Not_Packing for a session that is not packed.
   --
   --  @param Item Session whose block it is.
   --  @param Slot Where the first written row begins, in elements of the
   --    host's flat keys or values.
   --  @param Width How wide a row is.
   --  @param Keys True for the keys, False for the values.
   --  @param Seated True for a round, whose rows each add their own
   --    block and their own cell out of the table: Slot is then the
   --    layer's first row, and this session's block is not in it.
   --  @return The packing, as the placing step is told it.
   function Packing_Of
     (Item   : Session;
      Slot   : Element_Count;
      Width  : Element_Count;
      Keys   : Boolean;
      Seated : Boolean := False;
      Paged  : Boolean := False)
      return Model_Runner.Backend.Device.Packing_Shape
   is
      Base : constant Element_Count := (if Seated then 0 else Block_Base (Item));
      Laid : constant Packed_Block :=
        (if Paged then Packed_Page_Layout (Item) else Packed_Layout (Item));
      Held : constant Cache_Precision :=
        (if Keys then Item.Held else Item.Held_Values);
   begin
      if Item.Held not in Eighth | Fourth then
         return Model_Runner.Backend.Device.Not_Packing;
      end if;

      --  A cache in pages: At_Byte and At_Scale are the region's offset in
      --  a page, and the pack step adds the position's page and its place.
      --  No block base, and no Slot -- First_Position and the shift place
      --  the row.
      if Paged then
         return
           (Bits      => (if Held = Fourth then 4 else 8),
            Row_Bytes => Natural (Row_Bytes (Held, Width)),
            At_Byte   => Interfaces.Unsigned_64
                           (if Keys then 0 else Laid.Values_At) * 4,
            At_Scale  => Natural (if Keys then Laid.Key_Scales_At
                                  else Laid.Value_Scales_At),
            Blocks    => Natural (Blocks_Of (Held, Width)));
      end if;

      return
        (Bits      => (if Held = Fourth then 4 else 8),
         Row_Bytes => Natural (Row_Bytes (Held, Width)),
         At_Byte   => Interfaces.Unsigned_64
                        (Base + (if Keys then 0 else Laid.Values_At)) * 4
                      + Interfaces.Unsigned_64 (Byte_Of (Held, Slot, Width)),
         At_Scale  => Natural (Base
                               + (if Keys then Laid.Key_Scales_At
                                  else Laid.Value_Scales_At)
                               + Scale_Of (Held, Slot, Width)),
         Blocks    => Natural (Blocks_Of (Held, Width)));
   end Packing_Of;

   --  The blends over the other two storages, named here ahead of the
   --  device fallback that reads whichever the session keeps; the bodies
   --  follow it.
   procedure Blend_Halved
     (Query      : Real_Array;
      Keys       : T.Half_Array;
      Values     : T.Half_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  One score a head that joins the softmax's denominator and takes
      --  none of the weight, or null for an architecture that states none.
      Sinks      : Model_Runner.Tensors.Real_Array_Access;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean);

   procedure Blend_Eighth
     (Held       : Cache_Precision;
      V_Held     : Cache_Precision;
      Query      : Real_Array;
      Keys       : B.Byte_Array;
      Values     : B.Byte_Array;
      Key_Scales : Real_Array;
      Val_Scales : Real_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      Rows       : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  One score a head that joins the softmax's denominator and takes
      --  none of the weight, or null for an architecture that states none.
      Sinks      : Model_Runner.Tensors.Real_Array_Access;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean);

   --  How a packed session's batch may attend through the matrix
   --  instruction: this layer's cells, from the first to the batch's
   --  last, unpacked into the half-precision copy where the exact copy
   --  of this block would have been -- nobody's while the block is
   --  packed -- and the attention pointed there. Not_Unpacked where the
   --  layer's rows in halves do not fit that room, which is half the
   --  block's bytes: a model of fewer than four layers in bytes, or eight
   --  in nibbles.
   --
   --  @param Item Session whose block it is.
   --  @param K_Base Where this layer's keys begin, in elements of the
   --    host's flat keys.
   --  @param V_Base The same for the values.
   --  @param KV_Width How wide a row of keys is.
   --  @param V_Width How wide a row of values is.
   --  @param Cells How many cells of the layer the batch reads, its own
   --    included.
   --  @return The unpacking, as the whole layer is told it.
   function Unpacking_Of
     (Item     : Session;
      K_Base   : Element_Count;
      V_Base   : Element_Count;
      KV_Width : Element_Count;
      V_Width  : Element_Count;
      Cells    : Element_Count;
      Paged    : Boolean := False)
      return Model_Runner.Backend.Device.Unpacking_Shape
   is
      Base : constant Element_Count := (if Paged then 0 else Block_Base (Item));
   begin
      if Item.Held not in Eighth | Fourth or else Cells = 0 then
         return Model_Runner.Backend.Device.Not_Unpacked;
      end if;

      --  A block's rows unpack into the room its own front holds, which is
      --  the block's bytes read as halves and a fraction of it; where they
      --  do not fit -- a shallow model's short block -- the layer stays
      --  packed and takes the row kernel. A paged session unpacks into the
      --  copy buffer instead, which the packed pages leave untouched, so
      --  the room is the whole of it and the check is not this one.
      if not Paged
        and then Cells * (KV_Width + V_Width) > Packed_Layout (Item).Span
      then
         return Model_Runner.Backend.Device.Not_Unpacked;
      end if;

      --  Paged: the keys and values are read out of their pages, a region's
      --  offset in a page, and laid one after another at the copy's front,
      --  where the matrix attention then reads them. A block reads from its
      --  own front.
      return
        (Keys   => Packing_Of (Item, K_Base, KV_Width, True, Paged => Paged),
         Values => Packing_Of (Item, V_Base, V_Width, False, Paged => Paged),
         Cells  => Natural (Cells),
         K_Base => Natural (Base),
         V_Base => Natural (Base + Cells * KV_Width));
   end Unpacking_Of;

   --  One position attending, on the device, to the cache it already holds.
   --
   --  The arguments the processor's own attention takes, in the same order,
   --  so that the two call sites read alike and a reader can see that they
   --  are asking for the same thing.
   --
   --  @param Item Session the position belongs to.
   --  @param Source Model, for the bound its architecture states.
   --  @param Query This position's queries.
   --  @param Heads How many heads.
   --  @param Head_Size How wide a query head is.
   --  @param Value_Size How wide a value head is.
   --  @param First First cached position that may be looked at.
   --  @param Last Last cached position that may be looked at.
   --  @param K_Base Where this layer's keys begin.
   --  @param V_Base Where this layer's values begin.
   --  @param KV_Width How far apart one position's keys are from the next.
   --  @param V_Width How far apart one position's values are from the next.
   --  @param Scale What a score is multiplied by.
   --  @param Target Receives the blend, one position after another.
   --  @param Usable False when the arithmetic went non-finite.
   --  @param Positions How many positions attend at once. One while
   --    generating; the whole batch while a prompt is evaluated.
   --  @param Window This layer's sliding window, or zero for none, which a
   --    batch needs because every position of it has its own first.
   procedure Attend_There
     (Item       : in out Session;
      Source     : Model'Class;
      Query      : Real_Array;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Scale      : Real;
      Target     : out Real_Array;
      Usable     : out Boolean;
      Positions  : Element_Count := 1;
      Window     : Natural := 0;

      --  This layer's sinks, passed for the reason the window is: they
      --  belong to a layer and this procedure is told about one call
      --  rather than about a stack.
      Sinks      : Model_Runner.Tensors.Real_Array_Access := null)
   is
      --  What this model's attention is, asked of the model rather than
      --  passed in: a window is a property of a layer and changes down the
      --  stack, but whether a position may see what follows it is a
      --  property of the model and cannot differ between two calls about
      --  the same one.
      Causal : constant Boolean := Source.Settings.Causal;

      --  A head's worth of queries and of blend, which is how far apart one
      --  position of a batch is from the next in either array.
      Query_Span : constant Element_Count := Heads * Head_Size;
      Blend_Span : constant Element_Count := Heads * Value_Size;

      Took : Boolean;

      --  A settle that could not finish leaves the copy behind, which the
      --  read below then surfaces; nothing here can do better than that.
      Settled : Boolean;
   begin
      --  What the device wrote and the host was owed, before this reads it.
      Settle_Cache (Item, Settled);

      --  The device's attention has no sinks, so a layer with them is
      --  attended below, on the host, out of the same cache. It was asked
      --  regardless, and a mixture with sinks answered as if it had none:
      --  the fixture check said the sinks moved no logit.
      Took := False;

      if Sinks = null and then Item.Held in Eighth | Fourth then
         --  Over the packed block: the rows' bases in bytes and the
         --  scales' in floats, each from where the layer's rows begin.
         declare
            Block : constant Model_Runner.Backend.Device.Packed_Cache :=
              Packed_Shape (Item, K_Base, V_Base, KV_Width, V_Width);
         begin
            Model_Runner.Backend.Device.Attend_Packed
              (Block.K_Bits, Block.V_Bits,
               Query, Natural (Heads), Natural (Head_Size), Natural (Value_Size),
               Source.Settings.Group_Size, Natural (First), Natural (Last),
               Block.K_Bytes, Block.V_Bytes,
               Natural (KV_Width), Natural (V_Width),
               Block.KS_At, Block.VS_At, Block.K_Blocks, Block.V_Blocks,
               Scale, Source.Settings.Attention_Cap, Target, Took,
               Positions => Natural (Positions), Window => Window,
               Causal => Causal, Max_Bias => Source.Settings.Max_Bias);
         end;
      elsif Sinks = null then
         Model_Runner.Backend.Device.Attend
           (Query, Natural (Heads), Natural (Head_Size), Natural (Value_Size),
            Source.Settings.Group_Size, Natural (First), Natural (Last),
            Block_Base (Item) + K_Base,
            Block_Base (Item) + Item.Keys.all'Length + V_Base,
            Natural (KV_Width), Natural (V_Width),
            Scale, Source.Settings.Attention_Cap, Target, Took,
            Positions => Natural (Positions), Window => Window,
            Causal => Causal, Max_Bias => Source.Settings.Max_Bias);
      end if;

      if Took then
         Usable := True;
         return;
      end if;

      --  A device that will not take it is not a wrong answer, only an
      --  absent one, and the processor has the same cache to read: the
      --  positions were written to both. Saying so here rather than at
      --  either call site keeps the two evaluators alike, and keeps a
      --  refusal from being reported as a tensor gone non-finite.
      Usable := True;

      for Slot in 0 .. Positions - 1 loop
         declare
            --  Position Slot of the batch looks to Last + Slot, and back to
            --  the window's start where there is one. The device works this
            --  out from the same two numbers, which is what makes the two
            --  paths comparable rather than merely similar.
            --
            --  Attending both ways, every position looks to Last itself:
            --  the text ends where the text ends, whichever position is
            --  asking.
            Ends  : constant Element_Count :=
              (if Causal then Last + Slot else Last);

            --  And where this slot's own query sits, which Ends is not for
            --  a model that reads both ways: there every slot shares Ends
            --  and only this differs between them.
            Asking : constant Element_Count :=
              (if Causal then Ends else Last - (Positions - 1) + Slot);
            Since : constant Element_Count :=
              (if Window = 0 then First
               elsif Ends + 1 > Element_Count (Window)
               then Ends + 1 - Element_Count (Window)
               else 0);

            Q_At : constant Element_Count := Slot * Query_Span;
            B_At : constant Element_Count := Slot * Blend_Span;

            Fine : Boolean;
         begin
            --  Out of whichever storage the session keeps: a packed
            --  session's bytes and scales, whose row scales begin a row
            --  a position from the layer's first row.
            if Item.Held in Eighth | Fourth then
               Blend_Eighth
                 (Item.Held, Item.Held_Values,
                  Query (Query'First + Q_At .. Query'First + Q_At
                         + Query_Span - 1),
                  Item.Byte_Keys.all, Item.Byte_Values.all,
                  Item.Key_Scales.all, Item.Value_Scales.all,
                  K_Base, V_Base, K_Base / KV_Width, KV_Width, V_Width,
                  Heads, Head_Size, Value_Size,
                  Element_Count (Source.Settings.Group_Size),
                  Since, Ends, Scale, Source.Settings.Attention_Cap,
                  Source.Settings.Max_Bias, Asking, Sinks,
                  0, Heads - 1, Item.Score_Room, Item.Scores.all,
                  Target (Target'First + B_At .. Target'First + B_At
                          + Blend_Span - 1), Fine);
            elsif Item.Held = Halved then
               Blend_Halved
                 (Query (Query'First + Q_At .. Query'First + Q_At
                         + Query_Span - 1),
                  Item.Half_Keys.all, Item.Half_Values.all,
                  K_Base, V_Base, KV_Width, V_Width, Heads, Head_Size,
                  Value_Size, Element_Count (Source.Settings.Group_Size),
                  Since, Ends, Scale, Source.Settings.Attention_Cap,
                  Source.Settings.Max_Bias, Asking, Sinks,
                  0, Heads - 1, Item.Score_Room, Item.Scores.all,
                  Target (Target'First + B_At .. Target'First + B_At
                          + Blend_Span - 1), Fine);
            else
               Blend_Exact
                 (Query (Query'First + Q_At .. Query'First + Q_At
                         + Query_Span - 1),
                  Item.Keys.all, Item.Values.all,
                  K_Base, V_Base, KV_Width, V_Width, Heads, Head_Size,
                  Value_Size, Element_Count (Source.Settings.Group_Size),
                  Since, Ends, Scale, Source.Settings.Attention_Cap,
                  Source.Settings.Max_Bias, Asking, Sinks,
                  0, Heads - 1, Item.Score_Room, Item.Scores.all,
                  Target (Target'First + B_At .. Target'First + B_At
                          + Blend_Span - 1), Fine);
            end if;

            Usable := Usable and then Fine;
            exit when not Fine;
         end;
      end loop;
   end Attend_There;

   --  The same, over a cache held in half precision. Every element is
   --  widened where the exact one reads it; nothing else differs, and
   --  nothing here computes in half precision.
   --  One row of the cache, written as bytes with a scale of its own.
   --
   --  Symmetric around zero: the scale is the largest magnitude in the row
   --  divided by 127, so the largest element lands on the end of the range
   --  and zero stays zero. A row of zeros has no magnitude to scale by and
   --  keeps a scale of one, which reads back as the zeros it was.
   --
   --  The unit is a row rather than the whole cache because a row is what
   --  the evaluator writes at once and what it reads at once, and because
   --  one scale for a whole context would be set by whichever position had
   --  the largest key in it and would quantize every other position against
   --  that.
   --  One row of the cache rounded into its bytes and scales: a signed
   --  byte an element with the row's one scale, or a nibble an element
   --  with a scale a block of thirty-two -- the block's largest element,
   --  sign and all, over minus eight, and each element its share of that
   --  plus eight and a half cut to a whole number and held to fifteen,
   --  which is how the other runtime's four-bit cache rounds.
   procedure Pack_Row
     (Source : Real_Array;
      Into   : in out B.Byte_Array;
      Origin : Element_Count;
      Width  : Element_Count;
      Scales : in out Real_Array;
      Held   : Cache_Precision)
   is
      At_Byte  : constant B.Byte_Count := Byte_Of (Held, Origin, Width);
      At_Scale : constant Element_Count :=
        Scales'First + Scale_Of (Held, Origin, Width);
   begin
      if Held = Fourth then
         declare
            Offset : Element_Count := 0;
         begin
            while Offset < Element_Count (Source'Length) loop
               declare
                  Span    : constant Element_Count :=
                    Element_Count'Min (Block, Element_Count (Source'Length) - Offset);
                  Largest : Real := 0.0;
                  Signed  : Real := 0.0;
                  Scale   : Real;
                  Inverse : Real;
               begin
                  for Index in Offset .. Offset + Span - 1 loop
                     if abs Source (Source'First + Index) > Largest then
                        Largest := abs Source (Source'First + Index);
                        Signed := Source (Source'First + Index);
                     end if;
                  end loop;
                  Scale := Signed / (-8.0);
                  Inverse := (if Scale /= 0.0 then 1.0 / Scale else 0.0);
                  Scales (At_Scale + Offset / Block) := Scale;

                  for Index in Offset .. Offset + Span - 1 loop
                     declare
                        Level : constant Real :=
                          Real'Floor (Source (Source'First + Index) * Inverse + 8.5);
                        Nibble : constant B.Byte :=
                          B.Byte (Integer (Real'Max (0.0, Real'Min (15.0, Level))));
                        Where  : constant B.Byte_Count :=
                          At_Byte + B.Byte_Count (Index / 2);
                     begin
                        if Index mod 2 = 0 then
                           Into (Where) := Nibble;
                        else
                           Into (Where) := Into (Where) or (Nibble * 16);
                        end if;
                     end;
                  end loop;
               end;
               Offset := Offset + Block;
            end loop;
         end;
         return;
      end if;

      declare
         Largest : Real := 0.0;
         Scale   : Real;
      begin
         for Value of Source loop
            Largest := Real'Max (Largest, abs Value);
         end loop;

         Scale := (if Largest > 0.0 then Largest / 127.0 else 1.0);
         Scales (At_Scale) := Scale;

         for Offset in 0 .. Element_Count (Source'Length) - 1 loop
            declare
               Step : constant Real :=
                 Real'Rounding (Source (Source'First + Offset) / Scale);
               Held_Step : constant Real :=
                 Real'Max (-127.0, Real'Min (127.0, Step));
            begin
               Into (At_Byte + B.Byte_Count (Offset)) :=
                 B.Byte (Integer (Held_Step) + 128);
            end;
         end loop;
      end;
   end Pack_Row;

   --  One element back out of it, numbered over the whole cache.
   function Unpack
     (From    : B.Byte_Array;
      Element : Element_Count;
      Width   : Element_Count;
      Scales  : Real_Array;
      Held    : Cache_Precision) return Real
   is
      Scale : constant Real := Scales (Scales'First + Scale_Of (Held, Element, Width));
      Held_Byte : constant B.Byte := From (Byte_Of (Held, Element, Width));
   begin
      if Held = Fourth then
         return Real (Integer (if (Element mod Width) mod 2 = 0
                               then Held_Byte and 15 else Held_Byte / 16)
                      - 8) * Scale;
      else
         return Real (Integer (Held_Byte) - 128) * Scale;
      end if;
   end Unpack;

   --  Attention over a cache stored packed: bytes and row scales, or
   --  nibbles and block scales, as Held says.
   --
   --  The same arithmetic as the other two, reading through the packed
   --  kernels. Written out rather than shared with them: what differs is
   --  the innermost read of the innermost loop, and a storage chosen per
   --  session would put a branch there rather than around it.
   procedure Blend_Eighth
     (Held       : Cache_Precision;
      V_Held     : Cache_Precision;
      Query      : Real_Array;
      Keys       : B.Byte_Array;
      Values     : B.Byte_Array;
      Key_Scales : Real_Array;
      Val_Scales : Real_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      Rows       : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  One score a head that joins the softmax's denominator and takes
      --  none of the weight, or null for an architecture that states none.
      Sinks      : Model_Runner.Tensors.Real_Array_Access;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is separate;

   procedure Blend_Halved
     (Query      : Real_Array;
      Keys       : T.Half_Array;
      Values     : T.Half_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Heads      : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      First      : Element_Count;
      Last       : Element_Count;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Query_At   : Element_Count;

      --  One score a head that joins the softmax's denominator and takes
      --  none of the weight, or null for an architecture that states none.
      Sinks      : Model_Runner.Tensors.Real_Array_Access;

      --  The heads this call is to blend, and how far apart the rows of the
      --  score buffer are.
      --
      --  A head at a time was one buffer for all of them, which is right
      --  when one task walks the heads in order and wrong the moment two do
      --  it at once: the scores of a head are written, softmaxed and read
      --  back within its own iteration, so two heads sharing them is two
      --  heads answering with each other's arithmetic. A row apiece is what
      --  lets a share of the heads run beside another share.
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Score_Room : Element_Count;
      Scores     : in out Real_Array;
      Target     : out Real_Array;
      Ok         : out Boolean) is

      --  As in Blend_Exact above, and for the reason written there: the
      --  overflow branch after every computed index, with the bounds check
      --  that catches a wrap left in place.
      pragma Suppress (Overflow_Check);
   begin
      Ok := True;

      for Head in From_Head .. To_Head loop
         declare
            Group    : constant Element_Count := Head / Group_Size;
            At_Score : constant Element_Count :=
              Scores'First + Head * Score_Room;
            Q_Origin : constant Element_Count := Query'First + Head * Head_Size;
            Usable   : Boolean;
         begin
            --  Four positions a call where four are left, the query read
            --  once for them and each score to the bit what one a call
            --  gave; one a call for the rest.
            declare
               Step : Element_Count := First;
               Dots : Real_Array (0 .. 3);
            begin
               while Step + 3 <= Last loop
                  K.Key_Dots_Halved_Four
                    (Left         => Query,
                     At_Left      => Q_Origin,
                     Right        => Keys,
                     At_Right     =>
                       Keys'First + K_Base + Step * KV_Width
                       + Group * Head_Size,
                     Right_Stride => KV_Width,
                     Span         => Head_Size,
                     Dots         => Dots);
                  for Which in Element_Count range 0 .. 3 loop
                     Scores (At_Score + Step + Which) := Dots (Which) * Scale;
                  end loop;
                  Step := Step + 4;
               end loop;

               while Step <= Last loop
                  Scores (At_Score + Step) :=
                    K.Head_Dot_Halved
                      (Left     => Query,
                       At_Left  => Q_Origin,
                       Right    => Keys,
                       At_Right =>
                         Keys'First + K_Base + Step * KV_Width
                         + Group * Head_Size,
                       Span     => Head_Size)
                    * Scale;
                  Step := Step + 1;
               end loop;
            end;

            --  As above: the bound in a loop of its own, and only when
            --  there is one.
            --  And the fall-off with distance, in a loop of its own for the
            --  same reason and under the same guard. Unsigned, because the
            --  one architecture that takes it reads a whole text and a
            --  position is as far from what follows it as from what came
            --  before.
            declare
               Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
            begin
               if Slope > 0.0 then
                  for Step in First .. Last loop
                     Scores (At_Score + Step) :=
                       Scores (At_Score + Step)
                       - Slope
                         * Real (abs (Integer (Step) - Integer (Query_At)));
                  end loop;
               end if;
            end;

            if Cap > 0.0 then
               for Step in First .. Last loop
                  Scores (At_Score + Step) :=
                    Capped (Scores (At_Score + Step), Cap);
               end loop;
            end if;

            --  With this head's sink where the architecture states one,
            --  which joins the denominator and takes none of the weight.
            if Sinks /= null then
               K.Softmax
                 (Scores (At_Score + First .. At_Score + Last),
                  Sinks.all (Sinks.all'First + Element_Count (Head)),
                  Usable);
            else
               K.Softmax
                 (Scores (At_Score + First .. At_Score + Last), Usable);
            end if;
            if not Usable then
               Ok := False;
               return;
            end if;

            --  A run of components at a time rather than one, and summed
            --  in binary32, for the reasons written out in Blend_Exact.
            declare
               Run : constant Element_Count := 64;
               At_Component : Element_Count := 0;
            begin
               while At_Component < Value_Size loop
                  declare
                     Here : constant Element_Count :=
                       Element_Count'Min (Run, Value_Size - At_Component);
                     Sums : Real_Array (0 .. Here - 1) := [others => 0.0];
                  begin
                     K.Blend_Run_Halved
                       (Sums      => Sums,
                        Weights   => Scores,
                        At_Weight => At_Score + First,
                        Values    => Values,
                        At_Value  =>
                          Values'First + V_Base + First * V_Width
                          + Group * Value_Size + At_Component,
                        Stride    => V_Width,
                        Steps     => Last - First + 1);

                     for Component in 0 .. Here - 1 loop
                        Target (Target'First + Head * Value_Size
                                + At_Component + Component) :=
                          Sums (Component);
                     end loop;

                     At_Component := At_Component + Here;
                  end;
               end loop;
            end;
         end;
      end loop;
   end Blend_Halved;

   --  Four queries' attention over the same keys, as Blend_Halved does one
   --  query's: a key read and converted once for the four, a value once.
   --  The four are consecutive positions of a batch, Q_Stride apart in
   --  Query and T_Stride apart in Target, each with its own range of
   --  cells; the block runs over the union of the ranges and a query's
   --  weights outside its own are nought. A prompt on the processor did
   --  one query at a time, every key it saw read and converted again:
   --  qwen3-8b's 3,863 tokens spent 46 s of 106 there.
   --  Over a cache kept in binary32 the same, with kernels that read it
   --  as it is (Blend_Exact_Four): one generic, the two caches' kernels
   --  given to it.
   type Cell_Quad is array (0 .. 7) of Element_Count;

   generic
      type Held is private;
      type Held_Array is
        array (Model_Runner.Numerics.Element_Index range <>) of Held;
      with procedure Dots_Four
        (Left        : Real_Array;
         At_Left     : Element_Count;
         Left_Stride : Element_Count;
         Right       : Held_Array;
         At_Right    : Element_Count;
         Span        : Element_Count;
         Dots        : out Real_Array);
      with procedure Dots_Eight
        (Left        : Real_Array;
         At_Left     : Element_Count;
         Left_Stride : Element_Count;
         Right       : Held_Array;
         At_Right    : Element_Count;
         Span        : Element_Count;
         Dots        : out Real_Array);
      with procedure Blend_Sixteen
        (Sums          : in out Real_Array;
         Weights       : Real_Array;
         At_Weight     : Element_Count;
         Weight_Stride : Element_Count;
         Values        : Held_Array;
         At_Value      : Element_Count;
         Stride        : Element_Count;
         Steps         : Element_Count);
   procedure Blend_Block_Four
     (Size       : Positive;
      Query      : Real_Array;
      Q_At       : Element_Count;
      Q_Stride   : Element_Count;
      Keys       : Held_Array;
      Values     : Held_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      Heads      : Element_Count;
      Firsts     : Cell_Quad;
      Lasts      : Cell_Quad;
      Query_Ats  : Cell_Quad;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Sinks      : Model_Runner.Tensors.Real_Array_Access;
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Room       : Element_Count;
      Rows       : in out Real_Array;
      Target     : in out Real_Array;
      T_At       : Element_Count;
      T_Stride   : Element_Count;
      Ok         : out Boolean);

   procedure Blend_Block_Four
     (Size       : Positive;
      Query      : Real_Array;
      Q_At       : Element_Count;
      Q_Stride   : Element_Count;
      Keys       : Held_Array;
      Values     : Held_Array;
      K_Base     : Element_Count;
      V_Base     : Element_Count;
      KV_Width   : Element_Count;
      V_Width    : Element_Count;
      Head_Size  : Element_Count;
      Value_Size : Element_Count;
      Group_Size : Element_Count;
      Heads      : Element_Count;
      Firsts     : Cell_Quad;
      Lasts      : Cell_Quad;
      Query_Ats  : Cell_Quad;
      Scale      : Real;
      Cap        : Real;
      Max_Bias   : Real;
      Sinks      : Model_Runner.Tensors.Real_Array_Access;
      From_Head  : Element_Count;
      To_Head    : Element_Count;
      Room       : Element_Count;
      Rows       : in out Real_Array;
      Target     : in out Real_Array;
      T_At       : Element_Count;
      T_Stride   : Element_Count;
      Ok         : out Boolean)
   is
      pragma Suppress (Overflow_Check);

      Last_Row : constant Natural := Size - 1;

      function Lowest return Element_Count is
         Low : Element_Count := Firsts (0);
      begin
         for R in 1 .. Last_Row loop
            Low := Element_Count'Min (Low, Firsts (R));
         end loop;
         return Low;
      end Lowest;

      function Highest return Element_Count is
         High : Element_Count := Lasts (0);
      begin
         for R in 1 .. Last_Row loop
            High := Element_Count'Max (High, Lasts (R));
         end loop;
         return High;
      end Highest;

      Lo : constant Element_Count := Lowest;
      Hi : constant Element_Count := Highest;
      Dots : Real_Array (0 .. 7);
   begin
      Ok := True;

      for Head in From_Head .. To_Head loop
         declare
            Group : constant Element_Count := Head / Group_Size;
            Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
         begin
            for Step in Lo .. Hi loop
               if Size = 8 then
                  Dots_Eight
                    (Query, Q_At + Head * Head_Size, Q_Stride,
                     Keys, Keys'First + K_Base + Step * KV_Width
                           + Group * Head_Size,
                     Head_Size, Dots);
               else
                  Dots_Four
                    (Query, Q_At + Head * Head_Size, Q_Stride,
                     Keys, Keys'First + K_Base + Step * KV_Width
                           + Group * Head_Size,
                     Head_Size, Dots (0 .. 3));
               end if;
               for R in 0 .. Last_Row loop
                  Rows (Rows'First + Element_Count (R) * Room + Step) :=
                    Dots (Element_Count (R)) * Scale;
               end loop;
            end loop;

            for R in 0 .. Last_Row loop
               declare
                  Row   : constant Element_Count :=
                    Rows'First + Element_Count (R) * Room;
                  Usable : Boolean;
               begin
                  if Slope > 0.0 then
                     for Step in Firsts (R) .. Lasts (R) loop
                        Rows (Row + Step) :=
                          Rows (Row + Step)
                          - Slope
                            * Real (abs (Integer (Step)
                                         - Integer (Query_Ats (R))));
                     end loop;
                  end if;

                  if Cap > 0.0 then
                     for Step in Firsts (R) .. Lasts (R) loop
                        Rows (Row + Step) := Capped (Rows (Row + Step), Cap);
                     end loop;
                  end if;

                  if Sinks /= null then
                     K.Softmax
                       (Rows (Row + Firsts (R) .. Row + Lasts (R)),
                        Sinks.all (Sinks.all'First + Element_Count (Head)),
                        Usable);
                  else
                     K.Softmax
                       (Rows (Row + Firsts (R) .. Row + Lasts (R)), Usable);
                  end if;
                  if not Usable then
                     Ok := False;
                     return;
                  end if;

                  for Step in Lo .. Firsts (R) - 1 loop
                     Rows (Row + Step) := 0.0;
                  end loop;
                  for Step in Lasts (R) + 1 .. Hi loop
                     Rows (Row + Step) := 0.0;
                  end loop;
               end;
            end loop;

            declare
               At_Component : Element_Count := 0;
               Sums : Real_Array (0 .. 63);
            begin
               while At_Component < Value_Size loop
                  --  Four queries a pass: sixteen sums each is what the
                  --  registers hold.
                  for Quarter in 0 .. Last_Row / 4 loop
                     Sums := [others => 0.0];
                     Blend_Sixteen
                       (Sums          => Sums,
                        Weights       => Rows,
                        At_Weight     =>
                          Rows'First + Element_Count (4 * Quarter) * Room + Lo,
                        Weight_Stride => Room,
                        Values        => Values,
                        At_Value      =>
                          Values'First + V_Base + Lo * V_Width
                          + Group * Value_Size + At_Component,
                        Stride        => V_Width,
                        Steps         => Hi - Lo + 1);

                     for R in 0 .. 3 loop
                        declare
                           Q : constant Element_Count :=
                             Element_Count (4 * Quarter + R);
                        begin
                           Target (T_At + Q * T_Stride
                                   + Head * Value_Size + At_Component
                                   .. T_At + Q * T_Stride
                                      + Head * Value_Size + At_Component + 15)
                             := Sums (Element_Count (R) * 16
                                      .. Element_Count (R) * 16 + 15);
                        end;
                     end loop;
                  end loop;

                  At_Component := At_Component + 16;
               end loop;
            end;
         end;
      end loop;
   end Blend_Block_Four;

   procedure Blend_Halved_Four is new Blend_Block_Four
     (Held          => Model_Runner.Numerics.Half,
      Held_Array    => Model_Runner.Numerics.Half_Array,
      Dots_Four     => K.Head_Dots_Halved_Four,
      Dots_Eight    => K.Head_Dots_Halved_Eight,
      Blend_Sixteen => K.Blend_Sixteen_Halved_Four);

   procedure Blend_Exact_Four is new Blend_Block_Four
     (Held          => Real,
      Held_Array    => Real_Array,
      Dots_Four     => K.Head_Dots_Four,
      Dots_Eight    => K.Head_Dots_Eight,
      Blend_Sixteen => K.Blend_Sixteen_Four);

   --  Normalize each head of a projection in place.
   --
   --  The gain is one element per element of a head, shared across the
   --  heads: a head is normalized against itself and scaled by the same
   --  vector every other head is. Room for one head is passed in rather
   --  than taken, because this runs inside the evaluator and the evaluator
   --  does not allocate.
   procedure Normalize_Heads
     (Vector  : in out Real_Array;
      Heads   : Element_Count;
      Width   : Element_Count;
      Gain    : Real_Array;
      Epsilon : Real;
      Room    : in out Real_Array) is
   begin
      for Head in 0 .. Heads - 1 loop
         declare
            Origin : constant Element_Count := Vector'First + Head * Width;
         begin
            --  Plainly, and not the lifted convention: this normalizes a
            --  query or key head, which only Qwen3 does, and Qwen3 trains
            --  those weights around one like everything else here.
            K.RMS_Norm
              (Vector (Origin .. Origin + Width - 1), Gain, Epsilon, Room);
            Vector (Origin .. Origin + Width - 1) := Room;
         end;
      end loop;
   end Normalize_Heads;

   --  Normalize each head of a projection in place, centred and with a gain
   --  of its own for every head.
   --
   --  Command-R+ does this where Qwen3 does the plain one above: it centres
   --  each head -- subtracting the mean -- rather than dividing by the root
   --  mean square, and carries a gain a head rather than one shared across
   --  them, so the gain is as wide as the whole projection and a head's is
   --  the slice at its own offset. No shift, as its layer normalizations
   --  carry none.
   procedure Normalize_Heads_Centred
     (Vector  : in out Real_Array;
      Heads   : Element_Count;
      Width   : Element_Count;
      Gain    : Real_Array;
      Epsilon : Real;
      Room    : in out Real_Array)
   is
      No_Shift : constant Real_Array (0 .. Width - 1) := [others => 0.0];
   begin
      for Head in 0 .. Heads - 1 loop
         declare
            Origin  : constant Element_Count := Vector'First + Head * Width;
            Gain_At : constant Element_Count := Gain'First + Head * Width;
         begin
            K.Layer_Norm
              (Vector (Origin .. Origin + Width - 1),
               Gain (Gain_At .. Gain_At + Width - 1),
               No_Shift, Epsilon, Room);
            Vector (Origin .. Origin + Width - 1) := Room;
         end;
      end loop;
   end Normalize_Heads_Centred;

   --  The feed-forward block of one position, through the experts its router
   --  chose for it.
   --
   --  The router scores every expert, the softmax turns the scores into a
   --  distribution, the highest few are taken and their shares renormalized
   --  over that few, and each of them runs the same gate-up-silu-down block
   --  a dense model has one of. The outputs are summed in proportion to
   --  those shares.
   --
   --  Ties go to the lower-numbered expert, which is what the strict
   --  comparison below buys: two experts scoring the same must not make the
   --  answer depend on which one the search happened to reach first.
   --
   --  Input and Result must not be the same buffer: every expert reads the
   --  input after the sum has started being written.
   --  The expert every position of a mixture goes through as well, where
   --  the mixture has one: the same gated block an expert is, over the
   --  whole feed width the file states for it, scaled by the sigmoid of
   --  its own router row against the input, and added to what the chosen
   --  experts said. One position here, a batch below.
   procedure Shared_Expert
     (Item    : in out Session;
      Current : Layer;
      Input   : T.Real_Array_Access;
      Result  : in out Real_Array;
      Status  : out E.Error_Info)
   is
   begin
      Product_Group
        (Item, [Current.Shared_Gate, Current.Shared_Up], Input,
         [Item.Shared_Row, Item.Shared_Up_Row], Status);
      if E.Is_Error (Status) then
         return;
      end if;

      K.SiLU (Item.Shared_Row.all);
      K.Multiply (Item.Shared_Row.all, Item.Shared_Up_Row.all);

      Product
        (Item, Current.Shared_Down, Item.Shared_Row, Item.Shared_Out_Row,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Scale : constant Real :=
           Shared_Weight (Current.Shared_Router, Input.all, Input.all'First);
      begin
         for Index in Result'Range loop
            Result (Index) :=
              Result (Index) + Scale * Item.Shared_Out_Row.all (Index);
         end loop;
      end;
   end Shared_Expert;

   procedure Mixture_Batch
     (Item    : in out Session;
      Current : Layer;
      Rows    : T.Real_Array_Access;
      Count   : Element_Count;
      Ok      : out Boolean;
      Status  : out E.Error_Info);

   procedure Mixture_Body
     (Item    : in out Session;
      Current : Layer;
      Input   : T.Real_Array_Access;
      Result  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is separate;

   --  The mixture, on the processor's pool where the device runs only the
   --  layers' front halves; as it always was otherwise.
   procedure Mixture
     (Item    : in out Session;
      Current : Layer;
      Input   : T.Real_Array_Access;
      Result  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Was : constant Boolean := Item.Host_Feed;
   begin
      Item.Host_Feed := Was or else Item.Owner.all.Split_Feed;
      Mixture_Body (Item, Current, Input, Result, Status);
      Item.Host_Feed := Was;
   exception
      when others =>
         Item.Host_Feed := Was;
         raise;
   end Mixture;

   -------------------
   -- Mixture_Batch --
   -------------------

   --  A batch's mixture, gathered by expert rather than run by position.
   --
   --  A batch has no one matrix to multiply the whole of it by: each
   --  position routes to its own few experts, which is why this block ran a
   --  position at a time however many were handed in. What that costs is
   --  not the arithmetic -- an expert chosen by seven positions of a
   --  hundred and ten had its three matrices READ SEVEN TIMES, and on a
   --  model larger than the device will hold, read means uploaded.
   --
   --  Turned round, the batch is grouped by expert: every position that
   --  chose one is gathered into a run of vectors, the expert's matrices
   --  are read once and multiplied by all of them, and the answers are
   --  scattered back. llama.cpp calls the same idea `mul_mat_id`.
   --
   --  THE SUM IS IN THE ORDER IT WAS. A position adds its experts' answers
   --  best first, and grouping by expert would add them in expert order
   --  instead -- a different sum of the same numbers, and a different
   --  answer in the last bits. Each answer is written to its own place in
   --  Ranked, by position and by rank, and the sums are done afterwards in
   --  the order they were always done in. That is what the largest of these
   --  buffers is for.
   --
   --  @param Item Session, for its buffers and its backend.
   --  @param Current The layer.
   --  @param Rows Count positions of Width, normalized, read and written.
   --  @param Count How many positions.
   --  @param Ok False where the batch could not be gathered, which leaves
   --    the caller to run the positions one at a time as it did before.
   --  @param Status Success, or the first refusal.
   procedure Mixture_Batch_Body
     (Item    : in out Session;
      Current : Layer;
      Rows    : T.Real_Array_Access;
      Count   : Element_Count;
      Ok      : out Boolean;
      Status  : out E.Error_Info)
   is separate;

   procedure Mixture_Batch
     (Item    : in out Session;
      Current : Layer;
      Rows    : T.Real_Array_Access;
      Count   : Element_Count;
      Ok      : out Boolean;
      Status  : out E.Error_Info)
   is
      Was : constant Boolean := Item.Host_Feed;
   begin
      Item.Host_Feed := Was or else Item.Owner.all.Split_Feed;
      Mixture_Batch_Body (Item, Current, Rows, Count, Ok, Status);
      Item.Host_Feed := Was;
   exception
      when others =>
         Item.Host_Feed := Was;
         raise;
   end Mixture_Batch;

   -----------
   -- Enter --
   -----------

   --  Evaluating does not name a phase. It used to set Generating, whether
   --  the tokens being evaluated were a prompt being read or a reply being
   --  written, because the evaluator cannot tell the difference -- so a
   --  session reading a prompt said it was generating, and the state that
   --  meant "reading a prompt" was reachable by nobody.
   procedure Enter (Item : in out Session; Phase : Session_State) is
   begin
      --  A failed or closed session stays where it is. A phase recorded over
      --  a failure would lose the one fact worth keeping about it.
      if Item.Current in Ready | Evaluating_Prompt | Generating then
         Item.Current := Phase;
      end if;
   end Enter;

   procedure Close
     (Item   : in out Model;
      Status : out E.Error_Info) is
   begin
      if Item.Sessions > 0 then
         Status := E.Make (E.Lifecycle_Session_Active);
         E.Add_Integer (Status, "sessions", Long_Long_Integer (Item.Sessions));
         return;
      end if;

      Item.Ready := False;

      declare
         --  A layer's vectors, of the stack or past it.
         procedure Free_Layer (Which : in out Layer) is
         begin
            T.Free (Which.Attention_Norm);
            T.Free (Which.Post_Attention_Norm);
            T.Free (Which.Attention_Norm_Bias);
            T.Free (Which.Post_Feed_Norm);
            T.Free (Which.Feed_Norm);
            T.Free (Which.Feed_Norm_Bias);
            T.Free (Which.Attention_Norm_Pair);
            T.Free (Which.Feed_Norm_Pair);
            T.Free (Which.Post_Attention_Norm_Pair);
            T.Free (Which.Post_Feed_Norm_Pair);
            T.Free (Which.Linear_Numbers);
            T.Free (Which.Rwkv_Pack);
            T.Free (Which.Ssm_Pack);

            --  The attention biases, which nothing released: a qwen2 model
            --  held three vectors a layer past its own closing, and only
            --  that architecture has them, which is why closing a llama
            --  model looked clean.
            T.Free (Which.Query_Norm);
            T.Free (Which.Query_Head_Norm);
            T.Free (Which.Key_Head_Norm);
            T.Free (Which.Query_Whole_Norm);
            T.Free (Which.Query_Whole_Norm_Bias);
            T.Free (Which.Key_Whole_Norm);
            T.Free (Which.Key_Whole_Norm_Bias);
            T.Free (Which.Second_Attention_Norm);
            T.Free (Which.Second_Attention_Norm_Bias);
            T.Free (Which.Key_Norm);
            T.Free (Which.Query_Bias);
            T.Free (Which.Key_Bias);
            T.Free (Which.Value_Bias);
            T.Free (Which.KV_Bias);
            T.Free (Which.Out_Bias);
            T.Free (Which.Up_Bias);
            T.Free (Which.Down_Bias);

            --  The linear layer's, the shared expert's and the next
            --  block's, null for a layer without them.
            T.Free (Which.A_Log);
            T.Free (Which.DT_Bias);
            T.Free (Which.Conv);
            T.Free (Which.State_Norm);
            T.Free (Which.Ssm_Dt_Norm);
            T.Free (Which.Ssm_B_Norm);
            T.Free (Which.Ssm_C_Norm);
            T.Free (Which.Shared_Router);
            T.Free (Which.Next_ENorm);
            T.Free (Which.Next_HNorm);
            T.Free (Which.Next_Head_Norm);

            if Which.Experts /= null then
               Deallocate_Experts (Which.Experts);
            end if;
         end Free_Layer;
      begin
         if Item.Layers /= null then
            for Index in Item.Layers.all'Range loop
               Free_Layer (Item.Layers.all (Index));
            end loop;
            Deallocate_Layers (Item.Layers);
         end if;

         if Item.Next /= null then
            for Index in Item.Next.all'Range loop
               Free_Layer (Item.Next.all (Index));
            end loop;
            Deallocate_Layers (Item.Next);
         end if;
      end;

      T.Free (Item.Output_Norm);
      T.Free (Item.Output_Norm_Bias);
      T.Free (Item.Output_Bias);
      T.Free (Item.Rope_Factors);

      --  The repacked arena goes with it, and after it: by then the device
      --  has been told to give everything back, so there is no address left
      --  for it to be wrong about.
      Release_Weights (Item);
      if Item.Panel_Writer /= null then
         while not Item.Panel_Writer'Terminated loop
            delay 0.01;
         end loop;
         declare
            procedure Release is new Ada.Unchecked_Deallocation
              (Model_Runner.Panel_Cache.Writing, Panel_Writing_Access);
         begin
            Release (Item.Panel_Writer);
         end;
      end if;
      B.Free (Item.Repacked);
      if Item.Panel_Map /= null then
         declare
            procedure Release is new Ada.Unchecked_Deallocation
              (Model_Runner.Byte_Sources.Files.File_Source, Panel_Map_Access);
         begin
            Model_Runner.Byte_Sources.Files.Close (Item.Panel_Map.all);
            Release (Item.Panel_Map);
         end;
      end if;
      if Item.Light_Head /= null then
         Mem.Record_Release
           (Item.Accounting, Mem.Converted_Weights,
            Interfaces.Unsigned_64 (Item.Light_Head.all'Length));
         B.Free (Item.Light_Head);
      end if;
      if Item.Draft_Head_Bytes /= null then
         Mem.Record_Release
           (Item.Accounting, Mem.Converted_Weights,
            Interfaces.Unsigned_64 (Item.Draft_Head_Bytes.all'Length));
         B.Free (Item.Draft_Head_Bytes);
      end if;
      Item.Draft_Head := T.Empty_View;
      Item.Embeddings := T.Empty_View;
      Item.Output := T.Empty_View;
      Item.Output_As_Stored := T.Empty_View;
      Item.Settings := (others => <>);
      Model_Runner.Tokenizer.Close (Item.Words);
      Model_Runner.Templates.Close (Item.Chat);
      Item.Chat_Present := False;
      Item.Chat_Status := E.Success;
      Status := E.Success;
   exception
      when others =>
         Item.Ready := False;
         Status := E.Success;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Model) is
      Ignored : E.Error_Info;
   begin
      Item.Sessions := 0;
      Close (Item, Ignored);
   end Finalize;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Item : Model) return Boolean is (Item.Ready);

   ------------
   -- Config --
   ------------

   function Config (Item : Model) return Configuration is (Item.Settings);

   ----------------
   -- Vocabulary --
   ----------------

   function Vocabulary
     (Item : Model) return access constant Model_Runner.Tokenizer.Vocabulary
   is (Item.Words'Unchecked_Access);

   -------------------
   -- Has_Template --
   -------------------

   function Has_Template (Item : Model) return Boolean is (Item.Chat_Present);

   ---------------------
   -- Template_Ready --
   ---------------------

   function Weights_Mapped (Item : Model) return Boolean
   is (not Item.Weights_Held
       and then Item.Weights_Base /= System.Null_Address);

   function Repacked_Bytes (Item : Model) return Interfaces.Unsigned_64
   is (if Item.Repacked = null then 0
       else Interfaces.Unsigned_64 (Item.Repacked.all'Length));

   function Panels_Cached (Item : Model) return Interfaces.Unsigned_64
   is (if Item.Panel_Map = null then 0
       else Interfaces.Unsigned_64
              (Model_Runner.Byte_Sources.Files.Size (Item.Panel_Map.all)));

   function Repack_Time (Item : Model) return Model_Runner.Clocks.Nanoseconds
   is (Item.Repack_Ns);

   function Template_Ready (Item : Model) return Boolean
   is (Item.Chat_Present and then Model_Runner.Templates.Is_Compiled (Item.Chat));

   -------------------------
   -- Template_Condition --
   -------------------------

   function Template_Condition (Item : Model) return E.Error_Info
   is (Item.Chat_Status);

   ---------------------
   -- Template_Format --
   ---------------------

   function Template_Format (Item : Model) return String
   is (Item.Chat_Format_Name (1 .. Item.Chat_Format_Used));

   -----------------------
   -- Template_Stood_In --
   -----------------------

   function Template_Stood_In (Item : Model) return Boolean
   is (Item.Chat_Stood_In);

   --------------
   -- Template --
   --------------

   function Template
     (Item : Model) return access constant Model_Runner.Templates.Compiled
   is (Item.Chat'Unchecked_Access);

   -------------
   -- Account --
   -------------

   function Account (Item : Model) return Mem.Account is (Item.Accounting);

   ---------------------------------------------------------------------------
   --  Sessions
   ---------------------------------------------------------------------------

   --------------------
   -- Merge_Adapter --
   --------------------

   procedure Merge_Adapter
     (Item   : in out Model;
      Source : Containers.Container;
      Bytes  : in out Model_Runner.Byte_Sources.Source'Class;
      Scale  : Real := 1.0;
      Status : out E.Error_Info)
   is separate;

   ---------------------------------------------------------------------------
   --  Saved sessions
   ---------------------------------------------------------------------------

   --  What a saved session begins with, so that a file that is not one is
   --  refused before anything in it is believed.
   Session_Magic : constant := 16#4D52_5345_5353_0001#;

   --  The layout below. A file written by another version is refused rather
   --  than guessed at.
   --  Two, because a saved session now says where each layer's run
   --  begins. A layer that slides a window does not hold the positions
   --  before it, so one run a layer from position zero stopped being a
   --  faithful record of what a session has. A file written by the version
   --  before this is refused by version, as it always was.
   Session_Version : constant := 2;

   ------------------
   -- Fingerprint --
   ------------------

   function Fingerprint (Item : Model) return Interfaces.Unsigned_64 is
      --  An ordinary multiply-and-mix. This identifies a model; it does not
      --  authenticate one, and a stronger function would only make it look
      --  as though it did.
      Digest : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;

      procedure Mix (Value : Interfaces.Unsigned_64) is
      begin
         Digest := (Digest xor Value) * 16#0000_0100_0000_01B3#;
      end Mix;

      procedure Mix_Count (Value : Natural) is
      begin
         Mix (Interfaces.Unsigned_64 (Value));
      end Mix_Count;
   begin
      if not Item.Ready then
         return 0;
      end if;

      Mix_Count (Architecture'Pos (Item.Settings.Kind));
      Mix_Count (Item.Settings.Context_Length);
      Mix_Count (Item.Settings.Embedding);
      Mix_Count (Item.Settings.Feed_Forward);
      Mix_Count (Item.Settings.Layers);
      Mix_Count (Item.Settings.Heads);
      Mix_Count (Item.Settings.KV_Heads);
      Mix_Count (Item.Settings.Head_Size);
      Mix_Count (Item.Settings.Value_Size);
      Mix_Count (Item.Settings.Rotary);
      Mix_Count (Item.Settings.Vocabulary);
      Mix_Count (Item.Settings.Window);
      Mix_Count (Item.Settings.Experts);
      Mix_Count (Item.Settings.Experts_Used);
      Mix_Count (Repack_Mode'Pos (Item.Packing));

      --  And whatever has been merged into the weights since, because a
      --  model with an adapter in it is not the model its file describes.
      Mix (Item.Adapted);

      --  And the weights themselves, by their size and a sample. Reading
      --  all of them would be a second pass over a model at every load for
      --  a number only a saved session uses.
      if Item.Weights_Base /= System.Null_Address then
         Mix (Interfaces.Unsigned_64 (Item.Weights_Span));

         declare
            --  Through the weights wherever they are: the copy when there
            --  is one, the file's own pages when there is not. Reading the
            --  arena directly was what this did, and the arena is null for
            --  a model that was never copied.
            Held : B.Byte_Array (1 .. Item.Weights_Span)
              with Import, Address => Item.Weights_Base;

            Step : constant B.Byte_Count :=
              B.Byte_Count'Max (1, Item.Weights_Span / 4096);
            At_Byte : B.Byte_Count := 0;
         begin
            while At_Byte < Item.Weights_Span loop
               Mix (Interfaces.Unsigned_64 (Held (Held'First + At_Byte)));
               At_Byte := At_Byte + Step;
            end loop;
         end;
      end if;

      return Digest;
   end Fingerprint;

   --------------
   -- Snapshot --
   --------------

   --  Make room in every layer that slides a window for the positions up
   --  to Upto.
   --
   --  A layer that slides holds the window and a margin. When a run of
   --  positions has passed the end of what it holds, what the window still
   --  needs is moved down to the front and the layer's origin moves with
   --  it. Nothing else in the engine knows this happened: a position is
   --  asked for by Cell_Of everywhere, and the blend takes cells rather
   --  than positions, so the arithmetic is the arithmetic it was.
   --
   --  How often, and how much: the margin is a window again or a batch,
   --  whichever is larger, so a layer slides about once every margin
   --  positions and moves at most a window of rows when it does. That is
   --  about one row moved for every row written, against the six hundred
   --  megabytes of weights a token reads.
   --  Positions a slide keeps past the window, for a rewind to land in:
   --  a drafted round's worth and more. A windowed layer's cells hold the
   --  window, these and a batch: kept to the window and a batch alone, a
   --  slide before a batch of more than 512 - 64 positions left the batch's
   --  last cells past the end -- gemma-3-4b stopped with a range check on
   --  any prompt whose last batch ran from 1,536 past 1,985.
   Rewind_Slack : constant := 64;

   procedure Make_Room
     (Item     : in out Session;
      Settings : Configuration;
      Upto     : Element_Count);

   procedure Make_Room
     (Item     : in out Session;
      Settings : Configuration;
      Upto     : Element_Count)
   is separate;

   procedure Snapshot
     (Item   : in out Session;
      Source : Model'Class;
      Into   : out B.Byte_Array_Access;
      Status : out E.Error_Info)
   is separate;

   -----------
   -- Adopt --
   -----------

   procedure Adopt
     (Item   : in out Session;
      Source : Model'Class;
      From   : B.Byte_Array;
      Status : out E.Error_Info)
   is separate;

   ------------------
   -- Plan_Session --
   ------------------

   procedure Plan_Session
     (Item    : Model;
      Context : Natural;
      Plan    : out Mem.Session_Plan;
      Status  : out E.Error_Info;
      Cache   : Cache_Precision := Exact;
      Values  : Value_Precision := Same_As_Keys) is
   begin
      Plan_For (Item.Settings, Context, Plan, Status, Cache, Values);
   end Plan_Session;

   ---------------
   -- Plan_For --
   ---------------

   procedure Plan_For
     (Settings : Configuration;
      Context  : Natural;
      Plan     : out Mem.Session_Plan;
      Status   : out E.Error_Info;
      Cache    : Cache_Precision := Exact;
      Values   : Value_Precision := Same_As_Keys)
   is
      Capacity : constant Natural :=
        (if Context = 0 then Settings.Context_Length else Context);

      --  How many positions the layers hold between them.
      --
      --  It was layers times capacity, because every layer held the whole
      --  context. A layer that slides a window holds the window and a
      --  margin instead, and this counts what Open will allocate rather
      --  than what it used to -- the two must agree, or a plan refuses a
      --  session that would have fitted or admits one that will not.
      --
      --  The rule is stated once, here and in Open, and the two are held
      --  together by a test that opens a session and compares what it took
      --  against what this said.
      Margin : constant Natural := Max_Batch;

      --  A linear layer keeps no cells: its state is counted below. The
      --  block past the stack keeps a layer's worth, as Open gives it.
      function Cells_Of (Layer : Natural) return Natural
      is (if Linear (Settings, Layer) and then Layer < Settings.Layers
          then 0
          elsif Slides (Settings, Layer)
          then Natural'Min (Capacity, Settings.Window + Margin)
          else Capacity);

      function Positions return Interfaces.Unsigned_64;

      function Positions return Interfaces.Unsigned_64 is
         Total : Interfaces.Unsigned_64 := 0;
      begin
         for Layer in 0 .. Settings.Layers + Settings.Next_Layers - 1 loop
            Total := Total + Interfaces.Unsigned_64 (Cells_Of (Layer));
         end loop;
         return Total;
      end Positions;

      --  What the linear layers hold instead: a state a value head and
      --  the convolution's memory, each layer, in binary32.
      function Linear_Bytes return Interfaces.Unsigned_64 is
         Count : Natural := 0;
      begin
         for Layer in 0 .. Settings.Layers - 1 loop
            if Linear (Settings, Layer) then
               Count := Count + 1;
            end if;
         end loop;
         return Interfaces.Unsigned_64 (Count)
           * (Interfaces.Unsigned_64 (Settings.Value_Heads)
              * Interfaces.Unsigned_64 (Settings.State_Size)
              * Interfaces.Unsigned_64 (Settings.State_Size)
              + Interfaces.Unsigned_64 (Natural'Max (Settings.Conv_Kernel, 1) - 1)
                * Interfaces.Unsigned_64 (Mix_Width (Settings)))
           * 4;
      end Linear_Bytes;

      --  positions * kv heads * head size * bytes * 2, entirely in checked
      --  arithmetic so that an implausible request is reported as an
      --  overflow rather than wrapping into a small allocation.
      --  The keys' side and the values', each at its own storage.
      Room : constant A.Checked :=
        (A.To_Checked (Positions)
         * A.To_Checked (Interfaces.Unsigned_64 (Settings.KV_Heads))
         * A.To_Checked (Interfaces.Unsigned_64 (Settings.Head_Size))
         * A.To_Checked (Cache_Element_Sixteenths (Cache))
         + A.To_Checked (Positions)
           * A.To_Checked (Interfaces.Unsigned_64 (Settings.KV_Heads))
           * A.To_Checked (Interfaces.Unsigned_64 (Settings.Value_Size))
           * A.To_Checked (Cache_Element_Sixteenths (Values_Held (Cache, Values))))
        / A.To_Checked (Interfaces.Unsigned_64'(16));
   begin
      Plan := (others => <>);

      if not A.Is_Valid (Room) then
         Status := E.Make (E.Memory_Plan_Overflow);
         return;
      end if;

      Plan.KV_Cache_Bytes := A.Value (Room) + Linear_Bytes;
      Plan.Activation_Bytes :=
        Interfaces.Unsigned_64 (Settings.Embedding) * 4 * 4;
      Plan.Batch_Bytes :=
        Interfaces.Unsigned_64 (Feed_Width (Settings)) * 4 * 2
        + Interfaces.Unsigned_64 (Settings.Experts) * 4
        + (if Settings.Experts > 0
           then Interfaces.Unsigned_64 (Settings.Embedding) * 4 * 2
           else 0);
      Plan.Logits_Bytes := Interfaces.Unsigned_64 (Settings.Vocabulary) * 4;
      Plan.Sampling_Bytes := Plan.Logits_Bytes;
      Plan.Token_History_Bytes := Interfaces.Unsigned_64 (Capacity) * 4;
      Plan.Decoder_Bytes := 64;
      Plan.Stop_Bytes := 4096;
      Plan.Rendering_Bytes := 0;

      Mem.Finalize_Session_Plan (Plan, Status);
   end Plan_For;

   --  The fewest positions a context nobody named is cut down to.
   Least_Context : constant := 1024;

   --  What a session planned so holds, counting the cache twice on a
   --  device: the device keeps its own copy of the cache beside the
   --  host's, and the host's memory is what both come out of on an
   --  integrated part.
   --
   --  Where the model learned no sinks the device keeps only the
   --  half-precision copy, not the cache proper, so its half of the count
   --  is halved -- which is what lets a sinkless model hold a context whose
   --  two full copies would not fit, the copy split across buffers so no
   --  one of them is too large.
   function Session_Needs
     (Source : Model'Class;
      Plan   : Mem.Session_Plan) return Interfaces.Unsigned_64
   is
      Sinkless : constant Boolean := Sink_Footprint (Source.Settings) = 0;

      Device_Cache : constant Interfaces.Unsigned_64 :=
        (if Model_Runner.Backend."="
              (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
         then (if Sinkless
               then Plan.KV_Cache_Bytes / 2
               else Plan.KV_Cache_Bytes)
         else 0);
   begin
      return Plan.Total_Resident + Device_Cache;
   end Session_Needs;

   ----------
   -- Open --
   ----------

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
   is separate;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Session) is
   begin
      if Item.Owner /= null and then Item.Current /= Closed then
         if Item.Owner.Sessions > 0 then
            Item.Owner.Sessions := Item.Owner.Sessions - 1;
         end if;
      end if;

      --  The pages of the device's cache this session held, given back --
      --  every slot it owns, wherever they are -- and the buffer let go
      --  once nobody holds a page, as a block does. Not cleared: a page
      --  taken again is written over or holds nothing committed.
      if Item.Paged_In and then Item.Pages /= null and then Page_Elements > 0
      then
         Release_Session_Pages (Item'Unchecked_Access);

         if (for all Owner of Page_Owner => Owner = null)
           and then (for all Holder of Block_Holder => Holder = null)
         then
            Model_Runner.Backend.Device.Release_Cache;
         end if;
      end if;

      --  The block of the device's cache this session held, given back. Not
      --  cleared: what is in it is a closed session's keys, and the next
      --  session to take the block writes its own over them or has nothing
      --  committed to write.
      if Item.Seat >= 0
        and then Item.Seat <= Block_Holder'Last
        and then Block_Holder (Item.Seat) = Item'Unchecked_Access
      then
         Block_Holder (Item.Seat) := null;

         --  And how far the buffer has been dealt, brought down to the
         --  blocks that are left: the table a round reads and a layer's
         --  sinks sit past that, so a block given back at the top of the
         --  buffer used to leave both where they were and every reserve
         --  after it asking for room nobody was in. A table that moved
         --  under a round already formed would be read where it is not,
         --  which is why this is said where a session closes and not
         --  while one is being served.
         Block_Taken := 0;

         for Which in Block_Holder'Range loop
            if Block_Holder (Which) /= null then
               Block_Taken :=
                 Element_Count'Max
                   (Block_Taken,
                    Block_Holder (Which).Cache_Base
                    + Block_Span_Of (Block_Holder (Which).all));
            end if;
         end loop;

         if (for all Holder of Block_Holder => Holder = null) then
            Block_Taken := 0;

            --  And the buffers themselves, which a reserve only ever
            --  grew: the last block given up is nobody holding the
            --  device's cache, and a run that read a long context and
            --  went on to short ones left the long one's cache there --
            --  on a part that shares the host's memory, the machine's
            --  memory held for a session that has closed.
            Model_Runner.Backend.Device.Release_Cache;
         end if;
      end if;

      Item.Seat := -1;

      Free_Cells (Item.Cells);
      Free_Cells (Item.At_Keys);
      Free_Cells (Item.At_Values);
      Free_Cells (Item.At_Rows);
      Free_Cells (Item.Origin);
      Free_Cells (Item.Pages);
      Free_Cells (Item.Page_First);
      Free_Cells (Item.Page_Count);
      Free_Cells (Item.Page_Table_At);
      Item.Paged := False;
      Item.Paged_In := False;

      T.Free (Item.Keys);
      T.Free (Item.Values);
      B.Free (Item.Byte_Keys);
      B.Free (Item.Byte_Values);
      T.Free (Item.Key_Scales);
      T.Free (Item.Value_Scales);
      T.Free (Item.Half_Keys);
      T.Free (Item.Half_Values);
      T.Free (Item.Activation);
      T.Free (Item.Normalized);
      T.Free (Item.Post_Room);
      T.Free (Item.Kept_Input);
      T.Free (Item.Query);
      T.Free (Item.Key_Row);
      T.Free (Item.Value_Row);
      T.Free (Item.Attention);
      T.Free (Item.MLA_Q_Lat);
      T.Free (Item.MLA_KV_Lat);
      T.Free (Item.MLA_C_Norm);
      T.Free (Item.MLA_KV);
      T.Free (Item.Scores);
      T.Free (Item.Gate);
      T.Free (Item.Up);
      T.Free (Item.Head_Row);
      T.Free (Item.Query_Full);
      T.Free (Item.Last_Final);
      T.Free (Item.Next_Input);
      T.Free (Item.Next_Keys);
      T.Free (Item.Next_Values);
      T.Free (Item.Head_Gate);
      T.Free (Item.Mix_Row);
      T.Free (Item.Z_Row);
      T.Free (Item.Mamba_XZ);
      T.Free (Item.Mamba_X);
      T.Free (Item.Mamba_DBC);
      T.Free (Item.Mamba_DTR);
      T.Free (Item.Mamba_DT);
      T.Free (Item.Mamba_Y);
      T.Free (Item.Mamba_Steps);
      T.Free (Item.Mamba_Decays);
      T.Free (Item.Mamba_Batch_XZ);
      T.Free (Item.Mamba_Batch_X);
      T.Free (Item.Mamba_Batch_Y);
      T.Free (Item.Rwkv_N1);
      T.Free (Item.Rwkv_Inp);
      T.Free (Item.Rwkv_N2);
      T.Free (Item.Rwkv_Mix);
      T.Free (Item.Rwkv_Lora);
      T.Free (Item.Rwkv_WLora);
      T.Free (Item.Rwkv_Rr);
      T.Free (Item.Rwkv_Kk);
      T.Free (Item.Rwkv_Vv);
      T.Free (Item.Rwkv_Gg);
      T.Free (Item.Rwkv_Ww);
      T.Free (Item.Rwkv_Y);
      T.Free (Item.Rwkv_CK);
      T.Free (Item.Alpha_Row);
      T.Free (Item.Beta_Row);
      T.Free (Item.Blend_Row);
      T.Free (Item.Shared_Row);
      T.Free (Item.Shared_Up_Row);
      T.Free (Item.Shared_Out_Row);
      T.Free (Item.Shared_Rows_A);
      T.Free (Item.Shared_Rows_B);
      T.Free (Item.Shared_Rows_Out);
      T.Free (Item.Shared_Given);
      Release_State_Room (Item'Unchecked_Access);
      T.Free (Item.Conv_State);
      T.Free (Item.Delta_State);
      T.Free (Item.Check_State);
      T.Free (Item.Check_Conv);
      Item.Check_At := 0;
      T.Free (Item.Routing);
      T.Free (Item.Mixture);
      T.Free (Item.Expert_Row);
      T.Free (Item.Expert_Arms);
      T.Free (Item.Expert_Feeds);
      T.Free (Item.Expert_Outs);
      T.Free (Item.Mixed);
      T.Free (Item.Route_Rows);
      T.Free (Item.Pick_Share);
      T.Free (Item.Gather_In);
      T.Free (Item.Gather_A);
      T.Free (Item.Gather_B);
      T.Free (Item.Gather_Out);
      T.Free (Item.Ranked);

      declare
         procedure Release is
           new Ada.Unchecked_Deallocation (Choice_List, Choice_Access);
      begin
         if Item.Pick_Which /= null then
            Release (Item.Pick_Which);
         end if;

         if Item.Gathered /= null then
            Release (Item.Gathered);
         end if;
      end;
      T.Free (Item.Logit_Row);

      if Item.Marks /= null then
         Deallocate_Marks (Item.Marks);
         Item.Marked := 0;
      end if;
      if Item.History /= null then
         Deallocate_History (Item.History);
      end if;

      Item.Owner := null;
      Item.Team := null;
      Item.Context := 0;
      Item.Committed := 0;
      Item.Current := Closed;
   exception
      when others =>
         Item.Current := Closed;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Session) is
   begin
      Close (Item);
   end Finalize;

   -----------
   -- State --
   -----------

   function State (Item : Session) return Session_State is (Item.Current);

   ----------------
   -- Precision --
   ----------------

   function Precision (Item : Session) return Cache_Precision
   is (if Item.Device_Halves then Halved else Item.Held);

   function Value_Precision_Of (Item : Session) return Cache_Precision
   is (if Item.Device_Halves then Halved else Item.Held_Values);

   -------------------
   -- Hidden_State --
   -------------------

   procedure Hidden_State
     (Item   : Session;
      Target : out Real_Array;
      Status : out E.Error_Info) is
   begin
      Target := [others => 0.0];

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Committed = 0
        or else Item.Normalized = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      if Target'Length /= Item.Normalized.all'Length then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "output", Long_Long_Integer (Target'Length));
         E.Add_Integer
           (Status, "expected",
            Long_Long_Integer (Item.Normalized.all'Length));
         return;
      end if;

      Target := Item.Normalized.all;
      Status := E.Success;
   end Hidden_State;

   --------------
   -- Position --
   --------------

   function Position (Item : Session) return Natural is (Item.Committed);

   --------------
   -- Capacity --
   --------------

   function Capacity (Item : Session) return Natural is (Item.Context);

   -------------
   -- Workers --
   -------------

   function Workers (Item : Session) return Workers_CPU.Pool_Reference
   is (Item.Team);

   ----------------------
   -- Committed_Token --
   ----------------------

   -------------------
   -- Reusable_From --
   -------------------

   function Reusable_From (Item : Session) return Natural is
      Lowest : Natural := 0;
   begin
      if Item.Origin = null or else Item.Owner = null then
         return 0;
      end if;

      declare
         Width : constant Natural := Item.Owner.Settings.Window;
      begin
         if Width = 0 then
            return 0;
         end if;

         for Layer in Item.Origin.all'Range loop
            declare
               Origin : constant Element_Count := Item.Origin.all (Layer);
            begin
               --  A layer still holding position zero holds everything, so
               --  any rewind is safe there. One that has slid holds from
               --  Origin, and the position rewound to has to leave a whole
               --  window above it.
               if Origin > 0 then
                  Lowest :=
                    Natural'Max
                      (Lowest, Natural (Origin) + Width - 1);
               end if;
            end;
         end loop;
      end;

      return Lowest;
   end Reusable_From;

   -----------
   -- Watch --
   -----------

   procedure Watch (Item : in out Session; By : Watcher_Access) is
   begin
      Item.Seen := By;
   end Watch;

   --  Which matrix this view is, or the empty string where nothing said.
   --
   --  A walk rather than a map: a model has a few hundred matrices and a
   --  product is a few million multiplies, so the walk is not measurable
   --  and a map would be a structure to keep in step with Resolve.
   function Named_As (Item : Model'Class; Which : T.View) return String is
   begin
      if Item.Named = null then
         return "";
      end if;

      for Index in 1 .. Item.Named_Up loop
         if Item.Named.all (Index).Base = Which.Base
           and then Item.Named.all (Index).Offset = Which.Offset
         then
            return Model_Runner.Text.To_String (Item.Named.all (Index).Name);
         end if;
      end loop;

      return "";
   end Named_As;

   function Committed_Token (Item : Session; Index : Natural) return Token_Id is
   begin
      if Item.History = null or else Index >= Item.Committed then
         return Model_Runner.Tokenizer.No_Token;
      else
         return Item.History.all (Index);
      end if;
   end Committed_Token;

   -----------
   -- Reset --
   -----------

   -----------
   -- Shift --
   -----------

   procedure Shift
     (Item   : in out Session;
      Source : Model'Class;
      Keep   : Natural;
      Drop   : Positive;
      Status : out E.Error_Info)
   is separate;

   ------------
   -- Rewind --
   ------------

   procedure Rewind
     (Item     : in out Session;
      Position : Natural;
      Status   : out E.Error_Info) is
   begin
      Status := E.Success;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if Position > Item.Committed then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "input", Long_Long_Integer (Position));
         E.Add_Integer (Status, "expected", Long_Long_Integer (Item.Committed));
         return;
      end if;

      --  A linear layer's state is what it is now and cannot be walked
      --  back: it is restored from the ring where the ring reaches, nought
      --  again at the front, and refused past that.
      --  The ring holds it where the position is within Kept_States of
      --  the newest: the slot the position reads is the one the position
      --  before it wrote, and nothing since has come round to it.
      if Item.Delta_State /= null and then Position < Item.Committed then
         if Position = 0 then
            declare
               Settings : Configuration renames Item.Owner.Settings;
               Slot : constant Element_Count := State_Slot (Item, 0);
               Every_State : constant Element_Count := State_Room (Settings);
               Every_Conv  : constant Element_Count := Conv_Room (Settings);
            begin
               Item.Delta_State.all
                 (Slot * Every_State .. (Slot + 1) * Every_State - 1) :=
                 [others => 0.0];
               Item.Conv_State.all
                 (Slot * Every_Conv .. (Slot + 1) * Every_Conv - 1) :=
                 [others => 0.0];
            end;

            --  The slot the ring starts from again is the host's now;
            --  what the device holds in the others is not read again.
            Item.State_On_Device := False;
            Item.Kept_Newest := 0;
         elsif Position <= Item.Kept_Newest
           and then Item.Kept_Newest - Position <= Item.Kept_States
         then
            --  Kept_Newest stays: the slots past the position still hold
            --  what was written there, and what decides whether a later
            --  rewind's slot is intact is the highest position ever
            --  written, not the committed count.
            null;
         elsif Item.Check_At > 0 and then Position = Item.Check_At
           and then Item.Check_On_Device and then Item.State_Seated
         then
            --  The checkpoint, copied on the device into the slot the
            --  position reads; the device's ring is the one to read from
            --  now, the others' contents past it never read again.
            declare
               Every : constant Element_Count := Device_Slot_Span (Item);
               Moved : Boolean;
            begin
               Model_Runner.Backend.Device.Copy_State
                 (From     => Device_Check_At (Item),
                  Into     =>
                    Item.State_Base + State_Slot (Item, Position) * Every,
                  Elements => Every,
                  Ok       => Moved);
               if not Moved then
                  Status := E.Make (E.Tensor_Shape_Mismatch);
                  E.Add_Integer
                    (Status, "input", Long_Long_Integer (Position));
                  E.Add_Integer
                    (Status, "expected",
                     Long_Long_Integer
                       (Natural'Max (0, Item.Kept_Newest - Item.Kept_States)));
                  return;
               end if;
            end;
            Item.State_On_Device := True;
            Item.Ring_Written := False;
            Item.Kept_Newest := Position;
         elsif Item.Check_At > 0 and then Position = Item.Check_At
           and then not Item.Check_On_Device
           and then Item.Check_State /= null and then Item.Check_Conv /= null
         then
            --  The checkpoint, into the slot the position reads; the
            --  host's ring is the one to send now, the others' contents
            --  past it never read again.
            declare
               Settings : Configuration renames Item.Owner.Settings;
               Slot : constant Element_Count := State_Slot (Item, Position);
               Every_State : constant Element_Count := State_Room (Settings);
               Every_Conv  : constant Element_Count := Conv_Room (Settings);
            begin
               Item.Delta_State.all
                 (Slot * Every_State .. (Slot + 1) * Every_State - 1) :=
                 Item.Check_State.all;
               Item.Conv_State.all
                 (Slot * Every_Conv .. (Slot + 1) * Every_Conv - 1) :=
                 Item.Check_Conv.all;
            end;
            Item.State_On_Device := False;
            Item.Ring_Written := True;
            Item.Kept_Newest := Position;
         else
            Status := E.Make (E.Tensor_Shape_Mismatch);
            E.Add_Integer (Status, "input", Long_Long_Integer (Position));
            E.Add_Integer
              (Status, "expected",
               Long_Long_Integer
                 (Natural'Max (0, Item.Kept_Newest - Item.Kept_States)));
            return;
         end if;
      end if;

      --  A checkpoint past where the session now stands describes a context
      --  it no longer holds.
      if Position < Item.Check_At then
         Item.Check_At := 0;
      end if;

      --  Nothing is cleared. What is past the position is not read: every
      --  attention reads the committed length and every write past it is a
      --  write to a slot that will be written again before it is read.
      Item.Committed := Position;
      Item.Marked := Natural'Min (Item.Marked, Position);
   end Rewind;

   procedure Keep_States
     (Item   : in out Session;
      Count  : Natural;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if Item.Current = Closed or else Item.Owner = null then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      if Item.Delta_State = null or else Count = Item.Kept_States then
         return;
      end if;

      --  The ring on the device, home, and its seat given back: the
      --  ring made anew is another size.
      Fetch_States (Item'Unchecked_Access);
      Release_State_Room (Item'Unchecked_Access);

      --  The ring made anew with Count + 1 slots, the state as it is
      --  now carried into the slot the committed count reads; what was
      --  behind it is not, so a rewind reaches back from here only.
      declare
         Settings : Configuration renames Item.Owner.Settings;
         Every_State : constant Element_Count := State_Room (Settings);
         Every_Conv  : constant Element_Count := Conv_Room (Settings);
         Slots  : constant Element_Count := Element_Count (Count) + 1;
         States : T.Real_Array_Access := null;
         Convs  : T.Real_Array_Access := null;
         From   : constant Element_Count := State_Slot (Item, Item.Committed);
         Into   : constant Element_Count :=
           Element_Count (Item.Committed) mod Slots;
      begin
         T.Allocate (Slots * Every_State, States);
         T.Allocate (Slots * Every_Conv, Convs);

         if States = null or else Convs = null then
            T.Free (States);
            T.Free (Convs);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;

         States.all (Into * Every_State .. (Into + 1) * Every_State - 1) :=
           Item.Delta_State.all
             (From * Every_State .. (From + 1) * Every_State - 1);
         Convs.all (Into * Every_Conv .. (Into + 1) * Every_Conv - 1) :=
           Item.Conv_State.all
             (From * Every_Conv .. (From + 1) * Every_Conv - 1);

         T.Free (Item.Delta_State);
         T.Free (Item.Conv_State);
         Item.Delta_State := States;
         Item.Conv_State := Convs;
         Item.Kept_States := Count;
         Item.Kept_Newest := Item.Committed;
      end;
   end Keep_States;

   function States_Kept (Item : Session) return Natural
   is (if Item.Delta_State = null then Natural'Last else Item.Kept_States);

   procedure Reset (Item : in out Session) is
   begin
      --  A context dropped is a context nothing will read, so the
      --  device owes the host nothing for it.
      Item.Owed_Count := 0;

      --  Only the logical contents are invalidated. The cache and scratch
      --  buffers stay allocated so that a reset costs nothing and the next
      --  turn does not have to plan memory again.
      --
      --  Their contents do not stay. A reset is a caller saying the previous
      --  conversation is over, and the tokens of it sat in the history until
      --  something happened to write over them. Bytes.Wipe was written for
      --  this and its documentation said it was used on session reset; it
      --  was called by nothing.
      Item.Marked := 0;
      if Item.History /= null then
         Item.History.all := [others => Model_Runner.Tokenizer.No_Token];
      end if;

      --  And every layer holds the front of the context again, which is
      --  where a session that has committed nothing begins.
      if Item.Origin /= null then
         Item.Origin.all := [others => 0];
      end if;

      --  A linear layer's memory of the context is its state and its
      --  convolution's last positions, and a context that is over is a
      --  state that is nought again.
      if Item.Conv_State /= null then
         Item.Conv_State.all := [others => 0.0];
      end if;
      if Item.Delta_State /= null then
         Item.Delta_State.all := [others => 0.0];
      end if;
      Item.State_On_Device := False;
      Item.Ring_Written := False;
      Item.Kept_Newest := 0;
      Item.Check_At := 0;
      Item.Check_On_Device := False;

      --  And the last state was the last of a context that is over.
      Item.Has_Final := False;

      Item.Committed := 0;
      if Item.Current /= Closed then
         Item.Current := Ready;
      end if;
   end Reset;

   --  The earliest position a query at Position may attend to.
   --
   --  Without a window that is the beginning; with one it is the window's
   --  worth of positions ending at Position, so a query at position ten
   --  with a window of four sees seven, eight, nine and ten. Positions
   --  before that are in the cache and are not read: the window narrows
   --  what may be seen, not what is held.
   function Earliest
     (Settings : Configuration;
      Position : Element_Count;

      --  Which layer is asking, because an architecture may window some of
      --  them and not others. Gemma2 windows every other one, starting with
      --  layer zero; every other architecture here windows all or none, and
      --  passes whatever it likes.
      Layer    : Natural := 0) return Element_Count
   is
      Width : constant Element_Count := Element_Count (Settings.Window);
   begin
      --  Which layers slide a window. Gemma2 alternates, so every second
      --  layer sees everything; Gemma3 windows five in six, so every sixth
      --  does. Written as one rule with the period the architecture states,
      --  because two rules that mean the same thing are two rules to get
      --  wrong.
      if Settings.Alternating
        and then Settings.Window_Every > 0
        and then Layer mod Settings.Window_Every = Settings.Window_Every - 1
      then
         return 0;
      end if;

      if Settings.Window = 0 or else Position < Width then
         return 0;
      else
         return Position - Width + 1;
      end if;
   end Earliest;

   ------------------------
   -- The linear layers --
   ------------------------

   --  One position through one linear layer, on the host, from the
   --  normalized activation in Item.Normalized to the layer's answer in
   --  Item.Normalized, ready to be joined to the residual. The four
   --  projections go to whichever backend the session runs on; the
   --  convolution, the rule and the gated normalization are here.
   --
   --  The convolution: each component of the mixed projection is a
   --  weighted sum of its last Conv_Kernel positions' values, the taps
   --  laid one component at a time in the file, the newest position
   --  under the last tap; then a sigmoid-linear unit. The memory of the
   --  earlier positions is the session's, and moves up by one.
   --
   --  The rule, a value head at a time, its key head being its number
   --  modulo the key heads -- the file lays the value heads out for that
   --  -- with the queries and keys normalized to unit length first: the
   --  state decays by exp (g), the value's error against what the state
   --  already says of the key is taken at the rate beta, the key times
   --  that error is added to the state, and the query reads the state
   --  out, scaled by one over the root of the width. g is minus the
   --  exponential of A_Log times the softplus of the decay projection
   --  plus its bias; beta the sigmoid of the rate projection.
   --
   --  The blend is normalized a head at a time by root mean square with
   --  the layer's gain, and scaled by the sigmoid-linear unit of the
   --  gate projection, component by component, before the projection
   --  back.
   --  Where a linear layer's rows for one position are: a session's own
   --  for one token, a batch buffer's slice for one of many. Each is an
   --  array and the origin of the row in it.
   type Linear_Rows is record
      Mixed  : T.Real_Array_Access := null;
      Z_Gate : T.Real_Array_Access := null;
      Alpha  : T.Real_Array_Access := null;
      Beta   : T.Real_Array_Access := null;
      Blend  : T.Real_Array_Access := null;
      M0, Z0, A0, B0, O0 : Element_Count := 0;
   end record;

   --  Where a chunk of positions' rows are: Linear_Rows for the first,
   --  and how far apart the positions lie in each array.
   type Chunk_Rows is record
      First : Linear_Rows;
      Count : Element_Count := 0;
      Mix_Stride, Z_Stride, Head_Stride, Blend_Stride : Element_Count := 0;
   end record;

   --  The rule for a share of the value heads over a chunk of positions,
   --  reading the state once rather than once a position: what the
   --  kernel in Model_Runner.Delta_Rule does, a head at a time, with the
   --  decays and rates a position worked out here from the file's shape
   --  and bias. Heads are independent, so the team takes them in shares.
   type Rule_Share is limited new Workers_CPU.Task_Item with record
      State      : T.Real_Array_Access := null;
      States     : Element_Count := 0;
      Written    : Model_Runner.Delta_Rule.Slot_Origins :=
        [others => Model_Runner.Delta_Rule.Nowhere];
      Head       : Element_Count := 0;
      Keys_Wide  : Element_Count := 0;
      Key_Heads  : Element_Count := 0;
      A_Log      : T.Real_Array_Access := null;
      DT_Bias    : T.Real_Array_Access := null;
      State_Norm : T.Real_Array_Access := null;
      Epsilon    : Real := 0.0;
      Scale      : Real := 0.0;
      Rows       : Chunk_Rows;

      --  False where a share found a row out of its array's reach and
      --  wrote nothing.
      Ok         : Boolean := True;
   end record;

   overriding procedure Run
     (Share : in out Rule_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Rule_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      Head   : constant Element_Count := Share.Head;
      Count  : constant Element_Count := Share.Rows.Count;
      Mixed  : Real_Array renames Share.Rows.First.Mixed.all;
      Z_Gate : Real_Array renames Share.Rows.First.Z_Gate.all;
      Blend  : Real_Array renames Share.Rows.First.Blend.all;
      Alpha  : Real_Array renames Share.Rows.First.Alpha.all;
      Beta   : Real_Array renames Share.Rows.First.Beta.all;
      M0     : constant Element_Count := Share.Rows.First.M0;
      Square : constant Element_Count := Head * Head;
      Decay  : Real_Array (0 .. Count - 1);
      Rate   : Real_Array (0 .. Count - 1);
      Last_Row : constant Element_Count :=
        M0 + (Count - 1) * Share.Rows.Mix_Stride;
   begin
      if From > To then
         return;
      end if;

      --  The reach proved once for the last head of the share; the
      --  kernel checks nothing.
      if Share.Key_Heads = 0 or else Count = 0
        or else Count > Model_Runner.Delta_Rule.Chunk_Most
        or else Share.States + (To + 1) * Square - 1 > Share.State.all'Last
        or else Last_Row + 2 * Share.Keys_Wide + (To + 1) * Head - 1
                > Mixed'Last
        or else Share.Rows.First.O0 + (Count - 1) * Share.Rows.Blend_Stride
                + (To + 1) * Head - 1 > Blend'Last
        or else Share.Rows.First.Z0 + (Count - 1) * Share.Rows.Z_Stride
                + (To + 1) * Head - 1 > Z_Gate'Last
        or else Share.Rows.First.A0 + (Count - 1) * Share.Rows.Head_Stride + To
                > Alpha'Last
        or else Share.Rows.First.B0 + (Count - 1) * Share.Rows.Head_Stride + To
                > Beta'Last
        or else To > Share.A_Log.all'Last
        or else To > Share.DT_Bias.all'Last
        or else Head - 1 > Share.State_Norm.all'Last
      then
         Share.Ok := False;
         return;
      end if;

      for T in 0 .. Count - 1 loop
         if Share.Written (T) /= Model_Runner.Delta_Rule.Nowhere
           and then Share.Written (T) + (To + 1) * Square - 1
                    > Share.State.all'Last
         then
            Share.Ok := False;
            return;
         end if;
      end loop;

      for H in From .. To loop
         declare
            KH : constant Element_Count := H mod Share.Key_Heads;
            Written : Model_Runner.Delta_Rule.Slot_Origins := Share.Written;
         begin
            --  The decays and rates: the file keeps minus the exponential
            --  of the decay's shape, not the shape, so what is stored is
            --  what multiplies.
            for T in 0 .. Count - 1 loop
               Decay (T) :=
                 Real (N.Exp (N.Wide_Real
                   (Share.A_Log.all (H)
                    * Softplus
                        (Alpha (Share.Rows.First.A0
                                + T * Share.Rows.Head_Stride + H)
                         + Share.DT_Bias.all (H)))));
               Rate (T) :=
                 Sigmoid (Beta (Share.Rows.First.B0
                                + T * Share.Rows.Head_Stride + H));
            end loop;

            for T in 0 .. Count - 1 loop
               if Written (T) /= Model_Runner.Delta_Rule.Nowhere then
                  Written (T) := Written (T) + H * Square;
               end if;
            end loop;

            Model_Runner.Delta_Rule.Chunk
              (State        => Share.State.all,
               From         => Share.States + H * Square,
               Written      => Written,
               Head         => Head,
               Count        => Count,
               Mixed        => Mixed,
               Stride       => Share.Rows.Mix_Stride,
               Key_At       => M0 - Mixed'First + Share.Keys_Wide + KH * Head,
               Query_At     => M0 - Mixed'First + KH * Head,
               Value_At     => M0 - Mixed'First + 2 * Share.Keys_Wide + H * Head,
               Decay        => Decay,
               Rate         => Rate,
               Z_Gate       => Z_Gate,
               Z_At         => Share.Rows.First.Z0 + H * Head,
               Z_Stride     => Share.Rows.Z_Stride,
               Blend        => Blend,
               Blend_At     => Share.Rows.First.O0 + H * Head,
               Blend_Stride => Share.Rows.Blend_Stride,
               State_Norm   => Share.State_Norm.all,
               Epsilon      => Share.Epsilon,
               Scale        => Share.Scale);
         end;
      end loop;
   end Run;

   --  The front of a linear layer for a share of the channel blocks over
   --  a chunk of positions: the convolution over each position and the
   --  ones remembered, the unit, and the queries and keys to unit length
   --  -- a block being a head's width, so a query or key head is one
   --  block. Positions go in order within a block, since each reads what
   --  the ones before left; blocks are independent, so the team takes
   --  them in shares.
   type Front_Share is limited new Workers_CPU.Task_Item with record
      Conv      : T.Real_Array_Access := null;
      Kept      : T.Real_Array_Access := null;
      Read      : Element_Count := 0;
      Written   : Model_Runner.Delta_Rule.Slot_Origins :=
        [others => Model_Runner.Delta_Rule.Nowhere];
      Mix       : Element_Count := 0;
      Taps      : Element_Count := 0;
      Head      : Element_Count := 0;
      Unit_Blocks : Element_Count := 0;
      Epsilon   : Real := 0.0;
      Rows      : Chunk_Rows;
      Ok        : Boolean := True;
   end record;

   overriding procedure Run
     (Share : in out Front_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Front_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      Head  : constant Element_Count := Share.Head;
      Count : constant Element_Count := Share.Rows.Count;
      Mix   : constant Element_Count := Share.Mix;
      Taps  : constant Element_Count := Share.Taps;
      Conv  : Real_Array renames Share.Conv.all;
      Kept  : Real_Array renames Share.Kept.all;
      Mixed : Real_Array renames Share.Rows.First.Mixed.all;
      M0    : constant Element_Count := Share.Rows.First.M0;

      --  What the block remembers: Taps - 1 positions' inputs, oldest
      --  first, and this position's on the way through.
      Memory : Real_Array (0 .. (Taps - 1) * Head - 1);
      Fresh  : Real_Array (0 .. Head - 1);
      Made    : Real_Array (0 .. Head - 1);

      --  The reach proved once for the last block of the share and the
      --  checks left out of the loops: with them in, a layer's
      --  convolution over six thousand components read 50 microseconds
      --  a position.
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);
   begin
      if From > To then
         return;
      end if;

      if Count = 0 or else Taps < 2 or else Head = 0
        or else (To + 1) * Head > Mix
        or else Conv'Length /= Taps * Mix
        or else Share.Read + (Taps - 1) * Mix - 1 > Kept'Last
        or else M0 + (Count - 1) * Share.Rows.Mix_Stride + Mix - 1 > Mixed'Last
      then
         Share.Ok := False;
         return;
      end if;

      for T in 0 .. Count - 1 loop
         if Share.Written (T) /= Model_Runner.Delta_Rule.Nowhere
           and then Share.Written (T) + (Taps - 1) * Mix - 1 > Kept'Last
         then
            Share.Ok := False;
            return;
         end if;
      end loop;

      for B in From .. To loop
         declare
            C0 : constant Element_Count := B * Head;
         begin
            for K in 0 .. Taps - 2 loop
               Memory (K * Head .. (K + 1) * Head - 1) :=
                 Kept (Share.Read + K * Mix + C0
                       .. Share.Read + K * Mix + C0 + Head - 1);
            end loop;

            for T in 0 .. Count - 1 loop
               declare
                  R0 : constant Element_Count :=
                    M0 + T * Share.Rows.Mix_Stride + C0;
                  Last : constant Element_Count := (Taps - 1) * Mix + C0;
               begin
                  Fresh := Mixed (R0 .. R0 + Head - 1);

                  for C in 0 .. Head - 1 loop
                     Made (C) := Fresh (C) * Conv (Last + C);
                  end loop;

                  for K in 0 .. Taps - 2 loop
                     declare
                        Tap : constant Element_Count := K * Mix + C0;
                        Mem : constant Element_Count := K * Head;
                     begin
                        for C in 0 .. Head - 1 loop
                           Made (C) := Made (C) + Memory (Mem + C) * Conv (Tap + C);
                        end loop;
                     end;
                  end loop;

                  --  The memory moved up a position: the inputs but the
                  --  oldest, and this position's under the last.
                  for K in 0 .. Taps - 3 loop
                     Memory (K * Head .. (K + 1) * Head - 1) :=
                       Memory ((K + 1) * Head .. (K + 2) * Head - 1);
                  end loop;
                  Memory ((Taps - 2) * Head .. (Taps - 1) * Head - 1) := Fresh;

                  if Share.Written (T) /= Model_Runner.Delta_Rule.Nowhere then
                     for K in 0 .. Taps - 2 loop
                        Kept (Share.Written (T) + K * Mix + C0
                              .. Share.Written (T) + K * Mix + C0 + Head - 1) :=
                          Memory (K * Head .. (K + 1) * Head - 1);
                     end loop;
                  end if;

                  --  The unit -- the row times its own logistic, through
                  --  the kernel that takes the exponential in binary32 --
                  --  and a query or key head to unit length.
                  K.SiLU (Made);

                  if B < Share.Unit_Blocks then
                     declare
                        Sum : Real := 0.0;
                     begin
                        for C in 0 .. Head - 1 loop
                           Sum := Sum + Made (C) * Made (C);
                        end loop;

                        declare
                           Unit : constant Real :=
                             1.0 / Real'Max (Real (N.Sqrt (N.Wide_Real (Sum))),
                                             Share.Epsilon);
                        begin
                           for C in 0 .. Head - 1 loop
                              Made (C) := Made (C) * Unit;
                           end loop;
                        end;
                     end;
                  end if;

                  Mixed (R0 .. R0 + Head - 1) := Made;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  A chunk of positions of one linear layer past its projections: the
   --  front over the channel blocks, then the rule over the heads, each
   --  shared out. Within it a position's state and memory are kept where
   --  the ring reaches them -- the last Kept_States positions and the last
   --  of all -- and dropped otherwise. More positions than a chunk holds
   --  go a chunk at a time, each leaving its last state and memory where
   --  the next reads them.
   procedure Linear_Chunk
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Position    : Natural;
      Rows        : Chunk_Rows;
      Status      : out E.Error_Info)
   is
      Settings : Configuration renames Source.Settings;
      Head     : constant Element_Count :=
        Element_Count (Settings.State_Size);
      Mix      : constant Element_Count := Element_Count (Mix_Width (Settings));
      Taps     : constant Element_Count :=
        Element_Count (Settings.Conv_Kernel);
      States   : constant Element_Count := State_At (Settings, Layer_Index);
      Memory   : constant Element_Count := Conv_At (Settings, Layer_Index);
      Every    : constant Element_Count := State_Room (Settings);
      Every_Conv : constant Element_Count := Conv_Room (Settings);
      Value_Heads : constant Element_Count :=
        Element_Count (Settings.Value_Heads);
      Taken    : Element_Count := 0;
   begin
      Status := E.Success;

      if Taps < 2 or else Head = 0 or else Mix mod Head /= 0
        or else Rows.First.Mixed = null or else Rows.First.Blend = null
        or else Rows.First.Z_Gate = null or else Rows.First.Alpha = null
        or else Rows.First.Beta = null
        or else Current.Conv = null or else Item.Conv_State = null
        or else Item.Delta_State = null
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Text (Status, "tensor", "ssm_conv1d", E.Param_Identifier);
         return;
      end if;

      --  The ring as the device left it, where a layer before this one
      --  went whole there.
      Fetch_States (Item'Unchecked_Access);
      Item.Ring_Written := True;

      while Taken < Rows.Count loop
         declare
            Here  : constant Element_Count :=
              Element_Count'Min
                (Model_Runner.Delta_Rule.Chunk_Most, Rows.Count - Taken);
            First : constant Natural := Position + Natural (Taken);
            Chunk : constant Chunk_Rows :=
              (First =>
                 (Mixed  => Rows.First.Mixed,
                  Z_Gate => Rows.First.Z_Gate,
                  Alpha  => Rows.First.Alpha,
                  Beta   => Rows.First.Beta,
                  Blend  => Rows.First.Blend,
                  M0 => Rows.First.M0 + Taken * Rows.Mix_Stride,
                  Z0 => Rows.First.Z0 + Taken * Rows.Z_Stride,
                  A0 => Rows.First.A0 + Taken * Rows.Head_Stride,
                  B0 => Rows.First.B0 + Taken * Rows.Head_Stride,
                  O0 => Rows.First.O0 + Taken * Rows.Blend_Stride),
               Count => Here,
               Mix_Stride => Rows.Mix_Stride,
               Z_Stride => Rows.Z_Stride,
               Head_Stride => Rows.Head_Stride,
               Blend_Stride => Rows.Blend_Stride);

            Written_State : Model_Runner.Delta_Rule.Slot_Origins :=
              [others => Model_Runner.Delta_Rule.Nowhere];
            Written_Conv  : Model_Runner.Delta_Rule.Slot_Origins :=
              [others => Model_Runner.Delta_Rule.Nowhere];
         begin
            for T in 0 .. Here - 1 loop
               if T = Here - 1
                 or else (Item.Kept_States > 0
                          and then T + Element_Count (Item.Kept_States) + 1
                                   >= Here)
               then
                  Written_State (T) :=
                    State_Slot (Item, First + Natural (T) + 1) * Every + States;
                  Written_Conv (T) :=
                    State_Slot (Item, First + Natural (T) + 1) * Every_Conv
                    + Memory;
               end if;
            end loop;

            declare
               Front : aliased Front_Share :=
                 (Conv      => Current.Conv,
                  Kept      => Item.Conv_State,
                  Read      => State_Slot (Item, First) * Every_Conv + Memory,
                  Written   => Written_Conv,
                  Mix       => Mix,
                  Taps      => Taps,
                  Head      => Head,
                  Unit_Blocks => 2 * Element_Count (Settings.Key_Heads),
                  Epsilon   => Settings.Epsilon,
                  Rows      => Chunk,
                  Ok        => True);
            begin
               Workers_CPU.Dispatch_Shares
                 (Item.Team, Mix / Head, Front'Unchecked_Access, Status,
                  Cost => Mix * Taps * Here);
               if E.Is_Error (Status) then
                  return;
               end if;

               if not Front.Ok then
                  Status := E.Make (E.Tensor_Shape_Mismatch);
                  E.Add_Text
                    (Status, "tensor", "ssm_conv1d", E.Param_Identifier);
                  return;
               end if;
            end;

            declare
               Share : aliased Rule_Share :=
                 (State      => Item.Delta_State,
                  States     => State_Slot (Item, First) * Every + States,
                  Written    => Written_State,
                  Head       => Head,
                  Keys_Wide  => Element_Count (Key_Width (Settings)),
                  Key_Heads  => Element_Count (Settings.Key_Heads),
                  A_Log      => Current.A_Log,
                  DT_Bias    => Current.DT_Bias,
                  State_Norm => Current.State_Norm,
                  Epsilon    => Settings.Epsilon,
                  Scale      =>
                    Real (1.0 / N.Sqrt (N.Wide_Real (Settings.State_Size))),
                  Rows       => Chunk,
                  Ok         => True);
            begin
               Workers_CPU.Dispatch_Shares
                 (Item.Team, Value_Heads, Share'Unchecked_Access, Status,
                  Cost => Value_Heads * Head * Head * 3 * Here);
               if E.Is_Error (Status) then
                  return;
               end if;

               if not Share.Ok then
                  Status := E.Make (E.Tensor_Shape_Mismatch);
                  E.Add_Text
                    (Status, "tensor", "ssm_state", E.Param_Identifier);
                  return;
               end if;
            end;

            Taken := Taken + Here;
         end;
      end loop;

      --  The ring reaches from the last position back, and no further.
      Item.Kept_Newest :=
        Natural'Max (Item.Kept_Newest, Position + Natural (Rows.Count));
   end Linear_Chunk;

   --  Mamba's causal convolution over a batch, a share of the channels
   --  each: a channel's last Taps activations, oldest first and this one
   --  last, against its taps, biased, a position at a time, and its memory
   --  slid on after each. Channels share nothing, so the team takes them.
   --  Width is the channels convolved; a position's inputs are Width
   --  consecutive numbers Shift into its row of XZ, rows Stride apart.
   --  Mamba convolves its inner activation, the front of a row of the
   --  activation and the gate; Mamba2 the activation with B and C, past
   --  the gate at the front of its one projection in.
   type Mamba_Conv_Share is limited new Workers_CPU.Task_Item with record
      Count  : Element_Count := 0;
      Inner  : Element_Count := 0;
      Stride : Element_Count := 0;
      Shift  : Element_Count := 0;
      Taps   : Element_Count := 0;
      Base   : Element_Count := 0;
      Memory : T.Real_Array_Access := null;
      Conv   : T.Real_Array_Access := null;
      Bias   : T.Real_Array_Access := null;
      XZ     : T.Real_Array_Access := null;
      Xc     : T.Real_Array_Access := null;

      --  Whether the share puts each row it convolved through the
      --  logistic-weighted unit as well, rather than the calling task
      --  putting all of them through it after, alone, while the workers
      --  wait.
      Unit   : Boolean := False;
   end record;

   overriding procedure Run
     (Share : in out Mamba_Conv_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Mamba_Conv_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Inner  : constant Element_Count := Share.Inner;
      Taps   : constant Element_Count := Share.Taps;
      Back   : constant Element_Count := Taps - 1;
      Base   : constant Element_Count := Share.Base;
      Count  : constant Element_Count := Share.Count;
      Memory : Real_Array renames Share.Memory.all;
      Conv   : Real_Array renames Share.Conv.all;

      --  Position Q's input to channel C, Q counted from the batch's first
      --  and signed: a position before it is in the memory, oldest first.
      function Input (C : Element_Count; Q : Long_Long_Integer) return Real
      is (if Q >= 0
          then Share.XZ (Element_Count (Q) * Share.Stride + Share.Shift + C)
          else Memory (Base + Element_Count (Q + Long_Long_Integer (Back))
                              * Inner + C));
   begin
      --  A position at a time and the share's channels within it, so that a
      --  position's inputs are read along its row rather than across rows.
      for P in 0 .. Count - 1 loop
         if P >= Back then
            --  Every input in the batch: read straight from its rows.
            declare
               First_Row : constant Element_Count :=
                 (P - Back) * Share.Stride + Share.Shift;
            begin
               for C in From .. To loop
                  declare
                     Acc : Real := Share.Bias (C);
                  begin
                     for K_At in 0 .. Taps - 1 loop
                        Acc := Acc
                          + Conv (C * Taps + K_At)
                            * Share.XZ (First_Row + K_At * Share.Stride + C);
                     end loop;
                     Share.Xc (P * Inner + C) := Acc;
                  end;
               end loop;
            end;
         else
            for C in From .. To loop
               declare
                  Acc : Real := Share.Bias (C);
               begin
                  for K_At in 0 .. Taps - 1 loop
                     Acc := Acc
                       + Conv (C * Taps + K_At)
                         * Input (C, Long_Long_Integer (P + K_At)
                                     - Long_Long_Integer (Back));
                  end loop;
                  Share.Xc (P * Inner + C) := Acc;
               end;
            end loop;
         end if;

         if Share.Unit then
            K.SiLU (Share.Xc.all (P * Inner + From .. P * Inner + To));
         end if;
      end loop;

      --  The memory taken on past the batch once, at its end: the last
      --  Back inputs, each read before it is overwritten -- a slot is
      --  filled from a later one, or from the batch.
      for J in 0 .. Back - 1 loop
         for C in From .. To loop
            Memory (Base + J * Inner + C) :=
              Input (C, Long_Long_Integer (Count + J)
                        - Long_Long_Integer (Back));
         end loop;
      end loop;
   end Run;

   --  The selective scan over a batch, a share of the channels each:
   --  channels are independent of each other, and within one the positions
   --  go in order, each reading the state the one before it left. For a
   --  channel and a position, the time step through the softplus; the
   --  state decayed by exp (dt * A) and driven by B times the input times
   --  the step; the answer C against the state, the skip D times the input
   --  added, and the gate applied.
   type Mamba_Scan_Share is limited new Workers_CPU.Task_Item with record
      Count  : Element_Count := 0;
      Inner  : Element_Count := 0;
      State  : Element_Count := 0;
      Rank   : Element_Count := 0;
      Base   : Element_Count := 0;
      H      : T.Real_Array_Access := null;
      A      : T.Real_Array_Access := null;
      D      : T.Real_Array_Access := null;
      Xc     : T.Real_Array_Access := null;
      DT     : T.Real_Array_Access := null;
      DBC    : T.Real_Array_Access := null;
      XZ     : T.Real_Array_Access := null;
      Y      : T.Real_Array_Access := null;

      --  A token's step sizes made here rather than before: each share
      --  projects its own channels' rows of the step projection from DTR
      --  and adds their bias, which saves a job of the pool a layer -- 17
      --  us of Jamba's, nearly all of it the job and not the bytes. An
      --  item is then sixteen channels, a whole number of panels.
      Fused   : Boolean := False;
      Dt_View : T.View := T.Empty_View;
      Dt_Bias : T.Real_Array_Access := null;
      DTR     : T.Real_Array_Access := null;
      Roles   : Workers_CPU.Role_Set := Workers_CPU.Integer_Activation_Roles;

      --  DTR packed once for every share, or null where it was not: a
      --  share packing it itself was four allocations and as many
      --  releases around a product of a few microseconds.
      Packed  : access constant Workers_CPU.Packed_Rows := null;

      --  The session's step sizes and decays, a channel's at the channel:
      --  the shares' channels do not overlap, so neither do their runs.
      Steps   : T.Real_Array_Access := null;
      Decays  : T.Real_Array_Access := null;
      Ok      : Boolean := True;
   end record;

   --  Channels an item of a fused scan holds.
   Fused_Channels : constant Element_Count := 16;

   overriding procedure Run
     (Share : in out Mamba_Scan_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Mamba_Scan_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Inner : constant Element_Count := Share.Inner;
      State : constant Element_Count := Share.State;
      Rank  : constant Element_Count := Share.Rank;
      Wide  : constant Element_Count := Rank + 2 * State;

      H   : Real_Array renames Share.H.all;
      A   : Real_Array renames Share.A.all;

      Lo : constant Element_Count :=
        (if Share.Fused then From * Fused_Channels else From);
      Hi : constant Element_Count :=
        (if Share.Fused
         then Element_Count'Min ((To + 1) * Fused_Channels, Inner) - 1
         else To);

      Channels : constant Element_Count := Hi - Lo + 1;

      --  Every channel's step size and decays for a position, made before
      --  any channel reads them: the decays as one run through the kernels'
      --  binary32 exponential, as llama.cpp's scan takes it. It was a run
      --  of sixteen a channel, and the call and its constants were most of
      --  a token's scan -- 59 us a share of 1,024 channels of Jamba.
      Steps  : Real_Array renames Share.Steps.all;
      Decays : Real_Array renames Share.Decays.all;

      function Softplus (X : N.Wide_Real) return N.Wide_Real
      is (if X > 20.0 then X else N.Log (1.0 + N.Exp (X)));
   begin
      if Lo > Hi then
         return;
      end if;

      if Share.Fused then
         declare
            Slice  : constant T.View :=
              Row_Slice (Share.Dt_View, Lo, Channels);
            Local  : E.Error_Info := E.Success;
            Packed : Boolean := False;
         begin
            if Share.Packed /= null then
               Workers_CPU.Multiply_Packed_Whole
                 (Slice, Share.Packed.all, Steps (Lo .. Hi), Packed);
            end if;
            if not Packed then
               --  Its own answer, not the session's: the start of that is
               --  another share's channels.
               declare
                  Own : T.Real_Array_Access;
               begin
                  T.Allocate (Channels, Own);
                  if Own = null then
                     Share.Ok := False;
                     return;
                  end if;
                  Workers_CPU.Dispatch_Batch
                    (null, Slice, Share.DTR, 1, Own, Local,
                     Roles => Share.Roles);
                  if E.Is_Ok (Local) then
                     Steps (Lo .. Hi) := Own (0 .. Channels - 1);
                  end if;
                  T.Free (Own);
               end;
            end if;
            if E.Is_Error (Local) then
               Share.Ok := False;
               return;
            end if;
            for C in Lo .. Hi loop
               Share.DT (C) := Steps (C) + Share.Dt_Bias (C);
            end loop;
         end;
      end if;

      for P in 0 .. Share.Count - 1 loop
         for C in Lo .. Hi loop
            declare
               Dt_Soft : constant Real :=
                 Real (Softplus (N.Wide_Real (Share.DT (P * Inner + C))));
               At_C    : constant Element_Count := C * State;
            begin
               Steps (C) := Dt_Soft;
               for S in 0 .. State - 1 loop
                  Decays (At_C + S) := Dt_Soft * A (C * State + S);
               end loop;
            end;
         end loop;
         K.Exponentiate (Decays (Lo * State .. (Hi + 1) * State - 1), 0.0);

         for C in Lo .. Hi loop
            declare
               Cells   : constant Element_Count := Share.Base + C * State;
               At_C    : constant Element_Count := C * State;
               X       : constant Real := Share.Xc (P * Inner + C);
               X_Dt    : constant Real := X * Steps (C);
               Row     : constant Element_Count := P * Wide;
               Sum     : Real := 0.0;
               Z       : constant N.Wide_Real :=
                 N.Wide_Real (Share.XZ (P * 2 * Inner + Inner + C));
            begin
               for S in 0 .. State - 1 loop
                  declare
                     New_H : constant Real :=
                       H (Cells + S) * Decays (At_C + S)
                       + Share.DBC (Row + Rank + S) * X_Dt;
                  begin
                     H (Cells + S) := New_H;
                     Sum := Sum + Share.DBC (Row + Rank + State + S) * New_H;
                  end;
               end loop;

               Share.Y (P * Inner + C) :=
                 Real ((N.Wide_Real (Sum)
                        + N.Wide_Real (Share.D (C)) * N.Wide_Real (X))
                       * (Z / (1.0 + N.Exp (-Z))));
            end;
         end loop;
      end loop;
   end Run;

   --  Count positions through one Mamba layer: Rows holds their normalized
   --  inputs, Width apart, and is left holding the block's outputs in their
   --  place. Every projection is taken once over the batch; the causal
   --  convolution goes position by position, since each reads the ones
   --  before it, but it reads only the projection in and not the scan, so it
   --  is done whole before the scan begins; and the scan is the team's,
   --  a share of the channels each. A generated token is a batch of one.
   procedure Mamba_Batch
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Rows        : T.Real_Array_Access;
      Count       : Element_Count;
      Status      : out E.Error_Info)
   is separate;

   --  One position through one Mamba layer, on the host: Mamba_Batch over a
   --  batch of one. It reads the layer's normalized input in
   --  Item.Normalized and leaves the block's output there for the residual
   --  to take, carrying the convolution's memory and the scan's state a
   --  session in the same ring a hybrid's linear layers use -- one slot,
   --  since Mamba neither drafts nor rewinds.
   --
   --  The block: the input projected to an inner activation and its gate; a
   --  depthwise causal convolution over the activation, biased and passed
   --  through a sigmoid-weighted unit; that projected to a time step and to
   --  B and C; the time step projected up and biased; the selective scan,
   --  channel by channel over the state; the skip added; the gate applied;
   --  and the projection back. The transition A is already the negative
   --  exponential the file stores, and the time step's softplus is taken
   --  here, in the scan, where the reference implementation takes it too.
   procedure Mamba_Step
     (Item    : in out Session;
      Source  : Model'Class;
      Current : Layer;
      Layer_Index : Natural;
      Status  : out E.Error_Info)
   is
   begin
      Mamba_Batch
        (Item, Source, Current, Layer_Index, Item.Normalized, 1, Status);
   end Mamba_Step;

   --  One position through one Mamba2 layer, on the host. Mamba's block
   --  restructured: one projection in lays out the gate, the inner
   --  activation, B and C and a time step a head end to end; the causal
   --  convolution runs over the activation with B and C beside it, all
   --  through a sigmoid-weighted unit; the scan is a head rather than a
   --  channel -- a scalar decay a head, B and C shared across the heads of
   --  a group -- and the skip is a head; and the answer is gated by the
   --  input's gate and normalized in groups before the projection back,
   --  where Mamba only gates. State and convolution memory carry a session
   --  in the same one-slot ring, since Mamba2 neither drafts nor rewinds.
   --  Mamba2's scan over a batch, a share of the heads each: a head
   --  decays by one scalar a position, reads its group's B and C, and its
   --  channels -- Head_Dim of them -- each keep a row of the state. Within
   --  a head the positions go in order.
   type Mamba2_Scan_Share is limited new Workers_CPU.Task_Item with record
      Count  : Element_Count := 0;
      Inner  : Element_Count := 0;
      State  : Element_Count := 0;
      Group  : Element_Count := 0;
      Per_G  : Element_Count := 0;
      Heads  : Element_Count := 0;
      Wide   : Element_Count := 0;
      DXBC   : Element_Count := 0;
      Base   : Element_Count := 0;
      H      : T.Real_Array_Access := null;
      D      : T.Real_Array_Access := null;
      Steps  : T.Real_Array_Access := null;
      Decays : T.Real_Array_Access := null;
      Xc     : T.Real_Array_Access := null;
      Y      : T.Real_Array_Access := null;
   end record;

   overriding procedure Run
     (Share : in out Mamba2_Scan_Share;
      From  : Element_Count;
      To    : Element_Count);

   --  A share is a run of channels rather than of heads: a head is Head_Dim
   --  channels, each with its own row of the state, and twenty-four heads
   --  on eight workers left a third of them idle for the last round. The
   --  head's step and decay a position are worked out once, before.
   overriding procedure Run
     (Share : in out Mamba2_Scan_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Inner : constant Element_Count := Share.Inner;
      State : constant Element_Count := Share.State;
      DXBC  : constant Element_Count := Share.DXBC;
      Whole : constant Element_Count := State - State mod 8;
      H     : Real_Array renames Share.H.all;
      Xc    : Real_Array renames Share.Xc.all;
   begin
      --  A position at a time, the share's channels within it: a channel's
      --  positions still go in order, and a position's activations are read
      --  along its row.
      for P in 0 .. Share.Count - 1 loop
         declare
            Row : constant Element_Count := P * DXBC;
         begin
            for Ch in From .. To loop
               declare
                  Hd    : constant Element_Count := Ch / Share.Wide;
                  Cells : constant Element_Count := Share.Base + Ch * State;
                  G_At  : constant Element_Count :=
                    Row + Inner + (Hd / Share.Per_G) * State;
                  C_At  : constant Element_Count := G_At + Share.Group * State;
                  dA    : constant Real := Share.Decays (P * Share.Heads + Hd);
                  X     : constant Real := Xc (Row + Ch);
                  X_Dt  : constant Real :=
                    X * Share.Steps (P * Share.Heads + Hd);

                  --  Eight running sums rather than one: a single sum over
                  --  a head's 128 states is a chain of 128 dependent
                  --  additions, and that chain was the scan.
                  L0, L1, L2, L3, L4, L5, L6, L7 : Real := 0.0;
                  Sum : Real := 0.0;
               begin
                  --  The update and the answer in one walk of the row: the row
                  --  is read and written once rather than twice, each sum
                  --  taking the same terms in the same order.
                  for S in 0 .. Whole / 8 - 1 loop
                     declare
                        At_B : constant Element_Count := G_At + S * 8;
                        At_C : constant Element_Count := C_At + S * 8;
                        At_H : constant Element_Count := Cells + S * 8;
                        H0 : constant Real := H (At_H) * dA + Xc (At_B) * X_Dt;
                        H1 : constant Real :=
                          H (At_H + 1) * dA + Xc (At_B + 1) * X_Dt;
                        H2 : constant Real :=
                          H (At_H + 2) * dA + Xc (At_B + 2) * X_Dt;
                        H3 : constant Real :=
                          H (At_H + 3) * dA + Xc (At_B + 3) * X_Dt;
                        H4 : constant Real :=
                          H (At_H + 4) * dA + Xc (At_B + 4) * X_Dt;
                        H5 : constant Real :=
                          H (At_H + 5) * dA + Xc (At_B + 5) * X_Dt;
                        H6 : constant Real :=
                          H (At_H + 6) * dA + Xc (At_B + 6) * X_Dt;
                        H7 : constant Real :=
                          H (At_H + 7) * dA + Xc (At_B + 7) * X_Dt;
                     begin
                        H (At_H) := H0;
                        H (At_H + 1) := H1;
                        H (At_H + 2) := H2;
                        H (At_H + 3) := H3;
                        H (At_H + 4) := H4;
                        H (At_H + 5) := H5;
                        H (At_H + 6) := H6;
                        H (At_H + 7) := H7;
                        L0 := L0 + Xc (At_C) * H0;
                        L1 := L1 + Xc (At_C + 1) * H1;
                        L2 := L2 + Xc (At_C + 2) * H2;
                        L3 := L3 + Xc (At_C + 3) * H3;
                        L4 := L4 + Xc (At_C + 4) * H4;
                        L5 := L5 + Xc (At_C + 5) * H5;
                        L6 := L6 + Xc (At_C + 6) * H6;
                        L7 := L7 + Xc (At_C + 7) * H7;
                     end;
                  end loop;
                  for S in Whole .. State - 1 loop
                     H (Cells + S) := H (Cells + S) * dA + Xc (G_At + S) * X_Dt;
                     L0 := L0 + Xc (C_At + S) * H (Cells + S);
                  end loop;
                  Sum := ((L0 + L1) + (L2 + L3)) + ((L4 + L5) + (L6 + L7));
                  Share.Y (P * Inner + Ch) := Sum + Share.D (Hd) * X;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  Mamba2's gate and grouped normalization over a batch, a share of the
   --  positions each: the answer weighted by the sigmoid-weighted front of
   --  the position's projection in, then normalized by root mean square in
   --  groups -- the width B and C share -- and scaled by the gain.
   type Mamba2_Gate_Share is limited new Workers_CPU.Task_Item with record
      Inner   : Element_Count := 0;
      In_Out  : Element_Count := 0;
      Group   : Element_Count := 0;
      Epsilon : Real := 0.0;
      Gain    : T.Real_Array_Access := null;
      XZ      : T.Real_Array_Access := null;
      Y       : T.Real_Array_Access := null;
   end record;

   overriding procedure Run
     (Share : in out Mamba2_Gate_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Mamba2_Gate_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Inner : constant Element_Count := Share.Inner;
      Grp_W : constant Element_Count := Inner / Share.Group;
      Y     : Real_Array renames Share.Y.all;
      Gate  : Real_Array (0 .. Inner - 1);
   begin
      for P in From .. To loop
         Gate := Share.XZ (P * Share.In_Out .. P * Share.In_Out + Inner - 1);
         K.SiLU (Gate);
         for C in 0 .. Inner - 1 loop
            Y (P * Inner + C) := Y (P * Inner + C) * Gate (C);
         end loop;

         for Grp in 0 .. Share.Group - 1 loop
            declare
               At_G : constant Element_Count := P * Inner + Grp * Grp_W;
               Sum  : N.Wide_Real := 0.0;
               Rms  : Real;
            begin
               for I in 0 .. Grp_W - 1 loop
                  Sum := Sum + N.Wide_Real (Y (At_G + I))
                               * N.Wide_Real (Y (At_G + I));
               end loop;
               Rms := Real (1.0 / N.Sqrt
                                    (Sum / N.Wide_Real (Grp_W)
                                     + N.Wide_Real (Share.Epsilon)));
               for I in 0 .. Grp_W - 1 loop
                  Y (At_G + I) :=
                    Y (At_G + I) * Rms * Share.Gain (Grp * Grp_W + I);
               end loop;
            end;
         end loop;
      end loop;
   end Run;

   --  Count positions through one Mamba2 layer, as Mamba_Batch takes
   --  them through a Mamba one: the projections in and out over the batch,
   --  the convolution and the scan the team's, and between them the gate
   --  and the grouped normalization, a position at a time.
   procedure Mamba2_Batch
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Rows        : T.Real_Array_Access;
      Count       : Element_Count;
      Whole       : out Boolean;
      Status      : out E.Error_Info)
   is separate;

   procedure Mamba2_Step
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Whole       : out Boolean;
      Status      : out E.Error_Info)
   is
   begin
      Mamba2_Batch
        (Item, Source, Current, Layer_Index, Item.Normalized, 1, Whole,
         Status);
   end Mamba2_Step;

   --  A small binary32 table against a batch of vectors, a share of the
   --  table's rows each: Out (P, J) := the unit of Tab (J) . X (P), the
   --  vector read Seg_Width further along for every Seg_Rows rows -- RWKV6's
   --  second shift projection reads each stream's own ranks. Kind 0 is no
   --  unit, 1 the hyperbolic tangent, 2 the decay exp (-exp (Bias + x)).
   type Table_Share is limited new Workers_CPU.Task_Item with record
      Tab        : T.Real_Array_Access := null;
      Width      : Element_Count := 0;
      X          : T.Real_Array_Access := null;
      X_Stride   : Element_Count := 0;
      Seg_Rows   : Element_Count := 1;
      Seg_Width  : Element_Count := 0;
      Count      : Element_Count := 0;
      Out_Rows   : T.Real_Array_Access := null;
      Out_Stride : Element_Count := 0;
      Kind       : Natural := 0;
      Bias       : T.Real_Array_Access := null;
   end record;

   overriding procedure Run
     (Share : in out Table_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Table_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Width : constant Element_Count := Share.Width;
      Whole : constant Element_Count := Width - Width mod 8;
      Tab   : Real_Array renames Share.Tab.all;
      X     : Real_Array renames Share.X.all;
   begin
      for J in From .. To loop
         declare
            Row  : constant Element_Count := J * Width;
            Xoff : constant Element_Count :=
              (J / Share.Seg_Rows) * Share.Seg_Width;
         begin
            for P in 0 .. Share.Count - 1 loop
               declare
                  At_X : constant Element_Count := P * Share.X_Stride + Xoff;
                  L0, L1, L2, L3, L4, L5, L6, L7 : Real := 0.0;
                  Acc : N.Wide_Real;
               begin
                  for C in 0 .. Whole / 8 - 1 loop
                     declare
                        A : constant Element_Count := Row + C * 8;
                        B : constant Element_Count := At_X + C * 8;
                     begin
                        L0 := L0 + Tab (A) * X (B);
                        L1 := L1 + Tab (A + 1) * X (B + 1);
                        L2 := L2 + Tab (A + 2) * X (B + 2);
                        L3 := L3 + Tab (A + 3) * X (B + 3);
                        L4 := L4 + Tab (A + 4) * X (B + 4);
                        L5 := L5 + Tab (A + 5) * X (B + 5);
                        L6 := L6 + Tab (A + 6) * X (B + 6);
                        L7 := L7 + Tab (A + 7) * X (B + 7);
                     end;
                  end loop;
                  for C in Whole .. Width - 1 loop
                     L0 := L0 + Tab (Row + C) * X (At_X + C);
                  end loop;
                  Acc := N.Wide_Real (((L0 + L1) + (L2 + L3))
                                      + ((L4 + L5) + (L6 + L7)));
                  Share.Out_Rows (P * Share.Out_Stride + J) :=
                    (case Share.Kind is
                        when 1 => Real (N.Tanh (Acc)),
                        when 2 =>
                          Real (N.Exp (-N.Exp (N.Wide_Real (Share.Bias (J))
                                               + Acc))),
                        when others => Real (Acc));
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  RWKV6's linear-attention recurrence over a batch, a share of the heads
   --  each: a head's state is its width by its width, and the positions go
   --  in order, each answer reading the state before the update with the
   --  bonus lifting the position's own key-value out of the decay.
   type Wkv_Share is limited new Workers_CPU.Task_Item with record
      Count : Element_Count := 0;
      RW    : Element_Count := 0;
      HN    : Element_Count := 0;
      Base  : Element_Count := 0;
      St    : T.Real_Array_Access := null;
      U     : T.Real_Array_Access := null;
      R     : T.Real_Array_Access := null;
      K_Row : T.Real_Array_Access := null;
      V     : T.Real_Array_Access := null;
      W     : T.Real_Array_Access := null;
      Y     : T.Real_Array_Access := null;
   end record;

   overriding procedure Run
     (Share : in out Wkv_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Wkv_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      HN : constant Element_Count := Share.HN;
      St : Real_Array renames Share.St.all;
      Y  : Real_Array renames Share.Y.all;
   begin
      for H in From .. To loop
         declare
            SB : constant Element_Count := Share.Base + H * HN * HN;
         begin
            for P in 0 .. Share.Count - 1 loop
               declare
                  At_Row : constant Element_Count := P * Share.RW + H * HN;
               begin
                  for J in 0 .. HN - 1 loop
                     Y (At_Row + J) := 0.0;
                  end loop;
                  --  A row of the state a key element, so the update and
                  --  the answer run along the value width.
                  for I in 0 .. HN - 1 loop
                     declare
                        Ki   : constant Real := Share.K_Row (At_Row + I);
                        Ri   : constant Real := Share.R (At_Row + I);
                        Ui   : constant Real := Share.U (H * HN + I);
                        Wi   : constant Real := Share.W (At_Row + I);
                        Cell : constant Element_Count := SB + I * HN;
                     begin
                        for J in 0 .. HN - 1 loop
                           declare
                              KV  : constant Real :=
                                Ki * Share.V (At_Row + J);
                              Old : constant Real := St (Cell + J);
                           begin
                              Y (At_Row + J) :=
                                Y (At_Row + J) + Ri * (Ui * KV + Old);
                              St (Cell + J) := Wi * Old + KV;
                           end;
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  The answer's per-head normalization -- centred, a floor of its own --
   --  scaled by the stored gain and shift, then weighted by the
   --  sigmoid-weighted gate, a share of the positions each.
   type Wkv_Out_Share is limited new Workers_CPU.Task_Item with record
      RW    : Element_Count := 0;
      HN    : Element_Count := 0;
      Gain  : T.Real_Array_Access := null;
      Shift : T.Real_Array_Access := null;
      G     : T.Real_Array_Access := null;
      Y     : T.Real_Array_Access := null;
   end record;

   overriding procedure Run
     (Share : in out Wkv_Out_Share;
      From  : Element_Count;
      To    : Element_Count);

   overriding procedure Run
     (Share : in out Wkv_Out_Share;
      From  : Element_Count;
      To    : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      RW    : constant Element_Count := Share.RW;
      HN    : constant Element_Count := Share.HN;
      Floor : constant N.Wide_Real := 64.0e-5;
      Y     : Real_Array renames Share.Y.all;
      Gate  : Real_Array (0 .. RW - 1);
   begin
      for P in From .. To loop
         for H in 0 .. RW / HN - 1 loop
            declare
               Base : constant Element_Count := P * RW + H * HN;
               Mean : N.Wide_Real := 0.0;
               Var  : N.Wide_Real := 0.0;
               Inv  : Real;
               M    : Real;
            begin
               for I in 0 .. HN - 1 loop
                  Mean := Mean + N.Wide_Real (Y (Base + I));
               end loop;
               Mean := Mean / N.Wide_Real (HN);
               for I in 0 .. HN - 1 loop
                  Var := Var
                    + (N.Wide_Real (Y (Base + I)) - Mean)
                      * (N.Wide_Real (Y (Base + I)) - Mean);
               end loop;
               Inv := Real (1.0 / N.Sqrt (Var / N.Wide_Real (HN) + Floor));
               M := Real (Mean);
               for I in 0 .. HN - 1 loop
                  Y (Base + I) :=
                    (Y (Base + I) - M) * Inv * Share.Gain (H * HN + I)
                    + Share.Shift (H * HN + I);
               end loop;
            end;
         end loop;

         Gate := Share.G (P * RW .. P * RW + RW - 1);
         K.SiLU (Gate);
         for C in 0 .. RW - 1 loop
            Y (P * RW + C) := Y (P * RW + C) * Gate (C);
         end loop;
      end loop;
   end Run;

   --  Count positions through one RWKV6 block. Cur holds their ln1 outputs
   --  and Acts their residual stream, Width apart; Into receives the block's
   --  output -- both residuals taken, and the rescale -- and may be Acts. The
   --  token shifts are a subtraction a position; every projection, large or
   --  small, is taken once over the batch; the recurrence is the team's, a
   --  share of the heads each, its positions in order. A generated token is
   --  a batch of one.
   procedure RWKV6_Batch
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Cur         : T.Real_Array_Access;
      Acts        : T.Real_Array_Access;
      Count       : Element_Count;
      Into        : T.Real_Array_Access;
      Whole       : out Boolean;
      Status      : out E.Error_Info)
   is separate;

   --  One position through one RWKV6 layer, on the host. Two sublayers each
   --  with its own residual, and no attention or feed-forward: a time mix
   --  where attention would be and a channel mix where the feed-forward
   --  would be, each shifted against the position before through a
   --  data-dependent interpolation, the time mix keeping a linear-attention
   --  state a head and the channel mix a squared-ReLU gate. Every
   --  normalization centres and carries a shift (LayerNorm, not root mean
   --  square). The block's output is halved every so many layers.
   --
   --  On entry Item.Normalized holds ln1 of the block input (the dispatch
   --  computed it); Item.Activation is the residual stream. The step owns
   --  both residuals and writes the block's output back into Item.Activation,
   --  so the dispatch does not join afterwards. It carries the two
   --  token-shift slots in the convolution memory and the state in the delta
   --  state, one slot, as Mamba does.
   procedure RWKV6_Step
     (Item        : in out Session;
      Source      : Model'Class;
      Current     : Layer;
      Layer_Index : Natural;
      Whole       : out Boolean;
      Status      : out E.Error_Info)
   is
   begin
      RWKV6_Batch
        (Item, Source, Current, Layer_Index, Item.Normalized,
         Item.Activation, 1, Item.Activation, Whole, Status);
   end RWKV6_Step;

   procedure Linear_Position
     (Item    : in out Session;
      Source  : Model'Class;
      Current : Layer;
      Layer_Index : Natural;
      Position : Natural;
      Status  : out E.Error_Info) is
   begin
      Product_Group
        (Item,
         [Current.Mix, Current.Z_Gate, Current.Alpha, Current.Beta],
         Item.Normalized,
         [Item.Mix_Row, Item.Z_Row, Item.Alpha_Row, Item.Beta_Row],
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Linear_Chunk
        (Item, Source, Current, Layer_Index, Position,
         (First => (Mixed => Item.Mix_Row, Z_Gate => Item.Z_Row,
                    Alpha => Item.Alpha_Row, Beta => Item.Beta_Row,
                    Blend => Item.Blend_Row, others => 0),
          Count => 1, others => 0),
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Product (Item, Current.Linear_Out, Item.Blend_Row, Item.Normalized, Status);
   end Linear_Position;

   --  The gate beside each head of a hybrid's full attention: the query
   --  projection wrote each head's query and then its gate, and this
   --  takes the gates out into Item.Head_Gate and closes the queries up.
   procedure Split_Head_Gates (Item : in out Session; Settings : Configuration)
   is
      Head : constant Element_Count := Element_Count (Settings.Head_Size);
      Full : Real_Array renames Item.Query_Full.all;
   begin
      for H in 0 .. Element_Count (Settings.Heads) - 1 loop
         for C in 0 .. Head - 1 loop
            Item.Query.all (H * Head + C) := Full (H * 2 * Head + C);
            Item.Head_Gate.all (H * Head + C) := Full (H * 2 * Head + Head + C);
         end loop;
      end loop;
   end Split_Head_Gates;

   --  And the blend scaled by the sigmoid of each gate, before the
   --  projection out.
   procedure Gate_Heads (Item : in out Session) is
   begin
      for C in Item.Attention.all'Range loop
         Item.Attention.all (C) :=
           Item.Attention.all (C) * Sigmoid (Item.Head_Gate.all (C));
      end loop;
   end Gate_Heads;

   -----------------
   -- Layer_Bytes --
   -----------------

   --  The bytes a layer's matrices read for a token: every projection,
   --  and a mixture's stacks at the share of experts a token chooses.
   function Layer_Bytes (Item : Model; L : Layer) return Float is
      Total : Float := 0.0;

      procedure Add (View : T.View; Share : Float := 1.0) is
      begin
         if T.Is_Present (View) then
            Total := Total
              + Float (View.Rows) * Float (T.Row_Bytes (View)) * Share;
         end if;
      end Add;

      Used : constant Float :=
        (if Item.Settings.Experts > 0
         then Float (Item.Settings.Experts_Used)
              / Float (Item.Settings.Experts)
         else 1.0);
   begin
      Add (L.Query);
      Add (L.Q_A);
      Add (L.Q_B);
      Add (L.KV_A_MQA);
      Add (L.KV_B);
      Add (L.Key);
      Add (L.Value);
      Add (L.Attention_Out);
      Add (L.Gate);
      Add (L.Up);
      Add (L.Down);
      Add (L.Router);
      Add (L.Mix);
      Add (L.Z_Gate);
      Add (L.Alpha);
      Add (L.Beta);
      Add (L.Ssm_In);
      Add (L.Ssm_X);
      Add (L.Ssm_Dt);
      Add (L.Shared_Gate);
      Add (L.Shared_Up);
      Add (L.Shared_Down);
      Add (L.Gate_Stack, Used);
      Add (L.Up_Stack, Used);
      Add (L.Down_Stack, Used);
      return Total;
   end Layer_Bytes;

   --  The output head: the output projection, or the embedding table where
   --  the two are tied.
   function Head_Of (Item : Model) return T.View
   is (if T.Is_Present (Item.Output) then Item.Output else Item.Embeddings);

   -----------------
   -- Token_Bytes --
   -----------------

   function Token_Bytes (Item : Model) return Float is
      Shared : constant T.View := Head_Of (Item);
      Total  : Float :=
        (if T.Is_Present (Shared)
         then Float (Shared.Rows) * Float (T.Row_Bytes (Shared))
         else 0.0);
   begin
      if Item.Layers = null then
         return 0.0;
      end if;

      for L of Item.Layers.all loop
         Total := Total + Layer_Bytes (Item, L);
      end loop;

      return Total;
   end Token_Bytes;

   -----------------
   -- Draft_Share --
   -----------------

   function Draft_Share (Item : Model) return Float is

      Shared : constant T.View := Head_Of (Item);

      --  The part of the head a draft reads.
      Drafted : constant Float :=
        (if T.Is_Present (Shared)
         then Float (Element_Count'Min (Shared.Rows, Draft_Vocabulary))
              * Float (T.Row_Bytes (Shared))
         else 0.0);

      Stack : constant Float := Token_Bytes (Item);
      Block : Float := Drafted;
   begin
      if Item.Next = null or else Item.Layers = null then
         return 1.0;
      end if;

      for L of Item.Next.all loop
         Block := Block + Layer_Bytes (Item, L);
      end loop;

      return (if Stack > 0.0 then Block / Stack else 1.0);
   end Draft_Share;

   function Drafts_Next (Item : Session) return Boolean
   is (Item.Current not in Closed | Failed
       and then Item.Owner /= null
       and then Item.Owner.Next /= null
       and then Item.Next_Input /= null
       and then (Item.Held = Exact or else Item.Next_Keys /= null));

   function Last_State (Item : Session) return N.Real_Array
   is (if Item.Has_Final and then Item.Last_Final /= null
       then Item.Last_Final.all
       else N.Real_Array'(1 .. 0 => 0.0));

   ----------------
   -- Draft_Next --
   ----------------

   procedure Draft_Next
     (Item       : in out Session;
      Source     : Model'Class;
      Token      : Model_Runner.Tokenizer.Token_Id;
      State      : N.Real_Array;
      Position   : Natural;
      Logits     : out N.Real_Array;
      Next_State : out N.Real_Array;
      Status     : out E.Error_Info)
   is separate;

   ---------------
   -- Feed_Next --
   ---------------

   procedure Feed_Next
     (Item   : in out Session;
      Source : Model'Class;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      States : N.Real_Array;
      First  : Natural;
      Status : out E.Error_Info)
   is separate;

   --------------------
   -- Evaluate_Token --
   --------------------

   --  Evaluate's work, the logits written into Row, whose length the
   --  caller gives as Asked. Every way to success leaves through writing
   --  all of Row, so it is not cleared on the way in: a megabyte of zeros
   --  on a large vocabulary, on the serial stretch between one token's
   --  head and the next token's first layer. Evaluate clears it on a
   --  failure. Row is the session's own or the caller's: the head writes
   --  straight into the caller's where it can, a copy of the vocabulary
   --  fewer on that stretch.
   procedure Evaluate_Token
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Row    : T.Real_Array_Access;
      Asked  : Element_Count;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info)
   is separate;

   --------------
   -- Evaluate --
   --------------

   procedure Evaluate
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Logits : out Real_Array;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info) is
   begin
      Evaluate_Token
        (Item, Source, Token, Item.Logit_Row, Logits'Length, Cancel, Status);
      if E.Is_Error (Status) then
         Logits := [others => 0.0];
      else
         Logits := Item.Logit_Row.all;
      end if;
   end Evaluate;

   procedure Evaluate
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Logits : T.Real_Array_Access;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info) is
   begin
      Evaluate_Token
        (Item, Source, Token, Logits,
         (if Logits = null then 0 else Logits.all'Length), Cancel, Status);
      if E.Is_Error (Status) and then Logits /= null then
         Logits.all := [others => 0.0];
      end if;
   end Evaluate;

   --  The fewest positions a batch on the device holds the part's clock
   --  up for: more than a drafted round checks.
   Prompt_Clock_Least : constant Element_Count := 16;

   ---------------------
   -- Evaluate_Batch --
   ---------------------

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
   is separate;

   ----------
   -- Rank --
   ----------

   procedure Rank
     (Item   : in out Session;
      Source : Model'Class;
      Pooled : Real_Array;
      Score  : out Real;
      Status : out E.Error_Info)
   is
      Width   : constant Element_Count :=
        Element_Count (Source.Settings.Embedding);
      In_Row  : T.Real_Array_Access := new Real_Array'(Pooled);
      Dense   : T.Real_Array_Access := new Real_Array (0 .. Width - 1);
      Out_Row : T.Real_Array_Access := new Real_Array (0 .. 0);
   begin
      Score  := 0.0;
      Status := E.Success;

      if not T.Is_Present (Source.Rank_Dense)
        or else not T.Is_Present (Source.Rank_Out)
      then
         Status := E.Make (E.Arch_Missing_Tensor);
      else
         --  The dense of the pooled state, its bias, and the logistic that
         --  the classifier a reranker learns puts between its two rows.
         Product (Item, Source.Rank_Dense, In_Row, Dense, Status);

         if E.Is_Ok (Status) then
            if Source.Rank_Dense_Bias /= null then
               K.Add (Dense.all, Source.Rank_Dense_Bias.all);
            end if;

            for Index in Dense.all'Range loop
               Dense.all (Index) :=
                 Real (N.Tanh (N.Wide_Real (Dense.all (Index))));
            end loop;

            --  And the single row down to the score.
            Product (Item, Source.Rank_Out, Dense, Out_Row, Status);
         end if;

         if E.Is_Ok (Status) then
            Score := Out_Row.all (Out_Row.all'First);
            if Source.Rank_Out_Bias /= null then
               Score := Score
                 + Source.Rank_Out_Bias.all
                     (Source.Rank_Out_Bias.all'First);
            end if;
         end if;
      end if;

      T.Free (In_Row);
      T.Free (Dense);
      T.Free (Out_Row);
   end Rank;

   --------------------
   -- Panels_Unasked --
   --------------------

   function Panels_Unasked
     (Weights        : Interfaces.Unsigned_64;
      Max_Allocation : Interfaces.Unsigned_64;
      Available      : Interfaces.Unsigned_64) return Boolean
   is
   begin
      return Model_Runner.Quantization.Integers.Has_Integer_Kernel
               (Model_Runner.GGUF.Type_Q2_K, Interleaved => True)
        and then Weights > 0
        and then Weights + 2 ** 30 <= Available
        and then Weights <= Max_Allocation;
   end Panels_Unasked;

   function Device_Context (Item : Model) return Natural
   is (Item.Device_Context);

   ---------------------
   -- Mark_Checkpoint --
   ---------------------

   procedure Mark_Checkpoint (Item : in out Session) is
   begin
      if Item.Current in Closed | Failed
        or else Item.Delta_State = null or else Item.Conv_State = null
        or else Item.Committed = 0
      then
         return;
      end if;

      declare
         Settings    : Configuration renames Item.Owner.Settings;
         Every_State : constant Element_Count := State_Room (Settings);
         Every_Conv  : constant Element_Count := Conv_Room (Settings);
         Slot        : constant Element_Count :=
           State_Slot (Item, Item.Committed);
         Read        : Boolean := True;
      begin
         --  On the device, into the slot past the ring, where the session
         --  has one and the device holds the newer copy.
         if Item.Check_Slot and then Item.State_On_Device
           and then Item.State_Seated
         then
            declare
               Every : constant Element_Count := Device_Slot_Span (Item);
            begin
               Model_Runner.Backend.Device.Copy_State
                 (From     => Item.State_Base + Slot * Every,
                  Into     => Device_Check_At (Item),
                  Elements => Every,
                  Ok       => Read);
            end;
            Item.Check_On_Device := Read;
            Item.Check_At := (if Read then Item.Committed else 0);
            return;
         end if;
         Item.Check_On_Device := False;

         if Item.Check_State = null then
            T.Allocate (Every_State, Item.Check_State);
         end if;
         if Item.Check_Conv = null then
            T.Allocate (Every_Conv, Item.Check_Conv);
         end if;
         if Item.Check_State = null or else Item.Check_Conv = null then
            Item.Check_At := 0;
            return;
         end if;

         --  The one slot the next position reads, from wherever the newer
         --  copy is; the device's whole ring is not brought home for it.
         if Item.State_On_Device and then Item.State_Seated then
            declare
               Every : constant Element_Count := Device_Slot_Span (Item);
            begin
               Model_Runner.Backend.Device.Get_State
                 (Item.State_Base + Slot * Every, Item.Check_Conv.all, Read);
               if Read then
                  Model_Runner.Backend.Device.Get_State
                    (Item.State_Base + Slot * Every + Every_Conv,
                     Item.Check_State.all, Read);
               end if;
            end;
         else
            Item.Check_State.all :=
              Item.Delta_State.all
                (Slot * Every_State .. (Slot + 1) * Every_State - 1);
            Item.Check_Conv.all :=
              Item.Conv_State.all
                (Slot * Every_Conv .. (Slot + 1) * Every_Conv - 1);
         end if;

         Item.Check_At := (if Read then Item.Committed else 0);
      end;
   end Mark_Checkpoint;

   ----------------------
   -- Hold_Checkpoints --
   ----------------------

   procedure Hold_Checkpoints (Item : in out Session) is
   begin
      if Item.Check_Slot or else Item.Current in Closed | Failed
        or else Item.Delta_State = null or else Item.Conv_State = null
      then
         return;
      end if;

      --  A seat already taken is the ring's size; the ring comes home and
      --  the seat is taken again, the larger, when it is next sent.
      if Item.State_Seated then
         Fetch_States (Item'Unchecked_Access);
         Release_State_Room (Item'Unchecked_Access);
      end if;
      Item.Check_Slot := True;
   end Hold_Checkpoints;

   function Checkpoint_On_Device (Item : Session) return Boolean
   is (Item.Check_At > 0 and then Item.Check_On_Device);

   ------------------
   -- Rewind_Point --
   ------------------

   function Rewind_Point (Item : Session; Position : Natural) return Natural is
      Wanted : Natural := Natural'Min (Position, Item.Committed);
   begin
      if Item.Current in Closed | Failed then
         return 0;
      end if;

      --  A hybrid's linear states: within the ring, or the checkpoint.
      if Item.Delta_State /= null and then Wanted < Item.Committed
        and then Wanted > 0
      then
         if Wanted <= Item.Kept_Newest
           and then Item.Kept_Newest - Wanted <= Item.Kept_States
         then
            null;
         elsif Item.Check_At > 0 and then Item.Check_At <= Wanted then
            Wanted := Item.Check_At;
         else
            return 0;
         end if;
      end if;

      --  A sliding window holds the positions from its origin on, and a
      --  position read again needs the window before it.
      if Item.Owner /= null and then Item.Origin /= null
        and then Item.Owner.Settings.Window > 0 and then Wanted > 0
      then
         for Layer in Item.Origin.all'Range loop
            if Slides (Item.Owner.Settings, Natural (Layer))
              and then Item.Origin.all (Layer) > 0
              and then Natural (Item.Origin.all (Layer))
                         + Item.Owner.Settings.Window > Wanted
            then
               return 0;
            end if;
         end loop;
      end if;

      return Wanted;
   end Rewind_Point;

end Model_Runner.Llama;
