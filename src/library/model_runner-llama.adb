with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Interfaces;

with Model_Runner.Arithmetic;
with Model_Runner.Backend.Reference;
with Model_Runner.Text;

package body Model_Runner.Llama is

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

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Arithmetic.Checked;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;
   use type Model_Runner.Tensors.Real_Array_Access;

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

   --  Bytes one cache element occupies. The V1 cache stores Real, which is the
   --  correctness baseline; a half-precision cache would need its own
   --  conformance evidence before it could be advertised.
   Cache_Element_Bytes : constant := 4;

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

   procedure Deallocate_History is
     new Ada.Unchecked_Deallocation (Token_History, Token_History_Access);

   ---------------------------------------------------------------------------
   --  Configuration
   ---------------------------------------------------------------------------

   --  Read and validate the architecture metadata.
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
                    when Qwen2 => K.Split);
               Found := True;
            end if;
         end loop;

         if not Found then
            Status := E.Make (E.Arch_Unsupported);
            E.Add_Text (Status, "architecture", Name, E.Param_Identifier);
            E.Add_Text
              (Status, "supported", Architecture_Name (Llama),
               E.Param_Identifier);
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

      Required (Model_Key (Settings.Kind, "feed_forward_length"),
                Long_Long_Integer (Bounds.Max_Embedding) * 64,
                Settings.Feed_Forward);
      if E.Is_Error (Status) then
         return;
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

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "attention.layer_norm_rms_epsilon"),
         0.0, 1.0, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Epsilon :=
        (if E.Is_Ok (Local) then N.Real (Value) else 1.0E-5);

      Containers.Get_Float
        (Source, Model_Key (Settings.Kind, "rope.freq_base"), 1.0, 1.0E12, Value, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Rope_Base := (if E.Is_Ok (Local) then Value else 10_000.0);

      --  Rotary scaling. Only "none" and "linear" are implemented; anything
      --  else changes the position mapping and would silently produce a
      --  different model.
      declare
         Scaling : constant String :=
           Containers.String_Value (Source, Model_Key (Settings.Kind, "rope.scaling.type"));
      begin
         if Scaling /= "" and then Scaling /= "none" and then Scaling /= "linear"
         then
            Status := E.Make (E.Arch_Unsupported_Rope_Scaling);
            E.Add_Text (Status, "scaling", Scaling, E.Param_Identifier);
            return;
         end if;

         Containers.Get_Float
           (Source, Model_Key (Settings.Kind, "rope.scaling.factor"), 0.0, 1.0E6, Value, Local);
         if Present_And_Wrong (Local) then
            Status := Local;
            return;
         end if;
         if E.Is_Ok (Local) and then Value > 0.0 then
            Settings.Rope_Scale := 1.0 / Value;
         end if;
      end;

      --  Features this profile does not implement. Presence of the key is
      --  enough to reject: the model is not the one this crate can run.
      if Containers.Has (Source, Model_Key (Settings.Kind, "expert_count"))
        or else Containers.Has (Source, Model_Key (Settings.Kind, "expert_used_count"))
      then
         Reject_Feature ("mixture_of_experts");
         return;
      end if;

      if Containers.Has (Source, Model_Key (Settings.Kind, "attention.sliding_window")) then
         Reject_Feature ("sliding_window_attention");
         return;
      end if;

      if Containers.Has (Source, Model_Key (Settings.Kind, "attention.value_length"))
        and then Containers.Has (Source, Model_Key (Settings.Kind, "attention.key_length"))
      then
         --  Separate key and value widths are legal GGUF but are not part of
         --  this profile, whose head size is derived from the embedding width.
         declare
            Key_Length, Value_Length : Long_Long_Integer;
            First, Second : E.Error_Info;
         begin
            Containers.Get_Integer
              (Source, Model_Key (Settings.Kind, "attention.key_length"), 1, 1_000_000,
               Key_Length, First);
            Containers.Get_Integer
              (Source, Model_Key (Settings.Kind, "attention.value_length"), 1, 1_000_000,
               Value_Length, Second);
            --  Both keys are known to be present here, so an unreadable one
            --  is the file being wrong. Skipping the comparison would let a
            --  mistyped width past the very check that exists to catch it.
            if Present_And_Wrong (First) then
               Status := First;
               return;
            end if;
            if Present_And_Wrong (Second) then
               Status := Second;
               return;
            end if;

            if E.Is_Ok (First) and then E.Is_Ok (Second)
              and then Key_Length /= Value_Length
            then
               Reject_Feature ("asymmetric_key_value_width");
               return;
            end if;
         end;
      end if;

      --  Derived widths must divide exactly; a remainder would mean the file
      --  describes a model this arithmetic cannot express.
      if Settings.Embedding mod Settings.Heads /= 0 then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer (Status, "embedding", Long_Long_Integer (Settings.Embedding));
         E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
         return;
      end if;

      if Settings.Heads mod Settings.KV_Heads /= 0 then
         Status := E.Make (E.Arch_Invalid_Head_Counts);
         E.Add_Integer (Status, "heads", Long_Long_Integer (Settings.Heads));
         E.Add_Integer
           (Status, "kv_heads", Long_Long_Integer (Settings.KV_Heads));
         return;
      end if;

      Settings.Head_Size := Settings.Embedding / Settings.Heads;
      Settings.Group_Size := Settings.Heads / Settings.KV_Heads;

      Containers.Get_Integer
        (Source, Model_Key (Settings.Kind, "rope.dimension_count"), 1,
         Long_Long_Integer (Settings.Head_Size), Number, Local);
      if Present_And_Wrong (Local) then
         Status := Local;
         return;
      end if;
      Settings.Rotary :=
        (if E.Is_Ok (Local) then Natural (Number) else Settings.Head_Size);

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

   --  Resolve one tensor by name and check its shape against the role it
   --  plays. Every required tensor is resolved during preparation; no name
   --  lookup happens during evaluation.
   procedure Resolve
     (Item     : in out Model;
      Source   : Containers.Container;
      Name     : String;
      Rows     : Element_Count;
      Columns  : Element_Count;
      Result   : out T.View;
      Status   : out E.Error_Info)
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
      --  No shipped configuration reaches this. The one backend claims
      --  exactly the formats the decoder decodes, and a format outside that
      --  set is refused by the check above. It is written anyway, because it
      --  is the seam a narrower backend plugs into, and because a capability
      --  record nothing consults is one that can be wrong for a year --
      --  which is how Supports_Batched came to say False while every prefill
      --  batched. Supports had no caller at all before this.
      if not Model_Runner.Backend.Supports
               (Item.Able, Containers.Tensor_Format (Source, Index))
      then
         Status := E.Make (E.Backend_Unsupported_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text
           (Status, "format",
            Model_Runner.GGUF.Type_Name
              (Containers.Tensor_Format (Source, Index)),
            E.Param_Identifier);
         E.Add_Text
           (Status, "backend",
            Model_Runner.Backend.Backend_Name (Item.Able.Kind),
            E.Param_Identifier);
         return;
      end if;

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
            Data    => Item.Arena,
            Offset  =>
              B.Byte_Count (Containers.Tensor_Offset (Source, Index))
              - Item.Arena_Base,
            Result  => Result,
            Status  => Status);

         if E.Is_Error (Status) then
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         end if;
      end;
   end Resolve;

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
      Resolve (Item, Source, Name, 1, Width, Weight, Status);
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
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Model_Runner.Templates.Close (Item.Chat);
      Model_Runner.Templates.Compile (Item.Chat, Source, Bounds, Status);
      Item.Chat_Present := E.Is_Ok (Status);
      Item.Chat_Status := Status;
   end Use_Template;

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
      Threads  : Positive := 1;
      Status   : out E.Error_Info)
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

      Mem.Initialize (Item.Accounting, Bounds, Bounds.Max_Model_Bytes);

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
         Item.Arena_Base := B.Byte_Count (Containers.Data_Offset (Source));

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
         Bytes.Read (Item.Arena_Base, Item.Arena.all, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
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
         KV     : constant Element_Count :=
           Element_Count (Item.Settings.KV_Heads * Item.Settings.Head_Size);
      begin
         Resolve
           (Item, Source, "token_embd.weight", Vocab, Width,
            Item.Embeddings, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         Resolve_Norm
           (Item, Source, "output_norm.weight", Width, Item.Output_Norm, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         --  A model with no output projection ties the output to the embedding
         --  table. The alias is explicit and immutable; nothing is copied.
         if Containers.Find_Tensor (Source, "output.weight") = 0 then
            Item.Settings.Tied_Output := True;
            Item.Output := Item.Embeddings;
         else
            Resolve
              (Item, Source, "output.weight", Vocab, Width,
               Item.Output, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end if;

         Item.Layers := new Layer_Array (0 .. Item.Settings.Layers - 1);

         for Index in Item.Layers.all'Range loop
            if C.Is_Cancelled (Cancel) then
               Fail (E.Make (E.Generation_Cancelled));
               return;
            end if;

            declare
               Current : Layer renames Item.Layers.all (Index);
            begin
               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "attn_norm.weight"), Width,
                  Current.Attention_Norm, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_q.weight"),
                  Width, Width, Current.Query, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_k.weight"),
                  KV, Width, Current.Key, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_v.weight"),
                  KV, Width, Current.Value, Status);
               exit when E.Is_Error (Status);

               --  Qwen2 adds a bias to each projection and Llama has none.
               --  Required when the architecture says so rather than taken
               --  if present: a qwen2 file without them is a file this
               --  cannot evaluate, and reading it as though the biases were
               --  zero would produce plausible text that is not what the
               --  model says.
               if Item.Settings.Kind = Qwen2 then
                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_q.bias"),
                     Width, Current.Query_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_k.bias"),
                     KV, Current.Key_Bias, Status);
                  exit when E.Is_Error (Status);

                  Resolve_Norm
                    (Item, Source, Layer_Key (Index, "attn_v.bias"),
                     KV, Current.Value_Bias, Status);
                  exit when E.Is_Error (Status);
               end if;

               Resolve
                 (Item, Source, Layer_Key (Index, "attn_output.weight"),
                  Width, Width, Current.Attention_Out, Status);
               exit when E.Is_Error (Status);

               Resolve_Norm
                 (Item, Source, Layer_Key (Index, "ffn_norm.weight"), Width,
                  Current.Feed_Norm, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "ffn_gate.weight"),
                  Feed, Width, Current.Gate, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "ffn_up.weight"),
                  Feed, Width, Current.Up, Status);
               exit when E.Is_Error (Status);

               Resolve
                 (Item, Source, Layer_Key (Index, "ffn_down.weight"),
                  Width, Feed, Current.Down, Status);
               exit when E.Is_Error (Status);
            end;
         end loop;

         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
      end;

      --  Decode the weight matrices once, if that was asked for.
      --
      --  Every matrix then refers into a second buffer holding binary32,
      --  and nothing else changes: the values written are the ones the
      --  decoder produces, in the order the kernels read them, so what
      --  follows is the same arithmetic on the same numbers. What it costs
      --  is four bytes a weight against about one, which is why it is asked
      --  for rather than done.
      if Repack /= No_Repack then
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

            --  Every matrix this model holds. A norm is already a decoded
            --  vector and a bias is too, so neither is here.
            type View_Access is access all T.View;
            type View_List is array (Positive range <>) of View_Access;

            Skipped : Natural := 0;

            function Matrices return View_List is
               Room  : View_List (1 .. 2 + 7 * Item.Settings.Layers);
               Count : Natural := 0;

               Target : constant Model_Runner.GGUF.Tensor_Type :=
                 (if Repack = To_BF16
                  then Model_Runner.GGUF.Type_BF16
                  else Model_Runner.GGUF.Type_F32);

               procedure Add (Where : View_Access) is
               begin
                  --  A matrix already in the target format is nothing to
                  --  decode: copying it would double the memory to buy
                  --  nothing, which is what the first version of this did
                  --  to every binary32 tensor in a file.
                  if T.Is_Present (Where.all) then
                     if Model_Runner.GGUF."=" (Where.all.Format, Target) then
                        Skipped := Skipped + 1;
                     else
                        Count := Count + 1;
                        Room (Count) := Where;
                     end if;
                  end if;
               end Add;
            begin
               Add (Item.Embeddings'Access);
               Add (Item.Output'Access);

               for Index in Item.Layers'Range loop
                  Add (Item.Layers (Index).Query'Access);
                  Add (Item.Layers (Index).Key'Access);
                  Add (Item.Layers (Index).Value'Access);
                  Add (Item.Layers (Index).Attention_Out'Access);
                  Add (Item.Layers (Index).Gate'Access);
                  Add (Item.Layers (Index).Up'Access);
                  Add (Item.Layers (Index).Down'Access);
               end loop;

               return Room (1 .. Count);
            end Matrices;

            Held : constant View_List := Matrices;
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
                    (if Item.Arena = null then 0
                     else Interfaces.Unsigned_64 (Item.Arena.all'Length));
               begin
                  B.Free (Item.Arena);
                  Item.Arena_Base := 0;
                  Mem.Record_Release
                    (Item.Accounting, Mem.Model_Weights, Was);
               end;
            end if;
         end;
      end if;

      P.Publish (Observer, P.Load_Progress (P.Finalizing_Model));
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
      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch (Item.Team, Weight, Vector, Target, Status);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product
              (Weight, Vector, Target, Status);
      end case;
   end Product;

   procedure Product_Batch
     (Item    : Session;
      Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      case Item.Owner.Able.Kind is
         when Model_Runner.Backend.Backend_CPU =>
            Workers_CPU.Dispatch_Batch
              (Item.Team, Weight, Vectors, Count, Target, Status);
         when Model_Runner.Backend.Backend_Reference =>
            Model_Runner.Backend.Reference.Product_Batch
              (Weight, Vectors, Count, Target, Status);
      end case;
   end Product_Batch;

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

      if Item.Layers /= null then
         for Index in Item.Layers.all'Range loop
            T.Free (Item.Layers.all (Index).Attention_Norm);
            T.Free (Item.Layers.all (Index).Feed_Norm);
         end loop;
         Deallocate_Layers (Item.Layers);
      end if;

      T.Free (Item.Output_Norm);
      B.Free (Item.Arena);
      B.Free (Item.Repacked);
      Item.Arena_Base := 0;
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

   function Template_Ready (Item : Model) return Boolean
   is (Item.Chat_Present and then Model_Runner.Templates.Is_Compiled (Item.Chat));

   -------------------------
   -- Template_Condition --
   -------------------------

   function Template_Condition (Item : Model) return E.Error_Info
   is (Item.Chat_Status);

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

   ------------------
   -- Plan_Session --
   ------------------

   procedure Plan_Session
     (Item    : Model;
      Context : Natural;
      Plan    : out Mem.Session_Plan;
      Status  : out E.Error_Info) is
   begin
      Plan_For (Item.Settings, Context, Plan, Status);
   end Plan_Session;

   ---------------
   -- Plan_For --
   ---------------

   procedure Plan_For
     (Settings : Configuration;
      Context  : Natural;
      Plan     : out Mem.Session_Plan;
      Status   : out E.Error_Info)
   is
      Capacity : constant Natural :=
        (if Context = 0 then Settings.Context_Length else Context);

      --  layers * capacity * kv heads * head size * bytes * 2, entirely in
      --  checked arithmetic so that an implausible request is reported as an
      --  overflow rather than wrapping into a small allocation.
      Cache : constant A.Checked :=
        A.To_Checked (Interfaces.Unsigned_64 (Settings.Layers))
        * A.To_Checked (Interfaces.Unsigned_64 (Capacity))
        * A.To_Checked (Interfaces.Unsigned_64 (Settings.KV_Heads))
        * A.To_Checked (Interfaces.Unsigned_64 (Settings.Head_Size))
        * A.To_Checked (Interfaces.Unsigned_64'(Cache_Element_Bytes))
        * A.To_Checked (Interfaces.Unsigned_64'(2));
   begin
      Plan := (others => <>);

      if not A.Is_Valid (Cache) then
         Status := E.Make (E.Memory_Plan_Overflow);
         return;
      end if;

      Plan.KV_Cache_Bytes := A.Value (Cache);
      Plan.Activation_Bytes :=
        Interfaces.Unsigned_64 (Settings.Embedding) * 4 * 4;
      Plan.Batch_Bytes :=
        Interfaces.Unsigned_64 (Settings.Feed_Forward) * 4 * 2;
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
      Status         : out E.Error_Info)
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

      if Source.Sessions > 0 then
         --  V1 supports one active session per prepared model.
         Status := E.Make (E.Lifecycle_Session_Active);
         return;
      end if;

      Settings := Source.Settings;
      Capacity := (if Context = 0 then Settings.Context_Length else Context);

      if Capacity = 0
        or else Capacity > Settings.Context_Length
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

      if Session_Bounds.Max_Session_Bytes /= 0
        and then Item.Plan.Total_Resident > Session_Bounds.Max_Session_Bytes
      then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", "kv_cache", E.Param_Identifier);
         E.Add_Integer
           (Status, "requested",
            Long_Long_Integer (Item.Plan.Total_Resident), E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Session_Bounds.Max_Session_Bytes),
            E.Param_Bytes);
         return;
      end if;

      declare
         Width : constant Element_Count :=
           Element_Count (Settings.Embedding);
         Feed  : constant Element_Count :=
           Element_Count (Settings.Feed_Forward);
         KV    : constant Element_Count :=
           Element_Count (Settings.KV_Heads * Settings.Head_Size);
         Cache : constant Element_Count :=
           Element_Count (Settings.Layers) * Element_Count (Capacity) * KV;
      begin
         T.Allocate (Cache, Item.Keys);
         T.Allocate (Cache, Item.Values);
         T.Allocate (Width, Item.Activation);
         T.Allocate (Width, Item.Normalized);
         T.Allocate (Width, Item.Query);
         T.Allocate (KV, Item.Key_Row);
         T.Allocate (KV, Item.Value_Row);
         T.Allocate (Width, Item.Attention);
         T.Allocate (Element_Count (Capacity), Item.Scores);
         T.Allocate (Feed, Item.Gate);
         T.Allocate (Feed, Item.Up);
         T.Allocate (Element_Count (Settings.Vocabulary), Item.Logit_Row);
         Item.History := new Token_History (0 .. Capacity - 1);

         if Item.Keys = null or else Item.Values = null
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

      T.Free (Item.Keys);
      T.Free (Item.Values);
      T.Free (Item.Activation);
      T.Free (Item.Normalized);
      T.Free (Item.Query);
      T.Free (Item.Key_Row);
      T.Free (Item.Value_Row);
      T.Free (Item.Attention);
      T.Free (Item.Scores);
      T.Free (Item.Gate);
      T.Free (Item.Up);
      T.Free (Item.Logit_Row);

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

   procedure Reset (Item : in out Session) is
   begin
      --  Only the logical contents are invalidated. The cache and scratch
      --  buffers stay allocated so that a reset costs nothing and the next
      --  turn does not have to plan memory again.
      --
      --  Their contents do not stay. A reset is a caller saying the previous
      --  conversation is over, and the tokens of it sat in the history until
      --  something happened to write over them. Bytes.Wipe was written for
      --  this and its documentation said it was used on session reset; it
      --  was called by nothing.
      if Item.History /= null then
         Item.History.all := [others => Model_Runner.Tokenizer.No_Token];
      end if;
      Item.Committed := 0;
      if Item.Current /= Closed then
         Item.Current := Ready;
      end if;
   end Reset;

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
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;
      Reserved  : constant Element_Count := Element_Count (Item.Committed);
      Scale     : constant Real :=
        Real (1.0 / N.Sqrt (N.Wide_Real (Settings.Head_Size)));
   begin
      Logits := [others => 0.0];

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
              Element_Count (Index) * Element_Count (Item.Context) * KV_Width;
            Slot    : constant Element_Count := Base + Reserved * KV_Width;
         begin
            --  Attention block.
            K.RMS_Norm
              (Item.Activation.all, Current.Attention_Norm.all,
               Settings.Epsilon, Item.Normalized.all);

            Product
              (Item, Current.Query, Item.Normalized, Item.Query, Status);
            exit when E.Is_Error (Status);
            Product
              (Item, Current.Key, Item.Normalized, Item.Key_Row, Status);
            exit when E.Is_Error (Status);
            Product
              (Item, Current.Value, Item.Normalized, Item.Value_Row,
               Status);
            exit when E.Is_Error (Status);

            --  The projection bias, before the rotary encoding, because the
            --  bias is part of the projection and the encoding acts on what
            --  the projection produced.
            if Current.Query_Bias /= null then
               K.Add (Item.Query.all, Current.Query_Bias.all);
               K.Add (Item.Key_Row.all, Current.Key_Bias.all);
               K.Add (Item.Value_Row.all, Current.Value_Bias.all);
            end if;

            K.Apply_Rotary
              (Item.Query.all, Heads, Head_Size,
               Element_Count (Settings.Rotary), Item.Committed,
               Settings.Rope_Base, Settings.Rope_Scale, Settings.Pairing);
            K.Apply_Rotary
              (Item.Key_Row.all, KV_Heads, Head_Size,
               Element_Count (Settings.Rotary), Item.Committed,
               Settings.Rope_Base, Settings.Rope_Scale, Settings.Pairing);

            --  Write into the reserved slot. The slot is only readable as
            --  context once Committed is advanced, at the end of this call.
            for Offset in 0 .. KV_Width - 1 loop
               Item.Keys.all (Slot + Offset) := Item.Key_Row.all (Offset);
               Item.Values.all (Slot + Offset) := Item.Value_Row.all (Offset);
            end loop;

            --  Causal attention over the committed positions and this one.
            --  Grouped-query attention maps each query head to its key-value
            --  head by division; no key or value head is ever duplicated.
            for Head in 0 .. Heads - 1 loop
               declare
                  Group    : constant Element_Count :=
                    Head / Element_Count (Settings.Group_Size);
                  Query    : Real_Array renames Item.Query.all;
                  Q_Origin : constant Element_Count := Head * Head_Size;
                  Scores   : Real_Array renames Item.Scores.all;
                  Usable   : Boolean;
               begin
                  for Step in 0 .. Reserved loop
                     declare
                        Origin : constant Element_Count :=
                          Base + Step * KV_Width + Group * Head_Size;
                        Sum    : N.Wide_Real := 0.0;
                     begin
                        for Component in 0 .. Head_Size - 1 loop
                           Sum := Sum
                             + N.Wide_Real (Query (Q_Origin + Component))
                               * N.Wide_Real
                                   (Item.Keys.all (Origin + Component));
                        end loop;
                        Scores (Step) := Real (Sum) * Scale;
                     end;
                  end loop;

                  K.Softmax (Scores (0 .. Reserved), Usable);
                  if not Usable then
                     Item.Current := Failed;
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     E.Add_Integer (Status, "layer", Long_Long_Integer (Index));
                     return;
                  end if;

                  for Component in 0 .. Head_Size - 1 loop
                     declare
                        Sum : N.Wide_Real := 0.0;
                     begin
                        for Step in 0 .. Reserved loop
                           Sum := Sum
                             + N.Wide_Real (Scores (Step))
                               * N.Wide_Real
                                   (Item.Values.all
                                      (Base + Step * KV_Width
                                       + Group * Head_Size + Component));
                        end loop;
                        Item.Attention.all (Q_Origin + Component) := Real (Sum);
                     end;
                  end loop;
               end;
            end loop;

            Product
              (Item, Current.Attention_Out, Item.Attention,
               Item.Normalized, Status);
            exit when E.Is_Error (Status);
            K.Add (Item.Activation.all, Item.Normalized.all);

            --  Feed-forward block.
            K.RMS_Norm
              (Item.Activation.all, Current.Feed_Norm.all,
               Settings.Epsilon, Item.Normalized.all);

            Product
              (Item, Current.Gate, Item.Normalized, Item.Gate, Status);
            exit when E.Is_Error (Status);
            Product
              (Item, Current.Up, Item.Normalized, Item.Up, Status);
            exit when E.Is_Error (Status);

            K.SiLU (Item.Gate.all);
            K.Multiply (Item.Gate.all, Item.Up.all);

            Product
              (Item, Current.Down, Item.Gate, Item.Normalized, Status);
            exit when E.Is_Error (Status);
            K.Add (Item.Activation.all, Item.Normalized.all);
         end;
      end loop;

      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      K.RMS_Norm
        (Item.Activation.all, Source.Output_Norm.all, Settings.Epsilon,
         Item.Normalized.all);

      --  The output projection is the widest product of the token, so it is
      --  the one that most benefits from the pool. It writes into a
      --  session-owned row that is then copied into the caller's vector.
      Product
        (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
      if E.Is_Error (Status) then
         Item.Current := Failed;
         return;
      end if;

      Logits := Item.Logit_Row.all;

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
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out E.Error_Info)
   is
      Settings  : constant Configuration := Source.Settings;
      Width     : constant Element_Count := Element_Count (Settings.Embedding);
      Feed      : constant Element_Count :=
        Element_Count (Settings.Feed_Forward);
      Head_Size : constant Element_Count := Element_Count (Settings.Head_Size);
      Heads     : constant Element_Count := Element_Count (Settings.Heads);
      KV_Heads  : constant Element_Count := Element_Count (Settings.KV_Heads);
      KV_Width  : constant Element_Count := KV_Heads * Head_Size;
      Wide      : constant Element_Count := Heads * Head_Size;
      Reserved  : constant Element_Count := Element_Count (Item.Committed);
      Count     : constant Element_Count := Element_Count (Tokens'Length);
      Scale     : constant Real :=
        Real (1.0 / N.Sqrt (N.Wide_Real (Settings.Head_Size)));

      --  One batch's activations. Held for the call rather than the session
      --  so that a session that never batches pays nothing for the option.
      Acts   : T.Real_Array_Access := null;
      Norm   : T.Real_Array_Access := null;
      Query  : T.Real_Array_Access := null;
      Keys   : T.Real_Array_Access := null;
      Values : T.Real_Array_Access := null;
      Attend : T.Real_Array_Access := null;
      Gate   : T.Real_Array_Access := null;
      Up     : T.Real_Array_Access := null;

      procedure Release is
      begin
         T.Free (Acts);
         T.Free (Norm);
         T.Free (Query);
         T.Free (Keys);
         T.Free (Values);
         T.Free (Attend);
         T.Free (Gate);
         T.Free (Up);
      end Release;

      --  Slice of a batch buffer belonging to one token of the batch.
      function Slot
        (Which : Element_Count; Stride : Element_Count) return Element_Count
      is (Which * Stride);
   begin
      Logits := [others => 0.0];

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

      if Count = 0 or else Count > Max_Batch then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "input", Long_Long_Integer (Count));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Batch));
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

      if Reserved + Count > Element_Count (Item.Context) then
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

      T.Allocate (Count * Width, Acts);
      T.Allocate (Count * Width, Norm);
      T.Allocate (Count * Wide, Query);
      T.Allocate (Count * KV_Width, Keys);
      T.Allocate (Count * KV_Width, Values);
      T.Allocate (Count * Wide, Attend);
      T.Allocate (Count * Feed, Gate);
      T.Allocate (Count * Feed, Up);

      if Acts = null or else Norm = null or else Query = null
        or else Keys = null or else Values = null or else Attend = null
        or else Gate = null or else Up = null
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "batch_activations", E.Param_Identifier);
         return;
      end if;

      --  Embedding lookup for every token of the batch.
      for Which in 0 .. Count - 1 loop
         declare
            Origin : constant Element_Count := Slot (Which, Width);
         begin
            T.Dequantize_Row
              (Source.Embeddings,
               Element_Count (Tokens (Tokens'First + Natural (Which))),
               Acts.all (Origin .. Origin + Width - 1), Status);
            if E.Is_Error (Status) then
               Release;
               Item.Current := Failed;
               return;
            end if;
         end;
      end loop;

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
              Element_Count (Index) * Element_Count (Item.Context) * KV_Width;
         begin
            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  K.RMS_Norm
                    (Acts.all (Origin .. Origin + Width - 1),
                     Current.Attention_Norm.all, Settings.Epsilon,
                     Norm.all (Origin .. Origin + Width - 1));
               end;
            end loop;

            --  One pass over each weight for the whole batch.
            Product_Batch
              (Item, Current.Query, Norm, Count, Query, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Key, Norm, Count, Keys, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Value, Norm, Count, Values, Status);
            exit when E.Is_Error (Status);

            --  Rotate at each token's own position, then publish every key
            --  and value before any attention reads them: token K of the
            --  batch attends to the earlier tokens of the same batch.
            for Which in 0 .. Count - 1 loop
               declare
                  Q_At : constant Element_Count := Slot (Which, Wide);
                  KV_At : constant Element_Count := Slot (Which, KV_Width);
                  Place : constant Element_Count :=
                    Base + (Reserved + Which) * KV_Width;
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
                     K.Add (Values.all (KV_At .. KV_At + KV_Width - 1),
                            Current.Value_Bias.all);
                  end if;

                  K.Apply_Rotary
                    (Query.all (Q_At .. Q_At + Wide - 1), Heads, Head_Size,
                     Element_Count (Settings.Rotary),
                     Item.Committed + Natural (Which),
                     Settings.Rope_Base, Settings.Rope_Scale,
                     Settings.Pairing);
                  K.Apply_Rotary
                    (Keys.all (KV_At .. KV_At + KV_Width - 1),
                     KV_Heads, Head_Size, Element_Count (Settings.Rotary),
                     Item.Committed + Natural (Which),
                     Settings.Rope_Base, Settings.Rope_Scale,
                     Settings.Pairing);

                  for Offset in 0 .. KV_Width - 1 loop
                     Item.Keys.all (Place + Offset) :=
                       Keys.all (KV_At + Offset);
                     Item.Values.all (Place + Offset) :=
                       Values.all (KV_At + Offset);
                  end loop;
               end;
            end loop;

            for Which in 0 .. Count - 1 loop
               declare
                  --  Causal: this token sees the committed context and the
                  --  batch tokens up to and including itself.
                  Last_Step : constant Element_Count := Reserved + Which;
                  Q_At      : constant Element_Count := Slot (Which, Wide);
               begin
                  for Head in 0 .. Heads - 1 loop
                     declare
                        Group    : constant Element_Count :=
                          Head / Element_Count (Settings.Group_Size);
                        Q_Origin : constant Element_Count :=
                          Q_At + Head * Head_Size;
                        Scores   : Real_Array renames Item.Scores.all;
                        Usable   : Boolean;
                     begin
                        for Step in 0 .. Last_Step loop
                           declare
                              Origin : constant Element_Count :=
                                Base + Step * KV_Width + Group * Head_Size;
                              Sum    : N.Wide_Real := 0.0;
                           begin
                              for Component in 0 .. Head_Size - 1 loop
                                 Sum := Sum
                                   + N.Wide_Real
                                       (Query.all (Q_Origin + Component))
                                     * N.Wide_Real
                                         (Item.Keys.all (Origin + Component));
                              end loop;
                              Scores (Step) := Real (Sum) * Scale;
                           end;
                        end loop;

                        K.Softmax (Scores (0 .. Last_Step), Usable);
                        if not Usable then
                           Release;
                           Item.Current := Failed;
                           Status := E.Make (E.Tensor_Non_Finite_Value);
                           E.Add_Integer
                             (Status, "layer", Long_Long_Integer (Index));
                           return;
                        end if;

                        for Component in 0 .. Head_Size - 1 loop
                           declare
                              Sum : N.Wide_Real := 0.0;
                           begin
                              for Step in 0 .. Last_Step loop
                                 Sum := Sum
                                   + N.Wide_Real (Scores (Step))
                                     * N.Wide_Real
                                         (Item.Values.all
                                            (Base + Step * KV_Width
                                             + Group * Head_Size + Component));
                              end loop;
                              Attend.all (Q_Origin + Component) := Real (Sum);
                           end;
                        end loop;
                     end;
                  end loop;
               end;
            end loop;

            Product_Batch
              (Item, Current.Attention_Out, Attend, Count, Norm, Status);
            exit when E.Is_Error (Status);

            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  K.Add
                    (Acts.all (Origin .. Origin + Width - 1),
                     Norm.all (Origin .. Origin + Width - 1));
                  K.RMS_Norm
                    (Acts.all (Origin .. Origin + Width - 1),
                     Current.Feed_Norm.all, Settings.Epsilon,
                     Norm.all (Origin .. Origin + Width - 1));
               end;
            end loop;

            Product_Batch
              (Item, Current.Gate, Norm, Count, Gate, Status);
            exit when E.Is_Error (Status);
            Product_Batch
              (Item, Current.Up, Norm, Count, Up, Status);
            exit when E.Is_Error (Status);

            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Feed);
               begin
                  K.SiLU (Gate.all (Origin .. Origin + Feed - 1));
                  K.Multiply
                    (Gate.all (Origin .. Origin + Feed - 1),
                     Up.all (Origin .. Origin + Feed - 1));
               end;
            end loop;

            Product_Batch
              (Item, Current.Down, Gate, Count, Norm, Status);
            exit when E.Is_Error (Status);

            for Which in 0 .. Count - 1 loop
               declare
                  Origin : constant Element_Count := Slot (Which, Width);
               begin
                  K.Add
                    (Acts.all (Origin .. Origin + Width - 1),
                     Norm.all (Origin .. Origin + Width - 1));
               end;
            end loop;
         end;
      end loop;

      if E.Is_Error (Status) then
         Release;
         Item.Current := Failed;
         return;
      end if;

      --  Only the last token's distribution is produced: the earlier tokens
      --  of a prompt are consumed to build context, not to be sampled from.
      declare
         Origin : constant Element_Count := Slot (Count - 1, Width);
      begin
         K.RMS_Norm
           (Acts.all (Origin .. Origin + Width - 1), Source.Output_Norm.all,
            Settings.Epsilon, Item.Normalized.all);
      end;

      Product
        (Item, Source.Output, Item.Normalized, Item.Logit_Row, Status);
      if E.Is_Error (Status) then
         Release;
         Item.Current := Failed;
         return;
      end if;

      Logits := Item.Logit_Row.all;

      --  Commit every position of the batch, or none of them.
      for Which in 0 .. Count - 1 loop
         Item.History.all (Item.Committed + Natural (Which)) :=
           Tokens (Tokens'First + Natural (Which));
      end loop;
      Item.Committed := Item.Committed + Natural (Count);
      Status := E.Success;
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
