with Model_Runner.Heap_Buffers;

--  A command's options held on the heap: eighty kilobytes of fixed room,
--  which a copy made a frame that size wherever one was declared.
package Model_Runner.CLI.Options.Rooms is new Model_Runner.Heap_Buffers.Holders (Model_Runner.CLI.Options.Command);
