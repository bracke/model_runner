with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

with Hostkit.Fs;

with Model_Runner.Framework.Records;

package body Model_Runner.Framework.Files is

   package E renames Model_Runner.Errors;
   package Dirs renames Ada.Directories;
   package Stream_IO renames Ada.Streams.Stream_IO;

   use Ada.Strings.Unbounded;
   use type Dirs.File_Kind;
   use type Dirs.File_Size;

   package Sorting is new Name_Lists.Generic_Sorting;

   type String_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);

   ------------------
   -- Write_Failed --
   ------------------

   procedure Write_Failed
     (Path   : String;
      Status : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Transaction_Failed);
      E.Add_Text (Status, "path", Path, E.Param_Path);
   end Write_Failed;

   ---------------
   -- Read_Text --
   ---------------

   procedure Read_Text
     (Path   : String;
      Text   : out Unbounded_String;
      Status : out E.Error_Info)
   is
      File   : Stream_IO.File_Type;
      Buffer : String_Access;
   begin
      Text := Null_Unbounded_String;
      Status := E.Success;

      declare
         Size : constant Dirs.File_Size := Dirs.Size (Path);
      begin
         if Size > Records.Max_Bytes then
            Status := E.Make (E.IO_File_Too_Large);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            E.Add_Integer
              (Status, "size", Long_Long_Integer (Size), E.Param_Bytes);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Records.Max_Bytes),
               E.Param_Bytes);
            return;
         end if;

         Buffer := new String (1 .. Natural (Size));
      end;

      Stream_IO.Open (File, Stream_IO.In_File, Path);

      --  Read whole, as bytes: String'Read goes a small block at a time,
      --  and the state's indexes are megabytes.
      if Buffer'Length > 0 then
         declare
            use type Ada.Streams.Stream_Element_Offset;
            Bytes : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Buffer'Length))
            with Import, Address => Buffer.all'Address;
            Last  : Ada.Streams.Stream_Element_Offset := 0;
            Got   : Ada.Streams.Stream_Element_Offset;
         begin
            while Last < Bytes'Last loop
               Stream_IO.Read (File, Bytes (Last + 1 .. Bytes'Last), Got);
               exit when Got <= Last;
               Last := Got;
            end loop;
            if Last < Bytes'Last then
               raise Stream_IO.End_Error;
            end if;
         end;
      end if;
      Stream_IO.Close (File);
      Text := To_Unbounded_String (Buffer.all);
      Free (Buffer);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Free (Buffer);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
   end Read_Text;

   ----------------
   -- Write_Text --
   ----------------

   procedure Write_Text
     (Path   : String;
      Text   : String;
      Status : out E.Error_Info)
   is
      File : Stream_IO.File_Type;
   begin
      Status := E.Success;
      Stream_IO.Create (File, Stream_IO.Out_File, Path);
      String'Write (Stream_IO.Stream (File), Text);
      Stream_IO.Close (File);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Write_Failed (Path, Status);
   end Write_Text;

   -----------------
   -- Write_Whole --
   -----------------

   procedure Write_Whole
     (Path   : String;
      Text   : String;
      Status : out E.Error_Info) is
   begin
      Write_Text (Path & Partial_Suffix, Text, Status);
      if E.Is_Ok (Status)
        and then not Hostkit.Fs.Replace_File (Path & Partial_Suffix, Path)
      then
         Write_Failed (Path, Status);
      end if;
   end Write_Whole;

   -----------------------
   -- Delete_If_Present --
   -----------------------

   function Delete_If_Present (Path : String) return Boolean is
   begin
      if Dirs.Exists (Path) then
         Dirs.Delete_File (Path);
      end if;
      return True;
   exception
      when others =>
         return False;
   end Delete_If_Present;

   -------------
   -- Discard --
   -------------

   procedure Discard (Path : String) is
      Gone : constant Boolean := Delete_If_Present (Path);
   begin
      pragma Unreferenced (Gone);
   end Discard;

   --------------------
   -- Make_Directory --
   --------------------

   function Make_Directory (Path : String) return Boolean is
   begin
      if not Dirs.Exists (Path) then
         Dirs.Create_Path (Path);
      end if;
      return Dirs.Kind (Path) = Dirs.Directory;
   exception
      when others =>
         return False;
   end Make_Directory;

   --------------
   -- Files_In --
   --------------

   function Files_In (Directory : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Search : Dirs.Search_Type;
      Found  : Dirs.Directory_Entry_Type;
   begin
      if not Dirs.Exists (Directory)
        or else Dirs.Kind (Directory) /= Dirs.Directory
      then
         return Result;
      end if;

      Dirs.Start_Search
        (Search, Directory, "",
         [Dirs.Ordinary_File => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Found);
         Result.Append (Dirs.Simple_Name (Found));
      end loop;
      Dirs.End_Search (Search);

      Sorting.Sort (Result);
      return Result;
   exception
      when others =>
         return Result;
   end Files_In;

   -----------------
   -- Remove_Tree --
   -----------------

   procedure Remove_Tree (Path : String) is
      use Ada.Directories;
      Search : Search_Type;
      Found  : Directory_Entry_Type;
      Names  : Name_Lists.Vector;
   begin
      if Hostkit.Fs.Is_Link (Path) then
         declare
            Gone : constant Boolean := Hostkit.Fs.Delete_Link (Path);
            pragma Unreferenced (Gone);
         begin
            return;
         end;
      elsif not Exists (Path) then
         return;
      elsif Kind (Path) /= Directory then
         Delete_File (Path);
         return;
      end if;
      Start_Search (Search, Path, "");
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Found);
         if Simple_Name (Found) not in "." | ".." then
            Names.Append (Simple_Name (Found));
         end if;
      end loop;
      End_Search (Search);
      for Name of Names loop
         Remove_Tree (Hostkit.Fs.Join (Path, Name));
      end loop;
      Delete_Directory (Path);
   exception
      when others =>
         null;
   end Remove_Tree;

end Model_Runner.Framework.Files;
