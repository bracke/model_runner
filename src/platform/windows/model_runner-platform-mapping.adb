with Ada.Directories;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

--  Windows file mapping.
--
--  The same contract the POSIX body implements, over CreateFileMappingA and
--  MapViewOfFile instead of mmap. Windows needs two objects where POSIX needs
--  one: the file, and a mapping object made from it. Both are closed here.
--
--  Everything is read-only and nothing is ever written back: the model file is
--  opened for reading, shared for reading, and mapped for reading. A hostile
--  or merely surprising file cannot be modified through this.
package body Model_Runner.Platform.Mapping is

   package B renames Model_Runner.Bytes;

   use type Ada.Directories.File_Kind;
   use type Interfaces.C.int;
   use type System.Address;

   subtype DWORD is Interfaces.C.unsigned_long;
   subtype HANDLE is System.Address;

   Invalid_Handle : constant HANDLE :=
     System'To_Address (-1);

   --  Access rights and flags, spelled out rather than imported so that the
   --  values are visible next to the calls that use them.
   Generic_Read      : constant DWORD := 16#8000_0000#;
   File_Share_Read   : constant DWORD := 16#0000_0001#;
   Open_Existing     : constant DWORD := 3;
   File_Attr_Normal  : constant DWORD := 16#0000_0080#;
   Page_Read_Only    : constant DWORD := 16#0000_0002#;
   File_Map_Read     : constant DWORD := 16#0000_0004#;

   function Create_File
     (Name        : Interfaces.C.Strings.chars_ptr;
      Access_Mode : DWORD;
      Share_Mode  : DWORD;
      Security    : System.Address;
      Disposition : DWORD;
      Attributes  : DWORD;
      Template    : System.Address) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateFileA";

   function Create_File_Mapping
     (File       : HANDLE;
      Security   : System.Address;
      Protection : DWORD;
      Size_High  : DWORD;
      Size_Low   : DWORD;
      Name       : Interfaces.C.Strings.chars_ptr) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateFileMappingA";

   function Map_View_Of_File
     (Mapping     : HANDLE;
      Access_Mode : DWORD;
      Offset_High : DWORD;
      Offset_Low  : DWORD;
      Count       : Interfaces.C.size_t) return System.Address
   with Import, Convention => Stdcall, External_Name => "MapViewOfFile";

   function Unmap_View_Of_File (Base : System.Address) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "UnmapViewOfFile";

   function Close_Handle (Item : HANDLE) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "CloseHandle";

   --  A HANDLE is pointer-sized, and Region stores it as an integer so that
   --  one record serves every host.
   function To_Integer (Item : HANDLE) return Long_Long_Integer
   is (Long_Long_Integer (System.Storage_Elements.To_Integer (Item)));

   function To_Handle (Item : Long_Long_Integer) return HANDLE
   is (System.Storage_Elements.To_Address
         (System.Storage_Elements.Integer_Address (Item)));

   ---------------------
   -- Is_Supported --
   ---------------------

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
         File    : HANDLE;
         Mapping : HANDLE;
         Base    : System.Address;
      begin
         --  Read-only, and shared for reading only, so the mapping cannot be
         --  used to modify the model file.
         File :=
           Create_File
             (C_Path, Generic_Read, File_Share_Read, System.Null_Address,
              Open_Existing, File_Attr_Normal, System.Null_Address);
         Interfaces.C.Strings.Free (C_Path);

         if File = Invalid_Handle then
            return;
         end if;

         --  A size of zero means "the whole file", which is what is wanted
         --  and avoids splitting the length across two words.
         Mapping :=
           Create_File_Mapping
             (File, System.Null_Address, Page_Read_Only, 0, 0,
              Interfaces.C.Strings.Null_Ptr);

         if Mapping = System.Null_Address then
            if Close_Handle (File) = 0 then
               null;
            end if;
            return;
         end if;

         Base := Map_View_Of_File (Mapping, File_Map_Read, 0, 0, 0);

         if Base = System.Null_Address then
            if Close_Handle (Mapping) = 0 then
               null;
            end if;
            if Close_Handle (File) = 0 then
               null;
            end if;
            return;
         end if;

         Item.Address := Base;
         Item.Size := File_Size;
         Item.Handle := To_Integer (File);
         Item.Mapping := To_Integer (Mapping);
         Available := True;
      exception
         when others =>
            Close (Item);
            Available := False;
      end;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Region) is
   begin
      if Item.Address /= System.Null_Address then
         if Unmap_View_Of_File (Item.Address) = 0 then
            null;
         end if;
      end if;

      if Item.Mapping >= 0 then
         if Close_Handle (To_Handle (Item.Mapping)) = 0 then
            null;
         end if;
      end if;

      if Item.Handle >= 0 then
         if Close_Handle (To_Handle (Item.Handle)) = 0 then
            null;
         end if;
      end if;

      Item.Address := System.Null_Address;
      Item.Size := 0;
      Item.Handle := -1;
      Item.Mapping := -1;
   exception
      when others =>
         Item.Address := System.Null_Address;
         Item.Size := 0;
         Item.Handle := -1;
         Item.Mapping := -1;
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
