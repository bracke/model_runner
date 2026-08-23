with Model_Runner.Bytes;

--  A container carrying a `t5` vocabulary and nothing else.
--
--  The point of it is one text on which the best-path road and the
--  greedy-merge road give different answers, which is the whole reason
--  unigram is a road and not a setting. The SentencePiece road merges the
--  adjacent pair whose joined piece scores highest and never reconsiders;
--  this road chooses the cut whose scores sum highest over the whole text.
--  A vocabulary where the two agree would let a reader that took the wrong
--  road pass, and every vocabulary written for the other roads is one.
--
--  It carries no merge table, no normalization table and no piece above
--  ASCII: what a published file adds to those is settled against a second
--  runtime rather than here, and what is settled here is the algorithm.
--
--  Task safety: pure.
package Unigram_Vocabulary is

   --  Build a container holding a `t5` vocabulary.
   --
   --  @param Image Container bytes; the caller frees them.
   procedure Build (Image : out Model_Runner.Bytes.Byte_Array_Access);

end Unigram_Vocabulary;
