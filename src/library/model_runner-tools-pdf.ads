--  Best-effort text out of a PDF's bytes.
--
--  A PDF keeps its shown text in content streams, most often compressed with
--  FlateDecode. This finds those streams, inflates the compressed ones, and
--  reads back the strings their text operators show -- the parenthesised and
--  hex strings inside a text block. It is enough for a PDF written with the
--  standard fonts, which is most English prose: the bytes of such a string
--  are the text.
--
--  What it does not do: fonts that map bytes through a CMap (CID and Type0
--  fonts), encrypted PDFs, and cross-reference or object streams. Those yield
--  little or nothing rather than an error, which is what the retrieve tool
--  wants -- a PDF it cannot read simply adds no passages.
--
--  Task safety: pure text in, text out; no state of its own.
package Model_Runner.Tools.PDF is

   --  The text of a PDF, as far as its content streams give it up. Raw is the
   --  file's bytes. The result is bounded; an unreadable or textless PDF
   --  yields the empty string.
   function Extract_Text (Raw : String) return String;

end Model_Runner.Tools.PDF;
