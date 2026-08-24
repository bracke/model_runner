with Ada.Directories;

with Ada.IO_Exceptions;
with Ada.Streams;
with Interfaces;

package body Model_Runner.Byte_Sources.Files is

   use type Ada.Directories.File_Kind;
   use type Ada.Streams.Stream_Element_Offset;
   use type Model_Runner.Bytes.Byte_Count;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package Map renames Model_Runner.Platform.Mapping;
   package Stream_IO renames Ada.Streams.Stream_IO;

   --  Largest single read issued to the file handle. Reads larger than this
   --  are split, so a hostile length cannot ask for one enormous buffer.
   Read_Chunk : constant B.Byte_Count := 1024 * 1024;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item      : in out File_Source;
      Path      : String;
      Policy    : Mapping_Policy := Mapping_Automatic;
      Max_Bytes : B.Byte_Count := 0;
      Status    : out E.Error_Info)
   is
      Mapped_Ok : Boolean := False;
   begin
      Close (Item);
      Status := E.Success;

      if Path = "" or else Path'Length > Max_Path_Length then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      if not Ada.Directories.Exists (Path) then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      begin
         if Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File then
            Status := E.Make (E.IO_Not_A_Regular_File);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
         end if;
         Item.Length := B.Byte_Count (Ada.Directories.Size (Path));
      exception
         when others =>
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
      end;

      if Max_Bytes /= 0 and then Item.Length > Max_Bytes then
         Status := E.Make (E.IO_File_Too_Large);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Integer
           (Status, "size", Long_Long_Integer (Item.Length), E.Param_Bytes);
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Max_Bytes), E.Param_Bytes);
         Item.Length := 0;
         return;
      end if;

      begin
         --  Shared, because a program may want the same file open twice:
         --  a model and a draft model may be the same file, and the
         --  language's default for reading is exclusive within one program
         --  -- so the second open failed with "cannot open", which is a
         --  true sentence about a file that is plainly there.
         --
         --  Read-only either way. Two readers of one file need nothing from
         --  each other.
         Stream_IO.Open
           (Item.File, Stream_IO.In_File, Path, Form => "shared=yes");
      exception
         when Ada.IO_Exceptions.Name_Error
            | Ada.IO_Exceptions.Use_Error
            | Ada.IO_Exceptions.Status_Error =>
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            Item.Length := 0;
            return;
      end;

      Item.Opened := True;
      Item.Path_Last := Path'Length;
      Item.Path_Text (1 .. Path'Length) := Path;

      if Policy /= Mapping_Disabled then
         Map.Open (Item.Map, Path, Mapped_Ok);
         Item.Mapped := Mapped_Ok and then Map.Length (Item.Map) = Item.Length;
         if not Item.Mapped then
            Map.Close (Item.Map);
         end if;
      end if;

      if Policy = Mapping_Required and then not Item.Mapped then
         Close (Item);
         Status := E.Make (E.Lifecycle_Mapping_Required);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out File_Source) is
   begin
      Map.Close (Item.Map);
      Item.Mapped := False;

      if Stream_IO.Is_Open (Item.File) then
         Stream_IO.Close (Item.File);
      end if;

      Item.Opened := False;
      Item.Length := 0;
      Item.Path_Last := 0;
   exception
      --  Close is called from failure paths and from finalization; it must not
      --  propagate.
      when others =>
         Item.Opened := False;
         Item.Mapped := False;
         Item.Length := 0;
         Item.Path_Last := 0;
   end Close;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : File_Source) return Boolean is (Item.Opened);

   -------------------
   -- Size_Changed --
   -------------------

   function Size_Changed (Item : File_Source) return Boolean is
   begin
      if not Item.Opened or else Item.Path_Last = 0 then
         return False;
      end if;

      return B.Byte_Count
        (Ada.Directories.Size (Item.Path_Text (1 .. Item.Path_Last)))
        /= Item.Length;
   exception
      when others =>
         return True;
   end Size_Changed;

   ----------
   -- Size --
   ----------

   overriding function Size (Self : File_Source) return B.Byte_Count
   is (Self.Length);

   ----------
   -- Read --
   ----------

   overriding procedure Read
     (Self   : in out File_Source;
      Offset : B.Byte_Count;
      Target : out B.Byte_Array;
      Status : out E.Error_Info)
   is
      --  Every path that leaves Target unfilled defines it here. Zeroing it
      --  first and then copying over it writes every byte twice, which for a
      --  caller reading straight into a large buffer is the whole of it.
      procedure Report_Truncated is
      begin
         Target := [others => 0];
         Status := E.Make (E.GGUF_Truncated);
         E.Add_Integer
           (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
         E.Add_Integer
           (Status, "length", Long_Long_Integer (Target'Length), E.Param_Bytes);
         E.Add_Integer
           (Status, "size", Long_Long_Integer (Self.Length), E.Param_Bytes);
         E.Set_Location (Status, Interfaces.Unsigned_64 (Offset));
      end Report_Truncated;
   begin
      Status := E.Success;

      if not Self.Opened then
         Target := [others => 0];
         Status := E.Make (E.IO_Read_Failed);
         return;
      end if;

      if Offset > Self.Length
        or else Target'Length > Self.Length - Offset
      then
         Report_Truncated;
         return;
      end if;

      if Target'Length = 0 then
         return;
      end if;

      if Self.Mapped then
         declare
            Ok : Boolean;
         begin
            Map.Copy (Self.Map, Offset, Target, Ok);
            if not Ok then
               Report_Truncated;
            end if;
         end;
         return;
      end if;

      declare
         Produced : B.Byte_Count := 0;
      begin
         Stream_IO.Set_Index
           (Self.File, Stream_IO.Positive_Count (Offset + 1));

         while Produced < Target'Length loop
            declare
               Wanted : constant B.Byte_Count :=
                 B.Byte_Count'Min (Read_Chunk, Target'Length - Produced);
               Buffer : Ada.Streams.Stream_Element_Array
                 (1 .. Ada.Streams.Stream_Element_Offset (Wanted));
               Last   : Ada.Streams.Stream_Element_Offset;
            begin
               Ada.Streams.Read (Stream_IO.Stream (Self.File).all, Buffer, Last);

               if Last < Buffer'First then
                  Report_Truncated;
                  return;
               end if;

               for Index in Buffer'First .. Last loop
                  Target (Target'First + Produced + B.Byte_Count (Index - 1)) :=
                    B.Byte (Buffer (Index));
               end loop;

               Produced := Produced + B.Byte_Count (Last);
            end;
         end loop;
      exception
         when Ada.IO_Exceptions.End_Error =>
            Report_Truncated;
         when others =>
            Target := [others => 0];
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Integer
              (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
      end;
   end Read;

   ---------------
   -- Is_Mapped --
   ---------------

   overriding function Is_Mapped (Self : File_Source) return Boolean
   is (Self.Mapped);

   ----------
   -- Base --
   ----------

   overriding function Base (Self : File_Source) return System.Address
   is (if Self.Mapped
       then Model_Runner.Platform.Mapping.Base (Self.Map)
       else System.Null_Address);

   ----------
   -- Name --
   ----------

   overriding function Name (Self : File_Source) return String
   is (Self.Path_Text (1 .. Self.Path_Last));

end Model_Runner.Byte_Sources.Files;
