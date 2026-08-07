with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Hostkit.Fs;

with Tarlib;
with Tarlib.Entries;
with Tarlib.Errors;
with Tarlib.Files;
with Tarlib.Writers;

with Model_Runner;

package body Packaging is

   package IO renames Ada.Text_IO;

   --  Copy one file into the open archive.
   procedure Add_File
     (Archive    : in out Tarlib.Writers.Writer;
      From       : String;
      As         : String;
      Executable : Boolean;
      Ok         : out Boolean)
   is
      use Ada.Streams;

      Size   : constant Ada.Directories.File_Size :=
        Ada.Directories.Size (From);
      Source : Stream_IO.File_Type;
      Result : Tarlib.Errors.Status;

      --  Copied in bounded chunks: a model file is not packaged, but the
      --  executable is tens of megabytes and there is no reason to hold it.
      Chunk : Stream_Element_Array (1 .. 64 * 1024);
      Last  : Stream_Element_Offset;
   begin
      Ok := False;

      --  The mode is set rather than defaulted. tarlib's default is 0644 for
      --  every regular file, which is right for the documents and wrong for
      --  the program: an archive whose executable unpacks without the execute
      --  bit is not a distribution, and the failure appears on someone else's
      --  machine rather than here.
      declare
         Attributes : Tarlib.Entries.Metadata :=
           Tarlib.Entries.Default_Metadata (Tarlib.Entries.Regular_File);
      begin
         if Executable then
            Attributes.Mode := 8#0755#;
         end if;

         Tarlib.Writers.Begin_Entry
           (Archive, As, Tarlib.Entries.Regular_File,
            Tarlib.Byte_Count (Size), Attributes, Result);
      end;
      if not Tarlib.Errors.Is_Success (Result) then
         return;
      end if;

      Stream_IO.Open (Source, Stream_IO.In_File, From);

      while not Stream_IO.End_Of_File (Source) loop
         Stream_IO.Read (Source, Chunk, Last);
         exit when Last < Chunk'First;

         Tarlib.Writers.Write (Archive, Chunk (Chunk'First .. Last), Result);
         if not Tarlib.Errors.Is_Success (Result) then
            Stream_IO.Close (Source);
            return;
         end if;
      end loop;

      Stream_IO.Close (Source);

      Tarlib.Writers.End_Entry (Archive, Result);
      Ok := Tarlib.Errors.Is_Success (Result);
   exception
      when others =>
         if Stream_IO.Is_Open (Source) then
            Stream_IO.Close (Source);
         end if;
         Ok := False;
   end Add_File;

   ---------
   -- Run --
   ---------

   procedure Run (Root : String; Target : String; Written : out Boolean) is
      Prefix : constant String :=
        Model_Runner.Program_Name & "-" & Model_Runner.Version;

      Archive_Path : constant String :=
        Ada.Directories.Compose (Target, Prefix & ".tar");

      --  The executable first, then what it needs beside it, then the
      --  documents. Everything here is required: an archive missing any of it
      --  is not one worth writing.
      type Pair is record
         From       : access constant String;
         Into       : access constant String;
         Executable : Boolean;
      end record;

      --  The names below are paths inside the archive, not on disk. USTAR
      --  writes them with a forward slash on every host, so these stay as
      --  they are: joining them the host's way would produce an archive that
      --  unpacks wrongly everywhere except where it was made.
      Executable  : aliased constant String := "bin/" & Model_Runner.Program_Name;
      Executable_At : aliased constant String :=
        Prefix & "/bin/" & Model_Runner.Program_Name;
      Catalog     : aliased constant String :=
        "resources/messages/catalog.txt";
      Catalog_At  : aliased constant String :=
        Prefix & "/share/" & Model_Runner.Program_Name
        & "/messages/catalog.txt";
      Licence     : aliased constant String := "LICENSE";
      Licence_At  : aliased constant String := Prefix & "/LICENSE";
      Readme      : aliased constant String := "README.md";
      Readme_At   : aliased constant String := Prefix & "/README.md";
      Changes     : aliased constant String := "CHANGELOG.md";
      Changes_At  : aliased constant String := Prefix & "/CHANGELOG.md";
      Security    : aliased constant String := "SECURITY.md";
      Security_At : aliased constant String := Prefix & "/SECURITY.md";

      Contents : constant array (1 .. 6) of Pair :=
        [(Executable'Access, Executable_At'Access, True),
         (Catalog'Access, Catalog_At'Access, False),
         (Licence'Access, Licence_At'Access, False),
         (Readme'Access, Readme_At'Access, False),
         (Changes'Access, Changes_At'Access, False),
         (Security'Access, Security_At'Access, False)];

      Sink    : aliased Tarlib.Files.File_Output_Sink;
      Archive : Tarlib.Writers.Writer;
      Result  : Tarlib.Errors.Status;
      Added   : Natural := 0;
   begin
      Written := False;

      --  Every input is checked before anything is written, so a failure
      --  leaves no half-made archive behind.
      for Entry_Item of Contents loop
         declare
            --  Joined rather than composed: these are relative paths with
            --  separators in them, and Compose takes a simple name.
            Full : constant String := Hostkit.Fs.Join (Root, Entry_Item.From.all);
         begin
            if not Ada.Directories.Exists (Full) then
               IO.Put_Line
                 (IO.Standard_Error,
                  "package: missing " & Entry_Item.From.all
                  & (if Entry_Item.From.all = Executable
                     then " -- build it first with alr build --release"
                     else ""));
               return;
            end if;
         end;
      end loop;

      Tarlib.Files.Create_Write (Sink, Archive_Path, Result);
      if not Tarlib.Errors.Is_Success (Result) then
         IO.Put_Line
           (IO.Standard_Error, "package: cannot write " & Archive_Path);
         return;
      end if;

      Tarlib.Writers.Initialize (Archive, Sink, Result);
      if not Tarlib.Errors.Is_Success (Result) then
         Tarlib.Files.Close (Sink, Result);
         return;
      end if;

      for Entry_Item of Contents loop
         declare
            Full : constant String := Hostkit.Fs.Join (Root, Entry_Item.From.all);
            Ok   : Boolean;
         begin
            Add_File
              (Archive, Full, Entry_Item.Into.all,
               Entry_Item.Executable, Ok);
            if not Ok then
               IO.Put_Line
                 (IO.Standard_Error,
                  "package: could not add " & Entry_Item.From.all);
               Tarlib.Files.Close (Sink, Result);
               return;
            end if;
            Added := Added + 1;
         end;
      end loop;

      Tarlib.Writers.Finish (Archive, Result);
      if not Tarlib.Errors.Is_Success (Result) then
         Tarlib.Files.Close (Sink, Result);
         return;
      end if;

      Tarlib.Files.Close (Sink, Result);
      Written := Tarlib.Errors.Is_Success (Result);

      if Written then
         IO.Put_Line
           (IO.Standard_Error,
            "wrote " & Archive_Path & ", " & Added'Image & " files");
      end if;
   end Run;

end Packaging;
