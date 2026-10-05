with System;

with Model_Runner.Bytes;

--  Large pages for a big buffer the program fills itself.
--
--  A copy of hundreds of megabytes made into fresh memory -- a projector's
--  weights padded to the shapes the device's tile reads -- takes a fault for
--  every page it first touches, and at the host's ordinary page that is most
--  of the copy's time. Where the host backs memory with large pages only when
--  asked, this asks. Only the asking is host-specific: one spec, one body a
--  host, and a host that has no such thing does nothing.
--
--  Task safety: a call touches nothing but the host's view of the buffer.
package Model_Runner.Platform.Pages is

   --  Ask the host to back Bytes with large pages, before it is first written.
   --
   --  Advice and nothing more: the contents are what they were, a host that
   --  refuses or has no large pages changes nothing, and a buffer too small
   --  to hold one is left alone.
   --
   --  @param Bytes The buffer; null does nothing.
   procedure Prefer_Large (Bytes : Model_Runner.Bytes.Byte_Array_Access);

   --  The same for a run of memory named by where it starts and how long
   --  it is: an array of another element type, which a session's cache is
   --  -- written a position at a time, and at the host's ordinary page a
   --  generated token's row took a fault for every page it reached first,
   --  15 us a layer of phi-3.
   --
   --  @param Start The first byte.
   --  @param Length Bytes in the run; nought does nothing.
   procedure Prefer_Large_At
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count);

end Model_Runner.Platform.Pages;
