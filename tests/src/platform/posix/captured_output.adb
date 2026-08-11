with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Interfaces.C;
with Interfaces.C.Strings;

package body Captured_Output is

   use type Interfaces.C.int;

   --  The four host calls, bound here because here is a directory the
   --  project file picks per host. Binding one from the portable half is
   --  what the repository checks refuse, and rightly: this file is compiled
   --  on POSIX and its sibling on Windows.
   --
   --  This went through Hostkit.Descriptors for two days, which reads as the
   --  portable answer and is not one for this purpose. Assign is dup2 on
   --  POSIX and SetStdHandle on Windows, and SetStdHandle changes the
   --  process's standard handle -- which is not the C runtime's file
   --  descriptor 1, and it is descriptor 1 that Ada.Text_IO writes through.
   --  So the redirection silently did nothing on Windows: the capture came
   --  back empty and five tests failed there while passing here.
   function C_Open
     (Path  : Interfaces.C.Strings.chars_ptr;
      Flags : Interfaces.C.int;
      Mode  : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";

   function C_Close (Descriptor : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "close";

   function C_Dup (Descriptor : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "dup";

   function C_Dup2 (From, To : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "dup2";

   --  The file is emptied through the standard library and then opened
   --  write-only, rather than opened with create-and-truncate flags.
   --
   --  Those flag values are not the same on every host: O_CREAT is 8#100# on
   --  Linux and 16#200# on macOS, O_TRUNC 8#1000# and 16#400#. The Linux
   --  numbers written here meant that on macOS the open asked for create and
   --  something else entirely and never asked for truncate, so a capture
   --  wrote over the start of the previous one and left its tail behind. A
   --  run that produced one byte read back as the nine bytes before it, and
   --  the stop test on that host compared a truncated run against an
   --  untruncated one and found them equal -- which is exactly what it
   --  reported.
   --
   --  O_WRONLY is 1 everywhere, which is the one value worth hard-coding.
   --  Write only. The file is emptied first, so nothing else is needed.
   Write_Only : constant Interfaces.C.int := 1;

   Standard_Output_Fd : constant Interfaces.C.int := 1;

   --  The file read back, with nothing between this and the bytes.
   --
   --  Read here rather than through Project_Tools, so that a host body
   --  depends on the standard library and its host and nothing else: the
   --  check that compiles every host body for every host gives it the
   --  crate's own sources and not a dependency's, and a body that reaches
   --  outside cannot be compiled from a machine of the wrong kind.
   --  Empty the file, portably, before the descriptor is opened on it.
   --
   --  Reported rather than swallowed. This is the whole of the truncation:
   --  if it does not happen, the descriptor opens on whatever was there
   --  before and a short capture reads back as the longer one before it,
   --  which is the defect this replaced. A procedure whose one job can fail
   --  in silence is the same defect with a different spelling.
   function Emptied (Path : String) return Boolean is
      Handle : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (Handle, Ada.Streams.Stream_IO.Out_File, Path);
      Ada.Streams.Stream_IO.Close (Handle);
      return True;
   exception
      when others =>
         return False;
   end Emptied;

   function Contents (Path : String) return String is
      use Ada.Streams;

      Source : Stream_IO.File_Type;
      Room   : String (1 .. 1024 * 1024);
      Used   : Natural := 0;
   begin
      Stream_IO.Open (Source, Stream_IO.In_File, Path);

      while not Stream_IO.End_Of_File (Source) and then Used < Room'Last loop
         declare
            Block : Stream_Element_Array (1 .. 4096);
            Last  : Stream_Element_Offset;
         begin
            Stream_IO.Read (Source, Block, Last);
            exit when Last < Block'First;

            for Index in Block'First .. Last loop
               exit when Used = Room'Last;
               Used := Used + 1;
               Room (Used) := Character'Val (Block (Index));
            end loop;
         end;
      end loop;

      Stream_IO.Close (Source);
      return Room (1 .. Used);
   exception
      when others =>
         if Stream_IO.Is_Open (Source) then
            Stream_IO.Close (Source);
         end if;
         return "";
   end Contents;

   Saved   : Interfaces.C.int := -1;
   Opened  : Interfaces.C.int := -1;
   Working : Boolean := False;
   Worked  : Boolean := False;
   Where   : String (1 .. 512);
   Where_L : Natural := 0;

   ----------
   -- Open --
   ----------

   procedure Open (Path : String) is
      Name : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Path);
      Ignored : Interfaces.C.int;
   begin
      --  One at a time. This holds a single saved descriptor, so a second
      --  Open inside the first would overwrite it and the first Close would
      --  restore standard output to the other capture rather than to where
      --  it started. That is not hypothetical: nesting a capture inside a
      --  capture is how the whole suite's report went missing, two of
      --  fifty-seven opens never being closed.
      if Working then
         Interfaces.C.Strings.Free (Name);
         raise Program_Error with "a capture is already open";
      end if;

      Working := False;
      Worked := False;
      Where_L := Natural'Min (Path'Length, Where'Length);
      Where (1 .. Where_L) := Path (Path'First .. Path'First + Where_L - 1);

      if not Emptied (Path) then
         Interfaces.C.Strings.Free (Name);
         return;
      end if;

      Opened := C_Open (Name, Write_Only, 0);
      Interfaces.C.Strings.Free (Name);

      if Opened < 0 then
         return;
      end if;

      --  Flush first: anything Text_IO is holding belongs to the caller's
      --  output and not to the file about to take its place.
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Saved := C_Dup (Standard_Output_Fd);
      if Saved < 0 then
         Ignored := C_Close (Opened);
         return;
      end if;

      if C_Dup2 (Opened, Standard_Output_Fd) < 0 then
         Ignored := C_Close (Saved);
         Ignored := C_Close (Opened);
         return;
      end if;

      Working := True;
      Worked := True;
   end Open;

   -----------
   -- Close --
   -----------

   function Close return String is
      Ignored : Interfaces.C.int;
   begin
      if not Working then
         return "";
      end if;

      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Ignored := C_Dup2 (Saved, Standard_Output_Fd);
      Ignored := C_Close (Saved);
      Ignored := C_Close (Opened);
      Working := False;

      return Contents (Where (1 .. Where_L));
   end Close;

   -----------------
   -- Took_Effect --
   -----------------

   function Took_Effect return Boolean is (Worked);

end Captured_Output;
