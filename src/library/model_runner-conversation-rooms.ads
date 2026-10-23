with Model_Runner.Heap_Buffers;

--  A conversation held on the heap: a hundred and forty kilobytes of
--  fixed room, which made a frame that size wherever one was declared.
package Model_Runner.Conversation.Rooms is new Model_Runner.Heap_Buffers.Holders (Model_Runner.Conversation.History);
