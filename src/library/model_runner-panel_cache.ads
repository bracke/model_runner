with System;
with Ada.Strings.Unbounded;

with Model_Runner.Bytes;
with Model_Runner.Platform.Mapping;

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

   --  A cache file being built where it will be read: made beside its
   --  final name with its header, and mapped for writing, so the panels
   --  are built straight into the file's pages rather than into the
   --  process's own memory and copied out after. Those were what a host
   --  short of memory sent to swap on a split model's first load at a
   --  context -- four gigabytes of ThinkingCap's -- and pages of a file are
   --  written back and let go instead.
   type Building is limited private;

   --  Make the file and map it.
   --
   --  @param Item The file being built.
   --  @param Path Where the cache file goes; it is built beside it.
   --  @param Header The bytes the file begins with, before the panels.
   --  @param Total The panels' bytes.
   --  @param Panels Where the panels are to be built, the header past.
   --  @param Ok False where no file was made or mapped; nothing is left.
   procedure Begin_Build
     (Item   : in out Building;
      Path   : String;
      Header : String;
      Total  : Model_Runner.Bytes.Byte_Count;
      Panels : out System.Address;
      Ok     : out Boolean);

   --  The panels are built: the file renamed into its name whole, its
   --  mapping kept until Release. What was written is the host's to write
   --  back.
   --
   --  @param Item The file built.
   --  @param Ok False where it could not be named; nothing is left.
   procedure Finish (Item : in out Building; Ok : out Boolean);

   --  Let the built file's mapping go, once it is mapped again for reading.
   --
   --  @param Item The file built.
   procedure Release (Item : in out Building);

   --  Give the file up: the mapping released and the file removed.
   --
   --  @param Item The file being built.
   procedure Abandon (Item : in out Building);

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

private

   type Building is limited record
      Region : Model_Runner.Platform.Mapping.Region;
      Path   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Panel_Cache;
