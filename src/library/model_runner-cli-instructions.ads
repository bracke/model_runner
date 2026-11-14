--  The user's standing instructions to a conversation's model: AGENTS.md,
--  the file other coding assistants read too.
--
--  Read from the settings folder (beside the settings file) and from the
--  session's folder and each folder above it, the outermost first, so the
--  nearest has the last word. Together they are at most Most_Bytes; what is
--  past that is left out, and said to be.
package Model_Runner.CLI.Instructions is

   --  The file read.
   File_Name : constant String := "AGENTS.md";

   --  The most of them the model is given.
   Most_Bytes : constant := 32 * 1024;

   --  The instructions for a session started in a folder, each file under
   --  the path it came from; "" where there are none.
   --
   --  @param Directory The session's folder.
   --  @return The instructions, to stand before the system message.
   function Gathered (Directory : String) return String;

   --  The files Gathered read, their paths separated by ", "; "" where none.
   --
   --  @param Directory The session's folder.
   --  @return The paths.
   function Found (Directory : String) return String;

end Model_Runner.CLI.Instructions;
