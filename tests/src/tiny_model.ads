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

   --  Write the model file to disk.
   --
   --  @param Path Destination path; overwritten if it exists.
   --  Write the fixture.
   --
   --  @param Path Where to write it.
   --  @param Qwen Write the file as a qwen2 model: its metadata under the
   --    qwen2 keys, and a bias beside each attention projection. The two
   --    architectures differ in that and in which elements the rotation
   --    pairs, and nothing but a file could tell the two apart.
   --  @param Room Context length the model declares. The default is small
   --    on purpose, so that tests reach the context bound without a large
   --    conversation; a test that needs a turn to complete asks for more.
   --  @param Adds_Beginning Whether the vocabulary declares that it wants a
   --    beginning-of-text marker. False is not a curiosity: real models
   --    declare it, and putting a marker in front of one that does not want
   --    it feeds a sequence no other implementation would.
   procedure Write
     (Path : String;
      Adds_Beginning : Boolean := True;
      Room : Positive := Context);

   --  Build the model file.
   --
   --  @param Result Newly allocated file bytes; the caller frees them.
   --  Which format the weight matrices use. The norms and the small vectors
   --  stay binary32 in both, as they do in a real quantized model.
   type Weight_Format is (Float32, Q8_0);

   --  Build the fixture.
   --
   --  @param Result Newly allocated file bytes; the caller frees them.
   --  @param Format Format for the weight matrices.
   --  A quantized row is a whole number of thirty-two element blocks, so a
   --  model whose widths are eight and twelve cannot be quantized at all.
   --  These are the widths the quantized fixture uses instead; everything
   --  else about it is the same.
   Wide_Embedding    : constant := 32;
   Wide_Feed_Forward : constant := 64;
   Wide_Head_Size    : constant := 16;

   --  Build the fixture.
   --
   --  @param Result Newly allocated file bytes; the caller frees them.
   --  @param Format Format for the weight matrices. Q8_0 also widens the
   --    model, because the narrow one cannot hold a quantized row.
   --  @param End_Token Identifier the vocabulary declares as its end token.
   --    Varying it is how a test reaches the end-of-sequence path without
   --    depending on which token these weights happen to produce.
   procedure Build
     (Result    : out Model_Runner.Bytes.Byte_Array_Access;
      Format    : Weight_Format := Float32;
      End_Token : Natural := 2;
      Adds_Beginning : Boolean := True;
      Room      : Positive := Context;
      Qwen      : Boolean := False;
      Omit_Biases : Boolean := False);

end Tiny_Model;
