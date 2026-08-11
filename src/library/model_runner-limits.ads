with Interfaces;

--  Resource limits applied to untrusted model files and requests.
--
--  Every count and size that a GGUF file can influence is checked against a
--  limit before the value is used to size a loop, an allocation or a buffer.
--  The defaults are generous enough for the supported model corpus and small
--  enough that a hostile file cannot exhaust memory or wall-clock time before
--  being rejected.
--
--  Limits are passed explicitly. There is no process-wide limit state, so a
--  test can drive the parser at a limit of a few kilobytes without affecting
--  any other test.
--
--  No compatibility mode may relax the structural checks these limits guard.
--  Raising a limit changes how large an accepted file may be; it never changes
--  whether an invalid file is rejected.
package Model_Runner.Limits is
   pragma Pure;

   subtype U64 is Interfaces.Unsigned_64;

   use type Interfaces.Unsigned_64;

   --  Limits applied while parsing and preparing a model.
   type Model_Limits is record
      --  Largest model file accepted, in bytes.
      Max_File_Bytes : U64 := 64 * 1024 * 1024 * 1024;

      --  Largest number of metadata entries in the container.
      Max_Metadata_Entries : Natural := 4096;

      --  Largest number of tensor descriptors in the container.
      Max_Tensors : Natural := 65_536;

      --  Largest single metadata string, in bytes.
      Max_String_Bytes : U64 := 16 * 1024 * 1024;

      --  Largest element count in a metadata array.
      Max_Array_Elements : Natural := 4_000_000;

      --  Largest total size of the metadata string pool, in bytes. This bounds
      --  the tokenizer vocabulary and every other string array together.
      Max_Metadata_Pool_Bytes : U64 := 256 * 1024 * 1024;

      --  Largest number of dimensions in a tensor descriptor. GGUF permits
      --  four; the supported architecture uses at most two.
      Max_Tensor_Rank : Natural := 4;

      --  Largest element count in a single tensor.
      Max_Tensor_Elements : U64 := 1024 * 1024 * 1024;

      --  Largest byte size of a single tensor.
      Max_Tensor_Bytes : U64 := 16 * 1024 * 1024 * 1024;

      --  Largest byte size of a single heap allocation.
      Max_Allocation_Bytes : U64 := 16 * 1024 * 1024 * 1024;

      --  Largest total resident allocation for model preparation, in bytes.
      --  Zero means unlimited.
      Max_Model_Bytes : U64 := 0;

      --  Largest vocabulary size accepted from a tokenizer definition.
      Max_Vocabulary : Natural := 1_000_000;

      --  Largest context length accepted from architecture metadata.
      Max_Context_Length : Natural := 1_048_576;

      --  Largest layer count accepted from architecture metadata.
      Max_Layers : Natural := 512;

      --  Largest embedding dimension accepted from architecture metadata.
      Max_Embedding : Natural := 65_536;

      --  Largest attention-head count accepted from architecture metadata.
      Max_Heads : Natural := 1024;

      --  Largest expert count accepted from architecture metadata. Every
      --  expert is three matrices, so this bounds how many tensors a single
      --  layer resolves as much as it bounds the routing.
      Max_Experts : Natural := 1024;

      --  Largest chat template accepted, in bytes.
      Max_Template_Bytes : Natural := 262_144;

      --  Most steps a single render of a chat template may take. A template
      --  is a small program from a model file, and nested loops over a
      --  conversation are how one runs away; this is what stops it. It is
      --  here rather than fixed in the engine because every other bound is,
      --  and because a caller that renders untrusted templates often may
      --  want a tighter one than a caller that renders its own.
      Max_Render_Iterations : Positive := 100_000;

      --  Whether bytes after the last tensor are accepted. Rejecting trailing
      --  data is the default because a well-formed writer never emits it and
      --  its presence usually means a truncated or concatenated file.
      Allow_Trailing_Data : Boolean := False;
   end record;

   --  Limits applied to a generation session and its requests.
   type Session_Limits is record
      --  Largest total session allocation, in bytes. Zero means unlimited.
      Max_Session_Bytes : U64 := 0;

      --  Largest context capacity a session may request.
      Max_Context : Natural := 1_048_576;

      --  Largest prefill batch, in tokens.
      Max_Batch : Natural := 4096;

      --  Largest number of worker tasks.
      Max_Workers : Natural := 256;

      --  Largest prompt accepted from a file or standard input, in bytes.
      Max_Prompt_Bytes : Natural := 16 * 1024 * 1024;

      --  Largest number of stop strings.
      Max_Stop_Strings : Natural := 16;

      --  Largest length of one stop string, in bytes.
      Max_Stop_String_Bytes : Natural := 256;

      --  Largest total stop-string storage, in bytes.
      Max_Stop_Storage_Bytes : Natural := 4096;

      --  Largest number of stop tokens.
      Max_Stop_Tokens : Natural := 64;

      --  Largest number of messages in a conversation.
      Max_Messages : Natural := 4096;

      --  Largest rendered prompt, in bytes.
      Max_Rendered_Bytes : Natural := 16 * 1024 * 1024;

      --  Largest retained generated text, in bytes.
      Max_Retained_Bytes : Natural := 16 * 1024 * 1024;
   end record;

   Default_Model_Limits   : constant Model_Limits := (others => <>);
   Default_Session_Limits : constant Session_Limits := (others => <>);

end Model_Runner.Limits;
