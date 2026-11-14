with Ada.Strings.Maps;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.Platform;

package body Model_Runner.CLI.Custom_Commands is

   use Ada.Strings.Unbounded;

   --  The two folders, the session's first.
   function Project_Folder return String
   is (Ada.Directories.Current_Directory & "/.model_runner/commands");

   function Own_Folder return String is
      Settings : constant String := Model_Runner.Platform.Config_File;
   begin
      return (if Settings = "" then ""
              else Ada.Directories.Containing_Directory (Settings) & "/commands");
   exception
      when others =>
         return "";
   end Own_Folder;

   type Folder_List is array (1 .. 2) of Unbounded_String;

   function Folders return Folder_List
   is ([To_Unbounded_String (Project_Folder), To_Unbounded_String (Own_Folder)]);

   --  A name a file may have: letters, digits, - and _ alone, so no name
   --  reaches outside the folder.
   function Fit (Name : String) return Boolean is
   begin
      if Name = "" then
         return False;
      end if;
      for C of Name loop
         if C not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' then
            return False;
         end if;
      end loop;
      return True;
   end Fit;

   function File_Of (Name : String) return String is
   begin
      if not Fit (Name) then
         return "";
      end if;
      for Folder of Folders loop
         declare
            Path : constant String := To_String (Folder) & "/" & Name & ".md";
         begin
            if To_String (Folder) /= "" and then Ada.Directories.Exists (Path) then
               return Path;
            end if;
         end;
      end loop;
      return "";
   end File_Of;

   function Text_Of (Path : String) return String is
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
   end Text_Of;

   --  Text without the blanks and line ends after it.
   function Trim_End (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trim_End;

   function Message (Path, Arguments : String) return String is
      Text  : constant String := Text_Of (Path);
      Mark  : constant String := "$ARGUMENTS";
      Found : constant Natural := Ada.Strings.Fixed.Index (Text, Mark);
      Body_Text : constant String := Trim_End (Text);
   begin
      if Found = 0 then
         return (if Arguments = "" then Body_Text else Body_Text & ASCII.LF & ASCII.LF & Arguments);
      end if;
      declare
         Result : Unbounded_String;
         From   : Positive := Text'First;
         At_It  : Natural := Found;
      begin
         while At_It > 0 loop
            Append (Result, Text (From .. At_It - 1) & Arguments);
            From := At_It + Mark'Length;
            At_It := Ada.Strings.Fixed.Index (Text (From .. Text'Last), Mark);
         end loop;
         Append (Result, Text (From .. Text'Last));
         return Trim_End (To_String (Result));
      end;
   end Message;

   function Names return Model_Runner.Framework.Name_Lists.Vector is
      Result : Model_Runner.Framework.Name_Lists.Vector;
   begin
      for Folder of Folders loop
         if To_String (Folder) /= "" and then Ada.Directories.Exists (To_String (Folder)) then
            declare
               Search : Ada.Directories.Search_Type;
               Found  : Ada.Directories.Directory_Entry_Type;
            begin
               Ada.Directories.Start_Search
                 (Search, To_String (Folder), "*.md",
                  Filter => [Ada.Directories.Ordinary_File => True, others => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  declare
                     Simple : constant String := Ada.Directories.Simple_Name (Found);
                     Name   : constant String := Simple (Simple'First .. Simple'Last - 3);
                  begin
                     if Fit (Name) and then not Result.Contains ("/" & Name) then
                        Result.Append ("/" & Name);
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            exception
               when others =>
                  null;
            end;
         end if;
      end loop;
      return Result;
   end Names;

   function Described (Path : String) return String is
      Text  : constant String := Text_Of (Path);
      Start : Positive := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            declare
               Line : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Ada.Strings.Fixed.Trim (Text (Start .. Index - 1), Ada.Strings.Both),
                    Ada.Strings.Maps.To_Set ("#"), Ada.Strings.Maps.Null_Set);
            begin
               if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
                  return Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return "";
   end Described;

end Model_Runner.CLI.Custom_Commands;
