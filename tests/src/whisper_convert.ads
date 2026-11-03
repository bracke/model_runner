with Model_Runner.GGUF;

--  OpenAI's Whisper checkpoint, as Hugging Face publishes it, written as
--  the GGUF file Model_Runner.Whisper reads (profile 1, docs/plan-speech.md).
--
--  The directory it reads holds what the hub's openai/whisper-* repositories
--  hold: config.json (the shapes), generation_config.json (the languages
--  and the tokens suppressed), vocab.json, added_tokens.json and merges.txt
--  (the byte-pair vocabulary), and model.safetensors (the weights, binary32
--  or binary16). Every tensor the profile names is looked for, its shape
--  held to what config.json says, and its values copied -- as binary32, or
--  the matrices as binary16 or Q8_0 where asked; norms, biases, the convolutions
--  and the position tables stay binary32 either way. A tensor missing, of
--  another shape, or the vocabulary not covering every identifier, and
--  nothing is written. The weights the decoder's output shares with its
--  token table (proj_out) are not copied: the profile says they are tied.
--
--  The file is written in a fixed order -- metadata, then tensors as the
--  profile lists them -- so the same checkpoint makes the same bytes. It is
--  opened again once written and read as a container, and a manifest is
--  written beside it: the profile, this tool, and the SHA-256 of the
--  checkpoint's weights and of the file made.
package Whisper_Convert is

   --  Convert a checkpoint.
   --
   --  @param From The checkpoint's directory.
   --  @param Into The GGUF file to write; replaced.
   --  @param Matrices The format the matrices are written in: F32, F16, or
   --    Q8_0, a byte a weight and a binary16 scale every thirty-two, encoded
   --    as ggml encodes it.
   --  @return 0 for a file written, 1 for anything refused, said on
   --    standard output.
   function Run (From, Into : String; Matrices : Model_Runner.GGUF.Tensor_Type) return Natural;

end Whisper_Convert;
