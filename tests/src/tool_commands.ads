--  What the tests tool can be asked to do.
--
--  There were two hand-kept lists of this set and they disagreed with each
--  other and with the code. The tool has eleven commands; its own usage line
--  named six, so mistyping one told you about half the tool, and the README's
--  tooling row named seven -- a different seven, missing the command a
--  section of that same file tells readers to run. Both were written by hand
--  beside a dispatch chain that neither could see.
--
--  So the set lives here. The usage line is built from it, and the
--  repository checks hold the dispatch and the README against it in both
--  directions: a command the tool answers and this does not list fails, a
--  command listed here that nothing dispatches fails, and a command no
--  document names fails. That is the same treatment every other registry in
--  this repository gets, applied at last to the crate that does the
--  checking.
--
--  Task safety: pure.
package Tool_Commands is

   --  One command.
   type Command is record
      --  The word typed after `tests`.
      Name    : access constant String;

      --  What follows it in the usage line, empty when nothing does.
      Takes   : access constant String;

      --  One line, for a reader deciding whether this is the one they want.
      Summary : access constant String;
   end record;

   --  Number of commands.
   --
   --  @return How many commands this registry holds.
   function Count return Natural;

   --  One command.
   --
   --  @param Index Position, from one.
   --  @return The command at that position.
   function Item (Index : Positive) return Command;

   --  The usage line, built from the whole set.
   --
   --  @return One line naming every command and what it takes.
   function Usage_Line return String;

end Tool_Commands;
