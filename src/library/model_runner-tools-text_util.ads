--  Small text tidying shared by the document extractors.
--
--  Task safety: pure text in, text out; no state of its own.
package Model_Runner.Tools.Text_Util is

   --  Every run of blanks -- spaces, tabs, carriage returns and newlines --
   --  becomes a single space, and the leading and trailing blanks go. This is
   --  what turns the ragged output of stripping tags out of a document into
   --  passages a reader (and a ranker) can use.
   function Collapse_Blanks (S : String) return String;

   --  The text between the tags of an HTML or XML document: each tag becomes
   --  a space so neighbouring words do not run together, the common named and
   --  numeric entities become their characters, and the blanks are collapsed.
   --  Bounded, so a very large file cannot fill memory.
   function Strip_Tags (S : String) return String;

   --  The text made valid UTF-8: every byte that is not part of a well-formed
   --  sequence becomes a space. Text pulled from a PDF or a legacy Word file
   --  is Latin-1 or cut mid-character, which a UTF-8 reader -- the embedding
   --  tokenizer, or the model the passage is handed back to -- refuses; this
   --  keeps the ASCII words and drops only the bytes that would break it.
   function To_Valid_Utf8 (S : String) return String;

end Model_Runner.Tools.Text_Util;
