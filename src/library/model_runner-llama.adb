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
with Model_Runner.Quantization.Interleave;

package body Model_Runner.Llama is

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
   is (Real
         (1.0
          / Model_Runner.Numerics.Sqrt
              (Model_Runner.Numerics.Wide_Real
                 (if Settings.Kind = Gemma3
                     and then Settings.Layers = 62
                     and then Settings.Heads > 0
                  then Settings.Embedding / Settings.Heads
                  else Settings.Head_Size))));

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
   function Conv_At
     (Settings : Configuration; Layer : Natural) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Layer))
       * Element_Count (Settings.Conv_Kernel - 1)
       * Element_Count (Mix_Width (Settings)));

   --  Where a linear layer's state begins within a slot: State_Size by
   --  State_Size a value head, the heads one after another, and within
   --  a head the state key-major -- row i holds S (i, j) for every j,
   --  contiguously -- so that every step of the rule is a row scaled
   --  into a running row.
   function State_At
     (Settings : Configuration; Layer : Natural) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Layer))
       * Element_Count (Settings.Value_Heads)
       * Element_Count (Settings.State_Size)
       * Element_Count (Settings.State_Size));

   --  How many numbers all of a session's linear states take, and all of
   --  its convolution memories.
   function State_Room (Settings : Configuration) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Settings.Layers))
       * Element_Count (Settings.Value_Heads)
       * Element_Count (Settings.State_Size)
       * Element_Count (Settings.State_Size));

   function Conv_Room (Settings : Configuration) return Element_Count
   is (Element_Count (Linear_Ordinal (Settings, Settings.Layers))
       * Element_Count (Settings.Conv_Kernel - 1)
       * Element_Count (Mix_Width (Settings)));

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
   is
      Number : Long_Long_Integer;
      Value  : N.Wide_Real;
      Local  : E.Error_Info;

      --  Read a required positive integer key.
      procedure Required
        (Key     : String;
         Maximum : Long_Long_Integer;
         Target  : out Natural) is
      begin
         Target := 0;
         Containers.Get_Integer (Source, Key, 1, Maximum, Number, Status);
         if E.Is_Ok (Status) then
            Target := Natural (Number);
         end if;
      end Required;

      --  Report whether a key was present and could not be used.
      --
      --  An optional key that is absent is not an error: the model does not
      --  say, and the profile falls back to its default. A key that is there
      --  and is the wrong type, or names a value outside the accepted range,
      --  is the file being wrong about the model it describes. Falling back
      --  then would build a model of a different shape than the file states
      --  and say nothing about it.
      function Present_And_Wrong (Item : E.Error_Info) return Boolean
      is (E.Is_Error (Item)
          and then Item.Code /= E.GGUF_Missing_Metadata_Key);

      --  Report an unsupported feature the file asked for.
      procedure Reject_Feature (Feature : String) is
      begin
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", Feature, E.Param_Identifier);
      end Reject_Feature;

   begin
      Settings := (others => <>);

      declare
         Name  : constant String :=
           Containers.String_Value (Source, "general.architecture");
         Found : Boolean := False;
      begin
         if Name = "" then
            Status := E.Make (E.Arch_Missing_Identifier);
            return;
         end if;

         --  Matched against the architectures this profile reads. Nothing is
         --  inferred: a file says what it is, and one that says something
         --  else is refused by name rather than read as though it were the
         --  shape this happens to implement.
         for Kind in Architecture loop
            if Architecture_Name (Kind) = Name then
               Settings.Kind := Kind;

               --  How the weights of this architecture were laid out for
               --  rotation. Llama interleaves the pairs; Qwen2 splits the
               --  head in half. Same rotation, different elements, and the
               --  wrong one reads as a model that has lost the thread.
               Settings.Pairing :=
                 (case Kind is
                    when Llama => K.Interleaved,
                    when Qwen2 | Qwen3 | Qwen3_MoE | GPT_OSS | Gemma | Gemma2
                       | Gemma3 | Phi3 | Falcon | Phi2 | GPT2 | Bert
                       | Nomic_Bert | Jina_Bert_V2 | Qwen35 | Qwen35_MoE =>
                      K.Split);

               --  What a position may see. Every architecture here
               --  generates, and a generated token cannot depend on one
               --  that does not exist yet -- except Bert, which does not
               --  generate at all: it reads a text that is already whole
               --  and every position of it may see every other.
               Settings.Causal := not Normalizes_After (Kind);

               --  And whether it can turn a state into a distribution at
               --  all. Decided here rather than where the output projection
               --  is resolved, because it is a fact about the architecture
               --  and `inspect` reports what a file says without resolving
               --  a tensor: read from the resolution, it said every model
               --  had a head, including the one that has none.
               Settings.Has_Head := not Normalizes_After (Kind);
               Found := True;
            end if;
         end loop;

         if not Found then
            --  What this build does read, listed from the enumeration rather
            --  than written out. It named one architecture while reading
            --  four, which is the kind of message that sends somebody
            --  looking for a build that does not exist.
            declare
               Known : String (1 .. 128) := [others => ' '];
               Last  : Natural := 0;

               procedure Append (Text : String) is
               begin
                  if Last + Text'Length <= Known'Last then
                     Known (Last + 1 .. Last + Text'Length) := Text;
                     Last := Last + Text'Length;
                  end if;
               end Append;
            begin
               for Kind in Architecture loop
                  if Last > 0 then
                     Append (" ");
                  end if;
                  Append (Architecture_Name (Kind));
               end loop;

               Status := E.Make (E.Arch_Unsupported);
               E.Add_Text (Status, "architecture", Name, E.Param_Identifier);
               E.Add_Text
                 (Status, "supported", Known (1 .. Last), E.Param_Text);
            end;
            return;
         end if;
      end;

      Required (Model_Key (Settings.Kind, "context_length"),
                Long_Long_Integer (Bounds.Max_Context_Length),
                Settings.Context_Length);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "embedding_length"),
                Long_Long_Integer (Bounds.Max_Embedding), Settings.Embedding);
      if E.Is_Error (Status) then
         return;
      end if;

      Required (Model_Key (Settings.Kind, "block_count"),
                Long_Long_Integer (Bounds.Max_Layers), Settings.Layers);
      if E.Is_Error (Status) then
         return;
      end if;

      --  A hybrid mixture states no dense width at all -- its experts'
      --  and its shared expert's widths are stated under their own keys
      --  below -- so the key is required of every architecture but that.
      if Settings.Kind = Qwen35_MoE
        and then not Containers.Has
                       (Source, Model_Key (Settings.Kind, "feed_forward_length"))
      then
         Settings.Feed_Forward := 0;
      else
         Required (Model_Key (Settings.Kind, "feed_forward_length"),
                   Long_Long_Integer (Bounds.Max_Embedding) * 64,
                   Settings.Feed_Forward);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      Required (Model_Key (Settings.Kind, "attention.head_count"),
                Long_Long_Integer (Bounds.Max_Heads), Settings.Heads);
      if E.Is_Error (Status) then
         return;
      end if;

      --  Key-value head count is optional; a model that omits it is
      --  multi-head rather than grouped-query.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.head_count_kv"), 1,
         Long_Long_Integer (Settings.Heads), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.KV_Heads :=
        (if E.Is_Ok (Local) then Natural (Number) else Settings.Heads);

      --  The floor under a normalization's divisor. An architecture that
      --  normalizes by root mean square states it under one key and Bert,
      --  which centres, states it under another -- the same quantity in the
      --  same units, named for the normalization it belongs to. Bert is
      --  asked for its own key and falls back to the other, so a file that
      --  states either is read and a file that states neither takes the
      --  default both would.
      if Normalizes_After (Settings.Kind) then
         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "attention.layer_norm_epsilon"),
            0.0, 1.0, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
      end if;

      if not Normalizes_After (Settings.Kind) or else E.Is_Error (Local) then
         Containers.Get_Float
           (Source,
            Model_Key (Settings.Kind, "attention.layer_norm_rms_epsilon"),
            0.0, 1.0, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
      end if;
      Settings.Epsilon :=
        (if E.Is_Ok (Local) then N.Real (Value) else 1.0E-5);

      --  What the file says its states should be pooled with. Read for the
      --  architecture that states it and left unstated for the rest, which
      --  is not the same as none: a model that says nothing about pooling
      --  has not asked for one, and a model that says none has.
      --
      --  Ranked pooling is a fourth value some files carry. It is not a way
      --  of reducing a text to a vector at all -- it names a scoring head
      --  this program does not have -- so it is refused by name rather than
      --  read as one of the three that are.
      if Normalizes_After (Settings.Kind) then
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "pooling_type"), 0, 4, Number,
            Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;

         if E.Is_Ok (Local) then
            case Number is
               when 0 => Settings.Pooling := Pool_None;
               when 1 => Settings.Pooling := Pool_Mean;
               when 2 => Settings.Pooling := Pool_Cls;
               when 3 => Settings.Pooling := Pool_Last;
               when others =>
                  Reject_Feature ("rank pooling");
                  return;
            end case;
         end if;

         --  A row for each segment a token may belong to. The architecture
         --  states two and the shape is checked against that where the
         --  tensor is resolved; a text embedded here is all one segment, so
         --  only the first row is ever read, and the second is required
         --  because a file that has not got it is not the model this
         --  computes.
         if Containers.Find_Tensor (Source, "token_types.weight") /= 0 then
            Settings.Segments := 2;
         end if;
      end if;

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.freq_base"), 1.0, 1.0E12, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Rope_Base := (if E.Is_Ok (Local) then Value else 10_000.0);

      --  Rotary scaling. A model that says nothing rotates as it was
      --  trained; "linear" divides every position by the factor; "yarn"
      --  divides the low frequencies and leaves the high ones alone. Any
      --  other name changes the position mapping in a way this does not
      --  compute, and running it as though it did would produce a model that
      --  reads its own context wrongly at long range and says nothing about
      --  it.
      declare
         Named : constant String :=
           Containers.String_Value
             (Source, Model_Key (Settings.Kind, "rope.scaling.type"));
      begin
         if Named /= "" and then Named /= "none" and then Named /= "linear"
           and then Named /= "yarn"
         then
            Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
            E.Add_Text (Status, "scaling", Named, E.Param_Identifier);
            return;
         end if;

         --  Two tables, chosen by how long the prompt turned out to be, is
         --  a different method again: it makes the rotation depend on the
         --  whole sequence rather than on the position, and nothing here
         --  does that. Refused by the tensors as well as by the name,
         --  because a file may carry them without naming the method.
         if Containers.Find_Tensor (Source, "rope_factors_long.weight") /= 0
           or else Containers.Find_Tensor
                     (Source, "rope_factors_short.weight") /= 0
         then
            Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
            E.Add_Text (Status, "scaling", "longrope", E.Param_Identifier);
            return;
         end if;

         Settings.Scaling.Kind :=
           (if Named = "yarn" then K.Yarn
            elsif Named = "linear" then K.Linear
            else K.Unscaled);

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.scaling.factor"), 0.0,
            1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) and then Value > 0.0 then
            Settings.Scaling.Frequency := 1.0 / Value;

            --  A factor with no name is the linear stretch, which is what
            --  the key meant before there was more than one kind of it.
            if Named = "" and then Value /= 1.0 then
               Settings.Scaling.Kind := K.Linear;
            end if;
         end if;
      end;

      --  What the ramp is derived from, which only Yarn reads. The context
      --  the model was trained on is the default for the context it was
      --  trained on, so a file that omits it is saying the two are the same.
      if K."=" (Settings.Scaling.Kind, K.Yarn) then
         Containers.Get_Integer
           (Source,
            Model_Key (Settings.Kind, "rope.scaling.original_context_length"),
            1, Long_Long_Integer (Bounds.Max_Context_Length), Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Scaling.Original :=
           (if E.Is_Ok (Local)
            then Natural (Number)
            else Settings.Context_Length);

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.scaling.attn_factor"),
            0.0, 1.0E3, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) then
            Settings.Scaling.Attenuation := Value;
         end if;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.scaling.beta_fast"),
            0.0, 1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) and then Value > 0.0 then
            Settings.Scaling.Beta_Fast := Value;
         end if;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.scaling.beta_slow"),
            0.0, 1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) and then Value > 0.0 then
            Settings.Scaling.Beta_Slow := Value;
         end if;
      end if;

      --  A mixture of experts, when the model names one. The count is what
      --  each layer holds and the used count is how many of them run for one
      --  position; a file naming either names both, because one without the
      --  other describes no model.
      if Containers.Has (Source, Model_Key (Settings.Kind, "expert_count"))
        or else Containers.Has
                  (Source, Model_Key (Settings.Kind, "expert_used_count"))
      then
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_count"),
            0, Long_Long_Integer (Bounds.Max_Experts), Number, Local);
         if E.Is_Error (Local) then
            Status := Local;
            return;
         end if;
         Settings.Experts := Natural (Number);

         --  A count of zero is a dense model that said so. The used count
         --  then has to say the same thing, since a model cannot run experts
         --  it does not have.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_used_count"),
            (if Settings.Experts = 0 then 0 else 1),
            Long_Long_Integer (Natural'Max (Settings.Experts, 1)),
            Number, Local);
         if E.Is_Error (Local) then
            Status := Local;
            return;
         end if;
         Settings.Experts_Used := Natural (Number);

         if Settings.Experts = 0 then
            Settings.Experts_Used := 0;
         end if;
      end if;

      --  The hybrid architectures' shape: how often a layer attends in
      --  full, and the linear layers' heads, state and convolution, all
      --  required, since a file without them describes no model of this
      --  kind. And how many blocks past the stack the file carries, which
      --  the stack does not run and the count of layers does not include.
      if Hybrid (Settings.Kind) then
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "full_attention_interval"),
            1, Long_Long_Integer (Bounds.Max_Layers), Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Linear_Every :=
           (if E.Is_Ok (Local) then Natural (Number) else 4);

         Required (Model_Key (Settings.Kind, "ssm.state_size"),
                   Long_Long_Integer (Bounds.Max_Embedding),
                   Settings.State_Size);
         if E.Is_Error (Status) then
            return;
         end if;

         Required (Model_Key (Settings.Kind, "ssm.group_count"),
                   Long_Long_Integer (Bounds.Max_Heads), Settings.Key_Heads);
         if E.Is_Error (Status) then
            return;
         end if;

         Required (Model_Key (Settings.Kind, "ssm.time_step_rank"),
                   Long_Long_Integer (Bounds.Max_Heads), Settings.Value_Heads);
         if E.Is_Error (Status) then
            return;
         end if;

         Required (Model_Key (Settings.Kind, "ssm.conv_kernel"),
                   16, Settings.Conv_Kernel);
         if E.Is_Error (Status) then
            return;
         end if;

         --  The inner size is the value heads times the state, and a file
         --  saying otherwise describes a shape this does not compute.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "ssm.inner_size"),
            1, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
         if Present_And_Wrong (Local)
           or else (E.Is_Ok (Local)
                    and then Natural (Number) /= Value_Width (Settings))
           or else Settings.Value_Heads mod Settings.Key_Heads /= 0
         then
            Status := E.Make (E.Arch_Invalid_Dimensions);
            E.Add_Integer
              (Status, "value_heads", Long_Long_Integer (Settings.Value_Heads));
            E.Add_Integer
              (Status, "key_heads", Long_Long_Integer (Settings.Key_Heads));
            return;
         end if;

         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "nextn_predict_layers"),
            0, 4, Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Next_Layers := (if E.Is_Ok (Local) then Natural (Number) else 0);

         if Settings.Next_Layers >= Settings.Layers then
            Status := E.Make (E.Arch_Invalid_Dimensions);
            E.Add_Integer
              (Status, "next_layers", Long_Long_Integer (Settings.Next_Layers));
            return;
         end if;
         Settings.Layers := Settings.Layers - Settings.Next_Layers;

         --  The shared expert's width, where the mixture has one.
         if Settings.Experts > 0 then
            Containers.Get_Integer
              (Source,
               Model_Key (Settings.Kind, "expert_shared_feed_forward_length"),
               0, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
            if Present_And_Wrong (Local) then
               Status := Local;
               return;
            end if;
            Settings.Shared_Feed :=
              (if E.Is_Ok (Local) then Natural (Number) else 0);
         end if;
      end if;

      if Settings.Experts > 0 then
         --  What is understood is a softmax over every expert, the highest
         --  few taken, and their weights renormalized over that few. A file
         --  naming a different gate or asking for the weights unnormalized
         --  describes a mixture this does not compute, and running it as
         --  though it did would produce a plausible wrong answer rather than
         --  a refusal.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_gating_func"),
            1, 1, Number, Local);
         if Present_And_Wrong (Local) then
            Reject_Feature ("expert_gating_function");
            return;
         end if;

         declare
            Normalized : Boolean;
         begin
            Containers.Get_Boolean
              (Source, Model_Key (Settings.Kind, "expert_weights_norm"),
               Normalized, Local);
            if Present_And_Wrong (Local)
              or else (E.Is_Ok (Local) and then not Normalized)
            then
               Reject_Feature ("unnormalized_expert_weights");
               return;
            end if;
         end;

         --  A shared expert runs for every position beside the chosen ones.
         --  Nothing here computes it, and a model that has one produces a
         --  different answer without it.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_shared_count"),
            0, 0, Number, Local);
         if Present_And_Wrong (Local) then
            Reject_Feature ("shared_expert");
            return;
         end if;

         --  One expert's width, when the file states it separately. A
         --  mixture-of-experts file often carries both numbers, and they are
         --  not the same: feed_forward_length describes the dense block the
         --  model does not have.
         Containers.Get_Integer
           (Source, Model_Key (Settings.Kind, "expert_feed_forward_length"),
            1, Long_Long_Integer (Bounds.Max_Embedding) * 64, Number, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Expert_Feed :=
           (if E.Is_Ok (Local)
            then Natural (Number)
            else Settings.Feed_Forward);
      end if;

      --  A sliding window, when the model names one. Read rather than
      --  refused: each position attends to the window's worth of positions
      --  ending at itself, and the layers all use the same window.
      --
      --  The value is bounded by the context length. A window at least as
      --  wide as the context can see everything the context holds, which is
      --  what no window means, so it is stored as none -- the attention loops
      --  then have no bound to test and a model that names a wide window
      --  costs nothing to run.
      if Containers.Has
           (Source, Model_Key (Settings.Kind, "attention.sliding_window"))
      then
         declare
            Value : Long_Long_Integer;
            Local : E.Error_Info;
         begin
            Containers.Get_Integer
              (Source, Model_Key (Settings.Kind, "attention.sliding_window"),
               1, Long_Long_Integer (Bounds.Max_Context_Length), Value, Local);

            if E.Is_Error (Local) then
               Status := Local;
               return;
            end if;

            if Natural (Value) < Settings.Context_Length then
               Settings.Window := Natural (Value);
            end if;
         end;
      end if;

      --  Whether a position may see what follows it, where the file says so.
      --
      --  The architecture's name is a good default and not an answer: a
      --  published all-MiniLM states `bert.attention.causal` as false
      --  rather than leaving it to be assumed, and a file that states the
      --  other thing means it. Read here so that what decides the
      --  arithmetic is the file, which is the rule everywhere else in this
      --  profile and was an assumption only here.
      declare
         Named : Boolean;
         Local : E.Error_Info;
      begin
         Containers.Get_Boolean
           (Source, Model_Key (Settings.Kind, "attention.causal"), Named,
            Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;

         if E.Is_Ok (Local) then
            Settings.Causal := Named;
         end if;
      end;

      --  A window is a bound on how far back a position may look, and a
      --  model that looks both ways has not got such a thing: there is no
      --  "back" to bound. A file stating one under a bidirectional
      --  architecture is describing something this cannot compute, and
      --  reading the window as though it bounded the whole span would give
      --  every position the same few positions to see -- an answer, and not
      --  the model's.
      if not Settings.Causal and then Settings.Window > 0 then
         Reject_Feature ("a sliding window on a model that attends both ways");
         return;
      end if;

      --  The two bounds Gemma2 states, and the window it alternates. Read
      --  where the architecture says so rather than taken if present: a
      --  gemma2 file without them is a file this build cannot compute, and
      --  a file that states them under another architecture's prefix is a
      --  file that means something else by them.
      if Settings.Kind = Gemma3 then
         --  Five layers in six slide a window; the sixth sees everything.
         Settings.Alternating := True;
         Settings.Window_Every := 6;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.local_freq_base"),
            1.0, 1.0E12, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Local_Base :=
           (if E.Is_Ok (Local) then Value else 10_000.0);
      end if;

      --  GPT_OSS alternates a window the same way Gemma2 does and turns
      --  the windowed layers on a base of their own, the way Gemma3 does.
      --  It is the first architecture here to want both, which is why
      --  neither of those two blocks could be reused for it.
      if Settings.Kind = GPT_OSS then
         Settings.Alternating := True;
         Settings.Window_Every := 2;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.freq_base_swa"),
            1.0, 1.0E12, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Local_Base :=
           (if E.Is_Ok (Local) then Value else Settings.Rope_Base);

         --  The gate's two bounds, which this architecture states nowhere:
         --  they are constants of the model rather than of the file, and
         --  llama.cpp writes them out in its graph for the same reason.
         --  1.702 is the slope that makes the logistic agree with the
         --  Gaussian error function this model was trained against.
         Settings.Gate_Alpha := 1.702;
         Settings.Gate_Limit := 7.0;
      end if;

      if Settings.Kind = Gemma2 then
         Settings.Alternating := True;
         Settings.Window_Every := 2;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "attn_logit_softcapping"),
            1.0, 1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Attention_Cap :=
           (if E.Is_Ok (Local) then N.Real (Value) else 0.0);

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "final_logit_softcapping"),
            1.0, 1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         Settings.Logit_Cap :=
           (if E.Is_Ok (Local) then N.Real (Value) else 0.0);
      end if;

      --  How steeply a head's attention falls off with distance, for the
      --  one architecture here that is told where a token is by the scores
      --  rather than by a rotation or a learned row.
      --
      --  Written rather than read. The key exists in the format --
      --  `<arch>.attention.max_alibi_bias` -- and no published
      --  jina-bert-v2 states it; the other runtime carries eight for this
      --  architecture in its own source and reads nothing. A file that does
      --  state one is refused rather than cut to eight, because a slope
      --  ladder is what tells the model where a token is and a wrong one
      --  answers rather than refuses.
      if Settings.Kind = Jina_Bert_V2 then
         Settings.Max_Bias := 8.0;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "attention.max_alibi_bias"),
            0.0, 1.0E6, Value, Local);
         if E.Is_Ok (Local) and then N.Real (Value) /= Settings.Max_Bias then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text
              (Status, "feature", "attention.max_alibi_bias other than 8",
               E.Param_Identifier);
            return;
         elsif Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
      end if;

      if Settings.Heads mod Settings.KV_Heads /= 0 then
         Status := E.Make (E.Arch_Invalid_Head_Counts);
         E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
         E.Add_Integer
           (Status, "kv_heads", Long_Long_Integer (Settings.KV_Heads));
         return;
      end if;

      Settings.Group_Size := Settings.Heads / Settings.KV_Heads;

      --  How wide a head is. A file may state the key width and the value
      --  width, and they need not be each other nor the embedding divided by
      --  the head count: a model is free to give its heads more room than
      --  its embedding would imply, or to read values narrower than the keys
      --  it selects them with.
      --
      --  A file that states neither has both derived from the embedding
      --  width, which then has to divide exactly -- a remainder would mean
      --  the file describes a model this arithmetic cannot express.
      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.key_length"),
         1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;

      if E.Is_Ok (Local) then
         Settings.Head_Size := Natural (Number);
      else
         if Settings.Embedding mod Settings.Heads /= 0 then
            Status := E.Make (E.Arch_Invalid_Dimensions);
            E.Add_Integer
              (Status, "embedding", Long_Long_Integer (Settings.Embedding));
            E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
            return;
         end if;
         Settings.Head_Size := Settings.Embedding / Settings.Heads;
      end if;

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "attention.value_length"),
         1, Long_Long_Integer (Bounds.Max_Embedding), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Value_Size :=
        (if E.Is_Ok (Local) then Natural (Number) else Settings.Head_Size);

      --  A hybrid's full attention carries a gate beside each head, of the
      --  head's own width, and scales the head's blend by it -- so its
      --  value width is its head size, and a file stating another is a
      --  model the reference implementation does not define either.
      --  Refused by name: read anyway, the gate ran off the end of the
      --  blend, and the fixture sweep's shape with the widths apart said
      --  INTERNAL_INVARIANT_VIOLATED on every backend for as long as the
      --  architecture had been read.
      if Hybrid (Settings.Kind)
        and then Settings.Value_Size /= Settings.Head_Size
      then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "head_size", Long_Long_Integer (Settings.Head_Size));
         E.Add_Integer
           (Status, "value_size", Long_Long_Integer (Settings.Value_Size));
         return;
      end if;

      Containers.Get_Integer
        --  From zero, not from one. Zero is what an architecture that
        --  learns where a token is rather than rotating for it states, and
        --  it is a fact about the model rather than a missing key: GPT2
        --  carries a table of positions and no rotation, and a reader that
        --  refused the zero would refuse the model.
        (Source, Model_Key (Settings.Kind, "rope.dimension_count"), 0,
         Long_Long_Integer (Settings.Head_Size), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      --  Bert does not rotate at all, so the width is zero however the file
      --  reads: it learns where a token is instead, and a published file
      --  states no rotary width because there is nothing to state. Left to
      --  the default below, an absent key would have taken the head size
      --  and turned every query and key of a model that never rotates --
      --  which the sweep could not have caught, because the fixture wrote
      --  the key as zero and so agreed with itself about a model nobody
      --  ships. That is the same trap gpt2's output bias fell into, found
      --  the same way: by reading a file somebody else published.
      Settings.Rotary :=
        (if Settings.Kind in Bert | Jina_Bert_V2 then 0
         elsif E.Is_Ok (Local) then Natural (Number)
         else Settings.Head_Size);

      --  The three parts a Qwen3.5 position has, and how many pairs each
      --  turns: stated as four counts, the fourth unused, and dealt
      --  interleaved. A text token has the three parts equal, so a model
      --  read without them rotates the same; they matter to a picture's
      --  rows, which have a row and a column of their own.
      if Settings.Kind in Qwen35 | Qwen35_MoE then
         declare
            Key    : constant String :=
              Model_Key (Settings.Kind, "rope.dimension_sections");
            Length : Natural := 0;
            Count  : Long_Long_Integer;
            Found  : E.Error_Info;
         begin
            Containers.Get_Array_Length
              (Source, Key, Model_Runner.GGUF.Value_Int32, Length, Found);
            if E.Is_Ok (Found) and then Length >= 3 then
               for Part in 1 .. Natural'Min (4, Length) loop
                  Containers.Get_Integer_Element (Source, Key, Part, Count, Found);
                  exit when E.Is_Error (Found) or else Count < 0 or else Count > 4096;
                  case Part is
                     when 1 => Settings.Sections.T := Natural (Count);
                     when 2 => Settings.Sections.H := Natural (Count);
                     when 3 => Settings.Sections.W := Natural (Count);
                     when others => Settings.Sections.E := Natural (Count);
                  end case;
               end loop;
               Settings.Sections.Interleaved := True;
               if E.Is_Error (Found) then
                  Settings.Sections := K.No_Sections;
               end if;
            end if;
         end;
      end if;

      if Settings.Rotary > Settings.Head_Size
        or else Settings.Rotary mod 2 /= 0
      then
         Status := E.Make (E.Arch_Invalid_Rope);
         E.Add_Integer (Status, "rotary", Long_Long_Integer (Settings.Rotary));
         E.Add_Integer
           (Status, "head_size", Long_Long_Integer (Settings.Head_Size));
         return;
      end if;

      Status := E.Success;
   end Read_Configuration;

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
        + (if Hybrid (Item.Settings.Kind) then 9 else 0);

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
         Add (Which.Linear_Out'Unchecked_Access);
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
      --  Said unconditionally. A model that never touched a device gives
      --  back nothing, which costs nothing, and a model cannot know whether
      --  the device holds its addresses.
      Model_Runner.Backend.Device.Forget_Matrices;
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
                | Jina_Bert_V2
       then 1 else 0);

   procedure Gate_Activation (Item : Model'Class; Target : in out Real_Array)
   is
   begin
      if Item.Settings.Kind
         in Gemma | Gemma2 | Gemma3 | Falcon | Phi2 | GPT2 | Bert
            | Jina_Bert_V2
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

      for Value of Values loop
         Value := Capped (Value, Settings.Logit_Cap);
      end loop;
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
   function Centres
     (Item : Model'Class; Bias : T.Real_Array_Access) return Boolean
   is (Item.Settings.Kind
         in Falcon | Phi2 | GPT2 | Bert | Nomic_Bert | Jina_Bert_V2
       and then Bias /= null);

   --  Normalize the way the architecture does, into Target.
   --
   --  Falcon, Phi2, GPT2 and Bert centre and carry a bias; everything else
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
         K.Layer_Norm (Source, Gain, Bias.all, Item.Settings.Epsilon, Target);
      else
         K.RMS_Norm (Source, Gain, Item.Settings.Epsilon, Target);
      end if;
   end Normalize;

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
       else 1.0);

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
      Stretch  : Rotary_Request := No_Rotary_Request)
   is
      Ignored : E.Error_Info;

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
            if not Normalizes_After (Item.Settings.Kind) then
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
            end if;

            --  Gemma2 normalizes what each sublayer produced as well as
            --  what it was given. Required rather than optional: a
            --  gemma2 file without them is not one this build can
            --  compute, and taking them if present would read such a
            --  file as a model with two normalizations missing.
            if Item.Settings.Kind in Gemma2 | Gemma3 then
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
            if Item.Settings.Kind in Falcon | Phi2 | GPT2 then
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "attn_norm.bias"),
                  Width, Current.Attention_Norm_Bias, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;

            if Is_Linear then
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
               in Phi3 | Falcon | Phi2 | GPT2 | Nomic_Bert
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
            if Item.Settings.Kind in Phi2 | GPT2 then
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
            if Item.Settings.Kind in Qwen2 | Bert | Jina_Bert_V2 then
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
                 Phi2 | GPT2 | Bert | Jina_Bert_V2 | GPT_OSS
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
            if Item.Settings.Kind not in Falcon | Phi2
              and then not Normalizes_After (Item.Settings.Kind)
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
               if Item.Settings.Kind in Falcon | Phi2 | GPT2
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

            if Item.Settings.Kind in Falcon | Phi2 | GPT2 | Bert then
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
               if Item.Settings.Kind in Phi2 | GPT2 | Bert then
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
              and then Item.Settings.Kind = Phi3
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

            elsif Item.Settings.Experts = 0 then
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

                  Resolve_Norm
                    (Item, Source,
                     Layer_Key (Index, "ffn_gate_inp_shexp.weight"),
                     Width, Current.Shared_Router, Status);
                  if E.Is_Error (Status) then
                     return;
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
           and then Normalizes_After (Item.Settings.Kind)
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

            if E.Is_Ok (Status)
              and then Item.Settings.Kind in Falcon | Phi2 | GPT2
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
      if Repack = To_Rows then
         P.Publish (Observer, P.Load_Progress (P.Repacking_Weights));

         declare
            Needed : B.Byte_Count := 0;

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

               declare
                  Bases : array (Held'Range) of B.Byte_Count :=
                    [others => 0];

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
                  begin
                     Model_Runner.Quantization.Interleave.Build
                       (Format => Where.all.Format,
                        Source => Source,
                        From   => Where.all.Offset,
                        Target => Item.Repacked.all,
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
                        Fail (Trouble);
                        return;
                     end if;
                  end;

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
            end if;
         end;
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

      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch (Item.Team, Weight, Vector, Target, Status);
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

      if Item.Owner.Able.Kind = Model_Runner.Backend.Backend_Device then
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
      if Item.Owner.Able.Kind = Model_Runner.Backend.Backend_CPU
        and then Apart = 0
      then
         Workers_CPU.Dispatch_Group (Item.Team, Weights, Vector, Into, Status);
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

      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch_Batch
              (Item.Team, Weight, Vectors, Count, Target, Status);
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
      Ok         : out Boolean) is

      --  Overflow checking off here, and bounds checking left alone.
      --
      --  A profile of a prompt put the exact blend at eleven per cent of it
      --  and said what the eleven per cent was: fifty-four per cent of the
      --  samples on 64-bit moves and twenty per cent on `jo`, the overflow
      --  branch after every index it computes. Not one of the ten hottest
      --  instructions was a multiply. These three blends are the only loops
      --  in the engine's own arithmetic that were never given the
      --  suppressions the integer kernels carry, and it shows.
      --
      --  Overflow rather than bounds, on purpose, and the two are not the
      --  same guard. What is dropped is the check that an index computation
      --  does not wrap: every value in one is an element count of a model
      --  this program has already validated, and wrapping needs numbers far
      --  larger than the widest tensor a file may declare. What is kept is
      --  the check that the index it produces is inside the array -- so a
      --  wrap that somehow happened would still be refused rather than
      --  read, and the note at the top of this unit that says bounds and
      --  range checking are untouched stays true.
      pragma Suppress (Overflow_Check);

      --  And bounds checking, once the ranges below are proved.
      --
      --  With the overflow branch gone a second profile said the same thing
      --  again: forty-six per cent of this procedure was `cmpq` and fifteen
      --  more the address arithmetic feeding it, against twenty-nine per
      --  cent doing the multiply-adds it exists for. Six index checks an
      --  element, on indices that differ from the last by a constant.
      --
      --  So they are proved once instead, which is what the integer kernels
      --  do and say: every index this procedure forms is a fixed function
      --  of the loop bounds, so the largest of each is computed below and
      --  compared against the array it will index. A call that would step
      --  outside is refused through Ok, which is a path the caller already
      --  handles because the softmax further down can refuse too.
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);

      --  The largest head's group, which is what fixes the reach into the
      --  keys and the values.
      Group_Top : constant Element_Count :=
        (if Group_Size = 0 then 0 else To_Head / Group_Size);
   begin
      Ok := True;

      --  Nothing to do is not a refusal.
      if To_Head < From_Head or else Last < First then
         return;
      end if;

      --  Every index the loops below will form, at its largest. The
      --  products are of dimensions a model file declared and this program
      --  validated when it read them, which is the same footing the row
      --  kernels' own reach check stands on.
      if Group_Size = 0
        or else Head_Size = 0
        or else Scores'Length < To_Head * Score_Room + Last + 1
        or else Query'Length < To_Head * Head_Size + Head_Size
        or else Keys'Length
                  < K_Base + Last * KV_Width + Group_Top * Head_Size
                    + Head_Size
        or else Values'Length
                  < V_Base + Last * V_Width + Group_Top * Value_Size
                    + Value_Size
        or else Target'Length < To_Head * Value_Size + Value_Size
      then
         Ok := False;
         return;
      end if;

      --  Every head's scores first, with the position outside the head.
      --
      --  A head at a time walked the whole key cache for itself, and the
      --  next head walked it again: a 1419-position context is 363 kilobytes
      --  of keys a group, streamed once for each of the heads that share
      --  them. With the position outside, the heads of a share read the same
      --  key row one after another and it is in the nearest cache for all
      --  but the first -- the same change the value blend below already
      --  had made to it, for the same reason, and this loop was left.
      --
      --  It is worth what it is worth because this loop is sixty-five per
      --  cent of attending and twenty-seven per cent of a processor prompt:
      --  emptying it takes a 1419-token prompt from 16.11 s to 11.96.
      --
      --  Bit for bit what it replaces. Each score is the same expression
      --  over the same components in the same order; what changed is which
      --  score is computed when, and no two of them touch.
      --  A block of positions at a time, and every head across that block
      --  before the next one.
      --
      --  Neither of the two obvious orders. Position outside head reads the
      --  key cache once, which is what the paragraph above is about, but it
      --  asks for one score at a time and a score costs a horizontal fold
      --  of about twenty cycles standing behind eight multiply-adds worth
      --  eight -- four per cent of a prompt, measured by removing it. Head
      --  outside position lets eight keys share one fold, and walks the
      --  whole cache again for every head.
      --
      --  Eight positions at a time has both: the eight key rows a block
      --  needs are eight kilobytes for this architecture and stay in the
      --  nearest cache while all thirty-two heads read them, and each head
      --  gets its eight scores from one run with one fold at the end.
      --
      --  Both loops are inside the kernel now and neither is written here.
      --  They were: a block loop around a head loop around a call, and the
      --  call was ten arguments and six reach comparisons and three index
      --  checks in front of sixty-four multiply-adds. Handing it the whole
      --  range instead proves the reach once and issues the runs in place,
      --  which is four per cent of the instructions a prompt executes.
      K.Head_Scores_Across
        (Query     => Query,
         At_Query  => Query'First,
         Keys      => Keys,
         At_Key    => Keys'First + K_Base + First * KV_Width,
         Stride    => KV_Width,
         Steps     => Last - First + 1,
         Span      => Head_Size,
         From_Head => From_Head,
         To_Head   => To_Head,
         Share     => Group_Size,
         Room      => Score_Room,
         Scale     => Scale,
         Scores    => Scores,
         At_Score  => Scores'First + First);

      for Head in From_Head .. To_Head loop
         declare
            At_Score : constant Element_Count :=
              Scores'First + Head * Score_Room;
            Usable   : Boolean;
         begin

            --  The bound afterwards, in a loop of its own, and only when
            --  there is one. Applied inside the loop above it cost every
            --  architecture a test per score -- twelve tokens went from
            --  1.83 s to 2.07 s and the processor time with it, for a
            --  feature one architecture of six uses.
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

         end;
      end loop;

      --  The blend, with the positions outside the heads.
      --
      --  Eight heads share one key head's values -- that is what a grouped
      --  query is -- so the shape this replaces read the same values eight
      --  times over, once for each head that wanted them, and a whole
      --  position range is far larger than the nearest cache. A tile of
      --  sixteen positions is sixteen kilobytes of values against
      --  thirty-two of cache, and every head after the first reads them
      --  where the first left them.
      --
      --  It is the same argument the score loop above makes about eight
      --  positions at a time, made about the other half of attention. What
      --  it costs is the accumulators: they live in memory between tiles
      --  rather than only at the ends, which is a load and a store of each
      --  every sixteen positions.
      --
      --  A run of components at a time rather than all of them because the
      --  run is on the stack and a head's width is a model's to choose;
      --  summed in binary32 and not the binary64 this once kept, for the
      --  reason the score dot product gives.
      declare
         Run   : constant Element_Count := 64;
         Rooms : constant Element_Count := To_Head - From_Head + 1;

         --  A tile only where there is something to reuse. A tile costs a
         --  load and a store of every accumulator at each of its ends, and
         --  buys the second and later heads their values out of the nearest
         --  cache; a range short enough to sit in that cache whole has
         --  nothing to buy and pays anyway. Generating is the case: a run
         --  of sixty-four tokens looks back over seventy positions and lost
         --  a fifth of itself to tiles it did not need.
         Tile  : constant Element_Count :=
           (if Last - First + 1 <= 128 then Last - First + 1 else 16);

         At_Component : Element_Count := 0;
      begin
         while At_Component < Value_Size loop
            declare
               Here : constant Element_Count :=
                 Element_Count'Min (Run, Value_Size - At_Component);

               Sums : Real_Array (0 .. Rooms * Here - 1) := [others => 0.0];

               At_Step : Element_Count := First;
            begin
               while At_Step <= Last loop
                  declare
                     Take : constant Element_Count :=
                       Element_Count'Min (Tile, Last - At_Step + 1);
                  begin
                     for Head in From_Head .. To_Head loop
                        declare
                           Group : constant Element_Count :=
                             Head / Group_Size;
                           Mine  : constant Element_Count :=
                             (Head - From_Head) * Here;
                        begin
                           K.Blend_Run
                             (Sums      => Sums (Mine .. Mine + Here - 1),
                              Weights   => Scores,
                              At_Weight =>
                                Scores'First + Head * Score_Room + At_Step,
                              Values    => Values,
                              At_Value  =>
                                Values'First + V_Base + At_Step * V_Width
                                + Group * Value_Size + At_Component,
                              Stride    => V_Width,
                              Steps     => Take);
                        end;
                     end loop;

                     At_Step := At_Step + Take;
                  end;
               end loop;

               for Head in From_Head .. To_Head loop
                  declare
                     Mine : constant Element_Count :=
                       (Head - From_Head) * Here;
                  begin
                     for Component in 0 .. Here - 1 loop
                        Target (Target'First + Head * Value_Size
                                + At_Component + Component) :=
                          Sums (Mine + Component);
                     end loop;
                  end;
               end loop;

               At_Component := At_Component + Here;
            end;
         end loop;
      end;
   end Blend_Exact;

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

   --  And when each block was last asked for. A session stamps its block
   --  every time it asks for it -- which is every layer that goes over
   --  whole, so the stamp is how recently the block was read rather than
   --  how recently it was granted -- and a session that finds every block
   --  held takes the one stamped longest ago. The clock counts asks and
   --  nothing else: it is compared and never read as a time.
   Block_Clock : Natural := 0;
   Block_Used  : array (Block_Holder'Range) of Natural := [others => 0];

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
   Last_Asker : Session_Access := null;

   --  Which sessions hold a seat in the device's state room: a ring
   --  each, Kept_States + 1 slots of every linear layer's memories and
   --  states, laid one after another past the runs' table at the front.
   --  A seat is taken the first time a session's linear layer goes over
   --  and given back when the session closes or its ring changes size;
   --  a new one takes the first gap that fits, or the end.
   State_Seats : array (0 .. Model_Runner.Backend.Device.Block_Limit - 1)
     of Session_Access := [others => null];

   --  And when each seat was last asked for, on the same clock the blocks
   --  are stamped with, for the same reason: a session that finds every
   --  seat taken takes the one gone longest unasked, where it used to run
   --  every linear layer on the processor for the rest of its life.
   State_Used : array (State_Seats'Range) of Natural := [others => 0];

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
   is ((Element_Count (Item.Kept_States) + 1) * Device_Slot_Span (Item));

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

      --  What this session asked at its previous token, as a block's
      --  guard reads.
      Asked_Last : Natural := 0;
   begin
      Cleared := False;

      Block_Clock := Block_Clock + 1;
      if Last_Asker /= Item then
         Item.Asked_Before := Item.Asked_At;
         Item.State_Asked_Before := Item.State_Asked_At;
         Last_Asker := Item;
      end if;
      Asked_Last := Item.State_Asked_Before;
      Item.State_Asked_At := Block_Clock;

      Ok := Item.State_Seated;
      if Ok then
         for Seat in State_Seats'Range loop
            if State_Seats (Seat) = Item then
               State_Used (Seat) := Item.State_Asked_At;
            end if;
         end loop;
         return;
      end if;

      for Seat in State_Seats'Range loop
         if State_Seats (Seat) = null then
            Free := Seat;
            exit;
         end if;
      end loop;

      --  None free: the seat gone longest unasked is taken from the
      --  session sitting in it, as a block of the cache is, and under the
      --  same guard -- only from a session that has gone unasked since
      --  before this one's last ask, so that seventeen hybrids reading a
      --  token apiece in turn do not carry their rings back and forth
      --  every token. The ring in that seat comes home first: the host's
      --  copy is what the session writes back into the seat it is given
      --  next, and a seat given up holds whatever the session before it
      --  left there.
      if Free < 0 then
         declare
            Oldest : Natural := 0;
            Found  : Integer := -1;
         begin
            for Seat in State_Seats'Range loop
               if State_Seats (Seat) /= null
                 and then State_Seats (Seat) /= Item
                 and then (Found < 0 or else State_Used (Seat) < Oldest)
               then
                  Found  := Seat;
                  Oldest := State_Used (Seat);
               end if;
            end loop;

            if Found < 0 or else State_Used (Found) >= Asked_Last then
               return;
            end if;

            declare
               Turned : constant Session_Access := State_Seats (Found);
            begin
               Fetch_States (Turned);

               if Turned.State_On_Device then
                  return;
               end if;

               State_Seats (Found) := null;
               Turned.State_Seated := False;
               Free := Found;

               Model_Runner.Backend.Device.Note_Turned (Ring => True);
            end;
         end;
      end if;

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
      State_Used (Free) := Item.State_Asked_At;
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
         if Cleared and then Item.Committed = 0 then
            Item.State_On_Device := True;
            return;
         end if;
      end;

      Write_Ring (Item, Ok);

      if Ok then
         Item.State_On_Device := True;
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

   --  Give a session a block of the device's cache, and keep it there.
   --
   --  A session takes the lowest free block the first time it writes to the
   --  device's cache and holds it while anything else can be given one.
   --  Nothing moves while a round forms -- not when its members change --
   --  which is what makes a round free to form: its rows read the blocks
   --  their sessions were already in.
   --
   --  Where every block is held, the one stamped longest ago is taken from
   --  the session holding it. That session's cache is read back into the
   --  host's copy first, which is the copy of record for every other thing
   --  a session can do, and written into a block again when the session
   --  next has a layer to put there. A seventeenth session used to be
   --  refused the device's cache for the rest of its life and attend every
   --  layer on the processor, whatever the sixteen holding blocks were
   --  doing with them.
   --
   --  @param Item The session.
   --  @param Ok True when the block is the session's and holds its cache.
   procedure Take_Block (Item : Session_Access; Ok : out Boolean);

   --  Read back whatever the device wrote that the host's copy has not
   --  got. Declared here because a session turned out of its block must
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

      declare
         Settings : Configuration renames Item.Owner.Settings;

         Head_Size  : constant Natural := Settings.Head_Size;
         Value_Size : constant Natural := Settings.Value_Size;

         Room : constant Natural :=
           Model_Runner.Backend.Device.Attention_Head_Room;

         Wanted : constant Interfaces.Unsigned_64 :=
           Model_Runner.Backend.Device.Cache_Bytes_For
             (Block_Span_Of (Item)
              + Element_Count (Model_Runner.Backend.Device.Table_Room)
              + Element_Count (Model_Runner.Backend.Device.Sink_Room));

         Bound : constant Interfaces.Unsigned_64 :=
           Model_Runner.Backend.Device.Cache_Bound;
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
         --  another session, and none of them cold enough to turn out.
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
   is
      use type Model_Runner.Backend.Backend_Kind;

      Seat : Natural := 0;

      --  When this session last asked for a block before this call.
      Asked_Last : Natural := 0;
   begin
      Ok := False;

      if Item = null
        or else Item.Owner = null
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else (Item.Held = Exact
                 and then (Item.Keys = null or else Item.Values = null))
        or else Item.Held = Halved
        --  A head wider than the room the device's attention keeps is
        --  attended on the processor whatever the cache holds, so the
        --  cache is not put there: it was, and written every position,
        --  for kernels that would refuse every layer that read it.
        or else (Model_Runner.Backend.Device.Attention_Head_Room > 0
                 and then
                   (Item.Owner.Settings.Head_Size
                    > Model_Runner.Backend.Device.Attention_Head_Room
                    or else Item.Owner.Settings.Value_Size
                            > Model_Runner.Backend.Device.Attention_Head_Room))
        or else (Item.Held in Eighth | Fourth
                 and then (Item.Byte_Keys = null or else Item.Byte_Values = null
                           or else Item.Key_Scales = null
                           or else Item.Value_Scales = null
                           or else not Model_Runner.Backend.Device.Attends_Packed
                           --  And a shape that kernel reads: it takes four
                           --  elements of a row at a time out of one word,
                           --  so a head is a whole number of fours. A model
                           --  whose heads are another shape used to take a
                           --  block of the device's cache, have it written
                           --  every position, and have every layer's
                           --  sequence built and refused at its attention
                           --  step -- the uploads of a cache nothing there
                           --  would read.
                           or else not
                             Model_Runner.Backend.Device.Attends_Packed_Heads
                               (Item.Owner.Settings.Head_Size,
                                Item.Owner.Settings.Value_Size)))
      then
         return;
      end if;

      --  This ask, and the run of asks before it: what the session asked
      --  at its previous token is what says whether it may turn another
      --  session out, below. Its own last ask says nothing -- that was
      --  the layer before, a tick ago.
      Blocks_Were_Held := False;
      Block_Clock := Block_Clock + 1;
      if Last_Asker /= Item then
         Item.Asked_Before := Item.Asked_At;
         Item.State_Asked_Before := Item.State_Asked_At;
         Last_Asker := Item;
      end if;
      Asked_Last := Item.Asked_Before;
      Item.Asked_At := Block_Clock;

      --  Already this session's, which is every call after the first:
      --  there is nothing to ask the device and nothing to write. Stamped
      --  as it goes, so that the block another session takes where every
      --  one is held is the one nobody has read for longest.
      if Item.Seat >= 0 and then Block_Holder (Item.Seat) = Item then
         Block_Used (Item.Seat) := Item.Asked_At;
         Ok := True;
         return;
      end if;

      --  A session with nothing to keep has nothing to be given.
      if Block_Span_Of (Item.all) = 0 then
         return;
      end if;

      --  And a block is not dealt while pages are: the two grow from the
      --  front of the one buffer, so a device holds one kind or the other.
      --  A block session that finds pages held attends on the host until
      --  they are given back.
      if Pages_In_Use > 0 then
         return;
      end if;

      --  The lowest free one. A closed session gives its block back, so
      --  what a long-running server deals out is the sessions it has open
      --  rather than the sessions it has ever opened.
      while Seat < Block_Holder'Length
        and then Block_Holder (Seat) /= null
      loop
         Seat := Seat + 1;
      end loop;

      --  None free: the block stamped longest ago is taken from the
      --  session holding it. What the device wrote into that block and the
      --  host has not read yet is read first -- the host's copy is what
      --  the session carries back into the block it is given next, and a
      --  read that fails leaves the block where it is rather than losing
      --  the positions in it.
      if Seat >= Block_Holder'Length then
         declare
            Oldest : Natural := 0;
            Found  : Integer := -1;
         begin
            for Which in Block_Holder'Range loop
               if Block_Holder (Which) /= null
                 and then Block_Holder (Which) /= Item
                 and then (Found < 0 or else Block_Used (Which) < Oldest)
               then
                  Found  := Which;
                  Oldest := Block_Used (Which);
               end if;
            end loop;

            if Found < 0 then
               Blocks_Were_Held := True;
               return;
            end if;

            --  And only from a session that has gone unasked since before
            --  this one's last ask. Seventeen sessions reading a token
            --  apiece in turn are all as warm as each other: taking the
            --  coldest block would have each of them turn the next out
            --  every token and write its cache across the bus again,
            --  where the seventeenth doing without costs that one session
            --  its speed and leaves the sixteen alone. A session new to
            --  the device is warmer than anything asked before it was
            --  opened, which is what lets it in where a block has gone
            --  cold.
            if Block_Used (Found) >= Asked_Last then
               Blocks_Were_Held := True;
               return;
            end if;

            declare
               Turned : constant Session_Access := Block_Holder (Found);

               Settled : Boolean;
            begin
               Settle_Cache (Turned.all, Settled);

               --  A read that could not finish leaves the block where it
               --  is: the device still holds what the host did not get, so
               --  taking it would lose those positions.
               if not Settled then
                  return;
               end if;

               Block_Holder (Found) := null;
               Turned.Seat := -1;
               Seat := Found;

               Model_Runner.Backend.Device.Note_Turned;
            end;
         end;
      end if;

      declare
         --  What this session keeps, and where it goes: the first gap in
         --  the buffer that holds it, from the front, past every block held
         --  that overlaps -- which is how a ring is placed in the room of
         --  rings, and for the same reason. A block used to be its seat
         --  times one dealt width, so a short-context session behind a long
         --  one took a block the long one's size and a session wanting more
         --  than the dealt width was refused the cache for as long as any
         --  session of that width was open.
         Span : constant Element_Count := Block_Span_Of (Item.all);

         Base : Element_Count := First_Block_Gap (Span);

         Written : Boolean := True;
      begin
         --  Where that gap is past what the buffer has been dealt to while
         --  there is a gap below it, the blocks are moved down instead of
         --  the buffer growing -- as the room of rings moves its seats,
         --  and for the same reason: blocks are the size of the sessions
         --  in them and come back in whatever order those sessions close.
         if Base + Span > Block_Taken then
            declare
               Taken : Element_Count := 0;
               Moved : Boolean;
            begin
               for Which in Block_Holder'Range loop
                  if Block_Holder (Which) /= null then
                     Taken :=
                       Taken
                       + (Block_Span_Of (Block_Holder (Which).all)
                          + Block_Alignment - 1)
                         / Block_Alignment * Block_Alignment;
                  end if;
               end loop;

               if Block_Taken - Taken >= Span then
                  Compact_Blocks (Span, Moved);

                  if Moved then
                     Base := First_Block_Gap (Span);
                  end if;
               end if;
            end;
         end if;

         declare
            --  Room for this block and every block held, for the table a
            --  round reads past them, and for a layer's sinks past that.
            Wanted : constant Element_Count :=
              Element_Count'Max (Base + Span, Block_Taken)
              + Element_Count (Model_Runner.Backend.Device.Table_Room)
              + Element_Count (Model_Runner.Backend.Device.Sink_Room);

            --  And how far the halves are read: this block's need and
            --  every held block's, which for a packed one is the room a
            --  layer unpacks into and not the block.
            Copy_Upto : Element_Count := Base + Copy_Span_Of (Item.all);
         begin
            for Which in Block_Holder'Range loop
               if Block_Holder (Which) /= null then
                  Copy_Upto :=
                    Element_Count'Max
                      (Copy_Upto,
                       Block_Holder (Which).Cache_Base
                       + Copy_Span_Of (Block_Holder (Which).all));
               end if;
            end loop;

            Model_Runner.Backend.Device.Reserve_Cache
              (Wanted, Copy_Upto, Ok);
            if not Ok then
               return;
            end if;

            if Base + Span > Block_Taken then
               Block_Taken := Base + Span;
            end if;
         end;

         Item.Cache_Base := Base;

         Write_Block (Item, Base, Written);

         if not Written then
            Ok := False;
            return;
         end if;

         Item.Seat := Seat;
         Block_Holder (Seat) := Item;
         Block_Used (Seat) := Item.Asked_At;
         Ok := True;
      end;
   end Take_Block;

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
                   (Item.Pages.all
                      (Natural (Item.Page_First.all (Layer)) + Page)
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
                (Pages_Taken, Element_Count (Slot + 1) * Page_Elements);
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
   is
      use type Model_Runner.Backend.Backend_Kind;

      KV_Width : Element_Count;
      V_Width  : Element_Count;
   begin
      Ok := False;

      if Item = null
        or else not Item.Paged
        or else Item.Owner = null
        or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
        or else Item.Held not in Exact | Eighth | Fourth
        or else Item.Pages = null
        --  A cache dealt in blocks and one dealt in pages both grow from
        --  the front of the one buffer, so a device holds one kind or the
        --  other, not both at once. Where a block is held, a paged session
        --  is refused its pages and attends on the host until the blocks
        --  are given back; nothing already this session's is disturbed,
        --  since Paged_In means its pages are already dealt.
        or else (not Item.Paged_In and then Block_Taken > 0)
      then
         return;
      end if;

      --  Every page of the pool is one size, because the slots the owner
      --  array counts are that size: a base is turned back into a slot by
      --  dividing by it, in Close and where a session is turned out. Two
      --  models of different key and value widths would size their pages
      --  differently, so a session whose page is not the size the held
      --  pages are is refused while any are held and attends on the host --
      --  the pool serves one geometry at a time, as it serves one kind.
      --  Where none are held the size is the new session's.
      declare
         --  A page holds a position's keys and values -- in full for an
         --  exact session, or its four packed regions for a packed one,
         --  which is a smaller page again. The pool serves one of these at
         --  a time, so a page that is not the held size is refused.
         Want : constant Element_Count :=
           (if Item.Held in Eighth | Fourth
            then Packed_Page_Layout (Item.all).Span
            else Element_Count (Page_Positions) * Page_Row (Item.all));
      begin
         if not Item.Paged_In
           and then Pages_In_Use > 0
           and then Want /= Page_Elements
         then
            return;
         end if;

         if Pages_In_Use = 0 then
            Page_Elements := Want;
         end if;
      end;

      V_Width := Element_Count (Item.Owner.Settings.KV_Heads
                                * Item.Owner.Settings.Value_Size);
      KV_Width := Page_Row (Item.all) - V_Width;

      --  This ask, and the run of asks before it, on the clock the blocks
      --  are stamped with -- a paged session holds no block, so the two
      --  cannot disagree. What the session asked at its previous token is
      --  what says whether it may turn another out, below.
      Block_Clock := Block_Clock + 1;
      if Last_Asker /= Item then
         Item.Asked_Before := Item.Asked_At;
         Last_Asker := Item;
      end if;
      Item.Asked_At := Block_Clock;

      --  Already reaching this position, which every layer's ask but the
      --  first of a token does: the pages are all dealt, so there is no
      --  layer to walk, no reserve to grow and nothing to write. Stamped
      --  above still, so a page turned out elsewhere is the one nobody has
      --  read for longest.
      if Item.Paged_In and then Upto <= Element_Count (Item.Paged_Upto) then
         Ok := True;
         return;
      end if;

      --  Each layer up to the page its highest new position reaches. A
      --  page is a slot at the front the buffer has not dealt, and taking
      --  it may grow how far the buffer is dealt and so the reserve.
      for Layer in 0 .. Item.Page_Count.all'Last loop
         if not Linear (Item.Owner.Settings, Layer) then
            declare
               Want : constant Element_Count :=
                 Pages_Wanted (Item.all, Layer, Upto);
               First : constant Element_Count := Item.Page_First.all (Layer);
            begin
               while Item.Page_Count.all (Layer) < Want loop
                  declare
                     Slot : Natural := 0;
                  begin
                     while Slot < Page_Cap and then Page_Owner (Slot) /= null
                     loop
                        Slot := Slot + 1;
                     end loop;

                     if Slot >= Page_Cap then
                        --  No slot free: what has been dealt stays, and the
                        --  layer holds fewer pages than it wanted, which the
                        --  caller reads as the cache being full.
                        return;
                     end if;

                     Page_Owner (Slot) := Item;
                     Pages_In_Use := Pages_In_Use + 1;
                     Item.Pages.all
                       (Natural (First) + Natural (Item.Page_Count.all (Layer)))
                       := Element_Count (Slot) * Page_Elements;
                     Item.Page_Count.all (Layer) :=
                       Item.Page_Count.all (Layer) + 1;
                     Pages_Taken :=
                       Element_Count'Max
                         (Pages_Taken,
                          Element_Count (Slot + 1) * Page_Elements);
                  end;
               end loop;
            end;
         end if;
      end loop;

      --  Room for every page dealt, the per-layer page tables past them --
      --  a table a layer, its pages and the over-read's padding -- and a
      --  layer's sinks past that; and the tables laid out and written, all
      --  at once. A table a layer at its own place, read by that layer's
      --  whole layer, rather than one table rewritten a layer: the write is
      --  once a token where the pages grow and not once a layer. Where the
      --  buffer's front has moved under another session the tables move
      --  with it, so their places are worked out afresh here each time.
      --
      --  A round's members do not write their tables here: the next member
      --  takes a page where this one's table sat, so a round lays them out
      --  once its members are all seated, past its per-row table, and gives
      --  only the room for the write back to a member come again.
      if Write_Tables then
         declare
            Where : Element_Count := Pages_Taken;
            Words : Natural := 0;
         begin
            for Layer in Item.Page_Count.all'Range loop
               Item.Page_Table_At.all (Layer) := Where;
               if not Linear (Item.Owner.Settings, Layer) then
                  declare
                     Count : constant Natural :=
                       Natural (Item.Page_Count.all (Layer)) + Page_Table_Pad;
                  begin
                     Where := Where + Element_Count (Count);
                     Words := Words + Count;
                  end;
               end if;
            end loop;

            Model_Runner.Backend.Device.Reserve_Cache
              (Pages_Taken + Element_Count (Words)
               + Element_Count (Model_Runner.Backend.Device.Sink_Room),
               Copy_Upto => Pages_Taken, Ok => Ok);
            if not Ok then
               return;
            end if;

            declare
               Table : Model_Runner.Backend.Device.Word_List
                         (1 .. Natural'Max (Words, 1));
            begin
               for Layer in Item.Page_Count.all'Range loop
                  if not Linear (Item.Owner.Settings, Layer) then
                     declare
                        First : constant Element_Count :=
                          Item.Page_First.all (Layer);
                        Held  : constant Element_Count :=
                          Item.Page_Count.all (Layer);
                        Off   : constant Natural :=
                          Natural
                            (Item.Page_Table_At.all (Layer) - Pages_Taken);
                     begin
                        --  The layer's pages, and the padding a masked
                        --  over-read reads, each pointing at a real page.
                        for Page in 0 .. Natural (Held) + Page_Table_Pad - 1
                        loop
                           Table (Off + Page + 1) :=
                             Natural
                               (Item.Pages.all
                                  (Natural
                                     (First
                                      + Element_Count'Min
                                          (Element_Count (Page),
                                           Element_Count'Max (Held, 1) - 1))));
                        end loop;
                     end;
                  end if;
               end loop;

               Model_Runner.Backend.Device.Put_Table (Pages_Taken, Table, Ok);
               if not Ok then
                  return;
               end if;
            end;
         end;
      else
         --  A round member: room for its pages and the widest layer's
         --  table the round will write past them, and the sinks.
         declare
            Widest : Element_Count := 0;
         begin
            for Layer in Item.Page_Count.all'Range loop
               Widest :=
                 Element_Count'Max (Widest, Item.Page_Count.all (Layer));
            end loop;

            Model_Runner.Backend.Device.Reserve_Cache
              (Pages_Taken + Widest + Element_Count (Page_Table_Pad)
               + Element_Count (Model_Runner.Backend.Device.Sink_Room),
               Copy_Upto => Pages_Taken, Ok => Ok);
            if not Ok then
               return;
            end if;
         end;
      end if;

      --  What was committed before this session held these pages -- an
      --  evicted session come back -- written into them a page at a time.
      --  Nothing to write for a session that has only grown, whose new
      --  pages the place step of this pass fills.
      if not Item.Paged_In and then Item.Committed > 0 then
         declare
            Written : Boolean := True;
         begin
            --  Every layer that holds pages, which is every non-linear one
            --  including the blocks past the stack -- Page_Count runs to
            --  Layers + Next_Layers - 1, and pages are dealt for all of
            --  them, so all of them are written back, not the stack alone.
            for Layer in Item.Page_Count.all'Range loop
               if not Linear (Item.Owner.Settings, Layer) then
                  if Item.Held = Exact then
                     Write_Pages_Layer
                       (Item.all, Layer, KV_Width, V_Width,
                        Element_Count (Item.Committed), Written);
                  else
                     Write_Packed_Pages_Layer
                       (Item.all, Layer, KV_Width, V_Width,
                        Element_Count (Item.Committed), Written);
                  end if;
                  exit when not Written;
               end if;
            end loop;
            if not Written then
               Ok := False;
               return;
            end if;
         end;
      end if;

      Item.Paged_In := True;
      Item.Paged_Upto := Natural (Upto);
      Ok := True;
   end Take_Pages;

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

   --  Whether a layer's sinks can go to the device: the layer has them,
   --  the cache has room for them, and there are no more heads than the
   --  room holds.
   --
   --  @param Sinks The layer's sinks, or null.
   --  @return True where Sinks_Ready would put them.
   function Sinks_Fit
     (Sinks : Model_Runner.Tensors.Real_Array_Access) return Boolean
   is (Sinks = null
       or else Sinks.all'Length
               <= Element_Count (Model_Runner.Backend.Device.Sink_Room));

   --  A layer's sinks put where the device's attention reads them, a head
   --  each after the round's table, and where they went: what the
   --  attention step is told as Sinks_At. Zero for a layer without them,
   --  which is every layer of every architecture but one; and zero where
   --  they could not be put, which sends the layer to the host. Put every
   --  time rather than once, because every session of the model puts the
   --  same numbers and a copy of a few hundred bytes into a standing
   --  mapping is nothing beside the layer.
   --
   --  @param Sinks The layer's sinks, or null.
   --  @return Where they begin, in elements, or zero.
   function Sinks_Ready
     (Sinks : Model_Runner.Tensors.Real_Array_Access) return Natural
   is
      Where : constant Element_Count := Sinks_Room_At;
      Ok    : Boolean;
   begin
      if Sinks = null or else Where = 0 or else not Sinks_Fit (Sinks) then
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
            Natural (Block_Base (Item) + K_Base),
            Natural (Block_Base (Item) + Item.Keys.all'Length + V_Base),
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
            for Step in First .. Last loop
               if Held = Fourth then
                  Scores (At_Score + Step) :=
                    K.Head_Dot_Fourth
                      (Left     => Query,
                       At_Left  => Q_Origin,
                       Right    => Keys,
                       At_Row   => B.Byte_Count (Keys'First)
                                   + Byte_Of (Fourth, K_Base + Step * KV_Width,
                                              KV_Width),
                       Offset   => Group * Head_Size,
                       Scales   => Key_Scales,
                       At_Scale => Key_Scales'First
                                   + Scale_Of (Fourth, K_Base + Step * KV_Width,
                                               KV_Width),
                       Span     => Head_Size)
                    * Scale;
               else
                  declare
                     Origin : constant B.Byte_Count :=
                       B.Byte_Count (Keys'First)
                       + B.Byte_Count (K_Base + Step * KV_Width
                                       + Group * Head_Size);
                     Row    : constant Real :=
                       Key_Scales (Key_Scales'First + Rows + Step);
                  begin
                     Scores (At_Score + Step) :=
                       K.Head_Dot_Eighth
                         (Left     => Query,
                          At_Left  => Q_Origin,
                          Right    => Keys,
                          At_Right => Origin,
                          Scale    => Row,
                          Span     => Head_Size)
                       * Scale;
                  end;
               end if;
            end loop;

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
            --  in binary32, for the reasons written out in Blend_Exact: a
            --  position's values are contiguous, and a map in binary32 is
            --  eight lanes an instruction where binary64 is four.
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
                     if V_Held = Fourth then
                        K.Blend_Run_Fourth
                          (Sums      => Sums,
                           Weights   => Scores,
                           At_Weight => At_Score + First,
                           Scales    => Val_Scales,
                           At_Scale  => Val_Scales'First
                                        + Scale_Of (Fourth, V_Base + First * V_Width,
                                                    V_Width),
                           Blocks    => Blocks_Of (Fourth, V_Width),
                           Values    => Values,
                           At_Row    => Values'First
                                        + Byte_Of (Fourth, V_Base + First * V_Width,
                                                   V_Width),
                           Row_Bytes => Row_Bytes (Fourth, V_Width),
                           Offset    => Group * Value_Size + At_Component,
                           Steps     => Last - First + 1);
                     else
                        K.Blend_Run_Eighth
                          (Sums      => Sums,
                           Weights   => Scores,
                           At_Weight => At_Score + First,
                           Scales    => Val_Scales,
                           At_Scale  => Val_Scales'First + Rows + First,
                           Values    => Values,
                           At_Value  =>
                             Values'First
                             + B.Byte_Count (V_Base + First * V_Width
                                             + Group * Value_Size
                                             + At_Component),
                           Stride    => V_Width,
                           Steps     => Last - First + 1);
                     end if;

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
   end Blend_Eighth;

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
            for Step in First .. Last loop
               declare
                  Origin : constant Element_Count :=
                    Keys'First + K_Base + Step * KV_Width + Group * Head_Size;
               begin
                  Scores (At_Score + Step) :=
                    K.Head_Dot_Halved
                      (Left     => Query,
                       At_Left  => Q_Origin,
                       Right    => Keys,
                       At_Right => Origin,
                       Span     => Head_Size)
                    * Scale;
               end;
            end loop;

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
      Gate : N.Wide_Real := 0.0;
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

      for Index in Input.all'Range loop
         Gate := Gate
           + N.Wide_Real (Input.all (Index))
             * N.Wide_Real (Current.Shared_Router.all (Index));
      end loop;

      declare
         Scale : constant Real := Sigmoid (Real (Gate));
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

   procedure Mixture
     (Item    : in out Session;
      Current : Layer;
      Input   : T.Real_Array_Access;
      Result  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Settings : Configuration renames Item.Owner.Settings;
      Used     : constant Natural := Settings.Experts_Used;

      Chosen : array (0 .. Used - 1) of Natural := [others => 0];
      Share  : array (0 .. Used - 1) of Real := [others => 0.0];
      Taken  : array (0 .. Settings.Experts - 1) of Boolean :=
        [others => False];

      Total  : Real := 0.0;
      Usable : Boolean;

      --  Whether this position's experts are read gathered out of the
      --  stacks the device holds, which is also where it is routed: the
      --  same kernel a batch and a token's whole layer choose through, so
      --  that every road through a mixture on the device chooses alike.
      Gathered : constant Boolean :=
        Item.Owner.all.Stacked
        and then (Current.Expert_Gate_Bias = null)
                 = (Current.Expert_Up_Bias = null)
        and then Used <= Model_Runner.Backend.Device.Max_Members
        and then T.Is_Present (Current.Gate_Stack)
        and then T.Is_Present (Current.Up_Stack)
        and then T.Is_Present (Current.Down_Stack);
   begin
      --  On the pool, one position goes the way a batch does: an expert to
      --  a worker, whole, and the pool woken once a layer. Cut across the
      --  pool a row at a time, the eight experts of a generated token were
      --  twenty-four products of a few hundred rows each, with a wake and
      --  a settle around every one -- and a 35B-A3B token spent 31 ms of
      --  its 73 in them, reading the experts at 22 GB/s where the dense
      --  products read at 30. Dealt whole, a worker walks an expert's
      --  three matrices at its own rate and nine of them together are
      --  bound by the memory again. The same kernels on the same rows in
      --  the same order, so the bits are the bits; and the sum is still
      --  best expert first, which is what Mixture_Batch keeps Ranked for.
      if Model_Runner.Backend."="
           (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU)
        and then Workers_CPU."/=" (Item.Team, null)
        and then Input /= Result
        and then Result.all'Length = Input.all'Length
      then
         declare
            Grouped : Boolean;
         begin
            Result.all := Input.all;
            Mixture_Batch (Item, Current, Result, 1, Grouped, Status);
            if E.Is_Error (Status) or else Grouped then
               return;
            end if;
         end;
      end if;

      if Gathered then
         declare
            Choice : Model_Runner.Backend.Device.Choice_Array
              (0 .. Used - 1);
            Shares : Real_Array (0 .. Element_Count (Used) - 1);
         begin
            if Item.Seen /= null then
               declare
                  Which : constant String :=
                    Named_As (Item.Owner.all, Current.Router);
               begin
                  if Which /= "" then
                     Item.Seen.Note (Which, Input.all, 1);
                  end if;
               end;
            end if;

            Model_Runner.Backend.Device.Dispatch_Route
              (Current.Router, Current.Router_Bias, Settings.Experts, Used,
               Input, 1, Choice, Shares, Status, Item.Stopping);
            if E.Is_Error (Status) then
               return;
            end if;

            for Slot in Chosen'Range loop
               Chosen (Slot) := Choice (Slot);
               Share (Slot) := Shares (Element_Count (Slot));
            end loop;
         end;

         goto Routed;
      end if;

      Product (Item, Current.Router, Input, Item.Routing, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What the router adds before it chooses, where an architecture
      --  states one. It changes which experts are picked and not only their
      --  weights, so it belongs before the softmax rather than after.
      if Current.Router_Bias /= null then
         K.Add
           (Item.Routing.all
              (Item.Routing.all'First
               .. Item.Routing.all'First
                  + Element_Count (Settings.Experts) - 1),
            Current.Router_Bias.all);
      end if;

      K.Softmax (Item.Routing.all, Usable);
      if not Usable then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;

      for Slot in Chosen'Range loop
         declare
            Best : Integer := -1;
         begin
            for Which in Taken'Range loop
               if not Taken (Which)
                 and then
                   (Best < 0
                    or else Item.Routing (Element_Count (Which))
                            > Item.Routing (Element_Count (Best)))
               then
                  Best := Which;
               end if;
            end loop;

            Taken (Best) := True;
            Chosen (Slot) := Best;
            Share (Slot) := Item.Routing (Element_Count (Best));
            Total := Total + Share (Slot);
         end;
      end loop;

      --  The shares came out of a softmax, so they are positive and sum to
      --  one over every expert; over the chosen few they sum to less, and
      --  this is what puts them back on a scale where the sum below is a
      --  weighted average rather than an arbitrarily shrunken one.
      if not (Total > 0.0) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;

      for Slot in Share'Range loop
         Share (Slot) := Share (Slot) / Total;
      end loop;

      <<Routed>>

      Result.all := [others => 0.0];

      --  Gathered, where the device holds the stacks: the chosen experts'
      --  three projections and the gate between them as one submission of
      --  four dispatches, where a slice at a time was two submissions of
      --  twenty-four. What comes back is each expert's projection down,
      --  and the shares and the sum are applied here in the order they
      --  always were, so the answer is the same sum of the same terms.
      --
      --  Biases and the clamped gate are what the sequence does not do,
      --  so an architecture carrying them takes the road below.
      if Gathered then
         declare
            Width : constant Element_Count :=
              Element_Count (Settings.Embedding);
            Feed  : constant Element_Count :=
              Element_Count (Settings.Expert_Feed);

            Members : Model_Runner.Backend.Device.Member_List :=
              [others => 0];
         begin
            for Slot in Chosen'Range loop
               Members (Slot + 1) := Chosen (Slot);
            end loop;

            if Item.Mixed = null
              or else Item.Mixed.all'Length < Element_Count (Used) * Width
            then
               T.Free (Item.Mixed);
               T.Allocate (Element_Count (Used) * Width, Item.Mixed);
               if Item.Mixed = null then
                  Status := E.Make (E.Memory_Allocation_Failed);
                  return;
               end if;
            end if;

            --  What each product was given, where anything asked to be
            --  told: the same names the slice-at-a-time road notes.
            if Item.Seen /= null then
               for Slot in Chosen'Range loop
                  declare
                     Which : Expert renames
                       Current.Experts.all (Chosen (Slot));

                     Gate_Name : constant String :=
                       Named_As (Item.Owner.all, Which.Gate);
                     Up_Name   : constant String :=
                       Named_As (Item.Owner.all, Which.Up);
                  begin
                     if Gate_Name /= "" then
                        Item.Seen.Note (Gate_Name, Input.all, 1);
                     end if;

                     if Up_Name /= "" then
                        Item.Seen.Note (Up_Name, Input.all, 1);
                     end if;
                  end;
               end loop;
            end if;

            Model_Runner.Backend.Device.Dispatch_Mixture
              (Current.Gate_Stack, Current.Up_Stack, Current.Down_Stack,
               Feed, Width, Members, Used, Gate_Unit (Item.Owner.all),
               Input, Item.Mixed, Status, Item.Stopping,
                        Alpha => Item.Owner.all.Settings.Gate_Alpha,
                        Limit => Item.Owner.all.Settings.Gate_Limit,
                        Gate_Bias => Current.Expert_Gate_Bias,
                        Up_Bias   => Current.Expert_Up_Bias,
                        Down_Bias => Current.Expert_Down_Bias);
            if E.Is_Error (Status) then
               return;
            end if;

            for Slot in Chosen'Range loop
               declare
                  From : constant Element_Count :=
                    Item.Mixed.all'First + Element_Count (Slot) * Width;
               begin
                  Item.Expert_Row.all
                    (Item.Expert_Row.all'First
                     .. Item.Expert_Row.all'First + Width - 1) :=
                    Item.Mixed.all (From .. From + Width - 1);
               end;

               K.Scale (Item.Expert_Row.all, Share (Slot));
               K.Add (Result.all, Item.Expert_Row.all);
            end loop;

            --  On to the shared expert, not out: this road returned
            --  here, and a hybrid mixture's one position on the device
            --  went without its shared expert -- the batch had it, and
            --  the sweep's device pass never built the mixture shape.
            goto Summed;
         end;
      end if;

      --  Every chosen expert's two arms at once.
      --
      --  They all read the same input, so they are a group and a group is
      --  one submission. Two a expert over eight experts and forty-eight
      --  layers is one thousand five hundred and thirty-six submissions a
      --  token, each paying a call this file measured at 64.3 microseconds
      --  before it computes anything -- against one a layer for the dense
      --  path, which was fused for exactly this reason and left the mixture
      --  behind. See the README's `### A mixture, in one submission a
      --  layer`.
      if T."/=" (Item.Expert_Arms, null) then
         declare
            Pairs : T.View_Group (1 .. 2 * Used);
            Rooms : T.Target_Group (1 .. 2 * Used);
         begin
            for Slot in Chosen'Range loop
               Pairs (2 * Slot + 1) :=
                 Current.Experts.all (Chosen (Slot)).Gate;
               Pairs (2 * Slot + 2) :=
                 Current.Experts.all (Chosen (Slot)).Up;
               Rooms (2 * Slot + 1) := Item.Expert_Arms.all (2 * Slot + 1);
               Rooms (2 * Slot + 2) := Item.Expert_Arms.all (2 * Slot + 2);
            end loop;

            Product_Group (Item, Pairs, Input, Rooms, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end;
      end if;

      for Slot in Chosen'Range loop
         declare
            Which : Expert renames Current.Experts.all (Chosen (Slot));

            --  This expert's two arms, out of what the group wrote, or the
            --  session's single pair where there is no group.
            Gate_Room : constant T.Real_Array_Access :=
              (if T."/=" (Item.Expert_Arms, null)
               then Item.Expert_Arms.all (2 * Slot + 1) else Item.Gate);
            Up_Room   : constant T.Real_Array_Access :=
              (if T."/=" (Item.Expert_Arms, null)
               then Item.Expert_Arms.all (2 * Slot + 2) else Item.Up);

            Expert_Feed : constant Element_Count :=
              Element_Count (Item.Owner.all.Settings.Expert_Feed);

            At_Feed : constant Element_Count :=
              Element_Count (Chosen (Slot)) * Expert_Feed;

            At_Wide : constant Element_Count :=
              Element_Count (Chosen (Slot))
              * Element_Count (Item.Owner.all.Settings.Embedding);
         begin
            if T."=" (Item.Expert_Arms, null) then
               Product (Item, Which.Gate, Input, Gate_Room, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Product (Item, Which.Up, Input, Up_Room, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;

            --  The biases, where the architecture carries them. One
            --  expert's are the run of Expert_Feed at its own index of an
            --  array holding every expert's, so what is added is a slice
            --  rather than a whole.
            if Current.Expert_Gate_Bias /= null then
               K.Add
                 (Gate_Room.all (Gate_Room.all'First
                                 .. Gate_Room.all'First + Expert_Feed - 1),
                  Current.Expert_Gate_Bias.all
                    (Current.Expert_Gate_Bias.all'First + At_Feed
                     .. Current.Expert_Gate_Bias.all'First + At_Feed
                        + Expert_Feed - 1));
               K.Add
                 (Up_Room.all (Up_Room.all'First
                               .. Up_Room.all'First + Expert_Feed - 1),
                  Current.Expert_Up_Bias.all
                    (Current.Expert_Up_Bias.all'First + At_Feed
                     .. Current.Expert_Up_Bias.all'First + At_Feed
                        + Expert_Feed - 1));
            end if;

            --  The gate this architecture states. A mixture used to be
            --  Qwen3_MoE only, which is the plain logistic gate; the
            --  clamped one below reaches the up projection as well as the
            --  gate, so it cannot be an activation followed by a multiply.
            if Item.Owner.all.Settings.Gate_Alpha > 0.0 then
               K.Clamped_Gate
                 (Gate_Room.all, Up_Room.all,
                  Item.Owner.all.Settings.Gate_Alpha,
                  Item.Owner.all.Settings.Gate_Limit);
            else
               Gate_Activation (Item.Owner.all, Gate_Room.all);
               K.Multiply (Gate_Room.all, Up_Room.all);
            end if;

            --  Grouped, the gated vector is laid into the one activation
            --  the group reads and the products follow together below.
            if T."/=" (Item.Expert_Outs, null) then
               Item.Expert_Feeds.all
                 (Item.Expert_Feeds.all'First
                    + Element_Count (Slot) * Expert_Feed
                  .. Item.Expert_Feeds.all'First
                     + Element_Count (Slot) * Expert_Feed + Expert_Feed - 1)
                 := Gate_Room.all
                      (Gate_Room.all'First
                       .. Gate_Room.all'First + Expert_Feed - 1);

               goto Next_Expert;
            end if;

            Product (Item, Which.Down, Gate_Room, Item.Expert_Row, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            if Current.Expert_Down_Bias /= null then
               declare
                  Wide : constant Element_Count :=
                    Element_Count (Item.Owner.all.Settings.Embedding);
               begin
                  K.Add
                    (Item.Expert_Row.all
                       (Item.Expert_Row.all'First
                        .. Item.Expert_Row.all'First + Wide - 1),
                     Current.Expert_Down_Bias.all
                       (Current.Expert_Down_Bias.all'First + At_Wide
                        .. Current.Expert_Down_Bias.all'First + At_Wide
                           + Wide - 1));
               end;
            end if;

            K.Scale (Item.Expert_Row.all, Share (Slot));
            K.Add (Result.all, Item.Expert_Row.all);

            <<Next_Expert>>
            null;
         end;
      end loop;

      --  And every chosen expert's down projection at once. Each reads its
      --  own stretch of the one activation, which is what the stride on a
      --  group is for, so eight submissions a layer become one.
      --
      --  The bias, the share and the sum stay where they were and in the
      --  order they were in: the products are the same products, batched.
      if T."/=" (Item.Expert_Outs, null) then
         declare
            Downs : T.View_Group (1 .. Used);
            Rooms : T.Target_Group (1 .. Used);

            Wide : constant Element_Count :=
              Element_Count (Settings.Embedding);
         begin
            for Slot in Chosen'Range loop
               Downs (Slot + 1) := Current.Experts.all (Chosen (Slot)).Down;
               Rooms (Slot + 1) := Item.Expert_Outs.all (Slot + 1);
            end loop;

            Product_Group
              (Item, Downs, Item.Expert_Feeds, Rooms, Status,
               Apart => Element_Count (Settings.Expert_Feed));
            if E.Is_Error (Status) then
               return;
            end if;

            for Slot in Chosen'Range loop
               declare
                  Mine : T.Real_Array_Access renames
                    Item.Expert_Outs.all (Slot + 1);

                  At_Wide : constant Element_Count :=
                    Element_Count (Chosen (Slot)) * Wide;
               begin
                  if Current.Expert_Down_Bias /= null then
                     K.Add
                       (Mine.all (Mine.all'First
                                  .. Mine.all'First + Wide - 1),
                        Current.Expert_Down_Bias.all
                          (Current.Expert_Down_Bias.all'First + At_Wide
                           .. Current.Expert_Down_Bias.all'First + At_Wide
                              + Wide - 1));
                  end if;

                  K.Scale (Mine.all, Share (Slot));
                  K.Add (Result.all, Mine.all);
               end;
            end loop;
         end;
      end if;

      <<Summed>>
      if T.Is_Present (Current.Shared_Gate) then
         Shared_Expert (Item, Current, Input, Result.all, Status);
      end if;
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
   procedure Mixture_Batch
     (Item    : in out Session;
      Current : Layer;
      Rows    : T.Real_Array_Access;
      Count   : Element_Count;
      Ok      : out Boolean;
      Status  : out E.Error_Info)
   is
      Settings : Configuration renames Item.Owner.Settings;

      Used   : constant Natural := Settings.Experts_Used;
      Many   : constant Natural := Settings.Experts;
      Width  : constant Element_Count := Element_Count (Settings.Embedding);
      Feed   : constant Element_Count :=
        Element_Count (Settings.Expert_Feed);

      Wide   : constant Element_Count := Count * Width;

      --  Whether the experts are dealt to the pool's workers below, an
      --  expert to a worker -- in which case the shared expert goes with
      --  them, as chunks of the same job, rather than as three products
      --  of its own cut across the pool with a wake and a settle around
      --  each. Three megabytes a layer beside the experts' thirty-five,
      --  and 0.14 ms a layer of a four-row batch where the bytes were
      --  0.09 -- and on a token, the same three dispatches for one row.
      On_Pool : constant Boolean :=
        Model_Runner.Backend."="
          (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU)
        and then Workers_CPU."/=" (Item.Team, null);

      --  The shared expert's feed width, where there is one; the experts'
      --  otherwise, so the rooms below are never too narrow.
      Shared_Feed : constant Element_Count :=
        (if T.Is_Present (Current.Shared_Gate)
         then Element_Count (Settings.Shared_Feed) else Feed);

      --  Take a buffer if there is not one, or a wider one if what there is
      --  is too narrow. A session does not know how wide a batch it will be
      --  handed, and every one of these is sized by that.
      procedure Ensure
        (Room : in out T.Real_Array_Access; Length : Element_Count) is
      begin
         if Room = null or else Room.all'Length < Length then
            T.Free (Room);
            T.Allocate (Length, Room);
         end if;
      end Ensure;

      procedure Ensure_Choices
        (Room : in out Choice_Access; Length : Natural)
      is
         procedure Release is
           new Ada.Unchecked_Deallocation (Choice_List, Choice_Access);
      begin
         if Room = null or else Room.all'Length < Length then
            if Room /= null then
               Release (Room);
            end if;

            Room := new Choice_List (0 .. Length - 1);
         end if;
      end Ensure_Choices;

      Usable : Boolean;
   begin
      Ok := False;
      Status := E.Success;

      Ensure (Item.Route_Rows, Count * Element_Count (Many));
      Ensure (Item.Pick_Share, Count * Element_Count (Used));
      Ensure (Item.Gather_In, Wide);
      Ensure (Item.Gather_A, Count * Feed);
      Ensure (Item.Gather_B, Count * Feed);
      Ensure (Item.Gather_Out, Wide);
      Ensure (Item.Ranked, Count * Element_Count (Used) * Width);
      Ensure_Choices (Item.Pick_Which, Natural (Count) * Used);
      Ensure_Choices (Item.Gathered, Natural (Count));

      if Item.Route_Rows = null or else Item.Pick_Share = null
        or else Item.Gather_In = null or else Item.Gather_A = null
        or else Item.Gather_B = null or else Item.Gather_Out = null
        or else Item.Ranked = null
        or else Item.Pick_Which = null or else Item.Gathered = null
      then
         --  Not an error: the caller runs the positions one at a time,
         --  which is what it did before any of this existed.
         return;
      end if;

      --  The shared expert over the whole batch, while the rows are still
      --  the input: its answer and its gate a row, added in at the end
      --  once the chosen experts have been summed into the rows.
      if T.Is_Present (Current.Shared_Gate) then
         declare
            Shared : constant Element_Count :=
              Element_Count (Settings.Shared_Feed);
         begin
            Ensure (Item.Shared_Rows_A, Count * Shared);
            Ensure (Item.Shared_Rows_B, Count * Shared);
            Ensure (Item.Shared_Rows_Out, Wide + Count);

            if Item.Shared_Rows_A = null or else Item.Shared_Rows_B = null
              or else Item.Shared_Rows_Out = null
            then
               return;
            end if;

            --  The gates first, after the answer's room: one number a
            --  row, the sigmoid of the router row against the input.
            for Which in 0 .. Count - 1 loop
               declare
                  At_Row : constant Element_Count :=
                    Rows.all'First + Which * Width;
                  Gate : N.Wide_Real := 0.0;
               begin
                  for C in 0 .. Width - 1 loop
                     Gate := Gate
                       + N.Wide_Real (Rows.all (At_Row + C))
                         * N.Wide_Real (Current.Shared_Router.all (C));
                  end loop;

                  Item.Shared_Rows_Out.all (Wide + Which) :=
                    Sigmoid (Real (Gate));
               end;
            end loop;

            --  Its answer, unless the pool will make it below among the
            --  experts' chunks.
            if not On_Pool then
               Product_Batch
                 (Item, Current.Shared_Gate, Rows, Count, Item.Shared_Rows_A,
                  Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Product_Batch
                 (Item, Current.Shared_Up, Rows, Count, Item.Shared_Rows_B,
                  Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               K.SiLU (Item.Shared_Rows_A.all (0 .. Count * Shared - 1));
               K.Multiply
                 (Item.Shared_Rows_A.all (0 .. Count * Shared - 1),
                  Item.Shared_Rows_B.all (0 .. Count * Shared - 1));

               Product_Batch
                 (Item, Current.Shared_Down, Item.Shared_Rows_A, Count,
                  Item.Shared_Rows_Out, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;
      end if;

      --  Routed on the device where the device holds the stacks, through
      --  the kernel a token's whole layer routes through, so that a prompt
      --  and a token choose the same experts with the same shares: the
      --  host's softmax sums in binary64 and the device's in binary32,
      --  and a share a bit apart is an answer a bit apart.
      if Item.Owner.all.Stacked
        and then Model_Runner.Backend."="
                   (Item.Owner.Able.Kind,
                    Model_Runner.Backend.Backend_Device)
        and then Used <= Model_Runner.Backend.Device.Max_Members
      then
         declare
            Choice : Model_Runner.Backend.Device.Choice_Array
              (0 .. Natural (Count) * Used - 1);
         begin
            if Item.Seen /= null then
               declare
                  Which : constant String :=
                    Named_As (Item.Owner.all, Current.Router);
               begin
                  if Which /= "" then
                     Item.Seen.Note
                       (Which,
                        Rows.all (Rows.all'First
                                  .. Rows.all'First + Count * Width - 1),
                        Count);
                  end if;
               end;
            end if;

            Model_Runner.Backend.Device.Dispatch_Route
              (Current.Router, Current.Router_Bias, Many, Used, Rows, Count,
               Choice,
               Item.Pick_Share.all
                 (Item.Pick_Share.all'First
                  .. Item.Pick_Share.all'First
                     + Count * Element_Count (Used) - 1),
               Status, Item.Stopping);
            if E.Is_Error (Status) then
               return;
            end if;

            for Index in Choice'Range loop
               Item.Pick_Which.all (Index) := Choice (Index);
            end loop;

            goto Chosen;
         end;
      end if;

      --  Every position's router scores at once, which is one product where
      --  it was one a position.
      Product_Batch
        (Item, Current.Router, Rows, Count, Item.Route_Rows, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  And the choosing, position by position, exactly as one position's
      --  mixture chooses: the bias before the softmax because it changes
      --  which experts are picked, the largest few in order, and the shares
      --  put back on a scale where their sum is one.
      for Where in 0 .. Count - 1 loop
         declare
            At_Row : constant Element_Count :=
              Item.Route_Rows.all'First + Where * Element_Count (Many);

            Scores : T.Real_Array renames
              Item.Route_Rows.all (At_Row .. At_Row + Element_Count (Many) - 1);

            Taken : array (0 .. Many - 1) of Boolean := [others => False];
            Total : Real := 0.0;
         begin
            if Current.Router_Bias /= null then
               K.Add (Scores, Current.Router_Bias.all);
            end if;

            K.Softmax (Scores, Usable);
            if not Usable then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;

            for Slot in 0 .. Used - 1 loop
               declare
                  Best : Integer := -1;
               begin
                  for Which in Taken'Range loop
                     if not Taken (Which)
                       and then
                         (Best < 0
                          or else Scores (Scores'First + Element_Count (Which))
                                  > Scores
                                      (Scores'First + Element_Count (Best)))
                     then
                        Best := Which;
                     end if;
                  end loop;

                  Taken (Best) := True;
                  Item.Pick_Which.all (Natural (Where) * Used + Slot) := Best;
                  Item.Pick_Share.all
                    (Item.Pick_Share.all'First
                     + Where * Element_Count (Used) + Element_Count (Slot)) :=
                    Scores (Scores'First + Element_Count (Best));
                  Total := Total
                    + Scores (Scores'First + Element_Count (Best));
               end;
            end loop;

            if not (Total > 0.0) then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;

            for Slot in 0 .. Used - 1 loop
               declare
                  At_Share : constant Element_Count :=
                    Item.Pick_Share.all'First
                    + Where * Element_Count (Used) + Element_Count (Slot);
               begin
                  Item.Pick_Share.all (At_Share) :=
                    Item.Pick_Share.all (At_Share) / Total;
               end;
            end loop;
         end;
      end loop;

      <<Chosen>>

      --  On the pool, an expert to a worker rather than a row to a worker.
      --
      --  An expert's product on a prompt is a handful of vectors by a few
      --  hundred rows, and the pool cut every one of the three hundred a
      --  layer across eight workers -- eight wakes and eight settles a
      --  product for a share of a few thousand rows each, which is where
      --  Qwen3-30B-A3B's prompt sat at 71 tokens a second against
      --  llama.cpp's 108 with the products themselves the same. Shared by
      --  expert, each worker gathers, multiplies, gates and scatters its
      --  own experts whole, serially, and the pool is woken once a layer.
      --
      --  The sum is still the sum below, in rank order: a worker writes
      --  each answer to the place its position and rank name, and no two
      --  experts share one, so the workers never write where another
      --  reads. The products a worker runs serially are the products the
      --  pool would have cut, so the bits are the bits.
      if On_Pool then
         declare
            --  Every expert's members, gathered once: where each expert's
            --  run begins in Listed and how long it is.
            Listed : Choice_List (0 .. Natural (Count) * Used - 1);
            Starts : array (0 .. Many - 1) of Natural := [others => 0];
            Counts : array (0 .. Many - 1) of Natural := [others => 0];
            Filled : Natural := 0;

            --  The items of the job: an expert's members in runs of at
            --  most Chunk_Size, so that a run is about the same work as
            --  the next whatever the expert. Dealt whole, an expert
            --  chosen by eighty positions beside one chosen by two left
            --  the pool half idle -- the shares are cut by count -- and
            --  the samples said so: as many workers waiting for a share
            --  as in a kernel. In runs, the shares are level to a run.
            --
            --  Order says which run each item of the job is, the runs
            --  dealt into the shares largest first and back and forth.
            Chunk_Size : constant := 16;

            --  And the shared expert's, one for every Chunk_Size rows of
            --  the batch, its number being Many: the expert past the last.
            Dealing_Shared : constant Boolean :=
              T.Is_Present (Current.Shared_Gate);

            Most_Chunks : constant Natural :=
              Natural (Count) * Used + Many + Natural (Count);

            Chunk_Expert : array (0 .. Most_Chunks - 1) of Natural;
            Chunk_Start  : array (0 .. Most_Chunks - 1) of Natural;
            Chunk_Count  : array (0 .. Most_Chunks - 1) of Natural;
            Chunks       : Natural := 0;

            Order  : array (0 .. Most_Chunks - 1) of Natural;
            Widest : Natural := 0;

            --  The layer's rows quantized once, for the gates and ups to
            --  gather out of: one packing where every expert's gate and up
            --  want the same sums, two where a mixture's formats differ in
            --  that. Where the pool does not quantize, neither is packed
            --  and the rows go to the products as they are.
            Packed_Super : Workers_CPU.Packed_Rows;
            Packed_Plain : Workers_CPU.Packed_Rows;
            Has_Super    : Boolean := False;
            Has_Plain    : Boolean := False;

            type Expert_Share is limited new Workers_CPU.Task_Item with
               record
                  Ok : Boolean := True;
               end record;

            overriding procedure Run
              (Share : in out Expert_Share;
               From  : Element_Count;
               To    : Element_Count);

            overriding procedure Run
              (Share : in out Expert_Share;
               From  : Element_Count;
               To    : Element_Count)
            is
               Local : E.Error_Info;

               --  Room for the widest expert, taken once a share rather
               --  than once an expert.
               In_Room  : T.Real_Array_Access;
               A_Room   : T.Real_Array_Access;
               B_Room   : T.Real_Array_Access;
               Out_Room : T.Real_Array_Access;
            begin
               T.Allocate (Element_Count (Widest) * Width, In_Room);
               T.Allocate
                 (Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed),
                  A_Room);
               T.Allocate
                 (Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed),
                  B_Room);
               T.Allocate (Element_Count (Widest) * Width, Out_Room);

               if In_Room = null or else A_Room = null
                 or else B_Room = null or else Out_Room = null
               then
                  Share.Ok := False;
               end if;

               for Index_Of in Natural (From) .. Natural (To) loop
                  if Share.Ok and then Chunk_Expert (Order (Index_Of)) = Many
                  then
                     --  The shared expert over a run of the batch's rows:
                     --  the same three products an expert is, over the
                     --  rows themselves rather than a gathering of them,
                     --  and its answer put where the sums below read the
                     --  shared expert's -- a row's own place, at its gate.
                     declare
                        Chunk : constant Natural := Order (Index_Of);
                        Start : constant Natural := Chunk_Start (Chunk);
                        Members_Held : constant Natural :=
                          Chunk_Count (Chunk);
                        Held : constant Element_Count :=
                          Element_Count (Members_Held);
                        Picked : Model_Runner.Shares.Member_Rows
                          (0 .. Members_Held - 1);
                        Done   : Boolean;
                     begin
                        for Index in 0 .. Members_Held - 1 loop
                           declare
                              At_In : constant Element_Count :=
                                Rows.all'First
                                + Element_Count (Start + Index) * Width;
                              At_Room : constant Element_Count :=
                                In_Room.all'First
                                + Element_Count (Index) * Width;
                           begin
                              In_Room.all (At_Room .. At_Room + Width - 1)
                                := Rows.all (At_In .. At_In + Width - 1);
                              Picked (Index) := Start + Index;
                           end;
                        end loop;

                        Done := False;
                        if Supers (Current.Shared_Gate) and then Has_Super
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Gate, Packed_Super, Picked,
                              A_Room, Done);
                        elsif not Supers (Current.Shared_Gate)
                          and then Has_Plain
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Gate, Packed_Plain, Picked,
                              A_Room, Done);
                        end if;

                        if not Done then
                           Workers_CPU.Dispatch_Batch
                             (null, Current.Shared_Gate, In_Room, Held,
                              A_Room, Local);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;
                        end if;

                        Done := False;
                        if Supers (Current.Shared_Up) and then Has_Super
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Up, Packed_Super, Picked,
                              B_Room, Done);
                        elsif not Supers (Current.Shared_Up)
                          and then Has_Plain
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Up, Packed_Plain, Picked,
                              B_Room, Done);
                        end if;

                        if not Done then
                           Workers_CPU.Dispatch_Batch
                             (null, Current.Shared_Up, In_Room, Held,
                              B_Room, Local);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;
                        end if;

                        --  The gated middle, as the batch off the pool
                        --  and one position both take it: the logistic
                        --  unit, whatever the experts' own is.
                        K.SiLU (A_Room.all (A_Room.all'First
                                            .. A_Room.all'First
                                               + Held * Shared_Feed - 1));
                        K.Multiply
                          (A_Room.all (A_Room.all'First
                                       .. A_Room.all'First
                                          + Held * Shared_Feed - 1),
                           B_Room.all (B_Room.all'First
                                       .. B_Room.all'First
                                          + Held * Shared_Feed - 1));

                        Workers_CPU.Dispatch_Batch
                          (null, Current.Shared_Down, A_Room, Held,
                           Out_Room, Local);
                        if E.Is_Error (Local) then
                           Share.Ok := False;
                        end if;

                        for Index in 0 .. Members_Held - 1 loop
                           declare
                              From_At : constant Element_Count :=
                                Out_Room.all'First
                                + Element_Count (Index) * Width;
                              Into : constant Element_Count :=
                                Item.Shared_Rows_Out.all'First
                                + Element_Count (Start + Index) * Width;
                           begin
                              Item.Shared_Rows_Out.all
                                (Into .. Into + Width - 1) :=
                                Out_Room.all (From_At .. From_At + Width - 1);
                           end;
                        end loop;
                     end;
                  elsif Share.Ok then
                     declare
                        Chunk : constant Natural := Order (Index_Of);
                        Which : constant Natural := Chunk_Expert (Chunk);
                        Start : constant Natural := Chunk_Start (Chunk);
                        Members_Held : constant Natural :=
                          Chunk_Count (Chunk);

                        Held : constant Element_Count :=
                          Element_Count (Members_Held);

                        Expert_At : Expert renames
                          Current.Experts.all (Which);
                     begin
                        begin
                           for Index in 0 .. Members_Held - 1 loop
                              declare
                                 Pick : constant Natural :=
                                   Listed (Start + Index);
                                 Where : constant Element_Count :=
                                   Element_Count (Pick / Used);
                                 At_In : constant Element_Count :=
                                   Rows.all'First + Where * Width;
                                 At_Room : constant Element_Count :=
                                   In_Room.all'First
                                   + Element_Count (Index) * Width;
                              begin
                                 In_Room.all (At_Room .. At_Room + Width - 1)
                                   := Rows.all (At_In .. At_In + Width - 1);
                              end;
                           end loop;

                           --  The two arms from the packed rows where
                           --  the pool packed them, gathered by member,
                           --  and from the rows as they are otherwise.
                           declare
                              Picked : Model_Runner.Shares.Member_Rows
                                (0 .. Members_Held - 1);
                              Done   : Boolean;
                           begin
                              for Index in Picked'Range loop
                                 Picked (Index) :=
                                   Listed (Start + Index) / Used;
                              end loop;

                              Done := False;
                              if Supers (Expert_At.Gate) and then Has_Super
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Gate, Packed_Super, Picked,
                                    A_Room, Done);
                              elsif not Supers (Expert_At.Gate)
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Gate, Packed_Plain, Picked,
                                    A_Room, Done);
                              end if;

                              if not Done then
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Gate, In_Room, Held,
                                    A_Room, Local);
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
                                 end if;
                              end if;

                              Done := False;
                              if Supers (Expert_At.Up) and then Has_Super
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Up, Packed_Super, Picked,
                                    B_Room, Done);
                              elsif not Supers (Expert_At.Up)
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Up, Packed_Plain, Picked,
                                    B_Room, Done);
                              end if;

                              if not Done then
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Up, In_Room, Held,
                                    B_Room, Local);
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
                                 end if;
                              end if;
                           end;

                           for Index in 0 .. Members_Held - 1 loop
                              declare
                                 At_Arm : constant Element_Count :=
                                   Element_Count (Index) * Feed;

                                 Gate_Part : T.Real_Array renames
                                   A_Room.all
                                     (A_Room.all'First + At_Arm
                                      .. A_Room.all'First + At_Arm + Feed
                                         - 1);

                                 Up_Part : T.Real_Array renames
                                   B_Room.all
                                     (B_Room.all'First + At_Arm
                                      .. B_Room.all'First + At_Arm + Feed
                                         - 1);

                                 At_Feed : constant Element_Count :=
                                   Element_Count (Which) * Feed;
                              begin
                                 if Current.Expert_Gate_Bias /= null then
                                    K.Add
                                      (Gate_Part,
                                       Current.Expert_Gate_Bias.all
                                         (Current.Expert_Gate_Bias.all'First
                                            + At_Feed
                                          .. Current.Expert_Gate_Bias.all'First
                                             + At_Feed + Feed - 1));
                                    K.Add
                                      (Up_Part,
                                       Current.Expert_Up_Bias.all
                                         (Current.Expert_Up_Bias.all'First
                                            + At_Feed
                                          .. Current.Expert_Up_Bias.all'First
                                             + At_Feed + Feed - 1));
                                 end if;

                                 if Settings.Gate_Alpha > 0.0 then
                                    K.Clamped_Gate
                                      (Gate_Part, Up_Part,
                                       Settings.Gate_Alpha,
                                       Settings.Gate_Limit);
                                 else
                                    Gate_Activation
                                      (Item.Owner.all, Gate_Part);
                                    K.Multiply (Gate_Part, Up_Part);
                                 end if;
                              end;
                           end loop;

                           Workers_CPU.Dispatch_Batch
                             (null, Expert_At.Down, A_Room, Held, Out_Room,
                              Local);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;

                           for Index in 0 .. Members_Held - 1 loop
                              declare
                                 Pick : constant Natural :=
                                   Listed (Start + Index);

                                 From_At : constant Element_Count :=
                                   Out_Room.all'First
                                   + Element_Count (Index) * Width;

                                 Into : constant Element_Count :=
                                   Item.Ranked.all'First
                                   + Element_Count (Pick) * Width;

                                 Mine : T.Real_Array renames
                                   Item.Ranked.all (Into .. Into + Width - 1);

                                 At_Wide : constant Element_Count :=
                                   Element_Count (Which) * Width;
                              begin
                                 Mine := Out_Room.all
                                   (From_At .. From_At + Width - 1);

                                 if Current.Expert_Down_Bias /= null then
                                    K.Add
                                      (Mine,
                                       Current.Expert_Down_Bias.all
                                         (Current.Expert_Down_Bias.all'First
                                            + At_Wide
                                          .. Current.Expert_Down_Bias.all'First
                                             + At_Wide + Width - 1));
                                 end if;
                              end;
                           end loop;
                        end;
                     end;
                  end if;
               end loop;

               T.Free (In_Room);
               T.Free (A_Room);
               T.Free (B_Room);
               T.Free (Out_Room);
            end Run;

            Share : aliased Expert_Share;
         begin
            for Which in 0 .. Many - 1 loop
               Starts (Which) := Filled;

               for Where in 0 .. Natural (Count) - 1 loop
                  for Slot in 0 .. Used - 1 loop
                     if Item.Pick_Which.all (Where * Used + Slot) = Which then
                        Listed (Filled) := Where * Used + Slot;
                        Filled := Filled + 1;
                        Counts (Which) := Counts (Which) + 1;
                     end if;
                  end loop;
               end loop;

               --  What each product was given, where anything asked to be
               --  told, said here on the submitting task as the road below
               --  says it.
               if Item.Seen /= null and then Counts (Which) > 0 then
                  declare
                     Expert_At : Expert renames Current.Experts.all (Which);
                     Gate_Name : constant String :=
                       Named_As (Item.Owner.all, Expert_At.Gate);
                     Up_Name   : constant String :=
                       Named_As (Item.Owner.all, Expert_At.Up);
                     Down_Name : constant String :=
                       Named_As (Item.Owner.all, Expert_At.Down);
                  begin
                     --  The gathered input is not built yet on this task;
                     --  a watcher is told the positions' own rows instead,
                     --  which is what the products read, gathered.
                     if Gate_Name /= "" or else Up_Name /= ""
                       or else Down_Name /= ""
                     then
                        Item.Seen.Note
                          ((if Gate_Name /= "" then Gate_Name
                            elsif Up_Name /= "" then Up_Name
                            else Down_Name),
                           Rows.all (Rows.all'First
                                     .. Rows.all'First + Count * Width - 1),
                           Count);
                     end if;
                  end;
               end if;
            end loop;

            --  The runs: each expert's members in Chunk_Size at a time.
            for Which in Counts'Range loop
               declare
                  Done : Natural := 0;
               begin
                  while Done < Counts (Which) loop
                     Chunk_Expert (Chunks) := Which;
                     Chunk_Start (Chunks) := Starts (Which) + Done;
                     Chunk_Count (Chunks) :=
                       Natural'Min (Chunk_Size, Counts (Which) - Done);
                     Widest := Natural'Max (Widest, Chunk_Count (Chunks));
                     Done := Done + Chunk_Count (Chunks);
                     Chunks := Chunks + 1;
                  end loop;
               end;
            end loop;

            --  The rows packed once, for each kind of sums a gate or up
            --  in this layer wants.
            if Dealing_Shared then
               declare
                  Done : Natural := 0;
               begin
                  while Done < Natural (Count) loop
                     Chunk_Expert (Chunks) := Many;
                     Chunk_Start (Chunks) := Done;
                     Chunk_Count (Chunks) :=
                       Natural'Min (Chunk_Size, Natural (Count) - Done);
                     Widest := Natural'Max (Widest, Chunk_Count (Chunks));
                     Done := Done + Chunk_Count (Chunks);
                     Chunks := Chunks + 1;
                  end loop;
               end;
            end if;

            for Which in 0 .. Many - 1 loop
               if Counts (Which) > 0 then
                  if Supers (Current.Experts.all (Which).Gate)
                    or else Supers (Current.Experts.all (Which).Up)
                  then
                     Has_Super := True;
                  end if;
                  if not Supers (Current.Experts.all (Which).Gate)
                    or else not Supers (Current.Experts.all (Which).Up)
                  then
                     Has_Plain := True;
                  end if;
               end if;
            end loop;

            if Dealing_Shared then
               if Supers (Current.Shared_Gate) or else Supers (Current.Shared_Up)
               then
                  Has_Super := True;
               end if;
               if not Supers (Current.Shared_Gate)
                 or else not Supers (Current.Shared_Up)
               then
                  Has_Plain := True;
               end if;
            end if;

            if Has_Super then
               Workers_CPU.Pack
                 (Packed_Super, Rows, Count, Width, True, Has_Super);
            end if;
            if Has_Plain then
               Workers_CPU.Pack
                 (Packed_Plain, Rows, Count, Width, False, Has_Plain);
            end if;

            --  The experts by size, largest first, dealt back and forth
            --  across as many bins as the pool will cut shares, and the
            --  bins laid out one after another.
            declare
               Bins   : constant Positive :=
                 Positive (Workers_CPU.Worker_Total (Item.Team.all)) + 1;
               Sorted : array (0 .. Chunks - 1) of Natural;
               Bin_Of : array (0 .. Chunks - 1) of Natural;
               Bin    : Natural := 0;
               Ahead  : Boolean := True;
               Placed : Natural := 0;
            begin
               for Which in Sorted'Range loop
                  Sorted (Which) := Which;
               end loop;

               for Outer in 1 .. Chunks - 1 loop
                  declare
                     Moving : constant Natural := Sorted (Outer);
                     Inner  : Integer := Outer - 1;
                  begin
                     while Inner >= 0
                       and then Chunk_Count (Sorted (Inner))
                                < Chunk_Count (Moving)
                     loop
                        Sorted (Inner + 1) := Sorted (Inner);
                        Inner := Inner - 1;
                     end loop;
                     Sorted (Inner + 1) := Moving;
                  end;
               end loop;

               for Rank in Sorted'Range loop
                  Bin_Of (Sorted (Rank)) := Bin;

                  if Ahead then
                     if Bin = Bins - 1 then
                        Ahead := False;
                     else
                        Bin := Bin + 1;
                     end if;
                  else
                     if Bin = 0 then
                        Ahead := True;
                     else
                        Bin := Bin - 1;
                     end if;
                  end if;
               end loop;

               for Bin_Index in 0 .. Bins - 1 loop
                  for Which in Bin_Of'Range loop
                     if Bin_Of (Which) = Bin_Index then
                        Order (Placed) := Which;
                        Placed := Placed + 1;
                     end if;
                  end loop;
               end loop;
            end;

            if Chunks > 0 then
               Workers_CPU.Dispatch_Shares
                 (Item.Team, Element_Count (Chunks), Share'Unchecked_Access,
                  Status,
                  Cost => Count * Element_Count (Used) * Feed * Width * 3);
            end if;

            Workers_CPU.Unpack (Packed_Super);
            Workers_CPU.Unpack (Packed_Plain);

            if E.Is_Error (Status) then
               return;
            end if;

            if not Share.Ok then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
         end;

         goto Summed;
      end if;

      --  And every expert once, with all the positions that chose it.
      for Which in 0 .. Many - 1 loop
         declare
            Members : Natural := 0;
         begin
            for Where in 0 .. Natural (Count) - 1 loop
               for Slot in 0 .. Used - 1 loop
                  if Item.Pick_Which.all (Where * Used + Slot) = Which then
                     Item.Gathered.all (Members) := Where * Used + Slot;
                     Members := Members + 1;
                  end if;
               end loop;
            end loop;

            if Members = 0 then
               goto Next_Expert;
            end if;

            declare
               Expert_At : Expert renames Current.Experts.all (Which);

               Held : constant Element_Count := Element_Count (Members);
            begin
               --  Gathered: the chosen positions' vectors, end to end.
               for Index in 0 .. Members - 1 loop
                  declare
                     Where : constant Element_Count :=
                       Element_Count (Item.Gathered.all (Index) / Used);

                     From : constant Element_Count :=
                       Rows.all'First + Where * Width;

                     Into : constant Element_Count :=
                       Item.Gather_In.all'First
                       + Element_Count (Index) * Width;
                  begin
                     Item.Gather_In.all (Into .. Into + Width - 1) :=
                       Rows.all (From .. From + Width - 1);
                  end;
               end loop;

               --  The whole of this expert as one submission, where the
               --  device holds the stacks and the architecture puts
               --  nothing between the products that the device cannot:
               --  the gate through the same kernel a token's gathered
               --  mixture puts it through, which is what keeps a prompt
               --  and a token agreeing to the bit.
               if Item.Owner.all.Stacked
                 and then (Current.Expert_Gate_Bias = null)
                          = (Current.Expert_Up_Bias = null)
                 and then Model_Runner.Backend."="
                            (Item.Owner.Able.Kind,
                             Model_Runner.Backend.Backend_Device)
                 and then T.Is_Present (Current.Gate_Stack)
                 and then T.Is_Present (Current.Up_Stack)
                 and then T.Is_Present (Current.Down_Stack)
               then
                  if Item.Seen /= null then
                     declare
                        Room : constant Element_Count := Held * Width;
                        Gate_Name : constant String :=
                          Named_As (Item.Owner.all, Expert_At.Gate);
                        Up_Name   : constant String :=
                          Named_As (Item.Owner.all, Expert_At.Up);
                     begin
                        if Gate_Name /= "" then
                           Item.Seen.Note
                             (Gate_Name,
                              Item.Gather_In.all
                                (Item.Gather_In.all'First
                                 .. Item.Gather_In.all'First + Room - 1),
                              Held);
                        end if;

                        if Up_Name /= "" then
                           Item.Seen.Note
                             (Up_Name,
                              Item.Gather_In.all
                                (Item.Gather_In.all'First
                                 .. Item.Gather_In.all'First + Room - 1),
                              Held);
                        end if;
                     end;
                  end if;

                  Model_Runner.Backend.Device.Dispatch_Expert
                    (Current.Gate_Stack, Current.Up_Stack,
                     Current.Down_Stack, Feed, Width, Which,
                     Gate_Unit (Item.Owner.all), Item.Gather_In, Held,
                     Item.Gather_Out, Status, Item.Stopping,
                        Alpha => Item.Owner.all.Settings.Gate_Alpha,
                        Limit => Item.Owner.all.Settings.Gate_Limit,
                        Gate_Bias => Current.Expert_Gate_Bias,
                        Up_Bias   => Current.Expert_Up_Bias,
                        Down_Bias => Current.Expert_Down_Bias);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  goto Scatter;
               end if;

               Product_Slice
                 (Item, Expert_At.Gate, Current.Gate_Stack, Feed, Which,
                  Item.Gather_In, Held, Item.Gather_A, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Product_Slice
                 (Item, Expert_At.Up, Current.Up_Stack, Feed, Which,
                  Item.Gather_In, Held, Item.Gather_B, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               --  The biases and the gate, a member at a time on its own
               --  stretch, which is what one position's mixture does to one.
               for Index in 0 .. Members - 1 loop
                  declare
                     At_Arm : constant Element_Count :=
                       Element_Count (Index) * Feed;

                     Gate_Part : T.Real_Array renames
                       Item.Gather_A.all
                         (Item.Gather_A.all'First + At_Arm
                          .. Item.Gather_A.all'First + At_Arm + Feed - 1);

                     Up_Part : T.Real_Array renames
                       Item.Gather_B.all
                         (Item.Gather_B.all'First + At_Arm
                          .. Item.Gather_B.all'First + At_Arm + Feed - 1);

                     At_Feed : constant Element_Count :=
                       Element_Count (Which) * Feed;
                  begin
                     if Current.Expert_Gate_Bias /= null then
                        K.Add
                          (Gate_Part,
                           Current.Expert_Gate_Bias.all
                             (Current.Expert_Gate_Bias.all'First + At_Feed
                              .. Current.Expert_Gate_Bias.all'First + At_Feed
                                 + Feed - 1));
                        K.Add
                          (Up_Part,
                           Current.Expert_Up_Bias.all
                             (Current.Expert_Up_Bias.all'First + At_Feed
                              .. Current.Expert_Up_Bias.all'First + At_Feed
                                 + Feed - 1));
                     end if;

                     if Settings.Gate_Alpha > 0.0 then
                        K.Clamped_Gate
                          (Gate_Part, Up_Part,
                           Settings.Gate_Alpha, Settings.Gate_Limit);
                     else
                        Gate_Activation (Item.Owner.all, Gate_Part);
                        K.Multiply (Gate_Part, Up_Part);
                     end if;
                  end;
               end loop;

               Product_Slice
                 (Item, Expert_At.Down, Current.Down_Stack, Width, Which,
                  Item.Gather_A, Held, Item.Gather_Out, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               <<Scatter>>

               --  Scattered back, each to the place its position and its
               --  rank name, so the sums below are in the order they were.
               for Index in 0 .. Members - 1 loop
                  declare
                     Pick : constant Natural := Item.Gathered.all (Index);

                     From : constant Element_Count :=
                       Item.Gather_Out.all'First
                       + Element_Count (Index) * Width;

                     Into : constant Element_Count :=
                       Item.Ranked.all'First + Element_Count (Pick) * Width;

                     Mine : T.Real_Array renames
                       Item.Ranked.all (Into .. Into + Width - 1);

                     At_Wide : constant Element_Count :=
                       Element_Count (Which) * Width;
                  begin
                     Mine := Item.Gather_Out.all (From .. From + Width - 1);

                     if Current.Expert_Down_Bias /= null then
                        K.Add
                          (Mine,
                           Current.Expert_Down_Bias.all
                             (Current.Expert_Down_Bias.all'First + At_Wide
                              .. Current.Expert_Down_Bias.all'First + At_Wide
                                 + Width - 1));
                     end if;
                  end;
               end loop;
            end;

            <<Next_Expert>>
            null;
         end;
      end loop;

      <<Summed>>

      --  And the sums, a position at a time and best expert first, which is
      --  the order one position's mixture adds them in and the reason the
      --  answers were kept apart rather than accumulated as they came.
      for Where in 0 .. Count - 1 loop
         declare
            At_Row : constant Element_Count := Rows.all'First + Where * Width;

            Into : T.Real_Array renames
              Rows.all (At_Row .. At_Row + Width - 1);
         begin
            Into := [others => 0.0];

            for Slot in 0 .. Used - 1 loop
               declare
                  Pick : constant Element_Count :=
                    Where * Element_Count (Used) + Element_Count (Slot);

                  From : constant Element_Count :=
                    Item.Ranked.all'First + Pick * Width;

                  Mine : T.Real_Array renames
                    Item.Ranked.all (From .. From + Width - 1);
               begin
                  K.Scale
                    (Mine,
                     Item.Pick_Share.all (Item.Pick_Share.all'First + Pick));
                  K.Add (Into, Mine);
               end;
            end loop;

            --  And the shared expert's answer for this row, at its gate.
            if T.Is_Present (Current.Shared_Gate) then
               declare
                  Scale : constant Real :=
                    Item.Shared_Rows_Out.all (Wide + Where);
               begin
                  for C in 0 .. Width - 1 loop
                     Into (Into'First + C) :=
                       Into (Into'First + C)
                       + Scale * Item.Shared_Rows_Out.all (Where * Width + C);
                  end loop;
               end;
            end if;
         end;
      end loop;

      Ok := True;
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

            --  The attention biases, which nothing released: a qwen2 model
            --  held three vectors a layer past its own closing, and only
            --  that architecture has them, which is why closing a llama
            --  model looked clean.
            T.Free (Which.Query_Norm);
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
            T.Free (Which.Out_Bias);
            T.Free (Which.Up_Bias);
            T.Free (Which.Down_Bias);

            --  The linear layer's, the shared expert's and the next
            --  block's, null for a layer without them.
            T.Free (Which.A_Log);
            T.Free (Which.DT_Bias);
            T.Free (Which.Conv);
            T.Free (Which.State_Norm);
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
      B.Free (Item.Repacked);
      Item.Embeddings := T.Empty_View;
      Item.Output := T.Empty_View;
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
   procedure Make_Room
     (Item     : in out Session;
      Settings : Configuration;
      Upto     : Element_Count);

   procedure Make_Room
     (Item     : in out Session;
      Settings : Configuration;
      Upto     : Element_Count)
   is
      KV_Width : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Head_Size);
      V_Width  : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Value_Size);
      Width    : constant Element_Count :=
        Element_Count (Settings.Window);
   begin
      if Item.Cells = null or else Settings.Window = 0 then
         return;
      end if;

      --  What the device wrote and the host has not read back, before any
      --  of it is moved. Asked only when something is about to slide, so
      --  the lazy settle this backend was built around still holds for
      --  every call that does not: a layer slides about once every batch
      --  of positions.
      if Item.Owed_Count > 0 then
         declare
            Sliding : Boolean := False;
         begin
            for Layer in Item.Cells.all'Range loop
               Sliding := Sliding
                 or else Upto - Item.Origin.all (Layer)
                         >= Item.Cells.all (Layer);
            end loop;

            if Sliding then
               declare
                  Settled : Boolean;
               begin
                  Settle_Cache (Item, Settled);
               end;
            end if;
         end;
      end if;

      for Layer in Item.Cells.all'Range loop
         declare
            Cells  : constant Element_Count := Item.Cells.all (Layer);
            Origin : constant Element_Count := Item.Origin.all (Layer);
         begin
            if Upto - Origin >= Cells then
               declare
                  --  The lowest position anything will read from here on,
                  --  which is the window measured back from the first of
                  --  the positions about to be written.
                  Held  : constant Element_Count :=
                    Element_Count (Item.Committed);
                  Start : constant Element_Count :=
                    (if Held < Width then 0 else Held - Width + 1);
                  Moved : constant Element_Count :=
                    (if Start >= Held then 0 else Held - Start);

                  Keys_Base : constant Element_Count := Keys_At (Item, Layer);
                  Vals_Base : constant Element_Count :=
                    Values_At (Item, Layer);
                  Rows_Base : constant Element_Count := Rows_At (Item, Layer);

                  From : constant Element_Count := Start - Origin;
               begin
                  if Moved > 0 then
                     case Item.Held is
                        when Exact =>
                           Item.Keys.all
                             (Keys_Base .. Keys_Base + Moved * KV_Width - 1) :=
                             Item.Keys.all
                               (Keys_Base + From * KV_Width
                                .. Keys_Base + (From + Moved) * KV_Width - 1);
                           Item.Values.all
                             (Vals_Base .. Vals_Base + Moved * V_Width - 1) :=
                             Item.Values.all
                               (Vals_Base + From * V_Width
                                .. Vals_Base + (From + Moved) * V_Width - 1);

                        when Halved =>
                           Item.Half_Keys.all
                             (Keys_Base .. Keys_Base + Moved * KV_Width - 1) :=
                             Item.Half_Keys.all
                               (Keys_Base + From * KV_Width
                                .. Keys_Base + (From + Moved) * KV_Width - 1);
                           Item.Half_Values.all
                             (Vals_Base .. Vals_Base + Moved * V_Width - 1) :=
                             Item.Half_Values.all
                               (Vals_Base + From * V_Width
                                .. Vals_Base + (From + Moved) * V_Width - 1);

                        when Eighth | Fourth =>
                           --  Whole rows move, so the bytes and the
                           --  scales move by a row's worth of each.
                           declare
                              KB : constant B.Byte_Count :=
                                Row_Bytes (Item.Held, KV_Width);
                              VB : constant B.Byte_Count :=
                                Row_Bytes (Item.Held_Values, V_Width);
                              KS : constant Element_Count :=
                                Blocks_Of (Item.Held, KV_Width);
                              VS : constant Element_Count :=
                                Blocks_Of (Item.Held_Values, V_Width);
                              Row_0 : constant Element_Count :=
                                Keys_Base / KV_Width;
                              V_Row_0 : constant Element_Count :=
                                Vals_Base / V_Width;
                           begin
                              Item.Byte_Keys.all
                                (B.Byte_Count (Row_0) * KB
                                 .. B.Byte_Count (Row_0 + Moved) * KB - 1) :=
                                Item.Byte_Keys.all
                                  (B.Byte_Count (Row_0 + From) * KB
                                   .. B.Byte_Count (Row_0 + From + Moved) * KB
                                      - 1);
                              Item.Byte_Values.all
                                (B.Byte_Count (V_Row_0) * VB
                                 .. B.Byte_Count (V_Row_0 + Moved) * VB - 1) :=
                                Item.Byte_Values.all
                                  (B.Byte_Count (V_Row_0 + From) * VB
                                   .. B.Byte_Count (V_Row_0 + From + Moved) * VB
                                      - 1);

                              Item.Key_Scales.all
                                (Rows_Base * KS .. (Rows_Base + Moved) * KS - 1) :=
                                Item.Key_Scales.all
                                  ((Rows_Base + From) * KS
                                   .. (Rows_Base + From + Moved) * KS - 1);
                              Item.Value_Scales.all
                                (Rows_Base * VS .. (Rows_Base + Moved) * VS - 1) :=
                                Item.Value_Scales.all
                                  ((Rows_Base + From) * VS
                                   .. (Rows_Base + From + Moved) * VS - 1);
                           end;
                     end case;
                  end if;

                  --  And the device's copy of what moved, which is these
                  --  same bytes in this session's own block. Only the
                  --  exact storage ever reaches a device, which is what
                  --  Take_Block asks of a session before it deals it one.
                  if Moved > 0
                    and then Item.Seat >= 0
                    and then Item.Held = Exact
                  then
                     declare
                        Sent : Boolean;
                     begin
                        Model_Runner.Backend.Device.Put_Cache
                          (Block_Base (Item) + Keys_Base,
                           Item.Keys.all
                             (Keys_Base
                              .. Keys_Base + Moved * KV_Width - 1),
                           Sent);
                        Model_Runner.Backend.Device.Put_Cache
                          (Block_Base (Item)
                           + Item.Keys.all'Length + Vals_Base,
                           Item.Values.all
                             (Vals_Base
                              .. Vals_Base + Moved * V_Width - 1),
                           Sent);
                     end;
                  elsif Moved > 0
                    and then Item.Seat >= 0
                    and then Item.Held in Eighth | Fourth
                  then
                     --  The packed rows that moved, a row at a time.
                     declare
                        Sent : Boolean;
                     begin
                        for Row in 0 .. Moved - 1 loop
                           Put_Packed_Position
                             (Item'Unchecked_Access,
                              Keys_Base + Row * KV_Width,
                              Vals_Base + Row * V_Width,
                              KV_Width, V_Width, Sent);
                        end loop;
                     end;
                  end if;

                  Item.Origin.all (Layer) := Start;
               end;
            end if;
         end;
      end loop;
   end Make_Room;

   procedure Snapshot
     (Item   : in out Session;
      Source : Model'Class;
      Into   : out B.Byte_Array_Access;
      Status : out E.Error_Info)
   is
      Settings : constant Configuration := Source.Settings;

      Held     : constant B.Byte_Count := B.Byte_Count (Item.Committed);
      KV_Width : constant B.Byte_Count :=
        B.Byte_Count (Settings.KV_Heads * Settings.Head_Size);
      V_Width  : constant B.Byte_Count :=
        B.Byte_Count (Settings.KV_Heads * Settings.Value_Size);
      Layers   : constant B.Byte_Count := B.Byte_Count (Settings.Layers);

      --  Where each layer's run begins, and how long it is. A layer that
      --  holds everything begins at zero and runs to what was committed,
      --  which is what every layer did before one of them slid.
      function Origin_Of (Layer : B.Byte_Count) return B.Byte_Count
      is (if Item.Origin = null then 0
          else B.Byte_Count (Item.Origin.all (Natural (Layer))));

      --  A linear layer holds no keys and values: nothing of it is a run.
      function Run_Of (Layer : B.Byte_Count) return B.Byte_Count
      is (if Linear (Settings, Natural (Layer)) or else Origin_Of (Layer) >= Held
          then 0 else Held - Origin_Of (Layer));

      --  And what it holds instead, written after every layer's values:
      --  every linear layer's convolution memory and state, as they are.
      States : constant B.Byte_Count :=
        (if Hybrid (Settings.Kind)
         then B.Byte_Count (Conv_Room (Settings))
              + B.Byte_Count (State_Room (Settings))
         else 0);

      function Runs return B.Byte_Count;

      function Runs return B.Byte_Count is
         Total : B.Byte_Count := 0;
      begin
         for Layer in 0 .. Layers - 1 loop
            Total := Total + Run_Of (Layer);
         end loop;
         return Total;
      end Runs;

      Spans : constant B.Byte_Count := Runs;

      --  And after everything, for a model whose positions have three
      --  parts, what each committed position turns by: four numbers of
      --  eight bytes a position. A reader that finds them missing --
      --  a snapshot from before they were written -- turns every
      --  position by its index, which is what a snapshot from then held.
      Marks : constant B.Byte_Count :=
        (if Item.Marks = null then 0 else Held * 4 * 8);

      --  Ten numbers of eight bytes, then a token each, then two numbers a
      --  layer saying where its run begins and how many positions the layer
      --  holds room for, then the two caches at four bytes an element
      --  whichever precision they are held in.
      Length : constant B.Byte_Count :=
        10 * 8 + Held * 8 + 2 * Layers * 8
        + Spans * KV_Width * 4
        + Spans * V_Width * 4
        + States * 4
        + Marks;

      At_Byte : B.Byte_Count := 0;

      procedure Put (Value : Interfaces.Unsigned_64) is
      begin
         Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 7) :=
           B.Put_U64 (Value);
         At_Byte := At_Byte + 8;
      end Put;

      procedure Put_Count (Value : Natural) is
      begin
         Put (Interfaces.Unsigned_64 (Value));
      end Put_Count;

      procedure Put_Bits (Bits : Interfaces.Unsigned_32) is
      begin
         Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 3) :=
           B.Put_U32 (Bits);
         At_Byte := At_Byte + 4;
      end Put_Bits;
   begin
      --  What the device wrote and the host was owed, which this
      --  reads: the copy is brought up to date where it is used
      --  rather than at the end of every call.
      declare
         Settled : Boolean;
      begin
         Settle_Cache (Item, Settled);
      end;

      Into := null;
      Status := E.Success;

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Owner = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      B.Allocate (Length, Into);
      if Into = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Put (Interfaces.Unsigned_64'(Session_Magic));
      Put_Count (Natural'(Session_Version));
      Put (Fingerprint (Source));
      Put_Count (Settings.Layers);
      Put_Count (Settings.KV_Heads);
      Put_Count (Settings.Head_Size);
      Put_Count (Settings.Value_Size);
      Put_Count (Item.Context);
      Put_Count (Item.Committed);
      --  The keys' storage, and the values' where it differs, in the
      --  word's eighths: a snapshot of a session storing both alike says
      --  what it always said.
      Put_Count (Cache_Precision'Pos (Item.Held)
                 + (if Item.Held_Values /= Item.Held
                    then 8 * Cache_Precision'Pos (Item.Held_Values) else 0));

      for Index in 0 .. Item.Committed - 1 loop
         Put_Count (Natural (Item.History.all (Index)));
      end loop;

      --  Where each layer's run begins, and the room it has. The second is
      --  what a reader compares against its own geometry: a session opened
      --  the same way cuts the cache the same way, and one that did not
      --  cannot be told where these positions belong.
      for Layer_Index in 0 .. Layers - 1 loop
         Put (Interfaces.Unsigned_64 (Origin_Of (Layer_Index)));
         Put (Interfaces.Unsigned_64
                (if Item.Cells = null then Element_Count (Item.Context)
                 else Item.Cells.all (Natural (Layer_Index))));
      end loop;

      --  One layer's run of positions at a time, from where that layer
      --  begins, and the layers are not adjacent.
      for Layer_Index in 0 .. Layers - 1 loop
         declare
            First : constant Element_Count :=
              Keys_At (Item, Natural (Layer_Index));
         begin
            for Index in 0 .. Element_Count (Run_Of (Layer_Index) * KV_Width)
                               - 1
            loop
               if Item.Held in Eighth | Fourth then
                  --  Written as the numbers it stands for rather than as
                  --  its bytes and scales: a saved context is read back by
                  --  a session that may hold a different precision, and
                  --  four bytes an element is what the format says.
                  Put_Bits
                    (N.Bits
                       (Unpack
                          (Item.Byte_Keys.all, First + Index,
                           Element_Count (KV_Width), Item.Key_Scales.all,
                           Item.Held)));
               elsif Item.Held = Exact then
                  Put_Bits (N.Bits (Item.Keys.all (First + Index)));
               else
                  Put_Bits
                    (Interfaces.Unsigned_32
                       (Item.Half_Keys.all (First + Index)));
               end if;
            end loop;
         end;
      end loop;

      for Layer_Index in 0 .. Layers - 1 loop
         declare
            First : constant Element_Count :=
              Values_At (Item, Natural (Layer_Index));
         begin
            for Index in 0 .. Element_Count (Run_Of (Layer_Index) * V_Width)
                               - 1
            loop
               --  The values as the keys above, and the packed caches
               --  unpacked as the keys were: the byte cache's values
               --  went through the halved arm here, which holds nothing
               --  for it, and a byte session could not snapshot at all.
               if Item.Held in Eighth | Fourth then
                  Put_Bits
                    (N.Bits
                       (Unpack
                          (Item.Byte_Values.all, First + Index,
                           Element_Count (V_Width), Item.Value_Scales.all,
                           Item.Held_Values)));
               elsif Item.Held = Exact then
                  Put_Bits (N.Bits (Item.Values.all (First + Index)));
               else
                  Put_Bits
                    (Interfaces.Unsigned_32
                       (Item.Half_Values.all (First + Index)));
               end if;
            end loop;
         end;
      end loop;

      --  The linear layers' memories and states as they are now: the
      --  slot the committed count reads, whole.
      if Item.Conv_State /= null then
         declare
            Slot : constant Element_Count := State_Slot (Item, Item.Committed);
            Every : constant Element_Count := Conv_Room (Source.Settings);
         begin
            for Value of Item.Conv_State.all
              (Slot * Every .. (Slot + 1) * Every - 1)
            loop
               Put_Bits (N.Bits (Value));
            end loop;
         end;
      end if;

      if Item.Delta_State /= null then
         declare
            Slot : constant Element_Count := State_Slot (Item, Item.Committed);
            Every : constant Element_Count := State_Room (Source.Settings);
         begin
            for Value of Item.Delta_State.all
              (Slot * Every .. (Slot + 1) * Every - 1)
            loop
               Put_Bits (N.Bits (Value));
            end loop;
         end;
      end if;

      if Item.Marks /= null then
         for Index in 0 .. Item.Committed - 1 loop
            declare
               Mark : constant Rope_Mark := Item.Marks.all (Index);
            begin
               Put_Count (Mark.Place.T);
               Put_Count (Mark.Place.H);
               Put_Count (Mark.Place.W);
               Put_Count (Mark.Next);
            end;
         end loop;
      end if;
   end Snapshot;

   -----------
   -- Adopt --
   -----------

   procedure Adopt
     (Item   : in out Session;
      Source : Model'Class;
      From   : B.Byte_Array;
      Status : out E.Error_Info)
   is
      use type Interfaces.Unsigned_32;

      Settings : constant Configuration := Source.Settings;

      KV_Width : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Head_Size);
      V_Width  : constant Element_Count :=
        Element_Count (Settings.KV_Heads * Settings.Value_Size);

      At_Byte : B.Byte_Count := 0;
      Trouble : Boolean := False;

      procedure Refuse (Code : E.Error_Code; What : String) is
      begin
         if not Trouble then
            Trouble := True;
            Status := E.Make (Code);
            E.Add_Text (Status, "construct", What, E.Param_Text);
         end if;
      end Refuse;

      function Get return Interfaces.Unsigned_64 is
         Ok : Boolean;
         Value : Interfaces.Unsigned_64;
      begin
         if Trouble then
            return 0;
         end if;

         Value := B.Get_U64 (From, At_Byte, Ok);
         if not Ok then
            Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
            return 0;
         end if;

         At_Byte := At_Byte + 8;
         return Value;
      end Get;

      function Get_Bits return Interfaces.Unsigned_32 is
         Ok : Boolean;
         Value : Interfaces.Unsigned_32;
      begin
         if Trouble then
            return 0;
         end if;

         Value := B.Get_U32 (From, At_Byte, Ok);
         if not Ok then
            Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
            return 0;
         end if;

         At_Byte := At_Byte + 4;
         return Value;
      end Get_Bits;

      --  One run of the cache, into whichever storage the session holds.
      --  One run of the cache, into whichever storage the session holds. A
      --  byte cache is filled a row at a time rather than an element at a
      --  time, because the scale a row is written with is the largest
      --  magnitude in it and there is no such thing until the row is whole.
      procedure Get_Run
        (Keys : Boolean; First : Element_Count; Count : Element_Count)
      is
         Width : constant Element_Count :=
           (if Keys then KV_Width else V_Width);
      begin
         for Index in 0 .. Count - 1 loop
            declare
               Bits : constant Interfaces.Unsigned_32 := Get_Bits;
            begin
               exit when Trouble;

               if Item.Held = Exact then
                  declare
                     Value : constant Real := N.From_Bits (Bits);
                  begin
                     --  A cache of not-a-number would poison every later
                     --  position, and these bytes are untrusted.
                     if not N.Is_Finite (Value) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Keys.all (First + Index) := Value;
                     else
                        Item.Values.all (First + Index) := Value;
                     end if;
                  end;
               elsif Item.Held in Eighth | Fourth then
                  declare
                     Value : constant Real := N.From_Bits (Bits);
                  begin
                     if not N.Is_Finite (Value) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Key_Row.all (Index mod Width) := Value;
                     else
                        Item.Value_Row.all (Index mod Width) := Value;
                     end if;

                     if Index mod Width = Width - 1 then
                        if Keys then
                           Pack_Row
                             (Item.Key_Row.all (0 .. Width - 1),
                              Item.Byte_Keys.all, First + Index - Width + 1,
                              Width, Item.Key_Scales.all, Item.Held);
                        else
                           Pack_Row
                             (Item.Value_Row.all (0 .. Width - 1),
                              Item.Byte_Values.all, First + Index - Width + 1,
                              Width, Item.Value_Scales.all, Item.Held_Values);
                        end if;
                     end if;
                  end;
               else
                  declare
                     Value : constant N.Half :=
                       N.Half (Bits and 16#FFFF#);
                  begin
                     if not N.Is_Finite (N.To_Real (Value)) then
                        Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                        exit;
                     end if;

                     if Keys then
                        Item.Half_Keys.all (First + Index) := Value;
                     else
                        Item.Half_Values.all (First + Index) := Value;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Get_Run;

      Held : Element_Count := 0;
   begin
      --  What the host is about to be given is the copy of record,
      --  so whatever the device was owed for is no longer owed: the
      --  positions it wrote are the ones being replaced.
      Item.Owed_Count := 0;

      Status := E.Success;

      if Item.Current not in Ready | Evaluating_Prompt | Generating
        or else Item.Owner = null
      then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      --  Nothing of what was there survives, whether or not this succeeds.
      Reset (Item);

      declare
         Magic   : constant Interfaces.Unsigned_64 := Get;
         Version : constant Interfaces.Unsigned_64 := Get;
         Mark    : constant Interfaces.Unsigned_64 := Get;
         Layers  : constant Interfaces.Unsigned_64 := Get;
         KV      : constant Interfaces.Unsigned_64 := Get;
         Wide    : constant Interfaces.Unsigned_64 := Get;
         Deep    : constant Interfaces.Unsigned_64 := Get;
         Room    : constant Interfaces.Unsigned_64 := Get;
         Filled  : constant Interfaces.Unsigned_64 := Get;
         Packed  : constant Interfaces.Unsigned_64 := Get;
      begin
         if not Trouble and then Magic /= Session_Magic then
            Refuse (E.Lifecycle_Cache_Unreadable, "not a saved session");
         end if;

         if not Trouble and then Version /= Session_Version then
            Refuse (E.Lifecycle_Cache_Unreadable, "another version");
         end if;

         if not Trouble and then Mark /= Fingerprint (Source) then
            Refuse (E.Lifecycle_Cache_Mismatched, "another model");
         end if;

         if not Trouble
           and then (Layers /= Interfaces.Unsigned_64 (Settings.Layers)
                     or else KV /= Interfaces.Unsigned_64 (Settings.KV_Heads)
                     or else Wide
                             /= Interfaces.Unsigned_64 (Settings.Head_Size)
                     or else Deep
                             /= Interfaces.Unsigned_64 (Settings.Value_Size))
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another shape");
         end if;

         if not Trouble
           and then Room /= Interfaces.Unsigned_64 (Item.Context)
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another context");
         end if;

         if not Trouble
           and then Packed
                    /= Interfaces.Unsigned_64
                         (Cache_Precision'Pos (Item.Held)
                          + (if Item.Held_Values /= Item.Held
                             then 8 * Cache_Precision'Pos (Item.Held_Values)
                             else 0))
         then
            Refuse (E.Lifecycle_Cache_Mismatched, "another precision");
         end if;

         if not Trouble
           and then Filled > Interfaces.Unsigned_64 (Item.Context)
         then
            Refuse (E.Lifecycle_Cache_Unreadable, "more than the context");
         end if;

         if not Trouble then
            Held := Element_Count (Filled);
         end if;
      end;

      if not Trouble then
         for Index in 0 .. Natural (Held) - 1 loop
            declare
               Value : constant Interfaces.Unsigned_64 := Get;
            begin
               exit when Trouble;

               if Value >= Interfaces.Unsigned_64 (Settings.Vocabulary) then
                  Refuse (E.Lifecycle_Cache_Unreadable, "token out of range");
                  exit;
               end if;

               Item.History.all (Index) :=
                 Model_Runner.Tokenizer.Token_Id (Value);
            end;
         end loop;
      end if;

      --  Where each layer's run begins, and the room the writer had. A
      --  session opened the same way cuts the cache the same way; one that
      --  did not cannot be told where these positions belong, and is
      --  refused rather than filled with them.
      if not Trouble then
         for Layer_Index in 0 .. Settings.Layers - 1 loop
            declare
               Begins : constant Interfaces.Unsigned_64 := Get;
               Room   : constant Interfaces.Unsigned_64 := Get;
            begin
               exit when Trouble;

               if Item.Cells = null
                 or else Room
                         /= Interfaces.Unsigned_64 (Item.Cells.all (Layer_Index))
               then
                  Refuse (E.Lifecycle_Cache_Mismatched, "another window");
                  exit;
               end if;

               if Begins > Interfaces.Unsigned_64 (Held) then
                  Refuse (E.Lifecycle_Cache_Unreadable, "a run past the end");
                  exit;
               end if;

               Item.Origin.all (Layer_Index) := Element_Count (Begins);
            end;
         end loop;
      end if;

      if not Trouble then
         for Layer_Index in 0 .. Settings.Layers - 1 loop
            Get_Run
              (True, Keys_At (Item, Layer_Index),
               (if Linear (Settings, Layer_Index) then 0
                else (Held - Item.Origin.all (Layer_Index)) * KV_Width));
            exit when Trouble;
         end loop;
      end if;

      if not Trouble then
         for Layer_Index in 0 .. Settings.Layers - 1 loop
            Get_Run
              (False, Values_At (Item, Layer_Index),
               (if Linear (Settings, Layer_Index) then 0
                else (Held - Item.Origin.all (Layer_Index)) * V_Width));
            exit when Trouble;
         end loop;
      end if;

      --  And the linear layers' memories and states, whole, where the
      --  session has them; a snapshot without them is one of another
      --  model's shape and was refused above by its fingerprint.
      --  Into the slot the committed count will read, which is the
      --  newest the ring holds and the only one: what was before it
      --  belongs to a session that is not this one.
      if not Trouble and then Item.Conv_State /= null then
         Fetch_States (Item'Unchecked_Access);
      end if;

      if not Trouble and then Item.Conv_State /= null then
         declare
            Slot : constant Element_Count :=
              State_Slot (Item, Natural (Held));
            Every : constant Element_Count := Conv_Room (Source.Settings);
         begin
            for Value of Item.Conv_State.all
              (Slot * Every .. (Slot + 1) * Every - 1)
            loop
               declare
                  Bits : constant Interfaces.Unsigned_32 := Get_Bits;
               begin
                  exit when Trouble;
                  Value := N.From_Bits (Bits);
               end;
            end loop;
         end;
      end if;
      if not Trouble and then Item.Delta_State /= null then
         declare
            Slot : constant Element_Count :=
              State_Slot (Item, Natural (Held));
            Every : constant Element_Count := State_Room (Source.Settings);
         begin
            for Value of Item.Delta_State.all
              (Slot * Every .. (Slot + 1) * Every - 1)
            loop
               declare
                  Bits : constant Interfaces.Unsigned_32 := Get_Bits;
               begin
                  exit when Trouble;
                  Value := N.From_Bits (Bits);
               end;
            end loop;
         end;
      end if;
      Item.Kept_Newest := Natural (Held);

      --  What was adopted is the host's, whatever the device held.
      Item.State_On_Device := False;

      --  What each position turns by, where the model has three parts
      --  and the snapshot carries them; a snapshot from before they were
      --  written leaves every position at its index, which is what it
      --  held. A mark past the context is a corrupt one.
      if not Trouble and then Item.Marks /= null then
         Item.Marked := 0;
         if From'Length >= At_Byte + B.Byte_Count (Held) * 4 * 8 then
            for Index in 0 .. Natural (Held) - 1 loop
               declare
                  T : constant Interfaces.Unsigned_64 := Get;
                  H : constant Interfaces.Unsigned_64 := Get;
                  W : constant Interfaces.Unsigned_64 := Get;
                  Next : constant Interfaces.Unsigned_64 := Get;
                  Bound : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Item.Context) * 4;
               begin
                  exit when Trouble;
                  if T > Bound or else H > Bound or else W > Bound
                    or else Next > Bound
                  then
                     Refuse (E.Lifecycle_Cache_Unreadable, "a mark past the context");
                     exit;
                  end if;
                  Item.Marks.all (Index) :=
                    (Place => (T => Natural (T), H => Natural (H), W => Natural (W)),
                     Next => Natural (Next));
               end;
            end loop;
            if not Trouble then
               Item.Marked := Natural (Held);
            end if;
         end if;
      end if;

      if Trouble then
         --  Nothing half read is left where a conversation would be.
         Reset (Item);
         return;
      end if;

      Item.Committed := Natural (Held);
   end Adopt;

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

      --  What the session holds, counting the cache twice on a device:
      --  the device keeps its own copy of the cache beside the host's,
      --  and the host's memory is what both come out of on an integrated
      --  part.
      declare
         Needed : constant Interfaces.Unsigned_64 :=
           Item.Plan.Total_Resident
           + (if Model_Runner.Backend."="
                   (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
              then Item.Plan.KV_Cache_Bytes else 0);
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
         --  and the room has to hold one whole. Not more: what a slide
         --  costs is a window of rows moved every margin positions, which
         --  is a window over a batch of rows for every position written --
         --  eight of them on gemma2, against the six hundred megabytes of
         --  weights that position reads. What a larger margin would buy is
         --  fewer slides and a bigger cache, which is the trade this
         --  section exists to refuse.
         Margin : constant Element_Count := Element_Count (Max_Batch);

         Windowed : constant Boolean := Settings.Window > 0;
      begin
         --  One entry a layer of the stack, and one more for each block
         --  past it, which attends in full over the same context and
         --  keeps its keys and values here like a layer of the stack.
         --  New to the device, and warmer for it than anything asked
         --  before it was opened: a session opened where every block of
         --  the cache and every seat in the room of rings is held takes
         --  one that has gone cold, and takes none where they are all as
         --  warm as it is.
         Block_Clock := Block_Clock + 1;
         Item.Asked_At := Block_Clock;
         Item.Asked_Before := Block_Clock;
         Item.State_Asked_At := Block_Clock;
         Item.State_Asked_Before := Block_Clock;

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
         --  and Paged stays false.
         if Paged
           and then Model_Runner.Backend."="
                      (Source.Able.Kind,
                       Model_Runner.Backend.Backend_Device)
           and then Cache in Exact | Eighth | Fourth
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
         if Source.Settings.Kind in Gemma2 | Gemma3 | Falcon | Phi2
           or else Normalizes_After (Source.Settings.Kind)
         then
            T.Allocate (Width, Item.Post_Room);
         end if;

         if (for some L of Source.Layers.all =>
               L.Second_Attention_Norm /= null)
         then
            T.Allocate (Width, Item.Kept_Input);
         end if;

         T.Allocate (Wide, Item.Query);
         T.Allocate (KV, Item.Key_Row);
         T.Allocate (KV_Out, Item.Value_Row);
         T.Allocate (Blend, Item.Attention);
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

         --  An architecture that normalizes its heads needs room for one.
         if Settings.Head_Size > 0
           and then Source.Layers /= null
           and then (for some L of Source.Layers.all => L.Query_Norm /= null)
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
      Item.Context := Capacity;
      Item.Committed := 0;
      Item.Current := Ready;
      Source.Sessions := Source.Sessions + 1;
   exception
      when others =>
         Close (Item);
         Status := E.Make (E.Memory_Allocation_Failed);
   end Open;

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
      T.Free (Item.Scores);
      T.Free (Item.Gate);
      T.Free (Item.Up);
      T.Free (Item.Head_Row);
      T.Free (Item.Query_Full);
      T.Free (Item.Last_Final);
      T.Free (Item.Next_Input);
      T.Free (Item.Head_Gate);
      T.Free (Item.Mix_Row);
      T.Free (Item.Z_Row);
      T.Free (Item.Alpha_Row);
      T.Free (Item.Beta_Row);
      T.Free (Item.Blend_Row);
      T.Free (Item.Shared_Row);
      T.Free (Item.Shared_Up_Row);
      T.Free (Item.Shared_Out_Row);
      T.Free (Item.Shared_Rows_A);
      T.Free (Item.Shared_Rows_B);
      T.Free (Item.Shared_Rows_Out);
      Release_State_Room (Item'Unchecked_Access);
      T.Free (Item.Conv_State);
      T.Free (Item.Delta_State);
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
   is
      Settings : constant Configuration := Source.Settings;

      Head_Size : constant Element_Count :=
        Element_Count (Settings.Head_Size);
      KV_Heads  : constant Element_Count :=
        Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;
      V_Width   : constant Element_Count :=
        KV_Heads * Element_Count (Settings.Value_Size);

      Moved : Natural;
   begin
      --  What the device wrote and the host was owed, which this
      --  reads: the copy is brought up to date where it is used
      --  rather than at the end of every call.
      declare
         Settled : Boolean;
      begin
         Settle_Cache (Item, Settled);
      end;

      Status := E.Success;

      --  A hybrid's linear layers hold no positions to move: their state
      --  is everything before it at once, and a context with the middle
      --  taken out is a context they never saw. Refused by name, and the
      --  caller re-evaluates what it keeps.
      if Hybrid (Settings.Kind) then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "shift", E.Param_Identifier);
         return;
      end if;

      if Item.Current = Closed or else Item.Current = Failed then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text
           (Status, "state",
            Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
            E.Param_Identifier);
         return;
      end if;

      if Keep + Drop > Item.Committed then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "input", Long_Long_Integer (Keep + Drop));
         E.Add_Integer
           (Status, "expected", Long_Long_Integer (Item.Committed));
         return;
      end if;

      Moved := Item.Committed - Keep - Drop;

      --  Every layer, every moved position: the key turned back by the angle
      --  Drop stands for and written where it now belongs, the value copied.
      --
      --  A LAYER THAT SLIDES A WINDOW DOES NOT HOLD WHAT THIS PROMISES TO
      --  KEEP. The first Keep positions are the ones a caller must not lose
      --  and they are the first ones a window drops, so on a slid layer the
      --  front of the cache is not there to be kept and the arithmetic that
      --  assumed it was went below zero -- this raised rather than shifted,
      --  on every architecture that slides, for any context long enough to
      --  have slid. Which is the whole of what the window was built for.
      --
      --  What a shift means to such a layer is only a renumbering. It holds
      --  the newest positions and those are exactly the ones that survive,
      --  so each key is turned back by the angle Drop stands for and stays
      --  in the cell it is in; what moves is the layer's origin, by Drop.
      --  The rows move only where a layer straddles the hole -- where its
      --  origin falls inside the dropped range -- and then only far enough
      --  to close it.
      for Index in Item.Owner.Layers'Range loop
         declare
            Layer : constant Natural := Natural (Index);

            --  The lowest position this layer still holds, before and
            --  after. Zero and zero for a layer that holds everything,
            --  which is what this was before a window slid.
            Low : constant Element_Count :=
              (if Item.Origin = null then 0 else Item.Origin.all (Layer));

            Settled : constant Element_Count :=
              (if Low <= Element_Count (Keep) then Low
               elsif Low >= Element_Count (Keep + Drop)
               then Low - Element_Count (Drop)
               else Element_Count (Keep));

            Base : constant Element_Count :=
              Keys_At (Item, Layer);
            V_Base : constant Element_Count :=
              Values_At (Item, Layer);
            Rows_Base : constant Element_Count :=
              Rows_At (Item, Layer);
         begin
            for Step in 0 .. Moved - 1 loop
               declare
                  --  What the position was and what it becomes.
                  Held_At : constant Element_Count :=
                    Element_Count (Keep + Drop + Step);
                  Ends_At : constant Element_Count :=
                    Element_Count (Keep + Step);

                  --  Where the two sit in this layer, which is not the
                  --  positions themselves for a layer that slides a window
                  --  -- and for one that has slid past this position, is
                  --  nowhere at all.
                  Absent : constant Boolean := Held_At < Low;

                  Was : constant Element_Count :=
                    (if Absent then 0 else Held_At - Low);
                  Now : constant Element_Count :=
                    (if Absent then 0 else Ends_At - Settled);

                  From : constant Element_Count := Base + Was * KV_Width;
                  Into : constant Element_Count := Base + Now * KV_Width;

                  V_From : constant Element_Count := V_Base + Was * V_Width;
                  V_Into : constant Element_Count := V_Base + Now * V_Width;
               begin
                  if not Absent then
                     if Item.Held in Eighth | Fourth then
                        for Offset in 0 .. KV_Width - 1 loop
                           Item.Key_Row.all (Offset) :=
                             Unpack (Item.Byte_Keys.all, From + Offset,
                                     KV_Width, Item.Key_Scales.all, Item.Held);
                        end loop;
                     elsif Item.Held = Exact then
                        Item.Key_Row.all (0 .. KV_Width - 1) :=
                          Item.Keys.all (From .. From + KV_Width - 1);
                     else
                        for Offset in 0 .. KV_Width - 1 loop
                           Item.Key_Row.all (Offset) :=
                             N.To_Real (Item.Half_Keys.all (From + Offset));
                        end loop;
                     end if;

                     K.Apply_Rotary
                       (Item.Key_Row.all, KV_Heads, Head_Size,
                        Element_Count (Settings.Rotary), Drop,
                        Turn_Base (Settings, Natural (Index)),
                        Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                        Settings.Pairing, Backwards => True);

                     if Item.Held in Eighth | Fourth then
                        --  Turned back and written again, which is a second
                        --  rounding of a row that was already rounded once.
                        --  A rolling context in this storage loses a little
                        --  more of what it keeps every time it rolls, and that
                        --  is the price of the storage rather than a fault in
                        --  the shift.
                        Pack_Row
                          (Item.Key_Row.all (0 .. KV_Width - 1),
                           Item.Byte_Keys.all, Into, KV_Width,
                           Item.Key_Scales.all, Item.Held);

                        --  The values move whole, bytes and scales.
                        declare
                           VB : constant B.Byte_Count :=
                             Row_Bytes (Item.Held_Values, V_Width);
                           VS : constant Element_Count :=
                             Blocks_Of (Item.Held_Values, V_Width);
                           From_Byte : constant B.Byte_Count :=
                             Byte_Of (Item.Held_Values, V_From, V_Width);
                           Into_Byte : constant B.Byte_Count :=
                             Byte_Of (Item.Held_Values, V_Into, V_Width);
                        begin
                           Item.Byte_Values.all (Into_Byte .. Into_Byte + VB - 1) :=
                             Item.Byte_Values.all (From_Byte .. From_Byte + VB - 1);
                           Item.Value_Scales.all
                             ((Rows_Base + Now) * VS .. (Rows_Base + Now + 1) * VS - 1) :=
                             Item.Value_Scales.all
                               ((Rows_Base + Was) * VS .. (Rows_Base + Was + 1) * VS - 1);
                        end;
                     elsif Item.Held = Exact then
                        Item.Keys.all (Into .. Into + KV_Width - 1) :=
                          Item.Key_Row.all (0 .. KV_Width - 1);
                        Item.Values.all (V_Into .. V_Into + V_Width - 1) :=
                          Item.Values.all (V_From .. V_From + V_Width - 1);
                     else
                        for Offset in 0 .. KV_Width - 1 loop
                           Item.Half_Keys.all (Into + Offset) :=
                             N.To_Half (Item.Key_Row.all (Offset));
                        end loop;
                        for Offset in 0 .. V_Width - 1 loop
                           Item.Half_Values.all (V_Into + Offset) :=
                             Item.Half_Values.all (V_From + Offset);
                        end loop;
                     end if;
                  end if;
               end;
            end loop;

            if Item.Origin /= null then
               Item.Origin.all (Layer) := Settled;
            end if;
         end;
      end loop;

      --  And the device's copy, which every edit above has just made stale.
      --
      --  It always had been. A block is filled once when it is granted and
      --  kept up to date a position at a time as positions are written, so
      --  nothing carried a shift's edits across -- a rolling context on the
      --  device attended to the conversation it had before the roll, with
      --  no error and no sign. A shift happens once a context, so the whole
      --  cache goes over rather than the rows that moved.
      if Item.Seat >= 0 and then Item.Held = Exact then
         declare
            Sent : Boolean;
         begin
            Model_Runner.Backend.Device.Put_Cache
              (Block_Base (Item), Item.Keys.all, Sent);

            if Sent then
               Model_Runner.Backend.Device.Put_Cache
                 (Block_Base (Item) + Item.Keys.all'Length,
                  Item.Values.all, Sent);
            end if;
         end;
      end if;

      --  And the history, which is what a restored context is checked
      --  against and what a prefix comparison reads.
      for Step in 0 .. Moved - 1 loop
         Item.History.all (Keep + Step) :=
           Item.History.all (Keep + Drop + Step);
      end loop;

      --  And the marks, moved with the tokens and turned back by Drop
      --  in every part, as the keys were.
      if Item.Marks /= null then
         for Step in 0 .. Moved - 1 loop
            declare
               Was : constant Rope_Mark := Item.Marks.all (Keep + Drop + Step);
            begin
               Item.Marks.all (Keep + Step) :=
                 (Place => (T => Integer'Max (0, Was.Place.T - Drop),
                            H => Integer'Max (0, Was.Place.H - Drop),
                            W => Integer'Max (0, Was.Place.W - Drop)),
                  Next  => Integer'Max (0, Was.Next - Drop));
            end;
         end loop;
         Item.Marked := Natural'Min (Item.Marked, Keep + Moved);
      end if;

      Item.Committed := Keep + Moved;
   end Shift;

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
      Item.Kept_Newest := 0;

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

   function Drafts_Next (Item : Session) return Boolean
   is (Item.Current not in Closed | Failed
       and then Item.Owner /= null
       and then Item.Owner.Next /= null
       and then Item.Next_Input /= null
       and then Item.Held = Exact);

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

         Product
           (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Logits := Item.Logit_Row.all;
         Finish_Logits (Source, Logits);
      end;
   end Draft_Next;

   --------------
   -- Evaluate --
   --------------

   procedure Evaluate
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Logits : out Real_Array;
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
                   <= Model_Runner.Backend.Device.Max_Members);

      --  A hybrid's linear layer goes whole where the device has the
      --  rule and the convolution, the session a ring that is over, and
      --  the feed-forward behind it is a shape the sequence takes.
      function Linear_Layer_Fits (L : Layer) return Boolean
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
          and then (if Settings.Experts > 0 then Mixture_Whole (L)
                    else T.Is_Present (L.Up)));

      --  A dense layer goes whole gated or not -- the one projection up
      --  with a unit alone on it is a shape the sequence takes -- and a
      --  mixture where the device holds its stacks.
      function Whole_Layer_Fits (L : Layer; Index : Natural) return Boolean
      is ((if Settings.Experts > 0 then Mixture_Whole (L)
           else T.Is_Present (L.Up))

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

          --  The device's attention takes a layer's sinks where the
          --  cache has room for them. A mixture with them went whole for
          --  a day with none, and the fixture check said its sinks
          --  answered to nothing, which is what the check is for.
          and then Sinks_Fit (L.Sinks)

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
          and then (Settings.Experts = 0
                    or else (L.Up_Bias = null and then L.Down_Bias = null))
          and then (L.Post_Feed_Norm = null
                    or else Settings.Experts = 0
                    or else Normalizes_After (Settings.Kind))

          --  The code variant's three normalizations more -- over the
          --  whole of the queries and the keys, and the attention
          --  sublayer's residual joined again -- are not in the sequence.
          and then L.Second_Attention_Norm = null
          and then L.Query_Whole_Norm = null);

      --  Whichever of the two a layer is: what the carry from the layer
      --  before asks of the layer after.
      function Layer_Fits (L : Layer; Index : Natural) return Boolean
      is (if Linear (Settings, Index) then Linear_Layer_Fits (L)
          else Whole_Layer_Fits (L, Index));

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
         if Gain /= null
           or else Produced.all'Length /= Item.Activation.all'Length
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
      Logits := [others => 0.0];

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

      if Logits'Length /= Element_Count (Settings.Vocabulary) then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "output", Long_Long_Integer (Logits'Length));
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
                 and then Linear_Layer_Fits (Current)
               then
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
                             Chaining
                             and then Index < Source.Layers.all'Last
                             and then Layer_Fits
                                        (Source.Layers.all (Index + 1),
                                         Natural (Index) + 1),
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
                             Linear_State_At (Item, Natural (Index)));
                        Went_Whole := Fused;
                     end if;
                  end;

                  if Fused then
                     Item.Kept_Newest :=
                       Natural'Max (Item.Kept_Newest, Natural (Reserved) + 1);
                     Carried :=
                       Chaining
                       and then Index < Source.Layers.all'Last
                       and then Layer_Fits
                                  (Source.Layers.all (Index + 1),
                                   Natural (Index) + 1);
                     if Chaining then
                        Deferred (Index) := True;
                     end if;
                     Charge (Item, Fusing, Mark);
                     goto Layer_Done;
                  end if;
               end if;

               Normalize
                 (Source, Item.Activation.all, Current.Attention_Norm.all,
                  Current.Attention_Norm_Bias, Item.Normalized.all);
               Charge (Item, Normalizing, Mark);

               Linear_Position
                 (Item, Source, Current, Natural (Index),
                  Natural (Reserved), Status);
               exit when E.Is_Error (Status);
               Charge (Item, Attending, Mark);

               Joined
                 (Item.Normalized, Current.Post_Attention_Norm,
                  Current.Post_Attention_Norm_Bias, Status);
               exit when E.Is_Error (Status);
               Charge (Item, Joining, Mark);
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
                 and then (Settings.Experts = 0 or else Mixture_Whole (Current))
                 and then Whole_Layer_Fits (Current, Natural (Index))
                 and then Model_Runner.Backend."="
                            (Item.Owner.Able.Kind,
                             Model_Runner.Backend.Backend_Device)
               then
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
                     Model_Runner.Backend.Device.Whole_Layer
                       (Item.Activation.all,
                        Device_Norm (Current.Attention_Norm,
                                     Current.Attention_Norm_Pair),
                        Device_Norm (Current.Feed_Norm,
                                     Current.Feed_Norm_Pair),
                        Settings.Epsilon,
                        Current.Query, Current.Key, Current.Value,
                        Angles, Natural (Head_Size), Settings.Rotary,
                        K."=" (Settings.Pairing, K.Split),
                        Natural ((if Item.Paged then 0
                                  else Block_Base (Item) + Slot)),
                        Natural ((if Item.Paged then Page_Value_Base (Item)
                                  else Block_Base (Item)
                                       + Exact_Keys (Item) + V_Slot)),
                        Natural (Heads), Natural (Value_Size),
                        Settings.Group_Size,
                        Natural (Cell_Of (Item, Natural (Index),
                                          Earliest (Settings, Reserved,
                                                    Natural (Index)))),
                        Natural (Cell),
                        Natural ((if Item.Paged then 0
                                  else Block_Base (Item) + Base)),
                        Natural ((if Item.Paged then Page_Value_Base (Item)
                                  else Block_Base (Item)
                                       + Exact_Keys (Item) + V_Base)),
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
                          Chaining
                          and then Index < Source.Layers.all'Last
                          and then Layer_Fits
                                     (Source.Layers.all (Index + 1),
                                      Natural (Index) + 1),
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
                        Sinks_At    => Sinks_Ready (Current.Sinks),
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
                        Shared_Router => Current.Shared_Router);
                     Went_Whole := Fused;
                  end if;
               end if;

               Carried :=
                 Chaining
                 and then Fused
                 and then Index < Source.Layers.all'Last
                 and then Layer_Fits
                            (Source.Layers.all (Index + 1),
                             Natural (Index) + 1);

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
                  Charge (Item, Fusing, Mark);
                  goto Layer_Done;
               end if;

               --  Attention block.
               Normalize
                 (Source, Item.Activation.all, Current.Attention_Norm.all,
                  Current.Attention_Norm_Bias, Item.Normalized.all);

               --  Falcon runs the feed-forward from this same normalized input
               --  rather than from what attention produced, so it is kept
               --  before attention overwrites the buffer it shares.
               if Current.Feed_Norm = null then
                  Item.Post_Room.all := Item.Normalized.all;
               end if;

               Charge (Item, Normalizing, Mark);

               --  The query projection's whole answer goes to its own room
               --  where it carries a gate beside each head, and the queries
               --  and the gates are taken out of it before anything reads
               --  them.
               Product_Group
                 (Item,
                  [Current.Query, Current.Key, Current.Value],
                  Item.Normalized,
                  [(if Hybrid (Settings.Kind) then Item.Query_Full else Item.Query),
                   Item.Key_Row, Item.Value_Row],
                  Status);
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

               K.Apply_Rotary
                 (Item.Query.all, Heads, Head_Size,
                  Element_Count (Settings.Rotary), Item.Committed,
                  Turn_Base (Settings, Natural (Index)),
                  Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                  Settings.Pairing,
                  Sections => Settings.Sections,
                  Place => Place_At (Item, Item.Committed));
               K.Apply_Rotary
                 (Item.Key_Row.all, KV_Heads, Head_Size,
                  Element_Count (Settings.Rotary), Item.Committed,
                  Turn_Base (Settings, Natural (Index)),
                  Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                  Settings.Pairing,
                  Sections => Settings.Sections,
                  Place => Place_At (Item, Item.Committed));

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
                  for Offset in 0 .. KV_Width - 1 loop
                     Item.Half_Keys.all (Slot + Offset) :=
                       N.To_Half (Item.Key_Row.all (Offset));
                  end loop;
                  for Offset in 0 .. V_Width - 1 loop
                     Item.Half_Values.all (V_Slot + Offset) :=
                       N.To_Half (Item.Value_Row.all (Offset));
                  end loop;
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
                    or else not Sinks_Fit (Current.Sinks)
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
                        Natural (Block_Base (Item) + Base),
                        --  A packed session has no exact rows for the
                        --  values to follow; its step reads neither base.
                        Natural (Block_Base (Item) + Exact_Keys (Item) + V_Base),
                        Natural (KV_Width), Natural (V_Width), Scale,
                        Settings.Attention_Cap, Current.Attention_Out,
                        Current.Feed_Norm.all, Settings.Epsilon,
                        Current.Gate, Current.Up, Current.Down,
                        Gate_Unit (Source), Item.Activation, Fused,
                        Max_Bias => Settings.Max_Bias,
                        Packed => Packed_Shape (Item, Base, V_Base,
                                                KV_Width, V_Width),
                        Sinks_At => Sinks_Ready (Current.Sinks),
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
                        Natural (Cell), Natural (Base),
                        Natural (Exact_Keys (Item) + V_Base),
                        Natural (KV_Width), Natural (V_Width), Scale,
                        Settings.Attention_Cap, Current.Attention_Out,
                        Item.Normalized, Projected,
                        Max_Bias => Settings.Max_Bias,
                        Packed => Packed_Shape (Item, Base, V_Base,
                                                KV_Width, V_Width),
                        Sinks_At => Sinks_Ready (Current.Sinks));

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
            if not Fused then
               --  Done already where the pair went over together, and
               --  where the layer is linear and joined its answer above.
               if not Is_Linear then
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
                  --  after the join, so it is kept across it.
                  if Current.Second_Attention_Norm /= null then
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
               --  the way in where the architecture runs the two in parallel,
               --  and what the residual holds now where it runs them one after
               --  the other -- which is the whole of the difference between
               --  the two arrangements.
               if Current.Feed_Norm = null then
                  Item.Normalized.all := Item.Post_Room.all;
               else
                  Normalize
                    (Source, Item.Activation.all, Current.Feed_Norm.all,
                     Current.Feed_Norm_Bias, Item.Normalized.all);
               end if;

               Charge (Item, Normalizing, Mark);

               if Settings.Experts > 0 then
                  Mixture
                    (Item, Current, Item.Normalized, Item.Mixture, Status);
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
                     if Model_Runner.Backend."=" (Item.Owner.Able.Kind,
                                                  Model_Runner.Backend
                                                    .Backend_Device)
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
                  Held => No_Block and then Blocks_Were_Held);
            end if;
         end;
      end loop;

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
                  if Item.Held in Eighth | Fourth then
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
        (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      Charge (Item, Reading_Out, Mark);

      Logits := Item.Logit_Row.all;
      Finish_Logits (Source, Logits);

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
   end Evaluate;

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
      --  at a time through the session's own buffers.
      Feed      : constant Element_Count :=
        (if Settings.Experts > 0
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
                   <= Model_Runner.Backend.Device.Max_Members);

      --  As the token's.
      function Linear_Layer_Fits (L : Layer) return Boolean
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
          and then (if Settings.Experts > 0 then Mixture_Whole (L)
                    else T.Is_Present (L.Up)));

      --  As the token's: a dense layer gated or not, a mixture where the
      --  device holds its stacks, the normalizations as the architecture
      --  arranges them and centred all or none, and a hybrid's attention
      --  layers but not its linear ones.
      function Whole_Layer_Fits (L : Layer; Index : Natural) return Boolean
      is ((if Settings.Experts > 0 then Mixture_Whole (L)
           else T.Is_Present (L.Up))
          and then not Linear (Settings, Index)
          and then (not Hybrid (Settings.Kind)
                    or else (Settings.Value_Size = Settings.Head_Size
                             and then L.Query_Bias = null))
          and then Sinks_Fit (L.Sinks)
          and then (L.Attention_Norm /= null)
                   = not Normalizes_After (Settings.Kind)
          and then (not Normalizes_After (Settings.Kind)
                    or else (L.Post_Attention_Norm /= null
                             and then L.Post_Feed_Norm /= null))
          and then Norms_Agree (L)
          and then (Settings.Experts = 0
                    or else (L.Up_Bias = null and then L.Down_Bias = null))
          and then (L.Post_Feed_Norm = null
                    or else Settings.Experts = 0
                    or else Normalizes_After (Settings.Kind))
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

      --  Whichever of the two a layer is: what the carry from the layer
      --  before asks of the layer after.
      function Layer_Fits (L : Layer; Index : Natural) return Boolean
      is (if Linear (Settings, Index) then Linear_Layer_Fits (L)
          else Whole_Layer_Fits (L, Index));

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
            then Max_Batch
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

      if Source.Settings.Kind in Falcon | Phi2 then
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

               if Current.Second_Attention_Norm /= null then
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
                        --  more after the join, so it is kept across it.
                        if Current.Second_Attention_Norm /= null then
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
                        if Normalizes_After (Source.Settings.Kind) then
                           Norm.all (Origin .. Origin + Width - 1) :=
                             Acts.all (Origin .. Origin + Width - 1);
                        elsif Current.Feed_Norm = null then
                           Norm.all (Origin .. Origin + Width - 1) :=
                             Kept_Norm.all (Origin .. Origin + Width - 1);
                        else
                           Normalize
                             (Source,
                              Acts.all (Origin .. Origin + Width - 1),
                              Current.Feed_Norm.all, Current.Feed_Norm_Bias,
                              Norm.all (Origin .. Origin + Width - 1));
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
              and then Linear_Layer_Fits (Current)
            then
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
                        Current.Gate, Current.Up, Current.Down,
                        Gate_Unit (Source),
                        Keys, Values, Acts, Whole_Layer_Done,
                        Positions => Natural (Count),
                        Cancel    => Item.Stopping,
                        Carry_In  => Carried,
                        Mirror    => False,
                        Carry_Out =>
                          Carrying
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
                          Linear_State_At (Item, Natural (Index)));
                     Went_Whole := Whole_Layer_Done;
                  end if;
               end;

               Deferred (Index) := Deferring and then Whole_Layer_Done;

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
                         and then Source.Settings.Kind not in Falcon | Phi2)
                        or else (Item.Held in Exact | Eighth | Fourth
                                 and then Whole_Layer_Fits
                                            (Current, Natural (Index))
                                 --  A round's members all seated, with
                                 --  the table its steps read; a batch
                                 --  with its block.
                                 and then Has_Block
                                            (Item'Unchecked_Access)))
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
                    and then (Settings.Experts = 0
                              or else Mixture_Whole (Current))
                    and then Whole_Layer_Fits (Current, Natural (Index))
                    and then not Has_Runs
                  then
                     Asked := True;
                     Model_Runner.Backend.Device.Whole_Layer
                       (Acts.all (0 .. Count * Width - 1),
                        Device_Norm (Current.Attention_Norm,
                                     Current.Attention_Norm_Pair),
                        Device_Norm (Current.Feed_Norm,
                                     Current.Feed_Norm_Pair),
                        Settings.Epsilon,
                        Current.Query, Current.Key, Current.Value,
                        (if Turnable
                         then Angles.all (0 .. Count * Pairs * 2 - 1)
                         else No_Turns),
                        Natural (Head_Size), Settings.Rotary,
                        K."=" (Settings.Pairing, K.Split),
                        Natural ((if Item.Paged then 0
                                  else Block_Base (Item)
                                       + Cell_Of (Item, Natural (Index),
                                                  Reserved) * KV_Width
                                       + Base)),
                        Natural ((if Item.Paged then Page_Value_Base (Item)
                                  else Block_Base (Item)
                                       + Cell_Of (Item, Natural (Index),
                                                  Reserved) * V_Width
                                       + Exact_Keys (Item) + V_Base)),
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
                        Natural ((if Item.Paged then 0
                                  else Block_Base (Item) + Base)),
                        Natural ((if Item.Paged then Page_Value_Base (Item)
                                  else Block_Base (Item)
                                       + Exact_Keys (Item) + V_Base)),
                        Natural (KV_Width), Natural (V_Width),
                        Scale, Settings.Attention_Cap,
                        Current.Attention_Out,
                        Current.Gate, Current.Up, Current.Down,
                        Gate_Unit (Source),
                        Keys, Values, Acts, Whole_Layer_Done,
                        Positions => Natural (Count),
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
                          Carrying
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
                        Sinks_At    => Sinks_Ready (Current.Sinks),
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
                        Shared_Router => Current.Shared_Router);
                     Went_Whole := Whole_Layer_Done;
                  end if;

                  Deferred (Index) := Deferring and then Whole_Layer_Done;

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
                    and then Source.Settings.Kind not in Falcon | Phi2
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
            if Source.Settings.Kind in Falcon | Phi2 then
               Kept_Norm.all (0 .. Count * Width - 1) :=
                 Norm.all (0 .. Count * Width - 1);
            end if;

            if Is_Linear and then Fused then
               --  Gone over whole above, feed-forward and all.
               null;
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
                  if Hybrid (Settings.Kind) then
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
                  Product_Batch
                    (Item, Current.Key, Norm, Count, Keys, Status);
                  exit when E.Is_Error (Status);
                  Product_Batch
                    (Item, Current.Value, Norm, Count, Values, Status);
                  exit when E.Is_Error (Status);
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

                     if Current.Query_Norm /= null then
                        Normalize_Heads
                          (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                           Current.Query_Norm.all, Settings.Epsilon,
                           Item.Head_Row.all);
                        Normalize_Heads
                          (Keys.all (KV_At .. KV_At + KV_Width - 1),
                           KV_Heads, Head_Size, Current.Key_Norm.all,
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
                                       Natural (Sits_At (Which))));
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
                        for Offset in 0 .. KV_Width - 1 loop
                           Item'Unchecked_Access.Half_Keys.all (Place + Offset) :=
                             N.To_Half (Keys.all (KV_At + Offset));
                        end loop;
                        for Offset in 0 .. V_Width - 1 loop
                           Item'Unchecked_Access.Half_Values.all (V_Place + Offset) :=
                             N.To_Half (Values.all (V_At + Offset));
                        end loop;
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
                       and then T.Is_Present (Current.Gate)
                       and then Current.Feed_Norm /= null
                       and then Current.Out_Bias = null
                       and then Current.Up_Bias = null
                       and then Current.Down_Bias = null
                       and then Current.Feed_Norm_Bias = null
                       and then Current.Post_Attention_Norm = null
                       and then Current.Post_Feed_Norm = null
                     then
                        Model_Runner.Backend.Device.Attend_And_Feed
                          (Query.all (0 .. Count * Wide - 1),
                           Acts.all (0 .. Count * Width - 1),
                           Natural (Heads), Natural (Head_Size),
                           Natural (Value_Size), Settings.Group_Size,
                           Natural (First_Step), Natural (Last_Step),
                           Natural (Seat_At + Base),
                           Natural (Seat_At + Exact_Keys (Item) + V_Base),
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
                           Sinks_At  => Sinks_Ready (Current.Sinks),
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

                        for Which in 0 .. Count - 1 loop
                           declare
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
                           end;
                        end loop;
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
            if not Fused then

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

               --  Which experts run is decided per position, so a batch has no
               --  one matrix to multiply the whole of it by: this is the one
               --  block that runs a token at a time however many were handed
               --  in. Everything before it -- the projections, the attention,
               --  the output -- still goes through the batch.
               if Settings.Experts > 0 then
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

            end if;

            --  What became of this layer, for the run's report.
            if Model_Runner.Backend."="
                 (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
            then
               Model_Runner.Backend.Device.Note_Layer
                 (Went_Whole, Asked, Cache => No_Block or else Blockless,
                  Held =>
                    (No_Block or else Blockless)
                    and then Blocks_Were_Held);
            end if;
         end;
      end loop;

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
                     if Item.Held in Eighth | Fourth then
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

end Model_Runner.Llama;
