--  The two code point maps the other runtime's WordPiece road folds a text
--  with: each code point's simple lower case, and the first code point of
--  its canonical decomposition, which is what that road reads for "take the
--  accents off" -- a one-for-one map, so a Hangul syllable becomes its first
--  letter alone and a full-width colon stays what it is, where a
--  compatibility decomposition took it to the ASCII one.
--
--  Generated from llama.cpp's src/unicode-data.cpp (unicode_map_lowercase,
--  unicode_ranges_nfd), which that project writes from Unicode's own data
--  with scripts/gen-unicode-data.py. Not edited by hand.
--
--  Task safety: safe; constant tables.
package Model_Runner.Tokenizer.Folding is

   --  A code point's simple lower case, or itself where it has none.
   --
   --  @param Code_Point The code point.
   --  @return Its lower case.
   function Lower (Code_Point : Natural) return Natural;

   --  The first code point of a code point's canonical decomposition, or
   --  itself where it does not decompose.
   --
   --  @param Code_Point The code point.
   --  @return The first of its decomposition.
   function First_Of_Decomposition (Code_Point : Natural) return Natural;

end Model_Runner.Tokenizer.Folding;
