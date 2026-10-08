with System;

with Model_Runner.Bytes;

--  The panel cache's files: where a load keeps the weights it wrote in
--  panels, so the next load maps them rather than writing them again.
--
--  Apart from the model's reading on purpose. The unit that interprets a
--  model may not reach a file, so that nothing a file says can make it read
--  another; the path here is the caller's, never the model's, and this is
--  where it is touched.
package Model_Runner.Panel_Cache is

   --  Whether a panel cache file is there to be mapped.
   --
   --  @param Path The caller's path for it.
   --  @return True where a file of that name exists.
   function Is_There (Path : String) return Boolean;

   --  Mark a panel cache file used now, so the cache's bound lets files
   --  nobody has mapped for longer go first.
   --
   --  @param Path The file just mapped.
   procedure Mark_Used (Path : String);

   --  Remove all but the newest Count of the cache files whose names begin
   --  as Prefix's does, in its directory: a split model's panels are kept
   --  one file to each split, and each is gigabytes. Anything the host
   --  refuses is left where it is.
   --
   --  @param Prefix The path the files' names begin with.
   --  @param Count How many of the newest to keep.
   procedure Keep_Newest (Prefix : String; Count : Natural);

   --  The panels just written, copied to the cache beside the run rather
   --  than before it: four gigabytes took nine seconds on the first load,
   --  and nothing the run does waits for them. Given the file's path, its
   --  header and where the panels lie; whoever holds the panels waits for
   --  the copy before letting them go. The file is written beside its final
   --  name and renamed into it whole, so a load never maps half of one, and
   --  anything that goes wrong -- no room, no directory -- leaves no file.
   task type Writing is

      --  Begin the copy.
      --
      --  @param Path Where the cache file goes.
      --  @param Header The bytes the file begins with, before the panels.
      --  @param From The panels' first byte.
      --  @param Total The panels' bytes.
      entry Start
        (Path   : String;
         Header : String;
         From   : System.Address;
         Total  : Model_Runner.Bytes.Byte_Count);
   end Writing;

end Model_Runner.Panel_Cache;
