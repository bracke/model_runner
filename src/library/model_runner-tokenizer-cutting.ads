--  Where the byte-pair road cuts a text before anything is merged.
--
--  A byte-pair vocabulary names, in `tokenizer.ggml.pre`, the rule that cuts
--  text into pieces before the merge table sees any of them. The other
--  runtime writes each rule as a list of regular expressions and applies
--  them in turn: the first cuts the whole text, and each after it cuts every
--  piece the ones before left, both what an expression matched and what it
--  left between its matches, so a boundary once drawn is never taken back.
--  This package is that machinery with the expressions written out by hand:
--  each pass is a scanner over code points that finds what its expression
--  would have, alternatives tried in the expression's order and the first
--  that matches taken, with the backtracking each expression needs worked
--  out once here rather than found by an engine at run time.
--
--  What a rule is here is therefore a list of passes, and what a name asks
--  for is one of those lists. The lists are transcribed from the other
--  runtime's, expression by expression, and the test that holds this to them
--  is a reader in the suite that interprets the expressions themselves.
--
--  Task safety: pure; every call works on its own arguments.
private package Model_Runner.Tokenizer.Cutting is

   --  The last byte of each piece, in order. A text of N bytes cuts into at
   --  most N pieces, and the array is sized by the text rather than grown.
   type Piece_Ends is array (Positive range <>) of Natural;
   type Piece_Ends_Access is access Piece_Ends;

   --  Cut Text into the pieces Rule names.
   --
   --  @param Text Valid UTF-8; the caller has checked it.
   --  @param Rule Which rule cuts it.
   --  @param Ends Allocated here, the caller frees it with Free; the last
   --    byte of piece K is Ends (K), and piece 1 begins at Text'First.
   --  @param Count How many pieces there are.
   procedure Cut
     (Text  : String;
      Rule  : Cut_Rule;
      Ends  : out Piece_Ends_Access;
      Count : out Natural);

   --  Give back what Cut allocated.
   --
   --  @param Item The ends to free; null afterwards.
   procedure Free (Item : in out Piece_Ends_Access);

   --  Whether a code point is Unicode punctuation, category P.
   --
   --  Declared here because the WordPiece road asks the same question and
   --  the table answering it is one table.
   --
   --  @param Code_Point The code point.
   --  @return True for every code point Unicode files under P.
   function Is_Punctuation (Code_Point : Natural) return Boolean;

end Model_Runner.Tokenizer.Cutting;
