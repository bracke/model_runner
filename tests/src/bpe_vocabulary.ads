with Model_Runner.Bytes;

--  A container carrying a byte-pair vocabulary and nothing else.
--
--  The suite had no such fixture. Every tokenizer test built a `llama`
--  vocabulary, so the whole byte-pair half of Model_Runner.Tokenizer -- the
--  merge table, the byte-to-character mapping and all six cutting rules --
--  ran nowhere in the suite, while the support matrix marked those rows
--  implemented under a definition that requires coverage.
--
--  The vocabulary here is the smallest one on which the six rules give six
--  different answers -- no one text tells them all apart, so the cases are
--  read together: a run of digits separates three groups, a tab before a
--  word separates two of those, and an apostrophe, a full stop and a grave
--  accent separate the two that cut punctuation out of the text first. It carries pieces in the mapped alphabet those
--  vocabularies use, where a space is U+0120 and a tab U+0109, and a merge
--  table whose ranks are deliberately not the order the pieces appear in, so
--  that a reader merging by position rather than by rank is caught.
--
--  Task safety: pure.
package BPE_Vocabulary is

   --  Build a container holding a `gpt2` vocabulary.
   --
   --  @param Pre Value for tokenizer.ggml.pre; the empty string omits the key.
   --  @param Image Container bytes; the caller frees them.
   procedure Build
     (Pre   : String;
      Image : out Model_Runner.Bytes.Byte_Array_Access);

end BPE_Vocabulary;
