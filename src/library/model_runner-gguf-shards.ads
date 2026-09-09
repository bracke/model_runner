with System;

with Model_Runner.Byte_Sources;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Limits;
with Model_Runner.Progress;

--  A model's bytes, in one file or in several.
--
--  A GGUF file above a few tens of gigabytes is usually not one file. The
--  converter cuts it into shards named `<stem>-00001-of-00003.gguf` and
--  writes three keys into each: `split.no`, which shard this is counting
--  from zero, `split.count`, how many there are, and
--  `split.tensors.count`, how many tensors they hold between them. Only the
--  first carries the model's metadata; the rest carry those three keys and
--  their share of the tensors.
--
--  Read as one file, the first shard is a well-formed container that holds a
--  third of a model, and what it produces is a refusal naming a tensor that
--  is simply in another file. This is the type that stops that happening.
--
--  It is a byte source, so nothing below it learns there was more than one
--  file: the parser is handed the first shard and then the rest, rebases
--  each shard's tensor offsets by the bytes before it, and every layer under
--  the parser sees one span of bytes with tensors at absolute offsets in it.
--
--  ONE SHARD IS THE COMMON CASE AND COSTS NOTHING. With a single part every
--  operation delegates to that part, including the mapping and its base
--  address, so a model in one file is read exactly as it was before this
--  existed.
--
--  Task safety: as the file source it is built from -- one task owns it.
package Model_Runner.GGUF.Shards is

   --  How many files one model may be split across.
   --
   --  The format's own bound is what fits in the sixteen bits `split.count`
   --  is written as. This is smaller on purpose: it is a count of open file
   --  descriptors and mapped regions, every one of them held for the life of
   --  the model, and no published model is near it. A model claiming more is
   --  refused by name rather than opening files until the host says no.
   Max_Shards : constant := 64;

   type Shard_Set is limited new Model_Runner.Byte_Sources.Source with private;

   --  Open the file a caller named, and only that file.
   --
   --  The set is then readable as a source of one part, which is what the
   --  first parse needs: `split.count` cannot be read before the container
   --  it is written in has been parsed.
   --
   --  @param Item Set to fill in; closed first.
   --  @param Path File to open.
   --  @param Policy Whether to map the file.
   --  @param Max_Bytes Largest file accepted, or zero for no bound.
   --  @param Status Success, or why the file could not be opened.
   procedure Open
     (Item      : in out Shard_Set;
      Path      : String;
      Policy    : Model_Runner.Byte_Sources.Files.Mapping_Policy :=
        Model_Runner.Byte_Sources.Files.Mapping_Automatic;
      Max_Bytes : Model_Runner.Bytes.Byte_Count := 0;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Open a model's files and parse them, however many there are.
   --
   --  This is the whole of what a caller with a path needs, and the reason
   --  it exists is that the sequence is not obvious and is wrong in four
   --  ways if it is written again from memory: the first file is parsed
   --  alone to learn how many there are, the rest are opened by the
   --  convention, and the set is parsed again -- with the FIRST SHARD as
   --  the source and the others beside it, because a parse validates every
   --  offset against the size of what it was handed.
   --
   --  On success the set is the model's bytes and the container is the
   --  model's shape, and neither says which file anything came out of.
   --
   --  @param Item Set to fill in; closed first.
   --  @param Held Container to fill in.
   --  @param Path Path of the model, or of its first shard.
   --  @param Policy Whether to map the files.
   --  @param Bounds Limits applied to every count and size.
   --  @param Cancel Cancellation token, or null.
   --  @param Observer Progress observer, or null.
   --  @param Status Success, or the first refusal.
   procedure Open_Model
     (Item     : in out Shard_Set;
      Held     : in out Model_Runner.GGUF.Containers.Container;
      Path     : String;
      Policy   : Model_Runner.Byte_Sources.Files.Mapping_Policy :=
        Model_Runner.Byte_Sources.Files.Mapping_Automatic;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Open the other shards of a model whose first shard is already open.
   --
   --  Their names are derived from the first's, which is the only way the
   --  format offers: the count is in the file and the names are the
   --  convention. A first shard whose name does not end in the convention's
   --  suffix is refused rather than guessed at, because a set built from a
   --  guess would read whatever happened to be beside it.
   --
   --  @param Item Set holding the first shard.
   --  @param Count How many shards the first says there are.
   --  @param Status Success, or which shard could not be opened.
   procedure Open_Rest
     (Item   : in out Shard_Set;
      Count  : Positive;
      Status : out Model_Runner.Errors.Error_Info);

   --  Close every file and release every mapping. Idempotent.
   --
   --  @param Item Set to close.
   procedure Close (Item : in out Shard_Set);

   --  How many files the set holds, or zero when it is closed.
   --
   --  @param Item Set to inspect.
   --  @return Number of parts.
   function Parts (Item : Shard_Set) return Natural;

   --  The first shard, on its own.
   --
   --  The parser is given this rather than the set, because a parse
   --  validates every offset against the size of what it was handed: given
   --  the set, the first shard's tensors would end two files early and the
   --  rest of the set would be read as data following them. The set is what
   --  goes to the model afterwards; the parse is of the files.
   --
   --  @param Item Set to read.
   --  @return Reference to the first part, or null when closed.
   function First
     (Item : in out Shard_Set)
      return Model_Runner.Byte_Sources.Source_Reference;

   --  The shards after the first, in order, as the parser wants them.
   --
   --  Empty for a model in one file, which is what makes the parser's
   --  further-shard parameter default to nothing.
   --
   --  @param Item Set to read.
   --  @return References to parts two and up.
   function Rest
     (Item : in out Shard_Set) return Model_Runner.Byte_Sources.Source_Array;

   --  The path of a shard of a set named by its first.
   --
   --  Public because a diagnostic wants to say which file it looked for and
   --  did not find, and because a test asserts the convention rather than
   --  trusting it.
   --
   --  @param First Path of the first shard.
   --  @param Index Which shard, counting from one.
   --  @param Count How many there are.
   --  @return The derived path, or an empty string when First does not end
   --    in the convention's suffix.
   function Shard_Path
     (First : String; Index : Positive; Count : Positive) return String;

   --  Whether a path ends in the convention's suffix at all.
   --
   --  @param Path Path to test.
   --  @return True when the name ends `-NNNNN-of-NNNNN.gguf`.
   function Is_Shard_Name (Path : String) return Boolean;

   overriding function Size
     (Self : Shard_Set) return Model_Runner.Bytes.Byte_Count;

   overriding procedure Read
     (Self   : in out Shard_Set;
      Offset : Model_Runner.Bytes.Byte_Count;
      Target : out Model_Runner.Bytes.Byte_Array;
      Status : out Model_Runner.Errors.Error_Info);

   overriding function Is_Mapped (Self : Shard_Set) return Boolean;

   overriding function Base (Self : Shard_Set) return System.Address;

   overriding function Name (Self : Shard_Set) return String;

   overriding function Changed (Self : Shard_Set) return Boolean;

private

   type Part_Access is access Model_Runner.Byte_Sources.Files.File_Source;

   type Part_Array is array (1 .. Max_Shards) of Part_Access;

   --  Where each part begins in the joined span, and how long it is. Held
   --  rather than recomputed so that a read costs one walk of a short array
   --  and no calls into the parts.
   type Span is record
      Start  : Model_Runner.Bytes.Byte_Count := 0;
      Length : Model_Runner.Bytes.Byte_Count := 0;
   end record;

   type Span_Array is array (1 .. Max_Shards) of Span;

   type Shard_Set is limited new Model_Runner.Byte_Sources.Source with record
      Held   : Natural := 0;
      Files  : Part_Array := [others => null];
      Spans  : Span_Array := [others => (0, 0)];
      Total  : Model_Runner.Bytes.Byte_Count := 0;
      Policy : Model_Runner.Byte_Sources.Files.Mapping_Policy :=
        Model_Runner.Byte_Sources.Files.Mapping_Automatic;
      Bound  : Model_Runner.Bytes.Byte_Count := 0;
   end record;

end Model_Runner.GGUF.Shards;
