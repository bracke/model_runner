with Interfaces.C;

package body Model_Runner.Zeroed_Storage is

   use type System.Address;
   use type System.Storage_Elements.Storage_Count;

   function Calloc
     (Count : Interfaces.C.size_t;
      Size  : Interfaces.C.size_t) return System.Address
     with Import, Convention => C, External_Name => "calloc";

   procedure Free (Block : System.Address)
     with Import, Convention => C, External_Name => "free";

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
