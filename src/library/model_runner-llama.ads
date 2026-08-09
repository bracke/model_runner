private with Ada.Finalization;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Limits;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Progress;
with Model_Runner.Templates;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

--  The supported Llama-compatible decoder-only profile.
--
--  Exactly one architecture is supported and it is selected by the
--  general.architecture metadata value being "llama". Nothing infers an
--  architecture from a file name, and no related family -- Mistral, Mixtral,
--  Qwen, Gemma, Phi, Falcon and the rest -- is treated as Llama-compatible
--  without its own support contract.
--
--  Rejected features. Mixture of experts, sliding-window attention, attention
--  sinks, cross-attention, multimodal projections, recurrent state,
--  unsupported rotary scaling, unsupported normalization and unsupported
--  activations are rejected during preparation, before any evaluation.
--
--  Staged ownership. Prepare acquires the tensor arena, the tokenizer and the
--  layer table into the Model object and only marks it ready once every stage
--  has succeeded. A failure at any stage releases everything acquired so far,
--  and a partially initialized model is never observable as usable.
--
--  Task safety: a Model is immutable once prepared and may be read
--  concurrently. A Session holds mutable state and belongs to one task.
package Model_Runner.Llama is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Wide_Real is Model_Runner.Numerics.Wide_Real;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;

   --  Architecture identifier this package implements. Never localized.
   Architecture_Name : constant String := "llama";

   --  Validated architecture configuration.
   --
   --  Every field is read from metadata through a typed accessor and range
   --  checked; the derived fields are checked for exact divisibility so that
   --  no later computation has to round.
   type Configuration is record
      Context_Length  : Natural := 0;
      Embedding       : Natural := 0;
      Feed_Forward    : Natural := 0;
      Layers          : Natural := 0;
      Heads           : Natural := 0;
      KV_Heads        : Natural := 0;
      Head_Size       : Natural := 0;
      Group_Size      : Natural := 0;
      Rotary          : Natural := 0;
      Vocabulary      : Natural := 0;
      Epsilon         : Real := 0.0;
      Rope_Base       : Wide_Real := 10_000.0;
      Rope_Scale      : Wide_Real := 1.0;
      Tied_Output     : Boolean := False;
   end record;

   --  A prepared, immutable model.
   type Model is tagged limited private;
   --  Replace the model's chat template with one the caller supplies.
   --
   --  For models whose own template this build will not compile. The source
   --  is compiled and validated exactly as an embedded one is, so an
   --  unusable replacement is refused rather than stored.
   --
   --  @param Item Prepared model.
   --  @param Source Template source.
   --  @param Bounds Limits applied while compiling.
   --  @param Status Success, or why the source was refused.
   procedure Use_Template
     (Item   : in out Model;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits;
      Status : out Model_Runner.Errors.Error_Info);


   --  Load, validate and prepare a model from an open byte source.
   --
   --  The source must stay open for the life of the model.
   --
   --  @param Item Model to prepare; released first.
   --  @param Source Container already parsed from Bytes.
   --  @param Bytes Byte source the container was parsed from.
   --  @param Bounds Limits applied to the configuration and to allocation.
   --  @param Cancel Cancellation token, or null.
   --  @param Observer Progress observer, or null.
   --  @param Backend Backend the model will be evaluated on. Every tensor is
   --    checked against what that backend can read, so a model carrying a
   --    format it cannot take is refused here with
   --    Backend_Unsupported_Format naming the tensor and the format.
   --  @param Status Success, or the first diagnostic that stopped preparation.

   procedure Prepare
     (Item     : in out Model;
      Source   : Model_Runner.GGUF.Containers.Container;
      Bytes    : in out Model_Runner.Byte_Sources.Source'Class;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Backend  : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Status   : out Model_Runner.Errors.Error_Info);

   --  What a prepared model holds, by category.
   --
   --  @param Item Prepared model.
   --  @return The account, all zero before preparation.
   function Accounting
     (Item : Model) return Model_Runner.Memory.Account;

   --  Release a model. Idempotent.
   --
   --  @param Item Model to release.
   --  @param Status Success, or Lifecycle_Session_Active when a session is
   --    still open on the model.
   procedure Close
     (Item   : in out Model;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report whether a model is ready to evaluate.
   --
   --  @param Item Model to inspect.
   --  @return True only after every preparation stage succeeded.
   function Is_Ready (Item : Model) return Boolean;

   --  Validated configuration of a prepared model.
   --
   --  @param Item Prepared model.
   --  @return Configuration; all zeros when the model is not ready.
   function Config (Item : Model) return Configuration;

   --  The model's tokenizer.
   --
   --  @param Item Prepared model.
   --  @return Read-only reference to the loaded vocabulary.
   function Vocabulary
     (Item : Model) return access constant Model_Runner.Tokenizer.Vocabulary;

   --  Read and validate the architecture configuration without loading any
   --  tensor data.
   --
   --  Used by the inspect command, which reports what a model declares without
   --  paying for the weights.
   --
   --  @param Source Validated container.
   --  @param Bounds Limits applied to the configuration.
   --  @param Settings Validated configuration; all zeros on failure.
   --  @param Status Success or an architecture diagnostic.
   procedure Read_Config
     (Source   : Model_Runner.GGUF.Containers.Container;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Settings : out Configuration;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Report whether the model file carries a chat template.
   --
   --  @param Item Prepared model.
   --  @return True when tokenizer.chat_template is present.
   function Has_Template (Item : Model) return Boolean;

   --  Report whether the chat template compiled into the supported subset.
   --
   --  A model whose template is present but unsupported is still usable in raw
   --  mode; conversation mode reports Template_Condition instead of guessing.
   --
   --  @param Item Prepared model.
   --  @return True when the template is compiled and renderable.
   function Template_Ready (Item : Model) return Boolean;

   --  Why the chat template is unusable, when it is.
   --
   --  @param Item Prepared model.
   --  @return Success when the template compiled or is absent.
   function Template_Condition
     (Item : Model) return Model_Runner.Errors.Error_Info;

   --  The compiled chat template.
   --
   --  @param Item Prepared model.
   --  @return Read-only reference; not renderable unless Template_Ready.
   function Template
     (Item : Model) return access constant Model_Runner.Templates.Compiled;

   --  Memory accounted during preparation.
   --
   --  @param Item Prepared model.
   --  @return Allocation account.
   function Account (Item : Model) return Model_Runner.Memory.Account;

   ---------------------------------------------------------------------------
   --  Sessions
   ---------------------------------------------------------------------------

   --  States a session moves through. Every operation checks the state and
   --  reports Lifecycle_Invalid_State rather than acting on a session that
   --  cannot serve the request.
   type Session_State is
     (Ready,
      Evaluating_Prompt,
      Generating,
      Completed,
      Cancelled,
      Failed,
      Closed);

   --  Mutable evaluation state: the KV cache, the activation buffers and the
   --  committed position.
   type Session is tagged limited private;

   --  Estimate the memory a session with the requested capacity would need.
   --
   --  Called before any session allocation, so an impossible request is
   --  rejected without touching the allocator.
   --
   --  @param Item Prepared model.
   --  @param Context Requested context capacity in tokens.
   --  @param Plan Estimate; Valid is False on overflow.
   --  @param Status Success or Memory_Plan_Overflow.
   procedure Plan_Session
     (Item    : Model;
      Context : Natural;
      Plan    : out Model_Runner.Memory.Session_Plan;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Estimate session memory from a configuration alone.
   --
   --  @param Settings Validated configuration.
   --  @param Context Requested context capacity; 0 uses the model's own.
   --  @param Plan Estimate; Valid is False on overflow.
   --  @param Status Success or Memory_Plan_Overflow.
   procedure Plan_For
     (Settings : Configuration;
      Context  : Natural;
      Plan     : out Model_Runner.Memory.Session_Plan;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Open a session on a prepared model.
   --
   --  @param Item Session to open; closed first.
   --  @param Source Prepared model; must outlive the session.
   --  @param Context Context capacity in tokens; 0 uses the model's own.
   --  @param Session_Bounds Limits applied to the request.
   --  @param Workers Worker pool used for matrix-vector products, or null to
   --    compute them on the calling task. The pool must outlive the session.
   --    Results do not depend on the worker count.
   --  @param Status Success, Lifecycle_Model_Not_Ready, Arch_Context_Too_Large
   --    or a memory diagnostic.
   procedure Open
     (Item           : in out Session;
      Source         : in out Model'Class;
      Context        : Natural := 0;
      Session_Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Workers        : Model_Runner.Backend.CPU.Pool_Reference := null;
      Status         : out Model_Runner.Errors.Error_Info);

   --  Worker pool the session was opened with.
   --
   --  @param Item Session to inspect.
   --  @return Pool reference, or null for serial execution.
   function Workers
     (Item : Session) return Model_Runner.Backend.CPU.Pool_Reference;

   --  What an open session holds, by category.
   --
   --  @param Item Open session.
   --  @return The account, all zero before the session opens.
   function Accounting
     (Item : Session) return Model_Runner.Memory.Account;

   --  Close a session. Idempotent.
   --
   --  @param Item Session to close.
   procedure Close (Item : in out Session);

   --  Current state of a session.
   --
   --  @param Item Session to inspect.
   --  @return Session state.
   function State (Item : Session) return Session_State;

   --  Number of committed context positions.
   --
   --  @param Item Session to inspect.
   --  @return Committed position count.
   function Position (Item : Session) return Natural;

   --  Context capacity of a session.
   --
   --  @param Item Session to inspect.
   --  @return Capacity in tokens.
   function Capacity (Item : Session) return Natural;

   --  Token committed at a position.
   --
   --  Used by interactive mode to check that a re-rendered conversation is an
   --  exact prefix extension of what the cache already holds.
   --
   --  @param Item Session to inspect.
   --  @param Index Zero-based position.
   --  @return Committed token, or No_Token when out of range.
   function Committed_Token (Item : Session; Index : Natural) return Token_Id;

   --  Evaluate one token and produce the next-token logits.
   --
   --  The cache position is reserved, every layer is evaluated, and the
   --  position is committed only after the whole token succeeded. A failure or
   --  a cancellation leaves the committed position count unchanged, so a
   --  partially written position is never readable as context.
   --
   --  @param Item Session to advance.
   --  @param Source Prepared model the session was opened on.
   --  @param Token Token to evaluate.
   --  @param Logits Raw vocabulary-sized logit vector, indexed from 0. No
   --    softmax is applied; the sampler consumes raw logits.
   --  @param Cancel Cancellation token, or null.
   --  @param Status Success, Generation_Context_Exhausted,
   --    Generation_Cancelled, Tokenizer_Invalid_Token_Id or a tensor
   --    diagnostic.
   procedure Evaluate
     (Item   : in out Session;
      Source : Model'Class;
      Token  : Token_Id;
      Logits : out Real_Array;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out Model_Runner.Errors.Error_Info);

   --  Largest number of tokens one batched call will evaluate. A batch holds
   --  activations for every token in it, so this bounds that working set
   --  rather than letting a long prompt decide it.
   Max_Batch : constant := 128;

   --  Evaluate several consecutive tokens in one pass.
   --
   --  This is how a prompt is consumed. Every token in the batch shares one
   --  pass over the weights, and reading and decoding those weights is what
   --  a forward pass actually spends its time on, so a batch of N costs far
   --  less than N single tokens. Only the last token's logits are produced:
   --  a prompt is consumed to establish context, and the intermediate
   --  distributions are not used.
   --
   --  Each token is computed exactly as it would be alone, in the same order,
   --  so a batch produces the same bits as the same tokens evaluated one at a
   --  time. Attention stays causal: token K of the batch sees the committed
   --  context and batch tokens 0 through K, and nothing after it.
   --
   --  Either every token commits or none does. A cancelled or failed batch
   --  leaves the cache describing exactly the context that preceded it.
   --
   --  @param Item Session to advance.
   --  @param Source Prepared model.
   --  @param Tokens Tokens to evaluate, at most Max_Batch of them.
   --  @param Logits Distribution after the last token of the batch.
   --  @param Cancel Cancellation token, observed between layers.
   --  @param Status Success, Generation_Cancelled, Generation_Context_Exhausted,
   --    Tokenizer_Invalid_Token_Id, Tensor_Shape_Mismatch, Lifecycle_Invalid_State
   --    or Memory_Allocation_Failed.
   procedure Evaluate_Batch
     (Item   : in out Session;
      Source : Model'Class;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      Logits : out Real_Array;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out Model_Runner.Errors.Error_Info);

   --  Invalidate the cache and the history without releasing memory.
   --
   --  @param Item Session to reset.
   procedure Reset (Item : in out Session);

private

   type Layer is record
      Attention_Norm : Model_Runner.Tensors.Real_Array_Access;
      Query          : Model_Runner.Tensors.View;
      Key            : Model_Runner.Tensors.View;
      Value          : Model_Runner.Tensors.View;
      Attention_Out  : Model_Runner.Tensors.View;
      Feed_Norm      : Model_Runner.Tensors.Real_Array_Access;
      Gate           : Model_Runner.Tensors.View;
      Up             : Model_Runner.Tensors.View;
      Down           : Model_Runner.Tensors.View;
   end record;

   type Layer_Array is array (Natural range <>) of Layer;
   type Layer_Array_Access is access Layer_Array;

   type Model is limited new Ada.Finalization.Limited_Controlled with record
      Ready       : Boolean := False;
      Sessions    : Natural := 0;
      Settings    : Configuration;
      Arena       : Model_Runner.Bytes.Byte_Array_Access := null;
      Arena_Base  : Model_Runner.Bytes.Byte_Count := 0;
      Layers      : Layer_Array_Access := null;
      Embeddings  : Model_Runner.Tensors.View;
      Output      : Model_Runner.Tensors.View;
      Output_Norm : Model_Runner.Tensors.Real_Array_Access;
      Words       : aliased Model_Runner.Tokenizer.Vocabulary;
      Chat        : aliased Model_Runner.Templates.Compiled;
      Chat_Present : Boolean := False;
      Chat_Status : Model_Runner.Errors.Error_Info;
      Accounting  : Model_Runner.Memory.Account;

      --  What the backend this model was prepared for can read. Every tensor
      --  is checked against it while the model loads, so that a format the
      --  backend cannot take is refused with the model rather than found by
      --  a matrix product part way through the first token.
      Able        : Model_Runner.Backend.Capabilities;
   end record;

   overriding procedure Finalize (Item : in out Model);

   type Token_History is array (Natural range <>) of Token_Id;
   type Token_History_Access is access Token_History;

   type Session is limited new Ada.Finalization.Limited_Controlled with record
      --  What this session holds, by category. The plan computes every one
      --  of these before anything is allocated; recording them is what makes
      --  a memory report say where the memory went, and what lets a limit
      --  count the largest thing a session has.
      Accounting : Model_Runner.Memory.Account;

      Current    : Session_State := Closed;
      Owner      : access Model'Class := null;
      Context    : Natural := 0;
      Committed  : Natural := 0;
      Keys       : Model_Runner.Tensors.Real_Array_Access := null;
      Values     : Model_Runner.Tensors.Real_Array_Access := null;
      History    : Token_History_Access := null;
      Activation : Model_Runner.Tensors.Real_Array_Access := null;
      Normalized : Model_Runner.Tensors.Real_Array_Access := null;
      Query      : Model_Runner.Tensors.Real_Array_Access := null;
      Key_Row    : Model_Runner.Tensors.Real_Array_Access := null;
      Value_Row  : Model_Runner.Tensors.Real_Array_Access := null;
      Attention  : Model_Runner.Tensors.Real_Array_Access := null;
      Scores     : Model_Runner.Tensors.Real_Array_Access := null;
      Gate       : Model_Runner.Tensors.Real_Array_Access := null;
      Up         : Model_Runner.Tensors.Real_Array_Access := null;
      Plan       : Model_Runner.Memory.Session_Plan;
      Team       : Model_Runner.Backend.CPU.Pool_Reference := null;
      Logit_Row  : Model_Runner.Tensors.Real_Array_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Session);

end Model_Runner.Llama;
