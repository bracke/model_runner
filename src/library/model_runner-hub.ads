with Interfaces;

with Model_Runner.Text;

--  Resolving a model named as a Hugging Face reference to a file to fetch.
--
--  A caller who names a model this program cannot find on disk may have
--  named one on the Hugging Face hub instead, in the form owner/repo:quant
--  -- the repository that holds it and the quantization wanted. This
--  package turns that reference into the GGUF file (or shard set) in the
--  repository whose name carries the quant, over the hub's read-only API,
--  and fetches it, a download that resumes where an interrupted one left
--  off. It reaches the network and nothing else here does; the caller asks
--  the user before any of it runs.
--
--  Task safety: each call is self-contained; run from one task.
package Model_Runner.Hub is

   --  A file to fetch: its name within the repository, its size so a
   --  download can tell a whole file from a part left by an interruption,
   --  and the SHA-256 the hub records for it so a whole file can be told
   --  from a corrupt one. Has_Hash is false where the hub gave no digest,
   --  and then the size is all there is to check the file against.
   type Download_File is record
      Name     : Model_Runner.Text.Bounded;
      Size     : Interfaces.Unsigned_64 := 0;
      SHA256   : String (1 .. 64) := [others => '0'];
      Has_Hash : Boolean := False;
   end record;

   --  The files a reference resolves to. A single-file model is one; a
   --  shard set is its several, and the loader opens the set from the
   --  first. At most this many shards, which no model reaches.
   Max_Files : constant := 64;
   type File_Set is array (1 .. Max_Files) of Download_File;

   --  Whether a name is a hub reference: owner/repo:quant, a slash in the
   --  part before the colon so that a Windows drive letter or a time is not
   --  taken for one. This is a shape test only; whether the repository or
   --  the quant exists is answered by resolving it.
   --
   --  @param Named The model name as the caller gave it.
   --  @return True when Named has the shape of a hub reference.
   function Is_Reference (Named : String) return Boolean;

   --  Resolve owner/repo:quant to the GGUF file or shard set that matches.
   --
   --  The repository's file list, with sizes, is read over the hub API and
   --  the GGUF files whose name carries the quant are collected. One file,
   --  or one shard set whose shards all carry the quant, is the answer;
   --  none or several unrelated files leave Ok false, the latter with the
   --  candidates in Reason.
   --
   --  @param Reference The owner/repo:quant name.
   --  @param Repo The owner/repo part, for building the download URL.
   --  @param Files The file, or the shards in order, each with its size.
   --  @param Count How many files the model is, one for a single file.
   --  @param Ok True when a single file or one shard set matched.
   --  @param Reason A short account when Ok is false, for the caller to show.
   procedure Resolve
     (Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Count     : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded);

   --  Fetch one file of a repository to a local path, its parents made.
   --
   --  The bytes stream to the file and are never held whole in memory, so
   --  a model larger than memory is fetched all the same. A download that
   --  stops part way -- a dropped connection, a closed laptop, a Ctrl-C --
   --  leaves the part on disk, and a later Fetch of the same file resumes
   --  from there rather than starting over, which is what makes a
   --  multi-gigabyte model worth trying on a shaky link. Size is the file's
   --  whole size, so a part can be told from a whole; zero where it is not
   --  known, and then the download is not resumed. HF_TOKEN, where the
   --  environment carries it, authorizes a gated repository.
   --
   --  The file arrived whole only when its bytes match the hub's SHA-256,
   --  where the hub gave one: a truncated or corrupt download is a failure,
   --  not a model, and the file it left is removed so a run does not open
   --  it or take it for done.
   --
   --  @param Repo The owner/repo the file belongs to.
   --  @param File The file to fetch: its name, size and digest.
   --  @param Dest_Path Where to write it.
   --  @param Ok True when the file arrived whole and matched its digest.
   --  @param Reason A short account when Ok is false.
   procedure Fetch
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded);

end Model_Runner.Hub;
