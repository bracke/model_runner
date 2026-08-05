with Model_Runner.Byte_Sources;
with Model_Runner.Cancellation;
with Model_Runner.Progress;

--  Parsing and structural validation of a GGUF container.
--
--  Every byte read here comes from an untrusted file. The parser therefore
--  states, for each field, exactly how many bytes it needs and at which
--  absolute offset, checks every count against a limit before it is used to
--  size a loop, and derives every offset and size with checked arithmetic that
--  reports overflow instead of wrapping.
--
--  What is validated, in order: magic, version, counts against limits, header
--  completeness, every metadata key and value including value tags, array
--  element types, array counts, string lengths and UTF-8 validity, duplicate
--  keys, every tensor descriptor including name, duplicate names, rank,
--  dimensions, element count, type identifier and block compatibility, the
--  data-section alignment, each tensor's absolute range against the file
--  bounds, pairwise non-overlap of tensor ranges, and the trailing-data policy.
--
--  What is not validated here: whether the model is one this crate can run.
--  That is the architecture layer's contract. A container can be perfectly
--  well formed and still be rejected later as unsupported.
--
--  Task safety: Parse is called by one task and takes exclusive use of the
--  source for its duration.
package Model_Runner.GGUF.Containers.Reader is

   --  Parse and validate a container.
   --
   --  On failure the container is left closed and holds no resources; on
   --  success it is valid and immutable. Cancellation is observed between
   --  metadata entries, between tensor descriptors and between validation
   --  passes, and is reported as Generation_Cancelled.
   --
   --  @param Item Container to fill in; closed first.
   --  @param Source Byte source positioned by absolute offset.
   --  @param Bounds Limits applied to every count and size.
   --  @param Cancel Cancellation token, or null.
   --  @param Observer Progress observer, or null.
   --  @param Status Success, or the first structural diagnostic found.
   procedure Parse
     (Item     : in out Container;
      Source   : in out Model_Runner.Byte_Sources.Source'Class;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Status   : out Model_Runner.Errors.Error_Info);

end Model_Runner.GGUF.Containers.Reader;
