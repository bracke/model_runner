with Model_Runner.GGUF.Containers;
with Model_Runner.Tokenizer;

--  A draft model for a model, found rather than named.
--
--  A draft proposes tokens for the model to check several at a pass, and it
--  pays when it is much smaller than the model and usually right: Steelman-14B
--  generates 7.6 tokens a second alone and 12.7 with Qwen2.5-Coder-0.5B
--  proposing three a round. The two must number their tokens alike, since a
--  proposal is a number; the draft may number fewer -- Qwen2.5's large models
--  pad their vocabularies to 152,064 where the small ones stop at 151,936 --
--  as long as the tokens both have are the same text.
package Model_Runner.Drafts is

   --  The most tokens a draft's text may differ from the model's in: Qwen2
   --  against Qwen2.5 differ in nineteen special tokens, and a draft with
   --  another tokenizer differs in nearly every one.
   Unlike_Most : constant := 64;

   --  Whether a draft whose tokens differ from the model's in this many of
   --  this many is one: at most Unlike_Most, and at most a hundredth of
   --  them, so that a small vocabulary is held to its every token.
   --
   --  @param Differ Tokens whose text differs.
   --  @param Length Tokens the draft has.
   --  @return True when the draft numbers its tokens as the model does.
   function Alike_Enough (Differ, Length : Natural) return Boolean
   is (Differ <= Unlike_Most and then Differ * 100 <= Length);

   --  A draft is at most this share of the model's file, so that its passes
   --  stay cheap beside the model's: Qwen3-0.6B at Q8_0 is a 7.9th of
   --  qwen3-8b at Q4_K_M, and takes it from 14.3 to 19.2 tokens a second.
   Default_Share : constant := 6;

   --  And at least this large, so that nothing but a model is taken for one.
   Default_Least : constant := 64 * 1024 * 1024;

   --  The largest file in a directory that can draft for a model.
   --
   --  A candidate is a single-file GGUF of the model's architecture, of at
   --  least Least bytes and at most a Share of the model's file, whose tokens
   --  are the model's text but for at most Unlike_Most. Asked of each file's
   --  header, so that a candidate that fails costs a read of its metadata and
   --  not a load. The model's own file is never its own draft: it is not a
   --  Share of itself.
   --
   --  @param Directory Where to look; nothing is found where it is empty
   --    or absent.
   --  @param Model_Path The model's file, whose size the share is of.
   --  @param Model The model's parsed container.
   --  @param Words The model's vocabulary.
   --  @param Share The most a draft may be of the model's size, as a divisor.
   --  @param Least The fewest bytes a draft's file may have.
   --  @return The draft's path, or an empty string when there is none.
   function Find
     (Directory  : String;
      Model_Path : String;
      Model      : Model_Runner.GGUF.Containers.Container;
      Words      : Model_Runner.Tokenizer.Vocabulary;
      Share      : Positive := Default_Share;
      Least      : Long_Long_Integer := Default_Least) return String;

end Model_Runner.Drafts;
