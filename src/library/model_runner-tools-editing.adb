with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Interfaces;

with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Metadata;
with Hostkit.Metadata_Copy;

with Model_Runner.Durable_Syncs;

package body Model_Runner.Tools.Editing is

   package E renames Model_Runner.Errors;
   package U renames Ada.Strings.Unbounded;

   use type Interfaces.Unsigned_64;
   use type Ada.Directories.File_Size;
   use type E.Error_Code;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   -------------
   -- On_Disk --
   -------------

   function On_Disk (Base, Path : String) return String
   is (if Base = "" or else Path = "" or else Path (Path'First) = '/'
       then Path
       elsif Path = "." then Base
       else Base & "/" & Path);

   function Failing (Text : String) return Said is
     ((Text => U.To_Unbounded_String ("error: " & Text), Failed => True, others => <>));

   ---------------
   -- Read_Text --
   ---------------

   procedure Read_Text
     (Path   : String;
      Text   : out U.Unbounded_String;
      Status : out E.Error_Info;
      Base   : String := "")
   is
      Disk : constant String := On_Disk (Base, Path);
      use Ada.Streams;
      File : Stream_IO.File_Type;
   begin
      Text := U.Null_Unbounded_String;
      Status := E.Success;
      if not Ada.Directories.Exists (Disk) then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      elsif Ada.Directories."/=" (Ada.Directories.Kind (Disk), Ada.Directories.Ordinary_File) then
         Status := E.Make (E.IO_Not_A_Regular_File);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      elsif Ada.Directories.Size (Disk) > Ada.Directories.File_Size (Text_Most) then
         Status := E.Make (E.IO_File_Too_Large);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Text (Status, "detail", Image (Natural (Ada.Directories.Size (Disk) / 1024)) & " KiB, past the "
                     & Image (Text_Most / 1024) & " KiB a file is read whole");
         return;
      end if;
      --  A slice at a time onto the text: a file of megabytes copied whole
      --  onto a stack, twice, overflowed a worker's.
      Stream_IO.Open (File, Stream_IO.In_File, Disk);
      declare
         Block : Stream_Element_Array (1 .. 64 * 1024);
         Last  : Stream_Element_Offset;
         Piece : String (1 .. Block'Length);
      begin
         while not Stream_IO.End_Of_File (File) loop
            Stream_IO.Read (File, Block, Last);
            exit when Last < Block'First;
            for Index in 1 .. Natural (Last) loop
               Piece (Index) := Character'Val (Block (Stream_Element_Offset (Index)));
               --  A NUL is not text: a binary file named like a source.
               if Piece (Index) = ASCII.NUL then
                  Stream_IO.Close (File);
                  Text := U.Null_Unbounded_String;
                  Status := E.Make (E.IO_Read_Failed);
                  E.Add_Text (Status, "path", Path, E.Param_Path);
                  E.Add_Text (Status, "detail", "it is not text");
                  return;
               end if;
            end loop;
            U.Append (Text, Piece (1 .. Natural (Last)));
            --  A file still being written past the bound it was checked
            --  against is held to it all the same.
            if U.Length (Text) > Text_Most then
               Stream_IO.Close (File);
               Text := U.Null_Unbounded_String;
               Status := E.Make (E.IO_File_Too_Large);
               E.Add_Text (Status, "path", Path, E.Param_Path);
               E.Add_Text (Status, "detail", "past the " & Image (Text_Most / 1024)
                           & " KiB a file is read whole");
               return;
            end if;
         end loop;
         Stream_IO.Close (File);
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Text := U.Null_Unbounded_String;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
   end Read_Text;

   --------------
   -- Revision --
   --------------

   function Revision (Text : String) return String is
      Hash   : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
      Digits_Of : constant String := "0123456789abcdef";
      Result : String (1 .. 16);
   begin
      for C of Text loop
         Hash := (Hash xor Interfaces.Unsigned_64 (Character'Pos (C))) * 16#0000_0100_0000_01B3#;
      end loop;
      for Index in reverse Result'Range loop
         Result (Index) := Digits_Of (Natural (Hash and 15) + 1);
         Hash := Interfaces.Shift_Right (Hash, 4);
      end loop;
      return Result;
   end Revision;

   -----------------
   -- Revision_Of --
   -----------------

   function Revision_Of (Path : String; Base : String := "") return String is
      Text   : U.Unbounded_String;
      Status : E.Error_Info;
   begin
      Read_Text (Path, Text, Status, Base);
      return (if E.Is_Ok (Status) then Revision (U.To_String (Text)) else "");
   end Revision_Of;

   --  What a failed read is said as, to a model.
   function Why_Unread (Path : String; Status : E.Error_Info) return String is
   begin
      if Status.Code = E.IO_Open_Failed then
         return "no file at " & Path;
      elsif Status.Code = E.IO_Not_A_Regular_File then
         return Path & " is a directory: list_directory lists it";
      elsif Status.Code = E.IO_File_Too_Large then
         return Path & " is too large to read whole (" & E.Text_Of (Status, "detail")
           & "): read_range reads lines of it, search_file finds them";
      elsif E.Text_Of (Status, "detail") /= "" then
         return Path & " cannot be read as text: " & E.Text_Of (Status, "detail");
      end if;
      return Path & " could not be read";
   end Why_Unread;

   --  How many lines a text has up to and including an index.
   function Line_At (Text : String; Index : Natural) return Positive is
      Count : Positive := 1;
   begin
      for At_Char in Text'First .. Natural'Min (Index, Text'Last) - 1 loop
         if Text (At_Char) = ASCII.LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Line_At;

   function Lines_In (Text : String) return Natural is
     (if Text'Length = 0 then 0
      else Ada.Strings.Fixed.Count (Text, [1 => ASCII.LF])
           + (if Text (Text'Last) = ASCII.LF then 0 else 1));

   --  A number for each partial file this process writes.
   protected Partial_Number is
      procedure Take (Number : out Natural);
   private
      Count : Natural := 0;
   end Partial_Number;

   protected body Partial_Number is
      procedure Take (Number : out Natural) is
      begin
         Count := Count + 1;
         Number := Count;
      end Take;
   end Partial_Number;

   function Next_Partial return Natural is
      Number : Natural;
   begin
      Partial_Number.Take (Number);
      return Number;
   end Next_Partial;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   -------------
   -- Replace --
   -------------

   procedure Replace
     (Path    : String;
      Content : String;
      Result  : out Said;
      Base    : String := "")
   is
      use Ada.Streams;
      Given  : constant String := On_Disk (Base, Path);
      --  A link written through to the file it names where that is inside
      --  the tree the write is held to -- renamed over, the link became a
      --  file of its own and what it named was left as it was -- and
      --  replaced as a link anywhere else: the state's restore and the
      --  take-in of work write with no tree to hold them, and a link
      --  planted there was written through to a file outside the project.
      Resolved : constant String :=
        (if Base /= "" and then Hostkit.Fs.Is_Link (Given) then Hostkit.Fs.Real_Path (Given) else "");
      Tree     : constant String := (if Base = "" then "" else Hostkit.Fs.Real_Path (Base));
      Disk   : constant String :=
        (if Resolved /= "" and then Tree /= "" and then Resolved'Length > Tree'Length
           and then Resolved (Resolved'First .. Resolved'First + Tree'Length - 1) = Tree
           and then Resolved (Resolved'First + Tree'Length) = '/'
         then Resolved else Given);
      Folder : constant String := Ada.Directories.Containing_Directory (Disk);
      --  Hidden beside it, where a crash may leave it, and on the same
      --  filesystem, which the rename needs; named for this process and this
      --  write, so two writers of one file never share it -- one named for
      --  the file alone let a second process empty the first's before it
      --  was renamed in.
      --  The file's own name held to a length that leaves room for the
      --  rest within a name's limit: a long name was a file that could not
      --  be written at all.
      Named   : constant String := Ada.Directories.Simple_Name (Disk);
      Partial : constant String :=
        (if Folder = "" then "" else Folder & "/") & "."
        & Named (Named'First .. Named'First + Natural'Min (Named'Length, 160) - 1)
        & ".model_runner-partial." & Trim (Integer'Image (Hostkit.Host.Own_Process_Id))
        & "." & Trim (Natural'Image (Next_Partial));
      There  : constant Boolean :=
        Ada.Directories.Exists (Disk)
        and then Ada.Directories."=" (Ada.Directories.Kind (Disk), Ada.Directories.Ordinary_File);
      Before : constant String := (if There then Revision_Of (Path, Base) else "");
      --  Whether the file has other names than this one: hard links. A
      --  link's own count, never what it names: Capture does not follow it.
      Shared_By_Names : constant Boolean :=
        There and then Hostkit.Metadata_Copy.Is_Available (Hostkit.Metadata_Copy.Capture (Disk))
        and then Interfaces."<" (1, Hostkit.Metadata_Copy.Link_Count (Hostkit.Metadata_Copy.Capture (Disk)));
      After  : constant String := Revision (Content);
      File   : Stream_IO.File_Type;

      --  The folders this write made for the file, deepest first: taken
      --  away again where the write fails, as they were not there before.
      Made_Folders : array (1 .. 64) of U.Unbounded_String;
      Made_Count   : Natural := 0;

      procedure Fail (Text : String) is
      begin
         Result := Failing (Text);
         Result.Before_Revision := U.To_Unbounded_String (Before);
         Result.After_Revision := U.To_Unbounded_String (Before);
         --  Empty ones only, and never followed through a link: a folder
         --  something else put a file in since stays.
         for Index in 1 .. Made_Count loop
            begin
               if Ada.Directories.Exists (U.To_String (Made_Folders (Index)))
                 and then not Hostkit.Fs.Is_Link (U.To_String (Made_Folders (Index)))
               then
                  Ada.Directories.Delete_Directory (U.To_String (Made_Folders (Index)));
               end if;
            exception
               when others =>
                  exit;
            end;
         end loop;
      end Fail;
   begin
      Result := (others => <>);
      Result.Before_Revision := U.To_Unbounded_String (Before);
      Result.After_Revision := U.To_Unbounded_String (After);
      Result.Created := not There;
      if There and then Before = After then
         return;
      end if;

      --  A file no one may write, as its mode says: not written over -- the
      --  rename put a writable one in its place. A link's mode is what it
      --  names, and a link is replaced as itself.
      if There and then not Hostkit.Fs.Is_Link (Disk) then
         declare
            Available : Boolean;
            Bits      : constant Natural := Hostkit.Metadata.File_Permission_Bits (Disk, Available);
         begin
            --  Where the bits say who may write: Windows gives them from its
            --  owner, group and everyone alone, and a file a group of users
            --  may write read as no one's.
            if Available and then Hostkit.Host."/=" (Hostkit.Host.Current, Hostkit.Host.Windows)
              and then (Bits / 8#200#) mod 2 = 0 and then (Bits / 8#20#) mod 2 = 0
              and then (Bits / 8#2#) mod 2 = 0
            then
               Fail (Path & " is read-only, so it is not written over: a person makes it writable first");
               return;
            end if;
         end;
      end if;

      --  Its folder made with it -- and the reason said where it cannot be.
      if Folder /= "" and then Ada.Directories.Exists (Folder)
        and then Ada.Directories."/=" (Ada.Directories.Kind (Folder), Ada.Directories.Directory)
      then
         Fail ("could not make the folder for " & Path & ": "
               & Ada.Directories.Simple_Name (Folder) & " is a file");
         return;
      elsif Folder /= "" and then not Ada.Directories.Exists (Folder) then
         --  Which of its folders are not there yet, deepest first.
         declare
            Up : U.Unbounded_String := U.To_Unbounded_String (Folder);
         begin
            while Made_Count < Made_Folders'Last and then U.Length (Up) > 0
              and then not Ada.Directories.Exists (U.To_String (Up))
            loop
               Made_Count := Made_Count + 1;
               Made_Folders (Made_Count) := Up;
               begin
                  Up := U.To_Unbounded_String (Ada.Directories.Containing_Directory (U.To_String (Up)));
               exception
                  when others =>
                     Up := U.Null_Unbounded_String;
               end;
            end loop;
         end;
         begin
            Ada.Directories.Create_Path (Folder);
         exception
            when Failure : others =>
               Fail ("could not make the folder for " & Path & ": "
                     & Ada.Exceptions.Exception_Message (Failure));
               return;
         end;
      end if;

      --  What a write of this file a crash cut short left beside it: its
      --  partials an hour old, which no writer still running holds.
      declare
         use type Ada.Calendar.Time;
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
         Stale  : U.Unbounded_String;
         --  As the partials are named: the file's name held to its cap.
         Prefix : constant String :=
           "." & Named (Named'First .. Named'First + Natural'Min (Named'Length, 160) - 1) & ".model_runner-partial.";
      begin
         Ada.Directories.Start_Search
           (Search, (if Folder = "" then "." else Folder), Prefix & "*",
            [Ada.Directories.Ordinary_File => True, others => False]);
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Found);
            if Ada.Calendar.Clock - Ada.Directories.Modification_Time (Found) > 3_600.0 then
               U.Append (Stale, Ada.Directories.Full_Name (Found) & ASCII.LF);
            end if;
         end loop;
         Ada.Directories.End_Search (Search);
         declare
            Listed : constant String := U.To_String (Stale);
            From   : Positive := Listed'First;
         begin
            for Index in Listed'Range loop
               if Listed (Index) = ASCII.LF then
                  begin
                     Ada.Directories.Delete_File (Listed (From .. Index - 1));
                  exception
                     when others =>
                        null;
                  end;
                  From := Index + 1;
               end if;
            end loop;
         end;
      exception
         --  Left for the next: the write itself is what was asked.
         when others =>
            null;
      end;

      --  Written whole beside itself, made durable, and renamed over it in
      --  one step: a crash, a full disk or an interrupt leaves the file as
      --  it was or as it is now, never cut short -- as the project's own
      --  state is written.
      declare
         Block : Stream_Element_Array (1 .. Stream_Element_Offset (Content'Length));
      begin
         for Index in Block'Range loop
            Block (Index) := Stream_Element (Character'Pos (Content (Content'First + Natural (Index) - 1)));
         end loop;
         Stream_IO.Create (File, Stream_IO.Out_File, Partial);
         Stream_IO.Write (File, Block);
         Stream_IO.Close (File);
      exception
         when Failure : others =>
            if Stream_IO.Is_Open (File) then
               Stream_IO.Close (File);
            end if;
            if Ada.Directories.Exists (Partial) then
               Ada.Directories.Delete_File (Partial);
            end if;
            Fail ("could not write " & Path & ": " & Ada.Exceptions.Exception_Message (Failure));
            return;
      end;
      declare
         use type Hostkit.Durability.Outcome;
      begin
         --  Failed, not unsupported: a host with no such sync has done all
         --  it can.
         Result.Durable := Model_Runner.Durable_Syncs.Sync_File (Partial) /= Hostkit.Durability.Failed;
      end;
      --  Not on the device, it is not put in its place: renamed over, a
      --  crash could leave the file empty where it held what it held.
      if not Result.Durable then
         if Ada.Directories.Exists (Partial) then
            Ada.Directories.Delete_File (Partial);
         end if;
         Fail ("could not write " & Path & ": what was written could not be made durable");
         return;
      end if;
      --  What the file was allowed keeps being allowed: a script stays one.
      if There then
         declare
            Available : Boolean;
            Bits      : constant Natural := Hostkit.Metadata.File_Permission_Bits (Disk, Available);
            Kept      : Boolean;
         begin
            if Available then
               Kept := Hostkit.Metadata.Set_Permissions (Partial, Bits);
               Result.Permissions_Kept := Kept;
            end if;
         end;
      end if;
      --  Still as it was when this write began: saved by something else
      --  while the new text was written and flushed, that save would be
      --  lost under the rename.
      if There and then Revision_Of (Path, Base) /= Before then
         if Ada.Directories.Exists (Partial) then
            Ada.Directories.Delete_File (Partial);
         end if;
         Fail (Path & " changed while it was being written, by something other than you: read it again");
         return;
      end if;
      --  A file of more than one name is written in place, its partial
      --  read back into it: renamed over, the name written went to a new
      --  file and the others kept the old text.
      if There and then Shared_By_Names then
         declare
            Copy  : Stream_IO.File_Type;
            Block : Stream_Element_Array (1 .. Stream_Element_Offset (Content'Length));
         begin
            for Index in Block'Range loop
               Block (Index) := Stream_Element (Character'Pos (Content (Content'First + Natural (Index) - 1)));
            end loop;
            Stream_IO.Open (Copy, Stream_IO.Out_File, Disk);
            Stream_IO.Write (Copy, Block);
            Stream_IO.Close (Copy);
            --  Durable as the file itself is made so, not as its partial was.
            declare
               use type Hostkit.Durability.Outcome;
            begin
               Result.Durable := Model_Runner.Durable_Syncs.Sync_File (Disk) /= Hostkit.Durability.Failed;
            end;
            Ada.Directories.Delete_File (Partial);
         exception
            when Failure : others =>
               if Stream_IO.Is_Open (Copy) then
                  Stream_IO.Close (Copy);
               end if;
               --  The file was opened empty to be written in place: its
               --  partial is the one whole copy of the new text, kept and
               --  named -- deleted, the text was lost with the old.
               Fail ("could not write " & Path & " in place: " & Ada.Exceptions.Exception_Message (Failure)
                     & "; its new text is kept whole in " & Partial);
               return;
         end;
      elsif not Hostkit.Fs.Replace_File (Partial, Disk) then
         if Ada.Directories.Exists (Partial) then
            Ada.Directories.Delete_File (Partial);
         end if;
         Fail ("could not put the new " & Path & " in place of the old");
         return;
      end if;
      declare
         use type Hostkit.Durability.Outcome;
      begin
         Result.Durable := Result.Durable
           and then Model_Runner.Durable_Syncs.Sync_Directory (if Folder = "" then "." else Folder)
                    /= Hostkit.Durability.Failed;
      end;
      Result.Changed := True;
   end Replace;

   ---------------
   -- Kept_Note --
   ---------------

   function Kept_Note (Item : Said) return String
   is ((if Item.Durable then ""
        else " -- but it could not be made durable: a crash now may lose it")
       & (if Item.Permissions_Kept then ""
          else " -- and its permission bits could not be kept"));

   ---------------------
   -- Declarations_In --
   ---------------------

   function Declarations_In (Text : String; First, Last : Positive) return String is
      type Word_Ref is access constant String;
      Opening : constant array (1 .. 15) of Word_Ref :=
        [new String'("procedure "), new String'("function "), new String'("package body "),
         new String'("package "), new String'("type "), new String'("subtype "),
         new String'("task body "), new String'("task "), new String'("protected body "),
         new String'("protected "), new String'("entry "), new String'("def "),
         new String'("class "), new String'("fn "), new String'("func ")];
      Found  : U.Unbounded_String;
      Above  : U.Unbounded_String;
      Line   : Positive := 1;
      Start  : Positive := Text'First;

      --  The name a line declares, or "".
      function Declared (Said : String) return String is
         Bare : constant String :=
           Ada.Strings.Fixed.Trim (Said, Ada.Strings.Both);
         Low  : constant String := Ada.Characters.Handling.To_Lower (Bare);
         Rest : constant String :=
           (if Low'Length > 11 and then Low (Low'First .. Low'First + 10) = "overriding " then
               Bare (Bare'First + 11 .. Bare'Last)
            elsif Low'Length > 4 and then Low (Low'First .. Low'First + 3) = "pub " then
               Bare (Bare'First + 4 .. Bare'Last)
            else Bare);
         Lower : constant String := Ada.Characters.Handling.To_Lower (Rest);
      begin
         for Word of Opening loop
            if Lower'Length > Word'Length
              and then Lower (Lower'First .. Lower'First + Word'Length - 1) = Word.all
            then
               declare
                  From : constant Positive := Rest'First + Word'Length;
                  To   : Natural := From - 1;
               begin
                  while To < Rest'Last
                    and then (Ada.Characters.Handling.Is_Alphanumeric (Rest (To + 1))
                              or else Rest (To + 1) in '_' | '.')
                  loop
                     To := To + 1;
                  end loop;
                  return Rest (From .. To);
               end;
            end if;
         end loop;
         return "";
      end Declared;

      procedure Note (Name : String) is
      begin
         if Name /= "" and then U.Index (Found, Name) = 0 then
            U.Append (Found, (if U.Length (Found) = 0 then "" else ", ") & Name);
         end if;
      end Note;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            declare
               Name : constant String := Declared (Text (Start .. Index - 1));
            begin
               if Name /= "" then
                  if Line <= First then
                     Above := U.To_Unbounded_String (Name);
                  elsif Line <= Last then
                     Note (Name);
                  end if;
               end if;
            end;
            exit when Line > Last;
            Line := Line + 1;
            Start := Index + 1;
         end if;
      end loop;
      declare
         Within : constant String := U.To_String (Found);
      begin
         Found := U.Null_Unbounded_String;
         Note (U.To_String (Above));
         if Within /= "" then
            U.Append (Found, (if U.Length (Found) = 0 then "" else ", ") & Within);
         end if;
      end;
      return U.To_String (Found);
   end Declarations_In;

   --  Where a passage that is not in a file would be: the file's lines from
   --  where a line of it stands, as read_file numbers them, as many as the
   --  passage has and two more -- a model told only "not there" read the
   --  file again, or went on from memory, and edited from a copy it no
   --  longer had. "" where no line of it is there.
   function Nearest (Text, Old_Text : String) return String is
      package Line_Lists is new Ada.Containers.Indefinite_Vectors (Positive, String);

      function Lines_Of (Item : String) return Line_Lists.Vector is
         Result : Line_Lists.Vector;
         Start  : Positive := Item'First;
      begin
         for Index in Item'First .. Item'Last + 1 loop
            if Index > Item'Last or else Item (Index) = ASCII.LF then
               Result.Append (Item (Start .. Index - 1));
               Start := Index + 1;
            end if;
         end loop;
         return Result;
      end Lines_Of;

      function Bare (Item : String) return String is
         First : Natural := Item'First;
         Last  : Natural := Item'Last;
      begin
         while First <= Last and then Item (First) in ' ' | ASCII.HT | ASCII.CR loop
            First := First + 1;
         end loop;
         while Last >= First and then Item (Last) in ' ' | ASCII.HT | ASCII.CR loop
            Last := Last - 1;
         end loop;
         return Item (First .. Last);
      end Bare;

      --  A line without the CR a CRLF file ends it with.
      function Without_CR (Item : String) return String
      is (if Item'Length > 0 and then Item (Item'Last) = ASCII.CR then Item (Item'First .. Item'Last - 1)
          else Item);

      File  : constant Line_Lists.Vector := Lines_Of (Text);
      Given : constant Line_Lists.Vector := Lines_Of (Old_Text);
      Said  : U.Unbounded_String;
   begin
      for Offset in 1 .. Natural (Given.Length) loop
         if Bare (Given (Offset)) /= "" then
            for At_Line in 1 .. Natural (File.Length) loop
               if Bare (File (At_Line)) = Bare (Given (Offset)) then
                  declare
                     First : constant Positive := Natural'Max (1, At_Line - Offset + 1);
                     Last  : constant Natural :=
                       Natural'Min (Natural (File.Length), First + Natural (Given.Length) + 1);
                  begin
                     U.Append (Said, "; where its line" & Natural'Image (Offset) & " is, the file reads:");
                     for Index in First .. Last loop
                        U.Append (Said, ASCII.LF & Ada.Strings.Fixed.Trim (Natural'Image (Index), Ada.Strings.Left)
                                  & ": " & Without_CR (File (Index)));
                     end loop;
                     return U.To_String (Said);
                  end;
               end if;
            end loop;
         end if;
      end loop;
      return "";
   end Nearest;

   ------------------
   -- Edit_Loosely --
   ------------------

   --  Old_Text matched in Text line for line with the spaces and tabs at
   --  each line's ends left out, where it matches in exactly one place:
   --  the lines there replaced by New_Text, each line of it moved by how
   --  far the first given line's indentation was from the file's. Failed,
   --  saying nothing, where it matches nowhere; failed saying the lines it
   --  starts at where it matches more than once -- "not there" sent a
   --  model resending the same edit until it was stopped.
   function Edit_Loosely
     (Path, Text, Now, Old_Text, New_Text : String;
      Base : String;
      Near_First, Near_Last : Natural) return Said
   is
      package Line_Lists is new Ada.Containers.Vectors (Positive, U.Unbounded_String, U."=");

      function Lines_Of (Item : String) return Line_Lists.Vector is
         Result : Line_Lists.Vector;
         Start  : Positive := Item'First;
      begin
         for Index in Item'First .. Item'Last + 1 loop
            if Index > Item'Last or else Item (Index) = ASCII.LF then
               Result.Append (U.To_Unbounded_String (Item (Start .. Index - 1)));
               Start := Index + 1;
            end if;
         end loop;
         return Result;
      end Lines_Of;

      function Bare (Item : String) return String is
         First : Natural := Item'First;
         Last  : Natural := Item'Last;
      begin
         while First <= Last and then Item (First) in ' ' | ASCII.HT | ASCII.CR loop
            First := First + 1;
         end loop;
         while Last >= First and then Item (Last) in ' ' | ASCII.HT | ASCII.CR loop
            Last := Last - 1;
         end loop;
         return Item (First .. Last);
      end Bare;

      function Indent (Item : String) return Natural is
         Count : Natural := 0;
      begin
         for C of Item loop
            exit when C /= ' ';
            Count := Count + 1;
         end loop;
         return Count;
      end Indent;

      File  : constant Line_Lists.Vector := Lines_Of (Text);
      Given : Line_Lists.Vector := Lines_Of (Old_Text);
      At_Line : Natural := 0;
      Found   : Natural := 0;
      Starts  : U.Unbounded_String;
      Settled_By_Read : Boolean := False;
      Refused : constant Said := (Failed => True, others => <>);
   begin
      --  Blank lines at the ends of what was given are no part of it.
      while not Given.Is_Empty and then Bare (U.To_String (Given.First_Element)) = "" loop
         Given.Delete_First;
      end loop;
      while not Given.Is_Empty and then Bare (U.To_String (Given.Last_Element)) = "" loop
         Given.Delete_Last;
      end loop;
      if Given.Is_Empty or else Natural (Given.Length) > Natural (File.Length) then
         return Refused;
      end if;
      for Start in 1 .. Natural (File.Length) - Natural (Given.Length) + 1 loop
         if (for all Offset in 0 .. Natural (Given.Length) - 1 =>
               Bare (U.To_String (File (Start + Offset))) = Bare (U.To_String (Given (1 + Offset))))
         then
            Found := Found + 1;
            At_Line := Start;
            U.Append (Starts, (if Found = 1 then "" else ",") & Natural'Image (Start));
         end if;
      end loop;
      --  There more than once, and once only within the lines last read:
      --  that one is meant.
      if Found > 1 and then Near_First > 0 then
         declare
            Within : Natural := 0;
            Where  : Natural := 0;
         begin
            for Start in 1 .. Natural (File.Length) - Natural (Given.Length) + 1 loop
               if Start in Near_First .. Near_Last
                 and then (for all Offset in 0 .. Natural (Given.Length) - 1 =>
                             Bare (U.To_String (File (Start + Offset))) = Bare (U.To_String (Given (1 + Offset))))
               then
                  Within := Within + 1;
                  Where := Start;
               end if;
            end loop;
            if Within = 1 then
               Found := 1;
               At_Line := Where;
               Settled_By_Read := True;
            end if;
         end;
      end if;
      if Found > 1 then
         return Failing
           ("old_text is not in " & Path & " exactly, and with the spaces at the ends of lines left out it"
            & " is there" & Natural'Image (Found) & " times, at lines" & U.To_String (Starts)
            & ": give more of the text around the one you mean, exactly as read_file shows it after"
            & " the ""N: """);
      elsif Found = 0 then
         return Refused;
      end if;

      --  Tabs are no spaces: a line the file indents with a tab, matched by
      --  one given indented otherwise, would be moved by spaces and lose
      --  its tab -- a Makefile's recipe so lost breaks its build.
      declare
         function Lead (Item : String) return String is
            Last : Natural := Item'First - 1;
         begin
            while Last < Item'Last and then Item (Last + 1) in ' ' | ASCII.HT loop
               Last := Last + 1;
            end loop;
            return Item (Item'First .. Last);
         end Lead;
      begin
         for Offset in 0 .. Natural (Given.Length) - 1 loop
            declare
               In_File  : constant String := Lead (U.To_String (File (At_Line + Offset)));
               In_Given : constant String := Lead (U.To_String (Given (1 + Offset)));
            begin
               if Ada.Strings.Fixed.Index (In_File & In_Given, [1 => ASCII.HT]) > 0
                 and then In_File /= In_Given
               then
                  return Failing
                    ("old_text is in " & Path & " only with its lines' tabs and spaces told apart otherwise, at"
                     & " line" & Natural'Image (At_Line + Offset) & ": give the lines exactly as read_file shows"
                     & " them, tabs and all");
               end if;
            end;
         end loop;
      end;

      declare
         Shift : constant Integer :=
           Indent (U.To_String (File (At_Line))) - Indent (U.To_String (Given.First_Element));
         --  The line ending of the lines replaced, kept: a file of CRLF lines
         --  given new LF lines had two endings.
         First_Line : constant String := U.To_String (File (At_Line));
         Ends_CR    : constant Boolean :=
           First_Line'Length > 0 and then First_Line (First_Line'Last) = ASCII.CR;
         Moved : U.Unbounded_String;
         --  The lines it puts, as written -- blank ones the model gave at its
         --  ends too, which were dropped -- but the empty one its closing
         --  line break makes: the line break of the lines replaced is the
         --  file's, and a blank line was put in for it.
         function Trimmed return Line_Lists.Vector is
            Result : Line_Lists.Vector := Lines_Of (New_Text);
         begin
            --  Nothing given: no line, not one empty one.
            if New_Text = "" then
               return Line_Lists.Empty_Vector;
            end if;
            if New_Text'Length > 0 and then New_Text (New_Text'Last) = ASCII.LF
              and then not Result.Is_Empty and then U.Length (Result.Last_Element) = 0
            then
               Result.Delete_Last;
            end if;
            return Result;
         end Trimmed;
         Fresh : constant Line_Lists.Vector := Trimmed;
         After : U.Unbounded_String;
      begin
         for Index in 1 .. Natural (Fresh.Length) loop
            declare
               Line : constant String := U.To_String (Fresh (Index));
               Lead : constant Natural := Indent (Line);
            begin
               U.Append (Moved, (if Index = 1 then "" else [1 => ASCII.LF]));
               if Line = "" then
                  null;
               elsif Shift >= 0 then
                  U.Append (Moved, [1 .. Shift => ' '] & Line);
               else
                  U.Append (Moved, Line (Line'First + Natural'Min (Lead, -Shift) .. Line'Last));
               end if;
               if Ends_CR and then (Line = "" or else Line (Line'Last) /= ASCII.CR) then
                  U.Append (Moved, ASCII.CR);
               end if;
            end;
         end loop;
         for Index in 1 .. Natural (File.Length) loop
            --  Nothing put in their place: the lines go, their breaks with
            --  them -- a blank line was left where they were.
            if Index = At_Line and then Fresh.Is_Empty then
               goto Next_Line;
            elsif Index = At_Line then
               U.Append (After, Moved);
            elsif Index in At_Line + 1 .. At_Line + Natural (Given.Length) - 1 then
               goto Next_Line;
            else
               U.Append (After, File (Index));
            end if;
            if Index < Natural (File.Length) then
               U.Append (After, ASCII.LF);
            end if;
            <<Next_Line>>
         end loop;
         declare
            Whole : constant String := U.To_String (After);
            Put   : Said;
            Upto  : constant Positive := At_Line + Natural'Max (1, Lines_In (New_Text)) - 1;
            Names : constant String := Declarations_In (Whole, At_Line, Upto);
         begin
            --  The file as it was: nothing edited, said as the exact match
            --  says it -- "edited" with the revision it already had sent a
            --  model resending its own text, as though it had changed.
            if Whole = Text then
               return (Text => U.To_Unbounded_String
                         ("unchanged: new_text is what the file already holds there (line"
                          & Natural'Image (At_Line) & "), so nothing was edited"),
                       others => <>);
            end if;
            Replace (Path, Whole, Put, Base);
            if Put.Failed then
               return Put;
            end if;
            return
              (Before_Revision => U.To_Unbounded_String (Now),
               After_Revision  => U.To_Unbounded_String (Revision (Whole)),
               Text    => U.To_Unbounded_String
                 ("edited " & Path & " at line" & Natural'Image (At_Line) & ":"
                  & Natural'Image (Natural (Given.Length)) & " line"
                  & (if Natural (Given.Length) = 1 then "" else "s") & " replaced by"
                  & Natural'Image (Lines_In (New_Text))
                  & (if Names = "" then "" else "; in " & Names)
                  & "; old_text matched with the spaces at its lines' ends left out"
                  & (if Settled_By_Read
                     then ", in more than one place, and edited in the one within the lines you last read"
                     else "")
                  & (if Shift = 0 then ""
                     else ", and the new text moved" & Natural'Image (abs Shift) & " space"
                          & (if abs Shift = 1 then "" else "s") & (if Shift > 0 then " in" else " out")
                          & " to the file's indentation")
                  & "; revision now " & Revision (Whole) & Kept_Note (Put)),
               Changed => True,
               Durable => Put.Durable,
               Permissions_Kept => Put.Permissions_Kept,
               others  => <>);
         end;
      end;
   end Edit_Loosely;

   ----------
   -- Edit --
   ----------

   function Edit
     (Path, Old_Text, New_Text, Expected : String;
      Base       : String := "";
      Near_First : Natural := 0;
      Near_Last  : Natural := 0) return Said
   is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
   begin
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      declare
         Text : constant String := U.To_String (Held);
         Now  : constant String := Revision (Text);
      begin
         if Expected /= "" and then Expected /= Now then
            return Failing (Path & " has changed since you read it (you read revision " & Expected
                            & ", it is now " & Now & "): read it again, then edit what is there");
         elsif Old_Text = "" then
            return Failing ("old_text is empty: give the exact text to replace (write_file makes a new file)");
         end if;
         declare
            --  There more than once, and once only starting within the
            --  lines last read: that one is meant.
            function Near return Natural is
               Within : Natural := 0;
               Where  : Natural := 0;
               From   : Natural := Ada.Strings.Fixed.Index (Text, Old_Text);
            begin
               if Near_First = 0 then
                  return 0;
               end if;
               while From > 0 loop
                  if Line_At (Text, From) in Near_First .. Near_Last then
                     Within := Within + 1;
                     Where := From;
                  end if;
                  From := (if From >= Text'Last then 0 else Ada.Strings.Fixed.Index (Text, Old_Text, From + 1));
               end loop;
               return (if Within = 1 then Where else 0);
            end Near;

            --  Every start, overlapping ones too: end; end; end; holds
            --  end; end; twice, and that is not one place.
            function Starts return Natural is
               Found : Natural := 0;
               From  : Natural := Ada.Strings.Fixed.Index (Text, Old_Text);
            begin
               while From > 0 loop
                  Found := Found + 1;
                  From := (if From >= Text'Last then 0 else Ada.Strings.Fixed.Index (Text, Old_Text, From + 1));
               end loop;
               return Found;
            end Starts;

            Times_There : constant Natural := Starts;
            Chosen      : constant Natural := (if Times_There > 1 then Near else 0);
            At_Text : constant Natural :=
              (if Chosen > 0 then Chosen else Ada.Strings.Fixed.Index (Text, Old_Text));
            Times   : constant Natural := (if Chosen > 0 then 1 else Times_There);
         begin
            if At_Text = 0 then
               --  Not there as given, but there line for line once the spaces
               --  at the ends of lines are left out, and in one place only:
               --  edited there, the new text moved by how far the given one
               --  was off. A model copying lines got the indentation one
               --  space wrong, twenty times running.
               declare
                  Loose : constant Said :=
                    Edit_Loosely (Path, Text, Now, Old_Text, New_Text, Base, Near_First, Near_Last);
               begin
                  if not Loose.Failed or else U.Length (Loose.Text) > 0 then
                     return Loose;
                  end if;
               end;
               return Failing ("old_text is not in " & Path & " as it is now (revision " & Now
                               & "): read the part you mean to change again, and give it exactly"
                               & Nearest (Text, Old_Text));
            elsif Times > 1 then
               return Failing ("old_text is in " & Path & Natural'Image (Times)
                               & " times: give more of the text around the one you mean");
            elsif Old_Text = New_Text then
               return (Text => U.To_Unbounded_String ("unchanged: old_text and new_text are the same"),
                       others => <>);
            end if;
            declare
               --  Where the line the passage starts on starts, and whether
               --  only its indentation comes before the passage.
               Line_Start : constant Positive :=
                 (if Ada.Strings.Fixed.Index (Text (Text'First .. At_Text - 1), [1 => ASCII.LF],
                                              Ada.Strings.Backward) = 0
                  then Text'First
                  else Ada.Strings.Fixed.Index (Text (Text'First .. At_Text - 1), [1 => ASCII.LF],
                                                Ada.Strings.Backward) + 1);
               Lead : constant Natural := At_Text - Line_Start;
               Only_Indent : constant Boolean :=
                 Lead > 0 and then (for all C of Text (Line_Start .. At_Text - 1) => C = ' ');

               function Indent_Of (Line : String) return Natural is
                  Count : Natural := 0;
               begin
                  for C of Line loop
                     exit when C /= ' ';
                     Count := Count + 1;
                  end loop;
                  return Count;
               end Indent_Of;

               --  New lines given for a passage that starts after a line's
               --  indentation are laid out as the model sees them: from
               --  their first line, which either has an indentation of its
               --  own or none. Put in as given, the lines after the first
               --  stood at the margin -- or the first at twice its depth --
               --  and every edit of the file after went by a ragged copy.
               --  Moved where the first given line has an indentation of its
               --  own, or where a later one stands left of the line's: so the
               --  first line stands at the line's indentation and the rest
               --  keep where they stood from it. Lines that already stand at
               --  or right of the line's indentation, after a first line that
               --  has none, are as the model meant them, and put in as given;
               --  so are all of them where old_text has lines after its first:
               --  matched exactly, those stand as the file has them, and the
               --  new ones were given in the same layout.
               Moved   : U.Unbounded_String;
               Shifted : Boolean := False;

               function Blank (Line : String) return Boolean
               is (for all C of Line => C in ' ' | ASCII.HT | ASCII.CR);

               --  Whether old_text has a line after its first with more than
               --  blanks on it.
               function Old_Laid_Out return Boolean is
                  Break : constant Natural := Ada.Strings.Fixed.Index (Old_Text, [1 => ASCII.LF]);
               begin
                  return Break > 0
                    and then (for some C of Old_Text (Break + 1 .. Old_Text'Last) =>
                                C not in ' ' | ASCII.HT | ASCII.CR | ASCII.LF);
               end Old_Laid_Out;

               procedure Lay_Out is
                  package Text_Lines is new Ada.Containers.Indefinite_Vectors (Positive, String);
                  Lines : Text_Lines.Vector;
                  Start : Positive := New_Text'First;
                  First_Indent : Natural;
                  Leftmost     : Natural := Natural'Last;
                  Shift        : Integer;
               begin
                  for Index in New_Text'First .. New_Text'Last + 1 loop
                     if Index > New_Text'Last or else New_Text (Index) = ASCII.LF then
                        Lines.Append (New_Text (Start .. Index - 1));
                        Start := Index + 1;
                     end if;
                  end loop;
                  First_Indent := Indent_Of (Lines.First_Element);
                  for Index in 2 .. Natural (Lines.Length) loop
                     if not Blank (Lines (Index)) then
                        Leftmost := Natural'Min (Leftmost, Indent_Of (Lines (Index)));
                     end if;
                  end loop;
                  if First_Indent = 0
                    and then (Leftmost = Natural'Last or else Leftmost >= Lead or else Old_Laid_Out)
                  then
                     return;
                  end if;
                  Shift := Lead - First_Indent;
                  for Index in 1 .. Natural (Lines.Length) loop
                     declare
                        Line : constant String := Lines (Index);
                        Own  : constant Natural := Indent_Of (Line);
                     begin
                        U.Append (Moved, (if Index = 1 then "" else [1 => ASCII.LF]));
                        if Blank (Line) then
                           U.Append (Moved, Line);
                        elsif Shift >= 0 then
                           U.Append (Moved, [1 .. Shift => ' '] & Line);
                        else
                           U.Append (Moved, Line (Line'First + Natural'Min (Own, -Shift) .. Line'Last));
                        end if;
                     end;
                  end loop;
                  Shifted := True;
               end Lay_Out;

               --  Lines ended as the file ends them: in one that ends them
               --  CR LF, a line break given alone is given its CR.
               function Fitted (Given : String) return String is
                  Line_End : constant Natural :=
                    Ada.Strings.Fixed.Index (Text (At_Text .. Text'Last), [1 => ASCII.LF]);
                  Crlf     : constant Boolean := Line_End > Text'First and then Text (Line_End - 1) = ASCII.CR;
                  Result   : U.Unbounded_String;
               begin
                  if not Crlf then
                     return Given;
                  end if;
                  for Index in Given'Range loop
                     if Given (Index) = ASCII.LF
                       and then (Index = Given'First or else Given (Index - 1) /= ASCII.CR)
                     then
                        U.Append (Result, ASCII.CR);
                     end if;
                     U.Append (Result, Given (Index));
                  end loop;
                  return U.To_String (Result);
               end Fitted;

               function Laid_Out return String is
               begin
                  if Only_Indent and then Ada.Strings.Fixed.Index (New_Text, [1 => ASCII.LF]) > 0 then
                     Lay_Out;
                  end if;
                  return (if Shifted
                          then Text (Text'First .. Line_Start - 1) & Fitted (U.To_String (Moved))
                          else Text (Text'First .. At_Text - 1) & Fitted (New_Text));
               end Laid_Out;

               After : constant String :=
                 Laid_Out & Text (At_Text + Old_Text'Length .. Text'Last);
               From  : constant Positive := Line_At (Text, At_Text);
               Upto  : constant Positive := From + Natural'Max (1, Lines_In (New_Text)) - 1;
               Names : constant String := Declarations_In (After, From, Upto);
               Put   : Said;
            begin
               Replace (Path, After, Put, Base);
               if Put.Failed then
                  return Put;
               end if;
               return
                 (Before_Revision => U.To_Unbounded_String (Now),
                  After_Revision  => U.To_Unbounded_String (Revision (After)),
                  Text    => U.To_Unbounded_String
                    ("edited " & Path & " at line" & Natural'Image (From) & ":"
                     & Natural'Image (Lines_In (Old_Text)) & " line"
                     & (if Lines_In (Old_Text) = 1 then "" else "s") & " replaced by"
                     & Natural'Image (Lines_In (New_Text))
                     & (if Names = "" then "" else "; in " & Names)
                     & (if Chosen > 0
                        then "; old_text is in the file" & Natural'Image (Times_There)
                             & " times, and was edited in the one within the lines you last read"
                        else "")
                     & (if Shifted then "; the new lines were set at that line's indentation ("
                                         & Ada.Strings.Fixed.Trim (Natural'Image (Lead), Ada.Strings.Left)
                                         & " spaces), each kept where it stood from the first"
                        else "")
                     & "; revision now " & Revision (After) & Kept_Note (Put)),
                  Changed => True,
                  Durable => Put.Durable,
                  Permissions_Kept => Put.Permissions_Kept,
                  others  => <>);
            end;
         end;
      end;
   exception
      when others =>
         return Failing ("could not write " & Path);
   end Edit;

   ----------------
   -- Read_Range --
   ----------------

   function Read_Range (Path : String; First, Last : Natural; Base : String := "") return Said is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
      Result : Said;
   begin
      if First = 0 or else (Last /= 0 and then Last < First) then
         return Failing ("read_range takes first_line from 1, and last_line at or after it (0 for the end)");
      end if;
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) and then Status.Code = E.IO_File_Too_Large then
         return Failing (Path & " is too large to read here (" & E.Text_Of (Status, "detail")
                         & "): search_file finds the lines you want");
      elsif E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      declare
         Text  : constant String := U.To_String (Held);
         Total : constant Natural := Lines_In (Text);
         Upto  : constant Natural :=
           Natural'Min (Natural'Min ((if Last = 0 then Total else Last), Total), First + Range_Most - 1);
         Line  : Positive := 1;
         Start : Positive := Text'First;
         --  The last line given, and whether the bytes, not the lines,
         --  ended the range: held to the lines alone, a range of long ones
         --  was an answer too large to return, every time it was asked.
         Shown : Natural := First - 1;
         Full  : Boolean := False;
      begin
         if First > Total then
            return Failing (Path & " has" & Natural'Image (Total) & " lines");
         end if;
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = ASCII.LF then
               if Line >= First and then Line <= Upto then
                  declare
                     --  The number, a colon and a space before the line: a
                     --  tab there was copied into old_text, where JSON
                     --  allows no raw tab; the space a model may copy into
                     --  the indentation is one an edit matched loosely takes
                     --  in its stride.
                     Head : constant String := Image (Line) & ": ";
                     Room : constant Integer :=
                       Range_Bytes - Path'Length - U.Length (Result.Text) - Head'Length - 1;
                  begin
                     if Index - Start <= Room then
                        U.Append (Result.Text, Head & Text (Start .. Index - 1) & ASCII.LF);
                        Shown := Line;
                     else
                        --  A line longer than all the room is shown in part,
                        --  so that it can be read at all.
                        if Shown < First and then Room > 0 then
                           U.Append (Result.Text, Head & Text (Start .. Start + Room - 1) & ASCII.LF
                                     & "(line" & Natural'Image (Line) & " is longer than can be shown: its first"
                                     & Natural'Image (Room) & " characters)" & ASCII.LF);
                           Shown := Line;
                        end if;
                        Full := True;
                     end if;
                  end;
               end if;
               exit when Line >= Upto or else Full;
               Line := Line + 1;
               Start := Index + 1;
            end if;
         end loop;
         if Shown < (if Last = 0 then Total else Natural'Min (Last, Total)) then
            Result.Truncated := True;
            U.Append (Result.Text, "(" & (if Full then "as many lines as fit in one answer"
                                          else Natural'Image (Range_Most) & " lines at most")
                      & "; read on from line" & Natural'Image (Shown + 1) & ")" & ASCII.LF);
         end if;
         U.Append (Result.Text, "(" & Path & ":" & Natural'Image (Total) & " lines, revision "
                   & Revision (Text) & ")");
         Result.Before_Revision := U.To_Unbounded_String (Revision (Text));
         Result.After_Revision := Result.Before_Revision;
         return Result;
      end;
   end Read_Range;

   --  The lines of a text holding a pattern, each with what is before it.
   procedure Search_Text
     (Text, Pattern, Before : String;
      Into   : in out Said;
      Hits   : in out Natural)
   is
      Line  : Positive := 1;
      Start : Positive := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            declare
               Said_Line : constant String := Text (Start .. Index - 1);
            begin
               if Ada.Strings.Fixed.Index (Said_Line, Pattern) > 0 then
                  if Hits = Search_Most then
                     Into.Truncated := True;
                     return;
                  end if;
                  Hits := Hits + 1;
                  U.Append (Into.Text, Before & Image (Line) & ": "
                            & (if Said_Line'Length > 200
                               then Said_Line (Said_Line'First .. Said_Line'First + 199) & " ..."
                               else Said_Line)
                            & ASCII.LF);
               end if;
            end;
            Line := Line + 1;
            Start := Index + 1;
         end if;
      end loop;
   end Search_Text;

   -----------------
   -- Search_File --
   -----------------

   function Search_File (Path, Pattern : String; Base : String := "") return Said is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
      Result : Said;
      Hits   : Natural := 0;
   begin
      if Pattern = "" then
         return Failing ("search_file needs a pattern: the text to find");
      end if;
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      Search_Text (U.To_String (Held), Pattern, "", Result, Hits);
      if Hits = 0 then
         Result.Text := U.To_Unbounded_String ("no line of " & Path & " holds that");
      elsif Result.Truncated then
         U.Append (Result.Text, "(the first" & Natural'Image (Search_Most) & " only; a longer pattern narrows it)");
      end if;
      return Result;
   end Search_File;

   -----------------
   -- Search_Code --
   -----------------

   function Search_Code
     (Folder, Pattern : String; Base : String := "";
      May_Read : access function (Path : String) return Boolean := null) return Said is
      Result : Said;
      Hits   : Natural := 0;

      --  What could not be searched -- a folder that would not list, a file
      --  too large or that would not read -- counted and the first named:
      --  no match among what was searched is not no match.
      Unread_Files   : Natural := 0;
      Unread_Folders : Natural := 0;
      First_Unread   : U.Unbounded_String;

      --  Files whose name is the pattern, the first few: a search for a
      --  file's name finds no file that holds it, and "no file holds that"
      --  was read as no such file -- gemma-3-4b looked for the
      --  docs/Add_Times.md its helper had just written that way, and took
      --  it to be missing.
      Named      : U.Unbounded_String;
      Named_Seen : Natural := 0;

      procedure Unread (Path : String; Folder : Boolean) is
      begin
         if Folder then
            Unread_Folders := Unread_Folders + 1;
         else
            Unread_Files := Unread_Files + 1;
         end if;
         if U.Length (First_Unread) = 0 then
            First_Unread := U.To_Unbounded_String (Path);
         end if;
      end Unread;

      function Passed_Over (Name : String) return Boolean is
        (Name'Length = 0 or else Name (Name'First) = '.'
         or else Name in "obj" | "bin" | "alire" | "node_modules" | "target" | "__pycache__");

      procedure Walk (Here : String) is
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search (Search, On_Disk (Base, Here), "");
         while Ada.Directories.More_Entries (Search) and then not Result.Truncated loop
            Ada.Directories.Get_Next_Entry (Search, Found);
            declare
               use type Ada.Directories.File_Kind;
               Name : constant String := Ada.Directories.Simple_Name (Found);
               Full : constant String := (if Here = "." then Name else Here & "/" & Name);
            begin
               --  Not through a link -- one may point anywhere, outside the
               --  tree the search is of -- and not into what the caller may
               --  not read.
               if Passed_Over (Name)
                 or else Hostkit.Fs.Is_Link (On_Disk (Base, Full))
                 or else (May_Read /= null and then not May_Read (Full))
               then
                  null;
               elsif Ada.Directories.Kind (Found) = Ada.Directories.Directory then
                  Walk (Full);
               elsif Ada.Directories.Kind (Found) = Ada.Directories.Ordinary_File then
                  if (Name = Pattern or else Full = Pattern) and then Named_Seen < 3 then
                     Named_Seen := Named_Seen + 1;
                     U.Append (Named, (if Named_Seen = 1 then "" else ", ") & Full);
                  end if;
                  declare
                     Held   : U.Unbounded_String;
                     Status : E.Error_Info;
                  begin
                     Read_Text (Full, Held, Status, Base);
                     if E.Is_Ok (Status) then
                        Search_Text (U.To_String (Held), Pattern, Full & ":", Result, Hits);
                     elsif E.Text_Of (Status, "detail") /= "it is not text" then
                        --  A binary file holds no source text; any other
                        --  that would not read might have.
                        Unread (Full, Folder => False);
                     end if;
                  end;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            Unread (Here, Folder => True);
      end Walk;
   begin
      if Pattern = "" then
         return Failing ("search_code needs a pattern: the text to find");
      elsif not Ada.Directories.Exists (On_Disk (Base, Folder))
        or else Ada.Directories."/=" (Ada.Directories.Kind (On_Disk (Base, Folder)), Ada.Directories.Directory)
      then
         return Failing ("no folder at " & Folder);
      end if;
      Walk (Folder);
      if Unread_Files + Unread_Folders > 0 then
         --  Said whatever was found: a search that could not look
         --  everywhere does not say what is absent.
         declare
            Missed : constant String :=
              (if Unread_Files > 0 then Natural'Image (Unread_Files) & " file"
                 & (if Unread_Files = 1 then "" else "s") else "")
              & (if Unread_Files > 0 and then Unread_Folders > 0 then " and" else "")
              & (if Unread_Folders > 0 then Natural'Image (Unread_Folders) & " folder"
                 & (if Unread_Folders = 1 then "" else "s") else "");
         begin
            Result.Incomplete := True;
            if Hits = 0 then
               Result.Text := U.To_Unbounded_String
                 ("no file searched under " & Folder & " holds that -- but" & Missed
                  & " could not be searched (" & U.To_String (First_Unread)
                  & " the first), so it may be there");
            else
               U.Append (Result.Text, "(and" & Missed & " could not be searched, "
                         & U.To_String (First_Unread) & " the first)");
            end if;
         end;
      elsif Hits = 0 and then Named_Seen > 0 then
         Result.Text := U.To_Unbounded_String
           ("no file under " & Folder & " holds that text, but there is a file of that name: "
            & U.To_String (Named));
      elsif Hits = 0 then
         Result.Text := U.To_Unbounded_String ("no file under " & Folder & " holds that");
      elsif Result.Truncated then
         U.Append (Result.Text, "(the first" & Natural'Image (Search_Most) & " only; a longer pattern narrows it)");
      end if;
      return Result;
   end Search_Code;

end Model_Runner.Tools.Editing;
