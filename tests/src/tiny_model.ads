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
   procedure Write (Path : String);

   --  Build the model file.
   --
   --  @param Result Newly allocated file bytes; the caller frees them.
   procedure Build (Result : out Model_Runner.Bytes.Byte_Array_Access);

end Tiny_Model;
