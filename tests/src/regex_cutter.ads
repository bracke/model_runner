--  A cutter that interprets the expressions themselves.
--
--  The engine's Tokenizer.Cutting carries every pre-tokenizer rule as a
--  scanner written out by hand from the other runtime's regular expressions.
--  What checks a hand transcription is a reader that does not transcribe:
--  this one takes the expressions as text, parses them, and matches them by
--  backtracking, one expression after another over the pieces the ones
--  before it left, which is how the other runtime applies them. It is slow
--  and general where the engine is fast and particular, and a mistake in
--  one is unlikely to be the same mistake in the other.
--
--  The subset understood is what those expressions use: literals and
--  escapes, character classes with ranges and the Unicode categories the
--  expressions name, groups, alternation, the greedy quantifiers, lookahead
--  in both senses, and the end anchor. Anything else is a parse failure
--  reported as no pieces at all, which is what a test would notice.
--
--  Task safety: pure.
package Regex_Cutter is

   type Expression is access constant String;
   type Expression_List is array (Positive range <>) of Expression;

   type Ends_Array is array (Positive range <>) of Natural;

   --  Cut Text by the expressions, each applied in turn to every piece the
   --  ones before it left.
   --
   --  @param Text Valid UTF-8.
   --  @param Expressions The expressions, in order.
   --  @param Ends The last byte of each piece, sized by the caller to
   --    Text'Length at least.
   --  @param Count Pieces made; zero for empty text or for an expression
   --    this cannot read.
   procedure Cut
     (Text        : String;
      Expressions : Expression_List;
      Ends        : out Ends_Array;
      Count       : out Natural);

end Regex_Cutter;
