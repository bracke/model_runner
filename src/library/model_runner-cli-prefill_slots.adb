with Ada.Containers;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

package body Model_Runner.CLI.Prefill_Slots is

   package Dirs renames Ada.Directories;
   package SIO renames Ada.Streams.Stream_IO;
   use type Dirs.File_Kind;

   Suffix : constant String := ".kv";
   Said   : constant String := ".asked";
   Drafts : constant String := ".draft" & Suffix;

   --  The path without its ".kv", which every name here is made from.
   function Stem (Path : String) return String is
     (if Path'Length >= Suffix'Length
         and then Path (Path'Last - Suffix'Length + 1 .. Path'Last) = Suffix
      then Path (Path'First .. Path'Last - Suffix'Length)
      else Path);

   function Asked_Path (Path : String) return String is
     (Stem (Path) & Said);

   function Draft_Path (Path : String) return String is
     (Stem (Path) & Drafts);

   function Asking
     (System : String; Has_System : Boolean; Prompt : String) return String
   is
     (if Has_System then "S" & System & ASCII.NUL & Prompt
      else "P" & Prompt);

   function Contents (Path : String; Most : Natural) return String is
      File : SIO.File_Type;
   begin
      if Path = "" or else not Dirs.Exists (Path)
        or else Dirs.Kind (Path) /= Dirs.Ordinary_File
      then
         return "";
      end if;
      SIO.Open (File, SIO.In_File, Path, Form => "shared=yes");
      declare
         Result : String
           (1 .. Natural (SIO.Count'Min (SIO.Size (File), SIO.Count (Most))));
      begin
         String'Read (SIO.Stream (File), Result);
         SIO.Close (File);
         return Result;
      end;
   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
         return "";
   end Contents;

   function Slot_Path (Base, Asked : String) return String is
      Image : constant String :=
        Ada.Containers.Hash_Type'Image (Ada.Strings.Hash (Asked));
   begin
      return Stem (Base) & "-" & Image (Image'First + 1 .. Image'Last)
        & Suffix;
   end Slot_Path;

   --  How many bytes two texts begin with alike.
   function Shared (Left, Right : String) return Natural is
      Count : Natural := 0;
   begin
      while Count < Left'Length and then Count < Right'Length
        and then Left (Left'First + Count) = Right (Right'First + Count)
      loop
         Count := Count + 1;
      end loop;
      return Count;
   end Shared;

   function Nearest
     (Base, Asked : String; Least : Positive := 256) return String
   is
      Folder  : constant String := Dirs.Containing_Directory (Base);
      Name    : constant String := Dirs.Simple_Name (Stem (Base));
      Search  : Dirs.Search_Type;
      Found   : Dirs.Directory_Entry_Type;
      Best    : Natural := 0;
      Enough  : constant Natural := Natural'Min (Least, Asked'Length);
      Longest : constant Natural := Asked'Length + 1;
   begin
      if Base = "" or else not Dirs.Exists (Folder) then
         return "";
      end if;

      declare
         Chosen : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Dirs.Start_Search
           (Search, Folder, Name & "-*" & Said,
            [Dirs.Ordinary_File => True, others => False]);
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            declare
               Path   : constant String := Dirs.Full_Name (Found);
               Kept   : constant String :=
                 Path (Path'First .. Path'Last - Said'Length) & Suffix;
               Theirs : constant String := Contents (Path, Longest);
               Alike  : constant Natural := Shared (Theirs, Asked);
            begin
               if Theirs /= "" and then Alike >= Enough and then Alike > Best
                 and then Dirs.Exists (Kept)
               then
                  Best := Alike;
                  Chosen := Ada.Strings.Unbounded.To_Unbounded_String (Kept);
               end if;
            end;
         end loop;
         Dirs.End_Search (Search);
         return Ada.Strings.Unbounded.To_String (Chosen);
      end;
   exception
      when others =>
         return "";
   end Nearest;

   procedure Record_Asked (Path, Asked : String) is
      Target : constant String := Asked_Path (Path);
      Part   : constant String := Target & ".part";
      File   : SIO.File_Type;
   begin
      SIO.Create (File, SIO.Out_File, Part, Form => "shared=yes");
      String'Write (SIO.Stream (File), Asked);
      SIO.Close (File);
      if Dirs.Exists (Target) then
         Dirs.Delete_File (Target);
      end if;
      Dirs.Rename (Part, Target);
   exception
      when others =>
         --  A cache file whose asking is not kept is one no run chooses,
         --  which the bound on the cache deletes in time.
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
   end Record_Asked;

   function Covered (Path, Asked : String) return Boolean is
      Theirs : constant String :=
        Contents (Asked_Path (Path), Asked'Length + 1);
   begin
      return Theirs /= "" and then Shared (Theirs, Asked) = Theirs'Length;
   end Covered;

   procedure Forget (Path : String) is
      procedure Delete (Name : String) is
      begin
         if Dirs.Exists (Name) then
            Dirs.Delete_File (Name);
         end if;
      exception
         when others =>
            null;
      end Delete;
   begin
      Delete (Path);
      Delete (Asked_Path (Path));
      Delete (Draft_Path (Path));
   end Forget;

   procedure Drop_Orphans (Folder : String) is

      --  Delete each file ending in Ending whose cache file is gone.
      procedure Drop (Ending : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
      begin
         Dirs.Start_Search
           (Search, Folder, "*" & Ending,
            [Dirs.Ordinary_File => True, others => False]);
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            declare
               Path : constant String := Dirs.Full_Name (Found);
            begin
               if not Dirs.Exists
                        (Path (Path'First .. Path'Last - Ending'Length)
                         & Suffix)
               then
                  Dirs.Delete_File (Path);
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
         Dirs.End_Search (Search);
      exception
         when others =>
            null;
      end Drop;
   begin
      if Folder = "" or else not Dirs.Exists (Folder) then
         return;
      end if;
      Drop (Said);
      Drop (Drafts);
   end Drop_Orphans;

end Model_Runner.CLI.Prefill_Slots;
