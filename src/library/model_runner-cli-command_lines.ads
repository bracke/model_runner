with Ada.Strings.Unbounded;

with Model_Runner.Framework;

--  A project command as typed, read into what it asks: the command, its
--  words in order, and its settings, NAME=VALUE. Every slash command is
--  read into one of these before anything is done with it, by one reader
--  (Project_Commands.Request_Of), so what a line asks is decided once and
--  a handler works from the request, not from the text.
--
--  A request is also written back as a line: the command, its words --
--  quoted where they hold a space -- then its settings. Read again, that
--  line is the same request, which is what holds the reader to itself as
--  the commands grow: a line it reads one way and writes another is a
--  reading that drifted.
--
--  Task safety: no state.
package Model_Runner.CLI.Command_Lines is

   type Request is record
      --  The command, slash and all: /task.
      Word       : Ada.Strings.Unbounded.Unbounded_String;

      --  Its words after the command, in order, a list split at its commas.
      Positional : Model_Runner.Framework.Name_Lists.Vector;

      --  Its settings, NAME=VALUE each, a value running on over the words
      --  after it to the next setting.
      Settings   : Model_Runner.Framework.Name_Lists.Vector;

      --  Whether its last word is free text kept as typed -- a note's --
      --  not words to be quoted.
      Free_Last  : Boolean := False;
   end record;

   --  A request as the one line that reads back as it: the command, its
   --  words -- a word with a space in it quoted, a free last one as it is
   --  -- and its settings last, so no word is taken into a value.
   --
   --  @param Item The request.
   --  @return The line.
   function Canonical (Item : Request) return String;

end Model_Runner.CLI.Command_Lines;
