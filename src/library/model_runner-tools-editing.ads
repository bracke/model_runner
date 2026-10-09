with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  What the tools that read and change source do with a file, deterministic
--  and shared: a text read whole only within a bound, a file's revision, an
--  edit of one exact passage that refuses a file changed since it was read,
--  a range of lines, and a search of one file or of a tree.
--
--  A model editing a 600-line body should not have to write it out again to
--  change three lines of it, nor edit a file someone changed after it read
--  it, nor read 1,200 lines to find the 80 it wants: these are the tools
--  that spare it, and the harness does the finding.
--
--  Task safety: no state; each call reads and writes the files it is given.
package Model_Runner.Tools.Editing is

   --  The largest file read whole as text. A larger one is said to be, with
   --  the ways to read part of it -- never allocated whole because a path
   --  named it.
   Text_Most : constant := 4 * 1024 * 1024;

   --  Lines a range gives at most, and hits a search.
   Range_Most  : constant := 400;
   Search_Most : constant := 100;

   --  Read a text file whole, within Text_Most.
   --
   --  @param Path The file.
   --  @param Text Its bytes, as they are.
   --  @param Status IO_Open_Failed where there is no such file,
   --    IO_Not_A_Regular_File for a directory, IO_File_Too_Large past
   --    Text_Most, IO_Read_Failed for a binary file or one that would not
   --    read -- each with the path, and the size where that was it.
   procedure Read_Text
     (Path   : String;
      Text   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info);

   --  A text's revision: sixteen hexadecimal digits that change when any of
   --  its bytes does.
   --
   --  @param Text The text.
   --  @return The revision.
   function Revision (Text : String) return String;

   --  The revision of a file as it is now, or "" where it is not a text
   --  Read_Text reads.
   --
   --  @param Path The file.
   --  @return Its revision.
   function Revision_Of (Path : String) return String;

   --  What a tool said, and how it went.
   type Said is record
      Text      : Ada.Strings.Unbounded.Unbounded_String;
      Failed    : Boolean := False;
      Changed   : Boolean := False;
      Truncated : Boolean := False;
   end record;

   --  Replace the one place a passage is in a file. Refused, and nothing
   --  written, where Expected is given and the file's revision is another,
   --  where the passage is not there, or where it is there more than once.
   --  Said on success: where, how many lines for how many, the declarations
   --  the edit falls in or names, and the new revision.
   --
   --  @param Path The file.
   --  @param Old_Text The exact text to replace.
   --  @param New_Text What replaces it.
   --  @param Expected The revision the caller read, or "".
   --  @return What happened.
   function Edit (Path, Old_Text, New_Text, Expected : String) return Said;

   --  Lines First .. Last of a file, numbered; Last of nought for to the
   --  end. At most Range_Most of them.
   --
   --  @param Path The file.
   --  @param First The first line, from one.
   --  @param Last The last line, or nought.
   --  @return The lines.
   function Read_Range (Path : String; First, Last : Natural) return Said;

   --  The lines of a file that hold a text, numbered; at most Search_Most.
   --
   --  @param Path The file.
   --  @param Pattern The text, as it is written.
   --  @return The lines.
   function Search_File (Path, Pattern : String) return Said;

   --  The lines of every text file under a folder that hold a text, as
   --  path:line; at most Search_Most. Hidden folders and those a build
   --  writes -- obj, bin, alire, node_modules, target, __pycache__ -- are
   --  passed over, as are binary files and those past Text_Most.
   --
   --  @param Folder The folder; "." for the whole tree.
   --  @param Pattern The text, as it is written.
   --  @return The hits.
   function Search_Code (Folder, Pattern : String) return Said;

   --  The declarations lines First .. Last of a text fall in or name: the
   --  nearest one opening at or above First, and each one opening within.
   --  A declaration is a line that opens with procedure, function, package,
   --  type, subtype, task, protected, entry, def, class, fn or func.
   --
   --  @param Text The text.
   --  @param First The first line.
   --  @param Last The last line.
   --  @return Their names, comma-separated; "" for none.
   function Declarations_In (Text : String; First, Last : Positive) return String;

end Model_Runner.Tools.Editing;
