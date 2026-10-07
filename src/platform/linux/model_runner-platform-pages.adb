with Model_Runner.Platform.Mapped_Ranges;
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
   use type Model_Runner.Bytes.Byte_Count;

   Page        : constant := 4096;
   Huge_Advice : constant := 14;   --  MADV_HUGEPAGE
   Out_Advice  : constant := 21;   --  MADV_PAGEOUT

   function Madvise
     (Start  : System.Address;
      Length : Interfaces.C.size_t;
      Advice : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "madvise";

   procedure Prefer_Large_At
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count)
   is
   begin
      if Length < 2 * Page then
         return;
      end if;

      declare
         First : constant Integer_Address := To_Integer (Start);
         Last  : constant Integer_Address := First + Integer_Address (Length);
         Begin_At : constant Integer_Address :=
           (First + Page - 1) / Page * Page;
         Whole : constant Integer_Address := (Last - Begin_At) / Page * Page;
         Answer : Interfaces.C.int;
      begin
         if Whole > 0 then
            Answer := Madvise (To_Address (Begin_At),
                               Interfaces.C.size_t (Whole), Huge_Advice);
            pragma Unreferenced (Answer);
         end if;
      end;
   end Prefer_Large_At;

   procedure Prefer_Large (Bytes : Model_Runner.Bytes.Byte_Array_Access) is
   begin
      if Bytes = null or else Bytes.all'Length = 0 then
         return;
      end if;

      Prefer_Large_At
        (Bytes.all (Bytes.all'First)'Address,
         Model_Runner.Bytes.Byte_Count (Bytes.all'Length));
   end Prefer_Large;

   procedure Page_Out
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count)
   is
   begin
      --  A file's mapping only: memory of the process's own given this
      --  advice goes to swap, which is what it is here to spare.
      if Length < Page
        or else not Model_Runner.Platform.Mapped_Ranges.Holds (Start, Length)
      then
         return;
      end if;

      declare
         First : constant Integer_Address := To_Integer (Start);
         Last  : constant Integer_Address := First + Integer_Address (Length);
         Begin_At : constant Integer_Address :=
           (First + Page - 1) / Page * Page;
         Whole : constant Integer_Address :=
           (if Last > Begin_At then (Last - Begin_At) / Page * Page else 0);
         Answer : Interfaces.C.int;
      begin
         if Whole > 0 then
            Answer := Madvise (To_Address (Begin_At),
                               Interfaces.C.size_t (Whole), Out_Advice);
            pragma Unreferenced (Answer);
         end if;
      end;
   end Page_Out;

end Model_Runner.Platform.Pages;
