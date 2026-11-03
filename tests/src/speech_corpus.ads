--  The speech corpus heard by a Whisper model and scored: each recording's
--  transcript against what is said in it, by word error rate and character
--  error rate, the language heard against the one spoken, and how long it
--  took; then each language's rates over all its recordings, and a silence's
--  words, of which there should be none (docs/plan-speech.md).
--
--  The rates are the usual ones: the fewest words (characters) put in, taken
--  out or changed to make the transcript what is said, over the words
--  (characters) said. Both texts are compared in lower case, punctuation
--  taken away and spaces run together, so "Americans," is "americans".
package Speech_Corpus is

   --  Hear the corpus.
   --
   --  @param Model The Whisper GGUF file.
   --  @param Corpus The manifest, tests/fixtures/speech/corpus.txt unless
   --    named; recordings are looked for beside it.
   --  @param Threads Workers, or 0 for the machine's default.
   --  @return 0 when every recording was heard.
   function Run (Model, Corpus : String; Threads : Natural) return Natural;

end Speech_Corpus;
