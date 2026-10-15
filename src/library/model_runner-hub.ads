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
   --
   --  Revision is the commit the listing was read at, where the hub said:
   --  the bytes are fetched from it and not from the branch's head, so a
   --  repository updated between two runs does not resume one file's old
   --  bytes with another's new ones. Empty where the hub gave none, and the
   --  head is read then.
   type Download_File is record
      Name     : Model_Runner.Text.Bounded;
      Size     : Interfaces.Unsigned_64 := 0;
      SHA256   : String (1 .. 64) := [others => '0'];
      Has_Hash : Boolean := False;
      Revision : Model_Runner.Text.Bounded;
   end record;

   --  The files a reference resolves to. A single-file model is one; a
   --  shard set is its several, and the loader opens the set from the
   --  first. At most this many shards, which no model reaches.
   Max_Files : constant := 64;
   type File_Set is array (1 .. Max_Files) of Download_File;

   --  A repository's GGUF files as its listing gives them.
   Max_Listed : constant := 256;
   type Listing is array (1 .. Max_Listed) of Download_File;

   --  The longest file name a listing's file may have: room is left in a
   --  bounded name for the owner/repo/ a colliding file is stored under.
   Max_Name : constant := Model_Runner.Text.Max_Length - 128;

   --  Read the hub's answer about a repository -- /api/models/OWNER/REPO
   --  with its blobs -- into the GGUF model files it lists.
   --
   --  Each file is read from its own entry of the listing's siblings: its
   --  name, its size, and the SHA-256 its LFS record gives. A file kept in
   --  the repository itself and not in LFS has no such digest and is
   --  checked by its size; a digest is never taken from a neighbour's
   --  entry, which a search of the text near the name did. A vision
   --  projector (an mmproj file) is no model to run and is left out, as is
   --  a name that climbs out of the store or is longer than Max_Name. Each
   --  file carries the commit the listing was read at, the answer's sha.
   --
   --  @param Text The answer's body.
   --  @param Files The model files, in the listing's order.
   --  @param Count How many.
   --  @param Ok False where the body is not such an answer.
   --  @param Reason Why, when Ok is false.
   procedure Read_Listing
     (Text   : String;
      Files  : out Listing;
      Count  : out Natural;
      Ok     : out Boolean;
      Reason : out Model_Runner.Text.Bounded);

   --  Of a repository's files, the one or the shard set whose name carries
   --  Quant, as Resolve chooses it.
   --
   --  @param Listed The repository's model files, from Read_Listing.
   --  @param Listed_Count How many of Listed are.
   --  @param Quant The quant asked for.
   --  @param Repo The repository, for what Reason says.
   --  @param Files The file, or the shards in order.
   --  @param Count How many.
   --  @param Ok True where one file or one whole shard set matched.
   --  @param Reason Why, when Ok is false.
   procedure Choose_Quant
     (Listed       : Listing;
      Listed_Count : Natural;
      Quant        : String;
      Repo         : String;
      Files        : out File_Set;
      Count        : out Natural;
      Ok           : out Boolean;
      Reason       : out Model_Runner.Text.Bounded);

   --  Of a repository's files, the model that best fits Budget, as Pick
   --  chooses it: the largest no bigger than it, or the smallest where
   --  none fits. A shard set is weighed and taken only where all of its
   --  shards are listed.
   --
   --  @param Listed The repository's model files, from Read_Listing.
   --  @param Listed_Count How many of Listed are.
   --  @param Budget The bytes a model may be; not zero.
   --  @param Repo The repository, for what Reason says.
   --  @param Files The chosen model's file, or shards in order.
   --  @param Count How many.
   --  @param Ok True where a model was chosen.
   --  @param Reason Why none was, or that the smallest was taken.
   procedure Choose_Fit
     (Listed       : Listing;
      Listed_Count : Natural;
      Budget       : Interfaces.Unsigned_64;
      Repo         : String;
      Files        : out File_Set;
      Count        : out Natural;
      Ok           : out Boolean;
      Reason       : out Model_Runner.Text.Bounded);

   --  Where a file of a repository is fetched from: at the commit given,
   --  or the main branch where none is, each segment of its name
   --  percent-encoded, so a space, a '#' or a '?' in a name fetches that
   --  file and not another path.
   --
   --  @param Repo The owner/repo.
   --  @param Revision The commit, or empty for the main branch.
   --  @param Name The file's name within the repository.
   --  @return The URL.
   function File_URL (Repo, Revision, Name : String) return String;

   --  The proxy a request to Host_Name goes through, by the environment's
   --  convention: Setting (HTTPS_PROXY) unless Bypass (NO_PROXY) names the
   --  host -- a comma-separated list of names, each matching itself and
   --  every name ending in "." and it, or "*" for every host.
   --
   --  @param Setting The proxy's URI, or empty for none.
   --  @param Bypass The hosts that are reached directly.
   --  @param Host_Name The host a request is for.
   --  @return The proxy's URI, or empty for a direct connection.
   function Proxy_For (Setting, Bypass, Host_Name : String) return String;

   --  How long a connection may take to be made, and a read to be answered,
   --  in milliseconds: past them a download fails, and the next run
   --  resumes it, where it had waited for ever on a link that had gone.
   --  The free space a download asks for past the bytes it still needs:
   --  a ranged fetch's chunk of 64 MB is on the disk beside the whole file
   --  while the chunks are joined, and as much again is left for the file
   --  system and whatever else is writing.
   Join_Headroom : constant := 2 * 64 * 1024 * 1024;

   Connect_Timeout_Ms : constant := 30_000;
   Read_Timeout_Ms    : constant := 60_000;

   --  Whether a name is a hub reference: owner/repo:quant, a slash in the
   --  part before the colon so that a Windows drive letter or a time is not
   --  taken for one. This is a shape test only; whether the repository or
   --  the quant exists is answered by resolving it.
   --
   --  @param Named The model name as the caller gave it.
   --  @return True when Named has the shape of a hub reference.
   function Is_Reference (Named : String) return Boolean;

   --  Whether a file name the hub lists may be written under the models
   --  directory as it is: relative, in forward-slash segments none of which
   --  is "." or "..", with no backslash, colon or control character. The
   --  listing is the server's word, and a name that climbed out of the
   --  directory -- or named a drive -- would write wherever it pointed; a
   --  file so named is left out of the listing.
   --
   --  @param Name The rfilename as the hub gave it.
   --  @return True when Name stays inside the directory it is joined to.
   function Is_Safe_File_Name (Name : String) return Boolean;

   --  Whether a name is a repository without a quant -- owner/repo, a slash
   --  in it and no colon, and not a .gguf path -- for which Pick chooses
   --  the quant rather than the caller naming one.
   --
   --  @param Named The model name as the caller gave it.
   --  @return True when Named is a bare repository.
   function Is_Repo (Named : String) return Boolean;

   --  Choose the quant of owner/repo that best fits a memory budget.
   --
   --  Every GGUF quant in the repository is weighed by its size (a shard
   --  set by its whole size), and the largest that is no bigger than Budget
   --  is chosen -- the best quality that fits. Where none fits, the
   --  smallest is chosen so that something runs, with a word in Reason.
   --  A zero Budget -- the machine would not say how much memory it has --
   --  leaves Ok false, asking for a quant by name. The result is the
   --  chosen quant's files, as Resolve gives a named quant's.
   --
   --  @param Reference The owner/repo name, without a quant.
   --  @param Budget The bytes a model may be, or zero when it is not known.
   --  @param Repo The owner/repo, echoed for building the download URL.
   --  @param Files The chosen quant's file, or shards in order, with sizes.
   --  @param Count How many files it is, one for a single file.
   --  @param Ok True when a quant was chosen.
   --  @param Reason A short account -- why none was chosen, or that the one
   --    chosen is the smallest because none fit.
   procedure Pick
     (Reference : String;
      Budget    : Interfaces.Unsigned_64;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Count     : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded);

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
   --  known, and then the whole length is not checked as it arrives.
   --  HF_TOKEN, where the environment carries it, authorizes a gated
   --  repository.
   --
   --  One run fetches a file at a time: a second asking for the same file
   --  while the first is under way is told so and fetches nothing, where
   --  the two had written the same part and its chunks over each other.
   --
   --  The file arrived whole only when its bytes match the hub's SHA-256,
   --  where the hub gave one: a truncated or corrupt download is a failure,
   --  not a model, and the file it left is removed so a run does not open
   --  it or take it for done. The bytes gather in Dest_Path & ".part" and
   --  take the file's name only once they are checked, so a file at
   --  Dest_Path is one that arrived whole; the part is what is resumed.
   --
   --  Told how a download is going, so a caller can paint a progress line:
   --  the bytes fetched so far and the whole size where it is known, zero
   --  where it is not. It runs on the downloading task, one call at a time,
   --  every few megabytes. Null asks for no progress. The hub does not
   --  reach the terminal itself -- what a progress line looks like, and
   --  whether there is one, belongs to the layer that has a terminal.
   type Progress_Reporter is
     access procedure
       (Written : Interfaces.Unsigned_64;
        Total   : Interfaces.Unsigned_64);

   --  @param Repo The owner/repo the file belongs to.
   --  @param File The file to fetch: its name, size and digest.
   --  @param Dest_Path Where to write it.
   --  @param Ok True when the file arrived whole and matched its digest.
   --  @param Reason A short account when Ok is false.
   --  @param Report Told the download's progress, or null for none.
   procedure Fetch
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded;
      Report    : Progress_Reporter := null);

   --  Whether the file at Path is the one File names: its digest, kept
   --  beside it as Path & ".sha256" once a download was checked, is the
   --  hub's. A file of the right size from another repository -- the same
   --  name, other bytes -- is not taken for this one. One with no digest
   --  kept is read once and kept as known where it is the hub's; a file
   --  the hub gives no digest for is whole by its size alone.
   --
   --  @param File The file as the hub lists it.
   --  @param Path Where it is on disk.
   --  @return True where the bytes are the hub's.
   function Is_Whole (File : Download_File; Path : String) return Boolean;

end Model_Runner.Hub;
