--  Text out of the ZIP-of-XML document formats.
--
--  A Word, Excel, PowerPoint, OpenDocument or EPUB file is a ZIP archive
--  whose text lives in XML parts inside it. This reads the archive's central
--  directory, inflates the parts that hold text for the format at hand, and
--  strips the XML to the words between the tags -- enough for a search over a
--  folder of documents.
--
--  What it does not do: styling, tables as tables, images, or the exact
--  reading order of a complex layout. It gathers the words, not the document.
--  A part it cannot inflate, or an archive it cannot parse, yields nothing
--  rather than an error.
--
--  Task safety: bytes in, text out; no state of its own.
package Model_Runner.Tools.OOXML is

   --  Which family a document belongs to, which decides the XML parts read.
   type Document_Kind is
     (Word,           --  .docx  -- word/document.xml
      Excel,          --  .xlsx  -- xl/sharedStrings.xml
      Powerpoint,     --  .pptx  -- ppt/slides/slide*.xml
      Open_Document,  --  .odt/.ods/.odp -- content.xml
      Epub);          --  .epub  -- the .xhtml/.html parts

   --  The kind a file name names by its extension. Found is false for a name
   --  that is none of these, and Kind is then meaningless.
   function Kind_Of
     (Name : String; Found : out Boolean) return Document_Kind;

   --  The text of such a document, from its bytes. Bounded; an archive that
   --  cannot be read yields the empty string.
   function Extract_Text (Raw : String; Kind : Document_Kind) return String;

end Model_Runner.Tools.OOXML;
