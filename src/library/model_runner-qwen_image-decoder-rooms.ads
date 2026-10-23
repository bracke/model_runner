with Model_Runner.Heap_Buffers;

--  A picture decoder held on the heap: a hundred and ten kilobytes of
--  fixed room, which made a frame that size wherever one was declared.
package Model_Runner.Qwen_Image.Decoder.Rooms is
  new Model_Runner.Heap_Buffers.Holders (Model_Runner.Qwen_Image.Decoder.Picture_Decoder);
