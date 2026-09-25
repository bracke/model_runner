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

end Model_Runner.Zeroed_Storage;
