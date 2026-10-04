with Interfaces.C;
with System.Storage_Elements;

--  Large pages on Linux: madvise with MADV_HUGEPAGE over the whole pages
--  inside the buffer. Transparent huge pages set to "madvise" -- the common
--  default -- back an anonymous allocation with them only when asked; set to
--  "always" this is already so, and set to "never" the call is refused, and
--  either way the buffer is what it was.
package body Model_Runner.Platform.Pages is

   use System.Storage_Elements;
   use type Model_Runner.Bytes.Byte_Array_Access;

   Page        : constant := 4096;
   Huge_Advice : constant := 14;   --  MADV_HUGEPAGE

   function Madvise
     (Start  : System.Address;
      Length : Interfaces.C.size_t;
      Advice : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "madvise";

   procedure Prefer_Large (Bytes : Model_Runner.Bytes.Byte_Array_Access) is
   begin
      if Bytes = null or else Bytes.all'Length < 2 * Page then
         return;
      end if;

      declare
         First : constant Integer_Address :=
           To_Integer (Bytes.all (Bytes.all'First)'Address);
         Last  : constant Integer_Address :=
           First + Integer_Address (Bytes.all'Length);
         Start : constant Integer_Address := (First + Page - 1) / Page * Page;
         Whole : constant Integer_Address := (Last - Start) / Page * Page;
         Answer : Interfaces.C.int;
      begin
         if Whole > 0 then
            Answer := Madvise (To_Address (Start),
                               Interfaces.C.size_t (Whole), Huge_Advice);
            pragma Unreferenced (Answer);
         end if;
      end;
   end Prefer_Large;

end Model_Runner.Platform.Pages;
