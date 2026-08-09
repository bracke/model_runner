private with Ada.Streams.Stream_IO;

private with Model_Runner.Platform.Mapping;

--  A byte source backed by a file on disk.
--
--  The file is opened read-only and is never written to. It stays open for the
--  life of the source, so validated offsets always refer to the bytes that
--  were validated.
--
--  Mapping. A file source may serve reads from a read-only mapping instead of
--  from the file handle. The choice is made once, at Open, according to the
--  requested policy; the rest of the crate cannot tell the difference except
--  through Is_Mapped and the reported statistics.
--
--  Task safety: not task safe.
package Model_Runner.Byte_Sources.Files is

   --  How hard to try to map the file.
   type Mapping_Policy is
     (Mapping_Automatic,   --  Map when possible, read when not.
      Mapping_Required,    --  Fail when the file cannot be mapped.
      Mapping_Disabled);   --  Never map.

   --  A source that reads from an open file.
   type File_Source is limited new Source with private;

   --  Open a file for reading.
   --
   --  @param Item Source to open.
   --  @param Path File to open.
   --  @param Policy Mapping policy to apply.
   --  @param Max_Bytes Largest accepted file size; 0 means unlimited.
   --  @param Status Success, IO_Open_Failed, IO_Not_A_Regular_File,
   --    IO_File_Too_Large or Lifecycle_Mapping_Required.
   procedure Open
     (Item      : in out File_Source;
      Path      : String;
      Policy    : Mapping_Policy := Mapping_Automatic;
      Max_Bytes : Model_Runner.Bytes.Byte_Count := 0;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Close the file and release any mapping. Idempotent.
   --
   --  @param Item Source to close.
   procedure Close (Item : in out File_Source);

   --  Report whether the source is open.
   --
   --  @param Item Source to inspect.
   --  @return True when a file is open.
   function Is_Open (Item : File_Source) return Boolean;

   --  Report whether the file has changed size since it was opened.
   --
   --  This is the file's answer to Byte_Sources.Changed, which model
   --  preparation asks before it reads the tensors -- a cheap check that the
   --  file was not replaced between validation and preparation. It cannot
   --  detect an in-place edit of the same length; the open handle covers
   --  that case on hosts where a replaced path leaves the original inode
   --  reachable.
   --
   --  @param Item Source to inspect.
   --  @return True when the size on disk differs from the size at Open.
   function Size_Changed (Item : File_Source) return Boolean;

   --  See Byte_Sources.Changed.
   --
   --  @param Self Source to inspect.
   --  @return True when the file has changed size since it was opened.
   overriding function Changed (Self : File_Source) return Boolean
   is (Size_Changed (Self));

   --  Size of the open file.
   --
   --  @param Self Source instance.
   --  @return Size in bytes, or 0 when closed.
   overriding function Size
     (Self : File_Source) return Model_Runner.Bytes.Byte_Count;

   --  Read bytes from the file or its mapping.
   --
   --  @param Self Source instance.
   --  @param Offset Absolute zero-based byte offset.
   --  @param Target Buffer filled on success.
   --  @param Status Success, GGUF_Truncated or IO_Read_Failed.
   overriding procedure Read
     (Self   : in out File_Source;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report whether reads are served from a mapping.
   --
   --  @param Self Source instance.
   --  @return True when the file is mapped.
   overriding function Is_Mapped (Self : File_Source) return Boolean;

   --  Path the source was opened with.
   --
   --  @param Self Source instance.
   --  @return File path, or an empty string when closed.
   overriding function Name (Self : File_Source) return String;

private

   Max_Path_Length : constant := 4096;

   type File_Source is limited new Source with record
      File        : Ada.Streams.Stream_IO.File_Type;
      Map         : Model_Runner.Platform.Mapping.Region;
      Mapped      : Boolean := False;
      Opened      : Boolean := False;
      Length      : Model_Runner.Bytes.Byte_Count := 0;
      Path_Text   : String (1 .. Max_Path_Length) := [others => ' '];
      Path_Last   : Natural := 0;
   end record;

end Model_Runner.Byte_Sources.Files;
