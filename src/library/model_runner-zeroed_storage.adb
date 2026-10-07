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

   ------------------
   -- Prefer_Large --
   ------------------

   procedure Prefer_Large
     (Start  : System.Address;
      Length : System.Storage_Elements.Storage_Count) is
   begin
      Model_Runner.Platform.Pages.Prefer_Large_At
        (Start, Model_Runner.Bytes.Byte_Count (Length));
   end Prefer_Large;

   -------------------
   -- Keep_Resident --
   -------------------

   procedure Keep_Resident
     (Start  : System.Address;
      Length : System.Storage_Elements.Storage_Count)
   is
      Kept : constant Boolean :=
        Model_Runner.Platform.Pages.Keep_Resident
          (Start, Model_Runner.Bytes.Byte_Count (Length));
      pragma Unreferenced (Kept);
   begin
      null;
   end Keep_Resident;

end Model_Runner.Zeroed_Storage;
