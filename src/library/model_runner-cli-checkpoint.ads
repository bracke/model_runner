with Model_Runner.Conversation;
with Model_Runner.Errors;

--  Save and load an agent or interactive conversation, so a run or a session
--  can be taken up again.
--
--  The file is a flat length-prefixed encoding: each message is its role
--  ("S", "U", "A" or "T"), its content, its call count, then each call's name
--  and arguments, and every field is written as its byte count, a space, and
--  its bytes. So any content -- a newline, a brace, a whole JSON object --
--  round-trips with no escaping, and a file is rebuilt through the ordinary
--  Conversation append operations, needing no new conversation API.
--
--  This is a CLI concern: it reads and writes a file, which the library below
--  it never does. Both `run --agent` (checkpoint and resume) and interactive
--  mode (/save and /load) use it.
package Model_Runner.CLI.Checkpoint is

   --  Write the whole conversation to Path. Best effort: a file that will not
   --  write is not fatal and is not reported.
   --
   --  @param Path File to write.
   --  @param Messages Conversation to save.
   procedure Save
     (Path : String; Messages : Model_Runner.Conversation.History);

   --  Rebuild a conversation from Path into Messages, which the caller has
   --  opened. A file that is missing or will not parse leaves Messages as it
   --  was; Loaded says whether anything was read, and Status carries a read
   --  failure.
   --
   --  @param Path File to read.
   --  @param Messages Conversation to extend with the saved messages.
   --  @param Loaded Whether at least one message was read in.
   --  @param Status Success, or IO_Read_Failed when the file could not be
   --    read, or whatever appending a message reported.
   procedure Load
     (Path     : String;
      Messages : in out Model_Runner.Conversation.History;
      Loaded   : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info);

end Model_Runner.CLI.Checkpoint;
