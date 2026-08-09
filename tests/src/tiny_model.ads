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
   type Weight_Format is (Float32, Q8_0, Q4_K);

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
   Deep_Embedding    : constant := 256;
   Deep_Feed_Forward : constant := 512;
   Deep_Head_Size    : constant := 128;

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
   procedure Build
     (Result         : out Model_Runner.Bytes.Byte_Array_Access;
      Format         : Weight_Format := Float32;
      End_Token      : Natural := 2;
      Adds_Beginning : Boolean := True;
      Room           : Positive := Context;
      Qwen           : Boolean := False;
      Omit_Biases    : Boolean := False);

end Tiny_Model;
