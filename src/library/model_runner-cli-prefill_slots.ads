--  The prefill cache's files for one model and its settings. There was one,
--  and a run asking about another document wrote over the one before it,
--  so two documents asked about in turn were each read whole every time.
--  Each file now belongs to what its run was asked -- the system text and
--  the prompt as given -- and keeps that beside it, so a run reads the file
--  whose asking begins most as its own does. The generation still keeps
--  only the tokens the two share: the asking chooses a file, it vouches
--  for nothing.
package Model_Runner.CLI.Prefill_Slots is

   --  What a run was asked, as one text for comparing: the system text,
   --  where there is one, and then the prompt.
   --
   --  @param System The system text, or empty.
   --  @param Has_System Whether there is one, an empty one included.
   --  @param Prompt The prompt as given.
   --  @return The asking.
   function Asking
     (System : String; Has_System : Boolean; Prompt : String) return String;

   --  A file's contents up to Most bytes, or empty where it cannot be
   --  read.
   --
   --  @param Path The file.
   --  @param Most Bytes to read at most.
   --  @return The contents.
   function Contents (Path : String; Most : Natural) return String;

   --  The file a run asked Asked keeps its cache in, beside the others of
   --  Base -- the path the model and its settings name.
   --
   --  @param Base The cache file the model and settings name.
   --  @param Asked What the run was asked.
   --  @return The path.
   function Slot_Path (Base, Asked : String) return String;

   --  The kept file of Base whose asking begins most as Asked does, or
   --  empty where none shares enough to be worth reading: the whole of a
   --  short asking, or Least bytes of a longer one. A few shared bytes
   --  are a few tokens, and adopting a file costs more than reading them.
   --
   --  @param Base The cache file the model and settings name.
   --  @param Asked What the run was asked.
   --  @param Least Shared bytes that make a file worth reading.
   --  @return The path, or empty.
   function Nearest
     (Base, Asked : String; Least : Positive := 256) return String;

   --  Keep beside the cache file just written what its run was asked.
   --
   --  @param Path The cache file.
   --  @param Asked What its run was asked.
   procedure Record_Asked (Path, Asked : String);

   --  Whether the file's run was asked a beginning of Asked: what it holds
   --  is then all in the file a run asked Asked writes.
   --
   --  @param Path The cache file.
   --  @param Asked What the later run was asked.
   --  @return Whether it is covered.
   function Covered (Path, Asked : String) return Boolean;

   --  Delete a cache file and what its run was asked.
   --
   --  @param Path The cache file.
   procedure Forget (Path : String);

   --  Delete every asking whose cache file is gone: the cache is kept to
   --  its bound by deleting its files, which knows nothing of these.
   --
   --  @param Folder The cache directory.
   procedure Drop_Orphans (Folder : String);

end Model_Runner.CLI.Prefill_Slots;
