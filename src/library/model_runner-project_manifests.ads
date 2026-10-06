--  What a project's manifests say about what it builds, read as the formats
--  are written rather than searched for words: an Alire manifest's
--  top-level executables, a GNAT project file's Main attribute. Pure: the
--  caller reads the files and hands over their text.
package Model_Runner.Project_Manifests is

   --  Whether an Alire manifest names at least one executable: a top-level
   --  executables key -- not one inside a table -- whose array holds a
   --  string. Comments, spacing and an array over several lines are read
   --  as TOML has them; an empty array names none.
   --
   --  @param Text The manifest's text.
   --  @return True when it names an executable.
   function Alire_Names_Executables (Text : String) return Boolean;

   --  Whether a GNAT project file names a main program: a Main attribute
   --  -- for Main use (...) in any letter case, across lines -- whose list
   --  holds a string. Comments and strings are read as the language has
   --  them, so a commented-out line or the words in a string do not count,
   --  and an empty list names none.
   --
   --  @param Text The project file's text.
   --  @return True when it names a main program.
   function Gpr_Names_Main (Text : String) return Boolean;

end Model_Runner.Project_Manifests;
