with Ada.Strings.Unbounded;
with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.GGUF.Containers;

--  An independent reference implementation of the Llama forward pass.
--
--  This exists to answer one question: are the engine's logits right? It
--  answers it by computing them a second time, differently, and comparing.
--
--  What makes it independent:
--
--    It shares no arithmetic with the engine. It decodes float32 from the file
--    bytes itself, computes in Long_Float throughout rather than in the
--    engine's binary32 storage with binary64 accumulation, and implements
--    every step -- normalization, projection, rotary encoding, attention,
--    activation, residuals -- with its own loops. It calls nothing from
--    Model_Runner.Kernels, Model_Runner.Tensors or Model_Runner.Llama.
--
--    It stores the whole key and value history rather than a reserved-and-
--    committed cache, so it cannot inherit a cache-indexing mistake.
--
--    It duplicates key and value heads for grouped-query attention instead of
--    mapping query heads onto them, so it cannot inherit a mapping mistake.
--
--  What it shares: the GGUF container parser, because reading the file is a
--  separate concern from computing with it, and because a parsing difference
--  would show up as a shape or count mismatch rather than as a wrong number.
--
--  It handles float32 tensors only, which is what the synthetic model uses. A
--  quantized model is rejected rather than approximated.
--
--  Task safety: a model is used by one task.
package Reference_Transformer is

   type Real_Vector is array (Natural range <>) of Long_Float;

   --  A loaded reference model.
   type Model is limited private;

   --  Load every tensor the forward pass needs.
   --
   --  @param Item Model to fill in; released first.
   --  @param Source Parsed container.
   --  @param Image File bytes the container was parsed from.
   --  @param Ok True when the model is float32 throughout and complete.
   --  @param Asked Every tensor name this asked the container for, in the
   --    order it asked, newline separated and each terminated by one, or
   --    null to record none. Written for the check that a fixture holds the
   --    set an architecture carries: whether a tensor is read is one
   --    question and whether the right tensors are there is another, and
   --    only this side knows what it asked for.
   procedure Load
     (Item   : in out Model;
      Source : Model_Runner.GGUF.Containers.Container;
      Image  : Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean;
      Asked  : access Ada.Strings.Unbounded.Unbounded_String := null);

   --  Release a model. Idempotent.
   --
   --  @param Item Model to release.
   procedure Close (Item : in out Model);

   --  Vocabulary size of a loaded model.
   --
   --  @param Item Loaded model.
   --  @return Token count.
   function Vocabulary (Item : Model) return Natural;

   --  How wide a state is, which is what a caller sizing a states buffer
   --  needs and cannot work out from the vocabulary.
   --
   --  @param Item Loaded model.
   --  @return Embedding width, or zero before a model is loaded.
   function Width (Item : Model) return Natural;

   type Token_Vector is array (Positive range <>) of Natural;

   --  Evaluate a token sequence from an empty context.
   --
   --  Every token is evaluated in order, exactly as the engine would, and the
   --  logits for the final token are returned.
   --
   --  @param Item Loaded model.
   --  @param Tokens Token identifiers, in order.
   --  @param Logits Vocabulary-sized raw logits for the last token.
   --  @param Ok True when the sequence was evaluated.
   procedure Run
     (Item   : in out Model;
      Tokens : Token_Vector;
      Logits : out Real_Vector;
      Ok     : out Boolean);

   --  How the model rounds what it keeps, where it is asked to: as the
   --  engine's byte cache does -- a signed byte an element with the row's
   --  largest over a hundred and twenty-seven, rounded to the nearest --
   --  or as its nibble cache does -- a block of thirty-two elements scaled
   --  by its largest, sign and all, over minus eight, each element its
   --  share of that plus eight and a half cut to a whole number and held
   --  to fifteen. Written here on its own, in binary64, so that the
   --  engine's packed caches can be held to what they claim -- the same
   --  rounding -- rather than to the exact cache, which they are not.
   type Cache_Rounding is (Unrounded, To_Bytes, To_Nibbles);

   --  Round every key and value the model keeps, each side its own way,
   --  from now on.
   --
   --  @param Item Loaded model.
   --  @param Keys How the keys are rounded.
   --  @param Values How the values are.
   procedure Round_Cache
     (Item : in out Model; Keys, Values : Cache_Rounding);

   --  Round both sides to nibbles, or neither.
   --
   --  @param Item Loaded model.
   --  @param On True to round from now on.
   procedure Round_Cache_To_Nibbles (Item : in out Model; On : Boolean);

   --  What the model made of every position, for the model that produces
   --  states and no distribution.
   --
   --  Bert is that model, and there is nothing else to ask it for: it
   --  carries no projection from a state to a token, so a comparison
   --  against the engine is of these or of nothing.
   --
   --  @param Item Loaded model.
   --  @param Tokens Token identifiers, in order.
   --  @param States Steps times the embedding width, position by position.
   --  @param Ok True when the sequence was evaluated.
   procedure Run_States
     (Item   : in out Model;
      Tokens : Token_Vector;
      States : out Real_Vector;
      Ok     : out Boolean);

   --  A draft from the block past the stack, for a model that carries
   --  one: the distribution over the token after Next, where Next is the
   --  token proposed for the position after the text. The stack runs the
   --  text, and the block runs every position of it in order -- given the
   --  token after each beside the stack's state at it -- so that the
   --  draft attends over what the block was given before, as the engine's
   --  own draft does after a prompt.
   --
   --  @param Item Loaded model with a block past its stack.
   --  @param Tokens The text.
   --  @param Next The token proposed for the position after it.
   --  @param Logits Distribution over the token after that; Vocabulary
   --    numbers.
   --  @param Ok True when the model drafts and the shapes agree.
   procedure Draft
     (Item   : in out Model;
      Tokens : Token_Vector;
      Next   : Natural;
      Logits : out Real_Vector;
      Ok     : out Boolean);

   --  Whether a loaded model carries a block past its stack to draft from.
   --
   --  @param Item Loaded model.
   --  @return True when the file counts one or more blocks past the stack.
   function Drafts (Item : Model) return Boolean;

