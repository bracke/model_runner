with Ada.Strings.Unbounded;

--  Files mentioned in a message: @ and a path -- at the start of the
--  message or after a space -- that names a file, which goes with the
--  message: its content, up to Most_Bytes of each, after the words typed.
--  A path that names no file, a folder or a file of bytes that are not
--  text is left as the words it is.
package Model_Runner.CLI.Mentions is

   --  The most of a file attached.
   Most_Bytes : constant := 64 * 1024;

   --  What a message's mentions attach, relative to the session's folder.
   --
   --  @param Message The message as typed.
   --  @param Named The files attached, separated by ", "; "" where none.
   --  @return The files' content to send after the message; "" where none.
   function Attached
     (Message : String;
      Named   : out Ada.Strings.Unbounded.Unbounded_String) return String;

end Model_Runner.CLI.Mentions;
