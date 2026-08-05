with System;

with Model_Runner.Bytes;

--  Read-only file mapping.
--
--  This is one of the few packages that touches System.Address. It maps a file
--  read-only and private, so the source model file can never be modified
--  through the mapping, and it exposes only the base address and the length.
--  Callers turn those into a bounds-checked Ada array by declaring an overlay
--  object; no address arithmetic escapes this package or its clients' overlay
--  declarations.
--
--  Availability. Mapping is a host facility, not a requirement. When it is not
--  available Open reports Available => False and the caller falls back to
--  ordinary reads, or fails when the caller demanded a mapping.
--
--  Task safety: a Region is created and destroyed by its owner; concurrent
--  reads through the mapping are safe because the mapping is read-only.
package Model_Runner.Platform.Mapping is

   use type Model_Runner.Bytes.Byte_Count;

   --  Largest region this package will map. A file larger than this is read
   --  rather than mapped, which keeps the address-space request bounded even
   --  for an implausibly large input.
   Max_Mapped_Bytes : constant Model_Runner.Bytes.Byte_Count := 2 ** 40;

   --  A read-only mapping of a whole file.
   type Region is limited private;

   --  Report whether the host provides read-only file mapping.
   --
   --  @return True when Open can succeed for a suitable file.
   function Is_Supported return Boolean;

   --  Map a file read-only.
   --
   --  @param Item Region to fill in.
   --  @param Path File to map.
   --  @param Available True when the file was mapped.
   procedure Open
     (Item      : in out Region;
      Path      : String;
      Available : out Boolean);

   --  Release a mapping. Idempotent and never raises.
   --
   --  @param Item Region to release.
   procedure Close (Item : in out Region);

   --  Report whether a region currently holds a mapping.
   --
   --  @param Item Region to inspect.
   --  @return True when mapped.
   function Is_Open (Item : Region) return Boolean;

   --  Base address of a mapping.
   --
   --  @param Item Mapped region.
   --  @return Address of the first mapped byte, or Null_Address.
   function Base (Item : Region) return System.Address;

   --  Length of a mapping in bytes.
   --
   --  @param Item Mapped region.
   --  @return Mapped length, or 0.
   function Length (Item : Region) return Model_Runner.Bytes.Byte_Count;

   --  Copy bytes out of a mapping.
   --
   --  Bounds are checked here so that clients never perform address
   --  arithmetic of their own.
   --
   --  @param Item Mapped region.
   --  @param Offset Zero-based offset within the mapping.
   --  @param Target Buffer to fill.
   --  @param Ok True when the request lay wholly inside the mapping.
   procedure Copy
     (Item   : Region;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Ok     : out Boolean);

private

   --  Handle is the file: a descriptor on POSIX, a HANDLE on Windows, which
   --  is pointer-sized and so does not fit in Integer. Mapping is the file
   --  mapping object Windows needs in addition; POSIX leaves it unset.
   type Region is limited record
      Address : System.Address := System.Null_Address;
      Size    : Model_Runner.Bytes.Byte_Count := 0;
      Handle  : Long_Long_Integer := -1;
      Mapping : Long_Long_Integer := -1;
   end record;

end Model_Runner.Platform.Mapping;