private

   type Matrix is array (Natural range <>, Natural range <>) of Long_Float;
   type Matrix_Access is access Matrix;
   type Vector_Access is access Real_Vector;

   --  The architectures this reference implements. It has to be the same
   --  set the engine implements, or a conformance run compares two
   --  different functions and blames the engine for the difference.
   --  Gemma is here for the same reason the others are: it is this shape
   --  with a difference, and the differences are worked out from what the
   --  architecture says rather than read out of the engine. Two of them --
   --  the embedding scale and the Gaussian gate -- and each is written here
   --  in the form the paper gives rather than the form the engine uses,
   --  which is the whole point of a second implementation. The third the
   --  paper states, one plus the weight as the normalization gain, is not
   --  here on purpose: the converter adds that one as it writes the file,
   --  and a reference that added it again agreed with an engine that did
   --  the same for a month.
   type Architecture is
     (Llama, Qwen2, Qwen3, Qwen3_MoE, GPT_OSS, Gemma, Gemma2, Gemma3, Phi3,
      Falcon, Phi2, GPT2, Bert, Nomic_Bert, Jina_Bert_V2, Qwen35, Qwen35_MoE,
      Granite, Olmo2);

   --  How a model stretches the rotation to reach past what it was trained
   --  on: not at all, by dividing every position, or by dividing only the
   --  frequencies slow enough that a long context needs them.
   type Rotary_Stretch is (Unscaled, Linear, Yarn);

   type Layer is record
      Attention_Norm : Vector_Access := null;

      --  Gemma2 normalizes what each sublayer produced as well as what it
      --  was given. Null for everything else.
      Post_Attention_Norm : Vector_Access := null;
      Post_Feed_Norm      : Vector_Access := null;

      --  The shift beside each of those gains, for the architecture whose
      --  post-normalization centres as well as scaling. Bert's; null for
      --  Gemma2 and Gemma3, whose two are by root mean square.
      Post_Attention_Norm_Bias : Vector_Access := null;
      Post_Feed_Norm_Bias      : Vector_Access := null;

      --  The bias the centred normalization carries, which Falcon and Phi2
      --  have. Null for every architecture that normalizes by root mean
      --  square.
      Attention_Norm_Bias : Vector_Access := null;
      Query          : Matrix_Access := null;
      Key            : Matrix_Access := null;
      Value          : Matrix_Access := null;
      Query_Bias     : Vector_Access := null;
      Key_Bias       : Vector_Access := null;
      Value_Bias     : Vector_Access := null;
      --  Qwen3 normalizes every query head and every key head against
      --  itself before the rotation, with one gain per element of a head.
      Query_Norm     : Vector_Access := null;
      Key_Norm       : Vector_Access := null;

      --  The code variant of jina-bert-v2 normalizes the whole of its
      --  queries and the whole of its keys, centred and with a shift,
      --  after their biases, and normalizes the attention sublayer a
      --  second time over the joined residual with the layer's input added
      --  once more. Null for every other model, and for the text variant.
      Query_Whole_Norm      : Vector_Access := null;
      Query_Whole_Norm_Bias : Vector_Access := null;
      Key_Whole_Norm        : Vector_Access := null;
      Key_Whole_Norm_Bias   : Vector_Access := null;
      Second_Attention_Norm      : Vector_Access := null;
      Second_Attention_Norm_Bias : Vector_Access := null;
      Attention_Out  : Matrix_Access := null;

      --  What Phi2 adds to a projection that is not one of the three above:
      --  on the way out of attention, and on each side of the feed-forward.
      Out_Bias       : Vector_Access := null;
      Up_Bias        : Vector_Access := null;
      Down_Bias      : Vector_Access := null;
      Feed_Norm      : Vector_Access := null;

      --  The shift beside that gain, where the architecture centres. Null
      --  for every architecture that does not, and for a file that carries
      --  no such tensor.
      Feed_Norm_Bias : Vector_Access := null;
      Gate           : Matrix_Access := null;
      Up             : Matrix_Access := null;
      Down           : Matrix_Access := null;

      --  What a mixture-of-experts layer carries instead. The experts are
      --  kept stacked, exactly as the file writes them, and an expert is
      --  reached by an offset into the rows rather than by a copy -- which
      --  is also the arithmetic the engine does, arrived at from the shape
      --  of the tensor rather than from the engine.
      Router         : Matrix_Access := null;
      Gate_Experts   : Matrix_Access := null;
      Up_Experts     : Matrix_Access := null;
      Down_Experts   : Matrix_Access := null;

      --  What GPT_OSS carries and nothing else here does: one score a head
      --  for the softmax's denominator, and a bias on the router and on
      --  each of an expert's three projections.
      Sinks             : Vector_Access := null;
      Router_Bias       : Vector_Access := null;
      Gate_Expert_Bias  : Vector_Access := null;
      Up_Expert_Bias    : Vector_Access := null;
      Down_Expert_Bias  : Vector_Access := null;

      --  A hybrid mixture's shared expert: the gate-up-down block every
      --  position goes through beside the chosen experts, and the row
      --  that gates its answer against the input.
      Shared_Gate    : Matrix_Access := null;
      Shared_Up      : Matrix_Access := null;
      Shared_Down    : Matrix_Access := null;
      Shared_Router  : Vector_Access := null;

      --  A hybrid's linear layer, where the block keeps a state rather
      --  than a cache: the three projections in one, the gate, the decay
      --  and the rate a value head, the decay's shape and the rate's
      --  bias, the taps of the convolution a channel, the blend's gain
      --  and the way back. Written out here from the architecture's own
      --  description, and sharing nothing with the engine's kernel.
      Linear     : Boolean := False;
      Mix        : Matrix_Access := null;
      Z_Gate     : Matrix_Access := null;
      Alpha      : Matrix_Access := null;
      Beta       : Matrix_Access := null;
      A_Log      : Vector_Access := null;
      DT_Bias    : Vector_Access := null;
      Conv       : Matrix_Access := null;
      State_Norm : Vector_Access := null;
      Linear_Out : Matrix_Access := null;
   end record;

   type Layer_Array is array (Natural range <>) of Layer;
   type Layer_Array_Access is access Layer_Array;

   type Model is limited record
      Loaded       : Boolean := False;
      Kind         : Architecture := Llama;

      --  How the keys and the values are rounded as they are kept, as
      --  Round_Cache says.
      Key_Rounding   : Cache_Rounding := Unrounded;
      Value_Rounding : Cache_Rounding := Unrounded;
      Embedding    : Natural := 0;
      Feed_Forward : Natural := 0;
      Layers       : Natural := 0;
      Heads        : Natural := 0;
      KV_Heads     : Natural := 0;
      Head_Size    : Natural := 0;

      --  A value head need not be as wide as a key head: the keys decide
      --  which positions are read and the values what is read from them.
      --  Equal to Head_Size for a file that states neither width.
      Value_Size   : Natural := 0;
      Rotary       : Natural := 0;
      Context      : Natural := 0;
      Words        : Natural := 0;
      Epsilon      : Long_Float := 1.0E-5;
      Rope_Base    : Long_Float := 10_000.0;

      --  How the model stretches the rotation, and what the stretch needs.
      --  Read from the file here as everything else is, and computed from
      --  the description of the method rather than from the engine.
      Stretch      : Rotary_Stretch := Unscaled;
      Frequency    : Long_Float := 1.0;
      Trained      : Natural := 0;
      Beta_Fast    : Long_Float := 32.0;
      Beta_Slow    : Long_Float := 1.0;
      Attenuation  : Long_Float := 1.0;

      --  How far back a position may attend, counting itself. Zero is no
      --  window: everything before it is visible. Read from the model's own
      --  metadata here, as everything else is, so that the two
      --  implementations agree because they read the same file rather than
      --  because one was told what the other found.
      Window       : Natural := 0;

      --  The two bounds Gemma2 states, as the scaled hyperbolic tangent it
      --  applies to a score and to a logit. Zero for an architecture that
      --  states none.
      Attention_Cap : Long_Float := 0.0;

      --  How steeply a head's attention falls off with distance, for a model
      --  that learned no positions and rotates nothing. Zero for every other.
      Max_Bias      : Long_Float := 0.0;
      Logit_Cap     : Long_Float := 0.0;

      --  Granite's four multipliers: on the embedding, on each sublayer's
      --  output before the residual add, on the attention scores in place of
      --  one over the root of the head width, and dividing the final logits.
      --  Zero is the identity, which is every architecture here but Granite.
      Embedding_Mul : Long_Float := 0.0;
      Residual_Mul  : Long_Float := 0.0;
      Attention_Mul : Long_Float := 0.0;
      Logit_Mul     : Long_Float := 0.0;

      --  How many layers in a row slide a window before one sees
      --  everything, and the base the windowed ones turn on. Gemma3 states
      --  both; every other architecture here turns every layer on one base
      --  and windows all of them or none.
      Window_Every  : Natural := 0;
      Local_Base    : Long_Float := 0.0;

      --  How many experts a layer holds, how many of them run for one
      --  position, and how wide one of them is. Zero experts is a dense
      --  model, which is what a file without the keys describes.
      Experts      : Natural := 0;
      Experts_Used : Natural := 0;
      Expert_Feed  : Natural := 0;
      Shared_Feed  : Natural := 0;

      --  The hybrid's shape: every Linear_Every-th layer attends in full
      --  and the rest run the rule over a state of State_Size squared a
      --  value head, the keys and queries over Key_Heads of the same
      --  width, after a convolution of Conv_Taps taps. Next_Layers blocks
      --  past the stack draft the token after the next; they are read, so
      --  that what the file carries is asked for, and the stack does not
      --  run them.
      Linear_Every : Natural := 0;
      State_Size   : Natural := 0;
      Key_Heads    : Natural := 0;
      Value_Heads  : Natural := 0;
      Conv_Taps    : Natural := 0;
      Next_Layers  : Natural := 0;
      Next_Proj    : Matrix_Access := null;
      Next_Enorm   : Vector_Access := null;
      Next_Hnorm   : Vector_Access := null;
      Next_Head_Norm : Vector_Access := null;
      Embeddings   : Matrix_Access := null;
      Output       : Matrix_Access := null;
      Output_Norm  : Vector_Access := null;

      --  And its bias, for the architecture that centres rather than
      --  scaling.
      Output_Norm_Bias : Vector_Access := null;

      --  Added to every logit. Phi2's output projection carries one.
      Output_Bias      : Vector_Access := null;

      --  One row a position, added to the token's row before the first
      --  layer. GPT2 learns where a token is instead of rotating for it.
      Positions        : Matrix_Access := null;

      --  One row a segment, of which a text uses the first, and the
      --  normalization over the sum of the token's row, the position's and
      --  the segment's. Bert's, and null everywhere else.
      Segments             : Matrix_Access := null;
      Embedding_Norm       : Vector_Access := null;
      Embedding_Norm_Bias  : Vector_Access := null;

      --  One divisor per rotated pair, when the file carries the table.
      Rope_Factors : Vector_Access := null;
      Blocks       : Layer_Array_Access := null;
   end record;

   --  Decode one little-endian float32 from the file bytes. Written here
   --  rather than reused so that the reference does not share the engine's
   --  decoding.
   function Decode_Float
     (Image  : Model_Runner.Bytes.Byte_Array;
      Offset : Interfaces.Unsigned_64) return Long_Float;

end Reference_Transformer;
