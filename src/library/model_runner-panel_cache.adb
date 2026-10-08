with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with System.Storage_Elements;
with Model_Runner.Platform;

package body Model_Runner.Panel_Cache is

   package B renames Model_Runner.Bytes;
   use type B.Byte_Count;
   use type System.Storage_Elements.Integer_Address;

   --------------
   -- Is_There --
   --------------

   procedure Keep_Newest (Prefix : String; Count : Natural) is
      use Ada.Directories;
      use type Ada.Calendar.Time;

      Folder : constant String := Containing_Directory (Prefix);
      Stem   : constant String := Simple_Name (Prefix);

      type Found is record
         Name : Ada.Strings.Unbounded.Unbounded_String;
         When_Made : Ada.Calendar.Time;
      end record;
      Most  : constant := 64;
      List  : array (1 .. Most) of Found;
      Held  : Natural := 0;
      Look  : Search_Type;
      Entry_Of : Directory_Entry_Type;
   begin
      Start_Search
        (Look, Folder, Stem & "*", [Ordinary_File => True, others => False]);
      while More_Entries (Look) and then Held < Most loop
         Get_Next_Entry (Look, Entry_Of);
         Held := Held + 1;
         List (Held) :=
           (Ada.Strings.Unbounded.To_Unbounded_String (Full_Name (Entry_Of)),
            Modification_Time (Entry_Of));
      end loop;
      End_Search (Look);

      --  Newest first.
      for I in 2 .. Held loop
         for J in reverse 2 .. I loop
            exit when List (J - 1).When_Made >= List (J).When_Made;
            declare
               Swap : constant Found := List (J);
            begin
               List (J) := List (J - 1);
               List (J - 1) := Swap;
            end;
         end loop;
      end loop;

      for I in Count + 1 .. Held loop
         begin
            Delete_File (Ada.Strings.Unbounded.To_String (List (I).Name));
         exception
            when others => null;
         end;
      end loop;
   exception
      when others =>
         null;
   end Keep_Newest;

   function Is_There (Path : String) return Boolean is
   begin
      return Path /= "" and then Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Is_There;

   ---------------
   -- Mark_Used --
   ---------------

   procedure Mark_Used (Path : String) is
   begin
      Model_Runner.Platform.Mark_Used (Path);
   end Mark_Used;

   Header_Size : constant := 4096;

   -----------------
   -- Begin_Build --
   -----------------

   procedure Begin_Build
     (Item   : in out Building;
      Path   : String;
      Header : String;
      Total  : B.Byte_Count;
      Panels : out System.Address;
      Ok     : out Boolean)
   is
      use Ada.Streams.Stream_IO;
      Part  : constant String := Path & ".part";
      Out_F : File_Type;
      Head  : Ada.Streams.Stream_Element_Array (1 .. Header_Size) :=
        [others => 0];
   begin
      Panels := System.Null_Address;
      Ok := False;
      Item.Path := Ada.Strings.Unbounded.To_Unbounded_String (Path);

      if Header'Length > Header_Size then
         return;
      end if;

      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      for Index in Header'Range loop
         Head (Ada.Streams.Stream_Element_Offset (Index - Header'First + 1)) :=
           Character'Pos (Header (Index));
      end loop;
      Create (Out_F, Out_File, Part);
      Write (Out_F, Head);
      Close (Out_F);

      Model_Runner.Platform.Mapping.Open_Writable
        (Item.Region, Part, Header_Size + Total, Ok);
      if not Ok then
         Ada.Directories.Delete_File (Part);
         return;
      end if;

      Panels :=
        System.Storage_Elements.To_Address
          (System.Storage_Elements.To_Integer
             (Model_Runner.Platform.Mapping.Base (Item.Region))
           + Header_Size);
   exception
      when others =>
         if Is_Open (Out_F) then
            Close (Out_F);
         end if;
         Abandon (Item);
         Panels := System.Null_Address;
         Ok := False;
   end Begin_Build;

   ------------
   -- Finish --
   ------------

   procedure Finish (Item : in out Building; Ok : out Boolean) is
      Path : constant String := Ada.Strings.Unbounded.To_String (Item.Path);
   begin
      Ok := False;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      Ada.Directories.Rename (Path & ".part", Path);
      Ok := True;

      Model_Runner.Platform.Trim_Directory
        (Ada.Directories.Containing_Directory (Path), "*.panels*",
         Model_Runner.Platform.Panel_Cache_Most, Keep => Path);
   exception
      when others =>
         Abandon (Item);
         Ok := False;
   end Finish;

   -------------
   -- Release --
   -------------

   procedure Release (Item : in out Building) is
   begin
      Model_Runner.Platform.Mapping.Close (Item.Region);
   end Release;

   -------------
   -- Abandon --
   -------------

   procedure Abandon (Item : in out Building) is
      Part : constant String :=
        Ada.Strings.Unbounded.To_String (Item.Path) & ".part";
   begin
      Model_Runner.Platform.Mapping.Close (Item.Region);
      if Part /= ".part" and then Ada.Directories.Exists (Part) then
         Ada.Directories.Delete_File (Part);
      end if;
   exception
      when others =>
         null;
   end Abandon;

   -------------
   -- Writing --
   -------------

   --  A file beside its final name, renamed into it whole, so a load never
   --  maps half of one. Anything that goes wrong -- no room, no directory --
   --  leaves no file and costs nothing but the attempt.
   task body Writing is
      use Ada.Streams.Stream_IO;

      Header_Bytes : constant := 4096;
      Chunk        : constant := 64 * 1024 * 1024;

      Path_Text  : Ada.Strings.Unbounded.Unbounded_String;
      Head_Text  : Ada.Strings.Unbounded.Unbounded_String;
      Data       : System.Address := System.Null_Address;
      Size_Of    : B.Byte_Count := 0;
   begin
      accept Start
        (Path   : String;
         Header : String;
         From   : System.Address;
         Total  : B.Byte_Count)
      do
         Path_Text := Ada.Strings.Unbounded.To_Unbounded_String (Path);
         Head_Text := Ada.Strings.Unbounded.To_Unbounded_String (Header);
         Data := From;
         Size_Of := Total;
      end Start;

      declare
         Path  : constant String := Ada.Strings.Unbounded.To_String (Path_Text);
         Text  : constant String := Ada.Strings.Unbounded.To_String (Head_Text);
         Part  : constant String := Path & ".part";
         Out_F : File_Type;
      begin
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
         Create (Out_F, Out_File, Part);

         declare
            Head : Ada.Streams.Stream_Element_Array (1 .. Header_Bytes) :=
              [others => 0];
         begin
            for Index in Text'Range loop
               Head (Ada.Streams.Stream_Element_Offset
                       (Index - Text'First + 1)) :=
                 Character'Pos (Text (Index));
            end loop;
            Write (Out_F, Head);
         end;

         declare
            Done : B.Byte_Count := 0;
         begin
            while Done < Size_Of loop
               declare
                  Size  : constant B.Byte_Count :=
                    B.Byte_Count'Min (Chunk, Size_Of - Done);
                  Piece : Ada.Streams.Stream_Element_Array
                    (1 .. Ada.Streams.Stream_Element_Offset (Size))
                    with Import,
                         Address =>
                           System.Storage_Elements.To_Address
                             (System.Storage_Elements.To_Integer (Data)
                              + System.Storage_Elements.Integer_Address (Done));
               begin
                  Write (Out_F, Piece);
                  Done := Done + Size;
               end;
            end loop;
         end;

         Close (Out_F);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         Ada.Directories.Rename (Part, Path);

         --  The cache kept to its bound, these panels whatever their size.
         Model_Runner.Platform.Trim_Directory
           (Ada.Directories.Containing_Directory (Path), "*.panels*",
            Model_Runner.Platform.Panel_Cache_Most, Keep => Path);
      exception
         when others =>
            if Is_Open (Out_F) then
               Close (Out_F);
            end if;
            if Ada.Directories.Exists (Part) then
               Ada.Directories.Delete_File (Part);
            end if;
      end;
   exception
      when others =>
         null;
   end Writing;

end Model_Runner.Panel_Cache;
