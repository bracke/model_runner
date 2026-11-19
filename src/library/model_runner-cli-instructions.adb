with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.Platform;

package body Model_Runner.CLI.Instructions is

   use Ada.Strings.Unbounded;

   type Path_List is array (1 .. 64) of Unbounded_String;

   --  The files, outermost first: the settings folder's, then the session's
   --  folder's ancestors' down to its own.
   procedure Files_For (Directory : String; Paths : out Path_List; Count : out Natural) is
      Upward : Path_List;
      Up     : Natural := 0;
      Here   : Unbounded_String := To_Unbounded_String (Directory);
   begin
      Count := 0;
      declare
         Settings : constant String := Model_Runner.Platform.Config_File;
      begin
         if Settings /= "" then
            declare
               Own : constant String :=
                 Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Settings), File_Name);
            begin
               if Ada.Directories.Exists (Own) then
                  Count := Count + 1;
                  Paths (Count) := To_Unbounded_String (Ada.Directories.Full_Name (Own));
               end if;
            end;
         end if;
      exception
         when others =>
            null;
      end;
      --  From the session's folder up to the root, nearest first.
      loop
         declare
            Folder : constant String := To_String (Here);
            File   : constant String := Hostkit.Fs.Join (Folder, File_Name);
         begin
            if Ada.Directories.Exists (File) and then Up < Upward'Last then
               Up := Up + 1;
               Upward (Up) := To_Unbounded_String (File);
            end if;
            exit when Folder = "/" or else Folder = "";
            Here := To_Unbounded_String (Ada.Directories.Containing_Directory (Folder));
            exit when To_String (Here) = Folder;
         end;
      end loop;
      for Index in reverse 1 .. Up loop
         --  The settings folder's, met again on the way up, is read once.
         if Count = 0 or else Paths (1) /= Upward (Index) then
            exit when Count = Paths'Last;
            Count := Count + 1;
            Paths (Count) := Upward (Index);
         end if;
      end loop;
   exception
      when others =>
         null;
   end Files_For;

   function Read_Whole (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Text : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path, Form => "shared=yes");
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Text);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_Whole;

   function Enabled return Boolean
   is (Model_Runner.Platform.Standing_Instructions_Enabled);

   function Gathered (Directory : String) return String is
      Paths  : Path_List;
      Count  : Natural;
      Result : Unbounded_String;
   begin
      Files_For (Directory, Paths, Count);
      for Index in 1 .. Count loop
         declare
            Text : constant String := Read_Whole (To_String (Paths (Index)));
         begin
            if Text /= "" then
               Append (Result, "From " & To_String (Paths (Index)) & ":" & ASCII.LF & Text & ASCII.LF);
            end if;
         end;
      end loop;
      if Length (Result) > Most_Bytes then
         return Slice (Result, 1, Most_Bytes) & ASCII.LF
           & "[" & Natural'Image (Length (Result) - Most_Bytes) & " more bytes of instructions left out]";
      end if;
      return To_String (Result);
   end Gathered;

   function Found (Directory : String) return String is
      Paths  : Path_List;
      Count  : Natural;
      Result : Unbounded_String;
   begin
      Files_For (Directory, Paths, Count);
      for Index in 1 .. Count loop
         if Length (Result) > 0 then
            Append (Result, ", ");
         end if;
         Append (Result, Paths (Index));
      end loop;
      return To_String (Result);
   end Found;

end Model_Runner.CLI.Instructions;
