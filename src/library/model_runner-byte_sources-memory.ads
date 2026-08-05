--  A byte source backed by a caller-owned buffer.
--
--  Used by the synthetic-model fixtures in the tests crate and by the
--  malformed-input corpus, so that parser behaviour can be exercised without
--  touching the filesystem.
--
--  Task safety: not task safe.
package Model_Runner.Byte_Sources.Memory is

   --  A source that reads from a buffer the caller keeps alive.
   type Buffer_Source (Data : access constant Model_Runner.Bytes.Byte_Array)
   is limited new Source with private;

   --  Size of the underlying buffer.
   --
   --  @param Self Source instance.
   --  @return Buffer length in bytes.
   overriding function Size
     (Self : Buffer_Source) return Model_Runner.Bytes.Byte_Count;

   --  Copy bytes out of the buffer.
   --
   --  @param Self Source instance.
   --  @param Offset Absolute zero-based byte offset.
   --  @param Target Buffer filled on success.
   --  @param Status Success or GGUF_Truncated.
   overriding procedure Read
     (Self   : in out Buffer_Source;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report that no mapping is involved.
   --
   --  @param Self Source instance.
   --  @return Always False.
   overriding function Is_Mapped (Self : Buffer_Source) return Boolean;

   --  Stable identifier of an in-memory source.
   --
   --  @param Self Source instance.
   --  @return The fixed token "<memory>".
   overriding function Name (Self : Buffer_Source) return String;

private

   type Buffer_Source (Data : access constant Model_Runner.Bytes.Byte_Array)
   is limited new Source with null record;

end Model_Runner.Byte_Sources.Memory;
