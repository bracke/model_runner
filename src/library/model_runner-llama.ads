with System;
private with Ada.Finalization;

with Interfaces;

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
--  Several sessions. A prepared model carries no per-evaluation state: the
--  activations, the normalized copies, the query and the key and value rows
--  all belong to the session, and the weights are read and never written. So
--  a model may have any number of sessions open at once, each with its own
--  context, and they do not see each other. What one model buys is the
--  loading and the memory: a second session on a model already prepared
--  costs its own cache and nothing else.
--
--  Anything that would write to the model is refused while a session is open
--  -- merging an adapter, closing the model -- which is what makes the
--  sentence above true rather than hopeful.
--
--  Task safety: a Model is immutable once prepared and may be read
--  concurrently. A Session holds mutable state and belongs to one task. Two
--  sessions may therefore be evaluated from two tasks, on a backend that
--  allows it: the processor backends do, each session bringing its own
--  worker pool, and the device backend does not -- it is one queue and says
--  so.
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
   --  grouped query attention and a gated feed-forward. Qwen2 adds a bias
   --  to each of the three attention projections; Qwen3 drops the biases
   --  again and normalizes each query and key head before the rotation;
   --  Qwen3_MoE is Qwen3 with its feed-forward block behind a router, which
   --  is a metadata prefix here and nothing else, because the mixture is
   --  read from the keys rather than from the name. Each belongs here rather
   --  than in a profile of its own because each is this shape with a
   --  difference.
   --
   --  Gemma is the same shape with three differences, and each is the kind
   --  that produces a plausible wrong answer rather than a refusal:
   --
   --    the normalization gain is one plus the stored weight, because the
   --    weights are trained around zero rather than around one -- read as
   --    llama reads them, every layer is scaled by roughly nothing;
   --
   --    the embedding row is multiplied by the square root of the embedding
   --    width before the first layer, which is a factor of about forty on a
   --    model of this size;
   --
   --    the feed-forward gate is a Gaussian error unit rather than a
   --    logistic one, which is close enough to SiLU to look right and
   --    different enough to be wrong.
   --  Gemma2 is Gemma with four more differences, and they are of the same
   --  kind: each is silent when missed. Two more normalizations a block,
   --  after each sublayer rather than before it; a bound on the attention
   --  scores and another on the logits, both applied as a scaled hyperbolic
   --  tangent; and a sliding window on every other layer rather than on all
   --  of them or none.
   --  Gemma3 keeps gemma2's two normalizations a block and drops its two
   --  bounds. What it adds is a rotation that differs by layer: five layers
   --  in six slide a window and turn on a base of their own, and the sixth
   --  attends to everything and turns on the model's. It normalizes query
   --  and key heads as Qwen3 does, which is the one difference here that was
   --  already written for something else.
   --  Phi3 is this shape with its projections written as two tensors rather
   --  than five: the queries, keys and values in one, and the gate and the
   --  up projection in another. Nothing about the arithmetic differs -- what
   --  differs is where the weights are, and a reader that took the first
   --  rows of a fused tensor for the whole of a projection would compute a
   --  model whose heads are somebody else's.
   --  Falcon is the first architecture here that is not this shape with a
   --  difference but a different arrangement of the same parts: it
   --  normalizes by centring rather than by root mean square and carries a
   --  bias for it, it runs attention and the feed-forward block from the
   --  same normalized input rather than one after the other, and its
   --  feed-forward has no gate -- one projection up, a Gaussian unit, one
   --  projection down. Its projections are fused as phi3's are.
   --  Bert is the first architecture here that does not generate. It reads a
   --  whole text at once and produces a state for every position of it, and
   --  three things follow from that which no decoder here has.
   --
   --  Its attention is bidirectional: a position sees every other position
   --  of the text, the ones after it as well as the ones before. Every other
   --  architecture here is causal, and the difference is not a parameter of
   --  attention but a fact about what the model was trained to be -- a bert
   --  read causally answers, and answers with an embedding that is quietly
   --  the wrong one.
   --
   --  It normalizes after the residual add rather than before the sublayer:
   --  LN(x + Attn(x)), where Gemma2 computes x + LN(Attn(x)). The parts are
   --  the same and the order is not, so this is a third arrangement beside
   --  the two already here rather than a flag on one of them.
   --
   --  And it learns three embeddings rather than one: a row for the token, a
   --  row for where the token is, and a row for which segment it belongs to,
   --  summed and normalized before the first layer. The position row is
   --  GPT2's, which is why there is no rotation anywhere in the model.
   --  Nomic_Bert is Bert's arrangement with three of its parts replaced. It
   --  rotates where Bert learns a row for the position, so it carries no
   --  position table at all; its queries, keys and values are written fused
   --  as Phi3 writes them; and its feed-forward is gated where Bert's is a
   --  single projection through a Gaussian unit. What it keeps is what
   --  makes Bert what it is: attention both ways, a normalization after
   --  each residual add rather than before each sublayer, a segment row
   --  beside the token's, and no projection to a distribution.
   --
   --  It carries no bias on any projection either -- only the two
   --  normalizations a block and the one over the embedding have one --
   --  which is why every bias here is asked for by architecture rather
   --  than taken if present.
   type Architecture is
     (Llama, Qwen2, Qwen3, Qwen3_MoE, Gemma, Gemma2, Gemma3, Phi3, Falcon,
      Phi2, GPT2, Bert, Nomic_Bert, Jina_Bert_V2);

   --  Whether an architecture normalizes after adding a sublayer to the
   --  residual rather than before handing the block its input.
   --
   --  Written once because it decides four things that are far apart: which
   --  normalization tensors a block carries, what the block is given, which
   --  side of the addition the gain falls on, and whether there is a final
   --  normalization at all. Named rather than listed at each, so a third
   --  architecture of this shape adds itself here.
   --
   --  @param Item Architecture to ask about.
   --  @return True where the normalization follows the residual add.
   function Normalizes_After (Item : Architecture) return Boolean
   is (Item in Bert | Nomic_Bert | Jina_Bert_V2);

   --  The identifier a file carries for an architecture.
   --
   --  @param Item Architecture to name.
   --  @return Lower-case identifier, as general.architecture spells it.
   function Architecture_Name (Item : Architecture) return String
   is (case Item is
         when Llama     => "llama",
         when Qwen2     => "qwen2",
         when Qwen3     => "qwen3",
         when Qwen3_MoE => "qwen3moe",
         when Gemma     => "gemma",
         when Gemma2    => "gemma2",
         when Gemma3    => "gemma3",
         when Phi3      => "phi3",
         when Falcon    => "falcon",
         when Phi2      => "phi2",
         when GPT2      => "gpt2",
         when Bert      => "bert",
         when Nomic_Bert => "nomic-bert",
         when Jina_Bert_V2 => "jina-bert-v2");

   --  How a file says the states of a text should be reduced to one vector.
   --
   --  A bert file states this in `bert.pooling_type` and a decoder states
   --  nothing, which is what Pool_Unstated is for: absent and none are not
   --  the same answer, and a model that says none is a model whose states
   --  the caller is expected to pool for themselves.
   type Pooling_Choice is
     (Pool_Unstated, Pool_None, Pool_Mean, Pool_Cls, Pool_Last);

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

      --  Whether the model can turn a state into a distribution over tokens
      --  at all. False for Bert, which was trained to produce states and to
      --  stop there: it carries no output projection and ties none to its
      --  embedding table either.
      --
      --  A model without one is refused where a distribution is asked for,
      --  by name, rather than given a row of zeros or the embedding matrix
      --  read backwards. Both would be answers, and neither would be the
      --  model's.
      Has_Head        : Boolean := True;

      --  Whether a position may see only the positions before it. True for
      --  every architecture that generates, and false for Bert, which reads
      --  a whole text and lets every position see every other.
      --
      --  A field rather than a case on the architecture, because it is asked
      --  in the inner loop of both evaluators and in the shader, and because
      --  what it selects is a property of the model rather than of the name
      --  it goes by.
      Causal          : Boolean := True;

      --  How many segments the model learned a row for -- two, for the file
      --  that states them, and zero for a model with no segment embedding at
      --  all, which is every architecture here but Bert. Every position of a
      --  text embedded here belongs to segment zero: the second is what a
      --  sentence-pair task uses, and this program has no way to ask for one.
      Segments        : Natural := 0;

      --  What the file says its states should be pooled into a vector with,
      --  which is a thing a bert file states and a decoder does not. Read
      --  and reported rather than obeyed silently: a caller naming a pooling
      --  gets that one, and a caller naming none gets what the model was
      --  trained for instead of an average that may be nothing of the kind.
      Pooling         : Pooling_Choice := Pool_Unstated;

      --  How far back attention may look, in positions, counting the
      --  current one. Zero is no window at all: every committed position is
      --  visible, which is what a model without the key means.
      --
      --  A model with a window is not a model with a shorter context. The
      --  context is still the bound on how much may be held; the window is
      --  the bound on how much each position may see. Both are needed and
      --  they are not the same number.
      Window          : Natural := 0;

      --  Bounds on the attention scores and on the logits, as the scaled
      --  hyperbolic tangent the architecture states: a score of s becomes
      --  cap * tanh (s / cap), which leaves small values alone and holds
      --  large ones just under the cap. Zero for an architecture that
      --  states none, which is every one here but Gemma2.
      Attention_Cap   : Model_Runner.Numerics.Real := 0.0;
      Logit_Cap       : Model_Runner.Numerics.Real := 0.0;

      --  How steeply a head's attention falls off with distance, for a model
      --  that learned no positions at all and is told where a token is by
      --  the scores instead. A score between positions i and j has
      --  slope * |i - j| taken off it, after the scale by one over the root
      --  of the head width and before the softmax, where slope is per head
      --  and follows from this number and the head count.
      --
      --  Zero for every architecture that rotates or learns a row for the
      --  position, which is every one here but Jina_Bert_V2. That one states
      --  no such key and the other runtime carries eight for it, so it is
      --  written here rather than read.
      --
      --  Bidirectional, because the model is: the distance is unsigned, so a
      --  position falls off as steeply forwards as backwards. That is what
      --  makes it different from the one causal models use, where every
      --  visible position is behind and the sign never comes up.
      Max_Bias        : Model_Runner.Numerics.Real := 0.0;

      --  Whether the sliding window applies to every other layer rather
      --  than to all of them. Gemma2 alternates, starting with the window
      --  on layer zero.
      Alternating     : Boolean := False;

      --  How many layers in a row slide a window before one attends to
      --  everything. Zero for an architecture with no pattern, two for one
      --  that alternates, six for Gemma3's five-in-six.
      Window_Every    : Natural := 0;

      --  The base the windowed layers turn on, where it differs from the
      --  model's. Zero when every layer turns on the same one, which is
      --  every architecture here but Gemma3.
      Local_Base      : Wide_Real := 0.0;

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

   --  How a session stores the keys and values it has committed.
   --
   --  Exact keeps them as the engine computes them, which is the correctness
   --  baseline every published figure is taken against. Halved stores each
   --  one as binary16: two bytes an element instead of four, at the cost of
   --  eleven mantissa bits, which for a long context is the difference
   --  between a session that fits and one that does not. It is lossy and it
   --  is measured; the README says by how much.
   --  Eighth stores each element as one signed byte with a scale for the
   --  row it belongs to: a quarter of the bytes, and the coarsest thing this
   --  program does to a number it will read back. A row is one position's
   --  keys, or its values, for one layer -- which is the unit the evaluator
   --  already writes and reads whole, and the smallest unit that has a
   --  magnitude of its own to scale by.
   type Cache_Precision is (Exact, Halved, Eighth);

   --  The identifier a caller names a cache precision by.
   --
   --  @param Item Precision to name.
   --  @return Lower-case identifier such as "f16".
   function Cache_Name (Item : Cache_Precision) return String
   is (case Item is
         when Exact  => "f32",
         when Halved => "f16",
         when Eighth => "q8");

   --  How a matrix product multiplies.
   --
   --  Float_Activations widens every weight to binary32 and accumulates in
   --  binary64, which is what every figure published before this mode
   --  existed was measured against and what the reference backend does.
   --  Integer_Activations rounds the vector to one byte an element, with a
   --  scale for every thirty-two of them, and multiplies two integers into
   --  an exact block sum -- more accurate than the other within a block,
   --  since nothing there rounds, and less accurate across the vector,
   --  since the input was rounded once before it arrived.
   --
   --  Only the formats and widths that line up take the second: a weight
   --  format without an integer kernel, or a width that is not a whole
   --  number of blocks, is computed the first way whatever is asked for.
   type Arithmetic_Mode is (Float_Activations, Integer_Activations);

   --  The identifier a caller names an arithmetic by.
   --
   --  @param Item Arithmetic to name.
   --  @return Lower-case identifier, "f32" or "int8".
   function Arithmetic_Name (Item : Arithmetic_Mode) return String
   is (case Item is
         when Float_Activations   => "f32",
         when Integer_Activations => "int8");

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
   --  @param Fit_Required Whether a model whose matrices are larger than the
   --    backend's memory is refused. True refuses it, with both numbers in
   --    the message: such a model runs, by giving back the matrix wanted
   --    longest ago and uploading it again when it is next needed, but it
   --    runs slower than the processor would. False says the caller knows
   --    that -- because the caller set the budget -- and wants it anyway.
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
      Fit_Required : Boolean := True;
      Threads  : Positive := 1;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Merge a low-rank adapter into a prepared model's weights.
   --
   --  An adapter says what a fine-tune changed, as two small matrices per
   --  weight it touches: the product of the pair is the difference, and
   --  adding it makes the model the fine-tune produced. It is a merge and
   --  not a second set of weights carried alongside, so evaluation costs
   --  what it cost before and the adapter's own storage is released with the
   --  file it came from.
   --
   --  The model has to have been prepared with To_F32. A quantized weight is
   --  a block of packed bits with a scale, and adding an arbitrary
   --  difference to one means requantizing it, which is a different and
   --  lossier operation than this; refusing is honest where re-rounding
   --  every weight would be silent. To_BF16 is refused for the same reason,
   --  with eight mantissa bits rather than a block scale as the cause.
   --
   --  Refused while a session is open: what a session has already committed
   --  to its cache came from the weights as they were.
   --
   --  @param Item Prepared model, which the merge modifies.
   --  @param Source Parsed adapter container.
   --  @param Bytes Byte source the adapter's tensors live in.
   --  @param Scale What to multiply the difference by, over and above the
   --    adapter's own alpha and rank. One is the adapter as trained.
   --  @param Status Success, Lifecycle_Model_Not_Ready,
   --    Lifecycle_Session_Active, Arch_Unsupported_Feature when the model was
   --    not prepared as binary32, Arch_Missing_Tensor when a pair is
   --    incomplete, or Arch_Invalid_Tensor_Shape.
   procedure Merge_Adapter
     (Item   : in out Model;
      Source : Model_Runner.GGUF.Containers.Container;
      Bytes  : in out Model_Runner.Byte_Sources.Source'Class;
      Scale  : Real := 1.0;
      Status : out Model_Runner.Errors.Error_Info);

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

   --  The parts of an evaluation a budget attributes time to.
   --
   --  Coarse on purpose: these are the boundaries a caller can act on, and a
   --  finer division would measure the clock as much as the work. Attending
   --  is the one that grows with the context while the rest are linear in
   --  it, which is the whole reason a prompt's budget is not a token's --
   --  the token budget under `tests benchmark` models the linear parts and
   --  says in its own output that attention is not among them.
   type Phase is
     (Normalizing, Projecting, Rotating, Attending, Feeding, Joining,
      Reading_Out);

   --  How long each of them took, in one run.
   type Phase_Times is array (Phase) of Duration;

   --  Mutable evaluation state: the KV cache, the activation buffers and the
   --  committed position.
   type Session is tagged limited private;

   --  Ask a session to keep account of where its time goes, or to stop.
   --
   --  Off by default, and worth saying why it is a switch rather than
   --  always on: the clock is read at every boundary below, which is about a
   --  hundred and fifty reads for a batch of a hundred and ten and nothing
   --  beside the second that batch takes -- but a run nobody asked a budget
   --  of should not pay even that, and a timing that is always collected is
   --  a timing that eventually gets read by something that should not.
   --
   --  Turning it on clears what was there, so a caller measures the run it
   --  asked about rather than that run plus whatever came before.
   --
   --  @param Item Session to account for.
   --  @param Wanted True to keep account, False to stop.
   procedure Account (Item : in out Session; Wanted : Boolean);

   --  What each phase of this session's evaluations has taken.
   --
   --  Zero everywhere when nothing was accounted for, which is what a caller
   --  that never asked sees. The sum is less than a run's wall time and is
   --  meant to be: what is outside these phases is the caller's own work,
   --  the pool's rendezvous, and whatever the operating system did instead.
   --
   --  @param Item Session to read.
   --  @return The times, one per phase.
   function Time_Spent (Item : Session) return Phase_Times;

   --  Estimate the memory a session with the requested capacity would need.
   --
   --  Called before any session allocation, so an impossible request is
   --  rejected without touching the allocator.
   --
   --  @param Item Prepared model.
   --  @param Context Requested context capacity in tokens.
   --  @param Plan Estimate; Valid is False on overflow.
   --  @param Status Success or Memory_Plan_Overflow.
   --  @param Cache Precision the session would store its context in, which
   --    is half the bytes for Halved and the whole reason to ask.
   procedure Plan_Session
     (Item    : Model;
      Context : Natural;
      Plan    : out Model_Runner.Memory.Session_Plan;
      Status  : out Model_Runner.Errors.Error_Info;
      Cache   : Cache_Precision := Exact);

   --  Estimate session memory from a configuration alone.
   --
   --  @param Settings Validated configuration.
   --  @param Context Requested context capacity; 0 uses the model's own.
   --  @param Plan Estimate; Valid is False on overflow.
   --  @param Status Success or Memory_Plan_Overflow.
   --  @param Cache Precision the session would store its context in.
   procedure Plan_For
     (Settings : Configuration;
      Context  : Natural;
      Plan     : out Model_Runner.Memory.Session_Plan;
      Status   : out Model_Runner.Errors.Error_Info;
      Cache    : Cache_Precision := Exact);

   --  Open a session on a prepared model.
   --
   --  Several sessions may be open on one model at once; see the note at
   --  the top of this specification for what they do and do not share.
   --
   --  @param Item Session to open; closed first.
   --  @param Source Prepared model; must outlive the session.
   --  @param Context Context capacity in tokens; 0 uses the model's own.
   --  @param Session_Bounds Limits applied to the request.
   --  @param Workers Worker pool used for matrix-vector products, or null to
   --    compute them on the calling task. The pool must outlive the session.
   --    Results do not depend on the worker count.
   --  @param Cache How the session stores what it commits. Exact is the
   --    precision the engine computes in and the correctness baseline;
   --    Halved is binary16, which holds half the bytes and is lossy by a
   --    measured amount.
   --  @param Status Success, Lifecycle_Model_Not_Ready, Arch_Context_Too_Large
   --    or a memory diagnostic.
   procedure Open
     (Item           : in out Session;
      Source         : in out Model'Class;
      Context        : Natural := 0;
      Session_Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Workers        : Model_Runner.Backend.CPU.Pool_Reference := null;
      Cache          : Cache_Precision := Exact;
      Status         : out Model_Runner.Errors.Error_Info);

   --  The hidden state the last evaluated position left behind.
   --
   --  This is what the model has made of everything it has read, after the
   --  final normalization and before the output projection turns it into a
   --  distribution over tokens. It is the vector an embedding is pooled
   --  from: two texts that mean the same thing leave similar ones, which the
   --  logits do not show, because the projection throws away everything
   --  except how much each token is favoured.
   --
   --  Refused before anything has been evaluated: there is no state to
   --  report then, and reporting the buffer as it happens to stand would be
   --  reporting zeros as though they meant something.
   --
   --  @param Item Session that has evaluated at least one token.
   --  @param Target Receives the state; must be Embedding elements long.
   --  @param Status Success, Lifecycle_Invalid_State when nothing has been
   --    evaluated, or Tensor_Shape_Mismatch.
   procedure Hidden_State
     (Item   : Session;
      Target : out Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  How this session stores its keys and values.
   --
   --  @param Item Session to inspect.
   --  @return The precision it was opened with.
   function Precision (Item : Session) return Cache_Precision;

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
   --
   --  Five hundred and twelve, which is where the device measures fastest
   --  and is what llama.cpp uses for the same job. A batch is one pass over
   --  the weights, so a 1419-token prompt is three passes here where a
   --  batch of a hundred and twenty-eight made twelve; the weights are
   --  nineteen per cent of a device prompt and this is most of what that
   --  buys. Above five hundred and twelve it goes back: 1.027 s at a
   --  thousand and twenty-four against 0.987 at five hundred and twelve,
   --  which is the activations of a batch outgrowing something they were
   --  fitting in.
   --
   --  What it costs is that working set: five hundred and twelve positions
   --  of the widest vector a layer holds, which for this model is the
   --  5632-wide feed-forward and eleven megabytes.
   Max_Batch : constant := 512;

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
   --  @param States Receives the hidden state of every position of the
   --    batch, Embedding elements each, or null to keep only the last
   --    position's. Only a caller pooling over the positions of a text
   --    wants them, and only that caller should pay for writing them out.
   --  @param Every Receives the logits of every position of the batch,
   --    Vocabulary elements each, or null for only the last position's.
   --    What this costs is the output projection once per position, which
   --    is the largest matrix in the model: a caller that does not need
   --    them should not ask. A caller checking what another model proposed
   --    does need them, because the answer at each position is the whole
   --    question.
   procedure Evaluate_Batch
     (Item   : in out Session;
      Source : Model'Class;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      Logits : out Real_Array;
      States : Model_Runner.Tensors.Real_Array_Access := null;
      Every  : Model_Runner.Tensors.Real_Array_Access := null;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out Model_Runner.Errors.Error_Info);

   --  What a session has committed, as bytes.
   --
   --  A prompt costs what it costs to read: on this machine a thousand
   --  tokens is tens of seconds of prefill, where its cache is tens of
   --  megabytes. Keeping that and handing it back next time is the
   --  difference between waiting for the model to re-read a document and
   --  not.
   --
   --  Only the committed positions are written, not the capacity: a session
   --  with room for two thousand tokens and fifty in it produces fifty. The
   --  bytes name the model they belong to, the shape of the cache and the
   --  precision it is held in, and Adopt refuses anything that does not
   --  match rather than reading one model's attention into another's.
   --
   --  Bytes rather than a file, because this package interprets what a
   --  model says and units that do that may not reach the filesystem. Where
   --  the bytes go is the caller's business.
   --
   --  @param Item Session to write out.
   --  @param Source Model it was opened on.
   --  @param Into Newly allocated bytes; the caller frees them. Null on
   --    failure.
   --  @param Status Success, Lifecycle_Invalid_State, or
   --    Memory_Allocation_Failed.
   procedure Snapshot
     (Item   : Session;
      Source : Model'Class;
      Into   : out Model_Runner.Bytes.Byte_Array_Access;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read a snapshot back into an open session.
   --
   --  The session is reset first, so a failure leaves nothing of either the
   --  old contents or the new: a session half filled would be a
   --  conversation that never happened.
   --
   --  A snapshot is untrusted input. Every field is range checked against
   --  the model and the session it is being read into, and any mismatch is
   --  refused. What cannot be checked is whether the contents mean
   --  anything: bytes that match the model and the shape are read, and what
   --  they say the model was thinking is what the model will think.
   --  Adopting a file is trusting whoever wrote it with the conversation.
   --
   --  @param Item Open session to fill.
   --  @param Source Model it was opened on.
   --  @param From Bytes a Snapshot produced.
   --  @param Status Success, Lifecycle_Cache_Unreadable or
   --    Lifecycle_Cache_Mismatched.
   procedure Adopt
     (Item   : in out Session;
      Source : Model'Class;
      From   : Model_Runner.Bytes.Byte_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  A number identifying the model a saved session belongs to.
   --
   --  It is the validated shape -- every width, count and identifier the
   --  cache's layout depends on -- together with the size of the tensor
   --  data and a sample of its bytes. That identifies a model file; it does
   --  not verify one, and it is not meant to. Two files that agree on all
   --  of it are the same model for the purposes of a cache.
   --
   --  @param Item Prepared model.
   --  @return The fingerprint, or zero before preparation.
   function Fingerprint (Item : Model) return Interfaces.Unsigned_64;

   --  Whether this model's weights are the file's own pages.
   --
   --  True when the model was prepared from a mapped source and nothing was
   --  copied: the weights cost address space rather than memory, and are
   --  read as they are touched. False when they were read into an arena,
   --  which is what a source that cannot be mapped, or a device that wants
   --  the host's own pointer, leads to.
   --
   --  @param Item Prepared model.
   --  @return True when the weights are borrowed rather than held.
   function Weights_Mapped (Item : Model) return Boolean;

   --  Drop the oldest positions and slide the rest down.
   --
   --  What it is for is a context that has filled. A run that stops there
   --  has stopped for want of room rather than for want of anything to say,
   --  and the usual answer is to forget the beginning of the conversation:
   --  the first Keep positions stay -- a beginning-of-text marker and
   --  whatever else the caller must not lose -- the Drop after them go, and
   --  everything later moves down to close the gap.
   --
   --  The keys move with it. A key was rotated for the position it was
   --  written at, and its new position is Drop earlier, so each moved key is
   --  turned back by the angle Drop stands for. Values carry no position and
   --  are copied as they are. Without that turn the cache would describe
   --  positions the text no longer has, and the model would attend to a
   --  conversation whose words had moved but whose places had not -- which
   --  produces fluent text about nothing in particular, and no error.
   --
   --  What this loses is more than what it drops, and the difference is
   --  worth stating. The keys and values that stay were computed while the
   --  dropped tokens were still there: every one of them is the model's
   --  reading of its position in a context that included them. Moving them
   --  down renumbers their positions; it does not recompute them. So a
   --  shifted context is not the context the same remaining tokens would
   --  have produced on their own, and this is an approximation rather than
   --  an equivalence -- a good one in practice, which is why every runtime
   --  that offers a rolling context offers this one, and still an
   --  approximation.
   --
   --  The alternative is to re-read the retained tokens, which is exact and
   --  costs a prefill. Nothing here does that automatically either: which
   --  of the two a caller wants depends on what the run is for, and both
   --  are the caller's to choose.
   --
   --  @param Item Session to shift.
   --  @param Source The model it was opened on, for the rotation the keys
   --    have to be turned back by.
   --  @param Keep How many positions at the front to leave in place.
   --  @param Drop How many to remove after those.
   --  @param Status Success, Lifecycle_Invalid_State when the session is not
   --    open, or Tensor_Shape_Mismatch when Keep and Drop do not fit inside
   --    what is committed.
   procedure Shift
     (Item   : in out Session;
      Source : Model'Class;
      Keep   : Natural;
      Drop   : Positive;
      Status : out Model_Runner.Errors.Error_Info);

   --  Give back the last few committed positions.
   --
   --  What it is for is checking: a caller that evaluated several tokens on
   --  the strength of a guess, and found the guess wrong partway, has to put
   --  the context back to where the guess stopped being right. Everything
   --  after Position becomes uncommitted and is overwritten by whatever is
   --  evaluated next; nothing is released and nothing is cleared, because a
   --  position that is not committed is never read.
   --
   --  Going forward is not rewinding and is refused: the positions between
   --  where a session is and where it would be have no keys and no values,
   --  and a session that claimed them would attend to arithmetic nobody did.
   --
   --  @param Item Session to rewind.
   --  @param Position Committed position to go back to, at most the current
   --    one.
   --  @param Status Success, Lifecycle_Invalid_State when the session is not
   --    open, or Tensor_Shape_Mismatch when the position is ahead of it.
   procedure Rewind
     (Item     : in out Session;
      Position : Natural;
      Status   : out Model_Runner.Errors.Error_Info);

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

      --  Applied to what a sublayer produced, before it is added back to
      --  the residual, rather than to what it was given. Null for an
      --  architecture that normalizes only on the way in, which is every
      --  one here but Gemma2.
      Post_Attention_Norm : Model_Runner.Tensors.Real_Array_Access;
      Post_Feed_Norm      : Model_Runner.Tensors.Real_Array_Access;

      --  The shift beside each of those gains, for the architecture whose
      --  normalization centres as well as scaling. Null for Gemma2 and
      --  Gemma3, whose post-normalizations are by root mean square and
      --  carry no bias, and null for every architecture that has no post-
      --  normalization at all.
      Post_Attention_Norm_Bias : Model_Runner.Tensors.Real_Array_Access;
      Post_Feed_Norm_Bias      : Model_Runner.Tensors.Real_Array_Access;

      --  The bias its normalization carries, for an architecture that
      --  centres rather than scaling. Null for every architecture that
      --  normalizes by root mean square, which is all of them but Falcon
      --  and Phi2.
      Attention_Norm_Bias : Model_Runner.Tensors.Real_Array_Access;
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

      --  Added to what a projection produced, for an architecture that
      --  biases every projection rather than only the three that make the
      --  queries, keys and values. Null everywhere but Phi2, which is the
      --  first architecture here to carry one on the way out of attention
      --  and on both sides of the feed-forward.
      Out_Bias       : Model_Runner.Tensors.Real_Array_Access;
      Up_Bias        : Model_Runner.Tensors.Real_Array_Access;
      Down_Bias      : Model_Runner.Tensors.Real_Array_Access;
      Feed_Norm      : Model_Runner.Tensors.Real_Array_Access;

      --  The shift beside that gain, for the architectures whose
      --  normalization is a centred one. Null everywhere else, and null for
      --  a centred architecture whose two sublayers run in parallel, which
      --  has no separate feed normalization to bias.
      Feed_Norm_Bias : Model_Runner.Tensors.Real_Array_Access;
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
      --  The model's weights, and where in the file they begin.
      --
      --  Arena is the copy, and is null when there is none: a source that
      --  can say where its bytes already are is read where they lie, which
      --  for a mapped file means the weights are the file's own pages --
      --  never copied, never counted as this program's memory, and faulted
      --  in as they are touched rather than all at once. Weights_Base and
      --  Weights_Span describe whichever of the two it turned out to be, and
      --  everything downstream reads only those.
      Arena       : Model_Runner.Bytes.Byte_Array_Access := null;
      Arena_Base  : Model_Runner.Bytes.Byte_Count := 0;
      Weights_Base : System.Address := System.Null_Address;
      Weights_Span : Model_Runner.Bytes.Byte_Count := 0;
      Weights_Held : Boolean := False;

      --  The decoded copy of the weight matrices, when one was asked for.
      --  Every matrix view then refers into this instead of into the file's
      --  own bytes, and the file's arena stays mapped for whatever was not
      --  repacked.
      Repacked    : Model_Runner.Bytes.Byte_Array_Access := null;
      Layers      : Layer_Array_Access := null;
      Embeddings  : aliased Model_Runner.Tensors.View;

      --  One row a position, added to the token's row before the first
      --  layer. GPT2 learns where a token is instead of rotating for it, so
      --  this is the whole of its position handling and there is no rotation
      --  anywhere in the model. Absent -- and never read -- for every
      --  architecture that rotates.
      Positions   : aliased Model_Runner.Tensors.View;

      --  One row a segment, added beside the token's row and the position's.
      --  Bert learned two and this program uses the first for every position
      --  of a text; a model with no segment embedding never reads this.
      Segments    : aliased Model_Runner.Tensors.View;

      --  The normalization over the sum of those three rows, before the
      --  first layer sees it. Bert normalizes what it embedded; every other
      --  architecture here hands the embedding row to layer zero as it is,
      --  or scales it by a constant, and reads this nowhere.
      Embedding_Norm      : Model_Runner.Tensors.Real_Array_Access;
      Embedding_Norm_Bias : Model_Runner.Tensors.Real_Array_Access;
      Output      : aliased Model_Runner.Tensors.View;
      Output_Norm : Model_Runner.Tensors.Real_Array_Access;

      --  And the bias for it, for the same reason and the same architecture.
      Output_Norm_Bias : Model_Runner.Tensors.Real_Array_Access;

      --  Added to every logit, for an architecture whose output projection
      --  carries a bias. Null everywhere but Phi2. It is the last thing the
      --  model does, so leaving it out shifts every logit by a fixed amount
      --  and changes which token is chosen wherever two were close.
      Output_Bias : Model_Runner.Tensors.Real_Array_Access;

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

      --  How the weights were written into Repacked, when they were. A
      --  merge needs to know, because it may only add to binary32.
      Packing     : Repack_Mode := No_Repack;

      --  What has been merged into those weights, as a digest of every
      --  adapter and the scale it was applied at. Zero for a model as its
      --  file describes it.
      --
      --  It is part of what identifies the model because a merge replaces
      --  the weights: a context computed before one describes attention the
      --  merged model never had, and the two would otherwise be
      --  indistinguishable to anything reading a saved context.
      Adapted     : Interfaces.Unsigned_64 := 0;
   end record;

   overriding procedure Finalize (Item : in out Model);

   type Token_History is array (Natural range <>) of Token_Id;
   type Token_History_Access is access Token_History;

   type Session is limited new Ada.Finalization.Limited_Controlled with record
      --  The token for the call in progress, or null between calls.
      --
      --  Held here rather than passed, and that is a deliberate choice with
      --  a cost. Every product in this engine goes through two procedures,
      --  and those two have twenty callers; threading a parameter to all of
      --  them would put the token where a reader expects it and would also
      --  be twenty places to miss one, silently, in a program where missing
      --  one means a run that cannot be stopped. Set at the top of the two
      --  entry points that take a token and cleared when they return.
      --
      --  Only the device reads it. The other backends are interruptible
      --  between layers, which is where this engine checks; a device is
      --  interruptible between slices of the wait for it, which is inside
      --  one layer and needs the token down there.
      Stopping : Model_Runner.Cancellation.Token_Reference := null;

      --  What this session holds, by category. The plan computes every one
      --  of these before anything is allocated; recording them is what makes
      --  a memory report say where the memory went, and what lets a limit
      --  count the largest thing a session has.
      Accounting : Model_Runner.Memory.Account;

      Current    : Session_State := Closed;
      Owner      : access Model'Class := null;
      Context    : Natural := 0;
      Committed  : Natural := 0;
      --  The committed keys and values, in one precision or the other.
      --  Exactly one pair is allocated; the other stays null, which is what
      --  the reads below test rather than carrying a converted copy.
      Held       : Cache_Precision := Exact;
      Keys       : Model_Runner.Tensors.Real_Array_Access := null;
      Values     : Model_Runner.Tensors.Real_Array_Access := null;
      Half_Keys  : Model_Runner.Tensors.Half_Array_Access := null;
      Half_Values : Model_Runner.Tensors.Half_Array_Access := null;

      --  And the third storage: one byte an element, with one scale for
      --  every row. The bytes hold a signed value biased by 128, so that a
      --  cache written by this build is bytes rather than a signed type the
      --  file format would have to name.
      Byte_Keys    : Model_Runner.Bytes.Byte_Array_Access := null;
      Byte_Values  : Model_Runner.Bytes.Byte_Array_Access := null;
      Key_Scales   : Model_Runner.Tensors.Real_Array_Access := null;
      Value_Scales : Model_Runner.Tensors.Real_Array_Access := null;
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

      --  How far apart the score rows of two heads are. One row a head
      --  rather than one for all of them, so that a share of the heads can
      --  be blended beside another share; a head's scores are written,
      --  softmaxed and read back inside its own iteration, and two heads
      --  sharing a row is two heads answering with each other's arithmetic.
      Score_Room : Model_Runner.Numerics.Element_Count := 0;

      --  Where this session's time went, and whether to keep asking.
      Spent      : Phase_Times := [others => 0.0];
      Budgeting  : Boolean := False;

      Gate       : Model_Runner.Tensors.Real_Array_Access := null;
      Up         : Model_Runner.Tensors.Real_Array_Access := null;

      --  What a mixture of experts needs beyond the dense block: the
      --  router's scores, the sum being accumulated over the chosen experts,
      --  and the one expert's output being added into it. All three are null
      --  for a dense model, which allocates none of them.
      Routing    : Model_Runner.Tensors.Real_Array_Access := null;
      Mixture    : Model_Runner.Tensors.Real_Array_Access := null;

      --  Room for a normalization that happens on the way out of a
      --  sublayer, which needs a buffer as wide as the embedding and cannot
      --  borrow one that is holding something: the query buffer was tried
      --  and is a head's width, so it was too small and the pass failed as
      --  an invariant violation rather than as anything a reader could act
      --  on. Allocated only for an architecture that normalizes that way.
      Post_Room  : Model_Runner.Tensors.Real_Array_Access := null;
      Expert_Row : Model_Runner.Tensors.Real_Array_Access := null;
      Plan       : Model_Runner.Memory.Session_Plan;
      Team       : Model_Runner.Backend.CPU.Pool_Reference := null;
      Logit_Row  : Model_Runner.Tensors.Real_Array_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Session);

end Model_Runner.Llama;
