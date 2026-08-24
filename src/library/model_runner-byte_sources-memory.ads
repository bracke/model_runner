with System;
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

   --  The buffer itself, which is already in this process.
   --
   --  @param Self Source instance.
   --  @return Address of the first byte, or Null_Address when there is none.
   overriding function Base (Self : Buffer_Source) return System.Address;

   --  Report that a buffer cannot change behind the reader.
   --
   --  There is nothing behind it: the bytes are the caller's and this source
   --  only reads them. A file has to be asked; this does not.
   --
   --  @param Self Source instance.
   --  @return Always False.
   overriding function Changed (Self : Buffer_Source) return Boolean;

   --  Stable identifier of an in-memory source.
   --
   --  @param Self Source instance.
   --  @return The fixed token "<memory>".
   overriding function Name (Self : Buffer_Source) return String;

private

   type Buffer_Source (Data : access constant Model_Runner.Bytes.Byte_Array)
   is limited new Source with null record;

end Model_Runner.Byte_Sources.Memory;
