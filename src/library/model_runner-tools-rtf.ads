--  Best-effort text from an RTF document.
--
--  RTF is text interleaved with control words (a backslash and a name), group
--  braces, and a few escapes. This reads the plain text out: control words
--  emit nothing except the few that stand for a space or a line break, the
--  `\'xx` and `\uN` escapes become their characters, and the destination
--  groups that hold no document text -- the font, colour and style tables and
--  the `\*` destinations -- are skipped.
--
--  It gathers the words, not the formatting. A malformed file yields what it
--  can rather than an error.
--
--  Task safety: bytes in, text out; no state of its own.
package Model_Runner.Tools.RTF is

   --  The text of an RTF document, from its bytes. Bounded; an input that is
   --  not RTF yields the empty string.
   --
   --  @param Raw The file's bytes.
   --  @return The document's text, or the empty string.
   function Extract_Text (Raw : String) return String;

end Model_Runner.Tools.RTF;
