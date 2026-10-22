with Ada.Calendar;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with System.Storage_Elements;
with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Host;
with Model_Runner.Platform;
with Model_Runner.Text;

package body Model_Runner.Panel_Cache is

   package B renames Model_Runner.Bytes;
   use type B.Byte_Count;
   use type Hostkit.Durability.Outcome;
   use type System.Storage_Elements.Integer_Address;

   protected Builds is
      procedure Next (Value : out Natural);
   private
      Count : Natural := 0;
   end Builds;

   protected body Builds is
      procedure Next (Value : out Natural) is
      begin
         Count := (if Count = Natural'Last then 0 else Count + 1);
         Value := Count;
      end Next;
   end Builds;

   ---------------
   -- Part_Name --
   ---------------

   function Part_Name (Path : String) return String is
      Seq : Natural;
   begin
      Builds.Next (Seq);
      declare
         Pid : constant String := Integer'Image (Hostkit.Host.Own_Process_Id);
         Own : constant String := Natural'Image (Seq);
      begin
         return Path & "." & Model_Runner.Text.Trim (Pid)
           & "-" & Own (Own'First + 1 .. Own'Last) & ".part";
      end;
   end Part_Name;

   --  Parts an ended process left -- killed while it built -- removed once
   --  they have sat an hour: a part another load is writing now is no
   --  leftover, and each name is a build's own so nothing reuses one.
   procedure Sweep_Parts (Path : String) is
      use Ada.Directories;
      use type Ada.Calendar.Time;
      Now  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Look : Search_Type;
      Item : Directory_Entry_Type;
   begin
      Start_Search
        (Look, Containing_Directory (Path), "*.panels*.part",
         [Ordinary_File => True, others => False]);
      while More_Entries (Look) loop
         Get_Next_Entry (Look, Item);
         if Now - Modification_Time (Item) > 3600.0 then
            begin
               Delete_File (Full_Name (Item));
            exception
               when others => null;
            end;
         end if;
      end loop;
      End_Search (Look);
   exception
      when others =>
         null;
   end Sweep_Parts;

   --------------
   -- Room_Now --
   --------------

   function Room_Now return Interfaces.Unsigned_64
   is (Model_Runner.Platform.Available_Memory);

   -----------------
   -- Keep_Newest --
   -----------------

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
         --  Not a part: that is a build under way, another load's perhaps.
         declare
            Name : constant String := Full_Name (Entry_Of);
         begin
            if Name'Length < 5 or else Name (Name'Last - 4 .. Name'Last) /= ".part" then
               Held := Held + 1;
               List (Held) :=
                 (Ada.Strings.Unbounded.To_Unbounded_String (Name),
                  Modification_Time (Entry_Of));
            end if;
         end;
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

   --------------
   -- Is_There --
   --------------

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

   --  The rename into Path on the device too, so the name and the bytes
   --  it names arrive together. Best effort: the bytes are already there.
   procedure Settle_Name (Path : String) is
      Outcome : constant Hostkit.Durability.Outcome :=
        Hostkit.Durability.Sync_Directory (Ada.Directories.Containing_Directory (Path));
   begin
      pragma Unreferenced (Outcome);
   end Settle_Name;

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
      Part  : constant String := Part_Name (Path);
      Out_F : File_Type;
      Head  : Ada.Streams.Stream_Element_Array (1 .. Header_Size) :=
        [others => 0];
   begin
      Panels := System.Null_Address;
      Ok := False;
      Item.Path := Ada.Strings.Unbounded.To_Unbounded_String (Path);
      Item.Part := Ada.Strings.Unbounded.To_Unbounded_String (Part);

      if Header'Length > Header_Size then
         return;
      end if;

      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      Sweep_Parts (Path);
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
      Part : constant String := Ada.Strings.Unbounded.To_String (Item.Part);

      --  The part file goes, the mapping stays: a failure here leaves the
      --  caller copying the panels out of the region before it releases
      --  it, and a region unmapped under that copy was a fault.
      procedure Drop_Part is
      begin
         if Ada.Directories.Exists (Part) then
            Ada.Directories.Delete_File (Part);
         end if;
      exception
         when others =>
            null;
      end Drop_Part;
   begin
      Ok := False;
      --  The panels on the device before the name says they are whole: a
      --  crash after a rename that outran the data would leave a file
      --  whose first panel verifies over zeros past it. They were written
      --  through the mapping, which only Linux makes the file's fsync
      --  cover: put into the file first, as every POSIX host needs.
      if Hostkit.Durability.Sync_Mapping
           (Model_Runner.Platform.Mapping.Base (Item.Region),
            Long_Long_Integer (Model_Runner.Platform.Mapping.Length (Item.Region)))
           = Hostkit.Durability.Failed
        or else Hostkit.Durability.Sync_File (Part) = Hostkit.Durability.Failed
      then
         Drop_Part;
         return;
      end if;

      --  Over whatever is there in one step: another load of the same
      --  model may have named its own a moment before, and a delete and
      --  a rename after it raced that load's.
      if not Hostkit.Fs.Replace_File (Part, Path) then
         Drop_Part;
         return;
      end if;
      Settle_Name (Path);
      Ok := True;

      Model_Runner.Platform.Trim_Directory
        (Ada.Directories.Containing_Directory (Path), "*.panels*",
         Model_Runner.Platform.Panel_Cache_Most, Keep => Path);
   exception
      when others =>
         --  Named already, the trim's trouble is the trim's.
         if not Ok then
            Drop_Part;
         end if;
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
      Part : constant String := Ada.Strings.Unbounded.To_String (Item.Part);
   begin
      Model_Runner.Platform.Mapping.Close (Item.Region);
      if Part /= "" and then Ada.Directories.Exists (Part) then
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
         Part  : constant String := Part_Name (Path);
         Out_F : File_Type;
      begin
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
         Sweep_Parts (Path);
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
         if Hostkit.Durability.Sync_File (Part) = Hostkit.Durability.Failed then
            raise Ada.IO_Exceptions.Use_Error;
         end if;
         --  Over another load's in one step, as Finish names its own.
         if not Hostkit.Fs.Replace_File (Part, Path) then
            raise Ada.IO_Exceptions.Use_Error;
         end if;
         Settle_Name (Path);

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
