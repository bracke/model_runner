with Model_Runner.Bytes;
with Model_Runner.Errors;

--  Random-access read-only access to model bytes.
--
--  The GGUF parser never relies on an implicit stream position: every read
--  states its absolute offset. That makes the parser re-entrant, makes every
--  bounds check local, and lets a test replay the same source in any order.
--
--  A source is opened once and kept open for the life of the prepared model.
--  Validated offsets are not re-derived by reopening the file by path, so a
--  path swapped between validation and preparation cannot substitute different
--  bytes.
--
--  Task safety: a source is read by the task that owns the preparation. The
--  file-backed implementation is not task safe.
package Model_Runner.Byte_Sources is

   --  A readable span of bytes with a known size.
   type Source is limited interface;

   --  Total size of the source in bytes.
   --
   --  @param Self Source instance.
   --  @return Size in bytes.
   function Size (Self : Source) return Model_Runner.Bytes.Byte_Count
   is abstract;

   --  Read exactly Target'Length bytes starting at Offset.
   --
   --  A short read is a failure, not a partial success: the parser always
   --  knows how many bytes a field needs.
   --
   --  @param Self Source instance.
   --  @param Offset Absolute zero-based byte offset.
   --  @param Target Buffer filled on success; unspecified on failure.
   --  @param Status Success, IO_Read_Failed or GGUF_Truncated.
   procedure Read
     (Self   : in out Source;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Status : out Model_Runner.Errors.Error_Info) is abstract;

   --  Report whether the source is backed by a read-only mapping.
   --
   --  @param Self Source instance.
   --  @return True when reads are served from mapped memory.
   function Is_Mapped (Self : Source) return Boolean is abstract;

   --  Stable identifier of the source used in diagnostics.
   --
   --  For a file this is its path. It is never localized and never escaped
   --  here; the presentation layer escapes it before display.
   --
   --  @param Self Source instance.
   --  @return Source name, possibly empty.
   function Name (Self : Source) return String is abstract;

   type Source_Reference is access all Source'Class;

end Model_Runner.Byte_Sources;
