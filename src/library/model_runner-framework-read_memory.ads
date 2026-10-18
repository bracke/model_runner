--  What reading a file gave, held against the file's stamp and given again
--  while the stamp is the same: for computations that read many small files
--  each time -- a derivation's key, a scan of the project's tasks -- of
--  which most have not changed since.
--
--  A stamp is the file's size and its modification and change times to the
--  nanosecond, one look at it; a file whose times are within two seconds of
--  now is read again whatever its stamp, since two writes of one size in
--  one kernel tick share one. Where the host gives no such times nothing is
--  held. What could not be read -- a value starting with "!" -- is never
--  held: an unreadable file is not taken for one remembered.
private package Model_Runner.Framework.Read_Memory is

   --  What reading a file gives, from memory where its stamp says it is as
   --  it was, else read and remembered.
   --
   --  @param Kind What is read of it, keeping one reading of a file apart
   --    from another of the same file.
   --  @param Full The file's whole path.
   --  @param Work What reads it.
   --  @return What Work gave, now or when the file was as it is.
   function Remembered
     (Kind, Full : String;
      Work       : not null access function return String) return String;

end Model_Runner.Framework.Read_Memory;
