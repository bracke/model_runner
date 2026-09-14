--  Best-effort text from a legacy Word file (.doc, the OLE2 compound
--  format).
--
--  A .doc keeps its text inside a compound-file container, as runs of either
--  single-byte (Windows-1252) or UTF-16LE characters. Parsing the container's
--  streams and the piece table to recover the text exactly is a great deal of
--  work; for a search over a folder, the words are what matter, so this reads
--  the printable runs out of the file's bytes -- both encodings -- and lets
--  the rest go.
--
--  What that means: it gets the document's words, and also some structural
--  noise (stream and style names). Reading order is approximate and layout is
--  gone. It is enough to find a .doc by what it says, which is what retrieve
--  wants; it is not a converter.
--
--  Task safety: bytes in, text out; no state of its own.
package Model_Runner.Tools.DOC is

   --  The printable text of a legacy Word file, from its bytes. Bounded; a
   --  file that is not an OLE2 container yields the empty string.
   function Extract_Text (Raw : String) return String;

end Model_Runner.Tools.DOC;
