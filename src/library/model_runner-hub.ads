with Model_Runner.Text;

--  Resolving a model named as a Hugging Face reference to a file to fetch.
--
--  A caller who names a model this program cannot find on disk may have
--  named one on the Hugging Face hub instead, in the form owner/repo:quant
--  -- the repository that holds it and the quantization wanted. This
--  package turns that reference into the one GGUF file in the repository
--  whose name carries the quant, over the hub's read-only API, and fetches
--  it. It reaches the network and nothing else here does; the caller asks
--  the user before any of it runs.
--
--  Task safety: each call is self-contained; run from one task.
package Model_Runner.Hub is

   --  Whether a name is a hub reference: owner/repo:quant, a slash in the
   --  part before the colon so that a Windows drive letter or a time is not
   --  taken for one. This is a shape test only; whether the repository or
   --  the quant exists is answered by resolving it.
   --
   --  @param Named The model name as the caller gave it.
   --  @return True when Named has the shape of a hub reference.
   function Is_Reference (Named : String) return Boolean;

   --  Resolve owner/repo:quant to the single GGUF file that matches.
   --
   --  The repository's file list is read over the hub API and the GGUF
   --  files whose name carries the quant, ignoring case, are collected.
   --  Exactly one is the answer; none or several leave Ok false, the
   --  latter with the candidates in Reason so the caller can say to name
   --  the quant more exactly.
   --
   --  A model split into shards -- files named ...-00001-of-000NN.gguf --
   --  carries the quant in every shard's name, so all of them match. The
   --  match is then that set: File_Name is its first shard, the one the
   --  loader opens, and Shards is how many there are, for the caller to
   --  fetch the rest of by the same naming. A single-file model is a set
   --  of one. Several files that match but are not one shard set are
   --  ambiguous, and leave Ok false with them named in Reason.
   --
   --  @param Reference The owner/repo:quant name.
   --  @param Repo The owner/repo part, for building the download URL.
   --  @param File_Name The matching file, or the first shard of the set.
   --  @param Shards How many files the model is, one for a single file.
   --  @param Ok True when a single file or one shard set matched.
   --  @param Reason A short account when Ok is false, for the caller to show.
   procedure Resolve
     (Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      File_Name : out Model_Runner.Text.Bounded;
      Shards    : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded);

   --  Fetch one file of a repository to a local path, its parents made.
   --
   --  The bytes stream to the file and are never held whole in memory, so
   --  a model larger than memory is fetched all the same. HF_TOKEN, where
   --  the environment carries it, authorizes a gated repository.
   --
   --  @param Repo The owner/repo the file belongs to.
   --  @param File_Name The file within it.
   --  @param Dest_Path Where to write it.
   --  @param Ok True when the file arrived whole.
   --  @param Reason A short account when Ok is false.
   procedure Fetch
     (Repo      : String;
      File_Name : String;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded);

end Model_Runner.Hub;
