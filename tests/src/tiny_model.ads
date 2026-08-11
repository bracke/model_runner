with Model_Runner.Bytes;

--  The tiny executable model used by the inference tests.
--
--  Its shape is deliberately small enough to reason about by hand and large
--  enough to exercise every structural feature the supported profile has:
--  more than one layer, more than one attention head, fewer key-value heads
--  than query heads so that grouped-query attention is real, a rotary width
--  narrower than the head, and a separate output projection.
--
--     vocabulary       16      layers             2
--     embedding         8      attention heads    2
--     feed-forward     12      key-value heads    1
--     head size         4      rotary width       4
--     context          16
--
--  Weights come from a fixed integer sequence, so the file has the same bytes
--  on every host and a logit vector can be compared exactly between runs.
package Tiny_Model is

   Vocabulary   : constant := 16;
   Embedding    : constant := 8;
   Feed_Forward : constant := 12;
   Layers       : constant := 2;
   Heads        : constant := 2;
   KV_Heads     : constant := 1;
   Head_Size    : constant := 4;
   Context      : constant := 16;

   --  Write the fixture where the suite reads it, at fixtures/tiny-model.gguf
   --  relative to the tests crate.
   --
   --  `tests/fixtures/*.gguf` is ignored by git: a model file is not
   --  committed unless its licence plainly allows it, and that rule is meant
   --  to keep the decision from being made by accident. The consequence went
   --  unnoticed -- four tests read a file the repository does not carry, so
   --  they passed on a machine where `tests fixtures` had been run and failed
   --  on every clean checkout, which is what continuous integration is. The
   --  suite had been reporting green against a file that only existed here.
   --
   --  Any test that reads the fixture writes it first. The bytes are fixed,
   --  so writing it again writes the same file, and a run that writes it
   --  needs nothing left behind by an earlier one.
   procedure Write_Suite_Fixture;

   --  Where that fixture is, for a test to name.
   Suite_Fixture : constant String := "fixtures/tiny-model.gguf";

   --  Write the fixture to disk.
   --
   --  @param Path Destination path; overwritten if it exists.
   --  @param Adds_Beginning Whether the vocabulary declares that it wants a
   --    beginning-of-text marker. False is not a curiosity: real models
   --    declare it, and putting a marker in front of one that does not want
   --    it feeds a sequence no other implementation would.
   --  @param Room Context length the model declares. The default is small
   --    on purpose, so that tests reach the context bound without a large
   --    conversation; a test that needs a turn to complete asks for more.
   procedure Write
     (Path           : String;
      Adds_Beginning : Boolean := True;
      Room           : Positive := Context);

   --  Which format the weight matrices use. The norms and the small vectors
   --  stay binary32 in both, as they do in a real quantized model.
   type Weight_Format is
     (F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0,
      Q2_K, Q3_K, Q4_K, Q5_K, Q6_K);

   --  A quantized row is a whole number of thirty-two element blocks, so a
   --  model whose widths are eight and twelve cannot be quantized at all.
   --  These are the widths the quantized fixture uses instead; everything
   --  else about it is the same.
   Wide_Embedding    : constant := 32;
   Wide_Feed_Forward : constant := 64;
   Wide_Head_Size    : constant := 16;

   --  A k-quant block is 256 elements, so a fixture carrying one has to be
   --  wider again. It is the format a real model most often uses, and it
   --  was unreachable here: every claim about quantized weights, including
   --  what repacking to brain floats costs, was measured on binary32 and
   --  Q8_0 alone.
   --  256 is the smallest embedding a k-quant row can have, so it is what
   --  these are. The feed-forward width was 512 and is 256 for the same
   --  reason the rest of this fixture is small: the independent
   --  implementation it is compared against computes in Long_Float without
   --  a pool, and halving that width took the conformance run from 53
   --  seconds to 36 without giving up a single comparison.
   Deep_Embedding    : constant := 256;
   Deep_Feed_Forward : constant := 256;
   Deep_Head_Size    : constant := 128;

   --  How the fixture stretches the rotation. Plain is a model that says
   --  nothing, which rotates as it was trained.
   type Rope_Stretch is (Plain, Linear, Yarn);

   --  Build the fixture in memory.
   --
   --  @param Result Newly allocated file bytes; the caller frees them.
   --  @param Format Format for the weight matrices. Q8_0 also widens the
   --    model, because the narrow one cannot hold a quantized row.
   --  @param End_Token Identifier the vocabulary declares as its end token.
   --    Varying it is how a test reaches the end-of-sequence path without
   --    depending on which token these weights happen to produce.
   --  @param Adds_Beginning Whether the vocabulary asks for a
   --    beginning-of-text marker.
   --  @param Room Context length the model declares.
   --  @param Qwen Write the file as a qwen2 model: its metadata under the
   --    qwen2 keys, and a bias beside each attention projection. The two
   --    architectures differ in that and in which elements the rotation
   --    pairs, and nothing but a file could tell the two apart.
   --  @param Omit_Biases Leave the attention biases out of a qwen2 file, so
   --    that a model claiming an architecture it does not carry the weights
   --    for is refused rather than read.
   --  @param Window Sliding-window width the model declares, in positions.
   --    Zero writes no key at all, which is a model that attends to
   --    everything committed. A model with a window is not a model with a
   --    shorter context: the context is what may be held and the window is
   --    what each position may see.
   --  @param Experts How many experts each layer carries. Zero writes a
   --    dense model: one feed-forward block a layer and no router. Any other
   --    count writes a router, a stack of expert matrices, and the metadata
   --    naming both -- including the expert width, which is narrower than the
   --    dense block this fixture would otherwise have.
   --  @param Experts_Used How many of those experts run for one position.
   --    Meaningful only beside a non-zero count.
   --  @param Stretch Which rotary scaling the file declares. Linear states
   --    a factor and nothing else; Yarn states the factor, the context the
   --    model was trained on -- half the one it declares, so the stretch has
   --    something to reach past -- and the two ends of the band it ramps
   --    across.
   --  @param Rope_Table Write a rope_freqs.weight table of per-dimension
   --    divisors. A file states a schedule that is not one number this way,
   --    and a model carrying one that is not applied rotates its long-range
   --    dimensions wrongly while looking healthy on a short prompt.
   --  @param Byte_Pair Write the vocabulary as a byte-pair one -- a `gpt2`
   --    model with a merge table, pieces in the stand-in alphabet and the
   --    same three control tokens -- instead of a SentencePiece one. That
   --    road had no model of its own: every session, every generated token
   --    and the whole conformance sweep went through SentencePiece, so
   --    nothing said whether a byte-pair vocabulary survives being driven
   --    rather than called.
   procedure Build
     (Result         : out Model_Runner.Bytes.Byte_Array_Access;
      Format         : Weight_Format := F32;
      End_Token      : Natural := 2;
      Adds_Beginning : Boolean := True;
      Room           : Positive := Context;
      Qwen           : Boolean := False;
      Omit_Biases    : Boolean := False;
      Byte_Pair      : Boolean := False;
      Window         : Natural := 0;
      Experts        : Natural := 0;
      Experts_Used   : Natural := 0;
      Stretch        : Rope_Stretch := Plain;
      Rope_Table     : Boolean := False);

end Tiny_Model;
