with Model_Runner.Heap_Buffers;

--  A session's seer held on the heap: seventy kilobytes of fixed room,
--  which made a frame that size wherever one was declared.
package Model_Runner.CLI.Pictures.Rooms is new Model_Runner.Heap_Buffers.Holders (Model_Runner.CLI.Pictures.Seer);
