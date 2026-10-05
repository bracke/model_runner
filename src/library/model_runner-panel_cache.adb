with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with System.Storage_Elements;

package body Model_Runner.Panel_Cache is

   package B renames Model_Runner.Bytes;
   use type B.Byte_Count;
   use type System.Storage_Elements.Integer_Address;

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
