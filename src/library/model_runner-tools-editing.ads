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

   --  Where a path is on disk: under Base where it is relative and a Base
   --  is given; as it is otherwise, which the process's directory then
   --  resolves.
   --
   --  @param Base The directory; "" for the process's own.
   --  @param Path The path, as a tool was given it.
   --  @return The path to open.
   function On_Disk (Base, Path : String) return String;

   --  Read a text file whole, within Text_Most.
   --
   --  @param Path The file.
   --  @param Text Its bytes, as they are.
   --  @param Status IO_Open_Failed where there is no such file,
   --    IO_Not_A_Regular_File for a directory, IO_File_Too_Large past
   --    Text_Most, IO_Read_Failed for a binary file or one that would not
   --    read -- each with the path, and the size where that was it.
   --  @param Base The directory a relative Path is under; "" for the
   --    process's own. Every function here that takes a path takes this,
   --    and says the path as it was given.
   procedure Read_Text
     (Path   : String;
      Text   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info;
      Base   : String := "");

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
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   --  @return Its revision.
   function Revision_Of (Path : String; Base : String := "") return String;

   --  What a tool said, and how it went: for a change, also the file's
   --  revision before and after it, and whether it made the file -- as
   --  values, beside the words the model reads.
   type Said is record
      Text      : Ada.Strings.Unbounded.Unbounded_String;
      Failed    : Boolean := False;
      Changed   : Boolean := False;
      Truncated : Boolean := False;
      --  For a search: whether some of what it was to look through could
      --  not be read, so no match is not no match.
      Incomplete : Boolean := False;
      Before_Revision : Ada.Strings.Unbounded.Unbounded_String;
      After_Revision  : Ada.Strings.Unbounded.Unbounded_String;
      Created   : Boolean := False;
   end record;

   --  Put a file's whole new contents in place: written beside it, made
   --  durable, its permission bits kept, and renamed over it in one step,
   --  so a crash, a full disk or an interrupt leaves it as it was or as it
   --  is now and never cut short; the folder made where it is not there.
   --  A file that holds the contents already is left as it is.
   --
   --  @param Path The file, as a tool was given it.
   --  @param Content Its new contents, as bytes.
   --  @param Result Changed, Created, the revisions before and after --
   --    before "" for a file made -- or Failed, with what failed and why.
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   procedure Replace
     (Path    : String;
      Content : String;
      Result  : out Said;
      Base    : String := "");

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
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   --  @return What happened.
   function Edit (Path, Old_Text, New_Text, Expected : String; Base : String := "") return Said;

   --  Lines First .. Last of a file, numbered; Last of nought for to the
   --  end. At most Range_Most of them.
   --
   --  @param Path The file.
   --  @param First The first line, from one.
   --  @param Last The last line, or nought.
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   --  @return The lines.
   function Read_Range (Path : String; First, Last : Natural; Base : String := "") return Said;

   --  The lines of a file that hold a text, numbered; at most Search_Most.
   --
   --  @param Path The file.
   --  @param Pattern The text, as it is written.
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   --  @return The lines.
   function Search_File (Path, Pattern : String; Base : String := "") return Said;

   --  The lines of every text file under a folder that hold a text, as
   --  path:line; at most Search_Most. Hidden folders and those a build
   --  writes -- obj, bin, alire, node_modules, target, __pycache__ -- are
   --  passed over, as are binary files and those past Text_Most.
   --
   --  @param Folder The folder; "." for the whole tree.
   --  @param Pattern The text, as it is written.
   --  @param Base The directory a relative path is under; "" for the
   --    process's own.
   --  @return The hits.
   function Search_Code (Folder, Pattern : String; Base : String := "") return Said;

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
