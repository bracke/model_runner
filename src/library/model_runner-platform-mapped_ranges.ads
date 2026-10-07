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
   procedure Note (Start : System.Address; Length : Model_Runner.Bytes.Byte_Count);

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

end Model_Runner.Platform.Mapped_Ranges;
