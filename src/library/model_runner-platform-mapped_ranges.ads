with System;
with Model_Runner.Bytes;

--  The runs of memory that are a file's read-only mapping, as the mapping
--  opened them: a run there can be given back to the host and read again
--  from the file, where memory of the process's own would have to go to
--  swap. Asked before such advice is given (Pages.Page_Out).
package Model_Runner.Platform.Mapped_Ranges is

   --  Note a mapping, as it opens.
   --
   --  @param Start Its first byte.
   --  @param Length Its bytes.
   --  @param Handle The host's handle on the file it maps, open while the
   --    mapping is, from its first byte; negative where there is none.
   procedure Note
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Handle : Long_Long_Integer := -1);

   --  Forget one, as it closes.
   --
   --  @param Start Its first byte, as noted.
   procedure Forget (Start : System.Address);

   --  Whether a run lies wholly inside one noted mapping.
   --
   --  @param Start The run's first byte.
   --  @param Length Its bytes.
   --  @return True where it does.
   function Holds
     (Start : System.Address; Length : Model_Runner.Bytes.Byte_Count)
      return Boolean;

   --  The file behind a run that lies wholly inside one noted mapping.
   --
   --  @param Start The run's first byte.
   --  @param Length Its bytes.
   --  @param Handle The mapping's file, as noted.
   --  @param Offset Where the run begins in that file.
   --  @return True where the run is a noted mapping's and it noted a handle.
   --    Where True, the handle stays the mapping's -- Forget waits -- until
   --    Located_Done is called, which the caller must do once it holds the
   --    file by a handle of its own, or no longer needs it.
   function Locate
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Handle : out Long_Long_Integer;
      Offset : out Model_Runner.Bytes.Byte_Count) return Boolean;

   --  Say a handle Locate gave out is no longer being opened from: the
   --  mappings it named may be forgotten again.
   procedure Located_Done;

end Model_Runner.Platform.Mapped_Ranges;
