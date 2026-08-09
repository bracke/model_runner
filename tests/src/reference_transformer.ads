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
   procedure Load
     (Item   : in out Model;
      Source : Model_Runner.GGUF.Containers.Container;
      Image  : Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean);

   --  Release a model. Idempotent.
   --
   --  @param Item Model to release.
   procedure Close (Item : in out Model);

   --  Vocabulary size of a loaded model.
   --
   --  @param Item Loaded model.
   --  @return Token count.
   function Vocabulary (Item : Model) return Natural;

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

private

   type Matrix is array (Natural range <>, Natural range <>) of Long_Float;
   type Matrix_Access is access Matrix;
   type Vector_Access is access Real_Vector;

   --  The architectures this reference implements. It has to be the same
   --  set the engine implements, or a conformance run compares two
   --  different functions and blames the engine for the difference.
   type Architecture is (Llama, Qwen2);

   type Layer is record
      Attention_Norm : Vector_Access := null;
      Query          : Matrix_Access := null;
      Key            : Matrix_Access := null;
      Value          : Matrix_Access := null;
      Query_Bias     : Vector_Access := null;
      Key_Bias       : Vector_Access := null;
      Value_Bias     : Vector_Access := null;
      Attention_Out  : Matrix_Access := null;
      Feed_Norm      : Vector_Access := null;
      Gate           : Matrix_Access := null;
      Up             : Matrix_Access := null;
      Down           : Matrix_Access := null;
   end record;

   type Layer_Array is array (Natural range <>) of Layer;
   type Layer_Array_Access is access Layer_Array;

   type Model is limited record
      Loaded       : Boolean := False;
      Kind         : Architecture := Llama;
      Embedding    : Natural := 0;
      Feed_Forward : Natural := 0;
      Layers       : Natural := 0;
      Heads        : Natural := 0;
      KV_Heads     : Natural := 0;
      Head_Size    : Natural := 0;
      Rotary       : Natural := 0;
      Context      : Natural := 0;
      Words        : Natural := 0;
      Epsilon      : Long_Float := 1.0E-5;
      Rope_Base    : Long_Float := 10_000.0;
      Embeddings   : Matrix_Access := null;
      Output       : Matrix_Access := null;
      Output_Norm  : Vector_Access := null;
      Blocks       : Layer_Array_Access := null;
   end record;

   --  Decode one little-endian float32 from the file bytes. Written here
   --  rather than reused so that the reference does not share the engine's
   --  decoding.
   function Decode_Float
     (Image  : Model_Runner.Bytes.Byte_Array;
      Offset : Interfaces.Unsigned_64) return Long_Float;

end Reference_Transformer;
