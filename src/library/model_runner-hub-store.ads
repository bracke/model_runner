--  What the models directory holds from the hub, and where.
--
--  A download is kept under the file's own name, which two repositories can
--  share: two quantizers of one model both call their file X-Q4_K_M.gguf,
--  and a run of the one reference after the other found the file not its
--  own and fetched it over the first's. A file name already another
--  repository's is kept under owner/repo/ instead. And a reference names a
--  repository, not a file, so it was resolved over the network on every
--  run -- a model whole on disk would not run offline. The manifest the
--  directory keeps answers both: for each file a download put there, the
--  reference it was fetched for, its repository, revision, size and
--  digest, and the name it is kept under.
--
--  A models directory with no manifest -- one filled before it was kept --
--  is read as it was: every name its own, and a reference resolved by the
--  hub.
--
--  Task safety: one task at a time; the manifest is read and rewritten
--  whole under a lock, so two runs noting at once do not lose a line.
package Model_Runner.Hub.Store is

   --  The manifest's name within the models directory.
   Manifest_Name : constant String := "hub-manifest.tsv";

   --  The names files are kept under, relative to the models directory.
   type Local_Names is array (1 .. Max_Files) of Model_Runner.Text.Bounded;

   --  The repository the manifest says a kept file came from, or "" where
   --  it says nothing of it.
   --
   --  @param Directory The models directory.
   --  @param Local The file's name within it.
   --  @return The owner/repo, or "".
   function Origin (Directory, Local : String) return String;

   --  The name a file of Repo is to be kept under: its own, unless another
   --  repository's file is kept by that name, and then owner/repo/ and it.
   --
   --  @param Directory The models directory.
   --  @param Repo The owner/repo the file belongs to.
   --  @param Name Its name within the repository.
   --  @return The name within the models directory.
   function Place (Directory, Repo, Name : String) return String;

   --  Record that Reference was fetched as these files, kept under these
   --  names: the reference's earlier record, and any other naming the same
   --  kept files, are replaced.
   --
   --  @param Directory The models directory.
   --  @param Reference The reference as the run named it.
   --  @param Repo Its owner/repo.
   --  @param Files The files, in order.
   --  @param Locals The names they are kept under.
   --  @param Count How many.
   procedure Note
     (Directory : String;
      Reference : String;
      Repo      : String;
      Files     : File_Set;
      Locals    : Local_Names;
      Count     : Natural);

   --  What the manifest records for Reference.
   --
   --  @param Directory The models directory.
   --  @param Reference The reference as a run names it.
   --  @param Repo Its owner/repo.
   --  @param Files The files, in order.
   --  @param Locals The names they are kept under.
   --  @param Count How many.
   --  @param Found True where the manifest has a whole record of it.
   procedure Find
     (Directory : String;
      Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Locals    : out Local_Names;
      Count     : out Natural;
      Found     : out Boolean);

   --  Drop every record of a kept file, as removing it does.
   --
   --  @param Directory The models directory.
   --  @param Local The file's name within it.
   procedure Forget (Directory, Local : String);

end Model_Runner.Hub.Store;
