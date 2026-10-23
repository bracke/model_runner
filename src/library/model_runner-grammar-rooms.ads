with Model_Runner.Heap_Buffers;

--  A compiled grammar held on the heap: two hundred kilobytes of fixed
--  room, which made a frame that size wherever one was declared.
package Model_Runner.Grammar.Rooms is new Model_Runner.Heap_Buffers.Holders (Model_Runner.Grammar.Compiled);
