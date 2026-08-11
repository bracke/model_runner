with Ada.Directories;

with Interfaces.C.Strings;
with System.Storage_Elements;

package body Model_Runner.Platform.Mapping is

   use type Ada.Directories.File_Kind;
   use type Interfaces.C.int;
   use type System.Address;

   package B renames Model_Runner.Bytes;

   --  POSIX constants. Declared here rather than imported so that the values
   --  used are visible in the source and testable against the host headers.
   --
   --  This directory is compiled for Linux and for macOS, and a number that
   --  is right for one is not thereby right for the other: the tests crate
   --  had 8#1101# here for create-and-truncate, which is Linux's spelling
   --  and asks for something else on macOS, and a capture silently stopped
   --  truncating there. These three agree on both -- O_RDONLY is 0,
   --  PROT_READ 1 and MAP_PRIVATE 2 in <fcntl.h> and <sys/mman.h> on each --
   --  and that is a fact somebody checked rather than a fact about POSIX.
   --
   --  What would catch it if one of them drifted is the published
   --  transcript, which carries the line "memory mapped yes" and is
   --  compared on every host: a wrong MAP_PRIVATE stops the mapping and
   --  fails it. Nothing else would, because the mapping policy falls back
   --  to reading and a program that reads instead of mapping is correct and
   --  slow.
   O_RDONLY  : constant Interfaces.C.int := 0;
   PROT_READ : constant Interfaces.C.int := 1;
   MAP_PRIVATE : constant Interfaces.C.int := 2;

   function C_Open
     (Path  : Interfaces.C.Strings.chars_ptr;
      Flags : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "open";

   function C_Close (Handle : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "close";

   function C_Mmap
     (Address : System.Address;
      Length  : Interfaces.C.size_t;
      Protect : Interfaces.C.int;
      Flags   : Interfaces.C.int;
      Handle  : Interfaces.C.int;
      Offset  : Interfaces.C.long) return System.Address
   with Import, Convention => C, External_Name => "mmap";

   function C_Munmap
     (Address : System.Address;
      Length  : Interfaces.C.size_t) return Interfaces.C.int
   with Import, Convention => C, External_Name => "munmap";

   --  mmap reports failure as (void *) -1 rather than null.
   Map_Failed : constant System.Address :=
     System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address'Last);

   ------------------
   -- Is_Supported --
   ------------------

   function Is_Supported return Boolean is (True);

   ----------
   -- Open --
   ----------

   procedure Open
     (Item      : in out Region;
      Path      : String;
      Available : out Boolean)
   is
      File_Size : B.Byte_Count;
   begin
      Available := False;
      Close (Item);

      if Path = "" or else not Ada.Directories.Exists (Path) then
         return;
      end if;

      begin
         if Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File then
            return;
         end if;
         File_Size := B.Byte_Count (Ada.Directories.Size (Path));
      exception
         when others =>
            return;
      end;

      if File_Size = 0 or else File_Size > Max_Mapped_Bytes then
         return;
      end if;

      declare
         C_Path : Interfaces.C.Strings.chars_ptr :=
           Interfaces.C.Strings.New_String (Path);
         Handle : Interfaces.C.int;
         Base_Address : System.Address;
      begin
         Handle := C_Open (C_Path, O_RDONLY);
         Interfaces.C.Strings.Free (C_Path);

         if Handle < 0 then
            return;
         end if;

         Base_Address :=
           C_Mmap
             (Address => System.Null_Address,
              Length  => Interfaces.C.size_t (File_Size),
              Protect => PROT_READ,
              Flags   => MAP_PRIVATE,
              Handle  => Handle,
              Offset  => 0);

         if Base_Address = Map_Failed or else Base_Address = System.Null_Address
         then
            if C_Close (Handle) /= 0 then
               null;
            end if;
            return;
         end if;

         Item.Address := Base_Address;
         Item.Size := File_Size;
         Item.Handle := Long_Long_Integer (Handle);
         Available := True;
      end;
   exception
      when others =>
         Close (Item);
         Available := False;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Region) is
   begin
      if Item.Address /= System.Null_Address and then Item.Size > 0 then
         if C_Munmap (Item.Address, Interfaces.C.size_t (Item.Size)) /= 0 then
            null;
         end if;
      end if;

      if Item.Handle >= 0 then
         if C_Close (Interfaces.C.int (Item.Handle)) /= 0 then
            null;
         end if;
      end if;

      Item.Address := System.Null_Address;
      Item.Size := 0;
      Item.Handle := -1;
   exception
      --  Finalization must never propagate.
      when others =>
         Item.Address := System.Null_Address;
         Item.Size := 0;
         Item.Handle := -1;
   end Close;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : Region) return Boolean
   is (Item.Address /= System.Null_Address and then Item.Size > 0);

   ----------
   -- Base --
   ----------

   function Base (Item : Region) return System.Address is (Item.Address);

   ------------
   -- Length --
   ------------

   function Length (Item : Region) return B.Byte_Count is (Item.Size);

   ----------
   -- Copy --
   ----------

   procedure Copy
     (Item   : Region;
      Offset : B.Byte_Count;
      Target : out B.Byte_Array;
      Ok     : out Boolean) is
   begin
      Target := [others => 0];

      if not Is_Open (Item)
        or else Offset > Item.Size
        or else Target'Length > Item.Size - Offset
      then
         Ok := False;
         return;
      end if;

      declare
         View : constant B.Byte_Array (1 .. Item.Size)
         with Import, Address => Item.Address;
      begin
         Target := View (1 + Offset .. Offset + Target'Length);
      end;
      Ok := True;
   end Copy;

end Model_Runner.Platform.Mapping;
