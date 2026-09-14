--  Small text tidying shared by the document extractors.
--
--  Task safety: pure text in, text out; no state of its own.
package Model_Runner.Tools.Text_Util is

   --  Every run of blanks -- spaces, tabs, carriage returns and newlines --
   --  becomes a single space, and the leading and trailing blanks go. This is
   --  what turns the ragged output of stripping tags out of a document into
   --  passages a reader (and a ranker) can use.
   function Collapse_Blanks (S : String) return String;

end Model_Runner.Tools.Text_Util;
