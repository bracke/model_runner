with Interfaces.C;

with Model_Runner.Bytes;
with Model_Runner.Platform.Pages;

package body Model_Runner.Zeroed_Storage is

   use type System.Address;
   use type System.Storage_Elements.Storage_Count;

   function Calloc
     (Count : Interfaces.C.size_t;
      Size  : Interfaces.C.size_t) return System.Address
     with Import, Convention => C, External_Name => "calloc";

   procedure Free (Block : System.Address)
     with Import, Convention => C, External_Name => "free";

   --  The smallest array asked for in large pages: two of them.
   Large_Floor : constant System.Storage_Elements.Storage_Count :=
     4 * 1024 * 1024;

   --------------
   -- Allocate --
   --------------

   overriding procedure Allocate
     (Item      : in out Pool;
      Address   : out System.Address;
      Size      : System.Storage_Elements.Storage_Count;
      Alignment : System.Storage_Elements.Storage_Count)
   is
      pragma Unreferenced (Item);
   begin
      if Alignment > 16 then
         raise Storage_Error;
      end if;

      Address :=
        Calloc (1, Interfaces.C.size_t
                     (System.Storage_Elements.Storage_Count'Max (1, Size)));

      if Address = System.Null_Address then
         raise Storage_Error;
      end if;

      --  A large array in large pages where the host gives them. The big
      --  ones are a session's cache and its scratch, written a position at
      --  a time, and in the host's ordinary pages a generated token's rows
      --  of the cache took a fault for each page they reached first: 15 us
      --  a layer of phi-3, a hundredth of its token. Advice only, and the
      --  memory is still nought until written.
      if Size >= Large_Floor then
         Model_Runner.Platform.Pages.Prefer_Large_At
           (Address, Model_Runner.Bytes.Byte_Count (Size));
      end if;
   end Allocate;

   ----------------
   -- Deallocate --
   ----------------

   overriding procedure Deallocate
     (Item      : in out Pool;
      Address   : System.Address;
      Size      : System.Storage_Elements.Storage_Count;
      Alignment : System.Storage_Elements.Storage_Count)
   is
      pragma Unreferenced (Item, Size, Alignment);
   begin
      Free (Address);
   end Deallocate;

end Model_Runner.Zeroed_Storage;
