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

   --  Tell the host a run of a file's mapping is not wanted again soon, so
   --  that its pages leave memory now rather than compete with what is:
   --  weights copied to a device whose memory is the host's own were held
   --  twice, once in the mapping, and a host short of memory swapped the
   --  device's pages out to keep them. Advice only: a page read again is
   --  read from the file as it was. Only the whole pages inside the run.
   --
   --  @param Start The first byte.
   --  @param Length Bytes in the run; less than a page does nothing.
   procedure Page_Out
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count);

   --  Tell the host the next reads of a run of a file's mapping are a few
   --  scattered bytes, or that they are not any more. A fault on a mapping
   --  read as it usually is reads the pages around it as well; a sample
   --  of four thousand bytes across a model whose pages had gone back
   --  read half a gigabyte from the file for them and took 14 s. Advice
   --  only, and only the whole pages inside the run.
   --
   --  @param Start The first byte.
   --  @param Length Bytes in the run; less than a page does nothing.
   --  @param Scattered True before the scattered reads, False after.
   procedure Expect_Scattered
     (Start     : System.Address;
      Length    : Model_Runner.Bytes.Byte_Count;
      Scattered : Boolean);

   --  Copy a run of a file's read-only mapping from the file itself, in
   --  large reads that pass the host's cache by, rather than through the
   --  mapping's faults.
   --
   --  A mapping read for the first time is read a fault at a time, and
   --  each fault reads ahead only as far as the host's read-ahead goes --
   --  128 KiB on this machine's drive, which answers a third of a
   --  gigabyte a second that way and two and a half in reads of
   --  megabytes. A model uploaded to the device is read once and its
   --  pages given back (Page_Out), so the host's cache was never going to
   --  keep it.
   --
   --  @param From The run's first byte, inside a mapping noted with its
   --    file (Mapped_Ranges.Note).
   --  @param Into Where it goes: Length bytes nobody else is writing.
   --  @param Length Its bytes.
   --  @param Done True where it was read; False where it was not -- a
   --    host without such reads, a run outside a noted mapping, a read the
   --    host refused -- and Into then holds nothing the caller may use.
   procedure Read_Direct
     (From   : System.Address;
      Into   : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Done   : out Boolean);

end Model_Runner.Platform.Pages;
