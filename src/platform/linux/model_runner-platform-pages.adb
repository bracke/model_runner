with Ada.Unchecked_Deallocation;
with Interfaces;
with Model_Runner.Platform.Mapped_Ranges;
with Interfaces.C;
with Interfaces.C.Strings;
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
   Random_Advice : constant := 1;  --  MADV_RANDOM
   Normal_Advice : constant := 0;  --  MADV_NORMAL
   Need_Advice   : constant := 3;  --  MADV_WILLNEED

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

   procedure Expect_Scattered
     (Start     : System.Address;
      Length    : Model_Runner.Bytes.Byte_Count;
      Scattered : Boolean)
   is
   begin
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
            Answer := Madvise
              (To_Address (Begin_At), Interfaces.C.size_t (Whole),
               (if Scattered then Random_Advice else Normal_Advice));
            pragma Unreferenced (Answer);
         end if;
      end;
   end Expect_Scattered;

   --  Read_Direct's calls: the file opened again past the host's cache,
   --  through the process's own handle on it, and an aligned buffer the
   --  reads land in.
   O_Direct    : constant := 8#40000#;

   --  And closed across an exec: a tool's child started while a matrix is
   --  copied would otherwise hold the model's file open past the run.
   O_Cloexec   : constant := 8#2000000#;
   Prot_Rw     : constant := 3;
   Map_Private_Anonymous : constant := 16#22#;
   Direct_Least : constant := 1_048_576;
   Direct_Chunk : constant := 8_388_608;

   function C_Open
     (Path : Interfaces.C.Strings.chars_ptr; Flags : Interfaces.C.int)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "open";

   function C_Close (Handle : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "close";

   function C_Pread
     (Handle : Interfaces.C.int;
      Buffer : System.Address;
      Count  : Interfaces.C.size_t;
      Offset : Interfaces.C.long) return Interfaces.C.long
   with Import, Convention => C, External_Name => "pread";

   function C_Mmap
     (Address : System.Address;
      Length  : Interfaces.C.size_t;
      Protect : Interfaces.C.int;
      Flags   : Interfaces.C.int;
      Handle  : Interfaces.C.int;
      Offset  : Interfaces.C.long) return System.Address
   with Import, Convention => C, External_Name => "mmap";

   function C_Munmap
     (Address : System.Address; Length : Interfaces.C.size_t)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "munmap";

   procedure Read_Direct
     (From   : System.Address;
      Into   : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Done   : out Boolean)
   is
      use type Interfaces.C.int;
      use type Interfaces.C.long;
      use type System.Address;

      Handle : Long_Long_Integer;
      Offset : Model_Runner.Bytes.Byte_Count;
      Again  : Interfaces.C.int := -1;
      Bounce : System.Address := System.Null_Address;
   begin
      Done := False;

      --  A small run is not worth a second opening of the file.
      if Length < Direct_Least
        or else not Model_Runner.Platform.Mapped_Ranges.Locate
                      (From, Length, Handle, Offset)
      then
         return;
      end if;

      declare
         Image : constant String := Long_Long_Integer'Image (Handle);
         Name  : constant String :=
           "/proc/self/fd/" & Image (Image'First + 1 .. Image'Last);
         C_Name : Interfaces.C.Strings.chars_ptr :=
           Interfaces.C.Strings.New_String (Name);
      begin
         Again := C_Open (C_Name, O_Direct + O_Cloexec);
         Interfaces.C.Strings.Free (C_Name);
      exception
         when others =>
            Model_Runner.Platform.Mapped_Ranges.Located_Done;
            raise;
      end;
      --  Held by a handle of its own now, or not at all: the region may go.
      Model_Runner.Platform.Mapped_Ranges.Located_Done;
      if Again < 0 then
         return;
      end if;

      Bounce := C_Mmap (System.Null_Address, Direct_Chunk, Prot_Rw,
                        Map_Private_Anonymous, -1, 0);
      if Bounce = To_Address (Integer_Address'Last)
        or else Bounce = System.Null_Address
      then
         if C_Close (Again) /= 0 then
            null;
         end if;
         return;
      end if;

      declare
         --  From the whole page the run begins in: a read past the cache
         --  starts and ends where the drive's blocks do.
         At_Page : Model_Runner.Bytes.Byte_Count := Offset / Page * Page;
         Skip    : Model_Runner.Bytes.Byte_Count := Offset - At_Page;
         Copied  : Model_Runner.Bytes.Byte_Count := 0;
         Got     : Interfaces.C.long;
         Failed  : Boolean := False;
      begin
         while Copied < Length loop
            --  As much as is left, to the page it ends in, and no more:
            --  a read past the run is the drive's time spent for nothing.
            Got := C_Pread
              (Again, Bounce,
               Interfaces.C.size_t
                 (Model_Runner.Bytes.Byte_Count'Min
                    (Direct_Chunk,
                     (Skip + Length - Copied + Page - 1) / Page * Page)),
               Interfaces.C.long (At_Page));
            if Got <= Interfaces.C.long (Skip) then
               Failed := True;
               exit;
            end if;

            declare
               Take : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count'Min
                   (Model_Runner.Bytes.Byte_Count (Got) - Skip,
                    Length - Copied);
               Target : Model_Runner.Bytes.Byte_Array (1 .. Take)
                 with Import, Address => Into + Storage_Offset (Copied);
               Origin : constant Model_Runner.Bytes.Byte_Array (1 .. Take)
                 with Import, Address => Bounce + Storage_Offset (Skip);
            begin
               Target := Origin;
               Copied := Copied + Take;
            end;

            At_Page := At_Page + Model_Runner.Bytes.Byte_Count (Got);
            Skip := 0;
         end loop;

         if C_Munmap (Bounce, Direct_Chunk) /= 0 then
            null;
         end if;
         Bounce := System.Null_Address;
         if C_Close (Again) /= 0 then
            null;
         end if;
         Again := -1;
         Done := not Failed;
      end;
   exception
      --  A fault in the copy is a run not read here, and the caller reads
      --  it through the mapping; the buffer and the second opening go
      --  with it rather than staying for the life of the process.
      when others =>
         if Bounce /= System.Null_Address
           and then Bounce /= To_Address (Integer_Address'Last)
         then
            if C_Munmap (Bounce, Direct_Chunk) /= 0 then
               null;
            end if;
         end if;
         if Again >= 0 then
            if C_Close (Again) /= 0 then
               null;
            end if;
         end if;
         Done := False;
   end Read_Direct;

   procedure Fetch_Soon
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count)
   is
   begin
      if Length = 0
        or else not Model_Runner.Platform.Mapped_Ranges.Holds (Start, Length)
      then
         return;
      end if;

      declare
         First    : constant Integer_Address := To_Integer (Start);
         Begin_At : constant Integer_Address := First / Page * Page;
         Last     : constant Integer_Address := First + Integer_Address (Length);
         Answer   : Interfaces.C.int;
      begin
         Answer := Madvise (To_Address (Begin_At),
                            Interfaces.C.size_t (Last - Begin_At),
                            Need_Advice);
         pragma Unreferenced (Answer);
      end;
   end Fetch_Soon;

   function Mincore
     (Start  : System.Address;
      Length : Interfaces.C.size_t;
      Vector : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "mincore";

   function Held_Percent
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count) return Natural
   is
      use type Interfaces.C.int;
      First : constant Integer_Address := To_Integer (Start) / Page * Page;
      Pages : constant Integer_Address :=
        (To_Integer (Start) + Integer_Address (Length) - First + Page - 1) / Page;
      type Flags is array (1 .. Pages) of Interfaces.Unsigned_8;
      type Flags_Access is access Flags;
      procedure Free is new Ada.Unchecked_Deallocation (Flags, Flags_Access);
      Vector : Flags_Access;
      Held   : Integer_Address := 0;
   begin
      if Length = 0 or else Pages = 0 then
         return 100;
      end if;
      Vector := new Flags;
      if Mincore (To_Address (First), Interfaces.C.size_t (Pages * Page), Vector.all'Address) /= 0 then
         Free (Vector);
         return 100;
      end if;
      for Flag of Vector.all loop
         if Interfaces."/=" (Interfaces."and" (Flag, 1), 0) then
            Held := Held + 1;
         end if;
      end loop;
      Free (Vector);
      return Natural (Held * 100 / Pages);
   exception
      when others =>
         Free (Vector);
         return 100;
   end Held_Percent;

end Model_Runner.Platform.Pages;
