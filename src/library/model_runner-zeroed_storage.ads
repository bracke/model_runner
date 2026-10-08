with System;
with System.Storage_Elements;
with System.Storage_Pools;

--  Storage that arrives zeroed, from the C library's calloc.
--
--  The engine's arrays are all zero when they are made, and they were
--  made zero by writing every element: a key-value cache for a context of
--  thirty-two thousand positions on qwen3-8b is eight gigabytes, and writing
--  it took three and a half seconds of the start of every run and put all
--  of it in memory, while the run read a few hundred positions. calloc hands
--  a block that large straight from the kernel's own zeroed pages, which
--  cost nothing until they are touched, and zeroes a small one itself -- so
--  the arrays are as zero as they were, and a page costs memory when a
--  position lands on it.
package Model_Runner.Zeroed_Storage is

   type Pool is new System.Storage_Pools.Root_Storage_Pool with null record;

   --  @param Item The pool.
   --  @param Address Receives the zeroed block.
   --  @param Size Bytes wanted.
   --  @param Alignment Alignment wanted; calloc's own, sixteen, at most.
   --  @raise Storage_Error where calloc has nothing, or the alignment is
   --    more than it gives.
   overriding procedure Allocate
     (Item      : in out Pool;
      Address   : out System.Address;
      Size      : System.Storage_Elements.Storage_Count;
      Alignment : System.Storage_Elements.Storage_Count);

   --  @param Item The pool.
   --  @param Address The block, as Allocate gave it.
   --  @param Size Bytes it holds.
   --  @param Alignment Its alignment.
   overriding procedure Deallocate
     (Item      : in out Pool;
      Address   : System.Address;
      Size      : System.Storage_Elements.Storage_Count;
      Alignment : System.Storage_Elements.Storage_Count);

   --  @param Item The pool.
   --  @return No bound of its own: what the host has.
   overriding function Storage_Size
     (Item : Pool) return System.Storage_Elements.Storage_Count
   is (System.Storage_Elements.Storage_Count'Last);

   --  The one pool the engine's arrays come from.
   Arrays : Pool;

   --  Ask the host to back a block from this pool with large pages, before
   --  most of it is written.
   --
   --  For a block written a little at a time over a long life -- a
   --  session's cache, a position's rows a token: in the host's ordinary
   --  pages each token took a fault for every page it reached first, 17.5
   --  us a layer of phi-3 against 2 once the pages are there. Not for every
   --  large block: scratch made and given back a layer faults a large page
   --  in for each, and a DeepSeek-V2 prompt on the processor lost a tenth
   --  when every block of four megabytes asked. Advice only; the block is
   --  as zero as it was.
   --
   --  @param Start The block's first byte, or within it.
   --  @param Length Bytes from Start; nought asks nothing.
   procedure Prefer_Large
     (Start  : System.Address;
      Length : System.Storage_Elements.Storage_Count);

   --  Platform.Pages.Expect_Scattered, for a caller that holds a model's
   --  mapping: a few bytes read across it, or reading as usual again.
   --
   --  @param Start The first byte.
   --  @param Length Bytes from Start.
   --  @param Scattered True before the scattered reads, False after.
   procedure Expect_Scattered
     (Start     : System.Address;
      Length    : System.Storage_Elements.Storage_Count;
      Scattered : Boolean);

end Model_Runner.Zeroed_Storage;
