--  The engine's tokenizer against llama.cpp's, on real files.
--
--  The suite's tokenizer tests cross the engine against a reference written
--  here, over fixture vocabularies -- and the reference once took its
--  character classes from the same tables the engine did, so a Unicode 4.0
--  letter class passed both for as long as the two agreed with each other.
--  This holds the engine to llama-tokenize instead, a program it shares
--  nothing with, over every model file it is given and a corpus of the
--  texts tokenizers disagree on: scripts, digits, whitespace runs, code,
--  emoji, special tokens written in text.
--
--  A tool, not a step of the gate: it needs a built llama.cpp, which a
--  checkout does not have.
--
--  Task safety: not task-safe; one run at a time.
package Tokenizer_Cross is

   --  What a run found.
   type Report is record
      Models   : Natural := 0;
      Cases    : Natural := 0;
      Agreed   : Natural := 0;
      Differed : Natural := 0;
      Failed   : Natural := 0;
   end record;

   --  Tokenize every case of the corpus with every model, both ways.
   --
   --  @param Llama Path of llama-tokenize.
   --  @param Models Paths of the model files, one a line, in a list file.
   --  @param Corpus The cases, separated by a line holding only U+241E.
   --  @param Scratch A directory for each case's text, as llama-tokenize
   --    reads a file.
   --  @param Result What agreed and what did not; each disagreement is
   --    printed as it is found.
   procedure Run
     (Llama   : String;
      Models  : String;
      Corpus  : String;
      Scratch : String;
      Result  : out Report);

end Tokenizer_Cross;
