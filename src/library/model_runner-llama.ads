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
with Model_Runner.Shares;
with Model_Runner.Progress;
with Model_Runner.Templates;
with Model_Runner.Tensors;
with Model_Runner.Text;
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
     (Llama, Qwen2, Qwen3, Qwen3_MoE, GPT_OSS, Gemma, Gemma2, Gemma3, Phi3,
      Falcon, Phi2, GPT2, Bert, Nomic_Bert, Jina_Bert_V2,
      Qwen35, Qwen35_MoE);

   --  Whether an architecture mixes linear attention -- a gated delta
   --  rule over a recurrent state -- into its stack, one full attention
   --  layer in every few. Qwen3.5 and Qwen3.6 do: three of every four
   --  layers keep no keys and values at all, only a state a position
   --  updates and a few positions' worth of projections for a short
   --  convolution. Named once because it decides what a session holds
   --  for a layer, what a position writes, and what a rewind can undo.
   --
   --  @param Item Architecture to ask about.
   --  @return True where some layers are linear rather than attending.
   function Hybrid (Item : Architecture) return Boolean
   is (Item in Qwen35 | Qwen35_MoE);

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
         when GPT_OSS   => "gpt-oss",
         when Gemma     => "gemma",
         when Gemma2    => "gemma2",
         when Gemma3    => "gemma3",
         when Phi3      => "phi3",
         when Falcon    => "falcon",
         when Phi2      => "phi2",
         when GPT2      => "gpt2",
         when Bert      => "bert",
         when Nomic_Bert => "nomic-bert",
         when Jina_Bert_V2 => "jina-bert-v2",
         when Qwen35     => "qwen35",
         when Qwen35_MoE => "qwen35moe");

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

      --  Whether that stretch was asked for rather than read.
      --
      --  It decides one thing: a model stretched by request may be opened
      --  at a context longer than the one it was trained on, and a model
      --  that was not may not. A file that states its own stretch has
      --  already stated the context that stretch reaches, so the two cases
      --  cannot be told apart by the stretch alone.
      Stretched       : Boolean := False;

      --  The context the file states, kept when a request raises the one a
      --  session may ask for, so that a report can say both.
      Trained_Context : Natural := 0;
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

      --  The gate unit's two bounds, for an architecture that clamps it.
      --
      --  GPT_OSS does not use the plain sigmoid-weighted gate every other
      --  architecture here does. Its gate is held at a limit before the
      --  logistic, its up projection is held to the same limit either side
      --  of nought, and the logistic is taken at a steeper slope:
      --
      --     x = min (gate, limit)
      --     y = max (-limit, min (up, limit))
      --     out = x / (1 + exp (-alpha * x)) * (y + 1)
      --
      --  The one is added because this architecture's up projection is
      --  centred on nought rather than on one. Alpha of zero means the
      --  plain gate, which is every other architecture here.
      Gate_Alpha      : Model_Runner.Numerics.Real := 0.0;
      Gate_Limit      : Model_Runner.Numerics.Real := 0.0;

      --  Width of one expert's feed-forward block. A mixture-of-experts file
      --  may state this separately from feed_forward_length, because the two
      --  are different numbers: one expert is narrower than the dense block
      --  the model would have had. Equal to Feed_Forward when the file does
      --  not say, and unused by a dense model.
      Expert_Feed     : Natural := 0;

      --  The hybrid architectures' shape, all nought for the rest.
      --
      --  Every Linear_Every-th layer attends in full and the others are
      --  linear: a state of State_Size by State_Size a value head, updated
      --  by the gated delta rule from queries and keys over Key_Heads
      --  heads and values over Value_Heads, each State_Size wide, after
      --  a causal convolution Conv_Kernel positions long over the three
      --  projections at once. A full attention layer's query projection
      --  carries a gate beside each head, which scales the head's blend
      --  through a sigmoid. Shared_Feed is the width of the one expert
      --  every position of a mixture also goes through, gated by a
      --  sigmoid of its own; Next_Layers how many blocks past the stack
      --  the file carries for predicting the token after the next, which
      --  the stack itself never runs.
      Linear_Every    : Natural := 0;
      Key_Heads       : Natural := 0;
      Value_Heads     : Natural := 0;
      State_Size      : Natural := 0;
      Conv_Kernel     : Natural := 0;
      Shared_Feed     : Natural := 0;
      Next_Layers     : Natural := 0;
   end record;

   --  Whether a layer of a hybrid architecture is a linear one. The
   --  full attention layers are every Linear_Every-th, counting from one,
   --  as the file counts them; an architecture with no interval has none.
   --
   --  @param Settings The model's configuration.
   --  @param Layer Layer index, counting from nought.
   --  @return True where the layer keeps a state rather than a cache.
   function Linear (Settings : Configuration; Layer : Natural) return Boolean
   is (Settings.Linear_Every > 0
       and then (Layer + 1) mod Settings.Linear_Every /= 0);

   --  Widths the linear layers' projections have: the queries and keys
   --  together, the values, and the three at once, which is what the
   --  convolution runs over.
   --
   --  @param Settings The model's configuration.
   --  @return Key heads times the state size.
   function Key_Width (Settings : Configuration) return Natural
   is (Settings.Key_Heads * Settings.State_Size);

   --  @param Settings The model's configuration.
   --  @return Value heads times the state size.
   function Value_Width (Settings : Configuration) return Natural
   is (Settings.Value_Heads * Settings.State_Size);

   --  @param Settings The model's configuration.
   --  @return Twice the key width and the value width.
   function Mix_Width (Settings : Configuration) return Natural
   is (2 * Key_Width (Settings) + Value_Width (Settings));

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
   --  For models whose own template this build will not compile, or whose
   --  caller wants another. The source is compiled and validated exactly as
   --  an embedded one is, so an unusable replacement is refused rather than
   --  stored.
   --
   --  @param Item Prepared model.
   --  @param Source Template source.
   --  @param Bounds Limits applied while compiling.
   --  @param Status Success, or why the source was refused.
   --  @param Name The carried format the source is, when it is one, so that
   --    Template_Format answers it. Empty for a source that is not.
   procedure Use_Template
     (Item   : in out Model;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits;
      Status : out Model_Runner.Errors.Error_Info;
      Name   : String := "");

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
   --
   --  To_Rows is not that kind of copy at all. It decodes nothing: the
   --  four-bit k-quant's weight matrices are written out again in the same
   --  bytes, eight rows interleaved, so that a lane of the product's
   --  accumulator is a row rather than an eighth of one. The copy is the
   --  same size as what it copies, nothing is rounded, and every other
   --  format in the file is left where it lies. What it is for is the
   --  kernel it lets a prompt take -- eight rows against eight vectors,
   --  where the row-major layout allows eight against four -- and
   --  Model_Runner.Quantization.Interleave describes the arrangement.
   --
   --  It is the one repacking mode that says nothing about the numbers and
   --  everything about their order, which is why it is a mode here rather
   --  than a thing done to every model that could take it: it costs a
   --  second copy of the weights, and a caller who cannot spare that should
   --  not have it forced on them.
   type Repack_Mode is (No_Repack, To_F32, To_BF16, To_Rows);

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
   --
   --  Mixed_Activations is the second everywhere but the attention
   --  projections, which take the first. What that is for: the rounding's
   --  error is tolerable in either the attention or the feed-forward of a
   --  block and not, compounded, in both -- Gemma 2 answers three tool
   --  tasks of ten with everything rounded, seven with nothing, and eight
   --  with its attention left whole -- and the attention projections are
   --  a tenth of the weight, so nearly all of the speed stays. Chosen by
   --  the role a weight plays, which the model reads from its name.
   type Arithmetic_Mode is
     (Float_Activations, Integer_Activations, Mixed_Activations);

   --  The identifier a caller names an arithmetic by.
   --
   --  @param Item Arithmetic to name.
   --  @return Lower-case identifier: "f32", "int8" or "mixed".
   function Arithmetic_Name (Item : Arithmetic_Mode) return String
   is (case Item is
         when Float_Activations   => "f32",
         when Integer_Activations => "int8",
         when Mixed_Activations   => "mixed");

   --  Which roles of weight an arithmetic quantizes the activations of.
   --
   --  @param Item Arithmetic to ask about.
   --  @return The roles that round, for Backend.CPU to be told.
   function Quantized_Roles
     (Item : Arithmetic_Mode) return Model_Runner.Backend.CPU.Role_Set
   is (case Item is
         when Float_Activations   => Model_Runner.Backend.CPU.No_Role,
         when Integer_Activations => Model_Runner.Backend.CPU.Every_Role,
         when Mixed_Activations   =>
           [Model_Runner.Tensors.Role_Attention => False, others => True]);

   --  The word a caller types for a repacking mode.
   --
   --  @param Item Mode to name.
   --  @return Lower-case identifier such as "bf16".
   function Repack_Name (Item : Repack_Mode) return String
   is (case Item is
         when No_Repack => "none",
         when To_F32    => "f32",
         when To_BF16   => "bf16",
         when To_Rows   => "rows");
   --  What a caller asks of the rotation, over what the file states.
   --
   --  A model is trained at one context length and its rotation is written
   --  for that length. Stretching the rotation -- turning by a smaller angle
   --  a position, so that more positions fit in the same span of angles --
   --  is what lets it be run past that length, and it is a decision the
   --  person running the model gets to make: a file written by an author
   --  who did not stretch it can still be stretched by whoever runs it.
   --
   --  Everything the stretch needs is read from the file already. This is
   --  the same set of numbers, asked for rather than read, and each is
   --  applied only where the caller named it -- so asking for a factor and
   --  nothing else takes the file's own band and attenuation with it.
   --
   --  Unasked means the file decides, which is what every caller before
   --  this meant and what the default is.
   type Rotary_Request_Kind is
     (Unasked, As_Trained, Linear_Stretch, Yarn_Stretch);

   --  @field Kind Which stretch, or Unasked to leave the file to decide.
   --  @field Factor What the rotation is stretched by, as a person states
   --    it: two is twice the context. Zero is unasked.
   --  @field Base The angle the first pair turns by, which every other pair
   --    is derived from. Zero is unasked.
   --  @field Original The context the model was trained on, which Yarn
   --    derives its ramp from. Zero is unasked.
   --  @field Beta_Fast The fast end of the band Yarn mixes across. Zero is
   --    unasked.
   --  @field Beta_Slow The slow end of it. Zero is unasked.
   --  @field Attenuation What Yarn attenuates the whole rotation by. Zero
   --    is unasked.
   type Rotary_Request is record
      Kind : Rotary_Request_Kind := Unasked;

      --  What the rotation is stretched by, as a person states it: two is
      --  twice the context. Zero is unasked. The kernels hold its
      --  reciprocal, which is what the file states and what the arithmetic
      --  wants, and the conversion is done once here rather than in every
      --  caller.
      Factor : Model_Runner.Numerics.Wide_Real := 0.0;

      --  The angle the first pair turns by, which every other pair is
      --  derived from. Zero is unasked.
      Base : Model_Runner.Numerics.Wide_Real := 0.0;

      --  What Yarn derives its ramp from: the context the model was
      --  trained on, the band it interpolates across, and the attenuation
      --  it puts on the whole. Zero is unasked for each of them.
      Original    : Natural := 0;
      Beta_Fast   : Model_Runner.Numerics.Wide_Real := 0.0;
      Beta_Slow   : Model_Runner.Numerics.Wide_Real := 0.0;
      Attenuation : Model_Runner.Numerics.Wide_Real := 0.0;
   end record;

   --  Nothing asked, which is what a caller who names none of these means.
   No_Rotary_Request : constant Rotary_Request := (others => <>);

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
   --  @param Stretch What the caller asks of the rotation, over what the
   --    file states. A model stretched by request may then be opened at a
   --    context longer than the one it was trained on; a model that was not
   --    may not, which is the rule as it was.
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
      Status   : out Model_Runner.Errors.Error_Info;
      Stretch  : Rotary_Request := No_Rotary_Request);

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

   --  The carried chat format the model renders with, when it is one.
   --
   --  Set by Use_Template when the caller named one, and by Prepare when
   --  the model's own template would not compile but its text is written
   --  in a format this build carries -- that format then stands in, and
   --  Template_Stood_In says so. A caller reads tool calls in the shape
   --  this format writes them: Templates.Syntax_Of.
   --
   --  @param Item Prepared model.
   --  @return Format name as Templates.Format_Name gives it, or the empty
   --    string when the model renders with its own template.
   function Template_Format (Item : Model) return String;

   --  Whether a carried format was chosen for the model rather than named.
   --
   --  True when Prepare recognised the model's own template, which would
   --  not compile, as a carried format and compiled that instead. A caller
   --  who wants to say so to a reader asks here; one who names a format
   --  through Use_Template afterwards resets it.
   --
   --  @param Item Prepared model.
   --  @return True when Template_Format was recognised, not named.
   function Template_Stood_In (Item : Model) return Boolean;

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
   --
   --  Fusing is the one that is not a part of a layer but the whole of one.
   --  Where a layer goes over to a device as a single sequence, nothing
   --  between the normalization at its front and the join at its back comes
   --  back to the host, so the host has one clock reading for the lot and
   --  no way to divide it. It used to be charged to Attending, which made
   --  the budget report attending as the largest cost on the device when an
   --  ablation of attention.comp says attention is a thirtieth of that.
   --  A phase that cannot be measured is named rather than guessed at.
   type Phase is
     (Normalizing, Projecting, Rotating, Attending, Feeding, Joining,
      Fusing, Reading_Out);

   --  How long each of them took, in one run.
   type Phase_Times is array (Phase) of Duration;

   --  Mutable evaluation state: the KV cache, the activation buffers and the
   --  committed position.
   type Session is tagged limited private;

   --  A session named rather than passed, so that a round can hold several.
   type Session_Access is access all Session;

   --  The sessions a round's rows belong to after the first, which is the
   --  one the call is made on. Empty is a batch: one session's own
   --  consecutive positions, which is what evaluation has always been.
   type Session_Group is array (Positive range <>) of Session_Access;

   --  No others, which is every call that is not a round.
   Alone : constant Session_Group (1 .. 0) := [others => null];

   --  How many rows each member of a round contributes, in the members'
   --  order.
   --
   --  One apiece is a decode round: every member says its next token and the
   --  pass produces one apiece. More than one is a member reading a prompt,
   --  and the two mix -- a member joining with a hundred tokens to read and
   --  seven members carrying on with one each is a round of a hundred and
   --  seven rows, which costs one pass over the weights rather than two.
   --
   --  A row is a member and a position and nothing else, so nothing in an
   --  evaluation cares which of the two kinds it is.
   type Row_Counts is array (Positive range <>) of Positive;

   --  One row a member, which is what a decode round asks for and what an
   --  empty share list means.
   Even_Shares : constant Row_Counts (1 .. 0) := [others => 1];

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

   --  The session's worker pool, as something that can be handed to a
   --  package that must not know what a pool is.
   --
   --  Sampling is the caller this exists for. It walks the vocabulary twice
   --  a token -- once for logits that are not numbers and once for the
   --  highest -- and both walks ran on the task that had just finished
   --  waiting for five, which the budget in the README puts at a quarter of
   --  a millisecond of a fifteen-millisecond token. It may not depend on a
   --  backend, so it takes a Model_Runner.Shares.Team instead and this is
   --  where the engine's own pool becomes one.
   --
   --  Null where the session runs on no pool, which is what a null team
   --  means everywhere: the caller does the work itself.
   --
   --  @param Item Session to read.
   --  @return A team, or null.
   function Sharing (Item : Session) return Model_Runner.Shares.Team_Access;

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

   --  The lowest position this session may be rewound to and still answer.
   --
   --  Zero for a session whose layers hold everything, which is every model
   --  that does not slide a window and every windowed one that has not
   --  filled a layer yet. A layer that has slid holds the newest positions
   --  and no others, so a rewind past what it holds leaves it unable to
   --  attend: the keys the window wants are the ones the slide dropped.
   --
   --  What a caller does with this is decide, and the two answers are both
   --  reasonable: rewind no further than this, or clear the context and
   --  read the whole thing again. This exists because the alternative is
   --  discovering the bound by getting a wrong answer -- llama.cpp met the
   --  same wall from the other side and answered it with `--swa-full`,
   --  which gives the memory back to keep the rewinding.
   --
   --  @param Item Session to inspect.
   --  @return The lowest safe position, or zero when any is safe.
   function Reusable_From (Item : Session) return Natural;

   --  Something told what every matrix product was given.
   --
   --  An importance matrix is a record of how much each input channel of
   --  each weight matrix actually carried over a corpus, and the only place
   --  that can be known is inside the engine, at the moment a product is
   --  about to happen. This is the seam: a session may be handed one of
   --  these, and it will be told the name of every weight matrix it
   --  multiplies by and the vectors it multiplies.
   --
   --  Nothing here computes anything with it. What a caller does with the
   --  vectors -- sum their squares, count them, write a file -- is the
   --  caller's, which is why this is an interface and not a switch: the
   --  engine's part is knowing which matrix it is about to read, and that is
   --  the part only the engine knows.
   --
   --  IT COSTS A NULL CHECK A PRODUCT when nothing is watching, which is
   --  every run that is not collecting a matrix.
   type Watcher is limited interface;

   --  One matrix product, before it happens.
   --
   --  @param Item The watcher.
   --  @param Which The weight matrix's name, as the file names it.
   --  @param Values The vectors about to be multiplied by it, laid out a
   --    row at a time.
   --  @param Rows How many vectors Values holds.
   procedure Note
     (Item   : in out Watcher;
      Which  : String;
      Values : Real_Array;
      Rows   : Element_Count) is abstract;

   type Watcher_Access is access all Watcher'Class;

   --  Have a session report every product to a watcher.
   --
   --  @param Item Session to watch.
   --  @param By The watcher, or null to stop.
   procedure Watch (Item : in out Session; By : Watcher_Access);

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

   --  Rows given in place of embeddings, for the positions of a batch that
   --  hold one token: a picture's rows behind its marker.
   type Given_Rows is record
      Token : Model_Runner.Tokenizer.Token_Id := Model_Runner.Tokenizer.No_Token;
      Rows  : Model_Runner.Tensors.Real_Array_Access := null;
      First : Model_Runner.Numerics.Element_Count := 0;
   end record;

   No_Given_Rows : constant Given_Rows := (others => <>);

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
   --  @param Beside The sessions rows one and up belong to, where this is a
   --    round of several sequences rather than a batch of one sequence's
   --    positions. Empty for a batch. Every row of the pass -- the
   --    normalizations, the rotation, the gated middle, the joins -- was
   --    already a row at a time, and the products were already over the
   --    whole batch. See docs/serving-several-sequences.md.
   --  @param Shares How many rows each member of a round contributes, in
   --    the members' order, or empty for one apiece. A member reading a
   --    prompt contributes its length and a member carrying on contributes
   --    one, and the two travel in the same pass: a row is a member and a
   --    position and nothing in an evaluation cares which kind it is.
   --    Ignored for a batch, whose rows are all one session's.
   --  @param Given Rows standing in for embeddings: at every position of
   --    the batch whose token is Given.Token, the next of Given.Rows --
   --    Embedding elements apiece, counting from row Given.First -- is
   --    the position's input, as it is, unscaled. This is how a picture
   --    reaches the model: the template writes a marker token wherever
   --    one stands, the encoder's rows are handed here, and the model
   --    reads them where it would have read the marker's embedding.
   procedure Evaluate_Batch
     (Item   : in out Session;
      Source : Model'Class;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      Logits : out Real_Array;
      States : Model_Runner.Tensors.Real_Array_Access := null;
      Every  : Model_Runner.Tensors.Real_Array_Access := null;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Beside : Session_Group := Alone;
      Shares : Row_Counts := Even_Shares;
      Given  : Given_Rows := No_Given_Rows;
      Status : out Model_Runner.Errors.Error_Info);

   --  One token from each of several sessions, in one pass over the weights.
   --
   --  What it is for is the measurement in docs/serving-several-sequences.md:
   --  a generated token reads every weight once and multiplies each of them
   --  once, so two tokens out of one reading cost barely more than one. Two
   --  callers served this way get tokens at about one and a half times the
   --  rate of two served in turn, and four at three and a quarter.
   --
   --  Every member gets, bit for bit, the logits it would have got alone.
   --  The products do not care how many rows they are given -- the same
   --  digest comes out at every batch size -- and each row reads and writes
   --  only its own session's cache.
   --
   --  Members must agree about the things the kernels cannot vary a row at
   --  a time: the same prepared model, the same cache precision and the same
   --  context capacity. They need not agree about anything else -- different
   --  prompts, lengths, positions and sliding windows are ordinary.
   --
   --  @param Members The sessions taking part, one a row.
   --  @param Source The model they all belong to.
   --  @param Tokens The rows' tokens, a member's rows together and the
   --    members in order. One a member unless Shares says otherwise.
   --  @param Shares How many rows each member contributes, or empty for one
   --    apiece. A member reading a prompt contributes its length; a member
   --    carrying on contributes one, and the two travel in the same pass.
   --  @param Logits Receives Vocabulary logits a member -- the member's last
   --    row -- in the members' order.
   --  @param Cancel Stops between layers, as evaluation does everywhere.
   --  @param Status Success, or the first refusal.
   procedure Evaluate_Round
     (Members : Session_Group;
      Source  : Model'Class;
      Tokens  : Model_Runner.Tokenizer.Token_Array;
      Logits  : Model_Runner.Tensors.Real_Array_Access;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Shares  : Row_Counts := Even_Shares;
      Status  : out Model_Runner.Errors.Error_Info);

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
     (Item   : in out Session;
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

   --  Keep the last few positions' states, so that a hybrid session can
   --  be rewound.
   --
   --  A linear layer's state summarizes everything before it and cannot
   --  be walked back, so a session of a hybrid architecture keeps the
   --  states as they were after each of the last Count positions, in a
   --  ring, and Rewind restores the one it is asked for -- which is what
   --  checking a draft needs: a few positions back, never further. A
   --  session keeping none refuses every rewind but to where it stands.
   --  What it costs is a copy of every linear layer's state a position,
   --  which is why it is asked for and not done. Nothing for an
   --  architecture without linear layers, which rewinds as it always did.
   --
   --  @param Item Open session.
   --  @param Count How many positions back a rewind may reach; nought to
   --    keep none.
   --  @param Status Success, Lifecycle_Invalid_State or
   --    Memory_Allocation_Failed.
   procedure Keep_States
     (Item   : in out Session;
      Count  : Natural;
      Status : out Model_Runner.Errors.Error_Info);

   --  How many positions back this session may be rewound; every position
   --  for an architecture without linear layers.
   --
   --  @param Item Open session.
   --  @return The count Keep_States was given, or Natural'Last where a
   --    rewind reaches anywhere.
   function States_Kept (Item : Session) return Natural;

   --  Whether the model carries a block past its stack for drafting the
   --  token after the next, and the session can run it: a hybrid file's
   --  nextn block, and a session holding its cache exactly.
   --
   --  @param Item Open session.
   --  @return True where Draft_Next may be called.
   function Drafts_Next (Item : Session) return Boolean;

   --  The final state of the last position this session evaluated, as
   --  the output head read it: what the block past the stack takes in
   --  beside the next token's embedding.
   --
   --  @param Item Session that has evaluated something.
   --  @return Embedding numbers, or an empty array before any evaluation.
   function Last_State (Item : Session) return Model_Runner.Numerics.Real_Array;

   --  Run the block past the stack once: a draft of the token after Token,
   --  from the stack's state at the position before it.
   --
   --  The block is a full attention layer with its own keys and values,
   --  kept in the session beside the stack's, at the position it is told:
   --  what it attends over is what it was given at the positions before,
   --  which is why a prompt is run through it position by position after
   --  the stack has seen the prompt, and why a draft's positions are run
   --  through it again with the stack's own states once the draft is
   --  checked. Its input at a position is a projection of the next
   --  token's embedding beside the state, each normalized; its answer is
   --  a distribution over the token after that and the state it would
   --  hand to itself for one more draft.
   --
   --  @param Item Open session on a model with a block past its stack.
   --  @param Source Model it was opened on.
   --  @param Token The token at Position + 1, whose successor is drafted.
   --  @param State The stack's final state at Position, Embedding numbers
   --    -- Last_State, or a row of Evaluate_Batch's States, or what this
   --    handed back the time before for a draft chained on a draft.
   --  @param Position Which position of the block's cache this writes and
   --    attends up to; at most the session's committed count.
   --  @param Logits Distribution over the token after Token; or empty,
   --    for a position run through only to put the block's cache and
   --    state right, which skips the head.
   --  @param Next_State What the block made, Embedding numbers, for the
   --    next draft's State.
   --  @param Status Success, Lifecycle_Invalid_State where the session
   --    cannot draft, Tensor_Shape_Mismatch on a wrong width or position.
   procedure Draft_Next
     (Item       : in out Session;
      Source     : Model'Class;
      Token      : Model_Runner.Tokenizer.Token_Id;
      State      : Model_Runner.Numerics.Real_Array;
      Position   : Natural;
      Logits     : out Model_Runner.Numerics.Real_Array;
      Next_State : out Model_Runner.Numerics.Real_Array;
      Status     : out Model_Runner.Errors.Error_Info);

   --  Invalidate the cache and the history without releasing memory.
   --
   --  @param Item Session to reset.
   procedure Reset (Item : in out Session);

private

   --  How many positions a layer holds, and where its rows begin. One
   --  entry a layer; see the Session's own comment for what they mean.
   type Cell_Counts is
     array (Natural range <>) of Model_Runner.Numerics.Element_Count;
   type Cell_Counts_Access is access Cell_Counts;

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

      --  What the router adds before it chooses, where an architecture
      --  states one.
      Router_Bias : Model_Runner.Tensors.Real_Array_Access;

      --  The experts' biases, held whole rather than a slice an expert.
      --  One expert's are the run of Expert_Feed at its own index, which
      --  the mixture below reaches by arithmetic -- there is nothing to
      --  gain by copying thirty-two runs out of three arrays and a
      --  megabyte to lose.
      Expert_Gate_Bias : Model_Runner.Tensors.Real_Array_Access;
      Expert_Up_Bias   : Model_Runner.Tensors.Real_Array_Access;
      Expert_Down_Bias : Model_Runner.Tensors.Real_Array_Access;

      --  One learned score a head, which joins the softmax's denominator
      --  and has no value behind it.
      --
      --  A head with a sink can attend to nothing: the sink competes with
      --  every real score for the weight, so when none of them is large the
      --  weights all come out small rather than being forced to sum to one
      --  over whatever is there. It costs one exponential a head and it is
      --  the only thing in this file that adds to a denominator without
      --  adding to a numerator.
      Sinks : Model_Runner.Tensors.Real_Array_Access;
      Experts : Expert_Array_Access := null;

      --  The experts' three matrices as the file stores them: one stack
      --  each, the expert axis outermost, of which every entry of Experts
      --  is a slice. A device that holds the whole model keeps each stack
      --  as one matrix and reads a token's chosen experts out of it in one
      --  dispatch, which is what Model.Stacked says it does.
      Gate_Stack : Model_Runner.Tensors.View;
      Up_Stack   : Model_Runner.Tensors.View;
      Down_Stack : Model_Runner.Tensors.View;

      --  A linear attention layer's own tensors, null and absent for a
      --  layer that attends in full. Mix projects the queries, keys and
      --  values at once; Z_Gate the gate the normalized blend is scaled
      --  by; Alpha and Beta the decay and the update rate, one number a
      --  value head; A_Log and DT_Bias shape the decay; Conv the
      --  convolution's taps, Conv_Kernel of them for every component of
      --  the mix; State_Norm the gain of the blend's normalization, one
      --  a component of a head; Linear_Out the projection back.
      Mix        : aliased Model_Runner.Tensors.View;
      Z_Gate     : aliased Model_Runner.Tensors.View;
      Alpha      : aliased Model_Runner.Tensors.View;
      Beta       : aliased Model_Runner.Tensors.View;
      A_Log      : Model_Runner.Tensors.Real_Array_Access;
      DT_Bias    : Model_Runner.Tensors.Real_Array_Access;
      Conv       : Model_Runner.Tensors.Real_Array_Access;
      State_Norm : Model_Runner.Tensors.Real_Array_Access;
      Linear_Out : aliased Model_Runner.Tensors.View;

      --  The expert every position of a mixture goes through as well,
      --  with the row that gates it; absent where the mixture has none.
      Shared_Gate   : aliased Model_Runner.Tensors.View;
      Shared_Up     : aliased Model_Runner.Tensors.View;
      Shared_Down   : aliased Model_Runner.Tensors.View;
      Shared_Router : Model_Runner.Tensors.Real_Array_Access;

      --  And the block past the stack's: what turns the stack's last
      --  state and the next token's embedding into this block's input,
      --  with the two normalizations before the projection and the one
      --  after the block, ahead of the shared output head.
      Next_Proj  : aliased Model_Runner.Tensors.View;
      Next_ENorm : Model_Runner.Tensors.Real_Array_Access;
      Next_HNorm : Model_Runner.Tensors.Real_Array_Access;
      Next_Head_Norm : Model_Runner.Tensors.Real_Array_Access;
   end record;

   type Layer_Array is array (Natural range <>) of Layer;
   type Layer_Array_Access is access Layer_Array;

   --  A matrix's name against where its bytes begin, for a watcher to ask
   --  which matrix a product is about to read.
   type Named_View is record
      Base   : System.Address := System.Null_Address;
      Offset : Model_Runner.Bytes.Byte_Count := 0;
      Name   : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
   end record;

   type Named_View_List is array (Positive range <>) of Named_View;
   type Named_View_Access is access Named_View_List;

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

      --  What every resolved matrix is called, against where it lives.
      --
      --  A view carries an address and a length and no name, which is right
      --  -- a name is a fact about a file and a view is a fact about memory
      --  -- and it leaves nothing to tell a watcher which matrix it is
      --  looking at. Resolve knows both at once and writes the pair down
      --  here, and that is the only place the two ever meet.
      --
      --  Read only by a run that is watching, and a linear walk when it is:
      --  two hundred comparisons against a product of a million multiplies.
      Named       : Named_View_Access := null;
      Named_Up    : Natural := 0;

      Layers      : Layer_Array_Access := null;

      --  The blocks past the stack, Next_Layers of them, which the stack
      --  never runs: a draft of the token after the next, when asked.
      Next        : Layer_Array_Access := null;
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

      --  The carried format Chat holds, when it holds one rather than the
      --  model's own template; and whether Prepare chose it because the
      --  model's own would not compile. A bounded name rather than a
      --  Chat_Format, so that "none" is the empty string and not a value
      --  the enumeration would have to carry for this one record.
      Chat_Format_Name : String (1 .. 16) := [others => ' '];
      Chat_Format_Used : Natural := 0;
      Chat_Stood_In    : Boolean := False;
      Accounting  : Model_Runner.Memory.Account;

      --  What the backend this model was prepared for can read. Every tensor
      --  is checked against it while the model loads, so that a format the
      --  backend cannot take is refused with the model rather than found by
      --  a matrix product part way through the first token.
      Able        : Model_Runner.Backend.Capabilities;

      --  How the weights were written into Repacked, when they were. A
      --  merge needs to know, because it may only add to binary32.
      Packing     : Repack_Mode := No_Repack;

      --  Whether a mixture's experts reach the device as whole stacks
      --  rather than a slice at a time. Decided once, at Prepare: a stack
      --  is one matrix to the device's residency, so this is right only
      --  where the whole model fits the device's budget -- read a slice at
      --  a time, a model that does not fit gives back and uploads again
      --  only the slices a token touches, and a stack would be all of them.
      Stacked     : Boolean := False;

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

   --  Which expert a position chose, and which positions chose an expert.
   --
   --  A plain count either way: the arrays are indexed by position times
   --  the picks a position makes, or by the positions gathered for one
   --  expert, and both are as long as a batch is wide.
   type Choice_List is array (Natural range <>) of Natural;
   type Choice_Access is access Choice_List;

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

      --  Which block of the device's cache holds this session's keys and
      --  values, or minus one where none does.
      --
      --  The device keeps one cache buffer. A session used to have it to
      --  itself; a round's rows are different sessions reading it side by
      --  side, so it is dealt out in blocks of one session's worth and a
      --  row of a round reads the block its row number names. What the
      --  host holds is the copy of record either way, so a session turned
      --  out of its block loses nothing but the copy.
      Seat       : Integer := -1;

      --  Positions the device has written into its own block and the host's
      --  copy has not been given yet, counted from Owed_At and none when
      --  Owed_Count is zero.
      --
      --  The host's copy used to be brought up to date at the end of every
      --  call, which is what "the copy of record" above meant: two reads a
      --  layer, twenty-two layers, sixty-four megabytes for a long prompt,
      --  and a wait on each of them. Nothing read those bytes for a run that
      --  neither saves its context nor rolls it, so they are fetched when
      --  something is about to read them instead -- which is
      --  Settle_Cache, and the three places that call it.
      --
      --  There is no eviction to lose them to: a block is granted once and
      --  a session keeps it until it closes, so a range recorded here is
      --  still on the device when it is asked for.
      Owed_At    : Natural := 0;
      Owed_Count : Natural := 0;

      --  The committed keys and values, in one precision or the other.
      --  Exactly one pair is allocated; the other stays null, which is what
      --  the reads below test rather than carrying a converted copy.
      Held       : Cache_Precision := Exact;

      --  Whether the session asked for halves and got them on the device,
      --  where the host's copy is exact and the device attends out of its
      --  own half-precision copy: what Precision reports as Halved.
      Device_Halves : Boolean := False;
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

      --  Room for every chosen expert's two arms at once.
      --
      --  A mixture multiplies its input by the gate and the up matrix of
      --  each expert it chose, and those all read THE SAME INPUT -- so they
      --  are a group, and a group is one submission. They were sixteen: two
      --  a expert, eight experts, forty-eight layers, which is one thousand
      --  five hundred and thirty-six submissions a token where the dense
      --  path takes one a layer. Each arm wants its own array because that
      --  is what a group's targets are, so they are held here rather than
      --  allocated a layer.
      --
      --  Null for a model with no experts, which allocates none of it.
      Expert_Arms : Model_Runner.Tensors.Group_Room_Access := null;

      --  The gated results of every chosen expert, end to end, and the room
      --  their down projections write into.
      --
      --  The down projections differ in their input as well as their
      --  matrix, so they are not a group of one activation -- but laid end
      --  to end in one they are still one submission, which is what the
      --  stride on a group is for. Eight submissions a layer become one.
      Expert_Feeds : Model_Runner.Tensors.Real_Array_Access := null;
      Expert_Outs  : Model_Runner.Tensors.Group_Room_Access := null;

      --  What a gathered mixture hands back: every chosen expert's
      --  projection down, one after another, before the shares weight
      --  them. Taken when the model is Stacked and the device is asked.
      Mixed        : Model_Runner.Tensors.Real_Array_Access := null;

      --  What a batch's mixture needs, to read every expert's matrices once
      --  a layer instead of once for every position that chose them.
      --
      --  A batch has no one matrix to multiply the whole of it by, which is
      --  why the mixture ran a position at a time however many were handed
      --  in -- and an expert chosen by seven positions of a hundred and ten
      --  had its three matrices read seven times. Gathered the other way
      --  round, by expert rather than by position, each is read once and
      --  multiplied by every position that chose it at once.
      --
      --  Taken at the first batch that needs them and grown if a later one
      --  is wider, because their size is the batch's and a session does not
      --  know what batches it will see. Null for a dense model and for a
      --  mixture on the processor, which pays nothing for a submission and
      --  reads its weights out of the same memory either way.
      Route_Rows : Model_Runner.Tensors.Real_Array_Access := null;
      Pick_Which : Choice_Access := null;
      Pick_Share : Model_Runner.Tensors.Real_Array_Access := null;
      Gather_In  : Model_Runner.Tensors.Real_Array_Access := null;
      Gather_A   : Model_Runner.Tensors.Real_Array_Access := null;
      Gather_B   : Model_Runner.Tensors.Real_Array_Access := null;
      Gather_Out : Model_Runner.Tensors.Real_Array_Access := null;
      Ranked     : Model_Runner.Tensors.Real_Array_Access := null;
      Gathered   : Choice_Access := null;
      Plan       : Model_Runner.Memory.Session_Plan;
      Team       : Model_Runner.Backend.CPU.Pool_Reference := null;
      Logit_Row  : Model_Runner.Tensors.Real_Array_Access := null;

      --  How the cache is cut up, one entry a layer.
      --
      --  It used to be one number: every layer held the whole context and a
      --  position sat at its own index. A layer that slides a window can
      --  never read further back than the window, so it is given the window
      --  and a margin instead, and a position sits at its distance from the
      --  lowest one the layer still holds. Origin is that lowest position
      --  and is the only one of these that moves.
      --
      --  Null until the session is opened, and null for a session that
      --  holds nothing.
      Cells     : Cell_Counts_Access := null;
      At_Keys   : Cell_Counts_Access := null;
      At_Values : Cell_Counts_Access := null;
      At_Rows   : Cell_Counts_Access := null;

      --  Something being told what every product was given, or null.
      Seen      : Watcher_Access := null;
      Origin    : Cell_Counts_Access := null;

      --  What a linear layer keeps instead of keys and values: the last
      --  Conv_Kernel - 1 positions' mixed projections, Mix_Width each,
      --  and the state, State_Size by State_Size a value head. One of
      --  each a linear layer, laid one after another in layer order,
      --  is a slot; a full attention layer has no room in it and a
      --  linear one has no cells.
      --
      --  Kept_States + 1 slots, a ring indexed by position: a position
      --  reads the slot before its own and writes its own, so the slots
      --  behind the newest hold the states as they were Kept_States
      --  positions back, which is what a rewind restores, since a state
      --  summarizes everything and cannot be walked back. One slot where
      --  nothing is kept, read and written in place. Kept as slots rather
      --  than copied into a ring after each position because the copy
      --  was eighteen megabytes a position on Qwen3.5-0.8B and most of
      --  what a draft's verification cost.
      Conv_State  : Model_Runner.Tensors.Real_Array_Access := null;
      Delta_State : Model_Runner.Tensors.Real_Array_Access := null;
      Kept_States : Natural := 0;

      --  One past the highest position written since the ring was
      --  last empty: the ring reaches Kept_States positions back from
      --  there. A rewind leaves it, since the slots past the position
      --  still hold what was written there and a later rewind's slot is
      --  intact only if nothing has come round to it.
      Kept_Newest : Natural := 0;

      --  Room a linear layer's answers take on the way through: the
      --  mixed projections, the gate, the decays and rates, the blend;
      --  and a mixture's shared expert's arms.
      Query_Full : Model_Runner.Tensors.Real_Array_Access := null;
      Head_Gate  : Model_Runner.Tensors.Real_Array_Access := null;
      Mix_Row    : Model_Runner.Tensors.Real_Array_Access := null;
      Z_Row      : Model_Runner.Tensors.Real_Array_Access := null;
      Alpha_Row  : Model_Runner.Tensors.Real_Array_Access := null;
      Beta_Row   : Model_Runner.Tensors.Real_Array_Access := null;
      Blend_Row  : Model_Runner.Tensors.Real_Array_Access := null;
      Shared_Row : Model_Runner.Tensors.Real_Array_Access := null;
      Shared_Up_Row : Model_Runner.Tensors.Real_Array_Access := null;
      Shared_Out_Row : Model_Runner.Tensors.Real_Array_Access := null;

      --  And the same three for a batch, as wide as the batch that last
      --  asked, taken when it asks.
      Shared_Rows_A   : Model_Runner.Tensors.Real_Array_Access := null;
      Shared_Rows_B   : Model_Runner.Tensors.Real_Array_Access := null;
      Shared_Rows_Out : Model_Runner.Tensors.Real_Array_Access := null;

      --  The last evaluated position's final state, and room for the
      --  next block's input: the two normalized halves side by side.
      Last_Final : Model_Runner.Tensors.Real_Array_Access := null;
      Next_Input : Model_Runner.Tensors.Real_Array_Access := null;
      Has_Final  : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Session);

end Model_Runner.Llama;
