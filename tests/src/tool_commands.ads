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

      --  The options it accepts, each surrounded by spaces, so that a
      --  membership test is a substring test. Empty for a command that
      --  takes only positional arguments -- and empty means every option is
      --  refused, not that none is checked.
      Options : access constant String;
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

   --  The options a command accepts.
   --
   --  Five of eleven commands used to check their options and six did not,
   --  each carrying its own copy of the list: `tests check --nonsense` ran
   --  the whole gate without a word, `tests docs --nonsense` read the typo
   --  as a directory and failed at writing, and `tests fixtures --nonsense`
   --  died with a stack trace. The lists live here now and one place reads
   --  them, so a command cannot forget to look.
   --
   --  @param Name Command word, as typed.
   --  @return The option list, or a single space when the command takes no
   --    options and when the name is not one this tool answers.
   function Options_Of (Name : String) return String;

end Tool_Commands;
