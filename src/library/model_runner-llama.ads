private with Ada.Finalization;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Kernels;
with Model_Runner.Limits;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Progress;
with Model_Runner.Templates;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

--  The supported Llama-compatible decoder-only profile.
--
--  The architectures this profile reads are listed in Architecture, and each
--  is selected by the general.architecture metadata value naming it. Nothing
--  infers an architecture from a file name, and no related family -- Mistral,
--  Mixtral, Gemma, Phi, Falcon and the rest -- is treated as compatible
--  without its own support contract.
--
--  A second architecture belongs here rather than in a profile of its own
--  when it is this shape with a difference, which is what Qwen2 is: the same
--  normalization, attention and feed-forward, plus a bias on each attention
--  projection and the other rotary pairing. One that differs in more than
--  that gets its own profile, because a profile that answers for everything
--  answers for nothing.
--
--  Rejected features. Attention sinks, cross-attention, multimodal
--  projections, recurrent state, unsupported normalization and unsupported
--  activations are rejected during preparation, before any evaluation.
--
--  Rotary scaling is implemented for the stretches a file can state as one
--  rule: none, linear, and yarn, together with the table of per-dimension
--  divisors a file writes when the schedule is not one number. What is
--  refused is a method that picks between two tables by how long the prompt
--  turned out to be, which makes the rotation depend on the sequence rather
--  than on the position.
--
--  Mixture of experts is implemented. A model that names an expert count
--  carries a router beside each layer's feed-forward block and a stack of
--  expert matrices instead of one; the router scores the experts for the
--  position being computed, the highest few are run, and their outputs are
--  summed in proportion to the scores the softmax gave them, renormalized
--  over the chosen few. Which experts run is decided per position, so this
--  is the one place where evaluating a batch is not evaluating a matrix
--  against many vectors at once.
--
--  What is not claimed there is a shared expert that runs for every position
--  beside the chosen ones, and a gate that is not a softmax. A model
--  carrying either is refused by name rather than run with the part that is
--  understood.
--
--  Sliding-window attention is implemented rather than rejected: a model that
--  names a window has each position attend to the window's worth of
--  positions ending at itself, and one that names none attends to everything
--  committed. The window is uniform across layers, which is what the key
--  means for a model that applies it to every layer; an architecture that
--  alternates windowed and full layers needs more than this and is not
--  claimed.
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
   --  The architectures this profile reads.
   --
   --  All of them are the same shape: RMS normalization, rotary encoding,
   --  grouped query attention and a SwiGLU feed-forward. Qwen2 adds a bias
   --  to each of the three attention projections; Qwen3 drops the biases
   --  again and normalizes each query and key head before the rotation;
   --  Qwen3_MoE is Qwen3 with its feed-forward block behind a router, which
   --  is a metadata prefix here and nothing else, because the mixture is
   --  read from the keys rather than from the name. Each belongs here rather
   --  than in a profile of its own because each is this shape with a
   --  difference.
   type Architecture is (Llama, Qwen2, Qwen3, Qwen3_MoE);

   --  The identifier a file carries for an architecture.
   --
   --  @param Item Architecture to name.
   --  @return Lower-case identifier, as general.architecture spells it.
   function Architecture_Name (Item : Architecture) return String
   is (case Item is
         when Llama     => "llama",
         when Qwen2     => "qwen2",
         when Qwen3     => "qwen3",
         when Qwen3_MoE => "qwen3moe");

   --  Validated architecture configuration.
   --
   --  Every field is read from metadata through a typed accessor and range
   --  checked; the derived fields are checked for exact divisibility so that
   --  no later computation has to round.
   type Configuration is record
      Kind            : Architecture := Llama;
      Pairing         : Model_Runner.Kernels.Rotary_Pairing :=
        Model_Runner.Kernels.Interleaved;
      Context_Length  : Natural := 0;
      Embedding       : Natural := 0;
      Feed_Forward    : Natural := 0;
      Layers          : Natural := 0;
      Heads           : Natural := 0;
      KV_Heads        : Natural := 0;
      --  Width of one query or key head, and of one value head. A file may
      --  state the two separately and they are then different numbers: the
      --  keys decide which positions a head reads and the values decide what
      --  it reads from them, and nothing requires those to be the same size.
      --  A file that states neither has both derived from the embedding
      --  width, which is what a model without the keys means.
      Head_Size       : Natural := 0;
      Value_Size      : Natural := 0;
      Group_Size      : Natural := 0;
      Rotary          : Natural := 0;
      Vocabulary      : Natural := 0;
      Epsilon         : Real := 0.0;
      Rope_Base       : Wide_Real := 10_000.0;

      --  How the model stretches the rotation to reach past the context it
      --  was trained on, and by how much. The default is the rotation as
      --  trained, which is what a model that says nothing means.
      Scaling         : Model_Runner.Kernels.Rotary_Scaling :=
        Model_Runner.Kernels.No_Scaling;
      Tied_Output     : Boolean := False;

      --  How far back attention may look, in positions, counting the
      --  current one. Zero is no window at all: every committed position is
      --  visible, which is what a model without the key means.
      --
      --  A model with a window is not a model with a shorter context. The
      --  context is still the bound on how much may be held; the window is
      --  the bound on how much each position may see. Both are needed and
      --  they are not the same number.
      Window          : Natural := 0;

      --  How many experts each layer holds and how many of them run for one
      --  position. Zero experts is a dense model: one feed-forward block per
      --  layer, no router, which is what a model without the key means.
      Experts         : Natural := 0;
      Experts_Used    : Natural := 0;

      --  Width of one expert's feed-forward block. A mixture-of-experts file
      --  may state this separately from feed_forward_length, because the two
      --  are different numbers: one expert is narrower than the dense block
      --  the model would have had. Equal to Feed_Forward when the file does
      --  not say, and unused by a dense model.
      Expert_Feed     : Natural := 0;
   end record;

   --  The feed-forward width one activation buffer has to hold: an expert's
   --  when the model has experts, and the dense block's when it does not.
   --
   --  @param Settings Configuration to inspect.
   --  @return Width in elements.
   function Feed_Width (Settings : Configuration) return Natural
   is (if Settings.Experts > 0
       then Settings.Expert_Feed
       else Settings.Feed_Forward);

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

   --  What to decode the weight matrices into before evaluating them.
   --
   --  No_Repack reads them as the file stores them, decoding a span on every
   --  pass. The other two decode every matrix once at load and evaluate from
   --  that copy, which costs four bytes a weight or two against about one.
   --
   --  To_F32 cannot change what the model says: the values written are the
   --  ones the decoder produces, in the order the kernels read them, and a
   --  test holds the logits to the bit.
   --
   --  To_BF16 can, and does. A brain float keeps eight mantissa bits where
   --  binary32 keeps twenty-three, so a value the decoder produced may not
   --  be representable and is rounded to the nearest one that is. It halves
   --  the copy. Whether that trade is worth taking is a measurement, and
   --  the README carries it.
   type Repack_Mode is (No_Repack, To_F32, To_BF16);

   --  The word a caller types for a repacking mode.
   --
   --  @param Item Mode to name.
   --  @return Lower-case identifier such as "bf16".
   function Repack_Name (Item : Repack_Mode) return String
   is (case Item is
         when No_Repack => "none",
         when To_F32    => "f32",
         when To_BF16   => "bf16");

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
   --  @param Repack What to decode the weight matrices into, or No_Repack
   --    to read them as the file stores them.
   --  @param Threads How many tasks may decode at once when repacking. The
   --    matrices are independent and each writes its own region, so this is
   --    the one part of a load that divides; at one it is what it was, which
   --    took thirteen seconds for a gigabyte while seven cores watched.
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
      Repack   : Repack_Mode := No_Repack;
      Threads  : Positive := 1;
      Status   : out Model_Runner.Errors.Error_Info);

   --  What the backend this model was prepared for can do.
   --
   --  A caller building a request asks this rather than assuming: a backend
   --  that cannot batch is given one token at a time, which is a decision
   --  about what to ask for and not a failure. Two paths build requests, and
   --  when the clamp lived in one of them the other refused its first turn.
   --
   --  @param Item Prepared model.
   --  @return The capability record, all defaults before preparation.
   function Capability
     (Item : Model) return Model_Runner.Backend.Capabilities;

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
   --  Where a session is.
   --
   --  A phase of the session, not of a request. Completed and Cancelled were
   --  declared here and reachable by nothing, and they could not have been
   --  reached correctly: a request that finishes or is cancelled leaves the
   --  session ready for the next one, and what became of the request is in
   --  the result it produced. A session that has failed is a different
   --  matter, because nothing further can be asked of it.
   type Session_State is
     (Ready,
      Evaluating_Prompt,
      Generating,
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

   --  Record what phase a session is in.
   --
   --  The session knows it has been asked to evaluate and to sample; only
   --  the caller running the request knows whether a batch is a prompt being
   --  read or a reply being written, or how the request ended. Three of the
   --  seven states this type declares were reachable by nobody until the
   --  caller could say so.
   --
   --  Refused unless the session is open, so that a phase cannot be recorded
   --  against a session that has failed or closed.
   --
   --  @param Item Open session.
   --  @param Phase Phase to record.
   procedure Enter
     (Item  : in out Session;
      Phase : Session_State);

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

   --  One expert's feed-forward block. The three matrices are views into the
   --  stacked tensor the file carries -- the expert axis is the outermost, so
   --  an expert's rows are contiguous and a view over them needs no copy.
   type Expert is record
      Gate : aliased Model_Runner.Tensors.View;
      Up   : aliased Model_Runner.Tensors.View;
      Down : aliased Model_Runner.Tensors.View;
   end record;

   type Expert_Array is array (Natural range <>) of Expert;
   type Expert_Array_Access is access Expert_Array;

   type Layer is record
      Attention_Norm : Model_Runner.Tensors.Real_Array_Access;
      Query : aliased Model_Runner.Tensors.View;
      Key : aliased Model_Runner.Tensors.View;
      Value : aliased Model_Runner.Tensors.View;

      --  Added to the projections after they are computed. Null for an
      --  architecture that has none, which is what Llama has.
      Query_Bias     : Model_Runner.Tensors.Real_Array_Access;
      Key_Bias       : Model_Runner.Tensors.Real_Array_Access;
      Value_Bias     : Model_Runner.Tensors.Real_Array_Access;
      --  A gain for each element of a head, applied to every query head and
      --  every key head before the rotation. Null for an architecture that
      --  does not normalize its heads, which is what Llama and Qwen2 are.
      Query_Norm     : Model_Runner.Tensors.Real_Array_Access;
      Key_Norm       : Model_Runner.Tensors.Real_Array_Access;
      Attention_Out : aliased Model_Runner.Tensors.View;
      Feed_Norm      : Model_Runner.Tensors.Real_Array_Access;
      Gate : aliased Model_Runner.Tensors.View;
      Up : aliased Model_Runner.Tensors.View;
      Down : aliased Model_Runner.Tensors.View;

      --  What a mixture-of-experts layer carries instead: the router, which
      --  scores every expert for a position, and the experts themselves.
      --  Both are absent from a dense layer, where Gate, Up and Down are the
      --  whole feed-forward block.
      Router  : aliased Model_Runner.Tensors.View;
      Experts : Expert_Array_Access := null;
   end record;

   type Layer_Array is array (Natural range <>) of Layer;
   type Layer_Array_Access is access Layer_Array;

   type Model is limited new Ada.Finalization.Limited_Controlled with record
      Ready       : Boolean := False;
      Sessions    : Natural := 0;
      Settings    : Configuration;
      Arena       : Model_Runner.Bytes.Byte_Array_Access := null;
      Arena_Base  : Model_Runner.Bytes.Byte_Count := 0;

      --  The decoded copy of the weight matrices, when one was asked for.
      --  Every matrix view then refers into this instead of into the file's
      --  own bytes, and the file's arena stays mapped for whatever was not
      --  repacked.
      Repacked    : Model_Runner.Bytes.Byte_Array_Access := null;
      Layers      : Layer_Array_Access := null;
      Embeddings  : aliased Model_Runner.Tensors.View;
      Output      : aliased Model_Runner.Tensors.View;
      Output_Norm : Model_Runner.Tensors.Real_Array_Access;

      --  One divisor per rotated pair, when the model carries the table.
      --  Null otherwise, which is every element one. Decoded once here
      --  rather than read per token: it is a few dozen numbers and the
      --  rotation reads all of them for every head of every layer.
      Rope_Factors : Model_Runner.Tensors.Real_Array_Access := null;
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

      --  Room for one head, for an architecture that normalizes each of them
      --  before the rotation. Null for one that does not.
      Head_Row   : Model_Runner.Tensors.Real_Array_Access := null;
      Scores     : Model_Runner.Tensors.Real_Array_Access := null;
      Gate       : Model_Runner.Tensors.Real_Array_Access := null;
      Up         : Model_Runner.Tensors.Real_Array_Access := null;

      --  What a mixture of experts needs beyond the dense block: the
      --  router's scores, the sum being accumulated over the chosen experts,
      --  and the one expert's output being added into it. All three are null
      --  for a dense model, which allocates none of them.
      Routing    : Model_Runner.Tensors.Real_Array_Access := null;
      Mixture    : Model_Runner.Tensors.Real_Array_Access := null;
      Expert_Row : Model_Runner.Tensors.Real_Array_Access := null;
      Plan       : Model_Runner.Memory.Session_Plan;
      Team       : Model_Runner.Backend.CPU.Pool_Reference := null;
      Logit_Row  : Model_Runner.Tensors.Real_Array_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Session);

end Model_Runner.Llama;
