with Model_Runner.Heap_Buffers;

--  A vision encoder held on the heap: sixty-five kilobytes of fixed room,
--  which made a frame that size wherever one was declared.
package Model_Runner.Vision.Rooms is new Model_Runner.Heap_Buffers.Holders (Model_Runner.Vision.Encoder);
