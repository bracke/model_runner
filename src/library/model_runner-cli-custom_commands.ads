with Model_Runner.Framework;

--  Commands of the user's own: a Markdown file whose text is a message.
--
--  /NAME runs NAME.md from the session's folder's .model_runner/commands,
--  else from the commands folder beside the settings file: its text sent as
--  the next message, $ARGUMENTS in it replaced by the words after the
--  command -- or, where it holds none, the words put after it. A command of
--  the conversation's or of the project's own of the same name is that one.
package Model_Runner.CLI.Custom_Commands is

   --  The file a command is, or "" where there is none.
   --
   --  @param Name The command's name, without its slash.
   --  @return The file's path.
   function File_Of (Name : String) return String;

   --  A command's message: its file's text, the words put in.
   --
   --  @param Path The command's file.
   --  @param Arguments The words after the command.
   --  @return The message to send.
   function Message (Path, Arguments : String) return String;

   --  The commands there are, each "/NAME" once, the session's folder's
   --  first.
   --
   --  @return The available command names.
   function Names return Model_Runner.Framework.Name_Lists.Vector;

   --  What a command does, as its file says in its first line that holds
   --  words; "" where it says nothing.
   --
   --  @param Path The command's file.
   --  @return The line, its # marks taken off.
   function Described (Path : String) return String;

end Model_Runner.CLI.Custom_Commands;
