with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  The file operations the project state is written with.
--
--  Private to the framework: what reaches the disk goes through here, and
--  what goes through here is only what the state and its templates need --
--  a whole file read, a whole file written, and a file replaced so that a
--  reader sees the old contents or the new and never part of either.
private package Model_Runner.Framework.Files is

   --  What a half-written file is called beside the one it will replace.
   Partial_Suffix : constant String := ".partial";

   --  Whether a text ends with a suffix.
   --
   --  @param Text The text.
   --  @param Suffix The suffix.
   --  @return True when it does.
   function Ends_With (Text, Suffix : String) return Boolean
   is (Text'Length >= Suffix'Length
       and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   --  Report a write that failed.
   --
   --  @param Path What was being written.
   --  @param Status Framework_Transaction_Failed naming it.
   procedure Write_Failed
     (Path   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read a whole file.
   --
   --  @param Path The file.
   --  @param Text Its bytes.
   --  @param Status IO_File_Too_Large past the record limit, IO_Read_Failed
   --    when it cannot be read.
   procedure Read_Text
     (Path   : String;
      Text   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Write a whole file, replacing what was there.
   --
   --  @param Path The file.
   --  @param Text Its bytes.
   --  @param Status Framework_Transaction_Failed when it cannot be written.
   procedure Write_Text
     (Path   : String;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Write a file so that it is either what it was or what it is now:
   --  written beside itself and renamed over.
   --
   --  @param Path The file.
   --  @param Text Its bytes.
   --  @param Status Framework_Transaction_Failed when it cannot be written.
   procedure Write_Whole
     (Path   : String;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Remove a file when it is there.
   --
   --  @param Path The file.
   --  @return False when it is there and could not be removed.
   function Delete_If_Present (Path : String) return Boolean;

   --  Remove a directory and everything in it without ever following a
   --  link: a link is removed as a link, wherever it points, and only a
   --  directory that is one is gone into. Ada.Directories.Delete_Tree
   --  follows a link to a directory and empties what it points at -- a
   --  workspace checked out with a link to somewhere else would take that
   --  somewhere with it.
   --
   --  @param Path The directory.
   procedure Remove_Tree (Path : String);

   --  Remove a file when it is there and can be; one that stays is derived
   --  and is found wanting when it is next read.
   --
   --  @param Path The file.
   procedure Discard (Path : String);

   --  Make a directory and its parents.
   --
   --  @param Path The directory.
   --  @return True when it is a directory afterwards.
   function Make_Directory (Path : String) return Boolean;

   --  The ordinary files in a directory, all of them: a listing that fails
   --  part way is a failure, never the part it had.
   --
   --  @param Directory The directory.
   --  @param Result Their simple names, sorted; none when it is not there.
   --  @param Status IO_Read_Failed naming the directory, with what was
   --    raised, where it could not be listed whole.
   procedure Files_In
     (Directory : String;
      Result    : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info);

   --  The same, for a caller with no failure of its own to report: one that
   --  cannot be listed whole raises Ada.IO_Exceptions.Use_Error naming it,
   --  rather than answering with part of it.
   --
   --  @param Directory The directory.
   --  @return Their simple names, sorted; none when it is not there.
   function Files_In (Directory : String) return Name_Lists.Vector;

end Model_Runner.Framework.Files;
